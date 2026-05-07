@testset "plugin protocol" begin
    G = ProtoBufDescriptors.google.protobuf
    GC = ProtoBufDescriptors.google.protobuf.compiler

    # Build a small CodeGeneratorRequest in memory and run it through
    # run_plugin to verify the read-decode / encode-write plumbing.
    request = GC.CodeGeneratorRequest(
        ["sample.proto"],
        nothing,
        G.FileDescriptorProto[
            G.FileDescriptorProto(
                "sample.proto",
                "sample",
                String[],
                Int32[],
                Int32[],
                G.DescriptorProto[],
                G.EnumDescriptorProto[],
                G.ServiceDescriptorProto[],
                G.FieldDescriptorProto[],
                nothing,
                nothing,
                "proto3",
            ),
        ],
        G.FileDescriptorProto[],
        nothing,
    )

    req_io = IOBuffer()
    ProtoBufDescriptors.encode(ProtoBufDescriptors.ProtoEncoder(req_io), request)
    req_bytes = take!(req_io)

    out_io = IOBuffer()
    response = ProtoBufDescriptors.run_plugin(IOBuffer(req_bytes), out_io)
    @test response isa GC.CodeGeneratorResponse
    @test response.error === nothing
    @test isempty(response.file)
    # Plugin claims it can handle proto3 `optional` so protoc doesn't reject
    # requests that contain them.
    @test response.supported_features == UInt64(1)  # FEATURE_PROTO3_OPTIONAL

    # The bytes round-trip back to the same response.
    response2 = ProtoBufDescriptors.decode(
        ProtoBufDescriptors.ProtoDecoder(IOBuffer(take!(out_io))),
        GC.CodeGeneratorResponse,
    )
    @test response2.error === nothing
    @test isempty(response2.file)
    @test response2.supported_features == UInt64(1)

    # Malformed input: the plugin reports the failure in `error` instead of
    # throwing — that's the protoc plugin contract.
    bad_io = IOBuffer()
    junk_response = ProtoBufDescriptors.run_plugin(IOBuffer(UInt8[0xff, 0xff, 0xff]), bad_io)
    @test junk_response.error !== nothing
    @test !isempty(junk_response.error)

    # The bin/protoc-gen-julia script exists and is executable.
    plugin_path = normpath(joinpath(@__DIR__, "..", "bin", "protoc-gen-julia"))
    @test isfile(plugin_path)
    @test (uperm(plugin_path) & 0o1) != 0
end
