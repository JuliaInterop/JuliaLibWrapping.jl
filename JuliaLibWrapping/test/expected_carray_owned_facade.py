"""carray_owned_demo idiomatic façade.

This file is generated **once** by JuliaLibWrapping as a starter
façade. Functions whose arguments and return are all recognized
(primitives, `CArray{owned,T,N}`, `CString`, direct `JLWStatus`)
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
    Nothing,
    CString,
    CVector_owned_Float64,
)

def give_vec():
    _result = _lowlevel.give_vec()
    try:
        _out = np.array(_result.as_numpy(), copy=True)
    finally:
        _result.free()
    return _out

__all__ = ["Nothing", "CString", "CVector_owned_Float64", "give_vec"]
