# Public façade for the rapiscale R package.
#
# JuliaLibWrapping creates this file once and never rewrites it, so
# edits here survive a rebuild. R/lowlevel.R is regenerated on every
# build.

# Scale every entry.
scale <- function(x, factor = 2.0, label) {
  .jlr_mylib_scale(x, factor, label)
}
