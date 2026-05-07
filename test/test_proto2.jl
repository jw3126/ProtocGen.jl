module TestProto2

include("setup.jl")

@testset "Phase 6 — proto2 required + optional" begin
    # Schema in fixtures/proto/p2.proto. `p2_full.pb` is from the textproto
    # `name: "the-name" / nested { v: 7 } / maybe: 0 / hint: "hi"`; the
    # explicit `maybe: 0` is the presence signal we care about. `p2_minimal.pb`
    # leaves both optionals unset.
    p2_full_pb    = fixture("p2_full.pb")
    p2_minimal_pb = fixture("p2_minimal.pb")

    response = run_codegen("p2.pb", ["p2.proto"])
    @test response.error === nothing
    f = response.file[1]

    # Generated source carries the right shapes.
    @test occursin("name::String", f.content)         # required scalar → bare type
    @test occursin("nested::Inner", f.content)        # required submessage → bare type
    @test occursin("maybe::Union{Nothing,Int32}", f.content)  # proto2 optional → presence
    @test occursin("hint::Union{Nothing,String}", f.content)
    @test occursin("_saw_name", f.content)
    @test occursin("required field", f.content)

    p2_mod = eval_generated(f.content, :GeneratedP2)

    # Decode protoc-emitted bytes; explicit `maybe: 0` survives as `Int32(0)`,
    # and omitted optionals come back as `nothing`.
    full = decode_latest(p2_mod.Wrap, p2_full_pb)
    @test full.name == "the-name"
    @test full.nested.v == 7
    @test full.maybe === Int32(0)
    @test full.hint  === "hi"

    minimal = decode_latest(p2_mod.Wrap, p2_minimal_pb)
    @test minimal.name == "n"
    @test minimal.nested.v == 1
    @test minimal.maybe === nothing
    @test minimal.hint  === nothing

    # Re-encoded bytes match what protoc would have emitted, byte-identically.
    @test encode_latest(full)    == p2_full_pb
    @test encode_latest(minimal) == p2_minimal_pb

    # Missing required → clear DecodeError. Hand-crafted bytes: only the
    # nested submessage (field 2 = {v: 1}); the `name` required field
    # (number 1) is absent.
    missing_name = UInt8[0x12, 0x02, 0x08, 0x01]
    err = try
        decode_latest(p2_mod.Wrap, missing_name)
        nothing
    catch e
        e
    end
    @test err isa ProtoBufDescriptors.DecodeError
    @test occursin("required field", err.msg)
    @test occursin("name", err.msg)
end

end  # module TestProto2
