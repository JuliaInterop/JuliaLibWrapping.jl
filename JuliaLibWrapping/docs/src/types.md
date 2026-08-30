```@meta
CurrentModule = JLWInterop
```

# Supported Julia types

[`@api`](@ref) maps Julia-level argument and return types to fixed-layout ABI
carriers and then to target-language values. This page is the authoritative
summary of the built-in mappings. [JLWInterop carriers](@ref) documents their
exact layouts and constructors.

“Scalar” below means `Int8`–`Int64`, `UInt8`–`UInt64`, `Float32`, `Float64`, or
`Bool`. Containers of other element types are rejected rather than
reinterpreted.

| Declared Julia type | Argument carrier | Return carrier | Python value |
|:--|:--|:--|:--|
| scalar | same type, by value | same type, by value | `int`, `float`, or `bool` |
| `String` | `CString{:borrowed}` | `CString{:owned}` | `str` |
| `Vector{String}` | `CStrArray{:borrowed}` | `CStrArray{:owned}` | `list[str]` |
| `Dict{String,V}` for scalar `V` | `CDict{:borrowed,V}` | `CDict{:owned,V}` | `dict[str, V]` |
| `Union{T,Nothing}` for scalar `T` | `COpt{T}` | `COpt{T}` | `T \| None` |
| `Array{T,N}` for scalar `T` | `CArray{:borrowed,T,N}` | `CArray{:owned,T,N}` | `numpy.ndarray` |
| `Tuple{…}` of 2–8 mapped types (return only) | — | `CTupleN{…}` | `tuple` |
| `Nothing` (return only) | — | `JLWStatus` | `None` |
| `Ptr{T}` | same type, by value | same type, by value | a `ctypes` pointer |
| concrete `Base.Enum{B}` with scalar base `B` | `B`, validated | `B` | generated `enum.IntEnum` |
| registered concrete type | its registered carrier | its registered carrier | target-dependent |

A tuple is a return type only. Each element carries its own ownership, so an
owning element is released while a scalar beside it is not.

`Vector{T}` and `Matrix{T}` use the one- and two-dimensional `CArray`
specializations. Optional enums and nested containers such as
`Dict{String,Vector{Int}}` are not built-in mappings.

## Ownership and release

Arguments backed by variable-size storage are borrowed: the caller owns their
memory and keeps it alive for the call. Array arguments are zero-copy views,
so mutation by the Julia function is visible to the caller. A function must
not retain such a view after returning, and callers must not pass read-only
storage to a mutating function. String-vector and dictionary arguments are
copied into Julia values during conversion.

Returns backed by variable-size storage are owning: the library allocates a
copy and transfers responsibility to the caller. A library with any owning
`@api` return must export its deallocation entrypoints once at module top
level:

```julia
using JLWInterop

@export_release_entrypoints
```

The generated Python façade copies owning results into Python-managed storage
and releases the carrier in a `finally` block. Omitting the entrypoints is a
build error for an annotated API, because safe automatic ownership would be
impossible.

## Arrays

`Array{T,N}` arguments must be dense, writable when the Julia function
mutates them, and use the carrier's column-major layout. The generated Python
helper accepts contiguous one-dimensional arrays. For `N ≥ 2`, it requires a
Fortran-contiguous NumPy array; use `np.asfortranarray(a)` when appropriate.

An array return is copied to a fresh dense allocation. Returning an array is
usually safer than returning a raw pointer because the dimensions and release
path cross the boundary together.

## Strings, string vectors, and dictionaries

`String` is transported as length-prefixed UTF-8, so embedded NUL bytes are
allowed. A string-vector carrier is an array of those length-prefixed strings.
A dictionary carrier contains parallel string-key and scalar-value arrays.
Supported dictionary value types are listed by [`CDICT_VALUE_TYPES`](@ref).

## Optional values

`Union{T,Nothing}` for scalar `T` uses an inline discriminant and value. It
does not allocate and has no ownership state. Optional enums are not currently
supported.

## Enums

An enum argument accepts an enum member, member name, or integer from Python;
invalid names or values raise `ValueError`. Returns are instances of the
generated `IntEnum`. Keyword defaults may name enum members.

## Raw pointers

A `Ptr{T}` carries only an address. For an argument, the caller must keep the
pointed-to memory alive through the call. For a return, the library author is
responsible for ensuring that the address remains valid and for defining any
needed release protocol. A pointer into a fresh Julia allocation can dangle
after garbage collection; a pointer into unmanaged allocation can leak.

Use an array when its length and ownership should be represented by the API.

## Registering a concrete type

A library can extend the mapping for its own type. An `isbits` struct can be
its own carrier:

```julia
struct Extent
    lo::Int32
    hi::Int32
end

JLWInterop.carrier_type(::Type{Extent}) = Extent
JLWInterop.to_carrier(e::Extent) = e
JLWInterop.from_carrier(::Type{Extent}, e::Extent) = e
```

Define these methods before the `@api` declaration. The carrier must be
`isbits`, because an error result needs a zero-filled value of the same ABI
type. Targets can pass a registered struct through directly; the Python target
exposes it as a `ctypes.Structure` unless the author replaces that policy in
the façade.
