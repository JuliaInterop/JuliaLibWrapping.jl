```@meta
CurrentModule = JLWInterop
```

# JLWInterop

```@docs
JLWInterop
```

## Ownership and layout discipline

Every type in this package holds a raw pointer and **does not own**
the underlying storage. The caller that allocated the buffer is
responsible for keeping it alive for the duration of any call that
sees it, and for freeing it afterward. In exchange, every type is
`isbits` (when the element type is), is `juliac --trim`-friendly,
and crosses a `@ccallable` boundary without heap allocation.

The [JuliaLibWrapping](@ref) Python emitter recognizes these types
**structurally** — by struct name plus field shape — so an author
who copy-pastes a compatible definition into their own library gets
the same wrapper behavior. Depending on `JLWInterop` is the way to
keep the definitions from drifting across libraries.

## `JLWStatus` — in-band error reporting

A library that needs to surface errors to its caller (rather than
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

## `CVector{T}` — 1-D numeric buffer

`CVector{T}` is `(length::Int32, data::Ptr{T})`. The caller owns the
storage; `CVector` borrows. For primitive numeric `T`, the Python
emitter generates `from_numpy` / `as_numpy` helpers so a Python
caller can pass a `numpy.ndarray` directly without copying.

Because `CVector{T} <: AbstractVector{T}`, it participates in
iteration, broadcasting, `sum`, views, and any function that accepts
an `AbstractVector{T}` — at zero allocation. `setindex!` is defined
unconditionally; only call it on storage you know to be writable.

```@docs
CVector
```

## `CMatrix{T}` — 2-D numeric buffer (column-major)

`CMatrix{T}` is `(rows::Int32, cols::Int32, data::Ptr{T})`, laid out
in **column-major** order — the same convention as `Matrix{T}` and
Fortran, not C. The same ownership discipline as `CVector` applies.

The column-major choice has a sharp consequence on the Python side:
the generated `from_numpy` helper requires a Fortran-contiguous
(column-major) array and **rejects** a default row-major `ndarray`.
Silently treating a row-major buffer as column-major would transpose
the matrix without warning, which is a footgun no caller asks for.
Python callers wrapping a default numpy array must `.copy(order='F')`
first.

`CMatrix{T} <: AbstractMatrix{T}` with `IndexLinear()`, so `m[i, j]`
reads slot `(j-1)*rows + i` and the type plugs into `LinearAlgebra`
routines at zero allocation.

```@docs
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
