"""Smoke test for the installed `ols_py` wheel.

Run against an already-installed wheel (no pytest dependency):

    pip install dist/*.whl
    python JuliaLibWrapping/examples/ols/test/smoke.py

Exits nonzero (via AssertionError) on any failure.
"""
import numpy as np

import ols_py


def _fit(X, y):
    """Call the low-level `fit` entrypoint; return (coeffs, r_squared).

    `fit`'s return type (`FitResult`) embeds a `JLWStatus`, so
    JuliaLibWrapping's façade auto-wrapper leaves it as a mechanical
    re-export: callers pass `CMatrix_Float64`/`CVector_Float64` wrappers
    directly rather than bare numpy arrays.
    """
    n, p = X.shape
    Xf = np.asfortranarray(X, dtype=np.float64)
    yf = np.asfortranarray(y, dtype=np.float64)
    coeffs_buf = np.zeros(p, dtype=np.float64)

    X_c = ols_py.CMatrix_Float64.from_numpy(Xf)
    y_c = ols_py.CVector_Float64.from_numpy(yf)
    coeffs_c = ols_py.CVector_Float64.from_numpy(coeffs_buf)

    result = ols_py.fit(X_c, y_c, coeffs_c)
    assert result.status.code == 0, (
        result.status.code,
        bytes(result.status.message).rstrip(b"\x00").decode("utf-8", errors="replace"),
    )
    # `coeffs_buf` is caller-allocated storage that `fit` writes into
    # directly; `result.coeffs` aliases the same buffer.
    return coeffs_buf.copy(), result.r_squared


def test_fit_matches_numpy_lstsq():
    rng = np.random.default_rng(0)
    n, p = 20, 3
    X = np.column_stack([np.ones(n), rng.standard_normal((n, p - 1))])
    true_coeffs = np.array([1.5, -2.0, 0.75])
    y = X @ true_coeffs + 0.01 * rng.standard_normal(n)

    coeffs, r_squared = _fit(X, y)
    expected, *_ = np.linalg.lstsq(X, y, rcond=None)

    assert np.allclose(coeffs, expected, atol=1e-8), (coeffs, expected)
    assert 0.0 <= r_squared <= 1.0, r_squared


def test_predict_matches_matrix_multiply():
    # `predict`'s args and return (a direct `JLWStatus`) are all recognized
    # vocabulary types, so the façade auto-wraps it to accept/return plain
    # numpy arrays; `out` is written in place.
    rng = np.random.default_rng(1)
    n, p = 10, 3
    X = np.asfortranarray(
        np.column_stack([np.ones(n), rng.standard_normal((n, p - 1))]), dtype=np.float64
    )
    coeffs = np.array([0.5, 1.0, -1.0], dtype=np.float64)
    out = np.zeros(n, dtype=np.float64)

    ols_py.predict(coeffs, X, out)

    expected = X @ coeffs
    assert np.allclose(out, expected, atol=1e-8), (out, expected)


def test_predict_raises_on_length_mismatch():
    X = np.asfortranarray(np.ones((5, 3)), dtype=np.float64)
    coeffs = np.ones(2, dtype=np.float64)  # wrong: X has 3 columns
    out = np.zeros(5, dtype=np.float64)
    try:
        ols_py.predict(coeffs, X, out)
    except ols_py.JLWError as exc:
        assert exc.code != 0
    else:
        raise AssertionError("expected JLWError for mismatched coeffs length")


if __name__ == "__main__":
    test_fit_matches_numpy_lstsq()
    test_predict_matches_matrix_multiply()
    test_predict_raises_on_length_mismatch()
    print("ols_py smoke test passed")
