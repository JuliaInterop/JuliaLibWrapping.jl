"""libsimple generated façade.

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
    CVector_borrowed_Float32,
    CVectorPair_Float32,
    MyTwoVec,
    CVector_borrowed_CTree_Float64,
    CTree_Float64,
)

from ._lowlevel import tree_size  # TODO: hand-wrap — `tree`: argument has unrecognized type `CTree{Float64}`
from ._lowlevel import copyto_and_sum  # TODO: hand-wrap — `fromto`: argument has unrecognized type `CVectorPair{Float32}`
from ._lowlevel import countsame  # TODO: hand-wrap — `list`: argument has raw pointer type `Ptr{MyTwoVec}`

__all__ = ["CVector_borrowed_Float32", "CVectorPair_Float32", "MyTwoVec", "CVector_borrowed_CTree_Float64", "CTree_Float64", "tree_size", "copyto_and_sum", "countsame"]
