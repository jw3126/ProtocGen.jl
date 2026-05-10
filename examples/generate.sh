#!/usr/bin/env bash
# Generate Julia bindings from the .proto files in this directory.
#
# Requires `protoc` on PATH. The plugin script `bin/protoc-gen-julia`
# is invoked via --plugin=; protoc reads each .proto file, hands its
# FileDescriptorProto to the plugin, and writes the returned Julia
# source to --julia_out.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
PLUGIN="$REPO/bin/protoc-gen-julia"

OUT_DIR="$HERE/out"
mkdir -p "$OUT_DIR"

protoc \
    --plugin=protoc-gen-julia="$PLUGIN" \
    --julia_out="$OUT_DIR" \
    --proto_path="$HERE" \
    --proto_path="$REPO/gen/proto" \
    "$HERE"/*.proto

echo "wrote Julia bindings to $OUT_DIR"
