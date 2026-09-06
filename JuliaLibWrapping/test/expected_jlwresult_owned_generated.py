"""jlwresult_owned_demo generated façade.

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
