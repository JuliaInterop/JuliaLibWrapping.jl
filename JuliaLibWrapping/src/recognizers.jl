# Target-independent, structural recognition of JLWInterop carriers.
#
# Recognizers report Julia-level facts (primitive names and widths, field names,
# and dimension counts); each emitter translates those into its own type names
# and decides which element types it supports (e.g. `_python_carray_info`
# in `python.jl`).

"""
    _match_fields(desc::StructDesc, names::NTuple{N,String}) where {N} -> Union{Nothing,NamedTuple}

Return the fields named by `names`, in that order, when `desc` has exactly
those fields. Otherwise return `nothing`.
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
    _integer_field_info(desc) -> Union{Nothing, NamedTuple}

Return `(; name, bits)` for a signed 32- or 64-bit primitive integer, or
`nothing`.
"""
function _integer_field_info(@nospecialize(desc))
    desc isa PrimitiveTypeDesc || return nothing
    desc.signed || return nothing
    desc.bits in (32, 64) || return nothing
    return (; name = desc.name, bits = desc.bits)
end

"""
    is_jlwstatus_struct(desc::StructDesc, typeinfo) -> Bool

Recognize `JLWStatus` by name and field layout.
"""
function is_jlwstatus_struct(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    desc.name == "JLWStatus" || return false
    length(desc.fields) == 2 || return false
    code_field, msg_field = desc.fields
    code_field.name == "code" || return false
    msg_field.name == "message" || return false
    isnothing(_integer_field_info(typeinfo[code_field.type])) && return false
    msg_type = typeinfo[msg_field.type]
    msg_type isa ArrayDesc || return false
    eltype = typeinfo[msg_type.element_type]
    eltype isa PrimitiveTypeDesc && eltype.name == "UInt8" || return false
    return true
end

"""
    jlwstatus_location(method, typeinfo) -> Union{Nothing, NamedTuple}

Locate a `JLWStatus` in `method`'s return type: `nothing` when there is none,
`(; field = nothing)` when the return type is a `JLWStatus`, and
`(; field = "<name>")` (the raw ABI field name) when one is an immediately
embedded field.
"""
function jlwstatus_location(method::MethodDesc, typeinfo::OrderedDict{Int, TypeDesc})
    method.return_type === nothing && return nothing # `void` return
    rt = typeinfo[method.return_type]
    rt isa StructDesc || return nothing
    if is_jlwstatus_struct(rt, typeinfo)
        return (; field = nothing)
    end
    for field in rt.fields
        ftype = typeinfo[field.type]
        if ftype isa StructDesc && is_jlwstatus_struct(ftype, typeinfo)
            return (; field = field.name)
        end
    end
    return nothing
end

"""
    cstring_struct_info(desc::StructDesc, typeinfo) -> Union{Nothing, NamedTuple}

Recognize `CString` with explicit ownership, a signed 32- or 64-bit `length`,
and a `data` pointer to `UInt8`. Return
`(; ownership, length_type, length_bits)`, or `nothing`.
"""
function cstring_struct_info(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    ownership = _carrier_ownership(desc.name, ("CString{",))
    isnothing(ownership) && return nothing
    m = _match_fields(desc, ("length", "data"))
    isnothing(m) && return nothing
    len = _integer_field_info(typeinfo[m.length.type])
    isnothing(len) && return nothing
    data_type = typeinfo[m.data.type]
    data_type isa PointerDesc || return nothing
    data_type.pointee_type === nothing && return nothing # `void` pointee
    pointee = typeinfo[data_type.pointee_type]
    pointee isa PrimitiveTypeDesc || return nothing
    pointee.name == "UInt8" || return nothing
    return (; ownership, length_type = len.name, length_bits = len.bits)
end

"""
    cstrarray_struct_info(desc::StructDesc, typeinfo) -> Union{Nothing, NamedTuple}

Recognize `CStrArray` with explicit ownership, a signed 32- or 64-bit
`length`, and a `data` pointer to a matching `CString`. Return
`(; ownership, length_type, length_bits)`, or `nothing`.
"""
function cstrarray_struct_info(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    ownership = _carrier_ownership(desc.name, ("CStrArray{",))
    isnothing(ownership) && return nothing
    m = _match_fields(desc, ("length", "data"))
    isnothing(m) && return nothing
    len = _integer_field_info(typeinfo[m.length.type])
    isnothing(len) && return nothing
    data_type = typeinfo[m.data.type]
    data_type isa PointerDesc || return nothing
    data_type.pointee_type === nothing && return nothing # `void` pointee
    pointee = typeinfo[data_type.pointee_type]
    pointee isa StructDesc || return nothing
    element = cstring_struct_info(pointee, typeinfo)
    isnothing(element) && return nothing
    element.ownership === ownership || return nothing
    return (; ownership, length_type = len.name, length_bits = len.bits)
end

"""
    cdict_struct_info(desc::StructDesc, typeinfo) -> Union{Nothing, NamedTuple}

Recognize `CDict` with explicit ownership, a signed 32- or 64-bit `length`,
`CString` keys, and primitive values. Return
`(; value_type, ownership, length_type, length_bits)`, or `nothing`.
"""
function cdict_struct_info(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    ownership = _carrier_ownership(desc.name, ("CDict{",))
    isnothing(ownership) && return nothing
    m = _match_fields(desc, ("length", "keys", "values"))
    isnothing(m) && return nothing
    len = _integer_field_info(typeinfo[m.length.type])
    isnothing(len) && return nothing
    keys_type = typeinfo[m.keys.type]
    keys_type isa PointerDesc || return nothing
    keys_type.pointee_type === nothing && return nothing # `void` pointee
    keys_pointee = typeinfo[keys_type.pointee_type]
    keys_pointee isa StructDesc || return nothing
    key = cstring_struct_info(keys_pointee, typeinfo)
    isnothing(key) && return nothing
    key.ownership === ownership || return nothing
    values_type = typeinfo[m.values.type]
    values_type isa PointerDesc || return nothing
    values_type.pointee_type === nothing && return nothing # `void` pointee
    values_pointee = typeinfo[values_type.pointee_type]
    values_pointee isa PrimitiveTypeDesc || return nothing
    return (;
        value_type = values_pointee.name, ownership,
        length_type = len.name, length_bits = len.bits,
    )
end

"""
    copt_struct_info(desc::StructDesc, typeinfo) -> Union{Nothing, NamedTuple}

Recognize `COpt` with a signed 32- or 64-bit `has_value` and primitive `value`.
Return `(; value_type, has_value_type, has_value_bits)`, or `nothing`.
"""
function copt_struct_info(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    startswith(desc.name, "COpt") || return nothing
    m = _match_fields(desc, ("has_value", "value"))
    isnothing(m) && return nothing
    hv = _integer_field_info(typeinfo[m.has_value.type])
    isnothing(hv) && return nothing
    value_type = typeinfo[m.value.type]
    value_type isa PrimitiveTypeDesc || return nothing
    return (;
        value_type = value_type.name,
        has_value_type = hv.name, has_value_bits = hv.bits,
    )
end

"""
    ctuple_struct_info(desc, typeinfo) -> Union{Nothing, NamedTuple}

Recognize `CTupleN`, the carrier for a tuple return: a struct with fields
`v1`…`vN` at every arity. Return `(; arity, element_type_ids)` with the
element type ids in field order, or `nothing`.
"""
function ctuple_struct_info(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    startswith(desc.name, "CTuple") || return nothing
    n = length(desc.fields)
    n >= 2 || return nothing
    m = _match_fields(desc, ntuple(i -> "v" * string(i), n))
    isnothing(m) && return nothing
    return (; arity = n, element_type_ids = [m[i].type for i in 1:n])
end

"""
    jlwresult_struct_info(desc::StructDesc, typeinfo) -> Union{Nothing, NamedTuple}

Recognize the generated `JLWResult{C}` return carrier: a struct named
`JLWResult…` whose fields are a `JLWStatus` (`status`) and the payload
(`value`). Return `(; value_type_id)` on a match — the `typeinfo` id of the
`value` field's type — otherwise `nothing`.
"""
function jlwresult_struct_info(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    startswith(desc.name, "JLWResult") || return nothing
    slots = _match_fields(desc, ("status", "value"))
    isnothing(slots) && return nothing
    status_desc = typeinfo[slots.status.type]
    status_desc isa StructDesc || return nothing
    is_jlwstatus_struct(status_desc, typeinfo) || return nothing
    return (; value_type_id = slots.value.type)
end

"""
    _carrier_ownership(name::AbstractString, prefixes) -> Union{Nothing, Symbol}

Return the ownership recorded in the leading type parameter of a carrier type
name whose spelling starts with one of `prefixes` (each ending in `{`) —
`:owned` for `"CVector{:owned, Float64}"`, `:borrowed` for
`"CArray{:borrowed, Float32, 3}"`. Return `nothing` when `name` matches no
prefix or its first parameter is neither token, so that a name carrying no
ownership is unrecognized rather than guessed at.
"""
function _carrier_ownership(name::AbstractString, prefixes)
    prefix = nothing
    for candidate in prefixes
        if startswith(name, candidate)
            prefix = candidate
            break
        end
    end
    isnothing(prefix) && return nothing
    rest = SubString(name, ncodeunits(prefix) + 1)
    stop = findfirst(c -> c == ',' || c == '}', rest)
    isnothing(stop) && return nothing
    token = strip(SubString(rest, 1, prevind(rest, stop)))
    token == ":owned" && return :owned
    token == ":borrowed" && return :borrowed
    return nothing
end

"""
    _CARRIER_FAMILY_PREFIXES

Prefixes of carrier families recognized by [`_carrier_ownership`](@ref).
"""
const _CARRIER_FAMILY_PREFIXES = (
    "CArray{", "CVector{", "CMatrix{", "CString{", "CStrArray{", "CDict{",
)

"""
    carrier_missing_ownership(name::AbstractString, prefixes = _CARRIER_FAMILY_PREFIXES) -> Union{Nothing, String}

Return the carrier family when `name` lacks an `:owned` or `:borrowed` token.
Return `nothing` for other names and valid carrier names.
"""
function carrier_missing_ownership(
        name::AbstractString, prefixes = _CARRIER_FAMILY_PREFIXES
    )
    isnothing(_carrier_ownership(name, prefixes)) || return nothing
    for prefix in prefixes
        base = SubString(prefix, 1, prevind(prefix, ncodeunits(prefix)))
        (name == base || startswith(name, prefix)) && return String(base)
    end
    return nothing
end

"""
    carray_struct_info(desc::StructDesc, typeinfo) -> Union{Nothing, NamedTuple}

Recognize `CArray`, `CVector`, or `CMatrix` with explicit ownership, signed
32- or 64-bit dimensions, and primitive data. Return
`(; eltype, ndim, ownership, dims_type, dims_bits)`, or `nothing`.
"""
function carray_struct_info(desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc})
    ownership = _carrier_ownership(desc.name, ("CArray{", "CVector{", "CMatrix{"))
    isnothing(ownership) && return nothing
    m = _match_fields(desc, ("dims", "data"))
    isnothing(m) && return nothing
    dims_type = typeinfo[m.dims.type]
    dims_type isa ArrayDesc || return nothing
    dims_eltype = _integer_field_info(typeinfo[dims_type.element_type])
    isnothing(dims_eltype) && return nothing
    data_type = typeinfo[m.data.type]
    data_type isa PointerDesc || return nothing
    data_type.pointee_type === nothing && return nothing # `void` pointee
    pointee = typeinfo[data_type.pointee_type]
    pointee isa PrimitiveTypeDesc || return nothing
    return (;
        eltype = pointee.name, ndim = dims_type.count, ownership,
        dims_type = dims_eltype.name, dims_bits = dims_eltype.bits,
    )
end

"""
    raw_primitive_pointer_args(method::MethodDesc, typeinfo) -> Vector{Int}

Return positional indices into `method.args` for arguments whose static type is
a bare `Ptr{T}` with `T` a primitive type other than `Cvoid`. Pointers inside
carrier structs are not examined.

A non-empty result identifies an argument with no length, ownership, or layout
metadata. Targets can use it to warn users or decline automatic wrapping.
"""
function raw_primitive_pointer_args(method::MethodDesc, typeinfo::OrderedDict{Int, TypeDesc})
    out = Int[]
    for (i, arg) in pairs(method.args)
        t = typeinfo[arg.type]
        t isa PointerDesc || continue
        t.pointee_type === nothing && continue # `Ptr{Cvoid}`
        pointee = typeinfo[t.pointee_type]
        pointee isa PrimitiveTypeDesc || continue
        push!(out, i)
    end
    return out
end

"""
    _RELEASE_ENTRYPOINT_SYMBOLS :: NTuple{2, String}

Release symbols emitted by [`JLWInterop.@export_release_entrypoints`](@ref).
Targets use them to manage owning carrier returns without exposing them as
public API.
"""
const _RELEASE_ENTRYPOINT_SYMBOLS = ("jlw_free", "jlw_free_strings")

"""
    _release_symbols_present(abi_info::ABIInfo) -> Bool

Return whether the ABI exports both carrier-release entrypoints. Targets use
this to decide whether owning returns can be wrapped automatically.
"""
function _release_symbols_present(abi_info::ABIInfo)
    symbols = Set{String}(m.symbol for m in abi_info.entrypoints)
    return all(sym -> sym in symbols, _RELEASE_ENTRYPOINT_SYMBOLS)
end

"""
    _check_release_entrypoint_signatures(abi_info::ABIInfo)

Validate release entrypoint signatures when both symbols are present.
"""
function _check_release_entrypoint_signatures(abi_info::ABIInfo)
    symbols = Dict{String, MethodDesc}()
    for m in abi_info.entrypoints
        m.symbol in _RELEASE_ENTRYPOINT_SYMBOLS && (symbols[m.symbol] = m)
    end
    length(symbols) == length(_RELEASE_ENTRYPOINT_SYMBOLS) || return nothing

    typeinfo = abi_info.typeinfo
    _check_jlw_free_signature(symbols["jlw_free"], typeinfo)
    _check_jlw_free_strings_signature(symbols["jlw_free_strings"], typeinfo)
    return nothing
end

function _check_jlw_free_signature(method::MethodDesc, typeinfo::OrderedDict{Int, TypeDesc})
    ok = method.return_type === nothing && length(method.args) == 1
    if ok
        t = typeinfo[only(method.args).type]
        ok = t isa PointerDesc && t.pointee_type === nothing
    end
    ok || error(
        "release entrypoint `jlw_free` has signature `" * method.name *
            "`, but JLWInterop.@export_release_entrypoints requires " *
            "`jlw_free(p::Ptr{Cvoid})::Cvoid`"
    )
    return nothing
end

function _check_jlw_free_strings_signature(
        method::MethodDesc, typeinfo::OrderedDict{Int, TypeDesc}
    )
    ok = method.return_type === nothing && length(method.args) == 2
    if ok
        p_type = typeinfo[method.args[1].type]
        ok = p_type isa PointerDesc && p_type.pointee_type !== nothing
        if ok
            pointee = typeinfo[p_type.pointee_type]
            ok = pointee isa StructDesc
            if ok
                info = cstring_struct_info(pointee, typeinfo)
                ok = !isnothing(info) && info.ownership === :owned
            end
        end
    end
    if ok
        len = _integer_field_info(typeinfo[method.args[2].type])
        ok = !isnothing(len) && len.bits == 64
    end
    ok || error(
        "release entrypoint `jlw_free_strings` has signature `" * method.name *
            "`, but JLWInterop.@export_release_entrypoints requires " *
            "`jlw_free_strings(p::Ptr{CString{:owned}}, n::Int64)::Cvoid`"
    )
    return nothing
end
