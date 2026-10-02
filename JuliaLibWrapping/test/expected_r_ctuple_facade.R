# Public façade for the rctuple R package.
#
# JuliaLibWrapping creates this file once and never rewrites it, so
# edits here survive a rebuild. R/lowlevel.R is regenerated on every
# build.

stats <- function() {
  .jlr_CNTuple_2_Tuple_CVector_owned_Float64_Int64_ret(.jlr_stats())
}

pair <- function() {
  .jlr_CNTuple_2_Tuple_CVector_owned_Float64_CVector_owned_Float64_ret(.jlr_pair())
}

bundle <- function() {
  .jlr_CNTuple_4_Tuple_CString_owned_CStrArray_owned_CDict_owned_Float64_COpt_Float64_ret(.jlr_bundle())
}
