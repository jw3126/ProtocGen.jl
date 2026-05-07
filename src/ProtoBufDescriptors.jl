module ProtoBufDescriptors

import EnumX
import BufferedStreams
using TOML

const PACKAGE_VERSION = let
    project = TOML.parsefile(joinpath(@__DIR__, "..", "Project.toml"))
    VersionNumber(project["version"])
end

struct OneOf{T}
    name::Symbol
    value::T
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

include("../gen/google/google.jl")

include("plugin.jl")

export encode, ProtoEncoder, decode, decode!, ProtoDecoder
export OneOf, AbstractProtoBufMessage
export reserved_fields, extendable_field_numbers, oneof_field_types, field_numbers, default_values

end # module
