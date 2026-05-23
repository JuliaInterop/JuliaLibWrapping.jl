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

    @testset "CString layout" begin
        @test fieldnames(CString) == (:length, :data)
        @test fieldtype(CString, :length) === Int32
        @test fieldtype(CString, :data) === Ptr{UInt8}
        @test isbitstype(CString)
        @test fieldoffset(CString, 1) == 0
        @test fieldoffset(CString, 2) == 8
        @test CString <: AbstractString
    end

    @testset "CString AbstractString interface" begin
        buf = codeunits("hello")
        GC.@preserve buf begin
            s = CString(Int32(length(buf)), pointer(buf))

            # AbstractString-derived methods.
            @test ncodeunits(s) === 5
            @test codeunit(s) === UInt8
            @test codeunit(s, 1) === UInt8('h')
            @test_throws BoundsError codeunit(s, 0)
            @test_throws BoundsError codeunit(s, 6)
            @test length(s) === 5  # character count (ASCII so == ncodeunits)
            @test collect(s) == collect("hello")
            @test s == "hello"
            @test "hello" == s
            @test cmp(s, "hello") == 0
            @test cmp(s, "world") < 0
            @test String(s) == "hello"
            @test occursin("ell", s)
            @test startswith(s, "he")
        end

        # Embedded NUL bytes are preserved (length-prefixed, not terminated).
        raw = UInt8[0x66, 0x00, 0x6f]  # "f\0o"
        GC.@preserve raw begin
            s = CString(Int32(length(raw)), pointer(raw))
            @test ncodeunits(s) === 3
            @test codeunit(s, 2) === 0x00
            @test String(s) == "f\0o"
        end

        # Multi-byte UTF-8 ("café"): 4 characters, 5 bytes.
        utf8 = codeunits("café")
        GC.@preserve utf8 begin
            s = CString(Int32(length(utf8)), pointer(utf8))
            @test ncodeunits(s) === 5
            @test length(s) === 4
            @test collect(s) == ['c', 'a', 'f', 'é']
            @test s == "café"
            @test String(s) == "café"
        end

        # Fast byte-level cmp between two CStrings.
        a_buf = codeunits("apple")
        b_buf = codeunits("banana")
        GC.@preserve a_buf b_buf begin
            a = CString(Int32(length(a_buf)), pointer(a_buf))
            b = CString(Int32(length(b_buf)), pointer(b_buf))
            @test cmp(a, b) < 0
            @test cmp(b, a) > 0
            @test cmp(a, a) == 0
            @test a < b
            @test a != b
        end
    end

    @testset "CMatrix AbstractMatrix interface" begin
        # Column-major storage; verify both linear and Cartesian indexing.
        buf = Float64[1.0, 2.0, 3.0, 4.0, 5.0, 6.0]  # 2x3, col-major
        GC.@preserve buf begin
            m = CMatrix{Float64}(Int32(2), Int32(3), pointer(buf))

            @test m isa AbstractMatrix{Float64}
            @test IndexStyle(typeof(m)) === IndexLinear()
            @test size(m) === (2, 3)
            @test size(m, 1) === 2
            @test size(m, 2) === 3
            @test length(m) === 6
            @test eltype(m) === Float64

            # Column-major: m[1,1]=1, m[2,1]=2, m[1,2]=3, m[2,2]=4, m[1,3]=5, m[2,3]=6
            @test m[1, 1] === 1.0
            @test m[2, 1] === 2.0
            @test m[1, 2] === 3.0
            @test m[2, 3] === 6.0
            @test m[3] === 3.0  # linear index = 3 → m[1, 2]

            # Bounds checking works in both forms.
            @test_throws BoundsError m[0]
            @test_throws BoundsError m[7]
            @test_throws BoundsError m[3, 1]
            @test_throws BoundsError m[1, 4]

            # AbstractArray machinery.
            @test sum(m) === 21.0
            @test collect(m) == reshape(buf, 2, 3)

            # setindex! writes through to the backing buffer.
            m[1, 2] = 99.0  # linear slot 3
            @test buf[3] == 99.0
            @test_throws BoundsError (m[3, 1] = 0.0)
        end
    end

    @testset "CMatrix layout" begin
        @test fieldnames(CMatrix) == (:rows, :cols, :data)
        @test fieldtype(CMatrix{Float64}, :rows) === Int32
        @test fieldtype(CMatrix{Float64}, :cols) === Int32
        @test fieldtype(CMatrix{Float64}, :data) === Ptr{Float64}
        @test isbitstype(CMatrix{Float64})
        @test fieldoffset(CMatrix{Float64}, 1) == 0
        @test fieldoffset(CMatrix{Float64}, 2) == 4
        # rows + cols pack into 8 bytes, then pointer-aligned.
        @test fieldoffset(CMatrix{Float64}, 3) == 8
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
