import ctypes

import numpy as np

import boundary_py as b

assert b.count_strs(["a", "bb"]) == 2
assert b.upcase_strs(["ab", "wörld"]) == ["AB", "WÖRLD"]
assert b.upcase_strs(["a\x00b"]) == ["A\x00B"]
assert b.sum_dict({"x": 1.5, "y": 2.5}) == 4.0
assert b.sum_dict({"x": 1.5}, scale=2.0) == 3.0
assert b.make_dict(3) == {"k1": 1.0, "k2": 2.0, "k3": 3.0}
assert b.maybe_sqrt(9.0) == 3.0
assert b.maybe_sqrt(None) is None
assert b.maybe_sqrt(-1.0) is None
assert list(b.scale_vec(np.asfortranarray([1.0, 2.0]))) == [2.0, 4.0]
assert list(b.scale_vec(np.asfortranarray([1.0, 2.0]), factor=3.0)) == [3.0, 6.0]

try:
    b.boom(7)
    raise AssertionError("expected JLWError")
except Exception as exc:
    assert "boom 7" in str(exc)

assert b.str_len("wörld") == 6  # 'ö' is 2 UTF-8 code units
assert b.str_len("a\x00b") == 3  # an embedded NUL is content, not a terminator

assert b.check_positive(1.0) is None
try:
    b.check_positive(-1.0)
    raise AssertionError("expected JLWError")
except Exception as exc:
    assert "not positive" in str(exc)

# A raw pointer and a library-registered struct cross unconverted, and still
# get their `@api` name, docstring and error boundary.
buf = np.asfortranarray([1.0, 2.0, 4.0])
data = buf.ctypes.data_as(ctypes.POINTER(ctypes.c_double))
assert b.sum_at(data, 3) == 7.0
assert b.sum_at.__doc__ == "Sum `n` Float64s at `data`."
try:
    b.sum_at(data, -1)
    raise AssertionError("expected JLWError")
except b.JLWError as exc:
    assert "negative length" in str(exc)

wide = b.widen(b.Extent(1, 5), 2)
assert (wide.lo, wide.hi) == (-1, 7)
try:
    b.widen(b.Extent(1, 5), -1)
    raise AssertionError("expected JLWError")
except b.JLWError as exc:
    assert "negative width" in str(exc)

# Hand-written entrypoints in the same library. Borrowed pass-throughs must
# not free the caller's buffer.
assert b.echo_strs(["x", "y"]) == ["x", "y"]
assert b.echo_dict({"k": 1.0}) == {"k": 1.0}

# Owning returns are copied and freed.
assert np.array_equal(b.make_vec(4), np.array([1.0, 2.0, 3.0, 4.0]))
assert b.make_str() == "héllo"

# `free()` is idempotent, against the real allocator. An owning `@api` return
# arrives nested in a JLWResult, and every read of `.value` builds a fresh
# Python wrapper over the same buffer — so the guard has to live in the
# carrier's own fields. A second release here would be a double free (N+1 of
# them for the string array), which glibc turns into an abort.
ll = b._lowlevel

r = ll.boundary_upcase_strs(ll.CStrArray_borrowed.from_list(["a", "bb"]))
assert r.value.as_list() == ["A", "BB"]
r.value.free()
r.value.free()
r.value.free()
assert r.value.as_list() == []  # nulled, so nothing is read back

r = ll.boundary_make_dict(3)
assert r.value.as_dict() == {"k1": 1.0, "k2": 2.0, "k3": 3.0}
r.value.free()
r.value.free()
assert r.value.as_dict() == {}

r = ll.boundary_scale_vec(
    ll.CVector_borrowed_Float64.from_numpy(np.asfortranarray([1.0, 2.0])), 2.0)
assert list(r.value.as_numpy()) == [2.0, 4.0]
r.value.free()
r.value.free()
try:
    r.value.as_numpy()
    raise AssertionError("expected a null-pointer error after free")
except ValueError:
    pass

# A bare owning return, the shape a hand-written entrypoint gives.
s = ll.make_str()
assert s.as_str() == "héllo"
s.free()
s.free()
assert s.as_str() == ""

v = ll.make_vec(4)
assert list(v.as_numpy()) == [1.0, 2.0, 3.0, 4.0]
v.free()
v.free()
print("free() idempotence: OK")

# Exercise repeated owning and borrowed returns.
for _ in range(10_000):
    b.upcase_strs(["x", "y", "z"])
    b.make_dict(5)
    b.scale_vec(np.asfortranarray([1.0, 2.0]))
    b.echo_strs(["x", "y"])
    b.echo_dict({"k": 1.0})
    b.make_vec(4)
print("boundary smoke: OK")
