"""
    PluginApp

Pkg.Apps entry point for the `protoc-gen-julia` executable. Both the
in-repo `bin/protoc-gen-julia` shim and the Pkg.Apps-installed binary
dispatch through [`PluginApp.@main`](@ref) so the two routes stay in
lockstep.
"""
module PluginApp

import ..ProtoBufDescriptors: run_plugin

function (@main)(ARGS)
    if !isempty(ARGS)
        write(stderr, "protoc-gen-julia: unexpected arguments: ", join(ARGS, " "), "\n")
        return 2
    end
    run_plugin(stdin, stdout)
    return 0
end

end # module
