"""libsimple idiomatic façade.

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
    MyTwoVec,
    CVector_Float32,
    CVectorPair_Float32,
    CVector_CTree_Float64,
    CTree_Float64,
)

from ._lowlevel import tree_size  # TODO: hand-wrap — `tree`: argument has unrecognized type `CTree{Float64}`
from ._lowlevel import copyto_and_sum  # TODO: hand-wrap — `fromto`: argument has unrecognized type `CVectorPair{Float32}`
from ._lowlevel import countsame  # TODO: hand-wrap — `list`: argument has raw pointer type `Ptr{MyTwoVec}`

__all__ = ["MyTwoVec", "CVector_Float32", "CVectorPair_Float32", "CVector_CTree_Float64", "CTree_Float64", "tree_size", "copyto_and_sum", "countsame"]
