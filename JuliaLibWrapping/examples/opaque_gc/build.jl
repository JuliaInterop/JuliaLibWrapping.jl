# Build the opaque-handle GC demo end to end. Run from this directory with a
# recent enough Julia 1.13:
#
#   julia --project=build-env -e 'using Pkg; Pkg.instantiate()'   # once
#   julia --project=. build.jl
#
# Output lands in `out/`. The generated `opaque_gc_py` package exposes
# `make_model`, which returns an `Opaque` handle, and `num_active_opaques`,
# which reports how many handles are rooted. `test/smoke.py` uses the latter to
# watch Python garbage collection free the former.
#
# In a tutorial-shaped library (post-registration of JuliaLibWrapping and
# JLWInterop) this script collapses to:
#
#     push!(LOAD_PATH, joinpath(@__DIR__, "build-env"))
#     using JuliaLibWrapping, JuliaC
#     standard_build(@__DIR__; libname = "opaque_gc", verbose = true)
#
# The extra `prepare_project` step below exists only because we dogfood
# against the in-tree `JLWInterop/` checkout, adding its path to a temporary
# copy of `Project.toml`.

using TOML: TOML

const HERE        = @__DIR__
const JLW_INTEROP = abspath(joinpath(HERE, "..", "..", "..", "JLWInterop"))

function prepare_project()
    toml = TOML.parsefile(joinpath(HERE, "Project.toml"))
    sources = get(toml, "sources", Dict{String, Any}())
    sources["JLWInterop"] = Dict("path" => JLW_INTEROP)
    toml["sources"] = sources
    tmp = mktempdir(; prefix = "opaque_gc-project-")
    open(joinpath(tmp, "Project.toml"), "w") do io
        TOML.print(io, toml; sorted = true)
    end
    cp(joinpath(HERE, "src"), joinpath(tmp, "src"))
    return tmp
end

push!(LOAD_PATH, joinpath(HERE, "build-env"))
using JuliaLibWrapping, JuliaC

result = standard_build(HERE;
    libname = "opaque_gc",
    project = prepare_project(),
    verbose = true,
)

@info "Built opaque_gc" library=result.library
