module TestRpcCodegen

include("setup.jl")

# The greeter FileDescriptorProto is built in-process (no protoc) by the
# shared fixture in src/testing.jl — the same one ProtocGenConnect's test
# suite uses, so the two can't drift.

# Dict-backed transport for the roundtrip test below. Defined at module
# top level (not inside a @testset) so no eval gymnastics are needed.
struct InMemTransport <: ProtocGen.AbstractRpcTransport
    routes::Dict{Tuple{String,String},Function}
end

function ProtocGen.rpc_call(
    t::InMemTransport,
    svc::AbstractString,
    method::AbstractString,
    body::AbstractVector{UInt8},
)
    f = t.routes[(String(svc), String(method))]
    return f(body)
end

@testset "codegen: service emission" begin
    proto = ProtocGen.greeter_file_descriptor()
    src = ProtocGen.Codegen.codegen(proto)

    # Surface checks — verify the pieces of generated service glue are
    # present without anchoring on whitespace.
    @test occursin("function SayHello end", src)
    @test occursin("function SayHelloStream end", src)
    @test occursin("function PB.MethodDescriptorProto(::typeof(SayHello))", src)
    @test occursin("PB.service_fqn(::typeof(SayHello)) = \"greeter.Greeter\"", src)
    @test occursin("PB.request_type(::typeof(SayHello)) = HelloRequest", src)
    @test occursin("PB.response_type(::typeof(SayHello)) = HelloReply", src)
    @test occursin("PB.request_type(::typeof(SayHelloStream)) = HelloRequest", src)
    @test occursin(
        "function SayHello(t::PB.AbstractRpcTransport, req::HelloRequest)::HelloReply",
        src,
    )
    @test occursin("const Greeter = (SayHello, SayHelloStream,)", src)
    # Streaming RPCs don't get a client stub yet — descriptor still present.
    @test occursin("function PB.MethodDescriptorProto(::typeof(SayHelloStream))", src)
    @test !occursin("function SayHelloStream(t::PB.AbstractRpcTransport", src)

    # Eval the module and exercise the trait surface.
    mod = eval_generated(src, :GeneratedGreeter)
    SayHello = mod.SayHello
    SayHelloStream = mod.SayHelloStream

    @test Base.invokelatest(ProtocGen.service_fqn, SayHello) == "greeter.Greeter"
    @test Base.invokelatest(ProtocGen.method_name, SayHello) == "SayHello"
    @test Base.invokelatest(ProtocGen.rpc_mode, SayHello) === :unary
    @test Base.invokelatest(ProtocGen.rpc_mode, SayHelloStream) === :server_stream
    @test Base.invokelatest(ProtocGen.request_type, SayHello) === mod.HelloRequest
    @test Base.invokelatest(ProtocGen.response_type, SayHello) === mod.HelloReply
    @test mod.Greeter === (SayHello, SayHelloStream)
end

@testset "codegen: duplicate RPC names across services are rejected" begin
    proto = ProtocGen.greeter_file_descriptor()
    svc = proto.service[1]
    clash = G.ServiceDescriptorProto(; name = "Greeter2", method = [svc.method[1]])
    proto2 = G.FileDescriptorProto(;
        name = proto.name,
        package = proto.package,
        syntax = proto.syntax,
        dependency = proto.dependency,
        public_dependency = proto.public_dependency,
        weak_dependency = proto.weak_dependency,
        enum_type = proto.enum_type,
        extension = proto.extension,
        message_type = proto.message_type,
        service = [svc, clash],
    )
    @test_throws "duplicate RPC name" ProtocGen.Codegen.codegen(proto2)
end

@testset "codegen: in-memory transport roundtrip" begin
    # Plug the Dict-backed transport into the codegen-emitted SayHello stub.
    # Exercises rpc_invoke + dispatch end-to-end without any HTTP.
    proto = ProtocGen.greeter_file_descriptor()
    src = ProtocGen.Codegen.codegen(proto)
    mod = eval_generated(src, :GreeterRpc)
    SayHello = mod.SayHello

    impl = function (body)
        req = ProtocGen.decode(body, mod.HelloRequest)
        reply = mod.HelloReply(; message = "Hi $(req.name)")
        return ProtocGen.encode(reply)
    end
    t = InMemTransport(Dict(("greeter.Greeter", "SayHello") => impl))

    reply = Base.invokelatest(SayHello, t, mod.HelloRequest(; name = "Bob"))
    @test reply.message == "Hi Bob"
end

end # module TestRpcCodegen
