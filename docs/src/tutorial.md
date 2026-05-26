```@meta
CurrentModule = JuliaLibWrapping
```

# Tutorial: wrap an OLS regression library

This walks through the full pipeline end to end: write a small Julia
library, run [`build_library`](@ref) to compile it and emit wrappers,
`pip install` the generated package, and call it from Python. The
worked example lives in `examples/ols/` and stays buildable as the
package evolves.

The subject is ordinary least squares (OLS) regression, which exercises several
[JLWInterop](https://github.com/JuliaInterop/JuliaLibWrapping.jl/tree/main/JLWInterop)
types:

| JLWInterop type            | Where it appears in `ols`            |
|----------------------------|--------------------------------------|
| `CMatrix{Float64}`         | design matrix `X`                    |
| `CVector{Float64}`         | response `y`, coefficients, predictions |
| `Float64` (primitive)      | `r_squared`                          |
| `CString`                  | output buffer for `summary_report`   |
| `JLWStatus` (direct)       | return of `predict`                  |
| `JLWStatus` (embedded)     | `FitResult.status` field             |

`CMatrix` and `CVector` are specific cases of `CArray`, the multi-dimensional
array type in JLWInterop.

The core of the algorithm is a single statement, `X \ y`, using Julia's own
LinearAlgebra for computation.

## 1. The Julia source

`examples/ols/src/ols.jl` defines three [`Base.@ccallable`] entrypoints
on top of JLWInterop's vocabulary:

```julia
module ols

using JLWInterop
using LinearAlgebra

struct FitResult
    status::JLWStatus
    coeffs::CVector{Float64}
    r_squared::Float64
end

Base.@ccallable function fit(X::CMatrix{Float64},
                              y::CVector{Float64},
                              coeffs_buf::CVector{Float64})::FitResult
    # … shape checks, then `coeffs = X \\ y`; copy into `coeffs_buf`,
    # compute R^2, and return FitResult with JLWStatus(0,…) on success
    # or JLWStatus(code, msg) on a recognized failure.
end

Base.@ccallable function predict(coeffs::CVector{Float64},
                                  X::CMatrix{Float64},
                                  out::CVector{Float64})::JLWStatus

Base.@ccallable function summary_report(result::FitResult,
                                         buf::CString)::JLWStatus
```

`coeffs_buf` and `out` are *caller-allocated* buffers: the library
writes into them but does not own them. This is the same discipline
JLWInterop documents for all its pointer-bearing types, notably
`CArray` and `CString`.

Errors travel back as a `JLWStatus`,
either returned directly (`predict`, `summary_report`) or embedded in
a return struct (`fit`'s `FitResult`). The Python emitter recognizes
both forms and translates a non-zero `code` into a
`JLWError` exception — see [Error handling](@ref "Error handling
across the ABI").

## 2. The entry `Project.toml`

A minimal `Project.toml` for the library:

```toml
name = "ols"
uuid = "7e81292c-b63a-42d7-9477-255b6fedc2ed"
version = "0.0.1"

[deps]
JLWInterop = "65e54657-ed21-41a3-96db-71ab7fa6d94b"
LinearAlgebra = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"

[compat]
JLWInterop = "0.1"
julia = "1.13"
```

There are two things to point out:

- The requirement for `julia = "1.13"` cannot be changed to an earlier Julia
  release, as the features needed to build language bindings shipped in Julia
  1.13. The OLS example here calls into BLAS via `\`, and that path needs Julia
  1.13.0-rc2 or later (or any build of the `backports-release-1.13` branch from
  2026-05-20 onward).

- The `[deps]` here describe what must be baked into `ols.so`. Keep it minimal,
  without build tooling or test dependencies. If you need a `[sources]` entry to
  point at a local checkout, use an absolute path: `juliac` relocates the
  project into a temporary directory before compiling, so relative `[sources]`
  paths cannot be resolved, and [`build_library`](@ref) rejects them.

## 3. Build the library and Python package

Two distinct environments are in play during a build:

- The **entry project** (`examples/ols/Project.toml`, activated by
  `julia --project=.`) declares the runtime deps just described.
- A **build-env** (`examples/ols/build-env/Project.toml`) declares the
  build tooling — [JuliaLibWrapping](https://github.com/JuliaInterop/JuliaLibWrapping.jl)
  and [JuliaC](https://github.com/JuliaLang/JuliaC.jl). `build.jl` pushes
  this directory onto `LOAD_PATH` so that `using JuliaLibWrapping`
  resolves there. Keeping the build tooling out of the entry project's
  `[deps]` is what lets your library remain reasonably minimal.

The build-env's `Project.toml` is just:

```toml
[deps]
JuliaC = "acedd4c2-ced6-4a15-accc-2607eb759ba2"
JuliaLibWrapping = "d61f35a8-f6af-436f-bc10-cee6b101f7bd"

[compat]
JuliaC = "0.3"
JuliaLibWrapping = "0.1"
julia = "1.13"
```

Instantiate it once:

```sh
julia --project=examples/ols/build-env -e 'using Pkg; Pkg.instantiate()'
```

To handle the two-environment split, we'll push `build-env` onto `LOAD_PATH`,
making it reachable, and then pop it again once the build concludes.
Here is the `build.jl` script:

```julia
push!(LOAD_PATH, joinpath(@__DIR__, "build-env"))
using JuliaLibWrapping, JuliaC

standard_build(@__DIR__; libname = "ols", verbose = true)
pop!(LOAD_PATH)
```

`using JuliaC` is what activates JuliaLibWrapping's weak dependency on
[JuliaC.jl](https://github.com/JuliaLang/JuliaC.jl); without it
[`build_library`](@ref) errors with a hint pointing at this line.

[`standard_build`](@ref) is a convenience wrapper around
[`build_library`](@ref) for the conventional layout — `src/<libname>.jl`
as the entry, `out/` as the artifact directory, both a C header and a
bundled Python `ctypes` package named `<libname>_py`. For layouts
outside that convention, or to drop one of the targets, call
[`build_library`](@ref) directly; `standard_build`'s docstring shows
the equivalent expansion.

Then run the build:

```sh
cd examples/ols
julia --project=. build.jl
```

After a successful build, `out/` contains:

    out/
    ├── ols.so              # compiled shared library
    ├── ols.abi.json        # ABI metadata emitted by juliac
    ├── ols.h               # C header (CTarget output)
    ├── pyproject.toml      # Python package metadata
    └── ols_py/
        ├── __init__.py
        ├── _lowlevel.py    # mechanical ctypes bindings (regenerated every build)
        ├── _facade.py      # idiomatic surface (written once; user-editable)
        └── bundle/         # juliac --bundle tree: libjulia, stdlibs, BLAS, …

`bundle = true` is essential for a `pip install` user who has no
Julia on their machine. See the bundling section of the
[overview](@ref "Bundling for distribution") for what is in the bundle
tree and how the loader finds `libjulia` from inside the wheel.

## 4. Install the Python package

Create a clean virtualenv with no system Julia, and install:

```sh
python -m venv /tmp/ols-venv
source /tmp/ols-venv/bin/activate
pip install numpy
pip install ./examples/ols/out/
```

The bundled `libjulia` and stdlibs live inside the wheel; the loader
in `_lowlevel.py` searches `bundle/lib/` first so the baked-in
`RUNPATH` resolves them at import time, with no `LD_LIBRARY_PATH`
required.

## 5. Call it from Python

To verify that things work, first we'll try calling `predict`, which is
auto-wrapped because its arguments and return are all recognized as known types
to JuliaLibWrapping's emitter. We'll call `predict` twice, once with correct
inputs and once with incorrect ones to verify that errors work as expected:

```python
import numpy as np
from ols_py import predict, JLWError

coeffs = np.array([0.06, 1.98])
X = np.asfortranarray(np.column_stack([np.ones(5), np.arange(1.0, 6.0)]))
out = np.zeros(5)
predict(coeffs, X, out)
# out is now X @ coeffs

try:
    bad = np.asfortranarray(np.zeros((5, 3)))   # wrong number of columns
    predict(coeffs, bad, out)
except JLWError as e:
    print(e.code, e.message)   # 1, "coeffs length must match X cols"
```

`np.asfortranarray` is required for any `CMatrix{T}` argument: JLWInterop's
`CArray` is column-major, and the automatically created façade rejects a
row-major view rather than silently transposing. In a moment you'll
see how to edit the wrapper, so you can choose any interface you wish.

In contrast with `predict`, `fit` is not automatically wrapped: it returns a
`FitResult`, and JuliaLibWrapping declines to make choices about what that
should look like from the Python perspective. The starter façade re-exports it
from `_lowlevel` with a `TODO: hand-wrap` comment naming the obstacle. You edit
`_facade.py` to provide the wrapper you want. The mechanical layer still raises
`JLWError` on a non-zero status, so a sklearn-flavored hand wrap is just:

```python
# in ols_py/_facade.py, replacing the auto-generated TODO line
def fit(X, y):
    X = np.asfortranarray(X)
    y = np.ascontiguousarray(y, dtype=np.float64)
    coeffs = np.zeros(X.shape[1])
    result = _lowlevel.fit(
        _lowlevel.CMatrix_Float64.from_numpy(X),
        _lowlevel.CVector_Float64.from_numpy(y),
        _lowlevel.CVector_Float64.from_numpy(coeffs),
    )
    return coeffs, float(result.r_squared)
```

`summary_report` is also a hand-wrap case (its `FitResult` argument
is an unrecognized struct). The caller allocates a writable
`CString` buffer, passes it in, and decodes the bytes after the call:

```python
def summary(result_struct, capacity=256):
    import ctypes
    buf_bytes = (ctypes.c_uint8 * capacity)()
    buf = _lowlevel.CString(
        length=capacity,
        data=ctypes.cast(buf_bytes, ctypes.POINTER(ctypes.c_uint8)),
    )
    _lowlevel.summary_report(result_struct, buf)
    return bytes(buf_bytes).rstrip(b"\x00").decode("utf-8")
```

## 6. Adding an entrypoint later

When you add a new `Base.@ccallable` to `ols.jl`:

- `_lowlevel.py` is **regenerated on every** `write_wrapper` /
  `build_library` call — your new entrypoint shows up automatically.
- `_facade.py` is **written once** and then never touched. To pick
  up new entrypoints in the starter façade, delete the file and
  rebuild; JuliaLibWrapping will regenerate it (auto-wrapping where
  it can, leaving `# TODO: hand-wrap` markers where it cannot).
- `__init__.py` is regenerated to re-export from `_facade`.

A common pattern is to keep `_facade.py` checked into your own repository
alongside the build script, treating it as hand-written glue. If you need to
automatically wrap new functions, currently the best option is to create a
branch in which you delete it, regenerate it with a fresh build, and then copy
the new pieces you want to keep into your existing hand-edited `_facade.py` and
make any additional edits needed for the new code.
