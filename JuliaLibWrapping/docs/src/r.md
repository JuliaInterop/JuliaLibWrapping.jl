```@meta
CurrentModule = JuliaLibWrapping
```

# R package and rdyncall bindings

[`RTarget`](@ref) emits an installable R package whose public functions call
the JuliaLibWrapping-compiled library through
[rdyncall](https://CRAN.R-project.org/package=rdyncall). Add it to a build
with `r_package`:

```julia
standard_build(@__DIR__; libname = "boundary", r_package = "boundary")
```

The generated package is a normal R package, installable with
`R CMD INSTALL <dir>/boundary` or `install.packages(<dir>/boundary,
repos = NULL, type = "source")`. Its `DESCRIPTION` lists `rdyncall` in
`Imports`, so installing the package pulls it in from CRAN; there is nothing
to compile.

```
<out>/boundary/
├── DESCRIPTION
├── NAMESPACE
├── LICENSE
├── R/
│   ├── lowlevel.R          regenerated on every build
│   └── facade.R            created once, author-editable
└── inst/
    └── bundle/             the juliac runtime closure, when bundle = true
        ├── lib/
        └── artifacts/
```

The split matches the Python target. `R/lowlevel.R` is rewritten every build
and holds the `cstruct()` registrations, the layout checks, the `JLWStatus`
condition helpers, the carrier builders and readers, and one binding per
entrypoint. `R/facade.R` is created only if it is absent, so edits to the
public API survive a rebuild. `NAMESPACE` exports every name that does not
start with a period, so the façade is public and the `.jlr_`-prefixed
internals stay private.

## Calling a wrapped function

With `@api` metadata, the façade keeps the declared public name, the
positional/keyword split, keyword defaults, enums, and the docstring, and the
function is called like any other R function:

```r
library(boundary)

count_strs(c("a", "bb"))          # 2
sum_dict(c(x = 1.5, y = 2.5))     # 4
sum_dict(c(x = 1.5), scale = 2)   # 3
maybe_sqrt(-1)                    # NULL
round_value(3.7, mode = "round_down")  # 3
```

Hand-written `@ccallable` entrypoints have no sidecar declaration, so they
get the mechanical, ABI-derived wrapping: the generator still recognizes the
carrier shapes and status returns, but it cannot recover Julia-level names,
keyword arguments, defaults, or docstrings.

## Type mapping

Scalars follow R's vector types; a struct passed or returned by value is a
`cstruct` `cdata`.

| Declared Julia type | R |
|---|---|
| `Int8`…`Int32`, `UInt8`…`UInt16` | `integer` |
| `Int64`, `UInt32`, `UInt64` | `double` (R has no 64-bit integer) |
| `Float32`, `Float64` | `double` |
| `Bool` | `logical` |
| `String` | `character` |
| `Vector{String}` | `character` vector |
| `Dict{String,V}` | named vector (named list for a non-atomic `V`) |
| `Array{T,N}` | numeric/integer/logical vector or `array` |
| `Union{T,Nothing}` | the value, or `NULL` |
| `Tuple{…}` | unnamed `list` |
| `Base.Enum` | a member name, or the underlying integer |
| `Ptr{T}` | `externalptr` (or a vector, which is borrowed in place) |
| `Nothing` | `NULL`, invisibly |

`Int64` and `UInt64` beyond 2^53 cannot round-trip exactly: rdyncall returns
them as R doubles, and R has no native 64-bit integer. Use them for counts and
other small values, not for identifiers.

An R matrix is column-major, matching `CArray` storage, so a `Matrix{T}`
carrier maps directly onto an R `matrix` or `array`, and its dimensions are
`dim`-attribute values.

Keyword arguments become named R arguments with the declared default.

## Copy-and-return for written arrays

A declaration that names an array in `mutates` copies the value before the
call and returns the result, because R's copy-on-modify semantics promise a
caller that an argument is not written through:

```r
mylib::scale(a, factor = 2.0)   # returns the written array
```

Pass `.in_place = TRUE` to skip the copy and let the library write the
caller's vector directly:

```r
mylib::scale(a, factor = 2.0, .in_place = TRUE)
```

The caller must then not alias `a`: any other binding to the same vector sees
the write too. `.in_place` begins with a period so it cannot collide with a
declared keyword.

## Enums

An enum argument accepts the member name (as a `character` scalar) or the
underlying integer, and validates it against the sidecar's members. An enum
return comes back as the member name; an unknown value raises a condition
with the `jlw_error` class. The member lookup is generated from the same
`enums` table the Python and MATLAB targets use.

## Errors

A non-zero status raises an R condition whose class names the failure, with
the message and code attached:

```r
tryCatch(round_value(1, mode = "bogus"), error = function(e) {
  class(e)              # "jlw_argument" "jlw_error" "error" "condition"
  e$code                # 2
  conditionMessage(e)   # "mode must be one of ..."
})
```

| code | class |
|---|---|
| 1 | `jlw_error` |
| 2 | `jlw_argument` |
| 3 | `jlw_dimension` |
| 4 | `jlw_inexact` |
| 5 | `jlw_bounds` |

Every class also inherits from `jlw_error`, so a single handler catches any
library failure. A bare `JLWStatus` return yields `NULL` on success.

Struct layouts are checked against `juliac`'s recorded sizes and offsets when
the package is installed. A divergence — for example if rdyncall's computed
layout ever changes — stops the package from loading rather than misreading
memory.

## Library loading

The generated `.onLoad` locates the shared library in this order:

1. the `<LIBNAME>_R_LIBRARY` environment variable, a path to the library
   file (the platform's usual extension is optional, as with the MATLAB
   gateway's `<LIBNAME>_MEX_LIBRARY`),
2. `<bundle_subdir>/lib` under the installed package, via `system.file`,
3. a library beside the installed package.

The environment variable is the escape hatch for a library built and left
outside the package, such as when developing against a fresh `juliac` output.

A bundle is copied into `inst/<bundle_subdir>`, which `R CMD INSTALL` moves
to the installed package root. The embedded `RUNPATH` (`$ORIGIN`-relative)
resolves `libjulia` from inside that tree, so a privatized bundle survives
installation unchanged and needs neither Julia nor `LD_LIBRARY_PATH` on the
target machine.

## Coexisting with another wrapped library

As with the Python and MATLAB targets, two JuliaLibWrapping libraries loaded
into one process share a single Julia runtime unless each bundle is
privatized. R keeps every loaded package in one process, so this is a real
constraint: a package built without a private `libjulia` warns at load time
when another JuliaLibWrapping R package is already loaded, and the first call
into whichever library did not initialize the runtime aborts the process.
Build each API as its own privatized bundle, or compile several APIs into one
library.

## Limits

- R has no 64-bit integer: `Int64` and `UInt64` round-trip through `double`.
- Calls are single-threaded, as in the MATLAB target; the Julia runtime
  requires its own initialization and is not entered concurrently here.
- Each wrapped library should be a privatized bundle to coexist with another.
- Varargs and callbacks are not part of the `@api` carrier vocabulary and are
  not wrapped.

## Reference

```@docs
RTarget
```
