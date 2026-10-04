"""libsimple public API.

JuliaLibWrapping writes this file once and never overwrites it. The
generated wrappers live in `_generated.py` and the ctypes bindings in
`_lowlevel.py`; both are rewritten on every build. Everything defined in
`_generated` is imported here, so a package with no hand-written layer
exposes the generated API unchanged.

Add, override, or hide names below:

- to add a function, define it here and append its name to `__all__`;
- to override a generated function under its public name, define it here
  after the import; the generated one stays reachable as
  `_generated.<name>`;
- to hide a generated name, remove it from `__all__`.

`__init__.py` re-exports whatever `__all__` lists.
"""
from . import _generated
from ._generated import *  # noqa: F401,F403

__all__ = list(_generated.__all__)
