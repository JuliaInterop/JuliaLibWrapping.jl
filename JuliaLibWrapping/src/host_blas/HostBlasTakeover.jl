# HostBlasTakeover
#
# Retarget Julia's `LinearAlgebra` BLAS/LAPACK entry points at a BLAS that is
# already loaded in the calling process, so that a wrapped library and its
# host (typically NumPy) share one backend and one thread pool.
#
# JuliaLibWrapping compiles this file into the wrapped library when a
# [`PythonTarget`](@ref) asks for `host_blas = true`; see `src/host_blas.jl`
# for the build side and the generated import-time hook.
#
# The file is written for `juliac --trim=safe`. The trim verifier rejects
# exception-based error reporting: a `catch` hands the verifier an exception
# of type `Any`, which it cannot resolve. Every failure path below therefore
# returns a status code and stores a fixed message, and the dynamic loading
# uses the non-throwing `dlopen_e`/`dlsym_e` forms.
#
# The tricky part is that PyPI NumPy's OpenBLAS is *namespaced*: it exports
# `scipy_dgemm_64_`, not `dgemm_64_`. LBT autodetects a symbol *suffix* but
# has no notion of a symbol *prefix*, so `lbt_forward()` finds nothing in it.
# We therefore install the forwards one by one with LBT's "footgun" API,
# `lbt_set_forward()`, mapping each exported BLAS name to its `scipy_..._64_`
# counterpart in the host library.
#
# Both sides are ILP64, so no width conversion is involved.
module HostBlasTakeover

using LinearAlgebra
using Libdl

const BLAS = LinearAlgebra.BLAS

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

@inline function _copy_out(out::Ptr{UInt8}, outlen::Cint, s::AbstractString)
    outlen <= 0 && return Cint(0)
    n = min(sizeof(s), Int(outlen) - 1)
    if n > 0
        bytes = codeunits(String(s))
        GC.@preserve bytes unsafe_copyto!(out, pointer(bytes), n)
    end
    unsafe_store!(out, UInt8(0), n + 1)
    return Cint(n)
end

const _LAST_ERROR = Ref{String}("")
const _HANDLE = Ref{Ptr{Cvoid}}(C_NULL)
const _FORWARDED = Ref{Int}(0)
const _READY = Ref{Bool}(false)

# Record a fixed message and return the failure status. Fixed strings keep
# the trim verifier away from exception formatting (`sprint(showerror, e)`).
@inline function _fail(msg::AbstractString)
    _LAST_ERROR[] = String(msg)
    return Cint(-1)
end

# Symbol-mangling prefix and suffix of an already-loaded library.  LBT probes
# the same `isamax_`/`dpotrf_` bases, but only for the suffix; we try the
# empty prefix first and then the `scipy_` prefix NumPy's OpenBLAS uses.
function _detect(handle::Ptr{Cvoid})
    for prefix in ("", "scipy_")
        for suffix in ("", "_", "64", "_64", "64_", "_64_")
            for base in ("isamax_", "dpotrf_")
                Libdl.dlsym_e(handle, Symbol(prefix * base * suffix)) == C_NULL ||
                    return prefix, suffix
            end
        end
    end
    return nothing, nothing
end

# 64 for ILP64, 32 for LP64, -1 when undecidable.  Mirrors LBT's `ilaver`
# probe so that an LP64 host is refused before any trampoline is touched.
function _probe_interface(handle::Ptr{Cvoid}, prefix::String, suffix::String)
    f = Libdl.dlsym_e(handle, Symbol(prefix * "ilaver_" * suffix))
    if f != C_NULL
        major = Ref{Int64}(-1)
        minor = Ref{Int64}(-1)
        patch = Ref{Int64}(-1)
        ccall(f, Cvoid, (Ref{Int64}, Ref{Int64}, Ref{Int64}), major, minor, patch)
        major[] > 0 && return 64
        major[] < 0 && return 32
        return -1
    end
    g = Libdl.dlsym_e(handle, Symbol(prefix * "isamax_" * suffix))
    if g != C_NULL
        n = Ref{Int64}(reinterpret(Int64, 0xffffffff00000003))
        x = Float32[1.0f0, 2.0f0, 1.0f0]
        incx = Ref{Int64}(1)
        r = ccall(g, Int64, (Ref{Int64}, Ptr{Cfloat}, Ref{Int64}), n, x, incx) & 0xffffffff
        r == 0 && return 64
        r == 2 && return 32
    end
    return -1
end

# Address of `name` in the host, trying the plain and the MKL-style
# extra-underscore spellings of the suffix.
function _lookup(handle::Ptr{Cvoid}, prefix::String, suffix::String, name::AbstractString)
    a = Libdl.dlsym_e(handle, Symbol(prefix * name * suffix))
    a != C_NULL && return a
    return Libdl.dlsym_e(handle, Symbol(prefix * name * "_" * suffix))
end

# ---------------------------------------------------------------------------
# Takeover
# ---------------------------------------------------------------------------

"""
    hostblas_takeover(path) -> Cint

Retarget Julia's BLAS/LAPACK entry points at the shared library at `path`.
Returns 0 on success; on failure returns -1 (see `hostblas_last_error`).

A failure leaves the trampolines untouched, so a caller with several
candidate host libraries can try the next one.
"""
Base.@ccallable function hostblas_takeover(path::Ptr{UInt8})::Cint
    _READY[] = false
    p = unsafe_string(path)
    # Force LinearAlgebra initialization before touching the trampolines.
    BLAS.get_config()
    # The library is already loaded (it is the host's), so RTLD_NOLOAD returns
    # the existing handle instead of introducing a twin.
    handle = Libdl.dlopen_e(p, Libdl.RTLD_LAZY | Libdl.RTLD_NOLOAD)
    handle == C_NULL && (handle = Libdl.dlopen_e(p, Libdl.RTLD_LAZY))
    handle == C_NULL && return _fail("could not open the host BLAS")
    prefix, suffix = _detect(handle)
    prefix === nothing && return _fail("no BLAS/LAPACK symbols found in the host library")
    iface = _probe_interface(handle, prefix, suffix)
    iface != 64 && return _fail(
        iface == 32 ? "host has an LP64 interface; ILP64 is required" :
            "host interface is unknown; ILP64 is required",
    )
    # Check that this is a real BLAS before installing anything. A library
    # with only the autodetection probes (such as a bundle's placeholder)
    # exports `isamax`, `sdot`, `zdotc`, `cdotc`, and `ilaver`, but no gemm.
    # The check precedes the forwarding loop so a rejected candidate leaves
    # the trampolines untouched for the next one.
    _lookup(handle, prefix, suffix, "dgemm_") == C_NULL &&
        return _fail("host library exports no BLAS gemm")
    n = 0
    for sym in BLAS.get_config().exported_symbols
        addr = _lookup(handle, prefix, suffix, sym)
        addr == C_NULL && continue
        BLAS.lbt_set_forward(sym, addr, :ilp64)
        n += 1
    end
    _HANDLE[] = handle
    _FORWARDED[] = n
    _LAST_ERROR[] = ""
    _READY[] = true
    return Cint(0)
end

Base.@ccallable function hostblas_is_ready()::Cint
    return _READY[] ? Cint(1) : Cint(0)
end

Base.@ccallable function hostblas_forwarded_count()::Cint
    return Cint(_FORWARDED[])
end

Base.@ccallable function hostblas_last_error(out::Ptr{UInt8}, outlen::Cint)::Cint
    return _copy_out(out, outlen, _LAST_ERROR[])
end

end # module HostBlasTakeover
