# ABI carrier recognizers — shared across every emission target.
#
# Each function below decides whether a `StructDesc`/`MethodDesc` matches one
# of JLWInterop's carrier conventions (CArray, CString, CStrArray, CDict,
# COpt, JLWStatus) by inspecting `ABIInfo`/`TypeDesc` structure alone. None of
# them import or hardcode a target language's type-name vocabulary; a few
# take a caller-supplied name table (e.g. `numpy_dtypes`, `pytypes` from
# `python.jl`) as an explicit argument so a future non-Python target can
# supply its own without editing this file.

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

Target-independent: operates on `ABIInfo`/`StructDesc` only.
"""
function _is_void_struct(desc::StructDesc)
    return desc.name == "Nothing" && isempty(desc.fields)
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

Target-independent: operates on `StructDesc` only.
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
    is_jlwstatus_struct(desc::StructDesc, typeinfo) -> Bool

Recognize the JLWInterop error-status convention by structural shape: a
struct named `JLWStatus` with two fields — an integer `code` field and a
`message` field that is a fixed-size byte array. Matching by name + shape
(rather than by package identity) means authors who copy-paste a compatible
definition still get the behavior.

Target-independent: operates on `ABIInfo`/`StructDesc`/`TypeDesc` only.
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
    jlwstatus_access_path(method, typeinfo, sanitize_fieldname) -> Union{Nothing, String}

If `method`'s return type carries a JLWStatus (either the return type *is* a
JLWStatus or it is a struct with a JLWStatus field), return the member
attribute path from `_result` to that status (e.g. `""` for direct return,
or `".status"` for an embedded field). Otherwise return `nothing`.
Recognition is shallow on purpose — only the immediate return struct's
top-level fields are inspected.

`sanitize_fieldname` turns a raw ABI field name into the target language's
identifier form (e.g. `sanitize_python_argname` in `python.jl`, which also
escapes reserved keywords) — passed in explicitly so this recognizer does
not need to know any target's identifier rules.

Target-independent: operates on `ABIInfo`/`MethodDesc`/`TypeDesc` plus the
caller-supplied `sanitize_fieldname` function.
"""
function jlwstatus_access_path(
        method::MethodDesc, typeinfo::OrderedDict{Int, TypeDesc},
        sanitize_fieldname::Function
    )
    rt = typeinfo[method.return_type]
    rt isa StructDesc || return nothing
    if is_jlwstatus_struct(rt, typeinfo)
        return ""
    end
    for field in rt.fields
        ftype = typeinfo[field.type]
        if ftype isa StructDesc && is_jlwstatus_struct(ftype, typeinfo)
            return "." * sanitize_fieldname(field.name)
        end
    end
    return nothing
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

Target-independent: operates on `ABIInfo`/`StructDesc`/`TypeDesc` only.
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
    (isnothing(length_field) || isnothing(data_field)) && return false
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

Target-independent: operates on `ABIInfo`/`StructDesc`/`TypeDesc` only.
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
    cdict_struct_info(desc::StructDesc, typeinfo, scalar_types) -> Union{Nothing, NamedTuple}

Recognize the JLWInterop `CDict{V}` shape: a struct whose name starts with
`"CDict"`, with exactly four fields named `length` (a primitive integer),
`keys` (a pointer to the `CString` struct, i.e. `Ptr{CString}` — the
same shape as [`cstrarray_struct_info`](@ref)'s `data`, recognized via
[`cstring_struct_info`](@ref) applied to the pointee), `values` (a
pointer to a primitive type recognized by `scalar_types`), and `owned`
(an `Int32` explicit-ownership discriminant — see the "Ownership contract"
section of `CDict`'s docstring: `0` = caller-owned/borrowed, `1` = allocated
by the own-out constructor). Field order may be any permutation of the four.
Returns `(; value_ctype)` on a match (`scalar_types`'s expression for `V`),
otherwise `nothing`. Recognition is by name + full shape (see
[`is_jlwstatus_struct`](@ref) for the rationale); the `owned` field is
required so a struct predating the ownership flag is correctly rejected
rather than silently mis-wrapped.

`scalar_types` is a caller-supplied `Dict{String,String}` mapping a Julia
primitive type name to the target language's expression for it (e.g.
`pytypes` in `python.jl`) — passed in explicitly so this recognizer does not
hardcode any target's type vocabulary.

Target-independent: operates on `ABIInfo`/`StructDesc`/`TypeDesc` plus the
caller-supplied `scalar_types` table.
"""
function cdict_struct_info(
        desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc},
        scalar_types::AbstractDict{String, String}
    )
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
    values_pointee.name in keys(scalar_types) || return nothing
    owned_type = typeinfo[m.owned.type]
    owned_type isa PrimitiveTypeDesc && owned_type.name == "Int32" || return nothing
    return (; value_ctype = scalar_types[values_pointee.name])
end

"""
    copt_struct_info(desc::StructDesc, typeinfo, scalar_types) -> Union{Nothing, NamedTuple}

Recognize the JLWInterop `COpt{T}` shape: a struct whose name starts with
`"COpt"`, with exactly two fields named `has_value` (an `Int32` primitive
— the 0/1 discriminant) and `value` (a primitive type recognized by
`scalar_types`). Field order may be either. Returns `(; value_ctype)` on
a match (`scalar_types`'s expression for `T`), otherwise `nothing`. Unlike
[`cstrarray_struct_info`](@ref) and [`cdict_struct_info`](@ref), `COpt` is
a by-value carrier (no pointer fields, no heap allocation), so no release
entrypoint is ever needed for it. Recognition is by name + shape (see
[`is_jlwstatus_struct`](@ref) for the rationale).

`scalar_types` is a caller-supplied `Dict{String,String}` mapping a Julia
primitive type name to the target language's expression for it (e.g.
`pytypes` in `python.jl`) — passed in explicitly so this recognizer does not
hardcode any target's type vocabulary.

Target-independent: operates on `ABIInfo`/`StructDesc`/`TypeDesc` plus the
caller-supplied `scalar_types` table.
"""
function copt_struct_info(
        desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc},
        scalar_types::AbstractDict{String, String}
    )
    startswith(desc.name, "COpt") || return nothing
    m = _match_fields(desc, ("has_value", "value"))
    isnothing(m) && return nothing
    hv_type = typeinfo[m.has_value.type]
    hv_type isa PrimitiveTypeDesc || return nothing
    hv_type.name == "Int32" || return nothing
    value_type = typeinfo[m.value.type]
    value_type isa PrimitiveTypeDesc || return nothing
    value_type.name in keys(scalar_types) || return nothing
    return (; value_ctype = scalar_types[value_type.name])
end

"""
    carray_struct_info(desc::StructDesc, typeinfo, numeric_types, scalar_types) -> Union{Nothing, NamedTuple}

Recognize the JLWInterop `CArray{T,N}` shape (which subsumes `CVector{T} =
CArray{T,1}` and `CMatrix{T} = CArray{T,2}`): a struct whose name starts
with `"CArray"`, `"CVector"`, or `"CMatrix"`, with exactly two fields
named `dims` (a fixed-size array of `N` integers, i.e. an `ArrayDesc`
of a signed/unsigned integer primitive in `numeric_types`) and `data`
(a pointer to a primitive numeric type also in `numeric_types`). Field order
may be either `dims, data` or `data, dims`. Returns
`(; pointee_name, pointee_ctype, dtype, ndim)` on a match (with `ndim` set
to the `dims` array's `count`), otherwise `nothing`.

Like [`is_jlwstatus_struct`](@ref), recognition is by name + shape so
authors who copy-paste a compatible definition still get the behavior.

`numeric_types` gates which primitive names count as array-element-eligible
and supplies the returned `dtype` string (e.g. `numpy_dtypes` in
`python.jl`); `scalar_types` supplies the returned `pointee_ctype` (e.g.
`pytypes`). Both are caller-supplied `Dict{String,String}`s so this
recognizer does not hardcode any target's type vocabulary.

Target-independent: operates on `ABIInfo`/`StructDesc`/`TypeDesc` plus the
caller-supplied `numeric_types`/`scalar_types` tables.
"""
function carray_struct_info(
        desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc},
        numeric_types::AbstractDict{String, String},
        scalar_types::AbstractDict{String, String}
    )
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
    (isnothing(dims_field) || isnothing(data_field)) && return nothing
    dims_type = typeinfo[dims_field.type]
    dims_type isa ArrayDesc || return nothing
    dims_eltype = typeinfo[dims_type.element_type]
    dims_eltype isa PrimitiveTypeDesc || return nothing
    (startswith(dims_eltype.name, "Int") || startswith(dims_eltype.name, "UInt")) || return nothing
    dims_eltype.name in keys(numeric_types) || return nothing
    data_type = typeinfo[data_field.type]
    data_type isa PointerDesc || return nothing
    pointee = typeinfo[data_type.pointee_type]
    pointee isa PrimitiveTypeDesc || return nothing
    pointee.name in keys(numeric_types) || return nothing
    return (;
        pointee_name = pointee.name,
        pointee_ctype = scalar_types[pointee.name],
        dtype = numeric_types[pointee.name],
        ndim = dims_type.count,
    )
end

"""
    raw_primitive_pointer_args(method::MethodDesc, typeinfo, numeric_types) -> Vector{Int}

Return positional indices into `method.args` for arguments whose static type is
a bare `Ptr{T}` where `T` is a primitive numeric type recognized by
`numeric_types` (e.g. `numpy_dtypes` in `python.jl`). `Ptr{Cvoid}` is excluded
(it lowers to `ctypes.c_void_p`). Pointers wrapped inside `CArray` / `CString`
structs are *not* reported — only top-level argument types are examined.

A non-empty result signals an argument that hands the C function a raw memory
address with no length, ownership, or layout metadata. The Python emitter uses
this to attach a docstring on the wrapper noting the column-major contract and
recommending the [`JLWInterop.CArray`](@ref) vocabulary instead.

`numeric_types` is a caller-supplied `Dict{String,String}` so this recognizer
does not hardcode any target's numeric-type vocabulary.

Target-independent: operates on `ABIInfo`/`MethodDesc`/`TypeDesc` plus the
caller-supplied `numeric_types` table.
"""
function raw_primitive_pointer_args(
        method::MethodDesc,
        typeinfo::OrderedDict{Int, TypeDesc},
        numeric_types::AbstractDict{String, String}
    )
    out = Int[]
    for (i, arg) in pairs(method.args)
        t = typeinfo[arg.type]
        t isa PointerDesc || continue
        pointee = typeinfo[t.pointee_type]
        pointee isa PrimitiveTypeDesc || continue
        pointee.name in keys(numeric_types) || continue
        push!(out, i)
    end
    return out
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

These are real C-ABI symbol names emitted by a JLWInterop macro — not a
target-language vocabulary — so, unlike `pytypes`/`numpy_dtypes`, this table
lives here rather than being passed in.
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

Target-independent: operates on `ABIInfo` only.
"""
function _release_symbols_present(abi_info::ABIInfo)
    symbols = Set{String}(m.symbol for m in abi_info.entrypoints)
    return all(sym -> sym in symbols, _RELEASE_ENTRYPOINT_SYMBOLS)
end
