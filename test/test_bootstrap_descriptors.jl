module TestBootstrapDescriptors

include("setup.jl")

@testset "bootstrap descriptors" begin
    # FileDescriptorSet for fixtures/proto/sample.proto. See fixtures/README.md.
    fdset = load_fdset("sample.pb")

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

    # FieldDescriptorProto.type — confirm value matches the INT32 enum
    # member (proto-side `TYPE_INT32`) the proto uses for `int32 a = 1`
    # in Inner. Codegen strips the enum-type prefix for in-Julia ergonomics
    # while preserving the wire-form name via `_enum_proto_prefix`.
    @test inner.field[1].type == G.var"FieldDescriptorProto.Type".INT32

    # Encode round-trip: re-decode of the re-encoded blob must observe the
    # same field values. (Bytes need not be identical: ProtoBuf.jl emits
    # message fields in struct-declaration order rather than proto-source
    # order, and enum fields still inherit the equal-to-default skip; both
    # are wire-format compatible but not byte-stable.)
    bytes = ProtocGen.encode(fdset)
    fdset2 = ProtocGen.decode(bytes, G.FileDescriptorSet)
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

end  # module TestBootstrapDescriptors
