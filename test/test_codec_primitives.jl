module TestCodecPrimitives

include("setup.jl")

using ProtocGenJulia: Codecs
using .Codecs: ProtoDecoder, vbyte_encode, vbyte_decode,
    zigzag_encode, zigzag_decode, _encode, _decode

function roundtrip(::Type{T}, x::T) where {T}
    io = IOBuffer()
    _encode(io, x)
    seekstart(io)
    d = ProtoDecoder(io)
    return _decode(d, T)
end

function roundtrip_fixed(::Type{T}, x::T) where {T}
    io = IOBuffer()
    _encode(io, x, Val{:fixed})
    seekstart(io)
    d = ProtoDecoder(io)
    return _decode(d, T, Val{:fixed})
end

function roundtrip_zigzag(::Type{T}, x::T) where {T}
    io = IOBuffer()
    _encode(io, x, Val{:zigzag})
    seekstart(io)
    d = ProtoDecoder(io)
    return _decode(d, T, Val{:zigzag})
end

@testset "codec primitives" begin
    @testset "varint scalars" begin
        for x in (Int32(0), Int32(1), Int32(-1), Int32(2147483647), Int32(-2147483648))
            @test roundtrip(Int32, x) == x
        end
        for x in (Int64(0), Int64(1), Int64(-1), typemax(Int64), typemin(Int64))
            @test roundtrip(Int64, x) == x
        end
        for x in (UInt32(0), UInt32(1), typemax(UInt32))
            @test roundtrip(UInt32, x) == x
        end
        for x in (UInt64(0), UInt64(1), typemax(UInt64))
            @test roundtrip(UInt64, x) == x
        end
    end

    @testset "fixed-width" begin
        for x in (Int32(0), Int32(-1), typemax(Int32), typemin(Int32))
            @test roundtrip_fixed(Int32, x) == x
        end
        for x in (Int64(0), Int64(-1), typemax(Int64), typemin(Int64))
            @test roundtrip_fixed(Int64, x) == x
        end
    end

    @testset "zigzag" begin
        for x in (Int32(0), Int32(1), Int32(-1), Int32(127), Int32(-128), typemax(Int32), typemin(Int32))
            @test roundtrip_zigzag(Int32, x) == x
        end
        for x in (Int64(0), Int64(1), Int64(-1), typemax(Int64), typemin(Int64))
            @test roundtrip_zigzag(Int64, x) == x
        end
    end

    @testset "zigzag encode/decode primitive" begin
        @test zigzag_encode(Int32(0)) == 0x00000000
        @test zigzag_encode(Int32(-1)) == 0x00000001
        @test zigzag_encode(Int32(1)) == 0x00000002
        @test zigzag_decode(zigzag_encode(Int64(-12345))) == -12345
    end

    @testset "floats" begin
        for x in (0.0f0, 1.0f0, -1.0f0, Float32(NaN), Inf32, -Inf32, -0.0f0)
            r = roundtrip(Float32, x)
            isnan(x) ? @test(isnan(r)) : @test(r === x)
        end
        for x in (0.0, 1.0, -1.0, NaN, Inf, -Inf, -0.0)
            r = roundtrip(Float64, x)
            isnan(x) ? @test(isnan(r)) : @test(r === x)
        end
    end

    @testset "bool" begin
        @test roundtrip(Bool, true) === true
        @test roundtrip(Bool, false) === false
    end

    @testset "tag encode/decode" begin
        for fn in (1, 2, 15, 16, 2047, 2048, typemax(Int32) >> 3)
            for wt in (Codecs.VARINT, Codecs.FIXED64, Codecs.LENGTH_DELIMITED, Codecs.FIXED32)
                io = IOBuffer()
                Codecs.encode_tag(io, fn, wt)
                seekstart(io)
                d = ProtoDecoder(io)
                got_fn, got_wt = Codecs.decode_tag(d)
                @test got_fn == UInt32(fn)
                @test got_wt == wt
            end
        end
    end
end

end  # module TestCodecPrimitives
