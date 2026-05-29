# Driver for the juliac → ABI JSON → wrappers pipeline. See issue #16.

using TOML: TOML
using Libdl: Libdl

const _TRIM_MODES = (:no, :safe, :unsafe, Symbol("unsafe-warn"))

"""
    build_library(entry, targets;
                  project=dirname(entry), libname, libdir=pwd(),
                  abi_path=joinpath(libdir, libname*".abi.json"),
                  trim=:safe, compile_ccallable=true,
                  backend=:auto, verbose=false,
                  bundle=false, bundle_dir=joinpath(libdir, libname*"-bundle"),
                  privatize=false)

Run the full `juliac` → ABI JSON → wrapper pipeline in one call.

`entry` is the path to the Julia source file (or package directory) that
`juliac` will compile; `targets` is a vector of [`AbstractTarget`](@ref)s that
will each receive a `write_wrapper` call once the ABI JSON is available.

Returns a NamedTuple `(library, abi_path, abi_info, target_outputs, backend,
bundle_dir)`. `bundle_dir` is the path to the produced bundle tree when
`bundle = true`, and `nothing` otherwise.

# Backend

`build_library` drives [JuliaC.jl](https://github.com/JuliaLang/JuliaC.jl)
(a weak dependency); load it with `using JuliaC` before calling this
function. `backend = :auto` (the default) and `backend = :juliac` are
synonyms; the kwarg is retained so additional backends can be added
without breaking the call surface.

# Example

```julia
using JuliaLibWrapping
out = mktempdir()
result = build_library(
    joinpath(@__DIR__, "src/mylib.jl"),
    [CTarget(out, "mylib"), PythonTarget(out, "mylib_py", "mylib")];
    project = @__DIR__,
    libname = "mylib",
    libdir  = out,
)
```

# `[sources]` paths must be absolute

`juliac` relocates the project into a temporary directory before compiling.
Relative `[sources]` paths in the entry project's `Project.toml` cannot be
resolved from there, so this function rejects them up front. Either use
absolute paths or `Pkg.develop` the dependency.

# Bundling for distribution (issue #17)

A juliac-produced `.so` depends on `libjulia`, a sysimage, stdlibs, and
artifacts — none of which a `pip install`-ing Python user has on their
machine. Pass `bundle = true` to also produce a self-contained directory
tree (the `juliac --bundle` layout) and copy it into every
[`PythonTarget`](@ref)'s package. The Python loader generated for those
targets searches the bundle first, so the baked-in `RUNPATH` resolves
`libjulia` from inside the wheel at import time.

`bundle = true` requires the `:juliac` backend and that each [`PythonTarget`](@ref)
declare a `bundle_subdir` (e.g.
`PythonTarget(out, "mylib_py", "mylib"; bundle_subdir = "bundle")`).
Targets that are not Python (e.g. [`CTarget`](@ref)) are unaffected — C
consumers manage their own linkage.

`privatize = true` salts the bundled libjulia files with a random prefix so
they cannot collide with a system libjulia. Off by default; opt in if the
wrapper might be loaded into a process that also has a different libjulia.
"""
function build_library(entry::AbstractString,
                       targets::AbstractVector{<:AbstractTarget};
                       project::AbstractString = dirname(entry),
                       libname::AbstractString,
                       libdir::AbstractString = pwd(),
                       abi_path::AbstractString = joinpath(libdir, libname * ".abi.json"),
                       trim::Union{Nothing,Symbol} = :safe,
                       compile_ccallable::Bool = true,
                       backend::Symbol = :auto,
                       verbose::Bool = false,
                       bundle::Bool = false,
                       bundle_dir::AbstractString = joinpath(libdir, libname * "-bundle"),
                       privatize::Bool = false)
    isfile(entry) || isdir(entry) ||
        throw(ArgumentError("entry not found: $entry"))
    isdir(project) ||
        throw(ArgumentError("project directory not found: $project"))
    if trim !== nothing && trim ∉ _TRIM_MODES
        throw(ArgumentError("trim must be one of $(_TRIM_MODES) or nothing; got :$trim"))
    end
    backend ∈ (:auto, :juliac) ||
        throw(ArgumentError("backend must be :auto or :juliac; got :$backend"))
    if bundle
        for t in targets
            t isa PythonTarget || continue
            t.bundle_subdir === nothing && throw(ArgumentError(
                "PythonTarget for package \"$(t.package_name)\" needs `bundle_subdir = \"bundle\"` " *
                "(or some other subdir name) when `build_library` is called with `bundle = true`; " *
                "the bundle tree is copied into that subdirectory of the package."))
        end
    end

    _validate_sources_absolute(project)

    mkpath(libdir)
    library_path = joinpath(libdir, libname * "." * Libdl.dlext)

    ext = Base.get_extension(@__MODULE__, :JuliaLibWrappingJuliaCExt)
    ext === nothing &&
        throw(ArgumentError("JuliaC.jl is required — run `using JuliaC` before calling `build_library`."))

    ext._build_library_juliac(entry; project, libname, libdir, abi_path,
                              trim, compile_ccallable, verbose,
                              bundle, bundle_dir = (bundle ? bundle_dir : nothing),
                              privatize)

    isfile(abi_path) ||
        error("juliac completed but no ABI JSON was written to $abi_path")
    abi_info = read_abi_info(abi_path)

    if bundle
        isdir(bundle_dir) ||
            error("juliac --bundle completed but no bundle tree at $bundle_dir")
        for t in targets
            t isa PythonTarget || continue
            _copy_bundle_into_python_package(t, bundle_dir)
        end
    end

    target_outputs = Vector{NamedTuple}(undef, length(targets))
    for (i, t) in pairs(targets)
        write_wrapper(t, abi_info)
        target_outputs[i] = (target = typeof(t), dir = t.dir)
    end

    return (; library = library_path, abi_path, abi_info, target_outputs,
            backend = :juliac, bundle_dir = bundle ? bundle_dir : nothing)
end

# Copy the juliac --bundle tree into a Python package. Run before
# `write_wrapper` so the package directory always exists with the runtime
# closure in place; `write_wrapper` then drops the Python sources alongside.
function _copy_bundle_into_python_package(t::PythonTarget, bundle_dir::AbstractString)
    pkgdir = joinpath(t.dir, t.package_name)
    mkpath(pkgdir)
    dest = joinpath(pkgdir, t.bundle_subdir::String)
    # Wipe any stale copy so a smaller-than-before bundle does not leave
    # orphan files behind that the new package-data manifest would pick up.
    ispath(dest) && rm(dest; recursive = true)
    cp(bundle_dir, dest)
    return dest
end

"""
    standard_build(dir = pwd(); libname, kwargs...)

Convenience wrapper around [`build_library`](@ref) for the conventional
single-library layout:

    dir/
    ├── Project.toml          # entry project (runtime deps only)
    ├── src/
    │   └── <libname>.jl      # @ccallable entrypoints
    └── out/                  # generated artifacts

Emits both a C header and a Python `ctypes` package (`<libname>_py`),
bundled for distribution. Equivalent to:

```julia
build_library(joinpath(dir, "src", libname*".jl"),
    [CTarget(joinpath(dir, "out"), libname),
     PythonTarget(joinpath(dir, "out"), libname*"_py", libname;
                  bundle_subdir = "bundle")];
    project = dir, libname, libdir = joinpath(dir, "out"),
    bundle = true, kwargs...)
```

The kwargs `out`, `entry`, `python_package`, `project`, and `bundle`
override the defaults above; anything else is forwarded to
`build_library` (e.g. `verbose`, `trim`, `privatize`). `project`
defaults to `dir`, but can be pointed at a separate location when the
on-disk source layout and the entry `Project.toml` live in different
directories (e.g. a transient project materialized with absolute
`[sources]` paths for `juliac`). For layouts outside this convention,
call `build_library` directly.
"""
function standard_build(dir::AbstractString = pwd();
                        libname::AbstractString,
                        project::AbstractString = dir,
                        out::AbstractString = joinpath(dir, "out"),
                        entry::AbstractString = joinpath(dir, "src", libname * ".jl"),
                        python_package::AbstractString = libname * "_py",
                        bundle::Bool = true,
                        kwargs...)
    targets = AbstractTarget[
        CTarget(out, libname),
        PythonTarget(out, python_package, libname;
                     bundle_subdir = bundle ? "bundle" : nothing),
    ]
    return build_library(entry, targets;
                         project, libname, libdir = out, bundle,
                         kwargs...)
end

function _validate_sources_absolute(project::AbstractString)
    pf = joinpath(project, "Project.toml")
    isfile(pf) || return  # nothing to validate
    toml = TOML.parsefile(pf)
    haskey(toml, "sources") || return
    sources = toml["sources"]
    sources isa AbstractDict || return
    for (name, spec) in sources
        spec isa AbstractDict || continue
        haskey(spec, "path") || continue
        p = spec["path"]
        if !isabspath(p)
            throw(ArgumentError(
                """[sources] entry "$name" has relative path "$p" in $pf.
                juliac copies the project into a temporary directory before compiling,
                so relative [sources] paths cannot be resolved. Use an absolute path
                (e.g. `path = $(repr(abspath(joinpath(project, p))))`) or `Pkg.develop`
                the dependency."""))
        end
    end
    return
end

