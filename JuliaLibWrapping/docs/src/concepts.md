```@meta
CurrentModule = JuliaLibWrapping
```

# Concepts

This page describes the pipeline, data model, bundling, and generated files.

## The pipeline

Wrapper generation has three stages:

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
callable individually when you need to configure each stage or test the
emitters against fixture JSON.

## Two ways to write a library

A library's entrypoints can be written either by hand or generated.
Hand-writing a `Base.@ccallable` function, as described in the rest of this
page and in [Error handling across the ABI](@ref), gives full control over the
C ABI, which is what a signature an outside header fixes needs — `@api`
always returns a `JLWResult` or a `JLWStatus`.
[`JLWInterop.@api`](@ref) generates the same kind of wrapper from a declared
call signature of an ordinary Julia function: the C symbol, the argument and
return conversions, and `JLWResult` error reporting all come from the declared
signature, and the wrapper's public name, keyword arguments, and docstring
reach binding targets through a metadata sidecar. The declaration defines
nothing itself, so it can sit in a binding layer around a package it does not
own. See [Annotating a library with `@api`](@ref) for the type table and
rules. The two styles coexist in one library.

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

`build_library` supports relative `[sources]` paths, including paths in
manifests for developed dependencies. It compiles from a temporary copy
with absolute paths because `juliac` relocates the project before
compiling. The original project is unchanged.

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

`sort_declarations!` orders the imported declarations. C
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
The carrier recognizers in `src/recognizers.jl` (`carray_struct_info`,
`cstring_struct_info`, `is_jlwstatus_struct`, and friends) decide whether a
`StructDesc`/`MethodDesc` matches a JLWInterop carrier shape by inspecting
`ABIInfo`/`TypeDesc` alone, so a new target can reuse them as-is instead of
reimplementing shape detection.

## Generated and editable Python modules

`write_wrapper(PythonTarget, …)` emits three files into the generated
package directory:

- `_lowlevel.py` — the mechanical `ctypes` bindings: `Structure`
  subclasses and functions carrying the raw C signature. **Always
  regenerated** on every `write_wrapper` call. Each `Structure` class is
  followed by a layout check comparing the size and field offsets ctypes
  computed against the ones the library was compiled with (from the ABI
  JSON); a divergence raises at import instead of silently misreading
  fields. It also defines enums declared in the `@api` metadata (see
  [Enums](@ref)).
- `_facade.py` — the package's public API. JuliaLibWrapping creates this
  file only if it does not exist. Its initial version wraps entrypoints whose
  arguments and return are recognized — primitive scalars,
  `CVector{owned,T}`, `CMatrix{owned,T}`, `CString{owned}`, or a direct
  `JLWStatus` return — is auto-wrapped to accept and return
  idiomatic Python objects (numpy arrays, `str`). Entrypoints with a
  raw pointer, an unrecognized struct, or an embedded `JLWStatus`
  field are re-exported with a `# TODO: hand-wrap` comment. Delete the file and
  rerun `write_wrapper` to regenerate it.
- `__init__.py` — always regenerated; re-exports names from `_facade`.

Users normally import the package-level API from `_facade`. The generated
bindings remain available under `pkg._lowlevel` when direct access is needed.

Recognition of `CArray`, `CString`, and `JLWStatus` matches the type name,
ownership parameter (where present), and field layout. Use
[JLWInterop](https://github.com/JuliaInterop/JuliaLibWrapping.jl/tree/main/JLWInterop)
for their canonical definitions.

## Bundling for distribution

A `juliac` library depends on `libjulia`, a sysimage, stdlibs, and artifacts.

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

The loader searches `bundle/lib/` before the package root, allowing bundled
installs without Julia or `LD_LIBRARY_PATH`. It falls back to a library beside
the package.

`pip install ./out/mylib_py` from a clean virtualenv on a machine
without a system Julia is the right manual check.

`bundle = true` requires the `:juliac` backend and that each
[`PythonTarget`](@ref) declare a `bundle_subdir`. The bundle is several
hundred megabytes (mostly `libLLVM` and `libjulia-codegen`), so it is
opt-in. Bundling also salts the bundled `libjulia` files so they cannot
be satisfied by another `libjulia` already loaded in the process; pass
`privatize = false` to turn that off — see [Multiple wrapped libraries in
one process](@ref).

`pyproject.toml` builds a generic sdist/wheel; distributors must supply any
required platform tags or audits.

## Multiple wrapped libraries in one process

To use multiple wrapped APIs in one process, either compile them into one
`juliac` library or build each bundled library with `privatize`, the default
for bundled builds.

`juliac` libraries embed `libjulia` as a runtime dependency. With the
default bundle layout each wheel ships its own
`bundle/lib/libjulia.so.1.13`, but the dynamic linker satisfies the second
library's `DT_NEEDED libjulia.so.1.13` from the first loaded copy. Both
libraries then address one runtime, but each expects to initialize it. Imports
succeed because initialization is deferred until the first entrypoint call;
the first library called works, and the first call into the other aborts the
process.

`privatize` gives each bundle's `libjulia` and `libjulia-internal` a distinct
SONAME prefix. The loader then maps each pair independently, and each library
initializes its own runtime. The runtimes have separate GC state and resolve
runtime symbols to separate addresses.

Two limits apply to that arrangement:

- **Only the Julia runtime is privatized.** `libopenblas`,
  `libblastrampoline`, `libgfortran`, and `libunwind` keep their usual names
  and may be shared. Bundles built by the same Julia contain identical copies;
  bundles built by different Julia versions have not been tested together.
- **Each runtime uses its own resources.** Two sysimages, two GC heaps, and
  two thread pools are resident at once.

This behavior was measured on Linux. macOS and Windows use different library
resolution rules and have not been tested.

At import time, generated `_lowlevel.py` files record their package names in
`sys._jlw_loaded_packages`. A non-privatized package emits a `RuntimeWarning`
if another wrapped package is already present. Privatized packages do not warn.
