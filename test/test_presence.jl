module TestPresence

include("setup.jl")

@testset "Phase 5 — proto3 explicit `optional` carries presence" begin
    # The whole point of presence: `maybe: 0` (explicit) and `maybe` unset
    # must NOT decode to the same Julia value. The two protoc-encoded payloads
    # come from fixtures/txtpb/outer_maybe_{zero,unset}.txtpb.
    bytes_maybe_zero  = fixture("outer_maybe_zero.pb")
    bytes_maybe_unset = fixture("outer_maybe_unset.pb")

    response = run_codegen("sample.pb", ["sample.proto"])
    @test response.error === nothing
    f = response.file[1]

    # Generated source carries the right type for the proto3-optional field.
    @test occursin("maybe::Union{Nothing,var\"#base\".Int32}", f.content)

    sample_mod = eval_generated(f.content, :GeneratedSamplePresence)

    # Decode: explicit zero stays zero, unset stays unset.
    oz = decode_latest(sample_mod.Outer, bytes_maybe_zero)
    @test oz.name == "z"
    @test oz.maybe === Int32(0)

    ou = decode_latest(sample_mod.Outer, bytes_maybe_unset)
    @test ou.name == "u"
    @test ou.maybe === nothing

    # Encode: nothing-valued optional yields no field-2 bytes; explicit-zero
    # optional emits field 2 with value 0. These bytes match what `protoc`
    # would have emitted from the same textproto, byte-identically.
    @test encode_latest(oz) == bytes_maybe_zero
    @test encode_latest(ou) == bytes_maybe_unset

    # Build the same two values directly and confirm. Constructor signature
    # is Outer(name, maybe, nested, packed_ints, choice) — `ci`/`cs` collapse
    # into the `choice` oneof field (Phase 6).
    nothing_outer = Base.invokelatest(sample_mod.Outer,
                                       "u", nothing, nothing, Int64[], nothing)
    zero_outer    = Base.invokelatest(sample_mod.Outer,
                                       "z", Int32(0), nothing, Int64[], nothing)
    @test encode_latest(nothing_outer) == bytes_maybe_unset
    @test encode_latest(zero_outer)    == bytes_maybe_zero
end

end  # module TestPresence
