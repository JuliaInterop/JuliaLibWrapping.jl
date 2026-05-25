```@meta
CurrentModule = JuliaLibWrapping
```

# Tutorial: wrap an OLS regression library

This walks through the full pipeline end to end: write a small Julia
library, run [`build_library`](@ref) to compile it and emit wrappers,
`pip install` the generated package, and call it from Python. The
worked example lives in `examples/ols/` and stays buildable as the
package evolves.

The subject is ordinary least squares (OLS) regression. The algorithm
is incidental — what matters is that one library exercises every
recognized [JLWInterop](https://github.com/JuliaInterop/JuliaLibWrapping.jl/tree/main/JLWInterop)
type:

| Vocabulary type            | Where it appears in `ols`            |
|----------------------------|--------------------------------------|
| `CMatrix{Float64}`         | design matrix `X`                    |
| `CVector{Float64}`         | response `y`, coefficients, predictions |
| `Float64` (primitive)      | `r_squared`                          |
| `CString`                  | output buffer for `summary_report`   |
| `JLWStatus` (direct)       | return of `predict`                  |
| `JLWStatus` (embedded)     | `FitResult.status` field             |

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
JLWInterop documents for all its pointer-bearing types — see
`CArray` and `CString`.

Errors travel back as a `JLWStatus`,
either returned directly (`predict`, `summary_report`) or embedded in
a return struct (`fit`'s `FitResult`). The Python emitter recognizes
both forms and translates a non-zero `code` into a
`JLWError` exception — see [Error handling](@ref "Error handling
across the ABI").

!!! note "About the algorithm"
    `fit` is a one-liner: `coeffs = X \\ y`. The interesting story is
    the wrapping, not the math. Production code with many predictors,
    rank-deficient inputs, or weighting concerns would substitute a
    proper factorization — the wrapping contract (`CMatrix{Float64}`
    in, caller-allocated `CVector{Float64}` out, `JLWStatus` for
    failures) does not change.

## 2. The entry `Project.toml`

A minimal `Project.toml` for the library:

```toml
name = "ols"
uuid = "7e81292c-b63a-42d7-9477-255b6fedc2ed"
version = "0.0.1"

[deps]
JLWInterop = "65e54657-ed21-41a3-96db-71ab7fa6d94b"
LinearAlgebra = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"

[sources]
JLWInterop = {path = "/absolute/path/to/JuliaLibWrapping/JLWInterop"}

[compat]
JLWInterop = "0.1"
julia = "1.13"
```

Two things to call out:

- The `julia = "1.13"` floor is mandatory; the `juliac` feature that
  emits the ABI JSON shipped in Julia 1.13.
- `[sources]` paths must be **absolute**. `juliac` relocates the
  project into a temporary directory before compiling, so a relative
  path cannot be resolved. [`build_library`](@ref) rejects relative
  `[sources]` up front with a clear error.

The in-tree `examples/ols/Project.toml` deliberately omits `[sources]`
so the file does not bake in a machine-specific path; its `build.jl`
instead materializes a transient project in a temp directory with
`[sources]` computed from `@__DIR__` and passes that as the `project=`
argument to [`build_library`](@ref). Authoring a fresh library, you
would normally just write `[sources]` once with your local absolute
path.

## 3. Build the library and Python package

`examples/ols/build.jl` is the driver:

```julia
using JuliaLibWrapping
using JuliaC

const HERE  = @__DIR__
const OUT   = joinpath(HERE, "out")
const ENTRY = joinpath(HERE, "src", "ols.jl")

result = build_library(ENTRY,
    [CTarget(OUT, "ols"),
     PythonTarget(OUT, "ols_py", "ols"; bundle_subdir = "bundle")];
    project = HERE,
    libname = "ols",
    libdir  = OUT,
    bundle  = true,
    verbose = true,
)
```

Run it with the Julia 1.13 release candidate:

```sh
cd examples/ols
julia +rc --project=. build.jl
```

`JuliaLibWrapping` and `JuliaC` need to be loadable — typically
`Pkg.develop` them into your global v1.13 environment, so the entry
project's stripped-down `[deps]` (just `JLWInterop`) reflects the
*runtime* dependencies of the compiled library rather than the build
tooling.

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

The default backend is `:juliac` (via [JuliaC.jl](https://github.com/JuliaLang/JuliaC.jl));
ABI developers chasing features ahead of JuliaC.jl can opt into the
unstable in-tree `share/julia/juliac/juliac.jl` script via
`backend = :script`.

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

`predict` is auto-wrapped — its arguments and return are all
recognized, so the façade accepts numpy arrays and raises `JLWError`
on a non-zero status:

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

`np.asfortranarray` is required for any `CMatrix{T}` argument:
JLWInterop's `CArray` is column-major, and the façade rejects a
row-major view rather than silently transposing.

`fit` returns a `FitResult` struct that *contains* a `JLWStatus`.
The emitter doesn't know how to shape that idiomatically (numpy of
`coeffs`? a tuple? the whole struct?), so the starter façade
re-exports it from `_lowlevel` with a `TODO: hand-wrap` comment
naming the obstacle. You edit `_facade.py` to provide the wrapper
you want. The mechanical layer still raises `JLWError` on a non-zero
status, so a sklearn-flavored hand wrap is just:

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

A common pattern is to keep `_facade.py` checked into your own
repository alongside the build script, treating it as hand-written
glue that occasionally absorbs new auto-wrappers when you delete
and regenerate it.
