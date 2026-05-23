module JuliaLibWrapping

using OrderedCollections: OrderedDict
using Graphs: SimpleDiGraph, add_edge!, strongly_connected_components, topological_sort
using JSON: JSON

export parse_abi_info, read_abi_info, write_wrapper, build_library
export AbstractTarget, CTarget, PythonTarget, ABIInfo

include("abi_import.jl")

abstract type AbstractTarget end

include("c.jl")
include("python.jl")
include("build.jl")

end
