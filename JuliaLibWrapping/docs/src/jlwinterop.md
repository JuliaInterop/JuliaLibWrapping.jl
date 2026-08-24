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
storage alive for the duration of the call. `CArray` states its ownership in
its type; `CStrArray` and `CDict` record it in an `owned` field. The types are
`isbits` when their element types are, work with `juliac --trim`, and cross a
`@ccallable` boundary without allocating a Julia object.

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

`CArray{owned,T,N}` is `(dims::NTuple{N,Int32}, data::Ptr{T})` in column-major
order. Targets may map this layout to native array types.

### `CArray` ownership contract

Ownership is the leading type parameter, `:owned` or `:borrowed`, so the two
flavors are two distinct types with identical layout.

- `CArray{:borrowed,T,N}` wraps memory the caller owns. The caller keeps it
  alive and makes it writable before mutation; the consumer never releases it.
  Pointer constructors build carriers of either ownership.
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

A library returning an owning `CArray` without
[`@export_release_entrypoints`](@ref) is demoted at build time to a `TODO`
re-export naming the macro to add — the same rule as `CStrArray` and `CDict`.
An owning `CArray` *argument* is likewise left to a human: it would transfer a
Julia allocation into the library, which numpy cannot supply.

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

## `CString` — length-prefixed UTF-8

`CString` is `(length::Int32, data::Ptr{UInt8})`. It is length-prefixed, so it
permits embedded NUL bytes.

As with the other types, `CString` borrows storage from the caller.
The Python target generates
`from_str` / `as_str` (UTF-8 round-trip) plus `from_bytes` /
`as_bytes` (raw bytes) helpers.

`CString <: AbstractString`; call `String(s)` to make an owning copy.

```@docs
CString
```

## `CStrArray` — string arrays

`CStrArray` stores a pointer to `length` [`CString`](@ref)s. Converting it to
`Vector{String}` copies the strings without freeing the source. Constructing it
from `Vector{String}` allocates an owning copy.

Each string uses an `Int32` byte length; oversized strings throw
`InexactError` rather than being truncated.

### Python target

| Julia | Python |
|---|---|
| `Vector{String}` | `list[str]` |

`CStrArray.from_list` creates a borrowed carrier and keeps its `ctypes`
buffers alive. `as_list` copies the result to a Python list. The façade calls
the carrier's idempotent `.free()` after converting a return value.

```@docs
CStrArray
```

## `CDict{V}` — string-keyed dictionaries

`CDict` stores parallel key and value arrays. Keys are [`CString`](@ref)s;
values use a type in [`CDICT_VALUE_TYPES`](@ref). Converting to a Julia `Dict`
copies without freeing the source. Constructing from a `Dict` allocates owning
key and value buffers.

### Python target

| Julia | Python |
|---|---|
| `Dict{String,V}` | `dict[str, V]` |

`CDict.from_dict` creates a borrowed carrier and keeps its buffers alive.
`as_dict` copies the result to a Python dictionary. The façade calls `.free()`
after converting a return value.

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

Libraries returning an owning `CArray`, `CStrArray`, or `CDict` must emit the
release entrypoints at module top level:

```julia
using JLWInterop

JLWInterop.@export_release_entrypoints
```

The macro exports `jlw_free` and `jlw_free_strings`. Binding targets use these
functions to release buffers through the library that allocated them. Owning
buffers must be released exactly once; borrowed buffers must not be released.

Without these entrypoints, a target cannot safely automate owning returns. The
current Python target leaves affected functions for manual wrapping.

```@docs
@export_release_entrypoints
_free_strings
```
