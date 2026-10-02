# Public façade for the rscalars R package.
#
# JuliaLibWrapping creates this file once and never rewrites it, so
# edits here survive a rebuild. R/lowlevel.R is regenerated on every
# build.

plain_add <- function(a, b) {
  .jlr_plain_add(a, b)
}

do_thing <- function(x) {
  .jlr_do_thing(x)
}

scale_value <- function(x) {
  .jlr_scale_value(x)
}
