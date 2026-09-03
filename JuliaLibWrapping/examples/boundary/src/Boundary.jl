"""
    Boundary

Plain Julia, with no idea that language bindings exist. Everything a foreign
caller reaches is an ordinary function here; the declarations that expose them
live in `lib/`, so this package's dependencies and its API are unaffected by
being wrapped.
"""
module Boundary

export Extent

"Count the strings."
count_strs(a::Vector{String}) = Int64(length(a))

upcase_strs(a::Vector{String}) = uppercase.(a)

"Sum the values."
sum_dict(d::Dict{String, Float64}; scale::Float64 = 1.0) =
    scale * sum(values(d); init = 0.0)

make_dict(n::Int64) = Dict(string("k", i) => Float64(i) for i in 1:n)

function maybe_sqrt(o::Union{Float64, Nothing})
    (isnothing(o) || o < 0.0) && return nothing
    return sqrt(o)
end

scale_vec(a::Vector{Float64}; factor::Float64 = 2.0) = factor .* a

"Always throws."
boom(x::Int64) = error("boom $x")

"Length in code units."
str_len(s::String) = Int64(ncodeunits(s))

"Upper-case it."
shout(s::String) = uppercase(s)

function check_positive(x::Float64)
    x > 0 || error("not positive")
    return nothing
end

"Double the vector and report how many elements it had."
stats(a::Vector{Float64}) = (2 .* a, Int64(length(a)))

"""
    Extent(lo, hi)

An `isbits` struct a binding layer can register as its own carrier.
"""
struct Extent
    lo::Int32
    hi::Int32
end

"""
    RoundMode

How [`round_value`](@ref) rounds: `round_down` (`floor`), `round_nearest`, or
`round_up` (`ceil`).
"""
@enum RoundMode round_down round_nearest round_up

"Round `x` according to `mode`."
function round_value(x::Float64; mode::RoundMode = round_nearest)
    mode === round_down && return floor(x)
    mode === round_up && return ceil(x)
    return round(x)
end

"Classify the sign of `x` as a `RoundMode`."
function sign_mode(x::Float64)
    x > 0 && return round_up
    x < 0 && return round_down
    return round_nearest
end

"Sum `n` Float64s at `data`."
function sum_at(data::Ptr{Float64}, n::Int64)
    n >= 0 || error("negative length")
    s = 0.0
    for i in 1:n
        s += unsafe_load(data, i)
    end
    return s
end

"Widen an extent by `by` on both sides."
function widen(e::Extent, by::Int32)
    by >= 0 || error("negative width")
    return Extent(e.lo - by, e.hi + by)
end

end # module
