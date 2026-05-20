"""
    PythonTarget(dir, package_name, library_basename)

Output configuration for a Python ctypes-based wrapper package. `dir` is the
directory into which the package will be written; a sub-directory named
`package_name` is created and is the importable Python module. `library_basename`
is the shared library's basename without an OS-specific suffix (e.g. `"libsimple"`,
which will be loaded from `libsimple.so` / `libsimple.dylib` / `libsimple.dll`
depending on the host).
"""
struct PythonTarget <: AbstractTarget
    dir::String
    package_name::String
    library_basename::String
end

function Base.show(io::IO, t::PythonTarget)
    print(io, "PythonTarget(", repr(t.dir), ", ", repr(t.package_name),
              ", ", repr(t.library_basename), ")")
end

const pytypes = Dict{String, String}(
    "Int8" => "ctypes.c_int8",
    "Int16" => "ctypes.c_int16",
    "Int32" => "ctypes.c_int32",
    "Int64" => "ctypes.c_int64",
    "UInt8" => "ctypes.c_uint8",
    "UInt16" => "ctypes.c_uint16",
    "UInt32" => "ctypes.c_uint32",
    "UInt64" => "ctypes.c_uint64",
    "Float32" => "ctypes.c_float",
    "Float64" => "ctypes.c_double",
    "Bool" => "ctypes.c_bool",
    "RawFD" => "ctypes.c_int",

    "Cstring" => "ctypes.c_char_p",
    "Cwstring" => "ctypes.c_wchar_p",

    # As in the C emitter, these are platform-specific aliases that will not
    # appear in an auto-exported ABI but are listed for completeness.
    "Cchar" => "ctypes.c_char",
    "Cwchar_t" => "ctypes.c_wchar",
    "Cvoid" => "None",
    "Cint" => "ctypes.c_int",
    "Cshort" => "ctypes.c_short",
    "Clong" => "ctypes.c_long",
    "Cuint" => "ctypes.c_uint",
    "Cushort" => "ctypes.c_ushort",
    "Culong" => "ctypes.c_ulong",
    "Cssize_t" => "ctypes.c_ssize_t",
    "Csize_t" => "ctypes.c_size_t",
)

"""
    mangle_python!(typedict, type_id, typeinfo) -> String

Return a Python expression naming the ctypes type for `type_id`. Struct names
go through `sanitize_for_c` (whose output is also a valid Python identifier)
with a `_<id>` collision suffix matching `mangle_c!`. Pointer types render
inline as `ctypes.POINTER(...)`; `Ptr{Cvoid}` collapses to `ctypes.c_void_p`.
Results are memoised in `typedict`.
"""
function mangle_python!(typedict::Dict{Int, String}, type_id::Int,
                        typeinfo::OrderedDict{Int, TypeDesc})
    if type_id in keys(typedict)
        return typedict[type_id]
    end

    type = typeinfo[type_id]
    if type isa PrimitiveTypeDesc
        if !in(type.name, keys(pytypes))
            error("unsupported primitive type: '$(type.name)'")
        end
        return pytypes[type.name]
    elseif type isa PointerDesc
        pointee = typeinfo[type.pointee_type]
        if pointee isa PrimitiveTypeDesc && pointee.name == "Cvoid"
            mangled = "ctypes.c_void_p"
        else
            inner = mangle_python!(typedict, type.pointee_type, typeinfo)
            mangled = "ctypes.POINTER(" * inner * ")"
        end
    elseif type isa StructDesc
        mangled = sanitize_for_c(type.name)
        if mangled in values(typedict)
            suffix = type_id
            extended = mangled * "_" * string(suffix)
            while extended in values(typedict)
                suffix += 1
                extended = mangled * "_" * string(suffix)
            end
            mangled = extended
        end
    else
        @assert false "unknown descriptor type"
    end

    typedict[type_id] = mangled
    return mangled
end

const PYTHON_KEYWORDS = Set{String}([
    "False", "None", "True", "and", "as", "assert", "async", "await", "break",
    "class", "continue", "def", "del", "elif", "else", "except", "finally",
    "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal",
    "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
])

function sanitize_python_argname(name::AbstractString)
    sanitized = sanitize_for_c(name)
    isempty(sanitized) && return "_"
    sanitized in PYTHON_KEYWORDS && return sanitized * "_"
    return sanitized
end

function write_wrapper(dest::PythonTarget, abi_info::ABIInfo)
    (; entrypoints, typeinfo, forward_declared) = abi_info

    pkgdir = joinpath(dest.dir, dest.package_name)
    mkpath(pkgdir)

    typedict = Dict{Int, String}()

    # Pre-mangle every struct so that the order in which `mangle_python!` is
    # first called (which influences collision-suffix allocation) is the
    # declaration order, not the order of first textual reference. This
    # mirrors the C emitter's behaviour.
    for (id, type) in pairs(typeinfo)
        if type isa StructDesc
            mangle_python!(typedict, id, typeinfo)
        end
    end

    bindings_path = joinpath(pkgdir, "_bindings.py")
    open(bindings_path, "w") do f
        _write_bindings(f, dest, abi_info, typedict)
    end

    # Collect the public names for __init__.py re-export.
    exported_names = String[]
    for (id, type) in pairs(typeinfo)
        if type isa StructDesc
            push!(exported_names, typedict[id])
        end
    end
    for method in entrypoints
        push!(exported_names, method.symbol)
    end

    init_path = joinpath(pkgdir, "__init__.py")
    open(init_path, "w") do f
        println(f, "\"\"\"", dest.package_name,
                   " Python bindings (auto-generated by JuliaLibWrapping).\"\"\"")
        if isempty(exported_names)
            println(f, "from . import _bindings  # noqa: F401")
        else
            println(f, "from ._bindings import (")
            for name in exported_names
                println(f, "    ", name, ",")
            end
            println(f, ")")
            println(f)
            print(f, "__all__ = [")
            isfirst = true
            for name in exported_names
                isfirst || print(f, ", ")
                print(f, "\"", name, "\"")
                isfirst = false
            end
            println(f, "]")
        end
    end

    pyproject_path = joinpath(dest.dir, "pyproject.toml")
    open(pyproject_path, "w") do f
        _write_pyproject(f, dest)
    end

    return nothing
end

function _write_bindings(f::IO, dest::PythonTarget, abi_info::ABIInfo,
                         typedict::Dict{Int, String})
    (; entrypoints, typeinfo, forward_declared) = abi_info
    env_var = uppercase(dest.package_name) * "_LIBRARY"

    println(f, "\"\"\"Auto-generated by JuliaLibWrapping. Do not edit by hand.\"\"\"")
    println(f, "import ctypes")
    println(f, "import os")
    println(f, "import sys")
    println(f, "import pathlib")
    println(f)
    println(f, "_HERE = pathlib.Path(__file__).resolve().parent")
    println(f, "_LIBRARY_BASENAME = ", repr(dest.library_basename))
    println(f, "_LIBRARY_ENV_VAR = ", repr(env_var))
    println(f)
    println(f, "def _resolve_library_path():")
    println(f, "    override = os.environ.get(_LIBRARY_ENV_VAR)")
    println(f, "    if override:")
    println(f, "        return override")
    println(f, "    if sys.platform == \"win32\":")
    println(f, "        suffixes = (\".dll\",)")
    println(f, "    elif sys.platform == \"darwin\":")
    println(f, "        suffixes = (\".dylib\", \".so\")")
    println(f, "    else:")
    println(f, "        suffixes = (\".so\", \".dylib\")")
    println(f, "    tried = []")
    println(f, "    for suffix in suffixes:")
    println(f, "        candidate = _HERE / (_LIBRARY_BASENAME + suffix)")
    println(f, "        tried.append(str(candidate))")
    println(f, "        if candidate.exists():")
    println(f, "            return str(candidate)")
    println(f, "    raise FileNotFoundError(")
    println(f, "        f\"Could not locate shared library {_LIBRARY_BASENAME!r}. \"")
    println(f, "        f\"Tried: {tried}. Set {_LIBRARY_ENV_VAR} to an explicit path.\"")
    println(f, "    )")
    println(f)
    println(f, "_lib = ctypes.CDLL(_resolve_library_path())")
    println(f)

    # Forward declarations: emit empty Structure subclasses for any recursive
    # type that the dependency sort could not place.
    if !isempty(forward_declared)
        println(f, "# Forward declarations for recursive types")
        for id in forward_declared
            type = typeinfo[id]
            @assert type isa StructDesc "unexpected forward-declared non-struct"
            println(f, "class ", typedict[id], "(ctypes.Structure):")
            println(f, "    pass")
            println(f)
        end
    end

    # Struct definitions in dependency order.
    for (id, type) in pairs(typeinfo)
        type isa StructDesc || continue
        name = typedict[id]
        if id in forward_declared
            # Body deferred — assign _fields_ now that all classes exist.
            println(f, name, "._fields_ = [")
            for field in type.fields
                ft = mangle_python!(typedict, field.type, typeinfo)
                println(f, "    (", repr(sanitize_python_argname(field.name)), ", ", ft, "),")
            end
            println(f, "]")
        else
            println(f, "class ", name, "(ctypes.Structure):")
            if isempty(type.fields)
                println(f, "    _fields_ = []")
            else
                println(f, "    _fields_ = [")
                for field in type.fields
                    ft = mangle_python!(typedict, field.type, typeinfo)
                    println(f, "        (", repr(sanitize_python_argname(field.name)), ", ", ft, "),")
                end
                println(f, "    ]")
            end
        end
        println(f)
    end

    # Function bindings.
    for method in entrypoints
        argexprs = String[mangle_python!(typedict, a.type, typeinfo) for a in method.args]
        rt = mangle_python!(typedict, method.return_type, typeinfo)
        println(f, "_lib.", method.symbol, ".argtypes = [", join(argexprs, ", "), "]")
        println(f, "_lib.", method.symbol, ".restype = ", rt)

        argnames = String[sanitize_python_argname(a.name) for a in method.args]
        # Disambiguate any duplicates that the sanitiser collapsed onto the same name.
        seen = Dict{String, Int}()
        for i in eachindex(argnames)
            n = argnames[i]
            if haskey(seen, n)
                seen[n] += 1
                argnames[i] = n * string(seen[n])
            else
                seen[n] = 1
            end
        end

        println(f, "def ", method.symbol, "(", join(argnames, ", "), "):")
        if rt == "None"
            println(f, "    _lib.", method.symbol, "(", join(argnames, ", "), ")")
        else
            println(f, "    return _lib.", method.symbol, "(", join(argnames, ", "), ")")
        end
        println(f)
    end
end

function _write_pyproject(f::IO, dest::PythonTarget)
    println(f, "# Auto-generated by JuliaLibWrapping. Edit only if you know what you are doing.")
    println(f, "[build-system]")
    println(f, "requires = [\"setuptools>=64\"]")
    println(f, "build-backend = \"setuptools.build_meta\"")
    println(f)
    println(f, "[project]")
    println(f, "name = ", repr(dest.package_name))
    println(f, "version = \"0.0.0\"")
    println(f, "description = \"Python bindings for ", dest.library_basename,
               ", auto-generated by JuliaLibWrapping\"")
    println(f, "requires-python = \">=3.8\"")
    println(f)
    println(f, "[tool.setuptools]")
    println(f, "packages = [", repr(dest.package_name), "]")
    println(f)
    println(f, "[tool.setuptools.package-data]")
    println(f, dest.package_name, " = [\"*.so\", \"*.dylib\", \"*.dll\"]")
end
