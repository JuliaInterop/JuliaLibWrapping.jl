# Public façade for the rcstrarray R package.
#
# JuliaLibWrapping creates this file once and never rewrites it, so
# edits here survive a rebuild. R/lowlevel.R is regenerated on every
# build.

take_strs <- function(a) {
  .jlr_take_strs(.jlr_CStrArray_borrowed_arg(a))
}

give_strs <- function() {
  .jlr_CStrArray_owned_ret(.jlr_give_strs())
}
