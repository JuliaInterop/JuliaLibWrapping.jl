"""carray_owned_demo generated façade.

Idiomatic wrappers over `_lowlevel`: functions whose arguments and return
are all recognized (primitives, carriers such as `CArray`, `CString`,
`CDict`, `COpt`, enums, and `JLWResult`/`JLWStatus` returns) accept and
return Python objects (numpy arrays, `str`, `dict`, ...). Anything else is
re-exported from `_lowlevel` with a `TODO` comment naming what needs
hand-wrapping.

This file is regenerated on every build. Do not edit it; put hand-written
code in `_facade.py`, which imports everything defined here.
"""
from . import _lowlevel  # noqa: F401
import numpy as np  # noqa: F401

from ._lowlevel import (
    CString_owned,
    CVector_owned_Float64,
)

def give_vec():
    _result = _lowlevel.give_vec()
    try:
        _out = np.array(_result.as_numpy(), copy=True)
    finally:
        _result.free()
    return _out

__all__ = ["CString_owned", "CVector_owned_Float64", "give_vec"]
