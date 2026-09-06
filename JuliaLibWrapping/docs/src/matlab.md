```@meta
CurrentModule = JuliaLibWrapping
```

# MATLAB package and gateway

[`MatlabTarget`](@ref) emits MATLAB bindings from the same `@api` declarations
that produce the Python ones. Add it to a build with `matlab_package`:

```julia
standard_build(@__DIR__; libname = "boundary", matlab_package = "boundary")
```

Two kinds of file come out. A `.m` façade per declaration, in a `+package`
directory so a wrapped function is called as `boundary.stats(a)` and cannot
collide with a name already on the MATLAB path. And one C gateway, dispatched
by name, that converts `mxArray`s to and from the carriers, calls the exported
entry point and releases what Julia allocated.

```
out/
    +boundary/
        stats.m                       one façade per declaration
        private/
            boundary_mex.mexa64       the gateway, once compiled
    boundary_mex.c
    boundary_mex_types.h
    build_mex.m
```

Emitting needs no MATLAB, exactly as emitting a Python package needs no Python.
Compiling the gateway does:

```matlab
build_mex                 % the library is in this directory
build_mex('/path/to/lib') % it is somewhere else
```

`build_mex` compiles the library's location into the gateway. Set
`<LIBNAME>_MEX_LIBRARY` to point a built MEX file at a library that has since
moved.

## Type mapping

| Declared Julia type | MATLAB |
|---|---|
| scalar | numeric scalar, `logical` for `Bool` |
| `String` | `char` or `string` in, `string` out |
| `Vector{String}` | `cellstr` |
| `Dict{String,V}` | `struct`, its fields the keys |
| `Array{T,N}` | numeric array |
| `Union{T,Nothing}` | the value, or `[]` |
| `Tuple{…}` | multiple outputs |
| `Base.Enum` | a member name, or the underlying integer |
| `Nothing` | no output |

Keyword arguments become name-value arguments. Outputs are named `out1`…`outN`:
the sidecar records argument names but not result names.

A tuple return maps onto MATLAB's multiple assignment, so `[x, n] = stats(a)`
works, and asking for fewer outputs is allowed. Asking for more is rejected by
MATLAB against the emitted signature.

## Integers

An integer argument is declared `double` and converted after validation. An
`arguments` block converts to the declared class *before* its validators run,
and `int64(2.5)` rounds rather than failing, so declaring the integer class
directly would silently accept a non-integer. The cost is that a magnitude
above 2^53 cannot be expressed.

## Enums

An enum argument takes either a member name or the underlying integer:

```matlab
boundary.round_value(3.2, mode = "round_up")
boundary.round_value(3.2, mode = 2)
```

An enum return comes back as its member name, which is a form the façades
accept, so a result passes straight into another declaration.

## Arrays are borrowed

An array argument is passed without copying: the gateway hands Julia a pointer
into MATLAB's own buffer.

MATLAB gives assignment value semantics and implements them by copying on
write, so `b = a` shares one buffer until MATLAB observes a write. A write from
Julia is one it never observes, so **a wrapped function that writes to an array
argument changes every variable sharing that buffer**, and nothing in the
MATLAB source says a copy was due.

Build with `duplicate_arguments = true` when the wrapped library mutates its
arguments:

```julia
standard_build(
    @__DIR__; libname = "boundary", matlab_package = "boundary",
    duplicate_arguments = true,
)
```

Each array argument is then copied for the call. The flag is per build, so a
library with one mutating function pays the copy everywhere. String,
string-array and dictionary arguments already copy, and scalars and optionals
cross by value, so only arrays are affected.

Façades for functions taking arrays carry this warning in their help text
unless the flag is set.

## Errors

A non-zero `JLWStatus` becomes a MATLAB error whose identifier comes from the
status code, so `ME.identifier` dispatch works from the same codes the Python
bindings turn into `JLWError.code`.

| code | identifier |
|---|---|
| 1 | `jlw:error` |
| 2 | `jlw:argument` |
| 3 | `jlw:dimension` |
| 4 | `jlw:inexact` |
| 5 | `jlw:bounds` |

## Limitations

- **One wrapped library per MATLAB session.** Two would mean two embedded Julia
  runtimes, which aborts. Put the functions in one library.
- **One call at a time.** Two threads calling a generated library segfault, so
  `parfeval` on a thread pool is unsupported. A gateway on MATLAB's main thread
  is single-threaded and safe.
- **`clear mex` is safe.** The gateway opens the library and never closes it,
  so reloading cannot run `jl_init` a second time in one process.
- An entry point whose arguments or return this target cannot map gets no
  façade, rather than one that raises when called.

```@docs
MatlabTarget
```
