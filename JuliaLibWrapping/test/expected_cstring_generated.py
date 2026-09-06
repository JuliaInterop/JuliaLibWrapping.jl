"""cstring_demo generated façade.

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
)

def greeting_length(s):
    _s = CString_borrowed.from_str(s)
    return _lowlevel.greeting_length(_s)

def greeting():
    _result = _lowlevel.greeting()
    return _result.as_str()

__all__ = ["CString_borrowed", "greeting_length", "greeting"]
