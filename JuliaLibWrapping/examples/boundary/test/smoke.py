import boundary_py as b

assert b.count_strs(["a", "bb", "ccc"]) == 3
assert b.upcase_strs(["ab", "wörld"]) == ["AB", "WÖRLD"]
assert b.upcase_strs(["a\x00b"]) == ["A\x00B"]
assert b.sum_dict({"x": 1.5, "y": 2.5}) == 4.0
assert b.make_dict(3) == {"k1": 1.0, "k2": 2.0, "k3": 3.0}
assert b.maybe_sqrt(9.0) == 3.0
assert b.maybe_sqrt(None) is None
assert b.maybe_sqrt(-1.0) is None

# no-double-free / leak hammer: repeated owning returns must not crash
for _ in range(10_000):
    b.upcase_strs(["x", "y", "z"])
    b.make_dict(5)
print("boundary smoke: OK")
