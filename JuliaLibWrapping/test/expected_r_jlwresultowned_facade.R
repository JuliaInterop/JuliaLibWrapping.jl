# Public façade for the rjlwresultowned R package.
#
# JuliaLibWrapping creates this file once and never rewrites it, so
# edits here survive a rebuild. R/lowlevel.R is regenerated on every
# build.

greet <- function() {
  .jlr_CString_owned_ret(.jlr_greet())
}

tally <- function() {
  .jlr_CDict_owned_Float64_ret(.jlr_tally())
}
