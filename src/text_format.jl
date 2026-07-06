# Protocol Buffers text format (textproto) — printer and parser.
#
# Implements the language described at
#   https://protobuf.dev/reference/protobuf/textformat-spec/
# via the same reflection-driven walk as `json.jl` (over `field_numbers`,
# `oneof_field_types`, `StructHelpers.default_keywords`, `_enum_proto_prefix`
# and the FQN registry). Text format uses the *original proto* field names
# (the Julia field names modulo keyword mangling — see `_proto_field_name`),
# never the camelCase `json_field_names`.
#
# Coverage: scalars (C-style string/bytes escaping, nan/inf floats,
# hex/octal integer literals on parse), nested messages with `{}` or `<>`
# delimiters, repeated fields (including `[v1, v2]` list shorthand), maps,
# enums by name or number, oneofs, `#` comments, and the expanded
# `google.protobuf.Any` form `[type.googleapis.com/pkg.Msg] { … }`. Unlike
# JSON, text format has no special forms for the other well-known types —
# Timestamp, Duration, wrappers, Struct all print as ordinary messages.
#
# Deliberate limits (mirroring the rest of ProtocGen): proto2 extension
# syntax `[pkg.ext]` is a clear parse error (there is no typed extension
# storage anywhere in ProtocGen), and unknown fields captured by the binary
# decoder are dropped on print, like JSON.
#
# Loaded after `json_wkt.jl` (and thus after `gen/google/google.jl`), so
# the `_Any_` alias and the google WKT types are in scope. Nothing in
# generated code references these functions, so — unlike `json.jl` — there
# is no load-order constraint from codegen.

# -----------------------------------------------------------------------------
# Public API
# -----------------------------------------------------------------------------

"""
    encode_text([io,] msg; registry=nothing) -> Union{Nothing,String}

Serialize `msg` to protobuf text format (textproto): multiline, 2-space
indent, one field per line. With an `IO` argument, writes to it and
returns `nothing`; without one, returns a `String`.

Unknown fields captured by the binary decoder are dropped, like JSON.
`registry`, if non-`nothing`, resolves FQN → Julia type for embedded
`google.protobuf.Any` values instead of the global registry; an `Any`
whose type can't be resolved prints its raw `type_url:`/`value:` fields
instead of the expanded form. See [`lookup_message_type`](@ref).
"""
function encode_text(
    io::IO,
    msg::AbstractProtoBufMessage;
    registry::Union{Nothing,AbstractDict} = nothing,
)
    _encode_text_message(io, msg, 0; registry = registry)
    return nothing
end

function encode_text(
    msg::AbstractProtoBufMessage;
    registry::Union{Nothing,AbstractDict} = nothing,
)
    io = IOBuffer()
    encode_text(io, msg; registry = registry)
    return String(take!(io))
end

# -----------------------------------------------------------------------------
# Encode side — message walker
# -----------------------------------------------------------------------------

# A message body is just its fields, one per line — the braces around a
# nested message belong to the *field* printer. `_encode_text_message` is
# the dispatch point (specialized for `google.protobuf.Any` below);
# `_encode_text_fields` is the shared generic loop.
function _encode_text_message(io::IO, msg::AbstractProtoBufMessage, indent::Int; kw...)
    _encode_text_fields(io, msg, indent; kw...)
    return nothing
end

function _encode_text_fields(
    io::IO,
    msg::T,
    indent::Int;
    kw...,
) where {T<:AbstractProtoBufMessage}
    oneofs = oneof_field_types(T)
    for jl_name in fieldnames(T)
        # Wire-format-only buffer for unrecognized tags; printing unknown
        # fields is optional per spec and we drop them, like JSON.
        jl_name === Symbol("#unknown_fields") && continue
        v = getfield(msg, jl_name)
        # `nothing` always means "field not set".
        v === nothing && continue
        # Oneofs: emit only the active member, under the member's name.
        if hasproperty(oneofs, jl_name)
            o = v::OneOf
            _encode_text_field(io, _proto_field_name(o.name), o.value, indent; kw...)
            continue
        end
        # Same emission policy as JSON/binary: implicit-presence scalars
        # are skipped at their default; presence-bearing fields
        # (`Union{Nothing,X}`) and proto2 `required` fields always print
        # (see `_emit_at_default`).
        if !_emit_at_default(T, jl_name) && _is_json_default(v)
            continue
        end
        _encode_text_field(io, _proto_field_name(jl_name), v, indent; kw...)
    end
    return nothing
end

function _text_indent(io::IO, indent::Int)
    for _ in 1:indent
        print(io, "  ")
    end
    return nothing
end

# -----------------------------------------------------------------------------
# Encode side — field dispatch
# -----------------------------------------------------------------------------

# One field entry (a `name: value` line or a `name { … }` block). Repeated
# and map fields expand to one entry per element here.
function _encode_text_field(
    io::IO,
    name::AbstractString,
    v::AbstractProtoBufMessage,
    indent::Int;
    kw...,
)
    _text_indent(io, indent)
    print(io, name, " {\n")
    _encode_text_message(io, v, indent + 1; kw...)
    _text_indent(io, indent)
    print(io, "}\n")
    return nothing
end

# Map: one synthetic-entry block per pair, in insertion order.
function _encode_text_field(
    io::IO,
    name::AbstractString,
    d::AbstractDict,
    indent::Int;
    kw...,
)
    for (k, mv) in d
        _text_indent(io, indent)
        print(io, name, " {\n")
        _encode_text_field(io, "key", k, indent + 1; kw...)
        _encode_text_field(io, "value", mv, indent + 1; kw...)
        _text_indent(io, indent)
        print(io, "}\n")
    end
    return nothing
end

# Repeated: one entry per element.
function _encode_text_field(
    io::IO,
    name::AbstractString,
    v::AbstractVector,
    indent::Int;
    kw...,
)
    for elt in v
        _encode_text_field(io, name, elt, indent; kw...)
    end
    return nothing
end

# `Vector{UInt8}` is always a `bytes` scalar, never a repeated field —
# protobuf has no 8-bit integer scalar, so codegen can't produce a
# repeated field of `UInt8` (same disambiguation json.jl uses).
function _encode_text_field(
    io::IO,
    name::AbstractString,
    v::Vector{UInt8},
    indent::Int;
    kw...,
)
    _text_indent(io, indent)
    print(io, name, ": ")
    _encode_text_scalar(io, v)
    print(io, '\n')
    return nothing
end

function _encode_text_field(io::IO, name::AbstractString, v, indent::Int; kw...)
    _text_indent(io, indent)
    print(io, name, ": ")
    _encode_text_scalar(io, v)
    print(io, '\n')
    return nothing
end

# -----------------------------------------------------------------------------
# Encode side — scalar rendering
# -----------------------------------------------------------------------------

function _encode_text_scalar(io::IO, v::Bool)
    print(io, v ? "true" : "false")
    return nothing
end

# Decimal for both signed and unsigned (`print` renders Unsigned in
# decimal; only `show`/`repr` use hex).
function _encode_text_scalar(io::IO, v::Union{Int32,UInt32,Int64,UInt64})
    print(io, v)
    return nothing
end

function _encode_text_scalar(io::IO, v::Float64)
    if isnan(v)
        print(io, "nan")
    elseif v == Inf
        print(io, "inf")
    elseif v == -Inf
        print(io, "-inf")
    else
        print(io, v)
    end
    return nothing
end

function _encode_text_scalar(io::IO, v::Float32)
    if isnan(v)
        print(io, "nan")
    elseif v == Inf32
        print(io, "inf")
    elseif v == -Inf32
        print(io, "-inf")
    else
        # Julia renders Float32 exponents with 'f' ("1.0f-10"), which the
        # text format grammar rejects — swap in 'e'. The mantissa-only
        # form ("3.14") has no 'f' and passes through unchanged.
        print(io, replace(string(v), 'f' => 'e'))
    end
    return nothing
end

function _encode_text_scalar(io::IO, s::AbstractString)
    print(io, '"')
    _escape_text_bytes(io, codeunits(s), true)
    print(io, '"')
    return nothing
end

function _encode_text_scalar(io::IO, b::Vector{UInt8})
    print(io, '"')
    _escape_text_bytes(io, b, false)
    print(io, '"')
    return nothing
end

# Canonical declared name with the codegen-stripped prefix reattached
# (via the `_enum_wire_name` helper shared with JSON); a numeric value
# outside the declared set prints as its number, same policy as JSON.
function _encode_text_scalar(io::IO, v::Base.Enum)
    name = _enum_wire_name(v)
    if name === nothing
        print(io, Integer(v))
    else
        print(io, name)
    end
    return nothing
end

# protoc-CEscape-compatible escaping. `utf8_passthrough = true` (string
# fields) copies bytes ≥ 0x80 verbatim so valid UTF-8 stays readable;
# `false` (bytes fields) renders them as 3-digit octal.
function _escape_text_bytes(io::IO, bytes, utf8_passthrough::Bool)
    for b in bytes
        if b == UInt8('\\')
            print(io, "\\\\")
        elseif b == UInt8('"')
            print(io, "\\\"")
        elseif b == UInt8('\'')
            print(io, "\\'")
        elseif b == UInt8('\n')
            print(io, "\\n")
        elseif b == UInt8('\r')
            print(io, "\\r")
        elseif b == UInt8('\t')
            print(io, "\\t")
        elseif 0x20 <= b < 0x7f
            write(io, b)
        elseif b >= 0x80 && utf8_passthrough
            write(io, b)
        else
            print(io, '\\', string(b; base = 8, pad = 3))
        end
    end
    return nothing
end

# -----------------------------------------------------------------------------
# Lexer
# -----------------------------------------------------------------------------

@enum _TokenKind _TOK_IDENT _TOK_NUMBER _TOK_STRING _TOK_PUNCT _TOK_EOF

struct _TextToken
    kind::_TokenKind
    text::String            # ident/number text or punct char; "" for string/eof
    bytes::Vector{UInt8}    # unescaped payload (string tokens only)
end

function _text_token(kind::_TokenKind, text)
    _TextToken(kind, String(text), UInt8[])
end

mutable struct _TextLexer
    s::String
    i::Int                              # byte index of the next unread byte
    peeked::Union{Nothing,_TextToken}
end

function _TextLexer(s::AbstractString)
    _TextLexer(String(s), 1, nothing)
end

function _text_error(lex::_TextLexer, msg::AbstractString)
    # 1-based line/column of the next unread byte — close enough to point
    # at the offending token.
    upto = min(lex.i - 1, ncodeunits(lex.s))
    line = 1
    last_nl = 0
    for j in 1:upto
        if codeunit(lex.s, j) == UInt8('\n')
            line += 1
            last_nl = j
        end
    end
    col = upto - last_nl + 1
    throw(ArgumentError("text format error at line $(line), column $(col): $(msg)"))
end

@inline function _is_text_ident_start(b::UInt8)
    return (UInt8('a') <= b <= UInt8('z')) ||
           (UInt8('A') <= b <= UInt8('Z')) ||
           b == UInt8('_')
end
@inline _is_text_digit(b::UInt8) = UInt8('0') <= b <= UInt8('9')
@inline _is_text_ident_char(b::UInt8) = _is_text_ident_start(b) || _is_text_digit(b)

function _skip_ws_and_comments!(lex::_TextLexer)
    n = ncodeunits(lex.s)
    while lex.i <= n
        b = codeunit(lex.s, lex.i)
        if b == UInt8(' ') ||
           b == UInt8('\t') ||
           b == UInt8('\n') ||
           b == UInt8('\r') ||
           b == UInt8('\v') ||
           b == UInt8('\f')
            lex.i += 1
        elseif b == UInt8('#')
            while lex.i <= n && codeunit(lex.s, lex.i) != UInt8('\n')
                lex.i += 1
            end
        else
            break
        end
    end
    return nothing
end

function _peek_token!(lex::_TextLexer)
    if lex.peeked === nothing
        lex.peeked = _lex_token!(lex)
    end
    return lex.peeked::_TextToken
end

function _next_token!(lex::_TextLexer)
    t = _peek_token!(lex)
    lex.peeked = nothing
    return t
end

function _peek_is_punct(lex::_TextLexer, text::AbstractString)
    tok = _peek_token!(lex)
    return tok.kind === _TOK_PUNCT && tok.text == text
end

function _expect_punct!(lex::_TextLexer, text::AbstractString)
    tok = _next_token!(lex)
    (tok.kind === _TOK_PUNCT && tok.text == text) ||
        _text_error(lex, "expected '$(text)', got '$(tok.text)'")
    return nothing
end

function _lex_token!(lex::_TextLexer)
    _skip_ws_and_comments!(lex)
    n = ncodeunits(lex.s)
    lex.i > n && return _text_token(_TOK_EOF, "")
    b = codeunit(lex.s, lex.i)
    if _is_text_ident_start(b)
        start = lex.i
        while lex.i <= n && _is_text_ident_char(codeunit(lex.s, lex.i))
            lex.i += 1
        end
        return _text_token(_TOK_IDENT, SubString(lex.s, start, lex.i - 1))
    elseif _is_text_digit(b) ||
           (b == UInt8('.') && lex.i < n && _is_text_digit(codeunit(lex.s, lex.i + 1)))
        return _lex_number!(lex)
    elseif b == UInt8('"') || b == UInt8('\'')
        return _lex_string!(lex)
    elseif b == UInt8('{') ||
           b == UInt8('}') ||
           b == UInt8('<') ||
           b == UInt8('>') ||
           b == UInt8('[') ||
           b == UInt8(']') ||
           b == UInt8(':') ||
           b == UInt8(',') ||
           b == UInt8(';') ||
           b == UInt8('/') ||
           b == UInt8('-') ||
           b == UInt8('.')
        lex.i += 1
        return _text_token(_TOK_PUNCT, string(Char(b)))
    else
        _text_error(lex, "unexpected character $(repr(Char(b)))")
    end
end

# Lex the raw span of a numeric literal; interpretation (hex/octal/decimal,
# int vs float, range checks) happens in the typed parse functions, which
# know the target field type. A '+'/'-' is only part of the literal when it
# directly follows a decimal exponent marker ('e'/'E' outside hex).
function _lex_number!(lex::_TextLexer)
    n = ncodeunits(lex.s)
    start = lex.i
    is_hex = false
    if codeunit(lex.s, lex.i) == UInt8('0') && lex.i < n
        nb = codeunit(lex.s, lex.i + 1)
        is_hex = nb == UInt8('x') || nb == UInt8('X')
    end
    while lex.i <= n
        b = codeunit(lex.s, lex.i)
        if _is_text_ident_char(b) || b == UInt8('.')
            lex.i += 1
        elseif (b == UInt8('+') || b == UInt8('-')) && !is_hex && lex.i > start
            prev = codeunit(lex.s, lex.i - 1)
            if prev == UInt8('e') || prev == UInt8('E')
                lex.i += 1
            else
                break
            end
        else
            break
        end
    end
    return _text_token(_TOK_NUMBER, SubString(lex.s, start, lex.i - 1))
end

function _lex_string!(lex::_TextLexer)
    n = ncodeunits(lex.s)
    quote_b = codeunit(lex.s, lex.i)
    lex.i += 1
    out = UInt8[]
    while true
        lex.i > n && _text_error(lex, "unterminated string literal")
        b = codeunit(lex.s, lex.i)
        if b == quote_b
            lex.i += 1
            return _TextToken(_TOK_STRING, "", out)
        elseif b == UInt8('\n')
            _text_error(lex, "string literals cannot span multiple lines")
        elseif b == UInt8('\\')
            lex.i += 1
            _unescape_into!(out, lex)
        else
            push!(out, b)
            lex.i += 1
        end
    end
end

@inline function _hex_digit_value(b::UInt8)
    if UInt8('0') <= b <= UInt8('9')
        return UInt32(b - UInt8('0'))
    elseif UInt8('a') <= b <= UInt8('f')
        return UInt32(b - UInt8('a') + 0x0a)
    elseif UInt8('A') <= b <= UInt8('F')
        return UInt32(b - UInt8('A') + 0x0a)
    else
        return nothing
    end
end

# One escape sequence, cursor positioned just past the backslash.
function _unescape_into!(out::Vector{UInt8}, lex::_TextLexer)
    n = ncodeunits(lex.s)
    lex.i > n && _text_error(lex, "unterminated escape sequence")
    c = codeunit(lex.s, lex.i)
    lex.i += 1
    if c == UInt8('a')
        push!(out, 0x07)
    elseif c == UInt8('b')
        push!(out, 0x08)
    elseif c == UInt8('f')
        push!(out, 0x0c)
    elseif c == UInt8('n')
        push!(out, 0x0a)
    elseif c == UInt8('r')
        push!(out, 0x0d)
    elseif c == UInt8('t')
        push!(out, 0x09)
    elseif c == UInt8('v')
        push!(out, 0x0b)
    elseif c == UInt8('?')
        push!(out, UInt8('?'))
    elseif c == UInt8('\\') || c == UInt8('\'') || c == UInt8('"')
        push!(out, c)
    elseif UInt8('0') <= c <= UInt8('7')
        # 1-3 octal digits, first already consumed.
        val = UInt32(c - UInt8('0'))
        taken = 1
        while taken < 3 && lex.i <= n
            b = codeunit(lex.s, lex.i)
            (UInt8('0') <= b <= UInt8('7')) || break
            val = val * 8 + (b - UInt8('0'))
            lex.i += 1
            taken += 1
        end
        val <= 0xff || _text_error(lex, "octal escape out of range")
        push!(out, UInt8(val))
    elseif c == UInt8('x') || c == UInt8('X')
        # 1-2 hex digits.
        val = UInt32(0)
        taken = 0
        while taken < 2 && lex.i <= n
            hv = _hex_digit_value(codeunit(lex.s, lex.i))
            hv === nothing && break
            val = val * 16 + hv
            lex.i += 1
            taken += 1
        end
        taken == 0 && _text_error(lex, "'\\x' escape with no hex digits")
        push!(out, UInt8(val))
    elseif c == UInt8('u')
        _append_unicode_escape!(out, lex, 4)
    elseif c == UInt8('U')
        _append_unicode_escape!(out, lex, 8)
    else
        _text_error(lex, "invalid escape sequence '\\$(Char(c))'")
    end
    return nothing
end

function _append_unicode_escape!(out::Vector{UInt8}, lex::_TextLexer, ndigits::Int)
    n = ncodeunits(lex.s)
    val = UInt32(0)
    for _ in 1:ndigits
        lex.i <= n || _text_error(lex, "truncated unicode escape")
        hv = _hex_digit_value(codeunit(lex.s, lex.i))
        hv === nothing && _text_error(lex, "invalid unicode escape digit")
        val = val * 16 + hv
        lex.i += 1
    end
    (0xd800 <= val <= 0xdfff) &&
        _text_error(lex, "unicode escape encodes a surrogate code point")
    val <= 0x10ffff || _text_error(lex, "unicode escape out of range")
    append!(out, codeunits(string(Char(val))))
    return nothing
end

# -----------------------------------------------------------------------------
# Decode side — message walker
# -----------------------------------------------------------------------------

"""
    decode_text(::Type{T}, source; ignore_unknown_fields=false, registry=nothing) -> T

Parse protobuf text format (textproto) into a `T <: AbstractProtoBufMessage`.
`source` may be an `AbstractString` or an `IO`.

By default a field name that doesn't exist in `T` (or a nested message
type) raises `ArgumentError`; pass `ignore_unknown_fields = true` to skip
such fields. Proto2 extension syntax (`[pkg.ext]`) is not supported and
always errors. `registry`, if non-`nothing`, replaces the global FQN →
type table for expanded-form `google.protobuf.Any` values. See
[`lookup_message_type`](@ref).
"""
function decode_text(
    ::Type{T},
    src::AbstractString;
    ignore_unknown_fields::Bool = false,
    registry::Union{Nothing,AbstractDict} = nothing,
) where {T<:AbstractProtoBufMessage}
    lex = _TextLexer(src)
    return _decode_text_message(
        _resolve_concrete(T; registry = registry),
        lex,
        nothing;
        ignore_unknown_fields = ignore_unknown_fields,
        registry = registry,
    )
end

function decode_text(
    ::Type{T},
    src::IO;
    ignore_unknown_fields::Bool = false,
    registry::Union{Nothing,AbstractDict} = nothing,
) where {T<:AbstractProtoBufMessage}
    return decode_text(
        T,
        read(src, String);
        ignore_unknown_fields = ignore_unknown_fields,
        registry = registry,
    )
end

# Text format has no codegen support, so cycle-abstract field types
# (`AbstractStruct`, `AbstractValue`, … — emitted when messages form
# reference cycles) can't rely on generated forwarding methods the way
# `_decode_json_message` does. Resolve the unique registered concrete
# subtype instead; codegen emits `register_message_type` for every
# concrete message, so the active registry always has it.
function _resolve_concrete(
    ::Type{T};
    registry::Union{Nothing,AbstractDict} = nothing,
) where {T<:AbstractProtoBufMessage}
    isconcretetype(T) && return T
    # The per-call `registry` is documented as overriding FQN → type lookup
    # for `Any` payloads; it usually holds just those types. So consult it
    # first, but fall back to the active registry — otherwise passing a
    # registry would break decoding of any message with a cycle-abstract
    # field (Struct/Value/ListValue).
    found = _scan_for_concrete(T, @something(registry, REGISTRY[]))
    if found === nothing && registry !== nothing
        found = _scan_for_concrete(T, REGISTRY[])
    end
    found === nothing && throw(
        ArgumentError(
            "no concrete message type registered for abstract $(T); load the proto module that defines it",
        ),
    )
    return found
end

function _scan_for_concrete(::Type{T}, registry::AbstractDict) where {T}
    found = nothing
    for C in values(registry)
        if C <: T && isconcretetype(C)
            if found !== nothing && found !== C
                throw(
                    ArgumentError(
                        "multiple concrete message types registered for abstract $(T): $(found) and $(C)",
                    ),
                )
            end
            found = C
        end
    end
    return found
end

# Parse one message body: at top level (`close_delim === nothing`) until
# EOF, nested until the matching `}` / `>` (which is consumed).
function _decode_text_message(
    ::Type{T},
    lex::_TextLexer,
    close_delim::Union{Nothing,Char};
    ignore_unknown_fields::Bool = false,
    registry::Union{Nothing,AbstractDict} = nothing,
) where {T<:AbstractProtoBufMessage}
    # Memoized per-type tables: proto field name → Julia field name
    # (identical modulo keyword mangling) plus the inverse oneof lookup.
    tables = _field_tables(T)
    name_to_jl = tables.proto_to_jl
    oneof_member_lookup = tables.oneof_members

    defaults = StructHelpers.default_keywords(T)
    vals = Dict{Symbol,Any}()
    for k in propertynames(defaults)
        vals[k] = getproperty(defaults, k)
    end

    seen = Set{Symbol}()        # singular scalars already set (duplicate → error)
    seen_oneof = Set{Symbol}()  # oneof parents already set

    while true
        tok = _peek_token!(lex)
        if tok.kind === _TOK_EOF
            close_delim === nothing && break
            _text_error(
                lex,
                "unexpected end of input inside $(T) (expected '$(close_delim)')",
            )
        elseif tok.kind === _TOK_PUNCT &&
               close_delim !== nothing &&
               tok.text == string(close_delim)
            _next_token!(lex)
            break
        elseif tok.kind === _TOK_PUNCT && tok.text == "["
            _decode_text_bracket_field!(
                T,
                vals,
                seen,
                lex;
                ignore_unknown_fields = ignore_unknown_fields,
                registry = registry,
            )
        elseif tok.kind === _TOK_IDENT
            _next_token!(lex)
            jl_name = get(name_to_jl, tok.text, nothing)
            if jl_name === nothing
                if ignore_unknown_fields
                    _skip_text_field_value!(lex)
                else
                    throw(
                        ArgumentError(
                            "unknown field \"$(tok.text)\" while decoding $(T); " *
                            "set `ignore_unknown_fields = true` to skip",
                        ),
                    )
                end
            else
                _decode_text_field!(
                    T,
                    vals,
                    seen,
                    seen_oneof,
                    oneof_member_lookup,
                    jl_name,
                    lex;
                    ignore_unknown_fields = ignore_unknown_fields,
                    registry = registry,
                )
            end
        else
            _text_error(lex, "expected a field name, got '$(tok.text)'")
        end
        _consume_field_separator!(lex)
    end

    # proto2 `required` message fields have no entry in `default_keywords`
    # (there is no meaningful default to construct) — if the text never set
    # one, that's a missing required field.
    args = ntuple(fieldcount(T)) do i
        fname = fieldname(T, i)
        haskey(vals, fname) || throw(
            ArgumentError(
                "missing required field \"$(_proto_field_name(fname))\" while decoding $(T)",
            ),
        )
        vals[fname]
    end
    return T(args...)
end

# One optional ',' or ';' after a field entry.
function _consume_field_separator!(lex::_TextLexer)
    tok = _peek_token!(lex)
    if tok.kind === _TOK_PUNCT && (tok.text == "," || tok.text == ";")
        _next_token!(lex)
    end
    return nothing
end

function _maybe_colon!(lex::_TextLexer)
    if _peek_is_punct(lex, ":")
        _next_token!(lex)
        return true
    end
    return false
end

# Consume '{' or '<' and return the matching close delimiter.
function _expect_open_delim!(lex::_TextLexer)
    tok = _next_token!(lex)
    if tok.kind === _TOK_PUNCT && tok.text == "{"
        return '}'
    elseif tok.kind === _TOK_PUNCT && tok.text == "<"
        return '>'
    else
        _text_error(lex, "expected '{' or '<', got '$(tok.text)'")
    end
end

# One named-field entry, field name already consumed. Dispatches on the
# field shape: map, repeated, oneof member, or singular. Any non-repeated
# field appearing more than once is an error — protoc's text parser
# rejects that even for message fields (unlike the binary wire format,
# which merges repeated occurrences of a singular message).
function _decode_text_field!(
    ::Type{T},
    vals::Dict{Symbol,Any},
    seen::Set{Symbol},
    seen_oneof::Set{Symbol},
    oneof_member_lookup::Dict{Symbol,Tuple{Symbol,Type}},
    jl_name::Symbol,
    lex::_TextLexer;
    ignore_unknown_fields::Bool,
    registry::Union{Nothing,AbstractDict},
) where {T<:AbstractProtoBufMessage}
    member = get(oneof_member_lookup, jl_name, nothing)
    FT = member !== nothing ? member[2] : Base.nonnothingtype(fieldtype(T, jl_name))
    had_colon = _maybe_colon!(lex)

    if FT <: AbstractDict
        # Map field: entries accumulate across occurrences; the `[e1, e2]`
        # list shorthand is accepted; duplicate keys last-wins.
        dict = vals[jl_name]
        if _peek_is_punct(lex, "[")
            _next_token!(lex)
            first = true
            while !_peek_is_punct(lex, "]")
                first || _expect_punct!(lex, ",")
                _parse_text_map_entry!(
                    dict,
                    lex;
                    ignore_unknown_fields = ignore_unknown_fields,
                    registry = registry,
                )
                first = false
            end
            _next_token!(lex)
        else
            _parse_text_map_entry!(
                dict,
                lex;
                ignore_unknown_fields = ignore_unknown_fields,
                registry = registry,
            )
        end
    elseif FT <: AbstractVector && FT !== Vector{UInt8}
        # Repeated field: single value per occurrence, or `[…]` shorthand.
        E = eltype(FT)
        list = vals[jl_name]
        if _peek_is_punct(lex, "[")
            # Per the grammar, the colon is only optional before message
            # values (and lists of them); a scalar list needs one.
            (had_colon || E <: AbstractProtoBufMessage) ||
                _text_error(lex, "expected ':' before scalar list")
            _next_token!(lex)
            first = true
            while !_peek_is_punct(lex, "]")
                first || _expect_punct!(lex, ",")
                push!(
                    list,
                    _parse_text_value(
                        E,
                        lex,
                        true;
                        ignore_unknown_fields = ignore_unknown_fields,
                        registry = registry,
                    ),
                )
                first = false
            end
            _next_token!(lex)
        else
            push!(
                list,
                _parse_text_value(
                    E,
                    lex,
                    had_colon;
                    ignore_unknown_fields = ignore_unknown_fields,
                    registry = registry,
                ),
            )
        end
    elseif member !== nothing
        parent = member[1]
        parent in seen_oneof && throw(
            ArgumentError(
                "multiple members of oneof '$(parent)' set in text format for $(T)",
            ),
        )
        push!(seen_oneof, parent)
        v = _parse_text_value(
            FT,
            lex,
            had_colon;
            ignore_unknown_fields = ignore_unknown_fields,
            registry = registry,
        )
        vals[parent] = OneOf(jl_name, v)
    else
        jl_name in seen && throw(
            ArgumentError(
                "non-repeated field \"$(_proto_field_name(jl_name))\" appears multiple times in text format for $(T)",
            ),
        )
        push!(seen, jl_name)
        vals[jl_name] = _parse_text_value(
            FT,
            lex,
            had_colon;
            ignore_unknown_fields = ignore_unknown_fields,
            registry = registry,
        )
    end
    return nothing
end

# One map entry block: `{ key: … value: … }` (either order, `<>` accepted,
# either half omittable — the missing half takes the type's default).
function _parse_text_map_entry!(
    dict::AbstractDict{K,V},
    lex::_TextLexer;
    ignore_unknown_fields::Bool,
    registry::Union{Nothing,AbstractDict},
) where {K,V}
    close = _expect_open_delim!(lex)
    key = _map_entry_default(K; registry = registry)
    val = _map_entry_default(V; registry = registry)
    have_key = false
    have_val = false
    while true
        tok = _peek_token!(lex)
        if tok.kind === _TOK_EOF
            _text_error(lex, "unexpected end of input inside map entry")
        elseif tok.kind === _TOK_PUNCT && tok.text == string(close)
            _next_token!(lex)
            break
        elseif tok.kind === _TOK_IDENT && tok.text == "key"
            have_key && _text_error(lex, "map entry specifies 'key' more than once")
            have_key = true
            _next_token!(lex)
            key = _parse_text_value(
                K,
                lex,
                _maybe_colon!(lex);
                ignore_unknown_fields = ignore_unknown_fields,
                registry = registry,
            )
        elseif tok.kind === _TOK_IDENT && tok.text == "value"
            have_val && _text_error(lex, "map entry specifies 'value' more than once")
            have_val = true
            _next_token!(lex)
            val = _parse_text_value(
                V,
                lex,
                _maybe_colon!(lex);
                ignore_unknown_fields = ignore_unknown_fields,
                registry = registry,
            )
        else
            _text_error(lex, "expected 'key' or 'value' in map entry, got '$(tok.text)'")
        end
        _consume_field_separator!(lex)
    end
    dict[key] = val
    return nothing
end

# Default for an omitted map-entry half. Text format is the only wire
# form that needs per-leaf-type defaults at runtime: an entry may omit
# `key:` or `value:` entirely (`fields { key: "a" }`), whereas JSON map
# syntax always carries both halves and `default_keywords` only covers
# whole messages, not leaf scalar types.
function _map_entry_default(
    ::Type{FT};
    registry::Union{Nothing,AbstractDict} = nothing,
) where {FT}
    if FT === Bool
        return false
    elseif FT === String
        return ""
    elseif FT <: Integer
        return zero(FT)
    elseif FT <: AbstractFloat
        return zero(FT)
    elseif FT === Vector{UInt8}
        return UInt8[]
    elseif FT <: Base.Enum
        return Core.bitcast(FT, zero(Base.Enums.basetype(FT)))
    elseif FT <: AbstractProtoBufMessage
        C = _resolve_concrete(FT; registry = registry)
        d = StructHelpers.default_keywords(C)
        return C(ntuple(i -> getproperty(d, fieldname(C, i)), fieldcount(C))...)
    else
        error("unreachable: no text-format default for map entry type $(FT)")
    end
end

# -----------------------------------------------------------------------------
# Decode side — value dispatch
# -----------------------------------------------------------------------------

# `had_colon` records whether the field loop consumed a ':' after the field
# name: required before scalar values, optional before message blocks.
function _require_colon(lex::_TextLexer, had_colon::Bool)
    had_colon || _text_error(lex, "expected ':' before scalar value")
    return nothing
end

function _consume_minus!(lex::_TextLexer)
    if _peek_is_punct(lex, "-")
        _next_token!(lex)
        return true
    end
    return false
end

function _parse_text_value(::Type{Bool}, lex::_TextLexer, had_colon::Bool; kw...)
    _require_colon(lex, had_colon)
    tok = _next_token!(lex)
    if tok.kind === _TOK_IDENT
        if tok.text == "true" || tok.text == "True" || tok.text == "t"
            return true
        elseif tok.text == "false" || tok.text == "False" || tok.text == "f"
            return false
        else
            _text_error(lex, "invalid bool literal '$(tok.text)'")
        end
    elseif tok.kind === _TOK_NUMBER
        if tok.text == "1"
            return true
        elseif tok.text == "0"
            return false
        else
            _text_error(lex, "invalid bool literal '$(tok.text)'")
        end
    else
        _text_error(lex, "expected bool literal, got '$(tok.text)'")
    end
end

function _parse_text_value(
    ::Type{FT},
    lex::_TextLexer,
    had_colon::Bool;
    kw...,
) where {FT<:Union{Int32,UInt32,Int64,UInt64}}
    _require_colon(lex, had_colon)
    neg = _consume_minus!(lex)
    tok = _next_token!(lex)
    tok.kind === _TOK_NUMBER ||
        _text_error(lex, "expected integer literal for $(FT), got '$(tok.text)'")
    mag = _text_int_magnitude(lex, tok.text)
    v = neg ? -mag : mag
    (Int128(typemin(FT)) <= v <= Int128(typemax(FT))) ||
        _text_error(lex, "integer literal out of range for $(FT)")
    return FT(v)
end

# Magnitude of an integer literal: decimal, 0x… hex, or leading-0 octal.
# Float syntax ('.', exponent, 'f' suffix) is rejected here — an int field
# must not accept a float literal.
function _text_int_magnitude(lex::_TextLexer, s::AbstractString)
    local sub::SubString{String}, base::Int
    str = String(s)
    if startswith(str, "0x") || startswith(str, "0X")
        sub = SubString(str, 3)
        (!isempty(sub) && all(isxdigit, sub)) ||
            _text_error(lex, "invalid hex literal '$(str)'")
        base = 16
    elseif length(str) > 1 && startswith(str, "0")
        sub = SubString(str, 2)
        all(c -> '0' <= c <= '7', sub) || _text_error(lex, "invalid octal literal '$(str)'")
        base = 8
    else
        sub = SubString(str, 1)
        (!isempty(sub) && all(isdigit, sub)) ||
            _text_error(lex, "invalid integer literal '$(str)'")
        base = 10
    end
    v = try
        parse(Int128, sub; base = base)
    catch
        _text_error(lex, "integer literal out of range: '$(str)'")
    end
    return v::Int128
end

function _parse_text_value(
    ::Type{FT},
    lex::_TextLexer,
    had_colon::Bool;
    kw...,
) where {FT<:Union{Float32,Float64}}
    _require_colon(lex, had_colon)
    neg = _consume_minus!(lex)
    tok = _next_token!(lex)
    v = if tok.kind === _TOK_IDENT
        low = lowercase(tok.text)
        if low == "inf" || low == "infinity"
            FT(Inf)
        elseif low == "nan"
            FT(NaN)
        else
            _text_error(lex, "invalid float literal '$(tok.text)'")
        end
    elseif tok.kind === _TOK_NUMBER
        s = tok.text
        if startswith(s, "0x") || startswith(s, "0X")
            FT(_text_int_magnitude(lex, s))
        else
            # Optional C-style 'f'/'F' suffix.
            stripped =
                (endswith(s, "f") || endswith(s, "F")) ?
                SubString(s, 1, ncodeunits(s) - 1) : SubString(s, 1)
            isempty(stripped) && _text_error(lex, "invalid float literal '$(tok.text)'")
            if length(stripped) > 1 &&
               startswith(stripped, "0") &&
               all(c -> '0' <= c <= '7', SubString(stripped, 2))
                # Integer-token octal ("017" is 15, even on a float field).
                FT(_text_int_magnitude(lex, stripped))
            else
                f = tryparse(Float64, stripped)
                f === nothing && _text_error(lex, "invalid float literal '$(tok.text)'")
                # Unlike JSON, the text format accepts out-of-range float
                # literals and clamps them to ±inf (protoc behavior;
                # conformance FloatFieldTooLarge requires it).
                FT(f)
            end
        end
    else
        _text_error(lex, "expected float literal for $(FT), got '$(tok.text)'")
    end
    return neg ? -v : v
end

function _parse_text_value(::Type{String}, lex::_TextLexer, had_colon::Bool; kw...)
    _require_colon(lex, had_colon)
    bytes = _parse_text_string_bytes!(lex)
    s = String(bytes)
    # A string field must hold valid UTF-8 (the same escapes on a bytes
    # field are unrestricted — that's the Vector{UInt8} method).
    isvalid(s) || throw(ArgumentError("invalid UTF-8 in text format string literal"))
    return s
end

function _parse_text_value(::Type{Vector{UInt8}}, lex::_TextLexer, had_colon::Bool; kw...)
    _require_colon(lex, had_colon)
    return _parse_text_string_bytes!(lex)
end

# One string value: a quoted literal plus any adjacent literals
# ("foo" 'bar' concatenates to "foobar").
function _parse_text_string_bytes!(lex::_TextLexer)
    tok = _next_token!(lex)
    tok.kind === _TOK_STRING ||
        _text_error(lex, "expected string literal, got '$(tok.text)'")
    out = tok.bytes
    while _peek_token!(lex).kind === _TOK_STRING
        append!(out, _next_token!(lex).bytes)
    end
    return out
end

function _parse_text_value(
    ::Type{E},
    lex::_TextLexer,
    had_colon::Bool;
    kw...,
) where {E<:Base.Enum}
    _require_colon(lex, had_colon)
    tok = _peek_token!(lex)
    if tok.kind === _TOK_IDENT
        _next_token!(lex)
        # Prefix stripping and bare-stripped-form slack live in
        # `_enum_from_wire_name`, shared with the JSON codec.
        v = _enum_from_wire_name(E, tok.text)
        v === nothing && _text_error(lex, "unknown value '$(tok.text)' for enum $(E)")
        return v
    else
        # Numeric form: any in-range integer, declared or not (mirrors the
        # binary codec's treatment of wire varints). This is open-enum
        # (proto3) semantics; protoc's text parser rejects undeclared
        # numbers for *closed* proto2 enums, but whether an enum is closed
        # isn't knowable from the runtime metadata codegen currently
        # emits, so we accept them for both. NB an out-of-set value
        # re-prints as a bare number, which a closed-enum parser refuses.
        neg = _consume_minus!(lex)
        tok2 = _next_token!(lex)
        tok2.kind === _TOK_NUMBER ||
            _text_error(lex, "expected enum name or number for $(E), got '$(tok2.text)'")
        mag = _text_int_magnitude(lex, tok2.text)
        v = neg ? -mag : mag
        Backing = Base.Enums.basetype(E)
        (Int128(typemin(Backing)) <= v <= Int128(typemax(Backing))) ||
            _text_error(lex, "enum value out of range for $(E)")
        return Core.bitcast(E, Backing(v))
    end
end

# Message value: the ':' after the field name is optional; delimiters must
# match (`{`…`}` or `<`…`>`).
function _parse_text_value(
    ::Type{FT},
    lex::_TextLexer,
    had_colon::Bool;
    ignore_unknown_fields::Bool = false,
    registry::Union{Nothing,AbstractDict} = nothing,
) where {FT<:AbstractProtoBufMessage}
    close = _expect_open_delim!(lex)
    return _decode_text_message(
        _resolve_concrete(FT; registry = registry),
        lex,
        close;
        ignore_unknown_fields = ignore_unknown_fields,
        registry = registry,
    )
end

# -----------------------------------------------------------------------------
# Decode side — `[` at field-name position: Any expanded form or extension
# -----------------------------------------------------------------------------

# `[type.googleapis.com/pkg.Msg] { … }` (URL contains a '/') is the
# expanded `google.protobuf.Any` form; `[pkg.ext]` (no '/') is proto2
# extension syntax, which ProtocGen does not support.
function _decode_text_bracket_field!(
    ::Type{T},
    vals::Dict{Symbol,Any},
    seen::Set{Symbol},
    lex::_TextLexer;
    ignore_unknown_fields::Bool,
    registry::Union{Nothing,AbstractDict},
) where {T<:AbstractProtoBufMessage}
    _next_token!(lex)   # '['
    url = _parse_text_bracket_name!(lex)
    occursin('/', url) ||
        throw(ArgumentError("extension fields are not supported by ProtocGen ([$(url)])"))
    T === _Any_ || _text_error(
        lex,
        "expanded Any form [$(url)] is only valid inside google.protobuf.Any",
    )
    (:type_url in seen || :value in seen) && throw(
        ArgumentError(
            "google.protobuf.Any specifies the expanded form [$(url)] more than once or mixes it with raw type_url/value fields",
        ),
    )
    push!(seen, :type_url)
    push!(seen, :value)
    fqn = _any_extract_fqn(url)
    C = lookup_message_type(fqn; registry = registry)
    C === nothing && throw(
        ArgumentError(
            """
            Any: no message type registered for $(repr(fqn)); load the proto module that defines it (or call ProtocGen.register_message_type, or pass a per-call `registry`).""",
        ),
    )
    _maybe_colon!(lex)
    close = _expect_open_delim!(lex)
    msg = _decode_text_message(
        _resolve_concrete(C; registry = registry),
        lex,
        close;
        ignore_unknown_fields = ignore_unknown_fields,
        registry = registry,
    )
    vals[:type_url] = url
    vals[:value] = encode(msg)
    return nothing
end

# The dotted/slashed name between '[' and ']'; consumes the ']'.
function _parse_text_bracket_name!(lex::_TextLexer)
    io = IOBuffer()
    tok = _next_token!(lex)
    tok.kind === _TOK_IDENT ||
        _text_error(lex, "expected a name after '[', got '$(tok.text)'")
    print(io, tok.text)
    while true
        tok = _next_token!(lex)
        if tok.kind === _TOK_PUNCT && tok.text == "]"
            return String(take!(io))
        elseif tok.kind === _TOK_PUNCT && (tok.text == "." || tok.text == "/")
            print(io, tok.text)
            tok2 = _next_token!(lex)
            tok2.kind === _TOK_IDENT ||
                _text_error(lex, "expected a name segment after '$(tok.text)' in '[…]'")
            print(io, tok2.text)
        else
            _text_error(lex, "unexpected token '$(tok.text)' inside '[…]'")
        end
    end
end

# --- google.protobuf.Any printing: expanded form when resolvable ---------

function _encode_text_message(
    io::IO,
    msg::_Any_,
    indent::Int;
    registry::Union{Nothing,AbstractDict} = nothing,
    kw...,
)
    fqn = findlast('/', msg.type_url) === nothing ? nothing : _any_extract_fqn(msg.type_url)
    C = fqn === nothing ? nothing : lookup_message_type(fqn; registry = registry)
    # `value` bytes that don't decode as the resolved type also fall back
    # to the raw form — the expanded form must never turn a printable Any
    # into a crash.
    inner = C === nothing ? nothing : try
        decode(msg.value, C)
    catch
        nothing
    end
    if inner === nothing
        # Unresolvable — print the raw fields (protoc's fallback too).
        _encode_text_fields(io, msg, indent; registry = registry, kw...)
    else
        _text_indent(io, indent)
        print(io, '[', msg.type_url, "] {\n")
        _encode_text_message(io, inner, indent + 1; registry = registry, kw...)
        _text_indent(io, indent)
        print(io, "}\n")
    end
    return nothing
end

# -----------------------------------------------------------------------------
# Decode side — skipping unknown fields (`ignore_unknown_fields = true`)
# -----------------------------------------------------------------------------

# Balanced skip of one field value after an unknown field name: the
# optional ':', then a scalar token, an adjacent string run, a
# `{…}`/`<…>` block, or a `[…]` list.
function _skip_text_field_value!(lex::_TextLexer)
    _maybe_colon!(lex)
    _skip_text_single_value!(lex)
    return nothing
end

function _skip_text_single_value!(lex::_TextLexer)
    tok = _peek_token!(lex)
    if tok.kind === _TOK_PUNCT && (tok.text == "{" || tok.text == "<")
        close = _expect_open_delim!(lex)
        _skip_text_block!(lex, close)
    elseif tok.kind === _TOK_PUNCT && tok.text == "["
        _next_token!(lex)
        first = true
        while !_peek_is_punct(lex, "]")
            first || _expect_punct!(lex, ",")
            _skip_text_single_value!(lex)
            first = false
        end
        _next_token!(lex)
    elseif tok.kind === _TOK_STRING
        _next_token!(lex)
        while _peek_token!(lex).kind === _TOK_STRING
            _next_token!(lex)
        end
    elseif tok.kind === _TOK_PUNCT && tok.text == "-"
        _next_token!(lex)
        tok2 = _next_token!(lex)
        (tok2.kind === _TOK_NUMBER || tok2.kind === _TOK_IDENT) ||
            _text_error(lex, "expected a value after '-'")
    elseif tok.kind === _TOK_NUMBER || tok.kind === _TOK_IDENT
        _next_token!(lex)
    else
        _text_error(lex, "expected a value, got '$(tok.text)'")
    end
    return nothing
end

# Skip a whole message block without knowing its schema.
function _skip_text_block!(lex::_TextLexer, close::Char)
    while true
        tok = _peek_token!(lex)
        if tok.kind === _TOK_EOF
            _text_error(lex, "unexpected end of input while skipping unknown field")
        elseif tok.kind === _TOK_PUNCT && tok.text == string(close)
            _next_token!(lex)
            return nothing
        elseif tok.kind === _TOK_IDENT
            _next_token!(lex)
            _skip_text_field_value!(lex)
            _consume_field_separator!(lex)
        elseif tok.kind === _TOK_PUNCT && tok.text == "["
            _next_token!(lex)
            _parse_text_bracket_name!(lex)
            _skip_text_field_value!(lex)
            _consume_field_separator!(lex)
        else
            _text_error(lex, "unexpected token '$(tok.text)' while skipping unknown field")
        end
    end
end
