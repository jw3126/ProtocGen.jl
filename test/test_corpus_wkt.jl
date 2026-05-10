module TestCorpusWKT

include("setup.jl")

# Verbatim copy of Google's `unittest_well_known_types.proto` from
# protobuf-master (committed under test/fixtures/proto/). This is the
# first fully-verbatim file from the Google golden corpus that the suite
# can consume — the rest of the corpus needed at least one feature we
# haven't implemented (extensions, groups, message_set, allow_alias).
#
# Phase 7c (cross-package import emission) is what unblocks this: the
# generated `unittest_well_known_types_pb.jl` carries
# `import ProtocGenJulia.google.protobuf as google_protobuf` at the
# top, and every WKT-typed field renders as `google_protobuf.<Type>`.
# That sidesteps the `Any`/`Type` clash with `Core` because the WKT
# names are reached only through the alias.

@testset "corpus: unittest_well_known_types (verbatim)" begin
    response = run_codegen("unittest_well_known_types.pb",
                           ["unittest_well_known_types.proto"])
    @test response.error === nothing
    @test length(response.file) == 1
    f = response.file[1]
    @test f.name == "unittest_well_known_types_pb.jl"

    # Cross-package import + qualified WKT refs are present.
    @test occursin("import ProtocGenJulia.google.protobuf as google_protobuf",
                   f.content)
    @test occursin("any_field::Union{Nothing,google_protobuf.Any}", f.content)
    @test occursin("type_field::Union{Nothing,google_protobuf.Type}", f.content)
    @test occursin("timestamp_field::Union{Nothing,google_protobuf.Timestamp}",
                   f.content)
    @test occursin("struct_field::Union{Nothing,google_protobuf.Struct}", f.content)

    # Eval into a fresh Module — the generated `import` brings the
    # WKT module in by alias; nothing has to be injected here.
    m = eval_generated(f.content, :GenUWKT)
    WKT = ProtocGenJulia.google.protobuf

    # Build a TestWellKnownTypes populating a representative subset.
    ts = Base.invokelatest(WKT.Timestamp, Int64(1_700_000_000), Int32(0))
    dur = Base.invokelatest(WKT.Duration, Int64(60), Int32(0))
    fm = Base.invokelatest(WKT.FieldMask, ["foo", "bar"])
    sc = Base.invokelatest(WKT.SourceContext, "src.proto")
    i32w = Base.invokelatest(WKT.Int32Value, Int32(42))
    sw = Base.invokelatest(WKT.StringValue, "hello")
    bw = Base.invokelatest(WKT.BoolValue, true)
    any_inst = Base.invokelatest(WKT.Any,
        "type.googleapis.com/google.protobuf.Empty", UInt8[])
    type_inst = Base.invokelatest(WKT.Type,
        "Foo", WKT.Field[], String[], WKT.Option[],
        nothing, WKT.Syntax.SYNTAX_PROTO3)

    t = Base.invokelatest(m.TestWellKnownTypes,
        any_inst, nothing, dur, nothing, fm, sc,
        nothing, ts, type_inst, nothing, nothing, nothing, nothing,
        i32w, nothing, bw, sw, nothing, nothing,
    )

    decoded = decode_latest(m.TestWellKnownTypes, encode_latest(t))
    @test decoded.any_field !== nothing
    @test decoded.any_field.type_url == "type.googleapis.com/google.protobuf.Empty"
    @test decoded.duration_field !== nothing
    @test decoded.duration_field.seconds == 60
    @test decoded.timestamp_field !== nothing
    @test decoded.timestamp_field.seconds == 1_700_000_000
    @test decoded.field_mask_field !== nothing
    @test decoded.field_mask_field.paths == ["foo", "bar"]
    @test decoded.source_context_field !== nothing
    @test decoded.source_context_field.file_name == "src.proto"
    @test decoded.type_field !== nothing
    @test decoded.type_field.name == "Foo"
    @test decoded.type_field.syntax == WKT.Syntax.SYNTAX_PROTO3
    @test decoded.int32_field !== nothing && decoded.int32_field.value == 42
    @test decoded.string_field !== nothing && decoded.string_field.value == "hello"
    @test decoded.bool_field !== nothing && decoded.bool_field.value === true
    @test decoded.struct_field === nothing
end

end  # module TestCorpusWKT
