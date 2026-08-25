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

# Borrowed pass-throughs must not free the caller's buffer.
assert b.echo_strs(["x", "y"]) == ["x", "y"]
assert b.echo_dict({"k": 1.0}) == {"k": 1.0}

# Owning returns are copied and freed.
assert np.array_equal(b.make_vec(4), np.array([1.0, 2.0, 3.0, 4.0]))

# Exercise repeated owning and borrowed returns.
for _ in range(10_000):
    b.upcase_strs(["x", "y", "z"])
    b.make_dict(5)
    b.echo_strs(["x", "y"])
    b.echo_dict({"k": 1.0})
    b.make_vec(4)
print("boundary smoke: OK")
