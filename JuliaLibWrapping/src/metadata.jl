# API metadata sidecar: read the JSON `JLWInterop.write_metadata` produces
# and validate it against the ABI JSON `juliac` produces for the same build.

"""
    read_api_metadata(path::AbstractString) -> NamedTuple{(:exports, :enums)}

Read the `<lib>.jlw.json` API metadata sidecar written by
`JLWInterop.write_metadata` and return `(; exports, enums)`:

- `exports` — symbol => `{"name", "args", "kwargs", "arg_enums"?, "return_enum"?, "doc"}`,
  as `JSON.parsefile` returns it, a `JSON.Object{String,Any}` that behaves as
  an `AbstractDict{String,Any}`.
- `enums` — name => `{"basetype", "members"}` (see `JLWInterop.write_metadata`),
  or an empty `Dict{String,Any}` when the sidecar is version 1, which has no
  `enums` table.

Throws an `ErrorException` when the file's `jlw_metadata_version` is neither
`1` nor `2`, the versions this reader understands.
"""
function read_api_metadata(path::AbstractString)
    doc = JSON.parsefile(path)
    version = doc["jlw_metadata_version"]
    version in (1, 2) || error(
        "unsupported jlw_metadata_version $version in $path " *
            "(this JuliaLibWrapping understands versions 1 and 2)"
    )
    enums = version == 2 ? doc["enums"] : Dict{String, Any}()
    return (exports = doc["exports"], enums = enums)
end

"""
    JuliaLibWrapping._ENUM_BASETYPES :: Set{String}

Julia scalar type names a sidecar enum's `"basetype"` may legally name: the
`Integer` subtypes of `JLWInterop._API_SCALARS` (a `Base.Enum`'s type
parameter must be an `Integer`, which excludes `Float32`/`Float64` from that
set regardless of this constant).
"""
const _ENUM_BASETYPES = Set{String}(
    ["Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64", "Bool"]
)

"""
    check_metadata_consistency(abi_info::ABIInfo, meta::AbstractDict, enums::AbstractDict = Dict{String,Any}()) -> Nothing

Validate an API metadata sidecar (as returned by [`read_api_metadata`](@ref):
`meta` is its `exports` map, `enums` its `enums` table) against the ABI JSON
produced for the same build. Throws an `ErrorException` on:

- a sidecar entry whose symbol has no matching entrypoint in the ABI;
- an argument-count mismatch: `length(args) + length(kwargs)` vs. the ABI
  entrypoint's argument count;
- an argument-name mismatch: `[args…; kwarg names…]` against the ABI
  entrypoint's argument names, elementwise. Targets associate the lists
  positionally, so a difference in either name or order would mislabel
  arguments.
- an `arg_enums` key that does not name a declared argument or keyword of
  that export;
- an `arg_enums` or `return_enum` value that names no entry in `enums`;
- an `enums` entry whose `"basetype"` is not in [`_ENUM_BASETYPES`](@ref);
- an `arg_enums`-annotated argument whose ABI type is not a primitive named
  exactly like its enum's `"basetype"`.
"""
function check_metadata_consistency(
        abi_info::ABIInfo, meta::AbstractDict, enums::AbstractDict = Dict{String, Any}()
    )
    (; entrypoints, typeinfo) = abi_info
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

        _check_enum_basetype(key, desc) = get(desc, "basetype", nothing) in _ENUM_BASETYPES || error(
            "API metadata sidecar entry '$symbol' references enum '$key', whose " *
                "basetype '$(get(desc, "basetype", nothing))' is not a known scalar type"
        )
        _resolve_enum(key) = begin
            desc = get(enums, key, nothing)
            isnothing(desc) && error(
                "API metadata sidecar entry '$symbol' references enum '$key', which has " *
                    "no entry in the sidecar's `enums` table"
            )
            _check_enum_basetype(key, desc)
            desc
        end

        arg_enums = get(entry, "arg_enums", nothing)
        if arg_enums !== nothing
            for (argname, key) in arg_enums
                idx = findfirst(==(String(argname)), declared)
                isnothing(idx) && error(
                    "API metadata sidecar entry '$symbol' declares an enum for argument " *
                        "'$argname', which is not one of its declared arguments $declared"
                )
                desc = _resolve_enum(String(key))
                basetype = desc["basetype"]
                abi_type = typeinfo[method.args[idx].type]
                (abi_type isa PrimitiveTypeDesc && abi_type.name == basetype) || error(
                    "API metadata sidecar entry '$symbol' declares argument '$argname' as " *
                        "enum '$key' with basetype '$basetype', but the ABI entrypoint's " *
                        "argument type is " *
                        (abi_type isa PrimitiveTypeDesc ? "'$(abi_type.name)'" : "not primitive")
                )
            end
        end

        return_enum = get(entry, "return_enum", nothing)
        return_enum === nothing || _resolve_enum(String(return_enum))
    end
    return nothing
end
