"""demo generated façade.

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
    JLWStatus,
    ResultStruct,
    JLWError,
)

from ._lowlevel import compute  # TODO: hand-wrap — returns struct `ResultStruct` with embedded JLWStatus; idiomatic shaping depends on the other fields
from ._lowlevel import plain_add

def do_thing(x):
    _lowlevel.do_thing(x)

__all__ = ["JLWStatus", "ResultStruct", "JLWError", "do_thing", "compute", "plain_add"]
