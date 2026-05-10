# ProtocGenJulia.jl

[![CI](https://github.com/jw3126/ProtocGenJulia.jl/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/jw3126/ProtocGenJulia.jl/actions/workflows/ci.yml)
Julia code generator for Protocol Buffers.
It is meant to be used as a protoc plugin.
Passes the required proto2 and proto3 conformance test suites using binary + JSON.

## Install

Install `protoc-gen-julia` binary:

```julia
julia> using Pkg
pkg> app add ProtocGenJulia
```

## Usage

```sh
cd examples
mkdir out

protoc \
    --julia_out=out \
    addressbook.proto
```

`addressbook.proto` imports `google/protobuf/timestamp.proto`; standard
protoc installations ship the well-known-type protos on their default
include path, so no extra `--proto_path` is needed.

This generates `out/addressbook_pb.jl`. It depends on the
`ProtocGenJulia.jl` package.

```julia
include("out/addressbook_pb.jl")

person = Person(
    name = "Alice",
    id = Int32(42),
    email = "alice@example.com",
    phones = [
        PhoneNumber("+1-555-0100", PhoneType.PHONE_TYPE_MOBILE),
        PhoneNumber("+1-555-0101", PhoneType.PHONE_TYPE_WORK),
    ],
    last_updated = google_protobuf.Timestamp(seconds = Int64(1_715_000_000)),
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

## Alternatives

[ProtoBuf.jl](https://github.com/JuliaIO/ProtoBuf.jl) is a good alternative.
It is meant to be used as a julia package, not protoc plugin.

## Acknowledgement

The wire codec under `src/codec/` is copied with light modifications
from [ProtoBuf.jl](https://github.com/JuliaIO/ProtoBuf.jl)
(MIT-licensed, © 2022 RelationalAI / Tomáš Drvoštěp / contributors).
ProtoBuf.jl is the long-running Julia Protocol Buffers library; this
package takes a different architectural route (descriptor-driven, with
proto3 `optional` presence and proto2 `required` semantics fixed) but
stands on its codec. See [LICENSE.md](LICENSE.md).
