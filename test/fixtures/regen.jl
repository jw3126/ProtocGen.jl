#!/usr/bin/env julia
# Regenerate every test fixture under test/fixtures/pb/ from its
# .proto / .txtpb source. Requires `protoc` on PATH.
#
# Usage (from repo root):
#     julia test/fixtures/regen.jl
#
# Tests then load these binaries via `read(joinpath(FIXTURES, "<name>.pb"))`.
# Keeping the bytes on disk (instead of inlining UInt8 arrays in test files)
# makes tests independent of `protoc` at run time while still being
# regenerable from declarative inputs.

const HERE  = @__DIR__
const PROTO = joinpath(HERE, "proto")
const TXTPB = joinpath(HERE, "txtpb")
const PB    = joinpath(HERE, "pb")

# (output_pb, source_proto, message, textproto_input).
# Each entry produces one binary by piping `txtpb` through
# `protoc --encode=<message>`.
const PAYLOADS = [
    ("sample_outer.pb",       "sample.proto",  "sample.Outer",  "sample_outer.txtpb"),
    ("outer_maybe_zero.pb",   "sample.proto",  "sample.Outer",  "outer_maybe_zero.txtpb"),
    ("outer_maybe_unset.pb",  "sample.proto",  "sample.Outer",  "outer_maybe_unset.txtpb"),
    ("corpus_sample.pb",      "corpus.proto",  "corpus.Wide",   "corpus_sample.txtpb"),
    ("maps_sample.pb",        "maps.proto",    "maps.Bag",      "maps_sample.txtpb"),
    ("p2_full.pb",            "p2.proto",      "p2.Wrap",       "p2_full.txtpb"),
    ("p2_minimal.pb",         "p2.proto",      "p2.Wrap",       "p2_minimal.txtpb"),
    ("rep_sample.pb",         "rep.proto",     "rep.M",         "rep_sample.txtpb"),
    ("maps_fx_sample.pb",     "maps_fx.proto", "mfx.Bag",       "maps_fx_sample.txtpb"),
]

# .proto files whose FileDescriptorSet we capture (as the codegen input
# fixture). Output name mirrors the proto name with `.pb` extension.
const DESCRIPTOR_SETS = [
    "sample.proto",
    "corpus.proto",
    "maps.proto",
    "p2.proto",
    "rep.proto",
    "maps_fx.proto",
]

function find_protoc()
    p = Sys.which("protoc")
    p === nothing && error("regen: `protoc` not found on PATH; install protobuf-compiler.")
    return p
end

function main()
    protoc = find_protoc()
    isdir(PB) || mkpath(PB)

    for proto in DESCRIPTOR_SETS
        out = joinpath(PB, replace(proto, r"\.proto$" => ".pb"))
        run(`$protoc --proto_path=$PROTO --descriptor_set_out=$out $proto`)
        println("wrote $(relpath(out, HERE))")
    end

    for (out_name, proto, msg, txtpb_name) in PAYLOADS
        out = joinpath(PB, out_name)
        in_path = joinpath(TXTPB, txtpb_name)
        cmd = pipeline(`$protoc --encode=$msg --proto_path=$PROTO $proto`,
                       stdin = in_path, stdout = out)
        run(cmd)
        println("wrote $(relpath(out, HERE))")
    end
end

main()
