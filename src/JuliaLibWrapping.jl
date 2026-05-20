module JuliaLibWrapping

using OrderedCollections: OrderedDict
using Graphs: SimpleDiGraph, add_edge!, strongly_connected_components, topological_sort
using JSON: JSON

export import_abi_info, write_wrapper
export AbstractTarget, CTarget, ABIInfo

include("abi_import.jl")

abstract type AbstractTarget end

include("c.jl")

end
