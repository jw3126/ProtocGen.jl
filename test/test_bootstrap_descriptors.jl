@testset "bootstrap descriptors" begin
    # FileDescriptorSet for the following sample.proto, produced by
    # `protoc --descriptor_set_out=...`. Captured as bytes so the test does
    # not depend on protoc being installed.
    #
    #     syntax = "proto3";
    #     package sample;
    #     message Inner {
    #       int32 a = 1;
    #     }
    #     message Outer {
    #       string name = 1;
    #       optional int32 maybe = 2;
    #       Inner nested = 3;
    #       oneof choice {
    #         int32 ci = 4;
    #         string cs = 5;
    #       }
    #       repeated int64 packed_ints = 6;
    #     }
    sample_pb = UInt8[
        0x0a,0xee,0x01,0x0a,0x0c,0x73,0x61,0x6d,0x70,0x6c,0x65,0x2e,0x70,0x72,0x6f,0x74,
        0x6f,0x12,0x06,0x73,0x61,0x6d,0x70,0x6c,0x65,0x22,0x15,0x0a,0x05,0x49,0x6e,0x6e,
        0x65,0x72,0x12,0x0c,0x0a,0x01,0x61,0x18,0x01,0x20,0x01,0x28,0x05,0x52,0x01,0x61,
        0x22,0xb6,0x01,0x0a,0x05,0x4f,0x75,0x74,0x65,0x72,0x12,0x12,0x0a,0x04,0x6e,0x61,
        0x6d,0x65,0x18,0x01,0x20,0x01,0x28,0x09,0x52,0x04,0x6e,0x61,0x6d,0x65,0x12,0x19,
        0x0a,0x05,0x6d,0x61,0x79,0x62,0x65,0x18,0x02,0x20,0x01,0x28,0x05,0x48,0x01,0x52,
        0x05,0x6d,0x61,0x79,0x62,0x65,0x88,0x01,0x01,0x12,0x25,0x0a,0x06,0x6e,0x65,0x73,
        0x74,0x65,0x64,0x18,0x03,0x20,0x01,0x28,0x0b,0x32,0x0d,0x2e,0x73,0x61,0x6d,0x70,
        0x6c,0x65,0x2e,0x49,0x6e,0x6e,0x65,0x72,0x52,0x06,0x6e,0x65,0x73,0x74,0x65,0x64,
        0x12,0x10,0x0a,0x02,0x63,0x69,0x18,0x04,0x20,0x01,0x28,0x05,0x48,0x00,0x52,0x02,
        0x63,0x69,0x12,0x10,0x0a,0x02,0x63,0x73,0x18,0x05,0x20,0x01,0x28,0x09,0x48,0x00,
        0x52,0x02,0x63,0x73,0x12,0x1f,0x0a,0x0b,0x70,0x61,0x63,0x6b,0x65,0x64,0x5f,0x69,
        0x6e,0x74,0x73,0x18,0x06,0x20,0x03,0x28,0x03,0x52,0x0a,0x70,0x61,0x63,0x6b,0x65,
        0x64,0x49,0x6e,0x74,0x73,0x42,0x08,0x0a,0x06,0x63,0x68,0x6f,0x69,0x63,0x65,0x42,
        0x08,0x0a,0x06,0x5f,0x6d,0x61,0x79,0x62,0x65,0x62,0x06,0x70,0x72,0x6f,0x74,0x6f,
        0x33,
    ]

    G = ProtoBufDescriptors.google.protobuf
    fdset = ProtoBufDescriptors.decode(
        ProtoBufDescriptors.ProtoDecoder(IOBuffer(sample_pb)),
        G.FileDescriptorSet,
    )

    @test length(fdset.file) == 1
    fd = fdset.file[1]
    @test fd.name == "sample.proto"
    @test fd.package == "sample"
    @test fd.syntax == "proto3"
    @test length(fd.message_type) == 2

    inner = fd.message_type[1]
    @test inner.name == "Inner"
    @test length(inner.field) == 1
    @test inner.field[1].name == "a"
    @test inner.field[1].number == 1

    outer = fd.message_type[2]
    @test outer.name == "Outer"
    @test length(outer.field) == 6
    @test length(outer.oneof_decl) == 2
    @test outer.oneof_decl[1].name == "choice"
    @test outer.oneof_decl[2].name == "_maybe"

    fields_by_name = Dict(f.name => f for f in outer.field)

    # The headline bit: proto3 `optional` is detected as proto3_optional + a
    # synthetic oneof (the `_maybe` one above). proto2 `optional` scalars are
    # Union{Nothing,T} so an unset bit is `nothing`, not `false`.
    maybe = fields_by_name["maybe"]
    @test maybe.proto3_optional === true
    @test maybe.oneof_index == 1

    # Real oneof members reference the non-synthetic oneof.
    ci = fields_by_name["ci"]
    @test ci.proto3_optional !== true
    @test ci.oneof_index == 0

    # Plain proto3 scalar/message/repeated fields don't set proto3_optional.
    @test fields_by_name["name"].proto3_optional !== true
    @test fields_by_name["nested"].proto3_optional !== true
    @test fields_by_name["nested"].type_name == ".sample.Inner"
    @test fields_by_name["packed_ints"].proto3_optional !== true

    # FieldDescriptorProto.type uses the `#type` Symbol because `type` is a
    # Julia keyword. Confirm the value matches the TYPE_INT32 enum the proto
    # uses for `int32 a = 1` in Inner.
    @test getfield(inner.field[1], Symbol("#type")) ==
          G.var"FieldDescriptorProto.Type".TYPE_INT32

    # Encode round-trip: re-decode of the re-encoded blob must observe the
    # same field values. (Bytes need not be identical: ProtoBuf.jl emits
    # message fields in struct-declaration order rather than proto-source
    # order, and enum fields still inherit the equal-to-default skip; both
    # are wire-format compatible but not byte-stable.)
    out = IOBuffer()
    ProtoBufDescriptors.encode(ProtoBufDescriptors.ProtoEncoder(out), fdset)
    fdset2 = ProtoBufDescriptors.decode(
        ProtoBufDescriptors.ProtoDecoder(IOBuffer(take!(out))),
        G.FileDescriptorSet,
    )
    fd2 = fdset2.file[1]
    @test fd2.name == fd.name
    @test fd2.package == fd.package
    @test fd2.syntax == fd.syntax
    outer2 = fd2.message_type[2]
    f2_by_name = Dict(f.name => f for f in outer2.field)
    @test f2_by_name["maybe"].proto3_optional === true
    @test f2_by_name["maybe"].oneof_index == 1
    # Presence is preserved: fields that protoc set on the wire come back set,
    # and ones it left unset stay unset (e.g. proto3_optional on plain fields).
    @test f2_by_name["name"].proto3_optional !== true
end
