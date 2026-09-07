"""cmatrix_demo generated façade.

Idiomatic wrappers over `_lowlevel`: functions whose arguments and return
are all recognized (primitives, carriers such as `CArray`, `CString`,
`CDict`, `COpt`, enums, and `JLWResult`/`JLWStatus` returns) accept and
return Python objects (numpy arrays, `str`, `dict`, ...). Anything else is
re-exported from `_lowlevel` with a `TODO` comment naming what needs
hand-wrapping.

This file is regenerated on every build. Do not edit it; put hand-written
code in `_facade.py`, which imports everything defined here.

Array arguments are coerced before the call: `np.asfortranarray(x, dtype=...)`
for arrays of two or more dimensions and `np.ascontiguousarray(x, dtype=...)`
for vectors. Input with the wrong dtype or memory order is copied silently.
"""
from . import _lowlevel  # noqa: F401
import numpy as np  # noqa: F401

from ._lowlevel import (
    CMatrix_borrowed_Float64,
)

def trace_cmatrix(m):
    _m = CMatrix_borrowed_Float64.from_numpy(np.asfortranarray(m, dtype="float64"))
    return _lowlevel.trace_cmatrix(_m)

__all__ = ["CMatrix_borrowed_Float64", "trace_cmatrix"]
