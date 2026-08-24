import numpy as np

import boundary_py as b

assert b.count_strs(["a", "bb", "ccc"]) == 3
assert b.upcase_strs(["ab", "wörld"]) == ["AB", "WÖRLD"]
assert b.upcase_strs(["a\x00b"]) == ["A\x00B"]
assert b.sum_dict({"x": 1.5, "y": 2.5}) == 4.0
assert b.make_dict(3) == {"k1": 1.0, "k2": 2.0, "k3": 3.0}
assert b.maybe_sqrt(9.0) == 3.0
assert b.maybe_sqrt(None) is None
assert b.maybe_sqrt(-1.0) is None

# Pass-through of a borrowed argument: echo_strs/echo_dict return one of
# their own CStrArray/CDict arguments unchanged (owned stays 0). This is
# the exact double-free the explicit `owned` flag exists to prevent — a
# wrapper that assumed "returns always own" would free the caller's buffer
# here.
assert b.echo_strs(["x", "y"]) == ["x", "y"]
assert b.echo_dict({"k": 1.0}) == {"k": 1.0}

# Owning CArray return: make_vec mallocs a fresh vector (owned == 1); the
# façade copies it into a numpy array and frees the Julia-allocated buffer
# before returning — the same copy-then-free contract as echo_strs/echo_dict's
# owning-return sibling functions, extended to CArray.
assert np.array_equal(b.make_vec(4), np.array([1.0, 2.0, 3.0, 4.0]))

# no-double-free / leak hammer: repeated owning returns AND pass-through
# returns must not crash
for _ in range(10_000):
    b.upcase_strs(["x", "y", "z"])
    b.make_dict(5)
    b.echo_strs(["x", "y"])
    b.echo_dict({"k": 1.0})
    b.make_vec(4)
print("boundary smoke: OK")
