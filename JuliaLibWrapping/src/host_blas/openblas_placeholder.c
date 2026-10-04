/*
 * Placeholder for the bundled OpenBLAS slot in a `host_blas` build.
 *
 * `OpenBLAS_jll`, a stdlib baked into Julia's sysimage, dlopens a library
 * named `libopenblas64_.so` during module initialization. When the real
 * OpenBLAS is removed from the bundle, that dlopen still has to succeed, and
 * libblastrampoline still has to classify the result as an ILP64 BLAS so
 * that `LinearAlgebra` initializes.
 *
 * This file exports only what libblastrampoline's autodetection probes:
 *
 *   isamax_64_  supplies the `64_` symbol suffix
 *   ilaver_64_  reports a positive version, so the interface is ILP64
 *   zdotc_64_, cdotc_64_  zero their return location, satisfying the
 *                         complex-return-style probe
 *   sdot_64_    returns 0.25, satisfying the gfortran f2c probe
 *
 * It implements no BLAS operation. Nothing calls it: the takeover retargets
 * every routine that exists in the host, and the build asserts that no
 * remaining bundle library exports `dgemm`.
 */
#include <stdint.h>
#include <complex.h>

void ilaver_64_(int64_t *major, int64_t *minor, int64_t *patch)
{
    *major = 3;
    *minor = 0;
    *patch = 0;
}

int64_t isamax_64_(int64_t *n, float *x, int64_t *incx)
{
    (void)x;
    (void)incx;
    return *n <= 0 ? 0 : 1;
}

void zdotc_64_(double _Complex *ret, int64_t *n, double _Complex *x,
               int64_t *incx, double _Complex *y, int64_t *incy)
{
    (void)n; (void)x; (void)incx; (void)y; (void)incy;
    *ret = 0.0;
}

void cdotc_64_(float _Complex *ret, int64_t *n, float _Complex *x,
               int64_t *incx, float _Complex *y, int64_t *incy)
{
    (void)n; (void)x; (void)incx; (void)y; (void)incy;
    *ret = 0.0f;
}

float sdot_64_(int64_t *n, float *x, int64_t *incx, float *y, int64_t *incy)
{
    (void)n; (void)x; (void)incx; (void)y; (void)incy;
    return 0.25f;
}
