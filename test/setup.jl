# Shared boilerplate for test files. Each test_*.jl wraps a module body
# whose first line is `include("setup.jl")`, so this file injects the same
# names (Test, ProtocGen, namespace aliases, fixture loader, and
# codegen-via-plugin helpers) into every test module.

using Test
using ProtocGen

# Namespace aliases used everywhere we touch protoc output.
const G  = ProtocGen.google.protobuf
const GC = ProtocGen.google.protobuf.compiler

# Test fixtures live in test/fixtures/pb/ as committed binary blobs;
# fixtures/README.md documents the layout and the regen recipe
# (`julia test/fixtures/regen.jl`).
const FIXTURES = joinpath(@__DIR__, "fixtures", "pb")
fixture(name) = read(joinpath(FIXTURES, name))

# Decode a FileDescriptorSet straight out of a fixture name.
function load_fdset(name::AbstractString)
    return ProtocGen.decode(fixture(name), G.FileDescriptorSet)
end

"""
    run_codegen(fdset_fixture, proto_paths) -> CodeGeneratorResponse

Drive the protoc plugin protocol end-to-end in-process: load a
FileDescriptorSet from `fixtures/pb/\$fdset_fixture`, build a
CodeGeneratorRequest naming the proto paths to generate, encode it,
hand it to `run_plugin`, and return the decoded response.
"""
function run_codegen(fdset_fixture::AbstractString, proto_paths::Vector{String})
    fdset = load_fdset(fdset_fixture)
    request = GC.CodeGeneratorRequest(
        file_to_generate = proto_paths,
        proto_file = fdset.file,
    )
    req_bytes = ProtocGen.encode(request)
    out_io = IOBuffer()
    return ProtocGen.run_plugin(IOBuffer(req_bytes), out_io)
end

"""
    eval_generated(content[, name=:Generated]) -> Module

Eval generated codegen source (the `.content` of a CodeGeneratorResponse.File)
into a fresh anonymous module so test files don't bleed names into each
other. `name` is just a label that shows up in stacktraces.
"""
function eval_generated(content::AbstractString, name::Symbol = :Generated)
    m = Module(name)
    Core.eval(m, Meta.parseall(content))
    return m
end

# `invokelatest`-wrapped wire ops. Generated types are eval'd partway through
# a test, so dispatch from our codec into them needs the latest world.
function decode_latest(::Type{T}, bytes::AbstractVector{UInt8}) where {T}
    return Base.invokelatest(ProtocGen.decode, bytes, T)
end

function encode_latest(x)
    return Base.invokelatest(ProtocGen.encode, x)
end
