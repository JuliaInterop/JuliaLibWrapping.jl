struct CProject
    dir::String
    headerbase::String
end

function wrapper(dest::CProject, entrypoints, typedescs)
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

        typedict = Dict{String, String}()
        for type in values(typedescs)
            println(f, "typedef struct {")
            for field in type.fields
                ft = mangle_c!(typedict, field.type)
                println(f, "    ", ft, " ", field.name, ";")
            end
            println(f, "} ", mangle_c!(typedict, type.name), ";")
        end
        println(f)

        for method in entrypoints
            args = join(method.args, ", ")
            if !isempty(args)
                args = ", " * args
            end
            print(f, mangle_c!(typedict, method.return_type), " ", method.name, "(")
            isfirst = true
            for arg in method.args
                if isfirst
                    isfirst = false
                else
                    print(f, ", ")
                end
                ft = mangle_c!(typedict, arg.type)
                print(f, ft, " ", arg.name)
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
    "Bool" => "_Bool",
    "Cvoid" => "void",
    "Cint" => "int",
    "Cshort" => "short",
    "Clong" => "long",
    "Cuint" => "unsigned int",
    "Cushort" => "unsigned short",
    "Culong" => "unsigned long",
    "Cssize_t" => "ssize_t",
    "Csize_t" => "size_t",
    "Cchar" => "char",
    "Cwchar_t" => "wchar_t",
    "Cstring" => "char *",
    "Cwstring" => "wchar_t *",
    "RawFD" => "int",
)

function mangle_c!(typedict::Dict{String, String}, type::AbstractString)
    ft = get(typedict, type, nothing)
    ft !== nothing && return ft
    ft = get(ctypes, type, nothing)
    ft !== nothing && return ft
    idxbad = findfirst(r"[^a-zA-Z0-9_\{\}]", type)
    if idxbad !== nothing
        error("Invalid type name: ", type, " (invalid character at position ", idxbad, ")")
    end
    m = match(r"^Ptr\{(.+)\}$", type)
    if m !== nothing
        inner_type = m.captures[1]
        result = mangle_c!(typedict, inner_type) * "*"
        typedict[type] = result
        return result
    end
    m = match(r"^(.+)\{(.+)\}$", type)
    if m !== nothing
        basename, params = m.captures
        params = split(params, ",")
        params = join(map(p -> mangle_c!(typedict, p), params), "_")
        result = basename * "_" * params * "_"
        typedict[type] = result
        return result
    end
    typedict[type] = type
    return type
end
