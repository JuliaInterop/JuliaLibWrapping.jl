# Smoke test for the installed `boundary` R package.
#
# Run against an already-installed package (Rscript is enough):
#
#     R CMD INSTALL -l <libdir> out/boundary
#     R_LIBS=<libdir> BOUNDARY_R_LIBRARY=<path/to/boundary.so> \
#         Rscript examples/boundary/test/smoke.R
#
# The `BOUNDARY_R_LIBRARY` override points the loader at a library built
# outside the package; a bundled package finds its own copy.
#
# Stops with an error (nonzero exit) on any failure.

library(boundary)

check <- function(condition, message) {
  if (!isTRUE(condition)) {
    stop(message, call. = FALSE)
  }
}

# Scalars, strings, and keyword defaults.
check(identical(count_strs(c("a", "bb")), 2), "count_strs")
check(identical(upcase_strs(c("ab", "wörld")), c("AB", "WÖRLD")), "upcase_strs")
check(identical(sum_dict(c(x = 1.5, y = 2.5)), 4), "sum_dict")
check(identical(sum_dict(c(x = 1.5), scale = 2), 3), "sum_dict scale")
check(identical(str_len("wörld"), 6), "str_len counts UTF-8 code units")
check(identical(shout("héllo"), "HÉLLO"), "shout frees an owned string")

# Arrays and matrices are borrowed directly from an R vector or matrix.
check(identical(scale_vec(c(1, 2)), c(2, 4)), "scale_vec")
check(identical(scale_vec(c(1, 2), factor = 3), c(3, 6)), "scale_vec factor")

# An empty argument is legal; the generated builder points it at a dummy
# byte rather than failing on `as.externalptr(raw(0))`.
check(identical(count_strs(character(0)), 0), "count_strs empty")
check(identical(scale_vec(numeric(0)), numeric(0)), "scale_vec empty")

# Optional scalars: NULL in, NULL out.
check(identical(maybe_sqrt(9), 3), "maybe_sqrt(9)")
check(is.null(maybe_sqrt(-1)), "maybe_sqrt(-1)")
check(is.null(maybe_sqrt(NULL)), "maybe_sqrt(NULL)")

# Dictionaries: a named vector in and out, in the library's iteration order.
md <- make_dict(3)
check(identical(md[c("k1", "k2", "k3")], c(k1 = 1, k2 = 2, k3 = 3)), "make_dict")
check(identical(echo_dict(c(k = 1)), c(k = 1)), "echo_dict")
check(identical(echo_strs(c("x", "y")), c("x", "y")), "echo_strs")

# Tuple returns become an unnamed list; owning elements are freed.
st <- stats(c(1, 2, 3))
check(identical(st[[1]], c(2, 4, 6)) && identical(st[[2]], 3), "stats")

bn <- bundle("a bb ccc")
check(identical(bn[[1]], "A BB CCC"), "bundle shout")
check(identical(bn[[2]], c("a", "bb", "ccc")), "bundle words")
check(identical(bn[[3]][c("a", "bb", "ccc")], c(a = 1, bb = 2, ccc = 3)), "bundle lengths")
check(identical(bn[[4]], 2), "bundle mean")
# An empty input leaves the optional mean absent.
check(is.null(bundle("")[[4]]), "bundle empty mean")

mm <- maximum_marginals(matrix(c(1, 4, 3, 2), 2, 2))
check(identical(mm[[1]], c(4, 3)) && identical(mm[[2]], c(3, 4)), "maximum_marginals")

# Enums accept a member name or the underlying integer, and come back named.
check(identical(round_value(3.2), 3), "round_value default")
check(identical(round_value(3.7, mode = "round_down"), 3), "round_value name")
check(identical(round_value(3.2, mode = "round_up"), 4), "round_value up")
check(identical(round_value(3.2, mode = 2), 4), "round_value ordinal")
check(identical(sign_mode(5), "round_up"), "sign_mode up")
check(identical(sign_mode(-5), "round_down"), "sign_mode down")
check(identical(sign_mode(0), "round_nearest"), "sign_mode zero")

enum_error <- tryCatch(round_value(1, mode = "bogus"), error = function(e) e)
check(inherits(enum_error, "jlw_argument"), "a bad enum name raises jlw_argument")
out_of_range <- tryCatch(round_value(1, mode = 99), error = function(e) e)
check(
  inherits(out_of_range, "jlw_argument") &&
    grepl("invalid value 99", conditionMessage(out_of_range), fixed = TRUE),
  "an out-of-range enum raises jlw_argument"
)

# Errors carry the code and a `jlw_*` class, and every class inherits
# `jlw_error`.
err <- tryCatch(boom(7), error = function(e) e)
check(inherits(err, "jlw_error"), "boom raises jlw_error")
check(grepl("boom 7", conditionMessage(err), fixed = TRUE), "boom message")
check(is.null(check_positive(1)), "check_positive passes")
neg <- tryCatch(check_positive(-1), error = function(e) e)
check(inherits(neg, "jlw_error"), "check_positive raises a JLW condition")
check(identical(neg$code, 1L), "the condition carries its code")

# A raw pointer and a library-registered struct cross unconverted.
buf <- as.double(c(1, 2, 4))
check(identical(sum_at(rdyncall::as.externalptr(buf), 3), 7), "sum_at")
bad_len <- tryCatch(sum_at(rdyncall::as.externalptr(buf), -1), error = function(e) e)
check(grepl("negative length", conditionMessage(bad_len), fixed = TRUE), "sum_at error")

extent <- rdyncall::cdata("Extent")
extent$lo <- 1L
extent$hi <- 5L
wide <- widen(extent, 2L)
check(wide$lo == -1L && wide$hi == 7L, "widen")

# Owning returns are copied and freed.
check(identical(make_vec(4), c(1, 2, 3, 4)), "make_vec")
check(identical(make_str(), "héllo"), "make_str")

# Repeat the owning paths so a leak or double free would show up under a
# memory checker.
for (i in seq_len(1000)) {
  upcase_strs(c("x", "y", "z"))
  make_dict(5)
  scale_vec(c(1, 2))
  shout("héllo")
  stats(c(1, 2, 3))
  bundle("a bb ccc")
}

cat("boundary smoke: OK\n")
