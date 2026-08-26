# Tests for `build_library`.

using JuliaLibWrapping
using JuliaC
using Test
using TOML: TOML

# `juliac` requires every `[sources]` path in the entry project to be
# absolute, and the examples deliberately ship without one so their
# `Project.toml` carries no machine-specific path. Materialize a transient
# project that points `JLWInterop` at the in-tree checkout.
function example_project(exdir)
    toml = TOML.parsefile(joinpath(exdir, "Project.toml"))
    sources = get(toml, "sources", Dict{String, Any}())
    sources["JLWInterop"] = Dict(
        "path" => abspath(joinpath(@__DIR__, "..", "..", "JLWInterop"))
    )
    toml["sources"] = sources
    tmp = mktempdir()
    open(joinpath(tmp, "Project.toml"), "w") do io
        TOML.print(io, toml; sorted = true)
    end
    cp(joinpath(exdir, "src"), joinpath(tmp, "src"))
    return tmp
end

@testset "build_library" begin
    @testset "validate [sources] paths" begin
        mktempdir() do proj
            open(joinpath(proj, "Project.toml"), "w") do io
                write(
                    io, """
                    name = "Dummy"
                    uuid = "00000000-0000-0000-0000-000000000000"

                    [sources]
                    Foo = {path = "../foo"}
                    """
                )
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

        # Absolute paths are accepted.
        mktempdir() do proj
            open(joinpath(proj, "Project.toml"), "w") do io
                write(
                    io, """
                    name = "Dummy"
                    uuid = "00000000-0000-0000-0000-000000000001"

                    [sources]
                    Foo = {path = "/tmp/foo"}
                    """
                )
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

    @testset "api metadata" begin
        mktempdir() do dir
            p = joinpath(dir, "m.jlw.json")
            write(
                p, """{"jlw_metadata_version": 1, "exports": {"M_f": {"name": "f", "args": ["x"], "kwargs": [], "doc": ""}}}"""
            )
            meta = JuliaLibWrapping.read_api_metadata(p)
            @test haskey(meta, "M_f")
            bad = joinpath(dir, "bad.jlw.json")
            write(bad, """{"jlw_metadata_version": 99, "exports": {}}""")
            @test_throws ErrorException JuliaLibWrapping.read_api_metadata(bad)
        end

        @testset "check_metadata_consistency" begin
            ok_info = read_abi_info("bindinginfo_jlwresult.json")  # JLWResult{Float64}, symbol "mylib_scale", no args

            ok_meta = Dict{String, Any}(
                "mylib_scale" => Dict{String, Any}(
                    "name" => "scale", "args" => String[], "kwargs" => Any[], "doc" => ""
                ),
            )
            @test isnothing(JuliaLibWrapping.check_metadata_consistency(ok_info, ok_meta))

            # Unknown symbol: no matching entrypoint in the ABI.
            unknown_symbol = Dict{String, Any}(
                "nope" => Dict{String, Any}(
                    "name" => "f", "args" => String[], "kwargs" => Any[], "doc" => ""
                ),
            )
            err = try
                JuliaLibWrapping.check_metadata_consistency(ok_info, unknown_symbol)
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("nope", err.msg)

            # Arg-count mismatch: sidecar declares 1 arg, ABI entrypoint takes 0.
            bad_arity = Dict{String, Any}(
                "mylib_scale" => Dict{String, Any}(
                    "name" => "scale", "args" => ["x"], "kwargs" => Any[], "doc" => ""
                ),
            )
            err = try
                JuliaLibWrapping.check_metadata_consistency(ok_info, bad_arity)
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("mylib_scale", err.msg)

            # Names and order must match elementwise: the Python emitter
            # zips the sidecar's list against the ABI's positionally.
            scale_info = read_abi_info("bindinginfo_api_scale.json")
            named(kws) = Dict{String, Any}(
                "mylib_scale" => Dict{String, Any}(
                    "name" => "scale", "args" => ["x"],
                    "kwargs" => Any[Dict{String, Any}("name" => k) for k in kws],
                    "doc" => "",
                ),
            )
            @test isnothing(
                JuliaLibWrapping.check_metadata_consistency(scale_info, named(["factor", "label"]))
            )
            err = try
                JuliaLibWrapping.check_metadata_consistency(scale_info, named(["label", "factor"]))
                nothing
            catch e
                e
            end
            @test err isa ErrorException
            @test occursin("mylib_scale", err.msg)
        end

        @testset "sidecar preconditions" begin
            # A file that uses `@api` and produces no sidecar is an error,
            # naming what went wrong; a file that does not is a silent skip.
            mktempdir() do dir
                proj = mkpath(joinpath(dir, "proj"))
                withapi = joinpath(dir, "withapi.jl")
                write(withapi, "using JLWInterop\n@api function f(x::Float64)::Float64\n    x\nend\n")
                err = try
                    JuliaLibWrapping._maybe_dump_api_metadata(withapi, proj, dir, "lib"; verbose = false)
                    nothing
                catch e
                    e
                end
                @test err isa ErrorException
                @test occursin("JLWInterop", err.msg)

                # A directory entry carries no text to scan, so it skips.
                @test isnothing(
                    JuliaLibWrapping._maybe_dump_api_metadata(dir, proj, dir, "lib"; verbose = false)
                )

                plain = joinpath(dir, "plain.jl")
                write(plain, "f(x) = x\n")
                @test isnothing(
                    JuliaLibWrapping._maybe_dump_api_metadata(plain, proj, dir, "lib"; verbose = false)
                )
            end
        end
    end

    @testset "backend selection" begin
        # The default backend requires JuliaC.
        ext = Base.get_extension(JuliaLibWrapping, :JuliaLibWrappingJuliaCExt)
        entry = joinpath(@__DIR__, "..", "examples", "abi_stress", "src", "abi_stress.jl")
        proj = joinpath(@__DIR__, "..", "examples", "abi_stress")
        if ext === nothing
            for be in (:auto, :juliac)
                err = try
                    build_library(
                        entry, AbstractTarget[]; project = proj,
                        libname = "abi_stress", backend = be
                    )
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
            build_library(
                entry, AbstractTarget[]; project = proj,
                libname = "abi_stress", backend = :bogus
            )
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin(":bogus", err.msg)

        # Unknown trim mode rejected.
        err = try
            build_library(
                entry, AbstractTarget[]; project = proj,
                libname = "abi_stress", trim = :wild
            )
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin(":wild", err.msg)
    end

    @testset "bundle validation" begin
        entry = joinpath(@__DIR__, "..", "examples", "abi_stress", "src", "abi_stress.jl")
        proj = joinpath(@__DIR__, "..", "examples", "abi_stress")

        # bundle = true with a PythonTarget lacking bundle_subdir must
        # fail immediately: writing into the package would leave the
        # generated loader looking in the wrong place.
        err = try
            build_library(
                entry,
                [PythonTarget("/tmp", "pkg", "libfoo")];
                project = proj, libname = "abi_stress",
                bundle = true
            )
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("needs `bundle_subdir", err.msg)
        @test occursin("\"pkg\"", err.msg)
    end

    @testset "end-to-end" begin
        # Run the expensive integration test only when juliac is available.
        has_julia = Sys.which("julia") !== nothing
        has_cc = Sys.which("gcc") !== nothing || Sys.which("clang") !== nothing
        juliac_ok = has_julia && VERSION >= v"1.13.0-rc1" && has_cc
        if !juliac_ok
            @info "Skipping build_library end-to-end test" has_julia has_cc VERSION
        else
            entry = joinpath(
                @__DIR__, "..", "examples", "abi_stress",
                "src", "abi_stress.jl"
            )
            proj = joinpath(@__DIR__, "..", "examples", "abi_stress")
            mktempdir() do out
                result = build_library(
                    entry,
                    [
                        CTarget(out, "abi_stress"),
                        PythonTarget(out, "abi_stress_py", "abi_stress"),
                    ];
                    project = proj, libname = "abi_stress",
                    libdir = out, cpu_target = "generic"
                )
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
                    @test success(run(pipeline(cmd; stderr = devnull, stdout = devnull); wait = true))
                end
            end
        end
    end

    @testset "examples: run smoke.py" begin
        # The `ols` and `boundary` examples ship Python smoke tests that call
        # into the generated wrappers for real. Build each library and run its
        # smoke test, which is the only coverage that exercises the emitted
        # helpers (numpy conversions, ownership handling) at runtime rather
        # than just parsing them.
        has_julia = Sys.which("julia") !== nothing
        has_cc = Sys.which("gcc") !== nothing || Sys.which("clang") !== nothing
        juliac_ok = has_julia && VERSION >= v"1.13.0-rc1" && has_cc
        if !juliac_ok
            @info "Skipping example smoke tests" has_julia has_cc VERSION
        else
            python3 = Sys.which("python3")
            # The smoke tests and the generated CArray helpers both need numpy.
            has_numpy = python3 !== nothing &&
                success(pipeline(`$python3 -c "import numpy"`; stderr = devnull))
            if !has_numpy
                haskey(ENV, "CI") && error(
                    "python3 with numpy is required on CI to run the example smoke tests"
                )
                @info "Skipping example smoke tests (no python3 with numpy)"
            else
                for name in ("ols", "boundary")
                    exdir = joinpath(@__DIR__, "..", "examples", name)
                    entry = joinpath(exdir, "src", name * ".jl")
                    mktempdir() do out
                        result = build_library(
                            entry,
                            [PythonTarget(out, name * "_py", name)];
                            project = example_project(exdir), libname = name,
                            libdir = out, cpu_target = "generic"
                        )
                        @test isfile(result.library)

                        # `out` on PYTHONPATH makes the generated package
                        # importable without installing it; the env override
                        # the loader consults points at the freshly built
                        # library rather than one beside the package.
                        cmd = addenv(
                            `$python3 $(joinpath(exdir, "test", "smoke.py"))`,
                            "PYTHONPATH" => out,
                            uppercase(name * "_py") * "_LIBRARY" => result.library,
                        )
                        @test success(
                            pipeline(
                                cmd; stdout = stdout, stderr = stderr
                            )
                        )
                    end
                end
            end
        end
    end

    @testset "end-to-end with bundle" begin
        # Bundle tests are opt-in because they copy hundreds of MB.
        get(ENV, "JLW_TEST_BUNDLE", "false") == "true" || (@info "Skipping bundle e2e test (set JLW_TEST_BUNDLE=true to run)"; return)
        ext = Base.get_extension(JuliaLibWrapping, :JuliaLibWrappingJuliaCExt)
        ext === nothing && error("JLW_TEST_BUNDLE set but JuliaC.jl is not loaded")
        VERSION >= v"1.13.0-rc1" || error("JLW_TEST_BUNDLE set but julia < 1.13")
        python3 = Sys.which("python3")
        python3 === nothing && error("JLW_TEST_BUNDLE set but python3 not on PATH")
        # The generated _lowlevel.py imports numpy (CVector helpers).
        # Report the missing dependency before attempting the import.
        has_numpy = success(pipeline(`$python3 -c "import numpy"`; stderr = devnull))
        has_numpy || error("JLW_TEST_BUNDLE set but `python3 -c 'import numpy'` failed; install numpy in this python")

        entry = joinpath(
            @__DIR__, "..", "examples", "abi_stress",
            "src", "abi_stress.jl"
        )
        proj = joinpath(@__DIR__, "..", "examples", "abi_stress")
        mktempdir() do out
            result = build_library(
                entry,
                [
                    PythonTarget(
                        out, "abi_stress_py", "abi_stress";
                        bundle_subdir = "bundle"
                    ),
                ];
                project = proj, libname = "abi_stress",
                libdir = out, bundle = true
            )
            @test result.bundle_dir !== nothing
            @test isdir(result.bundle_dir)

            pkgdir = joinpath(out, "abi_stress_py")
            bundled_lib = joinpath(
                pkgdir, "bundle", "lib",
                "abi_stress." * Base.Libc.Libdl.dlext
            )
            @test isfile(bundled_lib)
            # libjulia must be next to the user lib so the embedded
            # RUNPATH ($ORIGIN/../lib[/julia]) resolves it. Privatization is on
            # by default for bundles, so every copy carries a salt prefix and
            # none is named plain `libjulia*`.
            libnames = readdir(joinpath(pkgdir, "bundle", "lib"))
            salted = filter(f -> contains(f, "libjulia"), libnames)
            @test !isempty(salted)
            @test !any(startswith.(salted, "libjulia"))

            # Import directly from `out`, without installing.
            cmd = addenv(
                `$python3 -c "import abi_stress_py; print('ok')"`,
                "PYTHONPATH" => out
            )
            @test success(run(pipeline(cmd; stderr = stderr, stdout = stdout); wait = true))
        end
    end
end
