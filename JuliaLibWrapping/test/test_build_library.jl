# Tests for `build_library`.

using JuliaLibWrapping
using JuliaC
using Test
using TOML: TOML

# The examples deliberately ship without a `[sources]` entry so their
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
    @testset "materialize [sources] paths" begin
        materialize = JuliaLibWrapping._materialize_project

        # Rewrite relative paths while preserving other entries.
        mktempdir() do root
            mkpath(joinpath(root, "foo"))
            proj = joinpath(root, "proj")
            mkpath(joinpath(proj, "src"))
            write(joinpath(proj, "src", "dummy.jl"), "module Dummy end\n")
            pf = joinpath(proj, "Project.toml")
            write(pf, """
            name = "Dummy"
            uuid = "00000000-0000-0000-0000-000000000000"
            version = "1.2.3"

            [deps]
            Foo = "00000000-0000-0000-0000-0000000000f0"

            [compat]
            Foo = "0.1"

            [sources]
            Foo = {path = "../foo"}
            Bar = {path = "/somewhere/bar"}
            Baz = {url = "https://example.com/Baz.jl", rev = "main"}
            """)
            before = read(pf)

            dir = materialize(proj)
            @test dir != proj
            toml = TOML.parsefile(joinpath(dir, "Project.toml"))
            @test toml["sources"]["Foo"]["path"] == abspath(joinpath(root, "foo"))
            @test toml["sources"]["Bar"]["path"] == "/somewhere/bar"
            @test toml["sources"]["Baz"] == Dict("url" => "https://example.com/Baz.jl",
                                                 "rev" => "main")
            @test toml["name"] == "Dummy"
            @test toml["uuid"] == "00000000-0000-0000-0000-000000000000"
            @test toml["version"] == "1.2.3"
            @test toml["deps"] == Dict("Foo" => "00000000-0000-0000-0000-0000000000f0")
            @test toml["compat"] == Dict("Foo" => "0.1")

            # Copy package sources along with the TOML files.
            @test read(joinpath(dir, "src", "dummy.jl"), String) == "module Dummy end\n"

            # The original is untouched.
            @test read(pf) == before
        end

        # Rewrite developed-dependency paths in versioned and plain manifests.
        mktempdir() do root
            mkpath(joinpath(root, "foo"))
            proj = joinpath(root, "proj")
            mkpath(proj)
            write(joinpath(proj, "Project.toml"), """
            [sources]
            Foo = {path = "../foo"}
            """)
            mf = joinpath(proj, "Manifest.toml")
            write(mf, """
            julia_version = "1.13.0"
            manifest_format = "2.0"

            [[deps.Foo]]
            path = "../foo"
            uuid = "00000000-0000-0000-0000-0000000000f0"
            version = "0.1.0"

            [[deps.Bar]]
            path = "/somewhere/bar"
            uuid = "00000000-0000-0000-0000-0000000000ba"
            version = "0.2.0"
            """)
            mf113 = joinpath(proj, "Manifest-v1.13.toml")
            cp(mf, mf113)
            before, before113 = read(mf), read(mf113)

            dir = materialize(proj)
            for name in ("Manifest.toml", "Manifest-v1.13.toml")
                manifest = TOML.parsefile(joinpath(dir, name))
                @test manifest["manifest_format"] == "2.0"
                @test only(manifest["deps"]["Foo"])["path"] == abspath(joinpath(root, "foo"))
                @test only(manifest["deps"]["Bar"])["path"] == "/somewhere/bar"
                @test only(manifest["deps"]["Foo"])["version"] == "0.1.0"
            end
            @test read(mf) == before
            @test read(mf113) == before113
        end

        # Errors identify missing paths and their entries.
        mktempdir() do proj
            write(joinpath(proj, "Project.toml"), """
            [sources]
            Foo = {path = "../nowhere"}
            """)
            @test_throws "\"Foo\"" materialize(proj)
            @test_throws "../nowhere" materialize(proj)
            @test_throws abspath(joinpath(proj, "..", "nowhere")) materialize(proj)
        end

        # Use the original project when no paths need rewriting.
        mktempdir() do proj
            pf = joinpath(proj, "Project.toml")
            write(pf, """
            name = "Dummy"
            uuid = "00000000-0000-0000-0000-000000000001"

            [sources]
            Foo = {path = "/somewhere/foo"}
            """)
            @test materialize(proj) == proj
        end

        mktempdir() do proj
            write(joinpath(proj, "Project.toml"),
                  "name = \"Dummy\"\nuuid = \"00000000-0000-0000-0000-000000000002\"\n")
            @test materialize(proj) == proj
        end

        mktempdir() do proj
            @test materialize(proj) == proj
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

    @testset "bundle validation" begin
        entry = joinpath(@__DIR__, "..", "examples", "abi_stress", "src", "abi_stress.jl")
        proj  = joinpath(@__DIR__, "..", "examples", "abi_stress")

        # bundle = true with a PythonTarget lacking bundle_subdir must
        # fail immediately: writing into the package would leave the
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
        # Run the expensive integration test only when juliac is available.
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
                    libdir = out, cpu_target = "generic")
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
                        result = build_library(entry,
                            [PythonTarget(out, name * "_py", name)];
                            project = example_project(exdir), libname = name,
                            libdir = out, cpu_target = "generic")
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
                        @test success(pipeline(
                            cmd; stdout = stdout, stderr = stderr
                        ))
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
        has_numpy = success(pipeline(`$python3 -c "import numpy"`; stderr=devnull))
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
            # libjulia must be next to the user lib so the embedded
            # RUNPATH ($ORIGIN/../lib[/julia]) resolves it. Privatization is on
            # by default for bundles, so every copy carries a salt prefix and
            # none is named plain `libjulia*`.
            libnames = readdir(joinpath(pkgdir, "bundle", "lib"))
            salted = filter(f -> contains(f, "libjulia"), libnames)
            @test !isempty(salted)
            @test !any(startswith.(salted, "libjulia"))

            # Import directly from `out`, without installing.
            cmd = addenv(`$python3 -c "import abi_stress_py; print('ok')"`,
                         "PYTHONPATH" => out)
            @test success(run(pipeline(cmd; stderr=stderr, stdout=stdout); wait=true))
        end
    end
end
