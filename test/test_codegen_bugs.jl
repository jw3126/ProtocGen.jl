# Regression tests for two codegen bugs that lived in earlier passes. Both are
# fixed; this file is now a regression suite and is a natural candidate to
# merge into test_codegen.jl.
#
# Bug 1 (repeated bool/float/double) — codegen lumped Bool/Float32/Float64
#   into the same no-wire-type fast-path as String/Vector{UInt8}, but the
#   codec's `decode!(d, w, ::BufferedVector{T<:Union{Bool,Float32,Float64}})`
#   (decode.jl:174) requires the wire-type to switch packed vs unpacked.
#   Without it, dispatch fell into the generic `BufferedVector{T}` path
#   that assumes a length-prefixed message and crashed on the deleted
#   `LengthDelimitedProtoDecoder` fallback.
#
# Bug 2 (map<K,V> drops fixed/zigzag) — the map FieldModel set
#   `wire_annotation = ""` unconditionally, so codegen emitted bare
#   `decode!(d, dict)` / `encode(e, n, dict)` that hit the codec's default
#   varint path even for `map<sfixed32, sint64>` etc. Codec has the right
#   `Val{Tuple{KAnnot,VAnnot}}` dispatches (decode.jl:58–98 / encode.jl:
#   150–187); the fix threads each map's per-K/V annotation through.

module TestCodegenBugs

include("setup.jl")

@testset "regression: repeated bool/float/double" begin
    # Schema: fixtures/proto/rep.proto
    #     message M {
    #       repeated float  fs = 1;
    #       repeated double ds = 2;
    #       repeated bool   bs = 3;
    #     }
    # Sample: fixtures/txtpb/rep_sample.txtpb (fs/ds/bs each populated).
    response = run_codegen("rep.pb", ["rep.proto"])
    @test response.error === nothing
    f = response.file[1]

    rep_mod = eval_generated(f.content, :GeneratedRep)
    rep_sample_pb = fixture("rep_sample.pb")

    m = decode_latest(rep_mod.M, rep_sample_pb)
    @test m.fs == Float32[1.5f0, -2.25f0, 0.0f0]
    @test length(m.ds) == 2
    @test isapprox(m.ds[1], 3.14159265358979; atol = 1e-12)
    @test isapprox(m.ds[2], -1e-10; atol = 1e-22)
    @test m.bs == Bool[true, false, true]

    # Re-encoding should be byte-identical to what protoc produced. Vector
    # preserves order, so this is deterministic.
    @test encode_latest(m) == rep_sample_pb
end

@testset "regression: map<K,V> with fixed/zigzag K or V" begin
    # Schema: fixtures/proto/maps_fx.proto
    #     message Bag {
    #       map<sfixed32, sint64>  a = 1;
    #       map<string,   fixed64> b = 2;
    #       map<sint32,   string>  c = 3;
    #     }
    # Sample: fixtures/txtpb/maps_fx_sample.txtpb.
    response = run_codegen("maps_fx.pb", ["maps_fx.proto"])
    @test response.error === nothing
    f = response.file[1]

    # Surface check: each map's per-K/V wire annotation shows up exactly
    # where the codec dispatches on it. Codec methods key on
    # `Val{Tuple{KAnnot,VAnnot}}` where each annotation is the bare symbol
    # `:fixed` / `:zigzag` (or `Nothing`), not the `Val{:fixed}` form used by
    # non-map scalar fields. See codec/decode.jl:58–98 and encode.jl:150–187.
    @test occursin("Val{Tuple{:fixed,:zigzag}}",  f.content)  # map<sfixed32, sint64>
    @test occursin("Val{Tuple{Nothing,:fixed}}",  f.content)  # map<string,   fixed64>
    @test occursin("Val{Tuple{:zigzag,Nothing}}", f.content)  # map<sint32,   string>

    maps_mod = eval_generated(f.content, :GeneratedMapsFx)
    maps_sample_pb = fixture("maps_fx_sample.pb")

    bag = decode_latest(maps_mod.Bag, maps_sample_pb)
    @test bag.a == Dict(Int32(-1) => Int64(1), Int32(7) => Int64(-2))
    @test bag.b == Dict("k1" => UInt64(0xCAFEBABEDEADBEEF), "k2" => UInt64(1))
    @test bag.c == Dict(Int32(-3) => "neg", Int32(4) => "pos")

    # Encode-side cross-check: re-encode the protoc-decoded `bag` and assert
    # byte-equality against the protoc fixture. Map fields are
    # OrderedDict, so insertion order (= wire order on decode) survives
    # the round-trip; the per-K/V wire annotation we asserted above means
    # varint-of-sfixed32 vs raw-4-byte sfixed32 sizes also have to agree.
    @test encode_latest(bag) == maps_sample_pb
end

end  # module TestCodegenBugs
