# Regression tests for two codegen bugs that lived in Phase 4–6. Both are
# fixed; this file is now a regression suite and is a natural candidate to
# merge into test_codegen.jl.
#
# Bug 1 (repeated bool/float/double) — codegen lumped Bool/Float32/Float64
#   into the same no-wire-type fast-path as String/Vector{UInt8}, but the
#   codec's `decode!(d, w, ::BufferedVector{T<:Union{Bool,Float32,Float64}})`
#   (decode.jl:174) requires the wire-type to switch packed vs unpacked.
#   Without it, dispatch fell into the generic `BufferedVector{T}` path
#   that assumes a length-prefixed message and crashed on the deleted
#   `LengthDelimitedProtoDecoder` fallback.
#
# Bug 2 (map<K,V> drops fixed/zigzag) — the map FieldModel set
#   `wire_annotation = ""` unconditionally, so codegen emitted bare
#   `decode!(d, dict)` / `encode(e, n, dict)` that hit the codec's default
#   varint path even for `map<sfixed32, sint64>` etc. Codec has the right
#   `Val{Tuple{KAnnot,VAnnot}}` dispatches (decode.jl:58–98 / encode.jl:
#   150–187); the fix threads each map's per-K/V annotation through.

@testset "regression: repeated bool/float/double" begin
    # `_emit_decode_field` lumps Bool/Float32/Float64 into the same branch as
    # String/Vector{UInt8} and emits `PB.decode!(_d, $field)` without
    # wire_type. The codec only has a no-wire_type BufferedVector decoder for
    # String and Vector{UInt8}; for Bool/Float32/Float64 the matching method
    # (codec/decode.jl:174) requires a wire_type. The current codegen falls
    # through to the generic `decode!(d, ::BufferedVector{T})` which calls
    # `decode(d, Ref{T})` — i.e. expects a length-prefixed message, not a
    # packed/scalar payload.
    #
    # Schema: fixtures/proto/rep.proto
    #     message M {
    #       repeated float  fs = 1;
    #       repeated double ds = 2;
    #       repeated bool   bs = 3;
    #     }
    # Sample: fixtures/txtpb/rep_sample.txtpb (fs/ds/bs each populated).
    G  = ProtoBufDescriptors.google.protobuf
    GC = ProtoBufDescriptors.google.protobuf.compiler

    fdset = ProtoBufDescriptors.decode(
        ProtoBufDescriptors.ProtoDecoder(IOBuffer(fixture("rep.pb"))),
        G.FileDescriptorSet,
    )
    request = GC.CodeGeneratorRequest(
        ["rep.proto"], nothing, fdset.file,
        G.FileDescriptorProto[], nothing,
    )
    req_io = IOBuffer()
    ProtoBufDescriptors.encode(ProtoBufDescriptors.ProtoEncoder(req_io), request)
    out_io = IOBuffer()
    response = ProtoBufDescriptors.run_plugin(IOBuffer(take!(req_io)), out_io)
    @test response.error === nothing
    f = response.file[1]

    rep_mod = Module(:GeneratedRep)
    Core.eval(rep_mod, Meta.parseall(f.content))

    rep_sample_pb = fixture("rep_sample.pb")

    # Decode protoc's bytes — currently throws UndefVarError pointing into
    # the deleted `LengthDelimitedProtoDecoder` fallback in codec/decode.jl.
    m = Base.invokelatest(ProtoBufDescriptors.decode,
                          ProtoBufDescriptors.ProtoDecoder(IOBuffer(rep_sample_pb)),
                          rep_mod.M)
    @test m.fs == Float32[1.5f0, -2.25f0, 0.0f0]
    @test length(m.ds) == 2
    @test isapprox(m.ds[1], 3.14159265358979; atol = 1e-12)
    @test isapprox(m.ds[2], -1e-10; atol = 1e-22)
    @test m.bs == Bool[true, false, true]

    # Encode is wired through the correct codec method (encode.jl:226) for
    # Vector{Bool/Float32/Float64}, so re-encoding should be byte-identical
    # to what protoc produced. Vector preserves order, so this is
    # deterministic.
    function reencode(x)
        io = IOBuffer()
        Base.invokelatest(ProtoBufDescriptors.encode,
                          ProtoBufDescriptors.ProtoEncoder(io), x)
        return take!(io)
    end
    @test reencode(m) == rep_sample_pb
end

@testset "regression: map<K,V> with fixed/zigzag K or V" begin
    # `_emit_decode_field`/`_emit_encode_field` for the map branch emit
    # `PB.decode!(_d, $dict)` and `PB.encode(_e, $n, _x.$dict)` with no
    # `Val{Tuple{...}}` argument. The codec has the right dispatches for
    # fixed/zigzag-keyed/-valued maps (decode.jl:58–98, encode.jl:150–187)
    # keyed on `Val{Tuple{:fixed,Nothing}}` etc., but the codegen never
    # selects them — so any map with sfixed/sint/fixed keys or values
    # silently misencodes/misdecodes. The synthetic *Entry message is also
    # suppressed, so users can't see the wire annotation lurking on the
    # key/value fields.
    #
    # Schema: fixtures/proto/maps_fx.proto
    #     message Bag {
    #       map<sfixed32, sint64>  a = 1;
    #       map<string,   fixed64> b = 2;
    #       map<sint32,   string>  c = 3;
    #     }
    # Sample: fixtures/txtpb/maps_fx_sample.txtpb.
    G  = ProtoBufDescriptors.google.protobuf
    GC = ProtoBufDescriptors.google.protobuf.compiler

    fdset = ProtoBufDescriptors.decode(
        ProtoBufDescriptors.ProtoDecoder(IOBuffer(fixture("maps_fx.pb"))),
        G.FileDescriptorSet,
    )
    request = GC.CodeGeneratorRequest(
        ["maps_fx.proto"], nothing, fdset.file,
        G.FileDescriptorProto[], nothing,
    )
    req_io = IOBuffer()
    ProtoBufDescriptors.encode(ProtoBufDescriptors.ProtoEncoder(req_io), request)
    out_io = IOBuffer()
    response = ProtoBufDescriptors.run_plugin(IOBuffer(take!(req_io)), out_io)
    @test response.error === nothing
    f = response.file[1]

    # Surface check: each map's per-K/V wire annotation shows up exactly
    # where the codec dispatches on it. Codec methods key on
    # `Val{Tuple{KAnnot,VAnnot}}` where each annotation is the bare symbol
    # `:fixed` / `:zigzag` (or `Nothing`), not the `Val{:fixed}` form used by
    # non-map scalar fields. See codec/decode.jl:58–98 and encode.jl:150–187.
    @test occursin("Val{Tuple{:fixed,:zigzag}}",  f.content)  # map<sfixed32, sint64>
    @test occursin("Val{Tuple{Nothing,:fixed}}",  f.content)  # map<string,   fixed64>
    @test occursin("Val{Tuple{:zigzag,Nothing}}", f.content)  # map<sint32,   string>

    maps_mod = Module(:GeneratedMapsFx)
    Core.eval(maps_mod, Meta.parseall(f.content))

    maps_sample_pb = fixture("maps_fx_sample.pb")

    # Decode protoc's bytes via the generated decode. The bug makes this
    # interpret sfixed32 as varint, fixed64 as varint, etc. — values come
    # back garbled rather than throwing, so this is the silent failure mode.
    bag = Base.invokelatest(ProtoBufDescriptors.decode,
                            ProtoBufDescriptors.ProtoDecoder(IOBuffer(maps_sample_pb)),
                            maps_mod.Bag)
    @test bag.a == Dict(Int32(-1) => Int64(1), Int32(7) => Int64(-2))
    @test bag.b == Dict("k1" => UInt64(0xCAFEBABEDEADBEEF), "k2" => UInt64(1))
    @test bag.c == Dict(Int32(-3) => "neg", Int32(4) => "pos")

    # Encode-side cross-check: build the same dicts ourselves, encode via
    # the generated codec, and assert the byte length matches protoc's
    # reference. We don't compare bytes directly because Dict iteration
    # order is nondeterministic. The length still catches the bug because
    # varint-of-sfixed32 differs in size from raw-4-byte sfixed32, etc.
    bag2 = Base.invokelatest(maps_mod.Bag,
                             Dict(Int32(-1) => Int64(1), Int32(7) => Int64(-2)),
                             Dict("k1" => UInt64(0xCAFEBABEDEADBEEF), "k2" => UInt64(1)),
                             Dict(Int32(-3) => "neg", Int32(4) => "pos"))
    enc_io = IOBuffer()
    Base.invokelatest(ProtoBufDescriptors.encode,
                      ProtoBufDescriptors.ProtoEncoder(enc_io), bag2)
    @test length(take!(enc_io)) == length(maps_sample_pb)
end
