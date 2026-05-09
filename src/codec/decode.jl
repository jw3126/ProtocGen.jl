function decode_tag(d::AbstractProtoDecoder)
    b = vbyte_decode(get_stream(d), UInt32)
    field_number = b >> 3
    # Field number 0 is reserved by the protobuf spec — it cannot
    # appear on the wire. Reject explicitly so we don't silently
    # accept malformed input.
    field_number == 0 && error("decode_tag: tag has illegal field_number 0")
    wire_type = WireType(b & 0x07)
    return field_number, wire_type
end

const _ScalarTypes = Union{Float64,Float32,Int32,Int64,UInt64,UInt32,Bool,String,Vector{UInt8}}
const _ScalarTypesEnum = Union{_ScalarTypes,Enum}

# uint64
decode(d::AbstractProtoDecoder, ::Type{UInt64}) = vbyte_decode(get_stream(d), UInt64)
# uint32. The wire spec lets a UINT32 varint be up to 10 bytes — protoc
# happily emits e.g. `varint(kInt64Max)` into a uint32 field, expecting
# the decoder to consume the whole thing and truncate. Read as UInt64
# and truncate, matching what Int32 already does (line below). The
# bare `vbyte_decode(io, UInt32)` only handles up to 5 bytes; tags
# (always ≤ 5 bytes) and small uint32 lengths are still its territory.
decode(d::AbstractProtoDecoder, ::Type{UInt32}) = vbyte_decode(get_stream(d), UInt64) % UInt32
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
    io = get_stream(d)
    bytelen = vbyte_decode(io, UInt32)
    # `read(io, n)` returns up to `n` bytes — silent on truncation. The
    # spec wants malformed input rejected, so check first (matches the
    # symmetric LENGTH_DELIMITED check in `Base.skip` below).
    bytesavailable(io) >= bytelen || throw(EOFError())
    return read(io, bytelen)
end
function decode(d::AbstractProtoDecoder, ::Type{Base.CodeUnits{UInt8, String}})
    io = get_stream(d)
    bytelen = vbyte_decode(io, UInt32)
    bytesavailable(io) >= bytelen || throw(EOFError())
    return read(io, bytelen)
end
function decode!(d::AbstractProtoDecoder, buffer::BufferedVector{Vector{UInt8}})
    buffer[] = decode(d, Vector{UInt8})
    return nothing
end

function decode!(d::AbstractProtoDecoder, w::WireType, buffer::BufferedVector{T}) where {T <: Union{Bool,Int32,Int64,UInt32,UInt64,Enum{Int32},Enum{UInt32}}}
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

function decode!(d::AbstractProtoDecoder, w::WireType, buffer::BufferedVector{T}) where {T <: Union{Float32,Float64}}
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
        _merge_field_expr(name, type)
        for (name, type)
        in zip(fieldnames(T), fieldtypes(T))
    )
    return quote T($(merged_values...)) end
end

# Per-field merge expression for the @generated body. Inline-handle every
# field shape codegen can emit so we don't have to dispatch through
# `_merge_structs` for cases the primary handler can't see (notably
# `Union{Nothing,...}`, where it requires `s2::T` concrete and the inner
# bits-type early return doesn't fire on Union types).
function _merge_field_expr(name::Symbol, type)
    if type <: _ScalarTypesEnum
        # Bare scalar/enum (proto3 non-presence). Spec: latter replaces
        # former. But proto3 encoders are required to skip equal-to-
        # default scalars, so a 0/""/[] arriving on `s2` was never on
        # the wire — treat it as "unset" and keep `s1`. This is the
        # only way to match the wire-level merge semantics without
        # tracking presence on every bare scalar.
        return :(_at_default(s2.$(name)) ? s1.$(name) : s2.$(name))
    elseif type <: AbstractVector
        # Repeated: concatenate.
        return :(vcat(s1.$(name), s2.$(name)))
    elseif type <: AbstractDict
        # Map: per-key last-wins (s2 entries override s1).
        return :(merge(s1.$(name), s2.$(name)))
    elseif type isa Union && Nothing <: type
        # Presence-bearing field. Inline the nothing-checks so we never
        # hit `_merge_structs(::Union{Nothing,T}, ::Union{Nothing,T})` —
        # that signature isn't matched by the primary handler (s2 must
        # be concrete `T`).
        inner = Core.Compiler.typesubtract(type, Nothing, 2)
        if inner <: _ScalarTypesEnum
            # Presence scalar / enum: last-wins on set, else keep s1.
            return :(s2.$(name) === nothing ? s1.$(name) : s2.$(name))
        else
            # Presence submessage / oneof: merge if both set, else
            # take whichever side is set.
            return :(s2.$(name) === nothing ? s1.$(name) :
                     (s1.$(name) === nothing ? s2.$(name) :
                      _merge_structs(s1.$(name), s2.$(name))))
        end
    else
        # Bare submessage (proto2 required): always recurse.
        return :(_merge_structs(s1.$(name), s2.$(name)))
    end
end

# Default-value detection for proto3 bare scalars and enums. Used by the
# merge to decide whether `s2`'s value was on the wire or just the type's
# zero-value.
@inline _at_default(x::Number)            = iszero(x)
@inline _at_default(x::AbstractString)    = isempty(x)
@inline _at_default(x::AbstractVector)    = isempty(x)
@inline _at_default(x::Base.Enum)         = Integer(x) == 0

# OneOf-vs-OneOf is defined in the parent module (it depends on the
# `OneOf` type, which lives there). The presence-wrapper case
# (`Union{Nothing,OneOf{...}}`) is handled inline by
# `_merge_field_expr` above, which only calls `_merge_structs` when
# both sides are concrete OneOfs.

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
        # `read(io, UInt8)` errors on EOF mid-byte, which is the right
        # behavior for a truncated varint.
        while read(io, UInt8) >= 0x80 end
    elseif wire_type == FIXED64
        bytesavailable(io) >= 8 || throw(EOFError())
        skip(io, 8)
    elseif wire_type == LENGTH_DELIMITED
        bytelen = vbyte_decode(io, UInt32)
        bytesavailable(io) >= bytelen ||
            throw(EOFError())
        skip(io, bytelen)
    elseif wire_type == START_GROUP
        while peek(io) != UInt8(END_GROUP)
            skip(d, decode_tag(d)[2])
        end
        skip(io, 1)
    elseif wire_type == FIXED32
        bytesavailable(io) >= 4 || throw(EOFError())
        skip(io, 4)
    else wire_type == END_GROUP
        error("Encountered END_GROUP wiretype while skipping")
    end
    return nothing
end

# Append a varint to a Vector{UInt8} (no IO wrapping). Used by
# `_skip_and_capture!` to re-encode the (already-decoded) tag and any
# nested length prefix into the unknown-fields buffer.
@inline function _append_varint!(buf::Vector{UInt8}, x::Unsigned)
    while x >= 0x80
        push!(buf, UInt8((x & 0x7f) | 0x80))
        x >>= 7
    end
    push!(buf, UInt8(x))
    return nothing
end

# `Base.skip` consumes an unknown field's value bytes and discards them.
# `_skip_and_capture!` mirrors that walk but appends the tag plus the
# value bytes to `buf` so the caller can replay them verbatim later.
# Used by the codegen-emitted decode body to populate
# `_unknown_fields` for later re-emission.
function _skip_and_capture!(buf::Vector{UInt8}, d::AbstractProtoDecoder,
                            field_number::Integer, wire_type::WireType)
    io = get_stream(d)
    # Re-encode the tag we already decoded.
    _append_varint!(buf, (UInt32(field_number) << 3) | UInt32(wire_type))
    if wire_type == VARINT
        while true
            b = read(io, UInt8)
            push!(buf, b)
            b < 0x80 && break
        end
    elseif wire_type == FIXED64
        bytesavailable(io) >= 8 || throw(EOFError())
        append!(buf, read(io, 8))
    elseif wire_type == FIXED32
        bytesavailable(io) >= 4 || throw(EOFError())
        append!(buf, read(io, 4))
    elseif wire_type == LENGTH_DELIMITED
        bytelen = vbyte_decode(io, UInt32)
        _append_varint!(buf, bytelen)
        bytesavailable(io) >= bytelen || throw(EOFError())
        append!(buf, read(io, bytelen))
    elseif wire_type == START_GROUP
        # Groups are deprecated but spec-correct unknown-field
        # retention should still preserve them. Recurse into the
        # group, capturing each inner tag and the matching END_GROUP.
        while peek(io) != UInt8(END_GROUP)
            inner_field, inner_wire = decode_tag(d)
            _skip_and_capture!(buf, d, inner_field, inner_wire)
        end
        push!(buf, read(io, UInt8))  # END_GROUP byte
    else
        error("Encountered END_GROUP wiretype while capturing unknown field")
    end
    return nothing
end
