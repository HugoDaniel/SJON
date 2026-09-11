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

The host is written in TypeScript and runs in Node ≥ 22.6 with
`--experimental-strip-types` — no build step. For the **browser**, an
ESM build under `dist/` is emitted by `tsc -p tsconfig.browser.json`
(run `pnpm build:browser`, or `zig build web-host-browser`); browsers
can't execute `.ts` directly.

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
| `package.json`                  | ESM package descriptor (`exports` map to the `.ts`).    |

## Running it

```sh
zig build wasm-all              # produce both .wasm artifacts under zig-out/bin
zig build wasm-consumer-test    # node --test (depends on wasm-all)

# or directly (Node ≥ 22.6 strips the TypeScript types at load time):
node --test --experimental-strip-types hosts/web/test/*.test.ts hosts/web/*.test.ts
node --experimental-strip-types hosts/web/demo.ts
```

`zig build wasm-consumer-test` requires Node ≥ 20 (for built-in
`node:test`). It is **not** part of `zig build test` so the Zig suite
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
byte-identical (`(code, path)`) to the Zig CLI and the
`hosts/typescript-parity` reference.

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
returns the re-printed source; `applyEdits(source, actions)` applies a
list in one pass. The action grammar is `docs/LANGUAGE.md` §11: six ops
over a `path` into the document, plus an optional `root`.

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
(`MultipleRoots`) rather than editing whichever form came first. Layout
is not preserved by any op (the result is re-printed from the tree, and
a form carrying a comment always goes multi-line); comments are.
[`examples/edit-wrap.mjs`](../../examples/edit-wrap.mjs) prints the
three cases side by side.

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

## Lifting this into your own project

The wrapper is intentionally dependency-free. Two options:

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
