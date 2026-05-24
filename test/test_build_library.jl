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

    @testset "end-to-end" begin
        # Drive the full pipeline against examples/abi_stress for both
        # backends. The compile step is expensive (~minutes), so this is
        # gated on having a usable juliac available. On CI it's a hard
        # error if the prerequisites are present but the build fails,
        # mirroring the python3 pattern elsewhere.
        has_julia = Sys.which("julia") !== nothing
        has_cc = Sys.which("gcc") !== nothing || Sys.which("clang") !== nothing
        juliac_ok = has_julia && VERSION >= v"1.13.0-rc1" && has_cc
        if !juliac_ok
            @info "Skipping build_library end-to-end test" has_julia has_cc VERSION
        else
            entry = joinpath(@__DIR__, "..", "examples", "abi_stress",
                             "src", "abi_stress.jl")
            proj  = joinpath(@__DIR__, "..", "examples", "abi_stress")
            for backend in (:juliac, :script)
                @testset "backend = $backend" begin
                    mktempdir() do out
                        # Use the currently-running interpreter so the
                        # :script backend works regardless of what
                        # `julia` resolves to on PATH.
                        result = build_library(entry,
                            [CTarget(out, "abi_stress"),
                             PythonTarget(out, "abi_stress_py", "abi_stress")];
                            project = proj, libname = "abi_stress",
                            libdir = out, backend,
                            julia = Base.julia_cmd())
                        @test isfile(result.library)
                        @test isfile(result.abi_path)
                        @test result.abi_info isa JuliaLibWrapping.ABIInfo
                        @test result.backend === backend

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
        end
    end
end
