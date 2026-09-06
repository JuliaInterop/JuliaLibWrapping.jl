"""cdict_int32_demo generated façade.

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
    CString_owned,
    CDict_borrowed_Int32,
    CDict_owned_Int32,
)

def take_dict_i32(d):
    _d = CDict_borrowed_Int32.from_dict(d)
    return _lowlevel.take_dict_i32(_d)

def give_dict_i32():
    _result = _lowlevel.give_dict_i32()
    try:
        _out = _result.as_dict()
    finally:
        _result.free()
    return _out

__all__ = ["CString_borrowed", "CString_owned", "CDict_borrowed_Int32", "CDict_owned_Int32", "take_dict_i32", "give_dict_i32"]
