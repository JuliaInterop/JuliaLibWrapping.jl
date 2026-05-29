# Tests for `build_library` — see issue #16.

using JuliaLibWrapping
using JuliaC
using Test

@testset "build_library" begin
    @testset "validate [sources] paths" begin
        mktempdir() do proj
            open(joinpath(proj, "Project.toml"), "w") do io
                write(io, """
                name = "Dummy"
                uuid = "00000000-0000-0000-0000-000000000000"

                [sources]
                Foo = {path = "../foo"}
                """)
            end
            entry = joinpath(proj, "src.jl")
            touch(entry)
            err = try
                build_library(entry, AbstractTarget[]; project = proj, libname = "x")
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("relative path", err.msg)
            @test occursin("Foo", err.msg)
        end

        # Absolute path is accepted (validator returns silently). We can't run a
        # full build without juliac, so just exercise the validator directly.
        mktempdir() do proj
            open(joinpath(proj, "Project.toml"), "w") do io
                write(io, """
                name = "Dummy"
                uuid = "00000000-0000-0000-0000-000000000001"

                [sources]
                Foo = {path = "/tmp/foo"}
                """)
            end
            @test JuliaLibWrapping._validate_sources_absolute(proj) === nothing
        end

        # No [sources] table at all is fine.
        mktempdir() do proj
            open(joinpath(proj, "Project.toml"), "w") do io
                write(io, "name = \"Dummy\"\nuuid = \"00000000-0000-0000-0000-000000000002\"\n")
            end
            @test JuliaLibWrapping._validate_sources_absolute(proj) === nothing
        end
    end

    @testset "backend selection" begin
        # Without JuliaC loaded, the default (:auto) backend must fail-fast
        # with an actionable message pointing the user at JuliaC.
        ext = Base.get_extension(JuliaLibWrapping, :JuliaLibWrappingJuliaCExt)
        entry = joinpath(@__DIR__, "..", "examples", "abi_stress", "src", "abi_stress.jl")
        proj = joinpath(@__DIR__, "..", "examples", "abi_stress")
        if ext === nothing
            for be in (:auto, :juliac)
                err = try
                    build_library(entry, AbstractTarget[]; project = proj,
                                  libname = "abi_stress", backend = be)
                    nothing
                catch e
                    e
                end
                @test err isa ArgumentError
                @test occursin("using JuliaC", err.msg)
            end
        end

        # Unknown backend rejected.
        err = try
            build_library(entry, AbstractTarget[]; project = proj,
                          libname = "abi_stress", backend = :bogus)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin(":bogus", err.msg)

        # Unknown trim mode rejected.
        err = try
            build_library(entry, AbstractTarget[]; project = proj,
                          libname = "abi_stress", trim = :wild)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin(":wild", err.msg)
    end

    @testset "bundle validation (issue #17)" begin
        entry = joinpath(@__DIR__, "..", "examples", "abi_stress", "src", "abi_stress.jl")
        proj  = joinpath(@__DIR__, "..", "examples", "abi_stress")

        # bundle = true with a PythonTarget lacking bundle_subdir must
        # fail-fast: silently writing into the package would leave the
        # generated loader looking in the wrong place.
        err = try
            build_library(entry,
                [PythonTarget("/tmp", "pkg", "libfoo")];
                project = proj, libname = "abi_stress",
                bundle = true)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("needs `bundle_subdir", err.msg)
        @test occursin("\"pkg\"", err.msg)
    end

    @testset "end-to-end" begin
        # Drive the full pipeline against examples/abi_stress. The compile
        # step is expensive (~minutes), so this is gated on having a
        # usable juliac available. On CI it's a hard error if the
        # prerequisites are present but the build fails, mirroring the
        # python3 pattern elsewhere.
        has_julia = Sys.which("julia") !== nothing
        has_cc = Sys.which("gcc") !== nothing || Sys.which("clang") !== nothing
        juliac_ok = has_julia && VERSION >= v"1.13.0-rc1" && has_cc
        if !juliac_ok
            @info "Skipping build_library end-to-end test" has_julia has_cc VERSION
        else
            entry = joinpath(@__DIR__, "..", "examples", "abi_stress",
                             "src", "abi_stress.jl")
            proj  = joinpath(@__DIR__, "..", "examples", "abi_stress")
            mktempdir() do out
                result = build_library(entry,
                    [CTarget(out, "abi_stress"),
                     PythonTarget(out, "abi_stress_py", "abi_stress")];
                    project = proj, libname = "abi_stress",
                    libdir = out)
                @test isfile(result.library)
                @test isfile(result.abi_path)
                @test result.abi_info isa JuliaLibWrapping.ABIInfo
                @test result.backend === :juliac

                header = read(joinpath(out, "abi_stress.h"), String)
                @test occursin("tree_size", header)
                @test occursin("countsame", header)

                lowlevel = joinpath(out, "abi_stress_py", "_lowlevel.py")
                @test isfile(lowlevel)
                python3 = Sys.which("python3")
                if python3 !== nothing
                    cmd = `$python3 -c "import ast; ast.parse(open('$lowlevel').read())"`
                    @test success(run(pipeline(cmd; stderr=devnull, stdout=devnull); wait=true))
                end
            end
        end
    end

    @testset "end-to-end with bundle (issue #17)" begin
        # Opt-in: the bundle build copies libjulia + stdlibs + artifacts
        # and is multi-hundred-MB, so we don't run it in default CI. Set
        # JLW_TEST_BUNDLE=true to exercise it locally; the test then runs
        # `python3 -c 'import abi_stress_py'` against the generated
        # package as the real "does the wheel work?" check.
        get(ENV, "JLW_TEST_BUNDLE", "false") == "true" || (@info "Skipping bundle e2e test (set JLW_TEST_BUNDLE=true to run)"; return)
        ext = Base.get_extension(JuliaLibWrapping, :JuliaLibWrappingJuliaCExt)
        ext === nothing && error("JLW_TEST_BUNDLE set but JuliaC.jl is not loaded")
        VERSION >= v"1.13.0-rc1" || error("JLW_TEST_BUNDLE set but julia < 1.13")
        python3 = Sys.which("python3")
        python3 === nothing && error("JLW_TEST_BUNDLE set but python3 not on PATH")
        # The generated _lowlevel.py imports numpy (CVector helpers).
        # Surface that gap up-front rather than failing inside the import
        # with a confusing-looking error.
        has_numpy = success(run(pipeline(`$python3 -c "import numpy"`;
                                        stderr=devnull, stdout=devnull); wait=true))
        has_numpy || error("JLW_TEST_BUNDLE set but `python3 -c 'import numpy'` failed; install numpy in this python")

        entry = joinpath(@__DIR__, "..", "examples", "abi_stress",
                         "src", "abi_stress.jl")
        proj  = joinpath(@__DIR__, "..", "examples", "abi_stress")
        mktempdir() do out
            result = build_library(entry,
                [PythonTarget(out, "abi_stress_py", "abi_stress";
                              bundle_subdir = "bundle")];
                project = proj, libname = "abi_stress",
                libdir = out, bundle = true)
            @test result.bundle_dir !== nothing
            @test isdir(result.bundle_dir)

            pkgdir = joinpath(out, "abi_stress_py")
            bundled_lib = joinpath(pkgdir, "bundle", "lib",
                                   "abi_stress." * Base.Libc.Libdl.dlext)
            @test isfile(bundled_lib)
            # libjulia must be next to the user lib so the baked-in
            # RUNPATH ($ORIGIN/../lib[/julia]) resolves it.
            @test any(startswith.(readdir(joinpath(pkgdir, "bundle", "lib")), "libjulia"))

            # The real test: can Python import the package and call a
            # function? `out` is added to PYTHONPATH so `abi_stress_py`
            # is importable without `pip install`.
            cmd = addenv(`$python3 -c "import abi_stress_py; print('ok')"`,
                         "PYTHONPATH" => out)
            @test success(run(pipeline(cmd; stderr=stderr, stdout=stdout); wait=true))
        end
    end
end
