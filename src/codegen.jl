module Codegen

using ..ProtocGen: ProtocGen
using ..ProtocGen.google.protobuf: FieldDescriptorProto, DescriptorProto,
    EnumDescriptorProto, FileDescriptorProto, var"FieldDescriptorProto.Label",
    var"FieldDescriptorProto.Type"

# ----------------------------------------------------------------------------
# `[batteries]` / `[enumbatteries]` config table → `@batteries` macro call
# kwargs. Each entry becomes `key=<julia repr of value>`. `repr` handles
# the bool / number / string variants TOML can produce; nested tables
# would round-trip as `Dict(...)` literals (currently no @batteries
# option needs that, but the helper is type-agnostic).
# ----------------------------------------------------------------------------
function _config_kw_table(config::AbstractDict, table::AbstractString)
    haskey(config, table) || return ""
    inner = config[table]
    inner isa AbstractDict || return ""
    isempty(inner) && return ""
    parts = String[]
    for (k, v) in pairs(inner)
        push!(parts, "$(k)=$(repr(v))")
    end
    return join(parts, " ")
end

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
# like ".pkg.Outer.Inner". A `Universe` collects FQN→jl_name mappings across
# all input files (every entry in CodeGeneratorRequest.proto_file), so a
# cross-file reference resolves the same way as a local one — the codegen
# emitters never need to know whether a referenced type was defined in
# `file` or in one of `file`'s imports. `LocalNames` is a per-file view that
# pairs the universe with the current file's syntax and package; everything
# but `package` and `syntax` is a shared reference.
# Nested types are emitted at top level using `var"Outer.Inner"` to mirror
# the bootstrap convention.
# ----------------------------------------------------------------------------

Base.@kwdef struct Universe
    messages::Set{String}        # fully-qualified names like ".sample.Outer.Inner"
    enums::Set{String}           # fully-qualified names like ".sample.MyEnum"
    jl_names::Dict{String,String}  # FQN -> Julia identifier ("Outer" or var"Outer.Inner")
    enum_defs::Dict{String,EnumDescriptorProto}  # FQN -> the enum's descriptor
    map_entries::Dict{String,DescriptorProto}    # FQN -> map_entry synthetic message
    package_of::Dict{String,String}              # FQN -> proto package ("google.protobuf")
end

# Map from proto package name to Julia module path. Cross-package references
# in generated code are emitted as `<alias>.<TypeName>` and the file head
# carries `import <julia_module> as <alias>` per package, where <alias> is
# the package name with dots → underscores. The WKT entry is hardcoded;
# real users with multi-package proto trees will eventually configure this
# via a plugin parameter (Phase 7c+ / Phase 11).
const WKT_PACKAGE_MAP = Dict{String,String}(
    "google.protobuf" => "ProtocGen.google.protobuf",
)

_package_alias(pkg::String) = replace(pkg, "." => "_")

# Compute the Julia *relative* import path from the source proto package
# `from_pkg` to the target proto package `to_pkg`, given that each proto
# package is laid out as a nested Julia module hierarchy with the same
# component names. The result is a leading-dotted dotted name suitable for
# `import <result> as <alias>`.
#
# Mechanics: Julia's leading-dot convention is "1 dot = current module,
# 2 dots = parent, …, N dots = N−1 levels up". So to reach a sibling
# proto package, we go up to the deepest common ancestor (= length of
# common prefix) and then descend into the target's remaining components.
#
#   from              to               result
#   programs.jobs     assets.types     ...assets.types       (3 dots = up 2)
#   programs.jobs     programs.types   ..types               (2 dots = up 1)
#   common            programs.types   ..programs.types
#   ""  (root)        programs.types   .programs.types       (1 dot = current)
#
# The same-package case (from_pkg == to_pkg) shouldn't arrive here at all
# — codegen filters out self-references before computing imports.
function _relative_import_path(from_pkg::AbstractString, to_pkg::AbstractString)
    from_parts = isempty(from_pkg) ? String[] : split(String(from_pkg), '.')
    to_parts   = isempty(to_pkg)   ? String[] : split(String(to_pkg),   '.')
    common = 0
    while common < length(from_parts) && common < length(to_parts) &&
          from_parts[common + 1] == to_parts[common + 1]
        common += 1
    end
    dots = (length(from_parts) - common) + 1
    rest = join(@view(to_parts[common + 1:end]), '.')
    return repeat('.', dots) * rest
end

# Per-file context. Tables come from the shared universe; only `package`,
# `syntax`, and `cycle` are file-local. The `messages`/`enums`/etc. fields
# exist as direct accessors so the existing `_resolve_typename(name, names)`
# style keeps working without a sweeping rename. `cycle` is the set of
# message FQNs that participate in a recursive dependency within this
# file — empty for almost everything, populated for `struct.proto`'s
# Struct↔Value↔ListValue cycle. Field-type resolution consults it to
# decide whether to emit the concrete name or the abstract supertype.
Base.@kwdef struct LocalNames
    package::String              # e.g. "sample"; "" if no package
    syntax::String               # "proto2" or "proto3"
    messages::Set{String}
    enums::Set{String}
    jl_names::Dict{String,String}
    enum_defs::Dict{String,EnumDescriptorProto}
    map_entries::Dict{String,DescriptorProto}
    package_of::Dict{String,String}  # FQN -> proto package
    cycle::Set{String} = Set{String}()  # message FQNs in a recursion cycle
end

function _is_map_entry(msg::DescriptorProto)
    o = msg.options
    return o !== nothing && o.map_entry === true
end

# Walk one file and add its messages/enums to the universe's tables in place.
function _add_file_to_universe!(u::Universe, file::FileDescriptorProto)
    package = something(file.package, "")
    prefix = isempty(package) ? "" : ".$(package)"

    function visit_message(msg::DescriptorProto, parent_proto::String, parent_jl::String)
        proto_name = string(parent_proto, ".", something(msg.name, ""))
        jl_name = isempty(parent_jl) ? something(msg.name, "") : string(parent_jl, ".", something(msg.name, ""))
        push!(u.messages, proto_name)
        u.jl_names[proto_name] = jl_name
        u.package_of[proto_name] = package
        if _is_map_entry(msg)
            u.map_entries[proto_name] = msg
        end
        for nested in msg.nested_type
            visit_message(nested, proto_name, jl_name)
        end
        for e in msg.enum_type
            ename = something(e.name, "")
            efqn = string(proto_name, ".", ename)
            ejl = string(jl_name, ".", ename)
            push!(u.enums, efqn)
            u.jl_names[efqn] = ejl
            u.enum_defs[efqn] = e
            u.package_of[efqn] = package
        end
    end

    for msg in file.message_type
        visit_message(msg, prefix, "")
    end
    for e in file.enum_type
        ename = something(e.name, "")
        efqn = string(prefix, ".", ename)
        push!(u.enums, efqn)
        u.jl_names[efqn] = ename
        u.enum_defs[efqn] = e
        u.package_of[efqn] = package
    end
    return u
end

# Build a Universe from every file the codegen request supplies. The plugin
# passes all entries of `request.proto_file` here (which includes the
# transitive imports protoc considered relevant), not just the files
# `file_to_generate` will produce code for.
function gather_universe(files)
    u = Universe(;
        messages = Set{String}(),
        enums = Set{String}(),
        jl_names = Dict{String,String}(),
        enum_defs = Dict{String,EnumDescriptorProto}(),
        map_entries = Dict{String,DescriptorProto}(),
        package_of = Dict{String,String}(),
    )
    for f in files
        _add_file_to_universe!(u, f)
    end
    return u
end

# Per-file view. Tables are shared references with the universe; `package`
# and `syntax` come from the file itself.
function _make_local_names(universe::Universe, file::FileDescriptorProto)
    return LocalNames(;
        package = something(file.package, ""),
        syntax = something(file.syntax, "proto2"),
        messages = universe.messages,
        enums = universe.enums,
        jl_names = universe.jl_names,
        enum_defs = universe.enum_defs,
        map_entries = universe.map_entries,
        package_of = universe.package_of,
    )
end

function _resolve_typename(type_name::String, names::LocalNames)
    haskey(names.jl_names, type_name) || error(
        "codegen: unresolved type reference $(type_name) " *
        "(type not found in any input file)",
    )
    jl = names.jl_names[type_name]
    # `Foo` stays as-is; `Foo.Bar` needs var"Foo.Bar" because the dot is not a
    # legal identifier character. The bootstrap follows the same convention.
    base = occursin('.', jl) ? "var\"$(jl)\"" : jl
    # Cycle participants get their abstract supertype as the visible name.
    # `struct.proto` is the only WKT that needs this — Struct.fields refers
    # to Value, which refers back to Struct via its `struct_value` oneof
    # member, so neither can be defined first concretely. The abstract
    # types are emitted upfront and a forwarding `decode(d, ::AbstractX)`
    # method routes back to the concrete type.
    if type_name in names.cycle
        return _abstract_name(base)
    end
    # Cross-package: qualify with the imported alias. A user file
    # importing `google/protobuf/timestamp.proto` references
    # `.google.protobuf.Timestamp` which lives in package
    # `google.protobuf`; that package gets its alias `google_protobuf`,
    # and the type renders as `google_protobuf.Timestamp`. The file head
    # carries the matching `import ... as google_protobuf`. Within the
    # same package, refs stay bare.
    pkg = get(names.package_of, type_name, "")
    if !isempty(pkg) && pkg != names.package
        return string(_package_alias(pkg), ".", base)
    end
    return base
end

# Map a concrete generated type name to the abstract supertype name we
# emit for cycle participants. `Foo` → `AbstractFoo`, `var"Foo.Bar"` →
# `var"AbstractFoo.Bar"`. The supertype lives in the same Julia module
# as the struct.
function _abstract_name(jl::String)
    if startswith(jl, "var\"") && endswith(jl, "\"")
        inner = jl[5:end-1]
        return string("var\"Abstract", inner, "\"")
    end
    return string("Abstract", jl)
end

# ----------------------------------------------------------------------------
# Field model. We compute everything once up front so the emitters are simple
# string-building.
# ----------------------------------------------------------------------------

Base.@kwdef struct FieldModel
    proto_name::String          # snake_case as in .proto
    jl_fieldname::String        # Julia field name (escaped if needed)
    json_name::String           # JSON key (camelCase by default, or `[json_name = …]`)
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
    # Julia keywords that are illegal as a struct field name. `type` is
    # NOT one — only the two-token `abstract type` / `primitive type` are
    # keywords, and `type` standalone is just an identifier; the
    # descriptor bootstrap commonly carries a `type` field (e.g.
    # FieldDescriptorProto.type) and tolerating it bare keeps the
    # generated API readable. Anything in the list below is mangled to
    # `var"#name"`.
    KEYWORDS = ("begin","while","if","for","try","return","break","continue",
                "function","macro","quote","let","local","global","const",
                "do","struct","module","baremodule","using","import","export",
                "end","else","elseif","catch","finally","true","false")
    return name in KEYWORDS ? "var\"#$(name)\"" : name
end

function _model_field(field::FieldDescriptorProto, names::LocalNames)
    L = var"FieldDescriptorProto.Label"
    T = var"FieldDescriptorProto.Type"

    proto_name = something(field.name, "")
    jl_fieldname = _jl_fieldname(proto_name)
    # `json_name` is populated by protoc with the camelCase form (or the
    # `[json_name = "…"]` override) for every field. Fall back to the raw
    # field name only for hand-built descriptors that lack it.
    json_name = something(field.json_name, proto_name)
    number = Int(something(field.number, Int32(0)))
    label = field.label
    ftype = field.type
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
                json_name,
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
            json_name,
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
        elseif _wants_scalar_presence(field, names)
            # proto2 `optional` and proto3 explicit `optional` enums carry
            # presence — same treatment as scalars. Without this, an
            # `optional Foo enum_field = 1` set to `Foo.FIRST` (numeric 0)
            # is dropped by the equal-to-default skip on encode, and the
            # field is indistinguishable from unset.
            jl_type  = "Union{Nothing,$(elem_t)}"
            init_val = "nothing"
            default  = "nothing"
            skip     = "!isnothing(_x.$(jl_fieldname))"
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
            json_name,
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
            json_name,
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
    ftype = field.type
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
    ftype = field.type
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
        "codegen: enum $(fqn) not found in any input file",
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

function _emit_message(io::IO, msg::DescriptorProto, parent_jl::String, names::LocalNames,
                       parent_proto::String = isempty(names.package) ? "" : ".$(names.package)";
                       batteries_kw::String = "",
                       enumbatteries_kw::String = "")
    name = something(msg.name, "")
    jl_name_plain = isempty(parent_jl) ? name : string(parent_jl, ".", name)
    jl_name = occursin('.', jl_name_plain) ? "var\"$(jl_name_plain)\"" : jl_name_plain
    proto_fqn = string(parent_proto, ".", name)
    is_cycle_participant = proto_fqn in names.cycle

    # Emit nested enums and nested messages first so they're defined before
    # this struct (which references them). Skip synthetic map_entry messages —
    # those are surfaced as `OrderedDict{K,V}` on the parent field, never as a
    # standalone Julia struct.
    for e in msg.enum_type
        _emit_enum(io, e, jl_name_plain; enumbatteries_kw = enumbatteries_kw)
    end
    for nested in msg.nested_type
        _is_map_entry(nested) && continue
        _emit_message(io, nested, jl_name_plain, names, proto_fqn;
                      batteries_kw = batteries_kw,
                      enumbatteries_kw = enumbatteries_kw)
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

    # struct: plain fields + one slot per real oneof + a buffer for
    # unknown fields. The unknown buffer lets us round-trip wire bytes
    # whose tags we don't recognize, per the protobuf spec's
    # forward-compat requirement. Cycle participants are tagged with
    # their abstract supertype so other participants can type their
    # fields against the abstract.
    #
    # `Base.@kwdef` synthesizes an outer kwarg constructor next to the
    # struct, giving users `T(; field1=val, ...)` ergonomics. Plain
    # positional construction (used by the generated decode body) still
    # works through Julia's compiler-generated all-fields constructor.
    # `var\"#unknown_fields\"` instead of plain `_unknown_fields` for the
    # buffer field so it can't collide with a user proto field of that
    # name — proto field names match `[a-zA-Z_][a-zA-Z0-9_]*` so `#` is
    # forever out of reach for protoc.
    println(io, "Base.@kwdef ", is_cycle_participant ?
            "struct $(jl_name) <: $(_abstract_name(jl_name))" :
            "struct $(jl_name) <: PB.AbstractProtoBufMessage")
    param_names = String[]
    for f in plain_fields
        # proto2 required submessages have `default_value = Ref{T}()`,
        # which doesn't fit the concrete field type T. Emit those without
        # a default — kwarg construction then requires the user to pass
        # them explicitly, mirroring the protocol's "required" semantics.
        if f.is_required && f.is_message
            println(io, "    ", f.jl_fieldname, "::", f.jl_type)
        else
            println(io, "    ", f.jl_fieldname, "::", f.jl_type, " = ", f.default_value)
        end
        push!(param_names, f.jl_fieldname)
    end
    for o in real_oneofs
        println(io, "    ", o.jl_fieldname, "::", _oneof_jl_type(o), " = nothing")
        push!(param_names, o.jl_fieldname)
    end
    println(io, "    var\"#unknown_fields\"::Vector{UInt8} = UInt8[]")
    push!(param_names, "var\"#unknown_fields\"")
    # Inner constructor with `_unknown_fields=UInt8[]` default. Coexists
    # with @kwdef's outer kwarg constructor and replaces Julia's auto-
    # generated all-positional constructor; users get
    #     T(field1, ..., fieldN-1)              (buffer defaults to UInt8[])
    #     T(field1, ..., fieldN-1, buffer)      (explicit buffer)
    #     T(; field1=val, ...)                  (kwarg form, all optional)
    # The constructor is *inner* — emitting it as outer would split the
    # binding partition on Julia 1.12 and break `Type{<:T}` dispatch.
    #
    # Skip the inner ctor for messages whose only field is the buffer
    # (e.g. WKT `Empty`): there it collides with @kwdef's auto-positional
    # `T(::Vector{UInt8})` since both take exactly the buffer arg.
    if length(param_names) > 1
        inner_params = join(param_names[1:end-1], ", ")
        sep = isempty(inner_params) ? "" : ", "
        println(io, "    function ", jl_name, "(", inner_params, sep, "_unknown_fields=UInt8[])")
        pos_args = String[]
        for n in param_names
            push!(pos_args, n == "var\"#unknown_fields\"" ? "_unknown_fields" : n)
        end
        println(io, "        return new(", join(pos_args, ", "), ")")
        println(io, "    end")
    end
    println(io, "end")

    # Metadata.
    println(io, "function PB.default_values(::Core.Type{", jl_name, "})")
    pieces = String[]
    for f in plain_fields
        push!(pieces, "$(f.jl_fieldname) = $(f.default_value)")
    end
    for o in real_oneofs
        push!(pieces, "$(o.jl_fieldname) = nothing")
    end
    push!(pieces, "var\"#unknown_fields\" = UInt8[]")
    println(io, "    return (;", join(pieces, ", "), ")")
    println(io, "end")

    println(io, "function PB.field_numbers(::Core.Type{", jl_name, "})")
    pieces = String[]
    for f in plain_fields
        push!(pieces, "$(f.jl_fieldname) = $(f.number)")
    end
    for o in real_oneofs
        for m in o.members
            push!(pieces, "$(m.jl_fieldname) = $(m.number)")
        end
    end
    println(io, "    return (;", join(pieces, ", "), ")")
    println(io, "end")

    println(io, "function PB.json_field_names(::Core.Type{", jl_name, "})")
    pieces = String[]
    for f in plain_fields
        push!(pieces, "$(f.jl_fieldname) = $(repr(f.json_name))")
    end
    for o in real_oneofs
        for m in o.members
            push!(pieces, "$(m.jl_fieldname) = $(repr(m.json_name))")
        end
    end
    println(io, "    return (;", join(pieces, ", "), ")")
    println(io, "end")

    # Register the message type by its protobuf FQN so `Any` (which
    # carries `type.googleapis.com/<FQN>` URLs) and any other
    # introspection user can reverse-look-up the Julia type. The
    # leading dot in our internal FQN is dropped — protobuf type URLs
    # don't carry it.
    fqn = startswith(proto_fqn, ".") ? proto_fqn[2:end] : proto_fqn
    println(io, "PB.register_message_type(", repr(fqn), ", ", jl_name, ")")

    if !isempty(real_oneofs)
        println(io, "function PB.oneof_field_types(::Core.Type{", jl_name, "})")
        oneof_pieces = String[]
        for o in real_oneofs
            inner = join(("$(m.jl_fieldname) = $(m.elem_jl_type)" for m in o.members), ", ")
            push!(oneof_pieces, "$(o.jl_fieldname) = (;$(inner))")
        end
        println(io, "    return (;", join(oneof_pieces, ", "), ")")
        println(io, "end")
    end

    _emit_reserved_fields(io, jl_name, msg)

    println(io)

    # decode.
    println(io, "function PB._decode(_d::PB.AbstractProtoDecoder, ::Core.Type{<:", jl_name, "}, _endpos::Int=0, _group::Bool=false)")
    for f in plain_fields
        println(io, "    ", f.jl_fieldname, " = ", f.init_value)
        if f.is_required
            println(io, "    _saw_", f.jl_fieldname, " = false")
        end
    end
    for o in real_oneofs
        println(io, "    ", o.jl_fieldname, "::", _oneof_jl_type(o), " = nothing")
    end
    println(io, "    _unknown_fields = UInt8[]")
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
        # No known fields at all — every tag is unknown.
        println(io, "        PB._skip_and_capture!(_unknown_fields, _d, field_number, wire_type)")
    else
        println(io, "        else")
        println(io, "            PB._skip_and_capture!(_unknown_fields, _d, field_number, wire_type)")
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
    push!(arg_parts, "_unknown_fields")
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

    println(io, "function PB._encode(_e::PB.AbstractProtoEncoder, _x::", jl_name, ")")
    println(io, "    initpos = position(_e.io)")
    for (_, emit_e, _) in encode_plan
        emit_e(io)
    end
    # Replay unknown-field bytes verbatim. Append-at-end semantics: not
    # byte-identical to protoc when known + unknown tags interleave, but
    # spec-correct (the protobuf wire format makes no field-order
    # promises) and enough for forward-compat round-trips.
    println(io, "    if !isempty(_x.var\"#unknown_fields\")")
    println(io, "        write(_e.io, _x.var\"#unknown_fields\")")
    println(io, "    end")
    println(io, "    return position(_e.io) - initpos")
    println(io, "end")

    println(io, "function PB._encoded_size(_x::", jl_name, ")")
    println(io, "    encoded_size = 0")
    for (_, _, emit_s) in encode_plan
        emit_s(io)
    end
    println(io, "    encoded_size += length(_x.var\"#unknown_fields\")")
    println(io, "    return encoded_size")
    println(io, "end")

    # Optional StructHelpers `@batteries` decoration. Forwarded from the
    # plugin's `--julia_opt=config=...` TOML; empty string means the
    # user didn't opt in for messages, so we skip the line entirely.
    if !isempty(batteries_kw)
        println(io, "@batteries ", jl_name, " ", batteries_kw)
    end

    println(io)
end

function _oneof_jl_type(o::OneofModel)
    elem_union = join((m.elem_jl_type for m in o.members), ",")
    return "Union{Nothing,OneOf{<:Union{$(elem_union)}}}"
end

function _emit_decode_oneof_member(io::IO, o::OneofModel, m::FieldModel)
    # Decode the value into a temporary, then wrap in OneOf.
    if m.is_message
        # OneOf members can be submessages. Per spec: when the *same*
        # message-type oneof member appears multiple times on the wire,
        # the values are merged (as singular submessages would be).
        # Seed the Ref with the prior value if and only if that prior
        # value belonged to *this* member; otherwise start from
        # `nothing`. The Union{Nothing,T} `decode!` overload then
        # merges the new wire instance into the seeded value.
        elem = m.elem_jl_type
        println(io, "            _v = Ref{Union{Nothing,$(elem)}}(",
                "(!isnothing(", o.jl_fieldname, ") && ", o.jl_fieldname, ".name === :",
                m.jl_fieldname, ") ? ", o.jl_fieldname, ".value::", elem, " : nothing)")
        println(io, "            PB._decode!(_d, _v)")
        println(io, "            ", o.jl_fieldname, " = OneOf(:", m.jl_fieldname, ", _v[]::", elem, ")")
    elseif m.is_enum
        println(io, "            ", o.jl_fieldname, " = OneOf(:", m.jl_fieldname, ", PB._decode(_d, ", m.elem_jl_type, "))")
    else
        if !isempty(m.wire_annotation)
            println(io, "            ", o.jl_fieldname, " = OneOf(:", m.jl_fieldname, ", PB._decode(_d, ", m.elem_jl_type, ", ", m.wire_annotation, "))")
        else
            println(io, "            ", o.jl_fieldname, " = OneOf(:", m.jl_fieldname, ", PB._decode(_d, ", m.elem_jl_type, "))")
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
    _emit_oneof_member_guarded(io, o, m, "PB._encode(_e, $(m.number), _o.value$(args))")
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
            println(io, "            PB._decode!(_d, ", f.jl_fieldname, ")")
        else
            println(io, "            PB._decode!(_d, ", f.jl_fieldname, ", ", f.wire_annotation, ")")
        end
    elseif f.is_message
        if f.is_repeated
            println(io, "            PB._decode!(_d, ", f.jl_fieldname, ")")
        else
            println(io, "            PB._decode!(_d, ", f.jl_fieldname, ")")
        end
    elseif f.is_enum
        if f.is_repeated
            println(io, "            PB._decode!(_d, wire_type, ", f.jl_fieldname, ")")
        else
            println(io, "            ", f.jl_fieldname, " = PB._decode(_d, ", f.elem_jl_type, ")")
        end
    else
        if f.is_repeated
            if f.elem_jl_type in ("String", "Vector{UInt8}")
                # Strings and bytes have no-wire-type BufferedVector decoders
                # (decode.jl:107, 120). Bool/Float32/Float64 do *not* — they
                # need the wire-type so the codec can switch between packed
                # (LENGTH_DELIMITED) and unpacked (decode.jl:174).
                println(io, "            PB._decode!(_d, ", f.jl_fieldname, ")")
            elseif !isempty(f.wire_annotation)
                println(io, "            PB._decode!(_d, wire_type, ", f.jl_fieldname, ", ", f.wire_annotation, ")")
            else
                println(io, "            PB._decode!(_d, wire_type, ", f.jl_fieldname, ")")
            end
        else
            if !isempty(f.wire_annotation)
                println(io, "            ", f.jl_fieldname, " = PB._decode(_d, ", f.elem_jl_type, ", ", f.wire_annotation, ")")
            else
                println(io, "            ", f.jl_fieldname, " = PB._decode(_d, ", f.elem_jl_type, ")")
            end
        end
    end
end

function _decode_finalize(f::FieldModel)
    if f.is_map
        # `dict` is a real Dict the codec mutates in place; pass through.
        return f.jl_fieldname
    elseif f.is_message || f.is_repeated
        # Singular message: `Ref{T}[]` unwraps to T.
        # Repeated (message or scalar): `BufferedVector[]` finalizes to Vector{T}.
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

    println(io, "function PB.reserved_fields(::Core.Type{", jl_name, "})")
    println(io, "    return (names = ", name_str, ", numbers = ", range_str, ")")
    println(io, "end")
end

function _emit_encode_field(io::IO, f::FieldModel)
    args = isempty(f.wire_annotation) ? "" : ", $(f.wire_annotation)"
    if f.emit_unpacked_loop
        # Unpacked repeated scalar/enum: protoc emits one tag-value pair
        # per element (proto2 default, or proto3 with [packed = false]).
        # Emit per-element so the singular scalar encode paths apply.
        println(io, "    if !isempty(_x.", f.jl_fieldname, ")")
        println(io, "        for _v in _x.", f.jl_fieldname)
        println(io, "            PB._encode(_e, ", f.number, ", _v", args, ")")
        println(io, "        end")
        println(io, "    end")
    else
        println(io, "    ", f.encode_skip, " && PB._encode(_e, ", f.number, ", _x.", f.jl_fieldname, args, ")")
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

function _emit_enum(io::IO, e::EnumDescriptorProto, parent_jl::String;
                    enumbatteries_kw::String = "")
    name = something(e.name, "")
    jl_name_plain = isempty(parent_jl) ? name : string(parent_jl, ".", name)
    jl_name = occursin('.', jl_name_plain) ? "var\"$(jl_name_plain)\"" : jl_name_plain

    allow_alias = e.options !== nothing && e.options.allow_alias === true
    if !allow_alias
        members = join((string(something(v.name, ""), "=", Int(something(v.number, Int32(0)))) for v in e.value), " ")
        println(io, "@enumx ", jl_name, " ", members)
        # `@enumx` wraps the underlying `Base.@enum` in a baremodule
        # named after the enum; the enum *type* is `<EnumName>.T`. That
        # is what `@enumbatteries` operates on.
        if !isempty(enumbatteries_kw)
            println(io, "@enumbatteries ", jl_name, ".T ", enumbatteries_kw)
        end
        println(io)
        return
    end

    # `option allow_alias = true;` lets multiple symbolic names map to the
    # same numeric value. EnumX (like Julia's `@enum`) rejects duplicates,
    # so we partition: the *first* name per number is canonical and goes
    # into the `@enumx` declaration; subsequent names with the same number
    # are emitted as `const`s inside the enum module via `eval`. They
    # bind to the same enum *instance* as the canonical, so
    # `Foo.MOO === Foo.ALIAS_BAZ` and `Symbol(Foo.MOO)` returns
    # `:ALIAS_BAZ` (canonical wins on display, matching protoc).
    seen = Dict{Int,String}()  # number -> canonical name
    canonicals = Tuple{String,Int}[]
    aliases = Tuple{String,String}[]  # (alias, canonical)
    for v in e.value
        vname = something(v.name, "")
        vnum = Int(something(v.number, Int32(0)))
        if haskey(seen, vnum)
            push!(aliases, (vname, seen[vnum]))
        else
            seen[vnum] = vname
            push!(canonicals, (vname, vnum))
        end
    end
    members = join((string(n, "=", num) for (n, num) in canonicals), " ")
    println(io, "@enumx ", jl_name, " ", members)
    # `Core.eval(Mod, expr)` rather than `Mod.eval(expr)` because EnumX
    # builds the enum module as a `baremodule`, which doesn't import
    # `Base.eval`.
    for (alias, canonical) in aliases
        println(io, "Core.eval(", jl_name, ", :(const ", alias, " = ", canonical, "))")
    end
    if !isempty(enumbatteries_kw)
        println(io, "@enumbatteries ", jl_name, ".T ", enumbatteries_kw)
    end
    println(io)
end

# ----------------------------------------------------------------------------
# Topological sort. A message's struct depends on the types of its fields.
# Within one file we may need to reorder the messages so referenced types are
# defined first. proto allows recursive messages (Foo containing a Foo) — in
# Julia this works fine for `Union{Nothing,Foo}` references because it only
# needs the type name, but for `Vector{Foo}` we also need Foo's name to exist.
# We emit messages in topological order. Cycles are handled separately by
# forward-declaring an `abstract type AbstractFoo` per cycle participant and
# typing cyclic references against the abstract — see `_abstract_name` and
# the cycle plumbing in `LocalNames`.
# ----------------------------------------------------------------------------

function _direct_message_deps(msg::DescriptorProto, names::LocalNames)
    # Only the message's own fields — nested types are not visited.
    # Self-edges from this set are *safe*: Julia parses a struct body
    # lazily enough that `field::Union{Nothing,Foo}` inside `struct Foo`
    # resolves correctly. This is what lets DescriptorProto.nested_type::
    # Vector{DescriptorProto} compile without a forward declaration.
    deps = Set{String}()
    T = var"FieldDescriptorProto.Type"
    for f in msg.field
        ftype = f.type
        if ftype === T.TYPE_MESSAGE
            tn = something(f.type_name, "")
            if tn in names.messages
                push!(deps, tn)
            end
        end
    end
    return deps
end

function _nested_message_deps(msg::DescriptorProto, names::LocalNames)
    # Only deps from the message's *nested* types (recursively). A
    # self-edge here is unsafe because the nested struct body parses
    # before the parent struct is defined, so `field::Foo` inside the
    # nested type would forward-reference the parent's name.
    deps = Set{String}()
    T = var"FieldDescriptorProto.Type"
    function visit(m::DescriptorProto)
        for f in m.field
            ftype = f.type
            if ftype === T.TYPE_MESSAGE
                tn = something(f.type_name, "")
                if tn in names.messages
                    push!(deps, tn)
                end
            end
        end
        for nested in m.nested_type
            visit(nested)
        end
    end
    for nested in msg.nested_type
        visit(nested)
    end
    return deps
end

function _toplevel_message_deps(msg::DescriptorProto, names::LocalNames)
    deps = Set{String}()
    function visit(m::DescriptorProto)
        for f in m.field
            ftype = f.type
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

    # Three views of the dependency graph:
    #   `direct_deps` — only the top-level msg's own fields.
    #   `nested_deps` — deps that surface via nested types (their bodies
    #                   are parsed before the parent struct is defined,
    #                   so a self-reference there forces an abstract).
    #   `all_deps`    — direct_deps ∪ nested_deps; used for normal topo
    #                   sort (we still need correct ordering against
    #                   non-self deps regardless of where they came from).
    # Cycle detection drops a self-edge iff it's a *direct-only*
    # self-reference (safe in Julia: `struct Foo; r::Union{Nothing,Foo}; end`
    # compiles fine).
    direct_deps = Dict(fqn => filter(d -> d in keys(by_fqn),
                                     _direct_message_deps(by_fqn[fqn], names))
                       for fqn in order)
    nested_deps = Dict(fqn => filter(d -> d in keys(by_fqn),
                                     _nested_message_deps(by_fqn[fqn], names))
                       for fqn in order)
    all_deps = Dict(fqn => union(direct_deps[fqn], nested_deps[fqn]) for fqn in order)

    function cycle_edges(node)
        out = Set{String}()
        for d in all_deps[node]
            d == node && (d in direct_deps[node]) && !(d in nested_deps[node]) && continue
            push!(out, d)
        end
        return out
    end

    # First pass: find cycle participants. A node is a cycle participant if
    # it can reach itself through `cycle_edges` via at least one other
    # node, OR if it has a nested-type self-reference (which `cycle_edges`
    # preserves). We DFS from each node and flag any back-edge target as
    # cyclic; transitively, any node on the back edge's path becomes
    # cyclic too.
    cycle_participants = Set{String}()
    let visiting = Set{String}(), visited = Set{String}(), path = String[]
        function dfs1(node)
            node in visited && return
            if node in visiting
                idx = findlast(==(node), path)
                if idx !== nothing
                    for i in idx:length(path)
                        push!(cycle_participants, path[i])
                    end
                end
                return
            end
            push!(visiting, node)
            push!(path, node)
            for d in cycle_edges(node)
                dfs1(d)
            end
            pop!(path)
            delete!(visiting, node)
            push!(visited, node)
        end
        for fqn in order
            dfs1(fqn)
        end
    end

    # Second pass: topo-sort with cycle edges removed. Edges into cycle
    # participants stay (so they're emitted after their non-cyclic
    # dependencies); edges *between* cycle participants are dropped (the
    # abstract supertype makes ordering between them irrelevant).
    sorted = String[]
    let visiting = Set{String}(), visited = Set{String}()
        function dfs2(node)
            node in visited && return
            push!(visiting, node)
            for d in all_deps[node]
                # Skip edges that lead back into the cycle from inside it.
                (node in cycle_participants && d in cycle_participants) && continue
                # Direct-only self-loops are safe (Julia handles them).
                d == node && (d in direct_deps[node]) && !(d in nested_deps[node]) && continue
                d in visiting && continue
                dfs2(d)
            end
            delete!(visiting, node)
            push!(visited, node)
            push!(sorted, node)
        end
        for fqn in order
            dfs2(fqn)
        end
    end
    return [by_fqn[fqn] for fqn in sorted], cycle_participants
end

# ----------------------------------------------------------------------------
# File emission.
# ----------------------------------------------------------------------------

# Collect every proto package referenced from `file` that is *not* the
# current file's own package. These map 1:1 to `import ... as <alias>`
# lines emitted at the top of the generated file.
function _collect_cross_packages(file::FileDescriptorProto, names::LocalNames)
    pkgs = Set{String}()
    function visit_msg(msg::DescriptorProto)
        # Map entry types are emitted inline as OrderedDict; their key/
        # value type refs need to flow through the same cross-package
        # check. We re-resolve via the FQN so map<K,V> with a V from
        # another package qualifies its V.
        for f in msg.field
            tn = something(f.type_name, "")
            isempty(tn) && continue
            pkg = get(names.package_of, tn, "")
            if !isempty(pkg) && pkg != names.package
                push!(pkgs, pkg)
            end
            # Map entry messages are children of `msg` but their fields'
            # type_names also need scanning. The recursive `nested_type`
            # walk below handles them.
        end
        for nested in msg.nested_type
            visit_msg(nested)
        end
    end
    for msg in file.message_type
        visit_msg(msg)
    end
    return pkgs
end

codegen(file::FileDescriptorProto) = codegen(file, gather_universe([file]))

function codegen(file::FileDescriptorProto, universe::Universe;
                 config::AbstractDict = Dict{String,Any}())
    names = _make_local_names(universe, file)
    io = IOBuffer()
    proto_name = something(file.name, "<unknown>")
    syntax = something(file.syntax, "proto2")

    # Per-type customization toggles. The user-supplied `config` dict
    # may carry a `[batteries]` and/or `[enumbatteries]` table whose
    # entries are forwarded as keyword arguments to `@batteries` /
    # `@enumbatteries` invocations on every generated message / enum.
    # Any other top-level config key is currently ignored.
    batteries_kw     = _config_kw_table(config, "batteries")
    enumbatteries_kw = _config_kw_table(config, "enumbatteries")
    has_batteries     = !isempty(batteries_kw)
    has_enumbatteries = !isempty(enumbatteries_kw)

    println(io, "# Generated by ProtocGen. Do not edit.")
    println(io, "# source: ", proto_name, " (", syntax, " syntax)")
    println(io, "#! format: off")
    println(io)
    println(io, "import ProtocGen as PB")
    println(io, "using ProtocGen: OneOf, OrderedDict")
    # Pull the user-facing codec entry points into the include site so
    # `encode(io, msg)` / `decode(io, T)` / `encode_json` / `decode_json`
    # work without the caller importing ProtocGen themselves.
    println(io, "using ProtocGen: encode, decode, encode_json, decode_json")
    println(io, "using ProtocGen.EnumX: @enumx")
    if has_batteries || has_enumbatteries
        # @batteries / @enumbatteries reach the user's namespace via the
        # ProtocGen → StructHelpers re-export, so users only need to
        # depend on ProtocGen.
        println(io, "using ProtocGen.StructHelpers: @batteries, @enumbatteries")
    end

    # Cross-package imports. Walk the file's referenced FQNs to find
    # external packages and emit one import line per package so
    # `_resolve_typename` can render cross-package refs as
    # `<alias>.<TypeName>`. Two strategies, in order:
    #   1. WKT_PACKAGE_MAP — absolute redirect for packages that live
    #      outside the user's tree. Today's only entry is
    #      google.protobuf → ProtocGen.google.protobuf.
    #   2. Relative import — assume the user puts every other proto
    #      package as a nested Julia module under a single common root,
    #      with names matching the proto package components. Codegen
    #      doesn't need to know where the user mounts that root.
    cross_packages = _collect_cross_packages(file, names)
    if !isempty(cross_packages)
        println(io)
        for pkg in sort!(collect(cross_packages))
            if haskey(WKT_PACKAGE_MAP, pkg)
                jlmod = WKT_PACKAGE_MAP[pkg]
                println(io, "import ", jlmod, " as ", _package_alias(pkg))
            else
                relpath = _relative_import_path(names.package, pkg)
                println(io, "import ", relpath, " as ", _package_alias(pkg))
            end
        end
    end
    println(io)

    # Export every top-level message and enum so `using <module>` reaches
    # them. Matches the bootstrap convention (gen/google/protobuf/
    # descriptor_pb.jl exports the same way) and is what user code
    # importing a generated `_pb.jl` will expect.
    exports = String[]
    for e in file.enum_type
        push!(exports, something(e.name, ""))
    end
    for msg in file.message_type
        _is_map_entry(msg) && continue
        push!(exports, something(msg.name, ""))
    end
    if !isempty(exports)
        println(io, "export ", join(exports, ", "))
        println(io)
    end

    for e in file.enum_type
        _emit_enum(io, e, ""; enumbatteries_kw = enumbatteries_kw)
    end
    sorted_msgs, cycle_participants = _topo_sort(file, names)
    # Build a cycle-aware `LocalNames` view. _resolve_typename consults
    # `names.cycle` to pick concrete vs abstract for every type reference.
    cycle_names = LocalNames(;
        package = names.package,
        syntax = names.syntax,
        messages = names.messages,
        enums = names.enums,
        jl_names = names.jl_names,
        enum_defs = names.enum_defs,
        map_entries = names.map_entries,
        package_of = names.package_of,
        cycle = cycle_participants,
    )
    # Forward `abstract type` for every cycle participant so the structs
    # in the cycle can reference each other through the abstract
    # supertype. struct.proto's Value↔Struct↔ListValue is the only WKT
    # that needs this.
    if !isempty(cycle_participants)
        println(io, "# Forward declarations for cyclic message types. Each cycle")
        println(io, "# participant has an abstract supertype; field types that")
        println(io, "# reference cycle participants resolve to the abstract.")
        for fqn in sort!(collect(cycle_participants))
            jl_plain = names.jl_names[fqn]
            jl = occursin('.', jl_plain) ? "var\"$(jl_plain)\"" : jl_plain
            abs_jl = _abstract_name(jl)
            println(io, "abstract type ", abs_jl, " <: PB.AbstractProtoBufMessage end")
        end
        println(io)
    end
    for msg in sorted_msgs
        _emit_message(io, msg, "", cycle_names;
                      batteries_kw = batteries_kw,
                      enumbatteries_kw = enumbatteries_kw)
    end
    # Forwarding decode methods so that decoding into Vector{Abstract<X>}
    # / Ref{Abstract<X>} dispatches into the concrete struct's decoder.
    # The same pattern routes JSON decode (Phase 12b) — `Struct.fields`
    # is `OrderedDict{String,AbstractValue}` and the JSON walker has to
    # land on `Value` to reconstruct.
    if !isempty(cycle_participants)
        for fqn in sort!(collect(cycle_participants))
            jl_plain = names.jl_names[fqn]
            jl = occursin('.', jl_plain) ? "var\"$(jl_plain)\"" : jl_plain
            abs_jl = _abstract_name(jl)
            println(io, "function PB._decode(_d::PB.AbstractProtoDecoder, ::Core.Type{<:", abs_jl, "}, _endpos::Int=0, _group::Bool=false)")
            println(io, "    return PB._decode(_d, ", jl, ", _endpos, _group)")
            println(io, "end")
            # NOTE: invariant `Type{X}` (no `<:`) so the forwarding fires
            # only for the abstract supertype itself; the concrete struct
            # falls through to the generic walker via the
            # `T <: AbstractProtoBufMessage` method on `_decode_json_message`.
            println(io, "function PB._decode_json_message(::Core.Type{", abs_jl, "}, json::AbstractDict; kw...)")
            println(io, "    return PB._decode_json_message(", jl, ", json; kw...)")
            println(io, "end")
        end
    end

    println(io)
    println(io, "#! format: on")
    return String(take!(io))
end

# ----------------------------------------------------------------------------
# Driver file — emitted alongside the per-file _pb.jl outputs by the protoc
# plugin. It declares the nested module skeleton matching the union of
# proto packages in the request, and `include`s each generated file in
# topological dependency order. The user includes the driver from wherever
# they want their proto namespace rooted:
#
#     module Services
#         include("services_pb_includes.jl")
#     end
#
# Per-file outputs use *relative* imports for cross-package refs (see
# `_relative_import_path`), so the driver-rooted layout is the only thing
# users need to set up — no per-package mapping required.
# ----------------------------------------------------------------------------

function codegen_driver(file_to_generate::Vector{String},
                        by_name::Dict{String,FileDescriptorProto})
    # Topo sort the to-generate set by `dependency` so includes load in
    # dependency order. WKT and other already-loaded deps are filtered out.
    in_set = Set(file_to_generate)
    deps = Dict{String,Vector{String}}()
    for path in file_to_generate
        haskey(by_name, path) || continue
        f = by_name[path]
        deps[path] = [d for d in f.dependency if d in in_set]
    end
    order = String[]
    remaining = Set(keys(deps))
    while !isempty(remaining)
        ready = sort!([n for n in remaining if all(d -> d in order, deps[n])])
        isempty(ready) && error("codegen_driver: dependency cycle in $remaining")
        append!(order, ready)
        foreach(n -> delete!(remaining, n), ready)
    end

    # Collect the full package hierarchy that needs declaring up-front
    # (every package + every prefix on the way to it).
    pkg_set = Set{String}()
    for path in order
        pkg = something(by_name[path].package, "")
        node = ""
        for part in (isempty(pkg) ? String[] : split(pkg, '.'))
            node = isempty(node) ? String(part) : "$node.$part"
            push!(pkg_set, node)
        end
    end

    io = IOBuffer()
    println(io, "# Generated by ProtocGen. Do not edit.")
    println(io, "# Driver file: declares the proto-package module skeleton")
    println(io, "# and includes each generated `_pb.jl` in topological order.")
    println(io, "# Include this file from wherever you want the namespace rooted.")
    println(io, "#! format: off")
    println(io)
    println(io, "const _PB_DIR  = @__DIR__")
    println(io, "const _PB_ROOT = @__MODULE__")
    println(io)
    # Bring the codec entry points into the wrapping module so callers
    # holding a `MyProtos.tutorial.Person` can do `MyProtos.encode(msg)`
    # without needing their own `using ProtocGen`.
    println(io, "using ProtocGen: encode, decode, encode_json, decode_json")
    println(io)

    # Emit empty skeleton modules (nested) so cross-module references in
    # the per-file outputs resolve before any `_pb.jl` is loaded.
    println(io, "# --- module skeleton ---")
    _emit_empty_skeleton(io, _build_skeleton_tree(pkg_set), "", 0)
    println(io)

    # Emit `Core.include(<module>, <abs path>)` for each file in topo
    # order. This evaluates the file in its target module regardless of
    # where the driver sits in the dispatcher's module stack.
    println(io, "# --- file includes (topological order) ---")
    for path in order
        f = by_name[path]
        pkg = something(f.package, "")
        out_name = string(replace(path, r"\.proto$" => ""), "_pb.jl")
        mod_expr = isempty(pkg) ? "_PB_ROOT" : "_PB_ROOT." * pkg
        # `Core.include(M, file)` evaluates `file` in module `M` and uses
        # the current `task_local_storage()[:SOURCE_PATH]` for relative
        # path resolution — so wrap with `joinpath(_PB_DIR, …)` to make
        # the include path resolve against this driver file's directory.
        println(io, "Core.include(", mod_expr,
                ", joinpath(_PB_DIR, ", repr(out_name), "))")
    end

    println(io)
    println(io, "#! format: on")
    return String(take!(io))
end

# Skeleton tree: every internal node is a package component. We don't
# attach includes to nodes — those are emitted separately in topo order.
struct _SkeletonNode
    children::Dict{String,_SkeletonNode}
end
_SkeletonNode() = _SkeletonNode(Dict{String,_SkeletonNode}())

function _build_skeleton_tree(pkg_set::Set{String})
    root = _SkeletonNode()
    for pkg in pkg_set
        node = root
        for part in split(pkg, '.')
            node = get!(node.children, String(part), _SkeletonNode())
        end
    end
    return root
end

function _emit_empty_skeleton(io::IO, node::_SkeletonNode, name::String, depth::Int)
    indent = "    " ^ depth
    if !isempty(name)
        println(io, indent, "module ", name)
    end
    for child_name in sort!(collect(keys(node.children)))
        _emit_empty_skeleton(io, node.children[child_name], child_name,
                             isempty(name) ? depth : depth + 1)
    end
    if !isempty(name)
        println(io, indent, "end # module ", name)
    end
    return nothing
end

end # module Codegen
