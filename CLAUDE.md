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
  if any unset. Required submessages use `Ref{T}()` (uninitialized) so the
  validation step throws before anyone touches the Ref.
- **Encode side**: skip iff `field === nothing`. **Never** suppress on
  equal-to-default — that is the ProtoBuf.jl bug.
- **Extensions**: not supported in v1. Skip-unknown-tags only. Custom options
  silently dropped.
- **Groups**: deprecated proto2 wire format. Not supported in v1; codegen
  errors clearly on `TYPE_GROUP`.
- **Maps**: detect via `MessageOptions.map_entry == true`. Emit
  `OrderedDict{K,V}` (insertion-ordered, from OrderedCollections.jl) so
  re-encode preserves wire order. Codec dispatches on `AbstractDict{K,V}`
  so user-supplied plain `Dict` works for encode (without ordering guarantees).
- **Real oneofs** (non-synthetic): `Union{Nothing, OneOf{Union{T1,T2,...}}}`.
- **Package shape**: monolithic for v1. Runtime/codegen split deferred to v2.
- **Generated API**: fresh, with a small ProtoBuf.jl-compat shim for migration.
  Not a drop-in replacement.
- **gRPC stubs / reflection / dynamic messages**: out of scope for v1.

## Phase plan

| Phase | Subject | Status |
|---|---|---|
| 0 | Repo skeleton | DONE |
| 1 | Wire codec copied from ProtoBuf.jl | DONE |
| 2 | Bootstrap descriptor types | DONE |
| 3 | Plugin protocol shim | DONE |
| 4 | Codegen happy path (proto3) | DONE |
| 5 | Presence — `Union{Nothing,T}` | DONE |
| 6 | proto2 `required`, maps, oneofs, packed (groups deferred) | DONE |
| 7 | Well-known types (all 11) | DONE |
| 8 | Self-bootstrap | DONE |
| 9 | Conformance + golden corpus | DONE |
| 12 | JSON mapping (encode + decode + WKT specials) | DONE |
| 10 | Startup latency (`PackageCompiler` sysimage) | pending |
| 11 | Docs + v0.1.0 release | pending |

**Conformance state (protobuf v25.9, Required)**: `2015 successes,
0 skipped, 0 expected failures, 0 unexpected`. Allowlist is empty.
The `--enforce_recommended` set still has 16 unexpected Recommended failures
(FieldMask edge cases, base64-URL alt alphabet, JSON unpaired surrogate
detection, IgnoreUnknown enum-string parsing). CI gates on Required only.

**Test count**: 1777 / 1777 julia tests pass (plus the conformance runner
gate, gated on Linux/macOS).

## Codebase map (what lives where)

- `src/codec/` — wire codec, originally copied from ProtoBuf.jl. We now own
  it; bug fixes here are candidates for upstream contribution.
- `src/ProtoBufDescriptors.jl` — re-exports the codec API, defines `OneOf`
  and `AbstractProtoBufMessage`, declares the metadata-API stubs
  (`reserved_fields`, `extendable_field_numbers`, `oneof_field_types`,
  `field_numbers`, `default_values`, `json_field_names`), includes
  `gen/google/google.jl` and the JSON files.
- `src/codegen.jl` (module `Codegen`) — emits Julia from a
  `FileDescriptorProto`. Tracks a `Universe` populated from every
  `proto_file` in the `CodeGeneratorRequest`; per-file `LocalNames`
  is a thin view that pairs the universe with the current file's
  syntax/package.
- `src/plugin.jl` — `generate(request)` and `run_plugin(in, out)`
  entry points (read `CodeGeneratorRequest`, write `CodeGeneratorResponse`;
  codegen errors go through `response.error`, not exceptions).
- `bin/protoc-gen-julia` — self-executing julia script that activates the
  package and calls `run_plugin()`.
- `src/json.jl` — generic JSON walker (encode/decode). Loaded *before*
  `gen/google/google.jl` so generated forwarding methods can extend it.
- `src/json_wkt.jl` — WKT-specific JSON forms (Wrappers, Timestamp,
  Duration, FieldMask, NullValue, Struct/Value/ListValue, Empty, Any).
  Loaded *after* the bootstrap so the WKT types are in scope. `Dates`
  is a runtime dep (Timestamp); base64 is implemented inline (Julia
  1.12 stdlib resolution refused Base64 from the General registry).
- `src/testing.jl` — `obtain_conformance_test_runner()`: clones protobuf
  at the pinned tag and cmake-builds the conformance target on first
  call, caches in a `Scratch` scratchspace. Override via
  `CONFORMANCE_TEST_RUNNER` env var.
- `gen/google/` — bootstrap descriptor + plugin + WKT bindings. Now
  generated by our own codegen via `gen/regen.jl` (single protoc
  invocation across the whole tree so the codegen Universe spans
  everything). ProtoBuf.jl is no longer on the build path.
- `test/conformance/` — `proto/conformance.proto` (vendored verbatim),
  `regen.jl` → `conformance_descriptors.pb`, `testee.jl` (binary +
  JSON dispatch with `ignore_unknown_fields=true` for the
  `JSON_IGNORE_UNKNOWN_PARSING_TEST` category), `failure_list.txt`
  (currently empty), `README.md`.
- `test/fixtures/` — `proto/*.proto`, `txtpb/*.txtpb`, `pb/*.pb`
  (committed binary fixtures so tests stay protoc-free at run time).
  `test/fixtures/regen.jl` rebuilds them.

## Non-obvious codegen behaviors

These are easy traps to forget when reading or modifying codegen:

- **Generated parameters are underscore-prefixed** (`_d`, `_e`, `_x`)
  so they can't collide with proto field names like `d`.
- **Field statements emit in field-number order** (sorted), not
  proto-source order, because protoc orders the wire that way.
  Each oneof member becomes its own check at its own field number so
  it can interleave correctly with plain fields.
- **Repeated-scalar packing** respects `field.options.packed` with
  syntax-default fallback (proto2 unpacked, proto3 packed).
- **Cycle detection**: a *direct* self-reference
  (`DescriptorProto.nested_type::Vector<DescriptorProto>`) parses
  natively in Julia and does **not** trigger abstract emission. A
  self-loop that surfaces only via a *nested* type's field still
  triggers `abstract type AbstractX` forward-declaration with
  cyclic field types resolving to the abstract supertype
  (`Vector{AbstractValue}` etc.). Forwarding `decode(::AbstractX)`
  routes into the concrete struct's decoder.
- **`option allow_alias = true;`** on enums: first occurrence per
  numeric value is canonical (goes into `@enumx`); subsequent names
  emit as `Core.eval(EnumMod, :(const Alias = Canonical))` inside the
  enum's baremodule.
- **Cross-package imports**: codegen tracks each FQN's package and
  qualifies cross-package refs as `<package_alias>.<TypeName>` (alias
  is package name with `.` → `_`, e.g. `google.protobuf` →
  `google_protobuf`). `WKT_PACKAGE_MAP` hardcodes
  `google.protobuf` → `ProtoBufDescriptors.google.protobuf`; for
  user-defined packages, `Codegen._relative_import_path(from_pkg,
  to_pkg)` falls back to a leading-dot relative-import path.
- **`_pb_includes.jl` driver**: emitted only when more than one
  `.proto` is being generated. Two halves: empty-module skeleton
  matching the union of proto packages, then `Core.include` calls in
  topological-dependency order. `_PB_DIR` / `_PB_ROOT` are captured at
  driver-load time so the driver works regardless of cwd.
- **`Type` / `Any` shadowing**: codegen emits `::Core.Type{...}` for
  dispatch annotations to avoid being shadowed by user types named
  `Type` (the `google.protobuf` submodule defines both `Any` and
  `Type` as message types).
- **Type registry**: codegen emits `PB.register_message_type(<fqn>,
  <jl_name>)` per message; bootstrap regen registers every WKT and
  descriptor type at package load. `lookup_message_type(fqn)` is the
  reverse. Used by JSON `Any` encode/decode.
- **`_unknown_fields::Vector{UInt8}`** is the last field of every
  generated message. Decode routes unknown tags through
  `_skip_and_capture!` (defined in the codec); encode writes the
  buffer verbatim *after* all known fields (append-at-end semantics:
  not byte-identical to protoc when known + unknown tags interleave,
  but spec-correct and enough for round-trips). The field is
  skipped in JSON. A convenience constructor that omits the buffer
  is also emitted. `Base.:(==)` and `Base.hash` are overloaded on
  `AbstractProtoBufMessage` to do field-wise comparison.

## Known bootstrap caveat

The committed bootstrap (`gen/google/`) was generated before the proto2
optional ENUM fix added in the conformance correctness pass. Until
`gen/regen.jl` is rerun, ENUM fields like `FieldDescriptorProto.label` /
`.type` are still emitted as bare enum types with the equal-to-default
skip on encode (instead of the new `Union{Nothing,EnumT}` presence form).
Harmless in practice — every consumer always sets these — but a
bootstrap-regen pass would close the gap. Doing the regen requires care:
codegen.jl itself reads `field.label` / `field.type` (now potentially
`Union{Nothing,…}`) via `===` comparisons that already handle the
`Nothing` case correctly, but a regen would still want a CI check that
no diff sneaks in unintentionally.

## Reference paths

- **ProtoBuf.jl source of truth** (read-only reference):
  `/home/jan/.julia/dev/ProtoBuf`
- **This repo**: `/home/jan/.julia/dev/ProtoBufDescriptors`

## Attribution

The wire codec under `src/codec/` is copied with light modifications from
ProtoBuf.jl (MIT, copyright 2022 RelationalAI / Tomáš Drvoštěp / contributors).
Attribution is in `LICENSE.md` and `README.md`. After Phase 8 (self-bootstrap),
ProtoBuf.jl is no longer involved at runtime or build time.

## How to resume

On the first turn of a fresh session:

1. Read this file (you are doing that now).
2. Skim `src/ProtoBufDescriptors.jl` and `src/codegen.jl` to confirm
   current state matches what's described above.
3. Confirm with the user before starting work on a new phase, unless
   explicitly in auto mode.

## Conventions specific to this project

These are in addition to the user's global `~/.claude/CLAUDE.md` rules
(julia-mcp, long-form `function ... end`, no emojis, etc.).

- **Do not weaken tests to make them pass.** If something fails, fix the
  code or ask the user.
- **Aqua + JET in CI from day one.** Both are wired up. Don't disable a
  check to silence a failure; fix the underlying issue.
- **Before exporting a name, make sure it's defined** (Aqua's
  `test_undefined_exports` will fail otherwise).
