# Public façade for the renum R package.
#
# JuliaLibWrapping creates this file once and never rewrites it, so
# edits here survive a rebuild. R/lowlevel.R is regenerated on every
# build.

# Scale `x`, squaring it when `penalty` is not `abslog1`.
scale_by <- function(x, penalty = "abslog1") {
  .jlr_EnumFixture_scale_by(x, .jlr_enum_coerce("PenaltyKind", penalty, "penalty"))
}

# Classify the sign of `x` as a PenaltyKind.
pick <- function(x) {
  .jlr_enum_name("PenaltyKind", .jlr_EnumFixture_pick(x))
}
