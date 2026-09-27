"""
    RTarget(dir, package_name, library_basename;
            bundle_subdir = nothing, version = $(repr(_DEFAULT_PACKAGE_VERSION)),
            privatized = false)

Output configuration for an R package that calls a JuliaLibWrapping-compiled
shared library through [rdyncall](https://CRAN.R-project.org/package=rdyncall).
`dir` is the directory into which the package is written; a sub-directory
named `package_name` holds the package that `R CMD INSTALL` installs.
`library_basename` is the shared library's basename without an OS-specific
suffix (e.g. `"boundary"`, loaded from `boundary.so`, `boundary.dylib` or
`boundary.dll` depending on the host).

The emitted package keeps the same split as the Python target: `R/lowlevel.R`
is rewritten on every build and holds the rdyncall type registrations, the
layout checks, the `JLWStatus` condition helpers, one binding per entrypoint
and the `.onLoad` loader, while `R/facade.R` is created only if it is absent,
so the public API an author edits there survives a rebuild. The façade wraps
scalar entrypoints — and, for an `@api` declaration, any entrypoint whose
carrier values pass through unchanged — and gives an `@api` keyword its
sidecar default.

`package_name` must be a legal R package name: it starts with a letter, then
takes letters, digits and periods, and does not end in a period. The
constructor rejects anything else.

When `bundle_subdir` is a string (e.g. `"bundle"`), the emitter assumes the
shared library and its juliac runtime closure will be laid out under that
subdirectory of the installed package in the standard `--bundle` shape
(`<bundle_subdir>/lib/<lib>`, `<bundle_subdir>/lib/julia/`,
`<bundle_subdir>/artifacts/`). The generated loader searches there first, so
the embedded `RUNPATH` resolves `libjulia` from inside the tree. The default
`nothing` preserves the flat single-`.so`-beside-the-package layout.

`version` sets the `Version` field of the generated `DESCRIPTION`.

`privatized` records whether the bundle carries a salted `libjulia`. A package
without one warns when another JuliaLibWrapping-generated R package is already
loaded, as the Python target does. Pass it when emitting for a bundle built
elsewhere; a build that produces its own bundle sets it from `privatize`.
"""
struct RTarget <: AbstractTarget
    dir::String
    package_name::String
    library_basename::String
    bundle_subdir::Union{Nothing, String}
    version::String
    privatized::Bool
end

RTarget(
    dir::AbstractString, package_name::AbstractString,
    library_basename::AbstractString; bundle_subdir = nothing,
    version::AbstractString = _DEFAULT_PACKAGE_VERSION,
    privatized::Bool = false
) = begin
    name = String(package_name)
    _check_r_package_name(name)
    isempty(version) &&
        throw(ArgumentError("RTarget version must not be empty"))
    RTarget(
        String(dir), name, String(library_basename),
        bundle_subdir === nothing ? nothing : String(bundle_subdir),
        String(version), privatized
    )
end

function Base.show(io::IO, t::RTarget)
    print(
        io, "RTarget(", repr(t.dir), ", ", repr(t.package_name),
        ", ", repr(t.library_basename)
    )
    t.bundle_subdir === nothing || print(io, "; bundle_subdir = ", repr(t.bundle_subdir))
    t.version == _DEFAULT_PACKAGE_VERSION || print(io, "; version = ", repr(t.version))
    t.privatized && print(io, "; privatized = true")
    return print(io, ")")
end

# R package names are what `R CMD INSTALL` and `library()` accept: a letter,
# then letters, digits and periods, with no trailing period.
function _check_r_package_name(name::AbstractString)
    occursin(r"^[A-Za-z][A-Za-z0-9.]*$", name) ||
        throw(
        ArgumentError(
            "R package name $(repr(String(name))) must start with a letter and " *
                "contain only letters, digits and periods"
        )
    )
    endswith(name, ".") &&
        throw(
        ArgumentError(
            "R package name $(repr(String(name))) must not end with a period"
        )
    )
    return nothing
end

"""
    R_KEYWORDS :: Set{String}

The words R reserves. [`sanitize_r_name`](@ref) gives one an `_` suffix, so a
function or field declared with such a name stays callable.
"""
const R_KEYWORDS = Set{String}(
    [
        "if", "else", "repeat", "while", "function", "for", "in", "next",
        "break", "TRUE", "FALSE", "NULL", "Inf", "NaN", "NA",
        "NA_integer_", "NA_real_", "NA_character_", "NA_complex_",
    ]
)

"""
    sanitize_r_name(name) -> String

Return an R identifier for `name`. An R identifier starts with a letter (the
leading `.` form is deliberately avoided, since `exportPattern("^[^.]")`
leaves such a name unexported), then takes letters, digits, periods and
underscores. A [`sanitize_for_c`](@ref) result that starts with anything else
gets an `x` prefix — Julia names a tuple field by its position, so `"1"`
becomes `"x_1"` — and a reserved word gets an `_` suffix.
"""
function sanitize_r_name(name::AbstractString)
    sanitized = sanitize_for_c(name)
    isempty(sanitized) && return "x"
    isletter(first(sanitized)) || (sanitized = "x" * sanitized)
    sanitized in R_KEYWORDS && (sanitized *= "_")
    return sanitized
end

"""
    rtypes :: Dict{String, String}

Map from Julia primitive type name (as it appears in a `PrimitiveTypeDesc`'s
`name` field) to the rdyncall type signature token, as the rdyncall
documentation lists them: `c`/`C` for the 8-bit integers, `s`/`S` for the
16-bit, `i`/`I` for the 32-bit, `l`/`L` for the 64-bit, `f`/`d` for the
floats, and `B` for `Bool`.

The platform-aliased C names at the end never appear in an auto-exported ABI;
they are listed because a hand-written declaration may mention them. `j` is
C `long` and `J` its unsigned form, which are 64-bit on every platform
JuliaLibWrapping targets. `Cwstring`/`Cwchar_t` have no rdyncall token and are
rejected.
"""
const rtypes = Dict{String, String}(
    "Int8" => "c", "Int16" => "s", "Int32" => "i", "Int64" => "l",
    "UInt8" => "C", "UInt16" => "S", "UInt32" => "I", "UInt64" => "L",
    "Float32" => "f", "Float64" => "d",
    "Bool" => "B",
    "RawFD" => "i",
    "Cchar" => "c", "Cshort" => "s", "Cint" => "i", "Clong" => "j",
    "Cushort" => "S", "Cuint" => "I", "Culong" => "J",
    "Cssize_t" => "j", "Csize_t" => "J",
    "Cstring" => "Z",
    "Cvoid" => "v",
)

"""
    _r_primitive_token(name; field = false) -> String

The rdyncall type signature token for the primitive `name`. With `field = true`
a `Bool` is emitted as `C` instead of `B`: rdyncall lays a `B` *field* out as
8 bytes while the compiled library uses C's one-byte `_Bool`, so the field is
registered as the matching one-byte `unsigned char` and converted in R. The
generated layout checks confirm the substitution, and a divergence stops the
package from loading.
"""
function _r_primitive_token(name::AbstractString; field::Bool = false)
    field && name == "Bool" && return "C"
    token = get(rtypes, name, nothing)
    isnothing(token) && error("unsupported primitive type for R: '$(name)'")
    field && token == "v" && error("a `Cvoid` struct field is not representable in R")
    return token
end

"""
    mangle_r_type!(typedict, id, typeinfo) -> String

Register and return the R name for the struct `id`: `sanitize_r_name` of its
Julia name, with a `_<id>` suffix when that already names another type in
`typedict`. This is the name a `cstruct()` call registers the type under and
the name [`r_type_signature`](@ref) wraps in `<...>`.

Results are memoized in `typedict`, which also supplies the collision pool, so
the caller must pre-mangle every struct in declaration order to keep suffix
allocation independent of first textual reference.
"""
function mangle_r_type!(
        typedict::Dict{Int, String}, id::Int,
        typeinfo::OrderedDict{Int, TypeDesc}
    )
    if id in keys(typedict)
        return typedict[id]
    end
    type = typeinfo[id]
    type isa StructDesc ||
        error("only structs get R type names; type $id is a $(nameof(typeof(type)))")
    mangled = sanitize_r_name(type.name)
    if mangled in values(typedict)
        suffix = id
        extended = mangled * "_" * string(suffix)
        while extended in values(typedict)
            suffix += 1
            extended = mangled * "_" * string(suffix)
        end
        mangled = extended
    end
    typedict[id] = mangled
    return mangled
end

"""
    r_type_signature(typedict, type_id, typeinfo; field = false) -> String

The rdyncall type signature for `type_id`, as the rdyncall manual spells them:
a primitive token, `<Name>` for a struct passed by value, `p` for an untyped
pointer, `*<signature>` for a typed one, and `<signature>[N]` for a fixed-size
array. A `nothing` `type_id` is a `void` return.

With `field = true`, `Bool` becomes the one-byte `C` field token; see
[`_r_primitive_token`](@ref).
"""
function r_type_signature(
        typedict::Dict{Int, String}, @nospecialize(type_id::Union{Int, Nothing}),
        typeinfo::OrderedDict{Int, TypeDesc}; field::Bool = false
    )
    type_id === nothing && return "v"
    type = typeinfo[type_id]
    if type isa PrimitiveTypeDesc
        return _r_primitive_token(type.name; field)
    elseif type isa StructDesc
        return "<" * mangle_r_type!(typedict, type_id, typeinfo) * ">"
    elseif type isa PointerDesc
        type.pointee_type === nothing && return "p"
        pointee = typeinfo[type.pointee_type]
        if pointee isa PrimitiveTypeDesc
            pointee.name == "Cvoid" && return "p"
            return "*" * _r_primitive_token(pointee.name; field)
        elseif pointee isa StructDesc
            return "*<" * mangle_r_type!(typedict, type.pointee_type, typeinfo) * ">"
        end
        # rdyncall has no typed form for a pointer to a pointer or to an
        # array; the untyped pointer token has the same ABI.
        return "p"
    elseif type isa ArrayDesc
        return r_type_signature(typedict, type.element_type, typeinfo; field) *
            "[" * string(type.count) * "]"
    else
        @assert false "unknown descriptor type"
    end
end

"""
    _r_call_token(typedict, type_id, typeinfo) -> Union{Nothing, String}

The rdyncall type signature token for a function argument or return of type
`type_id`: a primitive token, `<Name>` for a struct passed by value, `p` for
an untyped pointer and `*<token>` for a typed one. A pointer to a pointer or
to an array has no typed form in rdyncall, so it falls back to `p`, which has
the same ABI.

`nothing` means the type has no rdyncall token, so the entrypoint gets no
low-level binding. A `Cvoid` argument is one such case: only a return may be
`v`.
"""
function _r_call_token(
        typedict::Dict{Int, String}, type_id::Int,
        typeinfo::OrderedDict{Int, TypeDesc}
    )
    type = typeinfo[type_id]
    if type isa PrimitiveTypeDesc
        (type.name == "Cvoid" || !haskey(rtypes, type.name)) && return nothing
        return rtypes[type.name]
    elseif type isa StructDesc
        return "<" * mangle_r_type!(typedict, type_id, typeinfo) * ">"
    elseif type isa PointerDesc
        type.pointee_type === nothing && return "p"
        pointee = typeinfo[type.pointee_type]
        if pointee isa PrimitiveTypeDesc
            (pointee.name == "Cvoid" || !haskey(rtypes, pointee.name)) && return "p"
            return "*" * rtypes[pointee.name]
        elseif pointee isa StructDesc
            return "*<" * mangle_r_type!(typedict, type.pointee_type, typeinfo) * ">"
        end
        return "p"
    end
    # A bare array is not a C parameter or return type, so a descriptor that
    # reaches here cannot be called.
    return nothing
end

"""
    _r_call_signature(method, typeinfo, typedict) -> Union{Nothing, String}

The rdyncall call signature for `method`, `"<argument tokens>)<return token>"`
(for example `"ii)d"`), or `nothing` when a type has no rdyncall token.
Variadic entrypoints get no binding: dyncall needs the call-site argument
types, which the ABI does not record.

The signature is safety-critical — a mismatch crashes the R process rather
than raising an R error — so it is generated from the same tables as the
field tokens and covered by tests.
"""
function _r_call_signature(
        method::MethodDesc, typeinfo::OrderedDict{Int, TypeDesc},
        typedict::Dict{Int, String}
    )
    tokens = String[]
    for arg in method.args
        arg.isva && return nothing
        token = _r_call_token(typedict, arg.type, typeinfo)
        token === nothing && return nothing
        push!(tokens, token)
    end
    ret = method.return_type === nothing ? "v" :
        _r_call_token(typedict, method.return_type, typeinfo)
    ret === nothing && return nothing
    return join(tokens) * ")" * ret
end

"""
    _r_classify_arg(type_id, typeinfo) -> NamedTuple

Classify an entrypoint argument for the façade. The R target knows scalars
only: a primitive classifies `:scalar`, and everything else — a carrier, a
status, a raw pointer — is `:opaque`, which only an `@api` entry may pass
through unchanged (see [`_r_facade_plan`](@ref)).

A scalar argument is forwarded to dyncall as it stands: rdyncall accepts an R
integer, double, logical or raw for a numeric token and a character for `Z`.
"""
function _r_classify_arg(type_id::Int, typeinfo::OrderedDict{Int, TypeDesc})
    desc = typeinfo[type_id]
    desc isa PrimitiveTypeDesc && return (kind = :scalar,)
    return (; kind = :opaque, reason = "argument has type `$(desc.name)`")
end

"""
    _r_classify_return(type_id, typeinfo; pass_opaque = false) -> NamedTuple

Classify an entrypoint return for the façade. `kind` is one of:

- `:void` — no return at all; the wrapper returns `invisible(NULL)`
- `:status` — a bare `JLWStatus`; the same, after the status check
- `:scalar` — a primitive
- `:result` — a `JLWResult{C}`; `inner` is this classification applied to `C`
- `:opaque` — anything else, which makes the entrypoint skip the façade
- `:passthrough` — an opaque return for an `@api` entry, which the façade
  forwards unchanged

`pass_opaque` is `true` for an `@api` entry, whose raw carrier values the
caller may pass and receive until the idiomatic conversions exist. The
low-level binding always classifies with `pass_opaque = true`, since it must
decide only whether to check a status.
"""
function _r_classify_return(
        type_id::Union{Int, Nothing}, typeinfo::OrderedDict{Int, TypeDesc};
        pass_opaque::Bool = false
    )
    type_id === nothing && return (kind = :void,)
    desc = typeinfo[type_id]
    if desc isa PrimitiveTypeDesc
        (desc.name != "Cvoid" && haskey(rtypes, desc.name)) && return (kind = :scalar,)
        return pass_opaque ? (kind = :passthrough,) : (
            kind = :opaque,
            reason = "return type `$(desc.name)` has no rdyncall token",
        )
    end
    if desc isa StructDesc
        result = jlwresult_struct_info(desc, typeinfo)
        if !isnothing(result)
            inner = _r_classify_return(result.value_type_id, typeinfo; pass_opaque)
            return (kind = :result, inner = inner)
        end
        is_jlwstatus_struct(desc, typeinfo) && return (kind = :status,)
    end
    return pass_opaque ? (kind = :passthrough,) : (
        kind = :opaque,
        reason = "return type `$(desc.name)` is not a scalar",
    )
end

"""
    _r_entry_name(method, api_entry) -> String

The public name a façade is written under: the sidecar's name, sanitized, or
the exported symbol.
"""
function _r_entry_name(method::MethodDesc, api_entry)
    isnothing(api_entry) && return sanitize_r_name(method.symbol)
    return sanitize_r_name(String(get(api_entry, "name", method.symbol)))
end

"""
    _r_arg_names(method, api_entry) -> (positional, keywords)

The façade's argument names, sanitized for R: the sidecar's when it has them
and the ABI's otherwise. Positional and keyword names share one namespace in
an R signature, so a sanitizing collision is suffixed rather than silently
shadowing.
"""
function _r_arg_names(method::MethodDesc, api_entry)
    seen = Set{String}()
    if isnothing(api_entry)
        names = String[sanitize_r_name(a.name) for a in method.args]
        return (_uniquify!(names, seen), String[])
    end
    positional = String[sanitize_r_name(n) for n in get(api_entry, "args", [])]
    keywords = String[
        sanitize_r_name(kw["name"]) for kw in get(api_entry, "kwargs", [])
    ]
    return (_uniquify!(positional, seen), _uniquify!(keywords, seen))
end

"""
    _r_facade_plan(method, typeinfo, api_entry, api_enums) -> NamedTuple

Decide whether an entrypoint gets an R façade wrapper, and gather what writing
one needs. `kind` is `:auto` when every argument and the return are mapped — or
pass through unchanged for an `@api` entry — and `:skip` otherwise, with a
`reason`. A skipped entrypoint is still exposed, as a forwarder to its
low-level binding.

`pass_opaque` follows the Python target: an `@api` declaration may pass carriers
and raw pointers through as the values the low-level binding expects, while an
undeclared entrypoint is only wrapped when every type is a scalar. Enums are
not converted yet, so an enum-annotated entry is skipped rather than emitted
with a default that would not coerce.
"""
function _r_facade_plan(
        method::MethodDesc, typeinfo::OrderedDict{Int, TypeDesc},
        api_entry = nothing, api_enums::AbstractDict = Dict{String, Any}()
    )
    pass_opaque = !isnothing(api_entry)
    name = _r_entry_name(method, api_entry)
    skip(reason) = (kind = :skip, reason = reason, name = name)
    args = [_r_classify_arg(a.type, typeinfo) for a in method.args]
    for (i, a) in pairs(args)
        a.kind === :opaque && !pass_opaque &&
            return skip("argument $i: " * a.reason)
    end
    ret = _r_classify_return(method.return_type, typeinfo; pass_opaque)
    ret.kind === :result && ret.inner.kind === :opaque && !pass_opaque &&
        return skip("return: " * ret.inner.reason)
    ret.kind === :opaque && return skip("return: " * ret.reason)

    positional, keywords = _r_arg_names(method, api_entry)
    length(positional) + length(keywords) == length(args) || return skip(
        "the sidecar names $(length(positional) + length(keywords)) " *
            "arguments but the ABI has $(length(args))"
    )
    defaults = isnothing(api_entry) ? Any[] : Any[
        haskey(kw, "default") ? Some(kw["default"]) : nothing
        for kw in get(api_entry, "kwargs", [])
    ]
    if !isnothing(api_entry)
        arg_enums = get(api_entry, "arg_enums", nothing)
        if !isnothing(arg_enums) && !isempty(arg_enums)
            return skip("enum arguments need the R target's enum support")
        end
        return_enum = get(api_entry, "return_enum", nothing)
        isnothing(return_enum) ||
            return skip("enum returns need the R target's enum support")
    end
    return (;
        kind = :auto, args, ret, positional, keywords, defaults, name,
        doc = isnothing(api_entry) ? "" : String(get(api_entry, "doc", "")),
    )
end

"""
    _api_kwarg_default_r(value) -> String

Write an `@api` keyword argument default, as parsed from the metadata
sidecar's JSON, in R syntax. A string is re-quoted for R; every other JSON
scalar spells the same literal in R. The sidecar carries only numbers,
strings, booleans and `null`.

An integer is written without a trailing `L`: dyncall accepts a double for
every integer token, and R has no 64-bit integer for a large `Int64` default
anyway.
"""
_api_kwarg_default_r(v::Bool) = v ? "TRUE" : "FALSE"
_api_kwarg_default_r(::Nothing) = "NULL"
_api_kwarg_default_r(v::Integer) = string(v)
_api_kwarg_default_r(v::AbstractFloat) = string(v)
_api_kwarg_default_r(v::AbstractString) = _r_string(v)
_api_kwarg_default_r(v) =
    error("unsupported `@api` keyword default in the metadata sidecar: $(repr(v))")

"""
    _r_lowlevel_name(symbol) -> String

The internal R name of an entrypoint's binding: `.jlr_` plus the sanitized
symbol. The `.jlr_` prefix keeps it out of `exportPattern("^[^.]")`.
"""
_r_lowlevel_name(symbol::AbstractString) = ".jlr_" * sanitize_r_name(symbol)

# The field names a `cstruct()` signature lists, sanitized to R identifiers
# and made unique. Numeric Julia tuple field names become `x_1`, `x_2`, ....
function _r_field_names(desc::StructDesc)
    return _uniquify!([sanitize_r_name(field.name) for field in desc.fields], Set{String}())
end

# `struct-name { field-types } field-names ;`, the rdyncall structure type
# signature. Fields are concatenated with no separator; an array field carries
# its own `[N]` suffix.
function _r_struct_signature(
        id::Int, desc::StructDesc, typeinfo::OrderedDict{Int, TypeDesc},
        typedict::Dict{Int, String}
    )
    fields = join(
        (
            r_type_signature(typedict, field.type, typeinfo; field = true)
                for field in desc.fields
        )
    )
    return mangle_r_type!(typedict, id, typeinfo) * "{" * fields * "}" *
        join(_r_field_names(desc), " ") * ";"
end

# Emit an R double-quoted string literal.
function _r_string(s::AbstractString)
    return "\"" * replace(String(s), "\\" => "\\\\", "\"" => "\\\"") * "\""
end

"""
    write_wrapper(dest::RTarget, abi_info::ABIInfo;
                  api_metadata = Dict{String, Any}(), api_enums = Dict{String, Any}())

Emit the R package described by `dest`/`abi_info`: `DESCRIPTION`, `NAMESPACE`,
`LICENSE`, `R/lowlevel.R` and, when it does not exist yet, `R/facade.R`.

`R/lowlevel.R` registers every aggregate with `cstruct()` in dependency order,
checks each computed layout against the offsets `juliac` recorded, defines the
helpers that read a `JLWStatus` and raise a condition, binds every entrypoint
whose types have a dyncall token, and defines the `.onLoad` hook that locates
the shared library, resolves the exported symbols, and records the package as
loaded. The registration lines run when the package is installed, so the type
information is part of the installed namespace. The file is written to a
scratch name and renamed into place, so a failed emission never leaves a
half-written file.

`R/facade.R` is the author-editable public API. It is created only if it is
absent, so rebuilding never overwrites edits. An entrypoint whose arguments
and return are scalars — or, for an `@api` entry, which pass through raw —
gets a wrapper; anything else is exposed as a forwarder to its low-level
binding with a `TODO` comment.

`api_metadata` is the `exports` map from an `@api` metadata sidecar (see
[`read_api_metadata`](@ref)), keyed by C symbol. A symbol present there takes
its wrapper's name, argument names, keyword defaults and doc comment from the
sidecar entry. A symbol absent from `api_metadata` (the default is an empty
`Dict`) gets the mechanical, ABI-derived shape. `api_enums` is the sidecar's
`enums` table, carried for the enum conversion a later phase adds.
"""
function write_wrapper(
        dest::RTarget, abi_info::ABIInfo;
        api_metadata::AbstractDict = Dict{String, Any}(),
        api_enums::AbstractDict = Dict{String, Any}()
    )
    (; typeinfo) = abi_info

    pkgdir = joinpath(dest.dir, dest.package_name)
    rdir = joinpath(pkgdir, "R")
    mkpath(rdir)

    # Pre-mangle every struct in declaration order so that collision-suffix
    # allocation does not depend on the order of first textual reference.
    typedict = Dict{Int, String}()
    for (id, type) in pairs(typeinfo)
        type isa StructDesc && mangle_r_type!(typedict, id, typeinfo)
    end

    _write_atomically(joinpath(rdir, "lowlevel.R"), rdir) do f
        _write_r_lowlevel(f, dest, abi_info, typedict)
    end

    facade_path = joinpath(rdir, "facade.R")
    if !isfile(facade_path)
        _write_atomically(facade_path, rdir) do f
            _write_r_facade(f, dest, abi_info, typedict, api_metadata, api_enums)
        end
    end

    _write_r_description(joinpath(pkgdir, "DESCRIPTION"), dest)
    _write_r_namespace(joinpath(pkgdir, "NAMESPACE"))
    _write_r_license(joinpath(pkgdir, "LICENSE"))
    return nothing
end

function _write_r_lowlevel(
        f::IO, dest::RTarget, abi_info::ABIInfo, typedict::Dict{Int, String}
    )
    (; entrypoints, typeinfo) = abi_info

    println(f, "# Auto-generated by JuliaLibWrapping. Do not edit by hand.")
    println(f, "#")
    println(f, "# Low-level bindings for the ", dest.library_basename, " shared library.")
    println(f, "# R/facade.R holds the public API and is created only once; this file is")
    println(f, "# rewritten on every build.")
    println(f)

    println(f, "# Symbol pointers, resolved once by `.onLoad`.")
    println(f, ".jlr_syms <- new.env(parent = emptyenv())")
    println(f)

    _write_r_layout_check(f)
    _write_r_status_helpers(f)

    structs = [(id, desc) for (id, desc) in pairs(typeinfo) if desc isa StructDesc]
    if isempty(structs)
        println(f, "# The library declares no aggregate types.")
        println(f)
    else
        println(f, "# Foreign C aggregates, in dependency order.")
        for (id, desc) in structs
            signature = _r_struct_signature(id, desc, typeinfo, typedict)
            println(f, "cstruct(", _r_string(signature), ")")
            names = _r_field_names(desc)
            offsets = join(
                (
                    "$(names[i]) = $(desc.fields[i].offset)L"
                        for i in eachindex(desc.fields)
                ),
                ", ",
            )
            println(
                f, ".jlr_check_layout(", _r_string(typedict[id]), ", size = ",
                desc.size, "L, alignment = ", desc.alignment, "L,"
            )
            println(f, "                   offsets = c(", offsets, "))")
            println(f)
        end
    end

    _write_r_bindings(f, abi_info, typedict)
    _write_r_loader(f, dest, entrypoints)
    return nothing
end

# Condition classes for the `JLWStatus` codes, and the helpers the
# low-level bindings call. A nonzero code raises a condition whose class
# chain carries the specific category, as the MATLAB gateway's identifiers do.
function _write_r_status_helpers(f::IO)
    print(
        f, raw"""# A `JLWStatus` message is a NUL-terminated byte buffer. The layout check
# above guarantees the field is where the library put it.
.jlr_status_message <- function(status) {
  bytes <- as.raw(status$message)
  nul <- which(bytes == as.raw(0L))
  if (length(nul) > 0L) {
    bytes <- bytes[seq_len(nul[[1L]] - 1L)]
  }
  rawToChar(bytes)
}

# The R condition class for a `JLWStatus` code. An unknown code is a plain
# `jlw_error`.
.jlr_status_class <- function(code) {
  switch(
    as.character(code),
    "1" = "jlw_error",
    "2" = "jlw_argument",
    "3" = "jlw_dimension",
    "4" = "jlw_inexact",
    "5" = "jlw_bounds",
    "jlw_error"
  )
}

.jlr_abort <- function(code, msg) {
  stop(structure(
    class = c(.jlr_status_class(code), "jlw_error", "error", "condition"),
    list(message = msg, call = NULL, code = code)
  ))
}

# Raise on a failed status; a zero code is the only success.
.jlr_check_status <- function(status) {
  if (status$code != 0L) {
    .jlr_abort(status$code, .jlr_status_message(status))
  }
  invisible(NULL)
}

"""
    )
    return nothing
end

# One low-level binding per entrypoint whose types all have a dyncall token.
# The symbol is resolved lazily from `.jlr_syms`, which `.onLoad` fills, so
# nothing here runs at install time.
function _write_r_bindings(
        f::IO, abi_info::ABIInfo, typedict::Dict{Int, String}
    )
    (; entrypoints, typeinfo) = abi_info

    bindings = Tuple{MethodDesc, String, Vector{String}, NamedTuple}[]
    for method in entrypoints
        signature = _r_call_signature(method, typeinfo, typedict)
        signature === nothing && continue
        names = _uniquify!(
            [sanitize_r_name(a.name) for a in method.args], Set{String}()
        )
        ret = _r_classify_return(method.return_type, typeinfo; pass_opaque = true)
        push!(bindings, (method, signature, names, ret))
    end
    if isempty(bindings)
        println(f, "# The library exports no callable entrypoints.")
        println(f)
        return nothing
    end

    println(f, "# Low-level entrypoint bindings. Each signature string is generated")
    println(f, "# from the ABI; a mismatch would crash the R process rather than raise.")
    for (method, signature, names, ret) in bindings
        _write_r_binding(f, method, signature, names, ret)
    end
    return nothing
end

function _write_r_binding(
        f::IO, method::MethodDesc, signature::AbstractString,
        names::Vector{String}, ret
    )
    call = "dyncall(get(" * _r_string(method.symbol) * ", envir = .jlr_syms), " *
        _r_string(signature) *
        (isempty(names) ? "" : ", " * join(names, ", ")) * ")"
    println(
        f, _r_lowlevel_name(method.symbol), " <- function(", join(names, ", "), ") {"
    )
    if ret.kind === :status
        println(f, "  .jlr_result <- ", call)
        println(f, "  .jlr_check_status(.jlr_result)")
        println(f, "  invisible(NULL)")
    elseif ret.kind === :result
        println(f, "  .jlr_result <- ", call)
        println(f, "  .jlr_check_status(.jlr_result\$status)")
        println(f, "  .jlr_result\$value")
    elseif ret.kind === :void
        println(f, "  ", call)
        println(f, "  invisible(NULL)")
    else
        println(f, "  ", call)
    end
    println(f, "}")
    println(f)
    return nothing
end

# The R analogue of the Python target's import-time layout checks.
function _write_r_layout_check(f::IO)
    print(
        f, raw"""# Compare rdyncall's computed layout against the one the library was
# compiled with. A divergence would otherwise misread every field silently,
# so a mismatch stops the package from loading.
.jlr_check_layout <- function(name, size, alignment, offsets) {
  info <- get(name, envir = parent.frame())
  actual <- as.integer(info$fields$offset)
  names(actual) <- as.character(info$fields$name)
  # `as.integer` drops a vector's names, so restore them before comparing.
  expected <- as.integer(offsets)
  names(expected) <- names(offsets)
  if (info$size != size || info$align != alignment || !identical(actual, expected)) {
    stop(
      sprintf(
        paste0(
          "%s: rdyncall computed size %d, alignment %d and offsets [%s], but ",
          "the library was compiled with size %d, alignment %d and offsets ",
          "[%s]; the generated bindings do not match this platform's ABI"
        ),
        name, info$size, info$align, paste(actual, collapse = ", "),
        size, alignment, paste(expected, collapse = ", ")
      ),
      call. = FALSE
    )
  }
  invisible(NULL)
}

"""
    )
    return nothing
end

function _write_r_loader(f::IO, dest::RTarget, entrypoints::Vector{MethodDesc})
    environment = uppercase(sanitize_for_c(dest.library_basename)) * "_R_LIBRARY"

    println(f, "# The library the package loads, and where to find it.")
    println(f, ".jlr_library_basename <- ", _r_string(dest.library_basename))
    println(f, ".jlr_library_env_var <- ", _r_string(environment))
    symbols = unique(m.symbol for m in entrypoints)
    if isempty(symbols)
        println(f, ".jlr_symbols <- character(0)")
    else
        println(f, ".jlr_symbols <- c(")
        for (i, symbol) in pairs(symbols)
            comma = i == length(symbols) ? "" : ","
            println(f, "  ", _r_string(symbol), comma)
        end
        println(f, ")")
    end
    println(f)

    print(
        f, raw""".jlr_library_suffixes <- function() {
  if (.Platform$OS.type == "windows") {
    ".dll"
  } else if (identical(Sys.info()[["sysname"]], "Darwin")) {
    c(".dylib", ".so")
  } else {
    c(".so", ".dylib")
  }
}

# The directories the loader searches, in order. The shared library and its
# juliac runtime stay where they were built, so a bundle's RUNPATH resolves
# `libjulia` from inside the installed package.
.jlr_library_dirs <- function(libname, pkgname) {
  dirs <- character(0)
"""
    )
    if dest.bundle_subdir !== nothing
        println(f, "  bundle <- system.file(", _r_string(dest.bundle_subdir), ",")
        println(f, "    package = pkgname, lib.loc = libname)")
        println(f, "  if (nzchar(bundle)) {")
        println(f, "    dirs <- c(dirs, file.path(bundle, \"lib\"))")
        println(f, "  }")
    end
    print(
        f, raw"""  pkgdir <- system.file(package = pkgname, lib.loc = libname)
  if (nzchar(pkgdir)) {
    dirs <- c(dirs, pkgdir, dirname(pkgdir))
  }
  dirs
}

.jlr_resolve_library <- function(libname, pkgname) {
  override <- Sys.getenv(.jlr_library_env_var, unset = "")
  if (nzchar(override)) {
    return(override)
  }
  tried <- character(0)
  for (directory in .jlr_library_dirs(libname, pkgname)) {
    for (suffix in .jlr_library_suffixes()) {
      candidate <- file.path(directory, paste0(.jlr_library_basename, suffix))
      tried <- c(tried, candidate)
      if (file.exists(candidate)) {
        return(candidate)
      }
    }
  }
  stop(
    sprintf(
      "could not locate the %s shared library; tried %s; set %s to an explicit path",
      .jlr_library_basename, paste(tried, collapse = ", "), .jlr_library_env_var
    ),
    call. = FALSE
  )
}

.onLoad <- function(libname, pkgname) {
  handle <- dynload(.jlr_resolve_library(libname, pkgname))
  if (is.null(handle)) {
    stop(
      sprintf("could not load the %s shared library", .jlr_library_basename),
      call. = FALSE
    )
  }
  assign(".jlr_handle", handle, envir = .jlr_syms)
  for (symbol in .jlr_symbols) {
    pointer <- dynsym(handle, symbol)
    if (is.null(pointer)) {
      stop(
        sprintf("could not resolve the exported symbol %s", symbol),
        call. = FALSE
      )
    }
    assign(symbol, pointer, envir = .jlr_syms)
  }
  loaded <- getOption("jlw.loaded_r_packages", character(0))
"""
    )
    if !dest.privatized
        # Without a private libjulia the package shares whatever runtime is
        # already initialized, and the first call into whichever library did
        # not initialize it aborts the process.
        print(
            f, raw"""  if (length(loaded) > 0L && !(pkgname %in% loaded)) {
    warning(
      sprintf(
        paste0(
          "loading %s into a process that already loaded %s; this package was ",
          "built without a private libjulia, so both packages resolve a single ",
          "Julia runtime and the first call into whichever did not initialize ",
          "it aborts the process. Rebuild with `privatize = true`, or compile ",
          "both APIs into a single juliac library."
        ),
        pkgname, paste(loaded, collapse = ", ")
      ),
      call. = FALSE
    )
  }
"""
        )
    end
    print(
        f, raw"""  options(jlw.loaded_r_packages = unique(c(loaded, pkgname)))
  invisible(NULL)
}
"""
    )
    return nothing
end

function _write_r_facade(
        f::IO, dest::RTarget, abi_info::ABIInfo, typedict::Dict{Int, String},
        api_metadata::AbstractDict = Dict{String, Any}(),
        api_enums::AbstractDict = Dict{String, Any}()
    )
    (; entrypoints, typeinfo) = abi_info

    println(f, "# Public façade for the ", dest.package_name, " R package.")
    println(f, "#")
    println(f, "# JuliaLibWrapping creates this file once and never rewrites it, so")
    println(f, "# edits here survive a rebuild. R/lowlevel.R is regenerated on every")
    println(f, "# build.")
    println(f)

    # An entrypoint whose types have no dyncall token has no low-level
    # binding, so exposing it would leave a call to an undefined function.
    exposed = [
        m for m in entrypoints
            if _r_call_signature(m, typeinfo, typedict) !== nothing
    ]
    plans = [
        _r_facade_plan(m, typeinfo, get(api_metadata, m.symbol, nothing), api_enums)
            for m in exposed
    ]
    # The release entrypoints are internal plumbing, never public API.
    public = [
        (m, p) for (m, p) in zip(exposed, plans)
            if !(m.symbol in _RELEASE_ENTRYPOINT_SYMBOLS)
    ]
    if isempty(public)
        println(f, "# The library exports no entrypoints with a callable signature.")
        println(f)
        return nothing
    end

    # Two entrypoints mapping onto one public name would silently shadow
    # each other, so the build fails instead.
    claimed = Dict{String, String}()
    for (method, plan) in public
        owner = get(claimed, plan.name, nothing)
        isnothing(owner) || error(
            "the façade name `$(plan.name)` for '$(method.symbol)' is already " *
                "taken by $owner; rename the function in Julia"
        )
        claimed[plan.name] = "the entrypoint '$(method.symbol)'"
    end

    for (i, (method, plan)) in pairs(public)
        i == 1 || println(f)
        _write_r_facade_entry(f, method, plan)
    end
    return nothing
end

function _write_r_facade_entry(f::IO, method::MethodDesc, plan)
    lowlevel = _r_lowlevel_name(method.symbol)
    if plan.kind === :auto
        for line in (isempty(plan.doc) ? String[] : split(plan.doc, '\n'))
            println(f, "# ", line)
        end
        signature = String[]
        append!(signature, plan.positional)
        for (i, name) in pairs(plan.keywords)
            # R has no keyword-only parameters: a keyword is a named formal,
            # carrying the sidecar's default when it has one.
            default = plan.defaults[i]
            push!(
                signature,
                isnothing(default) ? name :
                    name * " = " * _api_kwarg_default_r(something(default))
            )
        end
        println(f, plan.name, " <- function(", join(signature, ", "), ") {")
        println(
            f, "  ", lowlevel, "(", join(vcat(plan.positional, plan.keywords), ", "), ")"
        )
        println(f, "}")
    else
        println(f, "# TODO: hand-wrap — ", plan.reason, ".")
        println(f, "# The low-level binding is exposed unchanged; see R/lowlevel.R.")
        println(f, plan.name, " <- function(...) {")
        println(f, "  ", lowlevel, "(...)")
        println(f, "}")
    end
    return nothing
end

function _write_r_description(path::AbstractString, dest::RTarget)
    open(path, "w") do f
        println(f, "Package: ", dest.package_name)
        println(f, "Type: Package")
        println(f, "Title: R Bindings for ", dest.library_basename)
        println(f, "Version: ", dest.version)
        println(f, "Authors@R: person(\"JuliaLibWrapping\", role = c(\"aut\", \"cre\"),")
        println(f, "    email = \"noreply@example.com\")")
        println(f, "Description: Generated bindings that load the ", dest.library_basename)
        println(f, "    shared library through rdyncall and expose its entry points.")
        println(f, "License: MIT + file LICENSE")
        println(f, "Encoding: UTF-8")
        println(f, "Imports: rdyncall")
    end
    return path
end

function _write_r_namespace(path::AbstractString)
    open(path, "w") do f
        println(f, "# Auto-generated by JuliaLibWrapping. Do not edit by hand.")
        println(f, "import(rdyncall)")
        println(f, "exportPattern(\"^[^.]\")")
    end
    return path
end

function _write_r_license(path::AbstractString)
    open(path, "w") do f
        println(f, "YEAR: ", Base.Libc.strftime("%Y", time()))
        println(f, "COPYRIGHT HOLDER: JuliaLibWrapping")
    end
    return path
end
