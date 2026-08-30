"""
    boundary

The binding layer for [`Boundary`](@ref). Nothing here is defined for Julia
users: `@api` declares which of the package's call signatures foreign callers
may use, and the generated entry points carry those to the target language.

Importing the wrapped functions by name is safe because a declaration defines
nothing — it cannot add a method to `Boundary.shout` and shadow the function
it is meant to reach.
"""
module boundary

using JLWInterop
using Boundary: Boundary, Extent, boom, check_positive, count_strs, make_dict,
    maybe_sqrt, scale_vec, shout, str_len, sum_at, sum_dict, upcase_strs, widen

@export_release_entrypoints

# The declared types are the boundary contract, not the package's signatures:
# `Boundary.sum_dict` accepts any `Dict{String,Float64}`, and this is the
# shape a foreign caller may hand it. Each declaration inherits the Julia
# docstring unless it is given one here.

@api count_strs(a::Vector{String})::Int64
@api upcase_strs(a::Vector{String})::Vector{String}
@api sum_dict(d::Dict{String, Float64}; scale::Float64 = 1.0)::Float64
@api make_dict(n::Int64)::Dict{String, Float64}
@api maybe_sqrt(o::Union{Float64, Nothing})::Union{Float64, Nothing}
@api scale_vec(a::Vector{Float64}; factor::Float64 = 2.0)::Vector{Float64}
@api boom(x::Int64)::Int64
@api str_len(s::String)::Int64
@api shout(s::String)::String
@api check_positive(x::Float64)::Nothing

# A raw pointer and a struct the *binding* registers as its own carrier. The
# struct belongs to the package; the three protocol methods that carry it
# across the ABI belong here, so the package needs no JLWInterop dependency.

JLWInterop.carrier_type(::Type{Extent}) = Extent
JLWInterop.to_carrier(e::Extent) = e
JLWInterop.from_carrier(::Type{Extent}, c::Extent) = c

@api sum_at(data::Ptr{Float64}, n::Int64)::Float64
@api widen(e::Extent, by::Int32)::Extent

# The rest is hand-written: `@api` and `Base.@ccallable` entrypoints coexist
# in one library. These four keep carrier ownership visible at the boundary,
# which `@api`'s value-level signatures hide.

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
