# Public façade for the rcopt R package.
#
# JuliaLibWrapping creates this file once and never rewrites it, so
# edits here survive a rebuild. R/lowlevel.R is regenerated on every
# build.

take_opt <- function(o) {
  .jlr_take_opt(.jlr_COpt_Float64_arg(o))
}

give_opt <- function() {
  .jlr_COpt_Float64_ret(.jlr_give_opt())
}
