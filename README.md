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

```sh
cd examples
mkdir out

protoc \
    --julia_out=out \
    addressbook.proto
```

This will generate `out/addressbook_pb.jl`. It will depend on the `ProtoBufDescriptors.jl` package.

```julia
include("out/addressbook_pb.jl")

person = Person(
    "Alice",
    Int32(42),
    "alice@example.com",
    [
        PhoneNumber("+1-555-0100", PhoneType.PHONE_TYPE_MOBILE),
        PhoneNumber("+1-555-0101", PhoneType.PHONE_TYPE_WORK),
    ],
)

# Binary wire format
bytes = encode(person)
@assert decode(bytes, Person) == person

# Canonical protobuf JSON mapping
js = encode_json(person)
# {"name":"Alice","id":42,"email":"alice@example.com","phones":[{"number":"+1-555-0100","type":"PHONE_TYPE_MOBILE"},…]}
@assert decode_json(Person, js) == person
```

`encode` / `decode` / `encode_json` / `decode_json` come in through the
generated file's `using` line, so user code never has to import
`ProtoBufDescriptors` itself.

WKT references resolve to `ProtoBufDescriptors.google.protobuf`
automatically — no extra wiring.

## Acknowledgement

The wire codec under `src/codec/` is copied with light modifications
from [ProtoBuf.jl](https://github.com/JuliaIO/ProtoBuf.jl)
(MIT-licensed, © 2022 RelationalAI / Tomáš Drvoštěp / contributors).
ProtoBuf.jl is the long-running Julia Protocol Buffers library; this
package takes a different architectural route (descriptor-driven, with
proto3 `optional` presence and proto2 `required` semantics fixed) but
stands on its codec. See [LICENSE.md](LICENSE.md).
