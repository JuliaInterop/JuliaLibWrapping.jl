"""copt_demo idiomatic façade.

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
    COpt_Float64,
)

def take_opt(o):
    _o = COpt_Float64.from_optional(o)
    return _lowlevel.take_opt(_o)

def give_opt():
    _result = _lowlevel.give_opt()
    return _result.as_optional()

__all__ = ["COpt_Float64", "take_opt", "give_opt"]
