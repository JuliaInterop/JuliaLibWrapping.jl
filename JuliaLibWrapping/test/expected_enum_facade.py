"""enum_py idiomatic façade.

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
