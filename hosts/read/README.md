# @sjon-lang/read — synchronous, dependency-free SJON reader

A pure-TypeScript reader for SJON: source-order trees, half-open **UTF-8 byte**
spans, and engine-order diagnostics. No WASM, no I/O, and **zero runtime
dependencies**; Node `>=20`, CC0-1.0. It ships as part of the four-package
release set (`schema → read → web → highlight`), and its 273-test suite
includes a test-only oracle that compares structure, spans, diagnostics, and
per-root values against the built `sjon.wasm`.

This is a **reader**, not a host. It parses and classifies text; it does not
validate against a schema, evaluate expressions, edit a document, load plugins,
or read files. Those surfaces stay on the WASM hosts (`@sjon-lang/web`,
`sjon-host`) and the Zig reference.

## What it promises

```ts
export interface Span {
  readonly start: number;
  readonly end: number;
}

export interface ReadResult {
  readonly roots: readonly Node[];
  readonly diagnostics: readonly ReadDiagnostic[];
}

/** Return roots only when no err-severity parse diagnostic fired. */
export function read(source: string): Node[];

/** Total parse: recovered roots and every diagnostic, in engine order. */
export function readResult(source: string): ReadResult;

export class ReadError extends Error {
  readonly result: ReadResult;
}

export function fields(form: FormNode): FormFields;

export interface FormFields {
  readonly pairs: readonly KvpairNode[];
  readonly positionals: readonly Node[];
  /** Last source-order pair wins; duplicates remain available in `pairs`. */
  get(key: string): Node | undefined;
}

export interface ReadDiagnostic {
  readonly code: string;
  readonly severity: 'err' | 'warning';
  readonly message: string;
  readonly span: Span;
  readonly path: readonly string[];
}
```

`Node` is one discriminated union on `tag` — `form`, `kvpair`, `vector`,
`number`, `date`, `time`, `string`, `symbol`, `keyword`, `boolean`, `nil` —
and every variant carries a byte `span`. A form's `head` is unqualified with
the prefix in `namespace`; a kvpair's `key` is without its `:` and its
`keySpan` includes it. A kvpair is a real node, so `children` / `elements`
keep source order and duplicate keys. Numbers carry an f64 `value`, an
optional unit, and an exact `bigint` when the literal is integer-shaped and
unitless.

### `read` — throwing, for strict inputs

`read(source)` is the strict entry. It parses once and returns the roots only
when no `err`-severity diagnostic fired; otherwise it throws `ReadError`,
whose `result` is the identical single-parse result (partial roots plus every
diagnostic). Use it where a recovered partial tree must not become
configuration — a resolver indexing plugin names, a build tool deciding what
to compile.

### `readResult` — total, for editors

`readResult(source)` is total for SJON syntax. Malformed input yields the
recovered roots plus every diagnostic in engine order; it never throws for
syntax. Use it for editor diagnostics, recovery UIs, and any consumer that
can render a partial forest. Both entries reject a non-string argument with
`TypeError` rather than coercing it into source.

### `fields` — a view, not a second pairing pass

`fields(form)` filters the form's existing children into `pairs` and
`positionals` in source order, preserving duplicates; `get(key)` scans
backwards so the last source-order pair wins. The parser performs the one
greedy `:key value` pass, so a positional keyword that became a flag is never
re-paired by this view.

### UTF-8 byte spans

Every span is a half-open **UTF-8 byte** range `[start, end)` into the encoded
source — including `headSpan` and `keySpan`. JS UTF-16 indices are never
exposed. The source string is encoded exactly once with `TextEncoder`
semantics before lexing, so a lone surrogate becomes U+FFFD. Decoding is
confined to node values; offsets always fall on code-point edges.

Arbitrary invalid-UTF-8 *byte strings* and comment retention are not promised
by this package: it reads a JS string, and comments are trivia. Those would be
different public data models, not missing parser cases.

### The engine oracle and its three exclusions

The test suite (`test/oracle.test.ts`, helpers under `test/helpers/`) drives
the built `zig-out/bin/sjon.wasm` through its public exports only — never the
engine's Zig sources. It compares `sjon_node_table` rows (structure, spans,
diagnostic code/severity/span sequence) and, per root, the UTF-8 bytes sliced
from that root's span through `sjon_to_json`. A missing, truncated, unbuilt,
or source-stale artifact throws with the command that fixes it; the oracle
never skips itself.

Only three representation losses are permitted, and each one is counted and
asserted to keep its reason:

- `expression` — the core schema collapses expression forms to `$expr` (or
  refuses a labelled one with `InvalidExprForm`); this is not source structure.
- `duplicate-key` — a JSON object keeps one value per key, so a duplicate pair
  is lost on the value leg while the tree still holds it.
- `parse-errors` — the value bridge needs a clean tree; structure and
  diagnostics still run for these sources.

Neither engine entry ships in the package.

## Developing

```bash
zig build wasm-all     # the oracle needs zig-out/bin/sjon.wasm
cd hosts/read
pnpm run typecheck     # tsc --noEmit, the beyond-strict host flag set
pnpm test              # node --test over test/*.test.ts
```

Both package scripts also run through the workspace glob legs of
`zig build verify`, which builds the WASM artifacts first.
