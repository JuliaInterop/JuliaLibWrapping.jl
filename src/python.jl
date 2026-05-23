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
    tuple_struct_info(desc::StructDesc) -> Union{Nothing, Tuple{Int, Int}}

If `desc` is the ABI encoding of a Julia tuple type (e.g. `NTuple{N, T}` —
which juliac emits as a struct whose fields are named `"1"`, `"2"`, …, `"N"`
and all share a common type), return `(element_type_id, count)`. Otherwise
return `nothing`. Such structs are emitted inline as `ctypes` arrays rather
than as `Structure` subclasses (Python forbids field identifiers that start
with a digit, and arrays are also more idiomatic for fixed-size byte buffers).
"""
function tuple_struct_info(desc::StructDesc)
    n = length(desc.fields)
    n == 0 && return nothing
    eltype_id = desc.fields[1].type
    for (i, field) in enumerate(desc.fields)
        field.name == string(i) || return nothing
        field.type == eltype_id || return nothing
    end
    return (eltype_id, n)
end

"""
    mangle_python!(typedict, type_id, typeinfo) -> String

Return a Python expression naming the ctypes type for `type_id`. Struct names
go through `sanitize_for_c` (whose output is also a valid Python identifier)
with a `_<id>` collision suffix matching `mangle_c!`. Pointer types render
inline as `ctypes.POINTER(...)`; `Ptr{Cvoid}` collapses to `ctypes.c_void_p`.
Tuple-shaped structs (see [`tuple_struct_info`](@ref)) render inline as
`(<eltype> * N)`. Results are memoized in `typedict`.
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
        tinfo = tuple_struct_info(type)
        if tinfo !== nothing
            eltype_id, count = tinfo
            eltype_expr = mangle_python!(typedict, eltype_id, typeinfo)
            mangled = "(" * eltype_expr * " * " * string(count) * ")"
        else
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

"""
    sanitize_python_argname(name) -> String
    sanitize_python_argname(name, seen::Set{String}) -> String

Return a Python-identifier form of `name`: characters illegal in identifiers
are stripped via [`sanitize_for_c`](@ref), an empty result becomes `"_"`, and
any reserved Python keyword is suffixed with `_`.

When a `seen` set is supplied, the returned name is also made unique within
that scope (callers should pass one `Set{String}` per scope — e.g. one per
function signature, one per struct's field list). If the candidate already
appears in `seen`, an integer suffix (`2`, `3`, …) is appended until the name
is fresh, skipping any value that itself already collides — so the result is
safe even when sanitized input happens to look like another argument plus a
numeric tail. The chosen name is inserted into `seen` before returning.
"""
function sanitize_python_argname(name::AbstractString, seen=nothing)
    sanitized = sanitize_for_c(name)
    isempty(sanitized) && (sanitized = "_")
    sanitized in PYTHON_KEYWORDS && (sanitized *= "_")
    if seen !== nothing
        if sanitized in seen
            i = 2
            candidate = sanitized * string(i)
            while candidate in seen
                i += 1
                candidate = sanitized * string(i)
            end
            sanitized = candidate
        end
        push!(seen, sanitized)
    end
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
    # mirrors the C emitter's behavior. Tuple-shaped structs are not
    # pre-mangled because they render inline (as ctypes arrays) and never
    # contribute a name to the collision pool.
    for (id, type) in pairs(typeinfo)
        if type isa StructDesc && tuple_struct_info(type) === nothing
            mangle_python!(typedict, id, typeinfo)
        end
    end

    needs_jlwerror = any(jlwstatus_access_path(m, typeinfo) !== nothing
                        for m in entrypoints)

    bindings_path = joinpath(pkgdir, "_bindings.py")
    open(bindings_path, "w") do f
        _write_bindings(f, dest, abi_info, typedict, needs_jlwerror)
    end

    # Collect the public names for __init__.py re-export. Tuple-shaped
    # structs do not emit a class so they are skipped here.
    exported_names = String[]
    needs_jlwerror && push!(exported_names, "JLWError")
    for (id, type) in pairs(typeinfo)
        if type isa StructDesc && tuple_struct_info(type) === nothing
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

"""
    is_jlwstatus_struct(desc::StructDesc, typeinfo) -> Bool

Recognize the JLWInterop error-status convention (issue #15) by structural
shape: a struct named `JLWStatus` with two fields — an integer `code` field
and a `message` field that is a tuple-of-bytes struct. Matching by name +
shape (rather than by package identity) means authors who copy-paste a
compatible definition still get the behavior.
"""
function is_jlwstatus_struct(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    desc.name == "JLWStatus" || return false
    length(desc.fields) == 2 || return false
    code_field, msg_field = desc.fields
    code_field.name == "code" || return false
    msg_field.name == "message" || return false
    code_type = typeinfo[code_field.type]
    code_type isa PrimitiveTypeDesc || return false
    code_type.name in ("Int32", "Int64") || return false
    msg_type = typeinfo[msg_field.type]
    msg_type isa StructDesc || return false
    tinfo = tuple_struct_info(msg_type)
    tinfo === nothing && return false
    eltype = typeinfo[tinfo[1]]
    eltype isa PrimitiveTypeDesc && eltype.name == "UInt8" || return false
    return true
end

"""
    jlwstatus_access_path(method, typeinfo) -> Union{Nothing, String}

If `method`'s return type carries a JLWStatus (either the return type *is* a
JLWStatus or it is a struct with a JLWStatus field), return the Python
attribute path from `_result` to that status (e.g. `""` for direct return,
or `".status"` for an embedded field). Otherwise return `nothing`.
Recognition is shallow on purpose — only the immediate return struct's
top-level fields are inspected. Implements part of issue #15.
"""
function jlwstatus_access_path(method::MethodDesc, typeinfo::OrderedDict{Int, TypeDesc})
    rt = typeinfo[method.return_type]
    rt isa StructDesc || return nothing
    if is_jlwstatus_struct(rt, typeinfo)
        return ""
    end
    for field in rt.fields
        ftype = typeinfo[field.type]
        if ftype isa StructDesc && is_jlwstatus_struct(ftype, typeinfo)
            return "." * sanitize_python_argname(field.name)
        end
    end
    return nothing
end

const JLWERROR_DEFINITION = """
class JLWError(RuntimeError):
    \"\"\"Raised when a wrapped function returns a non-zero JLWStatus.code.\"\"\"
    def __init__(self, code, message):
        super().__init__(f"[{code}] {message}")
        self.code = code
        self.message = message
"""

function _write_bindings(f::IO, dest::PythonTarget, abi_info::ABIInfo,
                         typedict::Dict{Int, String}, needs_jlwerror::Bool=false)
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

    if needs_jlwerror
        # Implements issue #15: error-propagation convention via JLWStatus.
        print(f, JLWERROR_DEFINITION)
        println(f)
    end

    # Forward declarations: emit empty Structure subclasses for any recursive
    # type that the dependency sort could not place. Tuple-shaped structs
    # render inline as ctypes arrays so they never need forward declaration.
    if !isempty(forward_declared)
        println(f, "# Forward declarations for recursive types")
        for id in forward_declared
            type = typeinfo[id]
            @assert type isa StructDesc "unexpected forward-declared non-struct"
            @assert tuple_struct_info(type) === nothing "tuple-shaped struct should not be forward-declared"
            println(f, "class ", typedict[id], "(ctypes.Structure):")
            println(f, "    pass")
            println(f)
        end
    end

    # Struct definitions in dependency order. Tuple-shaped structs are
    # emitted inline (as `(<eltype> * N)` ctypes arrays) by `mangle_python!`,
    # so they get no class of their own.
    for (id, type) in pairs(typeinfo)
        type isa StructDesc || continue
        tuple_struct_info(type) === nothing || continue
        name = typedict[id]
        field_names_seen = Set{String}()
        if id in forward_declared
            # Body deferred — assign _fields_ now that all classes exist.
            println(f, name, "._fields_ = [")
            for field in type.fields
                ft = mangle_python!(typedict, field.type, typeinfo)
                fname = sanitize_python_argname(field.name, field_names_seen)
                println(f, "    (", repr(fname), ", ", ft, "),")
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
                    fname = sanitize_python_argname(field.name, field_names_seen)
                    println(f, "        (", repr(fname), ", ", ft, "),")
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

        arg_names_seen = Set{String}()
        argnames = String[sanitize_python_argname(a.name, arg_names_seen) for a in method.args]

        status_path = jlwstatus_access_path(method, typeinfo)

        println(f, "def ", method.symbol, "(", join(argnames, ", "), "):")
        if status_path !== nothing
            # Implements issue #15: raise JLWError when status.code != 0.
            println(f, "    _result = _lib.", method.symbol, "(", join(argnames, ", "), ")")
            println(f, "    if _result", status_path, ".code != 0:")
            println(f, "        _msg = bytes(_result", status_path,
                       ".message).rstrip(b\"\\x00\").decode(\"utf-8\", errors=\"replace\")")
            println(f, "        raise JLWError(_result", status_path, ".code, _msg)")
            println(f, "    return _result")
        elseif rt == "None"
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
