"""Garbage-collection smoke test for the generated `opaque_gc_py` package.

`make_model` returns an `Opaque` handle that owns a Julia object; the object
is released — exactly once — when the handle is collected or `free()`d. This
test watches `num_active_opaques()`, the count of rooted handles, to confirm
that Python garbage collection actually reaches back into Julia and frees the
object.

Run against a package importable on `sys.path` (no pytest dependency):

    python JuliaLibWrapping/examples/opaque_gc/test/smoke.py

Exits nonzero (via AssertionError) on any failure.
"""
import gc

import opaque_gc_py
from opaque_gc_py import (
    make_model,
    model_size,
    model_sum,
    make_point,
    point_sum,
    num_active_opaques,
    force_gc,
    disable_gc,
    enable_gc,
    Opaque,
)


def test_gc_frees_each_handle():
    # A fresh process starts with no rooted handles.
    assert num_active_opaques() == 0

    h1 = make_model(4)
    assert isinstance(h1, Opaque)
    assert h1.alive
    assert num_active_opaques() == 1

    h2 = make_model(8)
    assert num_active_opaques() == 2

    # Dropping the last Python reference makes the handle collectable; its
    # finalizer calls jlw_free_opaque, which drops the Julia root.
    del h1
    gc.collect()
    assert num_active_opaques() == 1

    del h2
    gc.collect()
    assert num_active_opaques() == 0


def test_objects_survive_forced_julia_gc():
    # A live handle roots its Julia object, so forcing a full Julia garbage
    # collection must not reclaim it: the count is unchanged and every object
    # is still valid. `model_size` dereferences the object, so a stale/freed
    # object would surface here rather than passing silently.
    assert num_active_opaques() == 0

    sizes = [3, 5, 8, 13]
    handles = [make_model(n) for n in sizes]
    assert num_active_opaques() == len(sizes)
    # Baseline: every handle reads back its size before any GC.
    for h, n in zip(handles, sizes):
        assert model_size(h) == n

    # Force several full Julia collections; rooted objects must persist.
    for _ in range(3):
        force_gc()

    assert num_active_opaques() == len(sizes)
    for h, n in zip(handles, sizes):
        assert h.alive
        assert model_size(h) == n
    # The loop leaves `h` bound to the last handle; drop it so the only
    # references left are in `handles`.
    del h, n

    # Freeing still works normally after the forced collections: dropping the
    # handles removes their Julia roots, so a final GC leaves nothing behind.
    handles.clear()
    gc.collect()
    assert num_active_opaques() == 0


def test_object_is_only_finalized_when_freed():
    # Checks the variables only referred to by globals are rooted, 
    # as was not the case in
    # https://github.com/JuliaLang/julia/issues/60846

    force_gc()
    disable_gc()
    try:
        assert num_active_opaques() == 0
        h = make_model(4)

        # Check that h is collected after we freed it, but not before
        assert force_gc() == 0
        assert num_active_opaques() == 1
        h.free()
        assert num_active_opaques() == 0
        assert force_gc() == 1

        for _ in range(3):
            assert force_gc() == 0
        assert num_active_opaques() == 0
    finally:
        enable_gc()


def test_immutable_struct_round_trips():
    # `Point` is immutable, so it takes the RefValue-boxed branch of the
    # carrier's storage helpers (the mutable `Model` covers the by-identity
    # branch). This is the minimal check: create it, hand the opaque handle
    # back to Julia, and recover its value — unchanged, and still after a GC.
    assert num_active_opaques() == 0
    p = make_point(1.5, 2.25)
    assert isinstance(p, Opaque)
    assert num_active_opaques() == 1
    assert point_sum(p) == 1.5 + 2.25

    force_gc()
    assert point_sum(p) == 1.5 + 2.25

    p.free()
    assert num_active_opaques() == 0


def test_bulk_collection_returns_to_zero():
    assert num_active_opaques() == 0

    handles = [make_model(i + 1) for i in range(25)]
    assert num_active_opaques() == 25

    # Releasing every reference at once frees them all.
    handles.clear()
    gc.collect()
    assert num_active_opaques() == 0


def test_explicit_free_then_gc_frees_only_once():
    # A handle freed explicitly and then collected must leave the count at
    # zero: the finalizer fires at most once however release is triggered.
    assert num_active_opaques() == 0
    h = make_model(1)
    assert num_active_opaques() == 1
    h.free()
    assert num_active_opaques() == 0
    del h
    gc.collect()
    assert num_active_opaques() == 0


if __name__ == "__main__":
    test_gc_frees_each_handle()
    test_objects_survive_forced_julia_gc()
    test_immutable_struct_round_trips()
    test_object_is_only_finalized_when_freed()
    test_bulk_collection_returns_to_zero()
    test_explicit_free_then_gc_frees_only_once()
    print("opaque_gc_py GC smoke test passed")
