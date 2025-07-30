module JuliaLibWrapping

using OrderedCollections
using Graphs

export parselog, wrapper
export CProject

include("parselog.jl")
include("c.jl")

end
