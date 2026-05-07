@testset "Phase 5 — proto3 explicit `optional` carries presence" begin
    # The whole point of presence: `maybe: 0` (explicit) and `maybe` unset
    # must NOT decode to the same Julia value. The two protoc-encoded payloads
    # come from fixtures/txtpb/outer_maybe_{zero,unset}.txtpb.
    sample_pb         = fixture("sample.pb")
    bytes_maybe_zero  = fixture("outer_maybe_zero.pb")
    bytes_maybe_unset = fixture("outer_maybe_unset.pb")

    G = ProtoBufDescriptors.google.protobuf
    GC = ProtoBufDescriptors.google.protobuf.compiler

    fdset = ProtoBufDescriptors.decode(
        ProtoBufDescriptors.ProtoDecoder(IOBuffer(sample_pb)),
        G.FileDescriptorSet,
    )
    request = GC.CodeGeneratorRequest(
        ["sample.proto"], nothing, fdset.file,
        G.FileDescriptorProto[], nothing,
    )
    req_io = IOBuffer()
    ProtoBufDescriptors.encode(ProtoBufDescriptors.ProtoEncoder(req_io), request)
    out_io = IOBuffer()
    response = ProtoBufDescriptors.run_plugin(IOBuffer(take!(req_io)), out_io)
    @test response.error === nothing
    f = response.file[1]

    # Generated source carries the right type for the proto3-optional field.
    @test occursin("maybe::Union{Nothing,Int32}", f.content)

    sample_mod = Module(:GeneratedSamplePresence)
    Core.eval(sample_mod, Meta.parseall(f.content))

    # Decode: explicit zero stays zero, unset stays unset.
    oz = Base.invokelatest(ProtoBufDescriptors.decode,
                           ProtoBufDescriptors.ProtoDecoder(IOBuffer(bytes_maybe_zero)),
                           sample_mod.Outer)
    @test oz.name == "z"
    @test oz.maybe === Int32(0)

    ou = Base.invokelatest(ProtoBufDescriptors.decode,
                           ProtoBufDescriptors.ProtoDecoder(IOBuffer(bytes_maybe_unset)),
                           sample_mod.Outer)
    @test ou.name == "u"
    @test ou.maybe === nothing

    # Encode: nothing-valued optional yields no field-2 bytes; explicit-zero
    # optional emits field 2 with value 0. These bytes match what `protoc`
    # would have emitted from the same textproto, byte-identically.
    function reencode(x)
        io = IOBuffer()
        Base.invokelatest(ProtoBufDescriptors.encode,
                          ProtoBufDescriptors.ProtoEncoder(io), x)
        return take!(io)
    end
    @test reencode(oz) == bytes_maybe_zero
    @test reencode(ou) == bytes_maybe_unset

    # Build the same two values directly and confirm. Constructor signature
    # is Outer(name, maybe, nested, packed_ints, choice) — `ci`/`cs` collapse
    # into the `choice` oneof field (Phase 6).
    nothing_outer = Base.invokelatest(sample_mod.Outer,
                                       "u", nothing, nothing, Int64[], nothing)
    zero_outer    = Base.invokelatest(sample_mod.Outer,
                                       "z", Int32(0), nothing, Int64[], nothing)
    @test reencode(nothing_outer) == bytes_maybe_unset
    @test reencode(zero_outer)    == bytes_maybe_zero
end
