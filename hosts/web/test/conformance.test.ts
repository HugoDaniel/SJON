// D5 conformance runner.
//
// Phase 1: walks `conformance/cases/*` and runs the inline-manifest /
// `(use-plugin …)` cases through `SjonHost.validateDocument`.
//
// Phase 2 (commit 4): graduates the legacy schema+input cases through
// the same `validateDocument` entry by synthesising a single document
// containing each schema/extra as an inline `(plugin …)` declaration
// followed by the input source. This mirrors `runLegacyCaseAsHost` in
// `src/conformance_tests.zig` and the matching `conformance host: …`
// tests in `hosts/typescript-parity/test/conformance.test.ts`.
//
// Cross-host parity contract: the `(code, path)` stream this runner
// produces must match the Zig CLI (`sjon validate`) and typescript-
// parity for every fixture. Comparison ignores the `phase` metadata
// (D4 stance) — the Zig validator-only path doesn't tag phases, and
// the host's manifest/aggregate/validation tagging is host-private.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonHost } from '../SjonHost.ts';
import { createNodeFsResolver } from '../createNodeFsResolver.ts';
import { CONFORMANCE_DIALECT, parseNode, skipTrivia } from '../sjonSubsetParser.ts';
import type { Cursor, FormNode, ParsedNode } from '../sjonSubsetParser.ts';
import { parseJsonWithBigInt } from '../parseJsonWithBigInt.ts';
import {
  assertDiagnosticsMatch,
  classifyCase,
  discoverCaseDirs,
  hostCaseName,
  loadWasmHostSkipFamilies,
  queryCaseName,
  readMarkers,
  registerClassifierAudits,
  runnerOf,
  synthesizeLegacyDocument,
} from '../../conformance-shared/index.ts';
import type { ExpectedDiagnostic, SkipFamily } from '../../conformance-shared/index.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');
// Read sjon.wasm once for the whole run. With ~240 per-fixture tests,
// re-reading the bytes per test is wasted I/O — each test still gets its
// own instance via loadFromBytes (mirrors the Rust host's OnceLock).
const wasmBytes = readFileSync(wasmPath);
const corpus = path.join(root, 'conformance/cases');

// Directory-only discovery (shared with the ts-parity runner): drops non-dir
// junk (`.DS_Store`) and hidden dirs (the gitignored `.zig-cache`). A new
// fixture lands in the right runner automatically — the corpus dir is the
// single source of truth.
const ENTRIES = discoverCaseDirs(corpus);

// Skip families — every case dir the Web host does NOT run must match
// exactly one of these, carrying the reason it is skipped. The Web host
// drives the kitchen-sink `sjon.wasm`, exactly like the Rust host, so its
// skip set IS the shared wasm-host set — single-sourced in
// `conformance/classifier.json` and materialized here. (The
// typescript-parity host, a validator-only port, keeps a larger host-local
// set.) `hosts/rust/build.rs` reads the same JSON at build time.
const SKIP_FAMILIES: readonly SkipFamily[] = loadWasmHostSkipFamilies();

// Inline (`document.sjon`), legacy (`schema.sjon`), and PatternQuery
// (`query.sjon`) run sets — all derived from the shared `runnerOf` source
// of truth, so the audits and the runners can never disagree.
const runnerFor = (name: string): 'legacy' | 'inline' | 'query' | null =>
  runnerOf(name, readMarkers(corpus, name), SKIP_FAMILIES);
const INLINE_CASES = ENTRIES.filter((name) => runnerFor(name) === 'inline');
const LEGACY_CASES = ENTRIES.filter((name) => runnerFor(name) === 'legacy');
const QUERY_CASES = ENTRIES.filter((name) => runnerFor(name) === 'query');

// Shared corpus-coverage audits (non-empty, every-dir-classified,
// no-dead-family, classifier anchor) + the host-specific skip anchor below.
registerClassifierAudits({ entries: ENTRIES, corpusDir: corpus, skipFamilies: SKIP_FAMILIES });

test('classifier: lowering-* is a reasoned skip despite a document marker', () => {
  const c = classifyCase(
    'lowering-foo',
    { hasSchema: false, hasDocument: true, hasQuery: false },
    SKIP_FAMILIES,
  );
  assert.equal(c.kind, 'skip');
});

// readExpected must locate the `(diagnostics …)` form wherever it sits
// among the top-level forms — the Rust and ts-parity runners search all
// roots (`common::read_expected`, ts-parity `readExpected`), so a fixture
// that writes `(values …)` before `(diagnostics …)` must not fail only on
// the Web host. Corpus-free anchor (readExpected is a pure parse).
test('readExpected: finds (diagnostics …) even when (values …) comes first', () => {
  const valuesFirst =
    '(values (value :index 0 :result 42))\n(diagnostics (diagnostic :code unknown_form :path [foo]))';
  const got = readExpected(valuesFirst);
  assert.equal(got.length, 1);
  assert.equal(got[0]!.code, 'unknown_form');
  assert.deepEqual([...got[0]!.path], ['foo']);
});

// `synthesizeLegacyDocument` (shared by both TS hosts) and Rust's
// `synthesize_legacy_document` build the same string from a legacy case,
// and the comment on each said the two "MUST stay byte-identical" while
// nothing checked it. Both now diff against this golden, so a change to
// the separator or the extra-* ordering on one side fails on that side
// instead of quietly desynchronising the two hosts' inputs.
//
// `ambiguous-cross-ref-scope` is the case pinned because it has an
// `extra-b.sjon` — a case without one exercises neither the ordering
// nor the second separator.
test('synthesizeLegacyDocument matches the cross-host golden', () => {
  const golden = readFileSync(path.join(corpus, '..', 'legacy-synthesis.golden'), 'utf8');
  const built = synthesizeLegacyDocument(path.join(corpus, 'ambiguous-cross-ref-scope'));
  assert.equal(built, golden);
});

// The expected.sjon vocabulary is closed — a fixture typo must fail the
// read, not weaken the assertion it belongs to. Mirrors the matching
// tests in src/ConformanceExpected.zig, ts-parity and Rust.
// Corpus-free anchor (readExpected is a pure parse).
test('readExpected: rejects unknown fixture vocabulary', () => {
  const rejected = [
    '(diagnostics 7)',
    '(diagnostics (diagnostc :code unknown_form))',
    '(diagnostics (diagnostic unknown_form))',
    '(diagnostics (diagnostic :code unknown_form :pat [a]))',
    '(diagnostics (diagnostic :code unknown_form :severity warnign))',
    '(diagnostics (diagnostic :code unknown_form :path (a)))',
    '(diagnostics (diagnostic :path [a]))',
  ];
  for (const src of rejected) {
    assert.throws(() => readExpected(src), `reader accepted \`${src}\``);
  }
  const accepted = readExpected(
    '(diagnostics (diagnostic :code unknown_form :path [a 0 "b"])' +
      ' (diagnostic :code deprecated_member :severity warning))',
  );
  assert.equal(accepted.length, 2);
  assert.deepEqual([...accepted[0]!.path], ['a', '0', 'b']);
  assert.equal(accepted[1]!.severity, 'warning');
});

for (const name of INLINE_CASES) {
  test(hostCaseName(name), async () => {
    const caseDir = path.join(corpus, name);
    const documentPath = path.join(caseDir, 'document.sjon');
    const expectedPath = path.join(caseDir, 'expected.sjon');
    assert.ok(existsSync(documentPath), `${name}: missing document.sjon`);
    assert.ok(existsSync(expectedPath), `${name}: missing expected.sjon`);

    const documentSrc = readFileSync(documentPath, 'utf8');
    const expectedSrc = readFileSync(expectedPath, 'utf8');
    const projectFile = existsSync(path.join(caseDir, 'sjon-project.sjon'))
      ? path.join(caseDir, 'sjon-project.sjon')
      : null;

    // Always supply a resolver — even without a project file, the
    // explicit-`:path` branch is needed (e.g. `use-plugin-name-
    // mismatch`). `createNodeFsResolver` handles `projectFile=null`
    // by returning an empty name index; `:path` still resolves.
    // typescript-parity gets the same effect via its auto-built
    // `FilesystemResolver`, which the WASM host can't construct
    // because `Dir.cwd()` is freestanding-disabled.
    const { resolver, projectDiagnostics } = createNodeFsResolver({
      projectRoot: caseDir,
      projectFile,
    });

    const host = await SjonHost.loadFromBytes(wasmBytes, { resolver });
    const result = host.validateDocument(documentSrc, {
      projectRoot: caseDir,
      projectFile,
      projectDiagnostics,
    });

    const diags = result.diagnostics;
    const expected = readExpected(expectedSrc);

    assertDiagnosticsMatch(name, diags, expected);

    // Optional `expected.values.json` sibling — present on value-carrying
    // fixtures where the codec round-trip produces a value worth locking
    // in. The sibling is generated (build-time) from the fixture's
    // `(values …)` block through the SAME `wasm_common.appendValue` the
    // envelope uses, so routing both the sibling and `evaluatedResults`
    // through `parseJsonWithBigInt` makes `deepStrictEqual` exact by
    // construction (u64-max is BigInt on both sides). `evaluatedResults`
    // is always populated (empty array when nothing evaluated) per
    // writeHostResult's wire contract.
    const expectedValues = loadExpectedValuesJson(caseDir);
    for (const [indexStr, expectedValue] of expectedValues) {
      const index = Number(indexStr);
      const actual = result.evaluatedResults.find((r) => r.index === index);
      assert.ok(
        actual,
        `${name}: expected value at index ${index} but no matching evaluatedResults entry; got [${result.evaluatedResults.map((r) => r.index).join(', ')}]`,
      );
      assert.deepStrictEqual(
        actual!.value,
        expectedValue,
        `${name}: value mismatch at index ${index}`,
      );
    }
  });
}

// PatternQuery — query each pattern over its window via `sjon_query_pattern`
// and compare the returned `(haps …)` / `(diagnostics …)` text against
// expected.sjon. Both are parsed by the same mini-parser, so a structural
// deepEqual is the cross-host bit-exactness check.
for (const name of QUERY_CASES) {
  test(queryCaseName(name), async () => {
    const caseDir = path.join(corpus, name);
    const documentSrc = readFileSync(path.join(caseDir, 'document.sjon'), 'utf8');
    const querySrc = readFileSync(path.join(caseDir, 'query.sjon'), 'utf8');
    const expectedSrc = readFileSync(path.join(caseDir, 'expected.sjon'), 'utf8');

    const { begin, end, seed } = readQuerySpec(querySrc);
    const host = await SjonHost.loadFromBytes(wasmBytes);
    const actualText = host.queryPattern(documentSrc, begin, end, seed);

    assert.deepEqual(
      parseSingleForm(actualText),
      parseSingleForm(expectedSrc),
      `${name}: query result mismatch.\n  got:  ${actualText.trim()}\n  want: ${expectedSrc.trim()}`,
    );
  });
}

// D5 (4/4) — legacy fixture graduation through the host pipeline.
// Each schema/extra is concatenated as an inline `(plugin …)`
// declaration before the input source; `validateDocument` runs the
// composed document with no resolver (everything is inline).
for (const name of LEGACY_CASES) {
  test(hostCaseName(name), async () => {
    const dir = path.join(corpus, name);
    const expectedSrc = readFileSync(path.join(dir, 'expected.sjon'), 'utf8');
    const synthetic = synthesizeLegacyDocument(dir);

    const host = await SjonHost.loadFromBytes(wasmBytes);
    const result = host.validateDocument(synthetic, {
      projectRoot: dir,
      projectFile: null,
    });
    const diags = result.diagnostics;
    const expected = readExpected(expectedSrc);

    assertDiagnosticsMatch(name, diags, expected);
  });
}

/**
 * Parse `expected.sjon` into `{code, path}` pairs. Mirrors the readers
 * in `hosts/typescript-parity/test/conformance.test.ts` and
 * `src/conformance_tests.zig`. Path entries can be symbols, decimal-
 * stringified numbers, or strings.
 *
 * Hand-rolled SJON-subset parse — same surface as the resolver's
 * project-file parser (`hosts/web/createNodeFsResolver.ts`); we only
 * need to walk `(diagnostics (diagnostic :code … :path […]) …)`.
 */
function readExpected(source: string): ExpectedDiagnostic[] {
  // Search every top-level form for the required (diagnostics …) — an
  // optional (values …) sibling may precede it. Mirrors ts-parity's
  // readExpected and Rust's common::read_expected (same error text), so a
  // values-first fixture routes identically across all three hosts rather
  // than failing only here.
  const root = parseTopLevelForms(source).find((f) => f.head === 'diagnostics');
  if (root === undefined) {
    throw new Error('expected.sjon must contain a (diagnostics …) form');
  }
  // Everything inside `(diagnostics …)` is checked, not tolerated —
  // matching the ts-parity and Rust readers. A fixture typo must fail
  // the read rather than quietly weaken the assertion it belongs to.
  const out: ExpectedDiagnostic[] = [];
  for (const child of root.children) {
    if (child.tag !== 'form') {
      throw new Error(`(diagnostics …) child is not a form: ${child.tag}`);
    }
    if (child.head !== 'diagnostic') {
      throw new Error(`unknown form (${child.head} …) inside (diagnostics …)`);
    }
    let code: string | undefined;
    let p: string[] = [];
    let severity: 'err' | 'warning' = 'err';
    for (const kv of child.children) {
      if (kv.tag !== 'kvpair') {
        throw new Error(`(diagnostic …) child is not a kvpair: ${kv.tag}`);
      }
      if (kv.key === 'code') {
        if (kv.value.tag !== 'symbol') throw new Error(':code must be a symbol');
        code = kv.value.value;
      } else if (kv.key === 'severity') {
        if (kv.value.tag !== 'symbol') throw new Error(':severity must be a symbol');
        if (kv.value.value !== 'err' && kv.value.value !== 'warning') {
          throw new Error(`unknown :severity \`${kv.value.value}\``);
        }
        severity = kv.value.value;
      } else if (kv.key === 'path') {
        if (kv.value.tag !== 'vector') throw new Error(':path must be a vector');
        p = kv.value.elements.map((e): string => {
          // Numbers in path slots arrive as `symbol` nodes from
          // our tiny parser (numbers aren't a separate tag) —
          // their textual form already matches the validator's
          // decimal-string `indexStep` output.
          if (e.tag === 'symbol') return e.value;
          if (e.tag === 'string') return e.value;
          throw new Error(`:path element is not a symbol or string: ${e.tag}`);
        });
      } else {
        throw new Error(`unknown key \`:${kv.key}\` in (diagnostic …)`);
      }
    }
    if (code === undefined) throw new Error('(diagnostic …) is missing :code');
    out.push({ code, path: p, severity });
  }
  return out;
}

/**
 * Load a case's generated `expected.values.json` sibling as an ordered
 * `[indexString, value]` list, or `[]` when the case has no sibling (most
 * cases). The sibling is derived at build time from the fixture's
 * `(values …)` block through `wasm_common.appendValue` and drift-gated by
 * `zig build gen-expected-values`, so this host reads it verbatim rather
 * than re-deriving a literal→JSON decoder. Parsing through
 * `parseJsonWithBigInt` — the same reader the envelope goes through — keeps
 * out-of-Number-range integers (u64-max) as BigInt on both sides, so the
 * per-index `deepStrictEqual` is exact.
 */
function loadExpectedValuesJson(caseDir: string): [string, unknown][] {
  const sibling = path.join(caseDir, 'expected.values.json');
  if (!existsSync(sibling)) return [];
  const parsed = parseJsonWithBigInt(readFileSync(sibling, 'utf8')) as Record<string, unknown>;
  return Object.entries(parsed);
}

// ---------------------------------------------------------------------------
// Tiny SJON-subset parser (same shape as createNodeFsResolver's). We
// only need to read `(diagnostics (diagnostic :code SYMBOL :path […]))`.
// ---------------------------------------------------------------------------

/**
 * Parse every top-level form in `source`. Used for expected.sjon files
 * that may carry an optional `(values …)` sibling alongside the required
 * `(diagnostics …)` form.
 */
function parseTopLevelForms(source: string): FormNode[] {
  const c: Cursor = { src: source, i: 0 };
  const out: FormNode[] = [];
  while (true) {
    skipTrivia(c);
    if (c.i >= c.src.length) return out;
    const node = parseNode(c, CONFORMANCE_DIALECT);
    if (node.tag !== 'form') throw new Error('expected.sjon top-level must be a form');
    out.push(node);
  }
}

function parseSingleForm(source: string): FormNode {
  const c: Cursor = { src: source, i: 0 };
  skipTrivia(c);
  if (c.i >= c.src.length) throw new Error('expected.sjon empty');
  const node = parseNode(c, CONFORMANCE_DIALECT);
  if (node.tag !== 'form') throw new Error('expected.sjon root must be a form');
  return node;
}

/** Parse `(query :window [begin end] :seed N)` into numeric ticks + seed. */
function readQuerySpec(source: string): { begin: number; end: number; seed: number } {
  const form = parseSingleForm(source);
  if (form.head !== 'query') {
    throw new Error(`query.sjon root must be (query …), got (${form.head} …)`);
  }
  let begin = 0;
  let end = 0;
  let seed = 0;
  for (const child of form.children) {
    if (child.tag !== 'kvpair') continue;
    if (
      child.key === 'window' &&
      child.value.tag === 'vector' &&
      child.value.elements.length === 2
    ) {
      begin = atomNumber(child.value.elements[0]!);
      end = atomNumber(child.value.elements[1]!);
    } else if (child.key === 'seed') {
      seed = atomNumber(child.value);
    }
  }
  return { begin, end, seed };
}

/** Read a numeric tick / seed from a parsed atom (numbers parse as symbols). */
function atomNumber(node: ParsedNode): number {
  if (node.tag !== 'symbol') throw new Error(`expected a numeric atom, got ${node.tag}`);
  const n = Number(node.value);
  if (!Number.isFinite(n)) throw new Error(`not a number: ${node.value}`);
  return n;
}

// The mini-parser (parseNode/parseForm/…) and its Cursor/FormNode/
// ParsedNode types now live in ../sjonSubsetParser.ts, shared with
// createNodeFsResolver.ts. This runner drives it with CONFORMANCE_DIALECT
// (bare `:` → keyword node; `HH:MM:SS` → one symbol).
