using JuliaLibWrapping
using OrderedCollections
using JSON: parsefile
using Test
using Aqua
using ExplicitImports

import JuliaLibWrapping: StructDesc, FieldDesc, PointerDesc, PrimitiveTypeDesc, TypeDesc
import JuliaLibWrapping: sort_declarations!, mangle_c!

function onlymatch(f, collection)
    matches = filter(f, collection)
    if length(matches) != 1
        error("Expected exactly one match, found $(length(matches))")
    end
    return matches[1]
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
        findtype(descs, name) = (k = collect(keys(descs)); k[findfirst((id)->descs[id].name === name, k)])

        tdesc = typeinfo[findtype(typeinfo, "CVectorPair{Float32}")]
        @test tdesc.name == "CVectorPair{Float32}"
        @test length(tdesc.fields) == 2
        @test tdesc.fields[1].name == "from"
        @test typeinfo[tdesc.fields[1].type].name == "CVector{Float32}"
        @test tdesc.fields[1].offset == 0
        @test tdesc.fields[2].name == "to"
        @test typeinfo[tdesc.fields[2].type].name == "CVector{Float32}"
        @test tdesc.fields[2].offset == 16
        @test tdesc.size == 32
        tdesc = typeinfo[findtype(typeinfo, "CVector{Float32}")]
        @test tdesc.name == "CVector{Float32}"
        @test length(tdesc.fields) == 2
        @test tdesc.fields[1].name == "length"
        @test typeinfo[tdesc.fields[1].type].name == "Int32"
        @test tdesc.fields[1].offset == 0
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
        @test name2idx["CVectorPair{Float32}"] > name2idx["CVector{Float32}"]
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
        @test collect(keys(sorted)) == Int[3,2,1]

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
        @test collect(keys(sorted)) == Int[5,3,2,1,4]

        # Modify the type definitions so that test_struct1 and test_struct2 are
        # mutually recursive.
        unsorted[3].fields[1] = FieldDesc("field1", #= type =# 4, #= offset =# 0)

        sorted = copy(unsorted)
        fwd_decls = sort_declarations!(sorted)

        # At least one of the struct types should need to be forward-declared
        @test !isempty(fwd_decls)
        if fwd_decls == BitSet([1])
            # If 1 was forward-declared then 3 (and pointer to 1) is defined first
            @test collect(keys(sorted)) == Int[5,4,3,2,1]
        elseif fwd_decls == BitSet([3])
            # If 3 was forward-declared then 1 (and pointer to 3) is defined first
            @test collect(keys(sorted)) == Int[5,2,1,4,3]
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
            @test occursin("typedef struct CVector_Float32 {", content)
            @test occursin("    int32_t length;", content)
            @test occursin("    float* data;", content)
            @test occursin("CVector_Float32 from;", content)
            @test occursin("CVector_Float32 to;", content)
            @test occursin("float copyto_and_sum(CVectorPair_Float32 fromto);", content)
            @test occursin("int32_t countsame(MyTwoVec* list, int32_t n);", content)
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
    end

    @testset "PythonTarget" begin
        abi_info = read_abi_info("bindinginfo_libsimple.json")
        mktempdir() do path
            dest = PythonTarget(path, "libsimple", "libsimple")
            write_wrapper(dest, abi_info)

            bindings_path = joinpath(path, "libsimple", "_bindings.py")
            init_path = joinpath(path, "libsimple", "__init__.py")
            pyproject_path = joinpath(path, "pyproject.toml")
            @test isfile(bindings_path)
            @test isfile(init_path)
            @test isfile(pyproject_path)

            bindings = read(bindings_path, String)
            @test occursin("import ctypes", bindings)
            @test occursin("_LIBRARY_ENV_VAR = \"LIBSIMPLE_LIBRARY\"", bindings)
            @test occursin("class CTree_Float64(ctypes.Structure):\n    pass", bindings)
            @test occursin("class CVector_Float32(ctypes.Structure):", bindings)
            @test occursin("(\"length\", ctypes.c_int32)", bindings)
            @test occursin("(\"data\", ctypes.POINTER(ctypes.c_float))", bindings)
            # `from` is a Python keyword; it must be renamed to be reachable
            # via attribute access.
            @test occursin("(\"from_\", CVector_Float32)", bindings)
            @test occursin("CTree_Float64._fields_ = [", bindings)
            @test occursin("_lib.copyto_and_sum.argtypes = [CVectorPair_Float32]", bindings)
            @test occursin("_lib.copyto_and_sum.restype = ctypes.c_float", bindings)
            @test occursin("_lib.countsame.argtypes = [ctypes.POINTER(MyTwoVec), ctypes.c_int32]",
                           bindings)

            init = read(init_path, String)
            @test occursin("from ._bindings import (", init)
            @test occursin("copyto_and_sum", init)
            @test occursin("CTree_Float64", init)

            pyproject = read(pyproject_path, String)
            @test occursin("[build-system]", pyproject)
            @test occursin("name = \"libsimple\"", pyproject)

            golden = read(joinpath(@__DIR__, "expected_libsimple_bindings.py"), String)
            @test bindings == golden

            python3 = Sys.which("python3")
            if python3 === nothing
                # CI must exercise the Python wrapper; locally we allow skipping
                # so contributors without python3 can still run the suite.
                haskey(ENV, "CI") && error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            else
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr=devnull, stdout=devnull); wait=true))
            end
        end

        @testset "PythonTarget show" begin
            t = PythonTarget("/tmp/foo", "libsimple", "libsimple")
            @test sprint(show, t) ==
                  "PythonTarget(\"/tmp/foo\", \"libsimple\", \"libsimple\")"
        end

        @testset "unsupported primitive" begin
            typedict = Dict{Int, String}()
            typeinfo = OrderedDict{Int, TypeDesc}(
                1 => PrimitiveTypeDesc("NotARealType", false, 32, 4, 4),
            )
            @test_throws "unsupported primitive type: 'NotARealType'" JuliaLibWrapping.mangle_python!(typedict, 1, typeinfo)
        end
    end

    @testset "Aqua" begin
        Aqua.test_all(JuliaLibWrapping)
    end

    @testset "ExplicitImports" begin
        # JSON.parsefile and JSON.parse are the canonical JSON.jl entry points
        # but JSON.jl pre-dates the `public` keyword and never marked them
        # public. Disable the bundled all-qualified-accesses-are-public check
        # and re-run it with those names ignored.
        test_explicit_imports(JuliaLibWrapping; all_qualified_accesses_are_public=false)
        test_all_qualified_accesses_are_public(JuliaLibWrapping; ignore=(:parsefile, :parse))
    end
end
