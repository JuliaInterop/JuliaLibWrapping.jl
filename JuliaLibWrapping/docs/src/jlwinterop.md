```@meta
CurrentModule = JLWInterop
```

# JLWInterop

```@docs
JLWInterop
```

## Ownership and layout

The package defines fixed-layout types for passing values across a C ABI.
Borrowed values do not own their underlying storage; the caller must keep the
storage alive for the duration of the call. `CArray`, `CString`, `CStrArray`,
and `CDict` each state their ownership in a leading `:owned`/`:borrowed` type
parameter. The types are `isbits` when their element types are, work with
`juliac --trim`, and cross a `@ccallable` boundary without allocating a Julia
object.

JuliaLibWrapping targets recognize these types structurally, by name and field
layout. Using `JLWInterop` keeps those layouts consistent across libraries.

## `JLWStatus` — in-band error reporting

A library that needs to report errors to its caller (rather than
abort the process) returns either a `JLWStatus` directly, or a struct
that contains a `JLWStatus` field. `code == 0` is success; any
non-zero value is an error code the library defines. `message` is a
fixed-size UTF-8 buffer, null-terminated within the buffer.

The buffer is **inline and fixed-size** ([`JLW_MESSAGE_BYTES`](@ref)
bytes) on purpose: a `Cstring` or `Ptr{UInt8}` would force a decision
about who allocates and frees the message, which has no good answer
under `juliac --trim`. The price is a bounded message length; the
benefit is that constructing a status performs no heap allocation.

Construct values with the helpers:

```julia
using JLWInterop

Base.@ccallable function safe_sqrt(x::Float64)::JLWStatus
    x < 0 && return jlw_error(1, "negative input")
    return jlw_ok()
end
```

See [Error handling across the ABI](@ref) for the protocol and its current
Python mapping.

```@docs
JLWStatus
jlw_ok
jlw_error
JLW_MESSAGE_BYTES
```

## `CArray{owned,T,N}` — N-D numeric buffer (column-major)

`CArray{owned,T,N}` is `(dims::NTuple{N,Int64}, data::Ptr{T})` in column-major
order. Targets may map this layout to native array types.

### `CArray` ownership contract

Ownership is the leading type parameter, `:owned` or `:borrowed`, so the two
flavors are two distinct types with identical layout.

- `CArray{:borrowed,T,N}` wraps memory the caller owns. The caller keeps it
  alive and makes it writable before mutation; the consumer never releases it.
  `CArray{:borrowed}(A::DenseArray)` aliases `A`'s own storage (`pointer(A)`)
  without copying; other array types are refused, since only `DenseArray`
  guarantees the contiguous column-major layout the carrier promises. Pointer
  constructors build carriers of either ownership for callers who vouch for
  the layout themselves.
- `CArray{:owned,T,N}` holds a Julia allocation. `CArray{:owned}(A)`
  `Libc.malloc`s a dense column-major copy of `A`; the consumer releases
  `data` exactly once.

There is no ownership-defaulting constructor, and any parameter other than
`:owned` or `:borrowed` is rejected, so an ownership is never guessed.

The one- and two-dimensional aliases are:

```julia
const CVector{owned,T} = CArray{owned,T,1}
const CMatrix{owned,T} = CArray{owned,T,2}
```

`CArray{owned,T,N} <: AbstractArray{T,N}` with linear indexing. It supports
standard array operations; mutate only writable storage.

### Python target

A borrowed return becomes a zero-copy numpy view: the façade calls
`as_numpy()` and hands the view back, because the storage stays the caller's.
An owning return is copied into a fresh numpy array and the Julia allocation
is released in a `finally`. The generated classes follow: a borrowed class
gets `from_numpy` and `as_numpy` and no `free()`; an owning class gets
`as_numpy` and an idempotent `free()`, and no `from_numpy`.

A hand-written entrypoint returning an owning `CArray` without
[`@export_release_entrypoints`](@ref) is demoted at build time to a `TODO`
re-export naming the macro to add — the same rule as `CString`, `CStrArray`,
and `CDict`. An [`@api`](@ref) function in that position fails the build
instead. An owning `CArray` *argument* is likewise left to a human: it
would transfer a Julia allocation into the library, which numpy cannot supply.
The same holds for owning `CString`, `CStrArray`, and `CDict` arguments.

For `N ≥ 2`, the generated `from_numpy` helper requires a Fortran-contiguous
array. Convert row-major input with `np.asfortranarray`.

### C target

The two ownerships mangle to two distinct typedefs
(`CVector_owned_Float64`, `CVector_borrowed_Float64`), so whether to free a
returned buffer is visible in the signature.

```@docs
CArray
CVector
CMatrix
```

## `CString{owned}` — length-prefixed UTF-8

`CString{owned}` is `(length::Int64, data::Ptr{UInt8})`. It is length-prefixed,
so it permits embedded NUL bytes.

`CString{owned} <: AbstractString`; call `String(s)` to copy the bytes into a
Julia `String`.

### `CString` ownership contract

`owned` is `:owned` or `:borrowed`; both types have the same layout.

- `CString{:borrowed}` wraps a buffer the caller owns and keeps alive; the
  consumer never releases it.
- `CString{:owned}(::AbstractString)` allocates a copy of the UTF-8 bytes. The
  consumer releases `data` once with `jlw_free`.

### Python target

| Julia | Python |
|---|---|
| `AbstractString` | `str` |

A borrowed class gets `from_str`, `from_bytes`, `as_str`, and `as_bytes`. An
owning class gets the conversion methods and an idempotent `free()`, but no
constructors. Owning returns are decoded and freed in a `finally`; owning
arguments require a manual wrapper.

```@docs
CString
```

## `CStrArray{owned}` — string arrays

`CStrArray{owned}` is `(length::Int64, data::Ptr{CString{owned}})`: a pointer
to `length` [`CString`](@ref)s with matching ownership. Converting it to
`Vector{String}` copies the strings without freeing the source.

### `CStrArray` ownership contract

`owned` is `:owned` or `:borrowed`, and the two are distinct types with the
same layout.

- `CStrArray{:borrowed}` wraps storage the caller owns and keeps alive; the
  consumer never releases it.
- `CStrArray{:owned}` holds a Julia allocation, produced by
  `CStrArray{:owned}(::Vector{String})`. The consumer releases it once with
  `jlw_free_strings`. There is no borrowing constructor: a Julia
  `Vector{String}` has no length-prefixed layout to alias.

### Python target

| Julia | Python |
|---|---|
| `Vector{String}` | `list[str]` |

A borrowed class gets `from_list` and `as_list`; an owning class gets `as_list`
and an idempotent `free()`. Owning returns are copied and freed in a `finally`.

```@docs
CStrArray
```

## `CDict{owned,V}` — string-keyed dictionaries

`CDict{owned,V}` is `(length::Int64, keys::Ptr{CString{owned}},
values::Ptr{V})`: two parallel arrays. Keys are [`CString`](@ref)s with
matching ownership; values use a type in
[`CDICT_VALUE_TYPES`](@ref). Converting to a Julia `Dict` copies without
freeing the source.

### `CDict` ownership contract

`owned` is `:owned` or `:borrowed`, and the two are distinct types with the
same layout.

- `CDict{:borrowed,V}` wraps storage the caller owns and keeps alive; the
  consumer never releases it.
- `CDict{:owned,V}` holds two separate Julia allocations, produced by
  `CDict{:owned}(::Dict)`. `keys` is released with `jlw_free_strings` and
  `values` with `jlw_free`, each exactly once. There is no borrowing
  constructor: a `Dict`'s storage is neither length-prefixed strings nor a
  dense value array.

### Python target

| Julia | Python |
|---|---|
| `Dict{String,V}` | `dict[str, V]` |

A borrowed class gets `from_dict` and `as_dict`; an owning class gets `as_dict`
and an idempotent `free()`. Owning returns are copied and freed in a `finally`.

```@docs
CDict
CDICT_VALUE_TYPES
```

## `COpt{T}` — optional scalars

`COpt` represents `Union{T,Nothing}` with an `Int32` discriminant and an
inline value. It is allocation-free and has no ownership state.

### Python target

| Julia | Python |
|---|---|
| `Union{T,Nothing}` for scalar `T` | `T \| None` |

The generated `from_optional` and `as_optional` helpers convert the value
without a keepalive or release operation.

```@docs
COpt
unwrap
```

## Owning carrier returns

Libraries returning an owning `CArray`, `CString`, `CStrArray`, or `CDict`
must emit the release entrypoints at module top level:

```julia
using JLWInterop

JLWInterop.@export_release_entrypoints
```

The macro exports `jlw_free` and `jlw_free_strings`. Binding targets use these
functions to release buffers through the library that allocated them. Owning
buffers must be released exactly once; borrowed buffers must not be released.

Without these entrypoints, a target cannot safely automate owning returns. The
current Python target leaves affected functions for manual wrapping. A library
whose carriers are all borrowed needs no release entrypoints at all.

```@docs
@export_release_entrypoints
_free_strings
```
