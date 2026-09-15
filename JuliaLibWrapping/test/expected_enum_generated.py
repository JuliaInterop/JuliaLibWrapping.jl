"""enum_py generated façade.

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
    JLWResult_Float64,
    JLWResult_Int32,
    PenaltyKind,
    JLWError,
    _enum_coerce,
)

def scale_by(x, *, penalty=PenaltyKind.abslog1):
    """Scale `x`, squaring it when `penalty` is not `abslog1`."""
    _penalty = _enum_coerce(PenaltyKind, penalty)
    _r = _lowlevel.EnumFixture_scale_by(x, _penalty)
    return _r.value

def pick(x):
    """Classify the sign of `x` as a PenaltyKind."""
    _r = _lowlevel.EnumFixture_pick(x)
    return PenaltyKind(_r.value)

__all__ = ["JLWStatus", "JLWResult_Float64", "JLWResult_Int32", "PenaltyKind", "JLWError", "scale_by", "pick"]
