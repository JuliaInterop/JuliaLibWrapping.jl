module JuliaLibWrappingJuliaCExt

# `build_library` backend using the JuliaC.jl API.

using JuliaC: ImageRecipe, LinkRecipe, BundleRecipe,
              compile_products, link_products, bundle_products

# Use JuliaC's public `"@bundle"` rpath value.
const _RPATH_BUNDLE = "@bundle"

function _build_library_juliac(entry::AbstractString;
                               project, libname, libdir, abi_path,
                               trim, compile_ccallable, verbose,
                               bundle::Bool = false,
                               bundle_dir::Union{Nothing,AbstractString} = nothing,
                               privatize::Bool = false,
                               cpu_target::Union{Nothing,AbstractString} = nothing)
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
        cpu_target = cpu_target === nothing ? nothing : String(cpu_target),
    )
    # Bundling requires the bundle-relative rpath at link time; otherwise the
    # produced .so bakes in absolute paths to the host's Julia install and
    # cannot be relocated into a wheel.
    link = LinkRecipe(; image_recipe = img, outname = out_lib,
                      rpath = bundle ? _RPATH_BUNDLE : "@julia")
    compile_products(img)
    link_products(link)
    if bundle
        bundle_dir === nothing && error("internal: bundle_dir must be set when bundle = true")
        recipe = BundleRecipe(; link_recipe = link,
                              output_dir = String(bundle_dir),
                              privatize = privatize)
        bundle_products(recipe)
    end
    return
end

end # module
