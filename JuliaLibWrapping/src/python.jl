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
and by [`cdict_struct_info`](@ref)/[`copt_struct_info`](@ref) to recognize a
carrier's value-typed field as a supported scalar.
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
    _is_void_struct(desc::StructDesc) -> Bool

Recognize juliac's synthetic zero-field `struct Nothing` — the ABI-JSON
representation of `Cvoid` (`Cvoid` is a type alias for `Nothing` in Base).
juliac's `--export-abi` renders `Cvoid` as a real zero-size
`kind:"struct","name":"Nothing","fields":[]` type node in EVERY position —
a bare return type, and a pointer's pointee (`Ptr{Cvoid}` prints as
`Ptr{Nothing}`, pointing at this same node) — never as a `PrimitiveTypeDesc`
named `"Cvoid"` (`pytypes["Cvoid"] => "None"` only ever fires for the
primitive spelling and is unreachable for this struct spelling, in either
position). Two call sites rely on this:
`mangle_python!`'s `PointerDesc` branch (`Ptr{Nothing}` → `ctypes.c_void_p`,
matching the existing `Ptr{Cvoid}`-as-primitive special case) and
`_write_bindings`'s return-type resolution (bare `Nothing` return →
Python `None`, since libffi cannot build a call interface for a zero-size
struct return — `ffi_prep_cif failed`).

**Every position `mangle_python!` can reach for this same struct `type_id`
was swept, not just these two:**
- **struct field** (`_write_bindings`'s field-emission loops): a field
  typed as the BARE `Nothing` struct (not a pointer to it) mangles to the
  real `Nothing` class name, unchanged by this predicate — correctly so,
  not a gap: a ctypes `_fields_` entry needs a concrete ctypes type object,
  and Python's `None` is not a valid one. No known carrier or juliac
  output produces a bare-`Cvoid`-typed struct field (`Cvoid` has no
  instances beyond the singleton `nothing`, so there is nothing to lay out
  inline); a `Ptr{Nothing}` *pointer* field, by contrast, already collapses
  to `ctypes.c_void_p` via the `PointerDesc` branch fix above — see the
  `mangle_python! Nothing type_id sweep` testset.
- **array element** (`mangle_python!`'s `ArrayDesc` branch,
  `type.element_type`): a fixed-size array whose element type is the bare
  `Nothing` struct (i.e. an ABI representation of `NTuple{N,Cvoid}`) is
  **left unhandled** — it renders as `(Nothing * N)`, a ctypes array of a
  zero-size struct. `NTuple{N,Cvoid}` is not a producible Julia value
  shape (there is nothing to store `N` of), so no carrier or juliac
  `--export-abi` output has ever been observed to emit this; pinned as
  current (unfixed) behavior by the sweep testset rather than silently
  assumed safe, since it is untested territory.

Gated on BOTH the name AND zero fields — matching the
[`is_jlwstatus_struct`](@ref)/[`cstrarray_struct_info`](@ref) family's
name-plus-shape convention — so a genuine user struct that happens to be
named `Nothing` but carries real fields is never swallowed by this check.
"""
function _is_void_struct(desc::StructDesc)
    return desc.name == "Nothing" && isempty(desc.fields)
end

"""
    mangle_python!(typedict, type_id, typeinfo) -> String

Return a Python expression naming the ctypes type for `type_id`. Struct names
go through `sanitize_for_c` (whose output is also a valid Python identifier)
with a `_<id>` collision suffix matching `mangle_c!`. Pointer types render
inline as `ctypes.POINTER(...)`; `Ptr{Cvoid}` collapses to `ctypes.c_void_p`
— both when the pointee arrives as a `PrimitiveTypeDesc` named `"Cvoid"`
and when it arrives as juliac's zero-field `Nothing` struct (see
[`_is_void_struct`](@ref); the latter is what `Ptr{Nothing}` actually looks
like in a real ABI JSON). Array types render inline as `(<eltype> * N)`.
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
        pointee = typeinfo[type.pointee_type]
        if pointee isa PrimitiveTypeDesc && pointee.name == "Cvoid"
            mangled = "ctypes.c_void_p"
        elseif pointee isa StructDesc && _is_void_struct(pointee)
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
    carray_struct_info(desc::StructDesc, typeinfo) -> Union{Nothing, NamedTuple}

Recognize the JLWInterop `CArray{T,N}` shape (which subsumes `CVector{T} =
CArray{T,1}` and `CMatrix{T} = CArray{T,2}`): a struct whose name starts
with `"CArray"`, `"CVector"`, or `"CMatrix"`, with exactly two fields
named `dims` (a fixed-size array of `N` integers, i.e. an `ArrayDesc`
of a signed/unsigned integer primitive in [`numpy_dtypes`](@ref)) and `data`
(a pointer to a primitive numeric type also in `numpy_dtypes`). Field order
may be either `dims, data` or `data, dims`. Returns
`(; pointee_name, pointee_ctype, dtype, ndim)` on a match (with `ndim` set
to the `dims` array's `count`), otherwise `nothing`.

Like [`is_jlwstatus_struct`](@ref), recognition is by name + shape so
authors who copy-paste a compatible definition still get the behavior.
"""
function carray_struct_info(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    (
        startswith(desc.name, "CArray") || startswith(desc.name, "CVector") ||
            startswith(desc.name, "CMatrix")
    ) || return nothing
    length(desc.fields) == 2 || return nothing
    dims_field = nothing
    data_field = nothing
    for field in desc.fields
        if field.name == "dims"
            dims_field = field
        elseif field.name == "data"
            data_field = field
        end
    end
    (dims_field === nothing || data_field === nothing) && return nothing
    dims_type = typeinfo[dims_field.type]
    dims_type isa ArrayDesc || return nothing
    dims_eltype = typeinfo[dims_type.element_type]
    dims_eltype isa PrimitiveTypeDesc || return nothing
    (startswith(dims_eltype.name, "Int") || startswith(dims_eltype.name, "UInt")) || return nothing
    dims_eltype.name in keys(numpy_dtypes) || return nothing
    data_type = typeinfo[data_field.type]
    data_type isa PointerDesc || return nothing
    pointee = typeinfo[data_type.pointee_type]
    pointee isa PrimitiveTypeDesc || return nothing
    pointee.name in keys(numpy_dtypes) || return nothing
    return (;
        pointee_name = pointee.name,
        pointee_ctype = pytypes[pointee.name],
        dtype = numpy_dtypes[pointee.name],
        ndim = dims_type.count,
    )
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
    _match_fields(desc::StructDesc, names::NTuple{N,String}) where {N} -> Union{Nothing,NamedTuple}

Shared "scan fields, match by name" step behind [`cstrarray_struct_info`](@ref),
[`cdict_struct_info`](@ref), and [`copt_struct_info`](@ref): each recognizer's
name-prefix gate and type-specific per-field checks stay in the recognizer
itself, but the mechanical part — walking `desc.fields`, matching each one
against `names` by name, and rejecting on a field-count or missing-name
mismatch — is identical across all three and lives here once.

`desc` matches only if it has *exactly* `length(names)` fields and every
name in `names` appears among them (in any order — this is exactly the
"field order may be any permutation" behavior the three recognizers
document); otherwise returns `nothing`. On a match, returns a `NamedTuple`
keyed by `names` (as `Symbol`s) mapping each name to its `FieldDesc`, so the
caller can then read `.type` off each field for its own checks. Matches the
original hand-rolled loops' semantics exactly, including on a (never
actually seen) struct with a duplicate field name: the LAST field with a
given name wins, since the scan does not stop early.
"""
function _match_fields(desc::StructDesc, names::NTuple{N, String}) where {N}
    length(desc.fields) == N || return nothing
    slots = Dict{String, FieldDesc}()
    for field in desc.fields
        field.name in names && (slots[field.name] = field)
    end
    length(slots) == N || return nothing
    return NamedTuple{Tuple(Symbol.(names))}(ntuple(i -> slots[names[i]], N))
end

"""
    cstrarray_struct_info(desc::StructDesc, typeinfo) -> Bool

Recognize the JLWInterop `CStrArray` shape: a struct whose name starts with
`"CStrArray"`, with exactly three fields named `length` (a signed primitive
integer), `data` (a pointer to the `CString` struct, i.e. `Ptr{CString}` —
recognized via [`cstring_struct_info`](@ref) applied to the pointee), and
`owned` (an `Int32` explicit-ownership discriminant — see the "Ownership
contract" section of `CStrArray`'s docstring: `0` = caller-owned/borrowed,
`1` = allocated by the own-out constructor). Returns `true` on a match,
`false` otherwise. Field order may be any permutation. Recognition is by
name + full shape (see [`is_jlwstatus_struct`](@ref) for the rationale); the
name is only the first gate — the pointee is walked and checked as well, and
the `owned` field is required so a struct predating the ownership flag is
correctly rejected rather than silently mis-wrapped.
"""
function cstrarray_struct_info(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    startswith(desc.name, "CStrArray") || return false
    m = _match_fields(desc, ("length", "data", "owned"))
    isnothing(m) && return false
    length_type = typeinfo[m.length.type]
    length_type isa PrimitiveTypeDesc && length_type.signed || return false
    data_type = typeinfo[m.data.type]
    data_type isa PointerDesc || return false
    pointee = typeinfo[data_type.pointee_type]
    pointee isa StructDesc || return false
    cstring_struct_info(pointee, typeinfo) || return false
    owned_type = typeinfo[m.owned.type]
    owned_type isa PrimitiveTypeDesc && owned_type.name == "Int32" || return false
    return true
end

"""
    cdict_struct_info(desc::StructDesc, typeinfo) -> Union{Nothing, NamedTuple}

Recognize the JLWInterop `CDict{V}` shape: a struct whose name starts with
`"CDict"`, with exactly four fields named `length` (a primitive integer),
`keys` (a pointer to the `CString` struct, i.e. `Ptr{CString}` — the
same shape as [`cstrarray_struct_info`](@ref)'s `data`, recognized via
[`cstring_struct_info`](@ref) applied to the pointee), `values` (a
pointer to a primitive type recognized by [`pytypes`](@ref)), and `owned`
(an `Int32` explicit-ownership discriminant — see the "Ownership contract"
section of `CDict`'s docstring: `0` = caller-owned/borrowed, `1` = allocated
by the own-out constructor). Field order may be any permutation of the four.
Returns `(; value_ctype)` on a match (the `ctypes` expression for `V`),
otherwise `nothing`. Recognition is by name + full shape (see
[`is_jlwstatus_struct`](@ref) for the rationale); the `owned` field is
required so a struct predating the ownership flag is correctly rejected
rather than silently mis-wrapped.
"""
function cdict_struct_info(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    startswith(desc.name, "CDict") || return nothing
    m = _match_fields(desc, ("length", "keys", "values", "owned"))
    isnothing(m) && return nothing
    length_type = typeinfo[m.length.type]
    length_type isa PrimitiveTypeDesc || return nothing
    (startswith(length_type.name, "Int") || startswith(length_type.name, "UInt")) || return nothing
    keys_type = typeinfo[m.keys.type]
    keys_type isa PointerDesc || return nothing
    keys_pointee = typeinfo[keys_type.pointee_type]
    keys_pointee isa StructDesc || return nothing
    cstring_struct_info(keys_pointee, typeinfo) || return nothing
    values_type = typeinfo[m.values.type]
    values_type isa PointerDesc || return nothing
    values_pointee = typeinfo[values_type.pointee_type]
    values_pointee isa PrimitiveTypeDesc || return nothing
    values_pointee.name in keys(pytypes) || return nothing
    owned_type = typeinfo[m.owned.type]
    owned_type isa PrimitiveTypeDesc && owned_type.name == "Int32" || return nothing
    return (; value_ctype = pytypes[values_pointee.name])
end

"""
    _cstring_pointee_classname(desc, fieldname, typeinfo, typedict) -> String

Return the mangled Python `ctypes.Structure` class name for the
`CString` struct pointed to by `desc`'s field named `fieldname`
(`"data"` for [`cstrarray_struct_info`](@ref), `"keys"` for
[`cdict_struct_info`](@ref)). Callers must have already confirmed the field
recognizes as `Ptr{CString}`. `typedict` already carries the pointee's class
name by the time this is called — every struct is pre-mangled, in
declaration order, before `_write_bindings` walks `typeinfo`.
"""
function _cstring_pointee_classname(
        desc::StructDesc, fieldname::String,
        typeinfo::OrderedDict{Int, TypeDesc}, typedict::Dict{Int, String}
    )
    field = only(f for f in desc.fields if f.name == fieldname)
    pointee_id = (typeinfo[field.type]::PointerDesc).pointee_type
    return typedict[pointee_id]
end

"""
    copt_struct_info(desc::StructDesc, typeinfo) -> Union{Nothing, NamedTuple}

Recognize the JLWInterop `COpt{T}` shape: a struct whose name starts with
`"COpt"`, with exactly two fields named `has_value` (an `Int32` primitive
— the 0/1 discriminant) and `value` (a primitive type recognized by
[`pytypes`](@ref)). Field order may be either. Returns `(; value_ctype)` on
a match (the `ctypes` expression for `T`), otherwise `nothing`. Unlike
[`cstrarray_struct_info`](@ref) and [`cdict_struct_info`](@ref), `COpt` is
a by-value carrier (no pointer fields, no heap allocation), so no release
entrypoint is ever needed for it. Recognition is by name + shape (see
[`is_jlwstatus_struct`](@ref) for the rationale).
"""
function copt_struct_info(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    startswith(desc.name, "COpt") || return nothing
    m = _match_fields(desc, ("has_value", "value"))
    isnothing(m) && return nothing
    hv_type = typeinfo[m.has_value.type]
    hv_type isa PrimitiveTypeDesc || return nothing
    hv_type.name == "Int32" || return nothing
    value_type = typeinfo[m.value.type]
    value_type isa PrimitiveTypeDesc || return nothing
    value_type.name in keys(pytypes) || return nothing
    return (; value_ctype = pytypes[value_type.name])
end

"""
    raw_primitive_pointer_args(method::MethodDesc, typeinfo) -> Vector{Int}

Return positional indices into `method.args` for arguments whose static type is
a bare `Ptr{T}` where `T` is a primitive numeric type recognized by
[`numpy_dtypes`](@ref). `Ptr{Cvoid}` is excluded (it lowers to `ctypes.c_void_p`).
Pointers wrapped inside `CArray` / `CString` structs are *not* reported —
only top-level argument types are examined.

A non-empty result signals an argument that hands the C function a raw memory
address with no length, ownership, or layout metadata. The Python emitter uses
this to attach a docstring on the wrapper noting the column-major contract and
recommending the [`JLWInterop.CArray`](@ref) vocabulary instead.
"""
function raw_primitive_pointer_args(
        method::MethodDesc,
        typeinfo::OrderedDict{Int, TypeDesc}
    )
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

const PYTHON_KEYWORDS = Set{String}(
    [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break",
        "class", "continue", "def", "del", "elif", "else", "except", "finally",
        "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal",
        "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
    ]
)

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

function write_wrapper(dest::PythonTarget, abi_info::ABIInfo)
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
        isempty(raw_ptr_methods) || @info "JuliaLibWrapping: entrypoints take raw `Ptr{<primitive>}` arguments; the emitted Python wrappers carry a docstring describing the layout/ownership contract. Consider wrapping these in `CArray{T,N}` (JLWInterop) for safer interop." methods = raw_ptr_methods
    end

    needs_jlwerror = any(
        jlwstatus_access_path(m, typeinfo) !== nothing
            for m in entrypoints
    )
    needs_numpy = any(
        type isa StructDesc &&
            carray_struct_info(type, typeinfo) !== nothing
            for type in values(typeinfo)
    )

    lowlevel_path = joinpath(pkgdir, "_lowlevel.py")
    open(lowlevel_path, "w") do f
        _write_bindings(f, dest, abi_info, typedict, needs_jlwerror, needs_numpy)
    end

    # `_facade.py` defines the author-editable public API. JuliaLibWrapping
    # creates it only if it does not exist; delete the file and rerun to
    # regenerate it. The initial file wraps any entrypoint whose arguments
    # and return are all recognized ABI
    # types or primitives; anything else is re-exported with a TODO comment.
    facade_path = joinpath(pkgdir, "_facade.py")
    if !isfile(facade_path)
        open(facade_path, "w") do f
            _write_facade_stub(f, dest, abi_info, typedict, needs_jlwerror)
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
    is_jlwstatus_struct(desc::StructDesc, typeinfo) -> Bool

Recognize the JLWInterop error-status convention by structural shape: a
struct named `JLWStatus` with two fields — an integer `code` field and a
`message` field that is a fixed-size byte array. Matching by name + shape
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
    msg_type isa ArrayDesc || return false
    eltype = typeinfo[msg_type.element_type]
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

function _write_carray_helpers(f::IO, cainfo)
    # `cainfo` is the return of `carray_struct_info`. Helpers are emitted as
    # methods on the surrounding ctypes.Structure subclass; the `dims` and
    # `data` field names are guaranteed by the recognizer.
    ctype = cainfo.pointee_ctype
    dtype = cainfo.dtype
    ndim = cainfo.ndim
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
    println(f, "")
    println(f, "    def as_numpy(self):")
    return if ndim == 1
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
end

function _write_cstring_helpers(f::IO)
    # CString shape — see `cstring_struct_info`. The `length` and `data`
    # field names are guaranteed by the recognizer, and the pointee is
    # UInt8 / ctypes.c_uint8. Unlike CArray this emits no
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
    return println(f, "        return self.as_bytes().decode(\"utf-8\")")
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

function _write_cstrarray_helpers(f::IO, cstring_classname::AbstractString)
    # CStrArray shape — see `cstrarray_struct_info`. The `length`, `data`,
    # and `owned` field names are guaranteed by the recognizer, and `data`
    # is always Ptr{CString} / ctypes.POINTER(<cstring_classname>). Like
    # CString this emits no numpy dependency; helpers use only `ctypes`.
    # `data` is Julia-allocated memory when `owned` is 1 (own-out
    # convention), so unlike CString's helpers there is no `as_bytes`/
    # from-buffer split — the caller-facing vocabulary is `list[str]` in
    # and out. `from_list` always builds a caller-owned (`owned=0`) value:
    # the object never allocated it and must never free it.
    println(f, "")
    println(f, "    @classmethod")
    println(f, "    def from_list(cls, items):")
    println(f, "        if not isinstance(items, (list, tuple)):")
    println(f, "            raise TypeError(\"expected a list of str\")")
    _emit_cstring_array(f, "bufs", "arr", "items", "s", cstring_classname)
    println(
        f, "        obj = cls(length=len(bufs), data=ctypes.cast(arr, ctypes.POINTER(",
        cstring_classname, ")), owned=0)"
    )
    println(f, "        obj._buffer = (bufs, arr)   # keepalive — the from_numpy pattern")
    println(f, "        return obj")
    println(f, "")
    println(f, "    def as_list(self):")
    println(f, "        out = []")
    println(f, "        for i in range(self.length):")
    println(f, "            e = self.data[i]")
    println(f, "            out.append(ctypes.string_at(e.data, e.length).decode(\"utf-8\"))")
    println(f, "        return out")
    println(f, "")
    println(f, "    def free(self):")
    println(f, "        \"\"\"Free the Julia-allocated buffer iff this object owns it (owned is 1).")
    println(f, "")
    println(f, "        Idempotent: a second call, or a call on a borrowed (owned is 0) value, is a")
    println(f, "        no-op. For callers who bypass the façade's convert-then-free wrapper and")
    println(f, "        talk to `_lowlevel` directly.\"\"\"")
    println(f, "        if self.owned == 1:")
    println(f, "            _lib.jlw_free_strings(self.data, self.length)")
    return println(f, "            self.owned = 0")
end

function _write_cdict_helpers(f::IO, cdinfo, cstring_classname::AbstractString)
    # CDict{V} shape — see `cdict_struct_info`. The `length`, `keys`,
    # `values`, and `owned` field names are guaranteed by the recognizer;
    # `keys` is always Ptr{CString} (like CStrArray's `data`), `values` is
    # Ptr{<value_ctype>}. Like CStrArray this emits no numpy dependency;
    # `values` is `d.values()` boxed into a fresh ctypes array on the way
    # in, and read back element-by-element on the way out. `from_dict`
    # always builds a caller-owned (`owned=0`) value.
    ctype = cdinfo.value_ctype
    println(f, "")
    println(f, "    @classmethod")
    println(f, "    def from_dict(cls, d):")
    _emit_cstring_array(f, "keys", "karr", "d.keys()", "k", cstring_classname)
    println(f, "        varr = (", ctype, " * len(keys))(*d.values())")
    println(f, "        obj = cls(length=len(keys),")
    println(f, "                  keys=ctypes.cast(karr, ctypes.POINTER(", cstring_classname, ")),")
    println(f, "                  values=ctypes.cast(varr, ctypes.POINTER(", ctype, ")),")
    println(f, "                  owned=0)")
    println(f, "        obj._buffer = (keys, karr, varr)")
    println(f, "        return obj")
    println(f, "")
    println(f, "    def as_dict(self):")
    println(f, "        out = {}")
    println(f, "        for i in range(self.length):")
    println(f, "            e = self.keys[i]")
    println(f, "            k = ctypes.string_at(e.data, e.length).decode(\"utf-8\")")
    println(f, "            out[k] = self.values[i]")
    println(f, "        return out")
    println(f, "")
    println(f, "    def free(self):")
    println(f, "        \"\"\"Free the Julia-allocated buffers iff this object owns them (owned is 1).")
    println(f, "")
    println(f, "        Idempotent: a second call, or a call on a borrowed (owned is 0) value, is a")
    println(f, "        no-op. For callers who bypass the façade's convert-then-free wrapper and")
    println(f, "        talk to `_lowlevel` directly.\"\"\"")
    println(f, "        if self.owned == 1:")
    println(f, "            _lib.jlw_free_strings(self.keys, self.length)")
    println(f, "            _lib.jlw_free(ctypes.cast(self.values, ctypes.c_void_p))")
    return println(f, "            self.owned = 0")
end

function _write_copt_helpers(f::IO, coinfo)
    # COpt{T} shape — see `copt_struct_info`. The `has_value`/`value` field
    # names are guaranteed by the recognizer. COpt is by-value (no pointer
    # fields), so unlike the other vocabulary helpers there is no
    # `_buffer` keepalive and no free-on-release concern.
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
        needs_numpy::Bool = false
    )
    (; entrypoints, typeinfo, forward_declared) = abi_info
    env_var = uppercase(dest.package_name) * "_LIBRARY"

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
            cainfo = carray_struct_info(type, typeinfo)
            cdinfo = cdict_struct_info(type, typeinfo)
            coinfo = copt_struct_info(type, typeinfo)
            if cainfo !== nothing
                # Emit numpy helpers for supported CArray layouts.
                _write_carray_helpers(f, cainfo)
            elseif cstring_struct_info(type, typeinfo)
                # Emit CString conversion helpers.
                _write_cstring_helpers(f)
            elseif cstrarray_struct_info(type, typeinfo)
                # Emit CStrArray conversion helpers.
                cs_classname = _cstring_pointee_classname(type, "data", typeinfo, typedict)
                _write_cstrarray_helpers(f, cs_classname)
            elseif !isnothing(cdinfo)
                # Emit CDict conversion helpers.
                cs_classname = _cstring_pointee_classname(type, "keys", typeinfo, typedict)
                _write_cdict_helpers(f, cdinfo, cs_classname)
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
        return_desc = typeinfo[method.return_type]
        # A bare `::Cvoid` return arrives here as a zero-field `Nothing`
        # StructDesc (see `_is_void_struct`), not a `PrimitiveTypeDesc` — so
        # it must be intercepted BEFORE `mangle_python!`, which (correctly,
        # for every OTHER use of this same struct type_id — e.g. its `class
        # Nothing(ctypes.Structure): _fields_ = []` definition, still
        # emitted by the pre-mangle pass below for use as a struct-pointer
        # pointee elsewhere) mangles it to the real `Nothing` class name.
        # `restype` needs the Python singleton `None` instead — ctypes
        # cannot build a call interface for a zero-size struct return
        # (`ffi_prep_cif failed`). Using `typedict` here would either hit
        # the already-memoized class name (wrong) or, if overwritten,
        # corrupt every other reference to this type_id (also wrong) — so
        # this bypasses `mangle_python!`/`typedict` entirely for this one
        # call site rather than touching the shared memoized mapping. (A
        # `Ptr{Nothing}` *pointer* return, unlike a bare `Nothing` struct
        # return, would fall through to `mangle_python!` below and is
        # handled there — see `_is_void_struct`'s `PointerDesc`-branch use.)
        rt = return_desc isa StructDesc && _is_void_struct(return_desc) ?
            "None" : mangle_python!(typedict, method.return_type, typeinfo)
        println(f, "_lib.", method.symbol, ".argtypes = [", join(argexprs, ", "), "]")
        println(f, "_lib.", method.symbol, ".restype = ", rt)

        if method.symbol in _RELEASE_ENTRYPOINT_SYMBOLS
            # The release entrypoints (`jlw_free`/`jlw_free_strings`) are
            # internal plumbing an owning-return façade wrapper calls
            # directly via `_lowlevel._lib.<symbol>(...)` — bind argtypes/
            # restype above so that call works, but emit no module-level
            # `def` wrapper for them (see `_write_facade_stub`, which
            # correspondingly excludes them from the façade and `__all__`).
            println(f)
            continue
        end

        arg_names_seen = Set{String}()
        argnames = String[sanitize_python_argname(a.name, arg_names_seen) for a in method.args]

        status_path = jlwstatus_access_path(method, typeinfo)

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
            println(f, "    taking `.ctypes.data`, or — better — wrap the field in `CArray{T,N}`")
            println(f, "    (JLWInterop) so shape and layout travel with the buffer.")
            println(f, "    \"\"\"")
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
    _facade_classify_arg(arg, typeinfo, typedict) -> NamedTuple

Classify a method argument for façade auto-wrapping. The return is one of:
- `(kind=:primitive,)` — pass-through
- `(kind=:carray, classname=…)` — wrap with `<class>.from_numpy(name)`
- `(kind=:cstring, classname=…)` — wrap with `<class>.from_str(name)`
- `(kind=:cstrarray, classname=…)` — wrap with `<class>.from_list(name)`
- `(kind=:cdict, classname=…)` — wrap with `<class>.from_dict(name)`
- `(kind=:copt, classname=…)` — wrap with `<class>.from_optional(name)`
- `(kind=:opaque, reason=…)` — bail out; emit mechanical re-export instead.
"""
function _facade_classify_arg(
        arg::ArgDesc,
        typeinfo::OrderedDict{Int, TypeDesc},
        typedict::Dict{Int, String}
    )
    t = typeinfo[arg.type]
    if t isa PrimitiveTypeDesc
        return (kind = :primitive,)
    elseif t isa StructDesc
        if !isnothing(carray_struct_info(t, typeinfo))
            return (kind = :carray, classname = typedict[arg.type])
        elseif cstring_struct_info(t, typeinfo)
            return (kind = :cstring, classname = typedict[arg.type])
        elseif cstrarray_struct_info(t, typeinfo)
            return (kind = :cstrarray, classname = typedict[arg.type])
        elseif !isnothing(cdict_struct_info(t, typeinfo))
            return (kind = :cdict, classname = typedict[arg.type])
        elseif !isnothing(copt_struct_info(t, typeinfo))
            return (kind = :copt, classname = typedict[arg.type])
        else
            return (kind = :opaque, reason = "argument has unrecognized type `" * t.name * "`")
        end
    elseif t isa ArrayDesc
        return (kind = :opaque, reason = "argument has array type `" * t.name * "`")
    else  # PointerDesc
        return (kind = :opaque, reason = "argument has raw pointer type `" * t.name * "`")
    end
end

"""
    _RELEASE_ENTRYPOINT_SYMBOLS :: NTuple{2, String}

The macro-emitted release entrypoint symbols (`JLWInterop.@export_release_entrypoints`)
that owning-return façade wrappers call to free Julia-allocated buffers:
`jlw_free_strings` (string-array/dict-key allocations) and `jlw_free`
(generic single allocations, e.g. `CDict.values`). Used by
[`_release_symbols_present`](@ref) to gate owning-return auto-wrapping and
to exclude these two symbols from the public façade (they are internal
plumbing, bound on `_lib` only).
"""
const _RELEASE_ENTRYPOINT_SYMBOLS = ("jlw_free", "jlw_free_strings")

"""
    _release_symbols_present(abi_info::ABIInfo) -> Bool

Return `true` iff *both* macro-emitted release entrypoints
([`_RELEASE_ENTRYPOINT_SYMBOLS`](@ref): `jlw_free` and `jlw_free_strings`)
appear among `abi_info.entrypoints`' symbols. The ABI JSON carries no
ownership metadata, so this is the only signal that a library actually
exposes the release plumbing an owning-return
carrier (`CStrArray`, `CDict`) needs; without it, [`_facade_classify_return`](@ref)
refuses to auto-wrap such a return rather than emit a call to a symbol
that does not exist.
"""
function _release_symbols_present(abi_info::ABIInfo)
    symbols = Set{String}(m.symbol for m in abi_info.entrypoints)
    return all(sym -> sym in symbols, _RELEASE_ENTRYPOINT_SYMBOLS)
end

"""
    _facade_classify_return(method, typeinfo, typedict, release_present) -> NamedTuple

Classify a method's return for façade auto-wrapping. `release_present` is
[`_release_symbols_present`](@ref)'s verdict for the surrounding library.
The return is one of:
- `(kind=:passthrough,)` — primitive scalar (including `Cvoid`)
- `(kind=:carray_unwrap, classname=…)` — return `_result.as_numpy()`
- `(kind=:cstring_unwrap, classname=…)` — return `_result.as_str()`
- `(kind=:cstrarray_unwrap, classname=…)` — return `_result.as_list()`, then
  free the `data` buffer via `jlw_free_strings` iff `_result.owned` is `1`
  (ownership is read from the returned value itself, not assumed from the
  fact that it was returned — a pass-through of a borrowed argument stays
  `owned = 0` and is never freed)
- `(kind=:cdict_unwrap, classname=…)` — return `_result.as_dict()`, then,
  iff `_result.owned` is `1`, free the `keys` buffer via `jlw_free_strings`
  AND the `values` buffer via `jlw_free` (two separate allocations)
- `(kind=:copt_unwrap, classname=…)` — return `_result.as_optional()`; COpt
  is by-value, so no free is involved (not gated on `release_present`)
- `(kind=:jlwstatus_discard,)` — direct `JLWStatus` return; discard, return `None`
- `(kind=:opaque, reason=…)` — bail out. Also returned in place of
  `:cstrarray_unwrap`/`:cdict_unwrap` when `release_present` is `false`:
  auto-wrapping an owning return with no release entrypoints available
  would emit a call to a symbol that does not exist.
"""
function _facade_classify_return(
        method::MethodDesc,
        typeinfo::OrderedDict{Int, TypeDesc},
        typedict::Dict{Int, String},
        release_present::Bool
    )
    rt = typeinfo[method.return_type]
    if rt isa PrimitiveTypeDesc
        return (kind = :passthrough,)
    elseif rt isa StructDesc
        if is_jlwstatus_struct(rt, typeinfo)
            return (kind = :jlwstatus_discard,)
        elseif !isnothing(carray_struct_info(rt, typeinfo))
            return (kind = :carray_unwrap, classname = typedict[method.return_type])
        elseif cstring_struct_info(rt, typeinfo)
            return (kind = :cstring_unwrap, classname = typedict[method.return_type])
        elseif cstrarray_struct_info(rt, typeinfo)
            release_present || return (
                kind = :opaque,
                reason = "owning return needs release entrypoints; add JLWInterop.@export_release_entrypoints to the library",
            )
            return (kind = :cstrarray_unwrap, classname = typedict[method.return_type])
        elseif !isnothing(cdict_struct_info(rt, typeinfo))
            release_present || return (
                kind = :opaque,
                reason = "owning return needs release entrypoints; add JLWInterop.@export_release_entrypoints to the library",
            )
            return (kind = :cdict_unwrap, classname = typedict[method.return_type])
        elseif !isnothing(copt_struct_info(rt, typeinfo))
            return (kind = :copt_unwrap, classname = typedict[method.return_type])
        elseif !isnothing(jlwstatus_access_path(method, typeinfo))
            return (
                kind = :opaque,
                reason = "returns struct `" * rt.name *
                    "` with embedded JLWStatus; idiomatic shaping depends on the other fields",
            )
        else
            return (kind = :opaque, reason = "returns unrecognized struct `" * rt.name * "`")
        end
    elseif rt isa ArrayDesc
        return (kind = :opaque, reason = "returns array type `" * rt.name * "`")
    else  # PointerDesc
        return (kind = :opaque, reason = "returns raw pointer type `" * rt.name * "`")
    end
end

"""
    _facade_plan(method, typeinfo, typedict, release_present) -> NamedTuple

Decide whether an entrypoint should be auto-wrapped on the façade.
`release_present` is [`_release_symbols_present`](@ref)'s verdict for the
surrounding library, threaded through to [`_facade_classify_return`](@ref).
Returns `(auto::Bool, reason::String, args::Vector, ret::NamedTuple,
uses_numpy::Bool)`.

A function is auto-wrapped only when every argument and return classifies
as a recognized form *and* the wrapping actually adds value (converts a
vocabulary type or strips a discardable `JLWStatus`). Plain
primitive-in/primitive-out functions are left as straight re-exports.
"""
function _facade_plan(
        method::MethodDesc,
        typeinfo::OrderedDict{Int, TypeDesc},
        typedict::Dict{Int, String},
        release_present::Bool
    )
    arg_classes = [_facade_classify_arg(a, typeinfo, typedict) for a in method.args]
    for (i, c) in enumerate(arg_classes)
        if c.kind === :opaque
            return (
                category = :mechanical,
                reason = "`" * method.args[i].name * "`: " * c.reason,
                args = arg_classes, ret = (kind = :opaque,), uses_numpy = false,
            )
        end
    end
    ret = _facade_classify_return(method, typeinfo, typedict, release_present)
    if ret.kind === :opaque
        return (
            category = :mechanical, reason = ret.reason,
            args = arg_classes, ret = ret, uses_numpy = false,
        )
    end
    uses_numpy = any(c -> c.kind === :carray, arg_classes) ||
        ret.kind === :carray_unwrap
    adds_value = any(c -> c.kind !== :primitive, arg_classes) ||
        ret.kind in (
        :carray_unwrap, :cstring_unwrap, :cstrarray_unwrap,
        :cdict_unwrap, :copt_unwrap, :jlwstatus_discard,
    )
    if !adds_value
        # Primitive-only signatures need no conversion; re-export them directly.
        return (
            category = :passthrough, reason = "",
            args = arg_classes, ret = ret, uses_numpy = false,
        )
    end
    return (category = :auto, reason = "", args = arg_classes, ret = ret, uses_numpy = uses_numpy)
end

function _emit_facade_autowrapper(f::IO, method::MethodDesc, plan)
    arg_names_seen = Set{String}()
    argnames = String[
        sanitize_python_argname(a.name, arg_names_seen)
            for a in method.args
    ]
    println(f, "def ", method.symbol, "(", join(argnames, ", "), "):")
    # Convert vocabulary-typed arguments to their lowlevel struct counterparts.
    call_args = String[]
    for (name, cls) in zip(argnames, plan.args)
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
    call = "_lowlevel." * method.symbol * "(" * join(call_args, ", ") * ")"
    ret = plan.ret
    if ret.kind === :passthrough
        println(f, "    return ", call)
    elseif ret.kind === :jlwstatus_discard
        # `_lowlevel` already raises JLWError on a non-zero status; the
        # façade discards the status struct and returns `None`.
        println(f, "    ", call)
    elseif ret.kind === :carray_unwrap
        println(f, "    _result = ", call)
        println(f, "    return _result.as_numpy()")
    elseif ret.kind === :cstring_unwrap
        println(f, "    _result = ", call)
        println(f, "    return _result.as_str()")
    elseif ret.kind === :cstrarray_unwrap
        # `data` may be Julia-allocated (own-out convention, `owned == 1`)
        # or a pass-through of a borrowed argument (`owned == 0`, e.g. a
        # function that returns one of its own CStrArray arguments
        # unchanged): convert to the idiomatic `list[str]` first, then
        # release the buffer via the macro-emitted `jlw_free_strings`
        # release entrypoint ONLY if this result owns it — freeing a
        # borrowed value would double-free the caller's buffer.
        println(f, "    _result = ", call)
        println(f, "    _out = _result.as_list()")
        println(f, "    if _result.owned == 1:")
        println(f, "        _lowlevel._lib.jlw_free_strings(_result.data, _result.length)")
        println(f, "    return _out")
    elseif ret.kind === :cdict_unwrap
        # `keys` and `values` are two SEPARATE buffers, own-out or
        # pass-through exactly as for CStrArray above: convert to `dict`
        # first, then release both via their respective release
        # entrypoints ONLY if this result owns them — the string-array
        # allocator for `keys`, the generic allocator for `values`.
        println(f, "    _result = ", call)
        println(f, "    _out = _result.as_dict()")
        println(f, "    if _result.owned == 1:")
        println(f, "        _lowlevel._lib.jlw_free_strings(_result.keys, _result.length)")
        println(f, "        _lowlevel._lib.jlw_free(ctypes.cast(_result.values, ctypes.c_void_p))")
        println(f, "    return _out")
    elseif ret.kind === :copt_unwrap
        # COpt is by-value (no heap allocation) — unwrap only, no free.
        println(f, "    _result = ", call)
        println(f, "    return _result.as_optional()")
    end
    return println(f)
end

function _write_facade_stub(
        f::IO, dest::PythonTarget, abi_info::ABIInfo,
        typedict::Dict{Int, String}, needs_jlwerror::Bool
    )
    (; entrypoints, typeinfo) = abi_info

    struct_names = String[]
    for (id, type) in pairs(typeinfo)
        if type isa StructDesc
            push!(struct_names, typedict[id])
        end
    end

    release_present = _release_symbols_present(abi_info)
    plans = [_facade_plan(m, typeinfo, typedict, release_present) for m in entrypoints]
    needs_np = any(p -> p.uses_numpy, plans)
    # `:cdict_unwrap`'s release call casts `_result.values` via
    # `ctypes.cast(...)` directly in facade.py (see
    # `_emit_facade_autowrapper`), so `ctypes` must be imported there too.
    needs_ctypes = any(p -> p.ret.kind === :cdict_unwrap, plans)
    has_struct_exports = !isempty(struct_names) || needs_jlwerror

    println(f, "\"\"\"", dest.package_name, " idiomatic façade.")
    println(f)
    println(f, "This file is generated **once** by JuliaLibWrapping as a starter")
    println(f, "façade. Functions whose arguments and return are all recognized")
    println(f, "(primitives, `CArray{T,N}`, `CString`, direct `JLWStatus`)")
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
    if needs_ctypes
        println(f, "import ctypes")
    end
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
        # The release entrypoints are internal plumbing (bound on `_lib`
        # only in `_lowlevel.py`, see `_write_bindings`) — never public.
        method.symbol in _RELEASE_ENTRYPOINT_SYMBOLS && continue
        isfirst || print(f, ", ")
        print(f, "\"", method.symbol, "\"")
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
