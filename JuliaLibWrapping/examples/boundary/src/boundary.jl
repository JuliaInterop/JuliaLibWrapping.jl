module boundary

using JLWInterop

@export_release_entrypoints

@api "Count the strings." function count_strs(a::Vector{String})::Int64
    Int64(length(a))
end

@api function upcase_strs(a::Vector{String})::Vector{String}
    uppercase.(a)
end

@api "Sum the values." function sum_dict(d::Dict{String, Float64}; scale::Float64 = 1.0)::Float64
    scale * sum(values(d); init = 0.0)
end

@api function make_dict(n::Int64)::Dict{String, Float64}
    Dict(string("k", i) => Float64(i) for i in 1:n)
end

@api function maybe_sqrt(o::Union{Float64, Nothing})::Union{Float64, Nothing}
    (isnothing(o) || o < 0.0) && return nothing
    sqrt(o)
end

@api function scale_vec(a::Vector{Float64}; factor::Float64 = 2.0)::Vector{Float64}
    factor .* a
end

@api "Always throws." function boom(x::Int64)::Int64
    error("boom $x")
end

@api "Length in code units." function str_len(s::String)::Int64
    Int64(ncodeunits(s))
end

@api function check_positive(x::Float64)::Nothing
    x > 0 || error("not positive")
    nothing
end

# A raw pointer and a struct this module registers itself. Both cross the
# boundary unconverted; `@api` still supplies the Python name, the docstring
# and the error boundary.

struct Extent
    lo::Int32
    hi::Int32
end

JLWInterop.carrier_type(::Type{Extent}) = Extent
JLWInterop.to_carrier(e::Extent) = e
JLWInterop.from_carrier(::Type{Extent}, c::Extent) = c

@api "Sum `n` Float64s at `data`." function sum_at(data::Ptr{Float64}, n::Int64)::Float64
    n >= 0 || error("negative length")
    s = 0.0
    for i in 1:n
        s += unsafe_load(data, i)
    end
    s
end

@api "Widen an extent by `by` on both sides." function widen(e::Extent, by::Int32)::Extent
    by >= 0 || error("negative width")
    Extent(e.lo - by, e.hi + by)
end

# The rest of this module is hand-written: `@api` and `Base.@ccallable`
# entrypoints coexist in one library. These four keep carrier ownership
# visible at the boundary, which `@api`'s value-level signatures hide.

# A borrowed pass-through must not free the caller's buffer.
Base.@ccallable function echo_strs(a::CStrArray{:borrowed})::CStrArray{:borrowed}
    return a
end

Base.@ccallable function echo_dict(d::CDict{:borrowed, Float64})::CDict{:borrowed, Float64}
    return d
end

# The façade copies and frees these owned returns.
Base.@ccallable function make_vec(n::Int64)::CVector{:owned, Float64}
    return CArray{:owned}(collect(Float64, 1:n))
end

Base.@ccallable function make_str()::CString{:owned}
    return CString{:owned}("héllo")
end

end # module
