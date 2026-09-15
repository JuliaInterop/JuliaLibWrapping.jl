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

def _scale_1(x, *, factor=2.0, label):
    """Scale every entry."""
    _x = CVector_borrowed_Float64.from_numpy(x)
    _label = CString_borrowed.from_str(label)
    _r = _lowlevel.mylib_scale(_x, factor, _label)
    try:
        _out = np.array(_r.value.as_numpy(), copy=True)
    finally:
        _r.value.free()
    return _out

def _scale_2(x, y):
    """Scale `x` by the entries of `y`."""
    _x = CVector_borrowed_Float64.from_numpy(x)
    _y = CVector_borrowed_Float64.from_numpy(y)
    _r = _lowlevel.mylib_scale_2(_x, _y)
    try:
        _out = np.array(_r.value.as_numpy(), copy=True)
    finally:
        _r.value.free()
    return _out

def scale(*args, **kwargs):
    """Scale every entry.

    Scale `x` by the entries of `y`."""
    if len(args) == 1:
        return _scale_1(*args, **kwargs)
    if len(args) == 2:
        return _scale_2(*args, **kwargs)
    raise TypeError(
        f"scale() takes 1 or 2 positional arguments but {len(args)} were given"
    )

__all__ = ["CVector_borrowed_Float64", "CVector_owned_Float64", "CString_borrowed", "CString_owned", "JLWStatus", "JLWResult_CVector_owned_Float64", "JLWError", "scale"]
