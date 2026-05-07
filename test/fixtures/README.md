# test/fixtures

Test inputs that would otherwise be inlined as UInt8 arrays in test files.

## Layout

- `proto/` — `.proto` schemas. The truth.
- `txtpb/` — protoc textproto inputs (`--encode=<msg>` reads these).
- `pb/`    — committed binary outputs that tests load with `read(...)`.

## Regenerating

`pb/*.pb` are regenerated from `proto/*.proto` and `txtpb/*.txtpb`:

```
julia test/fixtures/regen.jl
```

Requires `protoc` on PATH. The script is declarative — see the
`PAYLOADS` and `DESCRIPTOR_SETS` tables in `regen.jl`. Add a new fixture
by dropping a `.proto` (or `.txtpb`) source in the right directory and
appending an entry to the appropriate table.

## Why files instead of inline bytes

Inlining raw bytes makes tests `protoc`-free at runtime (good) at the
cost of opaque hex blobs in source (bad — no way to see what the
fixture means without round-tripping through `protoc --decode`). Files
keep both properties: tests load committed binaries (no protoc at run
time), and the bytes are reproducible from the schema/textproto pair.
