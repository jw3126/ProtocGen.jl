# ProtoBufDescriptors.jl

A descriptor-driven Protocol Buffers compiler and runtime for Julia.

This package consumes `FileDescriptorSet` blobs (the output of `protoc`) and
emits Julia source. It can run as a `protoc-gen-julia` plugin or as an offline
generator. It does **not** parse `.proto` text directly; that's `protoc`'s job.

## Status

Pre-release. Phase 0 skeleton; APIs not stable.

## Differences from ProtoBuf.jl

`ProtoBuf.jl` parses `.proto` text directly in Julia and has its own well-loved
API. This package takes a different architectural route:

- Codegen consumes `FileDescriptorSet` blobs from `protoc`. No Julia-side
  `.proto` parser.
- Operates as a standard `protoc` plugin, so it composes with the existing
  protobuf tooling ecosystem (`buf`, Bazel `rules_proto`, etc.).
- Nullable singular fields use `Union{Nothing, T}` instead of zero-default
  scalars, so proto3 `optional` and proto2 `optional` track presence
  correctly. This matters for round-tripping messages produced by
  spec-conformant senders.
- `proto2 required` fields throw on decode if absent, instead of silently
  defaulting.

## Acknowledgement

The wire codec (`src/codec/`) is copied with light modifications from
[ProtoBuf.jl](https://github.com/JuliaIO/ProtoBuf.jl), copyright (c) 2022
RelationalAI, Tomáš Drvoštěp, and contributors, MIT-licensed. The descriptor
type bootstrap was generated using ProtoBuf.jl's `protojl` and committed to
this repo. After Phase 8, descriptor types are regenerated from the package's
own codegen and ProtoBuf.jl is no longer involved at runtime or build time.

See [LICENSE.md](LICENSE.md) for the full licenses.
