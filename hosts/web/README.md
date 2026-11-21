# `@sjon-lang/web` — SJON validating host (Node.js + browser)

The production wrapper around the SJON WASM artifacts, and one of the
four parity hosts the conformance corpus runs against:

- **`sjon.wasm`** — kitchen-sink. Wrapped as `SjonEncoder` (Binary IR +
  validate + evalExpr) and `SjonHost` (the validating-host pipeline with
  `(use-plugin …)` resolution).
- **`sjon-binary.wasm`** — read-only. Wrapped as `SjonReader`.

Use `SjonEncoder` when you need to ingest SJON text and produce Binary
IR or run the single-plugin core validator. Use `SjonReader` for
deployments that only validate / evaluate pre-baked Binary IR.
Use `SjonHost` when you have multi-plugin documents that declare or
reference plugins (`(plugin …)` / `(use-plugin …)`) — it runs the same
three-phase pipeline as the Zig CLI (`sjon validate`).

## Layout

The host is written in TypeScript. Inside this repository it runs in
Node ≥ 22.6 with `--experimental-strip-types` and has no build step. For
the **browser**, an ESM build under `dist/` is emitted by
`tsc -p tsconfig.browser.json` (run `pnpm build:browser`, or
`zig build web-host-browser`); browsers can't execute `.ts` directly.

The published package is compiled: `pnpm pack` and `pnpm publish` run
`prepack`, which builds `dist/` from `tsconfig.build.json` (JavaScript
plus declarations), and `publishConfig` points the packed `exports` at
it. Node refuses to strip types from a `.ts` file under `node_modules`,
so a package that shipped its sources could not be imported.

| File                            | What it is                                              |
| ------------------------------- | ------------------------------------------------------- |
| `sjon-reader.ts`                | `SjonEncoder` / `SjonReader` (low-level wrappers).      |
| `SjonHost.ts`                   | Validating-host wrapper; resolver-bridged, multi-plugin.|
| `createNodeFsResolver.ts`       | Node `fs` resolver (project-file walker + `:path`).     |
| `parseJsonWithBigInt.ts`        | BigInt-safe JSON parse used by the wrappers.            |
| `types.ts`                      | Shared TypeScript types for the public surface.         |
| `demo.ts`                       | Runnable walkthrough; encode → validate → eval.         |
| `*.test.ts`, `test/*.test.ts`   | `node:test` suites: wrappers, host, resolver, conformance, schema export. |
| `tsconfig*.json`                | Type-check config + the browser-ESM emit config.        |
| `package.json`                  | ESM package descriptor (`exports` map to the `.ts`; the packed one maps to `dist/`). |
| `tsconfig.build.json`           | The `prepack` compile: the four exports to `dist/` as JavaScript plus declarations. |

## Running it

```sh
zig build wasm-all              # produce both .wasm artifacts under zig-out/bin
zig build wasm-consumer-test    # node --test (depends on wasm-all)

# or directly (Node ≥ 22.6 strips the TypeScript types at load time):
node --test --experimental-strip-types hosts/web/test/*.test.ts hosts/web/*.test.ts
node --experimental-strip-types hosts/web/demo.ts
```

`zig build wasm-consumer-test` requires Node ≥ 22.6 for source type stripping. It is **not** part of `zig build test` so the Zig suite
stays runnable in toolchains without Node.

## Usage

### Binary IR + single-plugin validation

```js
import { SjonEncoder, SjonReader } from "./sjon-reader.ts";

const encoder = await SjonEncoder.load("./zig-out/bin/sjon.wasm");
const reader = await SjonReader.load("./zig-out/bin/sjon-binary.wasm");

// Source → Binary IR
const bin = encoder.toBinary('(scene :bpm 130 (canvas :name "main" [1 2 3]))');

// Binary IR → diagnostics
const report = reader.validateBinary(bin);
console.log(report.diagnostics);   // []

// Binary IR → safe-expression value
const value = reader.evalExprBinary(encoder.toBinary("(+ 1 2 (* 3 4))"));
console.log(value);                // 15
```

### Validating a multi-plugin document

`SjonHost` runs the cross-host validating pipeline: parse → partition
top-level forms into `(plugin …)` declarations / `(use-plugin …)`
references / data → load each manifest → resolve each reference →
schema-aggregate → validate the data forest. The diagnostic stream is
checked at `(code, path)` against Zig on supported fixtures. The WASM
runners replay 354 of 393 fixtures (38 `lowering-*` and `too-many-keys`
excluded by `conformance/classifier.json`); the TS reference has further
exclusions. See the [capability matrix](../../docs/INTEGRATION.md#capability-matrix).

#### Node — using the bundled `fs` resolver

```js
import { SjonHost } from "./SjonHost.ts";
import { createNodeFsResolver } from "./createNodeFsResolver.ts";

const projectRoot = "./examples/scene";
const projectFile = `${projectRoot}/sjon-project.sjon`;

// Build the resolver: indexes manifests under (project :plugins […]),
// captures any project-load diagnostics for the host to report.
const { resolver, projectDiagnostics } = createNodeFsResolver({
    projectRoot,
    projectFile,
});

const host = await SjonHost.load("./zig-out/bin/sjon.wasm", { resolver });

import { readFileSync } from "node:fs";
const source = readFileSync(`${projectRoot}/scene.sjon`, "utf8");

const result = host.validateDocument(source, {
    projectRoot,
    projectFile,
    projectDiagnostics,
});

for (const d of result.diagnostics) {
    if (d.severity !== "err") continue;
    console.error(`[${d.phase}] ${d.code} at ${d.path.join(".")}: ${d.message}`);
}
```

#### Browser — pre-fetched manifest map

`SjonHost`'s resolver is **synchronous** (WASM imports return immediately;
async would require a re-architecture). Browser callers should pre-fetch
all manifests, store them in a `Map<name, source>`, and supply a
sync resolver that does Map lookup:

```js
// In the browser, import the ESM build emitted by `pnpm build:browser`
// (`tsc -p tsconfig.browser.json`) — not the `.ts` source.
import { SjonHost } from "./dist/SjonHost.js";

// Pre-fetch every plugin you might reference. The exact set is
// app-specific; for a richer story (lockfile-driven discovery, async
// fetch in-flight) see the deferral note below.
const manifests = new Map();
for (const name of ["shapes", "audio"]) {
    const res = await fetch(`/plugins/${name}.sjon`);
    manifests.set(name, await res.text());
}

const resolver = (ref) => {
    if (ref.explicitPath !== null) {
        return { kind: "failure", code: "unresolved_plugin",
                 detail: "browser host does not support :path" };
    }
    const bytes = manifests.get(ref.name);
    if (!bytes) {
        return { kind: "failure", code: "unresolved_plugin",
                 detail: `no manifest pre-fetched for ${ref.name}` };
    }
    return { kind: "manifest", source: bytes, wasm: null };
};

// Browser uses `loadFromBytes`: `SjonHost.load(path)` is Node-only (it
// reaches for `node:fs`). Fetch the wasm yourself and hand over the bytes.
const wasmBytes = await fetch("/sjon.wasm").then((r) => r.arrayBuffer());
const host = await SjonHost.loadFromBytes(wasmBytes, { resolver });

const result = host.validateDocument(documentSource, {
    projectRoot: null,
    projectFile: null,
});
```

#### Out of scope

- **Async resolvers.** The resolver contract is sync: fetch everything a
  document references before validation, then hand the resolver the
  already-fetched bytes.
- **Bundler integration helpers.** Wire `sjon.wasm` as a static asset
  through your bundler of choice; the wrapper itself is dependency-free.

#### Executable plugins

A `Resolution.manifest` envelope carrying non-null `wasm` bytes now
instantiates inline: `SjonHost.load` runs pre-flight (compile, empty
imports, `sjon_plugin_abi_version() === 2`, required + declared
exports) and registers the instance in a per-host plugin pool. When the
document later evaluates a `:impl "wasm:…"` expr-func, the
`env.sjon_host_invoke_plugin` import bridges the call through the pool.
Traps map to `plugin_func_trapped`; plugin-reported errors to
`plugin_func_failed`; pre-flight failures collapse to
`plugin_abi_mismatch` / `plugin_export_missing` /
`plugin_import_forbidden` at the `(use-plugin …)` span.

### Validating against a local manifest string

When the manifest is already in hand — generated by a tool, or a fixture —
`validateAgainst` composes it with the document and runs the same
pipeline, with no project file and no resolver round-trip:

```js
import { SjonHost } from "./SjonHost.ts";

const host = await SjonHost.load("./zig-out/bin/sjon.wasm");

const manifestSource = `(plugin :name widget :version "1.0.0"
  (form :name widget
    (key :name name :type symbol)))`;

const documentSource = "(widget :name w0)";

const { diagnostics } = host.validateAgainst(manifestSource, documentSource);
```

The composition is exactly `manifestSource + "\n" + documentSource`: one
inserted LF even when the manifest already ends in one — nothing is
trimmed, normalized, or printed. `projectRoot` and `projectFile` are
forced to `null` for the call, so the two arguments are the only schema
source; the option type (`ValidateAgainstOptions`) is narrowed to
`failurePolicy` and `heldSymbol`, and rejects the project fields at
compile time.

Every diagnostic `span` indexes the **composed** UTF-8 bytes: a
document-origin span is offset by
`new TextEncoder().encode(manifestSource).byteLength + 1`, with no
rebasing. This is the convenience path — it recomposes and reparses on
every call. Repeated validation of one manifest should use
[preloaded-schema handles](#preloading-a-schema-once) instead.

### Preloading a schema once

`SjonHost.preload` compiles one schema for reuse across many documents.
Pass one manifest source or an array of standalone `(plugin …)` sources:

```js
const host = await SjonHost.load("./zig-out/bin/sjon.wasm");

const schema = host.preload(manifestSource);
// or: host.preload([shapesManifest, audioManifest]);

if (schema.hasErrors) {
  // Manifest content problems are reported, not thrown. The handle is
  // still usable; borrowing a partial schema is your call.
  for (const d of schema.diagnostics) console.error(d.code, d.message);
}

const { diagnostics } = host.validateDocument(documentSource, {
  projectRoot: null,
  projectFile: null,
  preloaded: schema,
});

schema.dispose(); // idempotent; releases the WASM-side schema
```

The preloaded schema is additive with document inline `(plugin …)` and
resolved `(use-plugin …)` declarations: the document validates against
preloaded ++ document-loaded. No span is rebased — document diagnostics
index the document alone, while `schema.sourceDiagnostics[i]` stays
input-index aligned to manifest source `i` — so there is no manifest
prefix to subtract. A form name claimed by both surfaces reports
`ambiguous_form` at validation rather than silently picking a winner.

The handle is instance-scoped and branded in JavaScript. A handle from a
different `SjonHost`, a disposed handle, or a bare numeric ID is refused
with an `InvalidSchemaHandle` error before it reaches WASM. Disposal is
explicit and one-way (numeric IDs are never reused): `dispose()` is
idempotent, use after dispose throws, and `await using host = await
SjonHost.load(...)` frees every live handle through `Symbol.asyncDispose`
before clearing plugin references. Disposing a handle (or the host) from
inside an active host call — a resolver or plugin callback — throws
`SchemaInUse`; freeing there would pull the schema out from under the
borrow that is still reading it.

Each `preload` call returns an independent handle; it never replaces or
stacks with another, and there is no ambient current schema. One
validation borrows at most one `preloaded` handle. Preloading compiles
declarative manifests only: an `:impl "wasm:…"` plugin is not
instantiated, so a handle makes its form *knowable* but not executable —
evaluating that form in the web host fails `plugin_func_failed`.
Executable hooks keep the resolver + pre-flight path. Explicit disposal is
required on a long-lived host; repeated preload/dispose cycles do not grow
the live-handle set.

This is a host capability, not a wire change: no binary-IR byte,
diagnostic code, or corpus case moves, so the TypeScript parity host and
`conformance/cases/` owe nothing. The raw ABI — input JSON array, framed
report, `preloadedHandle` option, and free semantics — is under
[Wire-protocol notes](#wire-protocol-notes) below.

`@sjon-lang/schema`'s WASM backend uses this surface for clean generated
manifests: it caches one handle per exact manifest text and falls back to
its historical two-LF composition whenever the preload report has any
diagnostics, so a dirty manifest never produces a mixed
source-coordinate diagnostic stream. Large fixed-schema browser apps are
the other beneficiary — send the manifest once instead of prepending it to
every document. The playground does not use this path: it runs on
`sjon-lsp.wasm`, whose native `schema_bundle` already retains its
`PreloadedSchema`.

### Effective config: reading materialized defaults

Apply schema defaults to a user's config *without writing into their
file*: validate, then read the side-tables. One key below defaults from
a literal, one from an expression — both land on
`materializedDefaults` when omitted:

```js
const src = `
(plugin :name config :version "1.0.0"
  (form :name server
    (key :name port :type number :default 8080)
    (key :name workers :type number :default (if true 4 1))))

(server)
`;

const host = await SjonHost.load('./zig-out/bin/sjon.wasm');
const r = host.validateDocument(src, { projectRoot: null, projectFile: null });

const effective = {};
for (const d of r.materializedDefaults) {
  // d.path = ['server', 'port'], d.key = 'port',
  // d.origin = 'literal_default' | 'expression_default', d.value = 8080 / 4
  effective[d.key] = d.value;
}
// effective => { port: 8080, workers: 4 } — the user's file still says `(server)`.
```

`evaluatedResults` is the sibling table for top-level expression forms
(`{ index, value }` per evaluated root). The CLI's `sjon effective
doc.sjon` prints the same view as spliced source text; the Rust host's
`materialized_defaults` example in
[hosts/rust/README.md](../rust/README.md) is this snippet, semantically
identical.

### Structural edits

`SjonEncoder.applyEdit(source, action)` applies one JSON edit action and
returns the re-printed source; `applyEdits(source, actions, options?)`
applies a list in one pass. The action grammar is `docs/LANGUAGE.md` §11:
eight ops, six of them over a `path` into one root (with an optional
`root` naming which) and two over the root list itself (`insert_root`
and `remove_root`, addressed by `index`).

`{ layout: "preserve" }` keeps the author's layout: each action replaces
one span, and every other byte comes back untouched, comments and column
alignment included. The default, `"reprint"`, prints the whole edited
tree, so comments survive but the line breaks are the printer's.

```js
// Only the `2` changes; the rest of the file is the author's.
encoder.applyEdits(source, [{ op: "replace", path: ["zoom"], value: 3 }], {
    layout: "preserve",
});
```

```js
// Compose a node into a new parent. The node at `path` is cloned into
// the `hole` inside `value`, so the comments inside it survive; the
// other five ops build their node from `value` through the JSON bridge,
// which carries none.
encoder.applyEdit(source, {
    op: "wrap",
    root: 1,                                  // the camera, after (use-plugin …)
    path: ["alpha"],
    value: { $expr: ["+", null, 0.1] },       // null marks the hole
    hole: [0],                                // first positional child of the parent
});
```

A file that names a plugin has more than one root, and an action on it
says which with `root`; omitting it there throws `SjonWasmError`
(`MultipleRoots`) rather than editing whichever form came first. A
document that does not parse throws `ParseErrors` instead of being
edited as the parser recovered it.
[`examples/edit-wrap.mjs`](../../examples/edit-wrap.mjs) prints the
three `wrap` cases side by side.

### Which node is under a byte

`encoder.addressOfSpan(source, start, end)` answers with the innermost
node containing a byte range, as `{ root, path, span, kind }`. `root` and
`path` are an edit action's two fields, so the answer goes straight back
into `applyEdits`. For more than one question per revision,
`encoder.nodeTable(source)` returns every addressable node in pre-order,
and the free functions `rowContaining(table, start, end?)` and
`pathOfRow(table, row)` hit-test it without calling into WebAssembly.
Offsets are UTF-8 bytes, and both answer on a document that does not
parse, with its diagnostics beside the answer.
[Editing SJON from a program](https://hugodaniel.com/pages/sjon/editing)
walks through both, and held positions (`heldSymbol`), on one camera.

### Declared identities: name → current address

`validateDocument` returns `result.identities` on the same result as
`diagnostics`. Nothing extra is called: one `validateDocument` is one
`sjon_host_validate_document` call, and the array rides that payload. It is
always present, empty when no declared name qualifies, and there is no second
export, reparse, or cached map to keep in step. `validateAgainst` and preloaded
validation return the field from their existing call, and the
project-diagnostic merge spreads the WASM result first, so identities are not
lost.

An identity is `(registry, scope, symbol)`: the canonical cross-ref registry,
the outermost-first stable parent prefixes, and the author-written symbol under
the vocabulary's `:name-key`. A row's `address` is `{ root, path }` — the same
`root` and `path` an edit action takes. The public TypeScript shape is:

```ts
interface IdentityScope {
    readonly registry: string;
    readonly symbol: string;
}
interface IdentityAddress {
    readonly root: number;
    readonly path: readonly (string | number)[];
}
type IdentityRow =
    | {
          readonly registry: string;
          readonly scope: readonly IdentityScope[];
          readonly symbol: string;
          readonly status: "resolved";
          readonly address: IdentityAddress;
      }
    | {
          readonly registry: string;
          readonly scope: readonly IdentityScope[];
          readonly symbol: string;
          readonly status: "ambiguous";
          readonly address: null;
      };
```

and the rows look like this on the wire (shapes, not one fixture):

```json
"identities": [
  { "registry": "music/piece", "scope": [], "symbol": "opening",
    "status": "resolved", "address": { "root": 1, "path": [] } },
  { "registry": "music/phrase",
    "scope": [{ "registry": "music/piece", "symbol": "opening" }],
    "symbol": "refrain", "status": "resolved",
    "address": { "root": 2, "path": ["body", 0] } },
  { "registry": "probe/kernel", "scope": [], "symbol": "flow",
    "status": "ambiguous", "address": null }
]
```

Compare a key **structurally**: registry string, then `scope` element-by-element
(each element's `registry` and `symbol`, in outermost-first order), then
`symbol`. Never compare `IdentityScope` objects by reference and never search by
address. No matching row is not found — anonymous nodes have no row at all. An
`ambiguous` row is the only row with a null address; refuse it before applying
an action rather than falling back to a positional guess. Rows are sorted
deterministically by registry, scope prefix, then symbol, so equal results from
equal inputs have equal order.

#### Rebuilding identity → address each revision

An address is a position in one revision, so retain the key, discard the
address, and revalidate after every edit:

```js
import { SjonHost } from "./SjonHost.ts";
import { SjonEncoder } from "./sjon-reader.ts";

const manifest = `(plugin :name probe :version "1.0.0"
  (value-kind :name kernel-ref :underlying symbol
    :cross-ref (cross-ref :target kernel))
  (form :name kernel (key :name name :type symbol :optional true))
  (form :name wrap :open true))`;

let source = `${manifest}
(wrap [3 (kernel :name flow)])
(kernel :name mover)
(kernel :name anchor)
`;

const host = await SjonHost.load("./zig-out/bin/sjon.wasm");
const encoder = await SjonEncoder.load("./zig-out/bin/sjon.wasm");

// The stable key is (registry, scope, symbol); the address is not.
const rowOf = (result, symbol) =>
    result.identities.find(
        (row) => row.registry === "probe/kernel" && row.scope.length === 0 && row.symbol === symbol,
    );

let result = host.validateDocument(source, { projectRoot: null, projectFile: null });
console.log(rowOf(result, "flow").address);   // { root: 1, path: [0, 1] } — wrap's vector, element 1

// A sibling inserted before the named element moves its address, not its key.
source = encoder.applyEdit(source, {
    op: "insert_positional",
    root: 1,
    path: [0],
    index: 1,
    value: 9,
});
result = host.validateDocument(source, { projectRoot: null, projectFile: null });
console.log(rowOf(result, "flow").address);   // { root: 1, path: [0, 2] }

// Removing and reinserting a root moves that root's address, not its key.
source = encoder.applyEdit(source, { op: "remove_root", index: 2 });
source = encoder.applyEdit(source, {
    op: "insert_root",
    index: 3,
    value: { $form: "kernel", name: { $sym: "mover" } },
});
result = host.validateDocument(source, { projectRoot: null, projectFile: null });
console.log(rowOf(result, "flow").address);   // { root: 1, path: [0, 2] } — unchanged
console.log(rowOf(result, "mover").address);  // { root: 3, path: [] } — root moved 2 → 3
```

There is no identity edit selector: apply an action to the current `address`
with `applyEdit` / `applyEdits`. The identity finds the row; it does not edit.
There is also no history across deletion and recreation: a name removed and
later re-added is the same key, not a tracked node, so a consumer that needs
durable history keeps it in its own model.

`identities` is a host-result addition, not a wire change: no binary-IR byte,
diagnostic code, or corpus case moves. Each call is fresh; nothing caches a row
or an address between revisions.

## Wire-protocol notes

The two artifacts share an identical C ABI: each output-returning
function returns a pointer to a `[u32 ok][u32 len][u8 payload…]`
buffer in the WASM linear memory. `sjon-reader.ts` reads the header,
copies the payload into a fresh JS `Uint8Array`, and frees the WASM
allocation before returning.

**Memory aliasing.** WASM linear memory can be reallocated when the
heap grows. `sjon-reader.ts` never holds a pointer or `Uint8Array`
view across function boundaries; every returned value is a JS-owned
copy. If you fork this module to add new exports, keep that invariant.

**Error framing.** When a WASM call fails it returns `ok=0` with the
Zig error name as the payload (`"InvalidEncoding"`, `"MultipleRoots"`,
`"DivisionByZero"`, …). The wrapper turns these into `SjonWasmError`
with `.fnName` and `.errorName` properties; if you want to inspect
the framed flag directly, use `reader.tryValidateBinary` or the lower-
level `_callRaw` helper.

**Preloaded-schema handles.** `sjon_preload_schema(src_ptr, src_len)` takes
a UTF-8 JSON array of standalone `(plugin …)` manifest source strings and
returns the framed report below (freed like every other export):

```json
{"handle":3,"hasErrors":false,"diagnostics":[],"sourceDiagnostics":[[]],
 "aggregateDiagnostics":[],
 "loadedPlugins":[{"name":"pngine","version":null,"formCount":75}]}
```

`sourceDiagnostics[i]` stays aligned to input source `i` even when that
source failed; `diagnostics` is the flattened source reports followed by
the aggregate reports. Manifest content problems are `ok=1` with
`hasErrors: true` and a live partial handle; malformed JSON
(`InvalidOptions`), handle exhaustion (`HandleExhausted`), and OOM are
errors — `ok=0` where the error frame itself can be allocated. The option
`preloadedHandle` on `sjon_host_validate_document` /
`sjon_host_eval_expr` borrows one handle for that synchronous call only
(`null`/absent is the old behavior); zero, negative, and non-integral values
are `InvalidOptions` at parse, while a stale or unknown positive ID frames
`InvalidSchemaHandle` at use. A foreign ID is rejected by this wrapper's
brand before it reaches WASM; the raw ABI cannot distinguish one that
collides with a live local ID. `sjon_schema_free(handle)` is total
and idempotent — zero, unknown, and already-freed IDs are no-ops, and a
freed ID is never reissued. The raw ABI carries no owner token, which is
why this wrapper brands `PreloadedSchemaHandle` per instance and never
exposes the numeric ID.

## Lifting this into your own project

Install it from npm:

```sh
npm install @sjon-lang/web
```

The package carries the compiled host and its declarations. It does not
carry the `.wasm` artifacts: build them from the SJON source with
`zig build wasm-all` (they land in `zig-out/bin/`) and hand their path to
`load`, or their bytes to `loadFromBytes`.

Two alternatives, if you would rather not depend on the registry:

1. **Vendor it.** Copy `sjon-reader.ts` (plus `parseJsonWithBigInt.ts`
   and `types.ts`) into your repo and ship the two `.wasm` files
   alongside. In Node, import the `.ts` directly under
   `--experimental-strip-types`; for the browser, run
   `tsc -p tsconfig.browser.json` and import the emitted `dist/*.js`.
2. **Path-link it during development.** In your project's
   `package.json`:

   ```json
   "dependencies": {
     "@sjon-lang/web": "file:../sjon/hosts/web"
   }
   ```

   The `exports` map resolves to the `.ts` sources (Node ≥ 22.6 strips
   the types); build to `dist/` for any environment that can't.
