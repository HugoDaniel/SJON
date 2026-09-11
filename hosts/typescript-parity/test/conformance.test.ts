// Conformance corpus runner — second-host TypeScript.
//
// Reads the same `conformance/cases/*` fixtures the Zig reference
// runner uses. For each case: load schema.sjon → Plugin, parse
// input.sjon, validate, compare actual vs expected diagnostics on
// (code, path).
//
// Cross-host conformance: if this runner reports zero failures, the
// TS host's diagnostic surface matches Zig for every fixture.
//
// Multi-plugin fixtures: a case directory may also contain one or
// more `extra-*.sjon` files. Each is loaded as an additional plugin
// in lexical order after `schema.sjon`. This lets fixtures exercise
// codes that require collisions across plugins (`ambiguous_form`,
// `ambiguous_expr`, `ambiguous_element_kind`, `ambiguous_cross_ref_*`).

import { test } from 'node:test';
import * as assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { parse } from '../src/parser.ts';
import { loadManifest } from '../src/loader.ts';
import { validate } from '../src/validator.ts';
import { validateCrossRefs } from '../src/plugin.ts';
import { validateDocument } from '../src/Host.ts';
import { queryDocument } from '../src/patternQuery.ts';
import type { Diagnostic } from '../src/diagnostics.ts';
import type { Node, FormNode } from '../src/ast.ts';
import {
  assertDiagnosticsMatch,
  classifyCase,
  heldSymbolFor,
  discoverCaseDirs,
  hostCaseName,
  nativeCaseName,
  queryCaseName,
  readMarkers,
  registerClassifierAudits,
  runnerOf,
  synthesizeLegacyDocument,
} from '../../conformance-shared/index.ts';
import type { ExpectedDiagnostic, SkipFamily } from '../../conformance-shared/index.ts';

const __filename = fileURLToPath(import.meta.url);
const HERE = dirname(__filename);
const CORPUS = resolve(HERE, '..', '..', '..', 'conformance', 'cases');

// Discover cases by walking the corpus (shared `discoverCaseDirs`, identical
// to the web runner): the `conformance/cases/` directory is the single source
// of truth, shared with the Zig runner. A new fixture appears in both hosts
// automatically; there is no host-specific list to keep in sync. The walk
// drops non-dir junk (`.DS_Store`) and hidden dirs (the gitignored
// `.zig-cache` build cache) so the `classify every case dir` audit below never
// trips on a stray entry.
//
// Inline-manifest cases (`document.sjon`-only directories) dispatch
// through `validateDocument`, mirroring the Zig host's
// `runInlineManifestCase` shape. The default FilesystemResolver picks
// up an optional sibling `sjon-project.sjon`.
const ENTRIES: readonly string[] = discoverCaseDirs(CORPUS);

// The `cross-ref-provider-*` cases that reject the *schema*, before any
// document is read: no extraction, no runtime, nothing this port lacks.
// Named rather than prefixed because the split is not a naming
// convention — it is which cases need a provider to run — and a new
// aggregate case has to be added here deliberately.
//
// Deliberately *not* shared with the Zig runner's split
// (`isRuntimeFreeProviderCase`, `src/conformance_tests.zig`), which also
// admits `-unavailable`: that case needs no runtime either, but reading
// it correctly still needs the provider route, which is the half this
// port does not have. Same family, two different gaps.
const AGGREGATE_PROVIDER_CASES: ReadonlySet<string> = new Set([
  'cross-ref-provider-unknown',
  'cross-ref-provider-ambiguous',
  'cross-ref-provider-source-key-unknown',
]);

// Skip families — the corpus fixtures the TS-parity port does NOT run,
// each carrying the reason it is skipped. TS-parity is declarative-only
// by design (spec §0): it has no Expr evaluator, no lowering pass, no
// executable-plugin runtime, no default-materialization overlay, and no
// exclusive-group runtime, so the families below leave evaluator-tied and
// runtime-tied coverage to the Web + Rust hosts (which delegate to the
// shared `sjon.wasm`). Folded from the eleven `is*` predicates this file
// used to carry into one data-driven registry so the `classify every case
// dir` audit below can prove no dir falls through and no family is dead.
// This set stays HOST-LOCAL: it is genuinely larger than the wasm-host set
// single-sourced in `conformance/classifier.json` (that JSON is consumed by
// the Web + Rust hosts, whose coverage differs from this port's). Marker
// filenames + dispatch precedence still come from that JSON transitively,
// via the shared `readMarkers` / `classifyCase`.
const SKIP_FAMILIES: readonly SkipFamily[] = [
  {
    label: 'plugin-exec-*',
    match: (n) => n.startsWith('plugin-exec-'),
    reason:
      'D7-exec executable-plugin runtime (instantiate sidecar wasm, pre-flight, dispatch); declarative-only by design — Web + Rust cover them end-to-end',
  },
  {
    label: 'default-expr-* / default-materialize-* / effective-axis-*',
    match: (n) =>
      n.startsWith('default-expr-') ||
      n.startsWith('default-materialize-') ||
      n.startsWith('effective-axis-'),
    reason:
      'Schema.validateDefaults + runtime materialization overlay + effective-validation axes; no `default` KeySpec field, no (key … :default (expr …)) parser, no materializeDefaults mirror',
  },
  {
    label: 'lowering-*',
    match: (n) => n.startsWith('lowering-'),
    reason:
      'D8-lowering-runtime hook registry + test/identity-v1 test hook (Zig-host only); no lowering pass and no JS-side test hook',
  },
  {
    label: 'expr-map-* / expr-filter-* / expr-any-* / expr-all-* / expr-fold-*',
    match: (n) =>
      n.startsWith('expr-map-') ||
      n.startsWith('expr-filter-') ||
      n.startsWith('expr-any-') ||
      n.startsWith('expr-all-') ||
      n.startsWith('expr-fold-'),
    reason:
      'higher-order core binder forms that produce values via the Expr evaluator; no evaluator, and the validator does not seed the core plugin, so (map [x] xs body) at top level surfaces as unknown_form',
  },
  {
    label: 'expr-label-*',
    match: (n) => n.startsWith('expr-label-'),
    reason:
      'labeled-call structure on core expression functions (lerp); the validator does not seed the core plugin, so (lerp :from 0 …) at top level surfaces as unknown_form before any label rule runs — the same limitation the expr-map-* family states',
  },
  {
    label: 'expr-number-*',
    match: (n) => n.startsWith('expr-number-'),
    reason:
      'integer-preserving eval pipeline (Value.integer_i64/_u64 through let-binding); no Expr evaluator to bind the (values …) block',
  },
  {
    label: 'expr-date-*',
    match: (n) => n.startsWith('expr-date-'),
    reason: 'Value.date round-trip through let / =; no Expr evaluator',
  },
  {
    label: 'expr-time-*',
    match: (n) => n.startsWith('expr-time-'),
    reason: 'Value.time round-trip through let / =; no Expr evaluator',
  },
  {
    label: 'expr-trig-*',
    match: (n) => n.startsWith('expr-trig-'),
    reason:
      'host-independent sin/cos/tan from the vendored src/trig.zig; binds via (values …), which needs the Expr evaluator',
  },
  {
    label: 'expr-pow-*',
    match: (n) => n.startsWith('expr-pow-'),
    reason:
      'host-independent pow from the vendored src/trig.zig pow64; binds via (values …), which needs the Expr evaluator',
  },
  {
    label: 'expr-value-*',
    match: (n) => n.startsWith('expr-value-'),
    reason:
      'the long-tail value axis — WGSL smoothing/vector semantics, inverse trig, seeded random, list and control forms. Every case in the family exists to pin a computed (values …) block bit-for-bit, which is precisely what needs the Expr evaluator this port does not have; the core plugin is not seeded either, so the forms would surface as unknown_form first',
  },
  {
    label: 'pattern-expr-*',
    match: (n) => n.startsWith('pattern-expr-'),
    reason:
      'pattern (pure …) leaves that are Expr expressions of time; per-hap evaluation needs the Expr evaluator the patternQuery port lacks (literal-atom leaves still run natively)',
  },
  {
    label: 'cross-ref-provider-* (executable tier)',
    match: (n) => n.startsWith('cross-ref-provider-') && !AGGREGATE_PROVIDER_CASES.has(n),
    reason:
      'provider-backed cross-refs need an extraction pre-pass over a wasm runtime; this port has no runtime and its index build takes the identity route, so the member set would come from :name-key rather than from the provider. The declarative half — loader, provider catalog, aggregate checks, schema export — is implemented, and the aggregate-tier cases run here',
  },
];

// Schema (`CASES` — run natively AND through host graduation), inline
// (`document.sjon`), and PatternQuery (`query.sjon`) run sets, all derived
// from the shared `runnerOf` source of truth so the audits and the runners
// can never disagree. Among the skip families only `pattern-expr-*` matches
// a query dir, so `runnerOf === 'query'` reproduces the old
// `query && !isPatternExpr`.
const runnerFor = (name: string): 'legacy' | 'inline' | 'query' | null =>
  runnerOf(name, readMarkers(CORPUS, name), SKIP_FAMILIES);
const CASES: readonly string[] = ENTRIES.filter((name) => runnerFor(name) === 'legacy');
const INLINE_CASES: readonly string[] = ENTRIES.filter((name) => runnerFor(name) === 'inline');
const QUERY_CASES: readonly string[] = ENTRIES.filter((name) => runnerFor(name) === 'query');

// Shared corpus-coverage audits (non-empty, every-dir-classified,
// no-dead-family, classifier anchor) + the host-specific skip anchor below.
registerClassifierAudits({ entries: ENTRIES, corpusDir: CORPUS, skipFamilies: SKIP_FAMILIES });

// The expected.sjon vocabulary is closed. Every source below is a
// fixture typo this reader used to absorb — an unknown `:severity` kept
// the `err` default, an unrecognized path element compared as `''`, an
// unknown key was skipped — so the assertion got quietly weaker instead
// of failing. Mirrors src/ConformanceExpected.zig and the other two
// hosts. Corpus-free anchor (readExpected is a pure parse).
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
    assert.throws(() => readExpected(parse(src)), `reader accepted \`${src}\``);
  }
  const accepted = readExpected(
    parse(
      '(diagnostics (diagnostic :code unknown_form :path [a 0 "b"])' +
        ' (diagnostic :code deprecated_member :severity warning))',
    ),
  );
  assert.equal(accepted.length, 2);
  assert.deepEqual([...accepted[0]!.path], ['a', '0', 'b']);
  assert.equal(accepted[1]!.severity, 'warning');
});

test('classifier: pattern-expr-* is a reasoned skip despite query markers', () => {
  const c = classifyCase(
    'pattern-expr-sin',
    { hasSchema: false, hasDocument: true, hasQuery: true },
    SKIP_FAMILIES,
  );
  assert.equal(c.kind, 'skip');
});

for (const name of INLINE_CASES) {
  test(hostCaseName(name), () => {
    const caseDir = resolve(CORPUS, name);
    const documentSrc = readFileSync(resolve(caseDir, 'document.sjon'), 'utf8');
    const expectedSrc = readFileSync(resolve(caseDir, 'expected.sjon'), 'utf8');
    const projectFile = existsSync(resolve(caseDir, 'sjon-project.sjon'))
      ? resolve(caseDir, 'sjon-project.sjon')
      : null;

    // `held-*` cases are documents being typed: the run sets `heldSymbol`,
    // so a position spelled `_` is one the author has deliberately not
    // filled in yet. Read from `classifier.json` through the shared module,
    // so this host, the web host, `hosts/rust/build.rs` and the Zig
    // reference runner cannot disagree about which cases opt in.
    const heldSymbol = heldSymbolFor(name);
    const result = validateDocument(documentSrc, {
      projectRoot: caseDir,
      resolver: null,
      projectFile,
      ...(heldSymbol === null ? {} : { heldSymbol }),
    });

    const diags = result.diagnostics;
    const expected = readExpected(parse(expectedSrc));

    assertDiagnosticsMatch(name, diags, expected);
  });
}

// PatternQuery — run each pattern over its window via the native
// `queryDocument` port and compare the returned `(haps …)` / `(diagnostics
// …)` form against expected.sjon. Both are parsed and canonicalized
// (span-free, bigint→string), so a structural string equality is the
// cross-host bit-exactness check.
for (const name of QUERY_CASES) {
  test(queryCaseName(name), () => {
    const caseDir = resolve(CORPUS, name);
    const documentSrc = readFileSync(resolve(caseDir, 'document.sjon'), 'utf8');
    const querySrc = readFileSync(resolve(caseDir, 'query.sjon'), 'utf8');
    const expectedSrc = readFileSync(resolve(caseDir, 'expected.sjon'), 'utf8');

    const { begin, end, seed } = readQuerySpec(querySrc);
    const actualText = queryDocument(documentSrc, begin, end, seed);

    const actual = parse(actualText);
    const expected = parse(expectedSrc);
    assert.equal(actual.length, 1, `${name}: query output must be one form, got ${actual.length}`);
    assert.equal(expected.length, 1, `${name}: expected.sjon must be one form`);
    assert.equal(
      canonicalize(actual[0]!),
      canonicalize(expected[0]!),
      `${name}: query result mismatch\n  got:  ${actualText.trim()}\n  want: ${expectedSrc.trim()}`,
    );
  });
}

/** Parse `(query :window [begin end] :seed N)` into numeric ticks + seed. */
function readQuerySpec(src: string): { begin: number; end: number; seed: number } {
  const roots = parse(src);
  const form = roots[0];
  if (roots.length !== 1 || form === undefined || form.tag !== 'form' || form.head !== 'query') {
    throw new Error('query.sjon root must be a single (query …) form');
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

function atomNumber(node: Node): number {
  if (node.tag !== 'number') throw new Error(`expected a numeric atom, got ${node.tag}`);
  return node.value;
}

/** Canonical, span-free serialization of a parsed node for structural
 *  comparison. Drops `span` / `headSpan` / `keySpan` (positions differ
 *  between single-line output and hand-formatted expected.sjon) and renders
 *  bigint `integerBits` as a string (JSON can't serialize bigint). */
function canonicalize(node: Node): string {
  return JSON.stringify(node, (key, value: unknown) => {
    if (key === 'span' || key === 'headSpan' || key === 'keySpan') return undefined;
    if (typeof value === 'bigint') return value.toString();
    return value;
  });
}

function readExpected(roots: readonly Node[]): ExpectedDiagnostic[] {
  // expected.sjon carries one required `(diagnostics …)` form and may carry
  // sibling forms — an `(values …)` block that locks return values for host
  // pipelines with evaluator support (Zig, Web, Rust). TS-parity has no Expr
  // evaluator, so any such sibling is simply skipped: search every top-level
  // root for the required `(diagnostics …)` form, uncapped, matching the web
  // (`parseTopLevelForms`) and Rust (`common::read_expected`) readers so a
  // multi-sibling fixture routes identically across all three hosts.
  let root: FormNode | undefined;
  for (const candidate of roots) {
    if (candidate.tag === 'form' && (candidate as FormNode).head === 'diagnostics') {
      root = candidate as FormNode;
      break;
    }
  }
  if (!root) {
    throw new Error('expected.sjon must contain a (diagnostics …) form');
  }
  // Everything inside `(diagnostics …)` is checked, not tolerated. The
  // fixture vocabulary is three keys and two severities; anything else
  // is a mistake in the fixture, and silently ignoring it weakens the
  // assertion instead of failing it — `:severity warnign` used to assert
  // `err`, and an unexpected path element used to compare as `''`.
  const out: ExpectedDiagnostic[] = [];
  for (const child of root.children) {
    if (child.tag !== 'form') {
      throw new Error(`(diagnostics …) child is not a form: ${child.tag}`);
    }
    if (child.head !== 'diagnostic') {
      throw new Error(`unknown form (${child.head} …) inside (diagnostics …)`);
    }
    let code: string | undefined;
    let path: string[] = [];
    let severity: 'err' | 'warning' = 'err';
    for (const kc of child.children) {
      if (kc.tag !== 'kvpair') {
        throw new Error(`(diagnostic …) child is not a kvpair: ${kc.tag}`);
      }
      if (kc.key === 'code') {
        if (kc.value.tag !== 'symbol') throw new Error(':code must be a symbol');
        code = kc.value.text;
      } else if (kc.key === 'severity') {
        if (kc.value.tag !== 'symbol') throw new Error(':severity must be a symbol');
        if (kc.value.text !== 'err' && kc.value.text !== 'warning') {
          throw new Error(`unknown :severity \`${kc.value.text}\``);
        }
        severity = kc.value.text;
      } else if (kc.key === 'path') {
        if (kc.value.tag !== 'vector') throw new Error(':path must be a vector');
        // Path entries are heterogeneous: declared keys are symbols,
        // vector / positional indices arrive as numbers, and any
        // string-typed steps stay as strings. Mirror the Zig runner's
        // shape (`indexStep` allocates a decimal string) so number
        // segments compare correctly.
        path = kc.value.elements.map((e) => {
          if (e.tag === 'symbol') return e.text;
          if (e.tag === 'number') return String(e.value);
          if (e.tag === 'string') return e.value;
          throw new Error(`:path element is not a symbol, number or string: ${e.tag}`);
        });
      } else {
        throw new Error(`unknown key \`:${kc.key}\` in (diagnostic …)`);
      }
    }
    if (code === undefined) throw new Error('(diagnostic …) is missing :code');
    out.push({ code, path, severity });
  }
  return out;
}

/**
 * Fixtures where the host pipeline emits a different diagnostic set
 * than the legacy pre-compose path. Mirrors `HOST_PASS_SKIP` in
 * `src/conformance_tests.zig` — the divergence is host design, not a
 * parser/validator drift, and skipping these in the host-pass keeps
 * the dual-pass invariant honest for everything else.
 *
 * `too-many-keys` — `validateDocument` drops errored plugins from the
 *   schema, so `(big …)` becomes `unknown_form` on top of the
 *   manifest-phase `too_many_keys`. The legacy path keeps the
 *   truncated plugin in the schema.
 */
const HOST_PASS_SKIP: ReadonlySet<string> = new Set(['too-many-keys']);

// D5 (4/4) — graduate the legacy schema+input fixtures through the
// host pipeline by synthesising a single document containing each
// plugin manifest as an inline `(plugin …)` declaration followed by
// the input source. Mirrors `runLegacyCaseAsHost` in
// `src/conformance_tests.zig` and `hosts/web/test/conformance.test.ts`.
for (const name of CASES) {
  if (HOST_PASS_SKIP.has(name)) continue;
  test(hostCaseName(name), () => {
    const dir = resolve(CORPUS, name);
    const expectedSrc = readFileSync(resolve(dir, 'expected.sjon'), 'utf8');
    const synthetic = synthesizeLegacyDocument(dir);
    const result = validateDocument(synthetic, {
      projectRoot: null,
      resolver: null,
      projectFile: null,
    });
    const diags = result.diagnostics;
    const expected = readExpected(parse(expectedSrc));

    assertDiagnosticsMatch(name, diags, expected);
  });
}

for (const name of CASES) {
  test(nativeCaseName(name), () => {
    const schemaSrc = readFileSync(resolve(CORPUS, name, 'schema.sjon'), 'utf8');
    const inputSrc = readFileSync(resolve(CORPUS, name, 'input.sjon'), 'utf8');
    const expectedSrc = readFileSync(resolve(CORPUS, name, 'expected.sjon'), 'utf8');

    // Phase 1 — manifest parse + load. Shape errors stay a fixture-author
    // failure (separate from the diagnostic stream); diagnostic-coded
    // emissions like `too_many_keys` join the phase concatenation.
    const schemaTree = parse(schemaSrc);
    const loaded = loadManifest(schemaTree);
    assert.deepEqual(loaded.errors, [], `schema errors for ${name}`);

    const diags: Diagnostic[] = [];
    for (const d of loaded.diagnostics) diags.push(d);

    // Optional sibling plugins (extra-*.sjon). Each becomes an additional
    // plugin in lexical order — see the module doc comment.
    const extras = readdirSync(resolve(CORPUS, name))
      .filter((f) => f.startsWith('extra-') && f.endsWith('.sjon'))
      .sort();
    const extraLoads = extras.map((file) => {
      const src = readFileSync(resolve(CORPUS, name, file), 'utf8');
      const tree = parse(src);
      const result = loadManifest(tree);
      assert.deepEqual(result.errors, [], `${name}/${file} errors`);
      for (const d of result.diagnostics) diags.push(d);
      return result;
    });

    const schema = { plugins: [loaded.plugin, ...extraLoads.map((r) => r.plugin)] };

    // Phase 2 — schema-aggregate cross-ref resolution. Skip on load
    // failure (any plugin): a partial plugin is missing the very pieces
    // aggregate validation walks.
    const anyLoadErr =
      loaded.diagnostics.some((d) => d.severity === 'err') ||
      extraLoads.some((r) => r.diagnostics.some((d) => d.severity === 'err'));
    if (!anyLoadErr) {
      for (const d of validateCrossRefs(schema)) diags.push(d);
    }

    // Phase 3 — input validate.
    const inputTree = parse(inputSrc);
    for (const d of validate(schema, inputTree)) diags.push(d);

    const expectedTree = parse(expectedSrc);
    const expected = readExpected(expectedTree);

    assertDiagnosticsMatch(name, diags, expected);
  });
}
