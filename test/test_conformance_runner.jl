# Conformance runner integration test.
#
# Drives Google's protobuf `conformance_test_runner` against the testee
# at `test/conformance/testee.jl`, applying our allowlist
# (`test/conformance/failure_list.txt`). The runner exits 0 when only
# allowlisted tests fail, non-zero when something *new* fails — that's
# the regression signal CI cares about.
#
# `ProtoBufDescriptors.obtain_conformance_test_runner` (in src/testing.jl)
# clones protobuf at a pinned tag and builds the runner via cmake on
# first use, then caches the binary in a Scratch.jl scratchspace owned
# by ProtoBufDescriptors. First invocation takes ~5–10 minutes;
# afterwards it's an O(1) lookup.
#
# Skipped only when:
#   - we're on Windows (the runner uses POSIX fork)
#   - cmake or git is not on PATH

module TestConformanceRunner

using Test
using ProtoBufDescriptors: obtain_conformance_test_runner

const CONFORMANCE_DIR = joinpath(@__DIR__, "conformance")
const TESTEE          = joinpath(CONFORMANCE_DIR, "testee.jl")
const FAILURE_LIST    = joinpath(CONFORMANCE_DIR, "failure_list.txt")

function _can_build()
    Sys.iswindows() && return false, "Windows (runner uses POSIX fork)"
    Sys.which("git")   === nothing && return false, "`git` not on PATH"
    Sys.which("cmake") === nothing && return false, "`cmake` not on PATH"
    return true, ""
end

@testset "conformance runner" begin
    @test isfile(TESTEE)
    @test Sys.isexecutable(TESTEE)
    @test isfile(FAILURE_LIST)

    ok, reason = _can_build()
    if !ok
        @info "skipping conformance run: $reason"
        @test_skip "conformance_test_runner unavailable: $reason"
    else
        runner = obtain_conformance_test_runner()
        cmd = `$runner --failure_list $FAILURE_LIST $TESTEE`
        out = IOBuffer()
        err = IOBuffer()
        proc = run(pipeline(ignorestatus(cmd); stdout = out, stderr = err))

        out_s = String(take!(out))
        err_s = String(take!(err))

        if proc.exitcode != 0
            tail_lines(s, n) = join(last(split(s, '\n'; keepempty = false), n), "\n")
            @info "conformance_test_runner failed; last 20 lines of stderr:" log = tail_lines(err_s, 20)
            @info "tail of stdout:" log = tail_lines(out_s, 5)
        end

        @test proc.exitcode == 0
    end
end

end # module
