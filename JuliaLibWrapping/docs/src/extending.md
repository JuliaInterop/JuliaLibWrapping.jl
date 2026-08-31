```@meta
CurrentModule = JuliaLibWrapping
```

# Extending JuliaLibWrapping

This page is for target implementers and contributors. Library authors do not
need the descriptor machinery to use [`standard_build`](@ref),
[`build_library`](@ref), or [`JLWInterop.@api`](@ref).

## ABI data model

`juliac` assigns each type an integer id. [`ABIInfo`](@ref) contains an ordered
dictionary of descriptors and a list of exported methods. Descriptors include
primitive types, structures whose fields refer to other ids, pointers, and
arrays; method arguments and results use the same ids. Together they form a
type-dependency graph.

[`parse_abi_info`](@ref) imports the JSON representation.
`sort_declarations!` orders definitions so an emitter can satisfy C-style
declaration-before-use rules. It finds strongly connected components, removes
pointer edges that permit forward declarations, topologically sorts the
remaining graph, and records types needing forward declarations.

## Adding a target

A target is a configuration subtype of [`AbstractTarget`](@ref) with a
corresponding method:

```julia
struct MyTarget <: AbstractTarget
    outdir::String
end

function JuliaLibWrapping.write_wrapper(target::MyTarget, info::ABIInfo)
    # Walk the ordered descriptors and methods, then write target files.
end
```

Use a target instance directly with `write_wrapper`, or include it in the
target vector passed to `build_library`.

The built-in emitters sanitize and uniquify foreign identifiers independently;
do not assume Julia type spellings are valid or unique in another language.
Pointer types may also need inline treatment rather than standalone aliases.

## Recognizing carriers

JuliaLibWrapping recognizes JLWInterop carriers from names and field layouts
in ABI metadata rather than requiring Julia type objects at generation time.
The recognizers in `src/recognizers.jl` cover `CArray`, `CString`,
`CStrArray`, `CDict`, `COpt`, `JLWStatus`, `JLWResult`, raw primitive pointers,
and release entrypoints. New targets can reuse these helpers so ownership and
shape validation remain consistent with the built-in Python target.

Treat a failed recognition as an ordinary unrecognized struct. A target should
not infer ownership from a similar-looking but invalid layout.

## API sidecar metadata

[`read_api_metadata`](@ref) reads the optional sidecar generated from `@api`
declarations, and `check_metadata_consistency` validates it against ABI
metadata. Sidecar entries are keyed by exported C symbol. They add public
names, argument/keyword descriptions, defaults, documentation, and enums to
the mechanical ABI.

A target must still handle symbols absent from the sidecar: hand-written
`@ccallable` entrypoints intentionally have no declaration metadata.

```@docs
read_api_metadata
check_metadata_consistency
sanitize_for_c
JuliaLibWrapping._ENUM_BASETYPES
```
