using Test
using ProtocGen
using ProtocGenConnect
using HTTP
using Sockets

# Generate + eval into a fresh anon module. The greeter descriptor is the
# shared in-process fixture from ProtocGen's src/testing.jl — hermetic (no
# protoc) and identical to the one ProtocGen's own codegen tests use.
const proto = ProtocGen.greeter_file_descriptor()
const src = ProtocGen.Codegen.codegen(proto)
const Greeter = Module()
Core.eval(Greeter, Meta.parseall(src))

const SayHello = Greeter.SayHello
const HelloRequest = Greeter.HelloRequest
const HelloReply = Greeter.HelloReply
const GreeterMethods = Greeter.Greeter

# User-side server impl.
struct EchoGreeter
    suffix::String
end
function (Greeter.SayHello)(impl::EchoGreeter, req::HelloRequest)
    if isempty(req.name)
        throw(ProtocGen.RpcError(ProtocGen.StatusCode.INVALID_ARGUMENT, "name is required"))
    end
    return HelloReply(; message = "Hello, $(req.name)$(impl.suffix)")
end

# Listen on an ephemeral port and tear down at the end.
function with_running_server(f; impl = EchoGreeter("!"))
    srv = ProtocGenConnect.Server()
    ProtocGenConnect.serve!(srv, impl, GreeterMethods)
    http = ProtocGenConnect.listen(srv; host = "127.0.0.1", port = 0)
    try
        # `port = 0` asks the kernel for a free port; the actual port lives on
        # the underlying TCP server. `HTTP.Server` does not expose it directly.
        _, port = getsockname(http.listener.server)
        f("http://127.0.0.1:$(port)")
    finally
        close(http)
    end
end

@testset "ProtocGenConnect — unary roundtrip" begin
    with_running_server() do url
        client = ProtocGenConnect.Client(url)
        reply = Base.invokelatest(SayHello, client, HelloRequest(; name = "Alice"))
        @test reply isa HelloReply
        @test reply.message == "Hello, Alice!"
    end
end

@testset "ProtocGenConnect — RpcError round-trip" begin
    with_running_server() do url
        client = ProtocGenConnect.Client(url)
        err = try
            Base.invokelatest(SayHello, client, HelloRequest(; name = ""))
            nothing
        catch e
            e
        end
        @test err isa ProtocGen.RpcError
        @test err.code === ProtocGen.StatusCode.INVALID_ARGUMENT
        @test occursin("name is required", err.message)
    end
end

@testset "ProtocGenConnect — 404 on unknown method" begin
    with_running_server() do url
        client = ProtocGenConnect.Client(url)
        err = try
            ProtocGen.rpc_call(client, "greeter.Greeter", "DoesNotExist", UInt8[])
            nothing
        catch e
            e
        end
        @test err isa ProtocGen.RpcError
        # The no-route 404 carries no Connect error envelope, so the client
        # falls back to the spec's HTTP-to-code table: bare 404 → unimplemented.
        @test err.code === ProtocGen.StatusCode.UNIMPLEMENTED
    end
end

@testset "ProtocGenConnect — 415 on wrong content type" begin
    with_running_server() do url
        resp = HTTP.post(
            "$(url)/greeter.Greeter/SayHello",
            ["Content-Type" => "application/json"],
            "{\"name\":\"Alice\"}";
            status_exception = false,
        )
        @test resp.status == 415
    end
end
