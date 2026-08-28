# Build the boundary example library end-to-end with a bundled Python package.
# Run from this directory with a recent enough Julia 1.13:
#
#   julia build.jl
#
# Output lands in `out/`. The build-env at `./build-env/` must be
# instantiated once:
#
#   julia --project=build-env -e 'using Pkg; Pkg.instantiate()'
#
# The library is built from `lib/`, the binding layer, not from the package
# beside it. `lib/Project.toml` names both the package and JLWInterop as
# relative `[sources]` paths, which `build_library` resolves by compiling a
# temporary copy with those paths made absolute — so nothing here or in that
# file carries a machine-specific path.
#
# Once JuliaLibWrapping and JLWInterop are registered, the `[sources]` entries
# go and this script is the four lines below.
#
# `using JuliaC` is what activates JuliaLibWrapping's weak dependency
# on JuliaC.jl — without it, `build_library` errors with a hint.

const HERE = @__DIR__

push!(LOAD_PATH, joinpath(HERE, "build-env"))
using JuliaLibWrapping, JuliaC

result = standard_build(
    joinpath(HERE, "lib");
    libname = "boundary",
    out = joinpath(HERE, "out"),
    verbose = true,
)

@info "Built boundary" library = result.library bundle = result.bundle_dir
