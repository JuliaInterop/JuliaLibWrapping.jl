using JuliaLibWrapping
using OrderedCollections
using JSON: parsefile
using Test
using Aqua
using ExplicitImports

import JuliaLibWrapping: StructDesc, FieldDesc, PointerDesc, PrimitiveTypeDesc, ArrayDesc, TypeDesc
import JuliaLibWrapping: sort_declarations!, mangle_c!

function onlymatch(f, collection)
    matches = filter(f, collection)
    if length(matches) != 1
        error("Expected exactly one match, found $(length(matches))")
    end
    return matches[1]
end

# The body of one emitted `ctypes.Structure` class, up to the next class.
function classbody(bindings::AbstractString, name::AbstractString)
    header = "class " * name * "(ctypes.Structure):"
    range = findfirst(header, bindings)
    isnothing(range) && error("no class named `", name, "` in the emitted bindings")
    rest = SubString(bindings, last(range) + 1)
    stop = findfirst("\nclass ", rest)
    return isnothing(stop) ? rest : SubString(rest, 1, first(stop) - 1)
end

@testset "JuliaLibWrapping.jl" begin
    @testset "parse_abi_info" begin
        abi_info = parse_abi_info(parsefile("bindinginfo_libsimple.json"))
        (; entrypoints, typeinfo) = abi_info

        methdesc = onlymatch(md -> md.symbol == "copyto_and_sum", entrypoints)
        @test typeinfo[methdesc.return_type].name == "Float32"
        @test length(methdesc.args) == 1
        argdesc = only(methdesc.args)
        @test argdesc.name == "fromto"
        @test typeinfo[argdesc.type].name == "CVectorPair{Float32}"
        @test argdesc.isva == false

        methdesc = onlymatch(md -> md.symbol == "countsame", entrypoints)
        @test typeinfo[methdesc.return_type].name == "Int32"
        @test length(methdesc.args) == 2
        argdesc1, argdesc2 = methdesc.args
        @test argdesc1.name == "list"
        @test typeinfo[argdesc1.type].name == "Ptr{MyTwoVec}"
        @test argdesc1.isva == false
        @test argdesc2.name == "n"
        @test typeinfo[argdesc2.type].name == "Int32"
        @test argdesc2.isva == false

        @test length(typeinfo) >= 3
        findtype(descs, name) = (k = collect(keys(descs)); k[findfirst((id) -> descs[id].name === name, k)])

        tdesc = typeinfo[findtype(typeinfo, "CVectorPair{Float32}")]
        @test tdesc.name == "CVectorPair{Float32}"
        @test length(tdesc.fields) == 2
        @test tdesc.fields[1].name == "from"
        @test typeinfo[tdesc.fields[1].type].name == "CVector{:borrowed, Float32}"
        @test tdesc.fields[1].offset == 0
        @test tdesc.fields[2].name == "to"
        @test typeinfo[tdesc.fields[2].type].name == "CVector{:borrowed, Float32}"
        @test tdesc.fields[2].offset == 16
        @test tdesc.size == 32
        tdesc = typeinfo[findtype(typeinfo, "CVector{:borrowed, Float32}")]
        @test tdesc.name == "CVector{:borrowed, Float32}"
        @test length(tdesc.fields) == 2
        @test tdesc.fields[1].name == "dims"
        dims_desc = typeinfo[tdesc.fields[1].type]
        @test dims_desc isa ArrayDesc
        @test dims_desc.count == 1
        @test typeinfo[dims_desc.element_type].name == "Int32"
        @test iszero(tdesc.fields[1].offset)
        @test tdesc.fields[2].name == "data"
        @test typeinfo[tdesc.fields[2].type].name == "Ptr{Float32}"
        @test tdesc.fields[2].offset == 8
        @test tdesc.size == 16
        tdesc = typeinfo[findtype(typeinfo, "MyTwoVec")]
        @test tdesc.name == "MyTwoVec"
        @test length(tdesc.fields) == 2
        @test tdesc.fields[1].name == "x"
        @test typeinfo[tdesc.fields[1].type].name == "Int32"
        @test tdesc.fields[1].offset == 0
        @test tdesc.fields[2].name == "y"
        @test typeinfo[tdesc.fields[2].type].name == "Int32"
        @test tdesc.fields[2].offset == 4
        @test tdesc.size == 8
        name2idx = Dict(desc.name => i for (i, desc) in enumerate(values(typeinfo)))
        @test name2idx["CVectorPair{Float32}"] > name2idx["CVector{:borrowed, Float32}"]
    end

    @testset "parse_abi_info: null Cvoid encoding" begin
        # JuliaC (JuliaLang/JuliaC.jl#122) encodes `Cvoid` returns and
        # `Ptr{Cvoid}` pointees as `null` type ids instead of a type node —
        # mirroring C, where `void` is not a type. The importer keeps that
        # shape: a `nothing` return type / pointee, and no `Cvoid` entry in
        # the type dictionary.
        abi = read_abi_info("bindinginfo_cvoid.json")
        (; entrypoints, typeinfo) = abi

        @test length(typeinfo) == 4
        @test !any(
            desc isa PrimitiveTypeDesc && desc.name == "Cvoid"
            for desc in values(typeinfo)
        )

        # `zero_first(p::Ptr{Cvoid}, n::Int32)::Cvoid`: null return and null
        # pointee both map to `nothing`.
        zero_first = onlymatch(md -> md.symbol == "zero_first", entrypoints)
        @test zero_first.return_type === nothing
        p_desc = typeinfo[zero_first.args[1].type]
        @test p_desc isa PointerDesc
        @test p_desc.pointee_type === nothing

        # `chunk_table()::Ptr{Ptr{Cvoid}}`: only the innermost pointee is
        # null; the outer pointer still references the inner one by id.
        chunk_table = onlymatch(md -> md.symbol == "chunk_table", entrypoints)
        rt_desc = typeinfo[chunk_table.return_type]
        @test rt_desc isa PointerDesc
        inner_desc = typeinfo[rt_desc.pointee_type]
        @test inner_desc isa PointerDesc
        @test inner_desc.pointee_type === nothing

        # The C emitter renders `nothing` as `void`, including for a
        # `Ptr{Cvoid}` struct field (which must not pick up a bogus
        # `struct ` prefix).
        mktempdir() do path
            dest = CTarget(path, "libcvoid")
            write_wrapper(dest, abi)
            content = read(joinpath(path, "libcvoid.h"), String)
            @test occursin("void zero_first(void* p, int32_t n);", content)
            @test occursin("void* next_chunk(Handle h);", content)
            @test occursin("void** chunk_table();", content)
            @test occursin("void* h;", content)
            @test !occursin("struct void", content)
            @test !occursin("Nothing", content)
        end

        # The Python emitter renders a `nothing` return as a `None` restype
        # and collapses a `nothing` pointee to `ctypes.c_void_p`.
        mktempdir() do path
            dest = PythonTarget(path, "libcvoid", "libcvoid")
            write_wrapper(dest, abi)
            bindings = read(joinpath(path, "libcvoid", "_lowlevel.py"), String)
            @test occursin("_lib.zero_first.argtypes = [ctypes.c_void_p, ctypes.c_int32]", bindings)
            @test occursin("_lib.zero_first.restype = None", bindings)
            @test occursin("_lib.next_chunk.restype = ctypes.c_void_p", bindings)
            @test occursin(
                "_lib.chunk_table.restype = ctypes.POINTER(ctypes.c_void_p)",
                bindings
            )
            @test occursin("(\"h\", ctypes.c_void_p)", bindings)
        end
    end

    @testset "parse_abi_info: malformed input" begin
        # Int32 id exercises the platform-tolerant integer handling (this is what
        # 32-bit Julia hands you for an unannotated `1` literal).
        bad = Dict{String, Any}(
            "types" => Any[Dict{String, Any}("id" => Int32(1), "kind" => "nonsense", "name" => "X")],
            "functions" => Any[],
        )
        @test_throws "unexpected kind 'nonsense'" parse_abi_info(bad)
    end

    @testset "read_abi_info" begin
        from_file = read_abi_info("bindinginfo_libsimple.json")
        from_dict = parse_abi_info(parsefile("bindinginfo_libsimple.json"))
        from_io = open(read_abi_info, "bindinginfo_libsimple.json")
        for other in (from_dict, from_io)
            @test collect(keys(from_file.typeinfo)) == collect(keys(other.typeinfo))
            @test from_file.forward_declared == other.forward_declared
            @test length(from_file.entrypoints) == length(other.entrypoints)
        end
    end

    @testset "sort_declarations!" begin
        unsorted = OrderedDict{Int, TypeDesc}(
            1 => StructDesc(
                "test_struct1",
                0, # size
                0, # alignment
                FieldDesc[
                    FieldDesc("field1", #= type =# 2, #= offset =# 0),
                    FieldDesc("field2", #= type =# 3, #= offset =# 0),
                ],
            ),
            2 => StructDesc(
                "test_struct2",
                0, # size
                0, # alignment
                FieldDesc[
                    FieldDesc("field1", #= type =# 3, #= offset =# 0),
                    FieldDesc("field2", #= type =# 3, #= offset =# 0),
                ],
            ),
            3 => PrimitiveTypeDesc("UInt16", false, 16, 2, 2),
        )
        sorted = copy(unsorted)
        fwd_decls = sort_declarations!(sorted)

        # No recursive types, so this should require no forward declarations
        @test isempty(fwd_decls)
        # There is only one order that these types could be defined such that
        # dependencies are defined before they are used.
        @test collect(keys(sorted)) == Int[3, 2, 1]

        unsorted = OrderedDict{Int, TypeDesc}(
            1 => StructDesc(
                "test_struct1",
                0, # size
                0, # alignment
                FieldDesc[
                    FieldDesc("field1", #= type =# 2, #= offset =# 0),
                    FieldDesc("field2", #= type =# 5, #= offset =# 0),
                ],
            ),
            2 => PointerDesc("pointer1", #= pointee_type =# 3),
            3 => StructDesc(
                "test_struct2",
                0, # size
                0, # alignment
                FieldDesc[
                    FieldDesc("field1", #= type =# 5, #= offset =# 0),
                    FieldDesc("field2", #= type =# 5, #= offset =# 0),
                ],
            ),
            4 => PointerDesc("pointer2", #= pointee_type =# 1),
            5 => PrimitiveTypeDesc("UInt16", false, 16, 2, 2),
        )
        sorted = copy(unsorted)
        fwd_decls = sort_declarations!(sorted)

        # We added a pointer indirection, but it's non-recursive so we should
        # require no forward declarations
        @test isempty(fwd_decls)

        # Once again, there is only one order that we can emit these definitions
        @test collect(keys(sorted)) == Int[5, 3, 2, 1, 4]

        # Modify the type definitions so that test_struct1 and test_struct2 are
        # mutually recursive.
        unsorted[3].fields[1] = FieldDesc("field1", #= type =# 4, #= offset =# 0)

        sorted = copy(unsorted)
        fwd_decls = sort_declarations!(sorted)

        # At least one of the struct types should need to be forward-declared
        @test !isempty(fwd_decls)
        if fwd_decls == BitSet([1])
            # If 1 was forward-declared then 3 (and pointer to 1) is defined first
            @test collect(keys(sorted)) == Int[5, 4, 3, 2, 1]
        elseif fwd_decls == BitSet([3])
            # If 3 was forward-declared then 1 (and pointer to 3) is defined first
            @test collect(keys(sorted)) == Int[5, 2, 1, 4, 3]
        else
            @test false # unexpected forward declarations
        end
    end

    @testset "show methods" begin
        abi_info = read_abi_info("bindinginfo_libsimple.json")
        terse = sprint(show, abi_info)
        @test !occursin('\n', terse)
        @test occursin("ABIInfo(", terse)
        @test occursin("types", terse) && occursin("entrypoints", terse)

        verbose = sprint(show, MIME("text/plain"), abi_info)
        @test occursin("Types:", verbose)
        @test occursin("Entrypoints:", verbose)

        target = CTarget("/tmp/foo", "libsimple")
        @test sprint(show, target) == "CTarget(\"/tmp/foo\", \"libsimple\")"
    end

    @testset "write_wrapper" begin
        mktempdir() do path
            mkpath(path)
            dest = CTarget(path, "libsimple")
            abi_info = read_abi_info("bindinginfo_libsimple.json")
            write_wrapper(dest, abi_info)

            headerfile = joinpath(dest.dir, dest.headerbase * ".h")
            @test isfile(headerfile)
            content = read(headerfile, String)
            @test occursin("#ifndef JULIALIB_LIBSIMPLE_H", content)
            @test occursin("#define JULIALIB_LIBSIMPLE_H", content)
            @test occursin("#include <stddef.h>", content)
            @test occursin("#include <stdint.h>", content)
            @test occursin("#include <stdbool.h>", content)
            @test occursin("typedef struct CVector_borrowed_Float32 {", content)
            @test occursin("    int32_t dims[1];", content)
            @test occursin("    float* data;", content)
            @test occursin("CVector_borrowed_Float32 from;", content)
            @test occursin("CVector_borrowed_Float32 to;", content)
            @test occursin("float copyto_and_sum(CVectorPair_Float32 fromto);", content)
            @test occursin("int32_t countsame(MyTwoVec* list, int32_t n);", content)
        end

        # The two CString ownerships are two distinct C typedefs, so whether a
        # buffer must be freed is visible in the signature.
        mktempdir() do path
            dest = CTarget(path, "libcstrarray")
            write_wrapper(dest, read_abi_info("bindinginfo_cstrarray.json"))

            content = read(joinpath(dest.dir, dest.headerbase * ".h"), String)
            @test occursin("typedef struct CString_borrowed {", content)
            @test occursin("typedef struct CString_owned {", content)
            @test occursin("    CString_borrowed* data;", content)
            @test occursin("    CString_owned* data;", content)
            @test occursin("void jlw_free_strings(CString_owned* p, int64_t n);", content)
        end
    end

    @testset "mangle_c!" begin
        # Unsupported primitive type: any name not in the `ctypes` table errors.
        typedict = Dict{Int, String}()
        typeinfo = OrderedDict{Int, TypeDesc}(
            1 => PrimitiveTypeDesc("NotARealType", false, 32, 4, 4),
        )
        @test_throws "unsupported primitive type: 'NotARealType'" mangle_c!(typedict, 1, typeinfo)

        # Two struct names that sanitize to the same C identifier collide;
        # the second gets a `_<id>` suffix, the third bumps to the next free id.
        typedict = Dict{Int, String}()
        typeinfo = OrderedDict{Int, TypeDesc}(
            1 => StructDesc("Foo!", 0, 0, FieldDesc[]),
            2 => StructDesc("Foo?", 0, 0, FieldDesc[]),
            3 => StructDesc("Foo#", 0, 0, FieldDesc[]),
        )
        @test mangle_c!(typedict, 1, typeinfo) == "Foo"
        @test mangle_c!(typedict, 2, typeinfo) == "Foo_2"
        @test mangle_c!(typedict, 3, typeinfo) == "Foo_3"

        # If the first `_<id>` slot is already taken, the while loop must
        # keep incrementing until it finds a free suffix.
        typedict = Dict{Int, String}()
        typeinfo = OrderedDict{Int, TypeDesc}(
            1 => StructDesc("Foo", 0, 0, FieldDesc[]),     # takes "Foo"
            2 => StructDesc("Foo_3", 0, 0, FieldDesc[]),   # takes "Foo_3"
            3 => StructDesc("Foo!", 0, 0, FieldDesc[]),    # wants "Foo_3", bumps to "Foo_4"
        )
        @test mangle_c!(typedict, 1, typeinfo) == "Foo"
        @test mangle_c!(typedict, 2, typeinfo) == "Foo_3"
        @test mangle_c!(typedict, 3, typeinfo) == "Foo_4"

        # Ownership parameters sanitize to distinct, valid C identifiers
        # rather than colliding on a shared prefix.
        typedict = Dict{Int, String}()
        typeinfo = OrderedDict{Int, TypeDesc}(
            1 => StructDesc("CString{:borrowed}", 16, 8, FieldDesc[]),
            2 => StructDesc("CString{:owned}", 16, 8, FieldDesc[]),
        )
        @test mangle_c!(typedict, 1, typeinfo) == "CString_borrowed"
        @test mangle_c!(typedict, 2, typeinfo) == "CString_owned"
    end

    @testset "PythonTarget" begin
        abi_info = read_abi_info("bindinginfo_libsimple.json")
        mktempdir() do path
            dest = PythonTarget(path, "libsimple", "libsimple")
            write_wrapper(dest, abi_info)

            bindings_path = joinpath(path, "libsimple", "_lowlevel.py")
            facade_path = joinpath(path, "libsimple", "_facade.py")
            init_path = joinpath(path, "libsimple", "__init__.py")
            pyproject_path = joinpath(path, "pyproject.toml")
            @test isfile(bindings_path)
            @test isfile(facade_path)
            @test isfile(init_path)
            @test isfile(pyproject_path)

            bindings = read(bindings_path, String)
            @test occursin("import ctypes", bindings)
            @test occursin("_LIBRARY_ENV_VAR = \"LIBSIMPLE_LIBRARY\"", bindings)
            @test occursin("class CTree_Float64(ctypes.Structure):\n    pass", bindings)
            @test occursin("class CVector_borrowed_Float32(ctypes.Structure):", bindings)
            @test occursin("(\"dims\", (ctypes.c_int32 * 1))", bindings)
            @test occursin("(\"data\", ctypes.POINTER(ctypes.c_float))", bindings)
            # `from` is a Python keyword; it must be renamed to be reachable
            # via attribute access.
            @test occursin("(\"from_\", CVector_borrowed_Float32)", bindings)
            @test occursin("CTree_Float64._fields_ = [", bindings)
            @test occursin("_lib.copyto_and_sum.argtypes = [CVectorPair_Float32]", bindings)
            @test occursin("_lib.copyto_and_sum.restype = ctypes.c_float", bindings)
            @test occursin(
                "_lib.countsame.argtypes = [ctypes.POINTER(MyTwoVec), ctypes.c_int32]",
                bindings
            )

            # Only primitive-element CArrays gain numpy helpers.
            @test occursin("import numpy as np", bindings)
            @test occursin("def from_numpy(cls, arr):", bindings)
            @test occursin("def as_numpy(self):", bindings)
            @test occursin("expected_dtype = np.dtype(\"float32\")", bindings)
            @test occursin("ctypes.POINTER(ctypes.c_float)", bindings)
            # The CVector_borrowed_CTree_Float64 class has a struct pointee, so the
            # recognizer must reject it (no helper emission). There is only
            # one `from_numpy` definition in the file.
            @test count(s -> occursin("def from_numpy", s), split(bindings, '\n')) == 1

            init = read(init_path, String)
            @test occursin("from ._facade import *", init)
            @test occursin("from ._facade import __all__", init)

            # `_facade.py` is the author-editable public API and is not overwritten;
            # the starter stub re-exports every public name from `_lowlevel`.
            facade = read(facade_path, String)
            @test occursin("from ._lowlevel import (", facade)
            @test occursin("copyto_and_sum", facade)
            @test occursin("CTree_Float64", facade)
            @test occursin("__all__ = [", facade)

            golden_facade = read(joinpath(@__DIR__, "expected_libsimple_facade.py"), String)
            @test facade == golden_facade

            # No-clobber contract: a hand-edit must survive a re-emission.
            sentinel = "# sentinel: hand-edited façade — do not overwrite\n"
            open(facade_path, "a") do io
                write(io, sentinel)
            end
            write_wrapper(dest, abi_info)
            @test occursin(sentinel, read(facade_path, String))

            pyproject = read(pyproject_path, String)
            @test occursin("[build-system]", pyproject)
            @test occursin("name = \"libsimple\"", pyproject)
            @test occursin("version = \"0.0.0\"", pyproject)
            # The bindings use numpy via the CArray helpers, so numpy must be
            # declared as a runtime dependency.
            @test occursin("dependencies = [\"numpy>=1.20\"]", pyproject)

            golden = read(joinpath(@__DIR__, "expected_libsimple_lowlevel.py"), String)
            @test bindings == golden

            # Without a private libjulia, a second wrapped package in the
            # process is a fatal configuration and the package says so.
            @test occursin("aborts the process", bindings)
            @test occursin("Rebuild with", bindings)
            # A privatized package uses its own runtime, so it does not warn,
            # but it still records itself for other packages to detect.
            priv_dir = mktempdir()
            write_wrapper(
                PythonTarget(priv_dir, "libsimple", "libsimple"; privatized = true),
                abi_info
            )
            priv = read(joinpath(priv_dir, "libsimple", "_lowlevel.py"), String)
            @test !occursin("RuntimeWarning", priv)
            @test occursin("_jlw_loaded.add(_jlw_this_pkg)", priv)

            python3 = Sys.which("python3")
            if python3 === nothing
                # CI must exercise the Python wrapper; locally we allow skipping
                # so contributors without python3 can still run the suite.
                haskey(ENV, "CI") && error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            else
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr = devnull, stdout = devnull); wait = true))
                cmd_f = `$python3 -c "import ast; ast.parse(open('$facade_path').read())"`
                @test success(run(pipeline(cmd_f; stderr = devnull, stdout = devnull); wait = true))
            end
        end

        @testset "PythonTarget show" begin
            t = PythonTarget("/tmp/foo", "libsimple", "libsimple")
            @test sprint(show, t) ==
                "PythonTarget(\"/tmp/foo\", \"libsimple\", \"libsimple\")"
            tb = PythonTarget(
                "/tmp/foo", "libsimple", "libsimple";
                bundle_subdir = "bundle"
            )
            @test sprint(show, tb) ==
                "PythonTarget(\"/tmp/foo\", \"libsimple\", \"libsimple\"; bundle_subdir = \"bundle\")"
            @test tb.bundle_subdir == "bundle"
            tv = PythonTarget("/tmp/foo", "libsimple", "libsimple"; version = "1.2.3")
            @test sprint(show, tv) ==
                "PythonTarget(\"/tmp/foo\", \"libsimple\", \"libsimple\"; version = \"1.2.3\")"
        end

        @testset "PythonTarget version" begin
            abi_info = read_abi_info("bindinginfo_libsimple.json")
            mktempdir() do path
                dest = PythonTarget(path, "libsimple", "libsimple"; version = "1.2.3")
                write_wrapper(dest, abi_info)
                pyproject = read(joinpath(path, "pyproject.toml"), String)
                @test occursin("version = \"1.2.3\"", pyproject)
            end
            mktempdir() do path
                dest = PythonTarget(path, "libsimple", "libsimple")
                write_wrapper(dest, abi_info)
                pyproject = read(joinpath(path, "pyproject.toml"), String)
                @test occursin("version = \"0.0.0\"", pyproject)
            end
            @test_throws "PythonTarget version must not be empty" PythonTarget(
                "/tmp/foo", "libsimple", "libsimple"; version = ""
            )
        end

        @testset "bundle-aware output" begin
            abi_info = read_abi_info("bindinginfo_libsimple.json")
            mktempdir() do path
                dest = PythonTarget(
                    path, "libsimple", "libsimple";
                    bundle_subdir = "bundle"
                )
                write_wrapper(dest, abi_info)

                bindings = read(joinpath(path, "libsimple", "_lowlevel.py"), String)
                # Bundle path is searched first so the baked-in RUNPATH
                # resolves libjulia from inside the wheel.
                @test occursin("search_dirs = (_HERE / \"bundle\" / \"lib\", _HERE)", bindings)
                @test occursin("for directory in search_dirs:", bindings)
                @test occursin("candidate = directory / (_LIBRARY_BASENAME + suffix)", bindings)
                @test occursin("_LIBRARY_ENV_VAR = \"LIBSIMPLE_LIBRARY\"", bindings)

                pyproject = read(joinpath(path, "pyproject.toml"), String)
                @test occursin("\"bundle/lib/*\"", pyproject)
                @test occursin("\"bundle/lib/julia/*\"", pyproject)
                @test occursin("\"bundle/artifacts/*/**/*\"", pyproject)

                python3 = Sys.which("python3")
                if python3 !== nothing
                    bp = joinpath(path, "libsimple", "_lowlevel.py")
                    cmd = `$python3 -c "import ast; ast.parse(open('$bp').read())"`
                    @test success(run(pipeline(cmd; stderr = devnull, stdout = devnull); wait = true))
                end
            end
        end

        @testset "unsupported primitive" begin
            typedict = Dict{Int, String}()
            typeinfo = OrderedDict{Int, TypeDesc}(
                1 => PrimitiveTypeDesc("NotARealType", false, 32, 4, 4),
            )
            @test_throws "unsupported primitive type: 'NotARealType'" JuliaLibWrapping.mangle_python!(typedict, 1, typeinfo)
        end

        @testset "struct name collision" begin
            # Mirrors the mangle_c! collision testset: the Python emitter
            # carries a near-identical suffix-bumping branch, and the two
            # implementations must not silently drift.
            typedict = Dict{Int, String}()
            typeinfo = OrderedDict{Int, TypeDesc}(
                1 => StructDesc("Foo!", 0, 0, FieldDesc[]),
                2 => StructDesc("Foo?", 0, 0, FieldDesc[]),
                3 => StructDesc("Foo#", 0, 0, FieldDesc[]),
            )
            @test JuliaLibWrapping.mangle_python!(typedict, 1, typeinfo) == "Foo"
            @test JuliaLibWrapping.mangle_python!(typedict, 2, typeinfo) == "Foo_2"
            @test JuliaLibWrapping.mangle_python!(typedict, 3, typeinfo) == "Foo_3"

            typedict = Dict{Int, String}()
            typeinfo = OrderedDict{Int, TypeDesc}(
                1 => StructDesc("Foo", 0, 0, FieldDesc[]),     # takes "Foo"
                2 => StructDesc("Foo_3", 0, 0, FieldDesc[]),   # takes "Foo_3"
                3 => StructDesc("Foo!", 0, 0, FieldDesc[]),    # wants "Foo_3", bumps to "Foo_4"
            )
            @test JuliaLibWrapping.mangle_python!(typedict, 1, typeinfo) == "Foo"
            @test JuliaLibWrapping.mangle_python!(typedict, 2, typeinfo) == "Foo_3"
            @test JuliaLibWrapping.mangle_python!(typedict, 3, typeinfo) == "Foo_4"
        end

        @testset "void pointee collapse" begin
            # A `nothing` pointee (`Ptr{Cvoid}`) must collapse to
            # `ctypes.c_void_p` in every position — NOT render as a distinct
            # named pointer type, which is what broke `jlw_free`'s argtype
            # (ctypes refuses a `c_void_p` argument for one).
            typedict = Dict{Int, String}()
            typeinfo = OrderedDict{Int, TypeDesc}(
                1 => StructDesc("Handle", 8, 8, FieldDesc[FieldDesc("x", 3, 0)]),
                2 => PointerDesc("Ptr{Nothing}", nothing),
                3 => PrimitiveTypeDesc("Int64", true, 64, 8, 8),
            )
            @test JuliaLibWrapping.mangle_python!(typedict, 2, typeinfo) == "ctypes.c_void_p"
            # An ordinary pointer is unaffected — still a typed pointer.
            typeinfo[4] = PointerDesc("Ptr{Handle}", 1)
            @test JuliaLibWrapping.mangle_python!(typedict, 4, typeinfo) ==
                "ctypes.POINTER(Handle)"
        end

        @testset "sanitize_python_argname" begin
            sanitize = JuliaLibWrapping.sanitize_python_argname
            # Prefix numeric tuple-field names to form Python identifiers.
            @test sanitize("1") == "_1"
            @test sanitize("2") == "_2"
            # Uniqueness still applies after the digit prefix.
            seen = Set{String}()
            @test sanitize("1", seen) == "_1"
            @test sanitize("1", seen) == "_12"
            # Existing behaviors still hold.
            @test sanitize("name!") == "name"
            @test sanitize("") == "_"
            @test sanitize("class") == "class_"
        end
    end

    @testset "carray_struct_info" begin
        # Structural recognition of the CArray{owned,T,N} shape: a struct named
        # CArray/CVector/CMatrix (since `CVector = CArray{_,_,1}` and
        # `CMatrix = CArray{_,_,2}` may print under either name) whose first
        # type parameter is `:owned` or `:borrowed`, with exactly the `dims`
        # (NTuple{N,Int32} → ArrayDesc) and `data` (Ptr{T}) fields, for any
        # primitive T. The recognizer reports T's Julia name and the
        # ownership; `_python_carray_info` decides whether numpy supports the
        # element type.
        cainfo(desc, typeinfo) = JuliaLibWrapping.carray_struct_info(desc, typeinfo)
        pycainfo(desc, typeinfo) = JuliaLibWrapping._python_carray_info(desc, typeinfo)

        # libsimple exercises CVector{:borrowed, Float32} (N=1, primitive
        # pointee, match) and CVector{:borrowed, CTree{Float64}} (struct
        # pointee, no match).
        abi = read_abi_info("bindinginfo_libsimple.json")
        findtype(descs, name) = (
            k = collect(keys(descs));
            k[findfirst((id) -> descs[id].name === name, k)]
        )
        cv_f32 = abi.typeinfo[findtype(abi.typeinfo, "CVector{:borrowed, Float32}")]
        cv_tree = abi.typeinfo[findtype(abi.typeinfo, "CVector{:borrowed, CTree{Float64}}")]
        info = cainfo(cv_f32, abi.typeinfo)
        @test info !== nothing
        @test info.eltype == "Float32"
        @test info.ndim == 1
        @test info.ownership === :borrowed
        pyinfo = pycainfo(cv_f32, abi.typeinfo)
        @test pyinfo.eltype == "Float32"
        @test pyinfo.ndim == 1
        @test pyinfo.ownership === :borrowed
        @test pyinfo.dtype == "float32"
        @test pyinfo.ctype == "ctypes.c_float"
        # Struct pointee → no match: `data` must point at a primitive.
        @test cainfo(cv_tree, abi.typeinfo) === nothing
        @test pycainfo(cv_tree, abi.typeinfo) === nothing

        # cmatrix fixture exercises the N=2 case under the CMatrix alias name.
        abi_cm = read_abi_info("bindinginfo_cmatrix.json")
        cm_f64 = abi_cm.typeinfo[findtype(abi_cm.typeinfo, "CMatrix{:borrowed, Float64}")]
        info2 = cainfo(cm_f64, abi_cm.typeinfo)
        @test info2 !== nothing
        @test info2.eltype == "Float64"
        @test info2.ndim == 2
        @test info2.ownership === :borrowed

        # carray3 fixture exercises N=3 under the CArray name directly.
        abi_c3 = read_abi_info("bindinginfo_carray3.json")
        ca_f64_3 = abi_c3.typeinfo[findtype(abi_c3.typeinfo, "CArray{:borrowed, Float64, 3}")]
        info3 = cainfo(ca_f64_3, abi_c3.typeinfo)
        @test info3 !== nothing
        @test info3.eltype == "Float64"
        @test info3.ndim == 3
        @test info3.ownership === :borrowed

        # carray_owned fixture exercises the `:owned` token.
        abi_co = read_abi_info("bindinginfo_carray_owned.json")
        cv_owned = abi_co.typeinfo[findtype(abi_co.typeinfo, "CVector{:owned, Float64}")]
        info4 = cainfo(cv_owned, abi_co.typeinfo)
        @test info4 !== nothing
        @test info4.eltype == "Float64"
        @test info4.ndim == 1
        @test info4.ownership === :owned

        # Ownership token parsing, independent of layout.
        ownership(name) = JuliaLibWrapping._carrier_ownership(
            name, ("CArray{", "CVector{", "CMatrix{")
        )
        @test ownership("CVector{:owned, Float64}") === :owned
        @test ownership("CMatrix{:borrowed, Float32}") === :borrowed
        @test ownership("CArray{:owned, Float64, 3}") === :owned
        @test ownership("CVector{:owned}") === :owned
        @test ownership("CArray{ :borrowed , Float64, 3}") === :borrowed
        @test ownership("CVector{Float64}") === nothing        # no token at all # noidiom
        @test ownership("CArray{Float64, 3}") === nothing      # noidiom
        @test ownership("CVector{:mine, Float64}") === nothing # unknown token # noidiom
        @test ownership("CVector") === nothing                 # brace required # noidiom
        @test ownership("MyCVector{:owned, Float64}") === nothing  # noidiom
        @test ownership("CVector{") === nothing                # unterminated # noidiom

        # Hand-built rejections: tokenless name, wrong name, wrong field names,
        # non-integer dims element, dims-as-primitive (not array), and the
        # three-field pre-type-parameter layout. Plus a Bool-pointee CArray,
        # which is a structural match the Python adapter declines.
        primint = PrimitiveTypeDesc("Int32", true, 32, 4, 4)
        primflt = PrimitiveTypeDesc("Float32", true, 32, 4, 4)
        primbool = PrimitiveTypeDesc("Bool", false, 8, 1, 1)
        ptr_to_flt = PointerDesc("Ptr{Float32}", 2)
        arr_int32_1 = ArrayDesc("NTuple{1, Int32}", 1, 1, 4, 4)
        arr_flt_1 = ArrayDesc("NTuple{1, Float32}", 2, 1, 4, 4)
        arr_bool_1 = ArrayDesc("NTuple{1, Bool}", 7, 1, 1, 1)
        ti = OrderedDict{Int, TypeDesc}(
            1 => primint, 2 => primflt, 3 => ptr_to_flt,
            4 => arr_int32_1, 5 => arr_flt_1,
            6 => StructDesc(
                "CVector{:borrowed, Float32}", 16, 8, FieldDesc[
                    FieldDesc("dims", 4, 0),
                    FieldDesc("data", 3, 8),
                ]
            ),
            7 => primbool,
            8 => arr_bool_1,
            9 => StructDesc(
                "NotACArray{:borrowed, Float32}", 16, 8, FieldDesc[
                    FieldDesc("dims", 4, 0),
                    FieldDesc("data", 3, 8),
                ]
            ),
            10 => StructDesc("CVectorEmpty", 0, 0, FieldDesc[]),
            11 => StructDesc(
                "CVector{:borrowed, Float32}", 16, 8, FieldDesc[
                    FieldDesc("len", 4, 0),
                    FieldDesc("data", 3, 8),
                ]
            ),
            12 => StructDesc(
                "CVector{:borrowed, Float32}", 16, 8, FieldDesc[
                    FieldDesc("dims", 5, 0),  # NTuple{1,Float32} — not Int*
                    FieldDesc("data", 3, 8),
                ]
            ),
            13 => StructDesc(
                "CVector{:borrowed, Float32}", 16, 8, FieldDesc[
                    FieldDesc("dims", 1, 0),  # primitive Int32, not ArrayDesc
                    FieldDesc("data", 3, 8),
                ]
            ),
            14 => StructDesc(
                "CVector{:borrowed, Float32}", 16, 8, FieldDesc[
                    FieldDesc("dims", 8, 0),  # Bool element — not Int/UInt
                    FieldDesc("data", 3, 8),
                ]
            ),
            15 => StructDesc(
                "CVector{Float32}", 16, 8, FieldDesc[   # no ownership token
                    FieldDesc("dims", 4, 0),
                    FieldDesc("data", 3, 8),
                ]
            ),
            16 => StructDesc(
                "CVector{:borrowed, Float32}", 24, 8, FieldDesc[
                    FieldDesc("dims", 4, 0),
                    FieldDesc("data", 3, 8),
                    FieldDesc("owned", 1, 16),   # runtime flag: no longer part of the layout
                ]
            ),
            17 => PointerDesc("Ptr{Bool}", 7),
            18 => StructDesc(
                "CVector{:owned, Bool}", 16, 8, FieldDesc[
                    FieldDesc("dims", 4, 0),
                    FieldDesc("data", 17, 8),
                ]
            ),
        )
        @test cainfo(ti[6], ti) !== nothing  # noidiom
        @test cainfo(ti[9], ti) === nothing   # wrong name prefix # noidiom
        @test cainfo(ti[10], ti) === nothing  # empty # noidiom
        @test cainfo(ti[11], ti) === nothing  # wrong field names # noidiom
        @test cainfo(ti[12], ti) === nothing  # non-integer dims element # noidiom
        @test cainfo(ti[13], ti) === nothing  # dims is primitive, not ArrayDesc # noidiom
        @test cainfo(ti[14], ti) === nothing  # Bool dims element rejected # noidiom
        @test cainfo(ti[15], ti) === nothing  # name states no ownership # noidiom
        @test cainfo(ti[16], ti) === nothing  # three-field layout rejected # noidiom

        # Bool element: matches structurally, but `Bool` has no
        # `numpy_dtypes` entry, so the Python adapter rejects it.
        info_bool = cainfo(ti[18], ti)
        @test info_bool !== nothing
        @test info_bool.eltype == "Bool"
        @test info_bool.ndim == 1
        @test info_bool.ownership === :owned
        @test pycainfo(ti[18], ti) === nothing  # noidiom

        # Field order may be any permutation.
        flipped = StructDesc(
            "CVector{:borrowed, Float32}", 16, 8, FieldDesc[
                FieldDesc("data", 3, 8),
                FieldDesc("dims", 4, 0),
            ]
        )
        @test cainfo(flipped, ti) !== nothing  # noidiom
    end

    @testset "cstring_struct_info" begin
        # Recognition requires an ownership parameter and the CString layout.
        csinfo = JuliaLibWrapping.cstring_struct_info
        findtype(descs, name) = (
            k = collect(keys(descs));
            k[findfirst((id) -> descs[id].name === name, k)]
        )
        abi = read_abi_info("bindinginfo_cstring.json")
        cs = abi.typeinfo[findtype(abi.typeinfo, "CString{:borrowed}")]
        @test csinfo(cs, abi.typeinfo).ownership === :borrowed
        abi_owned = read_abi_info("bindinginfo_cstring_owned.json")
        cs_owned = abi_owned.typeinfo[findtype(abi_owned.typeinfo, "CString{:owned}")]
        @test csinfo(cs_owned, abi_owned.typeinfo).ownership === :owned

        # Hand-built rejections.
        primint = PrimitiveTypeDesc("Int32", true, 32, 4, 4)
        primu8 = PrimitiveTypeDesc("UInt8", false, 8, 1, 1)
        primu16 = PrimitiveTypeDesc("UInt16", false, 16, 2, 2)
        ptr_to_u8 = PointerDesc("Ptr{UInt8}", 2)
        ptr_to_u16 = PointerDesc("Ptr{UInt16}", 3)
        ti = OrderedDict{Int, TypeDesc}(
            1 => primint, 2 => primu8, 3 => primu16,
            4 => ptr_to_u8, 5 => ptr_to_u16,
            6 => StructDesc(
                "CString{:borrowed}", 16, 8, FieldDesc[
                    FieldDesc("length", 1, 0),
                    FieldDesc("data", 4, 8),
                ]
            ),
            7 => StructDesc(
                "NotACString{:borrowed}", 16, 8, FieldDesc[
                    FieldDesc("length", 1, 0),
                    FieldDesc("data", 4, 8),
                ]
            ),
            8 => StructDesc(
                "CString{:borrowed}", 16, 8, FieldDesc[
                    FieldDesc("length", 1, 0),
                    FieldDesc("data", 5, 8),  # Ptr{UInt16} — not UInt8
                ]
            ),
            9 => StructDesc(
                "CString{:borrowed}", 16, 8, FieldDesc[
                    FieldDesc("size", 1, 0),
                    FieldDesc("data", 4, 8),
                ]
            ),
            10 => StructDesc(
                "CString", 16, 8, FieldDesc[   # no ownership token
                    FieldDesc("length", 1, 0),
                    FieldDesc("data", 4, 8),
                ]
            ),
            11 => StructDesc(
                "CString{:owned}", 16, 8, FieldDesc[
                    FieldDesc("length", 1, 0),
                    FieldDesc("data", 4, 8),
                ]
            ),
        )
        @test csinfo(ti[6], ti).ownership === :borrowed
        @test isnothing(csinfo(ti[7], ti))  # wrong name prefix
        @test isnothing(csinfo(ti[8], ti))  # non-UInt8 pointee
        @test isnothing(csinfo(ti[9], ti))  # wrong field names
        @test isnothing(csinfo(ti[10], ti)) # name states no ownership
        @test csinfo(ti[11], ti).ownership === :owned

        # Field order may be either way.
        flipped = StructDesc(
            "CString{:owned}", 16, 8, FieldDesc[
                FieldDesc("data", 4, 0),
                FieldDesc("length", 1, 8),
            ]
        )
        @test csinfo(flipped, ti).ownership === :owned
    end

    @testset "cstrarray_struct_info" begin
        # Recognition requires an ownership parameter and the CStrArray layout.
        csainfo = JuliaLibWrapping.cstrarray_struct_info
        abi = read_abi_info("bindinginfo_cstrarray.json")
        findtype(descs, name) = (
            k = collect(keys(descs));
            k[findfirst((id) -> descs[id].name === name, k)]
        )
        csa = abi.typeinfo[findtype(abi.typeinfo, "CStrArray{:borrowed}")]
        @test csainfo(csa, abi.typeinfo).ownership === :borrowed
        csa_owned = abi.typeinfo[findtype(abi.typeinfo, "CStrArray{:owned}")]
        @test csainfo(csa_owned, abi.typeinfo).ownership === :owned

        # Hand-built rejections.
        primi32 = PrimitiveTypeDesc("Int32", true, 32, 4, 4)
        primi64 = PrimitiveTypeDesc("Int64", true, 64, 8, 8)
        primu64 = PrimitiveTypeDesc("UInt64", false, 64, 8, 8)
        primu8 = PrimitiveTypeDesc("UInt8", false, 8, 1, 1)
        primu16 = PrimitiveTypeDesc("UInt16", false, 16, 2, 2)
        ptr_to_u8 = PointerDesc("Ptr{UInt8}", 4)
        ptr_to_u16 = PointerDesc("Ptr{UInt16}", 5)
        cstring_ok = StructDesc(
            "CString{:borrowed}", 16, 8, FieldDesc[
                FieldDesc("length", 1, 0),
                FieldDesc("data", 6, 8),
            ]
        )
        cstring_bad = StructDesc(
            # `data` points to UInt16, not UInt8 — `cstring_struct_info`
            # rejects this, so it must not be accepted as a CString pointee.
            "CString{:borrowed}", 16, 8, FieldDesc[
                FieldDesc("length", 1, 0),
                FieldDesc("data", 7, 8),
            ]
        )
        cstring_owned = StructDesc(
            "CString{:owned}", 16, 8, FieldDesc[
                FieldDesc("length", 1, 0),
                FieldDesc("data", 6, 8),
            ]
        )
        ptr_to_cstring = PointerDesc("Ptr{CString{:borrowed}}", 8)
        ptr_to_bad_cstring = PointerDesc("Ptr{CString{:borrowed}}", 9)
        ptr_to_cstring_owned = PointerDesc("Ptr{CString{:owned}}", 21)
        ti = OrderedDict{Int, TypeDesc}(
            1 => primi32, 2 => primi64, 3 => primu64,
            4 => primu8, 5 => primu16,
            6 => ptr_to_u8, 7 => ptr_to_u16,
            8 => cstring_ok, 9 => cstring_bad,
            10 => ptr_to_cstring, 11 => ptr_to_bad_cstring,
            12 => StructDesc(
                "CStrArray{:borrowed}", 16, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("data", 10, 8),
                ]
            ),
            13 => StructDesc(
                "NotACStrArray{:borrowed}", 16, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("data", 10, 8),
                ]
            ),
            14 => StructDesc(
                "CStrArray{:borrowed}", 16, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("data", 11, 8),  # Ptr{NotCString} — pointee isn't CString-shaped
                ]
            ),
            15 => StructDesc(
                "CStrArray{:borrowed}", 16, 8, FieldDesc[
                    FieldDesc("size", 2, 0),
                    FieldDesc("data", 10, 8),
                ]
            ),
            16 => StructDesc(
                "CStrArray{:borrowed}", 16, 8, FieldDesc[
                    FieldDesc("length", 3, 0),  # UInt64 — not signed
                    FieldDesc("data", 10, 8),
                ]
            ),
            17 => StructDesc(
                "CStrArray{:borrowed}", 16, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("data", 6, 8),  # Ptr{UInt8} — pointee isn't a struct at all
                ]
            ),
            18 => StructDesc(
                "CStrArray", 16, 8, FieldDesc[   # no ownership token
                    FieldDesc("length", 2, 0),
                    FieldDesc("data", 10, 8),
                ]
            ),
            19 => StructDesc(
                "CStrArray{:borrowed}", 24, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("data", 10, 8),
                    FieldDesc("owned", 1, 16),   # runtime flag: no longer part of the layout
                ]
            ),
            20 => StructDesc(
                "CStrArray{:owned}", 16, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("data", 22, 8),
                ]
            ),
            21 => cstring_owned, 22 => ptr_to_cstring_owned,
            23 => StructDesc(
                "CStrArray{:owned}", 16, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("data", 10, 8),  # borrowed elements in an owning container
                ]
            ),
            24 => StructDesc(
                "CStrArray{:borrowed}", 16, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("data", 22, 8),  # owned elements in a borrowed container
                ]
            ),
        )
        @test csainfo(ti[12], ti).ownership === :borrowed
        @test isnothing(csainfo(ti[13], ti))  # wrong name prefix
        @test isnothing(csainfo(ti[14], ti))  # data's pointee isn't CString-shaped
        @test isnothing(csainfo(ti[15], ti))  # wrong field names
        @test isnothing(csainfo(ti[16], ti))  # unsigned length
        @test isnothing(csainfo(ti[17], ti))  # data isn't a pointer-to-struct at all
        @test isnothing(csainfo(ti[18], ti))  # name states no ownership
        @test isnothing(csainfo(ti[19], ti))  # three-field layout rejected
        @test csainfo(ti[20], ti).ownership === :owned
        @test isnothing(csainfo(ti[23], ti))  # element ownership must match the container's
        @test isnothing(csainfo(ti[24], ti))  # ...in either direction

        # Field order may be either way.
        flipped = StructDesc(
            "CStrArray{:owned}", 16, 8, FieldDesc[
                FieldDesc("data", 22, 8),
                FieldDesc("length", 2, 0),
            ]
        )
        @test csainfo(flipped, ti).ownership === :owned
    end

    @testset "cdict_struct_info" begin
        # Recognition requires ownership and value parameters and the CDict layout.
        cdinfo(desc, typeinfo) = JuliaLibWrapping.cdict_struct_info(desc, typeinfo)
        pycdinfo(desc, typeinfo) = JuliaLibWrapping._python_cdict_info(desc, typeinfo)
        abi = read_abi_info("bindinginfo_cdict.json")
        findtype(descs, name) = (
            k = collect(keys(descs));
            k[findfirst((id) -> descs[id].name === name, k)]
        )
        cd = abi.typeinfo[findtype(abi.typeinfo, "CDict{:borrowed, Float64}")]
        info = cdinfo(cd, abi.typeinfo)
        @test !isnothing(info)
        @test info.value_type == "Float64"
        @test info.ownership === :borrowed
        pyinfo = pycdinfo(cd, abi.typeinfo)
        @test pyinfo.value_type == "Float64"
        @test pyinfo.ownership === :borrowed
        @test pyinfo.ctype == "ctypes.c_double"

        cd_owned = abi.typeinfo[findtype(abi.typeinfo, "CDict{:owned, Float64}")]
        @test cdinfo(cd_owned, abi.typeinfo).ownership === :owned
        @test pycdinfo(cd_owned, abi.typeinfo).ownership === :owned

        # Hand-built rejections.
        primi32 = PrimitiveTypeDesc("Int32", true, 32, 4, 4)
        primi64 = PrimitiveTypeDesc("Int64", true, 64, 8, 8)
        primu8 = PrimitiveTypeDesc("UInt8", false, 8, 1, 1)
        primu16 = PrimitiveTypeDesc("UInt16", false, 16, 2, 2)
        primf64 = PrimitiveTypeDesc("Float64", true, 64, 8, 8)
        primnotreal = PrimitiveTypeDesc("NotARealType", false, 32, 4, 4)
        ptr_to_u8 = PointerDesc("Ptr{UInt8}", 3)
        ptr_to_u16 = PointerDesc("Ptr{UInt16}", 4)
        ptr_to_f64 = PointerDesc("Ptr{Float64}", 5)
        ptr_to_notreal = PointerDesc("Ptr{NotARealType}", 6)
        cstring_ok = StructDesc(
            "CString{:borrowed}", 16, 8, FieldDesc[
                FieldDesc("length", 1, 0),
                FieldDesc("data", 7, 8),
            ]
        )
        cstring_bad = StructDesc(
            # `data` points to UInt16, not UInt8 — `cstring_struct_info`
            # rejects this, so it must not be accepted as a CString pointee.
            "CString{:borrowed}", 16, 8, FieldDesc[
                FieldDesc("length", 1, 0),
                FieldDesc("data", 8, 8),
            ]
        )
        cstring_owned = StructDesc(
            "CString{:owned}", 16, 8, FieldDesc[
                FieldDesc("length", 1, 0),
                FieldDesc("data", 7, 8),
            ]
        )
        ptr_to_cstring = PointerDesc("Ptr{CString{:borrowed}}", 9)
        ptr_to_bad_cstring = PointerDesc("Ptr{CString{:borrowed}}", 10)
        ptr_to_cstring_owned = PointerDesc("Ptr{CString{:owned}}", 28)
        ti = OrderedDict{Int, TypeDesc}(
            1 => primi32, 2 => primi64,
            3 => primu8, 4 => primu16, 5 => primf64,
            6 => primnotreal,
            7 => ptr_to_u8, 8 => ptr_to_u16,
            9 => cstring_ok, 10 => cstring_bad,
            11 => ptr_to_cstring, 12 => ptr_to_bad_cstring,
            13 => ptr_to_f64, 14 => ptr_to_notreal,
            15 => StructDesc(
                "CDict{:borrowed, Float64}", 24, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 11, 8),
                    FieldDesc("values", 13, 16),
                ]
            ),
            16 => StructDesc(
                "NotACDict{:borrowed, Float64}", 24, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 11, 8),
                    FieldDesc("values", 13, 16),
                ]
            ),
            17 => StructDesc(
                "CDict{:borrowed, Float64}", 24, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 12, 8),  # Ptr{NotCString} — pointee isn't CString-shaped
                    FieldDesc("values", 13, 16),
                ]
            ),
            18 => StructDesc(
                "CDict{:borrowed, Float64}", 24, 8, FieldDesc[
                    FieldDesc("len", 2, 0),
                    FieldDesc("keys", 11, 8),
                    FieldDesc("values", 13, 16),
                ]
            ),
            19 => StructDesc(
                "CDict{:borrowed, Float64}", 16, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 11, 8),
                ]
            ),
            20 => StructDesc(
                "CDict{:borrowed, NotARealType}", 24, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 11, 8),
                    FieldDesc("values", 14, 16),  # Ptr{NotARealType} — not in scalar_payload_types
                ]
            ),
            21 => StructDesc(
                "CDict{:borrowed, Float64}", 24, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 7, 8),  # Ptr{UInt8} — pointee isn't a struct at all
                    FieldDesc("values", 13, 16),
                ]
            ),
            22 => StructDesc(
                "CDict{Float64}", 24, 8, FieldDesc[   # no ownership token
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 11, 8),
                    FieldDesc("values", 13, 16),
                ]
            ),
            23 => StructDesc(
                "CDict{:borrowed, Float64}", 32, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 11, 8),
                    FieldDesc("values", 13, 16),
                    FieldDesc("owned", 1, 24),   # runtime flag: no longer part of the layout
                ]
            ),
            24 => PrimitiveTypeDesc("Cvoid", false, 0, 0, 1),
            25 => PointerDesc("Ptr{Cvoid}", 24),
            26 => StructDesc(
                # `values` points to `Cvoid`: matches the CDict shape, but
                # `Cvoid` is absent from `scalar_payload_types` (`None` is
                # not a valid ctypes field type).
                "CDict{:borrowed, Cvoid}", 24, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 11, 8),
                    FieldDesc("values", 25, 16),
                ]
            ),
            27 => StructDesc(
                "CDict{:owned, Float64}", 24, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 29, 8),
                    FieldDesc("values", 13, 16),
                ]
            ),
            28 => cstring_owned, 29 => ptr_to_cstring_owned,
            30 => StructDesc(
                "CDict{:owned, Float64}", 24, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 11, 8),  # borrowed keys in an owning dictionary
                    FieldDesc("values", 13, 16),
                ]
            ),
            31 => StructDesc(
                "CDict{:borrowed, Float64}", 24, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 29, 8),  # owned keys in a borrowed dictionary
                    FieldDesc("values", 13, 16),
                ]
            ),
        )
        @test !isnothing(cdinfo(ti[15], ti))
        @test isnothing(cdinfo(ti[16], ti)) # wrong name prefix
        @test isnothing(cdinfo(ti[17], ti)) # keys' pointee isn't CString-shaped
        @test isnothing(cdinfo(ti[18], ti)) # wrong field names
        @test isnothing(cdinfo(ti[19], ti)) # missing `values` field
        @test !isnothing(cdinfo(ti[20], ti)) # values pointee is a primitive: a structural match
        @test cdinfo(ti[20], ti).value_type == "NotARealType"
        @test isnothing(pycdinfo(ti[20], ti)) # ...but not a supported payload type
        @test isnothing(cdinfo(ti[21], ti)) # keys isn't a pointer-to-struct at all
        @test isnothing(cdinfo(ti[22], ti)) # name states no ownership
        @test isnothing(cdinfo(ti[23], ti)) # four-field layout rejected
        @test !isnothing(cdinfo(ti[26], ti)) # a Cvoid value type matches structurally
        @test cdinfo(ti[26], ti).value_type == "Cvoid"
        @test isnothing(pycdinfo(ti[26], ti)) # ...but Cvoid is not a scalar payload type
        @test cdinfo(ti[27], ti).ownership === :owned
        @test isnothing(cdinfo(ti[30], ti)) # key ownership must match the dictionary's
        @test isnothing(cdinfo(ti[31], ti)) # ...in either direction

        # Field order may be any permutation.
        permuted = StructDesc(
            "CDict{:owned, Float64}", 24, 8, FieldDesc[
                FieldDesc("values", 13, 16),
                FieldDesc("length", 2, 0),
                FieldDesc("keys", 29, 8),
            ]
        )
        @test cdinfo(permuted, ti).ownership === :owned
    end

    @testset "copt_struct_info" begin
        # Structural recognition of the COpt{T} shape: a struct named COpt
        # with `has_value` (Int32 primitive) and `value` (any primitive)
        # fields. The recognizer reports T's Julia name; `_python_copt_info`
        # decides whether it is a supported payload type.
        coinfo(desc, typeinfo) = JuliaLibWrapping.copt_struct_info(desc, typeinfo)
        pycoinfo(desc, typeinfo) = JuliaLibWrapping._python_copt_info(desc, typeinfo)
        abi = read_abi_info("bindinginfo_copt.json")
        findtype(descs, name) = (
            k = collect(keys(descs));
            k[findfirst((id) -> descs[id].name === name, k)]
        )
        co = abi.typeinfo[findtype(abi.typeinfo, "COpt{Float64}")]
        info = coinfo(co, abi.typeinfo)
        @test !isnothing(info)
        @test info.value_type == "Float64"
        pyinfo = pycoinfo(co, abi.typeinfo)
        @test pyinfo.value_type == "Float64"
        @test pyinfo.ctype == "ctypes.c_double"

        # Hand-built rejections.
        primi32 = PrimitiveTypeDesc("Int32", true, 32, 4, 4)
        primi64 = PrimitiveTypeDesc("Int64", true, 64, 8, 8)
        primf64 = PrimitiveTypeDesc("Float64", true, 64, 8, 8)
        primnotreal = PrimitiveTypeDesc("NotARealType", false, 32, 4, 4)
        ti = OrderedDict{Int, TypeDesc}(
            1 => primi32, 2 => primi64, 3 => primf64, 4 => primnotreal,
            5 => StructDesc(
                "COpt{Float64}", 16, 8, FieldDesc[
                    FieldDesc("has_value", 1, 0),
                    FieldDesc("value", 3, 8),
                ]
            ),
            6 => StructDesc(
                "NotACOpt", 16, 8, FieldDesc[
                    FieldDesc("has_value", 1, 0),
                    FieldDesc("value", 3, 8),
                ]
            ),
            7 => StructDesc(
                "COptInt64HasValue", 16, 8, FieldDesc[
                    FieldDesc("has_value", 2, 0),  # Int64 — not Int32
                    FieldDesc("value", 3, 8),
                ]
            ),
            8 => StructDesc(
                "COptBadNames", 16, 8, FieldDesc[
                    FieldDesc("present", 1, 0),
                    FieldDesc("value", 3, 8),
                ]
            ),
            9 => StructDesc(
                "COptUnsupportedValue", 16, 8, FieldDesc[
                    FieldDesc("has_value", 1, 0),
                    FieldDesc("value", 4, 8),  # NotARealType — not in scalar_payload_types
                ]
            ),
            10 => StructDesc(
                "COptThreeFields", 16, 8, FieldDesc[
                    FieldDesc("has_value", 1, 0),
                    FieldDesc("value", 3, 8),
                    FieldDesc("extra", 3, 8),
                ]
            ),
            11 => PrimitiveTypeDesc("Cvoid", false, 0, 0, 1),
            12 => StructDesc(
                # `value` is `Cvoid`: matches the COpt shape, but `Cvoid`
                # is absent from `scalar_payload_types`. Represents
                # COpt{Nothing} (`Nothing`/`Cvoid` are the same Julia type).
                "COptCvoidValue", 16, 8, FieldDesc[
                    FieldDesc("has_value", 1, 0),
                    FieldDesc("value", 11, 8),
                ]
            ),
        )
        @test !isnothing(coinfo(ti[5], ti))
        @test isnothing(coinfo(ti[6], ti)) # wrong name prefix
        @test isnothing(coinfo(ti[7], ti)) # has_value is Int64, not Int32
        @test isnothing(coinfo(ti[8], ti)) # wrong field names
        @test !isnothing(coinfo(ti[9], ti)) # value is a primitive: a structural match
        @test coinfo(ti[9], ti).value_type == "NotARealType"
        @test isnothing(pycoinfo(ti[9], ti)) # ...but not a supported payload type
        @test isnothing(coinfo(ti[10], ti)) # too many fields
        @test !isnothing(coinfo(ti[12], ti)) # COpt{Nothing} matches structurally
        @test coinfo(ti[12], ti).value_type == "Cvoid"
        @test isnothing(pycoinfo(ti[12], ti)) # ...but Cvoid is not a scalar payload type

        # Field order may be either way.
        flipped = StructDesc(
            "COpt{Float64}", 16, 8, FieldDesc[
                FieldDesc("value", 3, 8),
                FieldDesc("has_value", 1, 0),
            ]
        )
        @test !isnothing(coinfo(flipped, ti))
    end

    @testset "jlwstatus_location" begin
        # Three outcomes: no status, the return type *is* a JLWStatus, and a
        # JLWStatus embedded as a top-level field of the return struct. The
        # recognizer reports the raw ABI field name; `_python_status_path`
        # turns it into a Python member path, escaping keywords.
        abi = read_abi_info("bindinginfo_jlwstatus.json")
        byname(sym) = only(m for m in abi.entrypoints if m.symbol == sym)

        @test JuliaLibWrapping.jlwstatus_location(byname("plain_add"), abi.typeinfo) === nothing
        @test JuliaLibWrapping._python_status_path(byname("plain_add"), abi.typeinfo) === nothing

        direct = JuliaLibWrapping.jlwstatus_location(byname("do_thing"), abi.typeinfo)
        @test direct !== nothing
        @test direct.field === nothing
        @test JuliaLibWrapping._python_status_path(byname("do_thing"), abi.typeinfo) == ""

        embedded = JuliaLibWrapping.jlwstatus_location(byname("compute"), abi.typeinfo)
        @test embedded !== nothing
        @test embedded.field == "status"
        @test JuliaLibWrapping._python_status_path(byname("compute"), abi.typeinfo) == ".status"

        # A field named after a Python keyword is escaped on the way out;
        # the recognizer itself reports the unsanitized ABI name.
        primi32 = PrimitiveTypeDesc("Int32", true, 32, 4, 4)
        msgarr = ArrayDesc("NTuple{256, UInt8}", 3, 256, 256, 1)
        primu8 = PrimitiveTypeDesc("UInt8", false, 8, 1, 1)
        status = StructDesc(
            "JLWStatus", 264, 8, FieldDesc[
                FieldDesc("code", 1, 0),
                FieldDesc("message", 2, 8),
            ]
        )
        ti = OrderedDict{Int, TypeDesc}(
            1 => primi32, 2 => msgarr, 3 => primu8, 4 => status,
            5 => StructDesc(
                "KeywordFieldResult", 272, 8, FieldDesc[
                    FieldDesc("lambda", 4, 0),
                    FieldDesc("n", 1, 264),
                ]
            ),
        )
        method = JuliaLibWrapping.MethodDesc("kw", "kw()", 5, JuliaLibWrapping.ArgDesc[])
        @test JuliaLibWrapping.jlwstatus_location(method, ti).field == "lambda"
        @test JuliaLibWrapping._python_status_path(method, ti) == ".lambda_"
    end

    @testset "CString vocabulary" begin
        # Borrowed CString conversion requires no numpy or release function.
        abi = read_abi_info("bindinginfo_cstring.json")
        mktempdir() do path
            dest = PythonTarget(path, "cstring_demo", "libcstring")
            write_wrapper(dest, abi)

            bindings_path = joinpath(path, "cstring_demo", "_lowlevel.py")
            bindings = read(bindings_path, String)

            # No numpy: CString helpers use only `ctypes`.
            @test !occursin("import numpy", bindings)
            pyproject = read(joinpath(path, "pyproject.toml"), String)
            @test !occursin("numpy", pyproject)

            # Borrowed classes construct values but do not release them.
            @test occursin("class CString_borrowed(ctypes.Structure):", bindings)
            @test occursin("(\"length\", ctypes.c_int32)", bindings)
            @test occursin("(\"data\", ctypes.POINTER(ctypes.c_uint8))", bindings)
            @test occursin("def from_str(cls, s):", bindings)
            @test occursin("def from_bytes(cls, b):", bindings)
            @test occursin("def as_bytes(self):", bindings)
            @test occursin("def as_str(self):", bindings)
            @test occursin("s.encode(\"utf-8\")", bindings)
            @test occursin("ctypes.string_at(self.data, self.length)", bindings)
            @test occursin(".decode(\"utf-8\")", bindings)
            @test !occursin("def free(self):", bindings)

            # Round-trip-direction entrypoints are emitted as bare bindings.
            @test occursin("_lib.greeting_length.argtypes = [CString_borrowed]", bindings)
            @test occursin("_lib.greeting.restype = CString_borrowed", bindings)

            golden = read(joinpath(@__DIR__, "expected_cstring_lowlevel.py"), String)
            @test bindings == golden

            # Façade auto-wrap: CString args/returns become str in/out.
            facade = read(joinpath(path, "cstring_demo", "_facade.py"), String)
            @test occursin(
                "def greeting_length(s):\n    _s = CString_borrowed.from_str(s)\n" *
                    "    return _lowlevel.greeting_length(_s)", facade
            )
            @test occursin(
                "def greeting():\n    _result = _lowlevel.greeting()\n" *
                    "    return _result.as_str()", facade
            )
            @test !occursin("_result.free()", facade)
            golden_facade = read(joinpath(@__DIR__, "expected_cstring_facade.py"), String)
            @test facade == golden_facade

            python3 = Sys.which("python3")
            if python3 !== nothing
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr = devnull, stdout = devnull); wait = true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
        end
    end

    @testset "CString owned-return vocabulary" begin
        # The consumer releases an owning return with `jlw_free`.
        abi = read_abi_info("bindinginfo_cstring_owned.json")
        mktempdir() do path
            dest = PythonTarget(path, "cstring_owned_demo", "libcstringowned")
            write_wrapper(dest, abi)

            bindings_path = joinpath(path, "cstring_owned_demo", "_lowlevel.py")
            bindings = read(bindings_path, String)

            # Owning classes have an idempotent `free()` but no constructors.
            @test occursin("class CString_owned(ctypes.Structure):", bindings)
            @test !occursin("def from_str(cls, s):", bindings)
            @test !occursin("def from_bytes(cls, b):", bindings)
            @test occursin("def as_bytes(self):", bindings)
            @test occursin("def as_str(self):", bindings)
            @test occursin("        if getattr(self, \"_freed\", False):\n            return", bindings)
            @test occursin("_lib.jlw_free(ctypes.cast(self.data, ctypes.c_void_p))", bindings)
            @test occursin("        self._freed = True", bindings)

            golden = read(joinpath(@__DIR__, "expected_cstring_owned_lowlevel.py"), String)
            @test bindings == golden

            # Façade auto-wrap: decode to `str` first, then free in `finally`.
            facade = read(joinpath(path, "cstring_owned_demo", "_facade.py"), String)
            @test occursin(
                "def give_greeting():\n    _result = _lowlevel.give_greeting()\n" *
                    "    try:\n        _out = _result.as_str()\n" *
                    "    finally:\n        _result.free()\n    return _out",
                facade
            )
            @test !occursin("_lowlevel._lib.jlw_free", facade)
            golden_facade = read(joinpath(@__DIR__, "expected_cstring_owned_facade.py"), String)
            @test facade == golden_facade

            python3 = Sys.which("python3")
            if !isnothing(python3)
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr = devnull, stdout = devnull); wait = true))
                facade_path = joinpath(path, "cstring_owned_demo", "_facade.py")
                cmd_f = `$python3 -c "import ast; ast.parse(open('$facade_path').read())"`
                @test success(run(pipeline(cmd_f; stderr = devnull, stdout = devnull); wait = true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
        end
    end

    @testset "CString owning return without release symbols" begin
        # Same gate as CArray/CStrArray/CDict: an owning return with no
        # release entrypoints falls back to a mechanical TODO naming the macro
        # to add, rather than emitting a call to an absent symbol.
        abi = read_abi_info("bindinginfo_cstring_owned_nofree.json")
        @test JuliaLibWrapping._release_symbols_present(abi) === false
        mktempdir() do path
            dest = PythonTarget(path, "cstring_owned_nofree_demo", "libcstringownednofree")
            write_wrapper(dest, abi)

            bindings_path = joinpath(path, "cstring_owned_nofree_demo", "_lowlevel.py")
            bindings = read(bindings_path, String)
            @test !occursin("_lib.jlw_free.argtypes", bindings)
            @test occursin("def free(self):", bindings)
            @test !occursin("_lib.jlw_free(ctypes.cast(self.data, ctypes.c_void_p))", bindings)
            @test occursin(
                "raise RuntimeError(\"this library does not export release entrypoints; " *
                    "add JLWInterop.@export_release_entrypoints to the library\")",
                bindings
            )

            golden = read(joinpath(@__DIR__, "expected_cstring_owned_nofree_lowlevel.py"), String)
            @test bindings == golden

            facade = read(joinpath(path, "cstring_owned_nofree_demo", "_facade.py"), String)
            @test !occursin("def give_greeting():", facade)
            @test occursin(
                "from ._lowlevel import give_greeting  # TODO: hand-wrap — " *
                    "owning return needs release entrypoints; add " *
                    "JLWInterop.@export_release_entrypoints to the library",
                facade
            )
            golden_facade = read(joinpath(@__DIR__, "expected_cstring_owned_nofree_facade.py"), String)
            @test facade == golden_facade

            python3 = Sys.which("python3")
            if !isnothing(python3)
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr = devnull, stdout = devnull); wait = true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
        end
    end

    @testset "CStrArray vocabulary" begin
        # CStrArray conversion does not require numpy — pure ctypes, like
        # CString. Exercises a borrowed argument (take_strs), an owning
        # return that must be converted then freed via jlw_free_strings
        # (give_strs, auto-wrapped because both release symbols are
        # present in this fixture — see `_release_symbols_present`), and
        # the macro-emitted jlw_free/jlw_free_strings release entrypoints
        # themselves: bound on `_lib` (argtypes/restype) but excluded from
        # `_lowlevel.py`'s module-level `def`s and from the façade/`__all__`
        # entirely — they are internal plumbing, not part of the public API.
        abi = read_abi_info("bindinginfo_cstrarray.json")
        mktempdir() do path
            dest = PythonTarget(path, "cstrarray_demo", "libcstrarray")
            write_wrapper(dest, abi)

            bindings_path = joinpath(path, "cstrarray_demo", "_lowlevel.py")
            bindings = read(bindings_path, String)

            # No numpy: CStrArray helpers use only `ctypes`.
            @test !occursin("import numpy", bindings)
            pyproject = read(joinpath(path, "pyproject.toml"), String)
            @test !occursin("numpy", pyproject)

            # The macro-emitted release entrypoints get no module-level
            # `def` wrapper (bound on `_lib` only — see the golden compare
            # below for the argtypes/restype shape).
            @test !occursin("def jlw_free(", bindings)
            @test !occursin("def jlw_free_strings(", bindings)
            # `Cvoid` is a `null` type id in the ABI JSON — both the
            # bare-return case and the `Ptr{Nothing}`-argument case.
            # Mishandling either would silently reintroduce
            # `ffi_prep_cif failed` / `TypeError: expected LP_Nothing
            # instance instead of c_void_p` at the first real call.
            @test !occursin("_lib.jlw_free.restype = Nothing", bindings)
            @test !occursin("_lib.jlw_free_strings.restype = Nothing", bindings)
            @test !occursin("ctypes.POINTER(Nothing)", bindings)

            # Borrowed classes construct values; owned classes release them.
            @test !occursin("(\"owned\", ctypes.c_int32)", bindings)
            @test occursin("class CStrArray_borrowed(ctypes.Structure):", bindings)
            @test occursin("class CStrArray_owned(ctypes.Structure):", bindings)
            borrowed_body = classbody(bindings, "CStrArray_borrowed")
            owned_body = classbody(bindings, "CStrArray_owned")
            @test occursin("def from_list(cls, items):", borrowed_body)
            @test !occursin("def free(self):", borrowed_body)
            @test !occursin("def from_list(cls, items):", owned_body)
            # Low-level release is idempotent.
            @test occursin("def free(self):", owned_body)
            @test occursin("if getattr(self, \"_freed\", False):\n            return", owned_body)
            @test occursin("self._freed = True", owned_body)

            golden = read(joinpath(@__DIR__, "expected_cstrarray_lowlevel.py"), String)
            @test bindings == golden

            # jlw_free/jlw_free_strings are release-entrypoint internals —
            # never re-exported from the façade (no TODO line, no bare
            # re-export) and never listed in `__all__`, regardless of what
            # their own (raw-pointer) argument shape would otherwise
            # classify to.
            facade = read(joinpath(path, "cstrarray_demo", "_facade.py"), String)
            @test !occursin("import jlw_free", facade)
            @test !occursin("\"jlw_free\"", facade)
            @test !occursin("\"jlw_free_strings\"", facade)
            # The owning-return result is converted, then freed via
            # `.free()` in a `finally`.
            @test occursin("try:\n        _out = _result.as_list()\n    finally:\n        _result.free()", facade)
            @test !occursin("if _result.owned", facade)
            @test !occursin("_lowlevel._lib.jlw_free", facade)
            golden_facade = read(joinpath(@__DIR__, "expected_cstrarray_facade.py"), String)
            @test facade == golden_facade

            python3 = Sys.which("python3")
            if !isnothing(python3)
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr = devnull, stdout = devnull); wait = true))
                facade_path = joinpath(path, "cstrarray_demo", "_facade.py")
                cmd_f = `$python3 -c "import ast; ast.parse(open('$facade_path').read())"`
                @test success(run(pipeline(cmd_f; stderr = devnull, stdout = devnull); wait = true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
        end
    end

    @testset "CDict vocabulary" begin
        # CDict conversion does not require numpy — pure ctypes, like
        # CStrArray. Exercises a borrowed argument (take_dict), an owning
        # return that must be converted then freed via BOTH release
        # entrypoints (give_dict: jlw_free_strings for `keys`, jlw_free for
        # `values` — both present in this fixture, so give_dict is
        # auto-wrapped), and the macro-emitted jlw_free/jlw_free_strings
        # release entrypoints themselves: bound on `_lib` but excluded
        # from `_lowlevel.py`'s module-level `def`s and from the
        # façade/`__all__` entirely — they are internal plumbing.
        abi = read_abi_info("bindinginfo_cdict.json")
        mktempdir() do path
            dest = PythonTarget(path, "cdict_demo", "libcdict")
            write_wrapper(dest, abi)

            bindings_path = joinpath(path, "cdict_demo", "_lowlevel.py")
            bindings = read(bindings_path, String)

            # No numpy: CDict helpers use only `ctypes`.
            @test !occursin("import numpy", bindings)
            pyproject = read(joinpath(path, "pyproject.toml"), String)
            @test !occursin("numpy", pyproject)

            # The macro-emitted release entrypoints get no module-level
            # `def` wrapper (bound on `_lib` only — see the golden compare
            # below for the argtypes/restype shape).
            @test !occursin("def jlw_free(", bindings)
            @test !occursin("def jlw_free_strings(", bindings)
            # See the identical comment in the "CStrArray vocabulary"
            # testset above. CDict's owning
            # return frees `values` via `jlw_free(ctypes.cast(...,
            # ctypes.c_void_p))`, so a regression here would silently
            # reintroduce `TypeError: expected LP_Nothing instance instead
            # of c_void_p` at the first real call.
            @test !occursin("_lib.jlw_free.restype = Nothing", bindings)
            @test !occursin("_lib.jlw_free_strings.restype = Nothing", bindings)
            @test !occursin("ctypes.POINTER(Nothing)", bindings)

            # Borrowed classes construct values; owned classes release them.
            @test !occursin("(\"owned\", ctypes.c_int32)", bindings)
            @test occursin("class CDict_borrowed_Float64(ctypes.Structure):", bindings)
            @test occursin("class CDict_owned_Float64(ctypes.Structure):", bindings)
            borrowed_body = classbody(bindings, "CDict_borrowed_Float64")
            owned_body = classbody(bindings, "CDict_owned_Float64")
            @test occursin("def from_dict(cls, d):", borrowed_body)
            @test !occursin("def free(self):", borrowed_body)
            @test !occursin("def from_dict(cls, d):", owned_body)
            @test occursin("def free(self):", owned_body)
            @test occursin("if getattr(self, \"_freed\", False):\n            return", owned_body)
            @test occursin("self._freed = True", owned_body)

            golden = read(joinpath(@__DIR__, "expected_cdict_lowlevel.py"), String)
            @test bindings == golden

            # jlw_free/jlw_free_strings are release-entrypoint internals —
            # never re-exported and never listed in `__all__`.
            facade = read(joinpath(path, "cdict_demo", "_facade.py"), String)
            @test !occursin("import jlw_free", facade)
            @test !occursin("\"jlw_free\"", facade)
            @test !occursin("\"jlw_free_strings\"", facade)
            # The owning-return result is converted, then freed via
            # `.free()` in a `finally`, with no manual `owned` check or
            # `ctypes` import in the façade itself.
            @test occursin("try:\n        _out = _result.as_dict()\n    finally:\n        _result.free()", facade)
            @test !occursin("if _result.owned", facade)
            @test !occursin("_lowlevel._lib.jlw_free", facade)
            @test !occursin("import ctypes", facade)
            golden_facade = read(joinpath(@__DIR__, "expected_cdict_facade.py"), String)
            @test facade == golden_facade

            python3 = Sys.which("python3")
            if !isnothing(python3)
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr = devnull, stdout = devnull); wait = true))
                facade_path = joinpath(path, "cdict_demo", "_facade.py")
                cmd_f = `$python3 -c "import ast; ast.parse(open('$facade_path').read())"`
                @test success(run(pipeline(cmd_f; stderr = devnull, stdout = devnull); wait = true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
        end
    end

    @testset "CDict{Int32} vocabulary" begin
        # Verifies that the value-type parameterization (`_python_cdict_info`'s
        # `ctype` and the generated from_dict/as_dict codegen that
        # substitutes it) varies correctly for a value type other than the
        # Float64 exercised by the main "CDict vocabulary" testset. Field
        # offsets are identical to the Float64 fixture — `values` is a
        # pointer field, so its own size never depends on the pointee's size.
        # Also re-exercises the jlw_free `ctypes.c_void_p` argtype
        # handling on a second, independent fixture.
        abi = read_abi_info("bindinginfo_cdict_int32.json")
        mktempdir() do path
            dest = PythonTarget(path, "cdict_int32_demo", "libcdicti32")
            write_wrapper(dest, abi)

            bindings_path = joinpath(path, "cdict_int32_demo", "_lowlevel.py")
            bindings = read(bindings_path, String)

            @test occursin("class CDict_borrowed_Int32(ctypes.Structure):", bindings)
            @test occursin("class CDict_owned_Int32(ctypes.Structure):", bindings)
            @test occursin("(\"length\", ctypes.c_int64)", bindings)
            # Keys carry the dictionary's ownership, so the two dictionaries
            # point at two distinct CString classes.
            @test occursin(
                "(\"keys\", ctypes.POINTER(CString_borrowed))", bindings
            )
            @test occursin(
                "(\"keys\", ctypes.POINTER(CString_owned))", bindings
            )
            @test occursin("(\"values\", ctypes.POINTER(ctypes.c_int32))", bindings)
            # The value ctype substitution varies: Int32 here, not Float64.
            @test occursin("varr = (ctypes.c_int32 * len(keys))(*d.values())", bindings)
            @test occursin(
                "values=ctypes.cast(varr, ctypes.POINTER(ctypes.c_int32))", bindings
            )
            @test !occursin("ctypes.c_double", bindings)

            @test occursin("_lib.take_dict_i32.argtypes = [CDict_borrowed_Int32]", bindings)
            @test occursin("_lib.give_dict_i32.restype = CDict_owned_Int32", bindings)
            # Round-2 fix re-exercised on an independent fixture.
            @test occursin("_lib.jlw_free.argtypes = [ctypes.c_void_p]", bindings)
            @test occursin("_lib.jlw_free.restype = None", bindings)
            @test !occursin("ctypes.POINTER(Nothing)", bindings)

            golden = read(joinpath(@__DIR__, "expected_cdict_int32_lowlevel.py"), String)
            @test bindings == golden

            facade = read(joinpath(path, "cdict_int32_demo", "_facade.py"), String)
            @test occursin(
                "def give_dict_i32():\n    _result = _lowlevel.give_dict_i32()\n" *
                    "    try:\n        _out = _result.as_dict()\n" *
                    "    finally:\n        _result.free()\n    return _out", facade
            )
            golden_facade = read(joinpath(@__DIR__, "expected_cdict_int32_facade.py"), String)
            @test facade == golden_facade

            python3 = Sys.which("python3")
            if !isnothing(python3)
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr = devnull, stdout = devnull); wait = true))
                facade_path = joinpath(path, "cdict_int32_demo", "_facade.py")
                cmd_f = `$python3 -c "import ast; ast.parse(open('$facade_path').read())"`
                @test success(run(pipeline(cmd_f; stderr = devnull, stdout = devnull); wait = true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
        end
    end

    @testset "COpt vocabulary" begin
        # COpt conversion does not require numpy or jlw_free* — it is a
        # by-value carrier (no heap allocation), so the owning-return
        # façade wrapper unwraps with no free call.
        abi = read_abi_info("bindinginfo_copt.json")
        mktempdir() do path
            dest = PythonTarget(path, "copt_demo", "libcopt")
            write_wrapper(dest, abi)

            bindings_path = joinpath(path, "copt_demo", "_lowlevel.py")
            bindings = read(bindings_path, String)

            @test !occursin("import numpy", bindings)
            pyproject = read(joinpath(path, "pyproject.toml"), String)
            @test !occursin("numpy", pyproject)

            # No jlw_free* entrypoints in this by-value-only fixture.
            @test !occursin("jlw_free", bindings)

            golden = read(joinpath(@__DIR__, "expected_copt_lowlevel.py"), String)
            @test bindings == golden

            # COpt's owning return unwraps with NO free call (by-value).
            facade = read(joinpath(path, "copt_demo", "_facade.py"), String)
            @test !occursin("jlw_free", facade)
            golden_facade = read(joinpath(@__DIR__, "expected_copt_facade.py"), String)
            @test facade == golden_facade

            python3 = Sys.which("python3")
            if !isnothing(python3)
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr = devnull, stdout = devnull); wait = true))
                facade_path = joinpath(path, "copt_demo", "_facade.py")
                cmd_f = `$python3 -c "import ast; ast.parse(open('$facade_path').read())"`
                @test success(run(pipeline(cmd_f; stderr = devnull, stdout = devnull); wait = true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
        end
    end

    @testset "_release_symbols_present" begin
        # Both jlw_free AND jlw_free_strings must be present — either alone
        # is not enough, and a library with no release entrypoints at all
        # (or an unrelated function that happens to be named similarly)
        # must not be mistaken for having them.
        present = JuliaLibWrapping._release_symbols_present
        abi_both = read_abi_info("bindinginfo_cstrarray.json")
        @test present(abi_both) === true
        abi_neither = read_abi_info("bindinginfo_cstrarray_nofree.json")
        @test present(abi_neither) === false

        # Hand-built: only one of the two symbols present.
        only_free = JuliaLibWrapping.ABIInfo(
            OrderedDict{Int, TypeDesc}(1 => PrimitiveTypeDesc("Int64", true, 64, 8, 8)),
            BitSet(),
            JuliaLibWrapping.MethodDesc[
                JuliaLibWrapping.MethodDesc("jlw_free", "jlw_free(p)", 1, JuliaLibWrapping.ArgDesc[]),
            ]
        )
        @test present(only_free) === false
        only_strings = JuliaLibWrapping.ABIInfo(
            OrderedDict{Int, TypeDesc}(1 => PrimitiveTypeDesc("Int64", true, 64, 8, 8)),
            BitSet(),
            JuliaLibWrapping.MethodDesc[
                JuliaLibWrapping.MethodDesc(
                    "jlw_free_strings", "jlw_free_strings(p, n)", 1, JuliaLibWrapping.ArgDesc[]
                ),
            ]
        )
        @test present(only_strings) === false
        neither = JuliaLibWrapping.ABIInfo(
            OrderedDict{Int, TypeDesc}(1 => PrimitiveTypeDesc("Int64", true, 64, 8, 8)),
            BitSet(), JuliaLibWrapping.MethodDesc[]
        )
        @test present(neither) === false
        both = JuliaLibWrapping.ABIInfo(
            OrderedDict{Int, TypeDesc}(1 => PrimitiveTypeDesc("Int64", true, 64, 8, 8)),
            BitSet(),
            JuliaLibWrapping.MethodDesc[
                JuliaLibWrapping.MethodDesc("jlw_free", "jlw_free(p)", 1, JuliaLibWrapping.ArgDesc[]),
                JuliaLibWrapping.MethodDesc(
                    "jlw_free_strings", "jlw_free_strings(p, n)", 1, JuliaLibWrapping.ArgDesc[]
                ),
            ]
        )
        @test present(both) === true
    end

    @testset "CStrArray without release symbols" begin
        # Owning returns require release entrypoints; borrowed arguments do not.
        abi = read_abi_info("bindinginfo_cstrarray_nofree.json")
        @test JuliaLibWrapping._release_symbols_present(abi) === false
        mktempdir() do path
            dest = PythonTarget(path, "cstrarray_nofree_demo", "libcstrarraynofree")
            write_wrapper(dest, abi)

            bindings_path = joinpath(path, "cstrarray_nofree_demo", "_lowlevel.py")
            bindings = read(bindings_path, String)
            # Keep the low-level API shape, but report missing release symbols.
            @test !occursin("_lib.jlw_free_strings.argtypes", bindings)
            @test !occursin("_lib.jlw_free_strings.restype", bindings)
            @test !occursin("_lib.jlw_free.argtypes", bindings)
            @test !occursin("_lib.jlw_free.restype", bindings)
            @test occursin("def free(self):", bindings)
            @test !occursin("_lib.jlw_free_strings(self.data, self.length)", bindings)
            @test occursin(
                "raise RuntimeError(\"this library does not export release entrypoints; " *
                    "add JLWInterop.@export_release_entrypoints to the library\")",
                bindings
            )
            @test occursin("_lib.take_strs.argtypes = [CStrArray_borrowed]", bindings)
            @test occursin("_lib.give_strs.restype = CStrArray_owned", bindings)

            golden = read(joinpath(@__DIR__, "expected_cstrarray_nofree_lowlevel.py"), String)
            @test bindings == golden

            facade = read(joinpath(path, "cstrarray_nofree_demo", "_facade.py"), String)
            # Borrowed arguments remain auto-wrapped.
            @test occursin(
                "def take_strs(a):\n    _a = CStrArray_borrowed.from_list(a)\n" *
                    "    return _lowlevel.take_strs(_a)", facade
            )
            # Owning returns fall back to a TODO re-export.
            @test !occursin("def give_strs():", facade)
            @test occursin(
                "from ._lowlevel import give_strs  # TODO: hand-wrap — " *
                    "owning return needs release entrypoints; add " *
                    "JLWInterop.@export_release_entrypoints to the library",
                facade
            )
            golden_facade = read(joinpath(@__DIR__, "expected_cstrarray_nofree_facade.py"), String)
            @test facade == golden_facade

            python3 = Sys.which("python3")
            if !isnothing(python3)
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr = devnull, stdout = devnull); wait = true))
                facade_path = joinpath(path, "cstrarray_nofree_demo", "_facade.py")
                cmd_f = `$python3 -c "import ast; ast.parse(open('$facade_path').read())"`
                @test success(run(pipeline(cmd_f; stderr = devnull, stdout = devnull); wait = true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
        end
    end

    @testset "CDict without release symbols" begin
        # Owning returns require release entrypoints; borrowed arguments do not.
        abi = read_abi_info("bindinginfo_cdict_nofree.json")
        @test JuliaLibWrapping._release_symbols_present(abi) === false
        mktempdir() do path
            dest = PythonTarget(path, "cdict_nofree_demo", "libcdictnofree")
            write_wrapper(dest, abi)

            bindings_path = joinpath(path, "cdict_nofree_demo", "_lowlevel.py")
            bindings = read(bindings_path, String)
            @test !occursin("_lib.jlw_free_strings.argtypes", bindings)
            @test !occursin("_lib.jlw_free.argtypes", bindings)
            @test occursin("def free(self):", bindings)
            @test !occursin("_lib.jlw_free_strings(self.keys, self.length)", bindings)
            @test occursin(
                "raise RuntimeError(\"this library does not export release entrypoints; " *
                    "add JLWInterop.@export_release_entrypoints to the library\")",
                bindings
            )
            @test occursin("_lib.take_dict.argtypes = [CDict_borrowed_Float64]", bindings)
            @test occursin("_lib.give_dict.restype = CDict_owned_Float64", bindings)

            golden = read(joinpath(@__DIR__, "expected_cdict_nofree_lowlevel.py"), String)
            @test bindings == golden

            facade = read(joinpath(path, "cdict_nofree_demo", "_facade.py"), String)
            @test occursin(
                "def take_dict(d):\n    _d = CDict_borrowed_Float64.from_dict(d)\n" *
                    "    return _lowlevel.take_dict(_d)", facade
            )
            @test !occursin("def give_dict():", facade)
            @test occursin(
                "from ._lowlevel import give_dict  # TODO: hand-wrap — " *
                    "owning return needs release entrypoints; add " *
                    "JLWInterop.@export_release_entrypoints to the library",
                facade
            )
            golden_facade = read(joinpath(@__DIR__, "expected_cdict_nofree_facade.py"), String)
            @test facade == golden_facade

            python3 = Sys.which("python3")
            if !isnothing(python3)
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr = devnull, stdout = devnull); wait = true))
                facade_path = joinpath(path, "cdict_nofree_demo", "_facade.py")
                cmd_f = `$python3 -c "import ast; ast.parse(open('$facade_path').read())"`
                @test success(run(pipeline(cmd_f; stderr = devnull, stdout = devnull); wait = true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
        end
    end

    @testset "CMatrix vocabulary" begin
        # CMatrix{owned,T} = CArray{owned,T,2}: recognition + column-major numpy
        # helpers in the Python emitter.
        abi = read_abi_info("bindinginfo_cmatrix.json")
        mktempdir() do path
            dest = PythonTarget(path, "cmatrix_demo", "libcmatrix")
            write_wrapper(dest, abi)

            bindings_path = joinpath(path, "cmatrix_demo", "_lowlevel.py")
            bindings = read(bindings_path, String)

            # Numpy is imported and declared as a dep when CMatrix is present.
            @test occursin("import numpy as np", bindings)
            pyproject = read(joinpath(path, "pyproject.toml"), String)
            @test occursin("dependencies = [\"numpy>=1.20\"]", pyproject)

            # The struct class is emitted with the two-field layout and
            # decorated with the borrowed-flavored helpers.
            @test occursin("class CMatrix_borrowed_Float64(ctypes.Structure):", bindings)
            @test occursin("(\"dims\", (ctypes.c_int32 * 2))", bindings)
            @test occursin("(\"data\", ctypes.POINTER(ctypes.c_double))", bindings)
            # Borrowed storage belongs to the caller: no ownership field, and
            # no `free()` to call on memory this side never allocated.
            @test !occursin("owned", bindings)
            @test !occursin("def free(self):", bindings)

            # from_numpy enforces column-major (Fortran) layout — silently
            # treating a C-order numpy array as column-major would transpose.
            @test occursin("def from_numpy(cls, arr):", bindings)
            @test occursin("if arr.ndim != 2:", bindings)
            @test occursin("if not arr.flags.f_contiguous:", bindings)
            @test occursin("expected_dtype = np.dtype(\"float64\")", bindings)
            @test occursin("dims=(ctypes.c_int32 * 2)(*arr.shape)", bindings)

            # as_numpy returns a view with column-major strides.
            @test occursin("def as_numpy(self):", bindings)
            @test occursin(
                "np.ctypeslib.as_array(self.data, shape=tuple(self.dims)[::-1]).T",
                bindings
            )

            # Golden-file comparison.
            golden = read(joinpath(@__DIR__, "expected_cmatrix_lowlevel.py"), String)
            @test bindings == golden

            # Façade auto-wrap: CMatrix arg becomes numpy in.
            facade = read(joinpath(path, "cmatrix_demo", "_facade.py"), String)
            @test occursin("import numpy as np", facade)
            @test occursin(
                "def trace_cmatrix(m):\n    _m = CMatrix_borrowed_Float64.from_numpy(m)\n" *
                    "    return _lowlevel.trace_cmatrix(_m)", facade
            )
            golden_facade = read(joinpath(@__DIR__, "expected_cmatrix_facade.py"), String)
            @test facade == golden_facade

            python3 = Sys.which("python3")
            if python3 !== nothing
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr = devnull, stdout = devnull); wait = true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
        end
    end

    @testset "CArray{T,3} vocabulary" begin
        # Locks in 3-D coverage: the rank-agnostic CArray recognizer should
        # accept `CArray{:borrowed, Float64, 3}` and the emitter should produce
        # the same helper shape as for N=1,2 but with ndim=3 dispatches.
        abi = read_abi_info("bindinginfo_carray3.json")
        mktempdir() do path
            dest = PythonTarget(path, "carray3_demo", "libcarray3")
            write_wrapper(dest, abi)

            bindings_path = joinpath(path, "carray3_demo", "_lowlevel.py")
            bindings = read(bindings_path, String)

            @test occursin("class CArray_borrowed_Float64_3(ctypes.Structure):", bindings)
            @test occursin("(\"dims\", (ctypes.c_int32 * 3))", bindings)
            @test !occursin("owned", bindings)
            @test !occursin("def free(self):", bindings)
            @test occursin("if arr.ndim != 3:", bindings)
            @test occursin("if not arr.flags.f_contiguous:", bindings)
            @test occursin("dims=(ctypes.c_int32 * 3)(*arr.shape)", bindings)
            @test occursin(
                "np.ctypeslib.as_array(self.data, shape=tuple(self.dims)[::-1]).T",
                bindings
            )

            golden = read(joinpath(@__DIR__, "expected_carray3_lowlevel.py"), String)
            @test bindings == golden

            facade = read(joinpath(path, "carray3_demo", "_facade.py"), String)
            @test occursin(
                "def sum3d(a):\n    _a = CArray_borrowed_Float64_3.from_numpy(a)\n" *
                    "    return _lowlevel.sum3d(_a)", facade
            )
            golden_facade = read(joinpath(@__DIR__, "expected_carray3_facade.py"), String)
            @test facade == golden_facade

            python3 = Sys.which("python3")
            if python3 !== nothing
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr = devnull, stdout = devnull); wait = true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
        end
    end

    @testset "CArray owned-return vocabulary" begin
        # Exercises the owning-return façade path for CArray: carray3/cmatrix/
        # libsimple only ever cover borrowed CArrays, so this dedicated fixture
        # (one no-arg function returning a fresh CVector{:owned, Float64}, plus
        # the macro-emitted release entrypoints) is what actually drives
        # `:carray_unwrap` through `write_wrapper`.
        abi = read_abi_info("bindinginfo_carray_owned.json")
        mktempdir() do path
            dest = PythonTarget(path, "carray_owned_demo", "libcarrayowned")
            write_wrapper(dest, abi)

            bindings_path = joinpath(path, "carray_owned_demo", "_lowlevel.py")
            bindings = read(bindings_path, String)

            # An owning class has no `from_numpy`: Python has no Julia
            # allocation to hand over. It does get `free()`, made idempotent by
            # a Python-side attribute since the struct carries no flag.
            @test occursin("class CVector_owned_Float64(ctypes.Structure):", bindings)
            @test !occursin("def from_numpy(cls, arr):", bindings)
            @test !occursin("owned=0", bindings)
            @test occursin("        if getattr(self, \"_freed\", False):\n            return", bindings)
            @test occursin("_lib.jlw_free(ctypes.cast(self.data, ctypes.c_void_p))", bindings)
            @test occursin("        self._freed = True", bindings)

            golden = read(joinpath(@__DIR__, "expected_carray_owned_lowlevel.py"), String)
            @test bindings == golden

            # Façade auto-wrap: copy unconditionally, then free in `finally`.
            facade = read(joinpath(path, "carray_owned_demo", "_facade.py"), String)
            @test occursin(
                "def give_vec():\n    _result = _lowlevel.give_vec()\n" *
                    "    try:\n        _out = np.array(_result.as_numpy(), copy=True)\n" *
                    "    finally:\n        _result.free()\n    return _out",
                facade
            )
            # No runtime ownership test survives: the type already decided.
            @test !occursin("_result.owned", facade)
            # No manual free call bypassing `.free()`, and no `ctypes` import
            # (the façade no longer touches `ctypes.*` directly).
            @test !occursin("_lowlevel._lib.jlw_free", facade)
            @test !occursin("import ctypes", facade)

            golden_facade = read(joinpath(@__DIR__, "expected_carray_owned_facade.py"), String)
            @test facade == golden_facade

            python3 = Sys.which("python3")
            if !isnothing(python3)
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr = devnull, stdout = devnull); wait = true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
        end
    end

    @testset "CArray owning return without release symbols" begin
        # A library that returns an owning CArray but has not exported the
        # release entrypoints must not have that return auto-wrapped — the
        # façade would emit a call to a symbol the shared library does not
        # export. Same gate as CStrArray/CDict: give_vec falls back to a
        # mechanical TODO naming the macro to add.
        abi = read_abi_info("bindinginfo_carray_owned_nofree.json")
        @test JuliaLibWrapping._release_symbols_present(abi) === false
        mktempdir() do path
            dest = PythonTarget(path, "carray_owned_nofree_demo", "libcarrayownednofree")
            write_wrapper(dest, abi)

            bindings_path = joinpath(path, "carray_owned_nofree_demo", "_lowlevel.py")
            bindings = read(bindings_path, String)
            # Nothing is bound on `_lib` for the absent entrypoints, so
            # `.free()` — kept so the class API shape does not depend on the
            # library — reports the missing macro instead of raising a bare
            # `AttributeError` on `_lib.jlw_free`.
            @test !occursin("_lib.jlw_free.argtypes", bindings)
            @test !occursin("_lib.jlw_free.restype", bindings)
            @test occursin("def free(self):", bindings)
            @test !occursin("_lib.jlw_free(ctypes.cast(self.data, ctypes.c_void_p))", bindings)
            @test occursin(
                "raise RuntimeError(\"this library does not export release entrypoints; " *
                    "add JLWInterop.@export_release_entrypoints to the library\")",
                bindings
            )

            golden = read(joinpath(@__DIR__, "expected_carray_owned_nofree_lowlevel.py"), String)
            @test bindings == golden

            facade = read(joinpath(path, "carray_owned_nofree_demo", "_facade.py"), String)
            @test !occursin("def give_vec():", facade)
            @test occursin(
                "from ._lowlevel import give_vec  # TODO: hand-wrap — " *
                    "owning return needs release entrypoints; add " *
                    "JLWInterop.@export_release_entrypoints to the library",
                facade
            )
            golden_facade = read(joinpath(@__DIR__, "expected_carray_owned_nofree_facade.py"), String)
            @test facade == golden_facade

            python3 = Sys.which("python3")
            if !isnothing(python3)
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr = devnull, stdout = devnull); wait = true))
                facade_path = joinpath(path, "carray_owned_nofree_demo", "_facade.py")
                cmd_f = `$python3 -c "import ast; ast.parse(open('$facade_path').read())"`
                @test success(run(pipeline(cmd_f; stderr = devnull, stdout = devnull); wait = true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
        end
    end

    @testset "CArray façade classification by ownership" begin
        # Ownership is read off the type name, and it decides the shape of the
        # wrapper on both sides of the call.
        classify_arg = JuliaLibWrapping._facade_classify_arg
        classify_ret = JuliaLibWrapping._facade_classify_return
        findtype(descs, name) = (
            k = collect(keys(descs));
            k[findfirst((id) -> descs[id].name === name, k)]
        )
        premangled(abi) = (
            d = Dict{Int, String}();
            for (id, type) in pairs(abi.typeinfo)
                type isa StructDesc && JuliaLibWrapping.mangle_python!(d, id, abi.typeinfo)
            end;
            d
        )

        borrowed = read_abi_info("bindinginfo_cmatrix.json")
        td_b = premangled(borrowed)
        cm_id = findtype(borrowed.typeinfo, "CMatrix{:borrowed, Float64}")

        # A borrowed argument arrives from numpy.
        arg_b = JuliaLibWrapping.ArgDesc("m", cm_id, false)
        @test classify_arg(arg_b, borrowed.typeinfo, td_b).kind === :carray

        # A borrowed return is a zero-copy view, and needs no release
        # entrypoints because it releases nothing.
        ret_b = JuliaLibWrapping.MethodDesc(
            "view_cmatrix", "view_cmatrix()", cm_id, JuliaLibWrapping.ArgDesc[]
        )
        plan_b = JuliaLibWrapping._facade_plan(ret_b, borrowed.typeinfo, td_b, false)
        @test plan_b.category === :auto
        @test plan_b.ret.kind === :carray_view
        # The emitted wrapper hands the view straight back: no copy, no
        # try/finally, no free.
        @test sprint(JuliaLibWrapping._emit_facade_autowrapper, ret_b, plan_b) ==
            "def view_cmatrix():\n    _result = _lowlevel.view_cmatrix()\n" *
            "    return _result.as_numpy()\n\n"

        owned = read_abi_info("bindinginfo_carray_owned.json")
        td_o = premangled(owned)
        cv_id = findtype(owned.typeinfo, "CVector{:owned, Float64}")
        m_owned = onlymatch(md -> md.symbol == "give_vec", owned.entrypoints)

        # An owning return is copied then freed, and only when the library
        # exports the release entrypoints.
        @test classify_ret(m_owned, owned.typeinfo, td_o, true).kind === :carray_unwrap
        demoted = classify_ret(m_owned, owned.typeinfo, td_o, false)
        @test demoted.kind === :opaque
        @test occursin("owning return needs release entrypoints", demoted.reason)

        # An owning CArray argument transfers a Julia allocation into the
        # library; numpy cannot supply one, so the wrapper is left to a human.
        arg_o = JuliaLibWrapping.ArgDesc("a", cv_id, false)
        cls = classify_arg(arg_o, owned.typeinfo, td_o)
        @test cls.kind === :opaque
        @test cls.reason == "argument transfers CArray ownership into the library; hand-wrap"
    end

    @testset "CString façade classification by ownership" begin
        # CString follows the CArray ownership rules.
        classify_arg = JuliaLibWrapping._facade_classify_arg
        classify_ret = JuliaLibWrapping._facade_classify_return
        findtype(descs, name) = (
            k = collect(keys(descs));
            k[findfirst((id) -> descs[id].name === name, k)]
        )
        premangled(abi) = (
            d = Dict{Int, String}();
            for (id, type) in pairs(abi.typeinfo)
                type isa StructDesc && JuliaLibWrapping.mangle_python!(d, id, abi.typeinfo)
            end;
            d
        )

        borrowed = read_abi_info("bindinginfo_cstring.json")
        td_b = premangled(borrowed)
        cs_id = findtype(borrowed.typeinfo, "CString{:borrowed}")

        # A borrowed argument arrives as a Python `str`.
        arg_b = JuliaLibWrapping.ArgDesc("s", cs_id, false)
        @test classify_arg(arg_b, borrowed.typeinfo, td_b).kind === :cstring

        # A borrowed return needs no release entrypoint.
        m_borrowed = onlymatch(md -> md.symbol == "greeting", borrowed.entrypoints)
        @test classify_ret(m_borrowed, borrowed.typeinfo, td_b, false).kind === :cstring_convert

        owned = read_abi_info("bindinginfo_cstring_owned.json")
        td_o = premangled(owned)
        cso_id = findtype(owned.typeinfo, "CString{:owned}")
        m_owned = onlymatch(md -> md.symbol == "give_greeting", owned.entrypoints)

        # An owning return requires release entrypoints.
        @test classify_ret(m_owned, owned.typeinfo, td_o, true).kind === :cstring_unwrap
        demoted = classify_ret(m_owned, owned.typeinfo, td_o, false)
        @test demoted.kind === :opaque
        @test occursin("owning return needs release entrypoints", demoted.reason)

        # Owning arguments require a manual wrapper.
        arg_o = JuliaLibWrapping.ArgDesc("s", cso_id, false)
        cls = classify_arg(arg_o, owned.typeinfo, td_o)
        @test cls.kind === :opaque
        @test cls.reason == "argument transfers CString ownership into the library; hand-wrap"
    end

    @testset "raw primitive pointer docstring" begin
        # Bare primitive pointers produce ownership guidance during generation.
        abi = read_abi_info("bindinginfo_rawptr.json")

        # Helper recognizes the raw-primitive-pointer argument.
        method = only(abi.entrypoints)
        @test JuliaLibWrapping.raw_primitive_pointer_args(method, abi.typeinfo) == [1]

        mktempdir() do path
            dest = PythonTarget(path, "rawptr_demo", "librawptr")
            bindings = @test_logs (:info,) match_mode = :any begin
                write_wrapper(dest, abi)
                read(joinpath(path, "rawptr_demo", "_lowlevel.py"), String)
            end

            # Raw pointer is still rendered as ctypes.POINTER — no numpy.
            @test !occursin("import numpy", bindings)
            pyproject = read(joinpath(path, "pyproject.toml"), String)
            @test !occursin("numpy", pyproject)

            # Docstring lands on the wrapper, names the offending arg, and
            # documents the column-major contract.
            @test occursin("def sum_doubles(data, n):", bindings)
            @test occursin(
                "Raw pointer arguments — caller owns layout and lifetime.",
                bindings
            )
            @test occursin("`data` is a raw pointer to Float64", bindings)
            @test occursin("column-major (Fortran order)", bindings)
            @test occursin("`CArray{owned,T,N}`", bindings)

            golden = read(joinpath(@__DIR__, "expected_rawptr_lowlevel.py"), String)
            @test bindings == golden

            # Façade: raw-pointer arg is not auto-wrappable; the function
            # falls back to a mechanical re-export tagged with a TODO that
            # names the offending arg and its type.
            facade = read(joinpath(path, "rawptr_demo", "_facade.py"), String)
            @test occursin(
                "from ._lowlevel import sum_doubles  # TODO: hand-wrap — " *
                    "`data`: argument has raw pointer type `Ptr{Float64}`",
                facade
            )
            @test !occursin("def sum_doubles(", facade)
            golden_facade = read(joinpath(@__DIR__, "expected_rawptr_facade.py"), String)
            @test facade == golden_facade

            python3 = Sys.which("python3")
            if python3 !== nothing
                bindings_path = joinpath(path, "rawptr_demo", "_lowlevel.py")
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr = devnull, stdout = devnull); wait = true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
        end

        # Functions with no raw primitive pointers don't trigger the @info
        # and don't pick up the docstring.
        abi_cm = read_abi_info("bindinginfo_cmatrix.json")
        method_cm = only(abi_cm.entrypoints)
        @test isempty(JuliaLibWrapping.raw_primitive_pointer_args(method_cm, abi_cm.typeinfo))
    end

    @testset "JLWStatus convention" begin
        # In-band status values become Python exceptions.
        abi_info = read_abi_info("bindinginfo_jlwstatus.json")
        mktempdir() do path
            dest = PythonTarget(path, "demo", "libdemo")
            write_wrapper(dest, abi_info)

            bindings = read(joinpath(path, "demo", "_lowlevel.py"), String)
            facade = read(joinpath(path, "demo", "_facade.py"), String)
            init = read(joinpath(path, "demo", "__init__.py"), String)

            # The JLWError exception class is defined once.
            @test occursin("class JLWError(RuntimeError):", bindings)
            @test count(
                ==("class JLWError(RuntimeError):"),
                split(bindings, '\n')
            ) == 1

            # JLWStatus.message is emitted as a ctypes byte array, not as a
            # 256-field Structure (this also implicitly tests the new
            # tuple-struct handling).
            @test occursin("(\"message\", (ctypes.c_uint8 * 256))", bindings)
            @test !occursin("NTuple_256_UInt8", bindings)

            # Direct JLWStatus return: check uses `_result.code`.
            @test occursin(
                "def do_thing(x):\n    _result = _lib.do_thing(x)\n    if _result.code != 0:",
                bindings
            )
            # Embedded JLWStatus field: check uses `_result.status.code`.
            @test occursin(
                "def compute(x):\n    _result = _lib.compute(x)\n    if _result.status.code != 0:",
                bindings
            )
            @test occursin("raise JLWError(_result.status.code, _msg)", bindings)
            # Non-JLWStatus entrypoint stays a bare mechanical binding.
            @test occursin(
                "def plain_add(a, b):\n    return _lib.plain_add(a, b)",
                bindings
            )

            # JLWError is re-exported from the package via the façade.
            @test occursin("from ._facade import *", init)
            @test occursin("    JLWError,", facade)
            @test occursin("\"JLWError\"", facade)

            # Façade generation policy for the three cases:
            #  - direct JLWStatus return → auto-wrap that discards the
            #    status struct (lowlevel already raises);
            #  - embedded JLWStatus in a compound struct → mechanical
            #    TODO (we don't know how to shape the other fields);
            #  - plain primitive-in/primitive-out → passthrough re-export
            #    without a TODO comment.
            @test occursin("def do_thing(x):\n    _lowlevel.do_thing(x)", facade)
            @test occursin(
                "from ._lowlevel import compute  # TODO: hand-wrap " *
                    "— returns struct `ResultStruct` with embedded JLWStatus",
                facade
            )
            @test occursin("from ._lowlevel import plain_add\n", facade)
            @test !occursin("plain_add  # TODO", facade)
            golden_facade = read(joinpath(@__DIR__, "expected_jlwstatus_facade.py"), String)
            @test facade == golden_facade

            python3 = Sys.which("python3")
            if python3 !== nothing
                bindings_path = joinpath(path, "demo", "_lowlevel.py")
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr = devnull, stdout = devnull); wait = true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
        end
    end

    include("test_build_library.jl")

    @testset "Aqua" begin
        Aqua.test_all(JuliaLibWrapping)
    end

    @testset "ExplicitImports" begin
        # JSON.parsefile and JSON.parse are the canonical JSON.jl entry points
        # but JSON.jl pre-dates the `public` keyword and never marked them
        # public. Disable the bundled all-qualified-accesses-are-public check
        # and re-run it with those names ignored.
        test_explicit_imports(JuliaLibWrapping; all_qualified_accesses_are_public = false)
        test_all_qualified_accesses_are_public(JuliaLibWrapping; ignore = (:parsefile, :parse))
    end
end
