module JuliaLibWrapping

using OrderedCollections: OrderedDict
using Graphs: SimpleDiGraph, add_edge!, strongly_connected_components, topological_sort
using JSON: JSON

export import_abi_info, wrapper
export CProject, ABIInfo

include("abi_import.jl")
include("c.jl")

end
