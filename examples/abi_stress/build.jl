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

# To produce a self-contained Python package that can `pip install` and
# `import` without a Julia install on the user's machine (see issue #17),
# pass `bundle = true` and give the PythonTarget a `bundle_subdir`. The
# bundle is several hundred MiB, so this is opt-in.
#
# result = build_library(ENTRY,
#     [CTarget(OUT, "abi_stress"),
#      PythonTarget(OUT, "abi_stress_py", "abi_stress"; bundle_subdir = "bundle")];
#     project = HERE,
#     libname = "abi_stress",
#     libdir  = OUT,
#     bundle  = true,
#     verbose = true,
# )

@info "Built abi_stress" library=result.library backend=result.backend bundle=result.bundle_dir
