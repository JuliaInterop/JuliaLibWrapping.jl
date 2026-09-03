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
    Tuple_CVector_owned_Float64_Int64,
    CNTuple_2_Tuple_CVector_owned_Float64_Int64,
    JLWResult_CNTuple_2_Tuple_CVector_owned_Float64_Int64,
    CNTuple_2_Tuple_CVector_owned_Float64_CVector_owned_Float64,
    JLWResult_CNTuple_2_Tuple_CVector_owned_Float64_CVector_owned_Float64,
    JLWError,
)

def stats():
    _r = _lowlevel.stats()
    _v = _r.value
    try:
        _out = (np.array(_v.values._1.as_numpy(), copy=True), _v.values._2,)
    finally:
        _v.values._1.free()
    return _out

def pair():
    _r = _lowlevel.pair()
    _v = _r.value
    try:
        _out = (np.array(_v.values[0].as_numpy(), copy=True), np.array(_v.values[1].as_numpy(), copy=True),)
    finally:
        _v.values[0].free()
        _v.values[1].free()
    return _out

__all__ = ["CString_owned", "JLWStatus", "CVector_owned_Float64", "Tuple_CVector_owned_Float64_Int64", "CNTuple_2_Tuple_CVector_owned_Float64_Int64", "JLWResult_CNTuple_2_Tuple_CVector_owned_Float64_Int64", "CNTuple_2_Tuple_CVector_owned_Float64_CVector_owned_Float64", "JLWResult_CNTuple_2_Tuple_CVector_owned_Float64_CVector_owned_Float64", "JLWError", "stats", "pair"]
