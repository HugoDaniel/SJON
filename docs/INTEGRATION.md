# Integrating SJON

SJON ships as a Zig library with three reference host wrappers that
re-expose the same engine in other ecosystems. Pick the row that
matches your runtime; every host shares the diagnostic vocabulary, the
binary IR wire format, and the conformance corpus, so behavior is
byte-identical across rows.

| Host                       | When to use                                                                       | Entrypoint                                                  | Examples                                                                       |
| -------------------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------ |
| **Zig (in-process)**       | Embedding in another Zig binary. Canonical path. Zero runtime, full surface area. | `@import("sjon")` after the dep is wired in `build.zig.zon` | [`examples/binary-ir-demo.zig`](../examples/binary-ir-demo.zig), [README §Consuming](../README.md#consuming) |
| **Web / Node (WASM)**      | Browsers, Electron, Node services — need SJON in JS without a Zig toolchain.      | `SjonHost`, `SjonEncoder`, `SjonReader` from `hosts/web/`   | [`examples/quickstart-web.mjs`](../examples/quickstart-web.mjs) (start here), [`examples/web-todo/`](../examples/web-todo/), [`examples/web-canvas/`](../examples/web-canvas/), [`hosts/web/demo.ts`](../hosts/web/demo.ts) |
| **Rust (wasmtime)**        | Rust services, CLIs, build tools. Wraps the same `sjon.wasm` via `wasmtime`.      | `sjon_host::SjonHost::load(...)` in `hosts/rust/`           | [`examples/quickstart-rust.rs`](../examples/quickstart-rust.rs) (start here), [`hosts/rust/tests/smoke.rs`](../hosts/rust/tests/smoke.rs) |
| **TypeScript (reference)** | Second-source conformance verification or porting. **Not for production.**        | `import { Host } from '…/typescript-parity/src/index.ts'`   | [`hosts/typescript-parity/test/conformance.test.ts`](../hosts/typescript-parity/test/conformance.test.ts) |

All four hosts walk `conformance/cases/` and emit the same `(code,
path)` diagnostics. If a behavior differs across rows, that's a
conformance bug — open it as such.

## Zig — the reference path

Add SJON as a Zig package dependency, then `@import("sjon")` it. The
public API and a minimal `build.zig` / `build.zig.zon` snippet live in
the project [README § Consuming](../README.md#consuming). The full
authoring surface is [docs/AUTHORING.md](AUTHORING.md); the formal
language reference is [docs/LANGUAGE.md](LANGUAGE.md).

For plugin development, start from
[`examples/plugins/shapes.zig`](../examples/plugins/shapes.zig) and the
plugin contract in
[docs/plugin-model-v1.md](plugin-model-v1.md). To export a host
schema, see [docs/SCHEMA_EXPORT.md](SCHEMA_EXPORT.md).

## Web / Node WASM

`hosts/web/` is the kitchen-sink JS wrapper. Two WASM artifacts ship
side-by-side:

- `sjon.wasm` — full surface: parse, print, validate, eval, edit, JSON
  bridge, binary IR.
- `sjon-binary.wasm` — read-only IR consumer for deployments that ship
  pre-baked binary documents.

Build both with `zig build wasm-all`; consume from JS via
`SjonHost.ts` (multi-plugin pipeline) or the lower-level
`sjon-reader.ts`. See [hosts/web/README.md](../hosts/web/README.md)
for the full layout.

## Rust crate

`hosts/rust/` wraps `sjon.wasm` through `wasmtime`. It exposes
`SjonHost::validate_document(source, options)` with byte-identical
diagnostics to the Zig reference. Build with
`zig build rust-host-test`, or run
`cargo test --manifest-path hosts/rust/Cargo.toml` directly. See
[hosts/rust/README.md](../hosts/rust/README.md).

## TypeScript reference

`hosts/typescript-parity/` is a hand-ported subset for conformance
verification — not a published package. Use it as a starting point
when porting SJON to another platform, or to reproduce diagnostics in
a TypeScript test harness. See
[hosts/typescript-parity/README.md](../hosts/typescript-parity/README.md).

## Cross-host parity contract

Every wire-format or diagnostic-code change must land in all four rows
in the same PR. The conformance corpus
([`conformance/cases/`](../conformance/cases/)) is the single source of
truth. Hosts that fall behind on a feature are bugs, not "TODOs for
later."
