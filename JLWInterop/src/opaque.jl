"""
    COpaque

C-ABI carrier for a `JLWInterop` opaque handle. A single pointer to a Julia
object that a `@ccallable` boundary keeps alive, returned to a foreign caller
and passed back unchanged on a later call.

Unlike a bare `Ptr{Cvoid}`, `COpaque` is a distinct struct, so a binding target
recognizes it in the ABI and can wrap it in an owning handle that releases the
Julia object once with [`jlw_free_opaque`](@ref) — a raw pointer return would be
indistinguishable from any other `void *`.

An opaque carrier is registered for a Julia type with
[`@register_opaque_carrier`](@ref); the object stays reachable (rooted in a
per-type storage table) until the pointer is freed.
"""
struct COpaque
    ptr::Ptr{Cvoid}
end

# Type-agnostic list of all active destructors. `length` is the number of
# opaque handles currently rooted; a library that wants to expose that count
# (e.g. to observe garbage collection from a foreign caller) can read this
# registry from its own `@ccallable` — see `examples/opaque_gc`.
const type_specific_free_func_map = Dict{Ptr{Cvoid}, Ptr{Cvoid}}()

const opaque_storage_lock = Threads.SpinLock()

"""
    JLWInterop._free_opaque(ptr::Ptr{Cvoid})

Release the Julia object behind an opaque handle, dropping the root that kept it
alive. `ptr` is the pointer carried by a [`COpaque`](@ref); a null pointer is a
no-op. Internal; exposed at a `@ccallable` boundary as `jlw_free_opaque` by
[`@export_release_entrypoints`](@ref), so an opaque return is freed on the same
opt-in as the other owning carriers.
"""
function _free_opaque(ptr::Ptr{Cvoid})
    ptr == C_NULL && return nothing
    lock(opaque_storage_lock) do
        ccall(type_specific_free_func_map[ptr], Cvoid, (Clonglong,), ptr)
        delete!(type_specific_free_func_map, ptr) # Must be called when destructors is already locked
        nothing
    end
    nothing
end

_pointable_type(T) = ismutabletype(T) ? T : Base.RefValue{T}
_maybe_ref(x) = ismutabletype(typeof(x)) ? x : Ref(x)
_maybe_deref(T, x) = ismutabletype(T) ? x : x[]

macro register_opaque_carrier(
    jltype::Union{Expr, Symbol, DataType}
)
    type_specific_free_func  = GlobalRef(__module__, gensym("destructor_$jltype"))
    type_specific_storage    = GlobalRef(__module__, gensym("gc_storage_$jltype"))

    return quote
        # Create a global type-specific storage
        const $type_specific_storage = Dict{Ptr{Cvoid}, _pointable_type($(esc(jltype)))}()

        # A function for removing an index at position ind
        # from the type-specific global storage
        function $type_specific_free_func(ptr::Ptr{Cvoid})
            delete!($type_specific_storage, ptr)
            nothing
        end

        # The opaque carrier is a distinct struct rather than a bare
        # `Ptr{Cvoid}`, so targets recognize it structurally in the ABI.
        $(GlobalRef(@__MODULE__, :carrier_type))(::Type{$(esc(jltype))}) = COpaque

        function $(GlobalRef(@__MODULE__, :from_carrier))(::Type{$(esc(jltype))}, c::COpaque)
            lock(opaque_storage_lock) do
                # The dict's value type is `_pointable_type(jltype)`, so the
                # stored value is already the right type; no assertion needed.
                stored = $type_specific_storage[c.ptr]
                _maybe_deref($(esc(jltype)), stored)
            end
        end

        function $(GlobalRef(@__MODULE__, :to_carrier))(obj::$(esc(jltype)))::COpaque
            lock(opaque_storage_lock) do
                obj_pointable = _maybe_ref(obj)
                ptr::Ptr{Cvoid} = pointer_from_objref(obj_pointable)

                $type_specific_storage[ptr] = obj_pointable
                type_specific_free_func_map[ptr] = @cfunction($type_specific_free_func, Cvoid, (Ptr{Cvoid},))
                return COpaque(ptr)
            end
        end
    end
end
