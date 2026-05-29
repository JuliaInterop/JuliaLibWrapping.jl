# Build the OLS tutorial library end-to-end with a bundled Python package.
# Run from this directory with a recent enough Julia 1.13:
#
#   julia --project=. build.jl
#
# Output lands in `out/`. See `../../docs/src/tutorial.md` for the full
# walkthrough. The build-env at `./build-env/` must be instantiated once:
#
#   julia --project=build-env -e 'using Pkg; Pkg.instantiate()'
#
# In a tutorial-shaped library (post-registration of JuliaLibWrapping and
# JLWInterop) this script collapses to:
#
#     push!(LOAD_PATH, joinpath(@__DIR__, "build-env"))
#     using JuliaLibWrapping, JuliaC
#     standard_build(@__DIR__; libname = "ols", verbose = true)
#
# `using JuliaC` is what activates JuliaLibWrapping's weak dependency
# on JuliaC.jl — without it, `build_library` errors with a hint.
#
# The extra machinery below exists only because we are dogfooding against
# the in-tree `JLWInterop/` checkout: `juliac` requires `[sources]` paths
# in the entry project to be absolute, so we materialize a transient copy
# of `Project.toml` with `[sources]` injected. Once `JLWInterop` is
# registered, the `prepare_project` step disappears too.

using TOML: TOML

const HERE        = @__DIR__
const JLW_INTEROP = abspath(joinpath(HERE, "..", "..", "..", "JLWInterop"))

function prepare_project()
    toml = TOML.parsefile(joinpath(HERE, "Project.toml"))
    sources = get(toml, "sources", Dict{String, Any}())
    sources["JLWInterop"] = Dict("path" => JLW_INTEROP)
    toml["sources"] = sources
    tmp = mktempdir(; prefix = "ols-project-")
    open(joinpath(tmp, "Project.toml"), "w") do io
        TOML.print(io, toml; sorted = true)
    end
    return tmp
end

push!(LOAD_PATH, joinpath(HERE, "build-env"))
using JuliaLibWrapping, JuliaC

result = standard_build(HERE;
    libname = "ols",
    project = prepare_project(),
    verbose = true,
)

@info "Built ols" library=result.library bundle=result.bundle_dir
