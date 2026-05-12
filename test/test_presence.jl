module TestPresence

include("setup.jl")

@testset "proto3 explicit `optional` carries presence" begin
    # The whole point of presence: `maybe: 0` (explicit) and `maybe` unset
    # must NOT decode to the same Julia value. The two protoc-encoded payloads
    # come from fixtures/txtpb/outer_maybe_{zero,unset}.txtpb.
    bytes_maybe_zero = fixture("outer_maybe_zero.pb")
    bytes_maybe_unset = fixture("outer_maybe_unset.pb")

    response = run_codegen("sample.pb", ["sample.proto"])
    @test response.error === nothing
    f = response.file[1]

    # Generated source carries the right type for the proto3-optional field.
    # `sample.proto` has no built-in name collisions, so scalars render bare.
    @test occursin("maybe::Union{Nothing,Int32}", f.content)

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

    # Build the same two values directly via kwarg construction. `ci`/`cs`
    # collapse into the `choice` oneof field.
    nothing_outer = pb_make(sample_mod.Outer; name = "u")
    zero_outer = pb_make(sample_mod.Outer; name = "z", maybe = Int32(0))
    @test encode_latest(nothing_outer) == bytes_maybe_unset
    @test encode_latest(zero_outer) == bytes_maybe_zero
end

end  # module TestPresence
