# Smoke test for the installed `ols` R package.
#
# Run against an already-installed package (Rscript is enough):
#
#     R CMD INSTALL -l <libdir> out/ols
#     R_LIBS=<libdir> OLS_R_LIBRARY=<path/to/ols.so> \
#         Rscript examples/ols/test/smoke.R
#
# `ols` exposes hand-written `Base.@ccallable` entrypoints, so the generated
# façade is mechanical. `predict` takes plain R vectors; `fit` and
# `summary_report` pass their carriers through unchanged and are called
# through the package's internal builders, exactly as the Python smoke test
# passes `ctypes` wrappers.
#
# Stops with an error (nonzero exit) on any failure.

library(ols)

check <- function(condition, message) {
  if (!isTRUE(condition)) {
    stop(message, call. = FALSE)
  }
}

arg <- ols:::.jlr_CVector_borrowed_Float64_arg
mat_arg <- ols:::.jlr_CMatrix_borrowed_Float64_arg

# `fit` writes its coefficients into caller-provided storage and returns a
# struct embedding a `JLWStatus`.
X <- matrix(c(1, 1, 1, 1, 0, 1, 2, 3), 4, 2)
y <- as.double(c(1, 2.5, 4, 5.5))
coeffs_buf <- as.double(c(0, 0))

fit <- ols:::.jlr_fit(mat_arg(X), arg(y), arg(coeffs_buf))
check(identical(fit$status$code, 0L), "fit status is zero")
check(abs(fit$r_squared - 1) < 1e-8, "fit recovers a perfect fit")

# The returned `coeffs` carrier aliases `coeffs_buf`; reading it converts the
# borrowed vector.
fit_coeffs <- ols:::.jlr_CVector_borrowed_Float64_ret(fit$coeffs)
check(max(abs(coeffs_buf - c(1, 1.5))) < 1e-8, "fit coefficients")
check(max(abs(fit_coeffs - c(1, 1.5))) < 1e-8, "the returned carrier aliases the buffer")

# `predict`'s arguments and return are all recognized, so the façade takes
# plain R values and raises on failure.
out <- as.double(c(0, 0, 0, 0))
check(is.null(predict(c(1, 2), X, out)), "predict returns NULL on success")
check(max(abs(out - c(1, 3, 5, 7))) < 1e-8, "predict writes its output")

# A wrong coefficient count and a wrong output length both raise, with the
# status code carried on the condition.
bad_coeffs <- tryCatch(predict(c(1, 2, 3), X, out), error = function(e) e)
check(inherits(bad_coeffs, "jlw_error"), "a wrong coefficient count raises")
check(identical(bad_coeffs$code, 1L), "the coefficient error carries code 1")
check(
  grepl("coeffs length must match X cols", conditionMessage(bad_coeffs), fixed = TRUE),
  "the coefficient error message"
)

bad_out <- tryCatch(predict(c(1, 2), X, as.double(c(0, 0))), error = function(e) e)
check(inherits(bad_out, "jlw_argument"), "a wrong output length raises jlw_argument")
check(
  grepl("out length must match X rows", conditionMessage(bad_out), fixed = TRUE),
  "the output error message"
)

# `summary_report` writes into a caller-allocated `CString` buffer. The
# generated builder sizes the capacity from the R string, so build a cdata
# with the capacity this call needs over a raw vector.
report <- function(result, capacity = 200L) {
  buffer <- raw(capacity)
  carrier <- rdyncall::cdata("CString_borrowed")
  carrier$length <- capacity
  carrier$data <- rdyncall::as.externalptr(buffer)
  summary_report(result, carrier)
  ols:::.jlr_CString_borrowed_ret(carrier)
}

text <- report(fit)
check(grepl("2 coefficients", text, fixed = TRUE), "summary_report reports the count")
check(grepl("R^2 = 1.0", text, fixed = TRUE), "summary_report reports R squared")

# A fit whose status is not zero cannot be reported on; the bridge raises.
short_y <- as.double(c(1, 2, 3))
bad_fit <- ols:::.jlr_fit(mat_arg(X), arg(short_y), arg(as.double(c(0, 0))))
check(identical(bad_fit$status$code, 1L), "a length mismatch leaves a nonzero status")
not_reportable <- tryCatch(report(bad_fit), error = function(e) e)
check(inherits(not_reportable, "jlw_error"), "reporting a failed fit raises")
check(
  grepl("nothing to report", conditionMessage(not_reportable), fixed = TRUE),
  "the not-reportable message"
)

# A buffer that is too small is an error, not a truncated write.
too_small <- tryCatch(report(fit, capacity = 4L), error = function(e) e)
check(
  grepl("report buffer too small", conditionMessage(too_small), fixed = TRUE),
  "a short report buffer raises"
)

# Repeat the owning paths so a leak or double free would show up under a
# memory checker.
for (i in seq_len(1000)) {
  buffer <- as.double(c(0, 0))
  ols:::.jlr_fit(mat_arg(X), arg(y), arg(buffer))
  predict(c(1, 2), X, as.double(c(0, 0, 0, 0)))
  report(fit)
}

cat("ols smoke: OK\n")
