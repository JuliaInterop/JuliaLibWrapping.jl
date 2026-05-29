module ols

# Tiny OLS regression library, wrapped end-to-end for the JuliaLibWrapping
# tutorial. Three entrypoints exercise the recognized JLWInterop vocabulary:
# `fit` returns a struct embedding a `JLWStatus` (so its façade wrapper is
# the hand-edited path), `predict` returns `JLWStatus` directly (the
# auto-wrapped path that raises `JLWError` on failure), and `summary_report`
# writes into a caller-allocated `CString` buffer.

using JLWInterop
using LinearAlgebra

struct FitResult
    status::JLWStatus
    coeffs::CVector{Float64}
    r_squared::Float64
end

# Caller-owned storage discipline: `coeffs_buf` is allocated by the caller
# and outlives the call; the returned `FitResult.coeffs` aliases it.
Base.@ccallable function fit(X::CMatrix{Float64},
                              y::CVector{Float64},
                              coeffs_buf::CVector{Float64})::FitResult
    n, p = size(X)
    if length(y) != n
        return FitResult(jlw_error(1, "y length must match X rows"), coeffs_buf, 0.0)
    end
    if length(coeffs_buf) != p
        return FitResult(jlw_error(2, "coeffs_buf length must match X cols"), coeffs_buf, 0.0)
    end
    if n < p
        return FitResult(jlw_error(3, "underdetermined system (rows < cols)"), coeffs_buf, 0.0)
    end

    coeffs = X \ y
    @inbounds for i in 1:p
        coeffs_buf[i] = coeffs[i]
    end

    ymean = 0.0
    @inbounds for i in 1:n
        ymean += y[i]
    end
    ymean /= n
    ss_tot = 0.0
    ss_res = 0.0
    @inbounds for i in 1:n
        yhat = 0.0
        for j in 1:p
            yhat += X[i, j] * coeffs_buf[j]
        end
        d_tot = y[i] - ymean
        ss_tot += d_tot * d_tot
        d_res = y[i] - yhat
        ss_res += d_res * d_res
    end
    r_squared = ss_tot == 0 ? 0.0 : 1.0 - ss_res / ss_tot
    return FitResult(jlw_ok(), coeffs_buf, r_squared)
end

Base.@ccallable function predict(coeffs::CVector{Float64},
                                  X::CMatrix{Float64},
                                  out::CVector{Float64})::JLWStatus
    n, p = size(X)
    if length(coeffs) != p
        return jlw_error(1, "coeffs length must match X cols")
    end
    if length(out) != n
        return jlw_error(2, "out length must match X rows")
    end
    @inbounds for i in 1:n
        s = 0.0
        for j in 1:p
            s += X[i, j] * coeffs[j]
        end
        out[i] = s
    end
    return jlw_ok()
end

Base.@ccallable function summary_report(result::FitResult, buf::CString)::JLWStatus
    if result.status.code != 0
        return jlw_error(101, "result has non-zero status; nothing to report")
    end
    msg = "OLS fit: " * string(length(result.coeffs)) *
          " coefficients, R^2 = " * string(result.r_squared)
    bytes = codeunits(msg)
    capacity = Int(buf.length)
    if length(bytes) > capacity
        return jlw_error(102, "report buffer too small")
    end
    @inbounds for i in 1:length(bytes)
        unsafe_store!(buf.data, bytes[i], i)
    end
    @inbounds for i in (length(bytes) + 1):capacity
        unsafe_store!(buf.data, 0x00, i)
    end
    return jlw_ok()
end

end # module
