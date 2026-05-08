#!/usr/bin/env julia
# Regenerate every Julia binding under gen/google/protobuf/ from its
# .proto source under gen/proto/. After Phase 8 the entire `gen/` tree
# is produced by our own codegen — no ProtoBuf.jl on the build path.
#
# Usage (from repo root):
#     julia gen/regen.jl
#
# Requires `protoc` on PATH and the `bin/protoc-gen-julia` plugin script
# (already executable; the protoc invocation discovers it via --plugin=).
#
# What gets generated (single protoc invocation so the plugin's Universe
# spans every file at once):
#   Phase 8 — descriptor + plugin bootstrap:
#     descriptor.proto         (proto2)
#     compiler/plugin.proto    (proto2, imports descriptor.proto)
#   Phase 7a — dependency-free WKTs:
#     any, duration, empty, field_mask, source_context, timestamp, wrappers
#   Phase 7b — cross-file imports through the codegen Universe:
#     api    — depends on source_context, type
#     type   — depends on any, source_context
#   Phase 7b — recursion via abstract supertypes:
#     struct — Value ↔ Struct ↔ ListValue cycle.

const HERE       = @__DIR__
const REPO       = dirname(HERE)
const PROTO_PATH = joinpath(HERE, "proto")
const OUT_DIR    = HERE  # protoc writes <julia_out>/google/protobuf/<name>_pb.jl
const PLUGIN     = joinpath(REPO, "bin", "protoc-gen-julia")

const PROTOS = [
    # Bootstrap (Phase 8 — self-generated, replaces the prior
    # ProtoBuf.jl-emitted versions).
    "google/protobuf/descriptor.proto",
    "google/protobuf/compiler/plugin.proto",
    # WKTs (Phase 7).
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
