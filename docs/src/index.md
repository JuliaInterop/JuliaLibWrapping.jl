```@meta
CurrentModule = JuliaLibWrapping
```

# JuliaLibWrapping

Documentation for [JuliaLibWrapping](https://github.com/JuliaInterop/JuliaLibWrapping.jl).

See [Error handling](@ref "Error handling across the ABI") for the
`JLWStatus` convention that lets wrapped libraries surface errors as native
exceptions in the target language.

## Two-tier Python output

`write_wrapper(PythonTarget, …)` emits three files into the generated package
directory:

- `_lowlevel.py` — the mechanical `ctypes` bindings: `Structure` subclasses
  and functions carrying the raw C signature. **Always regenerated** on
  every `write_wrapper` call.
- `_facade.py` — the idiomatic surface that consumers of the package
  actually call. JuliaLibWrapping writes this **once** as a starter stub
  that re-exports every public name from `_lowlevel`, then never touches
  it again. Edit it freely — wrap mechanical entrypoints with numpy-friendly
  signatures, hide bookkeeping structs, package multi-return values, etc.
  To regenerate the stub (for example, after adding new entrypoints), delete
  the file and re-run `write_wrapper`.
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
