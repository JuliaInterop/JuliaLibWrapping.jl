"""cstrarray_demo generated façade.

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

from ._lowlevel import (
    CString_borrowed,
    CStrArray_borrowed,
    CString_owned,
    CStrArray_owned,
)

def take_strs(a):
    _a = CStrArray_borrowed.from_list(a)
    return _lowlevel.take_strs(_a)

def give_strs():
    _result = _lowlevel.give_strs()
    try:
        _out = _result.as_list()
    finally:
        _result.free()
    return _out

__all__ = ["CString_borrowed", "CStrArray_borrowed", "CString_owned", "CStrArray_owned", "take_strs", "give_strs"]
