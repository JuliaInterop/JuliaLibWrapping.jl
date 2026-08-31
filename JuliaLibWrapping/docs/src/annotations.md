```@meta
CurrentModule = JLWInterop
```

# Declaring an API with `@api`

[`@api`](@ref) declares a foreign-facing signature for an existing Julia
function. It generates a C-ABI entrypoint and records the semantic interface
used by binding targets: public and argument names, keyword defaults, enums,
and documentation.

Use `@api` when you control the foreign interface. Write a
`Base.@ccallable` entrypoint by hand when an existing C header fixes the exact
signature or when caller-managed buffers and custom result structs are
intentional parts of the API. See [Hand-written ABI entrypoints](@ref).

## Declaration syntax

The accepted form is:

```julia
@api [docstring] name(a::T1, …; k::K = default, …)::Ret
```

Define or import the function first. The declaration contains no body and does
not define another Julia method:

```julia
"Multiply every element by `factor`."
scale(a::Vector{Float64}; factor::Float64 = 2.0) = factor .* a

@api scale(a::Vector{Float64}; factor::Float64 = 2.0)::Vector{Float64}
```

The declared types define the ABI contract; the Julia method may accept a
broader signature. `@api` checks during expansion that the function accepts
the declared arguments and that every type has a carrier mapping. Bodies and
`where` clauses are not supported.

The public name is the Julia function name. Target-language identifier rules
still apply: for example, the Python target rejects a trailing `!` because it
cannot emit that spelling as a Python function.

## Generated boundary

For the `scale` declaration above, the generated boundary is equivalent in
shape to:

```julia
Base.@ccallable Boundary_scale(
    a::CArray{:borrowed,Float64,1},
    factor::Float64,
)::JLWResult{CArray{:owned,Float64,1}}
```

It converts arguments with [`from_carrier`](@ref), invokes `scale`, converts
the result with [`to_carrier`](@ref), and returns success via [`jlw_ok`](@ref).
A caught exception becomes [`jlw_error`](@ref). The precise C symbol includes
the declaring module path to avoid collisions; targets expose the unqualified
public name recorded in metadata.

See [Supported Julia types](@ref) for the complete argument, result, Python,
and ownership mappings.

## Documentation

A string immediately after `@api` supplies foreign-facing documentation:

```julia
@api "Scale an array and return a copy." scale(a::Vector{Float64})::Vector{Float64}
```

Without that argument, the declaration uses the function's Julia docstring.
Ordinary Julia documentation is therefore usually sufficient; give `@api` a
string when foreign callers need different wording.

## Keyword arguments

Keyword declarations follow the positional arguments and become trailing C
arguments in declaration order. Metadata retains the positional/keyword split
and defaults, allowing Python to generate keyword-only parameters:

```julia
sum_dict(d::Dict{String,Float64}; scale::Float64 = 1.0) =
    scale * sum(values(d); init = 0.0)

@api sum_dict(d::Dict{String,Float64}; scale::Float64 = 1.0)::Float64
```

The façade exposes this as `sum_dict(d, *, scale=1.0)`. A keyword without a
default is required.

Defaults must be literal integers, floats, booleans, strings, or `nothing`, and
their values must have the declared keyword type. Negated numeric literals are
accepted. Enum defaults may be bare or dotted member names resolved in the
declaring module. Arbitrary expressions are rejected because they cannot be
represented reliably in target metadata.

## Enums

Arguments and returns may use a concrete `Base.Enum` whose base is a supported
scalar. The metadata records the base type, member names, and values. The
Python target generates an `enum.IntEnum`; arguments accept a member, member
name, or valid integer, and returns are members. Invalid inputs raise
`ValueError` in Python. Optional enums are not currently mapped.

```julia
@enum RoundMode::Int32 round_nearest round_down round_up

round_value(x::Float64; mode::RoundMode = round_nearest) = x
@api round_value(x::Float64; mode::RoundMode = round_nearest)::Float64
```

## Errors

Every generated boundary wraps the call in `try`/`catch`. A caught exception
becomes a status with one of these codes:

| code | Julia exception |
|:--|:--|
| 1 | `ErrorException` or an unlisted exception |
| 2 | `ArgumentError` |
| 3 | `DimensionMismatch` |
| 4 | `InexactError` |
| 5 | `BoundsError` |

Recognized string messages are preserved within [`JLW_MESSAGE_BYTES`](@ref).
The Python façade raises `JLWError`, a `RuntimeError` subclass with `.code` and
`.message`. A `Nothing` return uses a bare `JLWStatus`; other returns use a
`JLWResult` containing both status and value.

The declared return conversion occurs inside the protected call, so a result
that does not satisfy the declaration is reported through the same error
boundary.

## Custom types

Carrier conversion is an extensible set of ordinary methods. An `isbits`
structure can serve as its own carrier:

```julia
struct Extent
    lo::Int32
    hi::Int32
end

JLWInterop.carrier_type(::Type{Extent}) = Extent
JLWInterop.to_carrier(e::Extent) = e
JLWInterop.from_carrier(::Type{Extent}, e::Extent) = e

widen(e::Extent, by::Int32) = Extent(e.lo - by, e.hi + by)
@api widen(e::Extent, by::Int32)::Extent
```

Define the mapping before the declaration. See [Registering a concrete
type](@ref) for the constraints and target behavior.

## Where declarations live

A declaration can live inside the package it exposes, but that makes
JLWInterop a dependency of the package for every Julia user. A separate
binding-layer project often keeps that concern isolated:

```
Foo/
├── Project.toml
├── src/Foo.jl
└── lib/
    ├── Project.toml       # [sources] Foo = {path = ".."}
    └── src/foo.jl         # imports Foo functions and declares @api entries
```

Point `build_library` at `lib/`. Relative `[sources]` paths are supported, so
the binding project stays committable. The
[`examples/boundary`](https://github.com/JuliaInterop/JuliaLibWrapping.jl/tree/main/JuliaLibWrapping/examples/boundary)
example uses this layout.

### Include-tree requirement

API metadata is collected by a subprocess that includes the entry file and
then calls [`write_metadata`](@ref). Declarations must therefore occur in the
entry file or a file it includes directly or transitively. A declaration in a
package merely loaded with `using` does not register in the metadata process,
because that package's top-level code may have run during precompilation rather
than in the collecting process.

This restriction applies only to declarations. They may name functions
imported normally from another package.

The entry file is also executed once for metadata collection and separately by
the compiler, so keep its top level safe to run twice. See [Configuring the
pipeline](@ref).

## Owning returns

An array, string, string-vector, or dictionary return transfers an allocation
to the foreign caller. Export the matching deallocation functions once at
module top level:

```julia
module Boundary
using JLWInterop

@export_release_entrypoints

upcase(a::Vector{String}) = uppercase.(a)
@api upcase(a::Vector{String})::Vector{String}

end
```

Omitting the macro is a build error for an annotated function with an owning
return. See [Ownership and release](@ref) for the complete contract.

## Updating a generated façade

The API metadata sidecar is regenerated during a build, as is the Python
low-level module. The public `_facade.py` is deliberately created only once so
author edits survive. After changing a declaration, generate a fresh façade
and merge the relevant update into the maintained file. See [Author-editable
façade](@ref).

The public declarations and conversion functions are collected in the
[JLWInterop API reference](@ref "JLWInterop").
