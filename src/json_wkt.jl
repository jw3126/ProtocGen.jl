# JSON special forms for the well-known types.
#
# Each WKT type has its own canonical JSON representation that bypasses
# the generic walker. Methods here override `_encode_json_value` /
# `_decode_json_value` (and a few `_encode_json_message` /
# `_decode_json_message` overloads for top-level usage). Loading order:
# this file is `include`d *after* `gen/google/google.jl` so the WKT
# types are in scope.
#
# Spec reference:
#   https://protobuf.dev/programming-guides/json/#json-options-1

import Dates

const _G = google.protobuf
const _Empty = _G.Empty
const _Timestamp = _G.Timestamp
const _Duration = _G.Duration
const _FieldMask = _G.FieldMask
const _NullValue = _G.NullValue
const _Struct = _G.Struct
const _Value = _G.Value
const _ListValue = _G.ListValue
const _Any_ = _G.var"Any"   # `Any` is a Core type; the WKT shadows it inside _G

# All 9 wrapper types.
const _BoolValue = _G.BoolValue
const _BytesValue = _G.BytesValue
const _DoubleValue = _G.DoubleValue
const _FloatValue = _G.FloatValue
const _Int32Value = _G.Int32Value
const _Int64Value = _G.Int64Value
const _StringValue = _G.StringValue
const _UInt32Value = _G.UInt32Value
const _UInt64Value = _G.UInt64Value

# -----------------------------------------------------------------------------
# Wrappers — emit/parse just the wrapped scalar (no `{"value": …}` envelope).
# -----------------------------------------------------------------------------

# Encode side: each wrapper passes through to its wrapped value.
function _encode_json_value(io::IO, v::_BoolValue; kw...)
    _encode_json_value(io, v.value; kw...)
end
function _encode_json_value(io::IO, v::_BytesValue; kw...)
    _encode_json_value(io, v.value; kw...)
end
function _encode_json_value(io::IO, v::_DoubleValue; kw...)
    _encode_json_value(io, v.value; kw...)
end
function _encode_json_value(io::IO, v::_FloatValue; kw...)
    _encode_json_value(io, v.value; kw...)
end
function _encode_json_value(io::IO, v::_Int32Value; kw...)
    _encode_json_value(io, v.value; kw...)
end
function _encode_json_value(io::IO, v::_Int64Value; kw...)
    _encode_json_value(io, v.value; kw...)
end
function _encode_json_value(io::IO, v::_StringValue; kw...)
    _encode_json_value(io, v.value; kw...)
end
function _encode_json_value(io::IO, v::_UInt32Value; kw...)
    _encode_json_value(io, v.value; kw...)
end
function _encode_json_value(io::IO, v::_UInt64Value; kw...)
    _encode_json_value(io, v.value; kw...)
end

# Decode side: the JSON value is a scalar (or scalar-string), reconstruct
# the wrapper. Typing each method against `Real` / `AbstractString` /
# `Bool` keeps these specific enough to avoid ambiguity with the generic
# `_decode_json_value(::Type{T}, ::AbstractDict)` for messages — Dict
# input falls to the message walker (which accepts the
# `{"value": …}` envelope as a friendly fallback).
function _decode_json_value(::Type{_BoolValue}, v::Bool; kw...)
    return _BoolValue(v, UInt8[])
end
function _decode_json_value(::Type{_StringValue}, v::AbstractString; kw...)
    return _StringValue(String(v), UInt8[])
end
function _decode_json_value(::Type{_BytesValue}, v::AbstractString; kw...)
    return _BytesValue(Base64.base64decode(v), UInt8[])
end
function _decode_json_value(::Type{_DoubleValue}, v::Real; kw...)
    return _DoubleValue(Float64(v), UInt8[])
end
function _decode_json_value(::Type{_DoubleValue}, v::AbstractString; kw...)
    return _DoubleValue(_decode_json_value(Float64, v; kw...), UInt8[])
end
function _decode_json_value(::Type{_FloatValue}, v::Real; kw...)
    return _FloatValue(Float32(v), UInt8[])
end
function _decode_json_value(::Type{_FloatValue}, v::AbstractString; kw...)
    return _FloatValue(_decode_json_value(Float32, v; kw...), UInt8[])
end
function _decode_json_value(::Type{_Int32Value}, v::Real; kw...)
    return _Int32Value(Int32(v), UInt8[])
end
function _decode_json_value(::Type{_Int32Value}, v::AbstractString; kw...)
    return _Int32Value(parse(Int32, v), UInt8[])
end
function _decode_json_value(::Type{_Int64Value}, v::Real; kw...)
    return _Int64Value(Int64(v), UInt8[])
end
function _decode_json_value(::Type{_Int64Value}, v::AbstractString; kw...)
    return _Int64Value(parse(Int64, v), UInt8[])
end
function _decode_json_value(::Type{_UInt32Value}, v::Real; kw...)
    return _UInt32Value(UInt32(v), UInt8[])
end
function _decode_json_value(::Type{_UInt32Value}, v::AbstractString; kw...)
    return _UInt32Value(parse(UInt32, v), UInt8[])
end
function _decode_json_value(::Type{_UInt64Value}, v::Real; kw...)
    return _UInt64Value(UInt64(v), UInt8[])
end
function _decode_json_value(::Type{_UInt64Value}, v::AbstractString; kw...)
    return _UInt64Value(parse(UInt64, v), UInt8[])
end

# -----------------------------------------------------------------------------
# Empty — `{}`. Generic walker already produces this on encode (no fields)
# and the AbstractDict decode path constructs an empty struct, so no
# overrides needed here. Documented for completeness.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Timestamp — RFC 3339 string in UTC, e.g. "2024-05-08T15:30:00.123456789Z".
# Fractional precision is 0/3/6/9 digits depending on trailing zeros.
# Spec range: 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z
# (i.e., seconds ∈ [-62135596800, 253402300799]).
# -----------------------------------------------------------------------------

const _TIMESTAMP_MIN_SECONDS = Int64(-62135596800)   # 0001-01-01T00:00:00Z
const _TIMESTAMP_MAX_SECONDS = Int64(253402300799)   # 9999-12-31T23:59:59Z

function _encode_json_value(io::IO, ts::_Timestamp; kw...)
    if ts.seconds < _TIMESTAMP_MIN_SECONDS || ts.seconds > _TIMESTAMP_MAX_SECONDS
        throw(
            ArgumentError(
                "Timestamp seconds out of range [$(Int(_TIMESTAMP_MIN_SECONDS)), $(Int(_TIMESTAMP_MAX_SECONDS))]: $(ts.seconds)",
            ),
        )
    end
    print(io, '"')
    _format_rfc3339(io, ts.seconds, ts.nanos)
    print(io, '"')
    return nothing
end

function _decode_json_value(::Type{_Timestamp}, s::AbstractString; kw...)
    seconds, nanos = _parse_rfc3339(s)
    if seconds < _TIMESTAMP_MIN_SECONDS || seconds > _TIMESTAMP_MAX_SECONDS
        throw(ArgumentError("Timestamp out of range: $(repr(s))"))
    end
    return _Timestamp(seconds, nanos, UInt8[])
end

function _format_rfc3339(io::IO, seconds::Integer, nanos::Integer)
    # Convert seconds-since-Unix-epoch + nanos to a UTC datetime.
    dt = Dates.unix2datetime(seconds)
    print(io, Dates.format(dt, Dates.dateformat"yyyy-mm-dd\THH:MM:SS"))
    if nanos != 0
        # Pick the shortest of 3 / 6 / 9 digit fractional that's lossless.
        n9 = lpad(string(nanos), 9, '0')
        if endswith(n9, "000000")
            print(io, '.', view(n9, 1:3))
        elseif endswith(n9, "000")
            print(io, '.', view(n9, 1:6))
        else
            print(io, '.', n9)
        end
    end
    print(io, 'Z')
    return nothing
end

function _parse_rfc3339(s::AbstractString)
    # Accept "<date>T<time>[.fractional][Z|±hh:mm]". Reject lower-case 't'/'z'.
    m = match(
        r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d{1,9})?(Z|[+\-]\d{2}:\d{2})$",
        s,
    )
    m === nothing && throw(ArgumentError("invalid RFC 3339 timestamp: $(repr(s))"))
    yr, mo, da, hh, mm, ss = parse.(Int, (m[1], m[2], m[3], m[4], m[5], m[6]))
    frac = m[7]
    nanos = if frac === nothing
        0
    else
        # `.\d{1,9}` — pad to 9 digits with trailing zeros.
        digits = frac[2:end]
        parse(Int, rpad(digits, 9, '0'))
    end
    tz = m[8]
    dt = Dates.DateTime(yr, mo, da, hh, mm, ss)
    seconds = Int64(Dates.datetime2unix(dt))
    if tz != "Z"
        sign = tz[1] == '+' ? -1 : 1   # offset → subtract to get UTC
        ohh = parse(Int, tz[2:3])
        omm = parse(Int, tz[5:6])
        seconds += sign * (ohh * 3600 + omm * 60)
    end
    return Int64(seconds), Int32(nanos)
end

# -----------------------------------------------------------------------------
# Duration — string ending in 's', e.g. "1.5s", "-12s", "3.000000001s".
# Spec range: ±10000 years, i.e. seconds ∈ [-315576000000, 315576000000].
# -----------------------------------------------------------------------------

const _DURATION_MAX_SECONDS = Int64(315576000000)

function _encode_json_value(io::IO, d::_Duration; kw...)
    if d.seconds > _DURATION_MAX_SECONDS || d.seconds < -_DURATION_MAX_SECONDS
        throw(
            ArgumentError(
                "Duration seconds out of range [-$(Int(_DURATION_MAX_SECONDS)), $(Int(_DURATION_MAX_SECONDS))]: $(d.seconds)",
            ),
        )
    end
    print(io, '"')
    s, n = d.seconds, d.nanos
    # Sign convention: seconds and nanos must agree on sign per spec.
    if s < 0 || n < 0
        print(io, '-')
        s = -s
        n = -n
    end
    print(io, s)
    if n != 0
        n9 = lpad(string(n), 9, '0')
        if endswith(n9, "000000")
            print(io, '.', view(n9, 1:3))
        elseif endswith(n9, "000")
            print(io, '.', view(n9, 1:6))
        else
            print(io, '.', n9)
        end
    end
    print(io, "s\"")
    return nothing
end

function _decode_json_value(::Type{_Duration}, s::AbstractString; kw...)
    m = match(r"^(-?)(\d+)(?:\.(\d{1,9}))?s$", s)
    m === nothing && throw(ArgumentError("invalid Duration string: $(repr(s))"))
    sign = m[1] == "-" ? -1 : 1
    seconds_abs = parse(Int64, m[2])
    if seconds_abs > _DURATION_MAX_SECONDS
        throw(ArgumentError("Duration out of range: $(repr(s))"))
    end
    seconds = sign * seconds_abs
    nanos = m[3] === nothing ? Int32(0) : Int32(sign * parse(Int, rpad(m[3], 9, '0')))
    return _Duration(seconds, nanos, UInt8[])
end

# -----------------------------------------------------------------------------
# FieldMask — single comma-separated string of camelCase paths.
# Wire form is repeated string of snake_case paths; the JSON form picks
# camelCase to match field-name conventions everywhere else. Conversion
# is lower_snake → lowerCamel within each path component.
# -----------------------------------------------------------------------------

function _encode_json_value(io::IO, fm::_FieldMask; kw...)
    print(io, '"')
    first = true
    for p in fm.paths
        first || print(io, ',')
        first = false
        _print_camel(io, p)
    end
    print(io, '"')
    return nothing
end

function _decode_json_value(::Type{_FieldMask}, s::AbstractString; kw...)
    isempty(s) && return _FieldMask(String[], UInt8[])
    paths = [_to_snake(String(p)) for p in split(s, ',')]
    return _FieldMask(paths, UInt8[])
end

# snake_case → camelCase per protoc's field-name conversion rule.
function _print_camel(io::IO, s::AbstractString)
    upper_next = false
    for c in s
        if c == '_'
            upper_next = true
        elseif upper_next
            print(io, uppercase(c))
            upper_next = false
        else
            print(io, c)
        end
    end
    return nothing
end

# camelCase → snake_case (only used on FieldMask parse).
function _to_snake(s::AbstractString)
    io = IOBuffer()
    for c in s
        if isuppercase(c)
            print(io, '_', lowercase(c))
        else
            print(io, c)
        end
    end
    return String(take!(io))
end

# -----------------------------------------------------------------------------
# Struct / Value / ListValue — passthrough JSON. The cycle abstract
# supertypes (AbstractStruct, AbstractValue, AbstractListValue) get
# forwarding methods that route to the concrete struct, mirroring the
# pattern codegen emits for the binary `decode` and the message-form
# `_decode_json_message`.
# -----------------------------------------------------------------------------

const _AbstractValue = _G.AbstractValue
const _AbstractStruct = _G.AbstractStruct
const _AbstractListValue = _G.AbstractListValue

# Value: emit whatever JSON value the active oneof member calls for.
function _encode_json_value(io::IO, v::_Value; kw...)
    if v.kind === nothing
        print(io, "null")
        return nothing
    end
    o = v.kind::OneOf
    if o.name === :null_value
        print(io, "null")
    else
        _encode_json_value(io, o.value; kw...)
    end
    return nothing
end

# Value decode: dispatch on the JSON value's runtime type.
function _decode_json_value(::Type{_Value}, ::Nothing; kw...)
    return _Value(OneOf(:null_value, _NullValue.NULL_VALUE), UInt8[])
end
function _decode_json_value(::Type{_Value}, v::Bool; kw...)
    return _Value(OneOf(:bool_value, v), UInt8[])
end
function _decode_json_value(::Type{_Value}, v::Real; kw...)
    return _Value(OneOf(:number_value, Float64(v)), UInt8[])
end
function _decode_json_value(::Type{_Value}, v::AbstractString; kw...)
    return _Value(OneOf(:string_value, String(v)), UInt8[])
end
function _decode_json_value(::Type{_Value}, v::AbstractDict; kw...)
    s = _decode_json_value(_Struct, v; kw...)
    return _Value(OneOf(:struct_value, s), UInt8[])
end
function _decode_json_value(::Type{_Value}, v::AbstractVector; kw...)
    lv = _decode_json_value(_ListValue, v; kw...)
    return _Value(OneOf(:list_value, lv), UInt8[])
end

# Struct: emit the fields dict as a bare JSON object.
function _encode_json_value(io::IO, s::_Struct; kw...)
    _encode_json_value(io, s.fields; kw...)
    return nothing
end

function _decode_json_value(::Type{_Struct}, v::AbstractDict; kw...)
    # The struct's field type is invariant `OrderedDict{String,AbstractValue}`
    # — entries land here as concrete `Value`, which is `<: AbstractValue`.
    fields = OrderedDict{String,_AbstractValue}()
    for (k, jv) in v
        fields[String(k)] = _decode_json_value(_Value, jv; kw...)
    end
    return _Struct(fields, UInt8[])
end

# ListValue: emit the values vector as a bare JSON array.
function _encode_json_value(io::IO, lv::_ListValue; kw...)
    _encode_json_value(io, lv.values; kw...)
    return nothing
end

function _decode_json_value(::Type{_ListValue}, v::AbstractVector; kw...)
    values = _AbstractValue[_decode_json_value(_Value, x; kw...) for x in v]
    return _ListValue(values, UInt8[])
end

# Cycle-abstract forwarding. Invariant `Type{X}` so calls dispatched on
# the concrete struct don't recurse back into the forwarding method.
# Each abstract gets a typed `::AbstractDict` overload to win against
# the generic `_decode_json_value(::Type{T<:AbstractProtoBufMessage}, ::AbstractDict)`.
function _decode_json_value(::Type{_AbstractValue}, v; kw...)
    return _decode_json_value(_Value, v; kw...)
end
function _decode_json_value(::Type{_AbstractValue}, v::AbstractDict; kw...)
    return _decode_json_value(_Value, v; kw...)
end
function _decode_json_value(::Type{_AbstractStruct}, v; kw...)
    return _decode_json_value(_Struct, v; kw...)
end
function _decode_json_value(::Type{_AbstractStruct}, v::AbstractDict; kw...)
    return _decode_json_value(_Struct, v; kw...)
end
function _decode_json_value(::Type{_AbstractListValue}, v; kw...)
    return _decode_json_value(_ListValue, v; kw...)
end
function _decode_json_value(::Type{_AbstractListValue}, v::AbstractDict; kw...)
    return _decode_json_value(_ListValue, v; kw...)
end

# -----------------------------------------------------------------------------
# Any — JSON form embeds the wrapped message together with a `@type`
# discriminator carrying the protobuf FQN. For WKTs that have a non-message
# scalar JSON form (Wrappers, Timestamp, Duration, FieldMask, Empty,
# Struct, Value, ListValue), the special form is wrapped under a
# `"value": <…>` field; for ordinary messages the fields are merged
# alongside `@type`.
#
#   Any wrapping a Foo message:
#       {"@type": "type.googleapis.com/<pkg>.Foo", "<fooField>": ..., ...}
#   Any wrapping a Timestamp:
#       {"@type": "type.googleapis.com/google.protobuf.Timestamp",
#        "value": "2024-…"}
#
# Encoding: parse `Any.type_url` → FQN → Julia type via the registry,
# decode `Any.value` bytes into that type using the binary codec, then
# emit JSON for the inner message and inject `@type`.
#
# Decoding: read `@type`, look up Julia type, decode the inner JSON form
# into a message, re-encode to bytes, store in Any.{type_url, value}.
# -----------------------------------------------------------------------------

# Set of WKT FQNs that take the `{"@type": ..., "value": …}` shape
# inside Any (i.e., their JSON form isn't a JSON object, or it IS an
# object but Any wraps it under `value` to disambiguate from message
# fields). Nested Any (Any wrapping Any) also uses this shape — the
# inner Any's own `@type` would otherwise collide with the outer.
const _WKT_VALUE_FORM = Set([
    "google.protobuf.Any",
    "google.protobuf.BoolValue",
    "google.protobuf.BytesValue",
    "google.protobuf.DoubleValue",
    "google.protobuf.FloatValue",
    "google.protobuf.Int32Value",
    "google.protobuf.Int64Value",
    "google.protobuf.StringValue",
    "google.protobuf.UInt32Value",
    "google.protobuf.UInt64Value",
    "google.protobuf.Timestamp",
    "google.protobuf.Duration",
    "google.protobuf.FieldMask",
    "google.protobuf.Struct",
    "google.protobuf.Value",
    "google.protobuf.ListValue",
])

function _any_extract_fqn(type_url::AbstractString)
    # Spec: "type.googleapis.com/<full.name>" (or any host before /).
    idx = findlast('/', type_url)
    idx === nothing && throw(ArgumentError("Any.type_url has no '/': $(repr(type_url))"))
    return String(type_url[idx+1:end])
end

function _encode_json_value(
    io::IO,
    a::_Any_;
    registry::Union{Nothing,AbstractDict} = nothing,
    kw...,
)
    fqn = _any_extract_fqn(a.type_url)
    T = lookup_message_type(fqn; registry = registry)
    T === nothing && throw(
        ArgumentError(
            """
            Any: no message type registered for $(repr(fqn)); load the proto module that defines it (or call ProtocGen.register_message_type, or pass a per-call `registry`).""",
        ),
    )
    # Decode the embedded binary payload into the concrete type.
    msg = decode(a.value, T)

    if fqn in _WKT_VALUE_FORM
        # `{"@type": ..., "value": <special>}`
        print(io, "{\"@type\":")
        JSON.print(io, a.type_url)
        print(io, ",\"value\":")
        _encode_json_value(io, msg; registry = registry, kw...)
        print(io, '}')
    else
        # Ordinary message: emit fields like a normal message but inject
        # `@type` first. We can't reuse the generic walker directly
        # because it always opens with `{` and writes its own field
        # entries — so call into a slimmed variant that *appends* fields
        # to an already-open object.
        print(io, "{\"@type\":")
        JSON.print(io, a.type_url)
        _encode_json_message_after_at_type(io, msg; registry = registry, kw...)
        print(io, '}')
    end
    return nothing
end

# Like `_encode_json_message` but assumes the caller has already written
# the opening `{` and an `@type` entry. Emits each field with a leading
# `,` (since `@type` already populated the object).
function _encode_json_message_after_at_type(
    io::IO,
    msg::T;
    kw...,
) where {T<:AbstractProtoBufMessage}
    keys = json_field_names(T)
    oneofs = oneof_field_types(T)
    for jl_name in fieldnames(T)
        jl_name === Symbol("#unknown_fields") && continue
        v = getfield(msg, jl_name)
        v === nothing && continue
        if hasproperty(oneofs, jl_name)
            o = v::OneOf
            json_key = getproperty(keys, o.name)
            print(io, ',')
            JSON.print(io, json_key)
            print(io, ':')
            _encode_json_value(io, o.value; kw...)
            continue
        end
        _is_json_default(v) && continue
        json_key = getproperty(keys, jl_name)
        print(io, ',')
        JSON.print(io, json_key)
        print(io, ':')
        _encode_json_value(io, v; kw...)
    end
    return nothing
end

function _decode_json_value(
    ::Type{_Any_},
    json::AbstractDict;
    registry::Union{Nothing,AbstractDict} = nothing,
    kw...,
)
    type_url = get(json, "@type", nothing)
    type_url === nothing && throw(ArgumentError("Any JSON object missing '@type'"))
    type_url isa AbstractString || throw(ArgumentError("Any '@type' is not a string"))

    fqn = _any_extract_fqn(type_url)
    T = lookup_message_type(fqn; registry = registry)
    T === nothing &&
        throw(ArgumentError("Any: no message type registered for $(repr(fqn))"))

    msg = if fqn in _WKT_VALUE_FORM
        haskey(json, "value") ||
            throw(ArgumentError("Any wrapping $(fqn) requires a 'value' field"))
        _decode_json_value(T, json["value"]; registry = registry, kw...)
    else
        # Strip @type and pass the rest to the message walker.
        rest = Dict{String,Any}()
        for (k, v) in json
            k == "@type" && continue
            rest[k] = v
        end
        _decode_json_message(T, rest; registry = registry, kw...)
    end

    # Re-encode to bytes for the Any wire form.
    return _Any_(String(type_url), encode(msg), UInt8[])
end

# -----------------------------------------------------------------------------
# NullValue — JSON `null` ↔ NULL_VALUE enum singleton.
# -----------------------------------------------------------------------------

# When emitted standalone (rare — typically as a oneof member in Value),
# always render as JSON null.
function _encode_json_value(io::IO, ::_NullValue.T; kw...)
    print(io, "null")
    return nothing
end

# JSON null parses to the NULL_VALUE enum value.
function _decode_json_value(::Type{_NullValue.T}, ::Nothing; kw...)
    return _NullValue.NULL_VALUE
end

# Tell the message walker that these three types accept JSON `null` as a
# real decoded value (rather than "field unset, use default"). See
# `_accepts_json_null` in json.jl.
@inline _accepts_json_null(::Type{_Value}) = true
@inline _accepts_json_null(::Type{_AbstractValue}) = true
@inline _accepts_json_null(::Type{_NullValue.T}) = true
