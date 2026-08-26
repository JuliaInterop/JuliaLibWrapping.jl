module boundary

using JLWInterop

JLWInterop.@export_release_entrypoints

Base.@ccallable function count_strs(a::CStrArray{:borrowed})::Int64
    return Int64(length(Vector{String}(a)))
end

Base.@ccallable function upcase_strs(a::CStrArray{:borrowed})::CStrArray{:owned}
    return CStrArray{:owned}([uppercase(s) for s in Vector{String}(a)])
end

Base.@ccallable function sum_dict(d::CDict{:borrowed, Float64})::Float64
    return sum(values(Dict{String, Float64}(d)); init = 0.0)
end

Base.@ccallable function make_dict(n::Int64)::CDict{:owned, Float64}
    return CDict{:owned}(Dict(string("k", i) => Float64(i) for i in 1:n))
end

Base.@ccallable function maybe_sqrt(o::COpt{Float64})::COpt{Float64}
    x = unwrap(o)
    (isnothing(x) || x < 0.0) && return COpt{Float64}(nothing)
    return COpt(sqrt(x))
end

# A borrowed pass-through must not free the caller's buffer.
Base.@ccallable function echo_strs(a::CStrArray{:borrowed})::CStrArray{:borrowed}
    return a
end

Base.@ccallable function echo_dict(d::CDict{:borrowed, Float64})::CDict{:borrowed, Float64}
    return d
end

# The façade copies and frees this owned return.
Base.@ccallable function make_vec(n::Int64)::CVector{:owned, Float64}
    return CArray{:owned}(collect(Float64, 1:n))
end

end # module
