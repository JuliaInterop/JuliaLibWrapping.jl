```@meta
CurrentModule = JuliaLibWrapping
```

# Building and distributing a library

[`standard_build`](@ref) handles the conventional package layout. Use
[`build_library`](@ref) when you need to select targets, paths, bundling, or
other compilation options explicitly.

## Conventional build

For a project whose entry is `src/<libname>.jl`, this is normally enough:

```julia
push!(LOAD_PATH, joinpath(@__DIR__, "build-env"))
using JuliaLibWrapping, JuliaC

standard_build(@__DIR__; libname = "mylib", verbose = true)

pop!(LOAD_PATH)
```

The entry project should contain only dependencies needed at library runtime.
A separate build environment can contain JuliaLibWrapping and JuliaC. Loading
`JuliaC` activates JuliaLibWrapping's weak dependency; calling the build driver
without it produces a diagnostic pointing out the missing `using JuliaC`.

The conventional build emits a C header and a bundled Python package under
`out/`. Consult [`standard_build`](@ref) for its complete expansion.

## Configuring the pipeline

[`build_library`](@ref) accepts one or more output targets:

```julia
using JuliaLibWrapping, JuliaC

out = joinpath(@__DIR__, "out")
result = build_library(
    joinpath(@__DIR__, "src", "mylib.jl"),
    [
        CTarget(out, "mylib"),
        PythonTarget(out, "mylib_py", "mylib"; bundle_subdir = "bundle"),
    ];
    project = @__DIR__,
    libname = "mylib",
    libdir = out,
    bundle = true,
)
```

The result reports the library, ABI metadata, optional API metadata, generated
target outputs, backend, and bundle. `build_library` supports relative
`[sources]` paths in projects and manifests. It compiles from a temporary copy
with those paths made absolute, leaving the original project unchanged.

An entry file containing `@api` declarations is included once to collect API
metadata and compiled separately by `juliac`. Its top-level code must therefore
be safe to execute twice; definitions and constants are appropriate, while
append-only writes or other one-shot side effects are not.

## Bundling for distribution

A compiled Julia library depends on `libjulia`, a sysimage, standard libraries,
and artifacts. `bundle = true` asks JuliaC to assemble that runtime closure and
copies it into each Python target's declared `bundle_subdir`:

```
mylib_py/
├── __init__.py
├── _facade.py
├── _lowlevel.py
└── bundle/
    ├── lib/
    │   ├── libmylib.so
    │   ├── libjulia.so.1.13
    │   └── julia/…
    └── artifacts/…
```

The bundle is large—typically hundreds of megabytes—but allows installation
on a machine without Julia or `LD_LIBRARY_PATH` configuration. Test a
distribution with `pip install` in a clean virtual environment on such a
machine.

Bundling requires the `:juliac` backend and a `bundle_subdir` for every Python
target. Generated `pyproject.toml` metadata builds a generic sdist or wheel;
distributors remain responsible for platform tags and any required wheel
audit/repair tooling.

## Running in the host BLAS

A bundled library normally carries its own OpenBLAS. Pass `host_blas = true`
to run Julia's `LinearAlgebra` in a BLAS the host process has already loaded,
for example the OpenBLAS that PyPI NumPy ships. Julia and NumPy then share one
backend and one thread pool, and the bundle loses the BLAS it would otherwise
duplicate.

```julia
standard_build(@__DIR__; libname = "mylib", host_blas = true)
```

[`build_library`](@ref) compiles the takeover module into the same library,
prunes the OpenBLAS and gfortran/gomp libraries from the bundle, and leaves a
non-BLAS placeholder in the OpenBLAS slot so that `OpenBLAS_jll` still
initializes. The generated Python package gains a `_hostblas.py` hook that
runs at import time: it finds a loaded BLAS, calls the takeover, and raises a
Python exception when no compatible BLAS is available. The takeover entry
points stay out of the package façade.

The hook reads `/proc/self/maps`, and the prune replaces an ELF `.so`, so
`host_blas` is Linux-only. It also requires a single-file `entry` and an ILP64
host BLAS; a loaded LP64 BLAS is refused with a readable error. Set
`<PACKAGE_NAME>_HOST_BLAS` to the path of an ILP64 BLAS to override discovery.
Without `bundle = true` the takeover still runs, but the prune is skipped.

Import the host package before the wrapped one, so the BLAS is loaded when the
hook runs:

```python
import numpy as np
import mylib_py
```

## Multiple wrapped libraries in one process

Multiple APIs can be compiled into one Julia library. If they are built as
separate bundled libraries, use runtime privatization, which is enabled by
default for bundled builds.

Without privatization, the dynamic linker may satisfy a second library's
`libjulia` dependency with the first package's already loaded runtime. Both
libraries then try to initialize one runtime despite having separate sysimages;
the first library called works and the first call into the other may abort.

Privatization gives each bundle's `libjulia` and `libjulia-internal` pair
distinct names so each library initializes a separate runtime. The runtimes
have independent GC state, sysimages, and thread pools. Pass
`privatize = false` only when that isolation is knowingly unnecessary.

Only the Julia runtime libraries are privatized. BLAS, Fortran, and unwind
libraries may still be shared. Bundles produced by different Julia versions
have not been established as mutually compatible. This behavior has been
measured on Linux; macOS and Windows follow different loader rules and have
not been tested equivalently.
