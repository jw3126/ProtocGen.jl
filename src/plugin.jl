const _G = google.protobuf
const _GC = google.protobuf.compiler

const _FEATURE_PROTO3_OPTIONAL  = UInt64(1)
const _FEATURE_SUPPORTS_EDITIONS = UInt64(2)

"""
    generate(request) -> CodeGeneratorResponse

Run codegen for a `CodeGeneratorRequest` and return a `CodeGeneratorResponse`.
Pure function — no I/O. The `request.proto_file` field gives the
`FileDescriptorProto`s in topological order (each file appears before any
file that imports it); `request.file_to_generate` lists the filenames the
plugin is supposed to emit code for.

Phase 3 stub: this function does not yet emit code. It returns an empty
response with the appropriate feature bits cleared. Phase 4 fills in real
codegen.
"""
function generate(::_GC.CodeGeneratorRequest)
    # We advertise FEATURE_PROTO3_OPTIONAL so protoc forwards proto3 `optional`
    # fields to us instead of rejecting the request. The descriptor types
    # already carry the `proto3_optional` flag and Phase 5 will codegen it
    # correctly; until then the codegen is a stub.
    return _GC.CodeGeneratorResponse(
        nothing,
        _FEATURE_PROTO3_OPTIONAL,
        nothing,
        nothing,
        _GC.var"CodeGeneratorResponse.File"[],
    )
end

"""
    run_plugin(input::IO=stdin, output::IO=stdout) -> CodeGeneratorResponse

Implement the `protoc` plugin protocol: read a `CodeGeneratorRequest` blob
from `input`, hand it to [`generate`](@ref), and write the resulting
`CodeGeneratorResponse` blob to `output`.

Per the plugin contract, *any* error that the plugin can describe to the
user — including malformed input or codegen failures — is reported by
populating `CodeGeneratorResponse.error` and exiting cleanly. The caller
(`bin/protoc-gen-julia`) should still propagate exceptions that indicate the
plugin itself is broken (I/O failure, signal, etc.) by letting them escape.
"""
function run_plugin(input::IO=stdin, output::IO=stdout)
    blob = read(input)
    response = try
        request = decode(ProtoDecoder(IOBuffer(blob)), _GC.CodeGeneratorRequest)
        generate(request)
    catch e
        _GC.CodeGeneratorResponse(
            sprint(showerror, e),
            nothing,
            nothing,
            nothing,
            _GC.var"CodeGeneratorResponse.File"[],
        )
    end
    out_io = IOBuffer()
    encode(ProtoEncoder(out_io), response)
    write(output, take!(out_io))
    return response
end
