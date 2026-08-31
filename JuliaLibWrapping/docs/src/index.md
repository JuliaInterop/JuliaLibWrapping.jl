```@meta
CurrentModule = JuliaLibWrapping
```

# JuliaLibWrapping

[JuliaLibWrapping](https://github.com/JuliaInterop/JuliaLibWrapping.jl) turns
ordinary Julia functions into a shared library with a C header and an
installable Python `ctypes` package. ABI export requires Julia 1.13 or later.

For most libraries, the complete interface starts with a declaration like
this:

```julia
scale(a::Vector{Float64}; factor::Float64 = 2.0) = factor .* a
@api scale(a::Vector{Float64}; factor::Float64 = 2.0)::Vector{Float64}
```

`@api` creates the C-ABI entrypoint, converts arguments and results, transports
Julia exceptions safely, and records enough metadata to generate an idiomatic
Python function. Start with [Your first wrapper](@ref) to build and call a
small library end to end.

## Choose an authoring path

**Declare an API with `@api`** when you control the foreign interface. This is
the default path: write ordinary Julia functions and declare the signatures to
expose. Arrays, strings, string vectors, dictionaries, optional scalars, enums,
and primitive values have built-in mappings. See [Declaring an API with
`@api`](@ref) and [Supported Julia types](@ref).

**Write ABI entrypoints by hand** when an existing C header fixes the exact
signature, when the caller must provide output buffers, or when you deliberately
want a custom result struct and Python façade. See [Hand-written ABI
entrypoints](@ref) and the [custom OLS tutorial](@ref "Tutorial: design a custom
OLS ABI"). The two styles can coexist in one library.

## What the package produces

[JuliaC.jl](https://github.com/JuliaLang/JuliaC.jl) compiles the shared library
and emits ABI metadata. JuliaLibWrapping consumes that metadata and emits a C
header or Python package. [`standard_build`](@ref) drives the complete process
for a conventional project; [`build_library`](@ref) provides detailed control.

The Python output separates regenerated mechanical bindings from an
author-editable public façade. A bundled package can carry its own Julia
runtime, so its users do not need Julia installed. See [Generated Python
bindings](@ref) and [Building and distributing a library](@ref).

## Find a topic

- [Your first wrapper](@ref): the shortest path from a Julia function to an
  installed Python package.
- [Declaring an API with `@api`](@ref): signatures, keywords, enums, custom
  types, declaration placement, and errors.
- [Supported Julia types](@ref): the authoritative conversion and ownership
  table.
- [JLWInterop carriers](@ref): exact ABI layouts and memory contracts.
- [Architecture and metadata flow](@ref): how compilation and generation fit
  together.
- [API reference](@ref): public JuliaLibWrapping and JLWInterop APIs.
