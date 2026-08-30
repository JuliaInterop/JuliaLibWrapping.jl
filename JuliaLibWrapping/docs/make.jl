using JuliaLibWrapping
using JLWInterop
using Documenter

DocMeta.setdocmeta!(JuliaLibWrapping, :DocTestSetup, :(using JuliaLibWrapping); recursive = true)
DocMeta.setdocmeta!(JLWInterop, :DocTestSetup, :(using JLWInterop); recursive = true)

makedocs(;
    modules = [JuliaLibWrapping, JLWInterop],
    authors = "Tim Holy <tim.holy@gmail.com> and contributors",
    sitename = "JuliaLibWrapping.jl",
    format = Documenter.HTML(;
        canonical = "https://JuliaInterop.github.io/JuliaLibWrapping.jl",
        edit_link = "main",
        assets = String[],
    ),
    pages = [
        "Home" => "index.md",
        "Tutorial" => "tutorial.md",
        "Concepts" => "concepts.md",
        "JLWInterop" => "jlwinterop.md",
        "Error handling" => "error_handling.md",
        "Annotating a library with `@api`" => "annotations.md",
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
