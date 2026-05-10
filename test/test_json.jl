# Protobuf-JSON mapping tests.
#
# Two layers:
#
#   1. Generic walker (Phase 12a/b) — exercised against non-WKT
#      bootstrap types like `FieldDescriptorProto`, `UninterpretedOption`,
#      and `SourceContext`. They cover scalars (incl. int64 / uint64 /
#      bytes / float / enum), nested submessage, repeated, and map-style
#      structural shapes without colliding with the WKT specials.
#
#   2. WKT special forms (Phase 12c) — Wrappers, Timestamp, Duration,
#      FieldMask, Empty, Struct, Value, ListValue, NullValue all have
#      their own canonical JSON. The `WKT:` testsets verify each.

module TestJSON

using Test
using ProtoBufDescriptors
using ProtoBufDescriptors: encode_json, decode_json, OneOf, OrderedDict
import JSON

const _G = ProtoBufDescriptors.google.protobuf

_parsed(x) = JSON.parse(encode_json(x))

# Build a message of type `T` from `default_values(T)`, with the given
# overrides merged in. Lets us touch only the fields a test cares about
# without listing every other slot as `nothing`.
function _make(::Type{T}; overrides...) where {T}
    d = ProtoBufDescriptors.default_values(T)
    merged = merge(d, NamedTuple(overrides))
    return T((merged[n] for n in fieldnames(T))...)
end

@testset "JSON" begin

    # -------------------------------------------------------------------------
    # Generic walker (Phase 12a/b) over non-WKT bootstrap types.
    # -------------------------------------------------------------------------

    @testset "scalars: 32-bit int emitted as JSON number" begin
        # FieldDescriptorProto.number :: Union{Nothing,Int32}. We override
        # only `name` and `number`; everything else (including the
        # required-with-default enums) comes from `default_values`.
        f = _make(_G.FieldDescriptorProto; name = "name", number = Int32(7))
        d = _parsed(f)
        @test d["name"] == "name"
        @test d["number"] == 7
    end

    @testset "scalars: 64-bit ints emitted as JSON strings" begin
        # UninterpretedOption.positive_int_value :: Union{Nothing,UInt64};
        # negative_int_value :: Union{Nothing,Int64}.
        u = _G.UninterpretedOption(
            _G.var"UninterpretedOption.NamePart"[],
            nothing,                           # identifier_value
            UInt64(123456789012345),           # positive_int_value
            Int64(-987654321098765),           # negative_int_value
            nothing,                           # double_value
            nothing,                           # string_value
            nothing,                           # aggregate_value
        )
        d = _parsed(u)
        @test d["positiveIntValue"] == "123456789012345"
        @test d["negativeIntValue"] == "-987654321098765"
        # Decode accepts string and number forms for 64-bit.
        back = decode_json(_G.UninterpretedOption,
            "{\"positiveIntValue\": \"42\", \"negativeIntValue\": -7}")
        @test back.positive_int_value == 42
        @test back.negative_int_value == -7
    end

    @testset "scalars: float / double / bytes / string" begin
        # UninterpretedOption.double_value :: Union{Nothing,Float64}
        u = _G.UninterpretedOption(
            _G.var"UninterpretedOption.NamePart"[],
            nothing, nothing, nothing,
            2.71828,
            nothing,
            nothing,
        )
        d = _parsed(u)
        @test d["doubleValue"] ≈ 2.71828

        # bytes (UninterpretedOption.string_value)
        u2 = _G.UninterpretedOption(
            _G.var"UninterpretedOption.NamePart"[],
            nothing, nothing, nothing, nothing,
            UInt8[0x68, 0x69],   # "hi" → "aGk="
            nothing,
        )
        @test _parsed(u2)["stringValue"] == "aGk="
        back = decode_json(_G.UninterpretedOption,
            "{\"stringValue\": \"aGk=\"}")
        @test back.string_value == UInt8[0x68, 0x69]

        # string (aggregate_value)
        u3 = _G.UninterpretedOption(
            _G.var"UninterpretedOption.NamePart"[],
            nothing, nothing, nothing, nothing, nothing,
            "hello \"world\"",
        )
        @test _parsed(u3)["aggregateValue"] == "hello \"world\""
    end

    @testset "floats: NaN and ±Infinity emitted as JSON strings" begin
        u_nan = _G.UninterpretedOption(_G.var"UninterpretedOption.NamePart"[],
            nothing, nothing, nothing, NaN, nothing, nothing)
        @test _parsed(u_nan)["doubleValue"] == "NaN"

        u_inf = _G.UninterpretedOption(_G.var"UninterpretedOption.NamePart"[],
            nothing, nothing, nothing, Inf, nothing, nothing)
        @test _parsed(u_inf)["doubleValue"] == "Infinity"

        u_ninf = _G.UninterpretedOption(_G.var"UninterpretedOption.NamePart"[],
            nothing, nothing, nothing, -Inf, nothing, nothing)
        @test _parsed(u_ninf)["doubleValue"] == "-Infinity"

        @test isnan(decode_json(_G.UninterpretedOption,
            "{\"doubleValue\": \"NaN\"}").double_value)
        @test decode_json(_G.UninterpretedOption,
            "{\"doubleValue\": \"Infinity\"}").double_value == Inf
    end

    @testset "default fields are omitted on encode" begin
        # UninterpretedOption.NamePart has only `name_part::String` and
        # `is_extension::Bool`, both required-with-default. Default
        # construction → empty struct → empty JSON object.
        T = _G.var"UninterpretedOption.NamePart"
        @test _parsed(_make(T)) == Dict{String,Any}()
    end

    @testset "presence is preserved on JSON encode even at default value" begin
        # FieldDescriptorProto.name :: Union{Nothing,String}. Setting it
        # to "" is presence-asserted (different from unset = nothing)
        # and MUST emit on JSON per the protobuf spec. The Phase 12a
        # default-skip predicate would otherwise drop it; the fix in
        # `_encode_json_message` is to disable default-skip for fields
        # whose declared type is `Union{Nothing,X}`.
        f_set   = _make(_G.FieldDescriptorProto; name = "")
        f_unset = _make(_G.FieldDescriptorProto)  # name stays nothing
        @test  haskey(_parsed(f_set),   "name") && _parsed(f_set)["name"]   == ""
        @test !haskey(_parsed(f_unset), "name")
        # Round-trip preserves the empty-string presence.
        @test decode_json(_G.FieldDescriptorProto, encode_json(f_set)).name == ""
        @test decode_json(_G.FieldDescriptorProto, encode_json(f_unset)).name === nothing
    end

    @testset "JSON null on a presence-bearing field → use default" begin
        back = decode_json(_G.FieldDescriptorProto,
            "{\"name\": \"foo\", \"number\": null}")
        @test back.name == "foo"
        @test back.number === nothing  # default for the optional field
    end

    @testset "decode accepts snake_case alias as well as camelCase" begin
        T = _G.var"UninterpretedOption.NamePart"
        x_camel = decode_json(T, "{\"namePart\": \"hi\", \"isExtension\": true}")
        x_snake = decode_json(T, "{\"name_part\": \"hi\", \"is_extension\": true}")
        @test x_camel.name_part == "hi"      == x_snake.name_part
        @test x_camel.is_extension == true   == x_snake.is_extension
    end

    @testset "encode emits camelCase keys" begin
        T = _G.var"UninterpretedOption.NamePart"
        d = _parsed(T("foo", true))
        @test haskey(d, "namePart")
        @test haskey(d, "isExtension")
        @test !haskey(d, "name_part")
    end

    @testset "repeated fields → JSON arrays" begin
        # FileDescriptorProto.dependency :: repeated string.
        f = _make(_G.FileDescriptorProto; dependency = ["a.proto", "b.proto"])
        @test _parsed(f)["dependency"] == ["a.proto", "b.proto"]
    end

    @testset "enums emit canonical name; decode accepts string or int" begin
        E = _G.var"FieldDescriptorProto.Type"
        v = E.TYPE_STRING
        io = IOBuffer()
        ProtoBufDescriptors._encode_json_value(io, v)
        @test String(take!(io)) == "\"TYPE_STRING\""
        @test ProtoBufDescriptors._decode_json_value(typeof(v), "TYPE_STRING") === v
        @test ProtoBufDescriptors._decode_json_value(typeof(v), 9) === v
    end

    @testset "nested submessage" begin
        sc = _G.SourceContext("foo.proto")
        @test _parsed(sc) == Dict("fileName" => "foo.proto")
        @test decode_json(_G.SourceContext, encode_json(sc)).file_name == "foo.proto"
    end

    @testset "strict mode rejects unknown JSON keys; ignore_unknown_fields skips" begin
        bad = "{\"name\": \"x\", \"unknownField\": 99}"
        @test_throws ArgumentError decode_json(_G.FieldDescriptorProto, bad)
        back = decode_json(_G.FieldDescriptorProto, bad; ignore_unknown_fields = true)
        @test back.name == "x"
    end

    # -------------------------------------------------------------------------
    # Phase 12c — WKT special forms.
    # -------------------------------------------------------------------------

    @testset "WKT: wrappers emit/parse as bare scalar" begin
        @test encode_json(_G.BoolValue(true))  == "true"
        @test encode_json(_G.BoolValue(false)) == "false"
        @test decode_json(_G.BoolValue, "true").value  == true
        @test decode_json(_G.BoolValue, "false").value == false

        @test JSON.parse(encode_json(_G.StringValue("hi"))) == "hi"
        @test decode_json(_G.StringValue, "\"hi\"").value == "hi"

        @test encode_json(_G.BytesValue(UInt8[0x68, 0x69])) == "\"aGk=\""
        @test decode_json(_G.BytesValue, "\"aGk=\"").value == UInt8[0x68, 0x69]

        @test encode_json(_G.Int32Value(Int32(-7))) == "-7"
        @test decode_json(_G.Int32Value, "42").value === Int32(42)

        @test encode_json(_G.Int64Value(Int64(123456789012345))) == "\"123456789012345\""
        @test decode_json(_G.Int64Value, "\"42\"").value == 42
        @test decode_json(_G.Int64Value, "42").value == 42

        @test encode_json(_G.UInt32Value(UInt32(99))) == "99"
        @test encode_json(_G.UInt64Value(UInt64(99))) == "\"99\""

        @test JSON.parse(encode_json(_G.DoubleValue(2.5))) == 2.5
        @test decode_json(_G.DoubleValue, "2.5").value ≈ 2.5
        @test isnan(decode_json(_G.DoubleValue, "\"NaN\"").value)
        @test decode_json(_G.DoubleValue, "\"Infinity\"").value == Inf
    end

    @testset "WKT: Timestamp RFC 3339" begin
        ts = _G.Timestamp(Int64(1715188800), Int32(123456789))
        s = encode_json(ts)
        @test occursin(r"^\"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z\"$", s)
        back = decode_json(_G.Timestamp, s)
        @test back.seconds == ts.seconds
        @test back.nanos   == ts.nanos
        # No fractional when nanos == 0.
        @test !occursin('.', encode_json(_G.Timestamp(Int64(1715188800), Int32(0))))
        # Fractional precision picks 3 / 6 / 9 trailing digits.
        @test occursin(".100Z",       encode_json(_G.Timestamp(Int64(0), Int32(100_000_000))))
        @test occursin(".000123Z",    encode_json(_G.Timestamp(Int64(0), Int32(123_000))))
        @test occursin(".000000007Z", encode_json(_G.Timestamp(Int64(0), Int32(7))))
        # Timezone offset on parse normalizes to UTC.
        back_tz = decode_json(_G.Timestamp, "\"2024-05-08T00:00:00+02:00\"")
        @test back_tz.seconds == decode_json(_G.Timestamp, "\"2024-05-07T22:00:00Z\"").seconds
    end

    @testset "WKT: Duration string" begin
        @test encode_json(_G.Duration(Int64(0), Int32(0)))         == "\"0s\""
        @test encode_json(_G.Duration(Int64(1), Int32(500_000_000))) == "\"1.500s\""
        @test encode_json(_G.Duration(Int64(-1), Int32(-500_000_000))) == "\"-1.500s\""
        @test encode_json(_G.Duration(Int64(3), Int32(1)))         == "\"3.000000001s\""
        for d in (_G.Duration(Int64(0), Int32(0)),
                  _G.Duration(Int64(7), Int32(123_000_000)),
                  _G.Duration(Int64(-12), Int32(-500_000_000)))
            back = decode_json(_G.Duration, encode_json(d))
            @test back.seconds == d.seconds
            @test back.nanos   == d.nanos
        end
    end

    @testset "WKT: FieldMask comma-joined camelCase paths" begin
        fm = _G.FieldMask(["foo_bar", "baz", "x_y_z"])
        @test encode_json(fm) == "\"fooBar,baz,xYZ\""
        back = decode_json(_G.FieldMask, "\"fooBar,baz,xYZ\"")
        @test back.paths == ["foo_bar", "baz", "x_y_z"]
        @test encode_json(_G.FieldMask(String[])) == "\"\""
        @test decode_json(_G.FieldMask, "\"\"").paths == String[]
    end

    @testset "WKT: Struct ↔ JSON object passthrough" begin
        od = OrderedDict{String,_G.AbstractValue}(
            "a" => _G.Value(OneOf(:number_value, 1.0)),
            "b" => _G.Value(OneOf(:string_value, "x")),
        )
        s = _G.Struct(od)
        @test JSON.parse(encode_json(s)) == Dict("a" => 1.0, "b" => "x")
        back = decode_json(_G.Struct, "{\"a\": 1.0, \"b\": \"x\"}")
        @test sort(collect(keys(back.fields))) == ["a", "b"]
        @test back.fields["a"].kind.value == 1.0
        @test back.fields["b"].kind.value == "x"
    end

    @testset "WKT: ListValue ↔ JSON array passthrough" begin
        lv = _G.ListValue(_G.AbstractValue[
            _G.Value(OneOf(:number_value, 1.0)),
            _G.Value(OneOf(:string_value, "two")),
            _G.Value(OneOf(:bool_value, true)),
            _G.Value(OneOf(:null_value, _G.NullValue.NULL_VALUE)),
        ])
        @test encode_json(lv) == "[1.0,\"two\",true,null]"
        back = decode_json(_G.ListValue, "[1.0,\"two\",true,null]")
        @test length(back.values) == 4
        @test back.values[1].kind.value == 1.0
        @test back.values[2].kind.value == "two"
        @test back.values[3].kind.value == true
        @test back.values[4].kind.name === :null_value
    end

    @testset "WKT: Value any-JSON passthrough" begin
        @test encode_json(_G.Value(nothing)) == "null"
        @test encode_json(_G.Value(OneOf(:bool_value, true))) == "true"
        @test encode_json(_G.Value(OneOf(:number_value, 3.5))) == "3.5"
        @test encode_json(_G.Value(OneOf(:string_value, "hi"))) == "\"hi\""
        @test decode_json(_G.Value, "null").kind.name === :null_value
        @test decode_json(_G.Value, "true").kind.value === true
        @test decode_json(_G.Value, "3.5").kind.value == 3.5
        @test decode_json(_G.Value, "\"hi\"").kind.value == "hi"
        @test decode_json(_G.Value, "{\"a\": 1}").kind.name === :struct_value
        @test decode_json(_G.Value, "[1, 2]").kind.name === :list_value
    end

    @testset "WKT: Empty ↔ {}" begin
        @test encode_json(_G.Empty()) == "{}"
        @test decode_json(_G.Empty, "{}") isa _G.Empty
    end

    @testset "WKT: Any wraps WKTs as `{\"@type\": …, \"value\": …}`" begin
        # Any wrapping a Timestamp: WKT special form under "value".
        ts = _G.Timestamp(Int64(1715188800), Int32(0))
        a = _G.var"Any"("type.googleapis.com/google.protobuf.Timestamp",
                        ProtoBufDescriptors.encode(ts))
        d = JSON.parse(encode_json(a))
        @test d["@type"] == "type.googleapis.com/google.protobuf.Timestamp"
        @test endswith(d["value"], "Z")
        # Round-trip: decode JSON, re-decode binary payload.
        back_a = decode_json(_G.var"Any", encode_json(a))
        back_ts = ProtoBufDescriptors.decode(back_a.value, _G.Timestamp)
        @test back_ts.seconds == ts.seconds
        @test back_ts.nanos   == ts.nanos

        # Any wrapping a BoolValue.
        bv = _G.BoolValue(true)
        a2 = _G.var"Any"("type.googleapis.com/google.protobuf.BoolValue",
                         ProtoBufDescriptors.encode(bv))
        d2 = JSON.parse(encode_json(a2))
        @test d2["@type"] == "type.googleapis.com/google.protobuf.BoolValue"
        @test d2["value"] == true
    end

    @testset "WKT: Any wraps ordinary messages with fields inlined" begin
        sc = _G.SourceContext("foo.proto")
        a = _G.var"Any"("type.googleapis.com/google.protobuf.SourceContext",
                        ProtoBufDescriptors.encode(sc))
        d = JSON.parse(encode_json(a))
        @test d == Dict(
            "@type"    => "type.googleapis.com/google.protobuf.SourceContext",
            "fileName" => "foo.proto",
        )
        # Round-trip
        back_a = decode_json(_G.var"Any", encode_json(a))
        back_sc = ProtoBufDescriptors.decode(back_a.value, _G.SourceContext)
        @test back_sc.file_name == "foo.proto"
    end

    @testset "WKT: Any errors on unknown @type" begin
        json = "{\"@type\": \"type.googleapis.com/never.registered.Whatever\"}"
        @test_throws ArgumentError decode_json(_G.var"Any", json)
        # Missing @type
        @test_throws ArgumentError decode_json(_G.var"Any", "{}")
    end

    @testset "lookup_message_type covers self-bootstrap WKTs and descriptors" begin
        @test ProtoBufDescriptors.lookup_message_type("google.protobuf.Timestamp") === _G.Timestamp
        @test ProtoBufDescriptors.lookup_message_type("google.protobuf.FileDescriptorProto") === _G.FileDescriptorProto
        @test ProtoBufDescriptors.lookup_message_type("nonexistent.Foo") === nothing
    end

end

end # module
