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

`duplicate_arguments` copies each array argument for the call. Use it when the
wrapped library writes to its arguments. By default the gateway hands Julia a
pointer into MATLAB's own buffer, and a write there changes every variable
sharing it, because MATLAB copies on write only for writes it sees. Arrays are
the only case: other carriers already copy or cross by value.
"""
struct MatlabTarget <: AbstractTarget
    dir::String
    package_name::String
    library_basename::String
    duplicate_arguments::Bool
    library_subdir::String
end

MatlabTarget(
    dir::AbstractString, package_name::AbstractString,
    library_basename::AbstractString; duplicate_arguments::Bool = false,
    library_subdir::AbstractString = ""
) = MatlabTarget(
    String(dir), String(package_name), String(library_basename),
    duplicate_arguments, String(library_subdir)
)

function Base.show(io::IO, t::MatlabTarget)
    print(
        io, "MatlabTarget(", repr(t.dir), ", ", repr(t.package_name),
        ", ", repr(t.library_basename)
    )
    t.duplicate_arguments && print(io, "; duplicate_arguments = true")
    print(io, ")")
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

# The integer classes. An `arguments` block converts before validators run,
# and `int64(2.5)` rounds, so they cross as `double` with a `mustBeInteger`
# validator.
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

Integers are declared `double` on purpose: an `arguments` block converts
before its validators run, and `int64(2.5)` rounds rather than failing, so a
later integrality check would always pass. The façade validates as a double
and converts in its body.
"""
function _matlab_arg_validation(kind, name::AbstractString)
    # The cost of the `double` declaration: magnitudes above 2^53 lose precision.
    kind.kind === :scalar &&
        return kind.integer ? "(1,1) double {mustBeInteger}" : "(1,1) " * kind.class
    # `string` accepts a char row vector too: the block converts it.
    kind.kind === :string && return "(1,1) string"
    # No class: `cellstr` in the body takes a cell, a string array or a char
    # matrix.
    kind.kind === :strarray && return ""
    kind.kind === :dict && return "(1,1) struct"
    # A vector argument takes either orientation; the body normalizes it.
    # Integer arrays are declared `double` for the reason scalars are: the
    # block converts before validating, and `int64(2.5)` rounds to 3.
    # `mustBeVector` needs the flag to accept `[]`, which is 0x0.
    if kind.kind === :array
        class = kind.integer ? "double" : kind.class
        # `logical(2)` is `true`, so integrality alone would pass 2.
        checks = kind.class == "logical" ? String["mustBeMember(" * name * ", [0 1])"] :
            kind.integer ? String["mustBeInteger"] : String[]
        kind.ndim == 1 &&
            push!(checks, "mustBeVector(" * name * ", \"allow-all-empties\")")
        isempty(checks) && return class
        return class * " {" * join(checks, ", ") * "}"
    end
    # Absent is `[]`, present is a scalar; the body tells them apart. An
    # integer payload is declared `double` for the reason a scalar one is:
    # the block would coerce before validating, and `int64(2.5)` rounds.
    kind.kind === :opt && return kind.integer ?
        "(:,:) double {mustBeInteger}" : "(:,:) " * kind.class
    return error("no MATLAB validation for argument kind $(kind.kind)")
end

"""
    _matlab_arg_forward(name, kind) -> String

The expression a façade passes to the gateway for one argument.
"""
function _matlab_arg_forward(name::AbstractString, kind)
    # The gateway reads `char`; the C API reads char arrays only.
    kind.kind === :string && return "convertStringsToChars(" * name * ")"
    kind.kind === :strarray && return "cellstr(" * name * ")"
    # A MATLAB vector arrives 1×N or N×1; `(:)` yields the column the carrier
    # expects, without a copy.
    if kind.kind === :array
        flat = kind.ndim == 1 ? name * "(:)" : name
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
    return (;
        kind = :auto, args, ret, positional, keywords, defaults, enums,
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
    _matlab_outputs(ret) -> Vector{String}

The façade's output names. A tuple return becomes one output per element, in
declaration order; anything else is a single output, and a `Nothing` return
yields zero.
"""
function _matlab_outputs(ret)
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
    outputs = _matlab_outputs(plan.ret)
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

    # A borrowed array is MATLAB's own buffer, and nothing in the MATLAB
    # source says a copy was due, so a caller cannot learn this from the code.
    borrows = !dest.duplicate_arguments && any(a -> a.kind === :array, plan.args)
    # `help` reads the first comment line as the summary, so it is written
    # even when the sidecar records no docstring: a bare `%` leaves it empty.
    if !isempty(plan.doc) || borrows
        lines = isempty(plan.doc) ? [""] : split(plan.doc, '\n')
        for (i, line) in pairs(lines)
            prefix = i == 1 ? "%" * uppercase(plan.name) * "  " : "%   "
            println(io, rstrip(prefix * line))
        end
    end
    if borrows
        println(io, "%")
        println(io, "%   Array arguments are passed without copying. If this function")
        println(io, "%   writes to one, every variable sharing that data changes with")
        println(io, "%   it. Rebuild with duplicate_arguments = true if it does.")
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
        push!(forwarded, _matlab_arg_forward(expression, kind))
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
    if !isnothing(plan.return_enum) && length(outputs) == 1
        _write_matlab_enum_out(io, only(outputs), plan.api_enums[plan.return_enum])
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
    println(io, "function build_mex(library_dir)")
    println(io, "%BUILD_MEX  Compile the ", dest.package_name, " gateway.")
    println(io, "%   BUILD_MEX() expects the shared library in this directory.")
    println(io, "%   BUILD_MEX(DIR) takes it from DIR instead. The path is compiled")
    println(
        io, "%   in; set ", uppercase(sanitize_for_c(dest.library_basename)),
        "_MEX_LIBRARY to override it at run time."
    )
    println(io, "    here = fileparts(mfilename('fullpath'));")
    println(io, "    if nargin < 1")
    if isempty(dest.library_subdir)
        println(io, "        library_dir = here;")
    else
        parts = join(
            ["'" * p * "'" for p in splitpath(dest.library_subdir)], ", "
        )
        println(io, "        library_dir = fullfile(here, ", parts, ");")
    end
    println(io, "    end")
    println(io, "    target = fullfile(here, '+", dest.package_name, "', 'private');")
    println(io, "    if ~isfolder(target)")
    println(io, "        mkdir(target);")
    println(io, "    end")
    println(io, "    % The library stays where it was built, next to the runtime its")
    println(io, "    % RUNPATH points at, so the path is compiled in instead of")
    println(io, "    % copying the library beside the MEX file.")
    println(io, "    stem = fullfile(library_dir, '", dest.library_basename, "');")
    println(io, "    % -R2018a selects the typed accessors the gateway uses.")
    println(io, "    mex('-R2018a', ...")
    println(io, "        '-outdir', target, ...")
    println(io, "        ['-I' here], ...")
    println(io, "        ['-DJLW_LIBRARY_PATH=\"' strrep(stem, '\\', '\\\\') '\"'], ...")
    println(io, "        fullfile(here, '", gateway, ".c'));")
    println(io, "end")
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

The library is opened here rather than linked, and never closed: `clear mex`
unloads the MEX file, and the next load would run `jl_init` twice in one
process, which aborts. `RTLD_NODELETE` keeps the runtime mapped even if the
handle is closed.
"""
function _write_matlab_gateway_prologue(
        io::IO, dest::MatlabTarget, header::AbstractString,
        message_bytes::Union{Int, Nothing}
    )
    println(io, "/* Auto-generated by JuliaLibWrapping. Do not edit by hand. */")
    println(io, "#include <stdint.h>")
    println(io, "#include <stdio.h>")
    println(io, "#include <stdlib.h>")
    println(io, "#include <string.h>")
    println(io, "#ifdef _WIN32")
    println(io, "#include <windows.h>")
    println(io, "#else")
    println(io, "#include <dlfcn.h>")
    println(io, "#include <fcntl.h>")
    println(io, "#endif")
    println(io, "#include \"mex.h\"")
    println(io, "#include \"", header, "\"")
    println(io)
    environment = uppercase(sanitize_for_c(dest.library_basename)) * "_MEX_LIBRARY"
    println(io, "/* Where the shared library is. `build_mex.m` bakes in the path it")
    println(io, "   was built against; the environment variable overrides it. A bare")
    println(io, "   name resolves against MATLAB's working directory, not the MEX")
    println(io, "   file's location. */")
    println(io, "#ifndef JLW_LIBRARY_PATH")
    println(io, "#define JLW_LIBRARY_PATH \"", dest.library_basename, "\"")
    println(io, "#endif")
    println(io, "#define JLW_LIBRARY_ENV \"", environment, "\"")
    println(io)
    println(io, "static void *jlw_library = NULL;")
    println(io)
    println(io, "/* Julia's runtime marks inherited pipes non-blocking and leaves")
    println(io, "   them that way, which MATLAB's own reads then see as errors.")
    println(io, "   It bites when MATLAB runs under -batch in a pipeline. */")
    println(io, "typedef struct { int ok; int flags[3]; } jlw_stdio_flags;")
    println(io)
    println(io, "static jlw_stdio_flags jlw_save_stdio(void)")
    println(io, "{")
    println(io, "    jlw_stdio_flags saved;")
    println(io, "    saved.ok = 0;")
    println(io, "#ifndef _WIN32")
    println(io, "    for (int fd = 0; fd < 3; fd++) {")
    println(io, "        saved.flags[fd] = fcntl(fd, F_GETFL);")
    println(io, "    }")
    println(io, "    saved.ok = 1;")
    println(io, "#endif")
    println(io, "    return saved;")
    println(io, "}")
    println(io)
    println(io, "static void jlw_restore_stdio(jlw_stdio_flags saved)")
    println(io, "{")
    println(io, "#ifndef _WIN32")
    println(io, "    if (saved.ok) {")
    println(io, "        for (int fd = 0; fd < 3; fd++) {")
    println(io, "            if (saved.flags[fd] != -1) {")
    println(io, "                fcntl(fd, F_SETFL, saved.flags[fd]);")
    println(io, "            }")
    println(io, "        }")
    println(io, "    }")
    println(io, "#else")
    println(io, "    (void)saved;")
    println(io, "#endif")
    println(io, "}")
    println(io)
    println(io, "/* Opened once and never closed: `clear mex` unloads this file, and")
    println(io, "   reloading the library would run `jl_init` twice in one process. */")
    println(io, "static void *jlw_symbol(const char *name)")
    println(io, "{")
    println(io, "    if (jlw_library == NULL) {")
    println(io, "        const char *override = getenv(JLW_LIBRARY_ENV);")
    println(io, "        jlw_stdio_flags saved = jlw_save_stdio();")
    println(io, "        char path[4096];")
    println(io, "        const char *base = override ? override : JLW_LIBRARY_PATH;")
    println(io, "        char reason[256];")
    println(io, "#ifdef _WIN32")
    println(io, "        snprintf(path, sizeof path, \"%s.dll\", base);")
    println(io, "        /* ALTERED_SEARCH_PATH so the library's own directory is")
    println(io, "           searched for its dependencies, libjulia among them. */")
    println(io, "        jlw_library = (void *)LoadLibraryExA(path, NULL,")
    println(io, "                                            LOAD_WITH_ALTERED_SEARCH_PATH);")
    println(io, "        snprintf(reason, sizeof reason, \"error %lu\",")
    println(io, "                 (unsigned long)GetLastError());")
    println(io, "#else")
    println(io, "#ifdef __APPLE__")
    println(io, "        snprintf(path, sizeof path, \"%s.dylib\", base);")
    println(io, "#else")
    println(io, "        snprintf(path, sizeof path, \"%s.so\", base);")
    println(io, "#endif")
    println(io, "        jlw_library = dlopen(path, RTLD_LAZY | RTLD_GLOBAL | RTLD_NODELETE);")
    println(io, "        const char *message = dlerror();")
    println(io, "        snprintf(reason, sizeof reason, \"%s\", message ? message : \"\");")
    println(io, "#endif")
    println(io, "        if (jlw_library == NULL) {")
    println(io, "            mexErrMsgIdAndTxt(\"jlw:library\",")
    println(io, "                \"could not load %s (%s); set \" JLW_LIBRARY_ENV")
    println(io, "                \" to its path without the extension\", path, reason);")
    println(io, "        }")
    println(io, "        jlw_restore_stdio(saved);")
    println(io, "    }")
    println(io, "#ifdef _WIN32")
    println(io, "    void *address = (void *)GetProcAddress((HMODULE)jlw_library, name);")
    println(io, "#else")
    println(io, "    void *address = dlsym(jlw_library, name);")
    println(io, "#endif")
    println(io, "    if (address == NULL) {")
    println(io, "        mexErrMsgIdAndTxt(\"jlw:library\", \"missing entry point %s\", name);")
    println(io, "    }")
    println(io, "    return address;")
    println(io, "}")
    println(io)
    # The status check is emitted only when the library reports a status.
    isnothing(message_bytes) && return nothing
    println(io, "/* Raises, so every caller must release what it holds before calling:")
    println(io, "   `mexErrMsgIdAndTxt` leaves by `longjmp`, which runs no cleanup. */")
    println(io, "static void jlw_check(JLWStatus status)")
    println(io, "{")
    println(io, "    if (status.code == 0) {")
    println(io, "        return;")
    println(io, "    }")
    println(io, "    char message[", message_bytes, " + 1];")
    println(io, "    memcpy(message, status.message, ", message_bytes, ");")
    println(io, "    message[", message_bytes, "] = '\\0';")
    println(io, "    const char *identifier;")
    println(io, "    switch (status.code) {")
    for code in sort(collect(keys(MATLAB_ERROR_IDENTIFIERS)))
        println(io, "        case ", code, ": identifier = \"", MATLAB_ERROR_IDENTIFIERS[code], "\"; break;")
    end
    println(io, "        default: identifier = \"jlw:error\"; break;")
    println(io, "    }")
    println(io, "    mexErrMsgIdAndTxt(identifier, \"%s\", message);")
    println(io, "}")
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
    _write_matlab_check(io, plan, symbol)

Write the validation phase of one handler: everything that can raise, before
anything is acquired. `mexErrMsgIdAndTxt` leaves by `longjmp`, which runs no
cleanup, so a check that raises while a carrier is live would leak it. Class,
shape, and sparsity checks hold no carrier, so they all run first.
"""
function _write_matlab_check(io::IO, plan, symbol::AbstractString)
    # `nlhs` is known before the call, so the output-count check runs here with
    # the other raises: after the call, `longjmp` would unwind past storage
    # Julia has already allocated.
    inner = plan.ret.kind === :result ? plan.ret.inner : plan.ret
    if inner.kind === :tuple
        count = length(inner.elements)
        println(io, "    int wanted = nlhs < 1 ? 1 : nlhs;")
        println(io, "    if (wanted > ", count, ") {")
        println(io, "        mexErrMsgIdAndTxt(\"jlw:argument\", \"at most ", count, " outputs\");")
        println(io, "    }")
    end
    println(io, "    if (nrhs != ", length(plan.args) + 1, ") {")
    println(
        io, "        mexErrMsgIdAndTxt(\"jlw:argument\", \"", symbol,
        " takes ", length(plan.args), " arguments\");"
    )
    println(io, "    }")
    for (i, kind) in pairs(plan.args)
        argument = "prhs[" * string(i) * "]"
        name = i <= length(plan.positional) ? plan.positional[i] :
            plan.keywords[i - length(plan.positional)]
        # A sparse mxArray passes a class check but stores (i, j, v) triples,
        # so borrowing it as a dense buffer would read the wrong memory.
        if kind.kind in (:array, :scalar, :opt, :dict)
            println(io, "    if (mxIsSparse(", argument, ")) {")
            println(
                io, "        mexErrMsgIdAndTxt(\"jlw:argument\", \"", name,
                " must not be sparse\");"
            )
            println(io, "    }")
        end
        if kind.kind === :scalar
            println(io, "    if (!mxIs", uppercasefirst(kind.class), "(", argument, ") || mxGetNumberOfElements(", argument, ") != 1) {")
            println(
                io, "        mexErrMsgIdAndTxt(\"jlw:argument\", \"", name,
                " must be a ", kind.class, " scalar\");"
            )
            println(io, "    }")
        elseif kind.kind === :array
            println(io, "    if (!mxIs", uppercasefirst(kind.class), "(", argument, ")) {")
            println(
                io, "        mexErrMsgIdAndTxt(\"jlw:argument\", \"", name,
                " must be ", kind.class, "\");"
            )
            println(io, "    }")
            println(io, "    if (mxGetNumberOfDimensions(", argument, ") > ", max(kind.ndim, 2), ") {")
            println(
                io, "        mexErrMsgIdAndTxt(\"jlw:dimension\", \"", name,
                " has too many dimensions\");"
            )
            println(io, "    }")
        elseif kind.kind === :string
            println(io, "    if (!mxIsChar(", argument, ")) {")
            println(
                io, "        mexErrMsgIdAndTxt(\"jlw:argument\", \"", name,
                " must be char\");"
            )
            println(io, "    }")
        elseif kind.kind === :strarray
            println(io, "    if (!mxIsCell(", argument, ")) {")
            println(
                io, "        mexErrMsgIdAndTxt(\"jlw:argument\", \"", name,
                " must be a cell array of char\");"
            )
            println(io, "    }")
        elseif kind.kind === :dict
            println(io, "    if (!mxIsStruct(", argument, ")) {")
            println(
                io, "        mexErrMsgIdAndTxt(\"jlw:argument\", \"", name,
                " must be a struct\");"
            )
            println(io, "    }")
        elseif kind.kind === :opt
            println(io, "    if (!mxIsEmpty(", argument, ") && mxGetNumberOfElements(", argument, ") != 1) {")
            println(
                io, "        mexErrMsgIdAndTxt(\"jlw:argument\", \"", name,
                " must be a scalar or []\");"
            )
            println(io, "    }")
        end
    end
    return nothing
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
    _write_matlab_length_guard(io, indent, expression, bits, what)

Guard a count that has to fit a 32-bit field: `mwSize` is unsigned and
64-bit, so a larger value would truncate to a negative number in Julia.
Nothing is held at these sites, so raising is safe.
"""
function _write_matlab_length_guard(
        io::IO, indent::AbstractString, expression::AbstractString,
        bits::Integer, what::AbstractString
    )
    bits >= 64 && return nothing
    println(io, indent, "if (", expression, " > INT32_MAX) {")
    println(
        io, indent, "    mexErrMsgIdAndTxt(\"jlw:dimension\", \"", what,
        " exceeds this library's 32-bit length field\");"
    )
    println(io, indent, "}")
    return nothing
end

"""
    _write_matlab_in_helpers(io, carriers)

Write one conversion helper per borrowed carrier an argument uses.

Each takes an already-validated `mxArray` and returns a carrier over MATLAB's
storage. What they allocate comes from `mxMalloc`, which MATLAB reclaims when
`mexFunction` exits, so an unwind past them is safe.
"""
function _write_matlab_in_helpers(io::IO, carriers, duplicate::Bool)
    for (name, kind) in carriers
        if kind.kind === :array
            ctype = _matlab_ctype(kind.class)
            println(io)
            println(io, "static ", name, " jlw_in_", name, "(const mxArray *value)")
            println(io, "{")
            if duplicate
                println(io, "    /* The caller asked for copies: a wrapped function that")
                println(io, "       writes to its argument would otherwise corrupt every")
                println(io, "       MATLAB variable sharing this buffer. The duplicate is")
                println(io, "       reclaimed when `mexFunction` exits. */")
                println(io, "    value = mxDuplicateArray(value);")
            end
            println(io, "    ", name, " carrier;")
            if kind.ndim == 1
                _write_matlab_length_guard(
                    io, "    ", "mxGetNumberOfElements(value)", kind.dims_bits,
                    "the vector's length"
                )
                println(
                    io, "    carrier.dims[0] = (", _matlab_length_type(kind.dims_bits),
                    ")mxGetNumberOfElements(value);"
                )
            else
                println(io, "    const mwSize *shape = mxGetDimensions(value);")
                println(io, "    mwSize rank = mxGetNumberOfDimensions(value);")
                println(io, "    for (int i = 0; i < ", kind.ndim, "; i++) {")
                println(io, "        /* MATLAB drops trailing singletons, so a missing")
                println(io, "           dimension is 1 rather than an error. */")
                _write_matlab_length_guard(
                    io, "        ", "(i < (int)rank ? shape[i] : 1)", kind.dims_bits,
                    "a dimension"
                )
                println(
                    io, "        carrier.dims[i] = (", _matlab_length_type(kind.dims_bits),
                    ")(i < (int)rank ? shape[i] : 1);"
                )
                println(io, "    }")
            end
            println(io, "    carrier.data = (", ctype, " *)", _matlab_accessor(kind.class), "(value);")
            println(io, "    return carrier;")
            println(io, "}")
        elseif kind.kind === :string
            println(io)
            println(io, "static ", name, " jlw_in_", name, "(const mxArray *value)")
            println(io, "{")
            println(io, "    /* From `mxMalloc`, so it is reclaimed even if an error unwinds past here. */")
            println(io, "    char *text = mxArrayToUTF8String(value);")
            println(io, "    if (text == NULL) {")
            println(io, "        mexErrMsgIdAndTxt(\"jlw:argument\", \"could not read char data\");")
            println(io, "    }")
            println(io, "    size_t size = strlen(text);")
            _write_matlab_length_guard(io, "    ", "size", kind.length_bits, "the string")
            println(io, "    ", name, " carrier;")
            println(
                io, "    carrier.length = (", _matlab_length_type(kind.length_bits), ")size;"
            )
            println(io, "    carrier.data = (uint8_t *)text;")
            println(io, "    return carrier;")
            println(io, "}")
        elseif kind.kind === :strarray
            println(io)
            println(io, "static ", name, " jlw_in_", name, "(const mxArray *value)")
            println(io, "{")
            println(io, "    mwSize count = mxGetNumberOfElements(value);")
            println(io, "    CString_borrowed *items =")
            println(io, "        (CString_borrowed *)mxMalloc((count ? count : 1) * sizeof(CString_borrowed));")
            println(io, "    for (mwSize i = 0; i < count; i++) {")
            println(io, "        const mxArray *cell = mxGetCell(value, i);")
            println(io, "        if (cell == NULL || !mxIsChar(cell)) {")
            println(io, "            mexErrMsgIdAndTxt(\"jlw:argument\", \"every cell must be char\");")
            println(io, "        }")
            println(io, "        char *text = mxArrayToUTF8String(cell);")
            println(io, "        size_t size = strlen(text);")
            _write_matlab_length_guard(
                io, "        ", "size", kind.element_bits, "a string"
            )
            println(
                io, "        items[i].length = (",
                _matlab_length_type(kind.element_bits), ")size;"
            )
            println(io, "        items[i].data = (uint8_t *)text;")
            println(io, "    }")
            _write_matlab_length_guard(io, "    ", "count", kind.length_bits, "the cell array")
            println(io, "    ", name, " carrier;")
            println(
                io, "    carrier.length = (", _matlab_length_type(kind.length_bits), ")count;"
            )
            println(io, "    carrier.data = items;")
            println(io, "    return carrier;")
            println(io, "}")
        elseif kind.kind === :dict
            ctype = _matlab_ctype(kind.class)
            println(io)
            println(io, "static ", name, " jlw_in_", name, "(const mxArray *value)")
            println(io, "{")
            println(io, "    int count = mxGetNumberOfFields(value);")
            println(io, "    CString_borrowed *keys =")
            println(io, "        (CString_borrowed *)mxMalloc((count ? count : 1) * sizeof(CString_borrowed));")
            println(io, "    ", ctype, " *values =")
            println(io, "        (", ctype, " *)mxMalloc((count ? count : 1) * sizeof(", ctype, "));")
            println(io, "    for (int i = 0; i < count; i++) {")
            println(io, "        const char *key = mxGetFieldNameByNumber(value, i);")
            println(io, "        keys[i].length = (int32_t)strlen(key);")
            println(io, "        /* A MATLAB field name is at most `mxMAXNAM`, so it fits. */")
            println(io, "        keys[i].data = (uint8_t *)key;")
            println(io, "        const mxArray *field = mxGetFieldByNumber(value, 0, i);")
            println(io, "        /* A sparse field passes a class check and has no")
            println(io, "           dense buffer to read. */")
            println(io, "        if (field == NULL || mxIsSparse(field) ||")
            println(io, "            !mxIs", uppercasefirst(kind.class), "(field) ||")
            println(io, "            mxGetNumberOfElements(field) != 1) {")
            println(io, "            mexErrMsgIdAndTxt(\"jlw:argument\",")
            println(io, "                \"field %s must be a ", kind.class, " scalar\", key);")
            println(io, "        }")
            println(io, "        values[i] = *", _matlab_accessor(kind.class), "(field);")
            println(io, "    }")
            println(io, "    ", name, " carrier;")
            println(
                io, "    carrier.length = (", _matlab_length_type(kind.length_bits), ")count;"
            )
            println(io, "    carrier.keys = keys;")
            println(io, "    carrier.values = values;")
            println(io, "    return carrier;")
            println(io, "}")
        elseif kind.kind === :opt
            ctype = _matlab_ctype(kind.class)
            println(io)
            println(io, "static ", name, " jlw_in_", name, "(const mxArray *value)")
            println(io, "{")
            println(io, "    ", name, " carrier;")
            println(io, "    if (mxIsEmpty(value)) {")
            println(io, "        carrier.has_value = 0;")
            println(io, "        carrier.value = (", ctype, ")0;")
            println(io, "    } else {")
            println(io, "        carrier.has_value = 1;")
            println(io, "        carrier.value = (", ctype, ")mxGetScalar(value);")
            println(io, "    }")
            println(io, "    return carrier;")
            println(io, "}")
        end
    end
    return nothing
end

"""
    _write_matlab_release(io)

Write cached wrappers for the library's deallocation entry points. They are
resolved once: a `dlsym` per release would cost a lookup on every returned
value.
"""
function _write_matlab_release(io::IO)
    println(io)
    println(io, "static void jlw_release(void *pointer)")
    println(io, "{")
    println(io, "    static void (*entry)(void *) = NULL;")
    println(io, "    if (entry == NULL) {")
    println(io, "        entry = (void (*)(void *))jlw_symbol(\"jlw_free\");")
    println(io, "    }")
    println(io, "    entry(pointer);")
    println(io, "}")
    println(io)
    # `void *`: the header declares the carrier typedef only when an entry
    # point uses it, so a carrier-free library still compiles.
    println(io, "static void jlw_release_strings(void *items, int64_t count)")
    println(io, "{")
    println(io, "    static void (*entry)(void *, int64_t) = NULL;")
    println(io, "    if (entry == NULL) {")
    println(io, "        entry = (void (*)(void *, int64_t))jlw_symbol(\"jlw_free_strings\");")
    println(io, "    }")
    println(io, "    entry(items, count);")
    println(io, "}")
    return nothing
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
        println(io)
        println(io, "static mxArray *jlw_out_", name, "(", name, " carrier)")
        println(io, "{")
        if kind.kind === :array
            ctype = _matlab_ctype(kind.class)
            println(io, "    mwSize shape[", max(kind.ndim, 2), "] = {", join(fill("1", max(kind.ndim, 2)), ", "), "};")
            for d in 1:kind.ndim
                println(io, "    shape[", d - 1, "] = (mwSize)carrier.dims[", d - 1, "];")
            end
            println(io, "    mxArray *out = ", _matlab_create_array(kind.class, max(kind.ndim, 2), "shape"), ";")
            println(io, "    memcpy(", _matlab_accessor(kind.class), "(out), carrier.data,")
            println(io, "           mxGetNumberOfElements(out) * sizeof(", ctype, "));")
            kind.owns && println(io, "    jlw_release(carrier.data);")
        elseif kind.kind === :string
            println(io, "    /* `mxCreateString` takes a C string, so an embedded NUL")
            println(io, "       truncates; Julia permits them. */")
            println(io, "    char *text = (char *)mxMalloc((size_t)carrier.length + 1);")
            println(io, "    memcpy(text, carrier.data, (size_t)carrier.length);")
            println(io, "    text[carrier.length] = '\\0';")
            kind.owns && println(io, "    jlw_release(carrier.data);")
            println(io, "    mxArray *out = mxCreateString(text);")
            println(io, "    mxFree(text);")
        elseif kind.kind === :strarray
            println(io, "    mxArray *out = mxCreateCellMatrix((mwSize)carrier.length, 1);")
            println(io, "    for (int64_t i = 0; i < carrier.length; i++) {")
            println(io, "        char *text = (char *)mxMalloc((size_t)carrier.data[i].length + 1);")
            println(io, "        memcpy(text, carrier.data[i].data, (size_t)carrier.data[i].length);")
            println(io, "        text[carrier.data[i].length] = '\\0';")
            println(io, "        mxSetCell(out, (mwSize)i, mxCreateString(text));")
            println(io, "        mxFree(text);")
            println(io, "    }")
            kind.owns && println(io, "    jlw_release_strings(carrier.data, carrier.length);")
        elseif kind.kind === :dict
            ctype = _matlab_ctype(kind.class)
            println(io, "    /* Field names are checked before anything is created, so a")
            println(io, "       bad key is reported while nothing is held. */")
            println(io, "    for (int64_t i = 0; i < carrier.length; i++) {")
            println(io, "        int32_t n = carrier.keys[i].length;")
            println(io, "        int ok = n > 0 && n < mxMAXNAM;")
            println(io, "        for (int32_t j = 0; ok && j < n; j++) {")
            println(io, "            uint8_t c = carrier.keys[i].data[j];")
            println(io, "            int alpha = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');")
            println(io, "            int rest = (c >= '0' && c <= '9') || c == '_';")
            println(io, "            /* A field name starts with a letter. */")
            println(io, "            ok = j == 0 ? alpha : (alpha || rest);")
            println(io, "        }")
            println(io, "        if (!ok) {")
            if kind.owns
                println(io, "            jlw_release_strings(carrier.keys, carrier.length);")
                println(io, "            jlw_release(carrier.values);")
            end
            println(io, "            mexErrMsgIdAndTxt(\"jlw:argument\",")
            println(io, "                \"a dictionary key is not a legal MATLAB field name\");")
            println(io, "        }")
            println(io, "    }")
            println(io, "    const char **names =")
            println(io, "        (const char **)mxMalloc((size_t)(carrier.length ? carrier.length : 1) * sizeof(char *));")
            println(io, "    for (int64_t i = 0; i < carrier.length; i++) {")
            println(io, "        char *key = (char *)mxMalloc((size_t)carrier.keys[i].length + 1);")
            println(io, "        memcpy(key, carrier.keys[i].data, (size_t)carrier.keys[i].length);")
            println(io, "        key[carrier.keys[i].length] = '\\0';")
            println(io, "        names[i] = key;")
            println(io, "    }")
            println(io, "    mxArray *out = mxCreateStructMatrix(1, 1, (int)carrier.length, names);")
            println(io, "    for (int64_t i = 0; i < carrier.length; i++) {")
            println(io, "        mxArray *field = ", _matlab_create_scalar(kind.class, 1, 1), ";")
            println(io, "        *", _matlab_accessor(kind.class), "(field) = (", ctype, ")carrier.values[i];")
            println(io, "        mxSetFieldByNumber(out, 0, (int)i, field);")
            println(io, "    }")
            if kind.owns
                println(io, "    jlw_release_strings(carrier.keys, carrier.length);")
                println(io, "    jlw_release(carrier.values);")
            end
        elseif kind.kind === :opt
            println(io, "    if (carrier.has_value == 0) {")
            println(io, "        return ", _matlab_create_scalar(kind.class, 0, 0), ";")
            println(io, "    }")
            println(io, "    mxArray *out = ", _matlab_create_scalar(kind.class, 1, 1), ";")
            println(io, "    *", _matlab_accessor(kind.class), "(out) = carrier.value;")
        elseif kind.kind === :scalar
            println(io, "    mxArray *out = ", _matlab_create_scalar(kind.class, 1, 1), ";")
            println(io, "    *", _matlab_accessor(kind.class), "(out) = carrier;")
        end
        println(io, "    return out;")
        println(io, "}")
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
    println(io)
    println(io, "static void jlw_call_", symbol)
    println(io, "    (int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])")
    println(io, "{")
    # Handlers share one signature, so a void or single-output one leaves
    # parameters unused; a MEX build with warnings on would say so.
    inner = plan.ret.kind === :result ? plan.ret.inner : plan.ret
    inner.kind === :tuple || println(io, "    (void)nlhs;")
    inner.kind in (:void, :none) && println(io, "    (void)plhs;")
    isempty(plan.args) && println(io, "    (void)prhs;")
    _write_matlab_check(io, plan, symbol)

    for (i, kind) in pairs(plan.args)
        carrier = names.args[i]
        source = "prhs[" * string(i) * "]"
        if kind.kind === :scalar
            println(io, "    ", _matlab_ctype(kind.class), " arg", i, " = (", _matlab_ctype(kind.class), ")mxGetScalar(", source, ");")
        else
            println(io, "    ", carrier, " arg", i, " = jlw_in_", carrier, "(", source, ");")
        end
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
        # Nothing comes back, so there is nothing to name or check.
        println(io, "    ", call)
        return println(io, "}")
    end
    println(io, "    ", names.result, " result =")
    println(io, "        ", call)

    # On a failure the value is zero-filled, so the check raises while
    # holding nothing; that is what lets it run before any conversion.
    if ret.kind === :result
        println(io, "    jlw_check(result.status);")
        _write_matlab_results(io, ret.inner, "result.value", names)
    elseif ret.kind === :void
        println(io, "    jlw_check(result);")
    else
        _write_matlab_results(io, ret, "result", names)
    end
    println(io, "}")
    return nothing
end

"""
    _write_matlab_results(io, ret, expression, names)

Assign an entry point's results into `plhs`.

A caller may request fewer outputs than a declaration produces; every element
is converted regardless, because conversion is what releases Julia's storage
for it. An unrequested element's `mxArray` is destroyed instead of assigned.
"""
function _write_matlab_results(io::IO, ret, expression::AbstractString, names)
    ret.kind in (:void, :none) && return nothing
    if ret.kind !== :tuple
        println(io, "    plhs[0] = jlw_out_", names.value, "(", expression, ");")
        return nothing
    end
    count = length(ret.elements)
    _write_matlab_tuple_precheck(io, ret, expression, names)
    for i in 1:count
        access = expression * ".values" * _matlab_element_access(ret.fields, i)
        println(io, "    mxArray *out", i, " = jlw_out_", names.elements[i], "(", access, ");")
    end
    for i in 1:count
        println(io, "    if (wanted >= ", i, ") {")
        println(io, "        plhs[", i - 1, "] = out", i, ";")
        println(io, "    } else {")
        println(io, "        mxDestroyArray(out", i, ");")
        println(io, "    }")
    end
    return nothing
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
    _write_matlab_in_helpers(io, incoming, dest.duplicate_arguments)
    _write_matlab_out_helpers(io, outgoing)

    for (method, plan, names) in named
        _write_matlab_handler(io, plan, method.symbol, names)
    end

    println(io)
    println(io, "void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])")
    println(io, "{")
    println(io, "    if (nrhs < 1 || !mxIsChar(prhs[0])) {")
    println(io, "        mexErrMsgIdAndTxt(\"jlw:argument\", \"the first argument names the function\");")
    println(io, "    }")
    # Read the dispatch name only when a function is wrapped; an empty gateway
    # would carry an unused variable.
    isempty(named) || println(io, "    char *name = mxArrayToUTF8String(prhs[0]);")
    for (i, (method, _, _)) in pairs(named)
        keyword = i == 1 ? "    if" : "    } else if"
        println(io, keyword, " (strcmp(name, \"", method.symbol, "\") == 0) {")
        println(io, "        jlw_call_", method.symbol, "(nlhs, plhs, nrhs, prhs);")
    end
    if isempty(named)
        println(io, "    (void)nlhs;")
        println(io, "    (void)plhs;")
        println(io, "    mexErrMsgIdAndTxt(\"jlw:argument\", \"no wrapped functions\");")
    else
        println(io, "    } else {")
        println(io, "        mexErrMsgIdAndTxt(\"jlw:argument\", \"unknown function %s\", name);")
        println(io, "    }")
    end
    println(io, "}")
    return nothing
end

"""
    _matlab_release_expression(kind, access) -> Vector{String}

The statements that release a carrier's storage without converting it. Used to
unwind a tuple whose elements have been produced but not yet converted.
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
    _write_matlab_tuple_precheck(io, ret, expression, names)

Validate every dictionary element's field names before any element of a tuple
is converted.

Conversion is also what releases an element, so a raise part-way would strand
the unconverted ones. Dictionary keys are runtime data from Julia, so this is
an ordinary path, not an edge case. Checking first means a raise happens
while the whole tuple is still intact and can be released.
"""
function _write_matlab_tuple_precheck(io::IO, ret, expression::AbstractString, names)
    dicts = [i for (i, element) in pairs(ret.elements) if element.kind === :dict]
    isempty(dicts) && return nothing
    for i in dicts
        access = expression * ".values" * _matlab_element_access(ret.fields, i)
        println(io, "    for (int64_t k = 0; k < ", access, ".length; k++) {")
        println(io, "        int32_t n = ", access, ".keys[k].length;")
        println(io, "        int ok = n > 0 && n < mxMAXNAM;")
        println(io, "        for (int32_t j = 0; ok && j < n; j++) {")
        println(io, "            uint8_t c = ", access, ".keys[k].data[j];")
        println(io, "            int alpha = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');")
        println(io, "            int rest = (c >= '0' && c <= '9') || c == '_';")
        println(io, "            /* A field name starts with a letter. */")
        println(io, "            ok = j == 0 ? alpha : (alpha || rest);")
        println(io, "        }")
        println(io, "        if (!ok) {")
        for (j, element) in pairs(ret.elements)
            other = expression * ".values" * _matlab_element_access(ret.fields, j)
            for statement in _matlab_release_expression(element, other)
                println(io, "            ", statement)
            end
        end
        println(io, "            mexErrMsgIdAndTxt(\"jlw:argument\",")
        println(io, "                \"a dictionary key is not a legal MATLAB field name\");")
        println(io, "        }")
        println(io, "    }")
    end
    return nothing
end
