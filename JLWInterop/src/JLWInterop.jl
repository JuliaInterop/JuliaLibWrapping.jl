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
export CVector

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
jlw_ok() = JLWStatus(Int32(0), ntuple(_ -> 0x00, JLW_MESSAGE_BYTES))

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
    buf = ntuple(JLW_MESSAGE_BYTES) do i
        i <= n ? bytes[i] : 0x00
    end
    return JLWStatus(Int32(code), buf)
end

end # module
