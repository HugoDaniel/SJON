# sjon-host-ts — Reference second-host implementation

A **partial** TypeScript port of the SJON validator. Exists to prove
the multi-language conformance story: this host loads the same
`conformance/cases/<name>/schema.sjon` manifests, validates the same
inputs, and emits diagnostics whose `(code, path)` pairs match the
Zig reference implementation byte-for-byte **on the corpus subset it
runs**. It is declarative-only by design — it skips every fixture that
needs the Expr evaluator, the executable-plugin runtime, or the
lowering / defaults passes (enumerated below), so it is *not*
byte-identical across the whole corpus.

This is a **reference**, not a production package. It implements the
substrate features exercised by the corpus subset it runs:

  * Tokenisation: parens, brackets, keywords (`:foo`), bare symbols,
    integer/float numbers with optional unit suffixes (`4b`, `2.5deg`,
    `50%`, `250ms`), hex, digit-group underscores, double-quoted
    strings, `true` / `false` / `nil`, line comments (`;`).
  * Parser: forms, kvpairs (greedy `:k v` pairing), vectors, atoms.
  * Validator: form-head lookup, declared-key type checks, duplicate
    keys, missing required keys, unit constraints (`unit_required`,
    `unit_not_allowed`, `unit_forbidden`,
    `numeric_bound_unit_mismatch`), HeadSet narrowing for form-typed
    slots. Emits diagnostics with semantic paths matching
    `docs/portable-manifest-v1.md` §11.1.
  * Manifest loader: `(plugin …)` walking → `Plugin`. Multi-plugin
    schemas via inline `(plugin …)` declarations and `(use-plugin …)`
    references resolved through `Host.validateDocument`.
  * Host pipeline: `validateDocument(source, options)` mirrors
    `src/Host.zig` — partition top-level forms into declarations /
    references / data, then run manifest, aggregate, and validation
    passes. The default `FilesystemResolver` indexes the project file
    declared by a sibling `sjon-project.sjon`; tests inject mock
    resolvers via `options.resolver`.

Deliberately **not** in v1 of this host:

  * `expr-func` validation (typed signatures, arity, kvpair-rejection).
  * Binary IR and `validateBinary`.
  * Comments inside structures (only top-level line comments
    are handled).
  * Block comments (`#| … |#`).
  * Raw strings.
  * The full diagnostic code surface — only the codes the corpus
    cases assert on are wired.
  * `:version` / `:hash` enforcement on `(use-plugin …)` references —
    parsed, accepted, not validated (matches the Zig declarative
    stance).
  * WASM plugin loading.

### Conformance cases it skips

The runner (`test/conformance.test.ts`) filters out these case families
by name — each is covered end-to-end by the Web + Rust hosts, which
delegate evaluation to the shared `sjon.wasm`:

  * `plugin-exec-*` — the executable-plugin runtime (instantiate sidecar
    wasm, pre-flight, dispatch); declarative-only by design.
  * `default-expr-*`, `default-materialize-*`, `effective-axis-*` —
    schema defaults, runtime default-materialization, and the
    effective-validation axes that read that overlay.
  * `lowering-*` — the lowering-runtime hook registry + `test/identity-v1`
    hook (no JS-side lowering pass).
  * `expr-map-*`, `expr-filter-*`, `expr-any-*`, `expr-all-*`,
    `expr-fold-*` — higher-order core binder forms (no Expr evaluator,
    and the validator doesn't seed the core plugin, so these surface as
    `unknown_form`).
  * `expr-number-*`, `expr-date-*`, `expr-time-*`, `expr-trig-*` —
    evaluator-tied value round-trips through `let` / `=`.
  * `exclusive-multi-key-*`, `exclusive-bundle-*` — multi-key
    exclusive-group runtime (schema-export reads the group metadata, but
    the validator emits no group diagnostics).

…plus the legacy `too-many-keys` fixture (`HOST_PASS_SKIP`), noted under
Usage below. Everything else in `conformance/cases/` runs.

## Usage

```bash
cd hosts/typescript-parity
npm install
npm test                  # runs the conformance corpus
```

The conformance runner reads `../../conformance/cases/<name>/`
relative to this package and compares emitted diagnostics against
each case's `expected.sjon`.

The host pass graduates the legacy schema+input fixtures through
`validateDocument`
too: each case runs once via the existing pre-compose path
(`conformance: <name>`) and once via the host adapter
(`conformance host: <name>`) which synthesises a single document
containing each plugin manifest as an inline `(plugin …)` declaration.
Both paths must agree on `(code, path)`; the same dual-pass invariant
runs on the Zig side (`src/conformance_tests.zig`) and in the WASM-
backed web host (`hosts/web/test/conformance.test.ts`). One fixture
(`too-many-keys`) is in the documented `HOST_PASS_SKIP` set because
the host pipeline drops errored plugins — see the comment in
`test/conformance.test.ts` for the full rationale.

## Extending the host

Add support for a new diagnostic code:

  1. Add a fixture under `conformance/cases/<name>/` (Zig host runs
     it from there too — the directory tree is the single source of
     truth, both runners discover cases by walking it).
  2. Wire the code in `src/diagnostics.ts` (just an enum literal).
  3. Add the validation rule in `src/validator.ts`.

The Zig host (`src/Validator.zig` + `src/conformance_tests.zig`)
is the source of truth for behaviour. When a divergence appears,
match Zig's output, not the other way around — the substrate spec
lives in `docs/LANGUAGE.md` and `docs/portable-manifest-v1.md`.
