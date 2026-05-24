module JuliaLibWrappingJuliaCExt

# Implements the :juliac backend of `build_library` using the JuliaC.jl
# library API. See issue #16.

using JuliaC: ImageRecipe, LinkRecipe, compile_products, link_products

function _build_library_juliac(entry::AbstractString;
                               project, libname, libdir, abi_path,
                               trim, compile_ccallable, verbose)
    out_lib = joinpath(libdir, libname)
    trim_mode = trim === nothing ? "no" : String(trim)
    img = ImageRecipe(;
        output_type = "--output-lib",
        file = String(entry),
        project = String(project),
        trim_mode,
        add_ccallables = compile_ccallable,
        export_abi = String(abi_path),
        verbose,
    )
    link = LinkRecipe(; image_recipe = img, outname = out_lib)
    compile_products(img)
    link_products(link)
    return
end

end # module
