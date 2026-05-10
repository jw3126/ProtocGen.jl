#!/usr/bin/env julia
# Regenerate every Julia binding under gen/google/protobuf/ from its
# .proto source under gen/proto/. The whole `gen/` tree is produced by
# our own codegen — ProtocGen self-hosts.
#
# Usage (from repo root):
#     julia gen/regen.jl
#
# Requires `protoc` on PATH and the `bin/protoc-gen-julia` plugin script
# (already executable; the protoc invocation discovers it via --plugin=).
#
# What gets generated (single protoc invocation so the plugin's Universe
# spans every file at once):
#   - descriptor + plugin bootstrap:
#       descriptor.proto         (proto2)
#       compiler/plugin.proto    (proto2, imports descriptor.proto)
#   - dependency-free WKTs:
#       any, duration, empty, field_mask, source_context, timestamp, wrappers
#   - cross-file imports through the codegen Universe:
#       api    — depends on source_context, type
#       type   — depends on any, source_context
#   - recursion via abstract supertypes:
#       struct — Value ↔ Struct ↔ ListValue cycle.

const HERE       = @__DIR__
const REPO       = dirname(HERE)
const PROTO_PATH = joinpath(HERE, "proto")
const OUT_DIR    = HERE  # protoc writes <julia_out>/google/protobuf/<name>_pb.jl
const PLUGIN     = joinpath(REPO, "bin", "protoc-gen-julia")

const PROTOS = [
    # Bootstrap.
    "google/protobuf/descriptor.proto",
    "google/protobuf/compiler/plugin.proto",
    # Well-known types.
    "google/protobuf/any.proto",
    "google/protobuf/duration.proto",
    "google/protobuf/empty.proto",
    "google/protobuf/field_mask.proto",
    "google/protobuf/source_context.proto",
    "google/protobuf/timestamp.proto",
    "google/protobuf/wrappers.proto",
    "google/protobuf/api.proto",
    "google/protobuf/type.proto",
    "google/protobuf/struct.proto",
]

function find_protoc()
    p = Sys.which("protoc")
    p === nothing && error("regen: `protoc` not found on PATH; install protobuf-compiler.")
    return p
end

function main()
    protoc = find_protoc()
    isfile(PLUGIN) || error("regen: plugin script missing at $(PLUGIN)")
    cmd = `$protoc --plugin=protoc-gen-julia=$PLUGIN --julia_out=$OUT_DIR --proto_path=$PROTO_PATH $PROTOS`
    run(cmd)
    for p in PROTOS
        out = joinpath(OUT_DIR, replace(p, r"\.proto$" => "_pb.jl"))
        println("wrote $(relpath(out, REPO))")
    end
end

main()
