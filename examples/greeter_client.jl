# Greeter client — companion to greeter_server.jl.
#
# Run from this directory, with the server already running on :8080:
#
#   julia --project=../ProtocGenConnect greeter_client.jl

using ProtocGen
using ProtocGenConnect

include(joinpath(@__DIR__, "out", "greeter_pb.jl"))

# `ProtocGenConnect.Client` *is* the client — no per-service GreeterClient
# wrapper. The codegen-emitted `SayHello(t::AbstractRpcTransport, ...)`
# method dispatches on it.
client = ProtocGenConnect.Client("http://127.0.0.1:8080")
reply = SayHello(client, HelloRequest(name = "Alice"))
println(reply.message)
