```@meta
CurrentModule = JLWInterop
```

# Annotating a library with `@api`

[`@api`](@ref) declares a C-ABI wrapper for an existing Julia function. It
also records the public name, parameters, and docstring for binding targets.
The named function must already accept the declared types. Hand-written
`@ccallable` wrappers can coexist with `@api`; see
[Two ways to write a library](@ref).

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

The macro stores entries in a `Vector{ApiEntry}` named
`_JLW_API_REGISTRY_` in the declaring module. This name is reserved.
[`api_entries`](@ref) gathers entries from a module and its submodules.

The declared types define the ABI contract; the Julia function may accept a
broader signature.

## Writing the signature

`@api` takes the signature apart at expansion time, so it accepts one shape:

```julia
@api [docstring] name(a::T1, …; k::K = default, …)::Ret
```

Bodies and `where` clauses are not supported. Define the function separately.

The docstring is the macro's first argument, on the same line as `@api`. A
declaration without one falls back to the function's own Julia docstring, so
documenting the function the ordinary way is usually enough; give the macro an
argument when foreign callers need something different from what a Julia
caller reads.

The function must be defined or imported before the declaration. `@api`
checks that it accepts the declared arguments during macro expansion.

The public name is the Julia function name. Targets may impose additional
identifier rules; for example, the Python target rejects a trailing `!`
rather than emitting `def bump!(…)`.

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

The `Array` argument's zero-copy view is valid only for the duration of the
call: a function that stores it for later use reads memory the caller may
have freed or repurposed by then. And because mutation is visible to the
caller, a caller must not pass read-only storage to a function that mutates
its argument. For example, this excludes a NumPy array with `writeable=False`.

A `Ptr{T}` carries only an address. The caller must keep its memory alive for
the call. Use `Vector{T}` when the length must cross the boundary.

Returning a `Ptr{T}` is allowed and puts the contract entirely in your hands.
The address must still be one the caller can reach after the call returns —
a pointer into a buffer it passed in, or into storage the library keeps. A
pointer into a fresh Julia allocation dangles once the collector runs, and one
into `Libc.malloc` memory leaks unless the target provides a matching release
contract. Return an `Array` when the caller should own the buffer: it gets a
length and a release path.

The [`examples/boundary`](https://github.com/JuliaInterop/JuliaLibWrapping.jl/tree/main/JuliaLibWrapping/examples/boundary)
example exercises every row except the multi-dimensional `Array{T,N}` form;
its arrays are all `Vector`s. Its declarations live in a binding layer beside
the package — see [Where the declarations live](@ref).

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

Define these methods before the `@api` declaration. The carrier must be
`isbits` because the error branch constructs a zero-filled value. The wrapper
is `Base.@ccallable Boundary_widen(e::Extent, by::Int32)::JLWResult{Extent}`,
and targets can expose its fields directly. For example, the Python target
generates a `ctypes.Structure`:

```python
wide = widen(Extent(1, 5), 2)   # wide.lo == -1, wide.hi == 7
```

Targets may pass a `Ptr` or registered struct through without conversion. The
current Python façade does so for `ctypes` values while still applying the
declared name, keyword arguments, docstring, and `JLWResult` error handling.

## Keyword arguments

A trailing `; k::K = default, …` block is appended to the positional C
arguments in declaration order. The metadata retains the positional/keyword
split and defaults so each target can express them in its own calling
conventions. For example, the Python target emits keyword-only parameters; a
keyword without a default is required.

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

A recognized `String` or `SubString{String}` message is preserved. Other
message types and unrecognized exceptions report the exception type name.

The declared return type is applied to the returned value *inside* the
`try`, so a function whose actual return type differs from the declaration
reports that as an ordinary error rather than failing in the wrapper's own
return conversion, which the `catch` cannot reach.

Targets decide how to report a non-zero `status.code`. The Python target
raises `JLWError`, a `RuntimeError` subclass carrying `.code` and `.message`.
See [Error handling across the ABI](@ref) for the underlying `JLWStatus`
convention.

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
collide. The sidecar also stores the unqualified public `name`, allowing a
target to expose it instead of the C symbol.

## Where the declarations live

A declaration defines nothing, so it does not have to sit in the package it
exposes. Two layouts work.

**A binding layer beside the package.** The package stays as it is, and a
second project holds the declarations:

```
Foo/
├── Project.toml          # what a Julia user installs — no JLWInterop dep
├── src/Foo.jl
└── lib/
    ├── Project.toml      # [sources] Foo = {path = ".."}
    └── src/foo.jl        # `using Foo: scale` + the @api declarations
```

`build_library` is pointed at `lib/`. The package gains no dependency and no
entrypoints, and someone who does not maintain it can still write its
bindings. Importing the wrapped functions by name is safe here precisely
because a declaration cannot define a method on them. Relative `[sources]`
paths are resolved by compiling a temporary copy with them made absolute, so
`lib/Project.toml` stays committable.
[`examples/boundary`](https://github.com/JuliaInterop/JuliaLibWrapping.jl/tree/main/JuliaLibWrapping/examples/boundary)
is built this way.

**Declarations inside the package.** Simpler, at the cost of a JLWInterop
dependency for every Julia user of the package and entry points compiled into
it.

## The include-tree limitation

`build_library` dumps the metadata sidecar by spawning a subprocess that
`include`s the entry file and calls [`write_metadata`](@ref). `@api` must
therefore live in the entry file's include tree — a file `include`d, directly
or transitively, from the file passed to `build_library`. An `@api` inside a
package loaded with `using`/`import` does not register: its precompilation ran
in a different process, and the dump subprocess never re-executes that
package's top-level code, so no [`ApiEntry`](@ref) is pushed in the process
that writes the sidecar.

This constrains the declarations, not the functions they name. In the
binding-layer form the declarations are in the entry file and the package is
an ordinary `using` dependency, which is what the rule asks for.

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

A target cannot automate ownership without the required release symbols. The
current Python target treats their absence as a build error for `@api`
entries rather than discarding the declared interface.

A hand-written `@ccallable` never appears in the sidecar, so the Python target
instead re-exports it with a `TODO` comment naming the macro:

```python
from ._lowlevel import Boundary_upcase_strs  # TODO: hand-wrap — owning return needs release entrypoints; add JLWInterop.@export_release_entrypoints to the library
```

## Python target example

```julia
result = build_library(
    joinpath(@__DIR__, "lib/src/boundary.jl"),
    [PythonTarget(out, "boundary_py", "boundary")];
    project = joinpath(@__DIR__, "lib"), libname = "boundary", libdir = out,
)
```

runs, in order: a subprocess that includes `entry.jl` and writes
`boundary.jlw.json`; `juliac`, which writes `boundary.abi.json`; then the
Python target, which merges both by C symbol and writes `_facade.py`. A
symbol present in the ABI JSON with no sidecar entry falls back to the
mechanical, unnamed wrapping every entrypoint gets without `@api`.

Both of them execute the entry file's top level, in two separate processes,
so that top level must be safe to run twice: it may define modules,
functions and constants, but not do work whose repetition would be wrong,
such as writing to a fixed output path or appending to a file.

`_facade.py` is written once and never regenerated — `write_wrapper` creates
it only when the file is absent, so an author's edits survive a rebuild.
After changing an `@api` signature, delete `_facade.py` and rerun; otherwise
the old wrapper keeps calling the regenerated `_lowlevel` with the old
argument list.

### Call path

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
_API_ERROR_TABLE
_api_status_expr
_api_as
_julia_docstring
_zero_carrier
_api_opt_inner
```
