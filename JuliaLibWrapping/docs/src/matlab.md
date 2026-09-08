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
[gateway](https://www.mathworks.com/help/matlab/matlab_external/gateway-routine.html)
that converts `mxArray`s to and from the carriers, calls the entry point, and
releases what Julia allocated.

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

`boundary_mex_types.h` holds the carrier typedefs. A build that also emits a
[`CTarget`](@ref) writes the same declarations to `boundary.h`. Both come from
the ABI, so they agree; this target emits its own so it can be used without a
`CTarget`.

Emitting the sources needs no MATLAB. Compiling the gateway does:

```matlab
build_mex                 % the library is in this directory
build_mex('/path/to/lib') % it is somewhere else
```

The gateway looks for the library in three places, in this order: the
`<LIBNAME>_MEX_LIBRARY` environment variable, the place relative to the MEX
file that this layout puts it in, and the absolute path `build_mex` compiled
in. The second is why the directory above can be moved, or built on one
machine and unpacked on another, and still work.

The library is not copied next to the MEX file: it has to stay beside the
Julia runtime its RUNPATH names. Set `<LIBNAME>_MEX_LIBRARY` to the library's
path without its extension if it moves on its own.

## Type mapping

| Declared Julia type | MATLAB |
|---|---|
| scalar | numeric scalar, `logical` for `Bool` |
| `String` | `char` or `string` in, `char` out |
| `Vector{String}` | whatever `cellstr` takes in, `cellstr` out |
| `Dict{String,V}` | `struct`, its fields the keys |
| `Array{T,N}` | numeric array |
| `Union{T,Nothing}` | the value, or `[]` |
| `Tuple{…}` | multiple outputs |
| `Base.Enum` | a member name, or the underlying integer |
| `Nothing` | no output |

Text comes back as `char`, and a list of it as a cell array of `char` rows,
which is what `cellstr` builds. Both forms are what a façade accepts, so a
result feeds straight into the next call.

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

Most functions only read their array arguments, and those need nothing from
you. They are passed by reference: Julia reads MATLAB's own memory, and no
copy is made.

One case does need something from you. If the Julia function writes into an
array argument, name that argument in the declaration:

```julia
scale!(a::Vector{Float64}, factor::Float64) = (a .*= factor; nothing)

@api scale!(a::Vector{Float64}, factor::Float64)::Nothing mutates = (a,)
```

### Calling it from MATLAB

MATLAB does not let a function change a variable its caller passed in, so the
argument is copied for the call and given back as an output:

```matlab
a = [1 2 3];
a = boundary.scale(a, 2);     % a is now [2 4 6]
```

Without the `a =` the result goes to `ans` and the array keeps its old
values. The generated help says which arguments behave this way, and the
build says so once per declaration:

```
┌ Warning: MATLAB has no way to write through an argument, so
│ boundary.scale copies a and returns the copy. Call it as
│ `[a] = boundary.scale(...)`.
```

### Why it is copied

MATLAB shares memory between variables until one of them is written to, and
it only notices writes made by MATLAB itself. After `b = a`, both names point
at the same array. A write from Julia goes straight to that shared memory, so
`b` would change as well, with nothing in the MATLAB code to explain it.
Copying the argument first leaves `b` unchanged.

### Names ending in `!`

A declaration whose name ends in `!` but names no argument gets a warning,
since a name like that usually writes to something.

## Errors

Errors carry an identifier, so `ME.identifier` dispatch works. They come from
two places.

An argument the façade or the gateway rejects raises `jlw:argument`, or
`jlw:dimension` for a shape. The two check some of the same things, and name
them the same way, so one `catch` covers a failure wherever it was found.

A call the library itself fails raises the identifier its `JLWStatus` code
names:

| code | identifier |
|---|---|
| 1 | `jlw:error` |
| 2 | `jlw:argument` |
| 3 | `jlw:dimension` |
| 4 | `jlw:inexact` |
| 5 | `jlw:bounds` |

A library that cannot be loaded raises `jlw:library`.

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
- **An entry point this target cannot map gets no façade**, rather than one
  that raises when called. The build says which, and why:

  ```
  ┌ Warning: no MATLAB façade for next_chunk: argument 1: unrecognized
  │ argument carrier `Handle`
  ```

  The entry point is still in the library, so C callers keep it.

```@docs
MatlabTarget
```
