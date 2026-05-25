# Build the OLS tutorial library end-to-end with a bundled Python package.
# Run from this directory with the Julia 1.13 release candidate:
#
#   julia +rc --project=. build.jl
#
# Output lands in `out/`:
#   out/ols.so         — the compiled shared library
#   out/ols.h          — the C header
#   out/ols_py/        — the Python package (with `bundle/` runtime closure)
#
# The bundled tree is several hundred MiB; that is what lets a downstream
# `pip install ./out/ols_py` work in a clean venv with no system Julia.
#
# `juliac` requires `[sources]` entries in the entry project's `Project.toml`
# to be absolute paths, so this script materializes a transient project in a
# temp directory with `[sources]` pointing at the in-tree `JLWInterop/`. The
# committed `Project.toml` therefore stays free of any machine-specific path.

using TOML: TOML
using JuliaLibWrapping
using JuliaC

const HERE        = @__DIR__
const OUT         = joinpath(HERE, "out")
const ENTRY       = joinpath(HERE, "src", "ols.jl")
const JLW_INTEROP = abspath(joinpath(HERE, "..", "..", "JLWInterop"))

# Materialize a temp project with absolute `[sources]` for this machine.
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

result = build_library(ENTRY,
    [CTarget(OUT, "ols"),
     PythonTarget(OUT, "ols_py", "ols"; bundle_subdir = "bundle")];
    project = prepare_project(),
    libname = "ols",
    libdir  = OUT,
    bundle  = true,
    verbose = true,
)

@info "Built ols" library=result.library bundle=result.bundle_dir
