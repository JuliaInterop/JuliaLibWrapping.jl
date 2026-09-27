# Tests for `RTarget`: the emitted R package skeleton.

"""
    _r_toolchain() -> Union{String, Nothing}

The `Rscript` binary, or `nothing` when this host cannot run the R layout
checks: no `Rscript` on `PATH`, or an R that cannot load rdyncall. The checks
run whenever they can; contributing without R installed still leaves a green
suite.
"""
function _r_toolchain()
    rscript = Sys.which("Rscript")
    if isnothing(rscript)
        @info "Skipping the R layout checks (no Rscript)"
        return nothing
    end
    probe = "quit(status = !requireNamespace(\"rdyncall\", quietly = TRUE))"
    available = success(
        run(
            pipeline(`$rscript --vanilla -e $probe`; stdout = devnull, stderr = devnull);
            wait = true
        )
    )
    if !available
        @info "Skipping the R layout checks (rdyncall is not installed)"
        return nothing
    end
    return rscript
end

"""
    _r_compiler() -> Union{String, Nothing}

The C compiler the end-to-end R test uses to build a small shared library, or
`nothing` when there is none. CI must run the test, so a missing compiler is
an error there; locally it is a skip, so a contributor without one still gets
a green suite.
"""
function _r_compiler()
    compiler = Sys.which("cc")
    if isnothing(compiler)
        haskey(ENV, "CI") &&
            error("cc not found on PATH; required on CI to compile the R test library")
        @info "Skipping the R end-to-end checks (no cc)"
    end
    return compiler
end

"""
    _r_field_typeinfo() -> OrderedDict{Int, TypeDesc}

A hand-built ABI whose aggregates exercise every field token the emitter can
produce: plain primitives, a one-byte `Bool`, fixed-size arrays, an untyped
pointer, typed pointers, a pointer to a struct and a struct nested by value.
The recorded sizes and offsets are the C ABI's on every platform
JuliaLibWrapping targets. The order is a valid dependency order; `Pair` must
precede the aggregates that hold it.
"""
function _r_field_typeinfo()
    return OrderedDict{Int, TypeDesc}(
        1 => PrimitiveTypeDesc("Int32", true, 32, 4, 4),
        2 => PrimitiveTypeDesc("UInt8", false, 8, 1, 1),
        3 => PrimitiveTypeDesc("UInt16", false, 16, 2, 2),
        4 => PrimitiveTypeDesc("Int64", true, 64, 8, 8),
        5 => PrimitiveTypeDesc("Float64", false, 64, 8, 8),
        6 => PrimitiveTypeDesc("Bool", false, 8, 1, 1),
        7 => PointerDesc("Ptr{Nothing}", nothing),
        8 => PointerDesc("Ptr{UInt8}", 2),
        9 => PointerDesc("Ptr{Float64}", 5),
        10 => ArrayDesc("NTuple{2, Int64}", 4, 2, 16, 8),
        11 => ArrayDesc("NTuple{3, UInt8}", 2, 3, 3, 1),
        12 => ArrayDesc("NTuple{4, UInt16}", 3, 4, 8, 2),
        13 => StructDesc(
            "Pair", 8, 4,
            FieldDesc[FieldDesc("x", 1, 0), FieldDesc("y", 1, 4)]
        ),
        14 => StructDesc(
            "Flags", 8, 4,
            FieldDesc[FieldDesc("ready", 6, 0), FieldDesc("code", 1, 4)]
        ),
        15 => PointerDesc("Ptr{Pair}", 13),
        16 => StructDesc(
            "Wrapper", 16, 8,
            FieldDesc[FieldDesc("pair", 15, 0), FieldDesc("count", 1, 8)]
        ),
        17 => StructDesc(
            "Wide", 16, 8,
            FieldDesc[FieldDesc("flags", 12, 0), FieldDesc("handle", 7, 8)]
        ),
        18 => StructDesc(
            "Vector2", 24, 8,
            FieldDesc[FieldDesc("dims", 10, 0), FieldDesc("data", 9, 16)]
        ),
        19 => StructDesc(
            "Nested", 12, 4,
            FieldDesc[FieldDesc("pair", 13, 0), FieldDesc("tags", 11, 8)]
        ),
    )
end

using JuliaLibWrapping
using Test

@testset "sanitize_r_name" begin
    @test JuliaLibWrapping.sanitize_r_name("scale") == "scale"
    @test JuliaLibWrapping.sanitize_r_name("sum-dict") == "sum_dict"

    # An R identifier begins with a letter. `_1` is legal C but not R, so the
    # sanitized name takes the same `x` prefix MATLAB names get.
    @test JuliaLibWrapping.sanitize_r_name("1") == "x_1"
    @test JuliaLibWrapping.sanitize_r_name("") == "x"

    # A reserved word is a syntax error where an identifier is expected.
    @test JuliaLibWrapping.sanitize_r_name("if") == "if_"
    @test JuliaLibWrapping.sanitize_r_name("TRUE") == "TRUE_"

    # A Julia type name keeps its shape, only losing the punctuation.
    @test JuliaLibWrapping.sanitize_r_name("CArray{:owned, Float64}") ==
        "CArray_owned_Float64"
end

@testset "RTarget" begin
    t = RTarget("out", "boundary", "libboundary")
    @test t.package_name == "boundary"
    @test t.library_basename == "libboundary"
    @test t.bundle_subdir === nothing
    @test t.version == JuliaLibWrapping._DEFAULT_PACKAGE_VERSION
    @test t.privatized === false
    @test t isa AbstractTarget
    @test sprint(show, t) == "RTarget(\"out\", \"boundary\", \"libboundary\")"

    bundled = RTarget(
        "out", "boundary", "libboundary";
        bundle_subdir = "bundle", version = "1.2.3", privatized = true
    )
    @test sprint(show, bundled) ==
        "RTarget(\"out\", \"boundary\", \"libboundary\"; bundle_subdir = " *
        "\"bundle\"; version = \"1.2.3\"; privatized = true)"

    # R package names start with a letter, take letters, digits and periods,
    # and do not end in a period.
    @test_throws ArgumentError RTarget("out", "1bad", "lib")
    @test_throws ArgumentError RTarget("out", "has-dash", "lib")
    @test_throws ArgumentError RTarget("out", "trailing.", "lib")
    @test_throws ArgumentError RTarget("out", "ok", "lib"; version = "")

    # `build_library` records whether the bundle a target describes was
    # privatized; a target may not be downgraded out of claiming one.
    priv = JuliaLibWrapping._apply_privatization(t, true)
    @test priv.privatized
    @test priv.package_name == t.package_name
    @test JuliaLibWrapping._apply_privatization(t, false) === t
    @test JuliaLibWrapping._apply_privatization(priv, true) === priv
    @test_throws ArgumentError JuliaLibWrapping._apply_privatization(priv, false)
end

@testset "R type mangling" begin
    typedict = Dict{Int, String}()
    info = OrderedDict{Int, TypeDesc}(
        1 => StructDesc("A.B", 4, 4, FieldDesc[]),
        2 => StructDesc("A_B", 4, 4, FieldDesc[]),
    )
    # Distinct Julia names can sanitize alike; the later one is suffixed.
    @test JuliaLibWrapping.mangle_r_type!(typedict, 1, info) == "A_B"
    @test JuliaLibWrapping.mangle_r_type!(typedict, 2, info) == "A_B_2"
    # Memoized, so a second call is stable.
    @test JuliaLibWrapping.mangle_r_type!(typedict, 2, info) == "A_B_2"

    @test_throws ErrorException JuliaLibWrapping.mangle_r_type!(
        Dict{Int, String}(), 1,
        OrderedDict{Int, TypeDesc}(1 => PrimitiveTypeDesc("Int32", true, 32, 4, 4))
    )
end

@testset "R field names" begin
    desc = StructDesc(
        "T", 8, 4,
        FieldDesc[FieldDesc("1", 1, 0), FieldDesc("2", 1, 4)]
    )
    @test JuliaLibWrapping._r_field_names(desc) == ["x_1", "x_2"]

    collision = StructDesc(
        "T", 8, 4,
        FieldDesc[FieldDesc("a-b", 1, 0), FieldDesc("a_b", 1, 4)]
    )
    @test JuliaLibWrapping._r_field_names(collision) == ["a_b", "a_b2"]
end

@testset "R type signatures" begin
    typeinfo = _r_field_typeinfo()
    typedict = Dict{Int, String}()
    for (id, type) in pairs(typeinfo)
        type isa StructDesc && JuliaLibWrapping.mangle_r_type!(typedict, id, typeinfo)
    end
    sig(id) = JuliaLibWrapping.r_type_signature(typedict, id, typeinfo)
    fsig(id) = JuliaLibWrapping.r_type_signature(typedict, id, typeinfo; field = true)

    for (id, token) in (
            (1, "i"), (2, "C"), (3, "S"), (4, "l"), (5, "d"), (6, "B"),
        )
        @test sig(id) == token
    end

    # rdyncall lays a `B` field out as 8 bytes, so the emitted field is the
    # one-byte `C` and the layout check guards the substitution.
    @test fsig(6) == "C"

    @test sig(7) == "p"
    @test sig(8) == "*C"
    @test sig(9) == "*d"
    @test sig(15) == "*<Pair>"
    @test sig(10) == "l[2]"
    @test fsig(11) == "C[3]"
    @test fsig(12) == "S[4]"
    @test sig(13) == "<Pair>"

    # A `nothing` return type is `void`.
    @test JuliaLibWrapping.r_type_signature(typedict, nothing, typeinfo) == "v"

    @test_throws ErrorException JuliaLibWrapping._r_primitive_token("ComplexF64")
    @test_throws ErrorException JuliaLibWrapping._r_primitive_token("Cvoid"; field = true)

    structsig(id) = JuliaLibWrapping._r_struct_signature(id, typeinfo[id], typeinfo, typedict)
    @test structsig(13) == "Pair{ii}x y;"
    @test structsig(14) == "Flags{Ci}ready code;"
    @test structsig(16) == "Wrapper{*<Pair>i}pair count;"
    @test structsig(17) == "Wide{S[4]p}flags handle;"
    @test structsig(18) == "Vector2{l[2]*d}dims data;"
    @test structsig(19) == "Nested{<Pair>C[3]}pair tags;"
end

@testset "RTarget golden output" begin
    abi = read_abi_info("bindinginfo_cvoid.json")
    mktempdir() do path
        write_wrapper(
            RTarget(path, "rprimitives", "libprimitives"; version = "1.2.3"), abi
        )
        pkgdir = joinpath(path, "rprimitives")
        for (file, golden) in (
                (joinpath("R", "lowlevel.R"), "expected_r_lowlevel.R"),
                (joinpath("R", "facade.R"), "expected_r_facade.R"),
                ("DESCRIPTION", "expected_r_description"),
                ("NAMESPACE", "expected_r_namespace"),
            )
            actual = read(joinpath(pkgdir, file), String)
            expected = read(joinpath(@__DIR__, golden), String)
            @test actual == expected
        end

        # The LICENSE file carries the current year, so it is checked by
        # shape rather than byte for byte.
        license = read(joinpath(pkgdir, "LICENSE"), String)
        @test occursin(r"^YEAR: \d{4}$"m, license)
        @test occursin("COPYRIGHT HOLDER: JuliaLibWrapping", license)
    end
end

@testset "RTarget keeps an edited facade" begin
    abi = read_abi_info("bindinginfo_cvoid.json")
    mktempdir() do path
        write_wrapper(RTarget(path, "kept", "libkept"), abi)
        facade = joinpath(path, "kept", "R", "facade.R")
        write(facade, "# edited\n")
        write_wrapper(RTarget(path, "kept", "libkept"), abi)
        @test read(facade, String) == "# edited\n"
        # Every other file is rewritten.
        @test occursin("libkept", read(joinpath(path, "kept", "R", "lowlevel.R"), String))
    end
end

@testset "RTarget bundle and privatization" begin
    abi = read_abi_info("bindinginfo_cvoid.json")
    mktempdir() do path
        write_wrapper(
            RTarget(
                path, "bundled", "libbundled";
                bundle_subdir = "bundle", privatized = true
            ), abi
        )
        src = read(joinpath(path, "bundled", "R", "lowlevel.R"), String)
        # The loader searches the bundle's `lib` directory first.
        @test occursin("system.file(\"bundle\"", src)
        @test occursin("file.path(bundle, \"lib\")", src)
        # A privatized package does not warn about sharing a runtime.
        @test !occursin("already loaded", src)
    end

    mktempdir() do path
        write_wrapper(RTarget(path, "shared", "libshared"), abi)
        src = read(joinpath(path, "shared", "R", "lowlevel.R"), String)
        @test !occursin("system.file(\"bundle\"", src)
        @test occursin("already loaded", src)
    end
end

@testset "R emitted files parse" begin
    rscript = _r_toolchain()
    if !isnothing(rscript)
        abi = read_abi_info("bindinginfo_cvoid.json")
        abi_scalars = read_abi_info("bindinginfo_r_scalars.json")
        abi_scale = read_abi_info("bindinginfo_api_scale.json")
        md = JuliaLibWrapping.read_api_metadata("api_scale.jlw.json")
        mktempdir() do path
            write_wrapper(RTarget(path, "shared", "libshared"), abi)
            write_wrapper(
                RTarget(
                    path, "bundled", "libbundled";
                    bundle_subdir = "bundle", privatized = true
                ), abi
            )
            write_wrapper(RTarget(path, "rscalars", "libscalars"), abi_scalars)
            write_wrapper(
                RTarget(path, "rapiscale", "libapiscale"), abi_scale;
                api_metadata = md.exports, api_enums = md.enums
            )
            script = joinpath(path, "parse.R")
            write(
                script, """
                for (pkg in c("shared", "bundled", "rscalars", "rapiscale")) {
                  invisible(parse(file = file.path($(repr(path)), pkg, "R", "lowlevel.R")))
                  invisible(parse(file = file.path($(repr(path)), pkg, "R", "facade.R")))
                }
                cat("OK\\n")
                """
            )
            out = IOBuffer()
            ok = success(pipeline(`$rscript --vanilla $script`; stdout = out, stderr = out))
            ok || @info "R parse output" output = String(take!(out))
            @test ok
        end
    end
end

@testset "R layout checks" begin
    rscript = _r_toolchain()
    if !isnothing(rscript)
        # A hand-built ABI, so the check covers every field token without
        # adding a fixture the MATLAB helper golden would sweep in.
        abi = ABIInfo(_r_field_typeinfo(), BitSet(), JuliaLibWrapping.MethodDesc[])
        mktempdir() do path
            write_wrapper(RTarget(path, "rfields", "librfields"), abi)
            lowlevel = joinpath(path, "rfields", "R", "lowlevel.R")
            script = joinpath(path, "layout.R")
            write(
                script, """
                library(rdyncall)
                sys.source($(repr(lowlevel)), envir = globalenv())
                # Every registration ran its own layout check; spot-check a few
                # facts the checks depend on.
                if (Pair\$size != 8L) stop("Pair has the wrong size")
                if (Flags\$fields\$type[[1]] != "C") stop("a Bool field is not one byte")
                if (Vector2\$fields\$type[[1]] != "l") stop("an array field lost its element")
                if (Vector2\$fields\$array_len[[1]] != 2) stop("an array field lost its count")
                if (Wrapper\$fields\$type[[1]] != "*<Pair>") stop("a pointer field lost its pointee")
                if (Nested\$fields\$type[[1]] != "<Pair>") stop("a struct field is not by value")
                refused <- tryCatch(
                  {
                    .jlr_check_layout("Pair", size = 8L, alignment = 4L,
                                      offsets = c(x = 0L, y = 8L))
                    FALSE
                  },
                  error = function(e) TRUE
                )
                if (!refused) stop("the layout check accepted a wrong offset")
                cat("OK\\n")
                """
            )
            out = IOBuffer()
            ok = success(pipeline(`$rscript --vanilla $script`; stdout = out, stderr = out))
            ok || @info "R layout check output" output = String(take!(out))
            @test ok

            # The real JLWInterop layouts, including the carrier structs the
            # api-scale fixture registers, must survive rdyncall's computation
            # unchanged: the field tokens are what phase 3 builds on.
            write_wrapper(
                RTarget(path, "rscalars", "libscalars"),
                read_abi_info("bindinginfo_r_scalars.json")
            )
            write_wrapper(
                RTarget(path, "rapiscale", "libapiscale"),
                read_abi_info("bindinginfo_api_scale.json")
            )
            script2 = joinpath(path, "layout2.R")
            write(
                script2, """
                library(rdyncall)
                sys.source(file.path($(repr(path)), "rscalars", "R", "lowlevel.R"),
                           envir = globalenv())
                sys.source(file.path($(repr(path)), "rapiscale", "R", "lowlevel.R"),
                           envir = globalenv())
                if (JLWStatus\$size != 260L) stop("JLWStatus has the wrong size")
                if (JLWStatus\$fields\$offset[[2]] != 4L) stop("a JLWStatus message moved")
                if (JLWResult_Float64\$size != 272L) stop("JLWResult{Float64} has the wrong size")
                if (CVector_borrowed_Float64\$size != 16L) stop("CVector has the wrong size")
                if (CString_borrowed\$fields\$type[[1]] != "l") stop("a CString length is not 64-bit")
                cat("OK\\n")
                """
            )
            out2 = IOBuffer()
            ok2 = success(pipeline(`$rscript --vanilla $script2`; stdout = out2, stderr = out2))
            ok2 || @info "R layout check output" output = String(take!(out2))
            @test ok2
        end
    end
end

@testset "R call signatures" begin
    typeinfo = _r_field_typeinfo()
    typedict = Dict{Int, String}()
    for (id, type) in pairs(typeinfo)
        type isa StructDesc && JuliaLibWrapping.mangle_r_type!(typedict, id, typeinfo)
    end
    arg(name, id) = JuliaLibWrapping.ArgDesc(name, id, false)
    method(ret, ids...) = JuliaLibWrapping.MethodDesc(
        "f", "f(...)", ret, [arg("a" * string(i), a) for (i, a) in enumerate(ids)]
    )
    sig(m) = JuliaLibWrapping._r_call_signature(m, typeinfo, typedict)

    @test sig(method(1, 1, 5)) == "id)i"
    @test sig(method(nothing, 7)) == "p)v"
    # A typed struct pointer would accept only a `cdata` struct, so the call
    # token is the untyped pointer with the same ABI.
    @test sig(method(13, 15)) == "p)<Pair>"
    @test sig(method(1, 13)) == "<Pair>)i"
    @test sig(method(nothing)) == ")v"

    # An array is not a C parameter, so the entrypoint gets no binding.
    @test sig(method(1, 10)) === nothing
    # Variadic entrypoints have no recorded call-site argument types.
    va = JuliaLibWrapping.MethodDesc(
        "f", "f(a, ...)", 1, [arg("a", 1), JuliaLibWrapping.ArgDesc("rest", 1, true)]
    )
    @test sig(va) === nothing

    # A pointer to a pointer has no typed rdyncall token; `p` has the same ABI.
    deep = OrderedDict{Int, TypeDesc}(
        1 => PrimitiveTypeDesc("Int32", true, 32, 4, 4),
        2 => PointerDesc("Ptr{Nothing}", nothing),
        3 => PointerDesc("Ptr{Ptr{Nothing}}", 2),
    )
    deepdict = Dict{Int, String}()
    @test JuliaLibWrapping._r_call_token(deepdict, 3, deep) == "p"
    @test JuliaLibWrapping._r_call_token(deepdict, 2, deep) == "p"

    # A `Cvoid` argument has no call token, nor does a primitive rdyncall has
    # no token for at all.
    void = OrderedDict{Int, TypeDesc}(1 => PrimitiveTypeDesc("Cvoid", false, 0, 0, 0))
    @test JuliaLibWrapping._r_call_token(Dict{Int, String}(), 1, void) === nothing
    wide = OrderedDict{Int, TypeDesc}(1 => PrimitiveTypeDesc("Cwchar_t", false, 32, 4, 4))
    @test JuliaLibWrapping._r_call_token(Dict{Int, String}(), 1, wide) === nothing
end

@testset "R keyword defaults" begin
    @test JuliaLibWrapping._api_kwarg_default_r(true) == "TRUE"
    @test JuliaLibWrapping._api_kwarg_default_r(false) == "FALSE"
    @test JuliaLibWrapping._api_kwarg_default_r(nothing) == "NULL"
    @test JuliaLibWrapping._api_kwarg_default_r(2) == "2"
    @test JuliaLibWrapping._api_kwarg_default_r(2.5) == "2.5"
    @test JuliaLibWrapping._api_kwarg_default_r("a\"b") == "\"a\\\"b\""
    @test_throws ErrorException JuliaLibWrapping._api_kwarg_default_r([1])
end

@testset "R façade plans" begin
    info = read_abi_info("bindinginfo_r_scalars.json")
    bysym(sym) = only(m for m in info.entrypoints if m.symbol == sym)
    for m in info.entrypoints
        @test JuliaLibWrapping._r_facade_plan(m, info.typeinfo).kind === :auto
    end
    @test JuliaLibWrapping._r_facade_plan(
        bysym("plain_add"), info.typeinfo
    ).ret.kind === :scalar
    @test JuliaLibWrapping._r_facade_plan(
        bysym("do_thing"), info.typeinfo
    ).ret.kind === :status
    result = JuliaLibWrapping._r_facade_plan(bysym("scale_value"), info.typeinfo)
    @test result.ret.kind === :result
    @test result.ret.inner.kind === :scalar

    # An undeclared entrypoint with a pointer argument or a generic struct
    # return gets a raw forwarder, not an idiomatic wrapper.
    cvoid = read_abi_info("bindinginfo_cvoid.json")
    zero = only(m for m in cvoid.entrypoints if m.symbol == "zero_first")
    plan = JuliaLibWrapping._r_facade_plan(zero, cvoid.typeinfo)
    @test plan.kind === :skip
    @test plan.name == "zero_first"
    @test occursin("argument 1", plan.reason)
    chunk = only(m for m in cvoid.entrypoints if m.symbol == "chunk_table")
    @test JuliaLibWrapping._r_facade_plan(chunk, cvoid.typeinfo).kind === :skip

    # An `@api` entry passes carriers and pointers through, so its sidecar
    # keyword defaults survive until the carriers are converted.
    abi = read_abi_info("bindinginfo_api_scale.json")
    md = JuliaLibWrapping.read_api_metadata("api_scale.jlw.json")
    scale = only(m for m in abi.entrypoints if m.symbol == "mylib_scale")
    plan = JuliaLibWrapping._r_facade_plan(
        scale, abi.typeinfo, md.exports["mylib_scale"], md.enums
    )
    @test plan.kind === :auto
    @test plan.name == "scale"
    @test plan.positional == ["x"]
    @test plan.keywords == ["factor", "label"]
    @test plan.defaults[1] == Some(2.0)
    @test plan.defaults[2] === nothing
    @test plan.doc == "Scale every entry."

    # Enum annotations wait for the enum conversion, so those entries become
    # forwarders under the sidecar's public name.
    enum = read_abi_info("bindinginfo_enum.json")
    emeta = JuliaLibWrapping.read_api_metadata("enum.jlw.json")
    pick = only(m for m in enum.entrypoints if m.symbol == "EnumFixture_pick")
    plan = JuliaLibWrapping._r_facade_plan(
        pick, enum.typeinfo, emeta.exports["EnumFixture_pick"]
    )
    @test plan.kind === :skip
    @test plan.name == "pick"
    @test occursin("enum returns", plan.reason)
    scale_by = only(m for m in enum.entrypoints if m.symbol == "EnumFixture_scale_by")
    plan = JuliaLibWrapping._r_facade_plan(
        scale_by, enum.typeinfo, emeta.exports["EnumFixture_scale_by"]
    )
    @test plan.kind === :skip
    @test occursin("enum arguments", plan.reason)

    @test JuliaLibWrapping.accepts_api_metadata(RTarget("out", "pkg", "lib"))
end

@testset "R scalars golden output" begin
    abi = read_abi_info("bindinginfo_r_scalars.json")
    mktempdir() do path
        write_wrapper(RTarget(path, "rscalars", "libscalars"; version = "1.2.3"), abi)
        pkgdir = joinpath(path, "rscalars")
        for (file, golden) in (
                (joinpath("R", "lowlevel.R"), "expected_r_scalars_lowlevel.R"),
                (joinpath("R", "facade.R"), "expected_r_scalars_facade.R"),
            )
            actual = read(joinpath(pkgdir, file), String)
            expected = read(joinpath(@__DIR__, golden), String)
            @test actual == expected
        end
    end
end

@testset "R api-scale golden output" begin
    abi = read_abi_info("bindinginfo_api_scale.json")
    md = JuliaLibWrapping.read_api_metadata("api_scale.jlw.json")
    mktempdir() do path
        write_wrapper(
            RTarget(path, "rapiscale", "libapiscale"; version = "1.2.3"), abi;
            api_metadata = md.exports, api_enums = md.enums
        )
        pkgdir = joinpath(path, "rapiscale")
        for (file, golden) in (
                (joinpath("R", "lowlevel.R"), "expected_r_api_scale_lowlevel.R"),
                (joinpath("R", "facade.R"), "expected_r_api_scale_facade.R"),
            )
            actual = read(joinpath(pkgdir, file), String)
            expected = read(joinpath(@__DIR__, golden), String)
            @test actual == expected
        end
    end
end

@testset "R shortcut expressions" begin
    # A borrowed array whose R vector already has the right C representation
    # is passed by reference; the rest are packed into a raw buffer.
    @test JuliaLibWrapping._r_array_borrow_expr("Float64", "x") ==
        "as.externalptr(as.double(x))"
    @test JuliaLibWrapping._r_array_borrow_expr("Int32", "x") ==
        "as.externalptr(as.integer(x))"
    @test JuliaLibWrapping._r_array_borrow_expr("Float32", "x") ==
        "as.externalptr(as.floatraw(as.double(x)))"
    @test JuliaLibWrapping._r_array_borrow_expr("UInt8", "x") ==
        "as.externalptr(as.raw(as.integer(x)))"
    @test JuliaLibWrapping._r_array_borrow_expr("Int16", "x") === nothing

    # A `Bool` is packed as the one-byte `C` token the field workaround uses.
    @test JuliaLibWrapping._r_pack_value_expr("Bool", "x") == "as.integer(x[[.jlr_i]])"
    @test JuliaLibWrapping._r_pack_value_expr("Int16", "x") == "x[[.jlr_i]]"
end

@testset "R carrier recognition" begin
    findtype(descs, name) = (
        k = collect(keys(descs));
        k[findfirst(id -> descs[id].name === name, k)]
    )
    classify(typeinfo, typedict, name) = begin
        id = findtype(typeinfo, name)
        return (
            id,
            JuliaLibWrapping._r_carrier_info(id, typeinfo),
            typedict,
        )
    end

    # A borrowed CArray is a builder, and an owning argument is demoted: an R
    # caller has no Julia allocation to hand over.
    cmatrix = read_abi_info("bindinginfo_cmatrix.json")
    td = JuliaLibWrapping._r_premangle_typeinfo(cmatrix.typeinfo)
    id, info, _ = classify(cmatrix.typeinfo, td, "CMatrix{:borrowed, Float64}")
    @test info.family === :array
    @test info.ownership === :borrowed
    @test info.eltype == "Float64"
    @test info.ndim == 2
    arg = JuliaLibWrapping._r_classify_arg(id, cmatrix.typeinfo, td)
    @test arg.kind === :carrier
    @test arg.builder == ".jlr_CMatrix_borrowed_Float64_arg"

    owned = read_abi_info("bindinginfo_carray_owned.json")
    td_o = JuliaLibWrapping._r_premangle_typeinfo(owned.typeinfo)
    id_o, info_o, _ = classify(owned.typeinfo, td_o, "CVector{:owned, Float64}")
    @test info_o.ownership === :owned
    demoted_arg = JuliaLibWrapping._r_classify_arg(id_o, owned.typeinfo, td_o)
    @test demoted_arg.kind === :opaque
    @test occursin("owning array carrier", demoted_arg.reason)
    ret = JuliaLibWrapping._r_classify_return(
        id_o, owned.typeinfo, td_o; release_present = true
    )
    @test ret.kind === :carrier
    @test ret.reader == ".jlr_CVector_owned_Float64_ret"
    nofree = JuliaLibWrapping._r_classify_return(
        id_o, owned.typeinfo, td_o; release_present = false
    )
    @test nofree.kind === :opaque
    @test occursin("release entrypoints", nofree.reason)

    # COpt has no ownership parameter, so it is a carrier on both sides.
    copt = read_abi_info("bindinginfo_copt.json")
    td_c = JuliaLibWrapping._r_premangle_typeinfo(copt.typeinfo)
    id_c, info_c, _ = classify(copt.typeinfo, td_c, "COpt{Float64}")
    @test info_c.family === :opt
    @test info_c.value_type == "Float64"
    @test JuliaLibWrapping._r_classify_arg(id_c, copt.typeinfo, td_c).kind === :carrier
    @test JuliaLibWrapping._r_classify_return(
        id_c, copt.typeinfo, td_c
    ).kind === :carrier

    # The remaining families are recognized off their shapes.
    cstring = read_abi_info("bindinginfo_cstring_owned.json")
    td_s = JuliaLibWrapping._r_premangle_typeinfo(cstring.typeinfo)
    _, info_s, _ = classify(cstring.typeinfo, td_s, "CString{:owned}")
    @test info_s.family === :string
    @test info_s.ownership === :owned

    cstrarray = read_abi_info("bindinginfo_cstrarray.json")
    td_sa = JuliaLibWrapping._r_premangle_typeinfo(cstrarray.typeinfo)
    _, info_sa, _ = classify(cstrarray.typeinfo, td_sa, "CStrArray{:owned}")
    @test info_sa.family === :strarray
    element = JuliaLibWrapping._r_pointee_struct(
        cstrarray.typeinfo[findtype(cstrarray.typeinfo, "CStrArray{:owned}")],
        "data", cstrarray.typeinfo
    )
    layout = JuliaLibWrapping._r_cstring_layout(element, cstrarray.typeinfo)
    @test layout.size == 16
    @test layout.length_offset == 0
    @test layout.length_token == "l"
    @test layout.data_offset == 8

    cdict = read_abi_info("bindinginfo_cdict.json")
    td_d = JuliaLibWrapping._r_premangle_typeinfo(cdict.typeinfo)
    _, info_d, _ = classify(cdict.typeinfo, td_d, "CDict{:owned, Float64}")
    @test info_d.family === :dict
    @test info_d.value_type == "Float64"

    # A tuple return classifies each element, which decides whether the whole
    # tuple can be converted.
    ctuple = read_abi_info("bindinginfo_ctuple.json")
    td_t = JuliaLibWrapping._r_premangle_typeinfo(ctuple.typeinfo)
    id_t = findtype(
        ctuple.typeinfo, "CNTuple{2, Tuple{CVector{:owned, Float64}, Int64}}"
    )
    ret_t = JuliaLibWrapping._r_classify_return(
        id_t, ctuple.typeinfo, td_t; release_present = true
    )
    @test ret_t.kind === :carrier
    @test ret_t.carrier.family === :tuple
    @test ret_t.carrier.elements[1].kind === :carrier
    @test ret_t.carrier.elements[2].kind === :scalar
    nofree_t = JuliaLibWrapping._r_classify_return(
        id_t, ctuple.typeinfo, td_t; release_present = false
    )
    @test nofree_t.kind === :opaque

    # An unrecognized buffer element type is not a carrier.
    @test JuliaLibWrapping._r_carrier_info(1, cmatrix.typeinfo) === nothing
end

@testset "R carrier golden output" begin
    for (fixture, prefix, pkg, lib) in (
            ("bindinginfo_carray3.json", "carray3", "rcarray3", "libcarray3"),
            (
                "bindinginfo_carray_owned.json", "carrayowned", "rcarrayowned",
                "libcarrayowned",
            ),
            (
                "bindinginfo_cstring_owned.json", "cstringowned", "rcstringowned",
                "libcstringowned",
            ),
            (
                "bindinginfo_cstrarray.json", "cstrarray", "rcstrarray",
                "libcstrarray",
            ),
            ("bindinginfo_cdict.json", "cdict", "rcdict", "libcdict"),
            ("bindinginfo_copt.json", "copt", "rcopt", "libcopt"),
            ("bindinginfo_ctuple.json", "ctuple", "rctuple", "libctuple"),
            (
                "bindinginfo_jlwresult_owned.json", "jlwresultowned",
                "rjlwresultowned", "libjlwresultowned",
            ),
        )
        abi = read_abi_info(fixture)
        mktempdir() do path
            write_wrapper(RTarget(path, pkg, lib; version = "1.2.3"), abi)
            pkgdir = joinpath(path, pkg)
            for (file, suffix) in (
                    (joinpath("R", "lowlevel.R"), "lowlevel"),
                    (joinpath("R", "facade.R"), "facade"),
                )
                actual = read(joinpath(pkgdir, file), String)
                expected = read(
                    joinpath(@__DIR__, "expected_r_" * prefix * "_" * suffix * ".R"),
                    String,
                )
                @test actual == expected
            end
        end
    end
end

@testset "R end-to-end" begin
    compiler = _r_compiler()
    rscript = _r_toolchain()
    if !isnothing(compiler) && !isnothing(rscript)
        abi = read_abi_info("bindinginfo_r_scalars.json")
        mktempdir() do path
            write_wrapper(RTarget(path, "rscalars", "librscalars"), abi)
            pkgdir = joinpath(path, "rscalars")
            csrc = joinpath(path, "rscalars.c")
            write(
                csrc, """
                #include <string.h>
                typedef struct { int code; unsigned char message[256]; } JLWStatus;
                typedef struct { JLWStatus status; double value; } JLWResultd;

                static void set_status(JLWStatus *s, int code, const char *msg) {
                  s->code = code;
                  memset(s->message, 0, 256);
                  if (msg != 0) strncpy((char *)s->message, msg, 255);
                }

                int plain_add(int a, int b) { return a + b; }

                JLWStatus do_thing(int x) {
                  JLWStatus s;
                  set_status(&s, x < 0 ? 2 : 0, x < 0 ? "negative" : "");
                  return s;
                }

                JLWResultd scale_value(double x) {
                  JLWResultd r;
                  if (x < 0) {
                    set_status(&r.status, 3, "must be non-negative");
                    r.value = 0.0;
                    return r;
                  }
                  set_status(&r.status, 0, "");
                  r.value = x * 2.0;
                  return r;
                }
                """
            )
            lib = joinpath(path, "librscalars." * Base.Libc.Libdl.dlext)
            compile = `$compiler -shared -fPIC -o $lib $csrc`
            ok = success(pipeline(compile; stdout = devnull, stderr = devnull))
            ok || @info "R test library compile failed" command = compile
            @test ok
            if ok
                script = joinpath(path, "run.R")
                lowlevel = joinpath(pkgdir, "R", "lowlevel.R")
                facade = joinpath(pkgdir, "R", "facade.R")
                write(
                    script, """
                    library(rdyncall)
                    env <- new.env(parent = globalenv())
                    sys.source($(repr(lowlevel)), envir = env)
                    handle <- dynload($(repr(lib)))
                    for (sym in env\$.jlr_symbols) {
                      assign(sym, dynsym(handle, sym), envir = env\$.jlr_syms)
                    }
                    # A scalar round-trips.
                    if (!identical(env\$.jlr_plain_add(2L, 3L), 5L)) {
                      stop("plain_add returned the wrong value")
                    }
                    # A bare JLWStatus is checked and discarded.
                    if (!is.null(env\$.jlr_do_thing(1L))) {
                      stop("do_thing did not return NULL")
                    }
                    err <- tryCatch(env\$.jlr_do_thing(-1L), error = function(e) e)
                    if (!inherits(err, "jlw_argument")) {
                      stop("do_thing did not raise jlw_argument")
                    }
                    if (!identical(conditionMessage(err), "negative")) {
                      stop("the status message was misread")
                    }
                    if (!identical(err\$code, 2L)) {
                      stop("the condition lost its code")
                    }
                    # A JLWResult unwraps its payload.
                    if (!identical(env\$.jlr_scale_value(2), 4)) {
                      stop("scale_value returned the wrong value")
                    }
                    err <- tryCatch(env\$.jlr_scale_value(-1), error = function(e) e)
                    if (!inherits(err, "jlw_dimension")) {
                      stop("scale_value did not raise jlw_dimension")
                    }
                    if (!identical(conditionMessage(err), "must be non-negative")) {
                      stop("the status message was misread")
                    }
                    # The façade wrapper calls the same binding.
                    facade <- new.env(parent = env)
                    sys.source($(repr(facade)), envir = facade)
                    if (!identical(facade\$plain_add(2, 3), 5L)) {
                      stop("the façade wrapper is not wired to the binding")
                    }
                    cat("OK\\n")
                    """
                )
                out = IOBuffer()
                ok = success(pipeline(`$rscript --vanilla $script`; stdout = out, stderr = out))
                ok || @info "R end-to-end output" output = String(take!(out))
                @test ok
            end
        end
    end
end

include("r_carriers.jl")
