# Public façade for the rcdict R package.
#
# JuliaLibWrapping creates this file once and never rewrites it, so
# edits here survive a rebuild. R/lowlevel.R is regenerated on every
# build.

take_dict <- function(d) {
  .jlr_take_dict(.jlr_CDict_borrowed_Float64_arg(d))
}

give_dict <- function() {
  .jlr_CDict_owned_Float64_ret(.jlr_give_dict())
}
