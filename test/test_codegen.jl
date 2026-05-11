module TestCodegen

include("setup.jl")

@testset "codegen happy path" begin
    response = run_codegen("sample.pb", ["sample.proto"])
    @test response.error === nothing
    # Per-proto `_pb.jl` plus the always-on `_pb_includes.jl` driver.
    @test length(response.file) == 2
    f = response.file[1]
    @test f.name == "sample_pb.jl"
    @test response.file[2].name == "_pb_includes.jl"
    @test occursin("struct Inner", f.content)
    @test occursin("struct Outer", f.content)
    @test occursin("nested::Union{Nothing,Inner}", f.content)
    # Scalar refs are emitted through the `var"#base"` alias defined
    # at the top of every generated file, so a user proto declaring
    # a message named e.g. `Bool` cannot shadow the codegen's scalar
    # type annotations.
    @test occursin("packed_ints::Vector{var\"#base\".Int64}", f.content)
    @test occursin(
        "choice::Union{Nothing,OneOf{<:Union{var\"#base\".Int32,var\"#base\".String}}}",
        f.content,
    )

    # Eval the generated module and verify a round-trip.
    sample_mod = eval_generated(f.content, :GeneratedSample)

    inner = pb_make(sample_mod.Inner; a = Int32(42))
    outer = pb_make(
        sample_mod.Outer;
        name = "hello",
        maybe = Int32(7),
        nested = inner,
        packed_ints = Int64[1, 2, 3, 4],
        choice = ProtocGen.OneOf(:ci, Int32(99)),
    )
    decoded = decode_latest(sample_mod.Outer, encode_latest(outer))
    @test decoded.name == outer.name
    @test decoded.maybe == outer.maybe
    @test decoded.nested !== nothing
    @test decoded.nested.a == outer.nested.a
    @test decoded.packed_ints == outer.packed_ints
    @test decoded.choice !== nothing
    @test decoded.choice.name === :ci
    @test decoded.choice.value == Int32(99)

    # Wire-compat: bytes that `protoc --encode=sample.Outer` produced for
    # fixtures/txtpb/sample_outer.txtpb.
    from_protoc = decode_latest(sample_mod.Outer, fixture("sample_outer.pb"))
    @test from_protoc.name == "from-protoc"
    @test from_protoc.maybe == 99
    @test from_protoc.nested !== nothing && from_protoc.nested.a == 7
    @test from_protoc.choice !== nothing &&
          from_protoc.choice.name === :ci &&
          from_protoc.choice.value == 13
    @test from_protoc.packed_ints == [10, 20, 30]

    # `Base.show` renders messages in @kwdef-style. The unknown-fields
    # buffer is suppressed when empty (the common case).
    s = sprint(show, inner)
    @test occursin("Inner(", s)
    @test occursin("a = ", s)
    @test !occursin("unknown_fields", s)
    # When the buffer carries bytes, it's shown — `kwshow` prints the
    # field's Symbol name verbatim (no `var""` wrapping).
    inner_with_unknown =
        pb_make(sample_mod.Inner; a = Int32(1), var"#unknown_fields" = UInt8[0xff])
    s2 = sprint(show, inner_with_unknown)
    @test occursin("#unknown_fields = ", s2)
end

@testset "codegen corpus: every wire encoding" begin
    # FileDescriptorSet for fixtures/proto/corpus.proto. Wide exercises every
    # scalar wire encoding, an enum, a nested message, and three flavors of
    # repeated. corpus_sample.pb is `protoc --encode=corpus.Wide` against
    # fixtures/txtpb/corpus_sample.txtpb (every field non-default).
    response = run_codegen("corpus.pb", ["corpus.proto"])
    @test response.error === nothing
    @test length(response.file) == 2
    f = response.file[1]
    @test f.name == "corpus_pb.jl"
    @test response.file[2].name == "_pb_includes.jl"

    corpus_mod = eval_generated(f.content, :GeneratedCorpus)

    # Decode the protoc-encoded payload and check every field.
    corpus_sample_pb = fixture("corpus_sample.pb")
    w = decode_latest(corpus_mod.Wide, corpus_sample_pb)
    @test w.i32 == Int32(-1)
    @test w.i64 == Int64(1234567890123)
    @test w.u32 == UInt32(4000000000)
    @test w.u64 == UInt64(18000000000000000000)
    @test w.s32 == Int32(-100)
    @test w.s64 == Int64(-100000000000)
    @test w.f32 == UInt32(0xCAFEBABE)
    @test w.f64 == UInt64(0xDEADBEEFCAFEBABE)
    @test w.sf32 == typemin(Int32)
    @test w.sf64 == typemin(Int64) + 1
    @test isapprox(w.f, 3.14f0; atol = 1.0f-6)
    @test isapprox(w.d, 2.71828; atol = 1e-9)
    @test w.bb == true
    @test w.ss == "héllo"
    @test w.by == UInt8[0xff, 0x00, 0xab]
    @test w.color == corpus_mod.Color.BLUE
    @test w.nested !== nothing
    @test w.nested.a == 7
    @test w.nested.note == "deep"
    @test w.ri == Int32[1, 2, 3]
    @test w.rs == ["x", "y"]
    @test length(w.rn) == 2
    @test w.rn[1].a == 10 && w.rn[1].note == "p"
    @test w.rn[2].a == 20 && w.rn[2].note == "q"

    # Re-encode and decode again — semantic round-trip should preserve every
    # field. Bytes need not be identical (we emit fields in struct-declaration
    # order; protoc emits them in proto-source order, which happens to be the
    # same here, but we don't depend on it).
    re = encode_latest(w)
    @test length(re) == length(corpus_sample_pb)
    w2 = decode_latest(corpus_mod.Wide, re)
    for fname in fieldnames(typeof(w))
        @test getfield(w, fname) == getfield(w2, fname)
    end
end

@testset "codegen: maps" begin
    # FileDescriptorSet + protoc-encoded Bag for fixtures/proto/maps.proto.
    response = run_codegen("maps.pb", ["maps.proto"])
    @test response.error === nothing
    f = response.file[1]

    # Maps surface as OrderedDict{K,V}; the synthetic *Entry messages stay invisible.
    # Scalar refs go through the `var"#base"` alias for shadow-immunity.
    @test occursin("counts::OrderedDict{var\"#base\".String,var\"#base\".Int32}", f.content)
    @test occursin("labels::OrderedDict{var\"#base\".Int32,var\"#base\".String}", f.content)
    @test occursin("items::OrderedDict{var\"#base\".String,Item}", f.content)
    @test !occursin("CountsEntry", f.content)
    @test !occursin("LabelsEntry", f.content)
    @test !occursin("ItemsEntry", f.content)

    maps_mod = eval_generated(f.content, :GeneratedMaps)

    sample_pb = fixture("maps_sample.pb")
    bag = decode_latest(maps_mod.Bag, sample_pb)
    @test bag.counts == Dict("a" => Int32(1), "b" => Int32(2))
    @test bag.labels == Dict(Int32(10) => "ten", Int32(20) => "twenty")
    @test sort(collect(keys(bag.items))) == ["x", "y"]
    @test bag.items["x"].v == 7 && bag.items["y"].v == 8

    # Insertion-order-preserving OrderedDict means re-encode is byte-identical
    # to the protoc-emitted fixture: the decode order tracks the wire order,
    # the encode iterator tracks insertion order, so we hit the same bytes.
    @test encode_latest(bag) == sample_pb
end

@testset "codegen: @batteries + @enumbatteries always emitted" begin
    fdset = load_fdset("sample.pb")
    universe = ProtocGen.Codegen.gather_universe(fdset.file)
    file = first(fdset.file)

    # Default emission: every generated message carries an `@batteries`
    # line with an auto-generated typesalt, every enum carries
    # `@enumbatteries`. The StructHelpers re-export is always imported
    # since these macros need to resolve in the include site's scope.
    baseline = ProtocGen.Codegen.codegen(file, universe)
    @test occursin("using ProtocGen.StructHelpers: @batteries, @enumbatteries", baseline)
    @test occursin(r"@batteries Inner typesalt=0x[0-9a-f]{16}", baseline)
    @test occursin(r"@batteries Outer typesalt=0x[0-9a-f]{16}", baseline)

    # The typesalt must be stable across regenerations — re-running
    # codegen on the same input produces an identical line.
    baseline2 = ProtocGen.Codegen.codegen(file, universe)
    @test baseline == baseline2

    # Two distinct types must get two distinct typesalts (FNV-1a of
    # different proto FQNs).
    inner_match = match(r"@batteries Inner typesalt=(0x[0-9a-f]+)", baseline)
    outer_match = match(r"@batteries Outer typesalt=(0x[0-9a-f]+)", baseline)
    @test inner_match !== nothing && outer_match !== nothing
    @test inner_match.captures[1] != outer_match.captures[1]

    # `[batteries]` populated → user kwargs joined onto the line after
    # the auto-generated typesalt.
    cfg = Dict("batteries" => Dict("kwshow" => true, "hash" => false))
    with_msgs = ProtocGen.Codegen.codegen(file, universe; config = cfg)
    @test occursin(r"@batteries Inner typesalt=0x[0-9a-f]{16} ", with_msgs)
    @test occursin("hash=false", with_msgs)
    @test occursin("kwshow=true", with_msgs)

    # User-supplied `typesalt` in config is silently ignored — the
    # auto-generated per-type salt always wins, since a single global
    # value would collide across types.
    bad_cfg = Dict("batteries" => Dict("typesalt" => 0xdead))
    with_bad = ProtocGen.Codegen.codegen(file, universe; config = bad_cfg)
    @test !occursin("typesalt=0xdead", with_bad)
    # The `kwconstructor=true kwshow=true` come from the always-emitted
    # baseline; `bad_cfg`'s `typesalt` doesn't leak through.
    @test occursin(
        r"@batteries Inner typesalt=0x[0-9a-f]{16} kwconstructor=true kwshow=true\s*$"m,
        with_bad,
    )

    # `[enumbatteries]` populated → user kwargs joined onto every
    # `@enumbatteries <Name>.T …` line. corpus.proto carries `Color`.
    corpus_fdset = load_fdset("corpus.pb")
    corpus_universe = ProtocGen.Codegen.gather_universe(corpus_fdset.file)
    corpus_file = first(corpus_fdset.file)
    enum_cfg = Dict("enumbatteries" => Dict("kwshow" => true))
    with_enums = ProtocGen.Codegen.codegen(corpus_file, corpus_universe; config = enum_cfg)
    @test occursin(
        r"@enumbatteries Color\.T typesalt=0x[0-9a-f]{16} kwshow=true",
        with_enums,
    )
end

@testset "codegen: @batteries works on Core/Base-shadowing types" begin
    # `shadow.proto` declares messages named `Core`, `Base`, `Type`,
    # `Any`, `Bool`, an enum `Integer`, and a `Holder` that pulls them
    # all together. Each of these names shadows a Core / Base binding
    # inside the generated module — the StructHelpers >=1.4.1 fix
    # captures the original Core / Base values at quote-build time so
    # @batteries macro expansion is no longer derailed.
    response = run_codegen("shadow.pb", ["shadow.proto"])
    @test response.error === nothing
    @test length(response.file) == 2
    @test response.file[2].name == "_pb_includes.jl"
    f = first(response.file)

    # Eval the file in a fresh anonymous module; this is where the
    # macro-expansion-time shadowing would bite if it weren't fixed.
    m = eval_generated(f.content, :GeneratedShadow)

    # Every shadow message + enum was decorated with @batteries /
    # @enumbatteries (StructHelpers.has_batteries returns true).
    for name in (:Core, :Base, :Type, :Any, :Bool, :Holder)
        T = Base.invokelatest(getproperty, m, name)
        @test Base.invokelatest(ProtocGen.StructHelpers.has_batteries, T)
    end
    EnumT = Base.invokelatest(getproperty, Base.invokelatest(getproperty, m, :Integer), :T)
    @test Base.invokelatest(ProtocGen.StructHelpers.has_batteries, EnumT)

    # Holder ties them together — round-trip through binary format
    # exercises the generated decode/encode plus the @batteries-
    # decorated structs. Use kwarg construction so the buffer fills in
    # from `default_keywords`.
    msg = pb_make(
        m.Holder;
        c = pb_make(m.Core; v = Int32(1)),
        b = pb_make(m.Base; label = "label"),
        t = pb_make(m.Type; name = "type-name"),
        a = pb_make(m.Any; url = "url"),
        bl = pb_make(m.Bool; flag = true),
        i = Base.invokelatest(getproperty, m.Integer, :TWO),
    )
    bytes = encode_latest(msg)
    back = decode_latest(m.Holder, bytes)
    @test back == msg
end

end  # module TestCodegen
