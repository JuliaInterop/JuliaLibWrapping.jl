# Public façade for the rcarray3 R package.
#
# JuliaLibWrapping creates this file once and never rewrites it, so
# edits here survive a rebuild. R/lowlevel.R is regenerated on every
# build.

sum3d <- function(a) {
  .jlr_sum3d(.jlr_CArray_borrowed_Float64_3_arg(a))
}
