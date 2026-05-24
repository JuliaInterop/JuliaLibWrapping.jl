using JuliaLibWrapping
using Documenter

DocMeta.setdocmeta!(JuliaLibWrapping, :DocTestSetup, :(using JuliaLibWrapping); recursive=true)

makedocs(;
    modules=[JuliaLibWrapping],
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
        "Error handling" => "error_handling.md",
        "API reference" => "api.md",
    ],
    warnonly=[:cross_references],  # CVector/CMatrix live in JLWInterop
)

deploydocs(;
    repo="github.com/JuliaInterop/JuliaLibWrapping.jl",
    devbranch="main",
)
