"""mylib_py generated façade.

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
    CVector_borrowed_Float64,
    CVector_owned_Float64,
    CString_borrowed,
    CString_owned,
    JLWStatus,
    JLWResult_CVector_owned_Float64,
    JLWError,
)

def scale(x, *, factor=2.0, label):
    """Scale every entry."""
    _x = CVector_borrowed_Float64.from_numpy(np.ascontiguousarray(x, dtype="float64"))
    _label = CString_borrowed.from_str(label)
    _r = _lowlevel.mylib_scale(_x, factor, _label)
    try:
        _out = np.array(_r.value.as_numpy(), copy=True)
    finally:
        _r.value.free()
    return _out

__all__ = ["CVector_borrowed_Float64", "CVector_owned_Float64", "CString_borrowed", "CString_owned", "JLWStatus", "JLWResult_CVector_owned_Float64", "JLWError", "scale"]
