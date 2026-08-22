module boundary

using JLWInterop

JLWInterop.@export_release_entrypoints

Base.@ccallable function count_strs(a::CStrArray)::Int64
    return Int64(length(Vector{String}(a)))
end

Base.@ccallable function upcase_strs(a::CStrArray)::CStrArray
    return CStrArray([uppercase(s) for s in Vector{String}(a)])
end

Base.@ccallable function sum_dict(d::CDict{Float64})::Float64
    return sum(values(Dict{String, Float64}(d)); init = 0.0)
end

Base.@ccallable function make_dict(n::Int64)::CDict{Float64}
    return CDict(Dict(string("k", i) => Float64(i) for i in 1:n))
end

Base.@ccallable function maybe_sqrt(o::COpt{Float64})::COpt{Float64}
    x = unwrap(o)
    (isnothing(x) || x < 0.0) && return COpt{Float64}(nothing)
    return COpt(sqrt(x))
end

# Pass-through of a borrowed argument: `a` arrives with `owned == 0` and is
# returned unchanged, still `owned == 0`. The regression case explicit
# ownership exists to prevent — a naive "returns always own" wrapper would
# double-free the caller's buffer here.
Base.@ccallable function echo_strs(a::CStrArray)::CStrArray
    return a
end

Base.@ccallable function echo_dict(d::CDict{Float64})::CDict{Float64}
    return d
end

end # module
