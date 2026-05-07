# gen/

Generated descriptor types and the proto sources they were generated from.
This directory exists to make Phase 2 of the package reproducible without a
checked-in binary blob.

## Layout

- `gen/google/...` — Julia bindings included from `src/ProtoBufDescriptors.jl`.
- `gen/proto/google/...` — the `.proto` sources used as input.

## Phase 2 bootstrap (current)

The Julia bindings here were produced one-shot by a fork of `ProtoBuf.jl`'s
`protojl` (branch `proto3-optional-scalars`, with `_is_proto3_optional_scalar`
broadened to also fire on proto2 `optional` so that proto2 `optional` scalars
correctly become `Union{Nothing,T}`) and then mechanically patched to import
`ProtoBufDescriptors` instead of `ProtoBuf`. The headers of `descriptor_pb.jl`
and `compiler/plugin_pb.jl` say so explicitly. To reproduce:

```julia
# Requires the proto3-optional-scalars fork of ProtoBuf.jl checked out.
using ProtoBuf
ProtoBuf.protojl(
    ["google/protobuf/descriptor.proto", "google/protobuf/compiler/plugin.proto"],
    joinpath(@__DIR__, "proto"),
    "/tmp/regen";
    include_vendored_wellknown_types = false,
    always_use_modules            = true,
    force_required                = nothing,
    add_kwarg_constructors        = false,
    parametrize_oneofs            = false,
    common_abstract_type          = false,
)
```

Then `diff -ru /tmp/regen gen/google` and apply the import patches at the top
of `descriptor_pb.jl` and `compiler/plugin_pb.jl` (replace `import ProtoBuf
as PB` / `using ProtoBuf...` with the equivalent `ProtoBufDescriptors`
imports).

`gen/proto/google/protobuf/descriptor.proto` is the older `descriptor.proto`
vendored by ProtoBuf.jl with `proto3_optional` (field 17 of
`FieldDescriptorProto`) hand-patched in. We use this older `descriptor.proto`
because `ProtoBuf.jl`'s text parser does not handle the newer
`extensions ... [declaration = {...}]` syntax in upstream `descriptor.proto`.
The newer fields we don't carry (Editions, ExtensionRangeOptions.declaration,
etc.) are decoded as unknown fields and discarded, which is the proto wire
contract.

`gen/proto/google/protobuf/compiler/plugin.proto` is taken from
`/usr/include/google/protobuf/compiler/plugin.proto` (libprotoc 3.20.x) as is.

## Phase 8 (future)

This directory is replaced by output from `ProtoBufDescriptors`'s own codegen,
and a CI check ensures regeneration produces no diff. ProtoBuf.jl drops out as
a dependency at that point.
