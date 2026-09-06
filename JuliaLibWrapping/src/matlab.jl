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

    # The dispatch name is `char`, not a double-quoted `string`: the gateway
    # reads it with `mxArrayToUTF8String`, and there is no public C API for
    # reading a MATLAB `string` object.
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
    wrapped = Tuple{MethodDesc, Any}[]
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
        push!(wrapped, (method, plan))
    end

    gateway = _matlab_gateway_name(dest)
    open(joinpath(dest.dir, gateway * ".c"), "w") do io
        _write_matlab_gateway(io, dest, abi_info, wrapped, dest.library_basename * ".h")
    end
    open(joinpath(dest.dir, "build_mex.m"), "w") do io
        _write_matlab_build_script(io, dest, gateway)
    end
    return written
end

"""
    _write_matlab_build_script(io, dest, gateway)

Write the script that compiles the gateway. It is run by the user, in MATLAB;
emitting it needs no MATLAB, exactly as emitting a Python package needs no
Python.

The library is opened at run time rather than linked, so this passes no
`-l` flag for it. The compiled MEX file lands in the package's `private/`
directory, where the façades can call it and nothing else can.
"""
function _write_matlab_build_script(io::IO, dest::MatlabTarget, gateway::AbstractString)
    println(io, "function build_mex()")
    println(io, "%BUILD_MEX  Compile the ", dest.package_name, " gateway.")
    println(io, "%   Run once, from this directory, with the shared library beside it.")
    println(io, "    here = fileparts(mfilename('fullpath'));")
    println(io, "    target = fullfile(here, '+", dest.package_name, "', 'private');")
    println(io, "    if ~isfolder(target)")
    println(io, "        mkdir(target);")
    println(io, "    end")
    println(io, "    % -R2018a selects the typed accessors the gateway uses.")
    println(io, "    mex('-R2018a', ...")
    println(io, "        '-outdir', target, ...")
    println(io, "        ['-I' here], ...")
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
    println(io, "    end")
    return nothing
end

"""
    MATLAB_ERROR_IDENTIFIERS :: Dict{Int, String}

The MATLAB error identifier each `JLWStatus.code` becomes, so a caller gets
`ME.identifier` dispatch from the same codes the Python bindings turn into
`JLWError.code`. A code outside this table falls back to `jlw:error`.
"""
const MATLAB_ERROR_IDENTIFIERS = Dict{Int, String}(
    1 => "jlw:error", 2 => "jlw:argument", 3 => "jlw:dimension",
    4 => "jlw:inexact", 5 => "jlw:bounds",
)

"""
    _write_matlab_gateway_prologue(io, dest, header)

Write the gateway's includes, its library loader and its status check.

The library is opened here rather than linked, and never closed. `clear mex`
unloads the MEX file, and dropping the last reference to the library would run
`jl_init` a second time in one process on the next call, which aborts.
`RTLD_NODELETE` keeps the runtime mapped even if the handle is closed.
"""
function _write_matlab_gateway_prologue(
        io::IO, dest::MatlabTarget, header::AbstractString, message_bytes::Int
    )
    println(io, "/* Auto-generated by JuliaLibWrapping. Do not edit by hand. */")
    println(io, "#include <stdint.h>")
    println(io, "#include <string.h>")
    println(io, "#ifdef _WIN32")
    println(io, "#include <windows.h>")
    println(io, "#else")
    println(io, "#include <dlfcn.h>")
    println(io, "#endif")
    println(io, "#include \"mex.h\"")
    println(io, "#include \"", header, "\"")
    println(io)
    println(io, "static void *jlw_library = NULL;")
    println(io)
    println(io, "/* Opened once and never closed: `clear mex` unloads this file, and")
    println(io, "   reloading the library would run `jl_init` twice in one process. */")
    println(io, "static void *jlw_symbol(const char *name)")
    println(io, "{")
    println(io, "    if (jlw_library == NULL) {")
    println(io, "#ifdef _WIN32")
    println(io, "        jlw_library = (void *)LoadLibraryA(\"", dest.library_basename, ".dll\");")
    println(io, "#elif defined(__APPLE__)")
    println(io, "        jlw_library = dlopen(\"@loader_path/", dest.library_basename, ".dylib\",")
    println(io, "                             RTLD_LAZY | RTLD_GLOBAL | RTLD_NODELETE);")
    println(io, "#else")
    println(io, "        jlw_library = dlopen(\"\$ORIGIN/", dest.library_basename, ".so\",")
    println(io, "                             RTLD_LAZY | RTLD_GLOBAL | RTLD_NODELETE);")
    println(io, "#endif")
    println(io, "        if (jlw_library == NULL) {")
    println(io, "            mexErrMsgIdAndTxt(\"jlw:library\",")
    println(io, "                \"could not load ", dest.library_basename, "\");")
    println(io, "        }")
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
    println(io, "/* Raises, so every caller must already have released what it holds:")
    println(io, "   `mexErrMsgIdAndTxt` leaves by `longjmp`, past any cleanup. */")
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
    _matlab_status_message_bytes(typeinfo) -> Int

The size of `JLWStatus.message`, read from the ABI rather than assumed.
"""
function _matlab_status_message_bytes(typeinfo::OrderedDict{Int, TypeDesc})
    for desc in values(typeinfo)
        desc isa StructDesc || continue
        is_jlwstatus_struct(desc, typeinfo) || continue
        field = only(f for f in desc.fields if f.name == "message")
        return (typeinfo[field.type]::ArrayDesc).count
    end
    return error("the ABI declares no JLWStatus, so no entry point can report an error")
end

"""
    _write_matlab_check(io, plan, symbol)

Write the validation phase of one handler: everything that can raise, before
anything is acquired.

This ordering is the first of the gateway's defenses against leaking.
`mexErrMsgIdAndTxt` leaves by `longjmp`, and a `longjmp` runs no cleanup
handlers, so a check that raises while a carrier is live would strand it.
Class, shape and sparsity checks acquire nothing, so they can all run first.
"""
function _write_matlab_check(io::IO, plan, symbol::AbstractString)
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
        # A sparse mxArray passes a class check but is not a dense buffer, so
        # borrowing one would read the wrong memory.
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
    _matlab_ctype(class) -> String

The C type behind a MATLAB class, as the generated header spells it.
"""
function _matlab_ctype(class::AbstractString)
    class == "double" && return "double"
    class == "single" && return "float"
    class == "logical" && return "mxLogical"
    return class * "_t"
end

"""
    _write_matlab_in_helpers(io, carriers)

Write one conversion helper per distinct borrowed carrier an argument uses.

Each takes an `mxArray` its caller has already validated and returns a carrier
borrowing MATLAB's storage. Storage these allocate comes from `mxMalloc`, which
MATLAB tracks and reclaims when `mexFunction` exits, including through an
error — the second of the gateway's defenses, and what makes an unwind past
them safe.
"""
function _write_matlab_in_helpers(io::IO, carriers)
    for (name, kind) in carriers
        if kind.kind === :array
            ctype = _matlab_ctype(kind.class)
            println(io)
            println(io, "static ", name, " jlw_in_", name, "(const mxArray *value)")
            println(io, "{")
            println(io, "    ", name, " carrier;")
            if kind.ndim == 1
                println(io, "    carrier.dims[0] = (int32_t)mxGetNumberOfElements(value);")
            else
                println(io, "    const mwSize *shape = mxGetDimensions(value);")
                println(io, "    mwSize rank = mxGetNumberOfDimensions(value);")
                println(io, "    for (int i = 0; i < ", kind.ndim, "; i++) {")
                println(io, "        /* MATLAB drops trailing singletons, so a missing")
                println(io, "           dimension is 1 rather than an error. */")
                println(io, "        carrier.dims[i] = (int32_t)(i < (int)rank ? shape[i] : 1);")
                println(io, "    }")
            end
            println(io, "    carrier.data = (", ctype, " *)", _matlab_accessor(kind.class), "(value);")
            println(io, "    return carrier;")
            println(io, "}")
        elseif kind.kind === :string
            println(io)
            println(io, "static ", name, " jlw_in_", name, "(const mxArray *value)")
            println(io, "{")
            println(io, "    /* `mxMalloc`-tracked, so an unwind past this reclaims it. */")
            println(io, "    char *text = mxArrayToUTF8String(value);")
            println(io, "    if (text == NULL) {")
            println(io, "        mexErrMsgIdAndTxt(\"jlw:argument\", \"could not read char data\");")
            println(io, "    }")
            println(io, "    ", name, " carrier;")
            println(io, "    carrier.length = (int32_t)strlen(text);")
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
            println(io, "        items[i].length = (int32_t)strlen(text);")
            println(io, "        items[i].data = (uint8_t *)text;")
            println(io, "    }")
            println(io, "    ", name, " carrier;")
            println(io, "    carrier.length = (int64_t)count;")
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
            println(io, "        keys[i].data = (uint8_t *)key;")
            println(io, "        const mxArray *field = mxGetFieldByNumber(value, 0, i);")
            println(io, "        if (field == NULL || !mxIs", uppercasefirst(kind.class), "(field) ||")
            println(io, "            mxGetNumberOfElements(field) != 1) {")
            println(io, "            mexErrMsgIdAndTxt(\"jlw:argument\",")
            println(io, "                \"field %s must be a ", kind.class, " scalar\", key);")
            println(io, "        }")
            println(io, "        values[i] = *", _matlab_accessor(kind.class), "(field);")
            println(io, "    }")
            println(io, "    ", name, " carrier;")
            println(io, "    carrier.length = (int64_t)count;")
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
    println(io, "static void jlw_release_strings(CString_owned *items, int64_t count)")
    println(io, "{")
    println(io, "    static void (*entry)(CString_owned *, int64_t) = NULL;")
    println(io, "    if (entry == NULL) {")
    println(io, "        entry = (void (*)(CString_owned *, int64_t))jlw_symbol(\"jlw_free_strings\");")
    println(io, "    }")
    println(io, "    entry(items, count);")
    println(io, "}")
    return nothing
end

"""
    _write_matlab_out_helpers(io, carriers)

Write one conversion helper per distinct return carrier, each copying Julia's
storage into a fresh `mxArray` and releasing the original.

A helper that can raise between acquiring and releasing frees first: cleanup
does not run through `mexErrMsgIdAndTxt`'s `longjmp`, so "release on every exit
path" has to be written out rather than delegated.
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
            println(io, "    mxArray *out = mxCreateNumericArray(", max(kind.ndim, 2), ", shape, ", _matlab_class_id(kind.class), ", mxREAL);")
            println(io, "    memcpy(", _matlab_accessor(kind.class), "(out), carrier.data,")
            println(io, "           mxGetNumberOfElements(out) * sizeof(", ctype, "));")
            kind.owns && println(io, "    jlw_release(carrier.data);")
        elseif kind.kind === :string
            println(io, "    /* `mxCreateString` takes a C string, so an embedded NUL")
            println(io, "       truncates. Julia permits them; this is documented. */")
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
            println(io, "            int digit = c >= '0' && c <= '9';")
            println(io, "            ok = alpha || c == '_' || (j > 0 && digit);")
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
            println(io, "        mxArray *field = mxCreateNumericMatrix(1, 1, ", _matlab_class_id(kind.class), ", mxREAL);")
            println(io, "        *", _matlab_accessor(kind.class), "(field) = (", ctype, ")carrier.values[i];")
            println(io, "        mxSetFieldByNumber(out, 0, (int)i, field);")
            println(io, "    }")
            if kind.owns
                println(io, "    jlw_release_strings(carrier.keys, carrier.length);")
                println(io, "    jlw_release(carrier.values);")
            end
        elseif kind.kind === :opt
            println(io, "    if (carrier.has_value == 0) {")
            println(io, "        return mxCreateNumericMatrix(0, 0, ", _matlab_class_id(kind.class), ", mxREAL);")
            println(io, "    }")
            println(io, "    mxArray *out = mxCreateNumericMatrix(1, 1, ", _matlab_class_id(kind.class), ", mxREAL);")
            println(io, "    *", _matlab_accessor(kind.class), "(out) = carrier.value;")
        elseif kind.kind === :scalar
            println(io, "    mxArray *out = mxCreateNumericMatrix(1, 1, ", _matlab_class_id(kind.class), ", mxREAL);")
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
    inner.kind === :void && println(io, "    (void)plhs;")
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
    println(io, "    ", names.result, " result =")
    println(io, "        ((", names.result, " (*)(", signature, "))jlw_symbol(\"", symbol, "\"))(", arguments, ");")

    # On a failure the value is zero-filled, so nothing is held while this
    # raises; that is what lets the check come before any conversion.
    ret = plan.ret
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

A caller may request fewer outputs than a declaration produces. Every element
is converted regardless, because conversion is also what releases Julia's
storage for it; an element the caller did not ask for has its `mxArray`
destroyed instead of being assigned.
"""
function _write_matlab_results(io::IO, ret, expression::AbstractString, names)
    ret.kind === :void && return nothing
    if ret.kind !== :tuple
        println(io, "    plhs[0] = jlw_out_", names.value, "(", expression, ");")
        return nothing
    end
    count = length(ret.elements)
    println(io, "    int wanted = nlhs < 1 ? 1 : nlhs;")
    println(io, "    if (wanted > ", count, ") {")
    println(io, "        mexErrMsgIdAndTxt(\"jlw:argument\", \"at most ", count, " outputs\");")
    println(io, "    }")
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

    # One helper per distinct carrier, not per use: the memory discipline for a
    # carrier then lives in a single place.
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
        elseif ret.kind !== :void
            outgoing[names.value] = ret
        end
    end
    _write_matlab_in_helpers(io, incoming)
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
    println(io, "    char *name = mxArrayToUTF8String(prhs[0]);")
    for (i, (method, _, _)) in pairs(named)
        keyword = i == 1 ? "    if" : "    } else if"
        println(io, keyword, " (strcmp(name, \"", method.symbol, "\") == 0) {")
        println(io, "        jlw_call_", method.symbol, "(nlhs, plhs, nrhs, prhs);")
    end
    if isempty(named)
        println(io, "    mexErrMsgIdAndTxt(\"jlw:argument\", \"no wrapped functions\");")
    else
        println(io, "    } else {")
        println(io, "        mexErrMsgIdAndTxt(\"jlw:argument\", \"unknown function %s\", name);")
        println(io, "    }")
    end
    println(io, "}")
    return nothing
end
