# Tests for `MatlabTarget`: the `.m` façades and the MEX gateway.

using JuliaLibWrapping
using Test

include("matlab_blocks.jl")

@testset "sanitize_matlab_name" begin
    @test JuliaLibWrapping.sanitize_matlab_name("stats") == "stats"
    @test JuliaLibWrapping.sanitize_matlab_name("sum-dict") == "sum_dict"

    # MATLAB identifiers begin with a letter, which is stricter than C:
    # `_1` is a legal C field name and a legal Python attribute.
    @test JuliaLibWrapping.sanitize_matlab_name("1") == "x_1"
    @test JuliaLibWrapping.sanitize_matlab_name("") == "x"

    # A reserved word is a syntax error where an identifier is expected.
    @test JuliaLibWrapping.sanitize_matlab_name("end") == "end_"
    @test JuliaLibWrapping.sanitize_matlab_name("for") == "for_"

    # Distinct declared names can sanitize alike; the later one is
    # suffixed rather than shadowing the earlier.
    seen = Set{String}()
    names = [JuliaLibWrapping.sanitize_matlab_name(n) for n in ("a-b", "a_b", "a.b")]
    @test JuliaLibWrapping._uniquify!(names, seen) == ["a_b", "a_b2", "a_b3"]
end

@testset "MatlabTarget" begin
    t = MatlabTarget("out", "boundary", "boundary")
    @test t.package_name == "boundary"
    @test JuliaLibWrapping._matlab_gateway_name(t) == "boundary_mex"
    @test sprint(show, t) == "MatlabTarget(\"out\", \"boundary\", \"boundary\")"
    @test t isa AbstractTarget
    @test t.library_subdir == ""
end

@testset "matlab argument classification" begin
    typeinfo = OrderedDict{Int, TypeDesc}(
        1 => PrimitiveTypeDesc("Float64", true, 64, 8, 8),
        2 => PrimitiveTypeDesc("Int64", true, 64, 8, 8),
        3 => PrimitiveTypeDesc("UInt8", false, 8, 1, 1),
        4 => PointerDesc("Ptr{UInt8}", 3),
        5 => PrimitiveTypeDesc("Int32", true, 32, 4, 4),
        6 => StructDesc(
            "CString{:borrowed}", 16, 8,
            FieldDesc[FieldDesc("length", 5, 0), FieldDesc("data", 4, 8)]
        ),
        7 => StructDesc(
            "CString{:owned}", 16, 8,
            FieldDesc[FieldDesc("length", 5, 0), FieldDesc("data", 4, 8)]
        ),
        8 => PointerDesc("Ptr{Float64}", 1),
        9 => ArrayDesc("NTuple{1, Int32}", 5, 1, 4, 4),
        10 => StructDesc(
            "CArray{:borrowed, Float64, 1}", 16, 8,
            FieldDesc[FieldDesc("dims", 9, 0), FieldDesc("data", 8, 8)]
        ),
        11 => PrimitiveTypeDesc("ComplexF64", false, 128, 16, 8),
    )

    scalar = JuliaLibWrapping._matlab_classify_arg(1, typeinfo)
    @test scalar.kind === :scalar
    @test scalar.class == "double"
    @test scalar.integer === false

    # An integer argument is declared `double` in the façade and converted
    # in the body, so the classification records that it is one.
    @test JuliaLibWrapping._matlab_classify_arg(2, typeinfo).integer === true

    @test JuliaLibWrapping._matlab_classify_arg(6, typeinfo).kind === :string

    array = JuliaLibWrapping._matlab_classify_arg(10, typeinfo)
    @test array.kind === :array
    @test array.class == "double"
    @test array.ndim == 1

    # Arguments are borrowed; an owning carrier in argument position is
    # left unwrapped because the emitter does not guess.
    owning = JuliaLibWrapping._matlab_classify_arg(7, typeinfo)
    @test owning.kind === :opaque
    @test occursin("borrowed", owning.reason)

    # A raw pointer and a scalar with no MATLAB class are both unwrappable.
    @test JuliaLibWrapping._matlab_classify_arg(8, typeinfo).kind === :opaque
    @test JuliaLibWrapping._matlab_classify_arg(11, typeinfo).kind === :opaque
end

@testset "matlab return classification" begin
    typeinfo = OrderedDict{Int, TypeDesc}(
        1 => PrimitiveTypeDesc("Float64", true, 64, 8, 8),
        2 => PrimitiveTypeDesc("Int64", true, 64, 8, 8),
        3 => PrimitiveTypeDesc("UInt8", false, 8, 1, 1),
        4 => PointerDesc("Ptr{UInt8}", 3),
        5 => PrimitiveTypeDesc("Int32", true, 32, 4, 4),
        6 => StructDesc(
            "CString{:owned}", 16, 8,
            FieldDesc[FieldDesc("length", 5, 0), FieldDesc("data", 4, 8)]
        ),
        7 => StructDesc(
            "CString{:borrowed}", 16, 8,
            FieldDesc[FieldDesc("length", 5, 0), FieldDesc("data", 4, 8)]
        ),
        8 => ArrayDesc("NTuple{256, UInt8}", 3, 256, 256, 1),
        9 => StructDesc(
            "JLWStatus", 260, 4,
            FieldDesc[FieldDesc("code", 5, 0), FieldDesc("message", 8, 4)]
        ),
        10 => StructDesc(
            "JLWResult{CString{:owned}}", 280, 8,
            FieldDesc[FieldDesc("status", 9, 0), FieldDesc("value", 6, 264)]
        ),
        11 => StructDesc(
            "Tuple{CString{:owned}, Int64}", 24, 8,
            FieldDesc[FieldDesc("1", 6, 0), FieldDesc("2", 2, 16)]
        ),
        12 => StructDesc(
            "CNTuple{2, Tuple{CString{:owned}, Int64}}", 24, 8,
            FieldDesc[FieldDesc("values", 11, 0)]
        ),
    )

    @test JuliaLibWrapping._matlab_classify_return(9, typeinfo, true).kind === :void
    # A bare `JLWStatus` is `:void`; no return type at all is `:none`.
    @test JuliaLibWrapping._matlab_classify_return(nothing, typeinfo, true).kind === :none

    owned = JuliaLibWrapping._matlab_classify_return(6, typeinfo, true)
    @test owned.kind === :string
    @test owned.owns === true

    # A borrowed return is the caller's storage passed straight back, so
    # releasing it would free memory it does not own.
    borrowed = JuliaLibWrapping._matlab_classify_return(7, typeinfo, true)
    @test borrowed.kind === :string
    @test borrowed.owns === false

    # `JLWResult` carries the status; the payload classifies underneath it
    # and the ownership travels up.
    wrapped = JuliaLibWrapping._matlab_classify_return(10, typeinfo, true)
    @test wrapped.kind === :result
    @test wrapped.inner.kind === :string
    @test wrapped.owns === true

    # A tuple owns storage when any element does, which is what the
    # gateway's release loop reads.
    tuple_ret = JuliaLibWrapping._matlab_classify_return(12, typeinfo, true)
    @test tuple_ret.kind === :tuple
    @test [e.kind for e in tuple_ret.elements] == [:string, :scalar]
    @test [e.owns for e in tuple_ret.elements] == [true, false]
    @test tuple_ret.owns === true
    @test tuple_ret.fields == ["1", "2"]

    # Without the release entrypoints there is nothing for the gateway to
    # call, so an owning return is left unwrapped rather than leaked.
    nofree = JuliaLibWrapping._matlab_classify_return(6, typeinfo, false)
    @test nofree.kind === :opaque
    @test occursin("release entrypoints", nofree.reason)
    @test JuliaLibWrapping._matlab_classify_return(12, typeinfo, false).kind === :opaque

    # A borrowed return needs no release, so it is unaffected.
    @test JuliaLibWrapping._matlab_classify_return(7, typeinfo, false).kind === :string
end

@testset "matlab facade emission" begin
    abi = read_abi_info("bindinginfo_ctuple.json")
    mktempdir() do path
        emitted = write_wrapper(MatlabTarget(path, "ctuple_demo", "libctuple"), abi)
        # The release entrypoints are the gateway's business, so they get
        # no façade even though they are exported.
        @test emitted == ["bundle", "pair", "stats"]

        for name in emitted
            actual = read(joinpath(path, "+ctuple_demo", name * ".m"), String)
            golden = read(joinpath(@__DIR__, "expected_matlab_" * name * ".m"), String)
            @test actual == golden
        end

        # A package directory, so a façade is called as `ctuple_demo.stats()`
        # and cannot collide with a name already on the MATLAB path.
        @test isdir(joinpath(path, "+ctuple_demo", "private"))
    end
end

@testset "matlab facade goldens per argument kind" begin
    # One façade per argument kind, frozen. The tuple fixture's entry
    # points take no arguments, so without these the validation, the
    # guards and the forwarding are pinned by nothing.
    picks = [
        ("cstring", "greeting_length"), ("cstrarray", "take_strs"),
        ("cdict", "take_dict"), ("copt", "take_opt"),
        ("cmatrix", "trace_cmatrix"), ("carray3", "sum3d"),
    ]
    for (fixture, name) in picks
        abi = read_abi_info("bindinginfo_" * fixture * ".json")
        mktempdir() do path
            write_wrapper(MatlabTarget(path, "demo", "libdemo"), abi)
            actual = read(joinpath(path, "+demo", name * ".m"), String)
            golden = read(joinpath(@__DIR__, "expected_matlab_" * name * ".m"), String)
            @test actual == golden
        end
    end
end

@testset "matlab gateway golden" begin
    # The gateway compiles under `-Werror`, but that says nothing about
    # what it does. A release dropped or reordered would still compile,
    # so the text is frozen too.
    abi = read_abi_info("bindinginfo_ctuple.json")
    mktempdir() do path
        write_wrapper(MatlabTarget(path, "ctuple_demo", "libctuple"), abi)
        @test read(joinpath(path, "libctuple_mex.c"), String) ==
            read(joinpath(@__DIR__, "expected_matlab_gateway.c"), String)
        @test read(joinpath(path, "build_mex.m"), String) ==
            read(joinpath(@__DIR__, "expected_matlab_build.m"), String)
    end

end

@testset "matlab helper golden" begin
    # `ctuple`'s entry points take no arguments, so the gateway golden
    # pins none of the conversions that read an `mxArray`. This one holds
    # every helper and handler the fixtures produce between them.
    @test matlab_emitted_blocks(@__DIR__) ==
        read(joinpath(@__DIR__, "expected_matlab_helpers.c"), String)
end

@testset "matlab facade from sidecar metadata" begin
    # The tuple fixture's entry points take no arguments, so the keyword,
    # default and enum paths need a declaration that has some.
    abi = read_abi_info("bindinginfo_enum.json")
    meta = Dict{String, Any}(
        "EnumFixture_scale_by" => Dict{String, Any}(
            "name" => "scale_by",
            "args" => ["x"],
            "kwargs" => [Dict{String, Any}("name" => "penalty", "default" => "abslog1")],
            "arg_enums" => Dict{String, Any}("penalty" => "PenaltyKind"),
            "doc" => "Scale `x`.",
        ),
        "EnumFixture_pick" => Dict{String, Any}(
            "name" => "pick",
            "args" => ["x"],
            "kwargs" => [],
            "return_enum" => "PenaltyKind",
            "doc" => "Classify `x`.",
        ),
    )
    enums = Dict{String, Any}(
        "PenaltyKind" => Dict{String, Any}(
            "basetype" => "Int32",
            "members" => [
                Dict{String, Any}("name" => "abslog1", "value" => 0),
                Dict{String, Any}("name" => "square", "value" => 1),
            ],
        ),
    )
    mktempdir() do path
        write_wrapper(
            MatlabTarget(path, "demo", "libdemo"), abi;
            api_metadata = meta, api_enums = enums
        )
        src = read(joinpath(path, "+demo", "scale_by.m"), String)

        # The sidecar's public name and argument names, not the ABI's.
        @test occursin("function out = scale_by(x, opts)", src)
        @test occursin("%SCALE_BY  Scale `x`.", src)

        # A keyword becomes a name-value argument carrying its default.
        @test occursin("opts.penalty = \"abslog1\"", src)

        # An enum takes a member name or the integer, so it carries no
        # class declaration and the body translates it.
        @test occursin("switch string(opts.penalty)", src)
        @test occursin("case \"abslog1\"; penalty_ = int32(0);", src)
        @test occursin("if isnumeric(opts.penalty) && isscalar(opts.penalty)", src)
        @test occursin("libdemo_mex('EnumFixture_scale_by', x, penalty_)", src)

        # An enum return comes back as the member name, which is a form
        # the façades accept, so a result can be passed straight back in.
        pick = read(joinpath(path, "+demo", "pick.m"), String)
        @test occursin("case 0; out = \"abslog1\";", pick)
    end
end

@testset "matlab gateway emission" begin
    abi = read_abi_info("bindinginfo_ctuple.json")
    mktempdir() do path
        write_wrapper(MatlabTarget(path, "ctuple_demo", "libctuple"), abi)
        gateway = read(joinpath(path, "libctuple_mex.c"), String)

        # Opened, never closed: `clear mex` unloads this file, and
        # reloading the library would run `jl_init` twice in one process.
        @test occursin("RTLD_NODELETE", gateway)
        @test !occursin("dlclose", gateway)

        # Dispatch is by name, from `char`.
        @test occursin("strcmp(name, \"stats\") == 0", gateway)

        # Every element of a tuple is converted, which is also what
        # releases Julia's storage for it, before any assignment: a caller
        # asking for one output of two must not leak the other.
        @test occursin("mxArray *out1 = jlw_out_CVector_owned_Float64", gateway)
        @test occursin("mxDestroyArray(out2);", gateway)

        # The inline-array form of a tuple is reached by index, the
        # named form by field.
        @test occursin("result.value.values[0]", gateway)
        @test occursin("result.value.values._1", gateway)

        # By default an array argument borrows MATLAB's buffer, so a
        # wrapped function that writes to it corrupts every variable
        # sharing that buffer.
        @test !occursin("mxDuplicateArray", gateway)

        # A build script that compiles it. Emitting it needs no MATLAB.
        build = read(joinpath(path, "build_mex.m"), String)
        @test occursin("mex('-R2018a'", build)
        @test occursin("'private'", build)
    end
end

@testset "standard_build target list" begin
    # A C header and a Python package by default, as before.
    default = JuliaLibWrapping._standard_targets(
        "out", "demo", "demo_py", nothing, true, "0.0.0"
    )
    @test map(typeof, default) == [CTarget, PythonTarget]

    # MATLAB is opt-in: its sources need `mex` run against them before
    # they can be called, which a build does not do.
    with_matlab = JuliaLibWrapping._standard_targets(
        "out", "demo", "demo_py", "demo", true, "0.0.0"
    )
    @test map(typeof, with_matlab) == [CTarget, PythonTarget, MatlabTarget]
    matlab = last(with_matlab)
    @test matlab.package_name == "demo"
    @test matlab.library_basename == "demo"
    @test matlab.library_subdir == joinpath("demo-bundle", "lib")
end

@testset "targets that read the sidecar" begin
    # `build_library` asks this before deciding what to hand a target. A
    # target that reads the sidecar but answers `false` gets the ABI alone
    # and silently loses its public names, keyword defaults, and
    # docstrings.
    @test JuliaLibWrapping.accepts_api_metadata(
        PythonTarget("out", "demo_py", "demo")
    )
    @test JuliaLibWrapping.accepts_api_metadata(MatlabTarget("out", "demo", "demo"))

    # A C header carries no names beyond the ABI's, so it needs nothing.
    @test !JuliaLibWrapping.accepts_api_metadata(CTarget("out", "demo"))
end

@testset "matlab mutated arguments" begin
    # An argument the declaration writes to is copied for the call and
    # returned, because MATLAB's value semantics do not let a write reach
    # the caller. Everything else is passed by reference.
    abi = read_abi_info("bindinginfo_carray3.json")
    entry = Dict{String, Any}(
        "name" => "sum3d", "args" => ["a"], "kwargs" => [],
        "mutates" => ["a"], "doc" => "",
    )
    meta = Dict{String, Any}("sum3d" => entry)
    mktempdir() do path
        write_wrapper(
            MatlabTarget(path, "demo", "libdemo"), abi; api_metadata = meta
        )
        gateway = read(joinpath(path, "libdemo_mex.c"), String)
        @test occursin("mxArray *copy1 = mxDuplicateArray(prhs[1]);", gateway)
        @test occursin("jlw_in_CArray_borrowed_Float64_3(copy1)", gateway)

        # Two outputs now: the copy, then what the function returns.
        @test occursin("int wanted = nlhs < 1 ? 1 : nlhs;", gateway)
        @test occursin("at most 2 outputs", gateway)
        @test occursin("plhs[0] = copy1;", gateway)

        facade = read(joinpath(path, "+demo", "sum3d.m"), String)
        @test occursin("function [a, out] = sum3d(a)", facade)
        @test occursin("Writes to A and returns it.", facade)
    end

    # A vector is passed as it stands rather than through `(:)`, so a caller
    # who passes a row gets a row back.
    vabi = read_abi_info("bindinginfo_api_scale.json")
    ventry = Dict{String, Any}(
        "name" => "scale!", "args" => ["y", "k", "label"], "kwargs" => [],
        "mutates" => ["y"], "doc" => "",
    )
    mktempdir() do path
        @test_logs (:warn, r"copies y and returns the copy") write_wrapper(
            MatlabTarget(path, "demo", "libdemo"), vabi;
            api_metadata = Dict{String, Any}("mylib_scale" => ventry)
        )
        facade = read(joinpath(path, "+demo", "scale.m"), String)
        @test occursin("libdemo_mex('mylib_scale', y, k,", facade)
        @test !occursin("y(:)", facade)
    end

    # Without the declaration the argument is passed by reference and
    # nothing is copied.
    mktempdir() do path
        write_wrapper(MatlabTarget(path, "demo", "libdemo"), abi)
        gateway = read(joinpath(path, "libdemo_mex.c"), String)
        @test !occursin("mxDuplicateArray", gateway)
    end
end

@testset "matlab carrier widths and guards" begin
    # The width comes from the ABI. `mwSize` is unsigned and 64-bit, so a
    # count that will not fit a 32-bit field is refused, not wrapped.
    mktempdir() do path
        # `carray_bool` declares 32-bit dims, so it needs a guard.
        write_wrapper(
            MatlabTarget(path, "demo", "libdemo"),
            read_abi_info("bindinginfo_carray_bool.json")
        )
        gateway = read(joinpath(path, "libdemo_mex.c"), String)
        @test occursin("mxGetNumberOfElements(value) > INT32_MAX", gateway)
        @test occursin("carrier.dims[0] = (int32_t)", gateway)
    end
    mktempdir() do path
        # `cstrarray` declares 64-bit lengths, so it needs none.
        write_wrapper(
            MatlabTarget(path, "demo", "libdemo"),
            read_abi_info("bindinginfo_cstrarray.json")
        )
        gateway = read(joinpath(path, "libdemo_mex.c"), String)
        @test occursin("carrier.length = (int64_t)count;", gateway)
        @test occursin("items[i].length = (int64_t)size;", gateway)
        @test !occursin("INT32_MAX", gateway)
    end
end

@testset "matlab loader and names" begin
    abi = read_abi_info("bindinginfo_ctuple.json")
    mktempdir() do path
        write_wrapper(MatlabTarget(path, "demo", "libdemo"), abi)
        gateway = read(joinpath(path, "libdemo_mex.c"), String)

        # Julia's runtime leaves inherited pipes non-blocking, which
        # MATLAB's own reads then see as errors.
        @test occursin("jlw_save_stdio()", gateway)
        @test occursin("jlw_restore_stdio(saved);", gateway)

        # A failure says why, so a missing dependency reads differently
        # from a wrong path.
        @test occursin("dlerror()", gateway)

        # Local: entry points come through the handle, so the global
        # namespace buys nothing and would carry this library's
        # unversioned names into a second one's reach.
        @test occursin("dlopen(path, RTLD_LAZY | RTLD_NODELETE)", gateway)
        @test !occursin("RTLD_GLOBAL", gateway)

    end

    # A sparse struct field passes a class check and has no dense buffer
    # to read; the fixture needs a dictionary *argument* to show it.
    mktempdir() do path
        write_wrapper(
            MatlabTarget(path, "demo", "libdemo"),
            read_abi_info("bindinginfo_cdict.json")
        )
        @test occursin(
            "mxIsSparse(field)", read(joinpath(path, "libdemo_mex.c"), String)
        )
    end

    # A library basename that is not an identifier still has to produce a
    # gateway the façades can call.
    @test JuliaLibWrapping._matlab_gateway_name(
        MatlabTarget("out", "demo", "lib-foo.2")
    ) == "lib_foo_2_mex"
end

@testset "matlab facade name collisions" begin
    # Two symbols can sanitize to one façade name. Writing both would
    # leave one file and one callable function, silently.
    typeinfo = OrderedDict{Int, TypeDesc}(
        1 => PrimitiveTypeDesc("Float64", true, 64, 8, 8)
    )
    methods = [
        JuliaLibWrapping.MethodDesc("a.b", "a.b()", 1, JuliaLibWrapping.ArgDesc[]),
        JuliaLibWrapping.MethodDesc("a-b", "a-b()", 1, JuliaLibWrapping.ArgDesc[]),
    ]
    abi = ABIInfo(typeinfo, BitSet(), methods)
    mktempdir() do path
        @test_throws "claimed by both" write_wrapper(
            MatlabTarget(path, "demo", "libdemo"), abi
        )
    end
end

@testset "matlab enum return rejects an unknown value" begin
    abi = read_abi_info("bindinginfo_enum.json")
    meta = Dict{String, Any}(
        "EnumFixture_pick" => Dict{String, Any}(
            "name" => "pick", "args" => ["x"], "kwargs" => [],
            "return_enum" => "PenaltyKind", "doc" => "",
        ),
    )
    enums = Dict{String, Any}(
        "PenaltyKind" => Dict{String, Any}(
            "basetype" => "Int32",
            "members" => [Dict{String, Any}("name" => "abslog1", "value" => 0)],
        ),
    )
    mktempdir() do path
        write_wrapper(
            MatlabTarget(path, "demo", "libdemo"), abi;
            api_metadata = meta, api_enums = enums
        )
        src = read(joinpath(path, "+demo", "pick.m"), String)
        # A value outside the enum means the library and these bindings
        # disagree, which is worth saying rather than passing through.
        @test occursin("otherwise", src)
        @test occursin("is not a known enum value", src)
    end
end


@testset "matlab tuple validates dict keys first" begin
    # A dictionary's keys are runtime data from Julia. Converting an
    # element is also what releases it, so a bad key found part-way
    # through a tuple would strand every element not yet reached.
    abi = read_abi_info("bindinginfo_ctuple.json")
    mktempdir() do path
        write_wrapper(MatlabTarget(path, "demo", "libdemo"), abi)
        gateway = read(joinpath(path, "libdemo_mex.c"), String)
        handler = gateway[findfirst("jlw_call_bundle", gateway)[1]:end]
        handler = handler[1:findfirst("\nstatic", handler)[1]]

        keys_at = findfirst("not a legal MATLAB field name", handler)
        convert_at = findfirst("mxArray *out1 =", handler)
        @test !isnothing(keys_at) && !isnothing(convert_at)
        @test first(keys_at) < first(convert_at)

        # And the raise releases the whole tuple, not just the dict.
        @test occursin("jlw_release_strings", handler)
    end
end

@testset "matlab argument validation details" begin
    abi = read_abi_info("bindinginfo_enum.json")
    meta = Dict{String, Any}(
        "EnumFixture_scale_by" => Dict{String, Any}(
            "name" => "scale_by", "args" => ["opts"],
            "kwargs" => [Dict{String, Any}("name" => "penalty", "default" => 0)],
            "doc" => "",
        ),
    )
    mktempdir() do path
        write_wrapper(
            MatlabTarget(path, "demo", "libdemo"), abi;
            api_metadata = meta, api_enums = Dict{String, Any}()
        )
        src = read(joinpath(path, "+demo", "scale_by.m"), String)
        # Keywords arrive as a struct named `opts`, so a positional
        # argument of that name must not shadow it.
        @test !occursin("function out = scale_by(opts, opts)", src)
        @test occursin("opts2", src)
    end
end

@testset "matlab library resolution" begin
    abi = read_abi_info("bindinginfo_ctuple.json")
    mktempdir() do path
        write_wrapper(MatlabTarget(path, "demo", "libdemo"), abi)

        # The gateway emits the carrier typedefs it needs, so a build
        # with no `CTarget` still produces something that compiles.
        @test isfile(joinpath(path, "libdemo_mex_types.h"))
        # Its own name, so it is visibly this target's file rather than
        # an overwrite of the C target's header.
        @test !isfile(joinpath(path, "libdemo.h"))

        gateway = read(joinpath(path, "libdemo_mex.c"), String)
        # A bare name resolves against MATLAB's working directory, not the
        # library, and `$ORIGIN` is the MEX file's own directory, where the
        # library is not.
        @test !occursin("\$ORIGIN", gateway)
        @test occursin("#define JLW_LIBRARY_PATH", gateway)
        @test occursin("getenv(JLW_LIBRARY_ENV)", gateway)
        @test occursin("#define JLW_LIBRARY_ENV \"LIBDEMO_MEX_LIBRARY\"", gateway)

        # The build script compiles the path in, and takes a directory so
        # the library can stay next to the runtime its RUNPATH names.
        build = read(joinpath(path, "build_mex.m"), String)
        @test occursin("function build_mex(library_dir)", build)
        @test occursin("-DJLW_LIBRARY_PATH=", build)
        # With no subdirectory the library sits beside the script.
        @test occursin("library_dir = here;", build)
    end

    # A bundled build keeps the library next to the runtime its RUNPATH
    # names, so the script defaults there instead.
    mktempdir() do path
        write_wrapper(
            MatlabTarget(
                path, "demo", "libdemo";
                library_subdir = joinpath("libdemo-bundle", "lib")
            ),
            abi
        )
        build = read(joinpath(path, "build_mex.m"), String)
        @test occursin("fullfile(here, 'libdemo-bundle', 'lib')", build)
    end
end

@testset "matlab void return" begin
    # A hand-written `Base.@ccallable f(x)::Cvoid` has no return type at
    # all, which is not the same as a `JLWStatus`: there is no value to
    # name or to check.
    typeinfo = OrderedDict{Int, TypeDesc}(
        1 => PrimitiveTypeDesc("Float64", true, 64, 8, 8)
    )
    method = JuliaLibWrapping.MethodDesc(
        "poke", "poke(x::Float64)", nothing,
        [JuliaLibWrapping.ArgDesc("x", 1, false)]
    )
    abi = ABIInfo(typeinfo, BitSet(), [method])
    @test JuliaLibWrapping._matlab_classify_return(nothing, typeinfo, true).kind ===
        :none

    compiler = Sys.which("cc")
    mktempdir() do path
        write_wrapper(MatlabTarget(path, "demo", "libdemo"), abi)
        gateway = read(joinpath(path, "libdemo_mex.c"), String)
        @test !occursin("void result", gateway)
        @test occursin("jlw_symbol(\"poke\")", gateway)

        if !isnothing(compiler)
            cp(joinpath(@__DIR__, "mex_stub.h"), joinpath(path, "mex.h"))
            command = `$compiler -fsyntax-only -Wall -Wextra -Werror -I$path
                           $(joinpath(path, "libdemo_mex.c"))`
            @test success(run(pipeline(command; stdout = stdout, stderr = stderr); wait = true))
        end
    end
end

@testset "matlab dictionary field names" begin
    # A MATLAB field name starts with a letter. The check exists to raise
    # while nothing is held, so a name it lets through would reach
    # `mxCreateStructMatrix` with the carrier live.
    abi = read_abi_info("bindinginfo_cdict.json")
    mktempdir() do path
        write_wrapper(MatlabTarget(path, "demo", "libdemo"), abi)
        gateway = read(joinpath(path, "libdemo_mex.c"), String)
        # Emitted once and called from both the dictionary helper and a
        # tuple holding one, so a fix lands in a single place.
        @test occursin("static int jlw_valid_field_name(", gateway)
        @test occursin("if (!(j == 0 ? alpha : (alpha || rest))) {", gateway)
        @test occursin("jlw_valid_field_name(carrier.keys[i].data", gateway)
    end
end

@testset "matlab text returns" begin
    # `mxCreateString` builds a char row, so a string and a list of them
    # agree: char, and a cell array of char rows. Both are forms a façade
    # accepts, so a result feeds back into the next call.
    helpers = read(joinpath(@__DIR__, "expected_matlab_helpers.c"), String)
    for name in ("jlw_out_CString_owned", "jlw_out_CString_borrowed")
        body = helpers[findfirst("static mxArray *" * name, helpers)[1]:end]
        body = body[1:first(findfirst("\n}", body))]
        @test occursin("mxCreateString(text)", body)
    end
    strarray = helpers[findfirst("static mxArray *jlw_out_CStrArray_owned", helpers)[1]:end]
    strarray = strarray[1:first(findfirst("\n}", strarray))]
    @test occursin("mxCreateCellMatrix", strarray)
    @test occursin("mxSetCell(out, (mwSize)i, mxCreateString(text));", strarray)
end

@testset "matlab skipped entry points" begin
    # Python re-exports what it cannot wrap, so nothing is lost silently
    # there. Here the entry point is absent from the package, so the
    # build says which one and why.
    abi = read_abi_info("bindinginfo_rawptr.json")
    mktempdir() do path
        @test_logs (:warn, r"no MATLAB façade for sum_doubles: argument 1") match_mode = :any write_wrapper(
            MatlabTarget(path, "demo", "libdemo"), abi
        )
        @test !isfile(joinpath(path, "+demo", "sum_doubles.m"))
    end
end

@testset "matlab integer arrays" begin
    # An integer or logical array carries no class, so MATLAB hands over
    # the array the caller built rather than converting it at the door.
    # The body converts, which costs nothing when the class already
    # matches. `logical(2)` is `true`, so a logical array takes 0 and 1
    # only.
    abi = read_abi_info("bindinginfo_carray_bool.json")
    mktempdir() do path
        write_wrapper(MatlabTarget(path, "demo", "libdemo"), abi)
        src = read(joinpath(path, "+demo", "mylib_count_true.m"), String)
        @test occursin("v {mustBeNumericOrLogical, mustBeMember(v, [0 1])", src)
        @test !occursin("v double", src)
        @test occursin("logical(v(:))", src)
    end

    # No fixture takes an integer scalar or an optional integer, so the
    # declarations are checked here directly.
    validation(kind) = JuliaLibWrapping._matlab_arg_validation(kind, "a")
    @test validation((kind = :scalar, class = "int64", integer = true)) ==
        "(1,1) {mustBeNumericOrLogical, mustBeInteger}"
    @test validation((kind = :opt, class = "int32", integer = true)) ==
        "(:,:) {mustBeNumericOrLogical, mustBeInteger}"
    @test validation(
        (kind = :array, class = "uint8", ndim = 2, integer = true, dims_bits = 64)
    ) == "{mustBeNumericOrLogical, mustBeInteger}"

    # A float argument still names its class: the carrier wants doubles,
    # and converting an integer array to one is the caller's cost either
    # way.
    @test validation((kind = :scalar, class = "double", integer = false)) ==
        "(1,1) double"
end

@testset "matlab keyword default of nothing" begin
    # A recorded default of `nothing` is a default. Reading it as
    # "no default" would make the keyword required.
    abi = read_abi_info("bindinginfo_copt.json")
    meta = Dict{String, Any}(
        "take_opt" => Dict{String, Any}(
            "name" => "take_opt", "args" => String[],
            "kwargs" => [Dict{String, Any}("name" => "o", "default" => nothing)],
            "doc" => "",
        ),
    )
    mktempdir() do path
        write_wrapper(
            MatlabTarget(path, "demo", "libdemo"), abi;
            api_metadata = meta, api_enums = Dict{String, Any}()
        )
        @test occursin(
            "opts.o (:,:) double = []",
            read(joinpath(path, "+demo", "take_opt.m"), String)
        )
    end
end

@testset "matlab gateway compiles" begin
    # Every fixture, not one: the gateway's shape depends on which
    # carriers an ABI happens to contain, so checking a single one
    # leaves whole branches of the emitter uncompiled. A stand-in for
    # `mex.h` is what makes this possible without MATLAB installed.
    compiler = Sys.which("cc")
    if isnothing(compiler)
        @info "Skipping MATLAB gateway compile check (no cc)"
    else
        fixtures = filter(
            name -> startswith(name, "bindinginfo_") && endswith(name, ".json"),
            readdir(@__DIR__)
        )
        @test !isempty(fixtures)
        for fixture in fixtures
            abi = read_abi_info(fixture)
            mktempdir() do path
                # No `CTarget` here on purpose: the MATLAB target emits
                # the header its gateway needs, so it stands alone.
                write_wrapper(MatlabTarget(path, "demo", "libdemo"), abi)
                cp(joinpath(@__DIR__, "mex_stub.h"), joinpath(path, "mex.h"))
                source = joinpath(path, "libdemo_mex.c")
                command = `$compiler -fsyntax-only -Wall -Wextra -Werror -I$path $source`
                process = run(pipeline(command; stdout = stdout, stderr = stderr); wait = true)
                success(process) || @error "gateway failed to compile" fixture
                @test success(process)
            end
        end
    end
end
