module TestConformanceCorpus

include("setup.jl")

# Patched copies of Google's golden conformance protos. The .proto files
# under fixtures/proto/ document exactly which upstream features were
# stripped (extensions, groups, recursion, WKT-typed fields, AliasedEnum)
# and why. This test exercises the surviving feature set end-to-end:
# every wire encoding × singular/repeated/packed/unpacked/map, the proto2
# oneof (set to one variant), the field-name-munge battery, and presence
# semantics for both an empty proto2 message (every nullable -> nothing)
# and an empty proto3 message (implicit-presence scalars -> default zero).

@testset "conformance corpus — proto2" begin
    response = run_codegen(
        "test_messages_proto2_patched.pb",
        ["test_messages_proto2_patched.proto"],
    )
    @test response.error === nothing
    @test length(response.file) == 1
    f = response.file[1]
    @test f.name == "test_messages_proto2_patched_pb.jl"

    p2 = eval_generated(f.content, :GeneratedConfP2)
    M = p2.TestAllTypesProto2

    # `reserved 1000 to 9999;` in the schema → reserved_fields metadata
    # carries the range. Single-number reservations would collapse to
    # bare Int; this one stays a UnitRange.
    @test ProtocGen.reserved_fields(M) ==
        (names = String[], numbers = Union{Int,UnitRange{Int}}[1000:9999])

    full_pb  = fixture("test_messages_proto2_full.pb")
    empty_pb = fixture("test_messages_proto2_empty.pb")
    @test isempty(empty_pb)

    # Populated decode: spot-check every category. The full field-by-field
    # check happens implicitly via the round-trip loop below — what we
    # assert here is that *the right things landed in the right places*.
    full = decode_latest(M, full_pb)

    # Singular scalars across all 16 wire encodings.
    @test full.optional_int32    == Int32(-123)
    @test full.optional_int64    == Int64(-123456789012)
    @test full.optional_uint32   == UInt32(4123456789)
    @test full.optional_uint64   == UInt64(12345678901234567890)
    @test full.optional_sint32   == Int32(-200)
    @test full.optional_sint64   == Int64(-200000000000)
    @test full.optional_fixed32  == UInt32(0xCAFEBABE)
    @test full.optional_fixed64  == UInt64(0xDEADBEEFCAFEBABE)
    @test full.optional_sfixed32 == Int32(-2147483647)
    @test full.optional_sfixed64 == Int64(-9223372036854775807)
    @test isapprox(full.optional_float, 3.14f0; atol = 1.0f-6)
    @test isapprox(full.optional_double, 2.718281828459045; atol = 1e-12)
    @test full.optional_bool     === true
    @test full.optional_string   == "héllo"
    @test full.optional_bytes    == UInt8[0xff, 0x00, 0xab]

    # Singular submessage and enum.
    @test full.optional_nested_message !== nothing
    @test full.optional_nested_message.a == Int32(42)
    @test full.optional_foreign_message !== nothing
    @test full.optional_foreign_message.c == Int32(99)
    @test full.optional_nested_enum  == p2.var"TestAllTypesProto2.NestedEnum".NEG
    @test full.optional_foreign_enum == p2.ForeignEnumProto2.FOREIGN_BAR

    # Repeated, packed, unpacked.
    @test full.repeated_int32 == Int32[1, 2, 3]
    @test full.repeated_string == ["a", "b"]
    @test length(full.repeated_nested_message) == 2
    @test full.repeated_nested_message[1].a == 10
    @test full.repeated_nested_enum ==
        [p2.var"TestAllTypesProto2.NestedEnum".FOO,
         p2.var"TestAllTypesProto2.NestedEnum".BAR,
         p2.var"TestAllTypesProto2.NestedEnum".NEG]
    @test full.packed_int32   == Int32[1, 2, 3]
    @test full.packed_bool    == [true, false]
    @test full.unpacked_int32 == Int32[1, 2]

    # Maps.
    @test full.map_int32_int32 == Dict(Int32(1) => Int32(100), Int32(2) => Int32(200))
    @test full.map_string_string == Dict("k1" => "v1", "k2" => "v2")
    @test haskey(full.map_string_nested_message, "k")
    @test full.map_string_nested_message["k"].a == Int32(1)
    @test full.map_bool_bool == Dict(true => false, false => true)

    # Oneof — set to oneof_string in the fixture.
    @test full.oneof_field !== nothing
    @test full.oneof_field.name === :oneof_string
    @test full.oneof_field.value == "hello-oneof"

    # Default-annotated fields: wire path ignores `[default = X]`. Setting
    # any of them in the fixture must round-trip the *fixture* value.
    @test full.default_int32  == Int32(1)
    @test full.default_string == "override"
    @test full.default_bool   === false  # upstream default is true; we set false

    # Field-name munge battery — pick a few of the ugliest.
    @test full._field_name3   == Int32(3)
    @test full.field__name4_  == Int32(4)
    @test full.__field_name13 == Int32(13)
    @test full.FIELD_NAME11   == Int32(11)

    # Re-encode is byte-identical to the protoc fixture. Map fields are
    # OrderedDict so insertion order (= wire order on decode) survives the
    # round-trip, and negative enums encode as 10-byte sign-extended varints
    # to match protoc.
    @test encode_latest(full) == full_pb

    # Empty: every Union{Nothing,T} optional → nothing, repeated/maps
    # empty, oneof nothing, and re-encode is zero bytes.
    empty = decode_latest(M, empty_pb)
    @test empty.optional_int32 === nothing
    @test empty.optional_string === nothing
    @test empty.optional_bytes === nothing
    @test empty.optional_nested_message === nothing
    @test empty.optional_foreign_message === nothing
    @test empty.oneof_field === nothing
    @test isempty(empty.repeated_int32)
    @test isempty(empty.repeated_nested_message)
    @test isempty(empty.packed_int32)
    @test isempty(empty.unpacked_int32)
    @test isempty(empty.map_int32_int32)
    @test isempty(empty.map_string_nested_message)
    @test empty.default_int32 === nothing  # presence wins over [default = X]
    @test isempty(encode_latest(empty))
end

@testset "conformance corpus — proto3" begin
    response = run_codegen(
        "test_messages_proto3.pb",
        ["test_messages_proto3.proto"],
    )
    @test response.error === nothing
    @test length(response.file) == 1
    f = response.file[1]
    @test f.name == "test_messages_proto3_pb.jl"

    # The proto3 conformance file is now verbatim upstream. AliasedEnum
    # uses `option allow_alias = true;` — codegen emits the canonical
    # names via @enumx and the aliases as `const`s inside the enum
    # module, all binding to the same enum *instance*. The other
    # features under test: cross-package import emission for WKT-typed
    # fields, abstract supertype + forwarding decode for the
    # `recursive_message` / `corecursive` cycle.
    @test occursin("import ProtocGen.google.protobuf as google_protobuf",
                   f.content)
    @test occursin("optional_timestamp::Union{Nothing,google_protobuf.Timestamp}",
                   f.content)
    @test occursin("recursive_message::Union{Nothing,AbstractTestAllTypesProto3}",
                   f.content)
    @test occursin("@enumx var\"TestAllTypesProto3.AliasedEnum\" ALIAS_FOO=0 ALIAS_BAR=1 ALIAS_BAZ=2",
                   f.content)
    @test occursin("Core.eval(var\"TestAllTypesProto3.AliasedEnum\", :(const MOO = ALIAS_BAZ))",
                   f.content)

    p3 = eval_generated(f.content, :GeneratedConfP3)
    M = p3.TestAllTypesProto3
    AE = p3.var"TestAllTypesProto3.AliasedEnum"
    # Aliases bind to the same instance as the canonical name.
    @test AE.MOO === AE.ALIAS_BAZ
    @test AE.moo === AE.ALIAS_BAZ
    @test AE.bAz === AE.ALIAS_BAZ
    # Display canonicalizes (`Symbol(MOO)` returns `:ALIAS_BAZ`).
    @test Symbol(AE.MOO) === :ALIAS_BAZ

    @test ProtocGen.reserved_fields(M) ==
        (names = String[], numbers = Union{Int,UnitRange{Int}}[501:510])

    full_pb  = fixture("test_messages_proto3_full.pb")
    empty_pb = fixture("test_messages_proto3_empty.pb")
    @test isempty(empty_pb)

    full = decode_latest(M, full_pb)

    # Implicit-presence scalars are bare-typed (no Union{Nothing,...}).
    @test full.optional_int32    === Int32(-123)
    @test full.optional_int64    === Int64(-123456789012)
    @test full.optional_uint32   === UInt32(4123456789)
    @test full.optional_uint64   === UInt64(12345678901234567890)
    @test full.optional_sint32   === Int32(-200)
    @test full.optional_sint64   === Int64(-200000000000)
    @test full.optional_fixed32  === UInt32(0xCAFEBABE)
    @test full.optional_fixed64  === UInt64(0xDEADBEEFCAFEBABE)
    @test full.optional_sfixed32 === Int32(-2147483647)
    @test full.optional_sfixed64 === Int64(-9223372036854775807)
    @test isapprox(full.optional_float, 3.14f0; atol = 1.0f-6)
    @test isapprox(full.optional_double, 2.718281828459045; atol = 1e-12)
    @test full.optional_bool     === true
    @test full.optional_string   == "héllo"
    @test full.optional_bytes    == UInt8[0xff, 0x00, 0xab]

    # Singular submessage and enum.
    @test full.optional_nested_message !== nothing
    @test full.optional_nested_message.a == Int32(42)
    @test full.optional_foreign_message !== nothing
    @test full.optional_foreign_message.c == Int32(99)
    @test full.optional_nested_enum  == p3.var"TestAllTypesProto3.NestedEnum".NEG
    @test full.optional_foreign_enum == p3.ForeignEnum.FOREIGN_BAR
    # Aliased enum: txtpb sets the field to `MOO`, which is an alias for
    # `ALIAS_BAZ`. Decoded value is the canonical instance.
    @test full.optional_aliased_enum === AE.ALIAS_BAZ
    @test full.optional_aliased_enum === AE.MOO   # by definition of the alias

    # Repeated.
    @test full.repeated_int32 == Int32[1, 2, 3]
    @test full.repeated_string == ["a", "b"]
    @test length(full.repeated_nested_message) == 2
    @test full.repeated_nested_message[1].a == 10
    @test full.repeated_nested_enum ==
        [p3.var"TestAllTypesProto3.NestedEnum".FOO,
         p3.var"TestAllTypesProto3.NestedEnum".BAR,
         p3.var"TestAllTypesProto3.NestedEnum".NEG]
    @test full.packed_int32   == Int32[1, 2, 3]
    @test full.unpacked_int32 == Int32[1, 2]

    # Maps.
    @test full.map_int32_int32 == Dict(Int32(1) => Int32(100), Int32(2) => Int32(200))
    @test full.map_string_string == Dict("k1" => "v1", "k2" => "v2")
    @test full.map_bool_bool == Dict(true => false, false => true)
    @test haskey(full.map_string_nested_message, "k")
    @test full.map_string_nested_message["k"].a == Int32(1)

    # Oneof.
    @test full.oneof_field !== nothing
    @test full.oneof_field.name === :oneof_string
    @test full.oneof_field.value == "hello-oneof"

    # Field-name munge battery.
    @test full._field_name3   == Int32(3)
    @test full.field__name4_  == Int32(4)
    @test full.__field_name13 == Int32(13)
    @test full.FIELD_NAME11   == Int32(11)

    # Re-encode is byte-identical to the protoc fixture. Same OrderedDict +
    # negative-enum encode reasoning as the proto2 case above.
    @test encode_latest(full) == full_pb

    # Empty: implicit-presence scalars are zero, repeated/maps empty,
    # oneof nothing, re-encode is zero bytes. (proto3 makes "unset"
    # indistinguishable from "set to default zero" on the wire — this is
    # not the proto3 *explicit* optional codepath, which test_presence.jl
    # already covers.)
    empty = decode_latest(M, empty_pb)
    @test empty.optional_int32 === Int32(0)
    @test empty.optional_string == ""
    @test empty.optional_bytes == UInt8[]
    @test empty.optional_bool === false
    @test empty.optional_nested_message === nothing  # singular submessage stays nullable in proto3
    @test empty.optional_nested_enum == p3.var"TestAllTypesProto3.NestedEnum".FOO  # first value
    @test empty.oneof_field === nothing
    @test isempty(empty.repeated_int32)
    @test isempty(empty.repeated_nested_message)
    @test isempty(empty.packed_int32)
    @test isempty(empty.unpacked_int32)
    @test isempty(empty.map_int32_int32)
    @test isempty(empty.map_string_nested_message)
    @test isempty(encode_latest(empty))
end

end  # module TestConformanceCorpus
