# ProtoBufDescriptors.jl — project context for Claude

This file is read at the start of every Claude Code session in this repo. It captures
the durable design decisions and the current state of work so a fresh session can
continue without re-deriving context.

## What this package is

A descriptor-driven Protocol Buffers compiler and runtime for Julia. It consumes
`FileDescriptorSet` blobs (the output of `protoc`) and emits Julia source. It can
run as a `protoc-gen-julia` plugin or as an offline generator. It does **not**
parse `.proto` text directly — that is `protoc`'s job.

This is a parallel package to ProtoBuf.jl, not a fork or replacement. The design
goal is to fix two known issues in ProtoBuf.jl:

1. Field presence semantics for proto3 `optional` (issue
   [JuliaIO/ProtoBuf.jl#293](https://github.com/JuliaIO/ProtoBuf.jl/issues/293)).
2. Silent defaulting of missing proto2 `required` fields.

## v1 design decisions (locked)

These were settled in the planning conversation and should not be re-litigated
without explicit reason.

- **Syntax support**: proto2 + proto3. Editions deferred to v2.
- **Presence model**: `Union{Nothing, T}` for every nullable singular field —
  proto3 `optional`, proto2 `optional`, and singular submessages. `nothing`
  default; submessages default to `nothing`, **not** `Ref{T}()`.
- **proto3 `optional` detection**: use `FieldDescriptorProto.proto3_optional=true`
  with `oneof_index` set (synthetic oneofs) — that's how `protoc` already
  represents it.
- **proto2 `required`**: emit non-nullable type. Decode-time validation accumulates
  a "saw this tag" bitset and throws `DecodeError("required field X missing")`
  if any unset.
- **Encode side**: skip iff `field === nothing`. **Never** suppress on
  equal-to-default — that is the ProtoBuf.jl bug.
- **Extensions**: not supported in v1. Skip-unknown-tags only (which the wire
  codec already does). Document as known limitation. Custom options are silently
  dropped.
- **Groups**: deprecated proto2 wire format. Round-trip them but document as
  legacy.
- **Maps**: detect synthesized message types via `map_entry=true`. Emit `Dict{K,V}`.
- **Real oneofs** (non-synthetic): `Union{Nothing, OneOf{Union{T1,T2,...}}}`.
- **Package shape**: monolithic for v1. Runtime/codegen split deferred to v2.
- **Generated API**: fresh, with a small ProtoBuf.jl-compat shim for migration.
  Not a drop-in replacement.
- **JSON mapping**: out of scope for v1.
- **gRPC stubs**: out of scope for v1; separate downstream package later.
- **Reflection / dynamic messages**: out of scope for v1.
- **Conformance**: wire up Google's runner; allowlist JSON and editions
  categories; partial pass acceptable for v1.

## Phase plan

Each phase is independently mergeable. Approximate sizes for one engineer.

| Phase | Subject | Status |
|---|---|---|
| 0 | Repo skeleton | DONE |
| 1 | Wire codec copied from ProtoBuf.jl | DONE |
| 2 | Bootstrap descriptor types (`descriptor.proto`, `plugin.proto`) | DONE |
| 3 | Plugin protocol shim (`bin/protoc-gen-julia`, offline driver) | DONE |
| 4 | Codegen happy path (proto3, no presence) | DONE |
| 5 | Presence — `Union{Nothing,T}` (the headline feature) | DONE |
| 6 | proto2 `required`, maps, oneofs, packed, groups | NEXT |
| 7 | Well-known types | pending |
| 8 | Self-bootstrap (regenerate descriptor types from own codegen) | pending |
| 9 | Conformance + golden corpus | pending |
| 10 | Startup latency (`PackageCompiler` sysimage) | pending |
| 11 | Docs + v0.1.0 release | pending |

**Total v0.1.0 estimate**: ~8–9 weeks for one focused engineer.

## Current state

- `Project.toml` UUID `b5fc38b8-670b-4930-8529-238e2ca71835`. Deps: BufferedStreams, EnumX, TOML.
- `src/codec/` is `ProtoBuf.jl/src/codec/` minus the legacy
  `LengthDelimitedProtoDecoder`/`GroupProtoDecoder` block.
- `src/ProtoBufDescriptors.jl` re-exports the codec API, defines `OneOf` and
  `AbstractProtoBufMessage`, exposes the metadata-API stubs
  (`reserved_fields`, `extendable_field_numbers`, `oneof_field_types`,
  `field_numbers`, `default_values`) that the bootstrap installs methods for,
  includes `gen/google/google.jl`, and includes `src/plugin.jl` (the protoc
  plugin protocol).
- `src/plugin.jl` exposes `generate(request)` (the codegen entry point —
  Phase 3 stub returns an empty response with `FEATURE_PROTO3_OPTIONAL` set;
  Phase 4 fills it in) and `run_plugin(in=stdin, out=stdout)` (read
  `CodeGeneratorRequest` blob, dispatch to `generate`, write
  `CodeGeneratorResponse` blob; codegen errors are reported via
  `response.error`, not exceptions, per the protoc plugin contract).
- `bin/protoc-gen-julia` is a self-executing julia script that activates the
  package and calls `run_plugin()`. Verified end-to-end with `protoc 3.20.x`:
  protoc invokes the script, codegen emits Julia for each input proto, and
  protoc writes the resulting `.jl` files to the output directory.
- `src/codegen.jl` (module `Codegen`) emits Julia from a `FileDescriptorProto`.
  Phase 4 covers proto3 happy path: all 16 scalar wire encodings (varint,
  zigzag, fixed, float, double, bool, string, bytes), enums, singular
  submessages (`Union{Nothing,T}` defaulted to `nothing`), repeated scalars
  (packed) and submessages, nested messages and enums (emitted at top level
  with `var"Outer.Inner"`-style names). Topological sort ensures referenced
  types are defined before their users; recursive types are not yet
  supported. Generated `decode`/`encode`/`_encoded_size` parameters are
  underscore-prefixed (`_d`/`_e`/`_x`) so they can't collide with proto field
  names like `d` (a real foot-gun discovered while the `Wide.d::Float64`
  field of the corpus test shadowed the decoder).
- Phase 5 layers presence on top: scalar fields with `field.proto3_optional ==
  true` (proto3 explicit `optional`, with its synthetic oneof) become
  `Union{Nothing,T}` defaulted to `nothing` and skip-iff-`nothing` on encode.
  As a result an explicit-optional scalar set to zero round-trips correctly:
  the value travels on the wire, and unset ≠ default-zero. proto2
  `optional` will share the same predicate when proto2 codegen lands in
  Phase 6.
- `gen/` holds the Phase 2 bootstrap.
  - `gen/proto/` — `.proto` source inputs. `descriptor.proto` is the older
    ProtoBuf.jl-vendored copy (parseable by ProtoBuf.jl's text parser) with
    `optional bool proto3_optional = 17` hand-patched into
    `FieldDescriptorProto`. `plugin.proto` is `/usr/include/google/protobuf/compiler/plugin.proto`.
  - `gen/google/` — Julia bindings produced by a fork of `ProtoBuf.jl`
    (branch `proto3-optional-scalars`, with the `_is_proto3_optional_scalar`
    predicate broadened to also fire on proto2 `optional`) and then hand-
    patched to import `ProtoBufDescriptors` instead of `ProtoBuf`. Headers
    in `descriptor_pb.jl` and `plugin_pb.jl` mark them as bootstrap files.
  - `gen/README.md` documents how to reproduce the bootstrap.
- `test/test_vbyte.jl` ported as-is from ProtoBuf.jl (1161 tests).
- `test/test_codec_primitives.jl` is a fresh hand-written round-trip suite
  (varints / fixed / zigzag / floats / bool / tag encoding).
- `test/test_bootstrap_descriptors.jl` decodes a small `FileDescriptorSet`
  blob produced by `protoc` (captured as bytes so `protoc` isn't a test dep)
  and asserts `proto3_optional` + synthetic-oneof detection.
- `test/test_plugin.jl` exercises `run_plugin` end-to-end in-process:
  encode a `CodeGeneratorRequest`, pipe it through `run_plugin`, decode and
  assert the response. Also tests the malformed-input → `response.error`
  contract and that `bin/protoc-gen-julia` is executable. The actual
  `protoc` subprocess test is intentionally not in the suite (cold julia
  start adds ~10s per invocation; revisit when Phase 10 sysimage lands).
- `test/test_codegen.jl` exercises Phase 4 codegen end-to-end. The "happy
  path" test runs the captured `sample.pb` `FileDescriptorSet` through
  `run_plugin`, evals the generated module into a fresh `Module`, and
  verifies (a) round-trip, (b) decoding bytes that came out of
  `protoc --encode`. The "every wire encoding" corpus test does the same
  for a richer proto exercising every scalar type, an enum, nested messages,
  and three flavors of repeated.
- `test/test_presence.jl` exercises Phase 5: a proto3 `optional int32`
  encoded by `protoc` with `maybe: 0` (wire bytes include field 2 = 0)
  decodes to `Int32(0)`, and the same proto encoded with `maybe` unset
  decodes to `nothing`. Re-encode of either is byte-identical to what
  `protoc --encode` would have produced.
- **`test/test_encode.jl` and `test/test_decode.jl` were NOT ported** — they
  exercise the codec via generated structs and depend on `protojl` /
  `test_messages_for_codec_pb.jl`. Port them in Phase 4 once codegen exists.
- CI matrix mirrors ProtoBuf.jl: 1.10 / 1 / nightly × Linux / Windows / macOS ×
  x64 / aarch64.
- 1401 / 1401 tests pass.

### Known bootstrap caveats

The Phase 2 bootstrap inherits two of ProtoBuf.jl's remaining behaviors:

- proto2 `optional` enum fields are still emitted as bare enum-typed Julia
  fields with the equal-to-default skip on encode. The proto2-optional bug
  was already fixed for *scalar* fields in the fork (the headline win), but
  the analogous fix for enums lives in a different ProtoBuf.jl code path
  (`jl_type_init_value(::FieldType{ReferencedType})`) and was deliberately
  left for later. In practice this only matters when re-encoding a
  descriptor where an enum field was intentionally set to its first enum
  value — `protoc` itself would also accept a missing field there.
- proto2 `required` is not validated.

Both will be addressed by Phase 5 / Phase 6 in our own codegen, and the
bootstrap is regenerated cleanly from that codegen in Phase 8.

## Reference paths

- **ProtoBuf.jl source of truth**: `/home/jan/.julia/dev/ProtoBuf` — read-only
  reference for porting and bootstrap. Do not modify.
- **This repo**: `/home/jan/.julia/dev/ProtoBufDescriptors`.
- **Vendored well-known types upstream**: `/home/jan/.julia/dev/ProtoBuf/src/google/protobuf/`
  (will be vendored here in Phase 7).
- **Test corpora to copy in Phase 9**: `/home/jan/.julia/dev/ProtoBuf/test/test_protos/google/`
  (`unittest_proto2/3.proto`, `test_messages_proto2/3.proto`,
  `unittest_well_known_types.proto`).

## Attribution

The wire codec under `src/codec/` is copied with light modifications from
ProtoBuf.jl (MIT, copyright 2022 RelationalAI / Tomáš Drvoštěp / contributors).
Attribution is in `LICENSE.md` and `README.md`. Phase 2 will use ProtoBuf.jl
as a one-shot bootstrap to compile `descriptor.proto`. After Phase 8
(self-bootstrap), ProtoBuf.jl is no longer involved at runtime or build time.

## How to resume

On the first turn of a fresh session:

1. Read this file (you are doing that now).
2. Read `README.md` and skim `src/ProtoBufDescriptors.jl` and `src/codec/Codecs.jl`
   to confirm current state matches what's described above.
3. Re-create the TaskList from the phase table above (TaskList is session-scoped
   and does not survive across sessions). Mark phases 0 and 1 completed; mark
   the next pending phase as the in-progress one.
4. Confirm with the user before starting work on a new phase, unless explicitly
   in auto mode.

## Conventions specific to this project

These are in addition to the user's global `~/.claude/CLAUDE.md` rules
(julia-mcp, long-form `function ... end`, no emojis, etc.).

- **Do not weaken tests to make them pass.** If something fails, fix the code
  or ask the user. Same rule as ProtoBuf.jl's CI.
- **Aqua + JET in CI from day one.** Both are wired up. Don't disable a check
  to silence a failure; fix the underlying issue.
- **Before exporting a name, make sure it's defined.** Aqua's
  `test_undefined_exports` will fail otherwise (this caught a premature
  `protojl` export in Phase 0).
- **Codec module is shared verbatim with ProtoBuf.jl for now.** Avoid divergent
  changes until Phase 8 lets us own it cleanly. Bug fixes that should also
  benefit ProtoBuf.jl are best contributed upstream.
- **Bootstrap files (Phase 2 output) are temporary.** Mark them clearly in
  comments. Phase 8 replaces them with self-generated equivalents and adds a
  CI check that regen produces no diff.
