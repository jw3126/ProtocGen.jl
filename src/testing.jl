# Test-infrastructure helpers that live in the runtime package so they
# can be invoked from anyone's test suite, not just ours.
#
# So far this just hosts `obtain_conformance_test_runner` — see its
# docstring for usage. The submodule will grow if we add more shared
# test plumbing.

using Scratch: get_scratch!

"""
    greeter_file_descriptor() -> google.protobuf.FileDescriptorProto

In-process `FileDescriptorProto` for the canonical greeter test service:
`HelloRequest`/`HelloReply` messages, a unary `SayHello`, and a
server-streaming `SayHelloStream` (package `greeter`). Built without
protoc so test suites stay hermetic. Shared by ProtocGen's own
service-codegen tests and transport packages (e.g. ProtocGenConnect)
so the fixture cannot drift between suites.
"""
function greeter_file_descriptor()
    G = google.protobuf
    function msg(name, fields...)
        G.DescriptorProto(;
            name = name,
            field = collect(fields),
            nested_type = G.DescriptorProto[],
            enum_type = G.EnumDescriptorProto[],
            extension_range = G.var"DescriptorProto.ExtensionRange"[],
            oneof_decl = G.OneofDescriptorProto[],
            reserved_range = G.var"DescriptorProto.ReservedRange"[],
            reserved_name = String[],
            extension = G.FieldDescriptorProto[],
        )
    end
    function fld(name, number)
        G.FieldDescriptorProto(;
            name = name,
            number = Int32(number),
            label = G.var"FieldDescriptorProto.Label".OPTIONAL,
            type = G.var"FieldDescriptorProto.Type".STRING,
        )
    end
    return G.FileDescriptorProto(;
        name = "greeter.proto",
        package = "greeter",
        syntax = "proto3",
        dependency = String[],
        public_dependency = Int32[],
        weak_dependency = Int32[],
        enum_type = G.EnumDescriptorProto[],
        extension = G.FieldDescriptorProto[],
        message_type = [
            msg("HelloRequest", fld("name", 1)),
            msg("HelloReply", fld("message", 1)),
        ],
        service = [
            G.ServiceDescriptorProto(;
                name = "Greeter",
                method = [
                    G.MethodDescriptorProto(;
                        name = "SayHello",
                        input_type = ".greeter.HelloRequest",
                        output_type = ".greeter.HelloReply",
                        client_streaming = false,
                        server_streaming = false,
                    ),
                    G.MethodDescriptorProto(;
                        name = "SayHelloStream",
                        input_type = ".greeter.HelloRequest",
                        output_type = ".greeter.HelloReply",
                        client_streaming = false,
                        server_streaming = true,
                    ),
                ],
            ),
        ],
    )
end

const _CONFORMANCE_PROTOBUF_TAG = "v25.9"
const _CONFORMANCE_RUNNER_VERSION = "v25.9-1"
const _CONFORMANCE_PROTOBUF_REPO = "https://github.com/protocolbuffers/protobuf.git"
const _CONFORMANCE_SCRATCH_KEY = "conformance-runner-$_CONFORMANCE_RUNNER_VERSION"

function _conformance_cache_dir()
    return get_scratch!(@__MODULE__, _CONFORMANCE_SCRATCH_KEY)
end

function _conformance_runner_path()
    explicit = get(ENV, "CONFORMANCE_TEST_RUNNER", "")
    isempty(explicit) || return explicit
    return joinpath(_conformance_cache_dir(), "build", "conformance_test_runner")
end

function _conformance_check_tool(name::AbstractString)
    Sys.which(name) === nothing &&
        error("obtain_conformance_test_runner: `$name` not found on PATH")
    return nothing
end

function _conformance_clone_source(src::AbstractString)
    if isdir(joinpath(src, ".git"))
        return nothing
    end
    rm(src; force = true, recursive = true)
    mkpath(dirname(src))
    @info "obtain_conformance_test_runner: cloning protobuf $_CONFORMANCE_PROTOBUF_TAG into $src (one-time)"
    run(`git clone --depth 1 --branch $_CONFORMANCE_PROTOBUF_TAG --recurse-submodules
         --shallow-submodules $_CONFORMANCE_PROTOBUF_REPO $src`)
    return nothing
end

function _conformance_configure_and_build(src::AbstractString, build::AbstractString)
    mkpath(build)
    cmake_args = String[
        "-DCMAKE_BUILD_TYPE=Release",
        "-Dprotobuf_BUILD_TESTS=OFF",
        "-Dprotobuf_BUILD_CONFORMANCE=ON",
        "-Dprotobuf_BUILD_EXAMPLES=OFF",
        "-Dprotobuf_ABSL_PROVIDER=module",
        "-Dprotobuf_JSONCPP_PROVIDER=module",
    ]
    @info "obtain_conformance_test_runner: cmake configure"
    cd(build) do
        run(`cmake $cmake_args $src`)
    end
    @info "obtain_conformance_test_runner: cmake build (this can take ~5–10 min on first run)"
    cd(build) do
        run(`cmake --build . --target conformance_test_runner -j$(Sys.CPU_THREADS)`)
    end
    return nothing
end

"""
    obtain_conformance_test_runner(; rebuild = false) -> String

Return an absolute path to a working `conformance_test_runner` binary
from Google's protobuf project. The binary is what
`ProtocGen`' own conformance test drives, but anyone wiring
their own protobuf-related tests can call this too.

The runner is cached in a Scratch.jl scratchspace owned by
`ProtocGen` (`~/.julia/scratchspaces/<UUID>/conformance-runner-…/`).
First call clones protobuf at a pinned tag and builds the conformance
target via `cmake` (~5–10 min). Subsequent calls return the cached
path immediately. Pass `rebuild = true` to wipe and rebuild.

Honors the `CONFORMANCE_TEST_RUNNER` env var: when set to an existing
executable, that path is returned and no build happens — useful for CI
that provisions the runner via a separate cache step.

Throws on Windows: the runner uses POSIX `fork`, which has no Windows
equivalent. Throws if `git` or `cmake` is missing on PATH.
"""
function obtain_conformance_test_runner(; rebuild::Bool = false)
    if Sys.iswindows()
        error(
            "obtain_conformance_test_runner: cannot build on Windows (runner uses POSIX fork)",
        )
    end

    explicit = get(ENV, "CONFORMANCE_TEST_RUNNER", "")
    if !isempty(explicit)
        isfile(explicit) && Sys.isexecutable(explicit) ||
            error("CONFORMANCE_TEST_RUNNER=$explicit is not an executable file")
        return explicit
    end

    p = _conformance_runner_path()
    if !rebuild && isfile(p) && Sys.isexecutable(p)
        return p
    end

    _conformance_check_tool("git")
    _conformance_check_tool("cmake")

    root = _conformance_cache_dir()
    src = joinpath(root, "src")
    build = joinpath(root, "build")

    _conformance_clone_source(src)
    _conformance_configure_and_build(src, build)

    isfile(p) && Sys.isexecutable(p) || error(
        "obtain_conformance_test_runner: build finished but $p is missing or not executable",
    )
    return p
end
