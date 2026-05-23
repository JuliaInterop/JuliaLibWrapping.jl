```@meta
CurrentModule = JuliaLibWrapping
```

# JuliaLibWrapping

Documentation for [JuliaLibWrapping](https://github.com/JuliaInterop/JuliaLibWrapping.jl).

See [Error handling](@ref "Error handling across the ABI") for the
`JLWStatus` convention that lets wrapped libraries surface errors as native
exceptions in the target language.

## Driving the pipeline

[`build_library`](@ref) runs the full `juliac` → ABI JSON → wrapper pipeline
in one call:

```julia
using JuliaLibWrapping
using JuliaC
out = mktempdir()
result = build_library(
    joinpath(@__DIR__, "src/mylib.jl"),
    [CTarget(out, "mylib"), PythonTarget(out, "mylib_py", "mylib")];
    project = @__DIR__,
    libname = "mylib",
    libdir  = out,
)
```

`build_library` invokes `juliac` to produce the shared library and ABI JSON,
then applies [`write_wrapper`](@ref) to each target. The supported route is
[JuliaC.jl](https://github.com/JuliaLang/JuliaC.jl) (a weak dependency): load
it with `using JuliaC` before calling `build_library`. ABI developers who want
to try features ahead of JuliaC.jl can opt into the unstable in-tree
`share/julia/juliac/juliac.jl` script by passing `backend = :script`.

Relative `[sources]` paths in the entry project's `Project.toml` are rejected
up front, because `juliac` relocates the project into a temporary directory
before compiling.

## Two-tier Python output

`write_wrapper(PythonTarget, …)` emits three files into the generated package
directory:

- `_lowlevel.py` — the mechanical `ctypes` bindings: `Structure` subclasses
  and functions carrying the raw C signature. **Always regenerated** on
  every `write_wrapper` call.
- `_facade.py` — the idiomatic surface that consumers of the package
  actually call. JuliaLibWrapping writes this **once** as a starter façade,
  then never touches it again. The starter is *not* a blank stub: any
  entrypoint whose arguments and return are all recognized — primitive
  scalars, `CVector{T}`, `CMatrix{T}`, `CString`, or a direct `JLWStatus`
  return — is auto-wrapped to accept and return idiomatic Python objects
  (numpy arrays, `str`). Entrypoints with a raw pointer, an unrecognized
  struct, or an embedded `JLWStatus` field are re-exported from `_lowlevel`
  and tagged with a `# TODO: hand-wrap` comment naming the obstacle.
  Edit anything freely; to regenerate (for example, after adding new
  entrypoints), delete the file and re-run `write_wrapper`.
- `__init__.py` — always regenerated; re-exports from `_facade` so the
  façade is the package's public surface.

The intent is that scientific users of the wrapped library import the
package top-level and see only the façade. The mechanical layer remains
available under `pkg._lowlevel` for power users who need it.

```@index
```

```@autodocs
Modules = [JuliaLibWrapping]
```
