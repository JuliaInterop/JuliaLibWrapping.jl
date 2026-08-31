```@meta
CurrentModule = JuliaLibWrapping
```

# Architecture and metadata flow

JuliaLibWrapping connects JuliaC's compilation metadata to language-specific
binding targets:

```
Julia source
    │
    ├── @api metadata collection ───────────────┐
    │                                           │
    └── JuliaC / juliac                         │
            │                                   │
            ├── shared library                  │
            └── ABI JSON                        │
                    │                           │
                    └── JuliaLibWrapping ◀──────┘
                              │
                              ├── C header
                              └── Python package
```

The ABI JSON describes exported C symbols and exact binary layouts. The
optional `.jlw.json` sidecar records information that ABI introspection cannot
recover: public names, argument names, keyword boundaries and defaults,
docstrings, and enums. Targets merge the two by C symbol.

## Two authoring layers

[`JLWInterop.@api`](@ref) starts from a Julia-level signature. It selects ABI
carriers, creates the `@ccallable` boundary, catches exceptions, and records
the semantic API metadata. This is the high-level path.

A hand-written `Base.@ccallable` starts at the ABI itself. It gives complete
control over argument layouts, output buffers, results, and status placement,
but targets see only the mechanical ABI metadata. The author supplies any
language-specific policy the ABI does not express.

Both ultimately produce ordinary C ABI entrypoints and can coexist in the
same compiled library.

## Generation stages

[`build_library`](@ref) chains three independently usable stages:

1. JuliaC compiles the entry source and emits the library and ABI JSON.
2. [`read_abi_info`](@ref) parses descriptors and orders declarations by their
   dependencies.
3. [`write_wrapper`](@ref) passes the normalized [`ABIInfo`](@ref) to each
   target, together with API metadata when available.

Calling the stages separately is useful for testing an emitter against a
fixture or integrating generation into a custom build system. Most library
authors should use `standard_build` or `build_library` instead.

## Output targets

[`CTarget`](@ref) emits a header containing typedefs and function declarations.
It exposes ownership through distinct carrier type names but otherwise keeps
the ABI mechanical.

[`PythonTarget`](@ref) emits low-level `ctypes` bindings plus a public façade.
It recognizes JLWInterop carriers structurally, verifies struct layouts at
import, converts declared values to Python types, raises `JLWError` for status
failures, and manages owning results.

See [Extending JuliaLibWrapping](@ref) for the descriptor graph and target
extension interface.
