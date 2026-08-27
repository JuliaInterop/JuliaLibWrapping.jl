"""
    ApiEntry

One `@api`-annotated function's metadata: the wrapped function's `name`, its
generated C `symbol` (which encodes the defining module, see
[`_api_symbol`](@ref)), positional `args`/keyword `kwargs`
(`(name, type)` / `(name, type, has_default, default)` tuples), return type
`ret`, and `doc`string.

A keyword's `default` is the literal value itself, already of type `type`;
`has_default` is `false` for a required keyword, and its `default` is then
`nothing`.
"""
struct ApiEntry
    name::Symbol
    symbol::String
    args::Vector{Tuple{Symbol, Type}}
    kwargs::Vector{Tuple{Symbol, Type, Bool, Any}}
    ret::Type
    doc::String
end

"""
    _API

Build-host registry of every `@api`-annotated function seen so far. Populated
by [`@api`](@ref); cleared with [`clear_api!`](@ref).
"""
const _API = ApiEntry[]

"""
    clear_api!()

Empty [`_API`](@ref). Intended for tests and for the sidecar dump subprocess,
which runs one entry file per process.
"""
clear_api!() = (empty!(_API); nothing)

"""
    _api_symbol(mod::Module, name::Symbol) -> String

The C symbol for `name` defined in `mod`: `join(fullname(mod), "_") * "_" *
name`, with a leading `Main` component stripped.
"""
function _api_symbol(mod::Module, name::Symbol)
    parts = String.(collect(fullname(mod)))
    isempty(parts) || parts[1] != "Main" || popfirst!(parts)
    return join([parts..., String(name)], "_")
end

# --- Carrier mapping: String is argument-only ------------------------------

const _API_SCALARS = Union{
    Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64,
    Float32, Float64, Bool,
}

"""
    carrier_type(::Type{T}) -> Union{Type, Nothing}

The C-ABI carrier type for `T` **as an argument**, or `nothing` if `T` has no
carrier mapping. An argument borrows the caller's storage, so every carrier
that states ownership in its type takes `:borrowed` here. See
[`carrier_return_type`](@ref) for the return position, where a freshly
allocated carrier is `:owned`.

A dictionary value, an optional payload and an array element must be a
scalar (`Int8`–`Int64`, `UInt8`–`UInt64`, `Float32`, `Float64`, `Bool`): the
carrier holds them as raw bytes behind a pointer,
which is only sound for bits types. `Vector{String}` is the exception, and
has its own carrier that copies each element.

A `Ptr{T}` is its own carrier and crosses unconverted: neither a length nor
an owner travels with it. An argument addresses memory the caller owns. A
return must address memory that outlives the call and that the caller can
already reach — a buffer it passed in, or storage the library holds onto. A
pointer into a fresh Julia allocation dangles as soon as the collector runs;
one into `Libc.malloc` memory leaks, because nothing on the far side knows to
free it.

`_API_SCALARS` is itself a `Union`, so a union *of* scalars satisfies
`T <: _API_SCALARS`. A carrier holds its payload as raw bytes at a known
size, which a union cannot supply, and `CArray`/`CDict` are `isbits`
whatever their parameter is — so the later `isbitstype` check on the carrier
cannot catch it. Every method below therefore demands a concrete payload
explicitly and returns `nothing` otherwise.

The mapping is open. A type outside this table becomes an `@api` type once
its own module adds methods for it to `carrier_type`, [`to_carrier`](@ref)
and [`from_carrier`](@ref); an `isbits` struct can be its own carrier, with
all three methods the identity.
"""
carrier_type(::Type{T}) where {T <: _API_SCALARS} = isconcretetype(T) ? T : nothing
carrier_type(::Type{Ptr{T}}) where {T} = Ptr{T}
carrier_type(::Type{String}) = CString{:borrowed}
carrier_type(::Type{Vector{String}}) = CStrArray{:borrowed}
carrier_type(::Type{Dict{String, V}}) where {V <: _API_SCALARS} =
    isconcretetype(V) ? CDict{:borrowed, V} : nothing
# `Nothing` unifies with `Union{T,Nothing} where T` (T = Union{}), which
# throws on an unbound static parameter, so it needs its own method.
# `Nothing` is return-only and has no carrier.
carrier_type(::Type{Nothing}) = nothing
carrier_type(::Type{Union{T, Nothing}}) where {T <: _API_SCALARS} =
    isconcretetype(T) ? COpt{T} : nothing
carrier_type(::Type{<:Array{T, N}}) where {T <: _API_SCALARS, N} =
    isconcretetype(T) ? CArray{:borrowed, T, N} : nothing
carrier_type(::Type) = nothing

"""
    carrier_return_type(::Type{T}) -> Union{Type, Nothing}

The C-ABI carrier type for `T` **as a return value**. The same as
[`carrier_type`](@ref) except for the carriers that state ownership in their
type: an argument borrows the caller's buffer, while a return is a fresh
Julia allocation the consumer must release, so it is `:owned`.
`Vector{String}` needs its own method: the `Array` method below is the more
specific signature and would otherwise shadow its [`CStrArray`](@ref)
carrier. The concrete-payload demand is the same as in
[`carrier_type`](@ref).
"""
carrier_return_type(::Type{Vector{String}}) = CStrArray{:owned}
carrier_return_type(::Type{Dict{String, V}}) where {V <: _API_SCALARS} =
    isconcretetype(V) ? CDict{:owned, V} : nothing
carrier_return_type(::Type{<:Array{T, N}}) where {T <: _API_SCALARS, N} =
    isconcretetype(T) ? CArray{:owned, T, N} : nothing
carrier_return_type(::Type{T}) where {T} = carrier_type(T)

"""
    _api_opt_inner(T::Type) -> Union{Type, Nothing}

`T` for an optional `Union{T,Nothing}` type, or `nothing` if `T` is not such a
union. Used at macro-expansion time to pick the return-conversion call
([`to_carrier`](@ref) vs [`to_carrier_opt`](@ref)). It avoids the
`Type{Union{T,Nothing}} where T` dispatch pattern, which also matches bare
`Nothing` (see [`carrier_type`](@ref)).
"""
function _api_opt_inner(T::Type)
    T isa Union || return nothing
    T.a === Nothing && return T.b
    T.b === Nothing && return T.a
    return nothing
end

"""
    to_carrier(x) -> carrier value

Convert a native value to its C-ABI carrier, per [`carrier_type`](@ref).
"""
to_carrier(x::_API_SCALARS) = x
to_carrier(p::Ptr) = p
# No to_carrier(::String): String returns are rejected at expansion, and
# argument CStrings are built by the caller, which Julia only reads.
to_carrier(v::Vector{String}) = CStrArray{:owned}(v)
to_carrier(d::Dict{String, V}) where {V} = CDict{:owned}(d)
to_carrier(A::AbstractArray) = CArray{:owned}(A)

"""
    to_carrier_opt(::Type{T}, x) -> COpt{T}

Convert a native `Union{T,Nothing}` value to its [`COpt{T}`](@ref) carrier.
`to_carrier` cannot dispatch on such a value, since a bare `nothing` carries
no information about `T`, so `@api` calls this for optional returns with `T`
fixed at macro-expansion time.
"""
to_carrier_opt(::Type{T}, x::T) where {T} = COpt(x)
to_carrier_opt(::Type{T}, ::Nothing) where {T} = COpt{T}(nothing)

"""
    from_carrier(::Type{T}, c) -> T

Convert a C-ABI carrier back to the native `T`.
"""
from_carrier(::Type{T}, c::T) where {T <: _API_SCALARS} = c
from_carrier(::Type{Ptr{T}}, c::Ptr{T}) where {T} = c
from_carrier(::Type{String}, c::CString) = String(c)
from_carrier(::Type{Vector{String}}, c::CStrArray) = Vector{String}(c)
from_carrier(::Type{Dict{String, V}}, c::CDict{owned, V}) where {owned, V} = Dict{String, V}(c)
from_carrier(::Type{A}, c::CArray{owned, T, N}) where {owned, T, N, A <: Array{T, N}} =
    unsafe_wrap(Array, c.data, Int.(Tuple(c.dims)); own = false)   # zero-copy view
from_carrier(::Type{Union{T, Nothing}}, c::COpt{T}) where {T} = unwrap(c)

# --- @api ----------------------------------------------------------------

# Split `f(a::T1, b::T2; k::K=dk)::Ret` into (name, positional-arg exprs,
# keyword-arg exprs, return-type expr).
function _split_api_signature(sig::Expr)
    sig.head === :where && error(
        "@api: `where` clauses are not supported; a wrapper needs one concrete " *
            "signature, so write the argument and return types out"
    )
    sig.head === :(::) ||
        error("@api: return type annotation `::Ret` is required")
    ret_expr = sig.args[2]
    call = sig.args[1]
    call isa Expr && call.head === :call ||
        error("@api expects a function definition")
    name = call.args[1]
    name isa Symbol || error("@api expects a plain function name")

    rest = call.args[2:end]
    kw_exprs = Any[]
    if !isempty(rest) && rest[1] isa Expr && rest[1].head === :parameters
        kw_exprs = rest[1].args
        rest = rest[2:end]
    end
    return name, rest, kw_exprs, ret_expr
end

# One positional argument `a::T` -> (name::Symbol, type_expr).
function _parse_api_arg(a)
    a isa Expr && a.head === :(::) && length(a.args) == 2 ||
        error("@api: positional arguments must be annotated, got `$a`")
    argname = a.args[1]
    argname isa Symbol || error("@api: positional arguments must be plain names")
    return argname, a.args[2]
end

# One keyword argument `k::K` or `k::K = default`.
# -> (name, type_expr, has_default::Bool, default_expr)
function _parse_api_kwarg(k)
    if k isa Expr && k.head === :kw
        lhs, default, has_default = k.args[1], k.args[2], true
    else
        lhs, default, has_default = k, nothing, false
    end
    lhs isa Expr && lhs.head === :(::) && length(lhs.args) == 2 ||
        error("@api: keyword arguments must be annotated, got `$k`")
    kwname = lhs.args[1]
    kwname isa Symbol || error("@api: keyword arguments must be plain names")
    return kwname, lhs.args[2], has_default, default
end

# Kwarg defaults must be literals (Int/Float/Bool/String/`nothing`), or a
# negated numeric literal (`-1`, `-1.5`). The parser folds most negated
# numbers into a literal token, but not every numeric-literal shape on every
# parser version, so `Expr(:call, :-, <number>)` is accepted as well.
_api_valid_default(x::Union{Integer, AbstractFloat, Bool, String}) = true
_api_valid_default(x::Symbol) = x === :nothing
_api_valid_default(x::Expr) =
    x.head === :call && length(x.args) == 2 && x.args[1] === :- &&
    x.args[2] isa Union{Integer, AbstractFloat}
_api_valid_default(x) = false

# The value a validated kwarg default expression denotes. `:nothing` is the
# only symbol `_api_valid_default` accepts, and the only `Expr` it accepts is
# a negated number.
_api_default_value(x::Symbol) = nothing
_api_default_value(x::Expr) = -x.args[2]
_api_default_value(x) = x

# Resolve a type expression to (native Type, carrier Type), or error naming
# the offending argument/return.
function _api_carrier_or_error(__module__::Module, fname::Symbol, label::String, texpr)
    T = Core.eval(__module__, texpr)
    T isa Type || error("@api $__module__.$fname: `$label` is not a type")
    if T === String && label == "return"
        error("@api $__module__.$fname: String returns are not supported")
    end
    C = label == "return" ? carrier_return_type(T) : carrier_type(T)
    isnothing(C) &&
        error(
        label == "return" ? "@api $__module__.$fname: return type $T has no carrier mapping" :
            "@api $__module__.$fname: argument '$label' of type $T has no carrier mapping",
    )
    # A wrapper whose body throws returns a zero-filled carrier, which
    # `_zero_carrier` can build only for an `isbits` type. Rejecting the
    # carrier here turns what would otherwise be a throw from inside the
    # wrapper's `catch` — fatal in a trimmed library, and reachable only on the
    # error path — into a macro-expansion error.
    isbitstype(C) || error(
        (
            label == "return" ? "@api $__module__.$fname: return type $T" :
                "@api $__module__.$fname: argument '$label' of type $T"
        ) *
            " maps to the carrier $C, which is not isbits. On a thrown error the wrapper " *
            "returns a zero-filled carrier, and only an isbits carrier can be zeroed."
    )
    return T, C
end

# The expression a generated wrapper's `catch` block uses to turn the caught
# exception `e` into a status message. `ErrorException`, `ArgumentError` and
# `DimensionMismatch` each carry a `msg::String`; anything else reports
# `"error"`. The `isa` chain keeps the code trim-safe: `e` is typed `Any` in a
# `catch`, and only a narrowing `isa` makes the field access concrete.
_api_message_expr() = quote
    let
        m::String = "error"
        if e isa Base.ErrorException
            em = e.msg
            if em isa String
                m = em
            end
        elseif e isa Base.ArgumentError
            am = e.msg
            if am isa String
                m = am
            end
        elseif e isa Base.DimensionMismatch
            dm = e.msg
            if dm isa String
                m = dm
            end
        end
        m
    end
end

"""
    @api [docstring] function name(a::T1, ...; k::K = default, ...)::Ret
        body
    end

Mark a plain Julia function as a JuliaLibWrapping API entry point. Leaves the
function unchanged; additionally generates a `Base.@ccallable` C-ABI wrapper
(named per [`_api_symbol`](@ref)) that converts arguments/return value
through [`carrier_type`](@ref)/[`carrier_return_type`](@ref)/[`to_carrier`](@ref)/[`from_carrier`](@ref)
and reports errors via [`JLWResult`](@ref)/[`JLWStatus`](@ref); and records
an [`ApiEntry`](@ref) in [`_API`](@ref).

Every argument and the return type must resolve (via `Core.eval` in the
defining module) to a type with a carrier mapping; a `String`
return is rejected. Types are resolved at macro-expansion time, so any
alias used in the signature must already be defined. Keyword defaults must be
literals (`Int`, `Float`, `Bool`, `String`, or `nothing`) of the keyword's
declared type: `k::Float64 = 2` is rejected, `k::Float64 = 2.0` is accepted.
"""
macro api(args...)
    if length(args) == 2
        doc, fn = args
        doc isa String || error("@api: the docstring argument must be a string literal")
    elseif length(args) == 1
        doc, fn = "", args[1]
    else
        error("@api expects `[docstring] function ... end`")
    end
    if !(fn isa Expr && fn.head === :function)
        fn isa Expr && fn.head === :(=) && error(
            "@api: the assignment form `f(x) = ...` is not supported; write " *
                "`function f(x) ... end`"
        )
        error("@api expects a function definition")
    end

    sig = fn.args[1]
    name, arg_exprs, kw_exprs, ret_expr = _split_api_signature(sig)

    arg_names = Symbol[]
    arg_types = Type[]
    arg_carriers = Type[]
    args_meta = Expr(:vect)
    for a in arg_exprs
        aname, texpr = _parse_api_arg(a)
        T, C = _api_carrier_or_error(__module__, name, String(aname), texpr)
        push!(arg_names, aname)
        push!(arg_types, T)
        push!(arg_carriers, C)
        push!(args_meta.args, :(($(QuoteNode(aname)), $T)))
    end

    kw_names = Symbol[]
    kw_types = Type[]
    kw_carriers = Type[]
    kwargs_meta = Expr(:vect)
    for k in kw_exprs
        kname, texpr, has_default, default = _parse_api_kwarg(k)
        T, C = _api_carrier_or_error(__module__, name, String(kname), texpr)
        default_value = nothing
        if has_default
            _api_valid_default(default) ||
                error("@api $__module__.$name: keyword '$kname' default must be a literal")
            default_value = _api_default_value(default)
            default_value isa T || error(
                "@api $__module__.$name: keyword '$kname' is declared ::$T but its " *
                    "default $(repr(default_value)) is a $(typeof(default_value))"
            )
        end
        push!(kw_names, kname)
        push!(kw_types, T)
        push!(kw_carriers, C)
        push!(kwargs_meta.args, :(($(QuoteNode(kname)), $T, $has_default, $(QuoteNode(default_value)))))
    end

    ret_type = Core.eval(__module__, ret_expr)
    ret_type isa Type || error("@api $__module__.$name: `return` is not a type")
    is_void = ret_type === Nothing
    ret_opt_inner = is_void ? nothing : _api_opt_inner(ret_type)
    ret_carrier = is_void ? Nothing : last(_api_carrier_or_error(__module__, name, "return", ret_expr))
    symbol = _api_symbol(__module__, name)
    # One C symbol per name, so a second `@api` method of the same function
    # would overwrite the first entry point instead of adding one.
    any(e -> e.symbol == symbol, _API) && error(
        "@api $__module__.$name: '$symbol' is already an API entry point. " *
            "A function can carry `@api` on one method only; give the second one its own name."
    )

    wrapper_args = Expr[]
    for (an, ac) in zip(arg_names, arg_carriers)
        push!(wrapper_args, :($an::$ac))
    end
    for (kn, kc) in zip(kw_names, kw_carriers)
        push!(wrapper_args, :($kn::$kc))
    end

    call_args = [:(JLWInterop.from_carrier($(arg_types[i]), $(arg_names[i]))) for i in eachindex(arg_names)]
    call_kwargs = [Expr(:kw, kw_names[i], :(JLWInterop.from_carrier($(kw_types[i]), $(kw_names[i])))) for i in eachindex(kw_names)]
    call_expr = isempty(call_kwargs) ? :($name($(call_args...))) :
        :($name($(call_args...); $(call_kwargs...)))

    ccallable_name = Symbol(symbol)
    to_carrier_call = isnothing(ret_opt_inner) ? :(JLWInterop.to_carrier($call_expr)) :
        :(JLWInterop.to_carrier_opt($ret_opt_inner, $call_expr))

    wrapper = if is_void
        quote
            Base.@ccallable function $ccallable_name($(wrapper_args...))::JLWInterop.JLWStatus
                try
                    $call_expr
                    JLWInterop.jlw_ok()
                catch e
                    JLWInterop.jlw_error(1, $(_api_message_expr()))
                end
            end
        end
    else
        quote
            Base.@ccallable function $ccallable_name($(wrapper_args...))::JLWInterop.JLWResult{$ret_carrier}
                try
                    JLWInterop.jlw_ok($to_carrier_call)
                catch e
                    JLWInterop.jlw_error(1, $(_api_message_expr()), $ret_carrier)
                end
            end
        end
    end

    registration = :(
        push!(
            JLWInterop._API,
            JLWInterop.ApiEntry(
                $(QuoteNode(name)), $symbol,
                $args_meta, $kwargs_meta, $ret_type, $doc,
            ),
        )
    )

    # `Base.@__doc__` marks which definition a docstring written above the
    # `@api` call binds to. Without it the docsystem has nothing to attach to
    # in the returned block and the function is undocumented in Julia as well
    # as in Python.
    return esc(
        quote
            Base.@__doc__ $fn
            $wrapper
            $registration
            nothing
        end
    )
end

# --- write_metadata --------------------------------------------------------

# Escape `"`, `\`, and control bytes for a JSON string body.
function _json_escape(s::AbstractString)
    io = IOBuffer()
    for c in s
        if c == '"'
            write(io, "\\\"")
        elseif c == '\\'
            write(io, "\\\\")
        elseif c == '\n'
            write(io, "\\n")
        elseif c == '\r'
            write(io, "\\r")
        elseif c == '\t'
            write(io, "\\t")
        elseif iscntrl(c)
            write(io, "\\u", lpad(string(UInt32(c); base = 16), 4, '0'))
        else
            write(io, c)
        end
    end
    return String(take!(io))
end

_json_str(s::AbstractString) = "\"" * _json_escape(s) * "\""

# A kwarg default as a JSON value of its own type. `Bool` is matched before
# `Integer` because `Bool <: Integer`.
_json_value(x::Bool) = x ? "true" : "false"
_json_value(x::Integer) = string(x)
function _json_value(x::AbstractFloat)
    isfinite(x) || error("keyword default $x has no JSON representation")
    return string(x)
end
_json_value(x::AbstractString) = _json_str(x)
_json_value(::Nothing) = "null"

"""
    write_metadata(path::AbstractString)

Write the JSON metadata sidecar for every [`@api`](@ref)-annotated function
recorded so far (in [`_API`](@ref)) to `path`:

    {"jlw_metadata_version": 1, "exports": {symbol: {"name", "args", "kwargs", "doc"}}}

`exports` entries are sorted by symbol for stable output. `args` is the
positional argument names, in declaration order. `kwargs` is a list of
`{"name": ...}` for a required keyword-only argument (see [`ApiEntry`](@ref))
or `{"name": ..., "default": ...}` for one with a default, written as a JSON
value of its own type: a number, a JSON string, `true`/`false`, or `null`.
Types are not repeated here: they live in the separate ABI JSON that
`juliac` produces, keyed by the same symbol.

The JSON is written by hand so that JLWInterop needs no JSON dependency.
"""
function write_metadata(path::AbstractString)
    entries = sort(_API; by = e -> e.symbol)
    io = IOBuffer()
    write(io, "{\n  \"jlw_metadata_version\": 1,\n  \"exports\": {\n")
    for (i, e) in enumerate(entries)
        write(io, "    ", _json_str(e.symbol), ": {\n")
        write(io, "      \"name\": ", _json_str(String(e.name)), ",\n")
        arg_strs = [_json_str(String(a[1])) for a in e.args]
        write(io, "      \"args\": [", join(arg_strs, ", "), "],\n")
        kw_strs = map(e.kwargs) do (kname, _, has_default, default)
            has_default ?
                "{\"name\": $(_json_str(String(kname))), \"default\": $(_json_value(default))}" :
                "{\"name\": $(_json_str(String(kname)))}"
        end
        write(io, "      \"kwargs\": [", join(kw_strs, ", "), "],\n")
        write(io, "      \"doc\": ", _json_str(e.doc), "\n")
        write(io, "    }", i < length(entries) ? "," : "", "\n")
    end
    write(io, "  }\n}\n")
    open(path, "w") do f
        write(f, take!(io))
    end
    return nothing
end
