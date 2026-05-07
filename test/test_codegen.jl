@testset "codegen happy path" begin
    G = ProtoBufDescriptors.google.protobuf
    GC = ProtoBufDescriptors.google.protobuf.compiler

    # FileDescriptorSet for fixtures/proto/sample.proto.
    sample_pb = fixture("sample.pb")
    fdset = ProtoBufDescriptors.decode(
        ProtoBufDescriptors.ProtoDecoder(IOBuffer(sample_pb)),
        G.FileDescriptorSet,
    )

    # Run the captured FileDescriptorProto through the plugin.
    request = GC.CodeGeneratorRequest(
        ["sample.proto"],
        nothing,
        fdset.file,
        G.FileDescriptorProto[],
        nothing,
    )
    req_io = IOBuffer()
    ProtoBufDescriptors.encode(ProtoBufDescriptors.ProtoEncoder(req_io), request)
    out_io = IOBuffer()
    response = ProtoBufDescriptors.run_plugin(IOBuffer(take!(req_io)), out_io)
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
    sample_mod = Module(:GeneratedSample)
    Core.eval(sample_mod, Meta.parseall(f.content))

    inner = Base.invokelatest(sample_mod.Inner, Int32(42))
    outer = Base.invokelatest(sample_mod.Outer,
                              "hello", Int32(7), inner,
                              Int64[1, 2, 3, 4],
                              ProtoBufDescriptors.OneOf(:ci, Int32(99)))
    enc_io = IOBuffer()
    Base.invokelatest(ProtoBufDescriptors.encode,
                      ProtoBufDescriptors.ProtoEncoder(enc_io), outer)
    decoded = Base.invokelatest(ProtoBufDescriptors.decode,
                                ProtoBufDescriptors.ProtoDecoder(IOBuffer(take!(enc_io))),
                                sample_mod.Outer)
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
    protoc_outer_pb = fixture("sample_outer.pb")
    from_protoc = Base.invokelatest(ProtoBufDescriptors.decode,
                                    ProtoBufDescriptors.ProtoDecoder(IOBuffer(protoc_outer_pb)),
                                    sample_mod.Outer)
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
    corpus_pb        = fixture("corpus.pb")
    corpus_sample_pb = fixture("corpus_sample.pb")

    G = ProtoBufDescriptors.google.protobuf
    GC = ProtoBufDescriptors.google.protobuf.compiler

    fdset = ProtoBufDescriptors.decode(
        ProtoBufDescriptors.ProtoDecoder(IOBuffer(corpus_pb)),
        G.FileDescriptorSet,
    )
    request = GC.CodeGeneratorRequest(
        ["corpus.proto"],
        nothing,
        fdset.file,
        G.FileDescriptorProto[],
        nothing,
    )
    req_io = IOBuffer()
    ProtoBufDescriptors.encode(ProtoBufDescriptors.ProtoEncoder(req_io), request)
    out_io = IOBuffer()
    response = ProtoBufDescriptors.run_plugin(IOBuffer(take!(req_io)), out_io)
    @test response.error === nothing
    @test length(response.file) == 1
    f = response.file[1]
    @test f.name == "corpus_pb.jl"

    corpus_mod = Module(:GeneratedCorpus)
    Core.eval(corpus_mod, Meta.parseall(f.content))

    # Decode the protoc-encoded payload and check every field.
    w = Base.invokelatest(ProtoBufDescriptors.decode,
                          ProtoBufDescriptors.ProtoDecoder(IOBuffer(corpus_sample_pb)),
                          corpus_mod.Wide)
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
    enc_io = IOBuffer()
    Base.invokelatest(ProtoBufDescriptors.encode,
                      ProtoBufDescriptors.ProtoEncoder(enc_io), w)
    re = take!(enc_io)
    @test length(re) == length(corpus_sample_pb)
    w2 = Base.invokelatest(ProtoBufDescriptors.decode,
                           ProtoBufDescriptors.ProtoDecoder(IOBuffer(re)),
                           corpus_mod.Wide)
    for fname in fieldnames(typeof(w))
        @test getfield(w, fname) == getfield(w2, fname)
    end
end

@testset "codegen: maps" begin
    # FileDescriptorSet + protoc-encoded Bag for fixtures/proto/maps.proto.
    maps_pb        = fixture("maps.pb")
    maps_sample_pb = fixture("maps_sample.pb")

    G = ProtoBufDescriptors.google.protobuf
    GC = ProtoBufDescriptors.google.protobuf.compiler

    fdset = ProtoBufDescriptors.decode(
        ProtoBufDescriptors.ProtoDecoder(IOBuffer(maps_pb)),
        G.FileDescriptorSet,
    )
    request = GC.CodeGeneratorRequest(
        ["maps.proto"], nothing, fdset.file,
        G.FileDescriptorProto[], nothing,
    )
    req_io = IOBuffer()
    ProtoBufDescriptors.encode(ProtoBufDescriptors.ProtoEncoder(req_io), request)
    out_io = IOBuffer()
    response = ProtoBufDescriptors.run_plugin(IOBuffer(take!(req_io)), out_io)
    @test response.error === nothing
    f = response.file[1]

    # Maps surface as Dict{K,V}; the synthetic *Entry messages stay invisible.
    @test occursin("counts::Dict{String,Int32}", f.content)
    @test occursin("labels::Dict{Int32,String}", f.content)
    @test occursin("items::Dict{String,Item}",   f.content)
    @test !occursin("CountsEntry", f.content)
    @test !occursin("LabelsEntry", f.content)
    @test !occursin("ItemsEntry",  f.content)

    maps_mod = Module(:GeneratedMaps)
    Core.eval(maps_mod, Meta.parseall(f.content))

    bag = Base.invokelatest(ProtoBufDescriptors.decode,
                            ProtoBufDescriptors.ProtoDecoder(IOBuffer(maps_sample_pb)),
                            maps_mod.Bag)
    @test bag.counts == Dict("a" => Int32(1), "b" => Int32(2))
    @test bag.labels == Dict(Int32(10) => "ten", Int32(20) => "twenty")
    @test sort(collect(keys(bag.items))) == ["x", "y"]
    @test bag.items["x"].v == 7 && bag.items["y"].v == 8

    # Round-trip — bytes need not be identical (Dict iteration order is
    # nondeterministic, so map-entry order on the wire can differ), but the
    # decoded values must match.
    enc_io = IOBuffer()
    Base.invokelatest(ProtoBufDescriptors.encode,
                      ProtoBufDescriptors.ProtoEncoder(enc_io), bag)
    bag2 = Base.invokelatest(ProtoBufDescriptors.decode,
                             ProtoBufDescriptors.ProtoDecoder(IOBuffer(take!(enc_io))),
                             maps_mod.Bag)
    @test bag.counts == bag2.counts
    @test bag.labels == bag2.labels
    @test length(bag.items) == length(bag2.items)
    for (k, v) in bag.items
        @test haskey(bag2.items, k) && bag2.items[k].v == v.v
    end
end
