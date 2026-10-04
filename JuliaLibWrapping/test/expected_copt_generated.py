"""copt_demo generated façade.

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
    COpt_Float64,
)

def take_opt(o):
    _o = COpt_Float64.from_optional(o)
    return _lowlevel.take_opt(_o)

def give_opt():
    _result = _lowlevel.give_opt()
    return _result.as_optional()

__all__ = ["COpt_Float64", "take_opt", "give_opt"]
