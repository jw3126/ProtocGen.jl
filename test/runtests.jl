using Aqua
using JET
using ProtoBufDescriptors
using Test

function is_ci()
    return get(ENV, "CI", "") in ("true", "True")
end

@testset "ProtoBufDescriptors" begin
    @testset "smoke" begin
        @test isdefined(ProtoBufDescriptors, :PACKAGE_VERSION)
        @test ProtoBufDescriptors.PACKAGE_VERSION isa VersionNumber
    end

    include("test_vbyte.jl")
    include("test_codec_primitives.jl")
    include("test_bootstrap_descriptors.jl")
    include("test_plugin.jl")
    include("test_codegen.jl")

    @testset "Aqua" begin
        Aqua.test_all(ProtoBufDescriptors)
    end
end
