using JuliaLibWrapping
using Test

@testset "JuliaLibWrapping.jl" begin
    @testset "parselog" begin
        entrypoints, typedescs = parselog("bindinginfo_simplelib.log")
        methdesc = only(entrypoints)
        @test methdesc.name == "copyto_and_sum"
        @test methdesc.return_type == "Float32"
        @test length(methdesc.args) == 1
        argdesc = only(methdesc.args)
        @test argdesc.name == "fromto"
        @test argdesc.type == "CVectorPair{Float32}"
        @test argdesc.isva == false
        @test length(typedescs) == 2
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
        @test sprint(show, only(entrypoints)) == "copyto_and_sum(fromto::CVectorPair{Float32})::Float32"
        str = sprint(show, typedescs)
        @test occursin("CVectorPair{Float32}(from::CVector{Float32}[0], to::CVector{Float32}[16]) (32 bytes)", str)
        @test occursin("CVector{Float32}(length::Int32[0], data::Ptr{Float32}[8]) (16 bytes)", str)
    end
end
