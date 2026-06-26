# Greeter server — minimal demo of ProtocGen RPC + ProtocGenConnect transport.
#
# Run from this directory after `./generate.sh`:
#
#   julia --project=../ProtocGenConnect greeter_server.jl
#
# The server listens on http://127.0.0.1:8080 and serves the Greeter
# service defined in greeter.proto. The matching client demo lives at
# greeter_client.jl.

using ProtocGen
using ProtocGenConnect

include(joinpath(@__DIR__, "out", "greeter_pb.jl"))

# User-side server impl. Pure multiple dispatch — the generated codegen
# emits `function SayHello end` and `function SayHelloStream end`; we
# add methods dispatched on our impl type.
struct MyGreeter end

function SayHello(::MyGreeter, req::HelloRequest)
    return HelloReply(message = "Hello, $(req.name)!")
end

# Streaming handler form. The transport will own the bytes-level channel
# and adapt to/from the typed `Channel{HelloReply}` we accept here.
# (ProtocGenConnect doesn't ship streaming yet — included for completeness.)
function SayHelloStream(::MyGreeter, req::HelloRequest, out::Channel{HelloReply})
    for g in ("Hi", "Hello", "Hey")
        put!(out, HelloReply(message = "$(g), $(req.name)!"))
    end
end

srv = ProtocGenConnect.Server()
ProtocGenConnect.serve!(srv, MyGreeter(), Greeter)
http = ProtocGenConnect.listen(srv; host = "127.0.0.1", port = 8080)
@info "Greeter listening on http://127.0.0.1:8080 — Ctrl-C to stop"
try
    wait(http.task)
catch _
    @info "stopping"
finally
    close(http)
end
