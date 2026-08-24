"""
    JLWInterop

Dependency-free ABI types for JuliaLibWrapping-generated libraries.
"""
module JLWInterop

export JLWStatus, jlw_ok, jlw_error
export CArray, CVector, CMatrix, CString
export CStrArray
export CDict, COpt, unwrap
export @export_release_entrypoints

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
property of its type rather than of the value.

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

`T` should be an `isbits` type. `CArray` implements the `AbstractArray`
interface with linear indexing, including bounds-checked access and mutation.
The aliases [`CVector`](@ref) and [`CMatrix`](@ref) cover one and two
dimensions.

Every construction path names an ownership: there is no defaulting
constructor, and any parameter other than `:owned` or `:borrowed` is
rejected.

Binding targets can map this layout to native N-D array types without
changing the ABI. They must preserve column-major dimension and stride
semantics. The two ownerships are two distinct types, so a target reads
"release this" or "do not release this" off the signature alone.
"""
struct CArray{owned, T, N} <: AbstractArray{T, N}
    dims::NTuple{N, Int32}
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
`String` (which is not C-ABI compatible) or a `Cstring` (which requires
NUL termination and forbids embedded NULs). Binding targets can map its
name and layout to native string and byte-sequence types.

`CString <: AbstractString` with `ncodeunits`, `codeunit`, and a fast
byte-level `cmp`; Base derives UTF-8 iteration, `length` (character
count vs. `ncodeunits` byte count), equality, `print`, regex matching,
`split`, `replace`, and the rest of the `AbstractString` interface. Use
`String(s)` to copy the bytes out into a fresh heap-allocated Julia
`String` when you need ownership.

The caller must keep `s.data` valid for the duration of the call.
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
    CStrArray

Array of length-prefixed UTF-8 [`CString`](@ref)s for C ABI boundaries.

# Ownership contract

`owned == 0` denotes borrowed storage. `owned == 1` denotes storage allocated
by `CStrArray(::Vector{String})`; release it once with `_free_strings` or the
`jlw_free_strings` entrypoint. Converting to `Vector{String}` copies without
freeing the source.

# Example

```julia
using JLWInterop

a = CStrArray(["hello", "world"])
a.owned == Int32(1)
Vector{String}(a) == ["hello", "world"]
JLWInterop._free_strings(a.data, a.length)
```
"""
struct CStrArray
    length::Int64
    data::Ptr{CString}     # each element a length-prefixed CString
    owned::Int32            # 0 = caller-owned/borrowed; 1 = allocated by CStrArray(::Vector{String})
end

# Copy without freeing the source.
function Base.Vector{String}(a::CStrArray)
    v = Vector{String}(undef, a.length)
    for i in 1:a.length
        v[i] = String(unsafe_load(a.data, i))
    end
    return v
end

# Allocate an owning copy.
function CStrArray(v::Vector{String})
    n = length(v)
    data = Ptr{CString}(Libc.malloc(max(n, 1) * sizeof(CString)))
    for i in 1:n
        s = v[i]
        nb = sizeof(s)
        p = Ptr{UInt8}(Libc.malloc(max(nb, 1)))  # never malloc(0): an empty string still needs a non-NULL, freeable p
        GC.@preserve s unsafe_copyto!(p, pointer(s), nb)
        unsafe_store!(data, CString(Int32(nb), p), i)
    end
    return CStrArray(Int64(n), data, Int32(1))
end

"""
    JLWInterop._free_strings(p::Ptr{CString}, n::Int64)

Free `n` string buffers pointed to by the `CString`s at `p` (each one's
`.data`), then free `p` itself. Matches the allocation made by
[`CStrArray(::Vector{String})`](@ref). Internal; exposed at a `@ccallable`
boundary as `jlw_free_strings` by [`@export_release_entrypoints`](@ref).
"""
function _free_strings(p::Ptr{CString}, n::Int64)
    for i in 1:n
        Libc.free(unsafe_load(p, i).data)
    end
    Libc.free(p)
    return nothing
end

"""
    CDICT_VALUE_TYPES

Supported value types for [`CDict{V}`](@ref). The closed list permits concrete,
trim-safe conversion methods; other value types throw `MethodError`.
"""
const CDICT_VALUE_TYPES = (
    Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64,
    Float32, Float64, Bool,
)

"""
    CDict{V}

String-keyed dictionary for C ABI boundaries. Keys are length-prefixed
[`CString`](@ref)s and values are a parallel array of a type in
[`CDICT_VALUE_TYPES`](@ref).

# Ownership contract

`owned == 0` denotes borrowed storage. `owned == 1` denotes storage allocated
by `CDict(::Dict)`: release `keys` with `_free_strings` and `values` with
`Libc.free`, or use the corresponding exported entrypoints. Converting to a
`Dict` copies without freeing the source.

# Example

```julia
using JLWInterop

c = CDict(Dict("a" => 1.5, "b" => -2.0))
c.owned == Int32(1)
Dict{String,Float64}(c) == Dict("a" => 1.5, "b" => -2.0)
JLWInterop._free_strings(c.keys, c.length)
Libc.free(c.values)
```
"""
struct CDict{V}
    length::Int64
    keys::Ptr{CString}
    values::Ptr{V}
    owned::Int32   # 0 = caller-owned/borrowed; 1 = allocated by CDict(::Dict{String,V})
end

# Concrete methods keep conversion trim-safe and reject unsupported values.
for V in CDICT_VALUE_TYPES
    @eval begin
        function Base.Dict{String, $V}(d::CDict{$V})
            out = Dict{String, $V}()
            sizehint!(out, d.length)
            for i in 1:d.length
                out[String(unsafe_load(d.keys, i))] = unsafe_load(d.values, i)
            end
            return out
        end
        function CDict(dict::Dict{String, $V})
            n = length(dict)
            kp = Ptr{CString}(Libc.malloc(max(n, 1) * sizeof(CString)))
            vp = Ptr{$V}(Libc.malloc(max(n, 1) * sizeof($V)))
            i = 0
            for (k, v) in dict
                i += 1
                nb = sizeof(k)
                p = Ptr{UInt8}(Libc.malloc(max(nb, 1)))  # never malloc(0): an empty key still needs a non-NULL, freeable p
                GC.@preserve k unsafe_copyto!(p, pointer(k), nb)
                unsafe_store!(kp, CString(Int32(nb), p), i)
                unsafe_store!(vp, v, i)
            end
            return CDict{$V}(Int64(n), kp, vp, Int32(1))
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

"""
    @export_release_entrypoints

At module top level, emit the release functions required by owning carrier
returns. `jlw_free` frees one allocation; `jlw_free_strings` frees an array of
`CString`s and their buffers.
"""
macro export_release_entrypoints()
    return esc(
        quote
            Base.@ccallable function jlw_free(p::Ptr{Cvoid})::Cvoid
                Libc.free(p)
                return nothing
            end
            Base.@ccallable function jlw_free_strings(p::Ptr{CString}, n::Int64)::Cvoid
                JLWInterop._free_strings(p, n)
                return nothing
            end
        end
    )
end

end # module
