"""jlwresult_owned_demo idiomatic façade.

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

from ._lowlevel import (
    CString_owned,
    CDict_owned_Float64,
    JLWStatus,
    JLWResult_CString_owned,
    JLWResult_CDict_owned_Float64,
    JLWError,
)

def greet():
    _r = _lowlevel.greet()
    try:
        _out = _r.value.as_str()
    finally:
        _r.value.free()
    return _out

def tally():
    _r = _lowlevel.tally()
    try:
        _out = _r.value.as_dict()
    finally:
        _r.value.free()
    return _out

__all__ = ["CString_owned", "CDict_owned_Float64", "JLWStatus", "JLWResult_CString_owned", "JLWResult_CDict_owned_Float64", "JLWError", "greet", "tally"]
