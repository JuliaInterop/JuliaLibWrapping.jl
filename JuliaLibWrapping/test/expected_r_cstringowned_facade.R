# Public façade for the rcstringowned R package.
#
# JuliaLibWrapping creates this file once and never rewrites it, so
# edits here survive a rebuild. R/lowlevel.R is regenerated on every
# build.

give_greeting <- function() {
  .jlr_CString_owned_ret(.jlr_give_greeting())
}
