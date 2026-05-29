"""
    CTarget(dir, headerbase)

Output configuration for a C header. [`write_wrapper`](@ref) writes a
single file `joinpath(dir, headerbase * ".h")` containing typedefs for
every struct in the ABI and `extern` declarations for every entrypoint.

Only the primitive Julia types listed in the emitter's `ctypes` table
have a direct C mapping; an ABI referencing any other primitive raises
an error. Pointer types are emitted inline as `T*` rather than as
separate typedefs. Non-C-safe identifiers are scrubbed by
[`sanitize_for_c`](@ref) and disambiguated with a numeric suffix on
collision.
"""
struct CTarget <: AbstractTarget
    dir::String
    headerbase::String
end

function Base.show(io::IO, t::CTarget)
    print(io, "CTarget(", repr(t.dir), ", ", repr(t.headerbase), ")")
end

function unwrap_pointer_type(type_id::Int, typeinfo::OrderedDict{Int, TypeDesc})
    while typeinfo[type_id] isa PointerDesc
        type_id = typeinfo[type_id].pointee_type
    end
    return type_id
end

"""
    write_wrapper(target::AbstractTarget, abi_info::ABIInfo)

Emit wrapper source files for `abi_info` into the location described by
`target`. The methods that ship are dispatched on [`CTarget`](@ref) (one
`.h` file) and [`PythonTarget`](@ref) (a Python `ctypes` package
directory). Add a method for a new [`AbstractTarget`](@ref) subtype to
support another output language.
"""
function write_wrapper end

# Field suffix for C array declarations: `T name[N];` rather than `T name;`.
function c_field_array_suffix(type_id::Int, typeinfo::OrderedDict{Int, TypeDesc})
    desc = typeinfo[type_id]
    return desc isa ArrayDesc ? "[" * string(desc.count) * "]" : ""
end

function write_wrapper(dest::CTarget, abi_info::ABIInfo)
    (; entrypoints, typeinfo, forward_declared) = abi_info

    # Write the header file for C
    headerfile = joinpath(dest.dir, dest.headerbase * ".h")
    libvar = "JULIALIB_" * uppercase(dest.headerbase) * "_H"
    open(headerfile, "w") do f
        println(f, "#ifndef $libvar")
        println(f, "#define $libvar")
        println(f, "#include <stddef.h>")
        println(f, "#include <stdint.h>")
        println(f, "#include <stdbool.h>")
        println(f)

        typedict = Dict{Int, String}()

        # Print forward-declarations (if any, for recursive types)
        for id in forward_declared
            type = typeinfo[id]
            @assert type isa StructDesc "un-expected forward declaration type"
            mangled_name = mangle_c!(typedict, id, typeinfo)
            println(f, "struct ", mangled_name, ";")
        end

        # Print the struct definitions
        printed = BitSet()
        for (id, type) in pairs(typeinfo)
            if type isa StructDesc
                mangled_name = mangle_c!(typedict, id, typeinfo)
                println(f, "typedef struct ", mangled_name, " {")
                for field in type.fields
                    ft = mangle_c!(typedict, field.type, typeinfo)
                    field_desc = typeinfo[field.type]
                    elt_id = field_desc isa ArrayDesc ? field_desc.element_type : field.type
                    if !in(unwrap_pointer_type(elt_id, typeinfo), printed)
                        ft = "struct " * ft
                    end
                    suffix = c_field_array_suffix(field.type, typeinfo)
                    println(f, "    ", ft, " ", sanitize_for_c(field.name), suffix, ";")
                end
                println(f, "} ", mangled_name, ";")
            elseif type isa PrimitiveTypeDesc
                # We only rely on built-in primitive types (c.f. `ctypes`)
            elseif type isa PointerDesc
                # We emit pointer types in-line - no need for a separate typedef
            elseif type isa ArrayDesc
                # Arrays render inline at field-emit sites (`T name[N]`); no typedef.
            else @assert false "unknown descriptor type" end
            push!(printed, id)
        end
        println(f)

        for method in entrypoints
            if typeinfo[method.return_type] isa ArrayDesc
                error("C entrypoint `", method.symbol,
                      "`: returning an array type is not representable in C; ",
                      "wrap the result in a struct.")
            end
            mangled_rt = mangle_c!(typedict, method.return_type, typeinfo)
            print(f, mangled_rt, " ", method.symbol, "(")
            isfirst = true
            for arg in method.args
                if typeinfo[arg.type] isa ArrayDesc
                    error("C entrypoint `", method.symbol, "`: argument `",
                          arg.name, "` has array type, which decays to a ",
                          "pointer in C parameters; wrap it in a struct or ",
                          "pass `Ptr{<element>}` plus a length.")
                end
                if isfirst
                    isfirst = false
                else
                    print(f, ", ")
                end
                ft = mangle_c!(typedict, arg.type, typeinfo)
                print(f, ft)
                if !(isempty(arg.name) || arg.name == "#unused#")
                    print(f, " ", sanitize_for_c(arg.name))
                end
                if arg.isva
                    print(f, "...")
                end
            end
            print(f, ");\n")
        end

        println(f, "\n#endif // $libvar")
    end
end

const ctypes = Dict{String, String}(
    "Int8" => "int8_t",
    "Int16" => "int16_t",
    "Int32" => "int32_t",
    "Int64" => "int64_t",
    "UInt8" => "uint8_t",
    "UInt16" => "uint16_t",
    "UInt32" => "uint32_t",
    "UInt64" => "uint64_t",
    "Float32" => "float",
    "Float64" => "double",
    "Bool" => "bool",
    "RawFD" => "int",

    "Cstring" => "char *",
    "Cwstring" => "wchar_t *",

    # Note: These types will never appear in an auto-exported ABI, since they are not
    # distinct Julia types (these are just platform-specific aliases to the types above).
    "Cchar" => "char",
    "Cwchar_t" => "wchar_t",
    "Cvoid" => "void",
    "Cint" => "int",
    "Cshort" => "short",
    "Clong" => "long",
    "Cuint" => "unsigned int",
    "Cushort" => "unsigned short",
    "Culong" => "unsigned long",
    "Cssize_t" => "ssize_t",
    "Csize_t" => "size_t",
)

"""
    sanitize_for_c(str) -> String

Return `str` with all non-alphanumeric (non-underscore) characters
replaced by `_`, leading/trailing underscores stripped, and runs of
underscores collapsed. Used to coerce Julia identifiers and type names
into valid C tokens. Two distinct inputs may collide; callers that need
uniqueness (e.g. `mangle_c!`) suffix the result with a numeric
disambiguator.
"""
function sanitize_for_c(str::AbstractString)
    # Replace any non alphanumeric characters with '_'
    str = replace(str, r"[^a-zA-Z0-9_]" => "_")
    # Strip any leading / trailing underscores
    str = strip(str, Char['_'])
    # Merge any repeated underscores to just one
    return replace(str, r"_+" => "_")
end

function mangle_c!(typedict::Dict{Int, String}, type_id::Int, typeinfo::OrderedDict{Int,TypeDesc})
    if type_id in keys(typedict)
        return typedict[type_id]
    end

    type = typeinfo[type_id]
    if type isa PrimitiveTypeDesc
        if !in(type.name, keys(ctypes))
            error("unsupported primitive type: '$(type.name)'")
        end
        return ctypes[type.name]
    elseif type isa PointerDesc
        mangled = mangle_c!(typedict, type.pointee_type, typeinfo) * "*"
    elseif type isa StructDesc
        mangled = sanitize_for_c(type.name)
    elseif type isa ArrayDesc
        # In C, arrays do not have a single token that composes anywhere a
        # type can appear — `T name[N]` requires the `[N]` to follow the
        # declarator. Callers that emit an array-typed field add `[N]` after
        # the field name; here we just hand back the element type's C name.
        return mangle_c!(typedict, type.element_type, typeinfo)
    end

    # Check for any name collision and unique the symbol, if necessary.
    if mangled in values(typedict)
        suffix = type_id
        extended = mangled * "_" * string(suffix)
        while extended in values(typedict)
            suffix += 1
            extended = mangled * "_" * string(suffix)
        end
        mangled = extended
    end

    typedict[type_id] = mangled
    return mangled
end
