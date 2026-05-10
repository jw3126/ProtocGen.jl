# ProtoBufDescriptors.jl

Julia code generator for Protocol Buffers.
It is meant to be used as a protoc plugin.

## Install

Install `protoc-gen-julia` binary:

```julia
julia> using Pkg
pkg> app add ProtoBufDescriptors
```

## Usage

`addressbook.proto` imports `google/protobuf/timestamp.proto`, so
protoc needs the well-known-types vendored under
`ProtoBufDescriptors/gen/proto` on its proto-path:

```sh
cd examples
mkdir out

protoc \
    --julia_out=out \
    --proto_path=. \
    --proto_path=/path/to/ProtoBufDescriptors/gen/proto \
    addressbook.proto
```

This generates `out/addressbook_pb.jl`. It depends on the
`ProtoBufDescriptors.jl` package.

```julia
import ProtoBufDescriptors as PB
include("out/addressbook_pb.jl")

person = Person(
    name = "Alice",
    id = Int32(42),
    email = "alice@example.com",
    phones = [
        PhoneNumber("+1-555-0100", PhoneType.PHONE_TYPE_MOBILE),
        PhoneNumber("+1-555-0101", PhoneType.PHONE_TYPE_WORK),
    ],
    last_updated = PB.google.protobuf.Timestamp(seconds = Int64(1_715_000_000)),
)

# Binary wire format
bytes = encode(person)
@assert decode(bytes, Person) == person

# Canonical protobuf JSON mapping (Timestamp renders as RFC 3339)
js = encode_json(person)
# {"name":"Alice","id":42,"email":"alice@example.com",
#  "phones":[…],"lastUpdated":"2024-05-06T12:53:20Z"}
@assert decode_json(Person, js) == person
```

`encode` / `decode` / `encode_json` / `decode_json` come in through the
generated file's `using` line; user code only needs `import
ProtoBufDescriptors as PB` to reach the well-known-type modules at
`PB.google.protobuf.<Type>`.

## Acknowledgement

The wire codec under `src/codec/` is copied with light modifications
from [ProtoBuf.jl](https://github.com/JuliaIO/ProtoBuf.jl)
(MIT-licensed, © 2022 RelationalAI / Tomáš Drvoštěp / contributors).
ProtoBuf.jl is the long-running Julia Protocol Buffers library; this
package takes a different architectural route (descriptor-driven, with
proto3 `optional` presence and proto2 `required` semantics fixed) but
stands on its codec. See [LICENSE.md](LICENSE.md).
