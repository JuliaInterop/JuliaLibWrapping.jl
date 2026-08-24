```@meta
CurrentModule = JuliaLibWrapping
```

# JuliaLibWrapping

[JuliaLibWrapping](https://github.com/JuliaInterop/JuliaLibWrapping.jl)
generates C headers and Python `ctypes` bindings for shared libraries
compiled from Julia by [`juliac`](https://github.com/JuliaLang/JuliaC.jl).
It turns `juliac` ABI metadata into bindings for non-Julia callers.

New to the package? Start with the [tutorial](@ref "Tutorial: wrap an
OLS regression library") — it follows a small library from Julia source
through `pip install` to a Python API using NumPy arrays.

## The two-tool split

    juliac / JuliaC.jl --emits--> JSON ABI-info file --consumed by--> JuliaLibWrapping --emits--> .h / Python package

[JuliaC.jl](https://github.com/JuliaLang/JuliaC.jl) compiles the shared
library and emits a JSON file describing its ABI, but does not generate
wrappers. JuliaLibWrapping consumes that JSON and emits the wrappers.

[`build_library`](@ref) runs both stages in one call when JuliaC.jl is
loaded. See [Concepts](@ref) for details about the pipeline, bundling,
loading multiple libraries in one process, and generated Python files.

## Where to go next

- [Tutorial: wrap an OLS regression library](@ref): build a small library with a
  Python wrapper using numpy.
- [Concepts](@ref): the pipeline, the ABI data model, the extension
  point for new target languages, and runtime bundling.
- [JLWInterop](@ref): the package that defines shared ABI types (`CArray`,
  `CString`, and `JLWStatus`)
  for defining ABI-compatible Julia entrypoints.
- [Error handling across the ABI](@ref): the `JLWStatus` convention
  that lets wrapped libraries report errors as native exceptions in
  the target language.
- [API reference](@ref): the public API.
