# Error handling across the ABI

A Julia `throw` inside a `--trim`-compiled `@ccallable` does not become a
Python exception — at best it aborts the host process. JuliaLibWrapping
defines a small convention for surfacing errors across the C ABI so that
generated wrappers can translate them into native exceptions.

## The `JLWStatus` convention

The canonical status struct is defined in the [JLWInterop](@ref)
subdir package and has the following shape:

```julia
struct JLWStatus
    code::Int32                       # 0 == success; non-zero == error
    message::NTuple{256, UInt8}       # UTF-8, null-terminated
end
```

A library opts in by *either*

1. returning a `JLWStatus` directly, or
2. returning a struct that contains a `JLWStatus` field (any field name).

Either form is recognized by the Python backend.

The fixed 256-byte message buffer is deliberate: a `Cstring` or `Ptr{UInt8}`
would raise an ownership question (who frees it, when?) that has no good
answer under `juliac --trim`. An inline buffer keeps `JLWStatus` an `isbits`
type with no heap allocation, at the cost of a bounded message length.

## Authoring a library

Add `JLWInterop` to your library's project, then construct status values
with the provided helpers:

```julia
using JLWInterop

struct ResultStruct
    status::JLWStatus
    value::Float64
end

Base.@ccallable function compute(x::Float64)::ResultStruct
    x < 0 && return ResultStruct(jlw_error(1, "negative input"), 0.0)
    return ResultStruct(jlw_ok(), x * 2)
end
```

`jlw_ok()` and `jlw_error(code, msg)` perform no heap allocation, so they
are safe in `--trim` builds.

## What the Python wrapper does

For each entrypoint whose return type carries a `JLWStatus` (directly or via
an embedded field), the generated wrapper checks `status.code` and raises a
`JLWError` (a `RuntimeError` subclass, carrying `.code` and `.message`) when
it is non-zero:

```python
from mylib import compute, JLWError

try:
    result = compute(-1.0)
except JLWError as e:
    print(e.code, e.message)   # 1, "negative input"
```

On success the full return struct is handed back unchanged, including the
status field (so callers can still inspect it explicitly if they prefer).

## C backend

The C header generator does not currently auto-emit a status-check macro;
C callers should check `result.status.code` themselves and read the message
with e.g. `printf("%.256s\n", result.status.message)`. A `JLW_CHECK`-style
helper macro is a possible follow-up.

## Recognition is structural

The Python emitter matches on struct name (`"JLWStatus"`) plus field shape
(`code::Int32` followed by a 256-byte tuple `message`). Authors who copy and
paste a compatible definition — rather than depending on JLWInterop — still
get the same wrapper behavior. The canonical package merely keeps the
definition from drifting across libraries.
