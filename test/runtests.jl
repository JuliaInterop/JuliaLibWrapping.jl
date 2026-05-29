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
        @test tdesc.fields[1].name == "dims"
        dims_desc = typeinfo[tdesc.fields[1].type]
        @test dims_desc isa ArrayDesc
        @test dims_desc.count == 1
        @test typeinfo[dims_desc.element_type].name == "Int32"
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
            @test occursin("    int32_t dims[1];", content)
            @test occursin("    float* data;", content)
            @test occursin("CVector_Float32 from;", content)
            @test occursin("CVector_Float32 to;", content)
            @test occursin("float copyto_and_sum(CVectorPair_Float32 fromto);", content)
            @test occursin("int32_t countsame(MyTwoVec* list, int32_t n);", content)
            @test occursin("int32_t unnamed_arguments(int32_t, int32_t);", content)
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
            @test occursin("class CVector_Float32(ctypes.Structure):", bindings)
            @test occursin("(\"dims\", (ctypes.c_int32 * 1))", bindings)
            @test occursin("(\"data\", ctypes.POINTER(ctypes.c_float))", bindings)
            # `from` is a Python keyword; it must be renamed to be reachable
            # via attribute access.
            @test occursin("(\"from_\", CVector_Float32)", bindings)
            @test occursin("CTree_Float64._fields_ = [", bindings)
            @test occursin("_lib.copyto_and_sum.argtypes = [CVectorPair_Float32]", bindings)
            @test occursin("_lib.copyto_and_sum.restype = ctypes.c_float", bindings)
            @test occursin("_lib.countsame.argtypes = [ctypes.POINTER(MyTwoVec), ctypes.c_int32]",
                           bindings)

            # Implements issue #12: CArray{primitive,N} structs gain numpy
            # conversion helpers; CArray{struct,N} does not.
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
            @test occursin("from ._facade import *", init)
            @test occursin("from ._facade import __all__", init)

            # `_facade.py` is the never-overwritten author-editable surface;
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
            # The bindings use numpy via the CArray helpers, so numpy must be
            # declared as a runtime dependency.
            @test occursin("dependencies = [\"numpy>=1.20\"]", pyproject)

            golden = read(joinpath(@__DIR__, "expected_libsimple_lowlevel.py"), String)
            @test bindings == golden

            python3 = Sys.which("python3")
            if python3 === nothing
                # CI must exercise the Python wrapper; locally we allow skipping
                # so contributors without python3 can still run the suite.
                haskey(ENV, "CI") && error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            else
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr=devnull, stdout=devnull); wait=true))
                cmd_f = `$python3 -c "import ast; ast.parse(open('$facade_path').read())"`
                @test success(run(pipeline(cmd_f; stderr=devnull, stdout=devnull); wait=true))
            end
        end

        @testset "PythonTarget show" begin
            t = PythonTarget("/tmp/foo", "libsimple", "libsimple")
            @test sprint(show, t) ==
                  "PythonTarget(\"/tmp/foo\", \"libsimple\", \"libsimple\")"
            tb = PythonTarget("/tmp/foo", "libsimple", "libsimple";
                              bundle_subdir = "bundle")
            @test sprint(show, tb) ==
                  "PythonTarget(\"/tmp/foo\", \"libsimple\", \"libsimple\"; bundle_subdir = \"bundle\")"
            @test tb.bundle_subdir == "bundle"
        end

        @testset "bundle-aware output (issue #17)" begin
            abi_info = read_abi_info("bindinginfo_libsimple.json")
            mktempdir() do path
                dest = PythonTarget(path, "libsimple", "libsimple";
                                    bundle_subdir = "bundle")
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
                    @test success(run(pipeline(cmd; stderr=devnull, stdout=devnull); wait=true))
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

        @testset "sanitize_python_argname" begin
            sanitize = JuliaLibWrapping.sanitize_python_argname
            # Heterogeneous tuples (issue #21): juliac emits Tuple{Int32,Float64}
            # as a struct with fields named "1", "2" — leading digits are illegal
            # Python identifiers, so the emitter must prefix an underscore.
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
        # Structural recognition of the CArray{T,N} shape: a struct named
        # CArray/CVector/CMatrix (since `CVector = CArray{_,1}` and
        # `CMatrix = CArray{_,2}` may print under either name) with `dims`
        # (NTuple{N,Int32} → ArrayDesc) and `data` (Ptr{T}) fields, for
        # primitive numeric T recognized by `numpy_dtypes`.
        cainfo = JuliaLibWrapping.carray_struct_info

        # libsimple exercises CVector{Float32} (N=1, primitive pointee, match)
        # and CVector{CTree{Float64}} (struct pointee, no match).
        abi = read_abi_info("bindinginfo_libsimple.json")
        findtype(descs, name) = (k = collect(keys(descs));
                                 k[findfirst((id)->descs[id].name === name, k)])
        cv_f32 = abi.typeinfo[findtype(abi.typeinfo, "CVector{Float32}")]
        cv_tree = abi.typeinfo[findtype(abi.typeinfo, "CVector{CTree{Float64}}")]
        info = cainfo(cv_f32, abi.typeinfo)
        @test info !== nothing
        @test info.pointee_name == "Float32"
        @test info.dtype == "float32"
        @test info.pointee_ctype == "ctypes.c_float"
        @test info.ndim == 1
        # Struct pointee → no match (no useful numpy mapping).
        @test cainfo(cv_tree, abi.typeinfo) === nothing

        # cmatrix fixture exercises the N=2 case under the CMatrix alias name.
        abi_cm = read_abi_info("bindinginfo_cmatrix.json")
        cm_f64 = abi_cm.typeinfo[findtype(abi_cm.typeinfo, "CMatrix{Float64}")]
        info2 = cainfo(cm_f64, abi_cm.typeinfo)
        @test info2 !== nothing
        @test info2.pointee_name == "Float64"
        @test info2.ndim == 2

        # carray3 fixture exercises N=3 under the CArray name directly.
        abi_c3 = read_abi_info("bindinginfo_carray3.json")
        ca_f64_3 = abi_c3.typeinfo[findtype(abi_c3.typeinfo, "CArray{Float64, 3}")]
        info3 = cainfo(ca_f64_3, abi_c3.typeinfo)
        @test info3 !== nothing
        @test info3.pointee_name == "Float64"
        @test info3.ndim == 3

        # Hand-built rejections: wrong name, wrong field names, non-integer
        # dims element, non-numpy pointee, dims-as-primitive (not array).
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
            6 => StructDesc("CVector{Float32}", 16, 8, FieldDesc[
                FieldDesc("dims", 4, 0),
                FieldDesc("data", 3, 8),
            ]),
            7 => primbool,
            8 => arr_bool_1,
            9 => StructDesc("NotACArray", 16, 8, FieldDesc[
                FieldDesc("dims", 4, 0),
                FieldDesc("data", 3, 8),
            ]),
            10 => StructDesc("CVectorEmpty", 0, 0, FieldDesc[]),
            11 => StructDesc("CVectorBadNames", 16, 8, FieldDesc[
                FieldDesc("len", 4, 0),
                FieldDesc("data", 3, 8),
            ]),
            12 => StructDesc("CVectorFloatDims", 16, 8, FieldDesc[
                FieldDesc("dims", 5, 0),  # NTuple{1,Float32} — not Int*
                FieldDesc("data", 3, 8),
            ]),
            13 => StructDesc("CVectorPrimDims", 16, 8, FieldDesc[
                FieldDesc("dims", 1, 0),  # primitive Int32, not ArrayDesc
                FieldDesc("data", 3, 8),
            ]),
            14 => StructDesc("CVectorBoolDims", 16, 8, FieldDesc[
                FieldDesc("dims", 8, 0),  # Bool element — in numpy_dtypes but not Int/UInt
                FieldDesc("data", 3, 8),
            ]),
        )
        @test cainfo(ti[6], ti) !== nothing
        @test cainfo(ti[9], ti) === nothing   # wrong name prefix
        @test cainfo(ti[10], ti) === nothing  # empty
        @test cainfo(ti[11], ti) === nothing  # wrong field names
        @test cainfo(ti[12], ti) === nothing  # non-integer dims element
        @test cainfo(ti[13], ti) === nothing  # dims is primitive, not ArrayDesc
        @test cainfo(ti[14], ti) === nothing  # Bool dims element rejected

        # Field order may be either way.
        flipped = StructDesc("CVector{Float32}", 16, 8, FieldDesc[
            FieldDesc("data", 3, 0),
            FieldDesc("dims", 4, 8),
        ])
        @test cainfo(flipped, ti) !== nothing
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

            bindings_path = joinpath(path, "cstring_demo", "_lowlevel.py")
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

            golden = read(joinpath(@__DIR__, "expected_cstring_lowlevel.py"), String)
            @test bindings == golden

            # Façade auto-wrap: CString args/returns become str in/out.
            facade = read(joinpath(path, "cstring_demo", "_facade.py"), String)
            @test occursin("def greeting_length(s):\n    _s = CString.from_str(s)\n" *
                           "    return _lowlevel.greeting_length(_s)", facade)
            @test occursin("def greeting():\n    _result = _lowlevel.greeting()\n" *
                           "    return _result.as_str()", facade)
            golden_facade = read(joinpath(@__DIR__, "expected_cstring_facade.py"), String)
            @test facade == golden_facade

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
        # CMatrix{T} = CArray{T,2}: recognition + column-major numpy helpers
        # in the Python emitter.
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

            # The struct class is emitted with the new `dims` array field and
            # decorated with helpers.
            @test occursin("class CMatrix_Float64(ctypes.Structure):", bindings)
            @test occursin("(\"dims\", (ctypes.c_int32 * 2))", bindings)
            @test occursin("(\"data\", ctypes.POINTER(ctypes.c_double))", bindings)

            # from_numpy enforces column-major (Fortran) layout — silently
            # treating a C-order numpy array as column-major would transpose.
            @test occursin("def from_numpy(cls, arr):", bindings)
            @test occursin("if arr.ndim != 2:", bindings)
            @test occursin("if not arr.flags.f_contiguous:", bindings)
            @test occursin("expected_dtype = np.dtype(\"float64\")", bindings)
            @test occursin("dims=(ctypes.c_int32 * 2)(*arr.shape)", bindings)

            # as_numpy returns a view with column-major strides.
            @test occursin("def as_numpy(self):", bindings)
            @test occursin("np.ctypeslib.as_array(self.data, shape=tuple(self.dims)[::-1]).T",
                           bindings)

            # Golden-file comparison.
            golden = read(joinpath(@__DIR__, "expected_cmatrix_lowlevel.py"), String)
            @test bindings == golden

            # Façade auto-wrap: CMatrix arg becomes numpy in.
            facade = read(joinpath(path, "cmatrix_demo", "_facade.py"), String)
            @test occursin("import numpy as np", facade)
            @test occursin("def trace_cmatrix(m):\n    _m = CMatrix_Float64.from_numpy(m)\n" *
                           "    return _lowlevel.trace_cmatrix(_m)", facade)
            golden_facade = read(joinpath(@__DIR__, "expected_cmatrix_facade.py"), String)
            @test facade == golden_facade

            python3 = Sys.which("python3")
            if python3 !== nothing
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr=devnull, stdout=devnull); wait=true))
            elseif haskey(ENV, "CI")
                error("python3 not found on PATH; required on CI to validate the emitted wrapper")
            end
        end
    end

    @testset "CArray{T,3} vocabulary" begin
        # Locks in 3-D coverage: the rank-agnostic CArray recognizer should
        # accept `CArray{Float64,3}` and the emitter should produce the same
        # helper shape as for N=1,2 but with ndim=3 dispatches.
        abi = read_abi_info("bindinginfo_carray3.json")
        mktempdir() do path
            dest = PythonTarget(path, "carray3_demo", "libcarray3")
            write_wrapper(dest, abi)

            bindings_path = joinpath(path, "carray3_demo", "_lowlevel.py")
            bindings = read(bindings_path, String)

            @test occursin("class CArray_Float64_3(ctypes.Structure):", bindings)
            @test occursin("(\"dims\", (ctypes.c_int32 * 3))", bindings)
            @test occursin("if arr.ndim != 3:", bindings)
            @test occursin("if not arr.flags.f_contiguous:", bindings)
            @test occursin("dims=(ctypes.c_int32 * 3)(*arr.shape)", bindings)
            @test occursin("np.ctypeslib.as_array(self.data, shape=tuple(self.dims)[::-1]).T",
                           bindings)

            golden = read(joinpath(@__DIR__, "expected_carray3_lowlevel.py"), String)
            @test bindings == golden

            facade = read(joinpath(path, "carray3_demo", "_facade.py"), String)
            @test occursin("def sum3d(a):\n    _a = CArray_Float64_3.from_numpy(a)\n" *
                           "    return _lowlevel.sum3d(_a)", facade)
            golden_facade = read(joinpath(@__DIR__, "expected_carray3_facade.py"), String)
            @test facade == golden_facade

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
                read(joinpath(path, "rawptr_demo", "_lowlevel.py"), String)
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
            @test occursin("`CArray{T,N}`", bindings)

            golden = read(joinpath(@__DIR__, "expected_rawptr_lowlevel.py"), String)
            @test bindings == golden

            # Façade: raw-pointer arg is not auto-wrappable; the function
            # falls back to a mechanical re-export tagged with a TODO that
            # names the offending arg and its type.
            facade = read(joinpath(path, "rawptr_demo", "_facade.py"), String)
            @test occursin("from ._lowlevel import sum_doubles  # TODO: hand-wrap — " *
                           "`data`: argument has raw pointer type `Ptr{Float64}`",
                           facade)
            @test !occursin("def sum_doubles(", facade)
            golden_facade = read(joinpath(@__DIR__, "expected_rawptr_facade.py"), String)
            @test facade == golden_facade

            python3 = Sys.which("python3")
            if python3 !== nothing
                bindings_path = joinpath(path, "rawptr_demo", "_lowlevel.py")
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

            bindings = read(joinpath(path, "demo", "_lowlevel.py"), String)
            facade = read(joinpath(path, "demo", "_facade.py"), String)
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

            # JLWError is re-exported from the package via the façade.
            @test occursin("from ._facade import *", init)
            @test occursin("    JLWError,", facade)
            @test occursin("\"JLWError\"", facade)

            # Façade auto-wrap policy for the three flavors:
            #  - direct JLWStatus return → auto-wrap that discards the
            #    status struct (lowlevel already raises);
            #  - embedded JLWStatus in a compound struct → mechanical
            #    TODO (we don't know how to shape the other fields);
            #  - plain primitive-in/primitive-out → passthrough re-export
            #    with no TODO noise.
            @test occursin("def do_thing(x):\n    _lowlevel.do_thing(x)", facade)
            @test occursin("from ._lowlevel import compute  # TODO: hand-wrap " *
                           "— returns struct `ResultStruct` with embedded JLWStatus",
                           facade)
            @test occursin("from ._lowlevel import plain_add\n", facade)
            @test !occursin("plain_add  # TODO", facade)
            golden_facade = read(joinpath(@__DIR__, "expected_jlwstatus_facade.py"), String)
            @test facade == golden_facade

            python3 = Sys.which("python3")
            if python3 !== nothing
                bindings_path = joinpath(path, "demo", "_lowlevel.py")
                cmd = `$python3 -c "import ast; ast.parse(open('$bindings_path').read())"`
                @test success(run(pipeline(cmd; stderr=devnull, stdout=devnull); wait=true))
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
        test_explicit_imports(JuliaLibWrapping; all_qualified_accesses_are_public=false)
        test_all_qualified_accesses_are_public(JuliaLibWrapping; ignore=(:parsefile, :parse))
    end
end
