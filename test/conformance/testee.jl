#!/bin/sh
# -*- mode: julia -*-
#=
# Self-executing Julia script. The shell exec below sits inside a Julia
# multi-line comment so Julia ignores it; the shell runs it and re-execs
# julia on this same file. This lets `conformance_test_runner` invoke the
# testee like any other binary.
HERE="$(cd "$(dirname "$0")" && pwd)"
exec julia --project="${HERE}/../.." --startup-file=no --color=no "$0" "$@"
=#

# Conformance testee for ProtoBufDescriptors.
#
# Runs as a subprocess of Google's `conformance_test_runner`. The runner
# spawns one testee, then sends framed `conformance.ConformanceRequest`
# blobs over stdin and reads framed `conformance.ConformanceResponse`
# blobs from stdout. Frame format on each stream is:
#
#     4 bytes little-endian length N
#     N bytes serialized message
#
# Run loop ends when the runner closes our stdin.
#
# At startup we feed the bundled FileDescriptorSet
# (test/conformance/conformance_descriptors.pb) through our own codegen
# and eval the result into three sub-modules. Everything else is plain
# decode → encode dispatch on `request.message_type`.
#
# We only support the protobuf wire format. JSON / JSPB / TEXT_FORMAT
# input or output is reported via `response.skipped`, which the runner
# treats as a non-failure.

using ProtoBufDescriptors
const PBD = ProtoBufDescriptors
const _G  = PBD.google.protobuf
const _GC = PBD.google.protobuf.compiler

const HERE     = @__DIR__
const FDS_PATH = joinpath(HERE, "conformance_descriptors.pb")

function load_generated_modules()
    fds = PBD.decode(PBD.ProtoDecoder(IOBuffer(read(FDS_PATH))), _G.FileDescriptorSet)
    request = _GC.CodeGeneratorRequest(
        ["conformance.proto",
         "test_messages_proto2_patched.proto",
         "test_messages_proto3.proto"],
        nothing,
        fds.file,
        _G.FileDescriptorProto[],
        nothing,
    )
    response = PBD.generate(request)
    if response.error !== nothing && !isempty(response.error)
        error("conformance testee: codegen failed:\n", response.error)
    end
    name_for = Dict(
        "conformance_pb.jl"                  => :GenConformance,
        "test_messages_proto2_patched_pb.jl" => :GenProto2,
        "test_messages_proto3_pb.jl"         => :GenProto3,
    )
    out = Dict{String,Module}()
    for f in response.file
        m = Module(name_for[f.name])
        Core.eval(m, Meta.parseall(f.content))
        out[f.name] = m
    end
    return out
end

const MODULES = load_generated_modules()
const Conf    = MODULES["conformance_pb.jl"]
const Proto2  = MODULES["test_messages_proto2_patched_pb.jl"]
const Proto3  = MODULES["test_messages_proto3_pb.jl"]

const MESSAGE_TYPE = Dict{String,Type}(
    "protobuf_test_messages.proto2.TestAllTypesProto2" => Proto2.TestAllTypesProto2,
    "protobuf_test_messages.proto3.TestAllTypesProto3" => Proto3.TestAllTypesProto3,
)

const WF_PROTOBUF = Conf.WireFormat.PROTOBUF
const WF_JSON     = Conf.WireFormat.JSON
const TC_JSON_IGNORE_UNKNOWN = Conf.TestCategory.JSON_IGNORE_UNKNOWN_PARSING_TEST

function read_le_uint32(io)::Union{Nothing,UInt32}
    bs = read(io, 4)
    isempty(bs) && return nothing
    length(bs) == 4 || error("conformance testee: short read on length prefix")
    return UInt32(bs[1]) |
           (UInt32(bs[2]) << 8) |
           (UInt32(bs[3]) << 16) |
           (UInt32(bs[4]) << 24)
end

function write_le_uint32(io, n::Integer)
    n = UInt32(n)
    write(io, UInt8(n & 0xff))
    write(io, UInt8((n >> 8) & 0xff))
    write(io, UInt8((n >> 16) & 0xff))
    write(io, UInt8((n >> 24) & 0xff))
    return nothing
end

function pb_encode(x)::Vector{UInt8}
    io = IOBuffer()
    PBD.encode(PBD.ProtoEncoder(io), x)
    return take!(io)
end

function pb_decode(::Type{T}, bytes::AbstractVector{UInt8}) where {T}
    return PBD.decode(PBD.ProtoDecoder(IOBuffer(bytes)), T)
end

function skipped_response(reason::AbstractString)
    return Conf.ConformanceResponse(PBD.OneOf(:skipped, String(reason)))
end

function handle_request(req)
    # The runner's first request is always a probe asking which tests we
    # know we'll fail. We don't predict those — return an empty FailureSet.
    if req.message_type == "conformance.FailureSet"
        fs = Conf.FailureSet(String[])
        return Conf.ConformanceResponse(PBD.OneOf(:protobuf_payload, pb_encode(fs)))
    end

    payload = req.payload
    if payload === nothing
        return Conf.ConformanceResponse(PBD.OneOf(:parse_error, "no payload in request"))
    end

    # JSPB / TEXT_FORMAT input remain skipped; binary and JSON we handle.
    if !(payload.name in (:protobuf_payload, :json_payload))
        return skipped_response(
            "input format $(payload.name) not supported by ProtoBufDescriptors v1 (binary + JSON only)")
    end
    if !(req.requested_output_format in (WF_PROTOBUF, WF_JSON))
        return skipped_response(
            "output format $(req.requested_output_format) not supported by ProtoBufDescriptors v1 (binary + JSON only)")
    end

    T = get(MESSAGE_TYPE, req.message_type, nothing)
    if T === nothing
        return Conf.ConformanceResponse(PBD.OneOf(:runtime_error,
            "unknown message_type: $(req.message_type)"))
    end

    # ---- Parse ----
    msg = try
        if payload.name === :protobuf_payload
            pb_decode(T, payload.value)
        else
            ignore_unknown = req.test_category == TC_JSON_IGNORE_UNKNOWN
            PBD.decode_json(T, payload.value; ignore_unknown_fields = ignore_unknown)
        end
    catch e
        return Conf.ConformanceResponse(PBD.OneOf(:parse_error, sprint(showerror, e)))
    end

    # ---- Serialize ----
    if req.requested_output_format == WF_PROTOBUF
        bytes = try
            pb_encode(msg)
        catch e
            return Conf.ConformanceResponse(PBD.OneOf(:serialize_error, sprint(showerror, e)))
        end
        return Conf.ConformanceResponse(PBD.OneOf(:protobuf_payload, bytes))
    else  # WF_JSON
        json = try
            PBD.encode_json(msg)
        catch e
            return Conf.ConformanceResponse(PBD.OneOf(:serialize_error, sprint(showerror, e)))
        end
        return Conf.ConformanceResponse(PBD.OneOf(:json_payload, json))
    end
end

function main()
    in_io  = stdin
    out_io = stdout
    while true
        len = read_le_uint32(in_io)
        len === nothing && break
        bytes = read(in_io, Int(len))
        length(bytes) == len || error("conformance testee: short read on payload")
        req = pb_decode(Conf.ConformanceRequest, bytes)

        resp = try
            handle_request(req)
        catch e
            Conf.ConformanceResponse(PBD.OneOf(:runtime_error, sprint(showerror, e)))
        end

        out_bytes = pb_encode(resp)
        write_le_uint32(out_io, length(out_bytes))
        write(out_io, out_bytes)
        flush(out_io)
    end
end

main()
