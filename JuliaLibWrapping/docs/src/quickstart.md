```@meta
CurrentModule = JuliaLibWrapping
```

# Your first wrapper

This tutorial exposes an ordinary Julia function as C and Python, builds a
redistributable library, installs its Python package, and calls it with a NumPy
array. It uses [`JLWInterop.@api`](@ref), the recommended starting point when
you control the foreign interface.

## 1. Create the library project

Use a small binding project with this layout:

```
mylib/
├── Project.toml
├── build.jl
├── build-env/
│   └── Project.toml
└── src/
    └── mylib.jl
```

`Project.toml` contains only dependencies compiled into the library:

```toml
name = "mylib"
uuid = "12b3f49a-b5e1-4ed6-8f3c-d9f271f3da61"
version = "0.1.0"

[deps]
JLWInterop = "65e54657-ed21-41a3-96db-71ab7fa6d94b"

[compat]
JLWInterop = "0.2"
julia = "1.13"
```

The separate `build-env/Project.toml` holds build tools that should not be
baked into the compiled library:

```toml
[deps]
JuliaC = "acedd4c2-ced6-4a15-accc-2607eb759ba2"
JuliaLibWrapping = "d61f35a8-f6af-436f-bc10-cee6b101f7bd"

[compat]
JuliaC = "0.3"
JuliaLibWrapping = "0.2"
julia = "1.13"
```

## 2. Define and declare the API

Put this in `src/mylib.jl`:

```julia
module mylib

using JLWInterop

"Multiply every element of `a` by `factor`."
scale(a::Vector{Float64}; factor::Float64 = 2.0) = factor .* a

@api scale(a::Vector{Float64}; factor::Float64 = 2.0)::Vector{Float64}

# `scale` returns an owning array, so foreign callers need the library's
# matching deallocator.
@export_release_entrypoints

end
```

The declaration does not replace or redefine `scale`. It says which method
signature foreign callers see. For this signature it generates an entrypoint
that:

- accepts a borrowed numeric array and a scalar;
- converts them to the declared Julia types;
- catches Julia exceptions and returns an error status;
- converts the result to an owning array that the caller releases; and
- records the name, keyword default, and docstring for wrapper targets.

The release macro is required because the returned vector is copied into
library-allocated storage. See [Supported Julia types](@ref) for the complete
mapping and [Ownership and release](@ref) for the underlying contract.

## 3. Build the library and wrappers

Put this in `build.jl`:

```julia
push!(LOAD_PATH, joinpath(@__DIR__, "build-env"))
using JuliaLibWrapping, JuliaC

standard_build(@__DIR__; libname = "mylib", verbose = true)

pop!(LOAD_PATH)
```

Instantiate both environments and run the build from `mylib/`:

```sh
julia --project=build-env -e 'using Pkg; Pkg.instantiate()'
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. build.jl
```

[`standard_build`](@ref) expects `src/<libname>.jl` and writes to `out/`. It
produces the shared library, ABI and API metadata, a C header, and a bundled
Python package:

```
out/
├── mylib.so
├── mylib.abi.json
├── mylib.jlw.json
├── mylib.h
├── pyproject.toml
└── mylib_py/
    ├── __init__.py
    ├── _lowlevel.py
    ├── _facade.py
    └── bundle/
```

The platform-specific shared-library suffix may differ. The bundle contains
the Julia runtime closure, so the installed package does not depend on a
system Julia. For other layouts or target selections, use [`build_library`](@ref)
as described in [Building and distributing a library](@ref).

## 4. Install and call it

Create a virtual environment outside `mylib/`—the compiler copies the entry
project during a build, so a nested virtual environment is undesirable:

```sh
python -m venv /tmp/mylib-venv
source /tmp/mylib-venv/bin/activate
pip install -e ./out
```

NumPy is installed as a generated package dependency because the exported API
uses an array. Call the generated function:

```python
import numpy as np
from mylib_py import scale

x = np.array([1.0, 2.0, 3.0])
print(scale(x))               # [2. 4. 6.]
print(scale(x, factor=0.5))   # [0.5 1.  1.5]
```

Python receives an independent NumPy array. The generated façade copies the
owning carrier into Python storage and releases the library allocation even if
conversion fails.

## 5. Continue developing

`_lowlevel.py`, `__init__.py`, and `pyproject.toml` are regenerated on every
build. `_facade.py` is created only when absent, because it is the place for
author-written Python policy. After changing an `@api` signature, regenerate a
fresh façade on a branch and merge the relevant changes into the version you
keep under source control. See [Generated Python bindings](@ref).

Next, use [Declaring an API with `@api`](@ref) for the full declaration syntax
or [Supported Julia types](@ref) to choose another foreign-facing type.
