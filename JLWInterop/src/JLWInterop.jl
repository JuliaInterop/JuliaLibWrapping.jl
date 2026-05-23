"""
    JLWInterop

Canonical types for the JuliaLibWrapping cross-ABI error convention (issue #15).

A library author opts in by including a `JLWStatus` field in any
`@ccallable`-returned struct; the JuliaLibWrapping Python emitter then
recognizes the field by struct name and emits code that raises a native
Python exception when `status.code != 0`.

This package deliberately has no dependencies so it stays
`juliac --trim`-friendly: it is intended to be a build-time *and* runtime
dependency of compiled libraries.
"""
module JLWInterop

export JLWStatus, jlw_ok, jlw_error

const JLW_MESSAGE_BYTES = 256

"""
    JLWStatus

ABI-stable status struct. `code == 0` means success; any non-zero value is an
error code chosen by the library. `message` is a UTF-8, null-terminated
buffer of fixed length ([`JLW_MESSAGE_BYTES`](@ref) bytes). The fixed buffer
avoids the ownership/lifetime question that `Cstring`/`Ptr{UInt8}` would raise
under `--trim`; payload size is bounded but no allocation is required to
construct one.
"""
struct JLWStatus
    code::Int32
    message::NTuple{JLW_MESSAGE_BYTES, UInt8}
end

"""
    jlw_ok() -> JLWStatus

Return a success status: code 0 with an empty message buffer.
"""
jlw_ok() = JLWStatus(Int32(0), ntuple(_ -> 0x00, JLW_MESSAGE_BYTES))

"""
    jlw_error(code::Integer, msg::AbstractString) -> JLWStatus

Return an error status with the given non-zero `code` and `msg`. `msg` is
copied into the fixed-size buffer, truncated to `JLW_MESSAGE_BYTES - 1` bytes
if necessary, and always null-terminated. `code` is converted to `Int32`.

Constructing this status performs no heap allocation.
"""
function jlw_error(code::Integer, msg::AbstractString)
    bytes = codeunits(msg)
    n = min(length(bytes), JLW_MESSAGE_BYTES - 1)
    buf = ntuple(JLW_MESSAGE_BYTES) do i
        i <= n ? bytes[i] : 0x00
    end
    return JLWStatus(Int32(code), buf)
end

end # module
