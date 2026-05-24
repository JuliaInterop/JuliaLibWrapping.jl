"""
    PythonTarget(dir, package_name, library_basename; bundle_subdir = nothing)

Output configuration for a Python ctypes-based wrapper package. `dir` is the
directory into which the package will be written; a sub-directory named
`package_name` is created and is the importable Python module. `library_basename`
is the shared library's basename without an OS-specific suffix (e.g. `"libsimple"`,
which will be loaded from `libsimple.so` / `libsimple.dylib` / `libsimple.dll`
depending on the host).

When `bundle_subdir` is a string (e.g. `"bundle"`), the emitter assumes the
shared library and its juliac runtime closure (`libjulia`, sysimage, stdlibs,
artifacts) will be laid out under that subdirectory of the Python package in
the standard `--bundle` shape (`<bundle_subdir>/lib/<lib>`,
`<bundle_subdir>/lib/julia/`, `<bundle_subdir>/artifacts/`). The generated
loader looks for the library inside the bundle first, the generated
`pyproject.toml` widens `package-data` to include the bundle tree, and
[`build_library`](@ref) with `bundle = true` will copy the bundle there.
The default `nothing` preserves the flat single-`.so`-next-to-the-package
layout and is the right choice for callers placing the library by hand.
"""
struct PythonTarget <: AbstractTarget
    dir::String
    package_name::String
    library_basename::String
    bundle_subdir::Union{Nothing, String}
end

PythonTarget(dir::AbstractString, package_name::AbstractString,
             library_basename::AbstractString; bundle_subdir = nothing) =
    PythonTarget(String(dir), String(package_name), String(library_basename),
                 bundle_subdir === nothing ? nothing : String(bundle_subdir))

function Base.show(io::IO, t::PythonTarget)
    print(io, "PythonTarget(", repr(t.dir), ", ", repr(t.package_name),
              ", ", repr(t.library_basename))
    t.bundle_subdir === nothing || print(io, "; bundle_subdir = ", repr(t.bundle_subdir))
    print(io, ")")
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

"""
    raw_primitive_pointer_args(method::MethodDesc, typeinfo) -> Vector{Int}

Return positional indices into `method.args` for arguments whose static type is
a bare `Ptr{T}` where `T` is a primitive numeric type recognized by
[`numpy_dtypes`](@ref). `Ptr{Cvoid}` is excluded (it lowers to `ctypes.c_void_p`).
Pointers wrapped inside `CVector` / `CMatrix` / `CString` structs are *not*
reported — only top-level argument types are examined.

A non-empty result signals an argument that hands the C function a raw memory
address with no length, ownership, or layout metadata. The Python emitter uses
this to attach a docstring on the wrapper noting the column-major contract and
recommending the [`CVector`](@ref) / [`CMatrix`](@ref) vocabulary instead.
"""
function raw_primitive_pointer_args(method::MethodDesc,
                                    typeinfo::OrderedDict{Int, TypeDesc})
    out = Int[]
    for (i, arg) in pairs(method.args)
        t = typeinfo[arg.type]
        t isa PointerDesc || continue
        pointee = typeinfo[t.pointee_type]
        pointee isa PrimitiveTypeDesc || continue
        pointee.name in keys(numpy_dtypes) || continue
        push!(out, i)
    end
    return out
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
are stripped via [`sanitize_for_c`](@ref), an empty result becomes `"_"`, a
leading digit (legal in juliac-emitted tuple field names like `"1"`, `"2"`,
…, but illegal in a Python identifier) is prefixed with `_`, and any reserved
Python keyword is suffixed with `_`.

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
    isdigit(first(sanitized)) && (sanitized = "_" * sanitized)
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

    # Implements issue #14: surface bare-pointer arguments at codegen time so
    # the author sees the layout/ownership caveat without grepping the output.
    let raw_ptr_methods = [m.symbol for m in entrypoints
                           if !isempty(raw_primitive_pointer_args(m, typeinfo))]
        isempty(raw_ptr_methods) || @info "JuliaLibWrapping: entrypoints take raw `Ptr{<primitive>}` arguments; the emitted Python wrappers carry a docstring describing the layout/ownership contract. Consider wrapping these in `CVector{T}` / `CMatrix{T}` (JLWInterop) for safer interop." methods=raw_ptr_methods
    end

    needs_jlwerror = any(jlwstatus_access_path(m, typeinfo) !== nothing
                        for m in entrypoints)
    needs_numpy = any(type isa StructDesc &&
                      (cvector_struct_info(type, typeinfo) !== nothing ||
                       cmatrix_struct_info(type, typeinfo) !== nothing)
                      for type in values(typeinfo))

    lowlevel_path = joinpath(pkgdir, "_lowlevel.py")
    open(lowlevel_path, "w") do f
        _write_bindings(f, dest, abi_info, typedict, needs_jlwerror, needs_numpy)
    end

    # `_facade.py` is the author-editable idiomatic surface. JuliaLibWrapping
    # writes a starter façade once and never touches it again — to
    # regenerate, delete the file and re-run. The stub auto-wraps any
    # entrypoint whose arguments and return are all recognized vocabulary
    # types or primitives; anything else is re-exported with a TODO comment.
    facade_path = joinpath(pkgdir, "_facade.py")
    if !isfile(facade_path)
        open(facade_path, "w") do f
            _write_facade_stub(f, dest, abi_info, typedict, needs_jlwerror)
        end
    end

    has_any_export = needs_jlwerror || !isempty(entrypoints) ||
                     any(type isa StructDesc && tuple_struct_info(type) === nothing
                         for type in values(typeinfo))
    init_path = joinpath(pkgdir, "__init__.py")
    open(init_path, "w") do f
        println(f, "\"\"\"", dest.package_name,
                   " Python bindings (auto-generated by JuliaLibWrapping).\"\"\"")
        if !has_any_export
            println(f, "from . import _lowlevel  # noqa: F401")
            println(f, "from . import _facade  # noqa: F401")
        else
            println(f, "from ._facade import *  # noqa: F401,F403")
            println(f, "from ._facade import __all__  # noqa: F401")
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
    if dest.bundle_subdir !== nothing
        # Bundle-aware layout: search the juliac --bundle tree first so the
        # baked-in RUNPATH (`$ORIGIN/../lib[/julia]` on Linux,
        # `@loader_path/../lib*` on macOS) resolves libjulia and friends from
        # inside the bundle. Fall back to the flat layout so the same loader
        # still works for a developer who drops a bare .so beside the package.
        println(f, "    search_dirs = (_HERE / ", repr(dest.bundle_subdir),
                   " / \"lib\", _HERE)")
        println(f, "    for directory in search_dirs:")
        println(f, "        for suffix in suffixes:")
        println(f, "            candidate = directory / (_LIBRARY_BASENAME + suffix)")
        println(f, "            tried.append(str(candidate))")
        println(f, "            if candidate.exists():")
        println(f, "                return str(candidate)")
    else
        println(f, "    for suffix in suffixes:")
        println(f, "        candidate = _HERE / (_LIBRARY_BASENAME + suffix)")
        println(f, "        tried.append(str(candidate))")
        println(f, "        if candidate.exists():")
        println(f, "            return str(candidate)")
    end
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
        raw_ptr_idx = raw_primitive_pointer_args(method, typeinfo)
        if !isempty(raw_ptr_idx)
            # Implements issue #14: nudge callers about layout / ownership for
            # bare `Ptr{<primitive>}` arguments — the wrapper cannot infer
            # length, shape, or memory order, and silent transpose is the
            # standard failure mode for Julia/numpy interop.
            println(f, "    \"\"\"Raw pointer arguments — caller owns layout and lifetime.")
            println(f)
            for i in raw_ptr_idx
                pointee_name = typeinfo[typeinfo[method.args[i].type].pointee_type].name
                println(f, "    `", argnames[i], "` is a raw pointer to ", pointee_name,
                           ". The wrapper does not check length, shape, or memory order.")
            end
            println(f)
            println(f, "    Julia indexes multidimensional buffers column-major (Fortran order).")
            println(f, "    A default numpy array is row-major (C order); passing `arr.ctypes.data`")
            println(f, "    from such an array to a Julia function that interprets it as a matrix")
            println(f, "    will see a silently transposed view. Use `np.asfortranarray(arr)` before")
            println(f, "    taking `.ctypes.data`, or — better — wrap the field in `CVector{T}` /")
            println(f, "    `CMatrix{T}` (JLWInterop) so length and layout travel with the buffer.")
            println(f, "    \"\"\"")
        end
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

"""
    _facade_classify_arg(arg, typeinfo, typedict) -> NamedTuple

Classify a method argument for façade auto-wrapping. The return is one of:
- `(kind=:primitive,)` — pass-through
- `(kind=:cvector, classname=…)` — wrap with `<class>.from_numpy(name)`
- `(kind=:cmatrix, classname=…)` — wrap with `<class>.from_numpy(name)`
- `(kind=:cstring, classname=…)` — wrap with `<class>.from_str(name)`
- `(kind=:opaque, reason=…)` — bail out; emit mechanical re-export instead.
"""
function _facade_classify_arg(arg::ArgDesc,
                              typeinfo::OrderedDict{Int, TypeDesc},
                              typedict::Dict{Int, String})
    t = typeinfo[arg.type]
    if t isa PrimitiveTypeDesc
        return (kind=:primitive,)
    elseif t isa StructDesc
        if cvector_struct_info(t, typeinfo) !== nothing
            return (kind=:cvector, classname=typedict[arg.type])
        elseif cmatrix_struct_info(t, typeinfo) !== nothing
            return (kind=:cmatrix, classname=typedict[arg.type])
        elseif cstring_struct_info(t, typeinfo)
            return (kind=:cstring, classname=typedict[arg.type])
        else
            return (kind=:opaque, reason="argument has unrecognized type `" * t.name * "`")
        end
    else  # PointerDesc
        return (kind=:opaque, reason="argument has raw pointer type `" * t.name * "`")
    end
end

"""
    _facade_classify_return(method, typeinfo, typedict) -> NamedTuple

Classify a method's return for façade auto-wrapping. The return is one of:
- `(kind=:passthrough,)` — primitive scalar (including `Cvoid`)
- `(kind=:cvector_unwrap, classname=…)` — return `_result.as_numpy()`
- `(kind=:cmatrix_unwrap, classname=…)` — return `_result.as_numpy()`
- `(kind=:cstring_unwrap, classname=…)` — return `_result.as_str()`
- `(kind=:jlwstatus_discard,)` — direct `JLWStatus` return; discard, return `None`
- `(kind=:opaque, reason=…)` — bail out.
"""
function _facade_classify_return(method::MethodDesc,
                                 typeinfo::OrderedDict{Int, TypeDesc},
                                 typedict::Dict{Int, String})
    rt = typeinfo[method.return_type]
    if rt isa PrimitiveTypeDesc
        return (kind=:passthrough,)
    elseif rt isa StructDesc
        if is_jlwstatus_struct(rt, typeinfo)
            return (kind=:jlwstatus_discard,)
        elseif cvector_struct_info(rt, typeinfo) !== nothing
            return (kind=:cvector_unwrap, classname=typedict[method.return_type])
        elseif cmatrix_struct_info(rt, typeinfo) !== nothing
            return (kind=:cmatrix_unwrap, classname=typedict[method.return_type])
        elseif cstring_struct_info(rt, typeinfo)
            return (kind=:cstring_unwrap, classname=typedict[method.return_type])
        elseif jlwstatus_access_path(method, typeinfo) !== nothing
            return (kind=:opaque,
                    reason="returns struct `" * rt.name *
                           "` with embedded JLWStatus; idiomatic shaping depends on the other fields")
        else
            return (kind=:opaque, reason="returns unrecognized struct `" * rt.name * "`")
        end
    else  # PointerDesc
        return (kind=:opaque, reason="returns raw pointer type `" * rt.name * "`")
    end
end

"""
    _facade_plan(method, typeinfo, typedict) -> NamedTuple

Decide whether an entrypoint should be auto-wrapped on the façade. Returns
`(auto::Bool, reason::String, args::Vector, ret::NamedTuple, uses_numpy::Bool)`.

A function is auto-wrapped only when every argument and return classifies
as a recognized form *and* the wrapping actually adds value (converts a
vocabulary type or strips a discardable `JLWStatus`). Plain
primitive-in/primitive-out functions are left as straight re-exports.
"""
function _facade_plan(method::MethodDesc,
                      typeinfo::OrderedDict{Int, TypeDesc},
                      typedict::Dict{Int, String})
    arg_classes = [_facade_classify_arg(a, typeinfo, typedict) for a in method.args]
    for (i, c) in enumerate(arg_classes)
        if c.kind === :opaque
            return (category=:mechanical,
                    reason="`" * method.args[i].name * "`: " * c.reason,
                    args=arg_classes, ret=(kind=:opaque,), uses_numpy=false)
        end
    end
    ret = _facade_classify_return(method, typeinfo, typedict)
    if ret.kind === :opaque
        return (category=:mechanical, reason=ret.reason,
                args=arg_classes, ret=ret, uses_numpy=false)
    end
    uses_numpy = any(c -> c.kind in (:cvector, :cmatrix), arg_classes) ||
                 ret.kind in (:cvector_unwrap, :cmatrix_unwrap)
    adds_value = any(c -> c.kind !== :primitive, arg_classes) ||
                 ret.kind in (:cvector_unwrap, :cmatrix_unwrap,
                              :cstring_unwrap, :jlwstatus_discard)
    if !adds_value
        # All-primitive in/out: the lowlevel signature is already idiomatic
        # Python, so re-export it directly with no comment noise.
        return (category=:passthrough, reason="",
                args=arg_classes, ret=ret, uses_numpy=false)
    end
    return (category=:auto, reason="", args=arg_classes, ret=ret, uses_numpy=uses_numpy)
end

function _emit_facade_autowrapper(f::IO, method::MethodDesc, plan)
    arg_names_seen = Set{String}()
    argnames = String[sanitize_python_argname(a.name, arg_names_seen)
                      for a in method.args]
    println(f, "def ", method.symbol, "(", join(argnames, ", "), "):")
    # Convert vocabulary-typed arguments to their lowlevel struct counterparts.
    call_args = String[]
    for (name, cls) in zip(argnames, plan.args)
        if cls.kind === :primitive
            push!(call_args, name)
        elseif cls.kind === :cvector || cls.kind === :cmatrix
            local_ = "_" * name
            println(f, "    ", local_, " = ", cls.classname, ".from_numpy(", name, ")")
            push!(call_args, local_)
        elseif cls.kind === :cstring
            local_ = "_" * name
            println(f, "    ", local_, " = ", cls.classname, ".from_str(", name, ")")
            push!(call_args, local_)
        end
    end
    call = "_lowlevel." * method.symbol * "(" * join(call_args, ", ") * ")"
    ret = plan.ret
    if ret.kind === :passthrough
        println(f, "    return ", call)
    elseif ret.kind === :jlwstatus_discard
        # `_lowlevel` already raises JLWError on a non-zero status; the
        # façade discards the status struct and returns `None`.
        println(f, "    ", call)
    elseif ret.kind === :cvector_unwrap || ret.kind === :cmatrix_unwrap
        println(f, "    _result = ", call)
        println(f, "    return _result.as_numpy()")
    elseif ret.kind === :cstring_unwrap
        println(f, "    _result = ", call)
        println(f, "    return _result.as_str()")
    end
    println(f)
end

function _write_facade_stub(f::IO, dest::PythonTarget, abi_info::ABIInfo,
                            typedict::Dict{Int, String}, needs_jlwerror::Bool)
    (; entrypoints, typeinfo) = abi_info

    struct_names = String[]
    for (id, type) in pairs(typeinfo)
        if type isa StructDesc && tuple_struct_info(type) === nothing
            push!(struct_names, typedict[id])
        end
    end

    plans = [_facade_plan(m, typeinfo, typedict) for m in entrypoints]
    needs_np = any(p -> p.uses_numpy, plans)
    has_struct_exports = !isempty(struct_names) || needs_jlwerror

    println(f, "\"\"\"", dest.package_name, " idiomatic façade.")
    println(f)
    println(f, "This file is generated **once** by JuliaLibWrapping as a starter")
    println(f, "façade. Functions whose arguments and return are all recognized")
    println(f, "(primitives, `CVector{T}`, `CMatrix{T}`, `CString`, direct `JLWStatus`)")
    println(f, "are wrapped to accept and return idiomatic Python objects (numpy")
    println(f, "arrays, `str`). Anything else is re-exported from `_lowlevel`")
    println(f, "with a `TODO` comment naming what needs hand-wrapping.")
    println(f)
    println(f, "Edit this file freely — JuliaLibWrapping will never overwrite it")
    println(f, "on subsequent runs. Delete it to regenerate.")
    println(f)
    println(f, "The mechanical bindings live in `_lowlevel.py` and are regenerated")
    println(f, "on every `write_wrapper` call.")
    println(f, "\"\"\"")

    has_any_export = !isempty(struct_names) || needs_jlwerror || !isempty(entrypoints)
    if !has_any_export
        println(f, "from . import _lowlevel  # noqa: F401")
        println(f)
        println(f, "__all__ = []")
        return
    end

    println(f, "from . import _lowlevel  # noqa: F401")
    if needs_np
        println(f, "import numpy as np  # noqa: F401")
    end
    println(f)

    # Re-export struct classes and JLWError so callers can still construct
    # or catch them by their public package name.
    if has_struct_exports
        println(f, "from ._lowlevel import (")
        for name in struct_names
            println(f, "    ", name, ",")
        end
        needs_jlwerror && println(f, "    JLWError,")
        println(f, ")")
        println(f)
    end

    any_reexport = false
    for (method, plan) in zip(entrypoints, plans)
        if plan.category === :mechanical
            println(f, "from ._lowlevel import ", method.symbol,
                       "  # TODO: hand-wrap — ", plan.reason)
            any_reexport = true
        elseif plan.category === :passthrough
            println(f, "from ._lowlevel import ", method.symbol)
            any_reexport = true
        end
    end
    any_reexport && println(f)

    for (method, plan) in zip(entrypoints, plans)
        plan.category === :auto || continue
        _emit_facade_autowrapper(f, method, plan)
    end

    print(f, "__all__ = [")
    isfirst = true
    for name in struct_names
        isfirst || print(f, ", ")
        print(f, "\"", name, "\"")
        isfirst = false
    end
    if needs_jlwerror
        isfirst || print(f, ", ")
        print(f, "\"JLWError\"")
        isfirst = false
    end
    for method in entrypoints
        isfirst || print(f, ", ")
        print(f, "\"", method.symbol, "\"")
        isfirst = false
    end
    println(f, "]")
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
    if dest.bundle_subdir === nothing
        println(f, dest.package_name, " = [\"*.so\", \"*.dylib\", \"*.dll\"]")
    else
        # Setuptools' package-data does not recurse, so each level of the
        # `juliac --bundle` tree (lib/, lib/julia/, artifacts/**) must be
        # enumerated. Native-library suffixes are listed redundantly with
        # `*` so a developer who hand-drops a bare lib next to the package
        # still gets it picked up.
        sub = dest.bundle_subdir
        globs = [
            "\"*.so\"", "\"*.dylib\"", "\"*.dll\"",
            "\"$sub/lib/*\"",
            "\"$sub/lib/julia/*\"",
            "\"$sub/bin/*\"",
            "\"$sub/artifacts/*\"",
            "\"$sub/artifacts/*/*\"",
            "\"$sub/artifacts/*/**/*\"",
        ]
        println(f, dest.package_name, " = [", join(globs, ", "), "]")
    end
end
