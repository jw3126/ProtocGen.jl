function decode_tag(d::AbstractProtoDecoder)
    b = vbyte_decode(get_stream(d), UInt32)
    field_number = b >> 3
    wire_type = WireType(b & 0x07)
    return field_number, wire_type
end

const _ScalarTypes = Union{Float64,Float32,Int32,Int64,UInt64,UInt32,Bool,String,Vector{UInt8}}
const _ScalarTypesEnum = Union{_ScalarTypes,Enum}

# uint32, uint64
decode(d::AbstractProtoDecoder, ::Type{T}) where {T <: Union{UInt32,UInt64}} = vbyte_decode(get_stream(d), T)
# int32: Negative int32 are encoded in 10 bytes...
# TODO: add check the int is negative if larger than typemax UInt32
decode(d::AbstractProtoDecoder, ::Type{Int32}) = reinterpret(Int32, UInt32(vbyte_decode(get_stream(d), UInt64) % UInt32))
# int64
decode(d::AbstractProtoDecoder, ::Type{Int64}) = reinterpret(Int64, vbyte_decode(get_stream(d), UInt64))
# sfixed32, sfixed64, # fixed32, fixed64
decode(d::AbstractProtoDecoder, ::Type{T}, ::Type{Val{:fixed}}) where {T <: Union{Int32,Int64,UInt32,UInt64}} = read(get_stream(d), T)
# sint32, sint64
function decode(d::AbstractProtoDecoder, ::Type{T}, ::Type{Val{:zigzag}}) where {T <: Union{Int32,Int64}}
    v = vbyte_decode(get_stream(d), unsigned(T))
    z = zigzag_decode(v)
    return reinterpret(T, z)
end
# Bool wire format: a varint where 0 → false, any non-zero → true.
# Spec is unambiguous on the "any non-zero" part; senders are also
# allowed to write the varint in non-canonical (oversized, up to 10
# bytes) form. Read as a UInt64 varint and check zero, matching what
# the `Int32`/`Enum` decoders already do for their values.
decode(d::AbstractProtoDecoder, ::Type{Bool}) = vbyte_decode(get_stream(d), UInt64) != zero(UInt64)
function decode(d::AbstractProtoDecoder, ::Type{T}) where {T <: Union{Enum{Int32},Enum{UInt32}}}
    # protoc sign-extends negative enum values to int64 on the wire (10-byte
    # varint). Read as UInt64 then truncate so we consume the full payload.
    # Same trick the Int32 scalar decoder uses on line 15. Upstream
    # ProtoBuf.jl carries the matching bug.
    val = vbyte_decode(get_stream(d), UInt64) % UInt32
    return Core.bitcast(T, reinterpret(Int32, val))
end
decode(d::AbstractProtoDecoder, ::Type{T}) where {T <: Union{Float64,Float32}} = read(get_stream(d), T)
# ----------------------------------------------------------------------------
# Map-entry decode.
#
# A map<K,V> field is wire-encoded as a `repeated` synthetic message whose
# entries each carry an `optional K key = 1; optional V value = 2;`. Per the
# spec the entry is a regular protobuf message — i.e., fields can appear in
# either order, can repeat (last wins), and can be missing entirely (use
# the type's default). We therefore loop over the entry's fields,
# dispatching on field number, instead of expecting exactly two tags in
# fixed order.
# ----------------------------------------------------------------------------

# Type-default for a map key/value cell. Scalars get their identity zero;
# strings / bytes / enums get the obvious empty / numeric-zero forms;
# message-typed values fall through to the helper below.
@inline _map_default(::Type{T}) where {T<:Union{Float64,Float32,Int32,Int64,UInt32,UInt64,Bool}} = zero(T)
@inline _map_default(::Type{String})              = ""
@inline _map_default(::Type{Vector{UInt8}})       = UInt8[]
@inline _map_default(::Type{T}) where {T<:Enum}   = T(0)

# Default for a message-typed map value: the all-defaults instance,
# obtained by running the type's own decoder against an empty buffer
# (which writes every default and reads no bytes).
@inline function _empty_message(::Type{T}) where {T}
    return decode(ProtoDecoder(IOBuffer(UInt8[])), T, 0, false)
end

function decode!(d::AbstractProtoDecoder, buffer::AbstractDict{K,V}) where {K,V<:_ScalarTypesEnum}
    io = get_stream(d)
    pair_len = vbyte_decode(io, UInt32)
    pair_end_pos = position(io) + pair_len
    key = _map_default(K)
    val = _map_default(V)
    while position(io) < pair_end_pos
        field_number, wire_type = decode_tag(d)
        if field_number == 1
            key = decode(d, K)
        elseif field_number == 2
            val = decode(d, V)
        else
            Base.skip(d, wire_type)
        end
    end
    buffer[key] = val
    return nothing
end

function decode!(d::AbstractProtoDecoder, buffer::AbstractDict{K,V}) where {K,V}
    io = get_stream(d)
    pair_len = vbyte_decode(io, UInt32)
    pair_end_pos = position(io) + pair_len
    key = _map_default(K)
    val = _empty_message(V)
    while position(io) < pair_end_pos
        field_number, wire_type = decode_tag(d)
        if field_number == 1
            key = decode(d, K)
        elseif field_number == 2
            val = decode(d, Ref{V})
        else
            Base.skip(d, wire_type)
        end
    end
    buffer[key] = val
    return nothing
end

for T in (:(:fixed), :(:zigzag))
    @eval function decode!(d::AbstractProtoDecoder, buffer::AbstractDict{K,V}, ::Type{Val{Tuple{Nothing,$(T)}}}) where {K,V}
        io = get_stream(d)
        pair_len = vbyte_decode(io, UInt32)
        pair_end_pos = position(io) + pair_len
        key = _map_default(K)
        val = _map_default(V)
        while position(io) < pair_end_pos
            field_number, wire_type = decode_tag(d)
            if field_number == 1
                key = decode(d, K)
            elseif field_number == 2
                val = decode(d, V, Val{$(T)})
            else
                Base.skip(d, wire_type)
            end
        end
        buffer[key] = val
        return nothing
    end

    @eval function decode!(d::AbstractProtoDecoder, buffer::AbstractDict{K,V}, ::Type{Val{Tuple{$(T),Nothing}}}) where {K,V}
        io = get_stream(d)
        pair_len = vbyte_decode(io, UInt32)
        pair_end_pos = position(io) + pair_len
        key = _map_default(K)
        val = _map_default(V)
        while position(io) < pair_end_pos
            field_number, wire_type = decode_tag(d)
            if field_number == 1
                key = decode(d, K, Val{$(T)})
            elseif field_number == 2
                val = decode(d, V)
            else
                Base.skip(d, wire_type)
            end
        end
        buffer[key] = val
        return nothing
    end
end

for T in (:(:fixed), :(:zigzag)), S in (:(:fixed), :(:zigzag))
    @eval function decode!(d::AbstractProtoDecoder, buffer::AbstractDict{K,V}, ::Type{Val{Tuple{$(T),$(S)}}}) where {K,V}
        io = get_stream(d)
        pair_len = vbyte_decode(io, UInt32)
        pair_end_pos = position(io) + pair_len
        key = _map_default(K)
        val = _map_default(V)
        while position(io) < pair_end_pos
            field_number, wire_type = decode_tag(d)
            if field_number == 1
                key = decode(d, K, Val{$(T)})
            elseif field_number == 2
                val = decode(d, V, Val{$(S)})
            else
                Base.skip(d, wire_type)
            end
        end
        buffer[key] = val
        return nothing
    end
end

function decode(d::AbstractProtoDecoder, ::Type{String})
    bytelen = vbyte_decode(get_stream(d), UInt32)
    str = Base._string_n(bytelen)
    Base.unsafe_read(get_stream(d), pointer(str), bytelen)
    return str
end
function decode!(d::AbstractProtoDecoder, buffer::BufferedVector{String})
    buffer[] = decode(d, String)
    return nothing
end

function decode(d::AbstractProtoDecoder, ::Type{Vector{UInt8}})
    bytelen = vbyte_decode(get_stream(d), UInt32)
    return read(get_stream(d), bytelen)
end
function decode(d::AbstractProtoDecoder, ::Type{Base.CodeUnits{UInt8, String}})
    bytelen = vbyte_decode(get_stream(d), UInt32)
    return read(get_stream(d), bytelen)
end
function decode!(d::AbstractProtoDecoder, buffer::BufferedVector{Vector{UInt8}})
    buffer[] = decode(d, Vector{UInt8})
    return nothing
end

function decode!(d::AbstractProtoDecoder, w::WireType, buffer::BufferedVector{T}) where {T <: Union{Int32,Int64,UInt32,UInt64,Enum{Int32},Enum{UInt32}}}
    if w == LENGTH_DELIMITED
        io = get_stream(d)
        bytelen = vbyte_decode(io, UInt32)
        endpos = bytelen + position(io)
        while position(io) < endpos
            buffer[] = decode(d, T)
        end
        @assert position(io) == endpos
    else
        buffer[] = decode(d, T)
    end
    return nothing
end

function decode!(d::AbstractProtoDecoder, w::WireType, buffer::BufferedVector{T}, ::Type{Val{:zigzag}}) where {T <: Union{Int32,Int64}}
    if w == LENGTH_DELIMITED
        io = get_stream(d)
        bytelen = vbyte_decode(io, UInt32)
        endpos = bytelen + position(io)
        while position(io) < endpos
            buffer[] = decode(d, T, Val{:zigzag})
        end
        @assert position(io) == endpos
    else
        buffer[] = decode(d, T, Val{:zigzag})
    end
    return nothing
end

function decode!(d::AbstractProtoDecoder, w::WireType, buffer::BufferedVector{T}, ::Type{Val{:fixed}}) where {T <: Union{Int32,Int64,UInt32,UInt64}}
    if w == LENGTH_DELIMITED
        io = get_stream(d)
        bytelen = vbyte_decode(io, UInt32)
        n_incoming = div(bytelen, sizeof(T))
        n_current = length(buffer.elements)
        resize!(buffer.elements, n_current + n_incoming)
        endpos = bytelen + position(io)
        for i in (n_current+1):(n_current + n_incoming)
            buffer.occupied += 1
            @inbounds buffer.elements[i] = decode(d, T, Val{:fixed})
        end
        @assert position(io) == endpos
    else
        buffer[] = decode(d, T, Val{:fixed})
    end
    return nothing
end

function decode!(d::AbstractProtoDecoder, w::WireType, buffer::BufferedVector{T}) where {T <: Union{Bool,Float32,Float64}}
    if w == LENGTH_DELIMITED
        io = get_stream(d)
        bytelen = vbyte_decode(io, UInt32)
        n_incoming = div(bytelen, sizeof(T))
        n_current = length(buffer.elements)
        resize!(buffer.elements, n_current + n_incoming)
        endpos = bytelen + position(io)
        for i in (n_current+1):(n_current + n_incoming)
            buffer.occupied += 1
            @inbounds buffer.elements[i] = decode(d, T)
        end
        @assert position(io) == endpos
    else
        buffer[] = decode(d, T)
    end
    return nothing
end

@noinline function _warn_old_decode_method()
    @warn "You are using code generated by an older version of ProtoBuf.jl, which \
    was deprecated. Please regenerate your protobuf definitions with the current version of \
    ProtoBuf.jl. The new version will allow for defining custom AbstractProtoDecoder variants. \
    This warning is only printed once per session." maxlog=1
    return nothing
end

# This method handles messages decoded as OneOf / repeated. We expect `decode(d, T)`
# to be generated / provided by the user. We do this so that we can conditionally
# eat the length varint (which is not present when decoding a toplevel message).
# We don't reuse the decode!(d::AbstractProtoDecoder, buffer::Base.RefValue{T}) method above
# as with OneOf fields, we can't be sure that the previous OneOf value was also T.
function decode(d::AbstractProtoDecoder, ::Type{Ref{T}}) where {T}
    io = get_stream(d)
    bytelen = vbyte_decode(io, UInt32)
    endpos = bytelen + position(io)
    if hasmethod(decode, Tuple{AbstractProtoDecoder, Type{T}, Int, Bool})
        out = decode(d, T, endpos, false)
    else
        _warn_old_decode_method()
        out = decode(LengthDelimitedProtoDecoder(get_stream(d), endpos), T)
    end
    @assert position(io) == endpos "$(T) decode: expected position $(endpos), got $(position(io))"
    return out
end

function decode!(d::AbstractProtoDecoder, buffer::BufferedVector{T}) where {T}
    buffer[] = decode(d, Ref{T})
    return nothing
end

function decode(d::AbstractProtoDecoder, ::Type{Ref{T}}, ::Type{Val{:group}}) where {T}
    if hasmethod(decode, Tuple{AbstractProtoDecoder, Type{T}, Int, Bool})
        out = decode(d, T, 0, true)
    else
        _warn_old_decode_method()
        out = decode(GroupProtoDecoder(get_stream(d)), T)
    end
    return out
end

function decode!(d::AbstractProtoDecoder, buffer::BufferedVector{T}, ::Type{Val{:group}}) where {T}
    buffer[] = decode(d, Ref{T}, Val{:group})
    return nothing
end

# When the type signature on buffer was Base.RefValue{Union{T,Nothing}} where T,
# Aqua was complaining about an unbound type parameter.
function decode!(d::AbstractProtoDecoder, buffer::Base.RefValue{S}) where {S>:Nothing}
    T = Core.Compiler.typesubtract(S, Nothing, 2)
    if !isnothing(buffer[])
        buffer[] = _merge_structs(getindex(buffer)::T, decode(d, Ref{T}))
    else
        buffer[] = decode(d, Ref{T})
    end
    return nothing
end

function decode!(d::AbstractProtoDecoder, buffer::Base.RefValue{T}) where {T}
    if isassigned(buffer)
        buffer[] = _merge_structs(buffer[], decode(d, Ref{T}))
    else
        buffer[] = decode(d, Ref{T})
    end
    return nothing
end

function decode!(d::AbstractProtoDecoder, buffer::Base.RefValue{S}, ::Type{Val{:group}}) where {S>:Nothing}
    T = Core.Compiler.typesubtract(S, Nothing, 2)
    if !isnothing(buffer[])
        buffer[] = _merge_structs(getindex(buffer)::T, decode(d, Ref{T}, Val{:group}))
    else
        buffer[] = decode(d, Ref{T}, Val{:group})
    end
    return nothing
end

function decode!(d::AbstractProtoDecoder, buffer::Base.RefValue{T}, ::Type{Val{:group}}) where {T}
    if isassigned(buffer)
        buffer[] = _merge_structs(buffer[], decode(d, Ref{T}, Val{:group}))
    else
        buffer[] = decode(d, Ref{T}, Val{:group})
    end
    return nothing
end

# From docs: Normally, an encoded message would never have more than one instance of a non-repeated field.
# ...
# For embedded message fields, the parser merges multiple instances of the same field, as if with the
# Message::MergeFrom method – that is, all singular scalar fields in the latter instance replace
# those in the former, singular embedded messages are merged, and repeated fields are concatenated.
# The effect of these rules is that parsing the concatenation of two encoded messages
# produces exactly the same result as if you had parsed the two messages separately
# and merged the resulting objects
@generated function _merge_structs(s1::Union{Nothing,T}, s2::T) where {T}
    isbitstype(s1) && return :(return s2)
    # TODO: Error gracefully on unsuported types like Missing, Matrices...
    #       Would be easier if we have a HolyTrait for user defined structs
    merged_values = Tuple(
        (
            type <: _ScalarTypesEnum ? :(s2.$(name)) :
            type <: AbstractVector ? :(vcat(s1.$(name), s2.$(name))) :
            :(_merge_structs(s1.$(name), s2.$(name)))
        )
        for (name, type)
        in zip(fieldnames(T), fieldtypes(T))
    )
    return quote T($(merged_values...)) end
end

@generated function _merge_structs!(s1::Union{Nothing,T}, s2::T) where {T}
    isbitstype(s1) && :(return nothing)
    exprs = Expr[]
    for (name, type) in zip(fieldnames(T), fieldtypes(T))
        (type <: _ScalarTypesEnum) && continue
        if (type <: AbstractVector)
            push!(exprs, :(prepend!(s2.$(name), s1.$(name));))
        else
            push!(exprs, :(_merge_structs!(s1.$(name), s2.$(name));))
        end
    end
    return quote
        $(exprs...)
        return nothing
    end
end

@inline function Base.skip(d::AbstractProtoDecoder, wire_type::WireType)
    io = get_stream(d)
    if wire_type == VARINT
        while read(io, UInt8) >= 0x80 end
    elseif wire_type == FIXED64
        skip(io, 8)
    elseif wire_type == LENGTH_DELIMITED
        bytelen = vbyte_decode(io, UInt32)
        skip(io, bytelen)
    elseif wire_type == START_GROUP
        while peek(io) != UInt8(END_GROUP)
            skip(d, decode_tag(d)[2])
        end
        skip(io, 1)
    elseif wire_type == FIXED32
        skip(io, 4)
    else wire_type == END_GROUP
        error("Encountered END_GROUP wiretype while skipping")
    end
    return nothing
end
