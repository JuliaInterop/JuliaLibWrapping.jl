# JuliaLibWrapping

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://JuliaInterop.github.io/JuliaLibWrapping.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaInterop.github.io/JuliaLibWrapping.jl/dev/)
[![Build Status](https://github.com/JuliaInterop/JuliaLibWrapping.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/JuliaInterop/JuliaLibWrapping.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/JuliaInterop/JuliaLibWrapping.jl/graph/badge.svg?token=UP6JQXXQS3)](https://codecov.io/gh/JuliaInterop/JuliaLibWrapping.jl)
[![Aqua QA](https://juliatesting.github.io/Aqua.jl/dev/assets/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)

JuliaLibWrapping turns the JSON ABI metadata emitted by
[`juliac`](https://github.com/JuliaLang/JuliaC.jl) into a C header or Python
`ctypes` package. ABI export requires Julia 1.13 or later.

The Python target separates generated `ctypes` bindings in `_lowlevel.py`
from the author-editable public API in `_facade.py`. The low-level module is
regenerated; the façade is created once. See the
[documentation](https://JuliaInterop.github.io/JuliaLibWrapping.jl/dev/python/)
for details.
