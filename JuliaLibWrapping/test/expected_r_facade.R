# Public façade for the rprimitives R package.
#
# JuliaLibWrapping creates this file once and never rewrites it, so
# edits here survive a rebuild. R/lowlevel.R is regenerated on every
# build.

# TODO: hand-wrap — argument 1: argument has type `Ptr{Nothing}`.
# The low-level binding is exposed unchanged; see R/lowlevel.R.
zero_first <- function(...) {
  .jlr_zero_first(...)
}

# TODO: hand-wrap — argument 1: argument has type `Handle`.
# The low-level binding is exposed unchanged; see R/lowlevel.R.
next_chunk <- function(...) {
  .jlr_next_chunk(...)
}

# TODO: hand-wrap — return: return type `Ptr{Ptr{Nothing}}` is not mapped.
# The low-level binding is exposed unchanged; see R/lowlevel.R.
chunk_table <- function(...) {
  .jlr_chunk_table(...)
}
