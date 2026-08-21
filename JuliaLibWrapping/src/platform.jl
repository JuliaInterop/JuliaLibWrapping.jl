# ── Platform facts shared across every emission target ────────────────────
#
# These are properties of JuliaC's bundle/build layout itself, not of any
# one target language — so `PythonTarget` today, and a future MATLAB/R
# target, must both consume them from here rather than re-deriving their
# own copy.

"""
    _current_os_kernel() -> Symbol

Identify the host OS as `:windows`, `:apple`, or `:linux`, for selecting
which platform-dependent text a target's `write_wrapper` emits (DLL search
path setup on Windows, `.dylib` suffix ordering on macOS, …). A function,
deliberately, not a `@static` branch: tests force the non-host branches to
exercise Windows/macOS codegen from a Linux CI runner.
"""
_current_os_kernel() = Sys.iswindows() ? :windows : Sys.isapple() ? :apple : :linux

"""
    bundle_libdir(os_kernel::Symbol) -> String

The subdirectory of a JuliaC `--bundle` tree that holds the runtime's
shared libraries — and, on Windows, the wrapped library itself: `"bin"` on
`:windows` (JuliaC bundles everything there; no rpath equivalent exists on
that platform for a `"lib"` directory to serve), `"lib"` on `:linux` and
`:apple` (resolved via `\$ORIGIN`/`@loader_path` respectively). A property
of JuliaC's bundle layout, not of any one target language.
"""
bundle_libdir(os_kernel::Symbol) = os_kernel === :windows ? "bin" : "lib"
