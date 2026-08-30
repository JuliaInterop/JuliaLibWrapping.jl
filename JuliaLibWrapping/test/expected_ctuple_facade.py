"""ctuple_demo idiomatic façade.

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
import numpy as np  # noqa: F401

from ._lowlevel import (
    CString_owned,
    JLWStatus,
    CVector_owned_Float64,
    CTuple2_CVector_owned_Float64_Int64,
    JLWResult_CTuple2_CVector_owned_Float64_Int64,
    JLWError,
)

def stats():
    _r = _lowlevel.stats()
    if _r.status.code != 0:
        raise JLWError(_r.status.code, bytes(_r.status.message).rstrip(b"\x00").decode("utf-8", errors="replace"))
    _v = _r.value
    try:
        _out = (np.array(_v.v1.as_numpy(), copy=True), _v.v2,)
    finally:
        _v.v1.free()
    return _out

__all__ = ["CString_owned", "JLWStatus", "CVector_owned_Float64", "CTuple2_CVector_owned_Float64_Int64", "JLWResult_CTuple2_CVector_owned_Float64_Int64", "JLWError", "stats"]
