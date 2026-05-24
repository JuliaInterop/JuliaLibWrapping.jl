# Driver for the juliac → ABI JSON → wrappers pipeline. See issue #16.

using TOML: TOML
using Libdl: Libdl

const _TRIM_MODES = (:no, :safe, :unsafe, Symbol("unsafe-warn"))

"""
    build_library(entry, targets;
                  project=dirname(entry), libname, libdir=pwd(),
                  abi_path=joinpath(libdir, libname*".abi.json"),
                  trim=:safe, compile_ccallable=true,
                  julia=`julia`, backend=:auto, verbose=false,
                  bundle=false, bundle_dir=joinpath(libdir, libname*"-bundle"),
                  privatize=false)

Run the full `juliac` → ABI JSON → wrapper pipeline in one call.

`entry` is the path to the Julia source file (or package directory) that
`juliac` will compile; `targets` is a vector of [`AbstractTarget`](@ref)s that
will each receive a `write_wrapper` call once the ABI JSON is available.

Returns a NamedTuple `(library, abi_path, abi_info, target_outputs, backend,
bundle_dir)`. `bundle_dir` is the path to the produced bundle tree when
`bundle = true`, and `nothing` otherwise.

# Backends

The default backend (`:auto`, equivalent to `:juliac`) requires
[JuliaC.jl](https://github.com/JuliaLang/JuliaC.jl) to be loaded into the
session (`using JuliaC`); JuliaC.jl ships the stable library API used here
and is the supported route.

Pass `backend = :script` to opt into the in-tree `share/julia/juliac/juliac.jl`
script shipped with Julia ≥ 1.13. That script self-declares as unstable; it is
mainly useful for ABI developers who want to try features before they reach
JuliaC.jl.

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
                       julia::Cmd = `julia`,
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
    backend ∈ (:auto, :juliac, :script) ||
        throw(ArgumentError("backend must be :auto, :juliac, or :script; got :$backend"))
    if bundle && backend === :script
        throw(ArgumentError("bundle = true requires backend = :juliac; the :script backend does not expose the bundle hook used here."))
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
    chosen = if backend === :script
        :script
    else  # :auto or :juliac — both require JuliaC
        ext === nothing &&
            throw(ArgumentError("JuliaC.jl is required — run `using JuliaC`, or pass `backend = :script` to use the unstable in-tree `juliac.jl` script shipped with Julia ≥ 1.13."))
        :juliac
    end

    if chosen === :juliac
        ext._build_library_juliac(entry; project, libname, libdir, abi_path,
                                  trim, compile_ccallable, verbose,
                                  bundle, bundle_dir = (bundle ? bundle_dir : nothing),
                                  privatize)
    else
        _build_library_script(entry; project, libname, libdir, abi_path,
                              trim, compile_ccallable, julia, verbose)
    end

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
            backend = chosen, bundle_dir = bundle ? bundle_dir : nothing)
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

function _locate_juliac_script(julia::Cmd)
    cmd = `$julia --startup-file=no --history-file=no -e 'print(joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac.jl"))'`
    path = try
        strip(read(cmd, String))
    catch e
        error("failed to locate juliac.jl via `$julia`: $e")
    end
    isfile(path) ||
        error("juliac.jl not found at $path — Julia ≥ 1.13 is required for the :script backend")
    return String(path)
end

function _build_library_script(entry::AbstractString;
                               project, libname, libdir, abi_path,
                               trim, compile_ccallable, julia::Cmd, verbose)
    juliac_jl = _locate_juliac_script(julia)
    out_lib = joinpath(libdir, libname)
    args = String[
        "--startup-file=no", "--history-file=no",
        juliac_jl,
        "--project=$project",
        "--output-lib", out_lib,
        "--export-abi", String(abi_path),
    ]
    compile_ccallable && push!(args, "--compile-ccallable")
    if trim !== nothing && trim !== :no
        push!(args, "--experimental")
        push!(args, "--trim=$(trim)")
    end
    verbose && push!(args, "--verbose")
    push!(args, String(entry))
    # Clear JULIA_LOAD_PATH / JULIA_PROJECT so the child julia uses its
    # default load path. juliac.jl does `using LazyArtifacts` at startup,
    # which needs stdlib reachable; under `Pkg.test` the parent's
    # restrictive load path would otherwise hide it.
    cmd = addenv(`$julia $args`,
                 "JULIA_LOAD_PATH" => nothing,
                 "JULIA_PROJECT"   => nothing)
    verbose && @info "Running juliac" cmd
    proc = run(pipeline(cmd; stdout, stderr); wait = false)
    wait(proc)
    success(proc) || error("juliac failed (exit $(proc.exitcode)): $cmd")
    return
end
