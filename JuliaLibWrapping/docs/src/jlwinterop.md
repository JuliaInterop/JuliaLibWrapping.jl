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

The [JuliaLibWrapping](@ref) Python emitter recognizes these types
**structurally** — by struct name plus field shape — so an author
who copies a compatible definition into their own library gets the same
wrapper behavior. Using the definitions from `JLWInterop` keeps their layouts
consistent across libraries.

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

See [Error handling across the ABI](@ref) for the full
library-author-and-Python-caller round trip, including how the
emitter raises `JLWError` on the Python side.

```@docs
JLWStatus
jlw_ok
jlw_error
JLW_MESSAGE_BYTES
```

## `CArray{T,N}` — N-D numeric buffer (column-major)

`CArray{T,N}` is `(dims::NTuple{N,Int32}, data::Ptr{T}, owned::Int32)`, laid
out in **column-major** order — the same convention as `Array{T,N}` and
Fortran, not C. For primitive numeric `T`, the Python emitter generates
`from_numpy` / `as_numpy` / `free` helpers so a Python caller can pass a
`numpy.ndarray` directly without copying.

### `CArray` ownership contract

Like `CStrArray`/`CDict` (see [L1 carriers: `CStrArray`, `CDict`, `COpt`](@ref)),
ownership is carried **explicitly in the data**, via `owned`: `0` means
caller-owned/borrowed, `1` means allocated by Julia's own-out constructor.
There is no partial ownership — the flag covers the single `data` allocation.

- Every constructor that takes a raw `Ptr{T}` (the tuple-form and
  scalar-form constructors below) builds a **borrowed** view: `CArray`
  neither allocates, copies, frees, nor keeps the storage alive, and sets
  `owned = 0` — today's, pre-flag semantics, unchanged. The caller must keep
  the buffer alive for the duration of any call that sees it, and ensure it
  is writable before `setindex!`.
- `CArray(A::AbstractArray)` **owns out**: it `Libc.malloc`s a dense
  column-major copy of `A` and sets `owned = 1`. The generated Python
  wrapper's `as_numpy()` always returns a zero-copy view; for an owning
  return, the façade copies that view into a fresh numpy array *before*
  releasing the Julia-allocated buffer via `jlw_free` (see
  [`@export_release_entrypoints`](@ref)) — never handing back a view over
  memory that is about to be freed.

For callers who bypass the façade and talk to `_lowlevel` directly, the
generated `ctypes.Structure` class carries a `.free()` method: it releases
`data` iff `self.owned == 1`, then sets `owned` back to `0`, so a second
call — or a call on a value that was never owned — is a no-op.

Unlike `CStrArray`/`CDict`, whose façade falls back to a direct
re-export at build time when release entrypoints are missing, a library
that returns an owned `CArray` without exporting them still gets a full
auto-wrapped return — the failure surfaces only at runtime, as `.free()`
raising `RuntimeError`, because gating `CArray` returns at build time
would demote every existing borrowed-`CArray` library.

The 1-D and 2-D specializations have familiar aliases:

```julia
const CVector{T} = CArray{T,1}
const CMatrix{T} = CArray{T,2}
```

mirroring Julia's own `Vector{T} = Array{T,1}` / `Matrix{T} = Array{T,2}`.
You can use either the alias or the underlying `CArray{T,N}` form; they
are the same type.

For `N ≥ 2`, the generated Python `from_numpy` helper requires a
Fortran-contiguous array and **rejects** a default row-major
`ndarray`. Silently treating a row-major buffer as column-major would
reinterpret the array with the wrong layout.
Python callers wrapping a default numpy array must `.copy(order='F')`
(or `np.asfortranarray(arr)`) first.

`CArray{T,N} <: AbstractArray{T,N}` with `IndexLinear()` style, so
the type participates in iteration, broadcasting, `sum`, views, and
any function that accepts an `AbstractArray{T,N}` without allocating the
array descriptor. `setindex!` is defined unconditionally; only call it on
storage you know to be writable.

```@docs
CArray
CVector
CMatrix
```

## `CString` — length-prefixed UTF-8

`CString` is `(length::Int32, data::Ptr{UInt8})`. It is
**length-prefixed and not null-terminated** — embedded NUL bytes are
permitted; `length` is the authoritative size. This makes it distinct
from `Base.Cstring`, which is null-terminated and forbids embedded
NULs.

As with the other types, `CString` borrows storage from the caller.
The Python emitter recognizes it by name plus shape and generates
`from_str` / `as_str` (UTF-8 round-trip) plus `from_bytes` /
`as_bytes` (raw bytes) helpers.

`CString <: AbstractString` with `ncodeunits`, `codeunit`, valid-
position checking, UTF-8 iteration, and a fast byte-level `cmp`.
Base derives the rest: `length` (character count, distinct from
`ncodeunits`), `==`, `print`, regex matching, `split`, `replace`, …
Call `String(s)` to copy the bytes out into a fresh, heap-allocated,
owning Julia `String`.

```@docs
CString
```

## `CStrArray`, `CDict{V}`, `COpt{T}` — variable-size and optional data

Three more carriers cover data `CArray`/`CString` cannot: an array of
strings, a string-keyed dictionary, and an optional scalar. Unlike the
non-owning types above, a Julia function that *returns* one of the first two
must allocate — see [L1 carriers: `CStrArray`, `CDict`, `COpt`](@ref) for the
struct layouts, the borrow-in/own-out ownership contract, and the
`@export_release_entrypoints` requirement for owning returns.
