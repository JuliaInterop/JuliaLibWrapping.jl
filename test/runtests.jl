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
        entrypoints, typedescs = parselog("bindinginfo_libsimple.log")

        methdesc = onlymatch(md -> md.name == "copyto_and_sum", entrypoints)
        @test methdesc.return_type == "Float32"
        @test length(methdesc.args) == 1
        argdesc = only(methdesc.args)
        @test argdesc.name == "fromto"
        @test argdesc.type == "CVectorPair{Float32}"
        @test argdesc.isva == false
        @test sprint(show, methdesc) == "copyto_and_sum(fromto::CVectorPair{Float32})::Float32"

        methdesc = onlymatch(md -> md.name == "countsame", entrypoints)
        @test methdesc.return_type == "Int32"
        @test length(methdesc.args) == 2
        argdesc1, argdesc2 = methdesc.args
        @test argdesc1.name == "list"
        @test argdesc1.type == "Ptr{MyTwoVec}"
        @test argdesc1.isva == false
        @test argdesc2.name == "n"
        @test argdesc2.type == "Int32"
        @test argdesc2.isva == false

        @test length(typedescs) == 3
        tdesc = typedescs["CVectorPair{Float32}"]
        @test tdesc.name == "CVectorPair{Float32}"
        @test length(tdesc.fields) == 2
        @test tdesc.fields[1].name == "from"
        @test tdesc.fields[1].type == "CVector{Float32}"
        @test tdesc.fields[1].offset == 0
        @test tdesc.fields[2].name == "to"
        @test tdesc.fields[2].type == "CVector{Float32}"
        @test tdesc.fields[2].offset == 16
        @test tdesc.size == 32
        tdesc = typedescs["CVector{Float32}"]
        @test tdesc.name == "CVector{Float32}"
        @test length(tdesc.fields) == 2
        @test tdesc.fields[1].name == "length"
        @test tdesc.fields[1].type == "Int32"
        @test tdesc.fields[1].offset == 0
        @test tdesc.fields[2].name == "data"
        @test tdesc.fields[2].type == "Ptr{Float32}"
        @test tdesc.fields[2].offset == 8
        @test tdesc.size == 16
        @test haskey(typedescs, "CVectorPair{Float32}")
        @test haskey(typedescs, "CVector{Float32}")
        tdesc = typedescs["MyTwoVec"]
        @test tdesc.name == "MyTwoVec"
        @test length(tdesc.fields) == 2
        @test tdesc.fields[1].name == "x"
        @test tdesc.fields[1].type == "Int32"
        @test tdesc.fields[1].offset == 0
        @test tdesc.fields[2].name == "y"
        @test tdesc.fields[2].type == "Int32"
        @test tdesc.fields[2].offset == 4
        @test tdesc.size == 8
        name2idx = Dict(name => i for (i, name) in enumerate(keys(typedescs)))
        @test name2idx["CVectorPair{Float32}"] > name2idx["CVector{Float32}"]

        str = sprint(show, typedescs)
        @test occursin("CVectorPair{Float32}(from::CVector{Float32}[0], to::CVector{Float32}[16]) (32 bytes)", str)
        @test occursin("CVector{Float32}(length::Int32[0], data::Ptr{Float32}[8]) (16 bytes)", str)
    end
end
