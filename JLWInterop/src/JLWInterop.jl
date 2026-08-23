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
    CArray{T,N}

Column-major N-D buffer descriptor for `@ccallable` boundaries. `data` must
point to `prod(dims)` contiguous elements of `T`.

# Ownership contract

The `owned` field records ownership explicitly; call direction does not
determine ownership.
`owned = 0` means caller-owned/borrowed: `CArray` neither allocates, copies,
frees, nor keeps the storage alive; the caller must keep the buffer alive and
ensure it is writable before mutation. `owned = 1` means Julia's own-out
constructor allocated it: it must be released exactly once (`Libc.free`, or
`jlw_free` from [`@export_release_entrypoints`](@ref) at a `@ccallable`
boundary). There is no partial ownership — the flag covers the single `data`
allocation as a whole. Julia never retains a reference to an `owned = 1`
buffer once it has handed it across the boundary.

- Every existing constructor below (the tuple-form and scalar-form ones)
  builds a **borrowed** (`owned = 0`) view over caller-supplied storage.
- `CArray(A::AbstractArray)` **owns out**: it `Libc.malloc`s a dense
  column-major copy of `A` and sets `owned = 1`.

# Example

```julia
using JLWInterop

Base.@ccallable function sum_values(a::CArray{Float64,2})::Float64
    return sum(a)
end
```

# Extended help

`T` should be an `isbits` type. The borrowed-view constructors do not
allocate, copy, free, or keep the storage alive; callers must ensure the
buffer remains valid and is writable when using `setindex!`.

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
struct CArray{T, N} <: AbstractArray{T, N}
    dims::NTuple{N, Int32}
    data::Ptr{T}
    owned::Int32   # 0 = caller-owned/borrowed; 1 = allocated by CArray(::AbstractArray)
end

"""
    CVector{T}

Alias for `CArray{T,1}`. See [`CArray`](@ref).
"""
const CVector{T} = CArray{T, 1}

"""
    CMatrix{T}

Alias for `CArray{T,2}`, laid out in column-major order. See [`CArray`](@ref).
"""
const CMatrix{T} = CArray{T, 2}

# Infer `N` from the dimensions; borrowed (owned = 0).
CArray{T}(dims::Tuple{Vararg{Integer, N}}, data::Ptr{T}) where {T, N} =
    CArray{T, N}(dims, data)

# 2-arg convenience constructor: borrowed (owned = 0) — the pre-`owned` shape.
CArray{T, N}(dims::Tuple{Vararg{Integer, N}}, data::Ptr{T}) where {T, N} =
    CArray{T, N}(dims, data, Int32(0))

# Scalar constructors for the 1-D and 2-D aliases; borrowed (owned = 0).
CArray{T, 1}(n::Integer, data::Ptr{T}) where {T} =
    CArray{T, 1}((n,), data)
CArray{T, 2}(rows::Integer, cols::Integer, data::Ptr{T}) where {T} =
    CArray{T, 2}((rows, cols), data)

"""
    CArray(A::AbstractArray{T,N}) where {T,N}

Allocates a dense column-major copy of `A` with `Libc.malloc` and returns a
[`CArray{T,N}`](@ref) with `owned = 1`. The consumer is responsible for
releasing the buffer exactly once, via `Libc.free(a.data)` (or, at a
`@ccallable` boundary, `jlw_free` from [`@export_release_entrypoints`](@ref)).
Julia never retains a reference to the buffer once it has handed it across
the boundary.

# Example

```julia
using JLWInterop

a = CArray([1.0 2.0; 3.0 4.0])
a.owned == Int32(1)
collect(a) == [1.0 2.0; 3.0 4.0]
Libc.free(a.data)
```
"""
function CArray(A::AbstractArray{T, N}) where {T, N}
    dense = Array{T, N}(undef, size(A))
    copyto!(dense, A)
    n = length(dense)
    data = Ptr{T}(Libc.malloc(max(n, 1) * sizeof(T)))
    GC.@preserve dense unsafe_copyto!(data, pointer(dense), n)
    return CArray{T, N}(size(A), data, Int32(1))
end

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

Owning-or-borrowed C-ABI descriptor for an array of UTF-8 strings: `length`
elements at `data`, each a length-prefixed [`CString`](@ref) (16 bytes, not
NUL-terminated; embedded NUL bytes are allowed). Each element's own length is
`CString`'s `Int32`, so a single string over ~2 GiB throws an `InexactError`
in the own-out constructor rather than being truncated.

# Ownership contract

Ownership is carried **explicitly in the data**, via the `owned` field —
never inferred from which direction a value happens to cross the boundary.
`owned = 0` means caller-owned/borrowed: nothing here frees it. `owned = 1`
means Julia's own-out constructor allocated it: it must be released exactly
once. There is no partial ownership — the flag covers the whole struct
(`data` and every per-string buffer it points to) as a single unit.

- `Base.Vector{String}(a::CStrArray)` **borrows**: it copies the strings out
  into a fresh Julia `Vector{String}` and never frees `a.data` or any of the
  per-string buffers, regardless of `a.owned`. The caller retains ownership.
- `CStrArray(v::Vector{String})` **owns out**: it `Libc.malloc`s the `CString`
  array and each per-string buffer, and sets `owned` to `1`. The consumer is
  responsible for releasing them exactly once, via
  [`JLWInterop._free_strings`](@ref) (or, at a `@ccallable` boundary,
  `jlw_free_strings` from [`@export_release_entrypoints`](@ref)).
- Julia never retains a reference to an `owned = 1` buffer once it has
  handed it across the boundary — the whole point of the flag is that the
  receiving side can tell, from the value alone, whether it must free.

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

# Borrow-in: copy out, never free (the caller owns the buffers, regardless of `owned`).
function Base.Vector{String}(a::CStrArray)
    v = Vector{String}(undef, a.length)
    for i in 1:a.length
        v[i] = String(unsafe_load(a.data, i))
    end
    return v
end

# Own-out: malloc'd copy, owned=1; consumer releases via jlw_free_strings.
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

The `V` types [`CDict{V}`](@ref) supports. Per-`V` methods are generated only
for these types (a closed, trim-safe allowlist), so `CDict(::Dict{String,V})`
for any other `V` throws `MethodError` rather than silently miscompiling or
requiring dynamic dispatch.
"""
const CDICT_VALUE_TYPES = (
    Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64,
    Float32, Float64, Bool,
)

"""
    CDict{V}

Owning-or-borrowed C-ABI descriptor for a `Dict{String,V}`: `length`
key/value pairs, keys as length-prefixed [`CString`](@ref)s at `keys`, values
as a parallel array of `V` at `values`. `V` is restricted to
[`CDICT_VALUE_TYPES`](@ref); the allowlist is enforced structurally — the
per-`V` conversion methods below are the only ones generated, so a
disallowed `V` fails as a `MethodError` at the call site. Each key's own
length is `CString`'s `Int32`, so a single key over ~2 GiB throws an
`InexactError` in the own-out constructor rather than being truncated.

# Ownership contract

Ownership is carried **explicitly in the data**, via the `owned` field —
never inferred from which direction a value happens to cross the boundary.
`owned = 0` means caller-owned/borrowed: nothing here frees it. `owned = 1`
means Julia's own-out constructor allocated it: it must be released exactly
once. There is no partial ownership — the flag covers the whole struct
(`keys` and `values`, and every per-key buffer `keys` points to) as a single
unit.

- `Base.Dict{String,V}(d::CDict{V})` **borrows**: it copies keys and values
  out into a fresh Julia `Dict` and never frees `d.keys`, the per-key
  buffers, or `d.values`, regardless of `d.owned`. The caller retains
  ownership.
- `CDict(d::Dict{String,V})` **owns out**: it `Libc.malloc`s the key
  `CString` array, each per-key buffer, and the value array, and sets
  `owned` to `1`. The consumer must release them exactly once: the keys via
  [`JLWInterop._free_strings`](@ref) (or `jlw_free_strings` from
  [`@export_release_entrypoints`](@ref)) and `values` via `Libc.free` (or
  `jlw_free`).
- Julia never retains a reference to an `owned = 1` buffer once it has
  handed it across the boundary.

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

# The loop IS the allowlist: per-V concrete methods keep trim-safety and reject
# unsupported V with a MethodError at the call site.
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

C-ABI descriptor for `Union{T,Nothing}`: a discriminant `has_value` (present
= 1, absent = 0) alongside an inline `value::T`, always present (but
meaningless / zero-filled in the absent branch) so the struct stays
`isbits` and needs no allocation or ownership handling in either direction.

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

Read a [`COpt{T}`](@ref) back into a native `Union{T,Nothing}`: `nothing`
in the absent branch, otherwise `o.value`.
"""
unwrap(o::COpt{T}) where {T} = o.has_value == Int32(0) ? nothing : o.value

"""
    @export_release_entrypoints

Emit the two C-callable release functions a wrapped library must export when it
returns owning carriers (`CArray`, `CStrArray`, `CDict`): `jlw_free` frees one
malloc'd block (also what releases an own-out [`CArray`](@ref)'s `data`);
`jlw_free_strings` frees `n` `CString`-element strings and their array.
Generated wrappers call them exactly once per returned value, via the
library's own handle. Place at top level of the entry module.
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
