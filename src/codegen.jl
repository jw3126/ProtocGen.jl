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
# like ".pkg.Outer.Inner". For Phase 4 we only handle types defined within the
# current FileDescriptorProto. Cross-file imports are deferred.
# Nested types are emitted at top level using `var"Outer.Inner"` to mirror the
# bootstrap convention.
# ----------------------------------------------------------------------------

struct LocalNames
    package::String              # e.g. "sample"; "" if no package
    messages::Set{String}        # fully-qualified names like ".sample.Outer.Inner"
    enums::Set{String}           # fully-qualified names like ".sample.MyEnum"
    jl_names::Dict{String,String}  # FQN -> Julia identifier ("Outer" or var"Outer.Inner")
    enum_defs::Dict{String,EnumDescriptorProto}  # FQN -> the enum's descriptor
end

function _gather_names(file::FileDescriptorProto)
    package = something(file.package, "")
    messages = Set{String}()
    enums = Set{String}()
    jl_names = Dict{String,String}()
    enum_defs = Dict{String,EnumDescriptorProto}()
    prefix = isempty(package) ? "" : ".$(package)"

    function visit_message(msg::DescriptorProto, parent_proto::String, parent_jl::String)
        proto_name = string(parent_proto, ".", something(msg.name, ""))
        jl_name = isempty(parent_jl) ? something(msg.name, "") : string(parent_jl, ".", something(msg.name, ""))
        push!(messages, proto_name)
        jl_names[proto_name] = jl_name
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
    return LocalNames(package, messages, enums, jl_names, enum_defs)
end

function _resolve_typename(type_name::String, names::LocalNames)
    haskey(names.jl_names, type_name) || error(
        "codegen: unresolved type reference $(type_name) " *
        "(cross-file imports are not supported in Phase 4)",
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

struct FieldModel
    proto_name::String          # snake_case as in .proto
    jl_fieldname::String        # Julia field name (escaped if needed)
    number::Int                 # field tag
    is_repeated::Bool
    is_message::Bool
    is_enum::Bool
    jl_type::String             # the type used in the struct field declaration
    elem_jl_type::String        # element type (drops Vector{} / Union{Nothing,})
    wire_annotation::String     # "" / "Val{:fixed}" / "Val{:zigzag}"
    init_value::String          # initializer used inside decode body
    default_value::String       # default exposed via PB.default_values
    encode_skip::String         # predicate used at encode-time to skip the field
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

    if is_message
        elem = _resolve_typename(something(field.type_name, ""), names)
        if is_repeated
            jl_type   = "Vector{$(elem)}"
            init_val  = "PB.BufferedVector{$(elem)}()"
            default   = "Vector{$(elem)}()"
            skip      = "!isempty(_x.$(jl_fieldname))"
        else
            jl_type   = "Union{Nothing,$(elem)}"
            init_val  = "Ref{Union{Nothing,$(elem)}}(nothing)"
            default   = "nothing"
            skip      = "!isnothing(_x.$(jl_fieldname))"
        end
        return FieldModel(proto_name, jl_fieldname, number, is_repeated, true, false,
                          jl_type, elem, "", init_val, default, skip)
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
            # value (numeric 0).
            jl_type  = elem_t
            init_val = "$(elem).$(_first_enum_member(field, names))"
            default  = init_val
            skip     = "_x.$(jl_fieldname) != $(default)"
        end
        return FieldModel(proto_name, jl_fieldname, number, is_repeated, false, true,
                          jl_type, elem_t, "", init_val, default, skip)
    else
        scalar_jl, wire = _scalar_jl_type_and_wire(ftype)
        if is_repeated
            jl_type   = "Vector{$(scalar_jl)}"
            init_val  = "PB.BufferedVector{$(scalar_jl)}()"
            default   = "Vector{$(scalar_jl)}()"
            skip      = "!isempty(_x.$(jl_fieldname))"
        else
            jl_type   = scalar_jl
            init_val  = _scalar_zero(scalar_jl)
            default   = init_val
            if scalar_jl == "String"
                skip = "!isempty(_x.$(jl_fieldname))"
            elseif scalar_jl == "Vector{UInt8}"
                skip = "!isempty(_x.$(jl_fieldname))"
            elseif scalar_jl == "Bool"
                skip = "_x.$(jl_fieldname) != false"
            else
                skip = "_x.$(jl_fieldname) != $(init_val)"
            end
        end
        return FieldModel(proto_name, jl_fieldname, number, is_repeated, false, false,
                          jl_type, scalar_jl, wire, init_val, default, skip)
    end
end

# Find the enum's zero-valued member. proto3 mandates a 0 value as the first
# entry; we look it up via LocalNames.enum_defs.
function _first_enum_member(field::FieldDescriptorProto, names::LocalNames)
    fqn = something(field.type_name, "")
    edef = get(names.enum_defs, fqn, nothing)
    edef === nothing && error(
        "codegen: enum $(fqn) not found in current file (cross-file imports " *
        "are not supported in Phase 4)",
    )
    for v in edef.value
        if Int(something(v.number, Int32(0))) == 0
            return something(v.name, "")
        end
    end
    return something(first(edef.value).name, "")
end

# ----------------------------------------------------------------------------
# Emitters.
# ----------------------------------------------------------------------------

function _emit_message(io::IO, msg::DescriptorProto, parent_jl::String, names::LocalNames)
    name = something(msg.name, "")
    jl_name_plain = isempty(parent_jl) ? name : string(parent_jl, ".", name)
    jl_name = occursin('.', jl_name_plain) ? "var\"$(jl_name_plain)\"" : jl_name_plain

    # Emit nested enums and nested messages first so they're defined before
    # this struct (which references them).
    for e in msg.enum_type
        _emit_enum(io, e, jl_name_plain)
    end
    for nested in msg.nested_type
        _emit_message(io, nested, jl_name_plain, names)
    end

    fields = [_model_field(f, names) for f in msg.field]

    # struct
    println(io, "struct ", jl_name)
    for f in fields
        println(io, "    ", f.jl_fieldname, "::", f.jl_type)
    end
    println(io, "end")

    # default_values + field_numbers metadata
    print(io, "PB.default_values(::Type{", jl_name, "}) = (;")
    print(io, join(("$(f.jl_fieldname) = $(f.default_value)" for f in fields), ", "))
    println(io, ")")
    print(io, "PB.field_numbers(::Type{", jl_name, "}) = (;")
    print(io, join(("$(f.jl_fieldname) = $(f.number)" for f in fields), ", "))
    println(io, ")")

    println(io)

    # decode. Parameters are underscore-prefixed so they can't collide with
    # proto field names (we've seen this fire when a field is literally named
    # `d` — a Float64 like Wide.d shadows the decoder otherwise).
    println(io, "function PB.decode(_d::PB.AbstractProtoDecoder, ::Type{<:", jl_name, "}, _endpos::Int=0, _group::Bool=false)")
    for f in fields
        println(io, "    ", f.jl_fieldname, " = ", f.init_value)
    end
    println(io, "    while !PB.message_done(_d, _endpos, _group)")
    println(io, "        field_number, wire_type = PB.decode_tag(_d)")
    first_branch = true
    for f in fields
        kw = first_branch ? "if" : "elseif"
        first_branch = false
        println(io, "        ", kw, " field_number == ", f.number)
        _emit_decode_field(io, f)
    end
    if !isempty(fields)
        println(io, "        else")
        println(io, "            Base.skip(_d, wire_type)")
        println(io, "        end")
    else
        println(io, "        Base.skip(_d, wire_type)")
    end
    println(io, "    end")
    print(io, "    return ", jl_name, "(")
    print(io, join(_decode_finalize.(fields), ", "))
    println(io, ")")
    println(io, "end")

    println(io)

    # encode
    println(io, "function PB.encode(_e::PB.AbstractProtoEncoder, _x::", jl_name, ")")
    println(io, "    initpos = position(_e.io)")
    for f in fields
        _emit_encode_field(io, f)
    end
    println(io, "    return position(_e.io) - initpos")
    println(io, "end")

    # _encoded_size
    println(io, "function PB._encoded_size(_x::", jl_name, ")")
    println(io, "    encoded_size = 0")
    for f in fields
        _emit_encoded_size_field(io, f)
    end
    println(io, "    return encoded_size")
    println(io, "end")

    println(io)
end

function _emit_decode_field(io::IO, f::FieldModel)
    if f.is_message
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
            if f.elem_jl_type in ("String", "Vector{UInt8}", "Bool", "Float32", "Float64")
                # The codec dispatches without wire-type for non-numeric repeated.
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
    if f.is_message
        return f.is_repeated ? "$(f.jl_fieldname)[]" : "$(f.jl_fieldname)[]"
    elseif f.is_repeated
        return "$(f.jl_fieldname)[]"
    else
        return f.jl_fieldname
    end
end

function _emit_encode_field(io::IO, f::FieldModel)
    args = isempty(f.wire_annotation) ? "" : ", $(f.wire_annotation)"
    println(io, "    ", f.encode_skip, " && PB.encode(_e, ", f.number, ", _x.", f.jl_fieldname, args, ")")
end

function _emit_encoded_size_field(io::IO, f::FieldModel)
    args = isempty(f.wire_annotation) ? "" : ", $(f.wire_annotation)"
    println(io, "    ", f.encode_skip, " && (encoded_size += PB._encoded_size(_x.", f.jl_fieldname, ", ", f.number, args, "))")
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
# tricks; that's deferred to Phase 5+.
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
        node in visiting && error("codegen: recursive message dependency at $(node) — Phase 4 doesn't handle cycles yet")
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
    println(io, "using ProtoBufDescriptors: OneOf")
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
