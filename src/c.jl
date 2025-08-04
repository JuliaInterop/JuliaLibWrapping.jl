struct CProject
    dir::String
    headerbase::String
end

function wrapper(dest::CProject, abi_info::ABIInfo)
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
        for (id, type) in pairs(typeinfo)
            if type isa StructDesc
                mangled_name = mangle_c!(typedict, id, typeinfo)
                println(f, "typedef struct ", mangled_name, " {")
                for field in type.fields
                    ft = mangle_c!(typedict, field.type, typeinfo)
                    println(f, "    ", ft, " ", sanitize_for_c(field.name), ";")
                end
                println(f, "} ", mangled_name, ";")
            elseif type isa PrimitiveTypeDesc
                # We only rely on built-in primitive types (c.f. `ctypes`)
            elseif type isa PointerDesc
                # We emit pointer types in-line - no need for a separate typedef
            end
        end
        println(f)

        for method in entrypoints
            args = join(method.args, ", ")
            if !isempty(args)
                args = ", " * args
            end
            mangled_rt = mangle_c!(typedict, method.return_type, typeinfo)
            print(f, mangled_rt, " ", method.symbol, "(")
            isfirst = true
            for arg in method.args
                if isfirst
                    isfirst = false
                else
                    print(f, ", ")
                end
                ft = mangle_c!(typedict, arg.type, typeinfo)
                print(f, ft, " ", sanitize_for_c(arg.name))
                if arg.isva
                    print(f, "...")
                end
            end
            print(f, ");\n")
        end

        println(f, "#endif // $libvar")
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
    end
    # FIXME: this function should check for name collisions at this stage (which can happen due to
    #        sanitization or name ambiguity in the printing from Julia) and gensym a unique suffix
    #        if necessary
    typedict[type_id] = mangled
    return mangled
end
