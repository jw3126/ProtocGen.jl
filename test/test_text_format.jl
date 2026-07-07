# Protobuf text format (textproto) tests.
#
# Three layers:
#
#   1. Printer + parser over the loaded bootstrap/WKT types — scalar
#      rendering and escaping, presence semantics, oneofs, maps, enums,
#      the full parse grammar, and error cases. Every printed form is
#      also re-parsed (`decode_text ∘ encode_text == identity`).
#
#   2. `google.protobuf.Any` — expanded `[type.googleapis.com/…] { … }`
#      form both ways, plus the raw `type_url:`/`value:` fallback for
#      unresolvable types.
#
#   3. Golden cross-validation — the `test/fixtures/txtpb/*.txtpb` files
#      are the protoc `--encode` inputs that produced the binary fixtures
#      under `test/fixtures/pb/`, so parsing the textproto must equal
#      decoding the binary, for codegen output eval'd on the fly.

module TestTextFormat

include("setup.jl")

using ProtocGen: encode_text, decode_text, OneOf, OrderedDict

const TXTPB = joinpath(@__DIR__, "fixtures", "txtpb")

# Build a message of type `T` from `StructHelpers.default_keywords(T)`,
# with the given overrides merged in (same helper as test_json.jl).
function _make(::Type{T}; overrides...) where {T}
    d = ProtocGen.StructHelpers.default_keywords(T)
    merged = merge(d, NamedTuple(overrides))
    return T((merged[n] for n in fieldnames(T))...)
end

# Print, assert the exact text, and assert the round-trip.
function _check_text(msg::T, expected::AbstractString) where {T}
    s = encode_text(msg)
    @test s == expected
    @test decode_text(T, s) == msg
    return nothing
end

@testset "TextFormat" begin

    # -------------------------------------------------------------------------
    # Printer — scalar rendering.
    # -------------------------------------------------------------------------

    @testset "printer: integers, strings, presence" begin
        # FieldDescriptorProto: presence-bearing scalars print even at
        # their zero default.
        f = _make(G.FieldDescriptorProto; name = "f", number = Int32(0))
        s = encode_text(f)
        @test occursin("name: \"f\"\n", s)
        @test occursin("number: 0\n", s)
        @test decode_text(G.FieldDescriptorProto, s) == f

        # Duration: implicit-presence scalars are skipped at default.
        @test encode_text(G.Duration(; seconds = 3)) == "seconds: 3\n"
        @test encode_text(G.Duration()) == ""

        # 64-bit ints print as plain decimal (no JSON-style quoting).
        u = _make(
            G.UninterpretedOption;
            positive_int_value = UInt64(12345678901234567890),
            negative_int_value = Int64(-9223372036854775807),
        )
        s = encode_text(u)
        @test occursin("positive_int_value: 12345678901234567890\n", s)
        @test occursin("negative_int_value: -9223372036854775807\n", s)
        @test decode_text(G.UninterpretedOption, s) == u
    end

    @testset "printer: floats" begin
        _check_text(G.DoubleValue(; value = 2.5), "value: 2.5\n")
        _check_text(G.DoubleValue(; value = Inf), "value: inf\n")
        _check_text(G.DoubleValue(; value = -Inf), "value: -inf\n")
        @test encode_text(G.DoubleValue(; value = NaN)) == "value: nan\n"
        v = decode_text(G.DoubleValue, "value: nan")
        @test isnan(v.value)

        # Float32 exponents: Julia's 'f' marker must come out as 'e'.
        _check_text(G.FloatValue(; value = 1.0f-10), "value: 1.0e-10\n")
        _check_text(G.FloatValue(; value = 3.14f0), "value: 3.14\n")
        _check_text(G.FloatValue(; value = -Inf32), "value: -inf\n")
    end

    @testset "printer: string and bytes escaping" begin
        # Control chars named, quotes/backslash escaped, UTF-8 verbatim.
        _check_text(
            G.StringValue(; value = "a\tb\n\"q\"\\z€"),
            "value: \"a\\tb\\n\\\"q\\\"\\\\z€\"\n",
        )
        # Bytes: printable ASCII verbatim, everything else 3-digit octal.
        _check_text(
            G.BytesValue(; value = UInt8[0x00, 0xff, 0x41, 0x07]),
            "value: \"\\000\\377A\\007\"\n",
        )
    end

    @testset "printer: enums with stripped prefix" begin
        # Codegen stripped `TYPE_`; the wire form must carry it.
        f = _make(
            G.FieldDescriptorProto;
            name = "f",
            type = G.var"FieldDescriptorProto.Type".DOUBLE,
        )
        s = encode_text(f)
        @test occursin("type: TYPE_DOUBLE\n", s)
        @test decode_text(G.FieldDescriptorProto, s) == f
        # The bare stripped form is accepted on parse too (same slack as JSON).
        @test decode_text(G.FieldDescriptorProto, "type: DOUBLE").type ==
              G.var"FieldDescriptorProto.Type".DOUBLE

        # A numeric value outside the declared set prints as its number.
        nv = Core.bitcast(G.NullValue.T, Int32(5))
        s = encode_text(G.Value(; kind = OneOf(:null_value, nv)))
        @test s == "null_value: 5\n"
        @test decode_text(G.Value, s).kind.value === nv
    end

    @testset "printer: oneof, repeated, map, nesting" begin
        # Oneof: only the active member, under the member's name.
        _check_text(G.Value(; kind = OneOf(:string_value, "hi")), "string_value: \"hi\"\n")
        @test encode_text(G.Value()) == ""

        # Repeated: one entry per line; nested blocks indent by 2.
        u = _make(
            G.UninterpretedOption;
            name = [
                G.var"UninterpretedOption.NamePart"(;
                    name_part = "a",
                    is_extension = false,
                ),
                G.var"UninterpretedOption.NamePart"(; name_part = "b", is_extension = true),
            ],
        )
        s = encode_text(u)
        # `is_extension` is a proto2 `required bool` — the
        # `required_field_names` trait makes it print even at `false`
        # (a strict parser rejects a message missing a required field).
        @test s ==
              "name {\n  name_part: \"a\"\n  is_extension: false\n}\n" *
              "name {\n  name_part: \"b\"\n  is_extension: true\n}\n"
        @test decode_text(G.UninterpretedOption, s) == u

        # Map: one key/value block per pair, insertion order; message
        # values become nested blocks (via the AbstractValue cycle type).
        st = G.Struct(;
            fields = OrderedDict{String,G.AbstractValue}(
                "x" => G.Value(; kind = OneOf(:bool_value, true)),
            ),
        )
        s = encode_text(st)
        @test s == "fields {\n  key: \"x\"\n  value {\n    bool_value: true\n  }\n}\n"
        @test decode_text(G.Struct, s) == st

        # A per-call `registry` only overrides Any's FQN lookup — cycle
        # abstracts (AbstractValue here) still resolve via the fallback to
        # the active registry.
        @test decode_text(G.Struct, s; registry = Dict{String,Type}()) == st
    end

    @testset "printer: WKTs have no special text forms" begin
        # Unlike JSON (RFC 3339 / "1.5s" strings), text format prints
        # Timestamp and Duration as plain messages.
        @test encode_text(G.Timestamp(; seconds = 1700000000, nanos = 1)) ==
              "seconds: 1700000000\nnanos: 1\n"
        @test encode_text(G.Duration(; seconds = -1, nanos = -500)) ==
              "seconds: -1\nnanos: -500\n"
    end

    # -------------------------------------------------------------------------
    # Parser — grammar.
    # -------------------------------------------------------------------------

    @testset "parser: delimiters, separators, comments, colons" begin
        src = """
        # leading comment
        name: "n";
        options < deprecated: true >,  # angle brackets + trailing comma
        number: 7
        """
        f = decode_text(G.FieldDescriptorProto, src)
        @test f.name == "n"
        @test f.number == Int32(7)
        @test f.options.deprecated === true

        # Colon before a message block is optional; delimiters must match.
        @test decode_text(
            G.FieldDescriptorProto,
            "options: { deprecated: true }",
        ).options.deprecated === true
        @test_throws ArgumentError decode_text(
            G.FieldDescriptorProto,
            "options { deprecated: true >",
        )
        # Colon before a scalar is required.
        @test_throws ArgumentError decode_text(G.Duration, "seconds 3")
    end

    @testset "parser: numeric literals" begin
        # Hex and octal integers.
        @test decode_text(G.Int32Value, "value: 0x1F").value == Int32(31)
        @test decode_text(G.Int32Value, "value: -0x10").value == Int32(-16)
        @test decode_text(G.Int32Value, "value: 017").value == Int32(15)
        @test decode_text(G.UInt64Value, "value: 0xDEADBEEFCAFEBABE").value ==
              UInt64(0xDEADBEEFCAFEBABE)
        # Range checks.
        @test_throws ArgumentError decode_text(G.Int32Value, "value: 2147483648")
        @test_throws ArgumentError decode_text(G.UInt32Value, "value: -1")
        # Float literal on an int field is rejected.
        @test_throws ArgumentError decode_text(G.Int32Value, "value: 1.5")
        @test_throws ArgumentError decode_text(G.Int64Value, "value: 1e3")

        # Floats: exponents, 'f'/'F' suffix, inf/infinity/nan idents,
        # bare integers, and Float32 overflow rejection.
        @test decode_text(G.DoubleValue, "value: -1.5e3").value == -1500.0
        @test decode_text(G.FloatValue, "value: 2.5f").value == 2.5f0
        @test decode_text(G.FloatValue, "value: 1F").value == 1.0f0
        @test decode_text(G.DoubleValue, "value: Infinity").value == Inf
        @test decode_text(G.DoubleValue, "value: -INF").value == -Inf
        @test isnan(decode_text(G.FloatValue, "value: NaN").value)
        @test decode_text(G.DoubleValue, "value: 4").value == 4.0
        # Out-of-range float literals clamp to ±inf (unlike JSON, which
        # rejects them — protoc's text parser clamps).
        @test decode_text(G.FloatValue, "value: 3.5e38").value == Inf32
        @test decode_text(G.FloatValue, "value: -3.5e38").value == -Inf32

        # Bool spellings.
        @test decode_text(G.BoolValue, "value: True").value === true
        @test decode_text(G.BoolValue, "value: t").value === true
        @test decode_text(G.BoolValue, "value: 0").value === false
        @test_throws ArgumentError decode_text(G.BoolValue, "value: yes")
    end

    @testset "parser: string literals" begin
        # Quote styles, adjacent concatenation, all escape classes.
        @test decode_text(G.StringValue, "value: \"a\" 'b' \"c\"").value == "abc"
        @test decode_text(G.StringValue, raw"value: '\a\b\f\n\r\t\v\?\\\'\"'").value ==
              "\a\b\f\n\r\t\v?\\'\""
        @test decode_text(G.StringValue, raw"value: '\101\x42'").value == "AB"
        @test decode_text(G.StringValue, raw"value: '€ \U0001F600'").value == "€ 😀"
        @test decode_text(G.BytesValue, raw"value: '\377\xff\x0'").value ==
              UInt8[0xff, 0xff, 0x00]

        # Bad UTF-8 is rejected on string fields but fine on bytes.
        @test_throws ArgumentError decode_text(G.StringValue, raw"value: '\xff'")
        # Unterminated / multiline / bad escapes.
        @test_throws ArgumentError decode_text(G.StringValue, "value: \"abc")
        @test_throws ArgumentError decode_text(G.StringValue, "value: \"a\nb\"")
        @test_throws ArgumentError decode_text(G.StringValue, raw"value: '\q'")
        # Surrogate code points are rejected.
        @test_throws ArgumentError decode_text(G.StringValue, raw"value: '\ud800'")
    end

    @testset "parser: repeated list shorthand and maps" begin
        lv = decode_text(
            G.ListValue,
            "values: [{number_value: 1}, {number_value: 2}]\nvalues { bool_value: true }",
        )
        @test length(lv.values) == 3
        @test lv.values[1].kind.value == 1.0
        @test lv.values[3].kind.value === true
        @test decode_text(G.ListValue, "values: []") == G.ListValue()
        # Trailing comma is rejected.
        @test_throws ArgumentError decode_text(G.ListValue, "values: [{number_value: 1},]")

        # Map entries: either order, `[…]` shorthand, missing halves
        # default, duplicate keys last-wins.
        st = decode_text(
            G.Struct,
            """
            fields { value { number_value: 1 } key: "a" }
            fields: [{ key: "b" value { number_value: 2 } }, { key: "c" }]
            fields { key: "a" value { number_value: 9 } }
            """,
        )
        @test st.fields["a"].kind.value == 9.0
        @test st.fields["b"].kind.value == 2.0
        @test st.fields["c"] == G.Value()   # missing value half → default
        @test_throws ArgumentError decode_text(G.Struct, "fields { key: \"a\" other: 1 }")
        # Duplicate `key`/`value` halves inside one entry block error
        # (protoc rejects them; last-wins would mask producer bugs).
        @test_throws ArgumentError decode_text(G.Struct, "fields { key: \"a\" key: \"b\" }")

        # The colon is required before a *scalar* list, optional before a
        # message list (matching protoc).
        @test decode_text(G.FieldMask, "paths: [\"a\", \"b\"]").paths == ["a", "b"]
        @test_throws ArgumentError decode_text(G.FieldMask, "paths [\"a\"]")
        @test decode_text(G.ListValue, "values [{bool_value: true}]").values[1].kind.value ===
              true
    end

    @testset "parser: duplicate non-repeated fields" begin
        # Duplicate singular scalar → error.
        @test_throws ArgumentError decode_text(G.Duration, "seconds: 1 seconds: 2")
        # Two members of one oneof → error.
        @test_throws ArgumentError decode_text(
            G.Value,
            "string_value: \"a\" bool_value: true",
        )
        # Duplicate singular *message* fields error too — protoc's text
        # parser rejects them (merging is binary wire semantics only).
        @test_throws ArgumentError decode_text(
            G.FieldDescriptorProto,
            "options { deprecated: true } options { packed: true }",
        )
    end

    @testset "parser: unknown fields and extensions" begin
        @test_throws ArgumentError decode_text(G.Duration, "bogus: 1")
        d = decode_text(
            G.Duration,
            """
            bogus: -3 other { x: 1 y [<a:1>, 'str' 'ings'] } listy: [1, 2]
            seconds: 5
            """;
            ignore_unknown_fields = true,
        )
        @test d.seconds == 5
        # Proto2 extension syntax is a clear, deliberate error.
        err = try
            decode_text(G.Duration, "[pkg.some_extension]: 1")
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("extension fields are not supported", err.msg)
        # Trailing garbage after the top-level message errors.
        @test_throws ArgumentError decode_text(G.Duration, "seconds: 1 }")
    end

    # -------------------------------------------------------------------------
    # google.protobuf.Any.
    # -------------------------------------------------------------------------

    @testset "Any: expanded form round-trip" begin
        a = G.var"Any"(;
            type_url = "type.googleapis.com/google.protobuf.Duration",
            value = encode(G.Duration(; seconds = 7, nanos = 20)),
        )
        s = encode_text(a)
        @test s ==
              "[type.googleapis.com/google.protobuf.Duration] {\n  seconds: 7\n  nanos: 20\n}\n"
        @test decode_text(G.var"Any", s) == a
        # Nested inside another message (Value can't hold Any; use a map
        # via Struct? — simplest nested carrier is Any-in-Any).
        outer = G.var"Any"(;
            type_url = "type.googleapis.com/google.protobuf.Any",
            value = encode(a),
        )
        s2 = encode_text(outer)
        @test occursin("[type.googleapis.com/google.protobuf.Any] {", s2)
        @test occursin("  [type.googleapis.com/google.protobuf.Duration] {", s2)
        @test decode_text(G.var"Any", s2) == outer

        # Raw type_url/value fields still parse; expanded + raw can't mix.
        raw =
            "type_url: \"type.googleapis.com/google.protobuf.Duration\"\n" *
            "value: \"$(String(copy(a.value)))\""
        @test decode_text(G.var"Any", raw) == a
        @test_throws ArgumentError decode_text(
            G.var"Any",
            "type_url: \"t\" [type.googleapis.com/google.protobuf.Duration] { seconds: 1 }",
        )
        # Unregistered FQN in the expanded form errors.
        @test_throws ArgumentError decode_text(
            G.var"Any",
            "[type.googleapis.com/no.such.Msg] { x: 1 }",
        )
    end

    @testset "Any: unresolvable prints raw fields" begin
        a = G.var"Any"(;
            type_url = "type.googleapis.com/no.such.Msg",
            value = UInt8[0x08, 0x01],
        )
        s = encode_text(a)
        @test occursin("type_url: \"type.googleapis.com/no.such.Msg\"\n", s)
        # A resolvable type_url whose value bytes don't decode also falls
        # back to raw fields instead of crashing.
        bad = G.var"Any"(;
            type_url = "type.googleapis.com/google.protobuf.Duration",
            value = UInt8[0xff, 0xff, 0xff],
        )
        sbad = encode_text(bad)
        @test occursin("type_url:", sbad) && occursin("value:", sbad)
        @test decode_text(G.var"Any", sbad) == bad
        @test occursin("value: \"\\010\\001\"\n", s)
        @test decode_text(G.var"Any", s) == a
        # Default Any prints nothing at all.
        @test encode_text(G.var"Any"()) == ""
    end

    # -------------------------------------------------------------------------
    # Golden cross-validation against the protoc-authored fixtures.
    # -------------------------------------------------------------------------

    # Each entry: descriptor-set fixture, proto path, top-level message
    # name, and the txtpb/pb payload pairs produced by fixtures/regen.jl.
    GOLDEN = [
        (
            "sample.pb",
            "sample.proto",
            :Outer,
            ["sample_outer", "outer_maybe_zero", "outer_maybe_unset"],
        ),
        ("corpus.pb", "corpus.proto", :Wide, ["corpus_sample"]),
        ("maps.pb", "maps.proto", :Bag, ["maps_sample"]),
        ("p2.pb", "p2.proto", :Wrap, ["p2_full", "p2_minimal"]),
        ("rep.pb", "rep.proto", :M, ["rep_sample"]),
        ("maps_fx.pb", "maps_fx.proto", :Bag, ["maps_fx_sample"]),
        (
            "test_messages_proto2_patched.pb",
            "test_messages_proto2_patched.proto",
            :TestAllTypesProto2,
            ["test_messages_proto2_full", "test_messages_proto2_empty"],
        ),
        (
            "test_messages_proto3.pb",
            "test_messages_proto3.proto",
            :TestAllTypesProto3,
            ["test_messages_proto3_full", "test_messages_proto3_empty"],
        ),
    ]

    @testset "golden txtpb ↔ pb: $(proto)" for (fdset, proto, msg, payloads) in GOLDEN
        response = run_codegen(fdset, [proto])
        @test response.error === nothing
        file_name = replace(proto, r"\.proto$" => "_pb.jl")
        idx = findfirst(f -> f.name == file_name, response.file)
        @test idx !== nothing
        reg = Dict{String,Type}()
        mod = eval_generated(
            response.file[idx].content,
            Symbol("GenText_", msg);
            registry = reg,
        )
        # The binding was created by the eval above — read it in the
        # latest world (Julia 1.12 warns otherwise).
        M = Base.invokelatest(getproperty, mod, msg)

        for payload in payloads
            expected = decode_latest(M, fixture(payload * ".pb"))
            txt = read(joinpath(TXTPB, payload * ".txtpb"), String)
            got = Base.invokelatest(decode_text, M, txt; registry = reg)
            # `==` (from @batteries) is generated alongside the type, so it
            # needs the latest world too.
            @test Base.invokelatest(==, got, expected)
            # Print-then-reparse is lossless too.
            printed = Base.invokelatest(encode_text, expected; registry = reg)
            reparsed = Base.invokelatest(decode_text, M, printed; registry = reg)
            @test Base.invokelatest(==, reparsed, expected)
        end
    end
end # testset TextFormat

end # module TestTextFormat
