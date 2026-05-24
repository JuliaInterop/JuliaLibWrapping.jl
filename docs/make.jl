using JuliaLibWrapping
using JLWInterop
using Documenter

DocMeta.setdocmeta!(JuliaLibWrapping, :DocTestSetup, :(using JuliaLibWrapping); recursive=true)
DocMeta.setdocmeta!(JLWInterop, :DocTestSetup, :(using JLWInterop); recursive=true)

makedocs(;
    modules=[JuliaLibWrapping, JLWInterop],
    authors="Tim Holy <tim.holy@gmail.com> and contributors",
    sitename="JuliaLibWrapping.jl",
    format=Documenter.HTML(;
        canonical="https://JuliaInterop.github.io/JuliaLibWrapping.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "Concepts" => "concepts.md",
        "JLWInterop" => "jlwinterop.md",
        "Error handling" => "error_handling.md",
        "API reference" => "api.md",
    ],
)

deploydocs(;
    repo="github.com/JuliaInterop/JuliaLibWrapping.jl",
    devbranch="main",
)
