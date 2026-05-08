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
- **Maps**: detect synthesized message types via `map_entry=true`. Emit
  `OrderedDict{K,V}` (insertion-ordered, from OrderedCollections.jl) so
  re-encode preserves wire order and yields byte-identical output to
  protoc. Codec dispatches on `AbstractDict{K,V}` so user-supplied plain
  `Dict` still works for encode (they just won't have ordering guarantees).
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
| 6 | proto2 `required`, maps, oneofs, packed, groups | DONE (groups deferred) |
| 7 | Well-known types | DONE (all 11) |
| 8 | Self-bootstrap (regenerate descriptor types from own codegen) | DONE |
| 9 | Conformance + golden corpus | DONE (proto2 corpus still patched, 188 codec failures allowlisted) |
| 10 | Startup latency (`PackageCompiler` sysimage) | pending |
| 11 | Docs + v0.1.0 release | pending |
| 12 | JSON mapping (encode + decode + WKT specials, conformance JSON green) | in progress (12a-c done; 12d pending) |

**Total v0.1.0 estimate**: ~8–9 weeks for one focused engineer.

## Current state

- `Project.toml` UUID `b5fc38b8-670b-4930-8529-238e2ca71835`. Deps:
  BufferedStreams, EnumX, OrderedCollections, TOML.
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
  the value travels on the wire, and unset ≠ default-zero. proto2 `optional`
  shares the same predicate after Phase 6.
- Phase 6 covers real oneofs, maps, and proto2:
  - **Real oneofs** (non-synthetic) collapse all member fields into a single
    struct field of type `Union{Nothing, OneOf{<:Union{T1, T2, ...}}}`.
    Decode dispatches on tag and writes `OneOf(:member, value)`; encode
    branches on `_o.name` and emits the active member. `oneof_field_types`
    metadata is also emitted so users can introspect the union.
  - **Maps** are detected via `MessageOptions.map_entry == true`. The field
    is emitted as `Dict{K,V}` and the synthetic `*Entry` message is
    suppressed; decode/encode go through the codec's existing
    `decode!(::Dict)` / `encode(::Int, ::Dict)` dispatch.
  - **proto2** is fully supported: `optional` scalars get the same
    `Union{Nothing,T}` treatment as proto3 explicit-optional; `required`
    fields are emitted as bare types with `_saw_*` flags accumulated during
    decode and a `DecodeError("required field X missing")` thrown if any
    flag stays `false`. Required submessages use `Ref{T}()` (uninitialized)
    so the validation step throws a clear error before anyone touches the
    Ref. `DecodeError <: Exception` is a new public type.
  - **Groups** (deprecated proto2 wire format) are intentionally not
    supported in v1. `_scalar_jl_type_and_wire` errors clearly if a
    `TYPE_GROUP` field reaches codegen.
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
- `test/test_proto2.jl` exercises proto2: required scalars + required
  submessage decode happy path, optional scalars round-trip presence,
  re-encode is byte-identical to protoc, and a hand-crafted blob missing
  the `name` required field raises `DecodeError`.
- `test_codegen.jl` also covers maps end-to-end (`Dict{String,Int32}`,
  `Dict{Int32,String}`, `Dict{String,SubMessage}`) and the real oneof on
  `sample.Outer`.
- `test/test_conformance_corpus.jl` runs patched copies of Google's
  conformance protos (`test_messages_proto{2,3}_patched.proto`) through
  codegen end-to-end. The patched files vendor upstream verbatim except
  for the features deferred in v1; their headers list every removal
  (extensions, groups, MessageSet, recursion, WKT-typed fields,
  AliasedEnum). Each syntax has a "full" populated fixture (every
  retained field non-default) and an "empty" fixture; the populated
  case asserts spot-checked decode values across every wire-type ×
  container shape category **and full byte-equality of re-encode against
  the protoc fixture**, the empty case asserts presence semantics and
  zero-byte re-encode. Authoring these protos surfaced four wire-format
  correctness issues fixed along the way:
  1. `decode(::Enum{Int32,UInt32})` only consumed 5-byte varints, but
     protoc sign-extends negative enum values to 10-byte int64. Fixed
     in `src/codec/decode.jl` to read as `UInt64` and truncate, matching
     the trick already in place for `decode(::Int32)`.
  2. `_encode(::Enum)` emitted 5 bytes regardless of sign. Mirrored the
     `_encode(::Int32)` sign-extension branch so negatives serialize as
     10 bytes (spec-compliant and protoc-byte-identical).
  3. `_varint_size(::Enum)` was the matching size-calculation bug;
     dispatched it through `_varint_size(::Int32)` so size and encode
     agree.
  4. Codegen always emitted *packed* encode for repeated scalar/enum
     fields, regardless of the field's `[packed = …]` annotation or the
     file syntax. proto2 defaults repeated scalars unpacked, proto3
     defaults packed; codegen now reads `field.options.packed` (with
     the syntax-default fallback) and emits a per-element loop for
     unpacked fields.

  ProtoBuf.jl carries items (1)–(3) as well — worth contributing upstream
  during Phase 8.

  The byte-equality assertion forced one further codegen change: encode
  and `_encoded_size` now emit field statements **in field-number order**
  (sorted), not proto-source order, because protoc orders the wire by
  field number. Each oneof member becomes its own `if !isnothing(_o) &&
  _o.name === :m` check at its own field number so it can interleave
  correctly with plain fields.
- Test fixtures live in `test/fixtures/`: `proto/*.proto` (schemas),
  `txtpb/*.txtpb` (protoc-encode inputs), `pb/*.pb` (committed binary
  outputs that tests load via `fixture("name.pb")` from runtests.jl).
  `test/fixtures/regen.jl` rebuilds the `pb/` files from the
  `proto/`/`txtpb/` sources via `protoc`. Tests stay `protoc`-free at
  run time; fixtures are reproducible from declarative inputs.
- **`test/test_encode.jl` and `test/test_decode.jl` were NOT ported** — they
  exercise the codec via generated structs and depend on `protojl` /
  `test_messages_for_codec_pb.jl`. Port them in Phase 4 once codegen exists.
- CI matrix mirrors ProtoBuf.jl: 1.10 / 1 / nightly × Linux / Windows / macOS ×
  x64 / aarch64.
- Phase 7 (well-known types) ships all 11 WKTs under
  `ProtoBufDescriptors.google.protobuf.*`, generated by our own codegen
  via `gen/regen_wkt.jl`. They live in the same Julia module as the
  bootstrap `descriptor_pb.jl` (no name conflicts; `Any` and `Type`
  shadow `Core.Any` / `Core.Type` inside the submodule, which is
  contained — codegen now emits `::Core.Type{...}` for dispatch
  annotations to avoid being shadowed by user types named `Type`).
  - **Phase 7a — dependency-free WKTs**: `any`, `duration`, `empty`,
    `field_mask`, `source_context`, `timestamp`, `wrappers`. No
    codegen changes needed beyond the existing single-file pipeline.
  - **Phase 7b — cross-file imports**: `api`, `type`. Codegen now
    keeps a `Universe` populated from every `proto_file` entry in the
    `CodeGeneratorRequest`; per-file `LocalNames` is a thin view that
    pairs the universe with the current file's syntax/package. The
    plugin builds the universe once and passes it into
    `Codegen.codegen(file, universe)`. Single-file `codegen(file)` is
    a convenience that builds a one-file universe.
  - **Phase 7b — recursion**: `struct`. The Value↔Struct↔ListValue
    cycle is broken with `abstract type AbstractValue` /
    `AbstractStruct` / `AbstractListValue` forward-declared at the top
    of the generated file; cyclic field types resolve to the abstract
    supertype (`Vector{AbstractValue}`,
    `OrderedDict{String,AbstractValue}`, oneof members typed
    `AbstractStruct` / `AbstractListValue`). Forwarding `decode(::
    AbstractX)` methods route into the concrete struct's decoder. The
    type-stability cost of going through the abstract is real but
    contained to struct.proto — no other proto in the test suite has
    a cycle.
- `test/test_wkt.jl` round-trips each WKT type, including:
  Timestamp/Duration sign-extended-int64 encode (negative-int coverage
  parallel to the negative-enum regression); Empty zero-byte
  encoding; FieldMask repeated string; Any wrapping arbitrary bytes;
  every wrapper variant; Type/Field/Option with cross-file refs to
  SourceContext; Api/Method/Mixin (cross-file Type refs); Struct/Value/
  ListValue with every Value.kind variant inside a nested ListValue
  (exercises the cycle).
- Phase 7c (cross-package import emission) lands the missing piece for
  user-generated files that reference types from another proto package.
  Codegen now tracks the package of every FQN in the universe, and
  `_resolve_typename` qualifies cross-package refs as
  `<package_alias>.<TypeName>` where the alias is the package name with
  dots → underscores (`google.protobuf` → `google_protobuf`). The file
  head carries an `import <julia_module> as <alias>` line per imported
  package. The mapping from proto package → Julia module path is a
  hardcoded `WKT_PACKAGE_MAP` for `google.protobuf` →
  `ProtoBufDescriptors.google.protobuf`; user-defined packages would
  need a plugin parameter (deferred until real users ask for it). The
  hardcoded map is enough to consume any user proto that imports WKTs.
- `test/test_corpus_wkt.jl` exercises the verbatim
  `unittest_well_known_types.proto` from Google's golden corpus —
  the first fully-verbatim corpus file in the suite. Fields like
  `any_field`, `type_field`, `timestamp_field` resolve to
  `google_protobuf.Any`, `google_protobuf.Type`,
  `google_protobuf.Timestamp` etc., sidestepping the ambiguity with
  `Core.Any` / `Core.Type` that broke the pre-Phase-7c attempt.
- `test/fixtures/proto/test_messages_proto3_patched.proto` is now
  near-verbatim upstream; the only patch is removing AliasedEnum (uses
  `option allow_alias`, unsupported by EnumX). WKT-typed fields and
  `recursive_message` / `corecursive` are restored. The conformance
  test exercises both cross-package import (`google_protobuf.Timestamp`
  etc.) and recursion (`recursive_message::Union{Nothing,
  AbstractTestAllTypesProto3}`).
- `unittest_proto3.proto` is still deferred (Phase 7c+ / 11) — it
  imports another non-WKT package (`protobuf_unittest_import`) which
  the hardcoded WKT map can't accommodate without a plugin parameter
  or per-test map configuration.
- Phase 8 (self-bootstrap) replaces the `descriptor_pb.jl` and
  `compiler/plugin_pb.jl` files — previously generated by a
  ProtoBuf.jl fork — with output from our own codegen. ProtoBuf.jl is
  no longer on the build path. The regen script is `gen/regen.jl`
  (single protoc invocation across all WKTs + descriptor + plugin so
  the codegen Universe spans the whole tree). The codegen change that
  unblocked self-bootstrap was distinguishing **direct** vs **nested**
  self-references in cycle detection: `descriptor.proto`'s
  `DescriptorProto.nested_type::Vector<DescriptorProto>` is a direct
  self-loop, which Julia handles natively (struct body parses lazily
  enough for the self-reference to resolve), so codegen no longer
  emits an unnecessary abstract supertype for it. A self-loop that
  surfaces only via a *nested* type's field still triggers the
  abstract emission — that's how `test_messages_proto3.proto`'s
  `NestedMessage.corecursive::TestAllTypesProto3` and
  `struct.proto`'s `Value ↔ Struct ↔ ListValue` cycle are handled.
- `option allow_alias = true;` on enums is supported (Phase 9): the
  first occurrence of each numeric value is the canonical name and goes
  into the `@enumx` declaration; subsequent names with the same number
  are emitted as `Core.eval(EnumMod, :(const Alias = Canonical))` lines
  inside the enum's baremodule. `Foo.Alias === Foo.Canonical` and
  `Symbol(Foo.Alias)` returns the canonical name (matching protoc's
  display behavior). With this in place,
  `test/fixtures/proto/test_messages_proto3.proto` ships verbatim
  upstream — the `_patched` suffix is gone.
- Phase 9 (2/2) wires up Google's `conformance_test_runner` against a
  Julia testee that drives our codec end-to-end. The new tree under
  `test/conformance/` holds:
  - `proto/conformance.proto` — vendored verbatim from protobuf v25.9.
  - `regen.jl` → `conformance_descriptors.pb` — bundled
    FileDescriptorSet covering `conformance.proto` plus the
    `test_messages_proto{2,3}` corpora (`--include_imports` drags the
    transitive WKT descriptors along).
  - `testee.jl` — self-executing Julia script (same shebang trick as
    `bin/protoc-gen-julia`). At startup it feeds the bundled
    descriptors through our own codegen and evals the result into
    three sub-modules; the run loop reads framed `ConformanceRequest`
    blobs from stdin, dispatches via decode → encode through
    `MESSAGE_TYPE`, writes framed `ConformanceResponse` blobs to
    stdout. JSON / JSPB / TEXT_FORMAT inputs and outputs are reported
    via `response.skipped`.
  - `failure_list.txt` — allowlist of 188 known-failing tests
    grouped by category in the header. Two underlying codec gaps:
    (a) lenient parser that accepts truncated/malformed inputs the
    spec wants rejected (`PrematureEof*`, `IllegalZeroFieldNum_*`,
    BOOL varint >1), and (b) map-entry decoder that rejects empty
    entries, duplicate fields within an entry, and value-before-key
    field order. Both are real binary-codec bugs against the wire
    spec — not v1 scope deferrals — and are tracked for a follow-up
    codec pass.
  - `README.md` — how to run the conformance test, how to refresh the
    failure list, how to force a rebuild.
  - `ProtoBufDescriptors.obtain_conformance_test_runner()` (defined
    in `src/testing.jl`, depends on `Scratch`) clones protobuf at the
    pinned tag and cmake-builds the conformance target on first call,
    caching the binary in a Scratch.jl scratchspace owned by this
    package. Subsequent calls are an O(1) lookup. Override via
    `CONFORMANCE_TEST_RUNNER` env var (use this exact path; skip
    build) — useful for CI that provisions the binary out-of-band.
  - `test/test_conformance_runner.jl` runs unconditionally on
    Linux/macOS — the first run pays ~5–10 min for clone + build,
    subsequent runs reuse the cached binary. The test asserts the
    runner's exit code is 0, which holds when only allowlisted tests
    fail. Skipped only on Windows (runner uses POSIX `fork`) or when
    `cmake` / `git` is missing on PATH. Current state against
    protobuf v25.9: **1071 successes, 729 skipped, 188 expected
    failures, 0 unexpected failures**.
- 1670 / 1670 julia tests pass (1666 from Phase 8 + 4 from the
  conformance runner gate).
- Phase 12a (JSON scaffold) lands the protobuf-JSON mapping — encode
  and decode for scalars, repeated, nested messages, enums, plus the
  generic wire quirks that fall out of plain type dispatch (int64 /
  uint64 → JSON string, bytes → base64 string, NaN/±Infinity → JSON
  string). Codegen now also emits `PB.json_field_names(::Core.Type{T})`
  per message — a Julia-field → JSON-key map honoring
  `[json_name = …]` overrides; non-overridden fields use protoc's
  camelCase default, which is already populated in the
  FieldDescriptorProto we receive. Encode is reflection-driven via the
  same metadata methods the binary path uses (`field_numbers`,
  `default_values`, `oneof_field_types`, `json_field_names`); WKT
  specials (Timestamp → RFC 3339, Duration → "1.5s", Any → `@type`,
  …) are deferred to Phase 12c. Maps and oneof parent-flattening
  defer to Phase 12b. Codegen also flips the struct supertype:
  generated messages now subtype `PB.AbstractProtoBufMessage` (cycle
  participants do too via their forward-declared abstract), which is
  what `encode_json` / `decode_json` dispatch on. **JSON.jl** is a
  new runtime dep; base64 is implemented inline (a few dozen LOC) to
  avoid wrestling with stdlib resolution under Julia 1.12.
- 1713 / 1713 julia tests pass (1670 + 43 new JSON tests).
- Phase 12b layered the structurally-distinct wire quirks onto the
  walker:
  - **Oneof parent flattening**: encode emits the active member at
    parent level (no wrapper key); decode detects oneof-member JSON
    keys and rewraps in `OneOf(name, value)` against the parent field.
    The lookup is built fresh per-call from `oneof_field_types(T)`.
  - **Maps**: per spec, all map keys are JSON strings — so
    `_emit_map_key` stringifies (`true`/`false` literal, decimal int,
    JSON-escaped string) and `_decode_map_key` parses back into the
    original `K`. Map encode/decode dispatches on `AbstractDict{K,V}`,
    matching our binary path.
  - **`ignore_unknown_fields` parse option**: default is **strict**
    (unknown JSON key → `ArgumentError`), matching the spec.
    Decoders thread the flag through `; kw...` so it propagates into
    nested message / map-value decode.
  - **Cycle abstracts and JSON**: codegen emits an invariant-`Type{X}`
    forwarding `_decode_json_message` per cycle abstract supertype
    (`AbstractValue → Value`, `AbstractStruct → Struct`,
    `AbstractListValue → ListValue`). Invariant (no `<:`) is critical
    — `<:` would also match the concrete struct and recurse forever.
  - **Module load order**: `src/json.jl` now includes *before*
    `gen/google/google.jl` so the generated forwarding methods can
    extend `_decode_json_message`.
- 1739 / 1739 julia tests pass (1713 + 26 new 12b tests covering
  oneof flatten / maps / strict-vs-lenient unknown fields).
- Phase 12c (10 of 11 WKTs — Any deferred) lands the WKT-specific
  JSON forms in `src/json_wkt.jl` (loaded *after* the bootstrap so the
  WKT types are in scope):
  - **Wrappers** (BoolValue, BytesValue, DoubleValue, FloatValue,
    Int32Value, Int64Value, StringValue, UInt32Value, UInt64Value):
    emit/parse the bare wrapped scalar — no `{"value": …}` envelope.
    On parse, a Dict still falls through to the generic walker as a
    friendly fallback.
  - **Empty**: emits `{}` (the generic walker already handles it
    correctly, no override needed).
  - **Timestamp**: RFC 3339 string, fractional precision auto-picks
    3/6/9 trailing digits or omits when nanos == 0. Parse accepts
    `Z` and `±hh:mm` offsets, normalizes to UTC. Implemented with
    `Dates` (added as a runtime dep).
  - **Duration**: `"<integer>[.<fractional>]s"` form, sign always
    leading. Round-trips via parse regex.
  - **FieldMask**: comma-separated, paths emitted in camelCase
    (snake-cased internally) and the inverse on parse.
  - **NullValue**: emits `null`, parses from `null` to NULL_VALUE.
  - **Struct / Value / ListValue**: passthrough — Struct emits its
    fields dict directly, ListValue emits its values vector
    directly, Value flattens its active oneof member's value
    one level higher than the generic walker would. Cycle abstracts
    (`AbstractValue`, `AbstractStruct`, `AbstractListValue`) get
    typed forwarding methods (both untyped and `::AbstractDict`)
    that route to the concrete struct, resolving the dispatch
    ambiguity with the generic message walker.
  - **Top-level entry rewired**: `encode_json` now delegates through
    `_encode_json_value`; `decode_json` through `_decode_json_value`
    — so wrappers / Timestamp / Duration / FieldMask work even when
    a user calls `encode_json(BoolValue(true))` directly.
- Inline base64 stays (Julia 1.12 stdlib resolution refuses to
  register Base64 from the General registry); Dates registers fine.
- 1764 / 1764 julia tests pass (1739 + 25 new 12c WKT tests across
  wrappers, Timestamp, Duration, FieldMask, Struct/Value/ListValue,
  Empty).
- Phase 12c.Any closes out 12c. New machinery:
  - **Type registry**: `_MESSAGE_REGISTRY :: Dict{String,Type}` keyed
    by protobuf FQN (e.g., `"google.protobuf.Timestamp"`). Codegen
    emits `PB.register_message_type(<fqn>, <jl_name>)` per message;
    bootstrap regen registers every WKT and descriptor type at
    package load time. `lookup_message_type(fqn)` is the reverse.
  - **Encode**: parses `Any.type_url`, looks up the Julia type,
    decodes the binary `Any.value` payload via the existing wire
    codec, then emits the JSON form. WKTs with non-message JSON
    (Wrappers, Timestamp, Duration, FieldMask, Empty, Struct,
    Value, ListValue — `_WKT_VALUE_FORM`) emit
    `{"@type": ..., "value": <special>}`; ordinary messages emit
    `{"@type": ..., <fields inlined>...}`. The inline-fields path
    uses a slim `_encode_json_message_after_at_type` helper that
    appends to an already-open object instead of opening its own.
  - **Decode**: reads `@type`, looks up Julia type, decodes either
    the `value` field (WKT) or the rest of the dict (ordinary), then
    re-encodes to bytes and stores both type_url and bytes back into
    Any. So a JSON-decoded Any carries the same wire representation
    as a binary-decoded one.
  - **Errors**: missing `@type` or unregistered FQN throw
    `ArgumentError`. Conformance tests for Any with unknown types
    will hit this — that's the right strict default; users can
    register their own types with `register_message_type`.
- 1777 / 1777 julia tests pass (1764 + 13 new Any tests).

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
