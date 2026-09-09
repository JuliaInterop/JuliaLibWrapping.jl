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
    # `int64([])` is an empty `int64`, so the absent form survives.
    kind.kind === :opt && kind.integer && return kind.class * "(" * name * ")"
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
                io, "        error(\"jlw:argument\", \"",
                name, " must be a scalar or [].\");"
            )
            println(io, "    end")
        elseif kind.kind === :array && kind.ndim > 1
            println(io, "    if ndims(", expression, ") > ", kind.ndim)
            println(
                io, "        error(\"jlw:dimension\", \"",
                name, " must have at most ", kind.ndim, " dimensions.\");"
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
        if plan.kind !== :auto
            # Python re-exports what it cannot wrap; there is no such form
            # here, so the entry point is simply absent from the package.
            @warn "no MATLAB façade for $(method.symbol): $(plan.reason)"
            continue
        end
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
            % The library is not copied next to the MEX file: it has to stay
            % beside the runtime its RUNPATH names. So its path is compiled
            % in, and a MEX file built here expects to find it here. Set
            % $environment to point a built one somewhere else.
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
        io, "                error(\"jlw:argument\", \"",
        name, " must be one of ", replace(names, "\"" => "'"),
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
