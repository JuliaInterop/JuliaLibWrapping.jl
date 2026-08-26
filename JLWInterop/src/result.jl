"""
    JLWResult{C}

Return carrier for a generated API wrapper: a [`JLWStatus`](@ref) plus a value.
A zero `status.code` means `value` is meaningful; on any nonzero code `value`
is zero-filled, and its pointers are null.
"""
struct JLWResult{C}
    status::JLWStatus
    value::C
end

"""
    jlw_ok(value::C) -> JLWResult{C}

Wrap a successful value: `status` is [`jlw_ok()`](@ref) and `value` is `value`.
"""
jlw_ok(value::C) where {C} = JLWResult{C}(jlw_ok(), value)

"""
    jlw_error(code::Integer, msg::AbstractString, ::Type{C}) -> JLWResult{C}

Wrap a failure: `status` is `jlw_error(code, msg)` and `value` is a
zero-filled `C` (see [`JLWInterop._zero_carrier`](@ref)) with a null pointer.
"""
jlw_error(code::Integer, msg::AbstractString, ::Type{C}) where {C} =
    JLWResult{C}(jlw_error(code, msg), _zero_carrier(C))

"""
    JLWInterop._zero_carrier(::Type{C}) -> C

Build a zero-filled `C` for the failure branch of [`jlw_error`](@ref): every
pointer is null and every count is zero, so releasing it is a no-op. Each
built-in carrier has its own method; any other `isbits` carrier — a raw
`Ptr`, or a struct a library registers with [`carrier_type`](@ref) — is
zeroed byte-wise, covering whatever padding it has. A carrier that is not
`isbits` throws an `ArgumentError`.
"""
function _zero_carrier(::Type{C}) where {C}
    isbitstype(C) || throw(ArgumentError("a carrier type must be isbits"))
    bytes = zeros(UInt8, sizeof(C))
    return GC.@preserve bytes unsafe_load(Ptr{C}(pointer(bytes)))
end

_zero_carrier(::Type{T}) where {T <: Union{Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64, Float32, Float64, Bool}} = zero(T)
_zero_carrier(::Type{CString{owned}}) where {owned} = CString{owned}(Int64(0), Ptr{UInt8}(C_NULL))
_zero_carrier(::Type{CStrArray{owned}}) where {owned} =
    CStrArray{owned}(Int64(0), Ptr{CString{owned}}(C_NULL))
_zero_carrier(::Type{CDict{owned, V}}) where {owned, V} =
    CDict{owned, V}(Int64(0), Ptr{CString{owned}}(C_NULL), Ptr{V}(C_NULL))
_zero_carrier(::Type{COpt{T}}) where {T} = COpt{T}(nothing)
_zero_carrier(::Type{CArray{owned, T, N}}) where {owned, T, N} =
    CArray{owned, T, N}(ntuple(_ -> Int64(0), Val(N)), Ptr{T}(C_NULL))
