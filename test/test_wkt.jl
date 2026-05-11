module TestWellKnownTypes

include("setup.jl")

# All 11 well-known types under `ProtocGen.google.protobuf.*`, generated
# by our own codegen via `gen/regen.jl`. The bindings divide naturally:
#   - no inter-file deps: any, duration, empty, field_mask,
#     source_context, timestamp, wrappers
#   - cross-file imports through the codegen Universe:
#       api   — depends on source_context, type
#       type  — depends on any, source_context
#   - recursion via abstract supertypes:
#       struct — Value ↔ Struct ↔ ListValue cycle

const WKT = ProtocGen.google.protobuf

function rt(x::T) where {T}
    bytes = Base.invokelatest(ProtocGen.encode, x)
    decoded = Base.invokelatest(ProtocGen.decode, bytes, T)
    return decoded, bytes
end

@testset "well-known types (round-trip)" begin
    @testset "Timestamp" begin
        # epoch + 1.7e9 sec, 123_456_789 nanos. Field 1 = seconds (varint),
        # field 2 = nanos (varint). protoc emits in field-number order.
        t = pb_make(WKT.Timestamp, Int64(1_700_000_000), Int32(123_456_789))
        decoded, bytes = rt(t)
        @test decoded.seconds == t.seconds
        @test decoded.nanos == t.nanos
        # Hand-verified wire bytes: tag=0x08 + varint(1_700_000_000) [5B]
        # + tag=0x10 + varint(123_456_789) [4B] = 11 bytes total.
        @test length(bytes) == 11
    end

    @testset "Timestamp epoch" begin
        # All-zero Timestamp encodes to zero bytes (proto3 implicit
        # presence: zero is indistinguishable from unset).
        t = pb_make(WKT.Timestamp, Int64(0), Int32(0))
        decoded, bytes = rt(t)
        @test decoded.seconds == 0 && decoded.nanos == 0
        @test isempty(bytes)
    end

    @testset "Duration" begin
        d = pb_make(WKT.Duration, Int64(-3600), Int32(-500_000_000))
        decoded, bytes = rt(d)
        @test decoded.seconds == d.seconds
        @test decoded.nanos == d.nanos
        # Negative int32/int64 encode as 10-byte sign-extended varint, so
        # tag=0x08 + 10B + tag=0x10 + 10B = 22 bytes. Our codec's Int32
        # encode already does this correctly (encode.jl:73).
        @test length(bytes) == 22
    end

    @testset "Empty" begin
        e = pb_make(WKT.Empty)
        decoded, bytes = rt(e)
        @test decoded isa WKT.Empty
        @test isempty(bytes)
    end

    @testset "FieldMask" begin
        # paths is `repeated string` — proto3 repeated, but strings are
        # length-delimited per element regardless of packed/unpacked.
        m = pb_make(WKT.FieldMask, ["foo", "bar.baz", "qux"])
        decoded, bytes = rt(m)
        @test decoded.paths == m.paths
        @test !isempty(bytes)
    end

    @testset "SourceContext" begin
        s = pb_make(WKT.SourceContext, "/path/to/file.proto")
        decoded, _ = rt(s)
        @test decoded.file_name == s.file_name
    end

    @testset "Any" begin
        # Any holds an opaque message in `value::Bytes`, identified by a
        # type URL. The package doesn't unmarshal — that's a v1
        # limitation. Just round-trip the wrapper.
        a = pb_make(WKT.Any,
            "type.googleapis.com/google.protobuf.Timestamp",
            UInt8[0x08, 0xC0, 0x84, 0x3D])  # seconds=1_000_000 in varint
        decoded, _ = rt(a)
        @test decoded.type_url == a.type_url
        @test decoded.value == a.value
    end

    @testset "Type / Field / Option (cross-file refs)" begin
        # `Type.source_context : SourceContext` and `Option.value : Any`
        # are cross-file references. Both should resolve to bare names
        # because they live in the same Julia submodule.
        opt = pb_make(WKT.Option, "deprecated", nothing)
        sc = pb_make(WKT.SourceContext, "foo.proto")
        field = pb_make(WKT.Field,
            WKT.var"Field.Kind".TYPE_STRING,
            WKT.var"Field.Cardinality".CARDINALITY_OPTIONAL,
            Int32(1), "name", "", Int32(0), false,
            WKT.Option[], "name", "")
        t = pb_make(WKT.Type,
            "MyType", [field], String[], [opt], sc,
            WKT.Syntax.SYNTAX_PROTO3)
        decoded, _ = rt(t)
        @test decoded.name == "MyType"
        @test length(decoded.fields) == 1
        @test decoded.fields[1].name == "name"
        @test decoded.fields[1].kind == WKT.var"Field.Kind".TYPE_STRING
        @test decoded.source_context !== nothing
        @test decoded.source_context.file_name == "foo.proto"
        @test length(decoded.options) == 1
        @test decoded.options[1].name == "deprecated"
        @test decoded.syntax == WKT.Syntax.SYNTAX_PROTO3
    end

    @testset "Api / Method / Mixin (cross-file refs)" begin
        m = pb_make(WKT.Method,
            "DoIt",
            "google.example.Request",   # request_type_url
            false,                       # request_streaming
            "google.example.Response",   # response_type_url
            false,                       # response_streaming
            WKT.Option[],
            WKT.Syntax.SYNTAX_PROTO3)
        a = pb_make(WKT.Api,
            "google.example.Service",
            [m],
            WKT.Option[],
            "v1",
            nothing,                     # source_context
            WKT.Mixin[],
            WKT.Syntax.SYNTAX_PROTO3)
        decoded, _ = rt(a)
        @test decoded.name == "google.example.Service"
        @test length(decoded.methods) == 1
        @test decoded.methods[1].name == "DoIt"
        @test decoded.methods[1].request_type_url == "google.example.Request"
        @test decoded.version == "v1"
    end

    @testset "Struct / Value / ListValue (cyclic)" begin
        # Cycle: Struct.fields → Value, Value.struct_value/list_value →
        # Struct/ListValue, ListValue.values → Value. Codegen breaks it
        # by emitting `abstract type AbstractStruct` /
        # `AbstractValue` / `AbstractListValue` and forwarding decode
        # methods. Round-trip exercises every variant of Value.kind:
        # null, number, string, bool, struct, list.
        v_num  = pb_make(WKT.Value, OneOf(:number_value, 3.14))
        v_str  = pb_make(WKT.Value, OneOf(:string_value, "hello"))
        v_bool = pb_make(WKT.Value, OneOf(:bool_value, true))
        v_null = pb_make(WKT.Value, OneOf(:null_value, WKT.NullValue.NULL_VALUE))

        lv = pb_make(WKT.ListValue, WKT.AbstractValue[v_num, v_str, v_bool, v_null])
        v_list = pb_make(WKT.Value, OneOf(:list_value, lv))

        fields = OrderedDict{String,WKT.AbstractValue}(
            "n"    => v_num,
            "s"    => v_str,
            "b"    => v_bool,
            "z"    => v_null,
            "list" => v_list,
        )
        s = pb_make(WKT.Struct, fields)

        # Round-trip Struct end-to-end.
        decoded, _ = rt(s)
        @test sort(collect(keys(decoded.fields))) == ["b", "list", "n", "s", "z"]
        @test decoded.fields["n"].kind.name === :number_value
        @test decoded.fields["n"].kind.value == 3.14
        @test decoded.fields["s"].kind.name === :string_value
        @test decoded.fields["s"].kind.value == "hello"
        @test decoded.fields["b"].kind.name === :bool_value
        @test decoded.fields["b"].kind.value === true
        @test decoded.fields["z"].kind.name === :null_value
        @test decoded.fields["z"].kind.value == WKT.NullValue.NULL_VALUE

        # Nested ListValue with mixed Value variants survives the cycle.
        @test decoded.fields["list"].kind.name === :list_value
        nested_list = decoded.fields["list"].kind.value
        @test nested_list isa WKT.ListValue
        @test length(nested_list.values) == 4
        @test nested_list.values[1].kind.value == 3.14
        @test nested_list.values[2].kind.value == "hello"

        # Standalone Value round-trip — confirms the `Value` decode also
        # works without a containing Struct.
        decoded_v, _ = rt(v_str)
        @test decoded_v.kind.name === :string_value
        @test decoded_v.kind.value == "hello"
    end

    @testset "Wrappers — every variant" begin
        wrappers = [
            (WKT.DoubleValue, 3.14),
            (WKT.FloatValue, 3.14f0),
            (WKT.Int32Value, Int32(-42)),
            (WKT.Int64Value, Int64(-42_000_000_000)),
            (WKT.UInt32Value, UInt32(0xFFFFFFFF)),
            (WKT.UInt64Value, UInt64(0xFFFFFFFFFFFFFFFF)),
            (WKT.BoolValue, true),
            (WKT.StringValue, "héllo"),
            (WKT.BytesValue, UInt8[0x00, 0xFF, 0xAB]),
        ]
        for (T, v) in wrappers
            w = pb_make(T, v)
            decoded, _ = rt(w)
            @test decoded.value == w.value
        end
    end
end

end  # module TestWellKnownTypes
