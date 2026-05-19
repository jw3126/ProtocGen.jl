# Regression tests for two codegen bugs that lived in earlier passes. Both are
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

module TestCodegenBugs

include("setup.jl")

@testset "regression: repeated bool/float/double" begin
    # Schema: fixtures/proto/rep.proto
    #     message M {
    #       repeated float  fs = 1;
    #       repeated double ds = 2;
    #       repeated bool   bs = 3;
    #     }
    # Sample: fixtures/txtpb/rep_sample.txtpb (fs/ds/bs each populated).
    response = run_codegen("rep.pb", ["rep.proto"])
    @test response.error === nothing
    f = response.file[1]

    rep_mod = eval_generated(f.content, :GeneratedRep)
    rep_sample_pb = fixture("rep_sample.pb")

    m = decode_latest(rep_mod.M, rep_sample_pb)
    @test m.fs == Float32[1.5f0, -2.25f0, 0.0f0]
    @test length(m.ds) == 2
    @test isapprox(m.ds[1], 3.14159265358979; atol = 1e-12)
    @test isapprox(m.ds[2], -1e-10; atol = 1e-22)
    @test m.bs == Bool[true, false, true]

    # Re-encoding should be byte-identical to what protoc produced. Vector
    # preserves order, so this is deterministic.
    @test encode_latest(m) == rep_sample_pb
end

@testset "regression: map<K,V> with fixed/zigzag K or V" begin
    # Schema: fixtures/proto/maps_fx.proto
    #     message Bag {
    #       map<sfixed32, sint64>  a = 1;
    #       map<string,   fixed64> b = 2;
    #       map<sint32,   string>  c = 3;
    #     }
    # Sample: fixtures/txtpb/maps_fx_sample.txtpb.
    response = run_codegen("maps_fx.pb", ["maps_fx.proto"])
    @test response.error === nothing
    f = response.file[1]

    # Surface check: each map's per-K/V wire annotation shows up exactly
    # where the codec dispatches on it. Codec methods key on
    # `Val{Tuple{KAnnot,VAnnot}}` where each annotation is the bare symbol
    # `:fixed` / `:zigzag` (or `Nothing`), not the `Val{:fixed}` form used by
    # non-map scalar fields. See codec/decode.jl:58–98 and encode.jl:150–187.
    @test occursin("Val{Tuple{:fixed,:zigzag}}", f.content)  # map<sfixed32, sint64>
    @test occursin("Val{Tuple{Nothing,:fixed}}", f.content)  # map<string,   fixed64>
    @test occursin("Val{Tuple{:zigzag,Nothing}}", f.content)  # map<sint32,   string>

    maps_mod = eval_generated(f.content, :GeneratedMapsFx)
    maps_sample_pb = fixture("maps_fx_sample.pb")

    bag = decode_latest(maps_mod.Bag, maps_sample_pb)
    @test bag.a == Dict(Int32(-1) => Int64(1), Int32(7) => Int64(-2))
    @test bag.b == Dict("k1" => UInt64(0xCAFEBABEDEADBEEF), "k2" => UInt64(1))
    @test bag.c == Dict(Int32(-3) => "neg", Int32(4) => "pos")

    # Encode-side cross-check: re-encode the protoc-decoded `bag` and assert
    # byte-equality against the protoc fixture. Map fields are
    # OrderedDict, so insertion order (= wire order on decode) survives
    # the round-trip; the per-K/V wire annotation we asserted above means
    # varint-of-sfixed32 vs raw-4-byte sfixed32 sizes also have to agree.
    @test encode_latest(bag) == maps_sample_pb
end

@testset "regression: driver namespace fragmentation when packages interleave" begin
    # Schema: fixtures/proto/driver_cycle_a{1,2}.proto + driver_cycle_b.proto.
    #     a1.proto: package driver_cycle.a; message Leaf
    #     b.proto:  package driver_cycle.b; import a1; message Mid { ...a.Leaf }
    #     a2.proto: package driver_cycle.a; import b; message Top {
    #                   ...b.Mid mid; Leaf leaf;   # Leaf is same-package
    #               }
    # Topo order (a1, b, a2) forces `driver_cycle.a` to appear in two
    # `module driver_cycle a … end` blocks in the generated
    # `_pb_includes.jl` — `b` slots between them because `Top` needs `Mid`.
    #
    # Bug: Julia's `module Name … end` source syntax always creates a
    # FRESH module (it does not "reopen" an existing one — that's a
    # REPL/`Base.eval` thing). So the second `module driver_cycle.a`
    # block shadows the first; `Top`'s unqualified reference to `Leaf`
    # then hits an empty namespace and fails with `UndefVarError`.
    #
    # Fix: the driver forward-declares every package's nested module
    # skeleton once, then emits `<pkg>.include("<file>")` calls in topo
    # order. Each `include` evaluates in the right pre-existing module,
    # so same-package refs see prior includes and cross-package refs
    # see sibling modules.

    response = run_codegen(
        "driver_cycle_a2.pb",
        ["driver_cycle_a1.proto", "driver_cycle_b.proto", "driver_cycle_a2.proto"],
    )
    @test response.error === nothing

    driver = only(f for f in response.file if f.name == "_pb_includes.jl")
    # Two-phase form is the canonical signal that the package-aware
    # topo couldn't find a contiguous order — qualified
    # `<pkg>.include(...)` calls are emitted at top level, so the
    # skeleton can be referenced after it's been opened-then-closed.
    @test occursin("driver_cycle.a.include", driver.content)
    @test occursin("driver_cycle.b.include", driver.content)

    # Materialize every emitted file on disk so the driver's relative
    # `include`s resolve. Then eval the driver in a fresh module under a
    # scoped `REGISTRY` so the per-file `PB.register_message_type` calls
    # land in a throwaway table — without this, re-running the test (or
    # any other test that touches the same FQNs) trips the
    # duplicate-FQN guard.
    dir = mktempdir()
    for f in response.file
        path = joinpath(dir, f.name)
        mkpath(dirname(path))
        write(path, f.content)
    end

    pkg_mod = Module(:DriverCycleTest)
    Core.eval(pkg_mod, :(import ProtocGen))
    Base.ScopedValues.with(ProtocGen.REGISTRY => Dict{String,Type}()) do
        # `Base.include` (vs the driver's own `include` keyword) makes
        # path resolution explicit: evaluate the driver source as if it
        # were the `_pb_includes.jl` file living in `dir`, so its
        # relative `include`s land on the sibling `*_pb.jl` files.
        Base.include(pkg_mod, joinpath(dir, "_pb_includes.jl"))
    end

    a_mod = pkg_mod.driver_cycle.a
    b_mod = pkg_mod.driver_cycle.b
    @test isdefined(a_mod, :Leaf)
    @test isdefined(a_mod, :Top)
    @test isdefined(b_mod, :Mid)

    # End-to-end: build a `Top` carrying both a cross-package `Mid` and a
    # same-package `Leaf`. If the second-block bug fires, `Top` either
    # doesn't exist or carries a `Leaf` from a different (empty) module.
    leaf = Base.invokelatest(a_mod.Leaf; x = Int32(7))
    mid = Base.invokelatest(b_mod.Mid; leaf)
    top = Base.invokelatest(a_mod.Top; mid, leaf)
    @test top isa a_mod.Top
    @test top.leaf isa a_mod.Leaf
    @test top.mid isa b_mod.Mid
end

@testset "driver: package-aware topo prefers contiguous (inline) emit" begin
    # Schema: fixtures/proto/driver_dag_{a1,a2,b}.proto.
    #     a1.proto: package driver_dag.a; message Spare  (no deps)
    #     b.proto:  package driver_dag.b; message Leaf   (no deps)
    #     a2.proto: package driver_dag.a; import b; message Top { ...b.Leaf }
    #
    # Package-level dep graph: `driver_dag.a → driver_dag.b` (acyclic).
    # The OLD batched-alphabetical file-topo would emit
    # [a1, b, a2] — pkg `driver_dag.a` split across positions 1 and 3.
    # The package-aware sort topo-sorts packages first (b before a),
    # then drains each in turn, producing [b, a1, a2] — pkg
    # `driver_dag.a` lands at positions 2,3, contiguous.
    response = run_codegen(
        "driver_dag_a2.pb",
        ["driver_dag_a1.proto", "driver_dag_b.proto", "driver_dag_a2.proto"],
    )
    @test response.error === nothing

    driver = only(f for f in response.file if f.name == "_pb_includes.jl")
    # Inline form is detectable structurally: the includes for pkg `a`
    # live inside the `module a … end` block, not at top level as
    # `driver_dag.a.include(...)` calls. Asserting on either side is
    # equivalent; pick the absence of the qualified form as the
    # canonical signal that we took the inline path.
    @test !occursin("driver_dag.a.include", driver.content)
    @test !occursin("driver_dag.b.include", driver.content)
    # And the inline-form module structure is present.
    @test occursin("module driver_dag", driver.content)

    # End-to-end: materialize every emitted file on disk and eval the
    # driver. With contiguous packages the inline form should produce a
    # working namespace — `Top` carrying a `Leaf` from the sibling pkg.
    dir = mktempdir()
    for f in response.file
        path = joinpath(dir, f.name)
        mkpath(dirname(path))
        write(path, f.content)
    end

    pkg_mod = Module(:DriverDagTest)
    Core.eval(pkg_mod, :(import ProtocGen))
    Base.ScopedValues.with(ProtocGen.REGISTRY => Dict{String,Type}()) do
        Base.include(pkg_mod, joinpath(dir, "_pb_includes.jl"))
    end

    a_mod = pkg_mod.driver_dag.a
    b_mod = pkg_mod.driver_dag.b
    @test isdefined(a_mod, :Spare)
    @test isdefined(a_mod, :Top)
    @test isdefined(b_mod, :Leaf)

    leaf = Base.invokelatest(b_mod.Leaf; x = Int32(11))
    top = Base.invokelatest(a_mod.Top; leaf)
    @test top isa a_mod.Top
    @test top.leaf isa b_mod.Leaf
    @test top.leaf.x == 11
end

end  # module TestCodegenBugs
