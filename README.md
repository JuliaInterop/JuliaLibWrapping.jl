# JuliaLibWrapping.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://JuliaInterop.github.io/JuliaLibWrapping.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaInterop.github.io/JuliaLibWrapping.jl/dev/)
[![Build Status](https://github.com/JuliaInterop/JuliaLibWrapping.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/JuliaInterop/JuliaLibWrapping.jl/actions/workflows/CI.yml?query=branch%3Amain)

JuliaLibWrapping generates language bindings for shared libraries compiled from Julia packages.

This repository contains two packages:

- **[`JuliaLibWrapping/`](JuliaLibWrapping/)** — generates C headers and Python
  `ctypes` packages from the JSON ABI-info file emitted by
  [`juliac`](https://github.com/JuliaLang/JuliaC.jl). This is the build-time
  tool; see its [README](JuliaLibWrapping/README.md) and the
  [documentation](https://JuliaInterop.github.io/JuliaLibWrapping.jl/dev/).

- **[`JLWInterop/`](JLWInterop/)** — a dependency-free package defining
  shared ABI types such as `CArray`, `CString`, and `JLWStatus`. Compiled
  libraries use these types, and the generated Python wrappers recognize their
  layouts. Compiled libraries can use it as a runtime dependency with
  `juliac --trim`.
