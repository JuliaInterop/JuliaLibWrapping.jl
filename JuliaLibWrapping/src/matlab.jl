"""
    MatlabTarget(dir, package_name, library_basename)

Emit MATLAB bindings for a JuliaLibWrapping library into `dir`.

`package_name` names a MATLAB package directory, written as `+<package_name>`,
so a wrapped function is called as `<package_name>.f(x)` and cannot collide
with a name already on the MATLAB path. `library_basename` is the shared
library's name without its extension.

The emitted sources are compiled by MATLAB, not by this package: emitting
needs no MATLAB installed, exactly as [`PythonTarget`](@ref) needs no Python.
"""
struct MatlabTarget <: AbstractTarget
    dir::String
    package_name::String
    library_basename::String
end

MatlabTarget(
    dir::AbstractString, package_name::AbstractString,
    library_basename::AbstractString
) = MatlabTarget(String(dir), String(package_name), String(library_basename))

function Base.show(io::IO, t::MatlabTarget)
    print(
        io, "MatlabTarget(", repr(t.dir), ", ", repr(t.package_name),
        ", ", repr(t.library_basename), ")"
    )
    return nothing
end

"""
    MATLAB_KEYWORDS :: Set{String}

The words MATLAB reserves, as `iskeyword` reports them. One of these used as
an identifier is a syntax error, so [`sanitize_matlab_name`](@ref) suffixes it.
"""
const MATLAB_KEYWORDS = Set{String}(
    [
        "break", "case", "catch", "classdef", "continue", "else", "elseif",
        "end", "for", "function", "global", "if", "otherwise", "parfor",
        "persistent", "return", "spmd", "switch", "try", "while",
    ]
)

"""
    sanitize_matlab_name(name) -> String

Return a MATLAB-identifier form of `name`. MATLAB identifiers begin with a
letter and continue with letters, digits and underscores, which is stricter
than C: a leading underscore is legal in C and in the Python emitter's output,
but not here, so [`sanitize_for_c`](@ref)'s result is prefixed with `x` when it
does not begin with a letter. A reserved word is suffixed with `_`.
"""
function sanitize_matlab_name(name::AbstractString)
    sanitized = sanitize_for_c(name)
    isempty(sanitized) && return "x"
    isletter(first(sanitized)) || (sanitized = "x" * sanitized)
    sanitized in MATLAB_KEYWORDS && (sanitized *= "_")
    return sanitized
end

"""
    _matlab_gateway_name(dest::MatlabTarget) -> String

The gateway's MEX function name. It lives under the package's `private/`
directory, so it is callable from the façades and invisible everywhere else.
"""
_matlab_gateway_name(dest::MatlabTarget) = dest.library_basename * "_mex"

"""
    _matlab_entry_name(method, api_entry) -> String

The name a façade is written under: the declared public name when the sidecar
records one, otherwise the exported symbol.
"""
function _matlab_entry_name(method::MethodDesc, api_entry)
    isnothing(api_entry) && return sanitize_matlab_name(method.symbol)
    return sanitize_matlab_name(get(api_entry, "name", method.symbol))
end

"""
    _matlab_arg_names(method, api_entry) -> (positional, keywords)

The façade's argument names. The sidecar records the declared names, which
read better than the ABI's; a symbol absent from it falls back to the ABI
argument names. Keywords become a name-value block, so they are kept apart
from the positional arguments.
"""
function _matlab_arg_names(method::MethodDesc, api_entry)
    seen = Set{String}()
    if isnothing(api_entry)
        names = String[sanitize_matlab_name(a.name) for a in method.args]
        return (_uniquify!(names, seen), String[])
    end
    positional = String[sanitize_matlab_name(n) for n in get(api_entry, "args", [])]
    keywords = String[
        sanitize_matlab_name(kw["name"]) for kw in get(api_entry, "kwargs", [])
    ]
    return (_uniquify!(positional, seen), _uniquify!(keywords, seen))
end

# Sanitizing can map two declared names onto one, which MATLAB rejects in a
# signature. Suffix the later of a pair rather than silently shadowing it.
function _uniquify!(names::Vector{String}, seen::Set{String})
    for i in eachindex(names)
        candidate = names[i]
        n = 2
        while candidate in seen
            candidate = names[i] * string(n)
            n += 1
        end
        push!(seen, candidate)
        names[i] = candidate
    end
    return names
end
