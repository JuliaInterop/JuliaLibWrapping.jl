```@meta
CurrentModule = JuliaLibWrapping
```

# JuliaLibWrapping

[JuliaLibWrapping](https://github.com/JuliaInterop/JuliaLibWrapping.jl)
generates C headers and Python `ctypes` bindings for shared libraries
compiled from Julia by [`juliac`](https://github.com/JuliaLang/JuliaC.jl).
It turns the ABI metadata that `juliac` emits into wrappers that let
non-Julia programs call the compiled library as if it were any other
native dependency.

New to the package? Start with the [tutorial](@ref "Tutorial: wrap an
OLS regression library") — it walks a small library end to end, from
Julia source through `pip install` to numpy-flavored Python.

## Who it is for

Authors of Julia libraries who want to ship a compiled artifact that
downstream users — typically C or Python programmers — can consume
without installing a Julia runtime themselves. The compiled library is
produced by `juliac`; this package produces the binding code that makes
it usable from the target language.

## The two-tool split

The pipeline is split deliberately across two packages:

    juliac / JuliaC.jl --emits--> JSON ABI-info file --consumed by--> JuliaLibWrapping --emits--> .h / Python package

[JuliaC.jl](https://github.com/JuliaLang/JuliaC.jl) compiles the shared
library and emits a JSON file describing its ABI, but does not generate
wrappers. JuliaLibWrapping consumes that JSON and emits the wrappers.
Coupling between the two repos is the JSON format alone.

[`build_library`](@ref) runs both halves in one call when JuliaC.jl is
loaded; see [Concepts](@ref) for the pipeline architecture and the
bundling, multi-library, and two-tier output stories.

## Where to go next

- [Tutorial: wrap an OLS regression library](@ref) — the on-ramp:
  one library, end to end, from Julia source through `pip install`
  to numpy-flavored Python.
- [Concepts](@ref) — the pipeline, the ABI data model, the extension
  point for new target languages, and the runtime-closure / bundling
  story.
- [JLWInterop](@ref) — the dependency-free vocabulary package
  (`CVector`, `CMatrix`, `CString`, `JLWStatus`) that compiled
  libraries and the Python emitter both speak.
- [Error handling across the ABI](@ref) — the `JLWStatus` convention
  that lets wrapped libraries surface errors as native exceptions in
  the target language.
- [API reference](@ref) — generated docstrings for the public API.
