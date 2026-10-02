# Public façade for the rcarrayowned R package.
#
# JuliaLibWrapping creates this file once and never rewrites it, so
# edits here survive a rebuild. R/lowlevel.R is regenerated on every
# build.

give_vec <- function() {
  .jlr_CVector_owned_Float64_ret(.jlr_give_vec())
}
