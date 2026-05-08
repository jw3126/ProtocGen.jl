# JSON mapping — Phase 12a / 12b tests.
#
# The bootstrap WKT types double as a handy fixture set: they cover every
# scalar wire form (Int64 / Int32 / Bool / String / Bytes / Float / Enum)
# and various aggregations (repeated, nested submessage, map, oneof). For
# now we exercise the *generic* walker only — Phase 12c lands the
# WKT-specific canonical forms (Timestamp → "2025-…", Duration → "1.5s",
# …) and those tests will move to a dedicated `test_json_wkt.jl`.

module TestJSON

using Test
using ProtoBufDescriptors
using ProtoBufDescriptors: encode_json, decode_json
import JSON

const _G  = ProtoBufDescriptors.google.protobuf

# -----------------------------------------------------------------------------
# Helper: parse encoded JSON to a Dict for structural assertions.
# -----------------------------------------------------------------------------

_parsed(x) = JSON.parse(encode_json(x))

@testset "JSON" begin

    # -------------------------------------------------------------------------
    @testset "scalars: 32-bit ints emitted as JSON numbers" begin
        # Timestamp.nanos is Int32 — pick a non-default to force emission.
        ts = _G.Timestamp(Int64(0), Int32(42))
        d = _parsed(ts)
        @test d == Dict("nanos" => 42)
        # Round-trip
        back = decode_json(_G.Timestamp, encode_json(ts))
        @test back.seconds == 0  # default
        @test back.nanos == 42
    end

    @testset "scalars: 64-bit ints emitted as JSON strings" begin
        # Timestamp.seconds is Int64.
        ts = _G.Timestamp(Int64(1234567890123), Int32(0))
        d = _parsed(ts)
        @test d == Dict("seconds" => "1234567890123")
        # Decode accepts string form
        back = decode_json(_G.Timestamp, encode_json(ts))
        @test back.seconds == 1234567890123
        # …and number form (per spec — must accept either on parse).
        back2 = decode_json(_G.Timestamp, "{\"seconds\": 7}")
        @test back2.seconds == 7
    end

    @testset "scalars: bool / string / float / double / bytes" begin
        # BoolValue
        b = _G.BoolValue(true)
        @test _parsed(b) == Dict("value" => true)
        @test decode_json(_G.BoolValue, "{\"value\": true}").value == true
        @test decode_json(_G.BoolValue, "{\"value\": false}").value == false

        # StringValue
        s = _G.StringValue("hello \"world\"")
        @test _parsed(s) == Dict("value" => "hello \"world\"")
        @test decode_json(_G.StringValue, encode_json(s)).value == "hello \"world\""

        # FloatValue (Float32)
        f = _G.FloatValue(Float32(3.14))
        @test _parsed(f)["value"] ≈ 3.14 atol = 1e-6
        # DoubleValue (Float64)
        df = _G.DoubleValue(2.71828)
        @test _parsed(df)["value"] ≈ 2.71828 atol = 1e-9
        @test decode_json(_G.DoubleValue, encode_json(df)).value ≈ 2.71828

        # BytesValue → base64
        bv = _G.BytesValue(UInt8[0x68, 0x65, 0x6c, 0x6c, 0x6f])  # "hello"
        @test _parsed(bv) == Dict("value" => "aGVsbG8=")
        @test decode_json(_G.BytesValue, encode_json(bv)).value == UInt8[0x68, 0x65, 0x6c, 0x6c, 0x6f]
    end

    @testset "floats: NaN and ±Infinity emitted as JSON strings" begin
        @test _parsed(_G.DoubleValue(NaN))["value"] == "NaN"
        @test _parsed(_G.DoubleValue(Inf))["value"]  == "Infinity"
        @test _parsed(_G.DoubleValue(-Inf))["value"] == "-Infinity"
        @test isnan(decode_json(_G.DoubleValue, "{\"value\": \"NaN\"}").value)
        @test decode_json(_G.DoubleValue, "{\"value\": \"Infinity\"}").value == Inf
        @test decode_json(_G.DoubleValue, "{\"value\": \"-Infinity\"}").value == -Inf
    end

    @testset "default scalars are omitted on encode" begin
        # Timestamp(0, 0) — both fields default → empty object.
        @test _parsed(_G.Timestamp(Int64(0), Int32(0))) == Dict{String,Any}()
        # Decoding back from empty restores defaults.
        back = decode_json(_G.Timestamp, "{}")
        @test back.seconds == 0
        @test back.nanos == 0
    end

    @testset "JSON null → field defaults" begin
        back = decode_json(_G.Timestamp, "{\"seconds\": null, \"nanos\": 7}")
        @test back.seconds == 0
        @test back.nanos == 7
    end

    @testset "decode accepts snake_case alias as well as camelCase" begin
        # FieldDescriptorProto has plenty of multi-word fields.
        # Use UninterpretedOption.NamePart: name_part / is_extension.
        T = _G.var"UninterpretedOption.NamePart"
        # camelCase form
        x1 = decode_json(T, "{\"namePart\": \"hi\", \"isExtension\": true}")
        @test x1.name_part == "hi"
        @test x1.is_extension == true
        # snake_case form (the original proto field name)
        x2 = decode_json(T, "{\"name_part\": \"hi\", \"is_extension\": true}")
        @test x2.name_part == "hi"
        @test x2.is_extension == true
    end

    @testset "encode emits camelCase keys" begin
        T = _G.var"UninterpretedOption.NamePart"
        d = _parsed(T("foo", true))
        @test haskey(d, "namePart")
        @test haskey(d, "isExtension")
        @test !haskey(d, "name_part")
    end

    @testset "repeated fields → JSON arrays" begin
        # FieldMask.paths is `repeated string`
        fm = _G.FieldMask(["foo", "bar.baz", "qux"])
        d = _parsed(fm)
        @test d == Dict("paths" => ["foo", "bar.baz", "qux"])
        back = decode_json(_G.FieldMask, encode_json(fm))
        @test back.paths == ["foo", "bar.baz", "qux"]
    end

    @testset "enums emit canonical name; decode accepts string or int" begin
        # FieldDescriptorProto.Type — pick TYPE_STRING (=9).
        E = _G.var"FieldDescriptorProto.Type"
        v = E.TYPE_STRING
        # Our encoder emits as string. We can't easily build a full
        # FieldDescriptorProto here without all required-for-defaults; instead
        # test the value-level dispatch directly.
        io = IOBuffer()
        ProtoBufDescriptors._encode_json_value(io, v)
        @test String(take!(io)) == "\"TYPE_STRING\""
        # String → enum
        @test ProtoBufDescriptors._decode_json_value(typeof(v), "TYPE_STRING") === v
        # Int → enum
        @test ProtoBufDescriptors._decode_json_value(typeof(v), 9) === v
    end

    @testset "nested submessage" begin
        # Type has a nested SourceContext field (cross-file ref). Set
        # source_context to a non-default; encode/decode round-trip
        # should preserve nested structure.
        sc = _G.SourceContext("foo.proto")
        # `Type` is the message type name; build with required fields blank.
        # Skipping `Type` because it's complex (Type{Field}, etc.). Just
        # test SourceContext alone.
        d = _parsed(sc)
        @test d == Dict("fileName" => "foo.proto")
        @test decode_json(_G.SourceContext, encode_json(sc)).file_name == "foo.proto"
    end

    @testset "strict mode rejects unknown JSON keys; ignore_unknown_fields skips" begin
        bad = "{\"seconds\": 5, \"nanos\": 6, \"unknown_field\": [1,2,3]}"
        # Default = strict.
        @test_throws ArgumentError decode_json(_G.Timestamp, bad)
        # Opt in to lenient.
        back = decode_json(_G.Timestamp, bad; ignore_unknown_fields = true)
        @test back.seconds == 5
        @test back.nanos == 6
    end

    @testset "oneof: active member is flattened into parent JSON" begin
        # Value.kind: oneof of 6 members — exercise three.
        v_str = _G.Value(ProtoBufDescriptors.OneOf(:string_value, "hi"))
        @test JSON.parse(encode_json(v_str)) == Dict("stringValue" => "hi")
        v_num = _G.Value(ProtoBufDescriptors.OneOf(:number_value, 3.5))
        @test JSON.parse(encode_json(v_num)) == Dict("numberValue" => 3.5)
        v_bool = _G.Value(ProtoBufDescriptors.OneOf(:bool_value, true))
        @test JSON.parse(encode_json(v_bool)) == Dict("boolValue" => true)

        # Round-trip every variant.
        for v in (v_str, v_num, v_bool)
            back = decode_json(_G.Value, encode_json(v))
            @test back.kind isa ProtoBufDescriptors.OneOf
            @test back.kind.name == v.kind.name
            @test back.kind.value == v.kind.value
        end
    end

    @testset "oneof: unset → JSON omits the parent key entirely" begin
        v = _G.Value(nothing)
        @test JSON.parse(encode_json(v)) == Dict{String,Any}()
        back = decode_json(_G.Value, encode_json(v))
        @test back.kind === nothing
    end

    @testset "maps: string-keyed map round-trips through JSON object" begin
        # Struct.fields :: OrderedDict{String, Value}
        od = ProtoBufDescriptors.OrderedDict{String,_G.Value}(
            "a" => _G.Value(ProtoBufDescriptors.OneOf(:number_value, 1.0)),
            "b" => _G.Value(ProtoBufDescriptors.OneOf(:string_value, "x")),
        )
        s = _G.Struct(od)
        encoded = encode_json(s)
        @test JSON.parse(encoded) == Dict(
            "fields" => Dict("a" => Dict("numberValue" => 1.0),
                             "b" => Dict("stringValue" => "x")),
        )
        back = decode_json(_G.Struct, encoded)
        @test sort(collect(keys(back.fields))) == ["a", "b"]
        @test back.fields["a"].kind.value == 1.0
        @test back.fields["b"].kind.value == "x"
    end

    @testset "map keys: stringification on encode, parsing on decode" begin
        # Exercise via the value-level dispatch directly so we don't have
        # to hand-construct a corpus message with each key type.
        let io = IOBuffer()
            ProtoBufDescriptors._encode_json_value(io, Dict{Bool,String}(true => "t", false => "f"))
            d = JSON.parse(String(take!(io)))
            @test d == Dict("true" => "t", "false" => "f")
        end
        let io = IOBuffer()
            ProtoBufDescriptors._encode_json_value(io, Dict{Int32,String}(Int32(1) => "one", Int32(-2) => "neg"))
            d = JSON.parse(String(take!(io)))
            @test d == Dict("1" => "one", "-2" => "neg")
        end
        # Decode side: invalid bool key raises.
        @test_throws ArgumentError ProtoBufDescriptors._decode_map_key(Bool, "yes")
        @test ProtoBufDescriptors._decode_map_key(Int32, "42") === Int32(42)
        @test ProtoBufDescriptors._decode_map_key(Bool, "true") === true
    end

    @testset "ignore_unknown_fields propagates into nested decoders" begin
        # Struct.fields[*] is decoded via the nested-message path. An
        # unknown key on a nested Value should be tolerated when the
        # flag is set on the outer call.
        json = """{"fields": {"a": {"numberValue": 1.0, "unknownInner": 99}}}"""
        @test_throws ArgumentError decode_json(_G.Struct, json)
        back = decode_json(_G.Struct, json; ignore_unknown_fields = true)
        @test back.fields["a"].kind.value == 1.0
    end

end

end # module
