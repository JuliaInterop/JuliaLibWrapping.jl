"""mylib_py idiomatic façade.

This file is generated **once** by JuliaLibWrapping as a starter
façade. Functions whose arguments and return are all recognized
(primitives, `CArray{owned,T,N}`, `CString{owned}`, direct `JLWStatus`)
are wrapped to accept and return idiomatic Python objects (numpy
arrays, `str`). Anything else is re-exported from `_lowlevel`
with a `TODO` comment naming what needs hand-wrapping.

Edit this file freely — JuliaLibWrapping will never overwrite it
on subsequent runs. Delete it to regenerate.

The mechanical bindings live in `_lowlevel.py` and are regenerated
on every `write_wrapper` call.
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
    _x = CVector_borrowed_Float64.from_numpy(x)
    _label = CString_borrowed.from_str(label)
    _r = _lowlevel.mylib_scale(_x, factor, _label)
    try:
        _out = np.array(_r.value.as_numpy(), copy=True)
    finally:
        _r.value.free()
    return _out

__all__ = ["CVector_borrowed_Float64", "CVector_owned_Float64", "CString_borrowed", "CString_owned", "JLWStatus", "JLWResult_CVector_owned_Float64", "JLWError", "scale"]
