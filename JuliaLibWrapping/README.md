# JuliaLibWrapping

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://JuliaInterop.github.io/JuliaLibWrapping.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaInterop.github.io/JuliaLibWrapping.jl/dev/)
[![Build Status](https://github.com/JuliaInterop/JuliaLibWrapping.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/JuliaInterop/JuliaLibWrapping.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/JuliaInterop/JuliaLibWrapping.jl/graph/badge.svg?token=UP6JQXXQS3)](https://codecov.io/gh/JuliaInterop/JuliaLibWrapping.jl)
[![Aqua QA](https://juliatesting.github.io/Aqua.jl/dev/assets/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)

`juliac` (see [JuliaC.jl](https://github.com/JuliaLang/JuliaC.jl)) can emit a JSON
ABI-info file describing the entrypoints and types of a compiled Julia library.
JuliaLibWrapping consumes that file and generates wrappers for other languages:
a C header (`.h`) via `CTarget`, or a Python `ctypes` package via
`PythonTarget`. The `juliac` ABI-export feature ships in Julia 1.13.

The Python target separates generated `ctypes` bindings in `_lowlevel.py`
from the public API in an author-editable `_facade.py`. The former is
regenerated on each run; the latter is created only if it does not exist. See the
[documentation](https://JuliaInterop.github.io/JuliaLibWrapping.jl/dev/#Two-tier-Python-output)
for details.

See the tests for an example of generating a `.h` file from a `juliac` ABI-info file.
