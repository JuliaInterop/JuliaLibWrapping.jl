```@meta
CurrentModule = JuliaLibWrapping
```

# Platform support

JuliaLibWrapping's generated Python packages load on Linux, macOS, and
Windows. `juliac`'s bundle layout differs per OS, and Windows in particular
needs generated-code help that Linux/macOS get for free from the dynamic
linker — this page documents what is tested, how the Windows loader works,
and what a future target author (MATLAB, R, …) needs to know before adding
another emission target.

## What works where

CI runs the full suite — unit tests, golden-fixture comparisons, and the
end-to-end build (`juliac` compile + link + `python -c "import ast; ast.parse(...)"`
of the emitted `_lowlevel.py`) — on `ubuntu-latest`, `macos-latest` (Apple
Silicon/arm64), and `windows-latest`, for both `JuliaLibWrapping` and
`JLWInterop`, across Julia's `min` and `pre` (soon-to-be-stable) release
channels. All three OSes are green, including the build end-to-end test —
nothing is skipped or marked experimental for the current stable-ish channels.

`nightly` is tracked separately and is **not** part of the "all green"
claim: `juliac --trim` currently fails to verify parts of Julia's own
`Base` on nightly (unresolved calls inside `HashState`, `next`,
`IOContext`) regardless of OS. That cell is `experimental: true`
(soft-fail) so the signal stays visible without blocking the workflow; it
is a pre-existing Julia-nightly/`juliac` issue, not a JuliaLibWrapping
platform gap.

macOS needed no loader changes at all — JuliaC already handles
`@loader_path` and codesigning for a bundled `.dylib`, so the macOS
codegen path is byte-identical to Linux's.

## JuliaC's bundle layout

A `juliac --bundle` tree holds the runtime's shared libraries under `lib/`
on Linux and macOS (resolved via `$ORIGIN`/`@loader_path` respectively —
see [Bundling for distribution](@ref)), but under `bin/` on Windows, which
has no rpath equivalent for a `lib/` directory to serve. `juliac` also
puts the wrapped library itself in `bin/` on Windows, alongside the
runtime.

This is a property of `juliac`'s bundle layout, not of any one target
language, so it is hoisted out of the Python emitter into
[`bundle_libdir`](@ref) (`src/platform.jl`) — `"bin"` on `:windows`,
`"lib"` otherwise — alongside [`_current_os_kernel`](@ref), which
identifies the host as `:windows`/`:apple`/`:linux`. `PythonTarget`'s
emitter calls `bundle_libdir(os_kernel)` rather than inlining its own
per-OS ternary.

## The Windows loader

Two problems are specific to Windows: `juliac` emits **no rpath** there
(unlike `$ORIGIN`/`@loader_path`), and Windows DLL search rules mean a
dependency (`libjulia*.dll`) sitting in a sibling directory is not found
automatically the way a Unix RUNPATH finds it. The generated Python
package handles each case differently depending on layout:

- **Bundled layout** (`bundle_subdir` set). `__init__.py` gains a preamble,
  emitted before any import of `_facade`/`_lowlevel`, that widens the DLL
  search path to the bundle's `bin/` directory:

  ```python
  import os as _os
  _d = _os.path.dirname(_os.path.abspath(__file__))
  _bin = _os.path.join(_d, "bundle", "bin")
  if hasattr(_os, "add_dll_directory"):
      _os.add_dll_directory(_bin)
  else:
      _os.environ["PATH"] = _bin + _os.pathsep + _os.environ.get("PATH", "")
  ```

  `add_dll_directory` (Python 3.8+) is preferred; the `PATH`-prepend branch
  is a fallback for older interpreters. This must run before `_lowlevel.py`
  reaches its own `ctypes.CDLL(...)` call, since that is what actually
  loads the wrapped library and pulls in its `libjulia*.dll` dependency.

- **Flat layout** (no bundle — a bare `.dll` shipped beside the package,
  requiring a system Julia). `_lowlevel.py` gains a `_find_julia_bin()`
  function that locates a system Julia the same way a `runtime=:system`
  wheel loader does: `JULIA_BINDIR` env var, then `JULIA_PREFIX`, then
  `shutil.which("julia")`
  followed by asking that `julia` binary for its own `Sys.BINDIR` via a
  subprocess. If a Julia install is located, its `bin/` directory is added
  to the DLL search path (`add_dll_directory` or the `PATH` fallback)
  before the existing `FileNotFoundError` path is reached.

  This is deliberately **DLL-search-path-only**: the located Julia `bin/`
  directory is never itself searched as a candidate location for the
  *wrapped library*. A user's built library never lives inside a Julia
  install, and treating it as a candidate would risk silently loading an
  unrelated same-named DLL and failing confusingly later. Only
  `libjulia*.dll` resolution benefits from the widened search path; the
  wrapped library itself is still found only beside the package (or
  via the `<PKG>_LIBRARY` environment-variable override).

`sys.platform`-based suffix selection (`.dll` / `.dylib`,`.so` /
`.so`,`.dylib`) needed no OS-kernel awareness — it was already computed at
Python runtime and works unchanged on every OS.

## Windows privatization caveat

[Privatizing a bundle](@ref "Multiple wrapped libraries in one process")
(giving `libjulia`/`libjulia-internal` a distinct SONAME so two wrapped
libraries can coexist in one process) works by salting ELF/Mach-O SONAMEs
— a mechanism `juliac` does not yet implement for Windows DLLs. Passing
`privatize = true` to [`build_library`](@ref) on a Windows build host
therefore cannot actually produce a privatized bundle.

Rather than silently label the output `privatized = true` for a bundle
that never carries a private runtime — which would suppress the
generated package's "another wrapped package may already be loaded"
warning for a hazard that is, on Windows, still live — `build_library`
downgrades the flag: it warns and builds with `privatized = false`
instead. The warning names the package:

```
JuliaLibWrapping: `privatize = true` has no effect on a Windows build host
(JuliaC does not yet implement libjulia SONAME salting there); the
generated package for "pkg" is labeled `privatized = false`.
```

This means only one non-privatized wrapped library can safely be imported
per process on a Windows build — the same restriction described in
[Multiple wrapped libraries in one process](@ref), without the escape
hatch that privatization provides on Linux/macOS.

## Load path by OS

![Load path per OS and layout: on Linux and macOS the bundle's baked-in rpath (`$ORIGIN` / `@loader_path`) already resolves libjulia, so `ctypes.CDLL` just works; on Windows a bundle needs an `add_dll_directory` preamble in `__init__.py` before `ctypes.CDLL` runs, and a flat (non-bundle) layout instead locates a system Julia install via `_find_julia_bin` and widens the DLL search path to it.](assets/platform-load-paths.svg)

> Diagram source: [`docs/src/assets/platform-load-paths.mmd`](assets/platform-load-paths.mmd);
> regenerate with `mmdc -i platform-load-paths.mmd -o platform-load-paths.svg -b transparent`.

## Writing a target: platform checklist

A future target (a MATLAB `.mex` emitter via
[Mexicah](https://github.com/JuliaInterop/Mexicah.jl), an R target, …)
should split platform handling the same way the Python target does:

- **Consume, don't re-derive, the target-independent facts.** Which
  subdirectory of a bundle holds the runtime ([`bundle_libdir`](@ref)) and
  which OS is currently building/running ([`_current_os_kernel`](@ref))
  are properties of `juliac`'s bundle layout, not of any target language —
  call the shared `src/platform.jl` functions rather than re-deriving a
  per-OS ternary in a new target's emitter.
- **Own your target's loader idiom.** How a target's *runtime* locates and
  loads its dependencies is target-specific and belongs in that target's
  emitter, not in `platform.jl`: Python's answer is `ctypes.CDLL` plus
  `os.add_dll_directory`/`PATH`-prepend; a MATLAB target has its own
  library-loading conventions (typically no equivalent of an rpath fallback
  either, since MEX files are themselves platform-specific binaries) and
  will need its own preamble, ported by the same "widen the search path,
  never search a runtime directory for the wrapped library itself"
  discipline used here.
- **Force `os_kernel` in tests, don't rely on the host.** `write_wrapper`
  defaults `os_kernel` to [`_current_os_kernel()`](@ref) but accepts it as
  a keyword, so Windows/macOS codegen can be exercised and golden-compared
  from any CI runner, the same pattern `PythonTarget`'s test suite uses
  (`test/runtests.jl`'s `"cross-platform loader (os_kernel)"` testset).
- **A bundled layout is not automatically the sole delivery mode.** If a
  target supports both a flat, system-runtime layout and a bundled one
  (as `PythonTarget` does), both need their own platform story — the flat
  Windows case needed a Julia-discovery fallback that the bundled case
  does not, since a bundle carries its own runtime.
