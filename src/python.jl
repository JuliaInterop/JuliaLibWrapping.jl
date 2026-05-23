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

const numpy_dtypes = Dict{String, String}(
    "Int8" => "int8", "Int16" => "int16", "Int32" => "int32", "Int64" => "int64",
    "UInt8" => "uint8", "UInt16" => "uint16", "UInt32" => "uint32", "UInt64" => "uint64",
    "Float32" => "float32", "Float64" => "float64",
)

"""
    cvector_struct_info(desc::StructDesc, typeinfo) -> Union{Nothing, NamedTuple}

Recognize the JLWInterop `CVector{T}` shape: a struct whose name starts
with `"CVector"`, with exactly two fields named `length` (a primitive
integer) and `data` (a pointer to a primitive numeric type recognized by
[`numpy_dtypes`](@ref)). Returns `(; pointee_name, pointee_ctype, dtype)`
on a match, otherwise `nothing`. Field order may be either `length, data`
or `data, length`. Like [`is_jlwstatus_struct`](@ref), recognition is by
name + shape so authors who copy-paste a compatible definition still get
the behavior.
"""
function cvector_struct_info(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    startswith(desc.name, "CVector") || return nothing
    length(desc.fields) == 2 || return nothing
    length_field = nothing
    data_field = nothing
    for field in desc.fields
        if field.name == "length"
            length_field = field
        elseif field.name == "data"
            data_field = field
        end
    end
    (length_field === nothing || data_field === nothing) && return nothing
    length_type = typeinfo[length_field.type]
    length_type isa PrimitiveTypeDesc || return nothing
    length_type.name in keys(numpy_dtypes) || return nothing
    # Reject Float* and Bool as length types — they're in numpy_dtypes but
    # only integers make sense for a count.
    startswith(length_type.name, "Int") || startswith(length_type.name, "UInt") || return nothing
    data_type = typeinfo[data_field.type]
    data_type isa PointerDesc || return nothing
    pointee = typeinfo[data_type.pointee_type]
    pointee isa PrimitiveTypeDesc || return nothing
    pointee.name in keys(numpy_dtypes) || return nothing
    return (; pointee_name = pointee.name,
              pointee_ctype = pytypes[pointee.name],
              dtype = numpy_dtypes[pointee.name])
end

"""
    cmatrix_struct_info(desc::StructDesc, typeinfo) -> Union{Nothing, NamedTuple}

Recognize the JLWInterop `CMatrix{T}` shape: a struct whose name starts
with `"CMatrix"`, with exactly three fields named `rows`, `cols` (primitive
integers) and `data` (a pointer to a primitive numeric type recognized by
[`numpy_dtypes`](@ref)). Field order is irrelevant. Returns
`(; pointee_name, pointee_ctype, dtype)` on a match, otherwise `nothing`.
Recognition is by name + shape (see [`is_jlwstatus_struct`](@ref) for the
rationale).
"""
function cmatrix_struct_info(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    startswith(desc.name, "CMatrix") || return nothing
    length(desc.fields) == 3 || return nothing
    rows_field = nothing
    cols_field = nothing
    data_field = nothing
    for field in desc.fields
        if field.name == "rows"
            rows_field = field
        elseif field.name == "cols"
            cols_field = field
        elseif field.name == "data"
            data_field = field
        end
    end
    (rows_field === nothing || cols_field === nothing || data_field === nothing) && return nothing
    for f in (rows_field, cols_field)
        t = typeinfo[f.type]
        t isa PrimitiveTypeDesc || return nothing
        (startswith(t.name, "Int") || startswith(t.name, "UInt")) || return nothing
        t.name in keys(numpy_dtypes) || return nothing
    end
    data_type = typeinfo[data_field.type]
    data_type isa PointerDesc || return nothing
    pointee = typeinfo[data_type.pointee_type]
    pointee isa PrimitiveTypeDesc || return nothing
    pointee.name in keys(numpy_dtypes) || return nothing
    return (; pointee_name = pointee.name,
              pointee_ctype = pytypes[pointee.name],
              dtype = numpy_dtypes[pointee.name])
end

"""
    cstring_struct_info(desc::StructDesc, typeinfo) -> Bool

Recognize the JLWInterop `CString` shape: a struct whose name starts with
`"CString"`, with exactly two fields named `length` (a primitive integer)
and `data` (a pointer to `UInt8`). The pointee type is restricted to
`UInt8` specifically (other widths would not round-trip as a UTF-8
string). Returns `true` on a match, `false` otherwise. Field order may be
either `length, data` or `data, length`. Recognition is by name + shape
(see [`is_jlwstatus_struct`](@ref) for the rationale).
"""
function cstring_struct_info(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    startswith(desc.name, "CString") || return false
    length(desc.fields) == 2 || return false
    length_field = nothing
    data_field = nothing
    for field in desc.fields
        if field.name == "length"
            length_field = field
        elseif field.name == "data"
            data_field = field
        end
    end
    (length_field === nothing || data_field === nothing) && return false
    length_type = typeinfo[length_field.type]
    length_type isa PrimitiveTypeDesc || return false
    (startswith(length_type.name, "Int") || startswith(length_type.name, "UInt")) || return false
    data_type = typeinfo[data_field.type]
    data_type isa PointerDesc || return false
    pointee = typeinfo[data_type.pointee_type]
    pointee isa PrimitiveTypeDesc || return false
    pointee.name == "UInt8" || return false
    return true
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
    needs_numpy = any(type isa StructDesc &&
                      (cvector_struct_info(type, typeinfo) !== nothing ||
                       cmatrix_struct_info(type, typeinfo) !== nothing)
                      for type in values(typeinfo))

    bindings_path = joinpath(pkgdir, "_bindings.py")
    open(bindings_path, "w") do f
        _write_bindings(f, dest, abi_info, typedict, needs_jlwerror, needs_numpy)
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
        _write_pyproject(f, dest, needs_numpy)
    end

    return nothing
end

"""
    is_jlwstatus_struct(desc::StructDesc, typeinfo) -> Bool

Recognize the JLWInterop error-status convention by structural shape: a
struct named `JLWStatus` with two fields — an integer `code` field and a
`message` field that is a tuple-of-bytes struct. Matching by name + shape
(rather than by package identity) means authors who copy-paste a compatible
definition still get the behavior.
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
top-level fields are inspected.
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

function _write_cvector_helpers(f::IO, cvinfo)
    # `cvinfo` is the return of `cvector_struct_info`. Helpers are emitted as
    # methods on the surrounding ctypes.Structure subclass; the `length` and
    # `data` field names are guaranteed by the recognizer.
    ctype = cvinfo.pointee_ctype
    dtype = cvinfo.dtype
    println(f, "")
    println(f, "    @classmethod")
    println(f, "    def from_numpy(cls, arr):")
    println(f, "        \"\"\"Return a CVector view of the 1-D contiguous numpy array `arr`.")
    println(f, "")
    println(f, "        Raises ValueError on ndim, contiguity, or dtype mismatch (fail-fast: no")
    println(f, "        silent reinterpretation). The returned object holds a reference to `arr`,")
    println(f, "        so the caller must keep it alive for the duration of any C call that uses")
    println(f, "        the buffer.\"\"\"")
    println(f, "        if arr.ndim != 1:")
    println(f, "            raise ValueError(f\"expected 1-D array, got {arr.ndim}-D\")")
    println(f, "        if not arr.flags.c_contiguous:")
    println(f, "            raise ValueError(\"array must be C-contiguous\")")
    println(f, "        expected_dtype = np.dtype(", repr(dtype), ")")
    println(f, "        if arr.dtype != expected_dtype:")
    println(f, "            raise ValueError(f\"expected dtype ", dtype, ", got {arr.dtype}\")")
    println(f, "        obj = cls(length=arr.size,")
    println(f, "                  data=arr.ctypes.data_as(ctypes.POINTER(", ctype, ")))")
    println(f, "        obj._buffer = arr")
    println(f, "        return obj")
    println(f, "")
    println(f, "    def as_numpy(self):")
    println(f, "        \"\"\"Return a 1-D numpy view of the underlying buffer (no copy).\"\"\"")
    println(f, "        return np.ctypeslib.as_array(self.data, shape=(self.length,))")
end

function _write_cstring_helpers(f::IO)
    # CString shape — see `cstring_struct_info`. The `length` and `data`
    # field names are guaranteed by the recognizer, and the pointee is
    # UInt8 / ctypes.c_uint8. Unlike CVector and CMatrix this emits no
    # numpy dependency; helpers use only `ctypes`.
    println(f, "")
    println(f, "    @classmethod")
    println(f, "    def from_str(cls, s):")
    println(f, "        \"\"\"Return a CString whose buffer holds the UTF-8 encoding of `s`.")
    println(f, "")
    println(f, "        Allocates a fresh ctypes buffer and copies the bytes into it; the")
    println(f, "        returned object holds a reference to that buffer, so the caller")
    println(f, "        must keep it alive for the duration of any C call that uses it.\"\"\"")
    println(f, "        if not isinstance(s, str):")
    println(f, "            raise TypeError(f\"expected str, got {type(s).__name__}\")")
    println(f, "        return cls.from_bytes(s.encode(\"utf-8\"))")
    println(f, "")
    println(f, "    @classmethod")
    println(f, "    def from_bytes(cls, b):")
    println(f, "        \"\"\"Return a CString whose buffer holds a copy of the bytes `b`.\"\"\"")
    println(f, "        if not isinstance(b, (bytes, bytearray)):")
    println(f, "            raise TypeError(f\"expected bytes-like, got {type(b).__name__}\")")
    println(f, "        n = len(b)")
    println(f, "        buf = (ctypes.c_uint8 * n).from_buffer_copy(b) if n else (ctypes.c_uint8 * 0)()")
    println(f, "        obj = cls(length=n,")
    println(f, "                  data=ctypes.cast(buf, ctypes.POINTER(ctypes.c_uint8)))")
    println(f, "        obj._buffer = buf")
    println(f, "        return obj")
    println(f, "")
    println(f, "    def as_bytes(self):")
    println(f, "        \"\"\"Return a copy of the underlying bytes as a Python `bytes` object.\"\"\"")
    println(f, "        return ctypes.string_at(self.data, self.length)")
    println(f, "")
    println(f, "    def as_str(self):")
    println(f, "        \"\"\"Return the underlying bytes decoded as UTF-8.\"\"\"")
    println(f, "        return self.as_bytes().decode(\"utf-8\")")
end

function _write_cmatrix_helpers(f::IO, cminfo)
    # Mirror of `_write_cvector_helpers` for the column-major 2-D shape.
    # `rows`, `cols`, and `data` field names are guaranteed by the recognizer.
    ctype = cminfo.pointee_ctype
    dtype = cminfo.dtype
    println(f, "")
    println(f, "    @classmethod")
    println(f, "    def from_numpy(cls, arr):")
    println(f, "        \"\"\"Return a CMatrix view of the 2-D Fortran-contiguous numpy array `arr`.")
    println(f, "")
    println(f, "        CMatrix storage is column-major (Julia / Fortran order). A default")
    println(f, "        row-major (C-order) numpy array is REJECTED rather than silently")
    println(f, "        transposed — call `np.asfortranarray(arr)` first if needed.")
    println(f, "        Raises ValueError on ndim, contiguity, or dtype mismatch. The returned")
    println(f, "        object holds a reference to `arr`, so the caller must keep it alive for")
    println(f, "        the duration of any C call that uses the buffer.\"\"\"")
    println(f, "        if arr.ndim != 2:")
    println(f, "            raise ValueError(f\"expected 2-D array, got {arr.ndim}-D\")")
    println(f, "        if not arr.flags.f_contiguous:")
    println(f, "            raise ValueError(\"array must be Fortran-contiguous (column-major); \"")
    println(f, "                             \"use np.asfortranarray(arr) to convert\")")
    println(f, "        expected_dtype = np.dtype(", repr(dtype), ")")
    println(f, "        if arr.dtype != expected_dtype:")
    println(f, "            raise ValueError(f\"expected dtype ", dtype, ", got {arr.dtype}\")")
    println(f, "        obj = cls(rows=arr.shape[0], cols=arr.shape[1],")
    println(f, "                  data=arr.ctypes.data_as(ctypes.POINTER(", ctype, ")))")
    println(f, "        obj._buffer = arr")
    println(f, "        return obj")
    println(f, "")
    println(f, "    def as_numpy(self):")
    println(f, "        \"\"\"Return a 2-D column-major numpy view of the underlying buffer (no copy).")
    println(f, "")
    println(f, "        The view has shape `(rows, cols)` and Fortran (column-major) strides,")
    println(f, "        matching the storage layout.\"\"\"")
    println(f, "        # Read the column-major buffer as (cols, rows) row-major then transpose:")
    println(f, "        # the transpose is a view, and the result has the correct (rows, cols)")
    println(f, "        # shape with column-major strides.")
    println(f, "        return np.ctypeslib.as_array(self.data, shape=(self.cols, self.rows)).T")
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
                         typedict::Dict{Int, String}, needs_jlwerror::Bool=false,
                         needs_numpy::Bool=false)
    (; entrypoints, typeinfo, forward_declared) = abi_info
    env_var = uppercase(dest.package_name) * "_LIBRARY"

    println(f, "\"\"\"Auto-generated by JuliaLibWrapping. Do not edit by hand.\"\"\"")
    println(f, "import ctypes")
    println(f, "import os")
    println(f, "import sys")
    println(f, "import pathlib")
    if needs_numpy
        # Implements issue #12: numpy conversion helpers for CVector structs.
        println(f, "import numpy as np")
    end
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
            cvinfo = cvector_struct_info(type, typeinfo)
            cminfo = cvinfo === nothing ? cmatrix_struct_info(type, typeinfo) : nothing
            if cvinfo !== nothing
                # Implements issue #12: emit numpy conversion helpers when the
                # struct matches the CVector{T} shape with a primitive pointee.
                _write_cvector_helpers(f, cvinfo)
            elseif cminfo !== nothing
                # Implements issue #12: column-major CMatrix{T} variant.
                _write_cmatrix_helpers(f, cminfo)
            elseif cstring_struct_info(type, typeinfo)
                # Implements issue #12: str/bytes round-trip for CString.
                _write_cstring_helpers(f)
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

function _write_pyproject(f::IO, dest::PythonTarget, needs_numpy::Bool=false)
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
    if needs_numpy
        # Implements issue #12: CVector helpers depend on numpy.
        println(f, "dependencies = [\"numpy>=1.20\"]")
    end
    println(f)
    println(f, "[tool.setuptools]")
    println(f, "packages = [", repr(dest.package_name), "]")
    println(f)
    println(f, "[tool.setuptools.package-data]")
    println(f, dest.package_name, " = [\"*.so\", \"*.dylib\", \"*.dll\"]")
end
