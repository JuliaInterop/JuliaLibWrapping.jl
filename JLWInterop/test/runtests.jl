using JLWInterop
using Test

@testset "JLWInterop" begin
    @testset "jlw_ok" begin
        s = jlw_ok()
        @test s.code == 0
        @test all(==(0x00), s.message)
    end

    @testset "jlw_error: basic" begin
        s = jlw_error(7, "oops")
        @test s.code == Int32(7)
        @test s.message[1:4] == (UInt8('o'), UInt8('o'), UInt8('p'), UInt8('s'))
        @test s.message[5] == 0x00  # null terminator immediately after
    end

    @testset "jlw_error: truncation + null-termination" begin
        # 300-byte message should truncate to 255 bytes + null.
        long = String(repeat('x', 300))
        s = jlw_error(1, long)
        @test s.code == Int32(1)
        @test all(==(UInt8('x')), s.message[1:255])
        @test s.message[256] == 0x00
    end

    @testset "jlw_error: exact-fit message still null-terminated" begin
        # 255 bytes exactly fills the message slots; byte 256 must remain 0.
        msg = String(repeat('a', 255))
        s = jlw_error(2, msg)
        @test all(==(UInt8('a')), s.message[1:255])
        @test s.message[256] == 0x00
    end

    @testset "jlw_error: accepts Int32 and wider integers" begin
        @test jlw_error(Int32(3), "x").code === Int32(3)
        @test jlw_error(Int64(4), "x").code === Int32(4)
    end

    @testset "JLWStatus is bits / C-ABI friendly" begin
        @test isbitstype(JLWStatus)
        # 4 bytes for code + 256 for message; alignment may pad to 260 or 264
        # depending on platform, but the type itself must be bits.
        @test sizeof(JLWStatus) >= 4 + 256
    end

    @testset "CVector AbstractVector interface" begin
        # `GC.@preserve buf` keeps the backing Vector alive for the duration
        # of the CVector view — the same pattern any Julia caller would use.
        buf = Float64[10.0, 20.0, 30.0, 40.0]
        GC.@preserve buf begin
            v = CVector{Float64}(Int32(length(buf)), pointer(buf))

            @test v isa AbstractVector{Float64}
            @test IndexStyle(typeof(v)) === IndexLinear()
            @test size(v) === (4,)
            @test length(v) === 4
            @test eltype(v) === Float64

            # getindex round-trips
            @test v[1] === 10.0
            @test v[4] === 40.0
            @test collect(v) == buf

            # bounds checking actually checks (we now have length info)
            @test_throws BoundsError v[0]
            @test_throws BoundsError v[5]

            # AbstractArray machinery just works
            @test sum(v) === 100.0
            @test v .+ 1.0 == buf .+ 1.0  # broadcasting allocates a Vector

            # setindex! writes through the pointer back into `buf`
            v[2] = 99.0
            @test buf[2] == 99.0
            @test_throws BoundsError (v[0] = 0.0)
        end
    end

    @testset "CVector layout" begin
        # Layout must match what the JuliaLibWrapping Python emitter expects:
        # length::Int32 first, data::Ptr{T} second. Helpers on the Python side
        # construct by keyword, but downstream C code reading the struct
        # depends on this order being stable.
        @test fieldnames(CVector) == (:length, :data)
        @test fieldtype(CVector{Float64}, :length) === Int32
        @test fieldtype(CVector{Float64}, :data) === Ptr{Float64}
        @test isbitstype(CVector{Float64})
        @test fieldoffset(CVector{Float64}, 1) == 0
        # data follows length, on any supported platform pointer alignment
        # pads length out to 8 bytes.
        @test fieldoffset(CVector{Float64}, 2) == 8
        v = CVector{Float64}(Int32(0), Ptr{Float64}(0))
        @test v.length === Int32(0)
        @test v.data === Ptr{Float64}(0)
    end
end
