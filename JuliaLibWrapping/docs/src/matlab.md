```@meta
CurrentModule = JuliaLibWrapping
```

# MATLAB package and gateway

[`MatlabTarget`](@ref) emits MATLAB bindings from `@api` declarations. Add it
to a build with `matlab_package`:

```julia
standard_build(@__DIR__; libname = "boundary", matlab_package = "boundary")
```

Two kinds of file come out. A `.m` façade per declaration, in a `+package`
directory, so a wrapped function is called as `boundary.stats(a)`. And one C
[gateway](https://www.mathworks.com/help/matlab/matlab_external/gateway-routine.html) that converts `mxArray`s to and from the carriers, calls the entry
point, and releases what Julia allocated.

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

Emitting is pure Julia. Compiling the gateway needs MATLAB:

```matlab
build_mex                 % the library is in this directory
build_mex('/path/to/lib') % it is somewhere else
```

`build_mex` compiles the library's location into the gateway. Set
`<LIBNAME>_MEX_LIBRARY` to point a built MEX file at a library that has moved.

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

Keyword arguments become name-value arguments. Outputs are named `out1`…`outN`,
because the sidecar records argument names but not result names.

A tuple return maps onto MATLAB's multiple assignment, so `[x, n] = stats(a)`
works, and asking for fewer outputs is fine. MATLAB rejects asking for more.

## Enums

An enum argument takes a member name, and an enum return comes back as one,
so a result passes straight into the next call:

```matlab
mode = boundary.sign_mode(-2.5);        % "round_down"
y = boundary.round_value(x, mode = mode);
```

The underlying integer is accepted too, for a caller that already has one.

## Arrays the function writes to

An array argument crosses without a copy: the gateway hands Julia a pointer
into MATLAB's own buffer. That is right for a function that only reads it.

Say so in the declaration when the function writes to one:

```julia
@api scale!(a::Vector{Float64}, k::Float64)::Nothing mutates = (a,)
```

MATLAB then copies `a` for the call and returns the copy, so the façade is
`a = boundary.scale(a, k)` and its help text says so. Without the copy the
write would reach every variable sharing that buffer: `b = a` shares one until
MATLAB sees a write, and a write from Julia is one it misses.

The build says so for each such declaration, because a caller who does not
assign the result loses the write:

```
┌ Warning: MATLAB has no way to write through an argument, so
│ boundary.scale copies y and returns the copy. Call it as
│ `[y] = boundary.scale(...)`.
```

A declaration whose name ends in `!` and lists nothing warns too.

## Errors

A non-zero `JLWStatus` becomes a MATLAB error whose identifier comes from the
status code, so `ME.identifier` dispatch works:

| code | identifier |
|---|---|
| 1 | `jlw:error` |
| 2 | `jlw:argument` |
| 3 | `jlw:dimension` |
| 4 | `jlw:inexact` |
| 5 | `jlw:bounds` |

## Limits

- **Each library must be a privatized bundle**, which `standard_build` gives
  you. Two of them load together, each with its own Julia runtime; two
  unprivatized ones share a `libjulia` and the second aborts on its first
  call, without a message. See
  [Multiple wrapped libraries in one process](@ref). Measured on Linux by
  loading the libraries directly, not yet from a MATLAB session.
- **One call at a time.** Two threads calling a generated library segfault, so
  `parfeval` on a thread pool is unsupported. A gateway on MATLAB's main thread
  is single-threaded and safe.
- **`clear mex` is safe.** Nothing releases the gateway's reference to the
  library, so unloading the MEX file leaves it mapped and the next load
  reuses it rather than initializing a second runtime.
- **An integer argument keeps the class you pass it.** `uint8` data stays
  `uint8`, so an image is not silently widened, and the array crosses without
  a copy. Whole-valued `double` is accepted too, and is exact below 2^53.
- An entry point this target cannot map gets no façade, rather than one that
  raises when called.

```@docs
MatlabTarget
```
