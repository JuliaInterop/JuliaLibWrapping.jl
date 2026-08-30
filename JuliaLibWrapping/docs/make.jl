using JuliaLibWrapping
using JLWInterop
using Documenter

DocMeta.setdocmeta!(JuliaLibWrapping, :DocTestSetup, :(using JuliaLibWrapping); recursive = true)
DocMeta.setdocmeta!(JLWInterop, :DocTestSetup, :(using JLWInterop); recursive = true)

makedocs(;
    modules = [JuliaLibWrapping, JLWInterop],
    checkdocs = :exports,
    authors = "Tim Holy <tim.holy@gmail.com> and contributors",
    sitename = "JuliaLibWrapping.jl",
    format = Documenter.HTML(;
        canonical = "https://JuliaInterop.github.io/JuliaLibWrapping.jl",
        edit_link = "main",
        assets = String[],
    ),
    pages = [
        "Home" => "index.md",
        "Getting started" => [
            "Your first wrapper" => "quickstart.md",
        ],
        "Authoring libraries" => [
            "Declaring an API with `@api`" => "annotations.md",
            "Supported Julia types" => "types.md",
            "Hand-written ABI entrypoints" => [
                "Custom OLS tutorial" => "tutorial.md",
                "Manual error status" => "error_handling.md",
            ],
        ],
        "Generated bindings" => [
            "Python package and façade" => "python.md",
            "JLWInterop carriers" => "jlwinterop.md",
        ],
        "Building and distribution" => "building.md",
        "Concepts and extension" => [
            "Architecture and metadata flow" => "architecture.md",
            "Adding a target backend" => "extending.md",
            "Pre-0.2 concepts index" => "concepts.md",
        ],
        "API reference" => "api.md",
    ],
)

deploydocs(;
    repo = "github.com/JuliaInterop/JuliaLibWrapping.jl",
    devbranch = "main",
    # TagBot tags releases of this subdir package as JuliaLibWrapping-vX.Y.Z;
    # without the prefix, deploydocs skips tag builds and never deploys
    # versioned (stable) docs.
    tag_prefix = "JuliaLibWrapping-",
)
