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
layout checks, and the `.onLoad` loader, while `R/facade.R` is created only if
it is absent, so the public API an author edits there survives a rebuild.

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
        return "*" * r_type_signature(typedict, type.pointee_type, typeinfo)
    elseif type isa ArrayDesc
        return r_type_signature(typedict, type.element_type, typeinfo; field) *
            "[" * string(type.count) * "]"
    else
        @assert false "unknown descriptor type"
    end
end

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
    write_wrapper(dest::RTarget, abi_info::ABIInfo)

Emit the R package described by `dest`/`abi_info`: `DESCRIPTION`, `NAMESPACE`,
`LICENSE`, `R/lowlevel.R` and, when it does not exist yet, `R/facade.R`.

`R/lowlevel.R` registers every aggregate with `cstruct()` in dependency order,
checks each computed layout against the offsets `juliac` recorded, and defines
the `.onLoad` hook that locates the shared library, resolves the exported
symbols, and records the package as loaded. The registration lines run when
the package is installed, so the type information is part of the installed
namespace. The file is written to a scratch name and renamed into place, so a
failed emission never leaves a half-written file.

`R/facade.R` is the author-editable public API. It is created only if it is
absent, so rebuilding never overwrites edits.
"""
function write_wrapper(dest::RTarget, abi_info::ABIInfo)
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
            _write_r_facade(f, dest)
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

    _write_r_loader(f, dest, entrypoints)
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

function _write_r_facade(f::IO, dest::RTarget)
    println(f, "# Public façade for the ", dest.package_name, " R package.")
    println(f, "#")
    println(f, "# JuliaLibWrapping creates this file once and never rewrites it, so")
    println(f, "# edits here survive a rebuild. R/lowlevel.R is regenerated on every")
    println(f, "# build.")
    println(f)
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
