# API metadata sidecar: read the JSON `JLWInterop.write_metadata` produces
# and validate it against the ABI JSON `juliac` produces for the same build.

"""
    read_api_metadata(path::AbstractString) -> AbstractDict

Read the `<lib>.jlw.json` API metadata sidecar written by
`JLWInterop.write_metadata` and return its `exports` map — symbol =>
`{"name", "args", "kwargs", "doc"}` — as `JSON.parsefile` returns it, a
`JSON.Object{String,Any}` that behaves as an `AbstractDict{String,Any}`.
Throws an `ErrorException` when the file's `jlw_metadata_version` is not `1`,
the only version this reader understands.
"""
function read_api_metadata(path::AbstractString)
    doc = JSON.parsefile(path)
    version = doc["jlw_metadata_version"]
    version == 1 || error(
        "unsupported jlw_metadata_version $version in $path " *
            "(this JuliaLibWrapping understands version 1)"
    )
    return doc["exports"]
end

"""
    check_metadata_consistency(abi_info::ABIInfo, meta::AbstractDict) -> Nothing

Validate an API metadata sidecar (as returned by [`read_api_metadata`](@ref))
against the ABI JSON produced for the same build. Throws an `ErrorException`
on:

- a sidecar entry whose symbol has no matching entrypoint in the ABI;
- an argument-count mismatch: `length(args) + length(kwargs)` vs. the ABI
  entrypoint's argument count;
- an argument-name mismatch: `[args…; kwarg names…]` against the ABI
  entrypoint's argument names, elementwise. Targets associate the lists
  positionally, so a difference in either name or order would mislabel
  arguments.
"""
function check_metadata_consistency(abi_info::ABIInfo, meta::AbstractDict)
    (; entrypoints) = abi_info
    by_symbol = Dict(m.symbol => m for m in entrypoints)
    for (symbol, entry) in meta
        method = get(by_symbol, symbol, nothing)
        isnothing(method) && error(
            "API metadata sidecar entry '$symbol' has no matching entrypoint in the ABI"
        )
        nargs = length(entry["args"]) + length(entry["kwargs"])
        nargs == length(method.args) || error(
            "API metadata sidecar entry '$symbol' declares $nargs argument(s) " *
                "($(length(entry["args"])) positional + $(length(entry["kwargs"])) keyword) " *
                "but the ABI entrypoint takes $(length(method.args))"
        )
        declared = String[String(a) for a in entry["args"]]
        append!(declared, String(kw["name"]) for kw in entry["kwargs"])
        actual = String[a.name for a in method.args]
        declared == actual || error(
            "API metadata sidecar entry '$symbol' declares arguments $declared " *
                "but the ABI entrypoint takes $actual"
        )
    end
    return nothing
end
