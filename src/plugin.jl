const _G = google.protobuf
const _GC = google.protobuf.compiler

const _FEATURE_PROTO3_OPTIONAL = UInt64(1)
const _FEATURE_SUPPORTS_EDITIONS = UInt64(2)

"""
    _parse_plugin_options(parameter::Union{Nothing,String}) -> Dict{String,Any}

Decode the `request.parameter` string protoc passes through from
`--julia_opt=k1=v1,k2=v2`. The only currently-recognized option is
`config=path.toml`, whose value is loaded as a TOML file and merged
into the returned options dict under the key `"config"`.
"""
function _parse_plugin_options(parameter::Union{Nothing,String})
    opts = Dict{String,Any}()
    parameter === nothing && return opts
    isempty(parameter) && return opts
    for entry in split(parameter, ',')
        kv = split(entry, '='; limit = 2)
        length(kv) == 2 || continue
        key, val = strip(kv[1]), strip(kv[2])
        if key == "config"
            opts["config"] = TOML.parsefile(String(val))
        end
    end
    return opts
end

"""
    generate(request) -> CodeGeneratorResponse

Run codegen for a `CodeGeneratorRequest` and return a `CodeGeneratorResponse`.
Pure function — no I/O except the optional config-file read. The
`request.proto_file` field gives the `FileDescriptorProto`s in
topological order (each file appears before any file that imports
it); `request.file_to_generate` lists the filenames the plugin is
supposed to emit code for.

When the user passes `--julia_opt=config=path.toml`, the file's
`[batteries]` and `[enumbatteries]` tables are forwarded as keyword
arguments to per-type `StructHelpers.@batteries` /
`StructHelpers.@enumbatteries` invocations in the generated source.
"""
function generate(request::_GC.CodeGeneratorRequest)
    # We advertise FEATURE_PROTO3_OPTIONAL so protoc forwards proto3 `optional`
    # fields to us instead of rejecting the request.
    by_name = Dict{String,_G.FileDescriptorProto}()
    for f in request.proto_file
        name = something(f.name, "")
        by_name[name] = f
    end
    plugin_opts = _parse_plugin_options(request.parameter)
    config = get(plugin_opts, "config", Dict{String,Any}())
    # Universe spans every entry in `proto_file` — that is the to-generate
    # files plus their transitive imports. Cross-file `type_name`
    # references in any generated file resolve against this shared table.
    universe = Codegen.gather_universe(request.proto_file)
    files = _GC.var"CodeGeneratorResponse.File"[]
    for path in request.file_to_generate
        haskey(by_name, path) || continue
        proto = by_name[path]
        out_name = string(replace(path, r"\.proto$" => ""), "_pb.jl")
        content = Codegen.codegen(proto, universe; config = config)
        push!(
            files,
            _GC.var"CodeGeneratorResponse.File"(
                out_name,
                nothing,
                content,
                nothing,
                UInt8[],
            ),
        )
    end
    # Driver file: emitted unconditionally so the consumer's `include` call
    # works the same whether the request has one or many .proto files. With
    # a single file the driver still pulls its weight by declaring the
    # proto-package module skeleton (otherwise the file's struct decls would
    # end up flat at the include site, exposing a different public API).
    driver = Codegen.codegen_driver(collect(request.file_to_generate), by_name)
    push!(
        files,
        _GC.var"CodeGeneratorResponse.File"(
            "_pb_includes.jl",
            nothing,
            driver,
            nothing,
            UInt8[],
        ),
    )
    return _GC.CodeGeneratorResponse(
        nothing,
        _FEATURE_PROTO3_OPTIONAL,
        nothing,
        nothing,
        files,
        UInt8[],
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
function run_plugin(input::IO = stdin, output::IO = stdout)
    blob = read(input)
    response = try
        request = decode(blob, _GC.CodeGeneratorRequest)
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
            UInt8[],
        )
    end
    write(output, encode(response))
    return response
end
