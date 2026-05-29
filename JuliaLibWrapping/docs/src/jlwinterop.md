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

## `CArray{T,N}` — N-D numeric buffer (column-major)

`CArray{T,N}` is `(dims::NTuple{N,Int32}, data::Ptr{T})`, laid out
in **column-major** order — the same convention as `Array{T,N}` and
Fortran, not C. The caller owns the storage; `CArray` borrows. For
primitive numeric `T`, the Python emitter generates
`from_numpy` / `as_numpy` helpers so a Python caller can pass a
`numpy.ndarray` directly without copying.

The 1-D and 2-D specializations have familiar aliases:

```julia
const CVector{T} = CArray{T,1}
const CMatrix{T} = CArray{T,2}
```

mirroring Julia's own `Vector{T} = Array{T,1}` / `Matrix{T} = Array{T,2}`.
You can use either the alias or the underlying `CArray{T,N}` form; they
are the same type.

The column-major choice has a sharp consequence on the Python side
for `N ≥ 2`: the generated `from_numpy` helper requires a
Fortran-contiguous array and **rejects** a default row-major
`ndarray`. Silently treating a row-major buffer as column-major would
transpose without warning, which is a footgun no caller asks for.
Python callers wrapping a default numpy array must `.copy(order='F')`
(or `np.asfortranarray(arr)`) first.

`CArray{T,N} <: AbstractArray{T,N}` with `IndexLinear()` style, so
the type participates in iteration, broadcasting, `sum`, views, and
any function that accepts an `AbstractArray{T,N}` — at zero
allocation. `setindex!` is defined unconditionally; only call it on
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
