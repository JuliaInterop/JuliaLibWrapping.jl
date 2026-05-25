```@meta
CurrentModule = JuliaLibWrapping
```

# Concepts

This page describes the pipeline architecture, the data model that
flows through it, and the cross-cutting concerns (bundling, runtime
sharing, two-tier output) that shape the generated wrappers.

## The pipeline

The transformation from a Julia source file to a wrapper package runs
in three stages with an optional driver in front:

    source.jl
      │   juliac
      ▼
    lib<name>.so + <name>_abi.json
      │   read_abi_info → parse_abi_info → sort_declarations!
      ▼
    ABIInfo (descriptors in dependency order)
      │   write_wrapper(target, abi_info)
      ▼
    .h / Python package

[`build_library`](@ref) chains the whole sequence; the stages are also
callable individually when you want finer control or are testing the
emitters against fixture JSON.

## Driving the pipeline

[`build_library`](@ref) runs the full `juliac` → ABI JSON → wrapper
pipeline in one call:

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

`build_library` invokes `juliac` to produce the shared library and ABI
JSON, then applies [`write_wrapper`](@ref) to each target. The pipeline
is driven through [JuliaC.jl](https://github.com/JuliaLang/JuliaC.jl)
(a weak dependency): load it with `using JuliaC` before calling
`build_library`.

Relative `[sources]` paths in the entry project's `Project.toml` are
rejected up front, because `juliac` relocates the project into a
temporary directory before compiling.

## The ABI data model

`juliac` assigns every type an integer `type_id`. The JSON file
contains a flat list of type descriptors keyed by that id, plus a list
of exported entrypoint methods.

After parsing, an `ABIInfo` carries an `OrderedDict{Int, TypeDesc}` of
descriptors:

- `PrimitiveTypeDesc` — `Int32`, `Float64`, etc.
- `StructDesc` — a sequence of `FieldDesc`s referencing other type ids.
- `PointerDesc` — a pointer to another type id.

and a list of `MethodDesc`s whose `ArgDesc`s likewise reference types
by id. All cross-references use ids, not names; the descriptors form a
graph.

`sort_declarations!` is the conceptual core of the import stage. C
requires a type to be defined before use, so the dict must be sorted
into dependency order. The implementation builds the type-dependency
graph (Graphs.jl), finds strongly-connected components for
mutually-recursive types, drops the pointer edges within those SCCs to
make the graph acyclic, topologically sorts the result, and returns
the `forward_declared::BitSet` that the C emitter uses to insert
forward declarations.

## Emission targets

`AbstractTarget` is the extension point for new output formats. Each
concrete target is a configuration struct passed to
`write_wrapper(target, abi_info)`. Two backends ship today:

- [`CTarget`](@ref) — emits a single `.h` header. Primitive types map
  through a fixed `ctypes` table; non-primitive names go through
  `mangle_c!` to produce C-safe identifiers (memoized in a per-target
  `typedict`, with numeric suffixing on collision). Pointer types are
  emitted inline as `T*` rather than as separate typedefs.
- [`PythonTarget`](@ref) — emits a Python `ctypes` package with the
  two-tier layout described below.

Adding a new target means defining a struct subtype of `AbstractTarget`
and a method `write_wrapper(::YourTarget, ::ABIInfo)` that walks the
sorted descriptors and emits whatever your target language requires.

## Two-tier Python output

`write_wrapper(PythonTarget, …)` emits three files into the generated
package directory:

- `_lowlevel.py` — the mechanical `ctypes` bindings: `Structure`
  subclasses and functions carrying the raw C signature. **Always
  regenerated** on every `write_wrapper` call.
- `_facade.py` — the idiomatic surface that consumers of the package
  actually call. JuliaLibWrapping writes this **once** as a starter
  façade, then never touches it again. The starter is *not* a blank
  stub: any entrypoint whose arguments and return are all recognized —
  primitive scalars, `CVector{T}`, `CMatrix{T}`, `CString`, or a
  direct `JLWStatus` return — is auto-wrapped to accept and return
  idiomatic Python objects (numpy arrays, `str`). Entrypoints with a
  raw pointer, an unrecognized struct, or an embedded `JLWStatus`
  field are re-exported from `_lowlevel` and tagged with a `# TODO:
  hand-wrap` comment naming the obstacle. Edit anything freely; to
  regenerate (for example, after adding new entrypoints), delete the
  file and re-run `write_wrapper`.
- `__init__.py` — always regenerated; re-exports from `_facade` so the
  façade is the package's public surface.

The intent is that scientific users of the wrapped library import the
package top-level and see only the façade. The mechanical layer
remains available under `pkg._lowlevel` for power users who need it.

Recognition of `CVector` / `CMatrix` / `CString` / `JLWStatus` is
**structural** — by struct name plus field shape — so authors who
copy-paste a compatible definition into their own library still get
the same wrapper behavior.
[JLWInterop](https://github.com/JuliaInterop/JuliaLibWrapping.jl/tree/main/JLWInterop)
is the canonical source of these definitions; using it keeps libraries
from drifting out of structural compatibility.

## Bundling for distribution

A `juliac`-compiled `.so` is not self-contained: it links against
`libjulia`, depends on a sysimage, and pulls in stdlibs and JLL
artifacts. A Python user who runs `pip install` does not have any of
that on their machine, so the default flat `lib<name>.so`-next-to-the-
package layout fails at import time for the actual target audience.

Pass `bundle = true` to [`build_library`](@ref) to also assemble the
full runtime closure (the `juliac --bundle` layout) and copy it into
every [`PythonTarget`](@ref)'s package:

```julia
using JuliaLibWrapping, JuliaC
out = mktempdir()
result = build_library(
    joinpath(@__DIR__, "src/mylib.jl"),
    [PythonTarget(out, "mylib_py", "mylib"; bundle_subdir = "bundle")];
    project = @__DIR__,
    libname = "mylib",
    libdir  = out,
    bundle  = true,
)
```

The resulting package layout is

    out/mylib_py/
    ├── __init__.py
    ├── _facade.py
    ├── _lowlevel.py
    ├── pyproject.toml
    └── bundle/
        ├── lib/
        │   ├── libmylib.so       # user lib, RUNPATH=$ORIGIN/[/julia]
        │   ├── libjulia.so.1.13
        │   └── julia/…           # libjulia-internal, stdlibs, BLAS, …
        └── artifacts/…

The generated `_lowlevel.py` loader searches `bundle/lib/` before the
package root, so the `RUNPATH` baked in at link time resolves
`libjulia` and friends from inside the wheel — no `LD_LIBRARY_PATH`
and no Julia install required on the user's machine. A developer who
instead drops a bare `lib<name>.so` next to the package (without
bundling) still works: the loader falls back to the flat layout.

`pip install ./out/mylib_py` from a clean virtualenv on a machine
without a system Julia is the right manual check.

`bundle = true` requires the `:juliac` backend and that each
[`PythonTarget`](@ref) declare a `bundle_subdir`. The bundle itself is
multi-hundred-MB (mostly `libLLVM` and `libjulia-codegen`), so it is
opt-in. Pass `privatize = true` to additionally salt the bundled
`libjulia` files with a random prefix, avoiding any chance of collision
with a system `libjulia` loaded by the same process.

Wheel-level packaging (platform tags, `manylinux` audit) is out of
scope for the current MVP — `pyproject.toml` builds a generic
sdist/wheel and the developer is responsible for any platform tagging
the distribution target requires.

## Multiple wrapped libraries in one process

One JLW-wrapped library per Python process is the supported
configuration. If your users need to combine two Julia libraries,
compile them as a single `juliac` library that exports both APIs.

The reason is that `juliac` libraries embed `libjulia` as a runtime
dependency, and the Julia runtime is not designed to coexist with
another copy of itself in the same process. With the default bundle
layout each wheel ships its own `bundle/lib/libjulia.so.1.13`, but the
dynamic linker satisfies the second library's `DT_NEEDED
libjulia.so.1.13` with the first library's already-loaded copy — first
one wins. That silently "works" only when both libraries were built
against byte-compatible Julia versions and their sysimages don't
collide on global runtime state; mismatched versions may crash or
miscompute.

Passing `privatize = true` to [`build_library`](@ref) salts each
bundle's `libjulia` with a random SONAME prefix so the dynamic linker
maps both copies independently. That removes the silent-sharing
footgun at the linker layer, but two Julia runtimes in one process —
independent GC root sets, two thread pools, two BLAS trampoline
initializations, two signal handler registrations — is itself
untested territory. We have no evidence the combination is robust.

To make the situation loud rather than silent, every generated
`_lowlevel.py` records its package name on a process-global sentinel
(`sys._jlw_loaded_packages`) at import time and emits a
`RuntimeWarning` when a second JLW-wrapped package is imported into
the same process. Tracked as
[issue #28](https://github.com/JuliaInterop/JuliaLibWrapping.jl/issues/28).
