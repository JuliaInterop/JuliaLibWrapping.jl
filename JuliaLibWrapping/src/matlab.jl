"""
    MatlabTarget(dir, package_name, library_basename)

Emit MATLAB bindings for a JuliaLibWrapping library into `dir`.

`package_name` becomes a `+<package_name>` directory, so a wrapped function is
called as `<package_name>.f(x)`. `library_basename` is the shared library's
name without its extension.

MATLAB compiles the emitted sources; emitting them is pure Julia.

`library_subdir` says where the shared library sits relative to `dir`, which
`build_mex.m` takes as its default. A bundled build puts it under
`<libname>-bundle/lib`.

An array argument is passed by reference, so the wrapped function reads
MATLAB's own buffer. An argument a `@api` declaration lists in `mutates` is
copied for the call instead, and the copy comes back as an output: MATLAB
gives assignment value semantics, so a write must not reach the caller's other
variables.
"""
struct MatlabTarget <: AbstractTarget
    dir::String
    package_name::String
    library_basename::String
    library_subdir::String
end

MatlabTarget(
    dir::AbstractString, package_name::AbstractString,
    library_basename::AbstractString; library_subdir::AbstractString = ""
) = MatlabTarget(
    String(dir), String(package_name), String(library_basename),
    String(library_subdir)
)

function Base.show(io::IO, t::MatlabTarget)
    print(
        io, "MatlabTarget(", repr(t.dir), ", ", repr(t.package_name),
        ", ", repr(t.library_basename), ")"
    )
    return nothing
end

"""
    MATLAB_KEYWORDS :: Set{String}

The words MATLAB reserves, as `iskeyword` reports them.
[`sanitize_matlab_name`](@ref) gives them an `_` suffix.
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

Return a MATLAB identifier for `name`. MATLAB identifiers start with a letter,
then take letters, digits and underscores — stricter than C. A
[`sanitize_for_c`](@ref) result starting with anything else gets an `x` prefix,
and a reserved word gets an `_` suffix.
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

The gateway's MEX function name. It lives in the package's `private/`, where
the façades can call it and other code cannot.
"""
_matlab_gateway_name(dest::MatlabTarget) =
    sanitize_matlab_name(dest.library_basename) * "_mex"

"""
    _matlab_types_header(dest::MatlabTarget) -> String

The header of carrier typedefs the gateway includes. Named after the gateway,
so it reads as this target's own file.
"""
_matlab_types_header(dest::MatlabTarget) = _matlab_gateway_name(dest) * "_types"

"""
    _matlab_entry_name(method, api_entry) -> String

The name a façade is written under: the sidecar's public name, or the exported
symbol.
"""
function _matlab_entry_name(method::MethodDesc, api_entry)
    isnothing(api_entry) && return sanitize_matlab_name(method.symbol)
    return sanitize_matlab_name(get(api_entry, "name", method.symbol))
end

"""
    _matlab_arg_names(method, api_entry) -> (positional, keywords)

The façade's argument names, from the sidecar when it has them and the ABI
otherwise. Keywords come back separately: they become a name-value block.
"""
function _matlab_arg_names(method::MethodDesc, api_entry)
    # Keywords arrive as a struct named `opts`, so a positional argument of
    # that name would shadow it and produce `function f(opts, opts)`.
    seen = Set{String}(["opts"])

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

"""
    MATLAB_CLASSES :: Dict{String, String}

The MATLAB class each carrier element type crosses as. The gateway checks
arguments against these and builds returns from them.
"""
const MATLAB_CLASSES = Dict{String, String}(
    "Float64" => "double", "Float32" => "single",
    "Int8" => "int8", "Int16" => "int16", "Int32" => "int32", "Int64" => "int64",
    "UInt8" => "uint8", "UInt16" => "uint16", "UInt32" => "uint32",
    "UInt64" => "uint64", "Bool" => "logical",
)

# The integer classes. These are declared with no class at all and converted
# in the façade body, so an argument that already has the class it needs
# crosses without a copy.
const _MATLAB_INTEGER_CLASSES = Set{String}(
    ["int8", "int16", "int32", "int64", "uint8", "uint16", "uint32", "uint64"]
)

"""
    _matlab_classify_arg(type_id, typeinfo) -> NamedTuple

Classify an entry point's argument for the façade and the gateway. `kind` is
one of:

- `:scalar` — a numeric or logical value, with the MATLAB `class` it arrives as
- `:string` — a borrowed `CString`, taken as `char` or `string`
- `:strarray` — a borrowed `CStrArray`, taken as a `cellstr`
- `:dict` — a borrowed `CDict`, taken as a `struct`
- `:array` — a borrowed `CArray` of rank `ndim`, borrowed in place
- `:opt` — a `COpt`, taken as the value or `[]`
- `:opaque` — anything else, which leaves the entry point unwrapped

An owning carrier is `:opaque` as an argument: arguments cross borrowed.
"""
function _matlab_classify_arg(type_id::Int, typeinfo::OrderedDict{Int, TypeDesc})
    desc = typeinfo[type_id]
    if desc isa PrimitiveTypeDesc
        class = get(MATLAB_CLASSES, desc.name, nothing)
        isnothing(class) && return (kind = :opaque, reason = "unsupported scalar type `$(desc.name)`")
        return (kind = :scalar, class = class, integer = class in _MATLAB_INTEGER_CLASSES)
    end
    desc isa StructDesc || return (kind = :opaque, reason = "argument is not a struct")

    info = cstring_struct_info(desc, typeinfo)
    if !isnothing(info)
        info.ownership === :borrowed || return _matlab_owning_argument("CString")
        return (kind = :string, length_bits = info.length_bits)
    end
    info = cstrarray_struct_info(desc, typeinfo)
    if !isnothing(info)
        info.ownership === :borrowed || return _matlab_owning_argument("CStrArray")
        return (;
            kind = :strarray, length_bits = info.length_bits,
            element_bits = info.element_length_bits,
        )
    end
    info = cdict_struct_info(desc, typeinfo)
    if !isnothing(info)
        info.ownership === :borrowed || return _matlab_owning_argument("CDict")
        class = get(MATLAB_CLASSES, info.value_type, nothing)
        isnothing(class) && return (kind = :opaque, reason = "unsupported dictionary value type `$(info.value_type)`")
        return (kind = :dict, class = class, length_bits = info.length_bits)
    end
    info = carray_struct_info(desc, typeinfo)
    if !isnothing(info)
        info.ownership === :borrowed || return _matlab_owning_argument("CArray")
        class = get(MATLAB_CLASSES, info.eltype, nothing)
        isnothing(class) && return (kind = :opaque, reason = "unsupported array element type `$(info.eltype)`")
        return (;
            kind = :array, class = class, ndim = info.ndim,
            dims_bits = info.dims_bits,
            integer = class in _MATLAB_INTEGER_CLASSES || class == "logical",
        )
    end
    info = copt_struct_info(desc, typeinfo)
    if !isnothing(info)
        class = get(MATLAB_CLASSES, info.value_type, nothing)
        isnothing(class) && return (kind = :opaque, reason = "unsupported optional payload type `$(info.value_type)`")
        return (kind = :opt, class = class, integer = class in _MATLAB_INTEGER_CLASSES)
    end
    return (kind = :opaque, reason = "unrecognized argument carrier `$(desc.name)`")
end

_matlab_owning_argument(family::AbstractString) = (
    kind = :opaque,
    reason = "an owning $family cannot be an argument; arguments are borrowed",
)

"""
    _matlab_classify_return(type_id, typeinfo, release_present) -> NamedTuple

Classify an entry point's return for the façade and the gateway. `kind` is one
of:

- `:none` — no return at all, so the gateway just calls
- `:void` — a bare `JLWStatus`, which the gateway checks and discards
- `:result` — a `JLWResult{C}`; `inner` is this classification applied to `C`
- `:scalar` — a numeric or logical value
- `:string`, `:strarray`, `:dict`, `:array` — a carrier the gateway copies into
  a new `mxArray`
- `:opt` — a `COpt`, copied by value, becoming the value or `[]`
- `:tuple` — a `CNTuple`; `elements` is this classification applied to each
  element and `fields` names them, or is `nothing` when juliac emitted the
  inner tuple as an inline array
- `:opaque` — anything else, which leaves the entry point unwrapped

Every classification carries `owns`: whether the gateway must release Julia's
storage for it. A tuple's release loop reads it, and it must hold for every
element — a caller may request fewer outputs than a declaration produces, but
the unrequested ones are allocated all the same.

An owning return classifies `:opaque` when `release_present` is `false`: the
library exports no deallocation entry points, so the gateway would have nothing
to call.
"""
function _matlab_classify_return(
        type_id::Union{Int, Nothing}, typeinfo::OrderedDict{Int, TypeDesc},
        release_present::Bool
    )
    # No return type at all, unlike a `JLWStatus`: there is no value to check.
    type_id === nothing && return (kind = :none, owns = false)
    desc = typeinfo[type_id]
    if desc isa PrimitiveTypeDesc
        class = get(MATLAB_CLASSES, desc.name, nothing)
        isnothing(class) && return (kind = :opaque, reason = "unsupported scalar type `$(desc.name)`", owns = false)
        return (kind = :scalar, class = class, owns = false)
    end
    desc isa StructDesc || return (kind = :opaque, reason = "return is not a struct", owns = false)

    result = jlwresult_struct_info(desc, typeinfo)
    if !isnothing(result)
        inner = _matlab_classify_return(result.value_type_id, typeinfo, release_present)
        inner.kind === :opaque && return (kind = :opaque, reason = inner.reason, owns = false)
        return (kind = :result, inner = inner, owns = inner.owns)
    end
    is_jlwstatus_struct(desc, typeinfo) && return (kind = :void, owns = false)

    info = cstring_struct_info(desc, typeinfo)
    !isnothing(info) && return _matlab_owned_return(:string, info.ownership, release_present)
    info = cstrarray_struct_info(desc, typeinfo)
    !isnothing(info) && return _matlab_owned_return(:strarray, info.ownership, release_present)
    info = cdict_struct_info(desc, typeinfo)
    if !isnothing(info)
        class = get(MATLAB_CLASSES, info.value_type, nothing)
        isnothing(class) && return (kind = :opaque, reason = "unsupported dictionary value type `$(info.value_type)`", owns = false)
        return _matlab_owned_return(:dict, info.ownership, release_present; class)
    end
    info = carray_struct_info(desc, typeinfo)
    if !isnothing(info)
        class = get(MATLAB_CLASSES, info.eltype, nothing)
        isnothing(class) && return (kind = :opaque, reason = "unsupported array element type `$(info.eltype)`", owns = false)
        return _matlab_owned_return(:array, info.ownership, release_present; class, ndim = info.ndim)
    end
    info = copt_struct_info(desc, typeinfo)
    if !isnothing(info)
        class = get(MATLAB_CLASSES, info.value_type, nothing)
        isnothing(class) && return (kind = :opaque, reason = "unsupported optional payload type `$(info.value_type)`", owns = false)
        # `COpt` is stored by value, so there is nothing to release.
        return (kind = :opt, class = class, owns = false)
    end
    info = ctuple_struct_info(desc, typeinfo)
    if !isnothing(info)
        elements = [
            _matlab_classify_return(id, typeinfo, release_present)
                for id in info.element_type_ids
        ]
        for el in elements
            el.kind === :opaque && return (kind = :opaque, reason = el.reason, owns = false)
            el.kind in (:tuple, :result, :void, :none) && return (
                kind = :opaque,
                reason = "a tuple element the gateway cannot build an mxArray from",
                owns = false,
            )
        end
        return (
            kind = :tuple, elements = elements, fields = info.element_fields,
            owns = any(el -> el.owns, elements),
        )
    end
    return (kind = :opaque, reason = "unrecognized return carrier `$(desc.name)`", owns = false)
end

# A storage-backed return is owned by the caller, and releasing it needs the
# library's deallocation entry points. Without them there is nothing to call,
# so the entry point is left unwrapped rather than leaked.
function _matlab_owned_return(
        kind::Symbol, ownership::Symbol, release_present::Bool; extra...
    )
    ownership === :borrowed && return (; kind, owns = false, extra...)
    release_present || return (
        kind = :opaque,
        reason = "owning return needs release entrypoints; add JLWInterop.@export_release_entrypoints to the library",
        owns = false,
    )
    return (; kind, owns = true, extra...)
end

"""
    _matlab_literal(value) -> String

Render a sidecar keyword default as MATLAB source.
"""
function _matlab_literal(value)
    value isa Bool && return value ? "true" : "false"
    value isa Integer && return string(value)
    value isa AbstractFloat && return isinteger(value) ? string(value) : repr(value)
    value isa AbstractString && return "\"" * replace(String(value), "\"" => "\"\"") * "\""
    isnothing(value) && return "[]"
    return error("unsupported MATLAB default value of type $(typeof(value))")
end

"""
    _matlab_arg_validation(kind, name) -> String

The `arguments`-block declaration following one argument's name.

An integer argument carries no class. A block converts before its validators
run, so declaring the class would round `2.5` to `3` and pass the integrality
check; declaring `double` would convert the caller's array and lose both its
class and the borrow. `mustBeInteger` takes the integer classes and
whole-valued doubles alike, and the body converts what is left.
"""
function _matlab_arg_validation(kind, name::AbstractString)
    kind.kind === :scalar &&
        return kind.integer ? "(1,1) {mustBeNumericOrLogical, mustBeInteger}" :
        "(1,1) " * kind.class
    # `string` accepts a char row vector too: the block converts it.
    kind.kind === :string && return "(1,1) string"
    # No class: `cellstr` in the body takes a cell, a string array or a char
    # matrix.
    kind.kind === :strarray && return ""
    kind.kind === :dict && return "(1,1) struct"
    # A vector argument takes either orientation; the body normalizes it.
    # An integer or logical array carries no class, so MATLAB hands over the
    # array the caller built: an image stays `uint8` rather than arriving as
    # `double`. `mustBeVector` needs the flag to accept `[]`, which is 0x0.
    if kind.kind === :array
        class = kind.integer ? "" : kind.class
        checks = String[]
        if kind.class == "logical"
            # `logical(2)` is `true`, so 0 and 1 are the whole domain.
            push!(checks, "mustBeNumericOrLogical", "mustBeMember(" * name * ", [0 1])")
        elseif kind.integer
            push!(checks, "mustBeNumericOrLogical", "mustBeInteger")
        end
        kind.ndim == 1 &&
            push!(checks, "mustBeVector(" * name * ", \"allow-all-empties\")")
        isempty(checks) && return class
        return strip(class * " {" * join(checks, ", ") * "}")
    end
    # Absent is `[]`, present is a scalar; the body tells them apart. An
    # integer payload carries no class, for the reason a scalar one does not.
    kind.kind === :opt && return kind.integer ?
        "(:,:) {mustBeNumericOrLogical, mustBeInteger}" : "(:,:) " * kind.class
    return error("no MATLAB validation for argument kind $(kind.kind)")
end

"""
    _matlab_arg_forward(name, kind, mutated) -> String

The expression a façade passes to the gateway for one argument.
"""
function _matlab_arg_forward(name::AbstractString, kind, mutated::Bool = false)
    # The gateway reads `char`; the C API reads char arrays only.
    kind.kind === :string && return "convertStringsToChars(" * name * ")"
    kind.kind === :strarray && return "cellstr(" * name * ")"
    # A MATLAB vector arrives 1×N or N×1; `(:)` yields the column the carrier
    # expects, without a copy. A mutated argument comes back, so it is passed
    # as it stands: the carrier counts elements, and reshaping it here would
    # return a column to a caller who passed a row.
    if kind.kind === :array
        flat = kind.ndim == 1 && !mutated ? name * "(:)" : name
        # Declared `double`, so convert once the block has validated it.
        return kind.integer ? kind.class * "(" * flat * ")" : flat
    end
    kind.kind === :scalar && kind.integer && return kind.class * "(" * name * ")"
    return String(name)
end

"""
    _matlab_facade_plan(method, typeinfo, release_present, api_entry) -> NamedTuple

Decide whether an entry point gets a façade, and gather what writing one needs.
`kind` is `:auto` when every argument and the return are mapped, and `:skip`
otherwise, with a `reason`.

`:skip` emits no file at all: MATLAB reports a missing function clearly, but a
façade that exists and fails looks like a bug in the wrapped library.
"""
function _matlab_facade_plan(
        method::MethodDesc, typeinfo::OrderedDict{Int, TypeDesc},
        release_present::Bool, api_entry, api_enums::AbstractDict = Dict{String, Any}()
    )
    args = [_matlab_classify_arg(a.type, typeinfo) for a in method.args]
    for (i, a) in pairs(args)
        a.kind === :opaque &&
            return (kind = :skip, reason = "argument $i: " * a.reason)
    end
    ret = _matlab_classify_return(method.return_type, typeinfo, release_present)
    ret.kind === :opaque && return (kind = :skip, reason = "return: " * ret.reason)

    positional, keywords = _matlab_arg_names(method, api_entry)
    length(positional) + length(keywords) == length(args) || return (
        kind = :skip,
        reason = "the sidecar names $(length(positional) + length(keywords)) arguments but the ABI has $(length(args))",
    )
    defaults = isnothing(api_entry) ? Any[] :
        # A recorded `nothing` is a default; a missing key means there is
        # none. Both read as `nothing`, so keep them apart.
        Any[
            haskey(kw, "default") ? Some(kw["default"]) : nothing
            for kw in get(api_entry, "kwargs", [])
        ]

    # An enum argument is declared by name in the sidecar, and its default is
    # recorded as a member name. The façade accepts either a member name or
    # the underlying integer, so the declared names travel with the plan.
    declared = vcat(positional, keywords)
    arg_enums = isnothing(api_entry) ? Dict{String, Any}() :
        get(api_entry, "arg_enums", Dict{String, Any}())
    enums = Union{Nothing, String}[
        get(arg_enums, raw, nothing) for raw in _matlab_declared_names(method, api_entry)
    ]
    for e in enums
        isnothing(e) || haskey(api_enums, e) ||
            return (kind = :skip, reason = "argument enum `$e` is missing from the sidecar")
    end
    return_enum = isnothing(api_entry) ? nothing : get(api_entry, "return_enum", nothing)
    isnothing(return_enum) || haskey(api_enums, return_enum) ||
        return (kind = :skip, reason = "return enum `$return_enum` is missing from the sidecar")

    # A declaration says which arguments it writes to; those are copied for
    # the call and returned. The names are the sidecar's own spelling.
    raw = _matlab_declared_names(method, api_entry)
    mutates = Int[]
    for name in (isnothing(api_entry) ? String[] : get(api_entry, "mutates", String[]))
        i = findfirst(==(String(name)), raw)
        isnothing(i) && return (
            kind = :skip,
            reason = "`mutates` names `$name`, which is not an argument here",
        )
        args[i].kind === :array || return (
            kind = :skip,
            reason = "`mutates` names `$name`, which is not an array argument",
        )
        push!(mutates, i)
    end
    sort!(mutates)

    return (;
        kind = :auto, args, ret, positional, keywords, defaults, enums, mutates,
        return_enum, api_enums, declared,
        name = _matlab_entry_name(method, api_entry),
        doc = isnothing(api_entry) ? "" : String(get(api_entry, "doc", "")),
    )
end

"""
    _matlab_declared_names(method, api_entry) -> Vector{String}

The argument names as the sidecar spells them, before sanitizing. `arg_enums`
is keyed by these, from which the MATLAB identifiers derive.
"""
function _matlab_declared_names(method::MethodDesc, api_entry)
    isnothing(api_entry) && return String[a.name for a in method.args]
    return vcat(
        String[String(n) for n in get(api_entry, "args", [])],
        String[String(kw["name"]) for kw in get(api_entry, "kwargs", [])],
    )
end


"""
    _matlab_outputs(plan) -> Vector{String}

The façade's output names: each argument the function writes to, in
declaration order, then the results. A tuple return becomes one output per
element; anything else is a single output, and a `Nothing` return yields
zero.

A written argument comes back because MATLAB gives arguments value semantics,
so `a = f(a)` is how a caller sees the write.
"""
function _matlab_outputs(plan)
    names = String[vcat(plan.positional, plan.keywords)[i] for i in plan.mutates]
    append!(names, _matlab_result_outputs(plan.ret))
    return names
end

"""
    _matlab_result_outputs(ret) -> Vector{String}

The output names for what the entry point returns, without the arguments it
writes to.
"""
function _matlab_result_outputs(ret)
    inner = ret.kind === :result ? ret.inner : ret
    inner.kind in (:void, :none) && return String[]
    inner.kind === :tuple && return String["out" * string(i) for i in 1:length(inner.elements)]
    return String["out"]
end

"""
    _write_matlab_facade(io, dest, method, plan)

Write one `.m` façade: an `arguments` block, the body conversions the block
cannot express, and the gateway call.
"""
function _write_matlab_facade(io::IO, dest::MatlabTarget, method::MethodDesc, plan)
    outputs = _matlab_outputs(plan)
    signature = if isempty(outputs)
        plan.name
    elseif length(outputs) == 1
        only(outputs) * " = " * plan.name
    else
        "[" * join(outputs, ", ") * "] = " * plan.name
    end
    names = vcat(plan.positional, plan.keywords)
    # Keywords arrive as one name-value struct, MATLAB's form for them.
    parameters = isempty(plan.keywords) ? plan.positional : vcat(plan.positional, "opts")
    println(io, "function ", signature, "(", join(parameters, ", "), ")")

    written = String[vcat(plan.positional, plan.keywords)[i] for i in plan.mutates]
    # `help` reads the first comment line as the summary, so it is written
    # even when the sidecar records no docstring: a bare `%` leaves it empty.
    if !isempty(plan.doc) || !isempty(written)
        lines = isempty(plan.doc) ? [""] : split(plan.doc, '\n')
        for (i, line) in pairs(lines)
            prefix = i == 1 ? "%" * uppercase(plan.name) * "  " : "%   "
            println(io, rstrip(prefix * line))
        end
    end
    if !isempty(written)
        println(io, "%")
        println(
            io, "%   Writes to ", join(uppercase.(written), ", "),
            " and returns ", length(written) == 1 ? "it" : "them", "."
        )
    end

    # Emit the `arguments` block only when it declares something.
    if !isempty(names)
        println(io, "    arguments")
        for (i, name) in pairs(plan.positional)
            # An enum takes a member name or the underlying integer, which no
            # single class declaration covers; the body sorts it out.
            validation = isnothing(plan.enums[i]) ?
                " " * _matlab_arg_validation(plan.args[i], name) : ""
            println(io, "        ", name, validation)
        end
        for (j, name) in pairs(plan.keywords)
            i = length(plan.positional) + j
            default = plan.defaults[j]
            validation = isnothing(plan.enums[i]) ?
                " " * _matlab_arg_validation(plan.args[i], name) : ""
            suffix = isnothing(default) ? "" :
                " = " * _matlab_literal(something(default))
            println(io, "        opts.", name, validation, suffix)
        end

        println(io, "    end")
    end

    forwarded = String[]
    for (i, name) in pairs(names)
        kind = plan.args[i]
        expression = i <= length(plan.positional) ? name : "opts." * name
        if !isnothing(plan.enums[i])
            local_name = name * "_"
            _write_matlab_enum_in(
                io, dest, plan, local_name, expression, name,
                plan.api_enums[plan.enums[i]], kind
            )
            push!(forwarded, local_name)
            continue
        end
        if kind.kind === :opt
            # `[]` is the absent form and a scalar the present one; the check
            # below rejects the rest.
            println(
                io, "    if ~isempty(", expression, ") && ~isscalar(", expression, ")"
            )
            println(
                io, "        error(\"", dest.package_name, ":", plan.name,
                "\", \"", name, " must be a scalar or [].\");"
            )
            println(io, "    end")
        elseif kind.kind === :array && kind.ndim > 1
            println(io, "    if ndims(", expression, ") > ", kind.ndim)
            println(
                io, "        error(\"", dest.package_name, ":", plan.name,
                "\", \"", name, " must have at most ", kind.ndim, " dimensions.\");"
            )
            println(io, "    end")
        end
        push!(forwarded, _matlab_arg_forward(expression, kind, i in plan.mutates))
    end

    # The dispatch name is passed as `char`: the gateway reads it with
    # `mxArrayToUTF8String`, the form the C API reads.
    call = _matlab_gateway_name(dest) * "('" * method.symbol * "'"
    isempty(forwarded) || (call *= ", " * join(forwarded, ", "))
    call *= ")"
    if isempty(outputs)
        println(io, "    ", call, ";")
    elseif length(outputs) == 1
        println(io, "    ", only(outputs), " = ", call, ";")
    else
        println(io, "    [", join(outputs, ", "), "] = ", call, ";")
    end
    results = _matlab_result_outputs(plan.ret)
    if !isnothing(plan.return_enum) && length(results) == 1
        _write_matlab_enum_out(io, only(results), plan.api_enums[plan.return_enum])
    end
    println(io, "end")
    return nothing
end

"""
    write_wrapper(dest::MatlabTarget, abi_info; api_metadata, api_enums)

Emit the MATLAB package described by `dest`/`abi_info`. `api_metadata` is the
sidecar's `exports` table (see [`read_api_metadata`](@ref)), keyed by C symbol;
a symbol present there supplies the façade's public name, argument names,
keyword defaults and documentation. A symbol absent from it — a hand-written
`Base.@ccallable` — falls back to the ABI's own names.

The façades land in `+<package_name>/`, so they are called as
`<package_name>.f(x)`. An entry point gets a file only when the emitter maps
its arguments and return.
"""
function write_wrapper(
        dest::MatlabTarget, abi_info::ABIInfo;
        api_metadata::AbstractDict = Dict{String, Any}(),
        api_enums::AbstractDict = Dict{String, Any}()
    )
    (; entrypoints, typeinfo) = abi_info
    release_present = _release_symbols_present(abi_info)

    package_dir = joinpath(dest.dir, "+" * dest.package_name)
    mkpath(joinpath(package_dir, "private"))

    written = String[]
    wrapped = Tuple{MethodDesc, Any}[]
    taken = Dict{String, String}()
    for method in sort(entrypoints; by = m -> m.symbol)
        # The release entry points serve the gateway, and the façades omit
        # them.
        method.symbol in ("jlw_free", "jlw_free_strings") && continue
        plan = _matlab_facade_plan(
            method, typeinfo, release_present,
            get(api_metadata, method.symbol, nothing), api_enums
        )
        plan.kind === :auto || continue
        # Two symbols can sanitize to one name. The second would overwrite
        # the first's file, leaving one of them callable.
        if haskey(taken, plan.name)
            error(
                "MATLAB façade name \"" * plan.name * "\" is claimed by both " *
                    taken[plan.name] * " and " * method.symbol
            )
        end
        taken[plan.name] = method.symbol
        open(joinpath(package_dir, plan.name * ".m"), "w") do io
            _write_matlab_facade(io, dest, method, plan)
        end
        push!(written, plan.name)
        push!(wrapped, (method, plan))
        # A caller who does not assign the result loses the write, so this is
        # worth saying once per declaration rather than leaving it to the
        # façade's help text.
        isempty(plan.mutates) || @warn(
            "MATLAB has no way to write through an argument, so " *
                "$(dest.package_name).$(plan.name) copies " *
                join(
                [vcat(plan.positional, plan.keywords)[i] for i in plan.mutates],
                ", "
            ) *
                " and returns the copy. Call it as " *
                "`[$(join(_matlab_outputs(plan), ", "))] = " *
                "$(dest.package_name).$(plan.name)(...)`."
        )
    end

    # The gateway needs the carrier typedefs. Emitting them here, instead of
    # requiring a `CTarget` in the same build, keeps this target usable on its
    # own. The C emitter is a pure function of the ABI, so a `CTarget` writing
    # the same file produces the same bytes.
    write_wrapper(CTarget(dest.dir, _matlab_types_header(dest)), abi_info)

    gateway = _matlab_gateway_name(dest)
    open(joinpath(dest.dir, gateway * ".c"), "w") do io
        _write_matlab_gateway(io, dest, abi_info, wrapped, _matlab_types_header(dest) * ".h")
    end
    open(joinpath(dest.dir, "build_mex.m"), "w") do io
        _write_matlab_build_script(io, dest, gateway)
    end
    return written
end

"""
    _write_matlab_build_script(io, dest, gateway)

Write the script that compiles the gateway. It is run by the user, in MATLAB;
emitting it needs no MATLAB.

The library is opened at run time rather than linked, so this passes no
`-l` flag for it. The compiled MEX file lands in the package's `private/`
directory, where only the façades can call it.
"""
function _write_matlab_build_script(io::IO, dest::MatlabTarget, gateway::AbstractString)
    environment = uppercase(sanitize_for_c(dest.library_basename)) * "_MEX_LIBRARY"
    default = if isempty(dest.library_subdir)
        "library_dir = here;"
    else
        parts = join(["'" * p * "'" for p in splitpath(dest.library_subdir)], ", ")
        "library_dir = fullfile(here, $parts);"
    end
    print(
        io, """
        function build_mex(library_dir)
        %BUILD_MEX  Compile the $(dest.package_name) gateway.
        %   BUILD_MEX() expects the shared library in this directory.
        %   BUILD_MEX(DIR) takes it from DIR instead. The path is compiled
        %   in; set $environment to override it at run time.
            here = fileparts(mfilename('fullpath'));
            if nargin < 1
                $default
            end
            target = fullfile(here, '+$(dest.package_name)', 'private');
            if ~isfolder(target)
                mkdir(target);
            end
            % The library stays where it was built, next to the runtime its
            % RUNPATH points at, so the path is compiled in instead of
            % copying the library beside the MEX file.
            stem = fullfile(library_dir, '$(dest.library_basename)');
            % -R2018a selects the typed accessors the gateway uses.
            mex('-R2018a', ...
                '-outdir', target, ...
                ['-I' here], ...
                ['-DJLW_LIBRARY_PATH="' stem '"'], ...
                fullfile(here, '$gateway.c'));
        end
        """
    )
    return nothing
end

"""
    _write_matlab_enum_in(io, dest, plan, local_name, expression, name, edesc, kind)

Translate an enum argument into its underlying integer. A caller may pass the
member name or the integer itself, so neither an `arguments`-block class nor a
plain cast covers it.
"""
function _write_matlab_enum_in(
        io::IO, dest::MatlabTarget, plan, local_name::AbstractString,
        expression::AbstractString, name::AbstractString, edesc, kind
    )
    println(io, "    switch string(", expression, ")")
    for member in edesc["members"]
        println(
            io, "        case \"", member["name"], "\"; ", local_name, " = ",
            kind.class, "(", member["value"], ");"
        )
    end
    println(io, "        otherwise")
    println(
        io, "            if isnumeric(", expression, ") && isscalar(", expression, ")"
    )
    println(io, "                ", local_name, " = ", kind.class, "(", expression, ");")
    println(io, "            else")
    names = join(["\"" * String(m["name"]) * "\"" for m in edesc["members"]], ", ")
    println(
        io, "                error(\"", dest.package_name, ":", plan.name,
        "\", \"", name, " must be one of ", replace(names, "\"" => "'"),
        ", or the underlying integer.\");"
    )
    println(io, "            end")
    println(io, "    end")
    return nothing
end

"""
    _write_matlab_enum_out(io, output, edesc)

Turn an enum return's integer back into its member name, which is the form the
façades accept, so a returned value can be passed straight back in.
"""
function _write_matlab_enum_out(io::IO, output::AbstractString, edesc)
    println(io, "    switch ", output)
    for member in edesc["members"]
        println(
            io, "        case ", member["value"], "; ", output, " = \"",
            member["name"], "\";"
        )
    end
    # A value outside the enum means the library and these bindings disagree.
    # Say so rather than hand back the integer.
    println(io, "        otherwise")
    println(
        io, "            error(\"jlw:error\", \"", output,
        " is not a known enum value: %d\", ", output, ");"
    )
    println(io, "    end")
    return nothing
end

"""
    MATLAB_ERROR_IDENTIFIERS :: Dict{Int, String}

The MATLAB error identifier each `JLWStatus.code` becomes, so a caller gets
`ME.identifier` dispatch on the shared status codes. A code outside this
table falls back to `jlw:error`.
"""
const MATLAB_ERROR_IDENTIFIERS = Dict{Int, String}(
    1 => "jlw:error", 2 => "jlw:argument", 3 => "jlw:dimension",
    4 => "jlw:inexact", 5 => "jlw:bounds",
)

"""
    _write_matlab_gateway_prologue(io, dest, header)

Write the gateway's includes, its library loader and its status check.

The library is opened here rather than linked, and never closed. Nothing
releases that reference, so `clear mex` unloading the MEX file leaves the
library mapped and the next load finds it rather than running `jl_init` a
second time; `RTLD_NODELETE` guards the same invariant against anything else
closing it. Opening it locally keeps its names out of the global namespace,
which is where a second wrapped library would otherwise meet them.
"""
function _write_matlab_gateway_prologue(
        io::IO, dest::MatlabTarget, header::AbstractString,
        message_bytes::Union{Int, Nothing}
    )
    environment = uppercase(sanitize_for_c(dest.library_basename)) * "_MEX_LIBRARY"
    print(
        io, """
        /* Auto-generated by JuliaLibWrapping. Do not edit by hand. */
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <dlfcn.h>
        #include <fcntl.h>
        #include "mex.h"
        #include "$header"

        /* Where the shared library is. `build_mex.m` bakes in the path it
           was built against; the environment variable overrides it. A bare
           name resolves against MATLAB's working directory, not the MEX
           file's location. */
        #ifndef JLW_LIBRARY_PATH
        #define JLW_LIBRARY_PATH "$(dest.library_basename)"
        #endif
        #define JLW_LIBRARY_ENV "$environment"

        static void *jlw_library = NULL;

        /* Julia's runtime marks inherited pipes non-blocking and leaves
           them that way, which MATLAB's own reads then see as errors.
           It bites when MATLAB runs under -batch in a pipeline. */
        typedef struct { int flags[3]; } jlw_stdio_flags;

        static jlw_stdio_flags jlw_save_stdio(void)
        {
            jlw_stdio_flags saved;
            for (int fd = 0; fd < 3; fd++) {
                saved.flags[fd] = fcntl(fd, F_GETFL);
            }
            return saved;
        }

        static void jlw_restore_stdio(jlw_stdio_flags saved)
        {
            for (int fd = 0; fd < 3; fd++) {
                if (saved.flags[fd] != -1) {
                    fcntl(fd, F_SETFL, saved.flags[fd]);
                }
            }
        }

        /* Opened once and never closed: `clear mex` unloads this file, and
           reloading the library would run `jl_init` twice in one process. */
        static void *jlw_symbol(const char *name)
        {
            if (jlw_library == NULL) {
                const char *override = getenv(JLW_LIBRARY_ENV);
                jlw_stdio_flags saved = jlw_save_stdio();
                char path[4096];
                const char *base = override ? override : JLW_LIBRARY_PATH;
                char reason[256];
        #ifdef __APPLE__
                snprintf(path, sizeof path, "%s.dylib", base);
        #else
                snprintf(path, sizeof path, "%s.so", base);
        #endif
                /* Local: every entry point is reached through this handle, and
           the runtime finds its own image from the address of the
           caller, so nothing here needs the global scope. Loading it
           globally would publish this library's unversioned names --
           the entry points, `jlw_free`, the image symbols -- where a
           second wrapped library would find them. */
        jlw_library = dlopen(path, RTLD_LAZY | RTLD_NODELETE);
                const char *message = dlerror();
                snprintf(reason, sizeof reason, "%s", message ? message : "");
                if (jlw_library == NULL) {
                    mexErrMsgIdAndTxt("jlw:library",
                        "could not load %s (%s); set " JLW_LIBRARY_ENV
                        " to its path without the extension", path, reason);
                }
                jlw_restore_stdio(saved);
            }
            void *address = dlsym(jlw_library, name);
            if (address == NULL) {
                mexErrMsgIdAndTxt("jlw:library", "missing entry point %s", name);
            }
            return address;
        }

        """
    )
    # The status check is emitted only when the library reports a status.
    isnothing(message_bytes) && return nothing
    cases = join(
        [
            "        case $code: identifier = \"$(MATLAB_ERROR_IDENTIFIERS[code])\"; break;"
                for code in sort(collect(keys(MATLAB_ERROR_IDENTIFIERS)))
        ], "\n"
    )
    print(
        io, """
        /* Raises, so every caller must release what it holds before calling:
           `mexErrMsgIdAndTxt` leaves by `longjmp`, which runs no cleanup. */
        static void jlw_check(JLWStatus status)
        {
            if (status.code == 0) {
                return;
            }
            char message[$message_bytes + 1];
            memcpy(message, status.message, $message_bytes);
            message[$message_bytes] = '\\0';
            const char *identifier;
            switch (status.code) {
        """
    )
    println(io, cases)
    print(
        io, """
                default: identifier = "jlw:error"; break;
            }
            mexErrMsgIdAndTxt(identifier, "%s", message);
        }
        """
    )
    return nothing
end

"""
    _matlab_status_message_bytes(typeinfo) -> Union{Int, Nothing}

The size of `JLWStatus.message`, read from the ABI rather than assumed, or
`nothing` when the library declares no `JLWStatus`. A library of
hand-written entry points may skip the status channel; then the gateway has
no errors to translate.
"""
function _matlab_status_message_bytes(typeinfo::OrderedDict{Int, TypeDesc})
    for desc in values(typeinfo)
        desc isa StructDesc || continue
        is_jlwstatus_struct(desc, typeinfo) || continue
        field = only(f for f in desc.fields if f.name == "message")
        return (typeinfo[field.type]::ArrayDesc).count
    end
    return nothing
end

"""
    _matlab_raise_if(condition, id, message) -> String

One guard in a handler: raise `message` under `id` when `condition` holds.
"""
function _matlab_raise_if(
        condition::AbstractString, id::AbstractString, message::AbstractString
    )
    return """
        if ($condition) {
            mexErrMsgIdAndTxt("$id", "$message");
        }
    """
end

"""
    _matlab_check(plan, symbol) -> String

The validation phase of one handler: everything that can raise, before
anything is acquired. `mexErrMsgIdAndTxt` leaves by `longjmp`, which runs no
cleanup, so a check that raises while a carrier is live would leak it. Class,
shape, and sparsity checks hold no carrier, so they all run first. `nlhs` is
known before the call, so the output count is checked here too.
"""
function _matlab_check(plan, symbol::AbstractString)
    parts = String[]
    total = length(plan.mutates) + length(_matlab_result_outputs(plan.ret))
    if total > 1
        push!(
            parts, """
                int wanted = nlhs < 1 ? 1 : nlhs;
            """
        )
        push!(parts, _matlab_raise_if("wanted > $total", "jlw:argument", "at most $total outputs"))
    end
    push!(
        parts, _matlab_raise_if(
            "nrhs != $(length(plan.args) + 1)", "jlw:argument",
            "$symbol takes $(length(plan.args)) arguments"
        )
    )
    for (i, kind) in pairs(plan.args)
        argument = "prhs[$i]"
        name = i <= length(plan.positional) ? plan.positional[i] :
            plan.keywords[i - length(plan.positional)]
        class = uppercasefirst(get(kind, :class, ""))
        if kind.kind in (:array, :scalar, :opt, :dict)
            # A sparse mxArray passes a class check but stores (i, j, v)
            # triples, so borrowing it as a dense buffer would read the wrong
            # memory.
            push!(
                parts, _matlab_raise_if(
                    "mxIsSparse($argument)", "jlw:argument", "$name must not be sparse"
                )
            )
        end
        if kind.kind === :scalar
            push!(
                parts, _matlab_raise_if(
                    "!mxIs$class($argument) || mxGetNumberOfElements($argument) != 1",
                    "jlw:argument", "$name must be a $(kind.class) scalar"
                )
            )
        elseif kind.kind === :array
            push!(
                parts, _matlab_raise_if(
                    "!mxIs$class($argument)", "jlw:argument", "$name must be $(kind.class)"
                )
            )
            push!(
                parts, _matlab_raise_if(
                    "mxGetNumberOfDimensions($argument) > $(max(kind.ndim, 2))",
                    "jlw:dimension", "$name has too many dimensions"
                )
            )
        elseif kind.kind === :string
            push!(
                parts, _matlab_raise_if(
                    "!mxIsChar($argument)", "jlw:argument", "$name must be char"
                )
            )
        elseif kind.kind === :strarray
            push!(
                parts, _matlab_raise_if(
                    "!mxIsCell($argument)", "jlw:argument",
                    "$name must be a cell array of char"
                )
            )
        elseif kind.kind === :dict
            push!(
                parts, _matlab_raise_if(
                    "!mxIsStruct($argument)", "jlw:argument", "$name must be a struct"
                )
            )
        elseif kind.kind === :opt
            push!(
                parts, _matlab_raise_if(
                    "!mxIsEmpty($argument) && mxGetNumberOfElements($argument) != 1",
                    "jlw:argument", "$name must be a scalar or []"
                )
            )
        end
    end
    return join(parts)
end

"""
    _matlab_accessor(class) -> String

The `-R2018a` typed data accessor for a MATLAB class. These return a pointer to
the mxArray's own buffer, which is what lets an array argument be borrowed
rather than copied.
"""
_matlab_accessor(class::AbstractString) = "mxGet" *
    (class == "logical" ? "Logicals" : uppercasefirst(class) * "s")

"""
    _matlab_class_id(class) -> String

The `mxClassID` naming a MATLAB class, for `mxCreateNumericArray`.
"""
_matlab_class_id(class::AbstractString) = "mx" * uppercase(class) * "_CLASS"

"""
    _matlab_create_array(class, rank, shape) -> String
    _matlab_create_scalar(class, rows, cols) -> String

The `mxCreate…` call for a class. `logical` has its own creators:
`mxCreateNumericArray` takes a numeric `mxClassID`, and `mxLOGICAL_CLASS` is
not one of them.
"""
_matlab_create_array(class::AbstractString, rank, shape::AbstractString) =
    class == "logical" ? "mxCreateLogicalArray(" * string(rank) * ", " * shape * ")" :
    "mxCreateNumericArray(" * string(rank) * ", " * shape * ", " *
    _matlab_class_id(class) * ", mxREAL)"

_matlab_create_scalar(class::AbstractString, rows, cols) =
    class == "logical" ?
    "mxCreateLogicalMatrix(" * string(rows) * ", " * string(cols) * ")" :
    "mxCreateNumericMatrix(" * string(rows) * ", " * string(cols) * ", " *
    _matlab_class_id(class) * ", mxREAL)"

"""
    _matlab_ctype(class) -> String

The C type behind a MATLAB class, as the generated header spells it.
"""
function _matlab_ctype(class::AbstractString)
    class == "double" && return "double"
    class == "single" && return "float"
    # The header spells `Bool` as C's `bool`.
    class == "logical" && return "bool"
    return class * "_t"
end

"""
    _matlab_length_type(bits) -> String

The C type of a carrier's length or dimension field. The real carriers are
64-bit but some hand-written fixtures are 32-bit, so the width comes from
the recognizers, not an assumption.
"""
_matlab_length_type(bits::Integer) = "int" * string(bits) * "_t"

"""
    _matlab_length_guard(indent, expression, bits, what) -> String

Guard a count that has to fit a 32-bit field: `mwSize` is unsigned and
64-bit, so a larger value would truncate to a negative number in Julia.
Nothing is held at these sites, so raising is safe. A 64-bit field needs no
guard, and the fragment is then empty.
"""
function _matlab_length_guard(
        indent::AbstractString, expression::AbstractString,
        bits::Integer, what::AbstractString
    )
    bits >= 64 && return ""
    return """
    $(indent)if ($expression > INT32_MAX) {
    $(indent)    mexErrMsgIdAndTxt("jlw:dimension", "$what exceeds this library's 32-bit length field");
    $(indent)}
    """
end

"""
    _matlab_in_body(name, kind) -> String

The body of the helper that converts an `mxArray` into carrier `name`, or
`nothing` for a kind that has no conversion.
"""
function _matlab_in_body(name::AbstractString, kind)
    if kind.kind === :array
        length_type = _matlab_length_type(kind.dims_bits)
        if kind.ndim == 1
            dims = _matlab_length_guard(
                "    ", "mxGetNumberOfElements(value)", kind.dims_bits,
                "the vector's length"
            )
            dims *= """
                carrier.dims[0] = ($length_type)mxGetNumberOfElements(value);
            """
        else
            dims = """
                const mwSize *shape = mxGetDimensions(value);
                mwSize rank = mxGetNumberOfDimensions(value);
                for (int i = 0; i < $(kind.ndim); i++) {
                    /* MATLAB drops trailing singletons, so a missing
                       dimension is 1 rather than an error. */
            """
            dims *= _matlab_length_guard(
                "        ", "(i < (int)rank ? shape[i] : 1)", kind.dims_bits, "a dimension"
            )
            dims *= """
                    carrier.dims[i] = ($length_type)(i < (int)rank ? shape[i] : 1);
                }
            """
        end
        tail = """
            carrier.data = ($(_matlab_ctype(kind.class)) *)$(_matlab_accessor(kind.class))(value);
            return carrier;
        """
        return "    $name carrier;\n" * dims * tail
    elseif kind.kind === :string
        head = """
            /* From `mxMalloc`, so it is reclaimed even if an error unwinds past here. */
            char *text = mxArrayToUTF8String(value);
            if (text == NULL) {
                mexErrMsgIdAndTxt("jlw:argument", "could not read char data");
            }
            size_t size = strlen(text);
        """
        guard = _matlab_length_guard("    ", "size", kind.length_bits, "the string")
        tail = """
            $name carrier;
            carrier.length = ($(_matlab_length_type(kind.length_bits)))size;
            carrier.data = (uint8_t *)text;
            return carrier;
        """
        return head * guard * tail
    elseif kind.kind === :strarray
        head = """
            mwSize count = mxGetNumberOfElements(value);
            CString_borrowed *items =
                (CString_borrowed *)mxMalloc((count ? count : 1) * sizeof(CString_borrowed));
            for (mwSize i = 0; i < count; i++) {
                const mxArray *cell = mxGetCell(value, i);
                if (cell == NULL || !mxIsChar(cell)) {
                    mexErrMsgIdAndTxt("jlw:argument", "every cell must be char");
                }
                char *text = mxArrayToUTF8String(cell);
                if (text == NULL) {
                    mexErrMsgIdAndTxt("jlw:argument", "could not read char data");
                }
                size_t size = strlen(text);
        """
        element_guard = _matlab_length_guard(
            "        ", "size", kind.element_bits, "a string"
        )
        middle = """
                items[i].length = ($(_matlab_length_type(kind.element_bits)))size;
                items[i].data = (uint8_t *)text;
            }
        """
        count_guard = _matlab_length_guard(
            "    ", "count", kind.length_bits, "the cell array"
        )
        tail = """
            $name carrier;
            carrier.length = ($(_matlab_length_type(kind.length_bits)))count;
            carrier.data = items;
            return carrier;
        """
        return head * element_guard * middle * count_guard * tail
    elseif kind.kind === :dict
        ctype = _matlab_ctype(kind.class)
        return """
            int count = mxGetNumberOfFields(value);
            CString_borrowed *keys =
                (CString_borrowed *)mxMalloc((count ? count : 1) * sizeof(CString_borrowed));
            $ctype *values =
                ($ctype *)mxMalloc((count ? count : 1) * sizeof($ctype));
            for (int i = 0; i < count; i++) {
                const char *key = mxGetFieldNameByNumber(value, i);
                keys[i].length = (int32_t)strlen(key);
                /* A MATLAB field name is at most `mxMAXNAM`, so it fits. */
                keys[i].data = (uint8_t *)key;
                const mxArray *field = mxGetFieldByNumber(value, 0, i);
                /* A sparse field passes a class check and has no
                   dense buffer to read. */
                if (field == NULL || mxIsSparse(field) ||
                    !mxIs$(uppercasefirst(kind.class))(field) ||
                    mxGetNumberOfElements(field) != 1) {
                    mexErrMsgIdAndTxt("jlw:argument",
                        "field %s must be a $(kind.class) scalar", key);
                }
                values[i] = *$(_matlab_accessor(kind.class))(field);
            }
            $name carrier;
            carrier.length = ($(_matlab_length_type(kind.length_bits)))count;
            carrier.keys = keys;
            carrier.values = values;
            return carrier;
        """
    elseif kind.kind === :opt
        ctype = _matlab_ctype(kind.class)
        return """
            $name carrier;
            if (mxIsEmpty(value)) {
                carrier.has_value = 0;
                carrier.value = ($ctype)0;
            } else {
                carrier.has_value = 1;
                carrier.value = ($ctype)mxGetScalar(value);
            }
            return carrier;
        """
    end
    return nothing
end

"""
    _write_matlab_in_helpers(io, carriers)

Write one conversion helper per borrowed carrier an argument uses.

Each takes an already-validated `mxArray` and returns a carrier over MATLAB's
storage. What they allocate comes from `mxMalloc`, which MATLAB reclaims when
`mexFunction` exits, so an unwind past them is safe.
"""
function _write_matlab_in_helpers(io::IO, carriers)
    for (name, kind) in carriers
        body = _matlab_in_body(name, kind)
        isnothing(body) && continue
        print(
            io, """

            static $name jlw_in_$name(const mxArray *value)
            {
            $(body)}
            """
        )
    end
    return nothing
end

"""
    _write_matlab_field_name_check(io)

Write the predicate for a legal MATLAB field name. A dictionary return checks
its keys, and so does a tuple holding one, so it is emitted once and called
from both.
"""
function _write_matlab_field_name_check(io::IO)
    print(
        io, """

        static int jlw_valid_field_name(const uint8_t *data, int32_t n)
        {
            if (n <= 0 || n >= mxMAXNAM) {
                return 0;
            }
            for (int32_t j = 0; j < n; j++) {
                uint8_t c = data[j];
                int alpha = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
                int rest = (c >= '0' && c <= '9') || c == '_';
                /* A field name starts with a letter. */
                if (!(j == 0 ? alpha : (alpha || rest))) {
                    return 0;
                }
            }
            return 1;
        }
        """
    )
    return nothing
end

"""
    _write_matlab_release(io)

Write cached wrappers for the library's deallocation entry points. They are
resolved once: a `dlsym` per release would cost a lookup on every returned
value.
"""
function _write_matlab_release(io::IO)
    # `void *`: the header declares the carrier typedef only when an entry
    # point uses it, so a carrier-free library still compiles.
    print(
        io, """

        static void jlw_release(void *pointer)
        {
            static void (*entry)(void *) = NULL;
            if (entry == NULL) {
                entry = (void (*)(void *))jlw_symbol("jlw_free");
            }
            entry(pointer);
        }

        static void jlw_release_strings(void *items, int64_t count)
        {
            static void (*entry)(void *, int64_t) = NULL;
            if (entry == NULL) {
                entry = (void (*)(void *, int64_t))jlw_symbol("jlw_free_strings");
            }
            entry(items, count);
        }
        """
    )
    return nothing
end

"""
    _matlab_out_body(kind) -> String

The body of the helper that turns carrier `kind` into an `mxArray`. It also
releases what Julia allocated, which is why every element of a tuple return is
converted even when the caller wants fewer outputs.
"""
function _matlab_out_body(kind)
    # One spelling of the release, from the same place the tuple unwind uses.
    release = join(
        "    $statement\n" for statement in _matlab_release_expression(kind, "carrier")
    )
    if kind.kind === :array
        rank = max(kind.ndim, 2)
        shape = """
            mwSize shape[$rank] = {$(join(fill("1", rank), ", "))};
        """
        shape *= join(
            "    shape[$(d - 1)] = (mwSize)carrier.dims[$(d - 1)];\n" for d in 1:kind.ndim
        )
        body = """
            mxArray *out = $(_matlab_create_array(kind.class, rank, "shape"));
            memcpy($(_matlab_accessor(kind.class))(out), carrier.data,
                   mxGetNumberOfElements(out) * sizeof($(_matlab_ctype(kind.class))));
        """
        return shape * body * release
    elseif kind.kind === :string
        head = """
            /* `mxCreateString` takes a C string, so an embedded NUL
               truncates; Julia permits them. */
            char *text = (char *)mxMalloc((size_t)carrier.length + 1);
            memcpy(text, carrier.data, (size_t)carrier.length);
            text[carrier.length] = '\\0';
        """
        tail = """
            mxArray *out = mxCreateString(text);
            mxFree(text);
        """
        return head * release * tail
    elseif kind.kind === :strarray
        body = """
            mxArray *out = mxCreateCellMatrix((mwSize)carrier.length, 1);
            for (int64_t i = 0; i < carrier.length; i++) {
                char *text = (char *)mxMalloc((size_t)carrier.data[i].length + 1);
                memcpy(text, carrier.data[i].data, (size_t)carrier.data[i].length);
                text[carrier.data[i].length] = '\\0';
                mxSetCell(out, (mwSize)i, mxCreateString(text));
                mxFree(text);
            }
        """
        return body * release
    elseif kind.kind === :dict
        head = """
            /* Keys are checked before anything is created, so a bad
               one is reported while nothing is held. */
            for (int64_t i = 0; i < carrier.length; i++) {
                if (!jlw_valid_field_name(carrier.keys[i].data, carrier.keys[i].length)) {
        """
        # Two levels deeper than the tail release: inside the loop and the `if`.
        head *= join(
            "            $statement\n"
                for statement in _matlab_release_expression(kind, "carrier")
        )
        body = """
                    mexErrMsgIdAndTxt("jlw:argument",
                        "a dictionary key is not a legal MATLAB field name");
                }
            }
            const char **names =
                (const char **)mxMalloc((size_t)(carrier.length ? carrier.length : 1) * sizeof(char *));
            for (int64_t i = 0; i < carrier.length; i++) {
                char *key = (char *)mxMalloc((size_t)carrier.keys[i].length + 1);
                memcpy(key, carrier.keys[i].data, (size_t)carrier.keys[i].length);
                key[carrier.keys[i].length] = '\\0';
                names[i] = key;
            }
            mxArray *out = mxCreateStructMatrix(1, 1, (int)carrier.length, names);
            for (int64_t i = 0; i < carrier.length; i++) {
                mxArray *field = $(_matlab_create_scalar(kind.class, 1, 1));
                *$(_matlab_accessor(kind.class))(field) = ($(_matlab_ctype(kind.class)))carrier.values[i];
                mxSetFieldByNumber(out, 0, (int)i, field);
            }
        """
        return head * body * release
    elseif kind.kind === :opt
        return """
            if (carrier.has_value == 0) {
                return $(_matlab_create_scalar(kind.class, 0, 0));
            }
            mxArray *out = $(_matlab_create_scalar(kind.class, 1, 1));
            *$(_matlab_accessor(kind.class))(out) = carrier.value;
        """
    elseif kind.kind === :scalar
        return """
            mxArray *out = $(_matlab_create_scalar(kind.class, 1, 1));
            *$(_matlab_accessor(kind.class))(out) = carrier;
        """
    end
    return ""
end

"""
    _write_matlab_out_helpers(io, carriers)

Write one conversion helper per distinct return carrier, each copying Julia's
storage into a fresh `mxArray` and releasing the original.

A helper that can raise between acquiring and releasing frees first:
`mexErrMsgIdAndTxt` leaves by `longjmp`, which runs no cleanup, so every exit
path releases explicitly.
"""
function _write_matlab_out_helpers(io::IO, carriers)
    for (name, kind) in carriers
        print(
            io, """

            static mxArray *jlw_out_$name($name carrier)
            {
            $(_matlab_out_body(kind))    return out;
            }
            """
        )
    end
    return nothing
end

"""
    _matlab_element_access(fields, i) -> String

How the gateway reaches element `i` of a `CNTuple`'s inner tuple. juliac emits
that tuple as a struct whose fields are the positions when the element types
differ, and as an inline array when they are all one type.
"""
_matlab_element_access(fields, i::Int) =
    isnothing(fields) ? "[" * string(i - 1) * "]" : "." * sanitize_for_c(fields[i])

"""
    _write_matlab_handler(io, plan, symbol, names)

Write one entry point's handler: validate, borrow the arguments, call, check
the status, then convert and assign the results.
"""
function _write_matlab_handler(io::IO, plan, symbol::AbstractString, names)
    # Handlers share one signature, so a void or single-output one leaves
    # parameters unused; a MEX build with warnings on would say so.
    copies = String["copy$i" for i in plan.mutates]
    total = length(copies) + length(_matlab_result_outputs(plan.ret))
    unused = String[]
    total > 1 || push!(unused, "    (void)nlhs;\n")
    total == 0 && push!(unused, "    (void)plhs;\n")
    isempty(plan.args) && push!(unused, "    (void)prhs;\n")

    conversions = map(eachindex(plan.args)) do i
        kind = plan.args[i]
        source = "prhs[$i]"
        if i in plan.mutates
            # The wrapped function writes here, and MATLAB's own buffer may
            # be shared with variables the caller never passed. The copy is
            # what comes back.
            source = "copy$i"
            text = "    mxArray *copy$i = mxDuplicateArray(prhs[$i]);\n"
            return text * "    $(names.args[i]) arg$i = jlw_in_$(names.args[i])($source);\n"
        end
        kind.kind === :scalar || return "    $(names.args[i]) arg$i = jlw_in_$(names.args[i])($source);\n"
        ctype = _matlab_ctype(kind.class)
        return "    $ctype arg$i = ($ctype)mxGetScalar($source);\n"
    end

    signature = isempty(plan.args) ? "void" :
        join(
            [
                plan.args[i].kind === :scalar ? _matlab_ctype(plan.args[i].class) : names.args[i]
                for i in eachindex(plan.args)
            ], ", "
        )
    arguments = join(["arg" * string(i) for i in eachindex(plan.args)], ", ")
    call = "((" * names.result * " (*)(" * signature * "))jlw_symbol(\"" *
        symbol * "\"))(" * arguments * ");"

    ret = plan.ret
    if ret.kind === :none
        # Nothing is returned, so there is nothing to name or check.
        tail = "    $call\n" * _matlab_assign("", copies)
    else
        # On a failure the value is zero-filled, so the check raises while
        # holding nothing; that is what lets it run before any conversion.
        results = if ret.kind === :result
            "    jlw_check(result.status);\n" *
                _matlab_results(ret.inner, "result.value", names, copies)
        elseif ret.kind === :void
            "    jlw_check(result);\n" * _matlab_assign("", copies)
        else
            _matlab_results(ret, "result", names, copies)
        end
        tail = """
                $(names.result) result =
                    $call
            """ * results
    end

    print(
        io, """

        static void jlw_call_$symbol
            (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
        {
        $(join(unused))$(_matlab_check(plan, symbol))$(join(conversions))$(tail)}
        """
    )
    return nothing
end
"""
    _matlab_results(ret, expression, names) -> String

Assign an entry point's results into `plhs`.

A caller may request fewer outputs than a declaration produces; every element
is converted regardless, because conversion is what releases Julia's storage
for it. An unrequested element's `mxArray` is destroyed instead of assigned.
"""
function _matlab_results(ret, expression::AbstractString, names, copies::Vector{String})
    values = copy(copies)
    ret.kind in (:void, :none) && return _matlab_assign("", values)
    if ret.kind !== :tuple
        # One output and nothing else to place: assign it where it is made.
        isempty(values) &&
            return "    plhs[0] = jlw_out_$(names.value)($expression);\n"
        push!(values, "out1")
        return _matlab_assign(
            "    mxArray *out1 = jlw_out_$(names.value)($expression);\n", values
        )
    end
    accesses = [
        expression * ".values" * _matlab_element_access(ret.fields, i)
            for i in eachindex(ret.elements)
    ]
    text = _matlab_tuple_precheck(ret, accesses)
    text *= join(
        "    mxArray *out$i = jlw_out_$(names.elements[i])($(accesses[i]));\n"
            for i in eachindex(ret.elements)
    )
    append!(values, "out$i" for i in eachindex(ret.elements))
    return _matlab_assign(text, values)
end

"""
    _matlab_assign(text, values) -> String

Put each output in `plhs`, after `text` has made it. One output goes straight
there. Two or more are placed only as far as the caller asked, and the rest
destroyed, since an `mxArray` nobody takes is the gateway's to release.
"""
function _matlab_assign(text::AbstractString, values::Vector{String})
    isempty(values) && return String(text)
    length(values) == 1 && return text * "    plhs[0] = $(only(values));\n"
    for (k, value) in pairs(values)
        text *= """
            if (wanted >= $k) {
                plhs[$(k - 1)] = $value;
            } else {
                mxDestroyArray($value);
            }
        """
    end
    return String(text)
end

"""
    _matlab_carrier_names(method, typedict, typeinfo) -> NamedTuple

The C type names the gateway needs for one entry point: the argument carriers,
the entry point's own return type, the payload under a `JLWResult`, and a
tuple payload's elements. They come from [`mangle_c!`](@ref), so they are the
same spellings the emitted header declares.
"""
function _matlab_carrier_names(
        method::MethodDesc, typedict::Dict{Int, String},
        typeinfo::OrderedDict{Int, TypeDesc}
    )
    args = String[mangle_c!(typedict, a.type, typeinfo) for a in method.args]
    result = mangle_c!(typedict, method.return_type, typeinfo)

    value_id = method.return_type
    if !isnothing(value_id)
        desc = typeinfo[value_id]
        if desc isa StructDesc
            wrapper = jlwresult_struct_info(desc, typeinfo)
            isnothing(wrapper) || (value_id = wrapper.value_type_id)
        end
    end
    value = isnothing(value_id) ? "void" : mangle_c!(typedict, value_id, typeinfo)

    elements = String[]
    if !isnothing(value_id)
        desc = typeinfo[value_id]
        if desc isa StructDesc
            info = ctuple_struct_info(desc, typeinfo)
            isnothing(info) ||
                (elements = String[mangle_c!(typedict, id, typeinfo) for id in info.element_type_ids])
        end
    end
    return (; args, result, value, elements)
end

"""
    _write_matlab_gateway(io, dest, abi_info, plans, header)

Write the whole gateway: prologue, the conversion helpers each carrier needs,
one handler per entry point, and the `mexFunction` that dispatches by name.
"""
function _write_matlab_gateway(io::IO, dest::MatlabTarget, abi_info::ABIInfo, plans, header)
    (; typeinfo) = abi_info
    typedict = Dict{Int, String}()
    named = [(method, plan, _matlab_carrier_names(method, typedict, typeinfo)) for (method, plan) in plans]

    _write_matlab_gateway_prologue(io, dest, header, _matlab_status_message_bytes(typeinfo))
    _write_matlab_field_name_check(io)
    _write_matlab_release(io)

    # One helper per distinct carrier: its memory discipline lives in a single
    # place.
    incoming = OrderedDict{String, Any}()
    outgoing = OrderedDict{String, Any}()
    for (_, plan, names) in named
        for (i, kind) in pairs(plan.args)
            kind.kind === :scalar || (incoming[names.args[i]] = kind)
        end
        ret = plan.ret.kind === :result ? plan.ret.inner : plan.ret
        if ret.kind === :tuple
            for (i, element) in pairs(ret.elements)
                outgoing[names.elements[i]] = element
            end
        elseif ret.kind ∉ (:void, :none)
            outgoing[names.value] = ret
        end
    end
    _write_matlab_in_helpers(io, incoming)
    _write_matlab_out_helpers(io, outgoing)

    for (method, plan, names) in named
        _write_matlab_handler(io, plan, method.symbol, names)
    end

    dispatch = ""
    if isempty(named)
        dispatch = """
            (void)nlhs;
            (void)plhs;
            mexErrMsgIdAndTxt("jlw:argument", "no wrapped functions");
        """
    else
        # Read the dispatch name only when a function is wrapped; an empty
        # gateway would carry an unused variable.
        dispatch = "    char *name = mxArrayToUTF8String(prhs[0]);\n"
        for (i, (method, _, _)) in pairs(named)
            keyword = i == 1 ? "    if" : "    } else if"
            dispatch *= "$keyword (strcmp(name, \"$(method.symbol)\") == 0) {\n"
            dispatch *= "        jlw_call_$(method.symbol)(nlhs, plhs, nrhs, prhs);\n"
        end
        dispatch *= """
            } else {
                mexErrMsgIdAndTxt("jlw:argument", "unknown function %s", name);
            }
        """
    end
    print(
        io, """

        void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
        {
            if (nrhs < 1 || !mxIsChar(prhs[0])) {
                mexErrMsgIdAndTxt("jlw:argument", "the first argument names the function");
            }
        $(dispatch)}
        """
    )
    return nothing
end

"""
    _matlab_release_expression(kind, access) -> Vector{String}

The statements that release a carrier's storage without converting it. The out
helpers release this way once they have copied, and a tuple whose elements are
produced but not yet converted unwinds this way.
"""
function _matlab_release_expression(kind, access::AbstractString)
    kind.owns || return String[]
    kind.kind === :strarray &&
        return ["jlw_release_strings(" * access * ".data, " * access * ".length);"]
    kind.kind === :dict && return [
        "jlw_release_strings(" * access * ".keys, " * access * ".length);",
        "jlw_release(" * access * ".values);",
    ]
    return ["jlw_release(" * access * ".data);"]
end

"""
    _matlab_tuple_precheck(ret, accesses) -> String

Validate every dictionary element's field names before any element of a tuple
is converted.

Conversion is also what releases an element, so a raise part-way would strand
the unconverted ones. Dictionary keys are runtime data from Julia, so this is
an ordinary path, not an edge case. Checking first means a raise happens
while the whole tuple is still intact and can be released.
"""
function _matlab_tuple_precheck(ret, accesses)
    # Releasing every element, including the one being checked, since none has
    # been converted yet.
    unwind = join(
        "            $statement\n"
            for (element, access) in zip(ret.elements, accesses)
            for statement in _matlab_release_expression(element, access)
    )
    text = ""
    for (element, access) in zip(ret.elements, accesses)
        element.kind === :dict || continue
        text *= """
            for (int64_t k = 0; k < $access.length; k++) {
                if (!jlw_valid_field_name($access.keys[k].data, $access.keys[k].length)) {
        """
        text *= unwind
        text *= """
                    mexErrMsgIdAndTxt("jlw:argument",
                        "a dictionary key is not a legal MATLAB field name");
                }
            }
        """
    end
    return text
end
