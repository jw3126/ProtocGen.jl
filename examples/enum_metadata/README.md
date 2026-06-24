# Enum metadata example

Demonstrates the opt-in `enum_metadata` feature: scalar custom options declared
via `extend google.protobuf.EnumValueOptions` are surfaced in the generated
Julia as a type-stable `enum_metadata(value)::NamedTuple` accessor.

- [`palette.proto`](palette.proto) — declares three scalar options (`hex`,
  `sort_order`, `hidden`) and a `Color` enum that sets them on its values.
- [`enum_metadata.toml`](enum_metadata.toml) — enables the feature.
- [`palette_pb.jl`](palette_pb.jl) — the generated bindings.

## Generate

The feature is off by default, so pass the config file to the plugin:

```bash
protoc \
    --plugin=protoc-gen-julia="../../bin/protoc-gen-julia" \
    --julia_out=. \
    --julia_opt=config=enum_metadata.toml \
    --proto_path=. \
    --proto_path=../../gen/proto \
    palette.proto
```

(`--proto_path=../../gen/proto` lets protoc resolve the
`import "google/protobuf/descriptor.proto"` the `extend` block needs.)

## Use

```julia
include("palette_pb.jl")

enum_metadata(Color.BLUE)   # (hex = "0000ff", sort_order = 3, hidden = true)
enum_metadata(Color.RED)    # (hex = "ff0000", sort_order = 1, hidden = false)

# Every value returns the same NamedTuple shape, so the result is type-stable;
# values that set no options get each option's default:
enum_metadata(Color.UNSPECIFIED)  # (hex = "", sort_order = 0, hidden = false)

# e.g. the visible colors, in picker order:
sort!([c for c in instances(Color.T) if !enum_metadata(c).hidden];
      by = c -> enum_metadata(c).sort_order)
```

## Notes

- Only **scalar** options are supported (string, bool, the integer/float
  families, bytes). Message-, group-, and enum-valued options are skipped with
  a warning.
- The accessor is generated only when the proto tree actually declares scalar
  `EnumValueOptions` extensions. Calling `enum_metadata` on an enum without
  generated methods is a `MethodError` — there is no empty-tuple fallback.
