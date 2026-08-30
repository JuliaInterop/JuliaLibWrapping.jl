"""
    JLWInterop

Dependency-free ABI types for JuliaLibWrapping-generated libraries, plus
[`@api`](@ref), the annotation macro that generates a `@ccallable` wrapper
(argument/return conversion, `JLWResult`/`JLWStatus` error reporting, and a
build-host metadata registry) from an ordinary Julia function.
"""
module JLWInterop

export JLWStatus, jlw_ok, jlw_error
export CArray, CVector, CMatrix, CString
export CStrArray
export CDict, COpt, unwrap
export JLWResult
export @export_release_entrypoints
export @api

"""
    JLW_MESSAGE_BYTES

Size of the inline [`JLWStatus`](@ref) message buffer. One byte is reserved
for the terminating NUL.
"""
const JLW_MESSAGE_BYTES = 256

"""
    CArray{owned,T,N}

Column-major N-D buffer for `@ccallable` boundaries. `data` points to
`prod(dims)` contiguous elements of `T`.

# Ownership contract

`owned` is `:owned` or `:borrowed`, so whether a value must be released is a
property of its type.

`CArray{:owned,T,N}` holds Julia-allocated storage, produced by
`CArray{:owned}(::AbstractArray)`. The consumer releases `data` exactly once,
with `Libc.free` or the `jlw_free` entrypoint emitted by
[`@export_release_entrypoints`](@ref).

`CArray{:borrowed,T,N}` wraps memory the caller owns and keeps alive; the
consumer never releases it, and must make the storage writable before
mutating it. Pointer constructors build carriers of either ownership.

# Example

```julia
using JLWInterop

Base.@ccallable function sum_values(a::CArray{:borrowed,Float64,2})::Float64
    return sum(a)
end
```

# Extended help

`T` should be an `isbits` type. `CArray <: DenseArray` and supports linear
indexing, the strided-array interface, and conversion to `Ptr{T}`. The aliases
[`CVector`](@ref) and [`CMatrix`](@ref) cover one and two dimensions.

`GC.@preserve` on a carrier protects nothing: the buffer is not
garbage-collected memory. An owned buffer is valid until it is released; a
borrowed one is valid for as long as its true owner keeps it so.

Every construction path names an ownership: there is no defaulting
constructor, and any parameter other than `:owned` or `:borrowed` is
rejected.

Binding targets can map this layout to native N-D array types without
changing the ABI. They must preserve column-major dimension and stride
semantics. The two ownerships are two distinct types, so a target reads
"release this" or "do not release this" off the signature alone.
"""
struct CArray{owned, T, N} <: DenseArray{T, N}
    dims::NTuple{N, Int64}
    data::Ptr{T}

    function CArray{owned, T, N}(dims, data) where {owned, T, N}
        owned === :owned || owned === :borrowed || throw(
            ArgumentError(
                "ownership parameter must be :owned or :borrowed, got $(repr(owned))"
            )
        )
        return new{owned, T, N}(dims, data)
    end
end

"""
    CVector{owned,T}

Alias for `CArray{owned,T,1}`. See [`CArray`](@ref).
"""
const CVector{owned, T} = CArray{owned, T, 1}

"""
    CMatrix{owned,T}

Alias for `CArray{owned,T,2}`, laid out in column-major order. See
[`CArray`](@ref).
"""
const CMatrix{owned, T} = CArray{owned, T, 2}

# Infer `T` and `N` from the pointer and the dimensions.
CArray{owned}(dims::Tuple{Vararg{Integer, N}}, data::Ptr{T}) where {owned, T, N} =
    CArray{owned, T, N}(dims, data)

# Infer `N` from the dimensions.
CArray{owned, T}(dims::Tuple{Vararg{Integer, N}}, data::Ptr{T}) where {owned, T, N} =
    CArray{owned, T, N}(dims, data)

# Scalar dimension forms for the 1-D and 2-D aliases.
CArray{owned, T, 1}(n::Integer, data::Ptr{T}) where {owned, T} =
    CArray{owned, T, 1}((n,), data)
CArray{owned, T, 2}(rows::Integer, cols::Integer, data::Ptr{T}) where {owned, T} =
    CArray{owned, T, 2}((rows, cols), data)

"""
    CArray{:owned}(A::AbstractArray{T,N})
    CArray{:borrowed}(A::DenseArray{T,N})

`CArray{:owned}(A)` allocates a dense column-major copy of `A`, taking `A`'s
values in iteration order and `A`'s `size` as `dims`. The consumer must
release `data` once with `Libc.free` or the exported `jlw_free`.

`CArray{:borrowed}(A)` wraps `A`'s own storage without copying: `data` is
`pointer(A)`. The caller must keep `A` alive (a rooted global, or
`GC.@preserve` around every use) for as long as the carrier is in use. Only
`DenseArray`s can be borrowed — their storage is already contiguous and
column-major, so the alias is exact; borrowing any other array throws an
`ArgumentError` rather than aliasing memory whose layout may not match.
Non-`DenseArray` storage can still be copied with `CArray{:owned}(A)`, or
wrapped through a pointer constructor by a caller who vouches for its
layout.

Neither constructor records axes: only `size(A)` crosses the boundary, so
arrays with offset axes are handled correctly but index the same data from
`1` on the other side.

# Example

```julia
using JLWInterop

a = CArray{:owned}([1.0 2.0; 3.0 4.0])
collect(a) == [1.0 2.0; 3.0 4.0]
Libc.free(a.data)

buf = zeros(3)
b = CArray{:borrowed}(buf)  # aliases buf; keep buf alive while b is in use
```
"""
function CArray{owned}(A::AbstractArray{T, N}) where {owned, T, N}
    if owned === :owned
        dense = Array{T, N}(undef, size(A))
        copyto!(dense, A)
        n = length(dense)
        data = Ptr{T}(Libc.malloc(max(n, 1) * sizeof(T)))
        GC.@preserve dense unsafe_copyto!(data, pointer(dense), n)
        return CArray{owned, T, N}(size(A), data)
    elseif owned === :borrowed
        throw(
            ArgumentError(
                "cannot borrow a " * string(typeof(A)) * ": only `DenseArray` " *
                    "storage (contiguous, column-major) can be aliased; copy with " *
                    "`CArray{:owned}(A)` or construct from a pointer"
            )
        )
    else
        throw(
            ArgumentError(
                "ownership parameter must be :owned or :borrowed, got $(repr(owned))"
            )
        )
    end
end

CArray{:borrowed}(A::DenseArray{T, N}) where {T, N} =
    CArray{:borrowed, T, N}(size(A), pointer(A))

Base.size(a::CArray) = Int.(a.dims)
Base.IndexStyle(::Type{<:CArray}) = IndexLinear()

Base.@propagate_inbounds function Base.getindex(a::CArray, i::Int)
    @boundscheck checkbounds(a, i)
    return unsafe_load(a.data, i)
end

Base.@propagate_inbounds function Base.setindex!(a::CArray{owned, T}, x, i::Int) where {owned, T}
    @boundscheck checkbounds(a, i)
    unsafe_store!(a.data, convert(T, x), i)
    return a
end

# `strides` and `pointer` use the `DenseArray` fallbacks.
Base.unsafe_convert(::Type{Ptr{T}}, a::CArray{owned, T}) where {owned, T} = a.data
Base.elsize(::Type{<:CArray{owned, T}}) where {owned, T} = sizeof(T)

# Distinct carriers may wrap the same buffer.
Base.dataids(a::CArray) = (UInt(a.data),)
Base.mightalias(A::CArray, B::CArray) = !isdisjoint(Base.dataids(A), Base.dataids(B))
Base.unaliascopy(a::CArray) = copy(a)

"""
    CString{owned}

Length-prefixed UTF-8 string descriptor for `@ccallable` boundaries.
It contains `length` bytes at `data` and permits embedded NUL bytes.

# Ownership contract

`owned` is `:owned` or `:borrowed`.

`CString{:owned}(::AbstractString)` allocates a copy. The consumer releases
`data` once with `Libc.free` or the `jlw_free` entrypoint emitted by
[`@export_release_entrypoints`](@ref).

`CString{:borrowed}` wraps a buffer the caller owns and keeps alive; the
consumer never releases it.

# Example

```julia
using JLWInterop

Base.@ccallable function greeting_length(s::CString{:borrowed})::Int32
    return Int32(length(s))
end

s = CString{:owned}("héllo")
String(s) == "héllo"
Libc.free(s.data)
```

# Extended help

Unlike `Base.Cstring`, `CString` is length-prefixed rather than NUL-terminated.

Use it instead of a `String`, which is not C-ABI compatible, or a `Cstring`,
which requires NUL termination and forbids embedded NULs.

Every construction path names an ownership: there is no defaulting
constructor, and any parameter other than `:owned` or `:borrowed` is
rejected.

`CString{owned} <: AbstractString`. Use `String(s)` to copy its bytes into a
Julia `String`.
"""
struct CString{owned} <: AbstractString
    length::Int64
    data::Ptr{UInt8}

    function CString{owned}(length, data) where {owned}
        owned === :owned || owned === :borrowed || throw(
            ArgumentError(
                "ownership parameter must be :owned or :borrowed, got $(repr(owned))"
            )
        )
        return new{owned}(length, data)
    end
end

# Allocate a copy of `s`'s UTF-8 bytes, without a terminating NUL.
function CString{:owned}(s::AbstractString)
    str = String(s)
    nb = sizeof(str)
    p = Ptr{UInt8}(Libc.malloc(max(nb, 1)))  # never malloc(0): an empty string still needs a non-NULL, freeable p
    GC.@preserve str unsafe_copyto!(p, pointer(str), nb)
    return CString{:owned}(Int64(nb), p)
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
@inline function Base.iterate(s::CString, i::Int = 1)
    (i % UInt) - 1 < (s.length % UInt) || return nothing
    b = unsafe_load(s.data, i)
    u = UInt32(b) << 24
    (0x80 <= b <= 0xf7) || return reinterpret(Char, u), i + 1
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

"""
    CStrArray{owned}

Array of length-prefixed UTF-8 [`CString`](@ref)s for C ABI boundaries.

# Ownership contract

`owned` is `:owned` or `:borrowed`, so whether a value must be released is a
property of its type rather than of the value.

`CStrArray{:owned}` holds Julia-allocated storage, produced by
`CStrArray{:owned}(::AbstractVector{<:AbstractString})`. The consumer releases
it exactly once with `_free_strings` or the `jlw_free_strings` entrypoint
emitted by [`@export_release_entrypoints`](@ref).

`CStrArray{:borrowed}` wraps memory the caller owns and keeps alive; the
consumer never releases it. Converting to `Vector{String}` copies without
freeing the source.

Elements share the container's ownership — `data` points to `CString{owned}`s
— and releasing an owning `CStrArray` releases every element's buffer too.

There is no default ownership or constructor that borrows a `Vector{String}`;
borrowed carriers arrive across the ABI.

`CStrArray{owned} <: AbstractVector{CString{owned}}` and is read-only.
Collected elements still alias the carrier's buffers, which must be released
only through the original carrier.

# Example

```julia
using JLWInterop

a = CStrArray{:owned}(["hello", "world"])
Vector{String}(a) == ["hello", "world"]
String.(a) == ["hello", "world"]
JLWInterop._free_strings(a.data, a.length)
```
"""
struct CStrArray{owned} <: AbstractVector{CString{owned}}
    length::Int64
    data::Ptr{CString{owned}}     # each element a length-prefixed CString

    function CStrArray{owned}(length, data) where {owned}
        owned === :owned || owned === :borrowed || throw(
            ArgumentError(
                "ownership parameter must be :owned or :borrowed, got $(repr(owned))"
            )
        )
        return new{owned}(length, data)
    end
end

Base.size(a::CStrArray) = (Int(a.length),)
Base.IndexStyle(::Type{<:CStrArray}) = IndexLinear()

Base.@propagate_inbounds function Base.getindex(a::CStrArray, i::Int)
    @boundscheck checkbounds(a, i)
    return unsafe_load(a.data, i)
end

# Replacing an owned descriptor would leak its buffer, so no `setindex!` is defined.

# Copy without freeing the source.
function Base.Vector{String}(a::CStrArray)
    v = Vector{String}(undef, a.length)
    for i in 1:a.length
        v[i] = String(unsafe_load(a.data, i))
    end
    return v
end

# Copy `v` to length-prefixed C strings in iteration order.
function CStrArray{:owned}(v::AbstractVector{<:AbstractString})
    n = length(v)
    data = Ptr{CString{:owned}}(Libc.malloc(max(n, 1) * sizeof(CString{:owned})))
    completed = 0
    try
        for (slot, s) in enumerate(v)
            unsafe_store!(data, CString{:owned}(s), slot)
            completed = slot
        end
    catch
        # An element that throws leaves this carrier unreachable to the caller,
        # so release what is built here. `catch`, not `finally`: on success the
        # buffers belong to the caller.
        _free_strings(data, Int64(completed))
        rethrow()
    end
    return CStrArray{:owned}(Int64(n), data)
end

"""
    JLWInterop._free_strings(p::Ptr{CString{:owned}}, n::Int64)

Free `n` string buffers pointed to by the `CString`s at `p` (each one's
`.data`), then free `p` itself. Matches the allocation made by
`CStrArray{:owned}(::AbstractVector{<:AbstractString})`. Internal; exposed at
a `@ccallable` boundary as `jlw_free_strings` by
[`@export_release_entrypoints`](@ref).
"""
function _free_strings(p::Ptr{CString{:owned}}, n::Int64)
    for i in 1:n
        Libc.free(unsafe_load(p, i).data)
    end
    Libc.free(p)
    return nothing
end

"""
    CDICT_VALUE_TYPES

Supported value types for [`CDict`](@ref). The closed list permits concrete,
trim-safe conversion methods; other value types throw `MethodError`.
"""
const CDICT_VALUE_TYPES = (
    Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64,
    Float32, Float64, Bool,
)

"""
    CDict{owned,V}

String-keyed dictionary for C ABI boundaries. Keys are length-prefixed
[`CString`](@ref)s and values are a parallel array of a type in
[`CDICT_VALUE_TYPES`](@ref).

# Ownership contract

`owned` is `:owned` or `:borrowed`, so whether a value must be released is a
property of its type.

`CDict{:owned,V}` holds Julia-allocated storage, produced by
`CDict{:owned}(::AbstractDict{<:AbstractString,V})`. The consumer releases
`keys` with `_free_strings` and `values` with `Libc.free`, or uses the
corresponding entrypoints emitted by [`@export_release_entrypoints`](@ref),
exactly once.

`CDict{:borrowed,V}` wraps memory the caller owns and keeps alive; the consumer
never releases it. Converting to a `Dict` copies without freeing the source.

Keys share the dictionary's ownership — `keys` points to `CString{owned}`s —
and releasing them releases every key's buffer too.

There is no default ownership or constructor that borrows a `Dict`; borrowed
carriers arrive across the ABI.

# Example

```julia
using JLWInterop

c = CDict{:owned}(Dict("a" => 1.5, "b" => -2.0))
Dict{String,Float64}(c) == Dict("a" => 1.5, "b" => -2.0)
JLWInterop._free_strings(c.keys, c.length)
Libc.free(c.values)
```
"""
struct CDict{owned, V}
    length::Int64
    keys::Ptr{CString{owned}}
    values::Ptr{V}

    function CDict{owned, V}(length, keys, values) where {owned, V}
        owned === :owned || owned === :borrowed || throw(
            ArgumentError(
                "ownership parameter must be :owned or :borrowed, got $(repr(owned))"
            )
        )
        return new{owned, V}(length, keys, values)
    end
end

# Infer `V` from the value pointer.
CDict{owned}(length, keys, values::Ptr{V}) where {owned, V} =
    CDict{owned, V}(length, keys, values)

# Concrete methods keep conversion trim-safe and reject unsupported values.
for V in CDICT_VALUE_TYPES
    @eval begin
        function Base.Dict{String, $V}(d::CDict{owned, $V}) where {owned}
            out = Dict{String, $V}()
            sizehint!(out, d.length)
            for i in 1:d.length
                out[String(unsafe_load(d.keys, i))] = unsafe_load(d.values, i)
            end
            return out
        end
        function CDict{:owned}(dict::AbstractDict{<:AbstractString, $V})
            n = length(dict)
            kp = Ptr{CString{:owned}}(Libc.malloc(max(n, 1) * sizeof(CString{:owned})))
            vp = Ptr{$V}(Libc.malloc(max(n, 1) * sizeof($V)))
            completed = 0
            try
                i = 0
                for (k, v) in dict
                    i += 1
                    unsafe_store!(kp, CString{:owned}(k), i)
                    unsafe_store!(vp, v, i)
                    completed = i
                end
            catch
                # A key that throws leaves this carrier unreachable to the
                # caller, so release both arrays here. `catch`, not `finally`:
                # on success they belong to the caller.
                _free_strings(kp, Int64(completed))
                Libc.free(vp)
                rethrow()
            end
            return CDict{:owned, $V}(Int64(n), kp, vp)
        end
    end
end

"""
    COpt{T}

C-ABI representation of `Union{T,Nothing}`. `has_value` is `1` when the inline
`value` is present and `0` when it is absent. Absent values are zero-filled.

Construct with `COpt(x)` (present) or `COpt{T}(nothing)` (absent, zero-filled);
read back with [`unwrap`](@ref).

# Example

```julia
using JLWInterop

unwrap(COpt(3.5)) === 3.5
isnothing(unwrap(COpt{Float64}(nothing)))
```
"""
struct COpt{T}
    has_value::Int32
    value::T
end
COpt(x::T) where {T} = COpt{T}(Int32(1), x)
COpt{T}(::Nothing) where {T} = COpt{T}(Int32(0), zero(T))   # zero-fill keeps the struct isbits

"""
    unwrap(o::COpt{T}) -> Union{T,Nothing}

Convert a [`COpt{T}`](@ref) to `Union{T,Nothing}`.
"""
unwrap(o::COpt{T}) where {T} = o.has_value == Int32(0) ? nothing : o.value

include("result.jl")
include("api.jl")

"""
    @export_release_entrypoints

At module top level, emit the release functions required by owning carrier
returns. `jlw_free` frees one allocation; `jlw_free_strings` frees an array of
`CString`s and their buffers.
"""
macro export_release_entrypoints()
    return esc(
        quote
            Base.@ccallable function jlw_free(p::$(Ptr{Cvoid}))::$(Cvoid)
                $(Libc.free)(p)
                return nothing
            end
            Base.@ccallable function jlw_free_strings(
                    p::$(Ptr{CString{:owned}}), n::$(Int64),
                )::$(Cvoid)
                $(_free_strings)(p, n)
                return nothing
            end
        end
    )
end

end # module
