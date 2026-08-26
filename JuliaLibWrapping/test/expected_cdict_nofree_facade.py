"""cdict_nofree_demo idiomatic façade.

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
    CString_borrowed,
    CString_owned,
    CDict_borrowed_Float64,
    CDict_owned_Float64,
)

from ._lowlevel import give_dict  # TODO: hand-wrap — owning return needs release entrypoints; add JLWInterop.@export_release_entrypoints to the library

def take_dict(d):
    _d = CDict_borrowed_Float64.from_dict(d)
    return _lowlevel.take_dict(_d)

__all__ = ["CString_borrowed", "CString_owned", "CDict_borrowed_Float64", "CDict_owned_Float64", "take_dict", "give_dict"]
