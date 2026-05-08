module Codegen

using ..ProtoBufDescriptors: ProtoBufDescriptors
using ..ProtoBufDescriptors.google.protobuf: FieldDescriptorProto, DescriptorProto,
    EnumDescriptorProto, FileDescriptorProto, var"FieldDescriptorProto.Label",
    var"FieldDescriptorProto.Type"

# ----------------------------------------------------------------------------
# Type translation. Each scalar proto type maps to (julia_type, wire_annotation).
# wire_annotation is the third positional argument we pass to decode/encode for
# non-default wire encodings ("", "Val{:fixed}", "Val{:zigzag}").
# ----------------------------------------------------------------------------

function _scalar_jl_type_and_wire(t)
    T = var"FieldDescriptorProto.Type"
    if t === T.TYPE_DOUBLE   ; return ("Float64",       "")
    elseif t === T.TYPE_FLOAT    ; return ("Float32",       "")
    elseif t === T.TYPE_INT64    ; return ("Int64",         "")
    elseif t === T.TYPE_UINT64   ; return ("UInt64",        "")
    elseif t === T.TYPE_INT32    ; return ("Int32",         "")
    elseif t === T.TYPE_FIXED64  ; return ("UInt64",        "Val{:fixed}")
    elseif t === T.TYPE_FIXED32  ; return ("UInt32",        "Val{:fixed}")
    elseif t === T.TYPE_BOOL     ; return ("Bool",          "")
    elseif t === T.TYPE_STRING   ; return ("String",        "")
    elseif t === T.TYPE_BYTES    ; return ("Vector{UInt8}", "")
    elseif t === T.TYPE_UINT32   ; return ("UInt32",        "")
    elseif t === T.TYPE_SFIXED32 ; return ("Int32",         "Val{:fixed}")
    elseif t === T.TYPE_SFIXED64 ; return ("Int64",         "Val{:fixed}")
    elseif t === T.TYPE_SINT32   ; return ("Int32",         "Val{:zigzag}")
    elseif t === T.TYPE_SINT64   ; return ("Int64",         "Val{:zigzag}")
    end
    error("scalar mapping not defined for $t")
end

function _is_scalar(t)
    T = var"FieldDescriptorProto.Type"
    return t !== T.TYPE_MESSAGE && t !== T.TYPE_GROUP && t !== T.TYPE_ENUM
end

function _scalar_zero(jl_type::String)
    if jl_type == "String"
        return "\"\""
    elseif jl_type == "Vector{UInt8}"
        return "UInt8[]"
    elseif jl_type == "Bool"
        return "false"
    else
        return "zero($(jl_type))"
    end
end

# ----------------------------------------------------------------------------
# Name resolution. The proto FieldDescriptorProto.type_name is fully qualified
# like ".pkg.Outer.Inner". We only handle types defined within the
# current FileDescriptorProto. Cross-file imports are deferred.
# Nested types are emitted at top level using `var"Outer.Inner"` to mirror the
# bootstrap convention.
# ----------------------------------------------------------------------------

Base.@kwdef struct LocalNames
    package::String              # e.g. "sample"; "" if no package
    syntax::String               # "proto2" or "proto3"
    messages::Set{String}        # fully-qualified names like ".sample.Outer.Inner"
    enums::Set{String}           # fully-qualified names like ".sample.MyEnum"
    jl_names::Dict{String,String}  # FQN -> Julia identifier ("Outer" or var"Outer.Inner")
    enum_defs::Dict{String,EnumDescriptorProto}  # FQN -> the enum's descriptor
    map_entries::Dict{String,DescriptorProto}    # FQN -> map_entry synthetic message
end

function _is_map_entry(msg::DescriptorProto)
    o = msg.options
    return o !== nothing && o.map_entry === true
end

function _gather_names(file::FileDescriptorProto)
    package = something(file.package, "")
    syntax = something(file.syntax, "proto2")
    messages = Set{String}()
    enums = Set{String}()
    jl_names = Dict{String,String}()
    enum_defs = Dict{String,EnumDescriptorProto}()
    map_entries = Dict{String,DescriptorProto}()
    prefix = isempty(package) ? "" : ".$(package)"

    function visit_message(msg::DescriptorProto, parent_proto::String, parent_jl::String)
        proto_name = string(parent_proto, ".", something(msg.name, ""))
        jl_name = isempty(parent_jl) ? something(msg.name, "") : string(parent_jl, ".", something(msg.name, ""))
        push!(messages, proto_name)
        jl_names[proto_name] = jl_name
        if _is_map_entry(msg)
            map_entries[proto_name] = msg
        end
        for nested in msg.nested_type
            visit_message(nested, proto_name, jl_name)
        end
        for e in msg.enum_type
            ename = something(e.name, "")
            efqn = string(proto_name, ".", ename)
            ejl = string(jl_name, ".", ename)
            push!(enums, efqn)
            jl_names[efqn] = ejl
            enum_defs[efqn] = e
        end
    end

    for msg in file.message_type
        visit_message(msg, prefix, "")
    end
    for e in file.enum_type
        ename = something(e.name, "")
        efqn = string(prefix, ".", ename)
        push!(enums, efqn)
        jl_names[efqn] = ename
        enum_defs[efqn] = e
    end
    return LocalNames(;
        package,
        syntax,
        messages,
        enums,
        jl_names,
        enum_defs,
        map_entries,
    )
end

function _resolve_typename(type_name::String, names::LocalNames)
    haskey(names.jl_names, type_name) || error(
        "codegen: unresolved type reference $(type_name) " *
        "(cross-file imports are not yet supported)",
    )
    jl = names.jl_names[type_name]
    # `Foo` stays as-is; `Foo.Bar` needs var"Foo.Bar" because the dot is not a
    # legal identifier character. The bootstrap follows the same convention.
    return occursin('.', jl) ? "var\"$(jl)\"" : jl
end

# ----------------------------------------------------------------------------
# Field model. We compute everything once up front so the emitters are simple
# string-building.
# ----------------------------------------------------------------------------

Base.@kwdef struct FieldModel
    proto_name::String          # snake_case as in .proto
    jl_fieldname::String        # Julia field name (escaped if needed)
    number::Int                 # field tag
    is_repeated::Bool = false
    is_message::Bool = false
    is_enum::Bool = false
    is_map::Bool = false        # `map<K,V>` — emitted as `OrderedDict{K,V}`
    is_required::Bool = false   # proto2 `required`
    is_packed::Bool = false     # repeated scalar/enum encoded packed (LENGTH_DELIMITED)
    emit_unpacked_loop::Bool = false  # encode emits per-element loop (proto2 default
                                #   for repeated scalar/enum, or [packed = false])
    jl_type::String             # the type used in the struct field declaration
    elem_jl_type::String        # element type (drops Vector{} / Union{Nothing,})
    wire_annotation::String = "" # "" / "Val{:fixed}" / "Val{:zigzag}"
    init_value::String          # initializer used inside decode body
    default_value::String       # default exposed via PB.default_values
    encode_skip::String         # predicate used at encode-time to skip the field
end

# proto2: repeated scalars/enums are unpacked unless `[packed = true]` is set.
# proto3: same fields are packed unless `[packed = false]` is set. The decoder
# accepts either wire form regardless; this only affects encode emission, and
# matters for byte-equality against protoc.
function _is_packed_repeated(field::FieldDescriptorProto, syntax::String)
    opts = field.options
    if opts !== nothing && opts.packed !== nothing
        return opts.packed
    end
    return syntax == "proto3"
end

function _jl_fieldname(name::String)
    # Julia keywords the proto schema actually uses are rare. The descriptor
    # bootstrap shows the convention: `type` → `var"#type"`. Apply the same
    # mangling for any keyword we hit.
    KEYWORDS = ("begin","while","if","for","try","return","break","continue",
                "function","macro","quote","let","local","global","const",
                "do","struct","module","baremodule","using","import","export",
                "end","else","elseif","catch","finally","true","false","type")
    return name in KEYWORDS ? "var\"#$(name)\"" : name
end

function _model_field(field::FieldDescriptorProto, names::LocalNames)
    L = var"FieldDescriptorProto.Label"
    T = var"FieldDescriptorProto.Type"

    proto_name = something(field.name, "")
    jl_fieldname = _jl_fieldname(proto_name)
    number = Int(something(field.number, Int32(0)))
    label = field.label
    ftype = getfield(field, Symbol("#type"))
    is_repeated = label === L.LABEL_REPEATED
    is_message = ftype === T.TYPE_MESSAGE
    is_enum = ftype === T.TYPE_ENUM
    is_required = label === L.LABEL_REQUIRED  # only legal in proto2

    if is_message
        ref_name = something(field.type_name, "")
        # Maps are sugar over `repeated <synthetic>Entry` where the entry has
        # `options.map_entry = true`. Surface the field as
        # `OrderedDict{K,V}` (insertion-order preserving) so re-encode is
        # byte-identical to the wire input. Codec dispatch is on
        # `AbstractDict{K,V}` so OrderedDict flows through the same paths
        # as the plain Dict.
        if is_repeated && haskey(names.map_entries, ref_name)
            entry = names.map_entries[ref_name]
            kv = _map_entry_kv(entry, names)
            jl_type  = "OrderedDict{$(kv.key_type),$(kv.val_type)}"
            init_val = "OrderedDict{$(kv.key_type),$(kv.val_type)}()"
            default  = "OrderedDict{$(kv.key_type),$(kv.val_type)}()"
            skip     = "!isempty(_x.$(jl_fieldname))"
            wire = if kv.key_wire == "Nothing" && kv.val_wire == "Nothing"
                # Both default — codec uses the unannotated `decode!(d, ::Dict)`
                # / `encode(e, i, ::Dict)` dispatch.
                ""
            else
                "Val{Tuple{$(kv.key_wire),$(kv.val_wire)}}"
            end
            return FieldModel(;
                proto_name,
                jl_fieldname,
                number,
                is_repeated = true,
                is_map = true,
                jl_type,
                elem_jl_type = jl_type,
                wire_annotation = wire,
                init_value = init_val,
                default_value = default,
                encode_skip = skip,
            )
        end
        elem = _resolve_typename(ref_name, names)
        if is_repeated
            jl_type   = "Vector{$(elem)}"
            init_val  = "PB.BufferedVector{$(elem)}()"
            default   = "Vector{$(elem)}()"
            skip      = "!isempty(_x.$(jl_fieldname))"
        elseif is_required
            # proto2 required submessage. Field is non-nullable; the decode
            # body initializes a Ref{T}() (uninitialized) and validates that
            # it was actually set.
            jl_type  = elem
            init_val = "Ref{$(elem)}()"
            default  = "Ref{$(elem)}()"
            skip     = "true"
        else
            jl_type   = "Union{Nothing,$(elem)}"
            init_val  = "Ref{Union{Nothing,$(elem)}}(nothing)"
            default   = "nothing"
            skip      = "!isnothing(_x.$(jl_fieldname))"
        end
        return FieldModel(;
            proto_name,
            jl_fieldname,
            number,
            is_repeated,
            is_message = true,
            is_required,
            jl_type,
            elem_jl_type = elem,
            init_value = init_val,
            default_value = default,
            encode_skip = skip,
        )
    elseif is_enum
        elem = _resolve_typename(something(field.type_name, ""), names)
        elem_t = "$(elem).T"
        if is_repeated
            jl_type  = "Vector{$(elem_t)}"
            init_val = "PB.BufferedVector{$(elem_t)}()"
            default  = "Vector{$(elem_t)}()"
            skip     = "!isempty(_x.$(jl_fieldname))"
        else
            # No presence on a bare proto3 enum — defaults to the first enum
            # value (numeric 0). proto2 required enums encode unconditionally.
            jl_type  = elem_t
            init_val = "$(elem).$(_first_enum_member(field, names))"
            default  = init_val
            skip     = is_required ? "true" : "_x.$(jl_fieldname) != $(default)"
        end
        is_packed = is_repeated && _is_packed_repeated(field, names.syntax)
        return FieldModel(;
            proto_name,
            jl_fieldname,
            number,
            is_repeated,
            is_enum = true,
            is_required,
            is_packed,
            emit_unpacked_loop = is_repeated && !is_packed,
            jl_type,
            elem_jl_type = elem_t,
            init_value = init_val,
            default_value = default,
            encode_skip = skip,
        )
    else
        scalar_jl, wire = _scalar_jl_type_and_wire(ftype)
        if is_repeated
            jl_type   = "Vector{$(scalar_jl)}"
            init_val  = "PB.BufferedVector{$(scalar_jl)}()"
            default   = "Vector{$(scalar_jl)}()"
            skip      = "!isempty(_x.$(jl_fieldname))"
        elseif _wants_scalar_presence(field, names)
            # Phase 5/6: proto3 explicit `optional` and proto2 `optional`
            # carry presence. Surface that in Julia by typing the field as
            # `Union{Nothing,T}` defaulted to `nothing`. The decode path
            # overwrites `nothing` on tag, the encode path skips iff
            # `nothing`. As a result an explicit-optional scalar set to zero
            # round-trips correctly — the value travels on the wire and unset
            # ≠ default-zero.
            jl_type  = "Union{Nothing,$(scalar_jl)}"
            init_val = "nothing"
            default  = "nothing"
            skip     = "!isnothing(_x.$(jl_fieldname))"
        else
            jl_type   = scalar_jl
            init_val  = _scalar_zero(scalar_jl)
            default   = init_val
            if is_required
                skip = "true"
            elseif scalar_jl == "String"
                skip = "!isempty(_x.$(jl_fieldname))"
            elseif scalar_jl == "Vector{UInt8}"
                skip = "!isempty(_x.$(jl_fieldname))"
            elseif scalar_jl == "Bool"
                skip = "_x.$(jl_fieldname) != false"
            else
                skip = "_x.$(jl_fieldname) != $(init_val)"
            end
        end
        # Packed-vs-unpacked only applies to repeated numeric scalars and
        # bool. String/bytes are length-delimited per element regardless;
        # the existing Vector{String}/Vector{Vector{UInt8}} codec methods
        # iterate them. So `emit_unpacked_loop` stays false for those
        # element types — the codec call handles the loop internally.
        is_packed_eligible =
            is_repeated && !(scalar_jl == "String" || scalar_jl == "Vector{UInt8}")
        is_packed = is_packed_eligible && _is_packed_repeated(field, names.syntax)
        return FieldModel(;
            proto_name,
            jl_fieldname,
            number,
            is_repeated,
            is_required,
            is_packed,
            emit_unpacked_loop = is_packed_eligible && !is_packed,
            jl_type,
            elem_jl_type = scalar_jl,
            wire_annotation = wire,
            init_value = init_val,
            default_value = default,
            encode_skip = skip,
        )
    end
end

# Whether this scalar field carries explicit presence semantics:
# - proto3 explicit `optional`: `proto3_optional == true` on the descriptor
#   plus a synthetic oneof; we ignore the oneof (descriptor scaffolding)
#   and key on the bool.
# - proto2 `optional`: every proto2 field has an explicit label, and the
#   spec requires presence tracking for `optional`.
# In both cases the field stays on the regular field list (it's not a real
# oneof member) and we just emit `Union{Nothing,T}`.
function _wants_scalar_presence(field::FieldDescriptorProto, names::LocalNames)
    L = var"FieldDescriptorProto.Label"
    field.proto3_optional === true && return true
    if names.syntax == "proto2"
        return field.label === L.LABEL_OPTIONAL
    end
    return false
end

# Resolve a single field's type to a Julia type string, used for map key/
# value lookup. Mirrors the type-mapping logic of _model_field but without
# the per-field-shape decoration (no Vector, no Union).
function _resolve_field_jl_type(field::FieldDescriptorProto, names::LocalNames)
    T = var"FieldDescriptorProto.Type"
    ftype = getfield(field, Symbol("#type"))
    if ftype === T.TYPE_MESSAGE
        return _resolve_typename(something(field.type_name, ""), names)
    elseif ftype === T.TYPE_ENUM
        return string(_resolve_typename(something(field.type_name, ""), names), ".T")
    else
        scalar_jl, _ = _scalar_jl_type_and_wire(ftype)
        return scalar_jl
    end
end

# For maps the codec dispatches on `Val{Tuple{KAnnot,VAnnot}}` where each
# annotation is a bare Symbol (`:fixed`, `:zigzag`) or `Nothing` — different
# from the per-field `wire_annotation` for non-map scalars, which spells the
# full `Val{:fixed}` form. See codec/decode.jl:58–98 / encode.jl:150–187.
function _map_wire_annot(field::FieldDescriptorProto)
    T = var"FieldDescriptorProto.Type"
    ftype = getfield(field, Symbol("#type"))
    if ftype === T.TYPE_FIXED32  || ftype === T.TYPE_FIXED64 ||
       ftype === T.TYPE_SFIXED32 || ftype === T.TYPE_SFIXED64
        return ":fixed"
    elseif ftype === T.TYPE_SINT32 || ftype === T.TYPE_SINT64
        return ":zigzag"
    end
    return "Nothing"
end

function _map_entry_kv(entry::DescriptorProto, names::LocalNames)
    key_field = nothing
    val_field = nothing
    for f in entry.field
        n = Int(something(f.number, Int32(0)))
        if n == 1
            key_field = f
        elseif n == 2
            val_field = f
        end
    end
    key_field === nothing && error("codegen: map_entry $(something(entry.name, "")) missing key field 1")
    val_field === nothing && error("codegen: map_entry $(something(entry.name, "")) missing value field 2")
    return (
        key_type = _resolve_field_jl_type(key_field, names),
        val_type = _resolve_field_jl_type(val_field, names),
        key_wire = _map_wire_annot(key_field),
        val_wire = _map_wire_annot(val_field),
    )
end

# Find the enum's zero-valued member. proto3 mandates a 0 value as the first
# entry; we look it up via LocalNames.enum_defs.
function _first_enum_member(field::FieldDescriptorProto, names::LocalNames)
    fqn = something(field.type_name, "")
    edef = get(names.enum_defs, fqn, nothing)
    edef === nothing && error(
        "codegen: enum $(fqn) not found in current file " *
        "(cross-file imports are not yet supported)",
    )
    for v in edef.value
        if Int(something(v.number, Int32(0))) == 0
            return something(v.name, "")
        end
    end
    return something(first(edef.value).name, "")
end

# ----------------------------------------------------------------------------
# Per-message layout. Real oneofs (non-synthetic) collapse multiple proto
# fields into a single Julia struct field of type
# `Union{Nothing, OneOf{<:Union{T1, T2, ...}}}`. Synthetic oneofs (proto3
# `optional` scaffolding) are descriptor-only — their member field stays a
# plain Phase-5 `Union{Nothing,T}`.
# ----------------------------------------------------------------------------

Base.@kwdef struct OneofModel
    proto_name::String
    jl_fieldname::String
    members::Vector{FieldModel}
end

# An oneof_decl is synthetic iff exactly one field references it AND that
# field has proto3_optional=true. We detect this from the field list (not
# the oneof_decl, which doesn't carry that information directly).
function _synthetic_oneof_indices(msg::DescriptorProto)
    counts = Dict{Int,Int}()
    p3_opt_in = Dict{Int,Bool}()
    for f in msg.field
        idx = f.oneof_index
        idx === nothing && continue
        i = Int(idx)
        counts[i] = get(counts, i, 0) + 1
        if f.proto3_optional === true
            p3_opt_in[i] = true
        end
    end
    out = Set{Int}()
    for (i, c) in counts
        if c == 1 && get(p3_opt_in, i, false)
            push!(out, i)
        end
    end
    return out
end

# Group real-oneof members by oneof_index.
function _build_oneofs(msg::DescriptorProto, names::LocalNames, synthetic::Set{Int})
    members_by_idx = Dict{Int,Vector{FieldModel}}()
    for f in msg.field
        idx = f.oneof_index
        idx === nothing && continue
        i = Int(idx)
        i in synthetic && continue
        push!(get!(members_by_idx, i, FieldModel[]), _model_field(f, names))
    end
    oneofs = OneofModel[]
    for (i, decl) in pairs(msg.oneof_decl)
        # `pairs` over a Vector is 1-indexed; oneof_index is 0-indexed.
        idx0 = i - 1
        idx0 in synthetic && continue
        haskey(members_by_idx, idx0) || continue
        oname = something(decl.name, "")
        push!(oneofs, OneofModel(;
            proto_name = oname,
            jl_fieldname = _jl_fieldname(oname),
            members = members_by_idx[idx0],
        ))
    end
    return oneofs
end

# ----------------------------------------------------------------------------
# Emitters.
# ----------------------------------------------------------------------------

function _emit_message(io::IO, msg::DescriptorProto, parent_jl::String, names::LocalNames)
    name = something(msg.name, "")
    jl_name_plain = isempty(parent_jl) ? name : string(parent_jl, ".", name)
    jl_name = occursin('.', jl_name_plain) ? "var\"$(jl_name_plain)\"" : jl_name_plain

    # Emit nested enums and nested messages first so they're defined before
    # this struct (which references them). Skip synthetic map_entry messages —
    # those are surfaced as `OrderedDict{K,V}` on the parent field, never as a
    # standalone Julia struct.
    for e in msg.enum_type
        _emit_enum(io, e, jl_name_plain)
    end
    for nested in msg.nested_type
        _is_map_entry(nested) && continue
        _emit_message(io, nested, jl_name_plain, names)
    end

    synthetic = _synthetic_oneof_indices(msg)
    real_oneofs = _build_oneofs(msg, names, synthetic)
    plain_fields = FieldModel[]
    for f in msg.field
        idx = f.oneof_index
        if idx !== nothing && !(Int(idx) in synthetic)
            # real-oneof member — folded into the OneofModel, not a plain field.
            continue
        end
        push!(plain_fields, _model_field(f, names))
    end

    # struct: plain fields + one slot per real oneof.
    println(io, "struct ", jl_name)
    for f in plain_fields
        println(io, "    ", f.jl_fieldname, "::", f.jl_type)
    end
    for o in real_oneofs
        println(io, "    ", o.jl_fieldname, "::", _oneof_jl_type(o))
    end
    println(io, "end")

    # Metadata.
    print(io, "PB.default_values(::Type{", jl_name, "}) = (;")
    pieces = String[]
    for f in plain_fields
        push!(pieces, "$(f.jl_fieldname) = $(f.default_value)")
    end
    for o in real_oneofs
        push!(pieces, "$(o.jl_fieldname) = nothing")
    end
    print(io, join(pieces, ", "))
    println(io, ")")

    print(io, "PB.field_numbers(::Type{", jl_name, "}) = (;")
    pieces = String[]
    for f in plain_fields
        push!(pieces, "$(f.jl_fieldname) = $(f.number)")
    end
    for o in real_oneofs
        for m in o.members
            push!(pieces, "$(m.jl_fieldname) = $(m.number)")
        end
    end
    print(io, join(pieces, ", "))
    println(io, ")")

    if !isempty(real_oneofs)
        print(io, "PB.oneof_field_types(::Type{", jl_name, "}) = (;")
        oneof_pieces = String[]
        for o in real_oneofs
            inner = join(("$(m.jl_fieldname) = $(m.elem_jl_type)" for m in o.members), ", ")
            push!(oneof_pieces, "$(o.jl_fieldname) = (;$(inner))")
        end
        print(io, join(oneof_pieces, ", "))
        println(io, ")")
    end

    _emit_reserved_fields(io, jl_name, msg)

    println(io)

    # decode.
    println(io, "function PB.decode(_d::PB.AbstractProtoDecoder, ::Type{<:", jl_name, "}, _endpos::Int=0, _group::Bool=false)")
    for f in plain_fields
        println(io, "    ", f.jl_fieldname, " = ", f.init_value)
        if f.is_required
            println(io, "    _saw_", f.jl_fieldname, " = false")
        end
    end
    for o in real_oneofs
        println(io, "    ", o.jl_fieldname, "::", _oneof_jl_type(o), " = nothing")
    end
    println(io, "    while !PB.message_done(_d, _endpos, _group)")
    println(io, "        field_number, wire_type = PB.decode_tag(_d)")
    first_branch = true
    for f in plain_fields
        kw = first_branch ? "if" : "elseif"
        first_branch = false
        println(io, "        ", kw, " field_number == ", f.number)
        _emit_decode_field(io, f)
        if f.is_required
            println(io, "            _saw_", f.jl_fieldname, " = true")
        end
    end
    for o in real_oneofs
        for m in o.members
            kw = first_branch ? "if" : "elseif"
            first_branch = false
            println(io, "        ", kw, " field_number == ", m.number)
            _emit_decode_oneof_member(io, o, m)
        end
    end
    if first_branch
        # No fields at all.
        println(io, "        Base.skip(_d, wire_type)")
    else
        println(io, "        else")
        println(io, "            Base.skip(_d, wire_type)")
        println(io, "        end")
    end
    println(io, "    end")

    # proto2 `required` validation. Emit a clear `DecodeError` per missing
    # field rather than letting the implicit `Ref{T}()[]` access throw a
    # generic UndefRefError, or letting a zero-defaulted scalar slip through.
    for f in plain_fields
        if f.is_required
            qname = repr(f.proto_name)
            println(io, "    _saw_", f.jl_fieldname,
                    " || throw(PB.DecodeError(\"required field \" * ", qname,
                    " * \" missing\"))")
        end
    end

    print(io, "    return ", jl_name, "(")
    arg_parts = String[]
    for f in plain_fields
        push!(arg_parts, _decode_finalize(f))
    end
    for o in real_oneofs
        push!(arg_parts, o.jl_fieldname)
    end
    print(io, join(arg_parts, ", "))
    println(io, ")")
    println(io, "end")

    println(io)

    # encode + _encoded_size emit fields in field-number order so the
    # output matches protoc byte-for-byte. proto-source order ≠
    # number order whenever maps or out-of-order field numbers appear,
    # and protoc encodes by tag number. Each oneof member becomes its own
    # check at its own number; only one fires, so the cost is the same as
    # the old chained if/elseif.
    encode_plan = Tuple{Int,Function,Function}[]  # (number, encode!, sized!)
    for f in plain_fields
        push!(encode_plan, (f.number,
            io_ -> _emit_encode_field(io_, f),
            io_ -> _emit_encoded_size_field(io_, f)))
    end
    for o in real_oneofs, m in o.members
        push!(encode_plan, (m.number,
            io_ -> _emit_encode_oneof_member(io_, o, m),
            io_ -> _emit_encoded_size_oneof_member(io_, o, m)))
    end
    sort!(encode_plan; by = first)

    println(io, "function PB.encode(_e::PB.AbstractProtoEncoder, _x::", jl_name, ")")
    println(io, "    initpos = position(_e.io)")
    for (_, emit_e, _) in encode_plan
        emit_e(io)
    end
    println(io, "    return position(_e.io) - initpos")
    println(io, "end")

    println(io, "function PB._encoded_size(_x::", jl_name, ")")
    println(io, "    encoded_size = 0")
    for (_, _, emit_s) in encode_plan
        emit_s(io)
    end
    println(io, "    return encoded_size")
    println(io, "end")

    println(io)
end

function _oneof_jl_type(o::OneofModel)
    elem_union = join((m.elem_jl_type for m in o.members), ",")
    return "Union{Nothing,OneOf{<:Union{$(elem_union)}}}"
end

function _emit_decode_oneof_member(io::IO, o::OneofModel, m::FieldModel)
    # Decode the value into a temporary, then wrap in OneOf.
    if m.is_message
        # OneOf members can be submessages — decode into a Ref, unwrap, wrap.
        elem = m.elem_jl_type
        println(io, "            _v = Ref{Union{Nothing,$(elem)}}(nothing)")
        println(io, "            PB.decode!(_d, _v)")
        println(io, "            ", o.jl_fieldname, " = OneOf(:", m.jl_fieldname, ", _v[]::", elem, ")")
    elseif m.is_enum
        println(io, "            ", o.jl_fieldname, " = OneOf(:", m.jl_fieldname, ", PB.decode(_d, ", m.elem_jl_type, "))")
    else
        if !isempty(m.wire_annotation)
            println(io, "            ", o.jl_fieldname, " = OneOf(:", m.jl_fieldname, ", PB.decode(_d, ", m.elem_jl_type, ", ", m.wire_annotation, "))")
        else
            println(io, "            ", o.jl_fieldname, " = OneOf(:", m.jl_fieldname, ", PB.decode(_d, ", m.elem_jl_type, "))")
        end
    end
end

# Wraps a one-line emission body in the `if !isnothing(_o) && _o.name ===
# :member` guard that fires only when this member of the oneof is active.
function _emit_oneof_member_guarded(io::IO, o::OneofModel, m::FieldModel, body::AbstractString)
    println(io, "    let _o = _x.", o.jl_fieldname)
    println(io, "        if !isnothing(_o) && _o.name === :", m.jl_fieldname)
    println(io, "            ", body)
    println(io, "        end")
    println(io, "    end")
end

function _emit_encode_oneof_member(io::IO, o::OneofModel, m::FieldModel)
    args = isempty(m.wire_annotation) ? "" : ", $(m.wire_annotation)"
    _emit_oneof_member_guarded(io, o, m, "PB.encode(_e, $(m.number), _o.value$(args))")
end

function _emit_encoded_size_oneof_member(io::IO, o::OneofModel, m::FieldModel)
    args = isempty(m.wire_annotation) ? "" : ", $(m.wire_annotation)"
    _emit_oneof_member_guarded(io, o, m, "encoded_size += PB._encoded_size(_o.value, $(m.number)$(args))")
end

function _emit_decode_field(io::IO, f::FieldModel)
    if f.is_map
        # Codec dispatch: `decode!(d, dict[, Val{Tuple{KAnnot,VAnnot}}])` reads
        # one entry off the wire and inserts (k, v). The optional 3rd arg is
        # only emitted when at least one of K/V uses fixed/zigzag wire format.
        if isempty(f.wire_annotation)
            println(io, "            PB.decode!(_d, ", f.jl_fieldname, ")")
        else
            println(io, "            PB.decode!(_d, ", f.jl_fieldname, ", ", f.wire_annotation, ")")
        end
    elseif f.is_message
        if f.is_repeated
            println(io, "            PB.decode!(_d, ", f.jl_fieldname, ")")
        else
            println(io, "            PB.decode!(_d, ", f.jl_fieldname, ")")
        end
    elseif f.is_enum
        if f.is_repeated
            println(io, "            PB.decode!(_d, wire_type, ", f.jl_fieldname, ")")
        else
            println(io, "            ", f.jl_fieldname, " = PB.decode(_d, ", f.elem_jl_type, ")")
        end
    else
        if f.is_repeated
            if f.elem_jl_type in ("String", "Vector{UInt8}")
                # Strings and bytes have no-wire-type BufferedVector decoders
                # (decode.jl:107, 120). Bool/Float32/Float64 do *not* — they
                # need the wire-type so the codec can switch between packed
                # (LENGTH_DELIMITED) and unpacked (decode.jl:174).
                println(io, "            PB.decode!(_d, ", f.jl_fieldname, ")")
            elseif !isempty(f.wire_annotation)
                println(io, "            PB.decode!(_d, wire_type, ", f.jl_fieldname, ", ", f.wire_annotation, ")")
            else
                println(io, "            PB.decode!(_d, wire_type, ", f.jl_fieldname, ")")
            end
        else
            if !isempty(f.wire_annotation)
                println(io, "            ", f.jl_fieldname, " = PB.decode(_d, ", f.elem_jl_type, ", ", f.wire_annotation, ")")
            else
                println(io, "            ", f.jl_fieldname, " = PB.decode(_d, ", f.elem_jl_type, ")")
            end
        end
    end
end

function _decode_finalize(f::FieldModel)
    if f.is_map
        # `dict` is a real Dict the codec mutates in place; pass through.
        return f.jl_fieldname
    elseif f.is_message
        return f.is_repeated ? "$(f.jl_fieldname)[]" : "$(f.jl_fieldname)[]"
    elseif f.is_repeated
        return "$(f.jl_fieldname)[]"
    else
        return f.jl_fieldname
    end
end

# Emit `PB.reserved_fields(::Type{T}) = (names = [...], numbers = [...])`
# when the proto says `reserved 1000 to 9999;` or `reserved "foo";`. Only
# emitted when the message actually has reserved entries — otherwise the
# package-level fallback returns the empty default. `DescriptorProto.
# ReservedRange.end` is exclusive on the wire (so `reserved 1000 to 9999`
# decodes to start=1000, end=10000); we collapse single-number ranges to
# bare `Int` and multi-number ranges to `UnitRange{Int}` to match the
# bootstrap's metadata shape.
function _emit_reserved_fields(io::IO, jl_name::String, msg::DescriptorProto)
    ranges = msg.reserved_range
    names = msg.reserved_name
    isempty(ranges) && isempty(names) && return

    range_pieces = String[]
    for r in ranges
        s = Int(something(r.start, Int32(0)))
        e = Int(something(getfield(r, Symbol("#end")), Int32(0)))
        push!(range_pieces, e - s == 1 ? string(s) : string(s, ":", e - 1))
    end
    range_str = isempty(range_pieces) ?
        "Union{Int,UnitRange{Int}}[]" :
        string("Union{Int,UnitRange{Int}}[", join(range_pieces, ", "), "]")

    name_str = isempty(names) ?
        "String[]" :
        string("[", join(("\"$(n)\"" for n in names), ", "), "]")

    println(io, "PB.reserved_fields(::Type{", jl_name, "}) = (names = ", name_str, ", numbers = ", range_str, ")")
end

function _emit_encode_field(io::IO, f::FieldModel)
    args = isempty(f.wire_annotation) ? "" : ", $(f.wire_annotation)"
    if f.emit_unpacked_loop
        # Unpacked repeated scalar/enum: protoc emits one tag-value pair
        # per element (proto2 default, or proto3 with [packed = false]).
        # Emit per-element so the singular scalar encode paths apply.
        println(io, "    if !isempty(_x.", f.jl_fieldname, ")")
        println(io, "        for _v in _x.", f.jl_fieldname)
        println(io, "            PB.encode(_e, ", f.number, ", _v", args, ")")
        println(io, "        end")
        println(io, "    end")
    else
        println(io, "    ", f.encode_skip, " && PB.encode(_e, ", f.number, ", _x.", f.jl_fieldname, args, ")")
    end
end

function _emit_encoded_size_field(io::IO, f::FieldModel)
    args = isempty(f.wire_annotation) ? "" : ", $(f.wire_annotation)"
    if f.emit_unpacked_loop
        println(io, "    if !isempty(_x.", f.jl_fieldname, ")")
        println(io, "        for _v in _x.", f.jl_fieldname)
        println(io, "            encoded_size += PB._encoded_size(_v, ", f.number, args, ")")
        println(io, "        end")
        println(io, "    end")
    else
        println(io, "    ", f.encode_skip, " && (encoded_size += PB._encoded_size(_x.", f.jl_fieldname, ", ", f.number, args, "))")
    end
end

function _emit_enum(io::IO, e::EnumDescriptorProto, parent_jl::String)
    name = something(e.name, "")
    jl_name_plain = isempty(parent_jl) ? name : string(parent_jl, ".", name)
    jl_name = occursin('.', jl_name_plain) ? "var\"$(jl_name_plain)\"" : jl_name_plain
    members = join((string(something(v.name, ""), "=", Int(something(v.number, Int32(0)))) for v in e.value), " ")
    println(io, "@enumx ", jl_name, " ", members)
    println(io)
end

# ----------------------------------------------------------------------------
# Topological sort. A message's struct depends on the types of its fields.
# Within one file we may need to reorder the messages so referenced types are
# defined first. proto allows recursive messages (Foo containing a Foo) — in
# Julia this works fine for `Union{Nothing,Foo}` references because it only
# needs the type name, but for `Vector{Foo}` we also need Foo's name to exist.
# We just emit forward declarations of structs by emitting them in topological
# order. Cycles are not yet supported — they'd need `mutable struct` or other
# tricks; deferred until needed.
# ----------------------------------------------------------------------------

function _toplevel_message_deps(msg::DescriptorProto, names::LocalNames)
    deps = Set{String}()
    function visit(m::DescriptorProto)
        for f in m.field
            ftype = getfield(f, Symbol("#type"))
            if ftype === var"FieldDescriptorProto.Type".TYPE_MESSAGE
                tn = something(f.type_name, "")
                # Only count deps that resolve to a top-level message in this
                # file (not the message itself, not nested types of itself).
                if tn in names.messages
                    push!(deps, tn)
                end
            end
        end
        for nested in m.nested_type
            visit(nested)
        end
    end
    visit(msg)
    return deps
end

function _topo_sort(file::FileDescriptorProto, names::LocalNames)
    package = something(file.package, "")
    prefix = isempty(package) ? "" : ".$(package)"

    by_fqn = Dict{String,DescriptorProto}()
    order = String[]
    for msg in file.message_type
        fqn = string(prefix, ".", something(msg.name, ""))
        by_fqn[fqn] = msg
        push!(order, fqn)
    end

    deps = Dict(fqn => filter(d -> d != fqn && d in keys(by_fqn),
                              _toplevel_message_deps(by_fqn[fqn], names))
                for fqn in order)

    sorted = String[]
    visiting = Set{String}()
    visited = Set{String}()

    function dfs(node)
        node in visited && return
        node in visiting && error("codegen: recursive message dependency at $(node) — cycles are not yet supported")
        push!(visiting, node)
        for d in deps[node]
            dfs(d)
        end
        delete!(visiting, node)
        push!(visited, node)
        push!(sorted, node)
    end

    for fqn in order
        dfs(fqn)
    end
    return [by_fqn[fqn] for fqn in sorted]
end

# ----------------------------------------------------------------------------
# File emission.
# ----------------------------------------------------------------------------

function codegen(file::FileDescriptorProto)
    names = _gather_names(file)
    io = IOBuffer()
    proto_name = something(file.name, "<unknown>")
    syntax = something(file.syntax, "proto2")
    println(io, "# Generated by ProtoBufDescriptors. Do not edit.")
    println(io, "# source: ", proto_name, " (", syntax, " syntax)")
    println(io)
    println(io, "import ProtoBufDescriptors as PB")
    println(io, "using ProtoBufDescriptors: OneOf, OrderedDict")
    println(io, "using ProtoBufDescriptors.EnumX: @enumx")
    println(io)

    for e in file.enum_type
        _emit_enum(io, e, "")
    end
    for msg in _topo_sort(file, names)
        _emit_message(io, msg, "", names)
    end

    return String(take!(io))
end

end # module Codegen
