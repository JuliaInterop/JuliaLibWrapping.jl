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

"""
    MATLAB_CLASSES :: Dict{String, String}

The MATLAB class each carrier element type is passed and returned as. MATLAB
numeric literals are `double`, so an integer argument is *declared* `double`
and converted in the façade body; these names are what the gateway checks with
`mxIs…` and what a return is built as.
"""
const MATLAB_CLASSES = Dict{String, String}(
    "Float64" => "double", "Float32" => "single",
    "Int8" => "int8", "Int16" => "int16", "Int32" => "int32", "Int64" => "int64",
    "UInt8" => "uint8", "UInt16" => "uint16", "UInt32" => "uint32",
    "UInt64" => "uint64", "Bool" => "logical",
)

# The integer classes, which an `arguments` block must not name directly: the
# block converts before validators run, and `int64(2.5)` rounds rather than
# failing, so an integrality check placed after it would always pass.
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

An owning carrier is `:opaque` in argument position: the ownership model gives
arguments to the callee borrowed, and a carrier that says otherwise is a shape
this emitter must not guess at.
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
        return (kind = :string,)
    end
    info = cstrarray_struct_info(desc, typeinfo)
    if !isnothing(info)
        info.ownership === :borrowed || return _matlab_owning_argument("CStrArray")
        return (kind = :strarray,)
    end
    info = cdict_struct_info(desc, typeinfo)
    if !isnothing(info)
        info.ownership === :borrowed || return _matlab_owning_argument("CDict")
        class = get(MATLAB_CLASSES, info.value_type, nothing)
        isnothing(class) && return (kind = :opaque, reason = "unsupported dictionary value type `$(info.value_type)`")
        return (kind = :dict, class = class)
    end
    info = carray_struct_info(desc, typeinfo)
    if !isnothing(info)
        info.ownership === :borrowed || return _matlab_owning_argument("CArray")
        class = get(MATLAB_CLASSES, info.eltype, nothing)
        isnothing(class) && return (kind = :opaque, reason = "unsupported array element type `$(info.eltype)`")
        return (kind = :array, class = class, ndim = info.ndim)
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
storage for it. That is what a tuple's release loop reads, and it must be
honored for every element, including elements a caller did not ask for — a
MATLAB caller may request fewer outputs than a declaration produces, and the
unrequested ones are allocated all the same.

An owning return classifies `:opaque` when `release_present` is `false`: the
library exports no deallocation entry points, so the gateway would have nothing
to call.
"""
function _matlab_classify_return(
        type_id::Union{Int, Nothing}, typeinfo::OrderedDict{Int, TypeDesc},
        release_present::Bool
    )
    type_id === nothing && return (kind = :void, owns = false)
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
            el.kind in (:tuple, :result, :void) && return (
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
    _matlab_arg_validation(kind) -> String

The `arguments`-block declaration for one argument, without its name.

An integer is declared `double` on purpose. An `arguments` block converts to
the declared class *before* its validators run, and `int64(2.5)` rounds rather
than failing, so an integrality check placed after a conversion always passes.
The façade validates as a double and converts in its body.
"""
function _matlab_arg_validation(kind)
    kind.kind === :scalar &&
        return kind.integer ? "(1,1) double {mustBeInteger}" : "(1,1) " * kind.class
    # `string` accepts a char row vector too: the block converts it.
    kind.kind === :string && return "(1,1) string"
    kind.kind === :strarray && return "(1,:) cell"
    kind.kind === :dict && return "(1,1) struct"
    # A vector argument takes either orientation; the body normalizes it.
    kind.kind === :array &&
        return kind.ndim == 1 ? kind.class * " {mustBeVector}" : kind.class
    # Absent is `[]`, present is a scalar; the body tells them apart.
    kind.kind === :opt && return "(:,:) " * kind.class
    return error("no MATLAB validation for argument kind $(kind.kind)")
end

"""
    _matlab_arg_forward(name, kind) -> String

The expression a façade passes to the gateway for one argument.
"""
function _matlab_arg_forward(name::AbstractString, kind)
    # The gateway reads `char`; there is no public C API for a MATLAB string.
    kind.kind === :string && return "convertStringsToChars(" * name * ")"
    # MATLAB has no 1-D array, so a vector arrives 1×N or N×1; `(:)` makes it
    # the column the carrier expects without copying either orientation twice.
    kind.kind === :array && kind.ndim == 1 && return name * "(:)"
    kind.kind === :scalar && kind.integer && return kind.class * "(" * name * ")"
    return String(name)
end

"""
    _matlab_facade_plan(method, typeinfo, release_present, api_entry) -> NamedTuple

Decide whether an entry point gets a façade, and gather what writing one needs.
`kind` is `:auto` when every argument and the return are mapped, and `:skip`
otherwise, with a `reason`.

`:skip` emits no file at all. A `.m` that exists but raises when called is
worse than an absent one: MATLAB reports a missing function clearly, whereas a
present one that fails looks like a bug in the wrapped library.
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
        Any[get(kw, "default", nothing) for kw in get(api_entry, "kwargs", [])]

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
is keyed by these, not by the MATLAB identifiers derived from them.
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
none at all.
"""
function _matlab_outputs(ret)
    inner = ret.kind === :result ? ret.inner : ret
    inner.kind === :void && return String[]
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

    if !isempty(plan.doc)
        for (i, line) in pairs(split(plan.doc, '\n'))
            prefix = i == 1 ? "%" * uppercase(plan.name) * "  " : "%   "
            println(io, rstrip(prefix * line))
        end
    end

    # An empty `arguments` block is legal but says nothing.
    if !isempty(names)
        println(io, "    arguments")
        for (i, name) in pairs(plan.positional)
            # An enum takes a member name or the underlying integer, which no
            # single class declaration covers; the body sorts it out.
            validation = isnothing(plan.enums[i]) ?
                " " * _matlab_arg_validation(plan.args[i]) : ""
            println(io, "        ", name, validation)
        end
        for (j, name) in pairs(plan.keywords)
            i = length(plan.positional) + j
            default = plan.defaults[j]
            validation = isnothing(plan.enums[i]) ?
                " " * _matlab_arg_validation(plan.args[i]) : ""
            suffix = isnothing(default) ? "" : " = " * _matlab_literal(default)
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
            # `[]` is absent and a scalar is present; nothing else is either.
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

    call = _matlab_gateway_name(dest) * "(\"" * method.symbol * "\""
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
`<package_name>.f(x)`. Entry points whose arguments or return this emitter
cannot map get no file.
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
    for method in sort(entrypoints; by = m -> m.symbol)
        # The release entry points are the gateway's business, not the
        # caller's, so they never get a façade.
        method.symbol in ("jlw_free", "jlw_free_strings") && continue
        plan = _matlab_facade_plan(
            method, typeinfo, release_present,
            get(api_metadata, method.symbol, nothing), api_enums
        )
        plan.kind === :auto || continue
        open(joinpath(package_dir, plan.name * ".m"), "w") do io
            _write_matlab_facade(io, dest, method, plan)
        end
        push!(written, plan.name)
    end
    return written
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
    println(io, "    end")
    return nothing
end
