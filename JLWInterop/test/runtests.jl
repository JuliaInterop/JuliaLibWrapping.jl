using JLWInterop
using LinearAlgebra
using OffsetArrays
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

    @testset "CArray aliases" begin
        # CVector and CMatrix are CArray aliases.
        @test CVector{:owned, Float64} === CArray{:owned, Float64, 1}
        @test CMatrix{:borrowed, Float64} === CArray{:borrowed, Float64, 2}
        @test CVector === CArray{owned, T, 1} where {owned, T}
        @test CMatrix === CArray{owned, T, 2} where {owned, T}
    end

    @testset "CVector AbstractVector interface" begin
        # Keep the borrowed buffer alive while using the view.
        buf = Float64[10.0, 20.0, 30.0, 40.0]
        GC.@preserve buf begin
            v = CVector{:borrowed, Float64}(Int64(length(buf)), pointer(buf))

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

            # Methods inherited from AbstractArray.
            @test sum(v) === 100.0
            @test v .+ 1.0 == buf .+ 1.0  # broadcasting allocates a Vector

            # setindex! writes through the pointer back into `buf`
            v[2] = 99.0
            @test buf[2] == 99.0
            @test_throws BoundsError (v[0] = 0.0)
        end
    end

    @testset "CString layout" begin
        @test fieldnames(CString{:borrowed}) == (:length, :data)
        @test fieldtype(CString{:borrowed}, :length) === Int64
        @test fieldtype(CString{:borrowed}, :data) === Ptr{UInt8}
        @test isbitstype(CString{:borrowed})
        @test fieldoffset(CString{:borrowed}, 1) == 0
        @test fieldoffset(CString{:borrowed}, 2) == 8
        @test CString{:borrowed} <: AbstractString

        # Ownership is part of the type, so the two flavors are distinct types
        # with identical layout.
        @test CString{:owned} !== CString{:borrowed}
        @test sizeof(CString{:owned}) == sizeof(CString{:borrowed}) == 16
    end

    @testset "CString ABI names" begin
        # `juliac` writes the ABI JSON's struct names with
        # `repr(dt; context = :compact => true)`, and JuliaLibWrapping's
        # recognizer parses the ownership back out of that text.
        compact(T) = repr(T; context = :compact => true)
        @test compact(CString{:owned}) == "CString{:owned}"
        @test compact(CString{:borrowed}) == "CString{:borrowed}"
    end

    @testset "CString constructors" begin
        # There is no ownership-defaulting constructor.
        @test_throws MethodError CString(Int64(0), Ptr{UInt8}(0))
        @test_throws MethodError CString("hello")

        # Only :owned and :borrowed name an ownership.
        @test_throws(
            "ownership parameter must be :owned or :borrowed, got :mine",
            CString{:mine}(Int64(0), Ptr{UInt8}(0))
        )
        @test_throws(
            "ownership parameter must be :owned or :borrowed, got 1",
            CString{1}(Int64(0), Ptr{UInt8}(0))
        )
    end

    @testset "CString owning round-trip" begin
        s = CString{:owned}("hé\0llo")   # incl. multi-byte UTF-8 and an embedded NUL
        @test s isa CString{:owned}
        @test s.length == 7
        @test String(s) == "hé\0llo"
        Libc.free(s.data)                       # tests own the free

        empty = CString{:owned}("")
        @test empty.length == 0
        @test empty.data != C_NULL   # empty string still mallocs a real, freeable pointer
        @test String(empty) == ""
        Libc.free(empty.data)
    end

    @testset "CString AbstractString interface" begin
        buf = codeunits("hello")
        GC.@preserve buf begin
            s = CString{:borrowed}(Int64(length(buf)), pointer(buf))

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
            s = CString{:borrowed}(Int64(length(raw)), pointer(raw))
            @test ncodeunits(s) === 3
            @test codeunit(s, 2) === 0x00
            @test String(s) == "f\0o"
        end

        # Multi-byte UTF-8 ("café"): 4 characters, 5 bytes.
        utf8 = codeunits("café")
        GC.@preserve utf8 begin
            s = CString{:borrowed}(Int64(length(utf8)), pointer(utf8))
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
            a = CString{:borrowed}(Int64(length(a_buf)), pointer(a_buf))
            b = CString{:borrowed}(Int64(length(b_buf)), pointer(b_buf))
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
            m = CMatrix{:borrowed, Float64}(Int64(2), Int64(3), pointer(buf))

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

            # Methods inherited from AbstractArray.
            @test sum(m) === 21.0
            @test collect(m) == reshape(buf, 2, 3)

            # setindex! writes through to the backing buffer.
            m[1, 2] = 99.0  # linear slot 3
            @test buf[3] == 99.0
            @test_throws BoundsError (m[3, 1] = 0.0)
        end
    end

    @testset "CArray{T,3} interface" begin
        # 2 × 3 × 4 = 24 elements in column-major layout.
        buf = collect(1.0:24.0)
        GC.@preserve buf begin
            a = CArray{:borrowed, Float64, 3}((2, 3, 4), pointer(buf))

            @test a isa AbstractArray{Float64, 3}
            @test IndexStyle(typeof(a)) === IndexLinear()
            @test size(a) === (2, 3, 4)
            @test ndims(a) === 3
            @test length(a) === 24
            @test eltype(a) === Float64

            # Column-major linear ⇔ Cartesian.
            @test a[1, 1, 1] === 1.0
            @test a[2, 1, 1] === 2.0
            @test a[1, 2, 1] === 3.0
            @test a[1, 1, 2] === 7.0   # one full page (2*3) ahead of a[1,1,1]
            @test a[2, 3, 4] === 24.0
            @test a[7] === 7.0

            # Bounds checking on both index forms.
            @test_throws BoundsError a[0]
            @test_throws BoundsError a[25]
            @test_throws BoundsError a[3, 1, 1]
            @test_throws BoundsError a[1, 4, 1]
            @test_throws BoundsError a[1, 1, 5]

            # AbstractArray operations: sum, reshape comparison, and mutation.
            @test sum(a) === sum(1.0:24.0)
            @test collect(a) == reshape(buf, 2, 3, 4)

            a[1, 1, 2] = -1.0
            @test buf[7] == -1.0
            @test_throws BoundsError (a[3, 1, 1] = 0.0)
        end
    end

    @testset "CArray strided interface" begin
        # A CArray is a contiguous, column-major StridedArray.
        @test CArray{:borrowed, Float64, 2} <: DenseArray{Float64, 2}
        @test CMatrix{:owned, Float64} <: StridedMatrix{Float64}
        @test CVector{:borrowed, Float64} <: StridedVector{Float64}

        A = [1.0 2.0; 3.0 4.0; 5.0 6.0]
        GC.@preserve A begin
            c = CArray{:borrowed}(A)
            @test strides(c) === (1, 3)
            @test Base.elsize(typeof(c)) === sizeof(Float64)
            @test Base.unsafe_convert(Ptr{Float64}, c) === pointer(A)
            @test pointer(c) === pointer(A)
            @test pointer(c, 4) === pointer(A, 4)

            # A ccall expecting Ptr{T} accepts the carrier.
            dest = zeros(6)
            GC.@preserve dest begin
                cdest = CArray{:borrowed}(dest)
                ccall(
                    :memcpy, Ptr{Cvoid}, (Ptr{Float64}, Ptr{Float64}, Csize_t),
                    cdest, c, 6 * sizeof(Float64)
                )
            end
            @test dest == vec(A)
        end

        # BLAS operates on the buffers in place.
        B, C, D = rand(4, 3), rand(3, 5), zeros(4, 5)
        GC.@preserve B C D begin
            mul!(CArray{:borrowed}(D), CArray{:borrowed}(B), CArray{:borrowed}(C))
            @test D ≈ B * C
        end
        v = rand(8)
        GC.@preserve v begin
            cv = CArray{:borrowed}(v)
            @test dot(cv, cv) ≈ dot(v, v)
        end

        # The all-zero error-path carrier is a well-formed empty array.
        z = JLWInterop._zero_carrier(CArray{:owned, Float64, 2})
        @test size(z) == (0, 0)
        @test strides(z) === (1, 0)
        @test isempty(collect(z))
        @test sum(z) === 0.0
    end

    @testset "CArray aliasing" begin
        # Aliasing is keyed on the data pointer rather than carrier identity.
        v = collect(1.0:6.0)
        other = zeros(6)
        GC.@preserve v other begin
            c6 = CArray{:borrowed}(v)
            c23 = CMatrix{:borrowed, Float64}(2, 3, pointer(v))
            cother = CArray{:borrowed}(other)

            @test Base.dataids(c6) === (UInt(pointer(v)),)
            @test Base.mightalias(c6, c23)
            @test !Base.mightalias(c6, cother)

            # `unalias` copies a detected alias.
            u = Base.unalias(c23, c6)
            @test u isa Vector{Float64}
            @test u == v
            @test Base.unalias(cother, c6) === c6
        end
    end

    @testset "CArray layout" begin
        # C and Python emitters rely on this field layout.
        @test fieldnames(CArray) == (:dims, :data)

        @test fieldtype(CVector{:borrowed, Float64}, :dims) === NTuple{1, Int64}
        @test fieldtype(CVector{:borrowed, Float64}, :data) === Ptr{Float64}
        @test isbitstype(CVector{:borrowed, Float64})
        @test iszero(fieldoffset(CVector{:borrowed, Float64}, 1))
        @test fieldoffset(CVector{:borrowed, Float64}, 2) == 8
        @test sizeof(CVector{:borrowed, Float64}) == 16

        @test fieldtype(CMatrix{:owned, Float64}, :dims) === NTuple{2, Int64}
        @test fieldtype(CMatrix{:owned, Float64}, :data) === Ptr{Float64}
        @test isbitstype(CMatrix{:owned, Float64})
        @test iszero(fieldoffset(CMatrix{:owned, Float64}, 1))
        @test fieldoffset(CMatrix{:owned, Float64}, 2) == 16
        @test sizeof(CMatrix{:owned, Float64}) == 24

        @test fieldtype(CArray{:borrowed, Float64, 3}, :dims) === NTuple{3, Int64}
        @test isbitstype(CArray{:borrowed, Float64, 3})
        @test iszero(fieldoffset(CArray{:borrowed, Float64, 3}, 1))
        @test fieldoffset(CArray{:borrowed, Float64, 3}, 2) == 24
        @test sizeof(CArray{:borrowed, Float64, 3}) == 32

        # Ownership is part of the type, so the two flavors are distinct types
        # with identical layout.
        @test CVector{:owned, Float64} !== CVector{:borrowed, Float64}
        @test sizeof(CVector{:owned, Float64}) == sizeof(CVector{:borrowed, Float64})
    end

    @testset "CArray ABI names" begin
        # `juliac` writes the ABI JSON's struct names with
        # `repr(dt; context = :compact => true)`, and JuliaLibWrapping's
        # recognizer parses the ownership back out of that text. Aliases print
        # in preference to the raw spelling.
        compact(T) = repr(T; context = :compact => true)
        @test compact(CVector{:owned, Float64}) == "CVector{:owned, Float64}"
        @test compact(CMatrix{:borrowed, Float32}) == "CMatrix{:borrowed, Float32}"
        @test compact(CArray{:owned, Float64, 3}) == "CArray{:owned, Float64, 3}"
    end

    @testset "CArray constructors" begin
        # Tuple dimensions convert to Int64; the ownership parameter is
        # required at every entry point.
        a = CArray{:borrowed, Float64}((Int64(2), Int64(3)), Ptr{Float64}(0))
        @test a isa CMatrix{:borrowed, Float64}
        @test a.dims === (Int64(2), Int64(3))

        # `T` and `N` are both inferred from the pointer and dimensions.
        a2 = CArray{:borrowed}((2, 3), Ptr{Float64}(0))
        @test a2 isa CMatrix{:borrowed, Float64}
        @test a2.dims === (Int64(2), Int64(3))

        a3 = CArray{:owned, Float64, 2}((2, 3), Ptr{Float64}(0))
        @test a3 isa CMatrix{:owned, Float64}
        @test a3.dims === (Int64(2), Int64(3))

        # Scalar-form shortcuts for 1-D and 2-D.
        v = CVector{:borrowed, Float64}(Int64(4), Ptr{Float64}(0))
        @test v.dims === (Int64(4),)
        @test v.data === Ptr{Float64}(0)

        m = CMatrix{:owned, Float64}(2, 3, Ptr{Float64}(0))
        @test m.dims === (Int64(2), Int64(3))

        # There is no ownership-defaulting constructor.
        @test_throws MethodError CArray([1.0])
        @test_throws MethodError CVector{Float64}(1, Ptr{Float64}(0))

        # Only :owned and :borrowed name an ownership.
        @test_throws(
            "ownership parameter must be :owned or :borrowed, got :mine",
            CArray{:mine, Float64, 1}((Int64(1),), Ptr{Float64}(0))
        )
        @test_throws(
            "ownership parameter must be :owned or :borrowed, got 1",
            CArray{1, Float64, 1}((Int64(1),), Ptr{Float64}(0))
        )
    end

    @testset "CArray{:owned} allocates" begin
        # The array constructor allocates a column-major copy the consumer owns.
        src = [1.0 2.0; 3.0 4.0]  # 2x2, column-major
        a = CArray{:owned}(src)
        @test a isa CMatrix{:owned, Float64}
        @test a.dims === (Int64(2), Int64(2))
        @test collect(a) == src
        Libc.free(a.data)

        # 1-D.
        v = CArray{:owned}([10.0, 20.0, 30.0])
        @test v isa CVector{:owned, Float64}
        @test collect(v) == [10.0, 20.0, 30.0]
        Libc.free(v.data)

        # `CArray <: AbstractArray`, so the same constructor promotes a
        # borrowed carrier into an owning copy.
        buf = Float64[5.0, 6.0]
        GC.@preserve buf begin
            borrowed = CVector{:borrowed, Float64}(Int64(2), pointer(buf))
            @test collect(borrowed) == [5.0, 6.0]
            copied = CArray{:owned}(borrowed)
            @test copied isa CVector{:owned, Float64}
            @test copied.data !== borrowed.data
            @test collect(copied) == [5.0, 6.0]
            Libc.free(copied.data)
        end

        # The invalid-symbol rejection also covers the array-argument entry
        # point.
        @test_throws(
            "ownership parameter must be :owned or :borrowed, got :mine",
            CArray{:mine}([1.0, 2.0])
        )
    end

    @testset "CArray{:borrowed} aliases dense arrays" begin
        # `DenseArray` storage is already contiguous and column-major, so the
        # constructor can alias it: `data` is `pointer(A)` and no copy is made.
        # The caller keeps `A` alive while the carrier is in use.
        buf = Float64[1.0, 2.0, 3.0]
        GC.@preserve buf begin
            v = CArray{:borrowed}(buf)
            @test v isa CVector{:borrowed, Float64}
            @test v.dims === (Int64(3),)
            @test v.data === pointer(buf)
            # Genuine aliasing, in both directions.
            buf[2] = 20.0
            @test v[2] === 20.0
            v[3] = 30.0
            @test buf[3] === 30.0
        end

        M = [1.0 2.0; 3.0 4.0]
        GC.@preserve M begin
            m = CArray{:borrowed}(M)
            @test m isa CMatrix{:borrowed, Float64}
            @test m.dims === (Int64(2), Int64(2))
            @test collect(m) == M

            # Re-borrowing a carrier returns the same descriptor.
            @test CArray{:borrowed}(m) === m
        end

        # Borrowing an owned carrier aliases without transferring ownership.
        o = CArray{:owned}([1.0, 2.0])
        b = CArray{:borrowed}(o)
        @test b isa CVector{:borrowed, Float64}
        @test b.data === o.data
        @test b.dims === o.dims
        Libc.free(o.data)

        # Non-`DenseArray` storage cannot be aliased safely, even when it
        # happens to be contiguous: the layout guarantee lives in the type.
        src = collect(1.0:6.0)
        @test_throws(
            "only `DenseArray` storage (contiguous, column-major) can be aliased",
            CArray{:borrowed}(view(src, 2:2:6))
        )
        @test_throws(
            "only `DenseArray` storage (contiguous, column-major) can be aliased",
            CArray{:borrowed}(view(src, 1:6))
        )
        @test_throws(
            "only `DenseArray` storage (contiguous, column-major) can be aliased",
            CArray{:borrowed}(OffsetArray([1.0, 2.0], -1))
        )
    end

    @testset "CArray{:owned} from arrays with unconventional axes" begin
        # `size(A)` supplies `dims` and the values arrive in iteration order,
        # so arrays whose axes do not start at 1 copy correctly.
        o = OffsetArray([10.0, 20.0, 30.0], -1:1)
        v = CArray{:owned}(o)
        @test v.dims === (Int64(3),)
        @test size(v) == size(o)
        @test collect(v) == collect(o)
        Libc.free(v.data)

        o2 = OffsetArray([1.0 2.0; 3.0 4.0], 0:1, 5:6)
        m = CArray{:owned}(o2)
        @test m.dims === (Int64(2), Int64(2))
        @test size(m) == size(o2)
        @test collect(m) == collect(o2)
        Libc.free(m.data)

        # A non-contiguous view is densified by the copy.
        src = collect(1.0:6.0)
        w = CArray{:owned}(view(src, 2:2:6))
        @test w.dims === (Int64(3),)
        @test collect(w) == [2.0, 4.0, 6.0]
        Libc.free(w.data)
    end

    @testset "CStrArray layout" begin
        @test fieldnames(CStrArray{:owned}) === (:length, :data)
        @test fieldtype(CStrArray{:owned}, :length) === Int64
        @test fieldtype(CStrArray{:owned}, :data) === Ptr{CString{:owned}}
        @test isbitstype(CStrArray{:owned})
        @test iszero(fieldoffset(CStrArray{:owned}, 1))
        @test fieldoffset(CStrArray{:owned}, 2) == 8
        @test sizeof(CStrArray{:owned}) == 16

        # Ownership is part of the type, so the two flavors are distinct types
        # with identical layout.
        @test CStrArray{:owned} !== CStrArray{:borrowed}
        @test sizeof(CStrArray{:owned}) == sizeof(CStrArray{:borrowed})
    end

    @testset "CStrArray ABI names" begin
        # `juliac` writes the ABI JSON's struct names with
        # `repr(dt; context = :compact => true)`, and JuliaLibWrapping's
        # recognizer parses the ownership back out of that text.
        compact(T) = repr(T; context = :compact => true)
        @test compact(CStrArray{:owned}) == "CStrArray{:owned}"
        @test compact(CStrArray{:borrowed}) == "CStrArray{:borrowed}"
    end

    @testset "CStrArray constructors" begin
        a = CStrArray{:borrowed}(Int64(0), Ptr{CString{:borrowed}}(0))
        @test a isa CStrArray{:borrowed}
        @test a.length === Int64(0)

        # There is no ownership-defaulting constructor, and no Julia-side
        # borrowed-from-collection constructor.
        @test_throws MethodError CStrArray(["x"])
        @test_throws MethodError CStrArray{:borrowed}(["x"])

        # Only :owned and :borrowed name an ownership.
        @test_throws(
            "ownership parameter must be :owned or :borrowed, got :mine",
            CStrArray{:mine}(Int64(0), Ptr{CString{:owned}}(0))
        )
        @test_throws(
            "ownership parameter must be :owned or :borrowed, got 1",
            CStrArray{1}(Int64(0), Ptr{CString{:owned}}(0))
        )
    end

    @testset "CStrArray round-trip" begin
        v = ["hello", "wörld", "", "a\0b"]   # incl. UTF-8, empty, and embedded NUL
        a = CStrArray{:owned}(v)
        @test a isa CStrArray{:owned}
        @test a.length == 4
        @test unsafe_load(a.data, 3).data != C_NULL   # empty string still mallocs a real, freeable pointer
        @test Vector{String}(a) == v
        JLWInterop._free_strings(a.data, a.length)   # tests own the free
        @test Vector{String}(CStrArray{:owned}(String[])) == String[]

        # Conversion copies regardless of ownership.
        a2 = CStrArray{:owned}(["p", "q"])
        borrowed = CStrArray{:borrowed}(a2.length, a2.data)
        @test Vector{String}(borrowed) == ["p", "q"]
        JLWInterop._free_strings(a2.data, a2.length)
    end

    @testset "CStrArray{:owned} from other AbstractVector{<:AbstractString}" begin
        # Preserve iteration order across axes and element types.
        o = OffsetArray(["hello", "wörld", "a\0b"], -1)
        a = CStrArray{:owned}(o)
        @test a.length == 3
        @test Vector{String}(a) == collect(o)
        JLWInterop._free_strings(a.data, a.length)

        v = ["the", "quick", "brown", "fox"]
        b = CStrArray{:owned}(view(v, 2:3))   # view of a Vector{String}
        @test Vector{String}(b) == ["quick", "brown"]
        JLWInterop._free_strings(b.data, b.length)
    end

    @testset "CStrArray AbstractVector interface" begin
        a = CStrArray{:owned}(["hello", "wörld", ""])
        @test a isa AbstractVector{CString{:owned}}
        @test IndexStyle(typeof(a)) === IndexLinear()
        @test size(a) == (3,)
        @test length(a) == 3
        @test eltype(a) === CString{:owned}

        # Indexing and iteration yield the descriptors in place.
        @test a[1] isa CString{:owned}
        @test String(a[2]) == "wörld"
        @test String.(a) == ["hello", "wörld", ""]
        @test map(ncodeunits, a) == [5, 6, 0]
        @test_throws BoundsError a[0]
        @test_throws BoundsError a[4]

        # Read-only: replacing a descriptor would leak the buffer it points to.
        @test_throws CanonicalIndexError a[1] = a[2]

        # `collect` copies descriptors, not buffers, so the elements alias.
        descs = collect(a)
        @test descs isa Vector{CString{:owned}}
        @test descs[1].data === a[1].data

        JLWInterop._free_strings(a.data, a.length)
    end

    @testset "CDict layout" begin
        @test fieldnames(CDict{:owned, Float64}) === (:length, :keys, :values)
        @test fieldtype(CDict{:owned, Float64}, :length) === Int64
        @test fieldtype(CDict{:owned, Float64}, :keys) === Ptr{CString{:owned}}
        @test fieldtype(CDict{:owned, Float64}, :values) === Ptr{Float64}
        @test isbitstype(CDict{:owned, Float64})
        @test iszero(fieldoffset(CDict{:owned, Float64}, 1))
        @test fieldoffset(CDict{:owned, Float64}, 2) == 8
        @test fieldoffset(CDict{:owned, Float64}, 3) == 16
        @test sizeof(CDict{:owned, Float64}) == 24

        @test CDict{:owned, Float64} !== CDict{:borrowed, Float64}
        @test sizeof(CDict{:owned, Float64}) == sizeof(CDict{:borrowed, Float64})
    end

    @testset "CDict ABI names" begin
        compact(T) = repr(T; context = :compact => true)
        @test compact(CDict{:owned, Float64}) == "CDict{:owned, Float64}"
        @test compact(CDict{:borrowed, Int32}) == "CDict{:borrowed, Int32}"
    end

    @testset "CDict constructors" begin
        # `V` is inferred from the value pointer.
        c = CDict{:borrowed}(Int64(0), Ptr{CString{:borrowed}}(0), Ptr{Float64}(0))
        @test c isa CDict{:borrowed, Float64}

        # There is no ownership-defaulting constructor, and no Julia-side
        # borrowed-from-collection constructor.
        @test_throws MethodError CDict(Dict("a" => 1.5))
        @test_throws MethodError CDict{:borrowed}(Dict("a" => 1.5))

        @test_throws(
            "ownership parameter must be :owned or :borrowed, got :mine",
            CDict{:mine, Float64}(Int64(0), Ptr{CString{:owned}}(0), Ptr{Float64}(0))
        )
        @test_throws(
            "ownership parameter must be :owned or :borrowed, got 1",
            CDict{1, Float64}(Int64(0), Ptr{CString{:owned}}(0), Ptr{Float64}(0))
        )
    end

    @testset "CDict round-trip and allowlist" begin
        d = Dict("a" => 1.5, "b" => -2.0, "c\0d" => 3.0, "" => 4.0)
        c = CDict{:owned}(d)
        @test c isa CDict{:owned, Float64}
        @test c.length == 4
        empty_idx = findfirst(i -> iszero(unsafe_load(c.keys, i).length), 1:c.length)
        @test unsafe_load(c.keys, empty_idx).data != C_NULL   # empty key still mallocs a real, freeable pointer
        @test Dict{String, Float64}(c) == d
        JLWInterop._free_strings(c.keys, c.length)
        Libc.free(c.values)
        @test_throws MethodError CDict{:owned}(Dict("x" => 1.0im))   # ComplexF64 not allowlisted

        # Conversion copies regardless of ownership.
        c2 = CDict{:owned}(Dict("b" => 2.5))
        borrowed = CDict{:borrowed}(c2.length, c2.keys, c2.values)
        @test Dict{String, Float64}(borrowed) == Dict("b" => 2.5)
        JLWInterop._free_strings(c2.keys, c2.length)
        Libc.free(c2.values)
    end

    @testset "CDict{:owned} from other AbstractDict{<:AbstractString,V}" begin
        d = Dict(SubString("aa", 1, 1) => 1.5, SubString("bb", 1, 1) => -2.0)
        c = CDict{:owned}(d)
        @test c isa CDict{:owned, Float64}
        @test c.length == 2
        @test Dict{String, Float64}(c) == Dict("a" => 1.5, "b" => -2.0)
        JLWInterop._free_strings(c.keys, c.length)
        Libc.free(c.values)
    end

    @testset "an owning constructor releases partial work when an element throws" begin
        # Reading an undefined element throws partway through the loop, with
        # the array and the first 100 elements already malloc'd. `mallinfo2`
        # measures what `Libc.malloc` still holds, so the counter must come
        # back to where it started. `CDict{:owned}` unwinds the same way; its
        # keys come from the dictionary, so it has no comparable trigger.
        if !Sys.islinux()
            @test_skip "mallinfo2 is glibc-only"
        else
            uordblks() = Int(ccall(:mallinfo2, NTuple{10, Csize_t}, ())[8])
            v = Vector{String}(undef, 101)
            v[1:100] .= "small"          # v[101] is left undefined

            @test_throws UndefRefError CStrArray{:owned}(v)   # also compiles it

            # The runtime itself allocates one-time state (compiled code,
            # exception machinery, allocator internals) at unpredictable
            # points, so any single window can see growth that is not the
            # constructor's. A leak here grows every window — about 2 KiB per
            # call, ~200 KiB per window — so it is enough that one window
            # holds the counter still.
            settled = false
            GC.gc()
            before = uordblks()
            for _ in 1:5
                for _ in 1:100
                    @test_throws UndefRefError CStrArray{:owned}(v)
                end
                GC.gc()
                after = uordblks()
                settled = after == before
                settled && break
                before = after
            end
            @test settled
        end
    end

    @testset "COpt" begin
        @test get(COpt(3.5), nothing) === 3.5
        @test get(COpt(3.5), 0.0) === 3.5
        o = COpt{Float64}(nothing)
        @test o.has_value == Int32(0) && o.value === 0.0     # zero-filled absent branch
        @test isnothing(get(o, nothing))
        @test get(o, 0.0) === 0.0
    end

    @testset "JLWResult" begin
        r = jlw_ok(3.5)
        @test r isa JLWResult{Float64}
        @test iszero(r.status.code)
        @test r.value == 3.5

        e = JLWInterop.jlw_error(1, "boom", Float64)
        @test e.status.code == Int32(1)
        @test iszero(e.value)
        @test e.status.message[1:4] == (UInt8('b'), UInt8('o'), UInt8('o'), UInt8('m'))
        @test iszero(e.status.message[5])

        # zero carriers for every carrier type
        @test iszero(JLWInterop._zero_carrier(Int64))
        @test JLWInterop._zero_carrier(CString{:owned}).length == Int64(0)
        @test JLWInterop._zero_carrier(CStrArray{:owned}).data == Ptr{CString{:owned}}(C_NULL)
        @test JLWInterop._zero_carrier(CDict{:owned, Float64}).keys == Ptr{CString{:owned}}(C_NULL)
        @test JLWInterop._zero_carrier(COpt{Float64}).has_value == Int32(0)
        @test JLWInterop._zero_carrier(CArray{:owned, Float64, 2}).data == Ptr{Float64}(C_NULL)
    end

    @testset "@api scalars and strings" begin
        m = Module(:ApiTestA)
        Core.eval(m, :(using JLWInterop))
        Core.eval(
            m, quote
                function twice(x::Float64)
                    2x
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api "Double it." twice(x::Float64)::Float64
            )
        )
        @test Core.eval(m, :(twice(2.0))) == 4.0
        e = only(JLWInterop.api_entries(m))
        @test e.name === :twice
        @test e.symbol == "ApiTestA_twice"
        @test e.args == [(:x, Float64)]
        @test isempty(e.kwargs)
        @test e.ret === Float64
        @test e.doc == "Double it."

        # String maps to CString as an argument (the return direction is
        # covered by "@api String argument borrows, String return owns").
        m2 = Module(:ApiTestB)
        Core.eval(m2, :(using JLWInterop))
        Core.eval(
            m2, quote
                function len(s::String)
                    Int64(ncodeunits(s))
                end
            end
        )
        Core.eval(
            m2, :(
                JLWInterop.@api len(s::String)::Int64
            )
        )
        @test only(JLWInterop.api_entries(m2)).args == [(:s, String)]

        # An unsupported type is rejected with the argument name in the message.
        @test_throws "argument 'd' of type Dict{Int64, Int64} has no carrier mapping" Core.eval(
            m2, :(
                JLWInterop.@api nope(d::Dict{Int, Int})::Int64
            )
        )
    end

    @testset "carrier_type rejects non-scalar payloads" begin
        # The carriers hold elements as raw bytes behind a pointer, so a
        # non-bits payload has no mapping rather than a reinterpreted one.
        @test isnothing(JLWInterop.carrier_type(Matrix{String}))
        @test isnothing(JLWInterop.carrier_type(Vector{Any}))
        @test isnothing(JLWInterop.carrier_type(Dict{String, Vector{Int}}))
        @test isnothing(JLWInterop.carrier_type(Union{String, Nothing}))
        @test isnothing(JLWInterop.carrier_return_type(Matrix{String}))
        @test isnothing(JLWInterop.carrier_return_type(Vector{Any}))
        @test isnothing(JLWInterop.carrier_return_type(Dict{String, Vector{Int}}))
        # Vector{String} keeps its own copying carrier.
        @test JLWInterop.carrier_type(Vector{String}) === CStrArray{:borrowed}
        @test JLWInterop.carrier_return_type(Vector{String}) === CStrArray{:owned}

        m = Module(:ApiTestJ)
        Core.eval(m, :(using JLWInterop))
        @test_throws "argument 'a' of type Matrix{String} has no carrier mapping" Core.eval(
            m, :(
                JLWInterop.@api nonbits(a::Matrix{String})::Int64
            )
        )
    end

    @testset "carrier_type rejects a union of scalars" begin
        # `_API_SCALARS` is itself a Union, so `T <: _API_SCALARS` accepts a
        # union OF scalars. `CArray`/`CDict` are isbits whatever the payload
        # (they hold only a pointer), so the isbits check on the carrier does
        # not catch it and the failure would surface as a juliac or
        # `unsafe_wrap` error much later.
        U = Union{Int64, Float64}
        for f in (JLWInterop.carrier_type, JLWInterop.carrier_return_type)
            @test isnothing(f(Vector{U}))
            @test isnothing(f(Matrix{U}))
            @test isnothing(f(Dict{String, U}))
        end
        @test isnothing(JLWInterop.carrier_type(U))
        @test isnothing(JLWInterop.carrier_type(Union{Int64, Float64, Nothing}))
        # The concrete forms still map.
        @test JLWInterop.carrier_type(Vector{Int64}) === CArray{:borrowed, Int64, 1}
        @test JLWInterop.carrier_type(Dict{String, Int64}) === CDict{:borrowed, Int64}
        @test JLWInterop.carrier_type(Union{Int64, Nothing}) === COpt{Int64}

        m = Module(:ApiTestUnion)
        Core.eval(m, :(using JLWInterop))
        Core.eval(m, :(const U = Union{Int64, Float64}))
        @test_throws "argument 'a' of type Vector{Union{Float64, Int64}} has no carrier mapping" Core.eval(
            m, :(
                JLWInterop.@api unionarg(a::Vector{U})::Int64
            )
        )
        @test_throws "return type Vector{Union{Float64, Int64}} has no carrier mapping" Core.eval(
            m, :(
                JLWInterop.@api unionret(n::Int64)::Vector{U}
            )
        )
    end

    @testset "@api rejects a carrier that is not isbits" begin
        # A library may register any carrier it likes, but the error boundary
        # returns a zero-filled one when the body throws, and `_zero_carrier`
        # can only zero an isbits type. Without this check the throw lands
        # inside the wrapper's `catch`, which aborts a trimmed library.
        m = Module(:ApiTestNonBits)
        Core.eval(m, :(using JLWInterop))
        Core.eval(
            m, :(
                mutable struct Boxed
                    x::Int64
                end
            )
        )
        Core.eval(
            m, :(
                JLWInterop.carrier_type(::Type{Boxed}) = Boxed;
                JLWInterop.carrier_return_type(::Type{Boxed}) = Boxed;
                JLWInterop.to_carrier(b::Boxed) = b;
                JLWInterop.from_carrier(::Type{Boxed}, c::Boxed) = c
            )
        )
        @test !isbitstype(Core.eval(m, :Boxed))
        @test_throws(
            "argument 'b' of type Main.ApiTestNonBits.Boxed maps to the carrier " *
                "Main.ApiTestNonBits.Boxed, which is not isbits",
            Core.eval(
                m, :(
                    JLWInterop.@api takes(b::Boxed)::Int64
                )
            )
        )
        @test_throws(
            "return type Main.ApiTestNonBits.Boxed maps to the carrier",
            Core.eval(
                m, :(
                    JLWInterop.@api gives(x::Int64)::Boxed
                )
            )
        )
        # The reason travels with the message: nothing else explains why an
        # isbits carrier is required.
        @test_throws(
            "only an isbits carrier can be zeroed",
            Core.eval(
                m, :(
                    JLWInterop.@api gives2(x::Int64)::Boxed
                )
            )
        )
    end

    @testset "@api rejects shapes it cannot take apart" begin
        m = Module(:ApiTestK)
        Core.eval(m, :(using JLWInterop))
        # A `where` clause: the return annotation is present, so the message
        # must name the `where`, not a missing `::Ret`.
        err = try
            Core.eval(
                m, :(
                    JLWInterop.@api generic(x::T)::T where {T}
                )
            )
            nothing
        catch e
            e
        end
        @test err isa LoadError
        @test occursin("where", err.error.msg)

        # A body, in either form: `@api` declares a signature and defines
        # nothing, so both are rejected.
        for body in (
                :(JLWInterop.@api f(x::Int64)::Int64 = x),
                :(
                    JLWInterop.@api function f(x::Int64)::Int64
                        x
                    end
                ),
            )
            err = try
                Core.eval(m, body)
                nothing
            catch e
                e
            end
            @test err isa LoadError
            @test occursin("does not define a function", err.error.msg)
        end

        # Varargs in either position: a C entry point has a fixed arity, so
        # the message names varargs rather than a missing annotation.
        @test_throws "varargs `xs::Int64...` are not supported" Core.eval(
            m, :(JLWInterop.@api vararg(xs::Int64...)::Int64)
        )
        @test_throws "varargs `kwargs...` are not supported" Core.eval(
            m, :(JLWInterop.@api kwsplat(x::Int64; kwargs...)::Int64)
        )
    end

    @testset "@api rejects a name it cannot call" begin
        # A declaration names an existing function, so both a typo and a
        # signature the function cannot serve are expansion errors rather than
        # a missing method when the library is compiled.
        m = Module(:ApiTestCallable)
        Core.eval(m, :(using JLWInterop))
        Core.eval(
            m, quote
                twice(x::Float64) = 2x
            end
        )

        err = try
            Core.eval(m, :(JLWInterop.@api twiceee(x::Float64)::Float64))
            nothing
        catch e
            e
        end
        @test err isa LoadError
        @test occursin("`twiceee` is not defined here", err.error.msg)

        # Defined, but not for these argument types.
        err = try
            Core.eval(m, :(JLWInterop.@api twice(s::String)::Float64))
            nothing
        catch e
            e
        end
        @test err isa LoadError
        @test occursin("no method twice(String)", err.error.msg)

        # Defined, but not with this keyword.
        err = try
            Core.eval(m, :(JLWInterop.@api twice(x::Float64; k::Int64 = 1)::Float64))
            nothing
        catch e
            e
        end
        @test err isa LoadError
        @test occursin("no method twice(Float64; k)", err.error.msg)

        # The signature it can serve is accepted.
        Core.eval(m, :(JLWInterop.@api twice(x::Float64)::Float64))
        @test only(JLWInterop.api_entries(m)).symbol == "ApiTestCallable_twice"
    end

    @testset "@api helpers: unions, escapes, docstrings" begin
        # `_api_opt_inner` recognizes an optional in either union order, and
        # declines anything that is not one.
        @test JLWInterop._api_opt_inner(Union{Float64, Nothing}) === Float64
        @test JLWInterop._api_opt_inner(Union{Nothing, Float64}) === Float64
        @test isnothing(JLWInterop._api_opt_inner(Union{Float64, Int64}))
        @test isnothing(JLWInterop._api_opt_inner(Float64))
        @test isnothing(JLWInterop._api_opt_inner(Nothing))

        # Every escape the sidecar writer produces, including the `\uXXXX`
        # form for a control byte with no shorthand.
        esc(s) = JLWInterop._json_str(s)
        @test esc("a\"b") == "\"a\\\"b\""
        @test esc("a\\b") == "\"a\\\\b\""
        @test esc("a\nb\rc\td") == "\"a\\nb\\rc\\td\""
        @test esc("a\x01b") == "\"a\\u0001b\""
        @test esc("a\0b") == "\"a\\u0000b\""   # embedded NUL, never a raw byte

        # More than a docstring and a signature.
        m = Module(:ApiTestArity)
        Core.eval(m, :(using JLWInterop))
        Core.eval(
            m, quote
                twice(x::Float64) = 2x
            end
        )
        err = try
            Core.eval(m, :(JLWInterop.@api "a" "b" twice(x::Float64)::Float64))
            nothing
        catch e
            e
        end
        @test err isa LoadError
        @test occursin("[docstring] f(args...)::Ret", err.error.msg)

        # A docstring argument with interpolation reaches the macro as an
        # Expr, not a String, and is rejected by name.
        interp = Meta.parse("JLWInterop.@api \"doc \$x\" twice(x::Float64)::Float64")
        @test_throws "the docstring argument must be a string literal" Core.eval(m, interp)
    end

    @testset "@api helper predicates" begin
        # These are reached through macro expansion elsewhere, but they are
        # small enough to pin directly.
        @test isnothing(JLWInterop.carrier_type(Nothing))
        @test JLWInterop.carrier_return_type(Nothing) === JLWInterop.carrier_type(Nothing)

        valid = JLWInterop._api_valid_default
        @test valid(3) && valid(2.5) && valid(true) && valid("a")
        @test valid(:nothing)
        @test !valid(:other)
        @test valid(:(-1)) && valid(:(-1.5))
        @test !valid(:(sqrt(2)))
        @test !valid(1 => 2)      # anything else

        jsonval = JLWInterop._json_value
        @test jsonval(nothing) == "null"
        @test jsonval(true) == "true" && jsonval(false) == "false"
        @test jsonval(3) == "3"
        @test jsonval("a") == "\"a\""
        @test_throws "no JSON representation" jsonval(NaN)
    end

    @testset "@api falls back to the Julia docstring" begin
        # Without a docstring argument the declaration carries the function's
        # own, so a foreign caller reads what a Julia caller reads.
        m = Module(:ApiTestDocFallback)
        Core.eval(m, :(using JLWInterop))
        Core.eval(
            m, Expr(
                :macrocall, GlobalRef(Core, Symbol("@doc")), LineNumberNode(0),
                "Doubles it.\n", :(twice(x::Float64) = 2x)
            )
        )
        Core.eval(
            m, quote
                plain(x::Float64) = x
            end
        )
        Core.eval(m, :(JLWInterop.@api twice(x::Float64)::Float64))
        Core.eval(m, :(JLWInterop.@api plain(x::Float64)::Float64))
        entries = Dict(e.name => e.doc for e in JLWInterop.api_entries(m))
        @test entries[:twice] == "Doubles it."
        @test entries[:plain] == ""

        # A docstring on the function rather than on a method is filed under
        # no signature, so the lookup falls back to the first one recorded.
        Core.eval(
            m, Expr(
                :macrocall, GlobalRef(Core, Symbol("@doc")), LineNumberNode(0),
                "On the function.\n", :(function quart end)
            )
        )
        Core.eval(
            m, quote
                quart(x::Float64) = 4x
            end
        )
        Core.eval(m, :(JLWInterop.@api quart(x::Float64)::Float64))
        @test only(e.doc for e in JLWInterop.api_entries(m) if e.name === :quart) ==
            "On the function."
        # An explicit argument wins over the Julia docstring.
        Core.eval(
            m, quote
                thrice(x::Float64) = 3x
            end
        )
        Core.eval(m, :(JLWInterop.@api "For callers." thrice(x::Float64)::Float64))
        @test only(e.doc for e in JLWInterop.api_entries(m) if e.name === :thrice) ==
            "For callers."
    end

    @testset "@api reports a SubString message" begin
        # `ErrorException.msg` is typed `AbstractString`, so a `SubString` is
        # as legitimate as a `String` and the wrapper has to narrow to both.
        status_message(st) = String(collect(Iterators.takewhile(!iszero, st.message)))
        m = Module(:ApiTestSubStr)
        Core.eval(m, :(using JLWInterop))
        Core.eval(
            m, quote
                sliced(x::Int64) = throw(ErrorException(SubString("the tail end", 5)))
            end
        )
        Core.eval(m, :(JLWInterop.@api sliced(x::Int64)::Int64))
        r = Core.eval(m, :(ApiTestSubStr_sliced(1)))
        @test r.status.code == JLWInterop._API_ERROR_CODES.generic
        @test status_message(r.status) == "tail end"

        # Any other AbstractString in `msg` cannot be converted trim-safely,
        # so the wrapper reports the exception's type name instead.
        gs = Test.GenericString("odd")
        Core.eval(m, :(exotic(x::Int64) = throw(ErrorException($gs))))
        Core.eval(m, :(JLWInterop.@api exotic(x::Int64)::Int64))
        r = Core.eval(m, :(ApiTestSubStr_exotic(1)))
        @test r.status.code == JLWInterop._API_ERROR_CODES.generic
        @test status_message(r.status) == "ErrorException"
    end

    @testset "@api applies the declared return type" begin
        # The declared type, not the callee's, is the boundary contract. The
        # conversion runs inside the `try`: a convertible return converts, and
        # one the declared type cannot represent reports an ordinary error
        # instead of failing in the wrapper's own return conversion, which the
        # `catch` cannot reach.
        status_message(st) = String(collect(Iterators.takewhile(!iszero, st.message)))
        m = Module(:ApiTestRetAs)
        Core.eval(m, :(using JLWInterop))
        Core.eval(
            m, quote
                narrower(n::Int64) = Float32[1.5f0, 2.5f0][1:n]
                fractional(x::Float64) = x / 2
                flat(x::Float64) = [x]
            end
        )
        Core.eval(m, :(JLWInterop.@api narrower(n::Int64)::Vector{Float64}))
        Core.eval(m, :(JLWInterop.@api fractional(x::Float64)::Int64))
        Core.eval(m, :(JLWInterop.@api flat(x::Float64)::Matrix{Float64}))

        # A `Vector{Float32}` return converts to the declared `Vector{Float64}`.
        r = Core.eval(m, :(ApiTestRetAs_narrower(2)))
        @test iszero(r.status.code)
        @test r.value isa CVector{:owned, Float64}
        @test unsafe_load(r.value.data, 1) === 1.5
        @test unsafe_load(r.value.data, 2) === 2.5
        Libc.free(r.value.data)

        # A value the declared type cannot represent is caught inside the
        # `try` and reported under the inexact code.
        r = Core.eval(m, :(ApiTestRetAs_fractional(3.0)))
        @test r.status.code == JLWInterop._API_ERROR_CODES.inexact
        @test iszero(r.value)
        @test status_message(r.status) == "InexactError"

        # The same declaration succeeds when the value is representable.
        r = Core.eval(m, :(ApiTestRetAs_fractional(4.0)))
        @test iszero(r.status.code)
        @test r.value === Int64(2)

        # A shape the declared type has no conversion for is also caught
        # inside the `try`, reported by the exception's type name.
        r = Core.eval(m, :(ApiTestRetAs_flat(1.0)))
        @test r.status.code == JLWInterop._API_ERROR_CODES.generic
        @test iszero(r.value.dims[1]) && iszero(r.value.dims[2])
        @test status_message(r.status) == "MethodError"
    end

    @testset "@api String argument borrows, String return owns" begin
        # The two directions take different carriers: an argument reads the
        # caller's bytes, a return hands over a copy the caller frees.
        m = Module(:ApiTestStrRet)
        Core.eval(m, :(using JLWInterop))
        Core.eval(
            m, quote
                function shout(s::String)
                    return uppercase(s)
                end
            end
        )
        Core.eval(m, :(JLWInterop.@api shout(s::String)::String))

        @test JLWInterop.carrier_type(String) === CString{:borrowed}
        @test JLWInterop.carrier_return_type(String) === CString{:owned}
        e = only(JLWInterop.api_entries(m))
        @test e.args == [(:s, String)]
        @test e.ret === String

        buf = Vector{UInt8}(codeunits("héllo"))
        GC.@preserve buf begin
            borrowed = CString{:borrowed}(Int32(length(buf)), pointer(buf))
            r = Core.eval(m, :(ApiTestStrRet_shout($borrowed)))
            @test iszero(r.status.code)
            @test String(r.value) == "HÉLLO"
            # The return is a fresh allocation, not the argument's buffer.
            @test r.value.data != borrowed.data
            Libc.free(r.value.data)
        end
    end


    @testset "@api needs only the macro in scope" begin
        # `using JLWInterop: @api` brings in the macro without the module
        # name, so the expansion has to refer to JLWInterop by value.
        m = Module(:ApiTestScope)
        Core.eval(m, :(using JLWInterop: @api))
        Core.eval(
            m, quote
                twice(x::Float64) = 2x
            end
        )
        Core.eval(m, :(@api twice(x::Float64)::Float64))
        @test !isdefined(m, :JLWInterop)
        @test only(JLWInterop.api_entries(m)).symbol == "ApiTestScope_twice"
        r = Core.eval(m, :(ApiTestScope_twice(2.5)))
        @test iszero(r.status.code)
        @test r.value == 5.0
    end

    @testset "the registry belongs to the declaring module" begin
        # The registry has to live in the annotated module so that a
        # precompiled package carries its entries in its own cache file.
        m = Module(:ApiTestReg)
        Core.eval(m, :(using JLWInterop))
        @test !isdefined(m, JLWInterop._REGISTRY_NAME)
        Core.eval(
            m, quote
                one(x::Float64) = x
            end
        )
        Core.eval(m, :(JLWInterop.@api one(x::Float64)::Float64))
        @test isdefined(m, JLWInterop._REGISTRY_NAME)
        @test getglobal(m, JLWInterop._REGISTRY_NAME) isa Vector{JLWInterop.ApiEntry}

        # A nested module keeps its own, and a walk from the parent finds both.
        Core.eval(
            m, :(
                module Inner
                using JLWInterop
                two(x::Int64) = x
                JLWInterop.@api two(x::Int64)::Int64
                end
            )
        )
        syms = [e.symbol for e in JLWInterop.api_entries(m)]
        @test sort(syms) == ["ApiTestReg_Inner_two", "ApiTestReg_one"]
        @test [e.symbol for e in JLWInterop.api_entries(getglobal(m, :Inner))] ==
            ["ApiTestReg_Inner_two"]

        # One signature per name: the second declaration claims a taken symbol.
        @test_throws "already an API entry point" Core.eval(
            m, :(JLWInterop.@api one(x::Float64)::Float64)
        )
    end
    @testset "@api type table" begin
        m = Module(:ApiTestC)
        Core.eval(m, :(using JLWInterop))
        Core.eval(
            m, quote
                function up(v::Vector{String})
                    uppercase.(v)
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api up(v::Vector{String})::Vector{String}
            )
        )
        Core.eval(
            m, quote
                function total(d::Dict{String, Float64})
                    sum(values(d); init = 0.0)
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api total(d::Dict{String, Float64})::Float64
            )
        )
        Core.eval(
            m, quote
                function maybe(x::Union{Float64, Nothing})
                    isnothing(x) ? nothing : 2x
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api maybe(x::Union{Float64, Nothing})::Union{Float64, Nothing}
            )
        )
        Core.eval(
            m, quote
                function scale(a::Vector{Float64})
                    2 .* a
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api scale(a::Vector{Float64})::Vector{Float64}
            )
        )
        Core.eval(
            m, quote
                function shout(s::String)
                    nothing
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api shout(s::String)::Nothing
            )
        )
        syms = [e.symbol for e in JLWInterop.api_entries(m)]
        @test syms == ["ApiTestC_up", "ApiTestC_total", "ApiTestC_maybe", "ApiTestC_scale", "ApiTestC_shout"]
        @test JLWInterop.carrier_type(Vector{String}) === CStrArray{:borrowed}
        @test JLWInterop.carrier_type(Dict{String, Float64}) === CDict{:borrowed, Float64}
        @test JLWInterop.carrier_type(Union{Float64, Nothing}) === COpt{Float64}
        @test JLWInterop.carrier_type(Vector{Float64}) === CArray{:borrowed, Float64, 1}
        @test JLWInterop.carrier_return_type(Vector{Float64}) === CArray{:owned, Float64, 1}
        @test JLWInterop.carrier_return_type(Dict{String, Float64}) === CDict{:owned, Float64}
        # The CArray return method excludes a String payload, so without its
        # own method Vector{String} would fall through to the carrier_type
        # fallback and come back :borrowed — the wrong ownership for a return.
        @test JLWInterop.carrier_return_type(Vector{String}) === CStrArray{:owned}
        @test last(JLWInterop.api_entries(m)).ret === Nothing

        # Array arguments are zero-copy views: mutation is visible through the carrier.
        A = [1.0, 2.0, 3.0]
        c = JLWInterop.to_carrier(A)            # CArray{:owned, Float64, 1}
        v = JLWInterop.from_carrier(
            Vector{Float64}, CArray{:borrowed, Float64, 1}(c.dims, c.data)
        )
        v[1] = 9.0
        @test unsafe_load(c.data) == 9.0
        Libc.free(c.data)

        # COpt round-trips.
        r = JLWInterop.from_carrier(Union{Float64, Nothing}, JLWInterop.to_carrier_opt(Float64, nothing))
        @test isnothing(r)
        # Value-present branch: `to_carrier_opt` must not route through the
        # parameterized `COpt{T}(x)` constructor, which only has a `::Nothing`
        # method and would throw a MethodError at the boundary.
        r2 = JLWInterop.from_carrier(Union{Float64, Nothing}, JLWInterop.to_carrier_opt(Float64, 3.0))
        @test r2 === 3.0
    end

    @testset "@api generated wrapper calls" begin
        # The generated `Base.@ccallable` wrapper is an ordinary Julia
        # function, so each type-table row and both error paths can be
        # exercised by calling it with carriers.
        status_message(st) = String(collect(Iterators.takewhile(!iszero, st.message)))

        m = Module(:ApiCall)
        Core.eval(m, :(using JLWInterop))
        Core.eval(
            m, quote
                function twice(x::Float64)
                    2x
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api twice(x::Float64)::Float64
            )
        )
        Core.eval(
            m, quote
                function len(s::String)
                    Int64(ncodeunits(s))
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api len(s::String)::Int64
            )
        )
        Core.eval(
            m, quote
                function up(v::Vector{String})
                    uppercase.(v)
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api up(v::Vector{String})::Vector{String}
            )
        )
        Core.eval(
            m, quote
                function total(d::Dict{String, Float64})
                    sum(values(d); init = 0.0)
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api total(d::Dict{String, Float64})::Float64
            )
        )
        Core.eval(
            m, quote
                function mk(n::Int64)
                    Dict(string("k", i) => Float64(i) for i in 1:n)
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api mk(n::Int64)::Dict{String, Float64}
            )
        )
        Core.eval(
            m, quote
                function maybe(x::Union{Float64, Nothing})
                    isnothing(x) ? nothing : 2x
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api maybe(x::Union{Float64, Nothing})::Union{Float64, Nothing}
            )
        )
        Core.eval(
            m, quote
                function scale(a::Vector{Float64}; factor::Float64 = 2.0)
                    factor .* a
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api scale(a::Vector{Float64}; factor::Float64 = 2.0)::Vector{Float64}
            )
        )
        Core.eval(
            m, quote
                function check(x::Float64)
                    x > 0 || error("not positive")
                    nothing
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api check(x::Float64)::Nothing
            )
        )
        Core.eval(
            m, quote
                function boom(x::Int64)
                    error("boom $x")
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api boom(x::Int64)::Int64
            )
        )
        Core.eval(
            m, quote
                function argue(x::Int64)
                    throw(ArgumentError("bad argument"))
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api argue(x::Int64)::Int64
            )
        )
        Core.eval(
            m, quote
                function mismatch(x::Int64)
                    throw(DimensionMismatch("shapes differ"))
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api mismatch(x::Int64)::Int64
            )
        )
        Core.eval(
            m, quote
                function outside(x::Int64)
                    throw(DomainError(x))
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api outside(x::Int64)::Int64
            )
        )

        # Scalars pass through by value.
        r = Core.eval(m, :(ApiCall_twice(2.0)))
        @test r isa JLWResult{Float64}
        @test iszero(r.status.code)
        @test r.value == 4.0

        # String argument: a borrowed CString the caller still owns.
        cs = CString{:owned}("wörld")
        r = Core.eval(m, :(ApiCall_len($(CString{:borrowed}(cs.length, cs.data)))))
        @test r.value == 6
        Libc.free(cs.data)

        # Vector{String}: borrowed in, owned out.
        src = CStrArray{:owned}(["ab", "cd"])
        r = Core.eval(m, :(ApiCall_up($(CStrArray{:borrowed}(src.length, src.data)))))
        @test Vector{String}(r.value) == ["AB", "CD"]
        JLWInterop._free_strings(r.value.data, r.value.length)
        JLWInterop._free_strings(src.data, src.length)

        # Dict{String,Float64}: borrowed in, owned out.
        d = CDict{:owned}(Dict("a" => 1.5, "b" => 2.5))
        r = Core.eval(m, :(ApiCall_total($(CDict{:borrowed}(d.length, d.keys, d.values)))))
        @test r.value == 4.0
        JLWInterop._free_strings(d.keys, d.length)
        Libc.free(d.values)

        r = Core.eval(m, :(ApiCall_mk(2)))
        @test Dict{String, Float64}(r.value) == Dict("k1" => 1.0, "k2" => 2.0)
        JLWInterop._free_strings(r.value.keys, r.value.length)
        Libc.free(r.value.values)

        # Union{Float64,Nothing} travels as COpt in both directions.
        @test get(Core.eval(m, :(ApiCall_maybe($(COpt(9.0))))).value, nothing) == 18.0
        @test isnothing(get(Core.eval(m, :(ApiCall_maybe($(COpt{Float64}(nothing))))).value, nothing))

        # Array argument, plus a keyword that reaches the wrapper as a
        # trailing positional C argument.
        a = [1.0, 2.0]
        r = GC.@preserve a Core.eval(m, :(ApiCall_scale($(CArray{:borrowed}(a)), 3.0)))
        @test unsafe_load(r.value.data, 1) == 3.0
        @test unsafe_load(r.value.data, 2) == 6.0
        Libc.free(r.value.data)

        # A `Nothing` return is a bare JLWStatus, with no value field.
        st = Core.eval(m, :(ApiCall_check(1.0)))
        @test st isa JLWStatus
        @test iszero(st.code)
        st = Core.eval(m, :(ApiCall_check(-1.0)))
        @test st.code == Int32(1)
        @test status_message(st) == "not positive"

        # Error paths: the exception types that carry a `msg` report it, under
        # a code of their own; anything else reports its type name under the
        # generic code.
        r = Core.eval(m, :(ApiCall_boom(7)))
        @test r.status.code == JLWInterop._API_ERROR_CODES.generic
        @test iszero(r.value)
        @test status_message(r.status) == "boom 7"

        st = Core.eval(m, :(ApiCall_argue(1))).status
        @test status_message(st) == "bad argument"
        @test st.code == JLWInterop._API_ERROR_CODES.argument

        st = Core.eval(m, :(ApiCall_mismatch(1))).status
        @test status_message(st) == "shapes differ"
        @test st.code == JLWInterop._API_ERROR_CODES.dimension

        st = Core.eval(m, :(ApiCall_outside(1))).status
        @test status_message(st) == "DomainError"
        @test st.code == JLWInterop._API_ERROR_CODES.generic
    end

    @testset "@api StridedArray arguments receive the carrier" begin
        # A StridedArray argument receives the CArray carrier directly.
        @test JLWInterop.carrier_type(StridedArray{Float64, 2}) === CArray{:borrowed, Float64, 2}
        @test JLWInterop.carrier_type(StridedVector{Int32}) === CArray{:borrowed, Int32, 1}
        @test JLWInterop.carrier_return_type(StridedArray{Float64, 1}) === CArray{:owned, Float64, 1}
        # Only supported concrete scalars have a fixed ABI.
        @test JLWInterop.carrier_type(StridedArray{Real, 2}) === nothing
        @test JLWInterop.carrier_type(StridedArray{String, 1}) === nothing

        c = CArray{:borrowed, Float64, 1}((Int64(2),), Ptr{Float64}(0))
        @test JLWInterop.from_carrier(StridedArray{Float64, 1}, c) === c

        m = Module(:ApiStrided)
        Core.eval(m, :(using JLWInterop))
        Core.eval(
            m, quote
                function colsum(A::StridedArray{Float64, 2})
                    A isa CMatrix{:borrowed, Float64} ||
                        error("expected the carrier, got " * string(typeof(A)))
                    vec(sum(A; dims = 1))
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api colsum(A::StridedArray{Float64, 2})::StridedArray{Float64, 1}
            )
        )
        Core.eval(
            m, quote
                function dbl(A::StridedArray{Float64, 1})
                    A .*= 2.0
                    nothing
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api dbl(A::StridedArray{Float64, 1})::Nothing
            )
        )

        # The declared return is copied into an owned carrier.
        A = [1.0 2.0; 3.0 4.0]
        r = GC.@preserve A Core.eval(m, :(ApiStrided_colsum($(CArray{:borrowed}(A)))))
        @test iszero(r.status.code)
        @test r.value isa CVector{:owned, Float64}
        @test unsafe_load(r.value.data, 1) == 4.0
        @test unsafe_load(r.value.data, 2) == 6.0
        Libc.free(r.value.data)

        # Mutation through the carrier reaches the caller's buffer.
        v = [1.0, 2.0, 3.0]
        st = GC.@preserve v Core.eval(m, :(ApiStrided_dbl($(CArray{:borrowed}(v)))))
        @test st isa JLWStatus
        @test iszero(st.code)
        @test v == [2.0, 4.0, 6.0]
    end

    @testset "@api raw pointers and library-registered carriers" begin
        # A `Ptr{T}` is its own carrier, and so is any `isbits` struct whose
        # library adds the three protocol methods for it.
        status_message(st) = String(collect(Iterators.takewhile(!iszero, st.message)))

        m = Module(:ApiRaw)
        Core.eval(m, :(using JLWInterop))
        Core.eval(
            m, :(
                struct P32
                    x::Int32
                    y::Int32
                end
            )
        )
        Core.eval(m, :(JLWInterop.carrier_type(::Type{P32}) = P32))
        Core.eval(m, :(JLWInterop.to_carrier(p::P32) = p))
        Core.eval(m, :(JLWInterop.from_carrier(::Type{P32}, c::P32) = c))
        Core.eval(
            m, quote
                function sum_at(data::Ptr{Float64}, n::Int64)
                    n >= 0 || error("negative length")
                    s = 0.0
                    for i in 1:n
                        s += unsafe_load(data, i)
                    end
                    s
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api sum_at(data::Ptr{Float64}, n::Int64)::Float64
            )
        )
        Core.eval(
            m, quote
                function shift(p::P32, by::Int32)
                    by >= 0 || error("negative shift")
                    P32(p.x + by, p.y + by)
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api shift(p::P32, by::Int32)::P32
            )
        )
        Core.eval(
            m, quote
                function head(v::Vector{Float64})
                    pointer(v)
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api head(v::Vector{Float64})::Ptr{Float64}
            )
        )

        @test JLWInterop.carrier_type(Ptr{Float64}) === Ptr{Float64}
        @test JLWInterop.carrier_return_type(Ptr{Cvoid}) === Ptr{Cvoid}
        @test JLWInterop.from_carrier(Ptr{Int8}, Ptr{Int8}(C_NULL)) === Ptr{Int8}(C_NULL)

        buf = [1.0, 2.0, 4.0]
        r = GC.@preserve buf Core.eval(m, :(ApiRaw_sum_at($(pointer(buf)), 3)))
        @test iszero(r.status.code)
        @test r.value == 7.0

        p = Core.eval(m, :(P32(Int32(1), Int32(2))))
        r = Core.eval(m, :(ApiRaw_shift($p, Int32(3))))
        @test iszero(r.status.code)
        @test r.value == Core.eval(m, :(P32(Int32(4), Int32(5))))

        # A `Ptr` return travels unconverted.
        r = GC.@preserve buf Core.eval(m, :(ApiRaw_head($(CArray{:borrowed}(buf)))))
        @test r.value === pointer(buf)

        # Errors still cross as a status, with a zero-filled value.
        r = GC.@preserve buf Core.eval(m, :(ApiRaw_sum_at($(pointer(buf)), -1)))
        @test r.status.code == Int32(1)
        @test status_message(r.status) == "negative length"
        r = Core.eval(m, :(ApiRaw_shift($p, Int32(-1))))
        @test r.status.code == Int32(1)
        @test status_message(r.status) == "negative shift"
        @test r.value == Core.eval(m, :(P32(Int32(0), Int32(0))))

        # Padding is zeroed too, and a non-isbits carrier is rejected.
        Core.eval(
            m, :(
                struct Padded
                    a::Int8
                    b::Int64
                end
            )
        )
        @test Core.eval(m, :(JLWInterop._zero_carrier(Padded))) ==
            Core.eval(m, :(Padded(0, 0)))
        @test_throws ArgumentError JLWInterop._zero_carrier(Vector{Float64})
    end

    @testset "@api kwargs and metadata" begin
        m = Module(:ApiTestD)
        Core.eval(m, :(using JLWInterop))
        Core.eval(
            m, quote
                function scale(x::Vector{Float64}; factor::Float64 = 2.0, label::String)
                    factor .* x
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api "Scale." scale(x::Vector{Float64}; factor::Float64 = 2.0, label::String)::Vector{Float64}
            )
        )
        e = only(JLWInterop.api_entries(m))
        @test e.args == [(:x, Vector{Float64})]
        @test e.kwargs == [(:factor, Float64, true, 2.0), (:label, String, false, nothing)]
        # non-literal defaults are rejected at expansion
        @test_throws "keyword 'k' default must be a literal" Core.eval(
            m, :(
                JLWInterop.@api bad(x::Float64; k::Float64 = sqrt(2))::Float64
            )
        )
        # so is a literal of the wrong type, in either direction
        @test_throws "keyword 'k' is declared ::Float64 but its default \"oops\" is a String" Core.eval(
            m, :(
                JLWInterop.@api wrongtype(x::Float64; k::Float64 = "oops")::Float64
            )
        )
        @test_throws "keyword 'k' is declared ::Float64 but its default 2 is a Int64" Core.eval(
            m, :(
                JLWInterop.@api narrowing(x::Float64; k::Float64 = 2)::Float64
            )
        )
        # A second @api method of the same function would claim the same C symbol.
        @test_throws "'ApiTestD_scale' is already an API entry point" Core.eval(
            m, :(
                JLWInterop.@api scale(x::Float64)::Float64
            )
        )
        mktempdir() do dir
            p = joinpath(dir, "m.jlw.json")
            JLWInterop.write_metadata(p, m)
            txt = read(p, String)
            @test occursin("\"jlw_metadata_version\": 1", txt)
            @test occursin("ApiTestD_scale", txt)
            @test occursin("\"factor\"", txt) && occursin("2.0", txt)
            @test occursin("Scale.", txt)
        end
    end

    @testset "@api kwargs: empty-string default vs required" begin
        # A `= ""` default stays distinguishable from no default, in both
        # ApiEntry.kwargs and the sidecar JSON.
        m = Module(:ApiTestE)
        Core.eval(m, :(using JLWInterop))
        Core.eval(
            m, quote
                function f(; opt::String = "", req::String)
                    0
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api f(; opt::String = "", req::String)::Int64
            )
        )
        e = only(JLWInterop.api_entries(m))
        @test e.kwargs == [(:opt, String, true, ""), (:req, String, false, nothing)]

        mktempdir() do dir
            p = joinpath(dir, "e.jlw.json")
            JLWInterop.write_metadata(p, m)
            txt = read(p, String)
            @test occursin("{\"name\": \"opt\", \"default\": \"\"}", txt)
            @test occursin("{\"name\": \"req\"}", txt)   # req: no default key at all
        end
    end

    @testset "@api kwarg defaults are typed JSON values" begin
        # Each default reaches the sidecar as a JSON value of its own type,
        # so the emitter never re-parses Julia source text.
        m = Module(:ApiTestH)
        Core.eval(m, :(using JLWInterop))
        Core.eval(m, :(f(; i, f64, b, s, o) = 0))
        Core.eval(
            m, :(
                JLWInterop.@api f(
                    ;
                    i::Int64 = 3, f64::Float64 = 2.5, b::Bool = true,
                    s::String = "a\$b\\c", o::Union{Float64, Nothing} = nothing,
                )::Int64
            )
        )
        e = only(JLWInterop.api_entries(m))
        @test e.kwargs == [
            (:i, Int64, true, 3), (:f64, Float64, true, 2.5), (:b, Bool, true, true),
            (:s, String, true, "a\$b\\c"),
            (:o, Union{Float64, Nothing}, true, nothing),
        ]
        mktempdir() do dir
            p = joinpath(dir, "h.jlw.json")
            JLWInterop.write_metadata(p, m)
            txt = read(p, String)
            @test occursin("{\"name\": \"i\", \"default\": 3}", txt)
            @test occursin("{\"name\": \"f64\", \"default\": 2.5}", txt)
            @test occursin("{\"name\": \"b\", \"default\": true}", txt)
            @test occursin("{\"name\": \"s\", \"default\": \"a\$b\\\\c\"}", txt)
            @test occursin("{\"name\": \"o\", \"default\": null}", txt)
        end
    end

    @testset "write_metadata: JSON escaping" begin
        # A docstring's double quote, backslash, and newline come back
        # escaped in the JSON text, never raw.
        m = Module(:ApiTestF)
        Core.eval(m, :(using JLWInterop))
        Core.eval(
            m, quote
                function g(x::Float64)
                    x
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api "Has \"quotes\", a \\backslash\\, and a\nnewline." g(x::Float64)::Float64
            )
        )
        mktempdir() do dir
            p = joinpath(dir, "g.jlw.json")
            JLWInterop.write_metadata(p, m)
            txt = read(p, String)
            @test occursin("\\\"quotes\\\"", txt)     # escaped double quote
            @test occursin("\\\\backslash\\\\", txt)  # escaped backslash
            @test occursin("a\\nnewline", txt)         # escaped newline
            @test !occursin("a\nnewline", txt)          # never a raw newline inside the string
        end
    end

    @testset "@api kwarg default: negated number literal" begin
        # The parser folds `-1`, `-1.5` and `-1f0` into a literal token but
        # leaves `-0x10` as `Expr(:call, :-, <number>)`, so that branch is
        # reachable through `@api`.
        @test Meta.parse("-0x10") isa Expr
        m = Module(:ApiTestI)
        Core.eval(m, :(using JLWInterop))
        Core.eval(
            m, quote
                function g(x::Float64; k::UInt8 = -0x10)
                    x
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api g(x::Float64; k::UInt8 = -0x10)::Float64
            )
        )
        @test only(JLWInterop.api_entries(m)).kwargs == [(:k, UInt8, true, 0xf0)]
        mktempdir() do dir
            p = joinpath(dir, "i.jlw.json")
            JLWInterop.write_metadata(p, m)
            @test occursin("{\"name\": \"k\", \"default\": 240}", read(p, String))
        end
    end

    @testset "@api enums" begin
        status_message(st) = String(collect(Iterators.takewhile(!iszero, st.message)))

        m = Module(:ApiEnum)
        Core.eval(m, :(using JLWInterop))
        Core.eval(m, :(@enum PenaltyKind::Int32 abslog1 = 0 square = 1))
        Core.eval(
            m, quote
                function scale_by(x::Float64, kind::PenaltyKind; penalty::PenaltyKind = abslog1)
                    (kind === abslog1 ? x : x^2) + (penalty === abslog1 ? 0.0 : 1.0)
                end
            end
        )
        Core.eval(
            m, :(
                JLWInterop.@api scale_by(
                    x::Float64, kind::PenaltyKind; penalty::PenaltyKind = abslog1,
                )::Float64
            )
        )
        Core.eval(
            m, quote
                function pick(x::Float64)
                    x > 0 ? square : abslog1
                end
            end
        )
        Core.eval(m, :(JLWInterop.@api pick(x::Float64)::PenaltyKind))

        # `carrier_type` maps a concrete enum to its base integer type; the
        # abstract/non-concrete forms have no carrier.
        @test JLWInterop.carrier_type(m.PenaltyKind) === Int32
        @test JLWInterop.carrier_return_type(m.PenaltyKind) === Int32
        @test isnothing(JLWInterop.carrier_type(Union{m.PenaltyKind, Nothing}))
        @test JLWInterop.to_carrier(m.abslog1) === Int32(0)
        @test JLWInterop.to_carrier(m.square) === Int32(1)
        @test JLWInterop.from_carrier(m.PenaltyKind, Int32(1)) === m.square

        e = only(e for e in JLWInterop.api_entries(m) if e.name === :scale_by)
        @test e.args == [(:x, Float64), (:kind, m.PenaltyKind)]
        @test e.kwargs == [(:penalty, m.PenaltyKind, true, m.abslog1)]
        @test only(e2.ret for e2 in JLWInterop.api_entries(m) if e2.name === :pick) === m.PenaltyKind

        # Round-trip through the generated wrapper: enum positional arg, enum
        # kwarg with a member default (every call still supplies it — the
        # default is a binding-layer concern, per `@api`'s docstring), and an
        # enum return.
        r = Core.eval(m, :(ApiEnum_scale_by(2.0, Int32(0), Int32(0))))
        @test iszero(r.status.code)
        @test r.value == 2.0
        r = Core.eval(m, :(ApiEnum_scale_by(2.0, Int32(1), Int32(1))))
        @test iszero(r.status.code)
        @test r.value == 5.0

        r = Core.eval(m, :(ApiEnum_pick(1.0)))
        @test iszero(r.status.code)
        @test r.value == Int32(1)
        r = Core.eval(m, :(ApiEnum_pick(-1.0)))
        @test iszero(r.status.code)
        @test r.value == Int32(0)

        # An invalid integer for an enum argument is an `ArgumentError`
        # (status code 2), not a crash or a silently wrapped value.
        r = Core.eval(m, :(ApiEnum_scale_by(2.0, Int32(9), Int32(0))))
        @test r.status.code == JLWInterop._API_ERROR_CODES.argument
        @test status_message(r.status) == "invalid value 9 for enum PenaltyKind"

        # Expansion errors: a numeric literal default for an enum kwarg is
        # not a symbol or dotted name, so it takes the ordinary
        # literal-type-mismatch path (rejected: `9 isa PenaltyKind` is
        # false); a symbol that resolves to a non-member value is rejected
        # by the enum-default path itself; and a non-enum kwarg still
        # rejects a symbol default.
        @test_throws "is declared ::Main.ApiEnum.PenaltyKind but its default 9 is a Int64" Core.eval(
            m, :(
                JLWInterop.@api bad1(x::Float64; k::PenaltyKind = 9)::Float64
            )
        )
        Core.eval(m, :(const not_a_penalty = 1))
        @test_throws "is not a member of" Core.eval(
            m, :(
                JLWInterop.@api bad2(x::Float64; k::PenaltyKind = not_a_penalty)::Float64
            )
        )
        @test_throws "keyword 'k' default must be a literal" Core.eval(
            m, :(
                JLWInterop.@api bad3(x::Float64; k::Float64 = abslog1)::Float64
            )
        )

        # `Union{PenaltyKind,Nothing}` has no carrier mapping: an optional
        # enum is out of scope and rejected the same way any other
        # unsupported type is.
        @test_throws "has no carrier mapping" Core.eval(
            m, :(
                JLWInterop.@api bad4(x::Union{PenaltyKind, Nothing})::Float64
            )
        )

        mktempdir() do dir
            p = joinpath(dir, "enum.jlw.json")
            JLWInterop.write_metadata(p, m)
            txt = read(p, String)
            @test occursin("\"jlw_metadata_version\": 2", txt)
            @test occursin("\"enums\"", txt)
            @test occursin("\"PenaltyKind\"", txt)
            @test occursin("\"basetype\": \"Int32\"", txt)
            @test occursin(
                "\"members\": [{\"name\": \"abslog1\", \"value\": 0}, {\"name\": \"square\", \"value\": 1}]",
                txt
            )
            @test occursin("\"arg_enums\": {\"kind\": \"PenaltyKind\", \"penalty\": \"PenaltyKind\"}", txt)
            @test occursin("\"return_enum\": \"PenaltyKind\"", txt)
            @test occursin("{\"name\": \"penalty\", \"default\": \"abslog1\"}", txt)
        end

        # A module with no enums still writes the old version-1 shape,
        # byte-identical to what it produced before enum support existed.
        m2 = Module(:ApiEnumNone)
        Core.eval(m2, :(using JLWInterop))
        Core.eval(m2, quote
            twice(x::Float64) = 2x
        end)
        Core.eval(m2, :(JLWInterop.@api twice(x::Float64)::Float64))
        mktempdir() do dir
            p = joinpath(dir, "none.jlw.json")
            JLWInterop.write_metadata(p, m2)
            txt = read(p, String)
            @test occursin("\"jlw_metadata_version\": 1", txt)
            @test !occursin("enums", txt)
            @test !occursin("arg_enums", txt)
            @test !occursin("return_enum", txt)
        end

        # Two distinct enum types sharing a name collide in the sidecar's
        # `enums` table, keyed by name — an error, not a silent merge.
        m3 = Module(:ApiEnumCollide)
        Core.eval(m3, :(using JLWInterop))
        Core.eval(m3, :(module A
            @enum PenaltyKind::Int32 a = 0
        end))
        Core.eval(m3, :(module B
            @enum PenaltyKind::Int32 b = 0
        end))
        Core.eval(m3, quote
            f(x::A.PenaltyKind) = x
            g(x::B.PenaltyKind) = x
        end)
        Core.eval(m3, :(JLWInterop.@api f(x::A.PenaltyKind)::A.PenaltyKind))
        Core.eval(m3, :(JLWInterop.@api g(x::B.PenaltyKind)::B.PenaltyKind))
        mktempdir() do dir
            p = joinpath(dir, "collide.jlw.json")
            @test_throws "two distinct enum types are both named 'PenaltyKind'" JLWInterop.write_metadata(p, m3)
        end
    end

    @testset "release entrypoints" begin
        # The expansion must not depend on other imports.
        m = Module()
        Core.eval(m, :(import JLWInterop: @export_release_entrypoints))
        Core.eval(m, :(@export_release_entrypoints))
        @test only(methods(m.jlw_free)).sig ==
            Tuple{typeof(m.jlw_free), Ptr{Cvoid}}
        @test only(methods(m.jlw_free_strings)).sig ==
            Tuple{typeof(m.jlw_free_strings), Ptr{JLWInterop.CString{:owned}}, Int64}
        # The functions accept malloc'd data.
        a = CStrArray{:owned}(["x", "y"])
        Core.eval(m, :(jlw_free_strings($(a.data), $(a.length))))
        p = Libc.malloc(16)
        Core.eval(m, :(jlw_free($p)))
    end

    @testset "CTupleN carriers" begin
        # Named fields, not a wrapped Julia Tuple: `fieldname` on a tuple
        # returns an integer, which the ABI exporter cannot render.
        @test fieldnames(CTuple2{Int64, Float64}) === (:v1, :v2)
        @test fieldnames(CTuple3{Int64, Float64, Bool}) === (:v1, :v2, :v3)
        @test String(fieldname(CTuple2{Int64, Float64}, 1)) == "v1"

        t = CTuple2{Int64, Float64}(3, 2.5)
        @test t.v1 === Int64(3)
        @test t.v2 === 2.5

        # A tuple of carriers is isbits, so the generic `_zero_carrier`
        # fallback works and `jlw_error` can build a failure value.
        C = CTuple2{CVector{:owned, Float64}, Int64}
        @test isbitstype(C)
        z = JLWInterop._zero_carrier(C)
        @test z.v1.data === Ptr{Float64}(C_NULL)
        @test z.v2 === Int64(0)
        @test JLWInterop._ctuple_type(2) === CTuple2
        @test JLWInterop._ctuple_type(8) === CTuple8
    end

    @testset "tuple returns map onto CTupleN" begin
        @test JLWInterop.carrier_return_type(Tuple{Float64, Int64}) ===
            CTuple2{Float64, Int64}
        @test JLWInterop.carrier_return_type(Tuple{Vector{Float64}, Int64}) ===
            CTuple2{CVector{:owned, Float64}, Int64}
        @test JLWInterop.carrier_return_type(Tuple{String, Vector{String}}) ===
            CTuple2{CString{:owned}, CStrArray{:owned}}

        # Tuples are return-only: the argument direction still has no mapping.
        @test isnothing(JLWInterop.carrier_type(Tuple{Float64, Int64}))

        # An element with no carrier makes the whole tuple unmapped, so the
        # macro reports its usual error instead of building a broken carrier.
        @test isnothing(JLWInterop.carrier_return_type(Tuple{Float64, Function}))

        # Outside the supported arity range.
        @test isnothing(JLWInterop.carrier_return_type(Tuple{Float64}))
        @test isnothing(
            JLWInterop.carrier_return_type(
                Tuple{Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64}
            )
        )

        # `to_carrier` builds the carrier element-wise.
        c = JLWInterop.to_carrier((2.5, Int64(7)))
        @test c === CTuple2{Float64, Int64}(2.5, Int64(7))

        c2 = JLWInterop.to_carrier(([1.0, 2.0], Int64(2)))
        @test c2 isa CTuple2{CVector{:owned, Float64}, Int64}
        @test collect(c2.v1) == [1.0, 2.0]
        @test c2.v2 === Int64(2)
        Libc.free(c2.v1.data)
    end

    @testset "@api tuple return end to end" begin
        status_message(st) = String(collect(Iterators.takewhile(!iszero, st.message)))
        m = Module(:ApiTestTuple)
        Core.eval(m, :(using JLWInterop))
        Core.eval(
            m, quote
                function stats(a::Vector{Float64})
                    return (2 .* a, Int64(length(a)))
                end
                function bad(a::Vector{Float64})
                    return error("no stats")
                end
            end
        )
        Core.eval(m, :(JLWInterop.@api stats(a::Vector{Float64})::Tuple{Vector{Float64}, Int64}))
        Core.eval(m, :(JLWInterop.@api bad(a::Vector{Float64})::Tuple{Vector{Float64}, Int64}))

        e = only(x for x in JLWInterop.api_entries(m) if x.name === :stats)
        @test e.ret === Tuple{Vector{Float64}, Int64}

        buf = [1.0, 2.0, 3.0]
        GC.@preserve buf begin
            arg = CVector{:borrowed, Float64}((Int32(3),), pointer(buf))
            r = Core.eval(m, :(ApiTestTuple_stats($arg)))
            @test iszero(r.status.code)
            @test collect(r.value.v1) == [2.0, 4.0, 6.0]
            @test r.value.v2 === Int64(3)
            Libc.free(r.value.v1.data)

            # On the error path every element is zeroed, so releasing is a
            # no-op and nothing dangles.
            rb = Core.eval(m, :(ApiTestTuple_bad($arg)))
            @test rb.status.code == JLWInterop._API_ERROR_CODES.generic
            @test status_message(rb.status) == "no stats"
            @test rb.value.v1.data === Ptr{Float64}(C_NULL)
            @test rb.value.v2 === Int64(0)
        end
    end
end
