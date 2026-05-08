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
function generate(request::_GC.CodeGeneratorRequest)
    # We advertise FEATURE_PROTO3_OPTIONAL so protoc forwards proto3 `optional`
    # fields to us instead of rejecting the request. Phase 5 will actually use
    # those bits; the Phase 4 happy-path codegen treats the field as a bare
    # proto3 scalar (no presence) which is wire-compatible.
    by_name = Dict{String,_G.FileDescriptorProto}()
    for f in request.proto_file
        name = something(f.name, "")
        by_name[name] = f
    end
    # Universe spans every entry in `proto_file` — that is the to-generate
    # files plus their transitive imports. Cross-file `type_name`
    # references in any generated file resolve against this shared table.
    universe = Codegen.gather_universe(request.proto_file)
    files = _GC.var"CodeGeneratorResponse.File"[]
    for path in request.file_to_generate
        haskey(by_name, path) || continue
        proto = by_name[path]
        out_name = string(replace(path, r"\.proto$" => ""), "_pb.jl")
        content = Codegen.codegen(proto, universe)
        push!(files, _GC.var"CodeGeneratorResponse.File"(out_name, nothing, content, nothing))
    end
    # Driver file: only useful when more than one .proto is being generated
    # (single-file outputs don't benefit from a wrapping skeleton). The user
    # `include`s it from wherever they want their namespace rooted.
    if length(request.file_to_generate) > 1
        driver = Codegen.codegen_driver(collect(request.file_to_generate), by_name)
        push!(files, _GC.var"CodeGeneratorResponse.File"(
            "_pb_includes.jl", nothing, driver, nothing))
    end
    return _GC.CodeGeneratorResponse(
        nothing,
        _FEATURE_PROTO3_OPTIONAL,
        nothing,
        nothing,
        files,
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
        # Include the backtrace in `response.error` so codegen bugs surface
        # with a real stack trace instead of a one-line message. The protoc
        # plugin contract treats this string as user-facing text — it
        # appears verbatim in protoc's stderr — so a trace there is the
        # only signal a user gets when something goes wrong inside us.
        bt = catch_backtrace()
        msg = sprint() do io
            showerror(io, e)
            println(io)
            Base.show_backtrace(io, bt)
        end
        _GC.CodeGeneratorResponse(
            msg,
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
