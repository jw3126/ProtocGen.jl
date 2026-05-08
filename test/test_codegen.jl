module TestCodegen

include("setup.jl")

@testset "codegen happy path" begin
    response = run_codegen("sample.pb", ["sample.proto"])
    @test response.error === nothing
    @test length(response.file) == 1
    f = response.file[1]
    @test f.name == "sample_pb.jl"
    @test occursin("struct Inner", f.content)
    @test occursin("struct Outer", f.content)
    @test occursin("nested::Union{Nothing,Inner}", f.content)
    @test occursin("packed_ints::Vector{Int64}", f.content)
    @test occursin("choice::Union{Nothing,OneOf{<:Union{Int32,String}}}", f.content)

    # Eval the generated module and verify a round-trip.
    sample_mod = eval_generated(f.content, :GeneratedSample)

    inner = Base.invokelatest(sample_mod.Inner, Int32(42))
    outer = Base.invokelatest(sample_mod.Outer,
                              "hello", Int32(7), inner,
                              Int64[1, 2, 3, 4],
                              ProtoBufDescriptors.OneOf(:ci, Int32(99)))
    decoded = decode_latest(sample_mod.Outer, encode_latest(outer))
    @test decoded.name == outer.name
    @test decoded.maybe == outer.maybe
    @test decoded.nested !== nothing
    @test decoded.nested.a == outer.nested.a
    @test decoded.packed_ints == outer.packed_ints
    @test decoded.choice !== nothing
    @test decoded.choice.name === :ci
    @test decoded.choice.value == Int32(99)

    # Wire-compat: bytes that `protoc --encode=sample.Outer` produced for
    # fixtures/txtpb/sample_outer.txtpb.
    from_protoc = decode_latest(sample_mod.Outer, fixture("sample_outer.pb"))
    @test from_protoc.name == "from-protoc"
    @test from_protoc.maybe == 99
    @test from_protoc.nested !== nothing && from_protoc.nested.a == 7
    @test from_protoc.choice !== nothing && from_protoc.choice.name === :ci && from_protoc.choice.value == 13
    @test from_protoc.packed_ints == [10, 20, 30]
end

@testset "codegen corpus: every wire encoding" begin
    # FileDescriptorSet for fixtures/proto/corpus.proto. Wide exercises every
    # scalar wire encoding, an enum, a nested message, and three flavors of
    # repeated. corpus_sample.pb is `protoc --encode=corpus.Wide` against
    # fixtures/txtpb/corpus_sample.txtpb (every field non-default).
    response = run_codegen("corpus.pb", ["corpus.proto"])
    @test response.error === nothing
    @test length(response.file) == 1
    f = response.file[1]
    @test f.name == "corpus_pb.jl"

    corpus_mod = eval_generated(f.content, :GeneratedCorpus)

    # Decode the protoc-encoded payload and check every field.
    corpus_sample_pb = fixture("corpus_sample.pb")
    w = decode_latest(corpus_mod.Wide, corpus_sample_pb)
    @test w.i32  == Int32(-1)
    @test w.i64  == Int64(1234567890123)
    @test w.u32  == UInt32(4000000000)
    @test w.u64  == UInt64(18000000000000000000)
    @test w.s32  == Int32(-100)
    @test w.s64  == Int64(-100000000000)
    @test w.f32  == UInt32(0xCAFEBABE)
    @test w.f64  == UInt64(0xDEADBEEFCAFEBABE)
    @test w.sf32 == typemin(Int32)
    @test w.sf64 == typemin(Int64) + 1
    @test isapprox(w.f, 3.14f0; atol = 1f-6)
    @test isapprox(w.d, 2.71828; atol = 1e-9)
    @test w.bb   == true
    @test w.ss   == "héllo"
    @test w.by   == UInt8[0xff, 0x00, 0xab]
    @test w.color == corpus_mod.Color.BLUE
    @test w.nested !== nothing
    @test w.nested.a == 7
    @test w.nested.note == "deep"
    @test w.ri == Int32[1, 2, 3]
    @test w.rs == ["x", "y"]
    @test length(w.rn) == 2
    @test w.rn[1].a == 10 && w.rn[1].note == "p"
    @test w.rn[2].a == 20 && w.rn[2].note == "q"

    # Re-encode and decode again — semantic round-trip should preserve every
    # field. Bytes need not be identical (we emit fields in struct-declaration
    # order; protoc emits them in proto-source order, which happens to be the
    # same here, but we don't depend on it).
    re = encode_latest(w)
    @test length(re) == length(corpus_sample_pb)
    w2 = decode_latest(corpus_mod.Wide, re)
    for fname in fieldnames(typeof(w))
        @test getfield(w, fname) == getfield(w2, fname)
    end
end

@testset "codegen: maps" begin
    # FileDescriptorSet + protoc-encoded Bag for fixtures/proto/maps.proto.
    response = run_codegen("maps.pb", ["maps.proto"])
    @test response.error === nothing
    f = response.file[1]

    # Maps surface as OrderedDict{K,V}; the synthetic *Entry messages stay invisible.
    @test occursin("counts::OrderedDict{String,Int32}", f.content)
    @test occursin("labels::OrderedDict{Int32,String}", f.content)
    @test occursin("items::OrderedDict{String,Item}",   f.content)
    @test !occursin("CountsEntry", f.content)
    @test !occursin("LabelsEntry", f.content)
    @test !occursin("ItemsEntry",  f.content)

    maps_mod = eval_generated(f.content, :GeneratedMaps)

    sample_pb = fixture("maps_sample.pb")
    bag = decode_latest(maps_mod.Bag, sample_pb)
    @test bag.counts == Dict("a" => Int32(1), "b" => Int32(2))
    @test bag.labels == Dict(Int32(10) => "ten", Int32(20) => "twenty")
    @test sort(collect(keys(bag.items))) == ["x", "y"]
    @test bag.items["x"].v == 7 && bag.items["y"].v == 8

    # Insertion-order-preserving OrderedDict means re-encode is byte-identical
    # to the protoc-emitted fixture: the decode order tracks the wire order,
    # the encode iterator tracks insertion order, so we hit the same bytes.
    @test encode_latest(bag) == sample_pb
end

end  # module TestCodegen
