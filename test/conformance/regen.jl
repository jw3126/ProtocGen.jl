#!/usr/bin/env julia
# Regenerate test/conformance/conformance_descriptors.pb — a single
# FileDescriptorSet bundling everything the testee needs:
#
#   - conformance.proto                  (the runner/testee wire protocol)
#   - test_messages_proto3.proto         (the proto3 corpus)
#   - test_messages_proto2_patched.proto (the proto2 corpus, minus deferred features)
#
# `--include_imports` drags in transitive WKT descriptors so the codegen
# Universe sees imported types without a separate fetch.
#
# Usage (from repo root):
#     julia test/conformance/regen.jl

const HERE = @__DIR__
const ROOT = abspath(joinpath(HERE, "..", ".."))
const CONF_PROTO = joinpath(HERE, "proto")
const FIX_PROTO = joinpath(ROOT, "test", "fixtures", "proto")
const WKT_PROTO = joinpath(ROOT, "gen", "proto")
const OUT = joinpath(HERE, "conformance_descriptors.pb")

function find_protoc()
    p = Sys.which("protoc")
    p === nothing && error("regen: `protoc` not found on PATH; install protobuf-compiler.")
    return p
end

function main()
    protoc = find_protoc()
    run(`$protoc
        --proto_path=$CONF_PROTO
        --proto_path=$FIX_PROTO
        --proto_path=$WKT_PROTO
        --include_imports
        --descriptor_set_out=$OUT
        conformance.proto
        test_messages_proto2_patched.proto
        test_messages_proto3.proto`)
    println("wrote $(relpath(OUT, ROOT))")
end

main()
