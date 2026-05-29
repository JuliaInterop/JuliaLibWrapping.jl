# JuliaLibWrapping.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://JuliaInterop.github.io/JuliaLibWrapping.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaInterop.github.io/JuliaLibWrapping.jl/dev/)
[![Build Status](https://github.com/JuliaInterop/JuliaLibWrapping.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/JuliaInterop/JuliaLibWrapping.jl/actions/workflows/CI.yml?query=branch%3Amain)

This repository is a monorepo holding two packages, in sibling subdirectories:

- **[`JuliaLibWrapping/`](JuliaLibWrapping/)** — generates C headers and Python
  `ctypes` packages from the JSON ABI-info file emitted by
  [`juliac`](https://github.com/JuliaLang/JuliaC.jl). This is the build-time
  tool; see its [README](JuliaLibWrapping/README.md) and the
  [documentation](https://JuliaInterop.github.io/JuliaLibWrapping.jl/dev/).

- **[`JLWInterop/`](JLWInterop/)** — a small, dependency-free package defining
  the types (`CArray`, `CString`, `JLWStatus`, …) that compiled
  libraries and the generated Python wrappers both know about. It is a runtime
  dependency of *compiled* libraries, kept separate so it stays
  `juliac --trim`-friendly.
