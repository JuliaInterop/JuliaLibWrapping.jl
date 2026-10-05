module opaque_gc

# A minimal library that exists to exercise opaque-handle garbage collection
# end to end. `Model` is registered as an opaque carrier, so an `@api` return
# of `Model` hands the Python caller an owning `Opaque` wrapper whose
# `weakref.finalize` calls `jlw_free_opaque` — dropping the Julia root — when
# the wrapper is collected. `num_active_opaques` reports how many handles are
# currently rooted; `model_size` and `model_sum` read an object back through
# its handle (a liveness check, and a check that the stored data is intact);
# and `force_gc` triggers a full Julia collection, which the smoke test uses to
# prove rooted objects survive it unchanged. An immutable `Point` is registered
# too, so both storage branches (by-identity for mutable, `RefValue`-boxed for
# immutable) are covered. See `test/smoke.py`.

using JLWInterop

mutable struct Model
    values::Vector{Float64}
end

# Registering the carrier defines `carrier_type`/`to_carrier`/`from_carrier`
# for `Model` and gives it a per-type storage table that keeps a returned
# object rooted until its handle is freed.
@register_opaque_carrier Model

const num_collected_models = Base.RefValue{UInt64}(0)

# Allocate a model and return an opaque handle to it. The payload is a
# deterministic pattern (`1.0, 2.0, …, n`) so the caller can check the stored
# data byte for byte after a round trip. The object stays alive until the
# handle is released — explicitly via the Python wrapper's `free()`, or
# automatically when that wrapper is garbage-collected.
function make_model(n::Int64)
    m = Model(Float64[i for i in 1:n])
    finalizer(m) do _
        num_collected_models[] += 1
    end
    m
end
@api make_model(n::Int64)::Model

# Read a model's length back through its handle. This dereferences the Julia
# object, so it doubles as a liveness check: were the object ever collected,
# this would read freed memory. The smoke test uses it to confirm objects
# survive a forced garbage collection intact.
model_size(m::Model) = Int64(length(m.values))
@api model_size(m::Model)::Int64

# Retrieve the value held behind the handle: the sum of the whole stored
# payload. It reads every element, so it verifies the data is intact after
# storage (and after a forced GC) — any lost or corrupted element changes the
# result. For `make_model(n)` the payload is `1..n`, so this is `n(n+1)/2`.
model_sum(m::Model) = sum(m.values; init = 0.0)
@api model_sum(m::Model)::Float64

# An *immutable* opaque type, registered alongside the mutable `Model` to cover
# the other branch of the carrier's storage helpers: an immutable value is
# boxed in a `RefValue` to be rooted (`_pointable_type`/`_maybe_ref`) and
# unboxed on the way back (`_maybe_deref`), whereas a mutable object is rooted
# by identity. `make_point`/`point_sum` do the minimal round trip — create,
# hand out a COpaque, pass it back, recover the value — to exercise that path
# end to end.
struct Point
    x::Float64
    y::Float64
end
@register_opaque_carrier Point

make_point(x::Float64, y::Float64) = Point(x, y)
@api make_point(x::Float64, y::Float64)::Point

# Recover both fields (as their sum) from a handle passed back in: a nonzero,
# field-dependent value proves the immutable struct survived the round trip.
point_sum(p::Point) = p.x + p.y
@api point_sum(p::Point)::Float64

"""
    num_active_opaques()::Int64

Number of opaque handles currently rooted, across every registered type. This
counter used to live in JLWInterop itself; it is test scaffolding rather than
runtime API, so it lives here and reads the registry directly. The smoke test
watches this value rise as handles are created and fall as they are freed.
"""
Base.@ccallable function num_active_opaques()::Int64
    return Int64(length(JLWInterop.type_specific_free_func_map))
end

"""
    force_gc()

Trigger a full Julia garbage collection. A l<ive handle roots its Julia object
in the per-type storage table, so `GC.gc()` must not reclaim it; the smoke test
calls this and then confirms the objects are still counted and still readable.
"""
Base.@ccallable function force_gc()::UInt64
    num_collected_models[] = 0
    prevstate = GC.enable(true)
    GC.gc()
    GC.enable(prevstate)
    sleep(.1)
    return num_collected_models[]
end

Base.@ccallable function disable_gc()::Cvoid
    GC.enable(false)
    nothing
end

Base.@ccallable function enable_gc()::Cvoid
    GC.enable(true)
    nothing
end


# Emit `jlw_free`, `jlw_free_strings` and `jlw_free_opaque` together. The last
# is what the Python `Opaque` wrapper calls to release a handle; without this
# opt-in the emitter would not wrap opaque returns at all.
@export_release_entrypoints

end # module
