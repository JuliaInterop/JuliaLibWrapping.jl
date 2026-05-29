"""demo idiomatic façade.

This file is generated **once** by JuliaLibWrapping as a starter
façade. Functions whose arguments and return are all recognized
(primitives, `CArray{T,N}`, `CString`, direct `JLWStatus`)
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
    JLWStatus,
    ResultStruct,
    JLWError,
)

from ._lowlevel import compute  # TODO: hand-wrap — returns struct `ResultStruct` with embedded JLWStatus; idiomatic shaping depends on the other fields
from ._lowlevel import plain_add

def do_thing(x):
    _lowlevel.do_thing(x)

__all__ = ["JLWStatus", "ResultStruct", "JLWError", "do_thing", "compute", "plain_add"]
