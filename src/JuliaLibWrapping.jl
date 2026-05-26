module JuliaLibWrapping

using OrderedCollections: OrderedDict
using Graphs: SimpleDiGraph, add_edge!, strongly_connected_components, topological_sort
using JSON: JSON

export parse_abi_info, read_abi_info, write_wrapper, build_library, standard_build
export AbstractTarget, CTarget, PythonTarget, ABIInfo

include("abi_import.jl")

"""
    AbstractTarget

Supertype of wrapper-emission targets. Each concrete subtype is a
configuration struct describing where and how to emit one output
language's bindings; a corresponding [`write_wrapper`](@ref) method
consumes that configuration plus an [`ABIInfo`](@ref) and writes the
files.

Ships today: [`CTarget`](@ref) for a C header, [`PythonTarget`](@ref)
for a Python `ctypes` package. New languages are added by defining a
subtype and a `write_wrapper` method for it.
"""
abstract type AbstractTarget end

include("c.jl")
include("python.jl")
include("build.jl")

end
