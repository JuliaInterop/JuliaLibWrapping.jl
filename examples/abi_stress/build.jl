# Build the abi_stress library end-to-end and emit C + Python wrappers.
# Run from this directory: `julia --project=. build.jl`

using JuliaLibWrapping

const HERE  = @__DIR__
const OUT   = joinpath(HERE, "out")
const ENTRY = joinpath(HERE, "src", "abi_stress.jl")

result = build_library(ENTRY,
    [CTarget(OUT, "abi_stress"),
     PythonTarget(OUT, "abi_stress_py", "abi_stress")];
    project = HERE,
    libname = "abi_stress",
    libdir  = OUT,
    verbose = true,
)

@info "Built abi_stress" library=result.library backend=result.backend
