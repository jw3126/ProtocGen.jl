module TestEnumMetadata

include("setup.jl")

# Drive codegen directly (not through the plugin protocol) so we can flip the
# `[codegen] enum_metadata` config on and off. `enum_meta.pb` carries an
# `extend google.protobuf.EnumValueOptions` block plus a `Color` enum whose
# values set scalar custom options.
function gen_meta(; enum_metadata::Bool)
    fdset = load_fdset("enum_meta.pb")
    file = only(f for f in fdset.file if something(f.name, "") == "enum_meta.proto")
    u = ProtocGen.Codegen.gather_universe(fdset.file)
    config =
        enum_metadata ? Dict("codegen" => Dict("enum_metadata" => true)) :
        Dict{String,Any}()
    return ProtocGen.Codegen.codegen(file, u; config = config)
end

@testset "enum_metadata: schema collection" begin
    fdset = load_fdset("enum_meta.pb")
    schema = ProtocGen.Codegen._collect_enum_metadata_schema(fdset.file)
    # Three scalar options, ordered by field number.
    @test [f.name for f in schema] == ["color_hex", "priority", "experimental"]
    @test [f.number for f in schema] == Int32[50001, 50002, 50003]
end

@testset "enum_metadata: emitted source" begin
    src = gen_meta(; enum_metadata = true)
    # Long-form, return-type-annotated method with a uniform NamedTuple shape.
    @test occursin(
        "function PB.enum_metadata(x::Color.T)::NamedTuple{(:color_hex, :priority, :experimental), Tuple{String, Int32, Bool}}",
        src,
    )
    # Every variant explicit; unset options fall back to defaults.
    @test occursin("if x == Color.UNSPECIFIED", src)
    @test occursin(
        "return (color_hex = \"\", priority = zero(Int32), experimental = false)",
        src,
    )
    @test occursin(
        "return (color_hex = \"ff0000\", priority = Int32(3), experimental = false)",
        src,
    )
    @test occursin("(experimental = true)", src) || occursin("experimental = true)", src)
    # Final else is the unreachable guard.
    @test occursin("error(\"enum_metadata: unreachable enum variant: \$x\")", src)
    # The symbol is surfaced in the generated module.
    @test occursin("using ProtocGen: enum_metadata", src)
    @test occursin("export Color, enum_metadata", src)
end

@testset "enum_metadata: default off is byte-stable" begin
    on = gen_meta(; enum_metadata = true)
    off = gen_meta(; enum_metadata = false)
    @test on != off
    # Nothing about the feature leaks into the default output.
    @test !occursin("enum_metadata", off)
    @test !occursin("color_hex", off)
end

@testset "enum_metadata: queryable after eval" begin
    src = gen_meta(; enum_metadata = true)
    mod = eval_generated(src, :GeneratedEnumMeta)
    meta = v -> Base.invokelatest(Core.eval(mod, :enum_metadata), Core.eval(mod, v))

    @test meta(:(Color.RED)) ==
          (color_hex = "ff0000", priority = Int32(3), experimental = false)
    @test meta(:(Color.GREEN)) ==
          (color_hex = "00ff00", priority = Int32(2), experimental = true)
    @test meta(:(Color.BLUE)) ==
          (color_hex = "0000ff", priority = Int32(0), experimental = false)
    # A value that sets no options returns the all-defaults tuple (not `(;)`).
    @test meta(:(Color.UNSPECIFIED)) ==
          (color_hex = "", priority = Int32(0), experimental = false)

    # Type stability: one concrete NamedTuple return type across all values.
    fn = Core.eval(mod, :enum_metadata)
    T = typeof(Core.eval(mod, :(Color.RED)))
    rt = Base.invokelatest(Base.return_types, fn, (T,))
    @test length(rt) == 1
    @test isconcretetype(rt[1])
    @test rt[1] ==
          NamedTuple{(:color_hex, :priority, :experimental),Tuple{String,Int32,Bool}}
end

@testset "enum_metadata: no methods when schema empty" begin
    # `sample.pb` has no EnumValueOptions extensions, so even with the flag on
    # nothing is emitted — a call would be a loud MethodError, never `(;)`.
    fdset = load_fdset("sample.pb")
    file = only(f for f in fdset.file if something(f.name, "") == "sample.proto")
    u = ProtocGen.Codegen.gather_universe(fdset.file)
    @test isempty(u.enum_metadata_schema)
    src = ProtocGen.Codegen.codegen(
        file,
        u;
        config = Dict("codegen" => Dict("enum_metadata" => true)),
    )
    @test !occursin("PB.enum_metadata", src)
end

end # module TestEnumMetadata
