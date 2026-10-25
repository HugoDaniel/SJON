# Integrating SJON

> **Embedding the engine** in your own program? You're in the right
> place. **Setting up an editor** (LSP, syntax highlighting) or using the
> `sjon` CLI lives in [docs/TOOLING.md](TOOLING.md).

SJON ships as a Zig library with three reference host wrappers that
re-expose the same engine in other ecosystems. Pick the row that
matches your runtime; every host shares the diagnostic vocabulary, the
binary IR wire format where implemented, and the conformance corpus.
Agreement is checked on each host's supported surfaces and replayed fixtures.

| Host                       | When to use                                                                       | Entrypoint                                                  | Examples                                                                       |
| -------------------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------ |
| **Zig (in-process)**       | Embedding in another Zig binary. Canonical path. Zero runtime, full surface area. | `@import("sjon")` after the dep is wired in `build.zig.zon` | [`examples/binary-ir-demo.zig`](../examples/binary-ir-demo.zig), [README §Consuming](../README.md#consuming) |
| **Web / Node (WASM)**      | Browsers, Electron, Node services — need SJON in JS without a Zig toolchain.      | `SjonHost`, `SjonEncoder`, `SjonReader` from `hosts/web/`   | [`examples/quickstart-web.mjs`](../examples/quickstart-web.mjs) (start here), [`examples/web-todo/`](../examples/web-todo/), [`examples/web-canvas/`](../examples/web-canvas/), [`hosts/web/demo.ts`](../hosts/web/demo.ts) |
| **Rust (wasmtime)**        | Rust services, CLIs, build tools. Wraps the same `sjon.wasm` via `wasmtime`.      | `sjon_host::SjonHost::load(...)` in `hosts/rust/`           | [`examples/quickstart-rust.rs`](../examples/quickstart-rust.rs) (start here), [`hosts/rust/tests/smoke.rs`](../hosts/rust/tests/smoke.rs) |
| **TypeScript (reference)** | Second-source conformance verification or porting. **Not for production.**        | `import { Host } from '…/typescript-parity/src/index.ts'`   | [`hosts/typescript-parity/test/conformance.test.ts`](../hosts/typescript-parity/test/conformance.test.ts) |

All four hosts discover `conformance/cases/` and emit the same `(code,
path)` diagnostics on the fixtures they replay. Differences on supported
shared contracts are conformance bugs; intentional boundaries and skip registries are described below.

## Capability matrix

The WASM columns describe exported engine capabilities; wrapper method names
and available artifact combinations are listed in each host README.

| Capability | Zig library | Kitchen-sink WASM (Web/Rust) | Read-only WASM (`SjonReader`) | Native TS reference |
|---|---|---|---|---|
| Validation | Full tree/binary | Text and binary | Binary | Declarative subset |
| Expressions | Tree, binary, binary views | Text and binary | Binary | No evaluator |
| Patterns | Tree, legacy/eval binary, prepared | Existing exported query surface | Legacy binary query | Literal leaves |
| Defaults | Validation and materialization | Host pipeline options | Binary validation surface | No runtime overlay |
| Edits and addresses | Yes | Yes | No parser/edit surface | No |
| Schema export | JSON Schema, TS, intermediate; CLI Markdown | JSON Schema, TS, both, intermediate | No | Native export subset |
| Executable plugins | Runtime/invoker | Host/runtime bridge | No runtime bridge | No |
| Lowering hooks | Zig function-pointer registry | No hook execution | No | No |

The additive native binary-pattern APIs do not add WASM exports or wrapper
methods. See [BINARY_PATTERNS.md](BINARY_PATTERNS.md) for choosing a native entry.

The wire version and diagnostic-code vocabulary remain shared contracts.
Lowering hooks and their provenance are Zig-only. Markdown schema export and
structured hints are CLI-only. `sjon-project.sjon` vocabulary belongs to the
filesystem resolver; a resolver claiming support must read its complete entry
shape. Document plugin pins remain a host-level check.

Conformance coverage is fixture coverage, not the number of test registrations:
the current WASM runners replay 354 of 393 fixtures, excluding 38 `lowering-*`
cases and `too-many-keys`. The reasons and matching rules are maintained in
[`conformance/classifier.json`](../conformance/classifier.json). The native TS
reference has additional exclusions in its
[`SKIP_FAMILIES`](../hosts/typescript-parity/test/conformance.test.ts), including
expression-valued patterns, runtime provider extraction, expression defaults,
materialization, effective validation, higher-order/value expressions and
exclusive-group runtime checks. Aggregate-only provider cases still run.
These exclusions describe existing boundaries, not permission for a new
shared-contract divergence. [The TS README](../hosts/typescript-parity/README.md)
details the supported subset.

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

Host lowering is Zig-only: a `LoweringRegistry` takes a Zig function
pointer, and no other host runs a hook. Its surface (a hook carrying
host state through `LoweringHook.ctx` and reading it back as
`LoweringInput.ctx`, resolving a cross-reference to the form it names
with `LoweringInput.resolveRef`, every staging layer kept in
`HostResult.lowering_stages`, and `provenanceChain` walking a lowered
form back to the authored one) is run end to end by
[`examples/lowering-stages-demo.zig`](../examples/lowering-stages-demo.zig)
(`zig build lowering-demo`).

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

## Choosing your type-sync lane

Two ways to keep host-language types and the SJON schema in lockstep —
pick by where the source of truth lives:

- **Builder-first** (`hosts/schema`, `@sjon-lang/schema`) — you own the
  schema in TypeScript. Build it with the fluent builder, take static
  types via `s.infer<typeof Form>`, and serialize the canonical
  manifest with `.manifest()` when a host needs it. Zero codegen: the
  static type and the emitted `.d.ts` agree by construction
  (`s.infer` is the compile-time mirror of
  `exportSchema(manifest()).tsTypes`). Start at
  [hosts/schema/README.md](../hosts/schema/README.md).
- **Manifest-first** (`sjon export-schema`) — the `.sjon` manifest is
  the source of truth (hand-written, or produced by another team).
  Wire `sjon export-schema plugin.sjon --target=typescript
  --output=src/generated` into your build and treat the emitted
  `.d.ts` like any other generated artifact; in CI, re-run the export
  and fail on diff (the repo's own golden discipline). Full mapping
  reference: [docs/SCHEMA_EXPORT.md](SCHEMA_EXPORT.md); `--target=markdown`
  renders the same descriptors as human reference pages.

Both lanes meet at the same place — a manifest any host validates
against — so switching later is a build-step change, not a rewrite.

## Cross-host parity contract

Every wire-format or diagnostic-code change must land in all four rows
in the same PR. The conformance corpus
([`conformance/cases/`](../conformance/cases/)) is the single source of
truth. Hosts that fall behind on a feature are bugs, not "TODOs for
later."
