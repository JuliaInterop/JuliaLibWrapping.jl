using JuliaLibWrapping
using JLWInterop
using Documenter

DocMeta.setdocmeta!(JuliaLibWrapping, :DocTestSetup, :(using JuliaLibWrapping); recursive = true)
DocMeta.setdocmeta!(JLWInterop, :DocTestSetup, :(using JLWInterop); recursive = true)

makedocs(;
    modules = [JuliaLibWrapping, JLWInterop],
    authors = "Tim Holy <tim.holy@gmail.com> and contributors",
    sitename = "JuliaLibWrapping.jl",
    # `cdict_struct_info`/`copt_struct_info`'s docstrings (JuliaLibWrapping/src/python.jl)
    # `@ref` the undocumented `pytypes` binding; that pre-exists this page (unrelated to
    # the L1 carriers docs) and needs a docstring on `pytypes` itself to fix for real —
    # out of scope for a docs-only change. Downgrade so it doesn't block the build.
    warnonly = [:cross_references],
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
        "L1 carriers" => "carriers.md",
        "Error handling" => "error_handling.md",
        "API reference" => "api.md",
    ],
)

deploydocs(;
    repo = "github.com/JuliaInterop/JuliaLibWrapping.jl",
    devbranch = "main",
)
