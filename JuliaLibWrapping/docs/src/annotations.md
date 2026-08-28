```@meta
CurrentModule = JLWInterop
```

# Annotating a library with `@api`

[`@api`](@ref) generates the `@ccallable` wrapper for you. An author declares
one call signature of an existing function and gets a C-ABI wrapper under a
generated symbol plus a build-host registry entry carrying the Python name,
argument and keyword names, and docstring across to the binding target. The
macro defines nothing: the function it names must already be callable with
those types, whether it is defined alongside the declaration or comes from a
package this layer wraps. Hand-written `@ccallable` wrappers keep working
alongside `@api` declarations — see [Two ways to write a library](@ref) in
Concepts.

What is left for a hand-written `Base.@ccallable` is a signature something
outside the library dictates: `@api` always returns a [`JLWResult`](@ref) or a
[`JLWStatus`](@ref), so a function whose exact C signature an existing header
fixes has to be written by hand.

## What `@api` generates

```julia
scale(a::Vector{Float64}; factor::Float64 = 2.0) = factor .* a

@api "Scale a vector." scale(a::Vector{Float64}; factor::Float64 = 2.0)::Vector{Float64}
```

The declaration expands to two things:

1. `Base.@ccallable Boundary_scale(a::CArray{:borrowed,Float64,1}, factor::Float64)::JLWResult{CArray{:owned,Float64,1}}`
   — arguments converted with [`from_carrier`](@ref), `scale` called, the
   result converted with [`to_carrier`](@ref) and wrapped in [`jlw_ok`](@ref),
   or a caught exception turned into [`jlw_error`](@ref).
2. An [`ApiEntry`](@ref) appended to the declaring module's registry, later
   written by [`write_metadata`](@ref) to the `<lib>.jlw.json` sidecar.

The registry is a `Vector{ApiEntry}` the macro declares in the annotated
module under the reserved name `_JLW_API_REGISTRY_`; do not bind that name to
anything else. It belongs to that module rather than to JLWInterop so that a
package carrying `@api` declarations keeps its entries in its own
precompilation cache — a registry owned by JLWInterop would hold only what the
current session happened to macro-expand, and a precompiled package's
declarations would be missing from it. [`api_entries`](@ref) gathers them from
a module and everything nested under it, which is how [`write_metadata`](@ref)
finds every declaration in a library whatever module they live in.

Both outputs are built from the declared signature in one expansion, so they
cannot disagree. The declared types are the boundary contract, not a method
signature: `scale` may accept more than this, and foreign callers get exactly
this. A signature `scale` cannot satisfy surfaces when the library is
compiled, as a missing method.

## Writing the signature

`@api` takes the signature apart at expansion time, so it accepts one shape:

```julia
@api [docstring] name(a::T1, …; k::K = default, …)::Ret
```

A body fails at expansion, in both the `function … end` and the
`f(x) = …` form, as does a `where` clause. Writing a body would define a
function, and in a layer that imports the wrapped function by name it would
add a method to it instead — which recurses when the declared signature is the
more specific one.

The docstring is the macro's first argument, on the same line as `@api`. A
declaration without one falls back to the function's own Julia docstring, so
documenting the function the ordinary way is usually enough; give the macro an
argument when foreign callers need something different from what a Julia
caller reads.

The name a declaration refers to must already be callable with the declared
types — defined above it, or brought in from the package this layer wraps.
`@api` checks with `hasmethod` at expansion, so a typo or a signature the
function cannot serve is an error at that point rather than a missing method
when the library is compiled.

The Python name is the Julia function name, so it has to be a legal Python
identifier. A trailing `!`, the Julia convention for a mutating function, is
rejected at build time rather than emitted as `def bump!(…)`.

## Type table

Every argument must resolve, via [`carrier_type`](@ref), and the return type
via [`carrier_return_type`](@ref), to a C-ABI carrier. An unmapped type is an
expansion-time error naming the offending argument or the return. "Scalar"
below means one of `Int8`–`Int64`, `UInt8`–`UInt64`, `Float32`, `Float64`,
`Bool`; the carriers hold those elements as raw bytes behind a pointer, so
`Vector{Any}`, `Matrix{String}`, `Dict{String,Vector{Int}}` and a union of
scalars such as `Vector{Union{Int64,Float64}}` are rejected rather than
reinterpreted.

| Julia `T` | as argument | as return |
|---|---|---|
| `Int8`–`Int64`, `UInt8`–`UInt64`, `Float32`, `Float64`, `Bool` | itself, by value | itself, by value |
| `String` | `CString{:borrowed}`, the caller's bytes | `CString{:owned}`, a copy the caller frees |
| `Vector{String}` | `CStrArray{:borrowed}`, copied (Julia-side mutation is invisible to the caller) | `CStrArray{:owned}` |
| `Dict{String,V}` (`V` scalar) | `CDict{:borrowed,V}`, copied | `CDict{:owned,V}` |
| `Union{T,Nothing}` (`T` scalar) | [`COpt`](@ref), by value | [`COpt`](@ref), by value |
| `Array{T,N}` / `Vector{T}` / `Matrix{T}` (`T` scalar) | `CArray{:borrowed,T,N}`, a zero-copy view (`unsafe_wrap`, `own=false`) — mutation through the argument is visible to the caller | `CArray{:owned,T,N}`, a fresh allocation |
| `Nothing` (return only) | — | bare [`JLWStatus`](@ref), no `value` field |
| `Ptr{T}` | itself, by value | itself, by value |
| a type the library registers (see [Registering your own type](@ref)) | its own carrier | its own carrier |

Each carrier states its ownership in its type, so an argument and a return
of the same Julia type are two distinct carrier types and the release
obligation is visible in the wrapper's signature; see
[Owning carrier returns](@ref) in [JLWInterop](@ref) for what a target does
with each.

A `Ptr{T}` is the one row that carries nothing but the address: no length, no
element count, no ownership. The library reads and writes through it on the
caller's terms, and the caller keeps the memory alive for the duration of the
call. `Vector{T}` is the row to reach for when the length should travel with
the buffer.

Returning a `Ptr{T}` is allowed and puts the contract entirely in your hands.
The address must still be one the caller can reach after the call returns —
a pointer into a buffer it passed in, or into storage the library keeps. A
pointer into a fresh Julia allocation dangles once the collector runs, and one
into `Libc.malloc` memory leaks, because nothing on the Python side knows how
to free it. Return an `Array` when the caller should own the buffer: it gets a
length and a release path.

The [`examples/boundary`](https://github.com/JuliaInterop/JuliaLibWrapping.jl/tree/main/JuliaLibWrapping/examples/boundary)
example exercises every row except the multi-dimensional `Array{T,N}` form;
its arrays are all `Vector`s.

## Registering your own type

The mapping is a set of ordinary methods, so a library can extend it for a
type of its own. An `isbits` struct can be its own carrier: it already has a
C layout, and the three methods are the identity.

```julia
struct Extent
    lo::Int32
    hi::Int32
end

JLWInterop.carrier_type(::Type{Extent}) = Extent
JLWInterop.to_carrier(e::Extent) = e
JLWInterop.from_carrier(::Type{Extent}, c::Extent) = c

function widen(e::Extent, by::Int32)
    by >= 0 || error("negative width")
    return Extent(e.lo - by, e.hi + by)
end

@api "Widen an extent by `by` on both sides." widen(e::Extent, by::Int32)::Extent
```

The three methods must be defined before the `@api` that uses the type:
`@api` resolves the signature at expansion time. The struct must also be
`isbits`, as `Extent` is: a `mutable struct`, or one with a `String` or
`Vector` field, is rejected at expansion, because the error branch constructs
a zero-filled carrier. `Extent` then behaves like
any other row of the table — the wrapper is
`Base.@ccallable Boundary_widen(e::Extent, by::Int32)::JLWResult{Extent}`,
and the Python side gets a `ctypes.Structure` with the struct's fields:

```python
wide = widen(Extent(1, 5), 2)   # wide.lo == -1, wide.hi == 7
```

A carrier must be an `isbits` type. On the error branch the wrapper returns a
zero-filled carrier alongside the status, and zeroing a type with heap
references would produce a value Julia cannot hold.

Neither a `Ptr` nor a registered struct is converted on the Python side: the
façade passes what `ctypes` gives it straight through. What the annotation
still buys is the rest of `@api` — the Python name, the keyword arguments,
the docstring, and the `JLWResult` error boundary.

## Keyword arguments

A trailing `; k::K = default, …` block becomes Python keyword-only
parameters, in declaration order, appended after the positional C arguments.
A keyword with a default is optional in Python and keeps that default; one
without a default is required keyword-only, and omitting it raises
`TypeError`.

Defaults must be literals: `Int`, `Float`, `Bool`, `String`, or `nothing`
(a negated numeric literal such as `-1` or `-1.5` is accepted too). Anything
else — a symbol, an expression, `[]` — fails at expansion with
`keyword '<k>' default must be a literal`. The literal must also have the
keyword's declared type, so `k::Float64 = 2` is rejected and
`k::Float64 = 2.0` is accepted.

The default travels to the sidecar as a JSON value of its own type — a
number, a JSON string, `true`/`false`, or `null` — and the Python target
writes that value as a Python literal, `None` for `null`.

```julia
sum_dict(d::Dict{String,Float64}; scale::Float64 = 1.0) =
    scale * sum(values(d); init = 0.0)

@api sum_dict(d::Dict{String,Float64}; scale::Float64 = 1.0)::Float64
```

becomes `def sum_dict(d, *, scale=1.0)` in the generated façade.

## Errors

Every `@api` wrapper wraps its call in `try`/`catch`. A caught exception
becomes a [`JLWResult`](@ref) whose `status.code` names the exception type:

| code | exception | message |
|:--|:--|:--|
| 1 | `ErrorException`, and anything not listed below | `e.msg`, or the exception's type name |
| 2 | `ArgumentError` | `e.msg` |
| 3 | `DimensionMismatch` | `e.msg` |
| 4 | `InexactError` | `"InexactError"` |
| 5 | `BoundsError` | `"BoundsError"` |

A message is read only from a field already known to hold a `String` or a
`SubString{String}`: the wrapper runs inside the trimmed library, where
converting an `AbstractString` is a dynamic call the build rejects. Anything
else reports its type name, which needs no conversion.

The declared return type is applied to the returned value *inside* the
`try`, so a function whose actual return type differs from the declaration
reports that as an ordinary error rather than failing in the wrapper's own
return conversion, which the `catch` cannot reach.

On the Python side, a non-zero `status.code` raises `JLWError` (a
`RuntimeError` subclass carrying `.code` and `.message`); see
[Error handling across the ABI](@ref) for the `JLWStatus` convention that
`JLWResult` builds on.

```julia
boom(x::Int64) = error("boom $x")

@api "Always throws." boom(x::Int64)::Int64
```

```python
try:
    boom(3)
except JLWError as e:
    print(e.code, e.message)   # 1, "boom 3"
```

## Symbol naming

The generated C symbol is `join(fullname(mod), "_") * "_" * name`, with a
leading `Main` component stripped. `A.B.f` and `C.B.f` therefore produce
distinct symbols (`A_B_f`, `C_B_f`) even though `nameof` alone would
collide. The Python name is `name`, unqualified — it comes from the sidecar,
not the C symbol.

## The include-tree limitation

`build_library` dumps the metadata sidecar by spawning a subprocess that
`include`s the entry file and calls [`write_metadata`](@ref). `@api` must
therefore live in the entry file's include tree — a file `include`d, directly
or transitively, from the file passed to `build_library`. An `@api` inside a
package loaded with `using`/`import` does not register: its precompilation ran
in a different process, and the dump subprocess never re-executes that
package's top-level code, so no [`ApiEntry`](@ref) is pushed in the process
that writes the sidecar.

## Owning returns require `@export_release_entrypoints`

Owning `Vector{String}`, `Dict`, and array returns need the release
entrypoints described in [Owning carrier returns](@ref) in
[JLWInterop](@ref). `@api` does not emit them itself — a macro cannot know
which of its expansions is the last one in a library — so add one
`@export_release_entrypoints` at the library's top level:

```julia
module Boundary
using JLWInterop

@export_release_entrypoints

upcase_strs(a::Vector{String}) = uppercase.(a)
@api upcase_strs(a::Vector{String})::Vector{String}
end
```

Omitting it fails the build:

```
cannot wrap `@api` entrypoint 'Boundary_upcase_strs': owning return needs release entrypoints; add JLWInterop.@export_release_entrypoints to the library
```

The Python emitter cannot call a release symbol the library does not export,
and re-exporting the raw binding instead would quietly cost the function the
Python name, keyword arguments and docstring `@api` was asked for.

A hand-written `@ccallable` never appears in the sidecar, so it has none of
those to lose. It is re-exported with a `TODO` comment naming the macro:

```python
from ._lowlevel import Boundary_upcase_strs  # TODO: hand-wrap — owning return needs release entrypoints; add JLWInterop.@export_release_entrypoints to the library
```

## Build flow

```julia
result = build_library(
    joinpath(@__DIR__, "src/boundary.jl"),
    [PythonTarget(out, "boundary_py", "boundary")];
    project = @__DIR__, libname = "boundary", libdir = out,
)
```

runs, in order: a subprocess that includes `entry.jl` and writes
`boundary.jlw.json`; `juliac`, which writes `boundary.abi.json`; then the
Python target, which merges both by C symbol and writes `_facade.py`. A
symbol present in the ABI JSON with no sidecar entry falls back to the
mechanical, unnamed wrapping every entrypoint gets without `@api`.

The sidecar subprocess and `juliac` run independently and never see each
other's output; the Python target is the only place the two files come
together.

Both of them execute the entry file's top level, in two separate processes,
so that top level must be safe to run twice: it may define modules,
functions and constants, but not do work whose repetition would be wrong,
such as writing to a fixed output path or appending to a file.

`_facade.py` is written once and never regenerated — `write_wrapper` creates
it only when the file is absent, so an author's edits survive a rebuild.
After changing an `@api` signature, delete `_facade.py` and rerun; otherwise
the old wrapper keeps calling the regenerated `_lowlevel` with the old
argument list.

## Call path

```julia
scale(a::Vector{Float64}; factor::Float64 = 2.0) = factor .* a
@api scale(a::Vector{Float64}; factor::Float64 = 2.0)::Vector{Float64}
```

```python
scale(a, factor=3.0)
```

calls the generated `Boundary_scale`, which converts arguments, calls
`scale`, and returns a `JLWResult`. The façade checks `status.code`: zero
converts `value` to the idiomatic Python type, freeing an owning carrier in
a `finally`; non-zero raises `JLWError(status.code, status.message)`.

```@docs
@api
ApiEntry
api_entries
carrier_type
carrier_return_type
to_carrier
to_carrier_as
from_carrier
write_metadata
JLWResult
```

## Internals

Private helpers referenced by the docstrings above:

```@docs
to_carrier_opt
_api_symbol
_REGISTRY_NAME
_register!
_API_ERROR_CODES
_api_as
_julia_docstring
_zero_carrier
_api_opt_inner
```
