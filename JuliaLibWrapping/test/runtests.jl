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
        findtype(descs, name) = (k = collect(keys(descs)); k[findfirst((id) -> descs[id].name === name, k)])

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
        @test length(tdesc.fields) == 3
        @test tdesc.fields[1].name == "dims"
        dims_desc = typeinfo[tdesc.fields[1].type]
        @test dims_desc isa ArrayDesc
        @test dims_desc.count == 1
        @test typeinfo[dims_desc.element_type].name == "Int32"
        @test iszero(tdesc.fields[1].offset)
        @test tdesc.fields[2].name == "data"
        @test typeinfo[tdesc.fields[2].type].name == "Ptr{Float32}"
        @test tdesc.fields[2].offset == 8
        @test tdesc.fields[3].name == "owned"
        @test typeinfo[tdesc.fields[3].type].name == "Int32"
        @test tdesc.fields[3].offset == 16
        @test tdesc.size == 24
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
            @test occursin("typedef struct CVector_Float32 {", content)
            @test occursin("    int32_t dims[1];", content)
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
            # The CVector_CTree_Float64 class has a struct pointee, so the
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
        # Structural recognition of the CArray{T,N} shape: a struct named
        # CArray/CVector/CMatrix (since `CVector = CArray{_,1}` and
        # `CMatrix = CArray{_,2}` may print under either name) with `dims`
        # (NTuple{N,Int32} → ArrayDesc), `data` (Ptr{T}), and `owned`
        # (Int32 explicit-ownership discriminant) fields, for primitive
        # numeric T recognized by `numpy_dtypes`.
        cainfo(desc, typeinfo) = JuliaLibWrapping.carray_struct_info(desc, typeinfo, JuliaLibWrapping.numpy_dtypes, JuliaLibWrapping.pytypes)

        # libsimple exercises CVector{Float32} (N=1, primitive pointee, match)
        # and CVector{CTree{Float64}} (struct pointee, no match).
        abi = read_abi_info("bindinginfo_libsimple.json")
        findtype(descs, name) = (
            k = collect(keys(descs));
            k[findfirst((id) -> descs[id].name === name, k)]
        )
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
        # dims element, non-numpy pointee, dims-as-primitive (not array),
        # missing owned, owned present but wrong type.
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
                "CVector{Float32}", 24, 8, FieldDesc[
                    FieldDesc("dims", 4, 0),
                    FieldDesc("data", 3, 8),
                    FieldDesc("owned", 1, 16),
                ]
            ),
            7 => primbool,
            8 => arr_bool_1,
            9 => StructDesc(
                "NotACArray", 24, 8, FieldDesc[
                    FieldDesc("dims", 4, 0),
                    FieldDesc("data", 3, 8),
                    FieldDesc("owned", 1, 16),
                ]
            ),
            10 => StructDesc("CVectorEmpty", 0, 0, FieldDesc[]),
            11 => StructDesc(
                "CVectorBadNames", 24, 8, FieldDesc[
                    FieldDesc("len", 4, 0),
                    FieldDesc("data", 3, 8),
                    FieldDesc("owned", 1, 16),
                ]
            ),
            12 => StructDesc(
                "CVectorFloatDims", 24, 8, FieldDesc[
                    FieldDesc("dims", 5, 0),  # NTuple{1,Float32} — not Int*
                    FieldDesc("data", 3, 8),
                    FieldDesc("owned", 1, 16),
                ]
            ),
            13 => StructDesc(
                "CVectorPrimDims", 24, 8, FieldDesc[
                    FieldDesc("dims", 1, 0),  # primitive Int32, not ArrayDesc
                    FieldDesc("data", 3, 8),
                    FieldDesc("owned", 1, 16),
                ]
            ),
            14 => StructDesc(
                "CVectorBoolDims", 24, 8, FieldDesc[
                    FieldDesc("dims", 8, 0),  # Bool element — in numpy_dtypes but not Int/UInt
                    FieldDesc("data", 3, 8),
                    FieldDesc("owned", 1, 16),
                ]
            ),
            15 => StructDesc(
                "CVectorNoOwned", 16, 8, FieldDesc[
                    FieldDesc("dims", 4, 0),
                    FieldDesc("data", 3, 8),
                ]
            ),
            16 => StructDesc(
                "CVectorOwnedWrongType", 24, 8, FieldDesc[
                    FieldDesc("dims", 4, 0),
                    FieldDesc("data", 3, 8),
                    FieldDesc("owned", 2, 16),  # Float32, not Int32
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
        @test cainfo(ti[15], ti) === nothing  # owned missing entirely # noidiom
        @test cainfo(ti[16], ti) === nothing  # owned present but not Int32 # noidiom

        # Field order may be any permutation.
        flipped = StructDesc(
            "CVector{Float32}", 24, 8, FieldDesc[
                FieldDesc("owned", 1, 16),
                FieldDesc("data", 3, 8),
                FieldDesc("dims", 4, 0),
            ]
        )
        @test cainfo(flipped, ti) !== nothing  # noidiom
    end

    @testset "cstring_struct_info" begin
        # Recognize the CString layout structurally.
        csinfo = JuliaLibWrapping.cstring_struct_info
        abi = read_abi_info("bindinginfo_cstring.json")
        findtype(descs, name) = (
            k = collect(keys(descs));
            k[findfirst((id) -> descs[id].name === name, k)]
        )
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
            6 => StructDesc(
                "CString", 16, 8, FieldDesc[
                    FieldDesc("length", 1, 0),
                    FieldDesc("data", 4, 8),
                ]
            ),
            7 => StructDesc(
                "NotACString", 16, 8, FieldDesc[
                    FieldDesc("length", 1, 0),
                    FieldDesc("data", 4, 8),
                ]
            ),
            8 => StructDesc(
                "CStringU16", 16, 8, FieldDesc[
                    FieldDesc("length", 1, 0),
                    FieldDesc("data", 5, 8),  # Ptr{UInt16} — not UInt8
                ]
            ),
            9 => StructDesc(
                "CStringBadNames", 16, 8, FieldDesc[
                    FieldDesc("size", 1, 0),
                    FieldDesc("data", 4, 8),
                ]
            ),
        )
        @test csinfo(ti[6], ti) === true
        @test csinfo(ti[7], ti) === false  # wrong name prefix
        @test csinfo(ti[8], ti) === false  # non-UInt8 pointee
        @test csinfo(ti[9], ti) === false  # wrong field names

        # Field order may be either way.
        flipped = StructDesc(
            "CString", 16, 8, FieldDesc[
                FieldDesc("data", 4, 0),
                FieldDesc("length", 1, 8),
            ]
        )
        @test csinfo(flipped, ti) === true
    end

    @testset "cstrarray_struct_info" begin
        # Structural recognition of the CStrArray shape: a struct named
        # CStrArray with `length` (signed primitive integer), `data`
        # (Ptr{CString} — the length-prefixed CString struct, recognized
        # via `cstring_struct_info` applied to the pointee), and `owned`
        # (an Int32 explicit-ownership discriminant) fields. The name is
        # only the first gate; the pointee's own shape and the `owned`
        # field's presence/type must also match.
        csainfo = JuliaLibWrapping.cstrarray_struct_info
        abi = read_abi_info("bindinginfo_cstrarray.json")
        findtype(descs, name) = (
            k = collect(keys(descs));
            k[findfirst((id) -> descs[id].name === name, k)]
        )
        csa = abi.typeinfo[findtype(abi.typeinfo, "CStrArray")]
        @test csainfo(csa, abi.typeinfo) === true

        # Hand-built rejections.
        primi32 = PrimitiveTypeDesc("Int32", true, 32, 4, 4)
        primi64 = PrimitiveTypeDesc("Int64", true, 64, 8, 8)
        primu64 = PrimitiveTypeDesc("UInt64", false, 64, 8, 8)
        primu8 = PrimitiveTypeDesc("UInt8", false, 8, 1, 1)
        primu16 = PrimitiveTypeDesc("UInt16", false, 16, 2, 2)
        ptr_to_u8 = PointerDesc("Ptr{UInt8}", 4)
        ptr_to_u16 = PointerDesc("Ptr{UInt16}", 5)
        cstring_ok = StructDesc(
            "CString", 16, 8, FieldDesc[
                FieldDesc("length", 1, 0),
                FieldDesc("data", 6, 8),
            ]
        )
        cstring_bad = StructDesc(
            # `data` points to UInt16, not UInt8 — `cstring_struct_info`
            # rejects this, so it must not be accepted as a CString pointee.
            "NotCString", 16, 8, FieldDesc[
                FieldDesc("length", 1, 0),
                FieldDesc("data", 7, 8),
            ]
        )
        ptr_to_cstring = PointerDesc("Ptr{CString}", 8)
        ptr_to_not_cstring = PointerDesc("Ptr{NotCString}", 9)
        ti = OrderedDict{Int, TypeDesc}(
            1 => primi32, 2 => primi64, 3 => primu64,
            4 => primu8, 5 => primu16,
            6 => ptr_to_u8, 7 => ptr_to_u16,
            8 => cstring_ok, 9 => cstring_bad,
            10 => ptr_to_cstring, 11 => ptr_to_not_cstring,
            12 => StructDesc(
                "CStrArray", 24, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("data", 10, 8),
                    FieldDesc("owned", 1, 16),
                ]
            ),
            13 => StructDesc(
                "NotACStrArray", 24, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("data", 10, 8),
                    FieldDesc("owned", 1, 16),
                ]
            ),
            14 => StructDesc(
                "CStrArrayBadPointee", 24, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("data", 11, 8),  # Ptr{NotCString} — pointee isn't CString-shaped
                    FieldDesc("owned", 1, 16),
                ]
            ),
            15 => StructDesc(
                "CStrArrayBadNames", 24, 8, FieldDesc[
                    FieldDesc("size", 2, 0),
                    FieldDesc("data", 10, 8),
                    FieldDesc("owned", 1, 16),
                ]
            ),
            16 => StructDesc(
                "CStrArrayUnsignedLen", 24, 8, FieldDesc[
                    FieldDesc("length", 3, 0),  # UInt64 — not signed
                    FieldDesc("data", 10, 8),
                    FieldDesc("owned", 1, 16),
                ]
            ),
            17 => StructDesc(
                "CStrArraySinglePtr", 24, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("data", 6, 8),  # Ptr{UInt8} — pointee isn't a struct at all
                    FieldDesc("owned", 1, 16),
                ]
            ),
            18 => StructDesc(
                "CStrArrayMissingOwned", 16, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("data", 10, 8),
                    # no `owned` field at all — otherwise identical to ti[12]
                ]
            ),
            19 => StructDesc(
                "CStrArrayOwnedWrongType", 24, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("data", 10, 8),
                    FieldDesc("owned", 2, 16),  # Int64, not Int32
                ]
            ),
        )
        @test csainfo(ti[12], ti) === true
        @test csainfo(ti[13], ti) === false  # wrong name prefix
        @test csainfo(ti[14], ti) === false  # data's pointee isn't CString-shaped
        @test csainfo(ti[15], ti) === false  # wrong field names
        @test csainfo(ti[16], ti) === false  # unsigned length
        @test csainfo(ti[17], ti) === false  # data isn't a pointer-to-struct at all
        @test csainfo(ti[18], ti) === false  # missing `owned` field entirely
        @test csainfo(ti[19], ti) === false  # `owned` present but not Int32

        # Field order may be any permutation.
        flipped = StructDesc(
            "CStrArray", 24, 8, FieldDesc[
                FieldDesc("owned", 1, 16),
                FieldDesc("data", 10, 0),
                FieldDesc("length", 2, 8),
            ]
        )
        @test csainfo(flipped, ti) === true
    end

    @testset "cdict_struct_info" begin
        # Structural recognition of the CDict{V} shape: a struct named CDict
        # with `length` (primitive integer), `keys` (Ptr{CString} — same
        # shape as CStrArray's `data`, recognized via `cstring_struct_info`
        # applied to the pointee), `values` (Ptr{<primitive in
        # pytypes>}), and `owned` (an Int32 explicit-ownership
        # discriminant) fields. The name is only the first gate; the full
        # 4-field shape and the keys pointee's own shape must also match.
        cdinfo(desc, typeinfo) = JuliaLibWrapping.cdict_struct_info(desc, typeinfo, JuliaLibWrapping.pytypes)
        abi = read_abi_info("bindinginfo_cdict.json")
        findtype(descs, name) = (
            k = collect(keys(descs));
            k[findfirst((id) -> descs[id].name === name, k)]
        )
        cd = abi.typeinfo[findtype(abi.typeinfo, "CDict{Float64}")]
        info = cdinfo(cd, abi.typeinfo)
        @test !isnothing(info)
        @test info.value_ctype == "ctypes.c_double"

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
            "CString", 16, 8, FieldDesc[
                FieldDesc("length", 1, 0),
                FieldDesc("data", 7, 8),
            ]
        )
        cstring_bad = StructDesc(
            # `data` points to UInt16, not UInt8 — `cstring_struct_info`
            # rejects this, so it must not be accepted as a CString pointee.
            "NotCString", 16, 8, FieldDesc[
                FieldDesc("length", 1, 0),
                FieldDesc("data", 8, 8),
            ]
        )
        ptr_to_cstring = PointerDesc("Ptr{CString}", 9)
        ptr_to_not_cstring = PointerDesc("Ptr{NotCString}", 10)
        ti = OrderedDict{Int, TypeDesc}(
            1 => primi32, 2 => primi64,
            3 => primu8, 4 => primu16, 5 => primf64,
            6 => primnotreal,
            7 => ptr_to_u8, 8 => ptr_to_u16,
            9 => cstring_ok, 10 => cstring_bad,
            11 => ptr_to_cstring, 12 => ptr_to_not_cstring,
            13 => ptr_to_f64, 14 => ptr_to_notreal,
            15 => StructDesc(
                "CDict{Float64}", 32, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 11, 8),
                    FieldDesc("values", 13, 16),
                    FieldDesc("owned", 1, 24),
                ]
            ),
            16 => StructDesc(
                "NotACDict", 32, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 11, 8),
                    FieldDesc("values", 13, 16),
                    FieldDesc("owned", 1, 24),
                ]
            ),
            17 => StructDesc(
                "CDictBadKeysPointee", 32, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 12, 8),  # Ptr{NotCString} — pointee isn't CString-shaped
                    FieldDesc("values", 13, 16),
                    FieldDesc("owned", 1, 24),
                ]
            ),
            18 => StructDesc(
                "CDictBadNames", 32, 8, FieldDesc[
                    FieldDesc("len", 2, 0),
                    FieldDesc("keys", 11, 8),
                    FieldDesc("values", 13, 16),
                    FieldDesc("owned", 1, 24),
                ]
            ),
            19 => StructDesc(
                "CDictTwoFields", 16, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 11, 8),
                ]
            ),
            20 => StructDesc(
                "CDictUnsupportedValue", 32, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 11, 8),
                    FieldDesc("values", 14, 16),  # Ptr{NotARealType} — not in pytypes
                    FieldDesc("owned", 1, 24),
                ]
            ),
            21 => StructDesc(
                "CDictSinglePtrKeys", 32, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 7, 8),  # Ptr{UInt8} — pointee isn't a struct at all
                    FieldDesc("values", 13, 16),
                    FieldDesc("owned", 1, 24),
                ]
            ),
            22 => StructDesc(
                "CDictMissingOwned", 24, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 11, 8),
                    FieldDesc("values", 13, 16),
                    # no `owned` field at all — otherwise identical to ti[15]
                ]
            ),
            23 => StructDesc(
                "CDictOwnedWrongType", 32, 8, FieldDesc[
                    FieldDesc("length", 2, 0),
                    FieldDesc("keys", 11, 8),
                    FieldDesc("values", 13, 16),
                    FieldDesc("owned", 2, 24),  # Int64, not Int32
                ]
            ),
        )
        @test !isnothing(cdinfo(ti[15], ti))
        @test isnothing(cdinfo(ti[16], ti)) # wrong name prefix
        @test isnothing(cdinfo(ti[17], ti)) # keys' pointee isn't CString-shaped
        @test isnothing(cdinfo(ti[18], ti)) # wrong field names
        @test isnothing(cdinfo(ti[19], ti)) # missing `values` field
        @test isnothing(cdinfo(ti[20], ti)) # values pointee not in pytypes
        @test isnothing(cdinfo(ti[21], ti)) # keys isn't a pointer-to-struct at all
        @test isnothing(cdinfo(ti[22], ti)) # missing `owned` field entirely
        @test isnothing(cdinfo(ti[23], ti)) # `owned` present but not Int32

        # Field order may be any permutation.
        permuted = StructDesc(
            "CDict{Float64}", 32, 8, FieldDesc[
                FieldDesc("owned", 1, 24),
                FieldDesc("values", 13, 16),
                FieldDesc("length", 2, 0),
                FieldDesc("keys", 11, 8),
            ]
        )
        @test !isnothing(cdinfo(permuted, ti))
    end

    @testset "copt_struct_info" begin
        # Structural recognition of the COpt{T} shape: a struct named COpt
        # with `has_value` (Int32 primitive) and `value` (any primitive in
        # `pytypes`) fields.
        coinfo(desc, typeinfo) = JuliaLibWrapping.copt_struct_info(desc, typeinfo, JuliaLibWrapping.pytypes)
        abi = read_abi_info("bindinginfo_copt.json")
        findtype(descs, name) = (
            k = collect(keys(descs));
            k[findfirst((id) -> descs[id].name === name, k)]
        )
        co = abi.typeinfo[findtype(abi.typeinfo, "COpt{Float64}")]
        info = coinfo(co, abi.typeinfo)
        @test !isnothing(info)
        @test info.value_ctype == "ctypes.c_double"

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
                    FieldDesc("value", 4, 8),  # NotARealType — not in pytypes
                ]
            ),
            10 => StructDesc(
                "COptThreeFields", 16, 8, FieldDesc[
                    FieldDesc("has_value", 1, 0),
                    FieldDesc("value", 3, 8),
                    FieldDesc("extra", 3, 8),
                ]
            ),
        )
        @test !isnothing(coinfo(ti[5], ti))
        @test isnothing(coinfo(ti[6], ti)) # wrong name prefix
        @test isnothing(coinfo(ti[7], ti)) # has_value is Int64, not Int32
        @test isnothing(coinfo(ti[8], ti)) # wrong field names
        @test isnothing(coinfo(ti[9], ti)) # value pointee not in pytypes
        @test isnothing(coinfo(ti[10], ti)) # too many fields

        # Field order may be either way.
        flipped = StructDesc(
            "COpt{Float64}", 16, 8, FieldDesc[
                FieldDesc("value", 3, 8),
                FieldDesc("has_value", 1, 0),
            ]
        )
        @test !isnothing(coinfo(flipped, ti))
    end

    @testset "_is_void_struct" begin
        # juliac's ABI JSON represents `Cvoid` as a zero-field `struct
        # Nothing`, not a PrimitiveTypeDesc named "Cvoid" — in EVERY
        # position: a bare return (routed to a Python `None` restype
        # instead of a real, zero-size, libffi-incompatible
        # ctypes.Structure class) AND a pointer's pointee (`Ptr{Nothing}`
        # routed to `ctypes.c_void_p` instead of `ctypes.POINTER(Nothing)`,
        # which ctypes refuses to accept a `c_void_p` argument for). This
        # predicate is the shared gate both call sites use.
        is_void = JuliaLibWrapping._is_void_struct
        @test is_void(StructDesc("Nothing", 0, 1, FieldDesc[])) === true
        # Name alone is not enough: a real struct literally named Nothing
        # with fields must not be swallowed.
        @test is_void(StructDesc("Nothing", 8, 8, FieldDesc[FieldDesc("x", 1, 0)])) === false
        # Fields alone is not enough either: an unrelated empty struct.
        @test is_void(StructDesc("Empty", 0, 1, FieldDesc[])) === false
        # Sanity: the real synthetic node from the CStrArray fixture.
        abi = read_abi_info("bindinginfo_cstrarray.json")
        findtype(descs, name) = (
            k = collect(keys(descs));
            k[findfirst((id) -> descs[id].name === name, k)]
        )
        nothing_desc = abi.typeinfo[findtype(abi.typeinfo, "Nothing")]
        @test is_void(nothing_desc) === true
    end

    @testset "mangle_python! Ptr{Nothing} collapse" begin
        # A PointerDesc whose pointee is the zero-field `Nothing` struct
        # (juliac's real representation of `Ptr{Cvoid}`, per
        # `_is_void_struct`) must collapse to `ctypes.c_void_p`, same
        # as the pre-existing `Ptr{Cvoid}`-as-primitive special case —
        # NOT render as `ctypes.POINTER(Nothing)`, which is what broke
        # `jlw_free`'s argtype (ctypes refuses a `c_void_p` argument where
        # a distinct named pointer type is declared).
        typedict = Dict{Int, String}()
        typeinfo = OrderedDict{Int, TypeDesc}(
            1 => StructDesc("Nothing", 0, 1, FieldDesc[]),
            2 => PointerDesc("Ptr{Nothing}", 1),
        )
        @test JuliaLibWrapping.mangle_python!(typedict, 2, typeinfo) == "ctypes.c_void_p"
        # The struct itself, referenced directly (not through a pointer),
        # still mangles to its real class name — unaffected, still needed
        # wherever the class definition itself is emitted.
        typedict2 = Dict{Int, String}()
        @test JuliaLibWrapping.mangle_python!(typedict2, 1, typeinfo) == "Nothing"
        # A pointer to a REAL (non-void) empty-named-Nothing struct with
        # fields is not swallowed — still a typed pointer.
        typedict3 = Dict{Int, String}()
        typeinfo3 = OrderedDict{Int, TypeDesc}(
            1 => PrimitiveTypeDesc("Int64", true, 64, 8, 8),
            2 => StructDesc("Nothing", 8, 8, FieldDesc[FieldDesc("x", 1, 0)]),
            3 => PointerDesc("Ptr{Nothing}", 2),
        )
        @test JuliaLibWrapping.mangle_python!(typedict3, 3, typeinfo3) == "ctypes.POINTER(Nothing)"
    end

    @testset "mangle_python! Nothing type_id sweep" begin
        # Pins behavior at EVERY position `mangle_python!` can reach the
        # zero-field `Nothing` struct type_id from, not just the two fixed
        # call sites (bare return, pointer pointee) — so a gap is a
        # failing assertion, not a silent assumption. See
        # `_is_void_struct`'s docstring for the per-position rationale.

        # Struct FIELD typed as a POINTER to Nothing (Ptr{Cvoid} field) —
        # this goes through the same fixed PointerDesc branch as an
        # argument/return would, so it correctly collapses too.
        let typedict = Dict{Int, String}()
            typeinfo = OrderedDict{Int, TypeDesc}(
                1 => StructDesc("Nothing", 0, 1, FieldDesc[]),
                2 => PointerDesc("Ptr{Nothing}", 1),
            )
            field_type = JuliaLibWrapping.mangle_python!(typedict, 2, typeinfo)
            @test field_type == "ctypes.c_void_p"
        end

        # Struct FIELD typed as the BARE Nothing struct (not a pointer) —
        # left unhandled BY DESIGN: a ctypes `_fields_` entry needs a real
        # ctypes type object, and `None` is not one, so this must keep
        # rendering the class name. Pinned so a future change to
        # `_is_void_struct`'s call sites can't silently start emitting an
        # invalid `("x", None)` field tuple.
        let typedict = Dict{Int, String}()
            typeinfo = OrderedDict{Int, TypeDesc}(
                1 => StructDesc("Nothing", 0, 1, FieldDesc[]),
            )
            field_type = JuliaLibWrapping.mangle_python!(typedict, 1, typeinfo)
            @test field_type == "Nothing"
        end

        # ARRAY ELEMENT typed as the bare Nothing struct (an ABI encoding
        # of the unrealizable `NTuple{N,Cvoid}`) — KNOWN UNHANDLED, pinned
        # rather than silently assumed safe. If juliac is ever observed to
        # emit this shape for a real carrier, this assertion is the trip
        # wire that forces a look, not a silent `(Nothing * N)` array of
        # zero-size structs shipped to users.
        let typedict = Dict{Int, String}()
            typeinfo = OrderedDict{Int, TypeDesc}(
                1 => StructDesc("Nothing", 0, 1, FieldDesc[]),
                2 => ArrayDesc("NTuple{3, Nothing}", 1, 3, 0, 1),
            )
            arr_type = JuliaLibWrapping.mangle_python!(typedict, 2, typeinfo)
            @test arr_type == "(Nothing * 3)"
        end

        # RETURN position via a Ptr{Nothing} (not a bare Nothing struct) —
        # `_write_bindings`'s round-1 ternary falls through to
        # `mangle_python!` for any non-StructDesc return, which is exactly
        # this PointerDesc case; confirms it resolves through the same
        # fixed branch as an argument would, with no separate handling
        # needed at the `_write_bindings` call site.
        let typedict = Dict{Int, String}()
            typeinfo = OrderedDict{Int, TypeDesc}(
                1 => StructDesc("Nothing", 0, 1, FieldDesc[]),
                2 => PointerDesc("Ptr{Nothing}", 1),
            )
            return_type = JuliaLibWrapping.mangle_python!(typedict, 2, typeinfo)
            @test return_type == "ctypes.c_void_p"
        end
    end

    @testset "CString vocabulary" begin
        # CString conversion does not require numpy.
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
            @test occursin(
                "def greeting_length(s):\n    _s = CString.from_str(s)\n" *
                    "    return _lowlevel.greeting_length(_s)", facade
            )
            @test occursin(
                "def greeting():\n    _result = _lowlevel.greeting()\n" *
                    "    return _result.as_str()", facade
            )
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

    @testset "CStrArray vocabulary" begin
        # CStrArray conversion does not require numpy — pure ctypes, like
        # CString. Exercises a borrow-in argument (take_strs), an owning
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
            # juliac's ABI JSON represents `Cvoid` as a zero-field
            # `Nothing` StructDesc, not a PrimitiveTypeDesc, in EVERY
            # position — both the bare-return case and the
            # `Ptr{Nothing}`-argument case. Mishandling either would
            # silently reintroduce `ffi_prep_cif failed` / `TypeError:
            # expected LP_Nothing instance instead of c_void_p` at the
            # first real call.
            @test !occursin("_lib.jlw_free.restype = Nothing", bindings)
            @test !occursin("_lib.jlw_free_strings.restype = Nothing", bindings)
            @test !occursin("ctypes.POINTER(Nothing)", bindings)

            # Explicit ownership: `from_list` always builds a caller-owned
            # (owned=0) value — it never allocated the buffer it borrows.
            @test occursin("(\"owned\", ctypes.c_int32)", bindings)
            @test occursin("owned=0)", bindings)
            # A `.free()` escape hatch for callers who bypass the façade:
            # frees iff owned, then clears the flag — idempotent.
            @test occursin("def free(self):", bindings)
            @test occursin("if self.owned == 1:", bindings)
            @test occursin("self.owned = 0", bindings)

            golden = read(joinpath(@__DIR__, "expected_cstrarray_lowlevel.py"), String)
            @test bindings == golden

            # jlw_free/jlw_free_strings are release-entrypoint internals —
            # never re-exported from the façade (no TODO line, no bare
            # re-export) and never listed in `__all__`, regardless of what
            # their own (raw-pointer) argument shape would otherwise
            # classify to. The internal call inside give_strs's own
            # auto-wrapper body (`_lowlevel._lib.jlw_free_strings(...)`)
            # is legitimate and stays (see the golden compare below).
            facade = read(joinpath(path, "cstrarray_demo", "_facade.py"), String)
            @test !occursin("import jlw_free", facade)
            @test !occursin("\"jlw_free\"", facade)
            @test !occursin("\"jlw_free_strings\"", facade)
            # The owning-return free call is gated on the RETURNED value's
            # own `owned` field, never assumed from call direction alone.
            @test occursin("if _result.owned == 1:", facade)
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
        # CStrArray. Exercises a borrow-in argument (take_dict), an owning
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

            # Explicit ownership: `from_dict` always builds a caller-owned
            # (owned=0) value, and a `.free()` escape hatch frees iff owned
            # then clears the flag — idempotent.
            @test occursin("(\"owned\", ctypes.c_int32)", bindings)
            @test occursin("owned=0)", bindings)
            @test occursin("def free(self):", bindings)
            @test occursin("if self.owned == 1:", bindings)
            @test occursin("self.owned = 0", bindings)

            golden = read(joinpath(@__DIR__, "expected_cdict_lowlevel.py"), String)
            @test bindings == golden

            # jlw_free/jlw_free_strings are release-entrypoint internals —
            # never re-exported and never listed in `__all__`. The
            # internal calls inside give_dict's own auto-wrapper body
            # are legitimate and stay (see the golden compare below).
            facade = read(joinpath(path, "cdict_demo", "_facade.py"), String)
            @test !occursin("import jlw_free", facade)
            @test !occursin("\"jlw_free\"", facade)
            @test !occursin("\"jlw_free_strings\"", facade)
            # The owning-return free calls are gated on the RETURNED
            # value's own `owned` field, never assumed from call direction.
            @test occursin("if _result.owned == 1:", facade)
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
        # Proves `value_ctype`/`value_dtype_name` parameterization (and
        # the generated from_dict/as_dict codegen that substitutes them)
        # varies correctly for a value type OTHER than the Float64
        # exercised by the main "CDict vocabulary" testset. Field offsets
        # are identical to the Float64 fixture — `values` is a pointer
        # field, so its own size never depends on the pointee's size.
        # Also re-exercises the jlw_free `ctypes.c_void_p` argtype
        # handling on a second, independent fixture.
        abi = read_abi_info("bindinginfo_cdict_int32.json")
        mktempdir() do path
            dest = PythonTarget(path, "cdict_int32_demo", "libcdicti32")
            write_wrapper(dest, abi)

            bindings_path = joinpath(path, "cdict_int32_demo", "_lowlevel.py")
            bindings = read(bindings_path, String)

            @test occursin("class CDict_Int32(ctypes.Structure):", bindings)
            @test occursin("(\"length\", ctypes.c_int64)", bindings)
            @test occursin(
                "(\"keys\", ctypes.POINTER(CString))", bindings
            )
            @test occursin("(\"values\", ctypes.POINTER(ctypes.c_int32))", bindings)
            # <value_ctype> substitution varies: Int32 here, not Float64.
            @test occursin("varr = (ctypes.c_int32 * len(keys))(*d.values())", bindings)
            @test occursin(
                "values=ctypes.cast(varr, ctypes.POINTER(ctypes.c_int32))", bindings
            )
            @test !occursin("ctypes.c_double", bindings)

            @test occursin("_lib.take_dict_i32.argtypes = [CDict_Int32]", bindings)
            @test occursin("_lib.give_dict_i32.restype = CDict_Int32", bindings)
            # Round-2 fix re-exercised on an independent fixture.
            @test occursin("_lib.jlw_free.argtypes = [ctypes.c_void_p]", bindings)
            @test occursin("_lib.jlw_free.restype = None", bindings)
            @test !occursin("ctypes.POINTER(Nothing)", bindings)

            golden = read(joinpath(@__DIR__, "expected_cdict_int32_lowlevel.py"), String)
            @test bindings == golden

            facade = read(joinpath(path, "cdict_int32_demo", "_facade.py"), String)
            @test occursin(
                "def give_dict_i32():\n    _result = _lowlevel.give_dict_i32()\n" *
                    "    _out = _result.as_dict()\n" *
                    "    if _result.owned == 1:\n" *
                    "        _lowlevel._lib.jlw_free_strings(_result.keys, _result.length)\n" *
                    "        _lowlevel._lib.jlw_free(ctypes.cast(_result.values, ctypes.c_void_p))\n" *
                    "    return _out", facade
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
        # A library that defines the CStrArray carrier but has
        # not exported the release entrypoints (no jlw_free/jlw_free_strings
        # among its functions) must not have its owning return auto-wrapped
        # — that would emit a call to a symbol the shared library does not
        # export. take_strs (borrow-in) is unaffected; give_strs (owning
        # return) falls back to a mechanical TODO naming the macro to add.
        abi = read_abi_info("bindinginfo_cstrarray_nofree.json")
        @test JuliaLibWrapping._release_symbols_present(abi) === false
        mktempdir() do path
            dest = PythonTarget(path, "cstrarray_nofree_demo", "libcstrarraynofree")
            write_wrapper(dest, abi)

            bindings_path = joinpath(path, "cstrarray_nofree_demo", "_lowlevel.py")
            bindings = read(bindings_path, String)
            # No jlw_free* entrypoints in this fixture's `functions` list at
            # all, so nothing gets bound on `_lib` (argtypes/restype) for
            # them. `CStrArray.free()` is still emitted (the bypass escape
            # hatch keeps the same API shape either way), but its body is a
            # clear `RuntimeError` instead of a call to a symbol `_lib` never
            # bound — calling it would otherwise raise a bare, confusing
            # `AttributeError` at runtime.
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
            @test occursin("_lib.take_strs.argtypes = [CStrArray]", bindings)
            @test occursin("_lib.give_strs.restype = CStrArray", bindings)

            golden = read(joinpath(@__DIR__, "expected_cstrarray_nofree_lowlevel.py"), String)
            @test bindings == golden

            facade = read(joinpath(path, "cstrarray_nofree_demo", "_facade.py"), String)
            # take_strs (borrow-in) is still auto-wrapped — the release-
            # symbol gate applies only to owning RETURNS.
            @test occursin(
                "def take_strs(a):\n    _a = CStrArray.from_list(a)\n" *
                    "    return _lowlevel.take_strs(_a)", facade
            )
            # give_strs (owning return) is NOT auto-wrapped: no free call
            # exists to emit safely, so it falls back to a mechanical
            # re-export with a TODO naming the fix.
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
                "def trace_cmatrix(m):\n    _m = CMatrix_Float64.from_numpy(m)\n" *
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
            @test occursin(
                "np.ctypeslib.as_array(self.data, shape=tuple(self.dims)[::-1]).T",
                bindings
            )

            golden = read(joinpath(@__DIR__, "expected_carray3_lowlevel.py"), String)
            @test bindings == golden

            facade = read(joinpath(path, "carray3_demo", "_facade.py"), String)
            @test occursin(
                "def sum3d(a):\n    _a = CArray_Float64_3.from_numpy(a)\n" *
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

    @testset "raw primitive pointer docstring" begin
        # Bare primitive pointers produce ownership guidance during generation.
        abi = read_abi_info("bindinginfo_rawptr.json")

        # Helper recognizes the raw-primitive-pointer argument.
        method = only(abi.entrypoints)
        @test JuliaLibWrapping.raw_primitive_pointer_args(method, abi.typeinfo, JuliaLibWrapping.numpy_dtypes) == [1]

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
            @test occursin("`CArray{T,N}`", bindings)

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
        @test isempty(JuliaLibWrapping.raw_primitive_pointer_args(method_cm, abi_cm.typeinfo, JuliaLibWrapping.numpy_dtypes))
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
