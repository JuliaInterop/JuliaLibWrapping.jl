# JuliaLibWrapping

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://JuliaInterop.github.io/JuliaLibWrapping.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaInterop.github.io/JuliaLibWrapping.jl/dev/)
[![Build Status](https://github.com/JuliaInterop/JuliaLibWrapping.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/JuliaInterop/JuliaLibWrapping.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/JuliaInterop/JuliaLibWrapping.jl/graph/badge.svg?token=UP6JQXXQS3)](https://codecov.io/gh/JuliaInterop/JuliaLibWrapping.jl)
[![Aqua QA](https://juliatesting.github.io/Aqua.jl/dev/assets/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)

**Status**: work-in-progress, not yet released.

`juliac` (see [JuliaC.jl](https://github.com/JuliaLang/JuliaC.jl)) can emit a JSON
ABI-info file describing the entrypoints and types of a compiled Julia library.
JuliaLibWrapping consumes that file and generates a C header (`.h`) so the library
can be called from C. The `juliac` ABI-export feature ships in Julia 1.13.

See the tests for an example of generating a `.h` file from a `juliac` ABI-info file.
