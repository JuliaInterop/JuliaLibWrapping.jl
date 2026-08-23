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
storage alive for the duration of the call. Types that support owning returns
record ownership in an `owned` field. The types are `isbits` when their element
types are, work with `juliac --trim`, and cross a `@ccallable` boundary without
allocating a Julia object.

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

## `CArray{T,N}` — N-D numeric buffer (column-major)

`CArray{T,N}` is `(dims::NTuple{N,Int32}, data::Ptr{T}, owned::Int32)` in
column-major order. Targets may map this layout to native array types.

### `CArray` ownership contract

As with `CStrArray` and `CDict`, `owned == 0` denotes borrowed storage and
`owned == 1` denotes Julia-allocated storage.

- Pointer constructors borrow. The caller must keep the buffer alive and make
  it writable before mutation.
- `CArray(A::AbstractArray)` **owns out**: it `Libc.malloc`s a dense
  column-major copy of `A` and sets `owned = 1`. A target must copy or transfer
  ownership before releasing this storage.

### Python target

The generated `as_numpy()` returns a zero-copy view. For an owning return, the
façade copies the view before releasing the Julia allocation. Low-level callers
can use the idempotent `.free()` method.

Unlike `CStrArray`/`CDict`, whose façade falls back to a direct
re-export at build time when release entrypoints are missing, a library
that returns an owned `CArray` without exporting them still gets a full
auto-wrapped return — the failure surfaces only at runtime, as `.free()`
raising `RuntimeError`, because gating `CArray` returns at build time
would demote every existing borrowed-`CArray` library.

The one- and two-dimensional aliases are:

```julia
const CVector{T} = CArray{T,1}
const CMatrix{T} = CArray{T,2}
```

For `N ≥ 2`, the generated Python `from_numpy` helper requires a
Fortran-contiguous array. Convert row-major input with `np.asfortranarray`.

`CArray{T,N} <: AbstractArray{T,N}` with linear indexing. It supports standard
array operations; mutate only writable storage.

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
