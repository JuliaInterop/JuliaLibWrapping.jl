"""
    PythonTarget(dir, package_name, library_basename;
                 bundle_subdir = nothing, version = $(repr(_DEFAULT_PACKAGE_VERSION)),
                 privatized = false)

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

`version` sets the `version` field in the generated `pyproject.toml`. It must
be PEP 440-compatible; a Julia `Major.Minor.Patch` version string is valid.

`privatized` records whether the bundle carries a salted `libjulia`. A package
without one warns if another wrapped package is already loaded. [`build_library`](@ref)
sets this option; pass it directly only when using [`write_wrapper`](@ref) for
a bundle built elsewhere.
"""
struct PythonTarget <: AbstractTarget
    dir::String
    package_name::String
    library_basename::String
    bundle_subdir::Union{Nothing, String}
    version::String
    privatized::Bool
end

PythonTarget(
    dir::AbstractString, package_name::AbstractString,
    library_basename::AbstractString; bundle_subdir = nothing,
    version::AbstractString = _DEFAULT_PACKAGE_VERSION,
    privatized::Bool = false
) =
    PythonTarget(
    String(dir), String(package_name), String(library_basename),
    bundle_subdir === nothing ? nothing : String(bundle_subdir),
    isempty(version) ? throw(
            ArgumentError(
                "PythonTarget version must not be empty"
            )
        ) : String(version),
    privatized
)

function Base.show(io::IO, t::PythonTarget)
    print(
        io, "PythonTarget(", repr(t.dir), ", ", repr(t.package_name),
        ", ", repr(t.library_basename)
    )
    t.bundle_subdir === nothing || print(io, "; bundle_subdir = ", repr(t.bundle_subdir))
    t.version == _DEFAULT_PACKAGE_VERSION || print(io, "; version = ", repr(t.version))
    t.privatized && print(io, "; privatized = true")
    return print(io, ")")
end

"""
    pytypes :: Dict{String, String}

Map from Julia primitive type name (as it appears in a `PrimitiveTypeDesc`'s
`name` field, e.g. `"Int64"`, `"Float32"`, `"Cvoid"`) to the corresponding
`ctypes` expression (e.g. `"ctypes.c_int64"`, `"ctypes.c_float"`, `"None"`).
Used by [`mangle_python!`](@ref) for scalar/primitive arguments and returns,
and by [`_python_carray_info`](@ref) for a `CArray`'s element type.
"""
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
inline as `ctypes.POINTER(...)`; `Ptr{Cvoid}` collapses to `ctypes.c_void_p`
Results are memoized in `typedict`.
"""
function mangle_python!(
        typedict::Dict{Int, String}, type_id::Int,
        typeinfo::OrderedDict{Int, TypeDesc}
    )
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
        if type.pointee_type === nothing
            mangled = "ctypes.c_void_p"
        else
            inner = mangle_python!(typedict, type.pointee_type, typeinfo)
            mangled = "ctypes.POINTER(" * inner * ")"
        end
    elseif type isa ArrayDesc
        eltype_expr = mangle_python!(typedict, type.element_type, typeinfo)
        mangled = "(" * eltype_expr * " * " * string(type.count) * ")"
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

"""
    numpy_dtypes :: Dict{String, String}

Map from Julia primitive type name to the corresponding numpy dtype
string. Used by the Python façade emitter to decide which pointer
element types can be exposed as numpy arrays in `CVector` / `CMatrix`
helpers; primitives absent from this table (notably `Bool`, the
platform-aliased C ints) are not auto-wrapped.
"""
const numpy_dtypes = Dict{String, String}(
    "Int8" => "int8", "Int16" => "int16", "Int32" => "int32", "Int64" => "int64",
    "UInt8" => "uint8", "UInt16" => "uint16", "UInt32" => "uint32", "UInt64" => "uint64",
    "Float32" => "float32", "Float64" => "float64",
)

"""
    scalar_payload_types :: Dict{String, String}

The allowlist of Julia scalar primitive types accepted as a `CDict{V}` value
or `COpt{T}` payload — Int8..Int64, UInt8..UInt64, Float32, Float64, Bool —
matching `JLWInterop.CDICT_VALUE_TYPES` exactly (`CDict`/`COpt`'s payload is
inline in the carrier struct/array, so they share one scalar contract; `Bool`
is `ctypes.c_bool`, a real scalar here, even though it is intentionally
absent from [`numpy_dtypes`](@ref) for the unrelated reason that numpy has no
single-byte boolean `ctypes` array element convention this emitter wraps).

This is a **restriction of [`pytypes`](@ref)**, not a separate vocabulary:
`pytypes` also maps several primitive names that are unsuitable as a
`CDict`/`COpt` payload even though they are valid elsewhere (an argument, a
return, a pointee) — `"Cvoid" => "None"` is not a legal `ctypes.Structure`
field type (`None` cannot appear in `_fields_`); `Cstring`/`Cwstring` are
pointer-backed nominal types needing their own lifetime management, not a
value CDict/COpt's inline-scalar convention can hold; `RawFD` and the
platform-aliased C ints (`Cint`, `Cshort`, …) are not part of
`CDICT_VALUE_TYPES` either. Using `pytypes` for this purpose would silently
accept `CDict{Cvoid}`/`COpt{Cvoid}` fixtures that cannot actually round-trip.

Used by [`_python_cdict_info`](@ref)/[`_python_copt_info`](@ref) instead of
`pytypes` to decide whether a recognized `CDict`/`COpt` payload type is
supported.
"""
const scalar_payload_types = Dict{String, String}(
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
)

"""
    _python_carray_info(desc::StructDesc, typeinfo) -> Union{Nothing, NamedTuple}

[`carray_struct_info`](@ref) with this emitter's type tables applied:
`nothing` unless the struct matches the `CArray` shape and its element type
has a [`numpy_dtypes`](@ref) entry; otherwise
`(; eltype, ndim, ownership, ctype, dtype)`, adding the element type's
`ctypes` expression ([`pytypes`](@ref)) and numpy dtype to the recognizer's
fields.
"""
function _python_carray_info(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    info = carray_struct_info(desc, typeinfo)
    info === nothing && return nothing
    haskey(numpy_dtypes, info.eltype) || return nothing
    return (;
        info.eltype, info.ndim, info.ownership,
        ctype = pytypes[info.eltype],
        dtype = numpy_dtypes[info.eltype],
    )
end

"""
    _python_cdict_info(desc::StructDesc, typeinfo) -> Union{Nothing, NamedTuple}

[`cdict_struct_info`](@ref) with this emitter's type tables applied:
`nothing` unless the struct matches the `CDict` shape and its value type
has a [`scalar_payload_types`](@ref) entry; otherwise
`(; value_type, ownership, ctype)`.
"""
function _python_cdict_info(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    info = cdict_struct_info(desc, typeinfo)
    info === nothing && return nothing
    haskey(scalar_payload_types, info.value_type) || return nothing
    return (; info.value_type, info.ownership, ctype = scalar_payload_types[info.value_type])
end

"""
    _python_copt_info(desc::StructDesc, typeinfo) -> Union{Nothing, NamedTuple}

[`copt_struct_info`](@ref) with this emitter's type tables applied:
`nothing` unless the struct matches the `COpt` shape and its payload type
has a [`scalar_payload_types`](@ref) entry; otherwise
`(; value_type, ctype)`.
"""
function _python_copt_info(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    info = copt_struct_info(desc, typeinfo)
    info === nothing && return nothing
    haskey(scalar_payload_types, info.value_type) || return nothing
    return (; info.value_type, ctype = scalar_payload_types[info.value_type])
end

"""
    _python_status_path(method::MethodDesc, typeinfo) -> Union{Nothing, String}

[`jlwstatus_location`](@ref) as a Python attribute path from `_result` to
the returned JLWStatus: `nothing` when the return carries no status, `""`
when the return type is a JLWStatus, and `".<field>"` (the field name
through [`sanitize_python_argname`](@ref), which escapes Python keywords)
when the status is an embedded field.
"""
function _python_status_path(method::MethodDesc, typeinfo::OrderedDict{Int, TypeDesc})
    loc = jlwstatus_location(method, typeinfo)
    loc === nothing && return nothing
    loc.field === nothing && return ""
    return "." * sanitize_python_argname(loc.field)
end

"""
    _cstring_pointee_classname(desc, fieldname, typeinfo, typedict) -> String

Return the mangled Python `ctypes.Structure` class name for the
`CString` struct pointed to by `desc`'s field named `fieldname`
(`"data"` for [`cstrarray_struct_info`](@ref), `"keys"` for
[`cdict_struct_info`](@ref)). The caller must first verify that the field
points to a `CString` with matching ownership.
"""
function _cstring_pointee_classname(
        desc::StructDesc, fieldname::String,
        typeinfo::OrderedDict{Int, TypeDesc}, typedict::Dict{Int, String}
    )
    field = only(f for f in desc.fields if f.name == fieldname)
    pointee_id = (typeinfo[field.type]::PointerDesc).pointee_type
    return typedict[pointee_id]
end

const PYTHON_KEYWORDS = Set{String}(
    [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break",
        "class", "continue", "def", "del", "elif", "else", "except", "finally",
        "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal",
        "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
    ]
)

"""
    _python_docstring(s) -> String

Escape `s` for use inside a Python `\"\"\"…\"\"\"` docstring: every backslash
becomes `\\\\` and every double quote becomes `\\\"`. Escaping each quote
individually keeps a `\"\"\"` in the text from closing the docstring and keeps
a trailing quote from running into the closing delimiter.
"""
_python_docstring(s::AbstractString) = replace(s, "\\" => "\\\\", "\"" => "\\\"")

"""
    _is_python_identifier(s) -> Bool

Is `s` usable as a Python identifier: ASCII letters, digits and underscores,
not starting with a digit, not empty, and not a reserved keyword.
"""
_is_python_identifier(s::AbstractString) =
    !isempty(s) && !isdigit(first(s)) && s ∉ PYTHON_KEYWORDS &&
    all(c -> c == '_' || ('a' <= c <= 'z') || ('A' <= c <= 'Z') || isdigit(c), s)

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
function sanitize_python_argname(name::AbstractString, seen = nothing)
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

"""
    write_wrapper(dest::PythonTarget, abi_info::ABIInfo; api_metadata = Dict{String, Any}())

Emit the Python `ctypes` package described by `dest`/`abi_info`. `api_metadata`
is the `exports` map from an `@api` metadata sidecar (see
[`read_api_metadata`](@ref)), keyed by C symbol. A symbol present there takes
its façade wrapper's shape from the sidecar entry: the Python name, the split
into positional `args` and keyword-only `kwargs` with translated defaults, and
the docstring, escaped by [`_python_docstring`](@ref). A symbol absent from `api_metadata` (the
default is an empty `Dict`) gets the mechanical, ABI-derived shape.
"""
function write_wrapper(
        dest::PythonTarget, abi_info::ABIInfo;
        api_metadata::AbstractDict = Dict{String, Any}()
    )
    (; entrypoints, typeinfo, forward_declared) = abi_info

    pkgdir = joinpath(dest.dir, dest.package_name)
    mkpath(pkgdir)

    typedict = Dict{Int, String}()

    # Pre-mangle every struct so that the order in which `mangle_python!` is
    # first called (which influences collision-suffix allocation) is the
    # declaration order, not the order of first textual reference. This
    # mirrors the C emitter's behavior. Array (NTuple) types render inline
    # and contribute no name to the collision pool.
    for (id, type) in pairs(typeinfo)
        if type isa StructDesc
            mangle_python!(typedict, id, typeinfo)
        end
    end

    # Report bare-pointer arguments during generation.
    let raw_ptr_methods = [
            m.symbol for m in entrypoints
                if !isempty(raw_primitive_pointer_args(m, typeinfo))
        ]
        isempty(raw_ptr_methods) || @info "JuliaLibWrapping: entrypoints take raw `Ptr{<primitive>}` arguments; the emitted Python wrappers carry a docstring describing the layout/ownership contract. Consider wrapping these in `CArray{owned,T,N}` (JLWInterop) for safer interop." methods = raw_ptr_methods
    end

    needs_jlwerror = any(
        _python_status_path(m, typeinfo) !== nothing
            for m in entrypoints
    )
    needs_numpy = any(
        type isa StructDesc &&
            _python_carray_info(type, typeinfo) !== nothing
            for type in values(typeinfo)
    )

    lowlevel_path = joinpath(pkgdir, "_lowlevel.py")
    open(lowlevel_path, "w") do f
        _write_bindings(f, dest, abi_info, typedict, needs_jlwerror, needs_numpy, api_metadata)
    end

    # `_facade.py` defines the author-editable public API. JuliaLibWrapping
    # creates it only if it does not exist; delete the file and rerun to
    # regenerate it. The initial file wraps any entrypoint whose arguments
    # and return are all recognized ABI
    # types or primitives; anything else is re-exported with a TODO comment.
    facade_path = joinpath(pkgdir, "_facade.py")
    if !isfile(facade_path)
        open(facade_path, "w") do f
            _write_facade_stub(f, dest, abi_info, typedict, needs_jlwerror, api_metadata)
        end
    end

    has_any_export = needs_jlwerror || !isempty(entrypoints) ||
        any(
        type isa StructDesc
            for type in values(typeinfo)
    )
    init_path = joinpath(pkgdir, "__init__.py")
    open(init_path, "w") do f
        println(
            f, "\"\"\"", dest.package_name,
            " Python bindings (auto-generated by JuliaLibWrapping).\"\"\""
        )
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
    _emit_owned_free_method(f, buffers_desc, free_lines, release_present)

Emit the `.free()` method for an `:owned` carrier class. Ownership is a type
parameter, so the struct carries no ownership field and idempotence rides on
a Python-side `_freed` attribute set after the release call. Borrowed classes
get no `free()` at all.

Without release entrypoints the body raises a `RuntimeError`; the façade never
reaches it, since an owning return is demoted to a mechanical re-export in
that case (see [`_facade_classify_return`](@ref)), but a `_lowlevel` caller
gets a clear diagnosis instead of an `AttributeError`.

`buffers_desc` fills in "buffer" or "buffers" in the docstring; `free_lines`
are the release-call statements (already indented to 8 spaces) emitted only
when `release_present`.
"""
function _emit_owned_free_method(
        f::IO, buffers_desc::AbstractString,
        free_lines::Vector{String}, release_present::Bool
    )
    println(f, "")
    println(f, "    def free(self):")
    println(f, "        \"\"\"Free the Julia-allocated ", buffers_desc, ".")
    println(f, "")
    println(f, "        Idempotent: a second call is a no-op. For callers who bypass the")
    println(f, "        façade's convert-then-free wrapper and talk to `_lowlevel` directly.\"\"\"")
    println(f, "        if getattr(self, \"_freed\", False):")
    println(f, "            return")
    if release_present
        for line in free_lines
            println(f, line)
        end
        return println(f, "        self._freed = True")
    else
        return println(
            f, "        raise RuntimeError(\"this library does not export release entrypoints; ",
            "add JLWInterop.@export_release_entrypoints to the library\")"
        )
    end
end

"""
    _write_carray_helpers(f, cainfo, release_present)

Emit the conversion methods on a recognized `CArray` `ctypes` class. The
class's ownership decides its API: a `:borrowed` class gets `from_numpy`
(building a carrier over a numpy buffer the caller keeps alive) and
`as_numpy`, and no `free()` — it never owns anything to release. An
`:owned` class gets `as_numpy` and `free()`, and no `from_numpy` — Python
has no Julia allocation to hand over.
"""
function _write_carray_helpers(f::IO, cainfo, release_present::Bool)
    ctype = cainfo.ctype
    dtype = cainfo.dtype
    ndim = cainfo.ndim
    if cainfo.ownership === :borrowed
        # 1-D arrays accept either C- or F-contiguous (equivalent); higher rank
        # requires Fortran order because CArray storage is column-major.
        contig_check = ndim == 1 ?
            "if not (arr.flags.c_contiguous or arr.flags.f_contiguous):" :
            "if not arr.flags.f_contiguous:"
        contig_msg = ndim == 1 ?
            "\"array must be contiguous\"" :
            (
                "\"array must be Fortran-contiguous (column-major); \"\n" *
                "                             \"use np.asfortranarray(arr) to convert\""
            )
        println(f, "")
        println(f, "    @classmethod")
        println(f, "    def from_numpy(cls, arr):")
        println(f, "        \"\"\"Return a CArray view of the ", ndim, "-D numpy array `arr`.")
        println(f, "")
        if ndim == 1
            println(f, "        Raises ValueError on ndim, contiguity, or dtype mismatch (fail-fast: no")
            println(f, "        silent reinterpretation). The returned object holds a reference to `arr`,")
            println(f, "        so the caller must keep it alive for the duration of any C call that uses")
            println(f, "        the buffer.\"\"\"")
        else
            println(f, "        CArray storage is column-major (Julia / Fortran order). A default")
            println(f, "        row-major (C-order) numpy array is REJECTED rather than silently")
            println(f, "        reinterpreted — call `np.asfortranarray(arr)` first if needed.")
            println(f, "        Raises ValueError on ndim, contiguity, or dtype mismatch. The returned")
            println(f, "        object holds a reference to `arr`, so the caller must keep it alive for")
            println(f, "        the duration of any C call that uses the buffer.\"\"\"")
        end
        println(f, "        if arr.ndim != ", ndim, ":")
        println(f, "            raise ValueError(f\"expected ", ndim, "-D array, got {arr.ndim}-D\")")
        println(f, "        ", contig_check)
        println(f, "            raise ValueError(", contig_msg, ")")
        println(f, "        expected_dtype = np.dtype(", repr(dtype), ")")
        println(f, "        if arr.dtype != expected_dtype:")
        println(f, "            raise ValueError(f\"expected dtype ", dtype, ", got {arr.dtype}\")")
        println(f, "        obj = cls(dims=(ctypes.c_int32 * ", ndim, ")(*arr.shape),")
        println(f, "                  data=arr.ctypes.data_as(ctypes.POINTER(", ctype, ")))")
        println(f, "        obj._buffer = arr")
        println(f, "        return obj")
    end
    println(f, "")
    println(f, "    def as_numpy(self):")
    if ndim == 1
        println(f, "        \"\"\"Return a 1-D numpy view of the underlying buffer (no copy).\"\"\"")
        println(f, "        return np.ctypeslib.as_array(self.data, shape=(self.dims[0],))")
    else
        println(f, "        \"\"\"Return a ", ndim, "-D column-major numpy view of the underlying buffer (no copy).")
        println(f, "")
        println(f, "        The view has shape `tuple(self.dims)` and Fortran (column-major) strides,")
        println(f, "        matching the storage layout.\"\"\"")
        println(f, "        # Read the column-major buffer as reversed-shape C-order then transpose:")
        println(f, "        # `.T` reverses all axes, yielding a view with the natural Fortran-order")
        println(f, "        # shape and strides.")
        println(f, "        return np.ctypeslib.as_array(self.data, shape=tuple(self.dims)[::-1]).T")
    end
    cainfo.ownership === :owned || return nothing
    return _emit_owned_free_method(
        f, "buffer",
        ["        _lib.jlw_free(ctypes.cast(self.data, ctypes.c_void_p))"],
        release_present
    )
end

"""
    _write_cstring_helpers(f, csinfo, release_present)

Emit conversion methods for a recognized `CString` `ctypes` class. Borrowed
classes also get constructors; owned classes get `free()`.
"""
function _write_cstring_helpers(f::IO, csinfo, release_present::Bool)
    # CString helpers use ctypes only.
    if csinfo.ownership === :borrowed
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
    end
    println(f, "")
    println(f, "    def as_bytes(self):")
    println(f, "        \"\"\"Return a copy of the underlying bytes as a Python `bytes` object.\"\"\"")
    println(f, "        return ctypes.string_at(self.data, self.length)")
    println(f, "")
    println(f, "    def as_str(self):")
    println(f, "        \"\"\"Return the underlying bytes decoded as UTF-8.\"\"\"")
    println(f, "        return self.as_bytes().decode(\"utf-8\")")
    csinfo.ownership === :owned || return nothing
    return _emit_owned_free_method(
        f, "buffer",
        ["        _lib.jlw_free(ctypes.cast(self.data, ctypes.c_void_p))"],
        release_present
    )
end

"""
    _emit_cstring_array(f, list_var, arr_var, source_expr, item_var, cstring_classname)

Emit the "encode each string into a raw (non-NUL-terminated) buffer, then
build a `ctypes` array of `<cstring_classname>` structs, each holding that
buffer's length and a pointer into it" template shared, byte-for-byte, by
`_write_cstrarray_helpers`'s `from_list` (`list_var="bufs"`, `arr_var="arr"`,
`source_expr="items"`, `item_var="s"`) and `_write_cdict_helpers`'s
`from_dict` (`list_var="keys"`, `arr_var="karr"`, `source_expr="d.keys()"`,
`item_var="k"`) — both build a `ctypes` argument out of an iterable of
Python `str`s, differing only in what the iterable/result Python variables
are named. `source_expr` is the Python expression iterated to produce raw
strings; `item_var` names the loop variable used in the outer comprehension
only — the inner per-buffer comprehension's loop variable is always `b`, so
both call sites emit identical text apart from the substituted names.
Embedded NUL bytes in the source strings survive intact: each element's
`length` is the exact byte count, not a NUL-terminator search.
"""
function _emit_cstring_array(
        f::IO, list_var::AbstractString, arr_var::AbstractString,
        source_expr::AbstractString, item_var::AbstractString,
        cstring_classname::AbstractString
    )
    println(
        f, "        ", list_var, " = [", item_var, ".encode(\"utf-8\") for ",
        item_var, " in ", source_expr, "]"
    )
    println(f, "        ", arr_var, " = (", cstring_classname, " * len(", list_var, "))(")
    return println(
        f, "            *[", cstring_classname, "(length=len(b), data=ctypes.cast(",
        "ctypes.create_string_buffer(b, len(b)), ctypes.POINTER(ctypes.c_uint8))) for b in ",
        list_var, "])"
    )
end

"""
    _write_cstrarray_helpers(f, csainfo, cstring_classname, release_present)

Emit the conversion methods on a recognized `CStrArray` `ctypes` class. The
borrowed class gets `from_list` and `as_list`; the owned class gets `as_list`
and `free()`.
"""
function _write_cstrarray_helpers(
        f::IO, csainfo, cstring_classname::AbstractString, release_present::Bool
    )
    if csainfo.ownership === :borrowed
        println(f, "")
        println(f, "    @classmethod")
        println(f, "    def from_list(cls, items):")
        println(f, "        if not isinstance(items, (list, tuple)):")
        println(f, "            raise TypeError(\"expected a list of str\")")
        _emit_cstring_array(f, "bufs", "arr", "items", "s", cstring_classname)
        println(
            f, "        obj = cls(length=len(bufs), data=ctypes.cast(arr, ctypes.POINTER(",
            cstring_classname, ")))"
        )
        println(f, "        obj._buffer = (bufs, arr)   # keep buffers alive")
        println(f, "        return obj")
    end
    println(f, "")
    println(f, "    def as_list(self):")
    println(f, "        out = []")
    println(f, "        for i in range(self.length):")
    println(f, "            e = self.data[i]")
    println(f, "            out.append(ctypes.string_at(e.data, e.length).decode(\"utf-8\"))")
    println(f, "        return out")
    csainfo.ownership === :owned || return nothing
    return _emit_owned_free_method(
        f, "buffer",
        ["        _lib.jlw_free_strings(self.data, self.length)"],
        release_present
    )
end

"""
    _write_cdict_helpers(f, cdinfo, cstring_classname, release_present)

Emit the conversion methods on a recognized `CDict` `ctypes` class. The
borrowed class gets `from_dict` and `as_dict`; the owned class gets `as_dict`
and `free()`.
"""
function _write_cdict_helpers(
        f::IO, cdinfo, cstring_classname::AbstractString, release_present::Bool
    )
    ctype = cdinfo.ctype
    if cdinfo.ownership === :borrowed
        println(f, "")
        println(f, "    @classmethod")
        println(f, "    def from_dict(cls, d):")
        _emit_cstring_array(f, "keys", "karr", "d.keys()", "k", cstring_classname)
        println(f, "        varr = (", ctype, " * len(keys))(*d.values())")
        println(f, "        obj = cls(length=len(keys),")
        println(f, "                  keys=ctypes.cast(karr, ctypes.POINTER(", cstring_classname, ")),")
        println(f, "                  values=ctypes.cast(varr, ctypes.POINTER(", ctype, ")))")
        println(f, "        obj._buffer = (keys, karr, varr)")
        println(f, "        return obj")
    end
    println(f, "")
    println(f, "    def as_dict(self):")
    println(f, "        out = {}")
    println(f, "        for i in range(self.length):")
    println(f, "            e = self.keys[i]")
    println(f, "            k = ctypes.string_at(e.data, e.length).decode(\"utf-8\")")
    println(f, "            out[k] = self.values[i]")
    println(f, "        return out")
    cdinfo.ownership === :owned || return nothing
    return _emit_owned_free_method(
        f, "buffers",
        [
            "        _lib.jlw_free_strings(self.keys, self.length)",
            "        _lib.jlw_free(ctypes.cast(self.values, ctypes.c_void_p))",
        ],
        release_present
    )
end

function _write_copt_helpers(f::IO, coinfo)
    # COpt is by-value and needs neither a keepalive nor release logic.
    println(f, "")
    println(f, "    @classmethod")
    println(f, "    def from_optional(cls, x):")
    println(f, "        if x is None:")
    println(f, "            return cls(has_value=0, value=0)")
    println(f, "        return cls(has_value=1, value=x)")
    println(f, "")
    println(f, "    def as_optional(self):")
    return println(f, "        return None if self.has_value == 0 else self.value")
end

const JLWERROR_DEFINITION = """
class JLWError(RuntimeError):
    \"\"\"Raised when a wrapped function returns a non-zero JLWStatus.code.\"\"\"
    def __init__(self, code, message):
        super().__init__(f"[{code}] {message}")
        self.code = code
        self.message = message
"""

function _write_bindings(
        f::IO, dest::PythonTarget, abi_info::ABIInfo,
        typedict::Dict{Int, String}, needs_jlwerror::Bool = false,
        needs_numpy::Bool = false, api_metadata::AbstractDict = Dict{String, Any}()
    )
    (; entrypoints, typeinfo, forward_declared) = abi_info
    env_var = uppercase(dest.package_name) * "_LIBRARY"
    # Carrier `.free()` methods use this to diagnose missing entrypoints.
    release_present = _release_symbols_present(abi_info)

    println(f, "\"\"\"Auto-generated by JuliaLibWrapping. Do not edit by hand.\"\"\"")
    println(f, "import ctypes")
    println(f, "import os")
    println(f, "import sys")
    println(f, "import pathlib")
    if needs_numpy
        # CArray helpers require numpy.
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
        println(
            f, "    search_dirs = (_HERE / ", repr(dest.bundle_subdir),
            " / \"lib\", _HERE)"
        )
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

    # Record this package on a process-global sentinel so that a later
    # non-privatized package can tell something is already loaded.
    println(f, "_JLW_LOADED_ATTR = \"_jlw_loaded_packages\"")
    println(f, "_jlw_loaded = getattr(sys, _JLW_LOADED_ATTR, None)")
    println(f, "if _jlw_loaded is None:")
    println(f, "    _jlw_loaded = set()")
    println(f, "    setattr(sys, _JLW_LOADED_ATTR, _jlw_loaded)")
    println(f, "_jlw_this_pkg = __package__ or __name__")
    if !dest.privatized
        # Without a private libjulia this package shares whatever runtime is
        # already initialized, and the first call into whichever library did
        # not initialize it aborts the process. A privatized package uses its
        # own runtime and does not need to warn.
        println(f, "if _jlw_loaded and _jlw_this_pkg not in _jlw_loaded:")
        println(f, "    import warnings")
        println(f, "    warnings.warn(")
        println(f, "        f\"Loading JuliaLibWrapping-generated package {_jlw_this_pkg!r} into a \"")
        println(f, "        f\"process that already loaded {sorted(_jlw_loaded)!r}. \"")
        println(f, "        \"This package was built without a private libjulia, so both \"")
        println(f, "        \"packages resolve a single Julia runtime and the first call into \"")
        println(f, "        \"whichever did not initialize it aborts the process. Rebuild with \"")
        println(f, "        \"`privatize = true`, or compile both APIs into a single juliac \"")
        println(f, "        \"library. See the JuliaLibWrapping docs section on multiple \"")
        println(f, "        \"wrapped libraries in one process.\",")
        println(f, "        RuntimeWarning,")
        println(f, "        stacklevel=2,")
        println(f, "    )")
    end
    println(f, "_jlw_loaded.add(_jlw_this_pkg)")
    println(f)

    if needs_jlwerror
        # JLWStatus error propagation.
        print(f, JLWERROR_DEFINITION)
        println(f)
    end

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

    # Struct definitions in dependency order. Array (NTuple) types are
    # emitted inline (as `(<eltype> * N)` ctypes arrays) by `mangle_python!`,
    # so they get no class of their own.
    for (id, type) in pairs(typeinfo)
        type isa StructDesc || continue
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
            cainfo = _python_carray_info(type, typeinfo)
            csinfo = cstring_struct_info(type, typeinfo)
            csainfo = cstrarray_struct_info(type, typeinfo)
            cdinfo = _python_cdict_info(type, typeinfo)
            coinfo = _python_copt_info(type, typeinfo)
            if cainfo !== nothing
                # Emit numpy helpers for supported CArray layouts.
                _write_carray_helpers(f, cainfo, release_present)
            elseif !isnothing(csinfo)
                # Emit CString conversion helpers.
                _write_cstring_helpers(f, csinfo, release_present)
            elseif !isnothing(csainfo)
                # Emit CStrArray conversion helpers.
                cs_classname = _cstring_pointee_classname(type, "data", typeinfo, typedict)
                _write_cstrarray_helpers(f, csainfo, cs_classname, release_present)
            elseif !isnothing(cdinfo)
                # Emit CDict conversion helpers.
                cs_classname = _cstring_pointee_classname(type, "keys", typeinfo, typedict)
                _write_cdict_helpers(f, cdinfo, cs_classname, release_present)
            elseif !isnothing(coinfo)
                # Emit COpt conversion helpers.
                _write_copt_helpers(f, coinfo)
            end
        end
        println(f)
    end

    # Function bindings.
    for method in entrypoints
        argexprs = String[mangle_python!(typedict, a.type, typeinfo) for a in method.args]
        # ctypes represents a `void` return as a `None` restype.
        rt = method.return_type === nothing ?
            "None" : mangle_python!(typedict, method.return_type, typeinfo)
        println(f, "_lib.", method.symbol, ".argtypes = [", join(argexprs, ", "), "]")
        println(f, "_lib.", method.symbol, ".restype = ", rt)

        if method.symbol in _RELEASE_ENTRYPOINT_SYMBOLS
            # Release entrypoints are bound on `_lib`, not exposed publicly.
            println(f)
            continue
        end

        arg_names_seen = Set{String}()
        argnames = String[sanitize_python_argname(a.name, arg_names_seen) for a in method.args]

        status_path = _python_status_path(method, typeinfo)

        println(f, "def ", method.symbol, "(", join(argnames, ", "), "):")
        raw_ptr_idx = raw_primitive_pointer_args(method, typeinfo)
        if !isempty(raw_ptr_idx)
            # Document metadata absent from bare primitive pointers.
            println(f, "    \"\"\"Raw pointer arguments — caller owns layout and lifetime.")
            println(f)
            for i in raw_ptr_idx
                pointee_name = typeinfo[typeinfo[method.args[i].type].pointee_type].name
                println(
                    f, "    `", argnames[i], "` is a raw pointer to ", pointee_name,
                    ". The wrapper does not check length, shape, or memory order."
                )
            end
            println(f)
            println(f, "    Julia indexes multidimensional buffers column-major (Fortran order).")
            println(f, "    A default numpy array is row-major (C order); passing `arr.ctypes.data`")
            println(f, "    from such an array to a Julia function that interprets it as a matrix")
            println(f, "    will see a silently transposed view. Use `np.asfortranarray(arr)` before")
            println(f, "    taking `.ctypes.data`, or — better — wrap the field in `CArray{owned,T,N}`")
            println(f, "    (JLWInterop) so shape and layout travel with the buffer.")
            println(f, "    \"\"\"")
        else
            api_entry = get(api_metadata, method.symbol, nothing)
            api_doc = isnothing(api_entry) ? "" : get(api_entry, "doc", "")
            isempty(api_doc) || println(f, "    \"\"\"", _python_docstring(api_doc), "\"\"\"")
        end
        if status_path !== nothing
            # Raise JLWError for a failed status.
            println(f, "    _result = _lib.", method.symbol, "(", join(argnames, ", "), ")")
            println(f, "    if _result", status_path, ".code != 0:")
            println(
                f, "        _msg = bytes(_result", status_path,
                ".message).rstrip(b\"\\x00\").decode(\"utf-8\", errors=\"replace\")"
            )
            println(f, "        raise JLWError(_result", status_path, ".code, _msg)")
            println(f, "    return _result")
        elseif rt == "None"
            println(f, "    _lib.", method.symbol, "(", join(argnames, ", "), ")")
        else
            println(f, "    return _lib.", method.symbol, "(", join(argnames, ", "), ")")
        end
        println(f)
    end
    return
end

"""
    _facade_classify_arg(arg, typeinfo, typedict; pass_opaque = false) -> NamedTuple

Classify a method argument for façade auto-wrapping. With `pass_opaque`, an
argument outside the emitter's vocabulary — a raw pointer, or a struct a
library registered with `JLWInterop.carrier_type` — classifies `:primitive`
and crosses the façade as it stands, instead of classifying `:opaque`. Only
an `@api` entrypoint sets it; see [`_facade_plan`](@ref). The return is one
of:
- `(kind=:primitive,)` — pass-through
- `(kind=:carray, classname=…)` — a borrowed `CArray`; wrap with
  `<class>.from_numpy(name)`
- `(kind=:cstring, classname=…)` — a borrowed `CString`; wrap with
  `<class>.from_str(name)`
- `(kind=:cstrarray, classname=…)` — a borrowed `CStrArray`; wrap with
  `<class>.from_list(name)`
- `(kind=:cdict, classname=…)` — a borrowed `CDict`; wrap with
  `<class>.from_dict(name)`
- `(kind=:copt, classname=…)` — wrap with `<class>.from_optional(name)`
- `(kind=:opaque, reason=…)` — bail out; emit mechanical re-export instead.
"""
function _facade_classify_arg(
        arg::ArgDesc,
        typeinfo::OrderedDict{Int, TypeDesc},
        typedict::Dict{Int, String};
        pass_opaque::Bool = false
    )
    t = typeinfo[arg.type]
    if t isa PrimitiveTypeDesc
        return (kind = :primitive,)
    elseif t isa StructDesc
        cainfo = _python_carray_info(t, typeinfo)
        csinfo = cstring_struct_info(t, typeinfo)
        csainfo = cstrarray_struct_info(t, typeinfo)
        cdinfo = _python_cdict_info(t, typeinfo)
        if !isnothing(cainfo)
            # An owning CArray argument hands Julia-allocated storage into the
            # library, which then owns the release. numpy cannot supply that.
            cainfo.ownership === :owned && return (
                kind = :opaque,
                reason = "argument transfers CArray ownership into the library; hand-wrap",
            )
            return (kind = :carray, classname = typedict[arg.type])
        elseif !isnothing(csinfo)
            # An owning CString argument hands Julia-allocated storage into the
            # library, which then owns the release. Python cannot supply that.
            csinfo.ownership === :owned && return (
                kind = :opaque,
                reason = "argument transfers CString ownership into the library; hand-wrap",
            )
            return (kind = :cstring, classname = typedict[arg.type])
        elseif !isnothing(csainfo)
            # An owning CStrArray argument hands Julia-allocated storage into
            # the library, which then owns the release. Python cannot supply
            # that.
            csainfo.ownership === :owned && return (
                kind = :opaque,
                reason = "argument transfers CStrArray ownership into the library; hand-wrap",
            )
            return (kind = :cstrarray, classname = typedict[arg.type])
        elseif !isnothing(cdinfo)
            cdinfo.ownership === :owned && return (
                kind = :opaque,
                reason = "argument transfers CDict ownership into the library; hand-wrap",
            )
            return (kind = :cdict, classname = typedict[arg.type])
        elseif !isnothing(_python_copt_info(t, typeinfo))
            return (kind = :copt, classname = typedict[arg.type])
        else
            pass_opaque && return (kind = :primitive,)
            return (kind = :opaque, reason = "argument has unrecognized type `" * t.name * "`")
        end
    elseif t isa ArrayDesc
        return (kind = :opaque, reason = "argument has array type `" * t.name * "`")
    else  # PointerDesc
        pass_opaque && return (kind = :primitive,)
        return (kind = :opaque, reason = "argument has raw pointer type `" * t.name * "`")
    end
end

"""
    _classify_return_type(type_id, typeinfo, typedict, release_present; method=nothing, pass_opaque=false) -> NamedTuple

Classify a return *type*, identified by its `typeinfo` id, for façade
auto-wrapping. `method` is the entrypoint whose return type this is, or
`nothing` when there is none, as in the recursive `JLWResult` call below.
`release_present` is [`_release_symbols_present`](@ref)'s verdict for the
surrounding library. `pass_opaque` is as in [`_facade_classify_arg`](@ref): a
raw pointer or unrecognized struct return then classifies `:passthrough`. The
return is one of:
- `(kind=:passthrough,)` — primitive scalar (including `Cvoid`)
- `(kind=:jlwresult_unwrap, inner=<NamedTuple>)` — a [`JLWInterop.JLWResult`](@ref)
  return, recognized via [`jlwresult_struct_info`](@ref). This must be checked
  before every other struct branch below, including the embedded-`JLWStatus`
  `:opaque` branch, because `JLWResult` also has a `status` field. `inner` is
  this same classification applied to the wrapped value's type; that kind
  decides the conversion and the free, rooted at `_r.value` instead of
  `_result` (see [`_emit_facade_return_body`](@ref)/[`_emit_value_unwrap`](@ref)).
  An `:opaque` payload makes the whole return `:opaque`.
- `(kind=:carray_view, classname=…)` — a borrowed `CArray` return: the
  storage belongs to the caller, so `return _result.as_numpy()` hands back a
  zero-copy view and nothing is freed. Not gated on `release_present` — there
  is nothing to release.
- `(kind=:carray_unwrap, classname=…)` — an owning `CArray` return: inside a
  `try`, copy into a fresh numpy array (`np.array(_result.as_numpy(),
  copy=True)`) FIRST — never hand back a view over memory about to be freed
  — then a `finally` calls `_result.free()`.
- `(kind=:cstring_convert, classname=…)` — a borrowed `CString` return:
  `return _result.as_str()`. `as_str` copies, so the result outlives the
  buffer; nothing is released. Not gated on `release_present`.
- `(kind=:cstring_unwrap, classname=…)` — an owning `CString` return: inside a
  `try`, `_out = _result.as_str()` (a real copy, independent of the buffer);
  a `finally` then calls `_result.free()`, releasing `data` via `jlw_free`.
- `(kind=:cstrarray_convert, classname=…)` — a borrowed `CStrArray` return:
  `return _result.as_list()`. `as_list` copies, so the result outlives the
  buffer; nothing is released. Not gated on `release_present`.
- `(kind=:cstrarray_unwrap, classname=…)` — an owning `CStrArray` return:
  inside a `try`, `_out = _result.as_list()` (a real copy, independent of the
  buffer); a `finally` then calls `_result.free()`, releasing `data` via
  `jlw_free_strings`.
- `(kind=:cdict_convert, classname=…)` — a borrowed `CDict` return:
  `return _result.as_dict()`, no release.
- `(kind=:cdict_unwrap, classname=…)` — an owning `CDict` return: inside a
  `try`, `_out = _result.as_dict()`; a `finally` then calls `_result.free()`,
  releasing `keys` via `jlw_free_strings` AND `values` via `jlw_free` (two
  separate allocations).
- `(kind=:copt_unwrap, classname=…)` — return `_result.as_optional()`; COpt
  is by-value, so no free is involved (not gated on `release_present`)
- `(kind=:jlwstatus_discard,)` — direct `JLWStatus` return; discard, return `None`
- `(kind=:opaque, reason=…)` — bail out. Also returned in place of
  `:carray_unwrap`/`:cstring_unwrap`/`:cstrarray_unwrap`/`:cdict_unwrap` when
  `release_present` is `false`: auto-wrapping an owning return with no release
  entrypoints available would emit a call to a symbol that does not exist.
"""
function _classify_return_type(
        type_id::Union{Int, Nothing},
        typeinfo::OrderedDict{Int, TypeDesc},
        typedict::Dict{Int, String},
        release_present::Bool;
        method::Union{Nothing, MethodDesc} = nothing,
        pass_opaque::Bool = false
    )
    type_id === nothing && return (kind = :passthrough,)
    rt = typeinfo[type_id]
    if rt isa PrimitiveTypeDesc
        return (kind = :passthrough,)
    elseif rt isa StructDesc
        jr = jlwresult_struct_info(rt, typeinfo)
        cainfo = _python_carray_info(rt, typeinfo)
        csinfo = cstring_struct_info(rt, typeinfo)
        csainfo = cstrarray_struct_info(rt, typeinfo)
        cdinfo = _python_cdict_info(rt, typeinfo)
        if !isnothing(jr)
            inner = _classify_return_type(
                jr.value_type_id, typeinfo, typedict, release_present; pass_opaque
            )
            # An unclassifiable payload makes the whole `JLWResult` return
            # unclassifiable: there is no unwrap to emit for it.
            inner.kind === :opaque && return (kind = :opaque, reason = inner.reason)
            return (kind = :jlwresult_unwrap, inner = inner)
        elseif is_jlwstatus_struct(rt, typeinfo)
            return (kind = :jlwstatus_discard,)
        elseif !isnothing(cainfo)
            cainfo.ownership === :borrowed &&
                return (kind = :carray_view, classname = typedict[type_id])
            release_present || return (
                kind = :opaque,
                reason = "owning return needs release entrypoints; add JLWInterop.@export_release_entrypoints to the library",
            )
            return (kind = :carray_unwrap, classname = typedict[type_id])
        elseif !isnothing(csinfo)
            csinfo.ownership === :borrowed &&
                return (kind = :cstring_convert, classname = typedict[type_id])
            release_present || return (
                kind = :opaque,
                reason = "owning return needs release entrypoints; add JLWInterop.@export_release_entrypoints to the library",
            )
            return (kind = :cstring_unwrap, classname = typedict[type_id])
        elseif !isnothing(csainfo)
            csainfo.ownership === :borrowed &&
                return (kind = :cstrarray_convert, classname = typedict[type_id])
            release_present || return (
                kind = :opaque,
                reason = "owning return needs release entrypoints; add JLWInterop.@export_release_entrypoints to the library",
            )
            return (kind = :cstrarray_unwrap, classname = typedict[type_id])
        elseif !isnothing(cdinfo)
            cdinfo.ownership === :borrowed &&
                return (kind = :cdict_convert, classname = typedict[type_id])
            release_present || return (
                kind = :opaque,
                reason = "owning return needs release entrypoints; add JLWInterop.@export_release_entrypoints to the library",
            )
            return (kind = :cdict_unwrap, classname = typedict[type_id])
        elseif !isnothing(_python_copt_info(rt, typeinfo))
            return (kind = :copt_unwrap, classname = typedict[type_id])
        elseif !isnothing(method) && !isnothing(_python_status_path(method, typeinfo))
            return (
                kind = :opaque,
                reason = "returns struct `" * rt.name *
                    "` with embedded JLWStatus; idiomatic shaping depends on the other fields",
            )
        else
            pass_opaque && return (kind = :passthrough,)
            return (kind = :opaque, reason = "returns unrecognized struct `" * rt.name * "`")
        end
    elseif rt isa ArrayDesc
        return (kind = :opaque, reason = "returns array type `" * rt.name * "`")
    else  # PointerDesc
        pass_opaque && return (kind = :passthrough,)
        return (kind = :opaque, reason = "returns raw pointer type `" * rt.name * "`")
    end
end
"""
    _facade_classify_return(method, typeinfo, typedict, release_present; pass_opaque = false) -> NamedTuple

[`_classify_return_type`](@ref) applied to `method`'s own return type.
"""
function _facade_classify_return(
        method::MethodDesc,
        typeinfo::OrderedDict{Int, TypeDesc},
        typedict::Dict{Int, String},
        release_present::Bool;
        pass_opaque::Bool = false
    )
    return _classify_return_type(
        method.return_type, typeinfo, typedict, release_present; method, pass_opaque
    )
end

# Answer `uses_numpy`/`adds_value` for a classification, recursing into a
# `:jlwresult_unwrap`'s `inner` kind.
_ret_uses_numpy(ret) = ret.kind in (:carray_view, :carray_unwrap) ||
    (ret.kind === :jlwresult_unwrap && _ret_uses_numpy(ret.inner))
_ret_adds_value(ret) = ret.kind === :jlwresult_unwrap || ret.kind in (
    :carray_view, :carray_unwrap, :cstring_convert, :cstring_unwrap,
    :cstrarray_convert, :cstrarray_unwrap, :cdict_convert, :cdict_unwrap,
    :copt_unwrap, :jlwstatus_discard,
)

"""
    _facade_plan(method, typeinfo, typedict, release_present, api_entry) -> NamedTuple

Decide whether an entrypoint should be auto-wrapped on the façade.
`release_present` is [`_release_symbols_present`](@ref)'s verdict for the
surrounding library, threaded through to [`_facade_classify_return`](@ref).
`api_entry` is the sidecar entry for this symbol,
`get(api_metadata, method.symbol, nothing)`, or `nothing` when there is no
sidecar. Returns `(category, reason, args, ret, uses_numpy, api_entry)`.

A function whose symbol has a sidecar entry is auto-wrapped (category
`:api_auto`) whenever every argument and return classifies as a recognized
form: the sidecar's name and kwargs split are what the wrapping adds, even
for an otherwise primitive-only signature. The entry also sets `pass_opaque`
on the classifiers, so a raw pointer or a struct outside the emitter's
vocabulary crosses as it stands rather than degrading the whole function. If
its return classifies as
`:opaque` — an owning carrier in a library that exports no release
entrypoints — this throws, naming `JLWInterop.@export_release_entrypoints`,
rather than dropping the annotation's name, kwargs and docstring.

Without a sidecar entry, a function is auto-wrapped (category `:auto`) only
when every argument and return classifies as a recognized form *and* the
wrapping adds something — it converts a vocabulary type, strips a
discardable `JLWStatus`, or unwraps a `JLWResult`; an `:opaque` argument or
return degrades it to a mechanical re-export carrying a `TODO` comment.
Primitive-in/primitive-out functions with no sidecar entry are left as
straight re-exports (`:passthrough`).
"""
function _facade_plan(
        method::MethodDesc,
        typeinfo::OrderedDict{Int, TypeDesc},
        typedict::Dict{Int, String},
        release_present::Bool,
        api_entry = nothing
    )
    # A sidecar entry means the author wrote this signature for these
    # bindings, so a raw pointer or a library-registered struct in it crosses
    # the façade unconverted. A hand-written entrypoint's signature can be
    # dictated from outside, so it keeps degrading to a mechanical re-export.
    pass_opaque = !isnothing(api_entry)
    arg_classes = [
        _facade_classify_arg(a, typeinfo, typedict; pass_opaque) for a in method.args
    ]
    for (i, c) in enumerate(arg_classes)
        if c.kind === :opaque
            return (
                category = :mechanical,
                reason = "`" * method.args[i].name * "`: " * c.reason,
                args = arg_classes, ret = (kind = :opaque,), uses_numpy = false,
                api_entry = nothing,
            )
        end
    end
    ret = _facade_classify_return(method, typeinfo, typedict, release_present; pass_opaque)
    if ret.kind === :opaque
        # An `@api` return the façade cannot unwrap is a build error, not a
        # degradation: falling back would silently drop the Python name,
        # keyword arguments and docstring the annotation asked for. The only
        # way an `@api` return reaches here is an owning carrier in a library
        # with no release entrypoints, so `reason` names the macro to add. A
        # hand-written `Base.@ccallable` has no sidecar entry and still
        # degrades to a mechanical re-export.
        isnothing(api_entry) || error(
            "cannot wrap `@api` entrypoint '", method.symbol, "': ", ret.reason
        )
        return (
            category = :mechanical, reason = ret.reason,
            args = arg_classes, ret = ret, uses_numpy = false,
            api_entry = nothing,
        )
    end
    uses_numpy = any(c -> c.kind === :carray, arg_classes) || _ret_uses_numpy(ret)
    if !isnothing(api_entry)
        return (
            category = :api_auto, reason = "",
            args = arg_classes, ret = ret, uses_numpy = uses_numpy,
            api_entry = api_entry,
        )
    end
    adds_value = any(c -> c.kind !== :primitive, arg_classes) || _ret_adds_value(ret)
    if !adds_value
        # Primitive-only signatures need no conversion; re-export them directly.
        return (
            category = :passthrough, reason = "",
            args = arg_classes, ret = ret, uses_numpy = false,
            api_entry = nothing,
        )
    end
    return (
        category = :auto, reason = "", args = arg_classes, ret = ret,
        uses_numpy = uses_numpy, api_entry = nothing,
    )
end

"""
    _facade_arg_conversions(f, argnames, arg_classes) -> Vector{String}

Emit one `_<name> = <classname>.from_*(name)` line per non-primitive
argument, converting each vocabulary-typed argument to its lowlevel struct
counterpart. Returns the expressions to pass positionally into the
`_lowlevel` call, in argument order: the converted local for a vocabulary
type, the bare name for a primitive.
"""
function _facade_arg_conversions(f::IO, argnames::Vector{String}, arg_classes)
    call_args = String[]
    for (name, cls) in zip(argnames, arg_classes)
        if cls.kind === :primitive
            push!(call_args, name)
        elseif cls.kind === :carray
            local_ = "_" * name
            println(f, "    ", local_, " = ", cls.classname, ".from_numpy(", name, ")")
            push!(call_args, local_)
        elseif cls.kind === :cstring
            local_ = "_" * name
            println(f, "    ", local_, " = ", cls.classname, ".from_str(", name, ")")
            push!(call_args, local_)
        elseif cls.kind === :cstrarray
            local_ = "_" * name
            println(f, "    ", local_, " = ", cls.classname, ".from_list(", name, ")")
            push!(call_args, local_)
        elseif cls.kind === :cdict
            local_ = "_" * name
            println(f, "    ", local_, " = ", cls.classname, ".from_dict(", name, ")")
            push!(call_args, local_)
        elseif cls.kind === :copt
            local_ = "_" * name
            println(f, "    ", local_, " = ", cls.classname, ".from_optional(", name, ")")
            push!(call_args, local_)
        end
    end
    return call_args
end

"""
    _emit_value_unwrap(f, root, kind)

Emit the body that converts `root` — a CArray/CString/CStrArray/CDict/COpt
low-level struct value — to its idiomatic Python representation, freeing an
owning buffer in a `finally`. `root` is the Python expression holding the
value: `"_result"` for a bare vocabulary-typed return, `"_r.value"` for a
[`JLWInterop.JLWResult`](@ref)'s payload (see
[`_emit_facade_return_body`](@ref)). `kind` is one of the value kinds
[`_classify_return_type`](@ref) returns; any other kind throws, so a
classification with no emitter cannot produce a body that returns nothing.
"""
function _emit_value_unwrap(f::IO, root::AbstractString, kind::Symbol)
    if kind === :passthrough
        println(f, "    return ", root)
    elseif kind === :carray_view
        # The storage belongs to the caller, so the view is safe to hand back
        # and there is nothing to release.
        println(f, "    return ", root, ".as_numpy()")
    elseif kind === :carray_unwrap
        # The Julia allocation is released here, so the caller gets a copy
        # rather than a view over freed memory.
        println(f, "    try:")
        println(f, "        _out = np.array(", root, ".as_numpy(), copy=True)")
        println(f, "    finally:")
        println(f, "        ", root, ".free()")
        println(f, "    return _out")
    elseif kind === :cstring_convert
        # The storage belongs to the caller; `as_str` copies, so there is
        # nothing to release.
        println(f, "    return ", root, ".as_str()")
    elseif kind === :cstring_unwrap
        # Decode to a Python `str` first (a real copy, independent of the
        # buffer), THEN free `data` via `jlw_free` in `finally`.
        println(f, "    try:")
        println(f, "        _out = ", root, ".as_str()")
        println(f, "    finally:")
        println(f, "        ", root, ".free()")
        println(f, "    return _out")
    elseif kind === :cstrarray_convert
        # The storage belongs to the caller; `as_list` copies, so there is
        # nothing to release.
        println(f, "    return ", root, ".as_list()")
    elseif kind === :cstrarray_unwrap
        # Convert to the idiomatic `list[str]` first (a real copy,
        # independent of the buffer), THEN free `data` via `jlw_free_strings`
        # in `finally`.
        println(f, "    try:")
        println(f, "        _out = ", root, ".as_list()")
        println(f, "    finally:")
        println(f, "        ", root, ".free()")
        println(f, "    return _out")
    elseif kind === :cdict_convert
        println(f, "    return ", root, ".as_dict()")
    elseif kind === :cdict_unwrap
        # `keys` and `values` are two SEPARATE buffers: convert to `dict`
        # first, then free both (`.free()` releases `keys` via
        # `jlw_free_strings` AND `values` via `jlw_free`) in `finally`.
        println(f, "    try:")
        println(f, "        _out = ", root, ".as_dict()")
        println(f, "    finally:")
        println(f, "        ", root, ".free()")
        println(f, "    return _out")
    elseif kind === :copt_unwrap
        # COpt is by-value (no heap allocation) — unwrap only, no free.
        println(f, "    return ", root, ".as_optional()")
    else
        error("unhandled return kind $kind")
    end
    return nothing
end

"""
    _emit_facade_return_body(f, call, ret)

Emit the façade wrapper's return handling for `call`, the
`_lowlevel.<symbol>(...)` expression built from the converted arguments,
classified as `ret` (a [`_classify_return_type`](@ref) result).
`:passthrough` and `:jlwstatus_discard` return or discard `call` directly.
`:jlwresult_unwrap` binds `_r = call`, raises `JLWError` on a non-zero
`_r.status.code`, then delegates to [`_emit_value_unwrap`](@ref) for
`ret.inner`, rooted at `_r.value`. Every other kind binds `_result = call`
and delegates to `_emit_value_unwrap`.
"""
function _emit_facade_return_body(f::IO, call::AbstractString, ret)
    if ret.kind === :passthrough
        println(f, "    return ", call)
    elseif ret.kind === :jlwstatus_discard
        # `_lowlevel` already raises JLWError on a non-zero status; the
        # façade discards the status struct and returns `None`.
        println(f, "    ", call)
    elseif ret.kind === :jlwresult_unwrap
        println(f, "    _r = ", call)
        println(f, "    if _r.status.code != 0:")
        println(
            f, "        raise JLWError(_r.status.code, bytes(_r.status.message)",
            ".rstrip(b\"\\x00\").decode(\"utf-8\", errors=\"replace\"))"
        )
        _emit_value_unwrap(f, "_r.value", ret.inner.kind)
    else
        println(f, "    _result = ", call)
        _emit_value_unwrap(f, "_result", ret.kind)
    end
    return nothing
end

"""
    _emit_facade_autowrapper(f, method, plan)

Emit a mechanically-classified façade wrapper (`plan.category === :auto`):
`def <symbol>(<argnames>):`, the argument conversions from
[`_facade_arg_conversions`](@ref), and the return body from
[`_emit_facade_return_body`](@ref) called on `plan.ret`. The counterpart for
an entrypoint with an `@api` metadata sidecar entry is
[`_emit_facade_api_autowrapper`](@ref).
"""
function _emit_facade_autowrapper(f::IO, method::MethodDesc, plan)
    arg_names_seen = Set{String}()
    argnames = String[
        sanitize_python_argname(a.name, arg_names_seen)
            for a in method.args
    ]
    println(f, "def ", method.symbol, "(", join(argnames, ", "), "):")
    call_args = _facade_arg_conversions(f, argnames, plan.args)
    call = "_lowlevel." * method.symbol * "(" * join(call_args, ", ") * ")"
    _emit_facade_return_body(f, call, plan.ret)
    return println(f)
end

"""
    _api_kwarg_default_python(value) -> String

Write an `@api` keyword argument default, as it was parsed from the metadata
sidecar's JSON, in Python literal syntax. A string is re-emitted through
`JSON.json`, whose escapes are also valid Python. Any other value type is an
error: the sidecar carries only numbers, strings, booleans and `null`.
"""
_api_kwarg_default_python(v::Bool) = v ? "True" : "False"
_api_kwarg_default_python(::Nothing) = "None"
_api_kwarg_default_python(v::Integer) = string(v)
_api_kwarg_default_python(v::AbstractFloat) = string(v)
_api_kwarg_default_python(v::AbstractString) = JSON.json(String(v))
_api_kwarg_default_python(v) =
    error("unsupported `@api` keyword default in the metadata sidecar: $(repr(v))")

"""
    _emit_facade_api_autowrapper(f, method, plan)

Emit an `@api`-sourced façade wrapper (`plan.category === :api_auto`): the
Python name from `plan.api_entry["name"]`, positional parameters for its
`"args"`, keyword-only parameters for its `"kwargs"` (with a translated
default, or bare when the entry has no `"default"` key), and its `"doc"` as
the docstring, escaped by [`_python_docstring`](@ref). Argument conversion and the return body match
[`_emit_facade_autowrapper`](@ref); only the `def` line's name and parameter
shape differ.
"""
function _emit_facade_api_autowrapper(f::IO, method::MethodDesc, plan)
    entry = plan.api_entry
    pos_names = String[String(n) for n in entry["args"]]
    kw_specs = entry["kwargs"]
    declared = vcat(pos_names, String[String(kw["name"]) for kw in kw_specs])
    seen = Set{String}()
    argnames = String[sanitize_python_argname(n, seen) for n in declared]
    npos = length(pos_names)

    sig_parts = copy(argnames[1:npos])
    if !isempty(kw_specs)
        push!(sig_parts, "*")
        for (i, kw) in enumerate(kw_specs)
            name = argnames[npos + i]
            push!(
                sig_parts,
                haskey(kw, "default") ? name * "=" * _api_kwarg_default_python(kw["default"]) : name
            )
        end
    end
    println(f, "def ", entry["name"], "(", join(sig_parts, ", "), "):")
    doc = get(entry, "doc", "")
    isempty(doc) || println(f, "    \"\"\"", _python_docstring(doc), "\"\"\"")

    call_args = _facade_arg_conversions(f, argnames, plan.args)
    call = "_lowlevel." * method.symbol * "(" * join(call_args, ", ") * ")"
    _emit_facade_return_body(f, call, plan.ret)
    return println(f)
end

function _write_facade_stub(
        f::IO, dest::PythonTarget, abi_info::ABIInfo,
        typedict::Dict{Int, String}, needs_jlwerror::Bool,
        api_metadata::AbstractDict = Dict{String, Any}()
    )
    (; entrypoints, typeinfo) = abi_info

    struct_names = String[]
    for (id, type) in pairs(typeinfo)
        if type isa StructDesc
            push!(struct_names, typedict[id])
        end
    end

    release_present = _release_symbols_present(abi_info)
    plans = [
        _facade_plan(m, typeinfo, typedict, release_present, get(api_metadata, m.symbol, nothing))
            for m in entrypoints
    ]
    needs_np = any(p -> p.uses_numpy, plans)
    has_struct_exports = !isempty(struct_names) || needs_jlwerror

    # Each `@api` function is defined on the façade under its sidecar name,
    # so that name has to be a Python identifier, and two entrypoints
    # claiming one name would leave only the second.
    claimed = Dict{String, String}()
    for (method, plan) in zip(entrypoints, plans)
        plan.category === :api_auto || continue
        pyname = String(plan.api_entry["name"])
        _is_python_identifier(pyname) || error(
            "`$pyname` (the Python name for '$(method.symbol)') is not a Python identifier; " *
                "rename the function in Julia"
        )
        owner = get(claimed, pyname, nothing)
        isnothing(owner) || error(
            "API metadata sidecar gives both '$owner' and '$(method.symbol)' the Python name `$pyname`"
        )
        claimed[pyname] = method.symbol
    end

    println(f, "\"\"\"", dest.package_name, " idiomatic façade.")
    println(f)
    println(f, "This file is generated **once** by JuliaLibWrapping as a starter")
    println(f, "façade. Functions whose arguments and return are all recognized")
    println(f, "(primitives, `CArray{owned,T,N}`, `CString{owned}`, direct `JLWStatus`)")
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
        method.symbol in _RELEASE_ENTRYPOINT_SYMBOLS && continue
        if plan.category === :mechanical
            println(
                f, "from ._lowlevel import ", method.symbol,
                "  # TODO: hand-wrap — ", plan.reason
            )
            any_reexport = true
        elseif plan.category === :passthrough
            println(f, "from ._lowlevel import ", method.symbol)
            any_reexport = true
        end
    end
    any_reexport && println(f)

    for (method, plan) in zip(entrypoints, plans)
        if plan.category === :auto
            _emit_facade_autowrapper(f, method, plan)
        elseif plan.category === :api_auto
            _emit_facade_api_autowrapper(f, method, plan)
        end
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
    for (method, plan) in zip(entrypoints, plans)
        # The release entrypoints are internal plumbing (bound on `_lib`
        # only in `_lowlevel.py`, see `_write_bindings`) — never public.
        method.symbol in _RELEASE_ENTRYPOINT_SYMBOLS && continue
        isfirst || print(f, ", ")
        # An `:api_auto` façade function is defined under its sidecar name,
        # not the ABI symbol, so that is the name `__all__` exports.
        public_name = plan.category === :api_auto ? plan.api_entry["name"] : method.symbol
        print(f, "\"", public_name, "\"")
        isfirst = false
    end
    return println(f, "]")
end

function _write_pyproject(f::IO, dest::PythonTarget, needs_numpy::Bool = false)
    println(f, "# Auto-generated by JuliaLibWrapping. Edit only if you know what you are doing.")
    println(f, "[build-system]")
    println(f, "requires = [\"setuptools>=64\"]")
    println(f, "build-backend = \"setuptools.build_meta\"")
    println(f)
    println(f, "[project]")
    println(f, "name = ", repr(dest.package_name))
    println(f, "version = ", repr(dest.version))
    println(
        f, "description = \"Python bindings for ", dest.library_basename,
        ", auto-generated by JuliaLibWrapping\""
    )
    println(f, "requires-python = \">=3.8\"")
    if needs_numpy
        # CArray helpers depend on numpy.
        println(f, "dependencies = [\"numpy>=1.20\"]")
    end
    println(f)
    println(f, "[tool.setuptools]")
    println(f, "packages = [", repr(dest.package_name), "]")
    println(f)
    println(f, "[tool.setuptools.package-data]")
    return if dest.bundle_subdir === nothing
        println(f, dest.package_name, " = [\"*.so\", \"*.dylib\", \"*.dll\"]")
    else
        # Setuptools' package-data does not recurse, so each level of the
        # `juliac --bundle` tree (lib/, lib/julia/, artifacts/**) must be
        # enumerated. Native-library suffixes are listed redundantly with
        # `*` so a manually added library beside the package is also included.
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
