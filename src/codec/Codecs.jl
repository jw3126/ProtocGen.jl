module Codecs

using BufferedStreams: BufferedOutputStream, BufferedInputStream

@enum(WireType::UInt32, VARINT=0, FIXED64=1, LENGTH_DELIMITED=2, START_GROUP=3, END_GROUP=4, FIXED32=5)

abstract type AbstractProtoDecoder end
abstract type AbstractProtoEncoder end
function get_stream(d::AbstractProtoDecoder)
    return d.io
end

mutable struct ProtoDecoder{I<:IO,F<:Function} <: AbstractProtoDecoder
    const io::I
    const message_done::F
end
function message_done(d::AbstractProtoDecoder, endpos::Int, group::Bool)
    io = get_stream(d)
    if group
        done = peek(io) == UInt8(END_GROUP)
        done && skip(io, 1)
    else
        done = d.message_done(io) || (endpos > 0 && position(io) >= endpos)
    end
    return done
end
function ProtoDecoder(io::IO)
    return ProtoDecoder(io, eof)
end

struct ProtoEncoder{I<:IO} <: AbstractProtoEncoder
    io::I
end

function zigzag_encode(x::T) where {T <: Integer}
    return xor(x << 1, x >> (8 * sizeof(T) - 1))
end
function zigzag_decode(x::T) where {T <: Integer}
    return xor(x >> 1, -(x & T(1)))
end

mutable struct BufferedVector{T}
    elements::Vector{T}
    occupied::Int
end
function BufferedVector{T}() where {T}
    return BufferedVector(T[], 0)
end
function BufferedVector(v::Vector{T}) where {T}
    return BufferedVector{T}(v, length(v))
end
function Base.getindex(x::BufferedVector)
    return resize!(x.elements, x.occupied)
end
function empty!(buffer::BufferedVector)
    buffer.occupied = 0
    return buffer
end
@inline function Base.setindex!(buffer::BufferedVector{T}, x::T) where {T}
    if length(buffer.elements) == buffer.occupied
        Base._growend!(buffer.elements, _grow_by(T))
    end
    buffer.occupied += 1
    @inbounds buffer.elements[buffer.occupied] = x
end
function _grow_by(::Type{T}) where {T<:Union{UInt32,UInt64,Int64,Int32,Enum{Int32},Enum{UInt32}}}
    return div(128, sizeof(T))
end
function _grow_by(::Type)
    return 16
end
function _grow_by(::Type{T}) where {T<:Union{Bool,UInt8}}
    return 64
end

include("encoded_size.jl")
include("vbyte.jl")
include("decode.jl")
include("encode.jl")

export encode, decode

end # module
