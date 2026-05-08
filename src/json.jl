# Protocol Buffers JSON mapping — encoder and decoder.
#
# Implements the wire format described at
#   https://protobuf.dev/programming-guides/json/
# via a reflection-driven walker over our existing metadata methods
# (`field_numbers`, `oneof_field_types`, `default_values`) plus the
# codegen-emitted `json_field_names`.
#
# Phase 12a covers: scalars (including int64/uint64 → JSON string and
# bytes → base64 string), float NaN/±Infinity → JSON string, nested
# messages, repeated, enums as canonical name strings (parsed from
# either string or integer), and proto3-style omit-defaults on encode.
# Maps, oneof parent-flattening, and the `ignore_unknown_fields` flag
# land in Phase 12b. WKT special forms (Timestamp, Duration, Any, …)
# land in Phase 12c.

import JSON

# -----------------------------------------------------------------------------
# Inline base64 — bytes <-> string. (Avoids declaring the Base64 stdlib as a
# dep; the protobuf-JSON spec only needs encode/decode of arbitrary byte
# strings, so a few dozen lines of pure-Julia code are enough.)
# -----------------------------------------------------------------------------

const _B64_ALPHABET = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

# Reverse map: ASCII byte → 0..63, or 0xff for invalid / padding.
const _B64_DECODE = let t = fill(0xff, 256)
    for (i, c) in enumerate(_B64_ALPHABET)
        t[Int(c) + 1] = UInt8(i - 1)
    end
    t
end

function _base64_encode(bytes::AbstractVector{UInt8})
    n = length(bytes)
    out = Vector{UInt8}(undef, 4 * cld(n, 3))
    i = 1; o = 1
    @inbounds while i + 2 <= n
        b1, b2, b3 = bytes[i], bytes[i + 1], bytes[i + 2]
        out[o]     = _B64_ALPHABET[(b1 >> 2) + 1]
        out[o + 1] = _B64_ALPHABET[(((b1 & 0x03) << 4) | (b2 >> 4)) + 1]
        out[o + 2] = _B64_ALPHABET[(((b2 & 0x0f) << 2) | (b3 >> 6)) + 1]
        out[o + 3] = _B64_ALPHABET[(b3 & 0x3f) + 1]
        i += 3; o += 4
    end
    rem = n - i + 1
    @inbounds if rem == 1
        b1 = bytes[i]
        out[o]     = _B64_ALPHABET[(b1 >> 2) + 1]
        out[o + 1] = _B64_ALPHABET[((b1 & 0x03) << 4) + 1]
        out[o + 2] = UInt8('=')
        out[o + 3] = UInt8('=')
    elseif rem == 2
        b1, b2 = bytes[i], bytes[i + 1]
        out[o]     = _B64_ALPHABET[(b1 >> 2) + 1]
        out[o + 1] = _B64_ALPHABET[(((b1 & 0x03) << 4) | (b2 >> 4)) + 1]
        out[o + 2] = _B64_ALPHABET[((b2 & 0x0f) << 2) + 1]
        out[o + 3] = UInt8('=')
    end
    return String(out)
end

function _base64_decode(s::AbstractString)
    bytes = codeunits(s)
    # Skip trailing '=' padding when computing length; reject padding inside.
    n = length(bytes)
    while n > 0 && bytes[n] == UInt8('=')
        n -= 1
    end
    rem = n & 0x3
    rem == 1 && throw(ArgumentError("invalid base64 length"))
    out_len = 3 * (n >> 2) + (rem == 0 ? 0 : rem == 2 ? 1 : 2)
    out = Vector{UInt8}(undef, out_len)
    i = 1; o = 1
    @inbounds while i + 3 <= n
        v1 = _B64_DECODE[Int(bytes[i])     + 1]
        v2 = _B64_DECODE[Int(bytes[i + 1]) + 1]
        v3 = _B64_DECODE[Int(bytes[i + 2]) + 1]
        v4 = _B64_DECODE[Int(bytes[i + 3]) + 1]
        (v1 | v2 | v3 | v4) == 0xff && throw(ArgumentError("invalid base64 character"))
        out[o]     = (v1 << 2) | (v2 >> 4)
        out[o + 1] = ((v2 & 0x0f) << 4) | (v3 >> 2)
        out[o + 2] = ((v3 & 0x03) << 6) | v4
        i += 4; o += 3
    end
    @inbounds if rem == 2
        v1 = _B64_DECODE[Int(bytes[i])     + 1]
        v2 = _B64_DECODE[Int(bytes[i + 1]) + 1]
        (v1 | v2) == 0xff && throw(ArgumentError("invalid base64 character"))
        out[o] = (v1 << 2) | (v2 >> 4)
    elseif rem == 3
        v1 = _B64_DECODE[Int(bytes[i])     + 1]
        v2 = _B64_DECODE[Int(bytes[i + 1]) + 1]
        v3 = _B64_DECODE[Int(bytes[i + 2]) + 1]
        (v1 | v2 | v3) == 0xff && throw(ArgumentError("invalid base64 character"))
        out[o]     = (v1 << 2) | (v2 >> 4)
        out[o + 1] = ((v2 & 0x0f) << 4) | (v3 >> 2)
    end
    return out
end

# -----------------------------------------------------------------------------
# Public API
# -----------------------------------------------------------------------------

"""
    encode_json([io,] msg) -> Union{Nothing,String}

Serialize `msg` to its protobuf-JSON representation. With an `IO`
argument, writes to it and returns `nothing`; without one, returns a
`String`.
"""
function encode_json(io::IO, msg::AbstractProtoBufMessage)
    _encode_json_message(io, msg)
    return nothing
end

function encode_json(msg::AbstractProtoBufMessage)
    io = IOBuffer()
    encode_json(io, msg)
    return String(take!(io))
end

"""
    decode_json(::Type{T}, source) -> T

Parse a protobuf-JSON document into a `T <: AbstractProtoBufMessage`.
`source` may be an `AbstractString`, an `IO`, or an already-parsed
JSON value (a `Dict{String,Any}` produced by `JSON.parse`).
"""
function decode_json(::Type{T}, src::AbstractString) where {T<:AbstractProtoBufMessage}
    return decode_json(T, JSON.parse(src))
end

function decode_json(::Type{T}, src::IO) where {T<:AbstractProtoBufMessage}
    return decode_json(T, JSON.parse(src))
end

function decode_json(::Type{T}, json::AbstractDict) where {T<:AbstractProtoBufMessage}
    return _decode_json_message(T, json)
end

# -----------------------------------------------------------------------------
# Encode side — message walker
# -----------------------------------------------------------------------------

function _encode_json_message(io::IO, msg::T) where {T<:AbstractProtoBufMessage}
    keys = json_field_names(T)
    print(io, '{')
    first = true
    for jl_name in fieldnames(T)
        v = getfield(msg, jl_name)
        # `nothing` always means "field not set" (presence-bearing fields
        # default to `nothing`, plain proto3 scalars never get `nothing`).
        v === nothing && continue
        # proto3 emits non-default-valued fields only by default.
        _is_json_default(v) && continue
        json_key = getproperty(keys, jl_name)
        first || print(io, ',')
        first = false
        JSON.print(io, json_key)
        print(io, ':')
        _encode_json_value(io, v)
    end
    print(io, '}')
    return nothing
end

# Skip-on-default predicate. Mirrors protoc's default emission policy:
# scalar zero / empty string / empty bytes / empty repeated all skipped.
# Submessages: `nothing` is already filtered above, so any concrete
# struct value here is non-default — emit it.
function _is_json_default(v::Bool)
    return v == false
end
function _is_json_default(v::Number)
    return v == 0
end
function _is_json_default(v::AbstractString)
    return isempty(v)
end
function _is_json_default(v::AbstractVector)
    return isempty(v)
end
function _is_json_default(v::AbstractDict)
    return isempty(v)
end
function _is_json_default(v)
    return false
end

# -----------------------------------------------------------------------------
# Encode side — value dispatch
# -----------------------------------------------------------------------------

function _encode_json_value(io::IO, v::Bool)
    print(io, v ? "true" : "false")
    return nothing
end

# 32-bit integers (and smaller) → JSON number.
function _encode_json_value(io::IO, v::Union{Int8,Int16,Int32,UInt8,UInt16,UInt32})
    print(io, v)
    return nothing
end

# 64-bit integers → JSON string. JS numbers can't represent the full
# int64/uint64 range, so the spec mandates string form.
function _encode_json_value(io::IO, v::Union{Int64,UInt64})
    print(io, '"', v, '"')
    return nothing
end

function _encode_json_value(io::IO, v::AbstractFloat)
    if isnan(v)
        print(io, "\"NaN\"")
    elseif !isfinite(v)
        print(io, v > 0 ? "\"Infinity\"" : "\"-Infinity\"")
    else
        # Julia's default print for finite Float32/64 produces a decimal
        # form that JSON parses back to the same value (e.g., "3.14",
        # "1.0e-10"). Avoid `print_shortest` here — it can emit "1." or
        # "1.f0" which aren't valid JSON.
        if v isa Float32
            # widen to double for printing so we don't drop precision
            print(io, Float64(v))
        else
            print(io, v)
        end
    end
    return nothing
end

function _encode_json_value(io::IO, s::AbstractString)
    JSON.print(io, s)
    return nothing
end

# bytes → base64 JSON string.
function _encode_json_value(io::IO, b::Vector{UInt8})
    print(io, '"', _base64_encode(b), '"')
    return nothing
end

# Enums: emit the canonical declared name. With EnumX, `Symbol(v)`
# returns the canonical-form name even for aliases (Phase 9
# `allow_alias` design).
function _encode_json_value(io::IO, v::Base.Enum)
    print(io, '"', String(Symbol(v)), '"')
    return nothing
end

# Repeated.
function _encode_json_value(io::IO, v::AbstractVector)
    print(io, '[')
    first = true
    for elt in v
        first || print(io, ',')
        first = false
        _encode_json_value(io, elt)
    end
    print(io, ']')
    return nothing
end

# Nested submessage.
function _encode_json_value(io::IO, v::AbstractProtoBufMessage)
    _encode_json_message(io, v)
    return nothing
end

# -----------------------------------------------------------------------------
# Decode side — message walker
# -----------------------------------------------------------------------------

function _decode_json_message(::Type{T}, json::AbstractDict) where {T<:AbstractProtoBufMessage}
    keys = json_field_names(T)
    # Build a JSON-key → Julia-field-name map. Per spec, parsers must
    # accept both the camelCase (`json_name`) form and the original
    # snake_case form on input; emit only camelCase on output.
    json_to_jl = Dict{String,Symbol}()
    for jl_name in propertynames(keys)
        json_to_jl[getproperty(keys, jl_name)] = jl_name
        json_to_jl[String(jl_name)] = jl_name
    end

    defaults = default_values(T)
    vals = Dict{Symbol,Any}()
    for k in propertynames(defaults)
        vals[k] = getproperty(defaults, k)
    end

    for (json_key, json_val) in json
        # Per spec, JSON `null` for a singular field means "use default";
        # we already populated `vals` from defaults.
        json_val === nothing && continue

        jl_name = get(json_to_jl, json_key, nothing)
        if jl_name === nothing
            # Phase 12b: respect `ignore_unknown_fields`; for now skip.
            continue
        end

        # Presence-bearing fields are typed `Union{Nothing,X}`. JSON
        # `null` was already filtered above, so for the actual decode we
        # only care about the non-`Nothing` half.
        FT = Base.nonnothingtype(fieldtype(T, jl_name))
        vals[jl_name] = _decode_json_value(FT, json_val)
    end

    args = ntuple(i -> vals[fieldname(T, i)], fieldcount(T))
    return T(args...)
end

# -----------------------------------------------------------------------------
# Decode side — value dispatch
# -----------------------------------------------------------------------------

function _decode_json_value(::Type{Bool}, v::Bool)
    return v
end

# Smaller integers. Accept either JSON number or numeric string.
function _decode_json_value(::Type{T}, v::Real) where {T<:Union{Int8,Int16,Int32,UInt8,UInt16,UInt32}}
    return T(v)
end
function _decode_json_value(::Type{T}, v::AbstractString) where {T<:Union{Int8,Int16,Int32,UInt8,UInt16,UInt32}}
    return parse(T, v)
end

# 64-bit integers — accept string (canonical) or number.
function _decode_json_value(::Type{T}, v::AbstractString) where {T<:Union{Int64,UInt64}}
    return parse(T, v)
end
function _decode_json_value(::Type{T}, v::Real) where {T<:Union{Int64,UInt64}}
    return T(v)
end

function _decode_json_value(::Type{T}, v::AbstractString) where {T<:AbstractFloat}
    if v == "NaN"
        return T(NaN)
    elseif v == "Infinity"
        return T(Inf)
    elseif v == "-Infinity"
        return T(-Inf)
    else
        return parse(T, v)
    end
end
function _decode_json_value(::Type{T}, v::Real) where {T<:AbstractFloat}
    return T(v)
end

function _decode_json_value(::Type{String}, v::AbstractString)
    return String(v)
end

# bytes — base64-decode.
function _decode_json_value(::Type{Vector{UInt8}}, v::AbstractString)
    return _base64_decode(v)
end

# Enums: accept canonical name (string) or numeric value.
function _decode_json_value(::Type{E}, v::AbstractString) where {E<:Base.Enum}
    return getfield(parentmodule(E), Symbol(v))::E
end
function _decode_json_value(::Type{E}, v::Real) where {E<:Base.Enum}
    return E(v)
end

# Repeated.
function _decode_json_value(::Type{Vector{T}}, v::AbstractVector) where {T}
    out = Vector{T}(undef, length(v))
    @inbounds for i in eachindex(v)
        out[i] = _decode_json_value(T, v[i])
    end
    return out
end

# Nested submessage.
function _decode_json_value(::Type{T}, v::AbstractDict) where {T<:AbstractProtoBufMessage}
    return _decode_json_message(T, v)
end
