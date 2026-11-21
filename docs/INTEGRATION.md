# Integrating SJON

> **Embedding the engine** in your own program? You're in the right
> place. **Setting up an editor** (LSP, syntax highlighting) or using the
> `sjon` CLI lives in [docs/TOOLING.md](TOOLING.md).

SJON ships as a Zig library with three reference conformance-host wrappers
that re-expose the same engine in other ecosystems, plus `@sjon-lang/read`, a
synchronous pure-TypeScript reader for tools that need a tree before any WASM
is loaded. Pick the row that matches your runtime; every conformance host
shares the diagnostic vocabulary, the binary IR wire format where implemented,
and the conformance corpus. Agreement is checked on each host's supported
surfaces and replayed fixtures.

| Host                       | When to use                                                                       | Entrypoint                                                  | Examples                                                                       |
| -------------------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------ |
| **Zig (in-process)**       | Embedding in another Zig binary. Canonical path. Zero runtime, full surface area. | `@import("sjon")` after the dep is wired in `build.zig.zon` | [`examples/binary-ir-demo.zig`](../examples/binary-ir-demo.zig), [README §Consuming](../README.md#consuming) |
| **Web / Node (WASM)**      | Browsers, Electron, Node services — need SJON in JS without a Zig toolchain.      | `SjonHost`, `SjonEncoder`, `SjonReader` from `hosts/web/`   | [`examples/quickstart-web.mjs`](../examples/quickstart-web.mjs) (start here), [`examples/web-todo/`](../examples/web-todo/), [`examples/web-canvas/`](../examples/web-canvas/), [`hosts/web/demo.ts`](../hosts/web/demo.ts) |
| **Rust (wasmtime)**        | Rust services, CLIs, build tools. Wraps the same `sjon.wasm` via `wasmtime`.      | `sjon_host::SjonHost::load(...)` in `hosts/rust/`           | [`examples/quickstart-rust.rs`](../examples/quickstart-rust.rs) (start here), [`hosts/rust/tests/smoke.rs`](../hosts/rust/tests/smoke.rs) |
| **Reader (pure TypeScript)** | Strict build tools and editors that need a synchronous parse before WASM loads. | `read`, `readResult`, `fields` from `@sjon-lang/read`       | [`hosts/read/README.md`](../hosts/read/README.md) |
| **TypeScript (reference)** | Second-source conformance verification or porting. **Not for production.**        | `import { Host } from '…/typescript-parity/src/index.ts'`   | [`hosts/typescript-parity/test/conformance.test.ts`](../hosts/typescript-parity/test/conformance.test.ts) |

The four conformance hosts — Zig, Web, Rust, and TypeScript parity — discover
`conformance/cases/` and emit the same `(code, path)` diagnostics on the
fixtures they replay. The reader is not a conformance host: it ships curated
reader fixtures plus a test-only engine oracle instead of replaying the corpus.
This is deliberately a different set from the four publishable packages
(`@sjon-lang/schema`, `@sjon-lang/read`, `@sjon-lang/web`,
`@sjon-lang/highlight`). Differences on supported shared contracts are
conformance bugs; intentional boundaries and skip registries are described
below.

## Capability matrix

The WASM columns describe exported engine capabilities; wrapper method names
and available artifact combinations are listed in each host README.

| Capability | Zig library | Kitchen-sink WASM (Web/Rust) | Read-only WASM (`SjonReader`) | Reader (`@sjon-lang/read`) | Native TS reference |
|---|---|---|---|---|---|
| Text parse | Full tree | Text and binary | No | Full text parse with UTF-8 byte spans | Declarative subset |
| Validation | Full tree/binary | Text and binary | Binary | No | Declarative subset |
| Expressions | Tree, binary, binary views | Text and binary | Binary | No evaluator | No evaluator |
| Patterns | Tree, legacy/eval binary, prepared | Existing exported query surface | Legacy binary query | No | Literal leaves |
| Defaults | Validation and materialization | Host pipeline options | Binary validation surface | No runtime overlay | No runtime overlay |
| Edits and addresses | Yes | Yes | No parser/edit surface | No edit surface; byte spans only | No |
| Declared identities | `HostResult.identities` | `identities` on the validate result; Web typed rows | No | No | No |
| Schema export | JSON Schema, TS, intermediate; CLI Markdown | JSON Schema, TS, both, intermediate | No | No | Native export subset |
| Preloaded schema handles | `PreloadedSchema` + `HostOptions.preloaded` | `sjon_preload_schema` / `sjon_schema_free`; Web `SjonHost.preload` | No | No | No |
| Executable plugins | Runtime/invoker | Host/runtime bridge | No runtime bridge | No | No |
| Lowering hooks | Zig function-pointer registry | No hook execution | No | No | No |

The additive native binary-pattern APIs do not add WASM exports or wrapper
methods. See [BINARY_PATTERNS.md](BINARY_PATTERNS.md) for choosing a native entry.

The preloaded-schema row is an engine capability in the kitchen-sink WASM
artifact; the Web wrapper exposes it as `SjonHost.preload`, and the Rust
wrapper does not implement it yet (see [Rust crate](#rust-crate)). The
read-only artifact and the reader have no schema handle surface.

The declared-identity row is also an engine capability: the kitchen-sink
`Host.validateDocument` projects rows while the validator index is live, and
the existing `sjon_host_validate_document` JSON carries one additive
`identities` array. The Web wrapper types and returns that array; the Rust
wrapper's typed mirror is specified and deferred (see [Rust crate](#rust-crate)).
The read-only artifact, the reader, and the TypeScript reference have no
identity surface.

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

## Reader — pure TypeScript

`hosts/read/` publishes `@sjon-lang/read`, a synchronous, dependency-free
TypeScript reader of the SJON front end. It parses text to the same tree
shape, diagnostics, and half-open **UTF-8 byte** spans as the Zig
lexer/parser. It does no validation, evaluation, editing, or plugin work, has
no WASM dependency, and reads no files; Node `>=20`, CC0-1.0.

- `read(source)` is the strict entry: roots only when no `err`-severity parse
  diagnostic fired, otherwise a `ReadError` carrying that same single-parse
  result. Use it where a partial tree must not become configuration.
- `readResult(source)` is total for SJON syntax: recovered roots plus every
  diagnostic in engine order, never a throw. Use it for editors and recovery
  UIs. A non-string argument is a `TypeError` in both.
- `fields(form)` is a view over the form's kvpair children. Source order and
  duplicate keys survive; last-wins `get(key)` is a convenience over `pairs`,
  and nothing is normalized or re-paired.
- Every span (`span`, `headSpan`, `keySpan`) is a half-open UTF-8 byte range
  `[start, end)` into the encoded source — JS indices are never exposed. A
  lone surrogate becomes U+FFFD under `TextEncoder`; arbitrary
  invalid-UTF-8 *byte strings* and comment retention are not part of this API.

The package's test suite includes a test-only engine oracle: it projects trees
into `sjon_node_table` rows and compares per-root values through
`sjon_to_json`. Only three representation losses are permitted, each counted
and asserted to keep its reason: `expression` (the core schema collapses
expression forms to `$expr` or refuses a labelled one), `duplicate-key` (a JSON
object keeps one value per key), and `parse-errors` (the value bridge needs a
clean tree; structure and diagnostics still run). Neither engine entry ships
in the package. See [hosts/read/README.md](../hosts/read/README.md).

**The resolver behaviour change is intentional.** The web host's
`createNodeFsResolver` now reads project and manifest files through throwing
`read`. The deleted subset parser accepted numbers, booleans, and `nil` as
pseudo-symbols in `:name`, so a malformed `(plugin :name 42)` could index a
nonsense name; the typed reader rejects those tags as a plugin name, and the
manifest now fails as `invalid_manifest` (missing `:name`).

The reader does **not** replace the TypeScript parity parser.
`hosts/typescript-parity/src/parser.ts` keeps its independently pinned
throw/recover contract, and retiring that second reference implementation is a
separate parity decision. It also does not replace
`hosts/rust/src/sjon_subset.rs`: the Rust resolver and conformance runner read
project files and `expected.sjon` *before* any WASM instance exists, so that
native, pre-WASM bootstrap boundary has no JavaScript runtime to delegate to
and no Rust crate is requested.

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

For a schema reused across many documents, `SjonHost.preload(manifestSources)`
compiles it once and returns a `PreloadedSchemaHandle`; pass it as
`HostOptions.preloaded` and dispose it explicitly. The handle is
instance-branded, so a foreign or disposed handle is rejected before it
reaches WASM, and disposal during an active host call — a resolver or plugin
callback — throws `SchemaInUse` rather than pulling the schema out from
under a live borrow. This is the path `@sjon-lang/schema`'s WASM backend uses
for clean generated manifests, and the one large fixed-schema browser apps
should use instead of re-sending the manifest with every document.

## Declared identities — names that survive a move

An **identity** is `(registry, scope, symbol)`: the canonical cross-ref
registry a declared `:cross-ref` gives a form, the stable lexical scope
prefixes around it, and the author-written symbol under that registry's
`:name-key`. Numeric root, AST `NodeIndex`, byte offset, path, and content are
not part of it, so the same name keeps its key when a sibling or the root
itself moves. Only a direct, author-written, symbol-valued `:name-key`
qualifies. A missing name, a quoted string or number, a held spelling, a
provider-extracted name, and a default-overlay name are anonymous and have no
row. Anonymous nodes are not "not found": they have no name to look up, and no
row is invented for them.

`HostResult.identities` carries one row per declared identity on every
whole-document validation. Rows are always present (empty when nothing
qualifies) and sorted deterministically by registry, scope prefix, then symbol.
A resolved row's `address` is `{ root, path }` — the same two fields an edit
action takes. An ambiguous row, for a name the pass cannot resolve to exactly
one site (including a duplicate registration or an ambiguous parent prefix),
keeps the key and has `address: null`. Cross-reference lookup itself stays
first-wins for diagnostics and references; an identity never silently follows
that first site.

The consumer recipe is four steps:

1. Validate once; retain the structural key `(registry, scope, symbol)` — not
   the address.
2. Find the row by structural equality on that key. No matching row is **not
   found**; a row with `status: "ambiguous"` is a refusal, not a fallback.
3. Use a resolved `address` with the existing §11 actions — it is the same
   `{ root, path }` an action already takes. There is no identity selector and
   no identity edit grammar.
4. Revalidate after every edit and take the next revision's addresses. Deleting
   and recreating a node under the same name is indistinguishable from retaining
   it; identity is nominal, not historical, and an address must never cross a
   revision.

Document scope is `scope: []`, including a multi-root document; the address's
`root` says which current root the path starts at, and root is never part of
the key. A lexical scope is an outermost-first array of stable parent
`{ registry, symbol }` prefixes. If a scope-opening form has no stable identity,
its scoped descendants have no row; if the parent prefix is ambiguous, the
descendants are ambiguous.

Two further boundaries. A fragment pass with
`Validator.Options.defer_cross_refs` records no identity registrations and
projects no rows, because a fragment cannot adjudicate missing or duplicate
names. And lowering never cross-joins layers: only registrations from the
source tree (`tree_idx == 0`) get addresses, while a lowered-away or
hook-emitted form has no source-tree row and is never given a path into the
returned `HostResult.tree`. Existing lowering diagnostics are unchanged.

This is an additive host-result field, not a wire change. The TypeScript parity
host has no `Edit`/address surface, and the conformance corpus checks
diagnostics and evaluated values rather than the whole `HostResult`, so neither
the corpus nor the native parity port owes an identity change. `@sjon-lang/read`
stays schema-free and unchanged: identity needs the loaded schema and the
engine's registration pass, which is exactly what the reader does not have.

## Rust crate

Install with `cargo add sjon-host@1.8.0` (Rust ≥ 1.92), then provide a
matching external `sjon.wasm`. The crates.io package builds without the
repository conformance corpus or a Zig toolchain.

`hosts/rust/` wraps `sjon.wasm` through `wasmtime`. It exposes
`SjonHost::validate_document(source, options)` with byte-identical
diagnostics to the Zig reference. Build with
`zig build rust-host-test`, or run
`cargo test --manifest-path hosts/rust/Cargo.toml` directly. See
[hosts/rust/README.md](../hosts/rust/README.md).

The Rust wrapper does **not** implement the preloaded-schema handle surface
yet. The ABI (`sjon_preload_schema` / `sjon_schema_free` and the
`preloadedHandle` option) is specified and shipped on the kitchen-sink
artifact, but `cargo`/`rustc` were absent in every environment this work was
developed in, so no Rust binding was written or tested. A `SchemaHandle`,
`PreloadedSchema`, `preload_schema`, `free_schema`, and
`HostOptions.preloaded` are planned, not present; do not describe the Rust
host as mirroring this surface until they are. No Rust Binary IR or
diagnostic-codec change is owed either way.

The Rust wrapper does not decode typed identity rows either. The kitchen-sink
result's `identities` array is specified and shipped on the artifact, but
there is no `IdentityRow`, `IdentityScope`, `IdentityAddress`,
`IdentityStatus`, or `HostResult.identities` here: `cargo`/`rustc` were absent
in every environment this work was developed in, so no Rust code was written or
tested, and an untested binding would not be parity. The eventual shape is
fixed by the same contract as Web — snake_case `resolved`/`ambiguous`, and an
`Option<IdentityAddress>` that is `None` exactly for an ambiguous row. Do not
describe the Rust host as mirroring the Web host's `result.identities` until
the mirror exists and its tests have run. No Rust Binary IR or
diagnostic-codec change, and no conformance-corpus obligation, is owed by this
surface.

## TypeScript reference

`hosts/typescript-parity/` is a hand-ported subset for conformance
verification — not a published package. Its parser keeps an independently
pinned throw/recover contract, which is why it remains separate from
`@sjon-lang/read` rather than importing it. Use it as a starting point when
porting SJON to another platform, or to reproduce diagnostics in a TypeScript
test harness. See
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

Every wire-format or diagnostic-code change must land in all four
conformance hosts (Zig, Web, Rust, TypeScript parity) in the same PR. The
conformance corpus
([`conformance/cases/`](../conformance/cases/)) is the single source of
truth. Hosts that fall behind on a feature are bugs, not "TODOs for
later."

A **host-surface** addition is not a wire-surface change. Preloaded schema
handles are the current example: they add two kitchen-sink exports and an
options field, but no binary-IR byte, no `Ast.Diagnostic.Code`, and no
corpus case. So the TypeScript parity host and `conformance/cases/` owe
nothing for it, while the Web wrapper ships the typed API and the Rust
wrapper is explicitly specified-but-unimplemented (Task 4 was deferred on a
missing toolchain, not waived).
