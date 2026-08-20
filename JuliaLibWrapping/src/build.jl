# juliac → ABI JSON → wrapper driver.

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
                  privatize=bundle, cpu_target=nothing)

Run the full `juliac` → ABI JSON → wrapper pipeline in one call.

`entry` is the path to the Julia source file (or package directory) that
`juliac` will compile; `targets` is a vector of [`AbstractTarget`](@ref)s that
will each receive a `write_wrapper` call once the ABI JSON is available.

Returns a NamedTuple `(library, abi_path, abi_info, target_outputs, backend,
bundle_dir)`. `bundle_dir` is the path to the produced bundle tree when
`bundle = true`, and `nothing` otherwise.

# Example

```julia
using JuliaLibWrapping, JuliaC
out = mktempdir()
result = build_library(
    joinpath(@__DIR__, "src/mylib.jl"),
    [CTarget(out, "mylib"), PythonTarget(out, "mylib_py", "mylib")];
    project = @__DIR__,
    libname = "mylib",
    libdir  = out,
)
```

# Extended help

# Backend

`build_library` drives [JuliaC.jl](https://github.com/JuliaLang/JuliaC.jl)
(a weak dependency); load it with `using JuliaC` before calling this
function. `backend = :auto` (the default) and `backend = :juliac` are
synonyms; the keyword is retained so additional backends can be added
without changing the calling interface.

# `[sources]` paths must be absolute

`juliac` relocates the project into a temporary directory before compiling.
Relative `[sources]` paths in the entry project's `Project.toml` cannot be
resolved from there, so this function rejects them up front. Either use
absolute paths or `Pkg.develop` the dependency.

# Bundling

A juliac-produced `.so` depends on `libjulia`, a sysimage, stdlibs, and
artifacts — none of which a `pip install`-ing Python user has on their
machine. Pass `bundle = true` to also produce a self-contained directory
tree (the `juliac --bundle` layout) and copy it into every
[`PythonTarget`](@ref)'s package. The Python loader generated for those
targets searches the bundle first, so the embedded `RUNPATH` resolves
`libjulia` from inside the wheel at import time.

`bundle = true` requires the `:juliac` backend and that each [`PythonTarget`](@ref)
declare a `bundle_subdir` (e.g.
`PythonTarget(out, "mylib_py", "mylib"; bundle_subdir = "bundle")`).
Targets that are not Python (e.g. [`CTarget`](@ref)) are unaffected — C
consumers manage their own linkage.

`privatize` salts the bundled `libjulia` and `libjulia-internal` with a
distinct SONAME prefix, so the loader cannot satisfy this library's runtime
dependency from another loaded copy. It defaults to `bundle`. See the manual
section on multiple wrapped libraries in one process.

Privatization applies to the bundle, so `privatize = true` with
`bundle = false` is an error rather than a silent no-op. Pass
`privatize = false` alongside `bundle = true` to opt out.

# CPU target

`cpu_target` sets the multi-microarchitecture target for the compiled
library, using the same syntax as the `--cpu-target` `julia` flag or the
`JULIA_CPU_TARGET` environment variable (e.g.
`"generic;sandybridge,-xsaveopt,clone_all"`). The default, `nothing`, defers
to `JULIA_CPU_TARGET` if it is set in the environment, or otherwise to the
host CPU.
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
                       privatize::Bool = bundle,
                       cpu_target::Union{Nothing,AbstractString} = nothing)
    isfile(entry) || isdir(entry) ||
        throw(ArgumentError("entry not found: $entry"))
    isdir(project) ||
        throw(ArgumentError("project directory not found: $project"))
    if trim !== nothing && trim ∉ _TRIM_MODES
        throw(ArgumentError("trim must be one of $(_TRIM_MODES) or nothing; got :$trim"))
    end
    backend ∈ (:auto, :juliac) ||
        throw(ArgumentError("backend must be :auto or :juliac; got :$backend"))
    if privatize && !bundle
        throw(ArgumentError(
            "privatize = true requires bundle = true: privatization salts the " *
            "bundled libjulia, and a build without a bundle has none to salt."))
    end
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
                              privatize, cpu_target)

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
        write_wrapper(_apply_privatization(t, privatize), abi_info)
        target_outputs[i] = (target = typeof(t), dir = t.dir)
    end

    return (; library = library_path, abi_path, abi_info, target_outputs,
            backend = :juliac, bundle_dir = bundle ? bundle_dir : nothing)
end

# Record whether the bundle was privatized so the generated Python can warn
# when another non-privatized package is already loaded.
_apply_privatization(t::AbstractTarget, ::Bool) = t
function _apply_privatization(t::PythonTarget, privatize::Bool)
    t.privatized == privatize && return t
    t.privatized && throw(ArgumentError(
        "PythonTarget for package \"$(t.package_name)\" was constructed with " *
        "`privatized = true`, but `build_library` was called with `privatize = false`. " *
        "The generated package would claim a private libjulia it does not have."))
    return PythonTarget(t.dir, t.package_name, t.library_basename;
                        bundle_subdir = t.bundle_subdir, version = t.version,
                        privatized = true)
end

# Copy the bundle before emitting Python sources.
function _copy_bundle_into_python_package(t::PythonTarget, bundle_dir::AbstractString)
    pkgdir = joinpath(t.dir, t.package_name)
    mkpath(pkgdir)
    dest = joinpath(pkgdir, t.bundle_subdir::String)
    # Avoid retaining files from an older, larger bundle.
    ispath(dest) && rm(dest; recursive = true)
    cp(bundle_dir, dest)
    return dest
end

"""
    standard_build(dir = pwd(); libname, kwargs...)

Run [`build_library`](@ref) with defaults for the conventional
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
                  bundle_subdir = "bundle", version = $(repr(_DEFAULT_PACKAGE_VERSION)))];
    project = dir, libname, libdir = joinpath(dir, "out"),
    bundle = true, kwargs...)
```

The kwargs `out`, `entry`, `python_package`, `project`, `bundle`, and
`version` override the defaults above; anything else is forwarded to
`build_library` (e.g. `verbose`, `trim`, `privatize`). `project`
defaults to `dir`, but can be pointed at a separate location when the
on-disk source layout and the entry `Project.toml` live in different
directories (e.g. a transient project materialized with absolute
`[sources]` paths for `juliac`). `version` sets the version in the generated
Python package's `pyproject.toml` (see [`PythonTarget`](@ref)). For layouts
outside this convention, call `build_library` directly.
"""
function standard_build(dir::AbstractString = pwd();
                        libname::AbstractString,
                        project::AbstractString = dir,
                        out::AbstractString = joinpath(dir, "out"),
                        entry::AbstractString = joinpath(dir, "src", libname * ".jl"),
                        python_package::AbstractString = libname * "_py",
                        bundle::Bool = true,
                        version::AbstractString = _DEFAULT_PACKAGE_VERSION,
                        kwargs...)
    targets = AbstractTarget[
        CTarget(out, libname),
        PythonTarget(out, python_package, libname;
                     bundle_subdir = bundle ? "bundle" : nothing,
                     version),
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
