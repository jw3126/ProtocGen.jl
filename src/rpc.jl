# RPC support — transport-agnostic surface that codegen-emitted service
# stubs build on. Concrete wire protocols (Connect, gRPC, gRPC-Web, ...)
# live in separate packages that subtype `AbstractRpcTransport` and
# implement `rpc_call` (unary) plus the streaming variants when they
# support them.
#
# Design notes live in https://github.com/jw3126/ProtocGen.jl/issues/9.

import EnumX

# Re-export the proto descriptor type at the top level so codegen can
# emit `PB.MethodDescriptorProto(...)` without reaching into the nested
# `google.protobuf` module. Users get a shorter spelling too.
const MethodDescriptorProto = google.protobuf.MethodDescriptorProto

"""
    AbstractRpcTransport

Supertype every concrete transport (`ProtocGenConnect.Client`,
`ProtocGenConnect.Server`, in-process test transports, ...) subtypes.

Codegen-emitted client stubs dispatch on this supertype, so the user
calls `SayHello(transport, req)` directly with whatever transport they
hold — no per-service `*Client` wrapper.
"""
abstract type AbstractRpcTransport end

"""
    StatusCode

Canonical RPC status code set, mirrored from gRPC / Connect. The
specific HTTP-status mapping is a transport concern; ProtocGen only
owns the symbolic vocabulary.
"""
EnumX.@enumx StatusCode begin
    OK = 0
    CANCELLED = 1
    UNKNOWN = 2
    INVALID_ARGUMENT = 3
    DEADLINE_EXCEEDED = 4
    NOT_FOUND = 5
    ALREADY_EXISTS = 6
    PERMISSION_DENIED = 7
    RESOURCE_EXHAUSTED = 8
    FAILED_PRECONDITION = 9
    ABORTED = 10
    OUT_OF_RANGE = 11
    UNIMPLEMENTED = 12
    INTERNAL = 13
    UNAVAILABLE = 14
    DATA_LOSS = 15
    UNAUTHENTICATED = 16
end

"""
    RpcError(code, message[, metadata])

Thrown by transports and handlers to signal an RPC-level failure.
The transport translates it to its wire-specific error form (HTTP
status + JSON envelope for Connect, trailers for gRPC, …).
"""
struct RpcError <: Exception
    code::StatusCode.T
    message::String
    metadata::Dict{String,String}
end

function RpcError(code::StatusCode.T, message::AbstractString)
    return RpcError(code, String(message), Dict{String,String}())
end

function Base.showerror(io::IO, e::RpcError)
    print(io, "RpcError(", e.code, "): ", e.message)
end

# -----------------------------------------------------------------------------
# Codegen-emitted methods. Generated `*_pb.jl` files attach one method per RPC
# function `f` to each of these:
#
#   PB.MethodDescriptorProto(::typeof(f))  — proto descriptor (name, I/O FQNs,
#                                            streaming bits).
#   PB.service_fqn(::typeof(f))            — owning service's FQN string. Not
#                                            on MethodDescriptorProto itself,
#                                            so it lives as its own trait.
#   PB.request_type(::typeof(f))           — concrete Julia request type.
#   PB.response_type(::typeof(f))          — concrete Julia response type.
#
# `request_type`/`response_type` are emitted directly (codegen already
# resolved the Julia types for the stub signature) rather than derived
# from the descriptor's FQN strings at call time — that would drag the
# global message-type registry into every RPC. `method_name` and
# `rpc_mode` are derived from the descriptor.
# -----------------------------------------------------------------------------

"""
    service_fqn(f) -> String

Fully-qualified service name (e.g. `"greeter.Greeter"`) of the RPC
function `f`. Codegen emits one method per RPC.
"""
function service_fqn end

"""
    request_type(f) -> Type

Concrete Julia type of the RPC function `f`'s request message.
Codegen emits one method per RPC.
"""
function request_type end

"""
    response_type(f) -> Type

Concrete Julia type of the RPC function `f`'s response message.
Codegen emits one method per RPC.
"""
function response_type end

function method_name(f::Function)
    desc = MethodDescriptorProto(f)
    name = desc.name
    name === nothing && error("MethodDescriptorProto for $(f) is missing the `name` field")
    return name
end

# Shared streaming-bit classification — codegen's service emitter uses
# the same helper when it picks stubs and comments, so the two can't drift.
function _rpc_mode(client_streaming::Bool, server_streaming::Bool)
    if client_streaming && server_streaming
        return :bidi
    elseif server_streaming
        return :server_stream
    elseif client_streaming
        return :client_stream
    else
        return :unary
    end
end

function rpc_mode(f::Function)
    desc = MethodDescriptorProto(f)
    return _rpc_mode(
        something(desc.client_streaming, false),
        something(desc.server_streaming, false),
    )
end

# -----------------------------------------------------------------------------
# Transport surface. Transports implement `rpc_call` (unary, mandatory)
# plus the streaming variants when they support them. All four are bare
# generic functions — a transport that lacks one fails with a MethodError
# at the call site instead of a misleading wire-level status.
# -----------------------------------------------------------------------------

"""
    rpc_call(t::AbstractRpcTransport, service_fqn, method, req_bytes) -> Vector{UInt8}

Send a unary RPC. Transports must implement this. `req_bytes` carries
the encoded protobuf body; the return value is the encoded response.
"""
function rpc_call end

# Streaming entry points — declared so transports that support them get a
# stable override target. Not wired into codegen yet (see #9).
function rpc_server_stream end
function rpc_client_stream end
function rpc_bidi_stream end

"""
    rpc_invoke(t::AbstractRpcTransport, f::Function, req) -> response

Generic client-side glue codegen calls into. Encodes `req`, dispatches
to `rpc_call` (or the relevant streaming variant), and decodes the
response per `response_type(f)`. Streaming variants will land alongside
the matching codegen.
"""
function rpc_invoke(t::AbstractRpcTransport, f::Function, req::AbstractProtoBufMessage)
    # One descriptor fetch per call — each trait accessor would otherwise
    # rebuild the descriptor struct.
    desc = MethodDescriptorProto(f)
    mode = _rpc_mode(
        something(desc.client_streaming, false),
        something(desc.server_streaming, false),
    )
    if mode === :unary
        name = desc.name
        name === nothing &&
            error("MethodDescriptorProto for $(f) is missing the `name` field")
        req_bytes = encode(req)
        resp_bytes = rpc_call(t, service_fqn(f), name, req_bytes)
        return decode(resp_bytes, response_type(f))
    else
        throw(
            RpcError(
                StatusCode.UNIMPLEMENTED,
                "rpc_invoke: $(mode) not yet wired (see #9)",
            ),
        )
    end
end
