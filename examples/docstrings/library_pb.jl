# Illustrative sketch of what `library.proto` generates with docstring
# retention enabled (`[codegen] docstrings = true`). The codec boilerplate
# ProtocGen always emits (PB._decode / PB._encode / PB._encoded_size /
# field_numbers / json_field_names / default_keywords) is elided with `# ...`
# to keep the focus on where the proto comments land. Topo order:
# dependencies before dependents.
#
# Field docs are rendered into each struct's docstring as a `# Fields` section
# so `?T` lists them with no dependency on DocStringExtensions. Enum-value
# comments are attached after `@enumx` as real, queryable docstrings.

module library

import ProtocGen as PB
using ProtocGen: OneOf, OrderedDict
using ProtocGen.EnumX: @enumx
using ProtocGen.StructHelpers: @batteries, @enumbatteries

# =====================================================================
# enum library.Membership   (top-level enum, no dependencies)
# =====================================================================

"Subscription tier of a member."
@enumx Membership UNSPECIFIED=0 BASIC=1 PREMIUM=2
"No tier selected." Membership.UNSPECIFIED
"Standard borrowing limits." Membership.BASIC
"Extended limits and early access." Membership.PREMIUM
@enumbatteries Membership.T typesalt=0x0000000000000001
PB._enum_proto_prefix(::Type{Membership.T}) = "MEMBERSHIP_"

# =====================================================================
# message library.Book   (emits its nested enum Book.Genre first)
# =====================================================================

# Multi-paragraph enum comment is kept verbatim as a triple-quoted docstring.
"""
The genre a book belongs to.

Used for shelving and search filters.
"""
@enumx var"Book.Genre" UNSPECIFIED=0 FICTION=1 NONFICTION=2
"Genre was never set (proto3 zero value)." var"Book.Genre".UNSPECIFIED
"Made-up stories." var"Book.Genre".FICTION
"Factual works." var"Book.Genre".NONFICTION
@enumbatteries var"Book.Genre".T typesalt=0x0000000000000002
PB._enum_proto_prefix(::Type{var"Book.Genre".T}) = "GENRE_"

"""
A single book in the catalog.

# Fields
- `isbn::String`: International Standard Book Number, 13-digit form.
- `title::String`: Full title as printed on the cover.
- `genre::var"Book.Genre".T`: Primary genre of the book.
- `availability::Union{Nothing,OneOf{<:Union{Int32,String}}}`: How the book can currently be obtained.
  - `copies_on_shelf::Int32`: Number of physical copies on the shelf.
  - `ebook_url::String`: URL to the e-book, if this is a digital-only title.
"""
struct Book <: PB.AbstractProtoBufMessage
    isbn::String
    title::String
    genre::var"Book.Genre".T
    availability::Union{Nothing,OneOf{<:Union{Int32,String}}}
    var"#unknown_fields"::Vector{UInt8}
end
# PB.field_numbers / json_field_names / oneof_field_types / _decode / _encode
# / _encoded_size / default_keywords ...
PB.register_message_type("library.Book", Book)
@batteries Book typesalt=0x0000000000000003 kwconstructor=true kwshow=true

# =====================================================================
# message library.Member   (depends on Membership, already defined)
# =====================================================================

"""
A person who can borrow books.

# Fields
- `id::String`: Stable unique identifier.
- `name::String`: Display name shown on the membership card.
- `tier::Membership.T`: The member's subscription tier.
"""
struct Member <: PB.AbstractProtoBufMessage
    id::String
    name::String
    tier::Membership.T
    var"#unknown_fields"::Vector{UInt8}
end
# ...
PB.register_message_type("library.Member", Member)
@batteries Member typesalt=0x0000000000000004 kwconstructor=true kwshow=true

# =====================================================================
# message library.Library   (depends on Book and Member)
# =====================================================================

"""
A library branch: catalogs books and the members who borrow them.

This is the top-level container for the whole system.

# Fields
- `name::String`: Human-readable name of the library branch.
- `books::Vector{Book}`: Every book currently in the catalog, in no particular order.
- `members_by_id::OrderedDict{String,Member}`: Registered members, keyed by their member id.
"""
struct Library <: PB.AbstractProtoBufMessage
    name::String
    books::Vector{Book}
    members_by_id::OrderedDict{String,Member}
    var"#unknown_fields"::Vector{UInt8}
end
# ...
PB.register_message_type("library.Library", Library)
@batteries Library typesalt=0x0000000000000005 kwconstructor=true kwshow=true

end # module library
