using JuliaLibWrapping
using Test

function onlymatch(f, collection)
    matches = filter(f, collection)
    if length(matches) != 1
        error("Expected exactly one match, found $(length(matches))")
    end
    return matches[1]
end

@testset "JuliaLibWrapping.jl" begin
    @testset "parselog" begin
        entrypoints, typedescs, forwarddecls = parselog("bindinginfo_libsimple.json")

        methdesc = onlymatch(md -> md.symbol == "copyto_and_sum", entrypoints)
        @test typedescs[methdesc.return_type].name == "Float32"
        @test length(methdesc.args) == 1
        argdesc = only(methdesc.args)
        @test argdesc.name == "fromto"
        @test typedescs[argdesc.type].name == "CVectorPair{Float32}"
        @test argdesc.isva == false

        methdesc = onlymatch(md -> md.symbol == "countsame", entrypoints)
        @test typedescs[methdesc.return_type].name == "Int32"
        @test length(methdesc.args) == 2
        argdesc1, argdesc2 = methdesc.args
        @test argdesc1.name == "list"
        @test typedescs[argdesc1.type].name == "Ptr{MyTwoVec}"
        @test argdesc1.isva == false
        @test argdesc2.name == "n"
        @test typedescs[argdesc2.type].name == "Int32"
        @test argdesc2.isva == false

        @test length(typedescs) >= 3
        findtype(descs, name) = (k = collect(keys(descs)); k[findfirst((id)->descs[id].name === name, k)])

        tdesc = typedescs[findtype(typedescs, "CVectorPair{Float32}")]
        @test tdesc.name == "CVectorPair{Float32}"
        @test length(tdesc.fields) == 2
        @test tdesc.fields[1].name == "from"
        @test typedescs[tdesc.fields[1].type].name == "CVector{Float32}"
        @test tdesc.fields[1].offset == 0
        @test tdesc.fields[2].name == "to"
        @test typedescs[tdesc.fields[2].type].name == "CVector{Float32}"
        @test tdesc.fields[2].offset == 16
        @test tdesc.size == 32
        tdesc = typedescs[findtype(typedescs, "CVector{Float32}")]
        @test tdesc.name == "CVector{Float32}"
        @test length(tdesc.fields) == 2
        @test tdesc.fields[1].name == "length"
        @test typedescs[tdesc.fields[1].type].name == "Int32"
        @test tdesc.fields[1].offset == 0
        @test tdesc.fields[2].name == "data"
        @test typedescs[tdesc.fields[2].type].name == "Ptr{Float32}"
        @test tdesc.fields[2].offset == 8
        @test tdesc.size == 16
        tdesc = typedescs[findtype(typedescs, "MyTwoVec")]
        @test tdesc.name == "MyTwoVec"
        @test length(tdesc.fields) == 2
        @test tdesc.fields[1].name == "x"
        @test typedescs[tdesc.fields[1].type].name == "Int32"
        @test tdesc.fields[1].offset == 0
        @test tdesc.fields[2].name == "y"
        @test typedescs[tdesc.fields[2].type].name == "Int32"
        @test tdesc.fields[2].offset == 4
        @test tdesc.size == 8
        name2idx = Dict(desc.name => i for (i, desc) in enumerate(values(typedescs)))
        @test name2idx["CVectorPair{Float32}"] > name2idx["CVector{Float32}"]
    end

    @testset "C wrapper" begin
        mktempdir() do path
            mkpath(path)
            dest = CProject(path, "libsimple")
            entrypoints, typedescs, forwarddecls = parselog("bindinginfo_libsimple.json")
            wrapper(dest, entrypoints, typedescs, forwarddecls)

            headerfile = joinpath(dest.dir, dest.headerbase * ".h")
            @test isfile(headerfile)
            content = read(headerfile, String)
            @test occursin("#ifndef JULIALIB_LIBSIMPLE_H", content)
            @test occursin("#define JULIALIB_LIBSIMPLE_H", content)
            @test occursin("#include <stddef.h>", content)
            @test occursin("#include <stdint.h>", content)
            @test occursin("#include <stdbool.h>", content)
            @test occursin("typedef struct CVector_Float32_ {", content)
            @test occursin("    int32_t length;", content)
            @test occursin("    float* data;", content)
            @test occursin("CVector_Float32_ from;", content)
            @test occursin("CVector_Float32_ to;", content)
            @test occursin("float copyto_and_sum(CVectorPair_Float32_ fromto);", content)
            @test occursin("int32_t countsame(MyTwoVec* list, int32_t n);", content)
        end
    end
end
