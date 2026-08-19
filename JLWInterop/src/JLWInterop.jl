"""
    JLWInterop

Dependency-free ABI types for JuliaLibWrapping-generated libraries.
"""
module JLWInterop

export JLWStatus, jlw_ok, jlw_error
export CArray, CVector, CMatrix, CString

"""
    JLW_MESSAGE_BYTES

Size of the inline [`JLWStatus`](@ref) message buffer. One byte is reserved
for the terminating NUL.
"""
const JLW_MESSAGE_BYTES = 256

"""
    CArray{T,N}

Non-owning, column-major N-D buffer descriptor for `@ccallable` boundaries.
`data` must point to `prod(dims)` contiguous elements of `T`.
The caller must keep the buffer alive and ensure it is writable before mutation.

# Example

```julia
using JLWInterop

Base.@ccallable function sum_values(a::CArray{Float64,2})::Float64
    return sum(a)
end
```

# Extended help

`T` should be an `isbits` type. The descriptor does not allocate, copy, free,
or keep its storage alive; callers must ensure the buffer remains valid and is
writable when using `setindex!`.

The 1-D and 2-D specializations have familiar aliases:

```julia
const CVector{T} = CArray{T,1}
const CMatrix{T} = CArray{T,2}
```

Use it to expose a numeric buffer at a `@ccallable` boundary instead of
a `Vector`/`Matrix`/`Array` (which are not C-ABI compatible). The
JuliaLibWrapping Python emitter recognizes `CArray{T,N}` for primitive
numeric `T` and generates `from_numpy` / `as_numpy` helpers on the
corresponding `ctypes.Structure`. For `N ≥ 2` the storage is column-major,
so `from_numpy` requires a Fortran-contiguous `numpy.ndarray` and rejects
the default row-major layout: callers passing a default numpy array must
write `np.asfortranarray(arr)` (or equivalent) first. This is deliberate —
silently treating a row-major array as column-major would reinterpret the
data without warning.

`CArray{T,N} <: AbstractArray{T,N}` and implements `size`, bounds-checked
`getindex`, and `setindex!` via `unsafe_load` / `unsafe_store!` on `data`,
with `IndexLinear()` style over the column-major storage. `CArray` supports
iteration, broadcasting, `sum`, views, `LinearAlgebra` routines, and functions
that accept an `AbstractArray{T,N}` without allocating the array descriptor.
`setindex!` is defined unconditionally, so callers must only
invoke it on buffers they know to be writable.

# Additional examples

```julia
using JLWInterop

Base.@ccallable function trace_cmatrix(m::CMatrix{Float64})::Float64
    n = min(size(m, 1), size(m, 2))
    s = 0.0
    @inbounds for i in 1:n
        s += m[i, i]
    end
    return s
end

Base.@ccallable function sum3d(a::CArray{Float64,3})::Float64
    return sum(a)
end
```

The caller (in Julia, Python, or C) is responsible for ensuring `a.data`
points to at least `prod(a.dims)` valid `T` slots, in column-major order,
for the duration of the call, and that the slots are writable when
`setindex!` is used.
"""
struct CArray{T,N} <: AbstractArray{T,N}
    dims::NTuple{N,Int32}
    data::Ptr{T}
end

"""
    CVector{T}

Alias for `CArray{T,1}`. See [`CArray`](@ref).
"""
const CVector{T} = CArray{T,1}

"""
    CMatrix{T}

Alias for `CArray{T,2}`, laid out in column-major order. See [`CArray`](@ref).
"""
const CMatrix{T} = CArray{T,2}

# Infer `N` from the dimensions.
CArray{T}(dims::Tuple{Vararg{Integer,N}}, data::Ptr{T}) where {T,N} =
    CArray{T,N}(dims, data)

# Scalar constructors for the 1-D and 2-D aliases.
CArray{T,1}(n::Integer, data::Ptr{T}) where {T} =
    CArray{T,1}((n,), data)
CArray{T,2}(rows::Integer, cols::Integer, data::Ptr{T}) where {T} =
    CArray{T,2}((rows, cols), data)

Base.size(a::CArray) = Int.(a.dims)
Base.IndexStyle(::Type{<:CArray}) = IndexLinear()

Base.@propagate_inbounds function Base.getindex(a::CArray, i::Int)
    @boundscheck checkbounds(a, i)
    return unsafe_load(a.data, i)
end

Base.@propagate_inbounds function Base.setindex!(a::CArray{T}, x, i::Int) where {T}
    @boundscheck checkbounds(a, i)
    unsafe_store!(a.data, convert(T, x), i)
    return a
end

"""
    CString

Non-owning UTF-8 string descriptor for `@ccallable` boundaries. It contains
`length` bytes at `data`; embedded NUL bytes are allowed.
The caller must keep the buffer alive while the descriptor is in use.

# Example

```julia
using JLWInterop

Base.@ccallable function greeting_length(s::CString)::Int32
    return Int32(length(s))
end
```

# Extended help

Unlike `Base.Cstring`, `CString` is length-prefixed rather than NUL-terminated.
It does not allocate, copy, free, or keep its storage alive.

Use it to expose a string value at a `@ccallable` boundary instead of a
`String` (which is not C-ABI compatible) or a `Cstring` (which forces
null-termination and forbids embedded NULs). The JuliaLibWrapping Python
emitter recognizes `CString` by name + shape and emits `from_str` /
`as_str` (UTF-8) plus `from_bytes` / `as_bytes` (raw) helpers on the
corresponding `ctypes.Structure`.

`CString <: AbstractString` with `ncodeunits`, `codeunit`, and a fast
byte-level `cmp`; Base derives UTF-8 iteration, `length` (character
count vs. `ncodeunits` byte count), equality, `print`, regex matching,
`split`, `replace`, and the rest of the `AbstractString` interface. Use
`String(s)` to copy the bytes out into a fresh heap-allocated Julia
`String` when you need ownership.

The caller (in Julia, Python, or C) is responsible for ensuring `s.data`
points to at least `s.length` valid UTF-8 bytes for the duration of the
call.
"""
struct CString <: AbstractString
    length::Int32
    data::Ptr{UInt8}
end

Base.ncodeunits(s::CString) = Int(s.length)
Base.codeunit(::CString) = UInt8

Base.@propagate_inbounds function Base.codeunit(s::CString, i::Integer)
    @boundscheck (1 <= i <= s.length) || throw(BoundsError(s, i))
    return unsafe_load(s.data, i)
end

# Valid character starts exclude UTF-8 continuation bytes.
function Base.isvalid(s::CString, i::Integer)
    1 <= i <= s.length || return false
    return (unsafe_load(s.data, i) & 0xC0) != 0x80
end

# Match `String` iteration, including malformed sequences.
@inline function Base.iterate(s::CString, i::Int=1)
    (i % UInt) - 1 < (s.length % UInt) || return nothing
    b = unsafe_load(s.data, i)
    u = UInt32(b) << 24
    (0x80 <= b <= 0xf7) || return reinterpret(Char, u), i+1
    return _cstring_iterate_continued(s, i, u)
end

@noinline function _cstring_iterate_continued(s::CString, i::Int, u::UInt32)
    u < 0xc0000000 && (i += 1; @goto ret)
    n = Int(s.length)
    (i += 1) > n && @goto ret
    b = unsafe_load(s.data, i)
    b & 0xc0 == 0x80 || @goto ret
    u |= UInt32(b) << 16
    ((i += 1) > n) | (u < 0xe0000000) && @goto ret
    b = unsafe_load(s.data, i)
    b & 0xc0 == 0x80 || @goto ret
    u |= UInt32(b) << 8
    ((i += 1) > n) | (u < 0xf0000000) && @goto ret
    b = unsafe_load(s.data, i)
    b & 0xc0 == 0x80 || @goto ret
    u |= UInt32(b); i += 1
    @label ret
    return reinterpret(Char, u), i
end

# Compare bytes directly; `==` and `isless` derive from this.
function Base.cmp(a::CString, b::CString)
    n = min(a.length, b.length)
    @inbounds for i in 1:n
        ai = unsafe_load(a.data, i)
        bi = unsafe_load(b.data, i)
        ai == bi || return ai < bi ? -1 : 1
    end
    return cmp(a.length, b.length)
end

Base.String(s::CString) = unsafe_string(s.data, s.length)

"""
    JLWStatus

ABI status value. `code == 0` means success; `message` is a fixed-size,
NUL-terminated UTF-8 buffer.
"""
struct JLWStatus
    code::Int32
    message::NTuple{JLW_MESSAGE_BYTES, UInt8}
end

"""
    jlw_ok() -> JLWStatus

Return a success status: code 0 with an empty message buffer.
"""
jlw_ok() = JLWStatus(Int32(0), ntuple(_ -> 0x00, Val(JLW_MESSAGE_BYTES)))

"""
    jlw_error(code::Integer, msg::AbstractString) -> JLWStatus

Return an allocation-free error status. `code` is converted to `Int32`; `msg`
is truncated as needed and NUL-terminated.
"""
function jlw_error(code::Integer, msg::AbstractString)
    bytes = codeunits(msg)
    n = min(length(bytes), JLW_MESSAGE_BYTES - 1)
    buf = ntuple(Val(JLW_MESSAGE_BYTES)) do i
        i <= n ? bytes[i] : 0x00
    end
    return JLWStatus(Int32(code), buf)
end

end # module
