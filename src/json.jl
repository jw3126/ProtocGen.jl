# Protocol Buffers JSON mapping — encoder and decoder.
#
# Implements the wire format described at
#   https://protobuf.dev/programming-guides/json/
# via a reflection-driven walker over our existing metadata methods
# (`field_numbers`, `oneof_field_types`, `default_values`) plus the
# codegen-emitted `json_field_names`.
#
# Phase 12a covered: scalars (including int64/uint64 → JSON string and
# bytes → base64 string), float NaN/±Infinity → JSON string, nested
# messages, repeated, enums as canonical name strings (parsed from
# either string or integer), and proto3-style omit-defaults on encode.
# Phase 12b layered on: oneof active-member parent flattening, maps
# (with stringified keys per spec), and the `ignore_unknown_fields`
# parse option (default off — strict). WKT special forms (Timestamp,
# Duration, Any, …) land in Phase 12c.

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
    decode_json(::Type{T}, source; ignore_unknown_fields = false) -> T

Parse a protobuf-JSON document into a `T <: AbstractProtoBufMessage`.
`source` may be an `AbstractString`, an `IO`, or an already-parsed
JSON value (a `Dict{String,Any}` produced by `JSON.parse`).

By default a JSON key that doesn't map to any field of `T` (or any
nested message type) raises `ArgumentError`, matching the spec's
strict default. Pass `ignore_unknown_fields = true` to silently drop
them (this is what conformance JSON_IGNORE_UNKNOWN_PARSING_TEST asks
for).
"""
function decode_json(::Type{T}, src::AbstractString;
                     ignore_unknown_fields::Bool = false) where {T<:AbstractProtoBufMessage}
    return decode_json(T, JSON.parse(src); ignore_unknown_fields)
end

function decode_json(::Type{T}, src::IO;
                     ignore_unknown_fields::Bool = false) where {T<:AbstractProtoBufMessage}
    return decode_json(T, JSON.parse(src); ignore_unknown_fields)
end

function decode_json(::Type{T}, json::AbstractDict;
                     ignore_unknown_fields::Bool = false) where {T<:AbstractProtoBufMessage}
    return _decode_json_message(T, json; ignore_unknown_fields)
end

# -----------------------------------------------------------------------------
# Encode side — message walker
# -----------------------------------------------------------------------------

function _encode_json_message(io::IO, msg::T) where {T<:AbstractProtoBufMessage}
    keys   = json_field_names(T)
    oneofs = oneof_field_types(T)
    print(io, '{')
    first = true
    for jl_name in fieldnames(T)
        v = getfield(msg, jl_name)
        # `nothing` always means "field not set" (presence-bearing fields
        # default to `nothing`, plain proto3 scalars never get `nothing`).
        v === nothing && continue
        # Real (non-synthetic) oneofs: collapse into the parent JSON
        # object — emit ONLY the active member at the parent level. The
        # JSON has no key corresponding to the oneof field itself.
        if hasproperty(oneofs, jl_name)
            o = v::OneOf
            json_key = getproperty(keys, o.name)
            first || print(io, ',')
            first = false
            JSON.print(io, json_key)
            print(io, ':')
            _encode_json_value(io, o.value)
            continue
        end
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

# Map. Per spec, map keys are stringified regardless of underlying type
# (bool → "true"/"false", any integer → decimal). Values use the regular
# value dispatch.
function _encode_json_value(io::IO, d::AbstractDict)
    print(io, '{')
    first = true
    for (k, v) in d
        first || print(io, ',')
        first = false
        _emit_map_key(io, k)
        print(io, ':')
        _encode_json_value(io, v)
    end
    print(io, '}')
    return nothing
end

function _emit_map_key(io::IO, k::Bool)
    print(io, k ? "\"true\"" : "\"false\"")
    return nothing
end
function _emit_map_key(io::IO, k::Integer)
    print(io, '"', k, '"')
    return nothing
end
function _emit_map_key(io::IO, k::AbstractString)
    JSON.print(io, k)  # writes the quoted, escaped form
    return nothing
end

# -----------------------------------------------------------------------------
# Decode side — message walker
# -----------------------------------------------------------------------------

function _decode_json_message(::Type{T}, json::AbstractDict;
                              ignore_unknown_fields::Bool = false) where {T<:AbstractProtoBufMessage}
    keys   = json_field_names(T)
    oneofs = oneof_field_types(T)

    # Build a JSON-key → Julia-field-name map. Per spec, parsers must
    # accept both the camelCase (`json_name`) form and the original
    # snake_case form on input; emit only camelCase on output.
    json_to_jl = Dict{String,Symbol}()
    for jl_name in propertynames(keys)
        json_to_jl[getproperty(keys, jl_name)] = jl_name
        json_to_jl[String(jl_name)] = jl_name
    end

    # Inverse oneof lookup: member-julia-name → (parent-julia-name, member-type).
    # `keys` already exposes member names at the top level — when a JSON
    # key resolves to a member we need to redirect the decoded value to
    # the parent oneof field, wrapped in `OneOf`.
    oneof_member_lookup = Dict{Symbol,Tuple{Symbol,Type}}()
    for parent in propertynames(oneofs)
        members = getproperty(oneofs, parent)
        for m in propertynames(members)
            oneof_member_lookup[m] = (parent, getproperty(members, m))
        end
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
            ignore_unknown_fields && continue
            throw(ArgumentError(
                "unknown field \"$(json_key)\" while decoding $(T); " *
                "set `ignore_unknown_fields = true` to skip"))
        end

        member = get(oneof_member_lookup, jl_name, nothing)
        if member !== nothing
            (parent_name, member_type) = member
            # Decoding an active oneof member: wrap in `OneOf` and
            # store at the parent field. The parent field type uses a
            # covariant `OneOf{<:Union{…}}` bound, so `OneOf{ConcreteT}`
            # is assignable.
            decoded = _decode_json_value(member_type, json_val;
                                         ignore_unknown_fields = ignore_unknown_fields)
            vals[parent_name] = OneOf(jl_name, decoded)
        else
            # Plain field. Strip the presence wrapper; JSON `null` was
            # already filtered above.
            FT = Base.nonnothingtype(fieldtype(T, jl_name))
            vals[jl_name] = _decode_json_value(FT, json_val;
                                               ignore_unknown_fields = ignore_unknown_fields)
        end
    end

    args = ntuple(i -> vals[fieldname(T, i)], fieldcount(T))
    return T(args...)
end

# -----------------------------------------------------------------------------
# Decode side — value dispatch
# -----------------------------------------------------------------------------

# All `_decode_json_value` methods accept a uniform `kw...` so the
# `ignore_unknown_fields` flag (currently the only thing that flows
# through) can recurse cleanly. Leaf methods just discard it.

function _decode_json_value(::Type{Bool}, v::Bool; kw...)
    return v
end

# Smaller integers. Accept either JSON number or numeric string.
function _decode_json_value(::Type{T}, v::Real; kw...) where {T<:Union{Int8,Int16,Int32,UInt8,UInt16,UInt32}}
    return T(v)
end
function _decode_json_value(::Type{T}, v::AbstractString; kw...) where {T<:Union{Int8,Int16,Int32,UInt8,UInt16,UInt32}}
    return parse(T, v)
end

# 64-bit integers — accept string (canonical) or number.
function _decode_json_value(::Type{T}, v::AbstractString; kw...) where {T<:Union{Int64,UInt64}}
    return parse(T, v)
end
function _decode_json_value(::Type{T}, v::Real; kw...) where {T<:Union{Int64,UInt64}}
    return T(v)
end

function _decode_json_value(::Type{T}, v::AbstractString; kw...) where {T<:AbstractFloat}
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
function _decode_json_value(::Type{T}, v::Real; kw...) where {T<:AbstractFloat}
    return T(v)
end

function _decode_json_value(::Type{String}, v::AbstractString; kw...)
    return String(v)
end

# bytes — base64-decode.
function _decode_json_value(::Type{Vector{UInt8}}, v::AbstractString; kw...)
    return _base64_decode(v)
end

# Enums: accept canonical name (string) or numeric value.
function _decode_json_value(::Type{E}, v::AbstractString; kw...) where {E<:Base.Enum}
    return getfield(parentmodule(E), Symbol(v))::E
end
function _decode_json_value(::Type{E}, v::Real; kw...) where {E<:Base.Enum}
    return E(v)
end

# Repeated.
function _decode_json_value(::Type{Vector{T}}, v::AbstractVector; kw...) where {T}
    out = Vector{T}(undef, length(v))
    @inbounds for i in eachindex(v)
        out[i] = _decode_json_value(T, v[i]; kw...)
    end
    return out
end

# Nested submessage.
function _decode_json_value(::Type{T}, v::AbstractDict; kw...) where {T<:AbstractProtoBufMessage}
    return _decode_json_message(T, v; kw...)
end

# Map. The Julia field type is `OrderedDict{K,V}` (codegen default) but
# we accept any `AbstractDict{K,V}`. Per spec, all map keys arrive as
# JSON strings — re-parse into `K` here.
function _decode_json_value(::Type{D}, v::AbstractDict; kw...) where {K,V,D<:AbstractDict{K,V}}
    out = D()
    for (jk, jv) in v
        out[_decode_map_key(K, jk)] = _decode_json_value(V, jv; kw...)
    end
    return out
end

function _decode_map_key(::Type{Bool}, s::AbstractString)
    s == "true"  && return true
    s == "false" && return false
    throw(ArgumentError("invalid bool map key: $(repr(s))"))
end
function _decode_map_key(::Type{T}, s::AbstractString) where {T<:Integer}
    return parse(T, s)
end
function _decode_map_key(::Type{String}, s::AbstractString)
    return String(s)
end
