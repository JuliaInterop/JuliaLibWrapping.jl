"""cdict_demo idiomatic façade.

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
    CDict_Float64,
)

def take_dict(d):
    _d = CDict_Float64.from_dict(d)
    return _lowlevel.take_dict(_d)

def give_dict():
    _result = _lowlevel.give_dict()
    try:
        _out = _result.as_dict()
    finally:
        _result.free()
    return _out

__all__ = ["CString", "CDict_Float64", "take_dict", "give_dict"]
