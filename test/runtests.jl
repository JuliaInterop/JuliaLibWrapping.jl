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

            # Implements issue #12: CVector{primitive} structs gain numpy
            # conversion helpers; CVector{struct} does not.
            @test occursin("import numpy as np", bindings)
            @test occursin("def from_numpy(cls, arr):", bindings)
            @test occursin("def as_numpy(self):", bindings)
            @test occursin("expected_dtype = np.dtype(\"float32\")", bindings)
            @test occursin("ctypes.POINTER(ctypes.c_float)", bindings)
            # The CVector_CTree_Float64 class has a struct pointee, so the
            # recognizer must reject it (no helper emission). There is only
            # one `from_numpy` definition in the file.
            @test count(s -> occursin("def from_numpy", s), split(bindings, '\n')) == 1

            init = read(init_path, String)
            @test occursin("from ._bindings import (", init)
            @test occursin("copyto_and_sum", init)
            @test occursin("CTree_Float64", init)

            pyproject = read(pyproject_path, String)
            @test occursin("[build-system]", pyproject)
            @test occursin("name = \"libsimple\"", pyproject)
            # The bindings use numpy via the CVector helpers, so numpy must be
            # declared as a runtime dependency.
            @test occursin("dependencies = [\"numpy>=1.20\"]", pyproject)

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
    end

    @testset "cvector_struct_info" begin
        # Implements issue #12: structural recognition of the CVector shape.
        cvinfo = JuliaLibWrapping.cvector_struct_info
        # The fixture exercises both a matching CVector{Float32} and a
        # non-matching CVector{CTree{Float64}} (struct pointee).
        abi = read_abi_info("bindinginfo_libsimple.json")
        findtype(descs, name) = (k = collect(keys(descs));
                                 k[findfirst((id)->descs[id].name === name, k)])
        cv_f32 = abi.typeinfo[findtype(abi.typeinfo, "CVector{Float32}")]
        cv_tree = abi.typeinfo[findtype(abi.typeinfo, "CVector{CTree{Float64}}")]
        info = cvinfo(cv_f32, abi.typeinfo)
        @test info !== nothing
        @test info.pointee_name == "Float32"
        @test info.dtype == "float32"
        @test info.pointee_ctype == "ctypes.c_float"
        # Struct pointee → no match (no useful numpy mapping).
        @test cvinfo(cv_tree, abi.typeinfo) === nothing

        # Hand-built rejections: wrong name, wrong field count, wrong field
        # names, wrong length type (not integer), wrong pointee (struct).
        primint = PrimitiveTypeDesc("Int32", true, 32, 4, 4)
        primflt = PrimitiveTypeDesc("Float32", true, 32, 4, 4)
        primbool = PrimitiveTypeDesc("Bool", false, 8, 1, 1)
        ptr_to_flt = PointerDesc("Ptr{Float32}", 2)
        ti = OrderedDict{Int, TypeDesc}(
            1 => primint, 2 => primflt, 3 => ptr_to_flt,
            4 => StructDesc("CVector{Float32}", 16, 8, FieldDesc[
                FieldDesc("length", 1, 0),
                FieldDesc("data", 3, 8),
            ]),
            5 => StructDesc("NotACVector", 16, 8, FieldDesc[
                FieldDesc("length", 1, 0),
                FieldDesc("data", 3, 8),
            ]),
            6 => StructDesc("CVectorEmpty", 0, 0, FieldDesc[]),
            7 => StructDesc("CVectorBadNames", 16, 8, FieldDesc[
                FieldDesc("len", 1, 0),
                FieldDesc("data", 3, 8),
            ]),
            8 => StructDesc("CVectorBadLength", 16, 8, FieldDesc[
                FieldDesc("length", 2, 0),  # Float length — not integer
                FieldDesc("data", 3, 8),
            ]),
            9 => primbool,
            10 => StructDesc("CVectorBoolLength", 16, 8, FieldDesc[
                FieldDesc("length", 9, 0),  # Bool — in numpy_dtypes but not Int/UInt
                FieldDesc("data", 3, 8),
            ]),
        )
        @test cvinfo(ti[4], ti) !== nothing
        @test cvinfo(ti[5], ti) === nothing  # wrong name
        @test cvinfo(ti[6], ti) === nothing  # empty
        @test cvinfo(ti[7], ti) === nothing  # wrong field names
        @test cvinfo(ti[8], ti) === nothing  # non-integer length
        @test cvinfo(ti[10], ti) === nothing # Bool length rejected

        # Field order may be either way.
        flipped = StructDesc("CVector{Float32}", 16, 8, FieldDesc[
            FieldDesc("data", 3, 0),
            FieldDesc("length", 1, 8),
        ])
        @test cvinfo(flipped, ti) !== nothing
    end

    @testset "cmatrix_struct_info" begin
        # Implements issue #12: structural recognition of the CMatrix shape
        # (rows::Int32, cols::Int32, data::Ptr{T}) for primitive numeric T.
        cminfo = JuliaLibWrapping.cmatrix_struct_info
        abi = read_abi_info("bindinginfo_cmatrix.json")
        findtype(descs, name) = (k = collect(keys(descs));
                                 k[findfirst((id)->descs[id].name === name, k)])
        cm_f64 = abi.typeinfo[findtype(abi.typeinfo, "CMatrix{Float64}")]
        info = cminfo(cm_f64, abi.typeinfo)
        @test info !== nothing
        @test info.pointee_name == "Float64"
        @test info.dtype == "float64"
        @test info.pointee_ctype == "ctypes.c_double"

        # Hand-built rejections.
        primint = PrimitiveTypeDesc("Int32", true, 32, 4, 4)
        primflt = PrimitiveTypeDesc("Float64", true, 64, 8, 8)
        ptr_to_flt = PointerDesc("Ptr{Float64}", 2)
        ti = OrderedDict{Int, TypeDesc}(
            1 => primint, 2 => primflt, 3 => ptr_to_flt,
            4 => StructDesc("CMatrix{Float64}", 16, 8, FieldDesc[
                FieldDesc("rows", 1, 0),
                FieldDesc("cols", 1, 4),
                FieldDesc("data", 3, 8),
            ]),
            5 => StructDesc("NotACMatrix", 16, 8, FieldDesc[
                FieldDesc("rows", 1, 0),
                FieldDesc("cols", 1, 4),
                FieldDesc("data", 3, 8),
            ]),
            6 => StructDesc("CMatrixOnlyTwoFields", 12, 8, FieldDesc[
                FieldDesc("rows", 1, 0),
                FieldDesc("data", 3, 8),
            ]),
            7 => StructDesc("CMatrixBadNames", 16, 8, FieldDesc[
                FieldDesc("nrows", 1, 0),
                FieldDesc("ncols", 1, 4),
                FieldDesc("data", 3, 8),
            ]),
            8 => StructDesc("CMatrixFloatRows", 16, 8, FieldDesc[
                FieldDesc("rows", 2, 0),  # Float64 — not integer
                FieldDesc("cols", 1, 4),
                FieldDesc("data", 3, 8),
            ]),
        )
        @test cminfo(ti[4], ti) !== nothing
        @test cminfo(ti[5], ti) === nothing  # wrong name prefix
        @test cminfo(ti[6], ti) === nothing  # missing cols
        @test cminfo(ti[7], ti) === nothing  # wrong field names
        @test cminfo(ti[8], ti) === nothing  # non-integer rows

        # Field order is irrelevant — recognizer matches by name.
        scrambled = StructDesc("CMatrix{Float64}", 16, 8, FieldDesc[
            FieldDesc("data", 3, 0),
            FieldDesc("cols", 1, 8),
            FieldDesc("rows", 1, 12),
        ])
        @test cminfo(scrambled, ti) !== nothing
    end

    @testset "cstring_struct_info" begin
        # Implements issue #12: structural recognition of the CString shape
        # (length::Integer, data::Ptr{UInt8}).
        csinfo = JuliaLibWrapping.cstring_struct_info
        abi = read_abi_info("bindinginfo_cstring.json")
        findtype(descs, name) = (k = collect(keys(descs));
                                 k[findfirst((id)->descs[id].name === name, k)])
        cs = abi.typeinfo[findtype(abi.typeinfo, "CString")]
        @test csinfo(cs, abi.typeinfo) === true

        # Hand-built rejections.
        primint = PrimitiveTypeDesc("Int32", true, 32, 4, 4)
        primu8 = PrimitiveTypeDesc("UInt8", false, 8, 1, 1)
        primu16 = PrimitiveTypeDesc("UInt16", false, 16, 2, 2)
        ptr_to_u8 = PointerDesc("Ptr{UInt8}", 2)
        ptr_to_u16 = PointerDesc("Ptr{UInt16}", 3)
        ti = OrderedDict{Int, TypeDesc}(
            1 => primint, 2 => primu8, 3 => primu16,
            4 => ptr_to_u8, 5 => ptr_to_u16,
            6 => StructDesc("CString", 16, 8, FieldDesc[
                FieldDesc("length", 1, 0),
                FieldDesc("data", 4, 8),
            ]),
            7 => StructDesc("NotACString", 16, 8, FieldDesc[
                FieldDesc("length", 1, 0),
                FieldDesc("data", 4, 8),
            ]),
            8 => StructDesc("CStringU16", 16, 8, FieldDesc[
                FieldDesc("length", 1, 0),
                FieldDesc("data", 5, 8),  # Ptr{UInt16} — not UInt8
            ]),
            9 => StructDesc("CStringBadNames", 16, 8, FieldDesc[
                FieldDesc("size", 1, 0),
                FieldDesc("data", 4, 8),
            ]),
        )
        @test csinfo(ti[6], ti) === true
        @test csinfo(ti[7], ti) === false  # wrong name prefix
        @test csinfo(ti[8], ti) === false  # non-UInt8 pointee
        @test csinfo(ti[9], ti) === false  # wrong field names

        # Field order may be either way.
        flipped = StructDesc("CString", 16, 8, FieldDesc[
            FieldDesc("data", 4, 0),
            FieldDesc("length", 1, 8),
        ])
        @test csinfo(flipped, ti) === true
    end

    @testset "CString vocabulary" begin
        # Implements issue #12: CString recognition + str/bytes round-trip
        # in the Python emitter. No numpy dependency triggered.
        abi = read_abi_info("bindinginfo_cstring.json")
        mktempdir() do path
            dest = PythonTarget(path, "cstring_demo", "libcstring")
            write_wrapper(dest, abi)

            bindings_path = joinpath(path, "cstring_demo", "_bindings.py")
            bindings = read(bindings_path, String)

            # No numpy: CString helpers use only `ctypes`.
            @test !occursin("import numpy", bindings)
            pyproject = read(joinpath(path, "pyproject.toml"), String)
            @test !occursin("numpy", pyproject)

            # Struct + helpers.
            @test occursin("class CString(ctypes.Structure):", bindings)
            @test occursin("(\"length\", ctypes.c_int32)", bindings)
            @test occursin("(\"data\", ctypes.POINTER(ctypes.c_uint8))", bindings)
            @test occursin("def from_str(cls, s):", bindings)
            @test occursin("def from_bytes(cls, b):", bindings)
            @test occursin("def as_bytes(self):", bindings)
            @test occursin("def as_str(self):", bindings)
            @test occursin("s.encode(\"utf-8\")", bindings)
            @test occursin("ctypes.string_at(self.data, self.length)", bindings)
            @test occursin(".decode(\"utf-8\")", bindings)

            # Round-trip-direction entrypoints are emitted as bare bindings.
            @test occursin("_lib.greeting_length.argtypes = [CString]", bindings)
            @test occursin("_lib.greeting.restype = CString", bindings)

            golden = read(joinpath(@__DIR__, "expected_cstring_bindings.py"), String)
            @test bindings == golden

            python3 = Sys.which("python3")
            if python3 !== nothing
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr=devnull, stdout=devnull); wait=true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
        end
    end

    @testset "CMatrix vocabulary" begin
        # Implements issue #12: CMatrix{T} recognition + column-major numpy
        # helpers in the Python emitter.
        abi = read_abi_info("bindinginfo_cmatrix.json")
        mktempdir() do path
            dest = PythonTarget(path, "cmatrix_demo", "libcmatrix")
            write_wrapper(dest, abi)

            bindings_path = joinpath(path, "cmatrix_demo", "_bindings.py")
            bindings = read(bindings_path, String)

            # Numpy is imported and declared as a dep when CMatrix is present.
            @test occursin("import numpy as np", bindings)
            pyproject = read(joinpath(path, "pyproject.toml"), String)
            @test occursin("dependencies = [\"numpy>=1.20\"]", pyproject)

            # The struct class is emitted and decorated with helpers.
            @test occursin("class CMatrix_Float64(ctypes.Structure):", bindings)
            @test occursin("(\"rows\", ctypes.c_int32)", bindings)
            @test occursin("(\"cols\", ctypes.c_int32)", bindings)
            @test occursin("(\"data\", ctypes.POINTER(ctypes.c_double))", bindings)

            # from_numpy enforces column-major (Fortran) layout — silently
            # treating a C-order numpy array as column-major would transpose.
            @test occursin("def from_numpy(cls, arr):", bindings)
            @test occursin("if arr.ndim != 2:", bindings)
            @test occursin("if not arr.flags.f_contiguous:", bindings)
            @test occursin("expected_dtype = np.dtype(\"float64\")", bindings)
            @test occursin("rows=arr.shape[0], cols=arr.shape[1]", bindings)

            # as_numpy returns a view with column-major strides.
            @test occursin("def as_numpy(self):", bindings)
            @test occursin("np.ctypeslib.as_array(self.data, shape=(self.cols, self.rows)).T",
                           bindings)

            # Golden-file comparison.
            golden = read(joinpath(@__DIR__, "expected_cmatrix_bindings.py"), String)
            @test bindings == golden

            python3 = Sys.which("python3")
            if python3 !== nothing
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr=devnull, stdout=devnull); wait=true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
        end
    end

    @testset "raw primitive pointer docstring" begin
        # Implements issue #14: bare `Ptr{<primitive>}` arguments get a
        # docstring on the Python wrapper warning about layout/ownership,
        # and `write_wrapper` emits a single @info during codegen.
        abi = read_abi_info("bindinginfo_rawptr.json")

        # Helper recognizes the raw-primitive-pointer argument.
        method = only(abi.entrypoints)
        @test JuliaLibWrapping.raw_primitive_pointer_args(method, abi.typeinfo) == [1]

        mktempdir() do path
            dest = PythonTarget(path, "rawptr_demo", "librawptr")
            bindings = @test_logs (:info,) match_mode=:any begin
                write_wrapper(dest, abi)
                read(joinpath(path, "rawptr_demo", "_bindings.py"), String)
            end

            # Raw pointer is still rendered as ctypes.POINTER — no numpy.
            @test !occursin("import numpy", bindings)
            pyproject = read(joinpath(path, "pyproject.toml"), String)
            @test !occursin("numpy", pyproject)

            # Docstring lands on the wrapper, names the offending arg, and
            # documents the column-major contract.
            @test occursin("def sum_doubles(data, n):", bindings)
            @test occursin("Raw pointer arguments — caller owns layout and lifetime.",
                           bindings)
            @test occursin("`data` is a raw pointer to Float64", bindings)
            @test occursin("column-major (Fortran order)", bindings)
            @test occursin("`CVector{T}` /\n    `CMatrix{T}`", bindings)

            golden = read(joinpath(@__DIR__, "expected_rawptr_bindings.py"), String)
            @test bindings == golden

            python3 = Sys.which("python3")
            if python3 !== nothing
                bindings_path = joinpath(path, "rawptr_demo", "_bindings.py")
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr=devnull, stdout=devnull); wait=true))
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
        # Implements issue #15: in-band status struct + Python raise-on-error.
        abi_info = read_abi_info("bindinginfo_jlwstatus.json")
        mktempdir() do path
            dest = PythonTarget(path, "demo", "libdemo")
            write_wrapper(dest, abi_info)

            bindings = read(joinpath(path, "demo", "_bindings.py"), String)
            init = read(joinpath(path, "demo", "__init__.py"), String)

            # The JLWError exception class is defined once.
            @test occursin("class JLWError(RuntimeError):", bindings)
            @test count(==("class JLWError(RuntimeError):"),
                        split(bindings, '\n')) == 1

            # JLWStatus.message is emitted as a ctypes byte array, not as a
            # 256-field Structure (this also implicitly tests the new
            # tuple-struct handling).
            @test occursin("(\"message\", (ctypes.c_uint8 * 256))", bindings)
            @test !occursin("NTuple_256_UInt8", bindings)

            # Direct JLWStatus return: check uses `_result.code`.
            @test occursin(
                "def do_thing(x):\n    _result = _lib.do_thing(x)\n    if _result.code != 0:",
                bindings)
            # Embedded JLWStatus field: check uses `_result.status.code`.
            @test occursin(
                "def compute(x):\n    _result = _lib.compute(x)\n    if _result.status.code != 0:",
                bindings)
            @test occursin("raise JLWError(_result.status.code, _msg)", bindings)
            # Non-JLWStatus entrypoint stays a bare mechanical binding.
            @test occursin(
                "def plain_add(a, b):\n    return _lib.plain_add(a, b)",
                bindings)

            # JLWError is re-exported from the package.
            @test occursin("    JLWError,", init)
            @test occursin("\"JLWError\"", init)

            python3 = Sys.which("python3")
            if python3 !== nothing
                bindings_path = joinpath(path, "demo", "_bindings.py")
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr=devnull, stdout=devnull); wait=true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
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
