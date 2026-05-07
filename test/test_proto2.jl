@testset "Phase 6 — proto2 required + optional" begin
    # FileDescriptorSet for:
    #     syntax = "proto2";
    #     package p2;
    #     message Inner { required int32 v = 1; }
    #     message Wrap {
    #       required string name = 1;
    #       required Inner  nested = 2;
    #       optional int32  maybe = 3;
    #       optional string hint = 4;
    #     }
    p2_pb = UInt8[
        0x0a,0x8e,0x01,0x0a,0x08,0x70,0x32,0x2e,0x70,0x72,0x6f,0x74,0x6f,0x12,0x02,0x70,
        0x32,0x22,0x15,0x0a,0x05,0x49,0x6e,0x6e,0x65,0x72,0x12,0x0c,0x0a,0x01,0x76,0x18,
        0x01,0x20,0x02,0x28,0x05,0x52,0x01,0x76,0x22,0x67,0x0a,0x04,0x57,0x72,0x61,0x70,
        0x12,0x12,0x0a,0x04,0x6e,0x61,0x6d,0x65,0x18,0x01,0x20,0x02,0x28,0x09,0x52,0x04,
        0x6e,0x61,0x6d,0x65,0x12,0x21,0x0a,0x06,0x6e,0x65,0x73,0x74,0x65,0x64,0x18,0x02,
        0x20,0x02,0x28,0x0b,0x32,0x09,0x2e,0x70,0x32,0x2e,0x49,0x6e,0x6e,0x65,0x72,0x52,
        0x06,0x6e,0x65,0x73,0x74,0x65,0x64,0x12,0x14,0x0a,0x05,0x6d,0x61,0x79,0x62,0x65,
        0x18,0x03,0x20,0x01,0x28,0x05,0x52,0x05,0x6d,0x61,0x79,0x62,0x65,0x12,0x12,0x0a,
        0x04,0x68,0x69,0x6e,0x74,0x18,0x04,0x20,0x01,0x28,0x09,0x52,0x04,0x68,0x69,0x6e,
        0x74,
    ]
    # `protoc --encode=p2.Wrap` for: name "the-name", nested {v:7}, maybe:0, hint:"hi"
    p2_full_pb = UInt8[
        0x0a,0x08,0x74,0x68,0x65,0x2d,0x6e,0x61,0x6d,0x65,0x12,0x02,0x08,0x07,0x18,0x00,
        0x22,0x02,0x68,0x69,
    ]
    # `protoc --encode=p2.Wrap` for: name "n", nested {v:1}; optionals omitted.
    p2_minimal_pb = UInt8[
        0x0a,0x01,0x6e,0x12,0x02,0x08,0x01,
    ]

    G = ProtoBufDescriptors.google.protobuf
    GC = ProtoBufDescriptors.google.protobuf.compiler

    fdset = ProtoBufDescriptors.decode(
        ProtoBufDescriptors.ProtoDecoder(IOBuffer(p2_pb)),
        G.FileDescriptorSet,
    )
    request = GC.CodeGeneratorRequest(
        ["p2.proto"], nothing, fdset.file,
        G.FileDescriptorProto[], nothing,
    )
    req_io = IOBuffer()
    ProtoBufDescriptors.encode(ProtoBufDescriptors.ProtoEncoder(req_io), request)
    out_io = IOBuffer()
    response = ProtoBufDescriptors.run_plugin(IOBuffer(take!(req_io)), out_io)
    @test response.error === nothing
    f = response.file[1]

    # Generated source carries the right shapes.
    @test occursin("name::String", f.content)         # required scalar → bare type
    @test occursin("nested::Inner", f.content)        # required submessage → bare type
    @test occursin("maybe::Union{Nothing,Int32}", f.content)  # proto2 optional → presence
    @test occursin("hint::Union{Nothing,String}", f.content)
    @test occursin("_saw_name", f.content)
    @test occursin("required field", f.content)

    p2_mod = Module(:GeneratedP2)
    Core.eval(p2_mod, Meta.parseall(f.content))

    # Decode protoc-emitted bytes; explicit `maybe: 0` survives as `Int32(0)`,
    # and omitted optionals come back as `nothing`.
    full = Base.invokelatest(ProtoBufDescriptors.decode,
                             ProtoBufDescriptors.ProtoDecoder(IOBuffer(p2_full_pb)),
                             p2_mod.Wrap)
    @test full.name == "the-name"
    @test full.nested.v == 7
    @test full.maybe === Int32(0)
    @test full.hint  === "hi"

    minimal = Base.invokelatest(ProtoBufDescriptors.decode,
                                ProtoBufDescriptors.ProtoDecoder(IOBuffer(p2_minimal_pb)),
                                p2_mod.Wrap)
    @test minimal.name == "n"
    @test minimal.nested.v == 1
    @test minimal.maybe === nothing
    @test minimal.hint  === nothing

    # Re-encoded bytes match what protoc would have emitted, byte-identically.
    function reencode(x)
        io = IOBuffer()
        Base.invokelatest(ProtoBufDescriptors.encode,
                          ProtoBufDescriptors.ProtoEncoder(io), x)
        return take!(io)
    end
    @test reencode(full)    == p2_full_pb
    @test reencode(minimal) == p2_minimal_pb

    # Missing required → clear DecodeError. Hand-crafted bytes: only the
    # nested submessage (field 2 = {v: 1}); the `name` required field
    # (number 1) is absent.
    missing_name = UInt8[0x12, 0x02, 0x08, 0x01]
    err = try
        Base.invokelatest(ProtoBufDescriptors.decode,
                          ProtoBufDescriptors.ProtoDecoder(IOBuffer(missing_name)),
                          p2_mod.Wrap)
        nothing
    catch e
        e
    end
    @test err isa ProtoBufDescriptors.DecodeError
    @test occursin("required field", err.msg)
    @test occursin("name", err.msg)
end
