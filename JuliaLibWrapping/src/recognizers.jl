# Target-independent, structural recognition of JLWInterop carriers.

"""
    _is_void_struct(desc::StructDesc) -> Bool

Recognize the zero-field `Nothing` struct that `juliac` emits for `Cvoid`.
Both the name and shape are checked, so ordinary structs named `Nothing` are
not matched.

`juliac` represents `Cvoid` as a struct rather than a primitive; if
JuliaLang/JuliaC.jl#178 and JuliaLang/julia#62860 merge, this predicate and its
call sites can be removed.
"""
function _is_void_struct(desc::StructDesc)
    return desc.name == "Nothing" && isempty(desc.fields)
end

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
    is_jlwstatus_struct(desc::StructDesc, typeinfo) -> Bool

Recognize `JLWStatus` by name and field layout.
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

Return the path to a direct or immediately embedded `JLWStatus`, or `nothing`.
Field names are passed through `sanitize_fieldname`.
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

Recognize `CString` by name and field layout. Field order is unrestricted.
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

Recognize `CStrArray` by name and field layout: exactly three fields named
`length` (a signed primitive integer), `data` (a pointer to a struct matching
[`cstring_struct_info`](@ref)), and `owned` (`Int32`, the ownership
discriminant: `0` = borrowed, `1` = allocated by the own-out constructor).
Field order is unrestricted.
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

Recognize `CDict` by name and field layout. Return the target-specific
`value_ctype` from the caller-supplied `scalar_types` map, or `nothing`.
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

Recognize `COpt` by name and field layout. Return the target-specific
`value_ctype` from the caller-supplied `scalar_types` map, or `nothing`.
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

Recognize `CArray`, `CVector`, or `CMatrix` by name and field layout. On a
match, return `(; pointee_name, pointee_ctype, dtype, ndim)`; otherwise return
`nothing`. The caller supplies target-specific numeric and scalar type maps.
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
    m = _match_fields(desc, ("dims", "data", "owned"))
    isnothing(m) && return nothing
    dims_type = typeinfo[m.dims.type]
    dims_type isa ArrayDesc || return nothing
    dims_eltype = typeinfo[dims_type.element_type]
    dims_eltype isa PrimitiveTypeDesc || return nothing
    (startswith(dims_eltype.name, "Int") || startswith(dims_eltype.name, "UInt")) || return nothing
    dims_eltype.name in keys(numeric_types) || return nothing
    data_type = typeinfo[m.data.type]
    data_type isa PointerDesc || return nothing
    pointee = typeinfo[data_type.pointee_type]
    pointee isa PrimitiveTypeDesc || return nothing
    pointee.name in keys(numeric_types) || return nothing
    owned_type = typeinfo[m.owned.type]
    owned_type isa PrimitiveTypeDesc && owned_type.name == "Int32" || return nothing
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
`numeric_types`. `Ptr{Cvoid}` and pointers inside carrier structs are excluded.

A non-empty result identifies an argument with no length, ownership, or layout
metadata. Targets can use it to warn users or decline automatic wrapping.

`numeric_types` maps a Julia primitive type name to the caller's own spelling
of it, e.g. `"Float64" => "float64"` for [`numpy_dtypes`](@ref); only its keys
are consulted here.
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
