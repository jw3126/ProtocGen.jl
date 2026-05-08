module ProtoBufDescriptors

import EnumX
import BufferedStreams
import OrderedCollections: OrderedDict
using TOML

const PACKAGE_VERSION = let
    project = TOML.parsefile(joinpath(@__DIR__, "..", "Project.toml"))
    VersionNumber(project["version"])
end

struct OneOf{T}
    name::Symbol
    value::T
end

"""
    DecodeError(msg)

Thrown by generated `decode` methods when a wire-format invariant is violated
that the decoder can describe — e.g., a proto2 `required` field is missing
from the input. Distinct from `EOFError` and the codec's lower-level errors.
"""
struct DecodeError <: Exception
    msg::String
end

function Base.showerror(io::IO, e::DecodeError)
    print(io, "DecodeError: ", e.msg)
end

function Base.getindex(t::OneOf)
    return t.value
end
function Base.Pair(t::OneOf)
    return t.name => t.value
end

include("codec/Codecs.jl")

import .Codecs
import .Codecs: decode, decode!, encode, AbstractProtoDecoder, AbstractProtoEncoder,
    ProtoDecoder, ProtoEncoder, BufferedVector, message_done, decode_tag, _encoded_size

abstract type AbstractProtoBufMessage end

function reserved_fields(::Type{T}) where {T}
    return (names = String[], numbers = Union{Int,UnitRange{Int}}[])
end

function extendable_field_numbers(::Type{T}) where {T}
    return Union{Int,UnitRange{Int}}[]
end

function oneof_field_types(::Type{T}) where {T}
    return (;)
end

function field_numbers(::Type{T}) where {T}
    return (;)
end

function default_values(::Type{T}) where {T}
    return (;)
end

# Maps each Julia field name → the JSON key it serializes to. Codegen
# emits a method per generated message reading the (already populated)
# `json_name` from the FieldDescriptor; the default-empty NamedTuple
# returned here means "use the Julia field name verbatim" — useful for
# in-process / hand-written types that haven't been through codegen.
function json_field_names(::Type{T}) where {T}
    return (;)
end

# `json.jl` defines `_decode_json_message`, which the generated bootstrap
# files extend (forwarding methods so abstract cycle supertypes route to
# the concrete struct). It has to load *before* `gen/google/google.jl`
# pulls those files in.
include("json.jl")

include("../gen/google/google.jl")

include("codegen.jl")
include("plugin.jl")
include("json_wkt.jl")
include("testing.jl")

export encode, ProtoEncoder, decode, decode!, ProtoDecoder
export encode_json, decode_json
export OneOf, AbstractProtoBufMessage, DecodeError, OrderedDict
export reserved_fields, extendable_field_numbers, oneof_field_types, field_numbers, default_values, json_field_names

end # module
