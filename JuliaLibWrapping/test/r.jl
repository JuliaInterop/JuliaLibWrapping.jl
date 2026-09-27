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
        mktempdir() do path
            write_wrapper(RTarget(path, "shared", "libshared"), abi)
            write_wrapper(
                RTarget(
                    path, "bundled", "libbundled";
                    bundle_subdir = "bundle", privatized = true
                ), abi
            )
            script = joinpath(path, "parse.R")
            write(
                script, """
                for (pkg in c("shared", "bundled")) {
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
        end
    end
end
