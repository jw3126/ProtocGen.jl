# [ProtocGen.jl](https://github.com/jw3126/ProtocGen.jl)

<p align="center">
  <img src="docs/src/assets/logo.png" alt="ProtocGen.jl" width="320">
</p>

[![CI](https://github.com/jw3126/ProtocGen.jl/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/jw3126/ProtocGen.jl/actions/workflows/ci.yml)

Julia code generator for Protocol Buffers.
It is meant to be used as a protoc plugin.
Passes the official required proto2 and proto3 [conformance test suites](https://github.com/protocolbuffers/protobuf/tree/c06e6b41d66d6d380427d29ef95ba59991866bf4/conformance) using binary + JSON.

## Install

Install `protoc-gen-julia` binary:

```julia
julia> using Pkg
pkg> app add ProtocGen
```

## Usage

```sh
cd examples
mkdir out

protoc --julia_out=out addressbook.proto
```

````proto
# addressbook.proto
syntax = "proto3";

package tutorial;

import "google/protobuf/timestamp.proto";

enum PhoneType {
    PHONE_TYPE_UNSPECIFIED = 0;
    PHONE_TYPE_MOBILE = 1;
    PHONE_TYPE_HOME = 2;
    PHONE_TYPE_WORK = 3;
}

message PhoneNumber {
    string number = 1;
    PhoneType type = 2;
}

message Person {
    string name = 1;
    int32 id = 2;
    optional string email = 3;
    repeated PhoneNumber phones = 4;
    google.protobuf.Timestamp last_updated = 5;
}

message AddressBook {
    repeated Person people = 1;
}

This generates `out/addressbook_pb.jl`. It depends on the
`ProtocGen.jl` package:

```julia
include("out/addressbook_pb.jl")

person = Person(
    name = "Alice",
    id = Int32(42),
    email = "alice@example.com",
    phones = [
        PhoneNumber(number = "+1-555-0100", type = PhoneType.MOBILE),
        PhoneNumber(number = "+1-555-0101", type = PhoneType.WORK),
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
````

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
