# Protocol Buffers JSON mapping — encoder and decoder.
#
# Implements the wire format described at
#   https://protobuf.dev/programming-guides/json/
# via a reflection-driven walker over our existing metadata methods
# (`field_numbers`, `oneof_field_types`, `StructHelpers.default_keywords`) plus the
# codegen-emitted `json_field_names`.
#
# Coverage: scalars (including int64/uint64 → JSON string and bytes →
# base64 string), float NaN/±Infinity → JSON string, nested messages,
# repeated, enums as canonical name strings (parsed from either string
# or integer), oneof active-member parent flattening, maps (with
# stringified keys per spec), the `ignore_unknown_fields` parse option
# (default off — strict), proto3-style omit-defaults on encode, plus
# WKT special forms (Timestamp, Duration, Any, …) in `json_wkt.jl`.

import JSON
import Base64

# -----------------------------------------------------------------------------
# Message-type registry — FQN ("google.protobuf.Timestamp") → Julia type.
# Codegen emits a `register_message_type` call per message, populating this
# at module-load time. `Any.type_url` carries the FQN, and `lookup_message_type`
# is the reverse direction the JSON walker uses to decode embedded messages.
# -----------------------------------------------------------------------------

const _MESSAGE_REGISTRY = Dict{String,Type}()

"""
    register_message_type(fqn, T)

Associate `fqn` (e.g. `"google.protobuf.Timestamp"`) with the Julia type
`T`. Called from generated `*_pb.jl` files at module-load time; user code
typically doesn't need to call this directly.

Re-registering the same `(fqn, T)` pair is a silent no-op (covers Revise
edits and re-`using` a precompiled package). Re-registering the same `fqn`
to a *different* Julia type throws — that means two distinct proto
definitions share an FQN and the global registry can't represent both.
Callers that need to round-trip both must pass a per-call `registry`
argument to `encode_json` / `decode_json` instead of relying on the
global table.
"""
function register_message_type(fqn::AbstractString, ::Type{T}) where {T}
    key = String(fqn)
    existing = get(_MESSAGE_REGISTRY, key, nothing)
    if existing === T
        return nothing
    elseif existing !== nothing
        throw(
            ArgumentError(
                """
                protobuf FQN $(repr(key)) is already registered to $(existing); refusing to overwrite with $(T).
                Two distinct proto definitions share this FQN — pass a per-call `registry` to encode_json/decode_json to disambiguate.""",
            ),
        )
    end
    _MESSAGE_REGISTRY[key] = T
    return nothing
end

"""
    unregister_message_type(fqn) -> Bool

Drop `fqn` from the global registry; returns `true` if the entry existed.
Intended for test/dev workflows that need to re-bind an FQN to a different
Julia type (e.g., when re-`eval`'ing codegen output into a fresh anonymous
module). Production code shouldn't need this.
"""
function unregister_message_type(fqn::AbstractString)
    return pop!(_MESSAGE_REGISTRY, String(fqn), nothing) !== nothing
end

"""
    lookup_message_type(fqn; registry=nothing) -> Union{Type,Nothing}

Reverse of `register_message_type`. Returns `nothing` if no type was
registered under that FQN — typically because the user hasn't loaded
the proto module that defines it.

If `registry` is non-`nothing`, *only* that table is consulted (no
fallback to the global registry). This matches Go's resolver semantics
and lets callers fully control FQN → type resolution when they need to.
"""
function lookup_message_type(
    fqn::AbstractString;
    registry::Union{Nothing,AbstractDict} = nothing,
)
    return get(something(registry, _MESSAGE_REGISTRY), String(fqn), nothing)
end

# Per-enum metadata: the proto wire-side prefix that codegen stripped from
# each value's Julia identifier (e.g. `"FEATURE_TYPE_"` for an enum whose
# values were `FEATURE_TYPE_FOO`/`FEATURE_TYPE_BAR`, leaving the Julia names
# `FOO` / `BAR`). Codegen emits an overload per stripped enum; the abstract
# default returns "" so verbatim-named enums and hand-written subtypes work
# unchanged. Read by the JSON walker to (re)attach the prefix at the wire
# boundary.
function _enum_proto_prefix(::Type{<:Base.Enum})
    return ""
end

# -----------------------------------------------------------------------------
# Public API
# -----------------------------------------------------------------------------

"""
    encode_json([io,] msg; registry=nothing) -> Union{Nothing,String}

Serialize `msg` to its protobuf-JSON representation. With an `IO`
argument, writes to it and returns `nothing`; without one, returns a
`String`.

`registry`, if non-`nothing`, is used to resolve FQN → Julia type for
any embedded `google.protobuf.Any` values encountered during the walk
instead of the global registry. See [`lookup_message_type`](@ref).
"""
function encode_json(
    io::IO,
    msg::AbstractProtoBufMessage;
    registry::Union{Nothing,AbstractDict} = nothing,
)
    # Route through `_encode_json_value` so WKT specializations
    # (wrappers, Timestamp, Duration, …) that override the value form
    # also work when called at the top level.
    _encode_json_value(io, msg; registry = registry)
    return nothing
end

function encode_json(
    msg::AbstractProtoBufMessage;
    registry::Union{Nothing,AbstractDict} = nothing,
)
    io = IOBuffer()
    encode_json(io, msg; registry = registry)
    return String(take!(io))
end

"""
    decode_json(::Type{T}, source; ignore_unknown_fields = false, registry=nothing) -> T

Parse a protobuf-JSON document into a `T <: AbstractProtoBufMessage`.
`source` may be an `AbstractString`, an `IO`, or an already-parsed
JSON value (a `Dict{String,Any}` produced by `JSON.parse`).

By default a JSON key that doesn't map to any field of `T` (or any
nested message type) raises `ArgumentError`, matching the spec's
strict default. Pass `ignore_unknown_fields = true` to silently drop
them (this is what conformance JSON_IGNORE_UNKNOWN_PARSING_TEST asks
for).

`registry`, if non-`nothing`, replaces the global FQN → type table for
any `google.protobuf.Any` values seen during the walk. See
[`lookup_message_type`](@ref).
"""
function decode_json(
    ::Type{T},
    src::AbstractString;
    ignore_unknown_fields::Bool = false,
    registry::Union{Nothing,AbstractDict} = nothing,
) where {T<:AbstractProtoBufMessage}
    return _decode_json_value(
        T,
        JSON.parse(src);
        ignore_unknown_fields = ignore_unknown_fields,
        registry = registry,
    )
end

function decode_json(
    ::Type{T},
    src::IO;
    ignore_unknown_fields::Bool = false,
    registry::Union{Nothing,AbstractDict} = nothing,
) where {T<:AbstractProtoBufMessage}
    return _decode_json_value(
        T,
        JSON.parse(src);
        ignore_unknown_fields = ignore_unknown_fields,
        registry = registry,
    )
end

# Already-parsed JSON value (Dict, Array, scalar, or `nothing`). The
# value walker handles all the WKT specializations as well as the
# generic message form.
function decode_json(
    ::Type{T},
    json;
    ignore_unknown_fields::Bool = false,
    registry::Union{Nothing,AbstractDict} = nothing,
) where {T<:AbstractProtoBufMessage}
    return _decode_json_value(
        T,
        json;
        ignore_unknown_fields = ignore_unknown_fields,
        registry = registry,
    )
end

# -----------------------------------------------------------------------------
# Encode side — message walker
# -----------------------------------------------------------------------------

function _encode_json_message(io::IO, msg::T; kw...) where {T<:AbstractProtoBufMessage}
    keys = json_field_names(T)
    oneofs = oneof_field_types(T)
    print(io, '{')
    first = true
    for jl_name in fieldnames(T)
        # `#unknown_fields` is a wire-format-only buffer for forward-compat
        # round-trips of unrecognized tags; the JSON form per spec drops
        # unknowns, so don't emit it here.
        jl_name === Symbol("#unknown_fields") && continue
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
            _encode_json_value(io, o.value; kw...)
            continue
        end
        # Default-skip applies to plain proto3 scalars (typed bare).
        # Presence-bearing fields (`Union{Nothing,X}` — proto3 explicit
        # `optional`, proto2 `optional`, singular submessages) carry
        # presence: a non-`nothing` value is always emitted, even if it
        # equals the type's default (`""`, `0`, `false`, etc.). The
        # `nothing` case was already filtered above.
        if !_field_is_presence_bearing(T, jl_name) && _is_json_default(v)
            continue
        end
        json_key = getproperty(keys, jl_name)
        first || print(io, ',')
        first = false
        JSON.print(io, json_key)
        print(io, ':')
        _encode_json_value(io, v; kw...)
    end
    print(io, '}')
    return nothing
end

# A field is presence-bearing iff its declared type is `Union{Nothing, X}`
# — i.e., codegen typed it that way to capture set-vs-unset.
@inline function _field_is_presence_bearing(::Type{T}, name::Symbol) where {T}
    ft = fieldtype(T, name)
    return ft isa Union && Nothing <: ft
end

# Does `T`'s JSON form treat a JSON `null` as a real value (rather than
# "field unset")? Default false; overridden in `json_wkt.jl` for
# `google.protobuf.Value`, its cycle supertype `AbstractValue`, and
# `google.protobuf.NullValue`.
@inline _accepts_json_null(::Type) = false

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

function _encode_json_value(io::IO, v::Bool; kw...)
    print(io, v ? "true" : "false")
    return nothing
end

# 32-bit integers → JSON number. (protobuf has no 8/16-bit integer types,
# so codegen never produces a field with one of those scalar types.)
function _encode_json_value(io::IO, v::Union{Int32,UInt32}; kw...)
    print(io, v)
    return nothing
end

# 64-bit integers → JSON string. JS numbers can't represent the full
# int64/uint64 range, so the spec mandates string form.
function _encode_json_value(io::IO, v::Union{Int64,UInt64}; kw...)
    print(io, '"', v, '"')
    return nothing
end

function _encode_json_value(io::IO, v::AbstractFloat; kw...)
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

function _encode_json_value(io::IO, s::AbstractString; kw...)
    JSON.print(io, s)
    return nothing
end

# bytes → base64 JSON string.
function _encode_json_value(io::IO, b::Vector{UInt8}; kw...)
    print(io, '"', Base64.base64encode(b), '"')
    return nothing
end

# Enums: emit the canonical declared name. With EnumX, `Symbol(v)`
# returns the canonical-form name even for aliases (per the
# `allow_alias` design). Per spec: an enum value with no declared name
# (i.e., a numeric value the wire/JSON delivered that isn't in this
# enum's value set) round-trips as a JSON number, not a string.
#
# The Julia identifier may have had a `<UPPER_SNAKE>_` prefix stripped by
# codegen; reattach it via `_enum_proto_prefix(typeof(v))` so the JSON wire
# form stays canonical (`"FEATURE_TYPE_FOO"`, not `"FOO"`). For verbatim
# enums the prefix is "" and this collapses to the prior behavior.
function _encode_json_value(io::IO, v::Base.Enum; kw...)
    name = try
        Symbol(v)
    catch
        nothing
    end
    if name === nothing
        print(io, Integer(v))
    else
        print(io, '"', _enum_proto_prefix(typeof(v)), String(name), '"')
    end
    return nothing
end

# Repeated.
function _encode_json_value(io::IO, v::AbstractVector; kw...)
    print(io, '[')
    first = true
    for elt in v
        first || print(io, ',')
        first = false
        _encode_json_value(io, elt; kw...)
    end
    print(io, ']')
    return nothing
end

# Nested submessage.
function _encode_json_value(io::IO, v::AbstractProtoBufMessage; kw...)
    _encode_json_message(io, v; kw...)
    return nothing
end

# Map. Per spec, map keys are stringified regardless of underlying type
# (bool → "true"/"false", any integer → decimal). Values use the regular
# value dispatch.
function _encode_json_value(io::IO, d::AbstractDict; kw...)
    print(io, '{')
    first = true
    for (k, v) in d
        first || print(io, ',')
        first = false
        _emit_map_key(io, k)
        print(io, ':')
        _encode_json_value(io, v; kw...)
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

function _decode_json_message(
    ::Type{T},
    json::AbstractDict;
    ignore_unknown_fields::Bool = false,
    registry::Union{Nothing,AbstractDict} = nothing,
) where {T<:AbstractProtoBufMessage}
    keys = json_field_names(T)
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

    defaults = StructHelpers.default_keywords(T)
    vals = Dict{Symbol,Any}()
    for k in propertynames(defaults)
        vals[k] = getproperty(defaults, k)
    end

    # Per spec, a JSON object that sets two members of the same oneof is
    # rejected. Track the set of parent oneof field names already set;
    # NB null members that resolve to "skip" are NOT counted (matches
    # OneofFieldNullFirst/Second).
    seen_oneof = Set{Symbol}()

    for (json_key, json_val) in json
        jl_name = get(json_to_jl, json_key, nothing)
        if jl_name === nothing
            ignore_unknown_fields && continue
            throw(
                ArgumentError(
                    "unknown field \"$(json_key)\" while decoding $(T); " *
                    "set `ignore_unknown_fields = true` to skip",
                ),
            )
        end

        # Determine the field-or-oneof-member's resolved type so we can
        # do null-handling consistently for both. `oneof_member_lookup`
        # maps a member name → (parent_field, member_type); plain
        # fields aren't in there.
        member = get(oneof_member_lookup, jl_name, nothing)
        FT = if member !== nothing
            member[2]
        else
            Base.nonnothingtype(fieldtype(T, jl_name))
        end

        # Per spec, JSON `null` for a singular field means "use default" —
        # we already populated `vals` from defaults, so just skip. The
        # exception is types whose JSON form treats null as a real
        # value (Value / NullValue) — `_accepts_json_null(T)` returns
        # `true` for those (overridden in json_wkt.jl, since the WKT
        # types live in a module loaded after this file).
        if json_val === nothing
            if _accepts_json_null(FT)
                decoded = _decode_json_value(
                    FT,
                    nothing;
                    ignore_unknown_fields = ignore_unknown_fields,
                    registry = registry,
                )
                if member !== nothing
                    parent = member[1]
                    parent in seen_oneof && throw(
                        ArgumentError(
                            "multiple members of oneof '$(parent)' set in JSON for $(T)",
                        ),
                    )
                    push!(seen_oneof, parent)
                    vals[parent] = OneOf(jl_name, decoded)
                else
                    vals[jl_name] = decoded
                end
            end
            continue
        end

        if member !== nothing
            # Decoding an active oneof member: wrap in `OneOf` and
            # store at the parent field. The parent field type uses a
            # covariant `OneOf{<:Union{…}}` bound, so `OneOf{ConcreteT}`
            # is assignable.
            parent = member[1]
            parent in seen_oneof && throw(
                ArgumentError("multiple members of oneof '$(parent)' set in JSON for $(T)"),
            )
            push!(seen_oneof, parent)
            decoded = _decode_json_value(
                FT,
                json_val;
                ignore_unknown_fields = ignore_unknown_fields,
                registry = registry,
            )
            vals[parent] = OneOf(jl_name, decoded)
        else
            # Plain field. Strip the presence wrapper; JSON `null` was
            # already filtered above.
            vals[jl_name] = _decode_json_value(
                FT,
                json_val;
                ignore_unknown_fields = ignore_unknown_fields,
                registry = registry,
            )
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

# 32-bit integers. Accept either JSON number or numeric string.
# `Bool <: Real`, so without the explicit Bool method JSON `true` /
# `false` would silently coerce to 0/1 — spec says reject. The Bool
# method's first-arg union must match the Real method's exactly to
# avoid Aqua ambiguity (more-specific second arg loses if first is
# wider), so the two are kept symmetric.
function _decode_json_value(::Type{T}, ::Bool; kw...) where {T<:Union{Int32,UInt32}}
    throw(ArgumentError("expected $(T), got JSON boolean"))
end
function _decode_json_value(::Type{T}, v::Real; kw...) where {T<:Union{Int32,UInt32}}
    return T(v)
end
function _decode_json_value(
    ::Type{T},
    v::AbstractString;
    kw...,
) where {T<:Union{Int32,UInt32}}
    return _strict_parse_int(T, v)
end

# 64-bit integers — accept string (canonical) or number.
function _decode_json_value(
    ::Type{T},
    v::AbstractString;
    kw...,
) where {T<:Union{Int64,UInt64}}
    return _strict_parse_int(T, v)
end
function _decode_json_value(::Type{T}, ::Bool; kw...) where {T<:Union{Int64,UInt64}}
    throw(ArgumentError("expected $(T), got JSON boolean"))
end
function _decode_json_value(::Type{T}, v::Real; kw...) where {T<:Union{Int64,UInt64}}
    return T(v)
end

# Strict integer parse: Julia's `parse(T, s)` accepts leading/trailing
# whitespace; the protobuf-JSON spec rejects it. Reject any non-canonical
# decoration before falling through.
function _strict_parse_int(::Type{T}, s::AbstractString) where {T<:Integer}
    if isempty(s) || s[1] in (' ', '\t', '\n', '\r') || s[end] in (' ', '\t', '\n', '\r')
        throw(ArgumentError("invalid $(T) literal: $(repr(s))"))
    end
    return parse(T, s)
end

function _decode_json_value(::Type{T}, v::AbstractString; kw...) where {T<:AbstractFloat}
    if v == "NaN"
        return T(NaN)
    elseif v == "Infinity"
        return T(Inf)
    elseif v == "-Infinity"
        return T(-Inf)
    else
        # `parse(Float32, big_string)` silently produces ±Inf on overflow.
        # Parse as Float64 first, then range-check the narrowing.
        return _checked_float(T, parse(Float64, v))
    end
end
function _decode_json_value(::Type{T}, v::Real; kw...) where {T<:AbstractFloat}
    return _checked_float(T, v)
end

# Range-checked narrowing. The two cases we have to catch:
#   * JSON literal exceeds Float64's range — JSON.parse returns a
#     `BigFloat` whose `Float64(v)` is ±Inf. Reject for any concrete
#     AbstractFloat target.
#   * JSON literal fits in Float64 but is outside Float32's representable
#     finite range — `Float32(big_double)` silently rounds to ±Inf.
# In both cases the source `v` was finite; the conversion isn't.
@inline function _checked_float(::Type{Float64}, v::Real)
    f = Float64(v)
    if !isfinite(f) && isfinite(v)
        throw(ArgumentError("Float64 literal out of range"))
    end
    return f
end
@inline function _checked_float(::Type{Float32}, v::Real)
    f = Float32(v)
    if !isfinite(f) && isfinite(v)
        throw(ArgumentError("Float32 literal out of range"))
    end
    return f
end

function _decode_json_value(::Type{String}, v::AbstractString; kw...)
    return String(v)
end

# bytes — base64-decode.
function _decode_json_value(::Type{Vector{UInt8}}, v::AbstractString; kw...)
    return Base64.base64decode(v)
end

# Enums: accept canonical name (string) or numeric value. The wire name
# carries the proto-side prefix (e.g. `"FEATURE_TYPE_FOO"`); strip it via
# `_enum_proto_prefix` to recover the Julia identifier (`FOO`). Verbatim
# enums set the prefix to "" and this is a no-op. As ergonomic slack we
# also accept the bare stripped form (`"FOO"`) — harmless and useful when
# users hand-write JSON literals matching the Julia identifier.
function _decode_json_value(::Type{E}, v::AbstractString; kw...) where {E<:Base.Enum}
    prefix = _enum_proto_prefix(E)
    name = startswith(v, prefix) ? SubString(v, lastindex(prefix) + 1) : v
    return getfield(parentmodule(E), Symbol(name))::E
end
# Numeric form. Per spec, *any* integer is accepted; values outside the
# enum's declared set round-trip as numbers (no symbolic name). Use
# `bitcast` to construct a value with the integer regardless of whether
# it's a declared member, mirroring what the binary codec produces from
# wire-level varints.
function _decode_json_value(::Type{E}, v::Real; kw...) where {E<:Base.Enum}
    Backing = Base.Enums.basetype(E)
    return Core.bitcast(E, Backing(v))
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
function _decode_json_value(
    ::Type{T},
    v::AbstractDict;
    kw...,
) where {T<:AbstractProtoBufMessage}
    return _decode_json_message(T, v; kw...)
end

# Map. The Julia field type is `OrderedDict{K,V}` (codegen default) but
# we accept any `AbstractDict{K,V}`. Per spec, all map keys arrive as
# JSON strings — re-parse into `K` here.
function _decode_json_value(
    ::Type{D},
    v::AbstractDict;
    kw...,
) where {K,V,D<:AbstractDict{K,V}}
    out = D()
    for (jk, jv) in v
        out[_decode_map_key(K, jk)] = _decode_json_value(V, jv; kw...)
    end
    return out
end

function _decode_map_key(::Type{Bool}, s::AbstractString)
    s == "true" && return true
    s == "false" && return false
    throw(ArgumentError("invalid bool map key: $(repr(s))"))
end
function _decode_map_key(::Type{T}, s::AbstractString) where {T<:Integer}
    return parse(T, s)
end
function _decode_map_key(::Type{String}, s::AbstractString)
    return String(s)
end
