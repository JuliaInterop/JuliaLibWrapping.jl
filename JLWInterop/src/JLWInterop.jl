"""
    JLWInterop

Canonical types for JuliaLibWrapping cross-ABI conventions. Provides
[`JLWStatus`](@ref) for in-band error reporting and [`CVector`](@ref) for
1-D numeric buffers; both are designed to cross a `@ccallable` boundary.

A library author opts in by using these types in any `@ccallable`-returned
or `@ccallable`-accepted struct; the JuliaLibWrapping Python emitter then
recognizes them by struct name + shape and emits idiomatic code — raising a
native Python exception on a non-zero `JLWStatus.code`, and exposing
`from_numpy` / `as_numpy` helpers on each recognized `CVector`.

This package deliberately has no dependencies so it stays
`juliac --trim`-friendly: it is intended to be a build-time *and* runtime
dependency of compiled libraries.
"""
module JLWInterop

export JLWStatus, jlw_ok, jlw_error
export CVector, CMatrix, CString

"""
    JLW_MESSAGE_BYTES

The fixed size, in bytes, of the inline `message` buffer inside
[`JLWStatus`](@ref). Sets the maximum message length an error can
carry across the ABI; longer strings passed to [`jlw_error`](@ref) are
truncated to `JLW_MESSAGE_BYTES - 1` bytes plus a terminating NUL.
"""
const JLW_MESSAGE_BYTES = 256

"""
    CVector{T}

ABI-stable 1-D buffer descriptor for crossing a `@ccallable` boundary:
`length` contiguous elements of type `T` starting at `data`. `T` should be
an `isbits` type, in which case `CVector{T}` is itself `isbits` and
allocation-free to construct, keeping the type `juliac --trim`-friendly.
The `length` field is `Int32`, matching the rest of the JLWInterop ABI
vocabulary.

`CVector{T}` holds a raw pointer; it does **not** own the underlying
buffer. Whoever allocated the storage (the caller passing the buffer in,
or the library that returned it) remains responsible for keeping it alive
for the entire time any `CVector` referring to it is in use, and for
freeing it afterward. `CVector` performs no allocation, no copy, and no
finalization.

Use it to expose a 1-D numeric buffer at a `@ccallable` boundary instead of
a `Vector{T}` (which is not C-ABI compatible). The JuliaLibWrapping Python
emitter recognizes `CVector{T}` for primitive numeric `T` and generates
`from_numpy` / `as_numpy` helpers on the corresponding `ctypes.Structure`,
so the Python caller can pass a `numpy.ndarray` directly.

`CVector{T} <: AbstractVector{T}` and implements `size`, bounds-checked
`getindex`, and `setindex!` via `unsafe_load` / `unsafe_store!` on `data`.
That means `CVector` participates in iteration, broadcasting, `sum`, views,
and any function that accepts an `AbstractVector{T}` — at zero allocation.
`setindex!` is defined unconditionally, so callers must only invoke it on
buffers they know to be writable.

# Example

```julia
using JLWInterop

Base.@ccallable function sum_cvector(v::CVector{Float64})::Float64
    return sum(v)
end

Base.@ccallable function copyto_cvector!(dst::CVector{Float64},
                                         src::CVector{Float64})::Int32
    n = min(length(dst), length(src))
    @inbounds for i in 1:n
        dst[i] = src[i]
    end
    return Int32(n)
end
```

The caller (in Julia, Python, or C) is responsible for ensuring `v.data`
points to at least `v.length` valid `T` slots for the duration of the
call, and that the slots are writable when `setindex!` is used.
"""
struct CVector{T} <: AbstractVector{T}
    length::Int32
    data::Ptr{T}
end

Base.size(v::CVector) = (Int(v.length),)
Base.IndexStyle(::Type{<:CVector}) = IndexLinear()

Base.@propagate_inbounds function Base.getindex(v::CVector, i::Int)
    @boundscheck checkbounds(v, i)
    return unsafe_load(v.data, i)
end

Base.@propagate_inbounds function Base.setindex!(v::CVector{T}, x, i::Int) where {T}
    @boundscheck checkbounds(v, i)
    unsafe_store!(v.data, convert(T, x), i)
    return v
end

"""
    CMatrix{T}

ABI-stable 2-D buffer descriptor for crossing a `@ccallable` boundary:
`rows × cols` elements of type `T` starting at `data`, laid out in
**column-major** order (the same convention as Julia's `Matrix{T}` and
Fortran). `T` should be an `isbits` type; `CMatrix{T}` is itself `isbits`
in that case and allocation-free to construct.

`CMatrix{T}` holds a raw pointer; it does **not** own the underlying
buffer. Whoever allocated the storage (the caller passing the buffer in,
or the library that returned it) remains responsible for keeping it alive
for the entire time any `CMatrix` referring to it is in use, and for
freeing it afterward. `CMatrix` performs no allocation, no copy, and no
finalization.

Use it to expose a 2-D numeric buffer at a `@ccallable` boundary instead
of a `Matrix{T}` (which is not C-ABI compatible). The JuliaLibWrapping
Python emitter recognizes `CMatrix{T}` for primitive numeric `T` and
generates `from_numpy` / `as_numpy` helpers on the corresponding
`ctypes.Structure`. Because the storage is column-major, `from_numpy`
requires a Fortran-contiguous (column-major) `numpy.ndarray` and rejects
the default row-major layout: callers passing a default numpy array must
write `arr.T.copy(order='F')` or equivalent first. This is deliberate —
silently treating a row-major array as column-major would transpose the
matrix without warning.

`CMatrix{T} <: AbstractMatrix{T}` and implements `size`, bounds-checked
`getindex`, and `setindex!` via `unsafe_load` / `unsafe_store!` on `data`.
With `IndexLinear()` style over column-major storage, `m[i, j]` reads
slot `(j-1)*rows + i` (1-based, Julia native), so `CMatrix` plugs into
`sum`, broadcasting, views, and `LinearAlgebra` routines at zero
allocation.

# Example

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
```

The caller (in Julia, Python, or C) is responsible for ensuring `m.data`
points to at least `m.rows * m.cols` valid `T` slots, in column-major
order, for the duration of the call, and that the slots are writable
when `setindex!` is used.
"""
struct CMatrix{T} <: AbstractMatrix{T}
    rows::Int32
    cols::Int32
    data::Ptr{T}
end

Base.size(m::CMatrix) = (Int(m.rows), Int(m.cols))
Base.IndexStyle(::Type{<:CMatrix}) = IndexLinear()

Base.@propagate_inbounds function Base.getindex(m::CMatrix, i::Int)
    @boundscheck checkbounds(m, i)
    return unsafe_load(m.data, i)
end

Base.@propagate_inbounds function Base.setindex!(m::CMatrix{T}, x, i::Int) where {T}
    @boundscheck checkbounds(m, i)
    unsafe_store!(m.data, convert(T, x), i)
    return m
end

"""
    CString

ABI-stable byte-string descriptor for crossing a `@ccallable` boundary:
`length` bytes starting at `data`, interpreted as UTF-8. Length-prefixed,
**not** null-terminated — embedded NUL bytes are permitted and
`length` is the authoritative size. Distinct from `Base.Cstring`
(which is null-terminated).

`CString` holds a raw pointer; it does **not** own the underlying buffer.
Whoever allocated the storage (the caller passing the string in, or the
library that returned it) remains responsible for keeping it alive for
the entire time any `CString` referring to it is in use, and for freeing
it afterward. `CString` performs no allocation, no copy, and no
finalization.

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

# Example

```julia
using JLWInterop

Base.@ccallable function greeting_length(s::CString)::Int32
    # AbstractString gives `length` (character count) directly; `s.length`
    # is the byte count.
    return Int32(length(s))
end
```

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

# A position is a valid character start if it is in range and is not a
# UTF-8 continuation byte (0b10xxxxxx). Base derives `length` (character
# count) and indexing from this.
function Base.isvalid(s::CString, i::Integer)
    1 <= i <= s.length || return false
    return (unsafe_load(s.data, i) & 0xC0) != 0x80
end

# UTF-8 iteration. Mirrors `Base.iterate(::String, ::Int)`: a `Char` is
# encoded as the raw UTF-8 bytes packed into a UInt32 (high byte first),
# so the fast-path reinterprets bytes directly without recomputing a
# codepoint. Malformed sequences yield a one-byte step at the offending
# position, matching String's behavior.
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

# Byte-level `cmp` short-circuits Base's default character-by-character
# comparison; `==` and `isless` derive from this.
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

ABI-stable status struct. `code == 0` means success; any non-zero value is an
error code chosen by the library. `message` is a UTF-8, null-terminated
buffer of fixed length ([`JLW_MESSAGE_BYTES`](@ref) bytes). The fixed buffer
avoids the ownership/lifetime question that `Cstring`/`Ptr{UInt8}` would raise
under `--trim`; payload size is bounded but no allocation is required to
construct one.
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

Return an error status with the given non-zero `code` and `msg`. `msg` is
copied into the fixed-size buffer, truncated to `JLW_MESSAGE_BYTES - 1` bytes
if necessary, and always null-terminated. `code` is converted to `Int32`.

Constructing this status performs no heap allocation.
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
