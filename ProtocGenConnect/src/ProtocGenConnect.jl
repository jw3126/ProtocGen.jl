"""
ProtocGenConnect — Connect RPC transport for ProtocGen-generated services.

Minimal v0 sketch covering unary calls only. Connect-protocol unary is
essentially a plain HTTP POST: request body is the encoded protobuf,
response body is the encoded reply, errors are HTTP non-200 with a
JSON envelope. No framing on either side — that's the big simplifier
versus gRPC-Web.

Streaming + Connect-JSON content type are intentionally deferred. The
streaming framing (`[flags:1][len:4][bytes]` with end-stream flag bit)
mirrors gRPC-Web closely; we'll land it once a real consumer needs it.

Spec reference: https://connectrpc.com/docs/protocol
"""
module ProtocGenConnect

import ProtocGen as PB
import HTTP
import JSON

const CONTENT_TYPE_PROTO = "application/proto"
const PROTOCOL_VERSION_HEADER = "Connect-Protocol-Version"
const PROTOCOL_VERSION = "1"

# ---------------------------------------------------------------------------
# Client.
# ---------------------------------------------------------------------------

"""
    Client(base_url; default_headers = Dict())

Connect-protocol client. Pass directly to a generated RPC stub:

    client = ProtocGenConnect.Client("http://localhost:8080")
    reply = SayHello(client, HelloRequest(name = "Alice"))

`base_url` is the origin only (no trailing slash); the path becomes
`/<service-fqn>/<method-name>` per Connect spec.
"""
struct Client <: PB.AbstractRpcTransport
    base_url::String
    # Complete header set, assembled once in the constructor — headers are
    # constant for the Client's lifetime, so rpc_call sends them as-is.
    headers::Vector{Pair{String,String}}
end

function Client(
    base_url::AbstractString;
    default_headers::AbstractDict = Dict{String,String}(),
)
    headers = Pair{String,String}[]
    # Protocol headers first; a user-supplied header of the same name
    # (case-insensitive, per HTTP) replaces the default instead of being
    # sent as a duplicate.
    for (k, v) in
        ("Content-Type" => CONTENT_TYPE_PROTO, PROTOCOL_VERSION_HEADER => PROTOCOL_VERSION)
        if !any(lowercase(String(uk)) == lowercase(k) for (uk, _) in default_headers)
            push!(headers, k => v)
        end
    end
    for (k, v) in default_headers
        push!(headers, String(k) => String(v))
    end
    return Client(String(rstrip(base_url, '/')), headers)
end

function PB.rpc_call(
    c::Client,
    service::AbstractString,
    method::AbstractString,
    body::AbstractVector{UInt8},
)
    url = string(c.base_url, "/", service, "/", method)
    # `encode` already hands us a fresh Vector{UInt8}; only copy when the
    # caller passed some other AbstractVector.
    req_body = body isa Vector{UInt8} ? body : Vector{UInt8}(body)
    resp = HTTP.post(url, c.headers, req_body; status_exception = false)
    if resp.status == 200
        return resp.body
    end
    throw(_decode_error_response(resp))
end

# Connect error wire form for unary: HTTP non-200 + JSON body
# `{"code":"invalid_argument","message":"…","details":[…]}`.
function _decode_error_response(resp::HTTP.Response)
    code = _status_from_http(resp.status)
    msg = "$(resp.status)"
    try
        body = String(copy(resp.body))
        if !isempty(body)
            payload = JSON.parse(body)
            if payload isa AbstractDict
                if haskey(payload, "code")
                    code = _status_from_connect_code(String(payload["code"]))
                end
                if haskey(payload, "message")
                    msg = String(payload["message"])
                end
            end
        end
    catch
        # Fall back to the HTTP-status mapping if the body isn't JSON.
    end
    return PB.RpcError(code, msg)
end

# ---------------------------------------------------------------------------
# Server.
# ---------------------------------------------------------------------------

"""
    Server() :: Server
    serve!(server, impl, methods::Tuple)
    listen(server; host, port)

In-process route table backing an HTTP listener. `serve!` walks the
tuple of RPC functions emitted by codegen (e.g. `Greeter = (SayHello,
SayHelloStream)`) and binds each to an impl object — the same impl
the user attached server-side methods to. `listen` opens an
`HTTP.serve` loop, sniffs the Content-Type, and dispatches.
"""
struct Server <: PB.AbstractRpcTransport
    routes::Dict{Tuple{String,String},Tuple{Function,Any}}
end
function Server()
    Server(Dict{Tuple{String,String},Tuple{Function,Any}}())
end

function serve!(s::Server, impl, methods::Tuple)
    for f in methods
        s.routes[(PB.service_fqn(f), PB.method_name(f))] = (f, impl)
    end
    return s
end

"""
    listen(server; host="0.0.0.0", port=8080) -> HTTP.Server

Start an HTTP listener routing requests through `server`'s route
table. Returns the HTTP.Server handle so callers can `close(srv)`
when done.
"""
function listen(s::Server; host = "0.0.0.0", port::Integer = 8080)
    return HTTP.serve!(_handler(s), host, port)
end

function _handler(s::Server)
    return function (req::HTTP.Request)
        # HTTP.URI handles query strings and multi-byte targets; hand-rolled
        # byte slicing would StringIndexError on non-ASCII paths.
        parts = HTTP.URIs.splitpath(HTTP.URI(req.target).path)
        length(parts) == 2 || return HTTP.Response(404, "expected /<service>/<method>")
        route = get(s.routes, (String(parts[1]), String(parts[2])), nothing)
        route === nothing &&
            return HTTP.Response(404, string("no route for ", parts[1], "/", parts[2]))
        # Unary Connect also allows application/json; we only speak proto so
        # far, so reject everything else with 415 per spec instead of feeding
        # a JSON body to the binary decoder.
        content_type = HTTP.header(req, "Content-Type", "")
        media_type = lowercase(strip(first(split(content_type, ';'; limit = 2))))
        media_type == CONTENT_TYPE_PROTO || return HTTP.Response(
            415,
            string(
                "unsupported content-type ",
                repr(content_type),
                "; only ",
                CONTENT_TYPE_PROTO,
                " is supported",
            ),
        )
        f, impl = route
        try
            mode = PB.rpc_mode(f)
            mode === :unary ||
                throw(PB.RpcError(PB.StatusCode.UNIMPLEMENTED, "$(mode) not supported"))
            req_val = PB.decode(req.body, PB.request_type(f))
            resp_val = f(impl, req_val)
            return HTTP.Response(
                200,
                ["Content-Type" => CONTENT_TYPE_PROTO],
                PB.encode(resp_val),
            )
        catch e
            if e isa PB.RpcError
                return _error_response(e)
            else
                # Wrap unexpected errors as INTERNAL so the client sees a
                # well-shaped Connect error envelope instead of a raw
                # 500 with a stringified exception.
                return _error_response(
                    PB.RpcError(PB.StatusCode.INTERNAL, sprint(showerror, e)),
                )
            end
        end
    end
end

function _error_response(e::PB.RpcError)
    body = JSON.json(Dict("code" => _connect_code_string(e.code), "message" => e.message))
    return HTTP.Response(
        _http_status_for(e.code),
        ["Content-Type" => "application/json"],
        body,
    )
end

# ---------------------------------------------------------------------------
# Status-code ↔ Connect-code-string ↔ HTTP-status tables.
# Per https://connectrpc.com/docs/protocol#error-codes.
# ---------------------------------------------------------------------------

function _connect_code_string(c::PB.StatusCode.T)
    if c === PB.StatusCode.OK
        return "ok"
    elseif c === PB.StatusCode.CANCELLED
        return "canceled"
    elseif c === PB.StatusCode.UNKNOWN
        return "unknown"
    elseif c === PB.StatusCode.INVALID_ARGUMENT
        return "invalid_argument"
    elseif c === PB.StatusCode.DEADLINE_EXCEEDED
        return "deadline_exceeded"
    elseif c === PB.StatusCode.NOT_FOUND
        return "not_found"
    elseif c === PB.StatusCode.ALREADY_EXISTS
        return "already_exists"
    elseif c === PB.StatusCode.PERMISSION_DENIED
        return "permission_denied"
    elseif c === PB.StatusCode.RESOURCE_EXHAUSTED
        return "resource_exhausted"
    elseif c === PB.StatusCode.FAILED_PRECONDITION
        return "failed_precondition"
    elseif c === PB.StatusCode.ABORTED
        return "aborted"
    elseif c === PB.StatusCode.OUT_OF_RANGE
        return "out_of_range"
    elseif c === PB.StatusCode.UNIMPLEMENTED
        return "unimplemented"
    elseif c === PB.StatusCode.INTERNAL
        return "internal"
    elseif c === PB.StatusCode.UNAVAILABLE
        return "unavailable"
    elseif c === PB.StatusCode.DATA_LOSS
        return "data_loss"
    elseif c === PB.StatusCode.UNAUTHENTICATED
        return "unauthenticated"
    else
        error("unreachable: unknown status code $(c)")
    end
end

const _CONNECT_CODE_LOOKUP = Dict{String,PB.StatusCode.T}(
    _connect_code_string(code) => code for code in instances(PB.StatusCode.T)
)

function _status_from_connect_code(s::AbstractString)
    return get(_CONNECT_CODE_LOOKUP, lowercase(strip(String(s))), PB.StatusCode.UNKNOWN)
end

function _http_status_for(c::PB.StatusCode.T)
    if c === PB.StatusCode.OK
        # An error envelope never carries OK; if a handler throws
        # RpcError(OK, …) anyway, surface it as a server bug.
        return 500
    elseif c === PB.StatusCode.CANCELLED
        return 499
    elseif c === PB.StatusCode.UNKNOWN
        return 500
    elseif c === PB.StatusCode.INVALID_ARGUMENT
        return 400
    elseif c === PB.StatusCode.DEADLINE_EXCEEDED
        return 504
    elseif c === PB.StatusCode.NOT_FOUND
        return 404
    elseif c === PB.StatusCode.ALREADY_EXISTS
        return 409
    elseif c === PB.StatusCode.PERMISSION_DENIED
        return 403
    elseif c === PB.StatusCode.RESOURCE_EXHAUSTED
        return 429
    elseif c === PB.StatusCode.FAILED_PRECONDITION
        return 400
    elseif c === PB.StatusCode.ABORTED
        return 409
    elseif c === PB.StatusCode.OUT_OF_RANGE
        return 400
    elseif c === PB.StatusCode.UNIMPLEMENTED
        return 501
    elseif c === PB.StatusCode.INTERNAL
        return 500
    elseif c === PB.StatusCode.UNAVAILABLE
        return 503
    elseif c === PB.StatusCode.DATA_LOSS
        return 500
    elseif c === PB.StatusCode.UNAUTHENTICATED
        return 401
    else
        error("unreachable: unknown status code $(c)")
    end
end

# Fallback used when the error body lacks a `code` field. Deliberately NOT
# the inverse of `_http_status_for` — the spec's HTTP-to-code table maps
# statuses a bare proxy/load-balancer would send (see "HTTP to Error Code"
# at https://connectrpc.com/docs/protocol#error-codes).
function _status_from_http(status::Integer)
    if status == 400
        return PB.StatusCode.INTERNAL
    elseif status == 401
        return PB.StatusCode.UNAUTHENTICATED
    elseif status == 403
        return PB.StatusCode.PERMISSION_DENIED
    elseif status == 404
        return PB.StatusCode.UNIMPLEMENTED
    elseif status == 429
        return PB.StatusCode.UNAVAILABLE
    elseif status == 502
        return PB.StatusCode.UNAVAILABLE
    elseif status == 503
        return PB.StatusCode.UNAVAILABLE
    elseif status == 504
        return PB.StatusCode.UNAVAILABLE
    else
        return PB.StatusCode.UNKNOWN
    end
end

end # module ProtocGenConnect
