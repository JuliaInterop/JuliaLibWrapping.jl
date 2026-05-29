module JuliaLibWrappingJuliaCExt

# Implements the :juliac backend of `build_library` using the JuliaC.jl
# library API. See issues #16 (driver) and #17 (bundling).

using JuliaC: ImageRecipe, LinkRecipe, BundleRecipe,
              compile_products, link_products, bundle_products

# `LinkRecipe.rpath` accepts the documented public magic string "@bundle"
# (JuliaC exposes this in the LinkRecipe docstring); the corresponding
# `RPATH_BUNDLE` constant is internal, so we use the string form to keep
# the import surface public.
const _RPATH_BUNDLE = "@bundle"

function _build_library_juliac(entry::AbstractString;
                               project, libname, libdir, abi_path,
                               trim, compile_ccallable, verbose,
                               bundle::Bool = false,
                               bundle_dir::Union{Nothing,AbstractString} = nothing,
                               privatize::Bool = false)
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
