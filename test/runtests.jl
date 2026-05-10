using Aqua
using ProtocGenJulia
using Test

# Each `test_*.jl` is wrapped in its own module that begins with
# `include("setup.jl")`. setup.jl provides the shared aliases (G/GC),
# fixture loader, codegen-via-plugin helper, and `invokelatest`-wrapped
# wire ops; see test/setup.jl.

@testset "smoke" begin
    @test isdefined(ProtocGenJulia, :PACKAGE_VERSION)
    @test ProtocGenJulia.PACKAGE_VERSION isa VersionNumber
end

include("test_vbyte.jl")
include("test_codec_primitives.jl")
include("test_bootstrap_descriptors.jl")
include("test_plugin.jl")
include("test_codegen.jl")
include("test_presence.jl")
include("test_proto2.jl")
include("test_codegen_bugs.jl")
include("test_conformance_corpus.jl")
include("test_wkt.jl")
include("test_corpus_wkt.jl")
include("test_json.jl")
include("test_conformance_runner.jl")

@testset "Aqua" begin
    Aqua.test_all(ProtocGenJulia)
end
