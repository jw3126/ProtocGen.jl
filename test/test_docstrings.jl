module TestDocstrings

include("setup.jl")

# Drive codegen directly (not through the plugin protocol) so we can flip the
# `[codegen] docstrings` config on and off. `docs.pb` is the only fixture
# captured WITH `--include_source_info`, so it carries the `//` comments.
function gen_docs(; docstrings::Bool)
    fdset = load_fdset("docs.pb")
    file = only(f for f in fdset.file if something(f.name, "") == "docs.proto")
    u = ProtocGen.Codegen.gather_universe([file])
    config = docstrings ? Dict("codegen" => Dict("docstrings" => true)) : Dict{String,Any}()
    return ProtocGen.Codegen.codegen(file, u; config = config)
end

@testset "docstrings: emitted text" begin
    src = gen_docs(; docstrings = true)

    # Message comment -> struct docstring; field comment -> leading `#` comment
    # above the struct field (no `# Fields` section in the docstring).
    @test occursin("A single book in the catalog.", src)
    @test !occursin("# Fields", src)
    @test occursin("    # International Standard Book Number", src)

    # Enum comment -> docstring above @enumx; value comments -> queryable
    # doc-attach lines AFTER the declaration.
    @test occursin("\"Subscription tier of a member.\"", src)
    @test occursin("\"Standard borrowing limits.\" Membership.BASIC", src)
    @test occursin("\"No tier selected.\" Membership.UNSPECIFIED", src)

    # Multi-paragraph enum comment kept as a triple-quoted docstring.
    @test occursin("The genre a book belongs to.", src)
    @test occursin("Used for shelving and search filters.", src)

    # Oneof comment -> leading field comment; members listed as `#` bullets.
    @test occursin("How the book can currently be obtained.", src)
    @test occursin("Number of physical copies on the shelf.", src)
    # oneof-member bullet: continuation line indented under the bullet, still
    # inside the leading `#` comment block.
    @test occursin("\n    #   Second line, to exercise sub-bullet continuation", src)

    # Escaping: `$` and `"` in a comment survive into a valid literal.
    @test occursin("\\\$variable", src)
    @test occursin("\\\"quotes\\\"", src)
end

@testset "docstrings: default off is byte-stable" begin
    on = gen_docs(; docstrings = true)
    off = gen_docs(; docstrings = false)
    @test on != off
    # No comment text at all leaks into the default (docstrings-off) output.
    @test !occursin("A single book in the catalog.", off)
    @test !occursin("# Fields", off)
    @test !occursin("International Standard Book Number", off)
    @test !occursin("Subscription tier of a member.", off)
    # Not even the bare leading `#` comment lines (incl. oneof member bullets)
    # leak in — the off path must stay byte-identical to the pre-feature output.
    @test !occursin("\n    # ", off)
end

@testset "docstrings: queryable after eval" begin
    src = gen_docs(; docstrings = true)
    mod = eval_generated(src, :GeneratedDocs)
    docof(expr) = string(Core.eval(mod, :(@doc $expr)))

    # Struct docstring carries the message comment. Field comments are plain
    # leading `#` comments on the struct fields, not part of the docstring, so
    # they are intentionally absent from `@doc Book`.
    @test occursin("A single book in the catalog.", docof(:Book))
    @test !occursin("International Standard Book Number", docof(:Book))

    # Enum + enum value docs are individually queryable.
    @test occursin("The genre a book belongs to.", docof(:(var"Book.Genre")))
    @test occursin("Made-up stories.", docof(:(var"Book.Genre".FICTION)))
    @test occursin("Subscription tier of a member.", docof(:Membership))
    @test occursin("Standard borrowing limits.", docof(:(Membership.BASIC)))
end

end # module TestDocstrings
