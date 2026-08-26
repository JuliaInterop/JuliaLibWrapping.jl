"""cstrarray_demo idiomatic façade.

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

from ._lowlevel import (
    CString,
    CStrArray_borrowed,
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

__all__ = ["CString", "CStrArray_borrowed", "CStrArray_owned", "take_strs", "give_strs"]
