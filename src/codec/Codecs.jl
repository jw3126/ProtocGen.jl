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
        # If the previous iteration's field decode/skip overshot the
        # message's declared end, fail loudly instead of silently
        # accepting it as "done". This catches truncated nested
        # messages whose unknown-field skip walked past `endpos`.
        if endpos > 0 && position(io) > endpos
            throw(EOFError())
        end
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

# `_encode` / `_decode` / `_decode!` are the wrapper-form codec entry
# points. They are not exported — the public surface (`encode(io, msg)`,
# `decode(io, T)`, etc.) lives in ProtocGen and forwards into
# them.

end # module
