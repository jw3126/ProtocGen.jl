module TestPlugin

include("setup.jl")

@testset "plugin protocol" begin
    # Build an empty CodeGeneratorRequest (no files to generate). This test
    # exercises the read-decode / encode-write plumbing only — actual codegen
    # is covered by test_codegen.jl.
    request = GC.CodeGeneratorRequest()

    req_bytes = ProtoBufDescriptors.encode(request)

    out_io = IOBuffer()
    response = ProtoBufDescriptors.run_plugin(IOBuffer(req_bytes), out_io)
    @test response isa GC.CodeGeneratorResponse
    @test response.error === nothing
    @test isempty(response.file)
    # Plugin claims it can handle proto3 `optional` so protoc doesn't reject
    # requests that contain them.
    @test response.supported_features == UInt64(1)  # FEATURE_PROTO3_OPTIONAL

    # The bytes round-trip back to the same response.
    response2 = ProtoBufDescriptors.decode(take!(out_io), GC.CodeGeneratorResponse)
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

@testset "PluginApp.main" begin
    # Both the Pkg.Apps-installed binary and bin/protoc-gen-julia funnel
    # into PluginApp.main, so exercise it end-to-end with redirected
    # stdin/stdout. Empty CodeGeneratorRequest → response with no files
    # and no error string. The redirect_stdout test also guards against
    # stray writes to stdout (e.g. an accidental @info) corrupting the
    # protoc plugin protocol.
    request = GC.CodeGeneratorRequest()
    req_bytes = ProtoBufDescriptors.encode(request)

    in_pipe = Pipe();  Base.link_pipe!(in_pipe)
    write(in_pipe.in, req_bytes); close(in_pipe.in)
    out_pipe = Pipe(); Base.link_pipe!(out_pipe)

    rc = redirect_stdin(in_pipe) do
        redirect_stdout(out_pipe) do
            ProtoBufDescriptors.PluginApp.main(String[])
        end
    end
    close(out_pipe.in)
    @test rc == 0

    out_bytes = read(out_pipe)
    response = ProtoBufDescriptors.decode(out_bytes, GC.CodeGeneratorResponse)
    @test response.error === nothing
    @test isempty(response.file)
    @test response.supported_features == UInt64(1)

    # Unexpected positional args → exit 2, no stdout output.
    out_pipe2 = Pipe(); Base.link_pipe!(out_pipe2)
    rc2 = redirect_stdout(out_pipe2) do
        ProtoBufDescriptors.PluginApp.main(["--unexpected"])
    end
    close(out_pipe2.in)
    @test rc2 == 2
    @test isempty(read(out_pipe2))
end

end  # module TestPlugin
