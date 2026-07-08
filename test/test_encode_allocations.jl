module TestEncodeAllocations

include("setup.jl")

# Regression test for quadratic allocation when encoding to an IOBuffer.
# On Julia ≥ 1.12 the Memory-backed IOBuffer reallocates and copies the
# whole buffer on every growing `truncate`, so the old truncate-based
# length-prefix reservation in `_with_size` allocated O(n²) bytes over n
# submessages (GiBs for MB-scale messages). Encoding must stay within a
# small constant factor of the output size.

function encode_allocated(msg)
    @allocated encode(msg)
end

@testset "encode allocations" begin
    n = 10_000
    msg = G.ListValue(;
        values = [G.Value(; kind = OneOf(:string_value, "payload $(i)")) for i in 1:n],
    )
    bytes = encode(msg)  # also warms up compilation before measuring
    @test length(bytes) == ProtocGen.Codecs._encoded_size(msg)

    # The seekable (IOBuffer) and non-seekable (PipeBuffer) encoder paths
    # take different `_with_size` branches; they must agree byte-for-byte.
    pipe = PipeBuffer()
    encode(pipe, msg)
    @test read(pipe) == bytes

    # Encoding must not allocate more than ~2× the in-memory size of the
    # message. The real cost is ~0.7× (geometric IOBuffer growth ≈ 2× the
    # output plus the take! copy); quadratic growth overshoots the bound
    # by >100×.
    encode_allocated(msg)  # warm up the measurement wrapper itself
    @test encode_allocated(msg) < 2 * Base.summarysize(msg)
end

end # module
