# Conformance test harness

This directory wires Google's protobuf
[`conformance_test_runner`](https://github.com/protocolbuffers/protobuf/tree/main/conformance)
to a Julia testee that drives our codec end-to-end.

```text
+--------+   pipe   +-------------+
| runner | <------> | testee.jl   |
| (C++)  |          | (Julia)     |
+--------+          +-------------+
   ^
   |
   reads test corpus (test_messages_proto2 / proto3 / WKTs),
   sends ConformanceRequest, expects matching ConformanceResponse
```

The runner is *not* shipped here — it's built from upstream protobuf
on first use and cached in a Scratch.jl scratchspace owned by this
package (`~/.julia/scratchspaces/<UUID>/conformance-runner-v25.9-1/`).
`test/test_conformance_runner.jl` calls `obtain_runner()`
unconditionally: the first run takes ~5–10 min to clone + cmake-build,
subsequent runs are an O(1) lookup. The test is skipped only on
Windows (runner uses POSIX `fork`) or when `cmake`/`git` are missing
from PATH.

## Files

- `proto/conformance.proto` — vendored verbatim from protobuf v25.9.
  Defines the `ConformanceRequest` / `ConformanceResponse` wire
  protocol the runner uses to talk to the testee.
- `regen.jl` — rebuilds `conformance_descriptors.pb` from
  `conformance.proto` plus the test_messages_proto{2,3} fixtures
  using `protoc --include_imports`. Run once after editing any of
  those proto files.
- `conformance_descriptors.pb` — committed `FileDescriptorSet`
  bundling the conformance protocol with both test_messages files
  and their transitive WKT dependencies. The testee reads this at
  startup, runs our codegen across all of it, and evals the
  resulting Julia source into in-process modules.
- `testee.jl` — the testee executable. Self-executing Julia script
  (the same shebang trick `bin/protoc-gen-julia` uses). Reads
  framed `ConformanceRequest` blobs from stdin, dispatches via
  decode → encode through our codec, writes framed
  `ConformanceResponse` blobs to stdout. JSON / JSPB / TEXT_FORMAT
  inputs and outputs are reported via `response.skipped`.
- `failure_list.txt` — allowlist of tests known to fail in v1. The
  runner treats listed names as expected failures, so the suite
  passes iff no *new* failures appear. The header inside the file
  groups failures by category and explains the underlying gaps.
- The runner itself is *not* in this directory. It's built on
  demand by `ProtocGen.obtain_conformance_test_runner()`
  (defined in `src/testing.jl`), which clones protobuf at a pinned
  tag, cmake-builds the conformance target, and caches the binary
  in a Scratch.jl scratchspace.

## Running

```sh
julia --project test/runtests.jl
```

The first run pays ~5–10 minutes for clone + build; subsequent runs
reuse the cached binary. To run only the conformance test:

```sh
julia --project -e 'using Test; include("test/test_conformance_runner.jl")'
```

Override knob: set `CONFORMANCE_TEST_RUNNER=/path/to/binary` to skip
the build entirely and use a binary you already have. Useful in CI
where the runner is provisioned via a separate cache action.

## Force a rebuild

Bumping `_CONFORMANCE_PROTOBUF_TAG` or `_CONFORMANCE_RUNNER_VERSION`
in `src/testing.jl` orphans the old scratchspace (its key is
suffixed with the version); the next test run rebuilds. Or call
`obtain_conformance_test_runner(rebuild = true)` to force one
explicitly. To delete the cache manually:

```julia
using Scratch, ProtocGen
Scratch.delete_scratch!(ProtocGen, "conformance-runner-v25.9-1")
```

To run the runner directly (for debugging) and see every WARNING /
ERROR line:

```sh
/path/to/conformance_test_runner \
    --failure_list test/conformance/failure_list.txt \
    test/conformance/testee.jl
```

## Current state (protobuf v25.9 runner)

```
1071 successes, 729 skipped, 188 expected failures, 0 unexpected failures
```

The 729 skipped cases are JSON, JSPB, and TEXT_FORMAT inputs/outputs
that v1 doesn't implement (the testee returns `response.skipped` for
those). The 188 expected failures fall into two underlying gaps,
both real binary-codec bugs to be addressed in a focused codec pass:

- **Lenient parser**: our decoder accepts several malformed-input
  cases the spec wants rejected (premature EOF in known/unknown
  fields, illegal zero field number, oversized BOOL varints).
- **Map-entry edge cases**: the synthetic *Entry message decoder
  rejects empty entries, duplicate key/value fields within an
  entry, and value-before-key field order.

See the header in `failure_list.txt` for the per-category breakdown.

## Updating the failure list

When the codec or codegen changes — say a parser fix lands — re-run
the suite without `--failure_list` to capture the new ground truth:

```sh
/path/to/conformance_test_runner test/conformance/testee.jl 2>/tmp/conf.txt
grep -aoE '^ERROR, test=[A-Za-z0-9_.\[\]]+' /tmp/conf.txt \
    | sed 's/^ERROR, test=//' | sort -u > /tmp/new_fails.txt
```

Then prune entries that no longer fail and add genuinely new ones
into `failure_list.txt`, preserving the `#`-prefixed header.
