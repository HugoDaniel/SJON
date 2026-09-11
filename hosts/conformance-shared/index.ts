// Shared conformance-runner scaffolding for the two TypeScript hosts
// (`hosts/web` + `hosts/typescript-parity`). Both walk the same
// `conformance/cases/*` corpus and need the identical case-classification
// logic, the identical coverage/dead-family audits, and the identical
// `(code, path, severity)` diagnostic comparison. This module owns all
// three so the hosts can never drift apart on them; each host still keeps
// its own `readExpected` / `readQuerySpec` (different parser substrates — the
// same reason those two stay host-local: web parses through its SJON-subset
// parser where numbers are `symbol` nodes, ts-parity through its native parser
// where they are `number` nodes, so a shared reader would need a lossy adapter).
//
// The classification DATA — marker filenames, dispatch precedence, and the
// wasm-host skip families — is single-sourced in `conformance/classifier.json`
// and read here at runtime, so this module, `hosts/rust/build.rs`, and (by
// mirror) the Zig reference runner can never disagree on it. The web host's
// skip set IS the wasm-host set (`loadWasmHostSkipFamilies`); the
// typescript-parity host is a validator-only port whose skip set genuinely
// differs, so it stays host-local — it still gets markers + precedence from
// the JSON transitively through the functions below.
//
// Not a workspace package — imported by relative path from both hosts'
// test dirs. It is covered by biome's include allowlist
// (`hosts/conformance-shared/**`) and typechecked transitively by each
// host's `tsc --noEmit` (via import-following), so both gates still reach
// it. Mirrors the same classification + audit shape as the Rust host's
// `build.rs` (which reads the same `classifier.json` at build time).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// --- classifier data (single source: conformance/classifier.json) --------

interface ClassifierMatch {
  readonly type: 'prefix' | 'exact';
  readonly value: string;
}

interface ClassifierSkipFamily {
  readonly label: string;
  readonly match: ClassifierMatch;
  readonly reason: string;
}

/**
 * A case family that runs with a non-default validator option. `option` is
 * the `sjon_host_validate_document` options-JSON key; `value` is what it is
 * set to for every case whose directory name matches.
 */
interface ClassifierOptionFamily {
  readonly label: string;
  readonly match: ClassifierMatch;
  readonly option: string;
  readonly value: string;
  readonly reason: string;
}

interface ClassifierData {
  readonly markers: { readonly legacy: string; readonly query: string; readonly inline: string };
  readonly precedence: readonly Runner[];
  readonly validatorOptionFamilies: readonly ClassifierOptionFamily[];
  readonly wasmHostSkipFamilies: readonly ClassifierSkipFamily[];
}

// `hosts/conformance-shared/` → `../../conformance/classifier.json`. Read
// once at module load (Node runtime — no bundler, no tsconfig JSON-import
// flag needed). The cast trusts the in-repo data file; a shape drift would
// surface as a downstream type error or a failing classifier audit.
const CLASSIFIER = JSON.parse(
  readFileSync(
    path.resolve(
      path.dirname(fileURLToPath(import.meta.url)),
      '..',
      '..',
      'conformance',
      'classifier.json',
    ),
    'utf8',
  ),
) as ClassifierData;

// Glue between the runner labels and the typed `CaseMarkers` fields — which
// boolean `readMarkers` populated for each runner. Not classification policy
// (that is the JSON's precedence + markers); just the interface binding.
const RUNNER_FIELD: Record<Runner, keyof CaseMarkers> = {
  legacy: 'hasSchema',
  query: 'hasQuery',
  inline: 'hasDocument',
};

function matcherFor(m: ClassifierMatch): (name: string) => boolean {
  if (m.type === 'prefix') {
    const prefix = m.value;
    return (name) => name.startsWith(prefix);
  }
  if (m.type === 'exact') {
    const exact = m.value;
    return (name) => name === exact;
  }
  throw new Error(`classifier.json: unknown match type ${JSON.stringify(m.type)}`);
}

/**
 * The wasm-host skip families (`lowering-*`, `too-many-keys`) materialized
 * from `classifier.json`. The web host — like the Rust host — drives the
 * kitchen-sink `sjon.wasm`, so this IS its full skip set. The
 * typescript-parity host does NOT use this (its port-specific set is larger
 * and host-local).
 */
export function loadWasmHostSkipFamilies(): SkipFamily[] {
  return CLASSIFIER.wasmHostSkipFamilies.map((fam) => ({
    label: fam.label,
    match: matcherFor(fam.match),
    reason: fam.reason,
  }));
}

/**
 * The `heldSymbol` a case runs with, or `null` for the overwhelming
 * majority that run with the option off.
 *
 * A family prefix rather than a per-case options sibling: every one of the
 * corpus's siblings is a document or an expectation, never a knob, and
 * inferring the option from the document instead would be the
 * document-weakens-its-own-schema hazard the option exists to avoid,
 * arriving through the test suite. One named option, one named prefix.
 *
 * Reads `validatorOptionFamilies` from `classifier.json`, so this function,
 * `hosts/rust/build.rs`, and (by mirror) `src/conformance_tests.zig`'s
 * `heldSymbolFor` cannot disagree about which cases opt in.
 */
export function heldSymbolFor(caseName: string): string | null {
  for (const fam of CLASSIFIER.validatorOptionFamilies) {
    if (fam.option !== 'heldSymbol') continue;
    if (matcherFor(fam.match)(caseName)) return fam.value;
  }
  return null;
}

// --- corpus discovery + legacy synthesis ---------------------------------

/**
 * The corpus case directories, sorted — the single source of truth both TS
 * hosts (and the Zig runner) walk. `withFileTypes` + the dot-filter keep
 * non-dir junk (`.DS_Store`) and hidden dirs (the gitignored `.zig-cache`
 * build cache) out, so a new fixture lands in the right runner automatically
 * and the `every case dir is classified` audit never trips on a stray entry.
 */
export function discoverCaseDirs(corpusDir: string): string[] {
  return readdirSync(corpusDir, { withFileTypes: true })
    .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
    .map((e) => e.name)
    .sort();
}

/**
 * Synthesize a legacy (schema + input) case into a single document by
 * concatenating `schema.sjon`, each `extra-*.sjon` in lexical order, and
 * `input.sjon` with `\n` separators — one `(plugin …)` manifest per source
 * ahead of the input. This recipe MUST stay byte-identical to the Rust host's
 * `run_legacy_case_as_host` (`hosts/rust/tests/conformance.rs`), which builds
 * the same string; the Zig host reaches the same diagnostics via
 * `Host.preloadSchema` over separate sources. Owning it here keeps the two TS
 * hosts from drifting apart on the ordering or the separator.
 */
export function synthesizeLegacyDocument(dir: string): string {
  const schemaSrc = readFileSync(path.join(dir, 'schema.sjon'), 'utf8');
  const inputSrc = readFileSync(path.join(dir, 'input.sjon'), 'utf8');
  const extras = readdirSync(dir)
    .filter((f) => f.startsWith('extra-') && f.endsWith('.sjon'))
    .sort()
    .map((f) => readFileSync(path.join(dir, f), 'utf8'));
  return [schemaSrc, ...extras, inputSrc].join('\n');
}

// Test-title builders — shared so a `--test-name-pattern` filter selects the
// same logical phase across both TS hosts. Inline and legacy-graduation cases
// both run through the host `validateDocument` entry, so they share the
// `conformance host:` prefix (web already used it for inline; ts-parity used a
// bare `conformance:` there — this aligns them). The PatternQuery pass and the
// ts-parity-only native validate-pipeline pass keep their own prefixes.
export const hostCaseName = (name: string): string => `conformance host: ${name}`;
export const queryCaseName = (name: string): string => `conformance query: ${name}`;
export const nativeCaseName = (name: string): string => `conformance: ${name}`;

// --- case classification -------------------------------------------------

/** Marker files present in a case dir, read once per dir. */
export interface CaseMarkers {
  readonly hasSchema: boolean;
  readonly hasDocument: boolean;
  readonly hasQuery: boolean;
}

/**
 * A corpus family a host does NOT run, carrying the reason it is skipped.
 * Data-driven so the `every case dir is classified` audit can prove two
 * things at once: no dir falls through unaccounted for, and no family is
 * dead (each must match ≥ 1 dir). The set differs per host — their
 * runtime coverage does — so it stays host-local data.
 */
export interface SkipFamily {
  readonly label: string;
  readonly match: (name: string) => boolean;
  readonly reason: string;
}

export type Runner = 'legacy' | 'inline' | 'query';

export type Classification =
  | { readonly kind: 'run'; readonly runner: Runner }
  | { readonly kind: 'skip'; readonly reason: string }
  | { readonly kind: 'unclassified' }
  | { readonly kind: 'ambiguous'; readonly markers: CaseMarkers };

/** Read the three runner-marker files for a case dir (filenames from the JSON). */
export function readMarkers(corpusDir: string, name: string): CaseMarkers {
  return {
    hasSchema: existsSync(path.join(corpusDir, name, CLASSIFIER.markers.legacy)),
    hasDocument: existsSync(path.join(corpusDir, name, CLASSIFIER.markers.inline)),
    hasQuery: existsSync(path.join(corpusDir, name, CLASSIFIER.markers.query)),
  };
}

/** The reason `name` is skipped, or null when it runs. */
export function skipReason(name: string, families: readonly SkipFamily[]): string | null {
  for (const fam of families) if (fam.match(name)) return fam.reason;
  return null;
}

/**
 * Classify a case dir into the runner that executes it, a reasoned skip,
 * or `unclassified` (a dir with no runner marker and no skip family — a
 * misfiled case or a new fixture nobody wired up). Skip is checked first
 * so a `lowering-*` / `pattern-expr-*` dir with a `document.sjon` marker
 * resolves to its skip, not the inline/query runner. Legacy (schema)
 * precedes query precedes inline, matching the runner dispatch — a query
 * case carries both `document.sjon` and `query.sjon`, and must land in the
 * query runner.
 */
export function classifyCase(
  name: string,
  markers: CaseMarkers,
  families: readonly SkipFamily[],
): Classification {
  const reason = skipReason(name, families);
  if (reason !== null) return { kind: 'skip', reason };
  // A legacy (schema) case and a document/query case cannot share a dir —
  // the runners would disagree (the TS hosts picked legacy by precedence,
  // Rust's build.rs picked query). Flag the conflict rather than silently
  // routing to a per-host-different runner. document+query alone is a valid
  // query case, so only schema-alongside-document/query is ambiguous.
  if (markers.hasSchema && (markers.hasDocument || markers.hasQuery)) {
    return { kind: 'ambiguous', markers };
  }
  // Dispatch precedence is JSON-sourced: return the first runner in
  // `precedence` whose marker is present. With the ambiguity guard above,
  // schema (legacy) is mutually exclusive with document/query, so the order
  // that actually resolves is query-before-inline (a doc+query dir is a
  // query case). Mirrors the Rust build.rs dispatch + the Zig runner.
  for (const runner of CLASSIFIER.precedence) {
    if (markers[RUNNER_FIELD[runner]]) return { kind: 'run', runner };
  }
  return { kind: 'unclassified' };
}

/** The runner that executes `name`, or null when it is skipped/unclassified. */
export function runnerOf(
  name: string,
  markers: CaseMarkers,
  families: readonly SkipFamily[],
): Runner | null {
  const c = classifyCase(name, markers, families);
  return c.kind === 'run' ? c.runner : null;
}

/**
 * Register the corpus-coverage audits shared by both hosts: the corpus is
 * non-empty, every case dir resolves to a runner or a reasoned skip (a new
 * fixture nobody wired up lands as `unclassified` and fails here rather
 * than vanishing from coverage), no skip family is dead, and the
 * corpus-free classifier anchor. Each host also keeps its own host-specific
 * skip anchor (`lowering-*` / `pattern-expr-*`).
 */
export function registerClassifierAudits(opts: {
  readonly entries: readonly string[];
  readonly corpusDir: string;
  readonly skipFamilies: readonly SkipFamily[];
}): void {
  const { entries, corpusDir, skipFamilies } = opts;

  test('conformance: corpus is non-empty', () => {
    const runnable = entries.filter(
      (name) => classifyCase(name, readMarkers(corpusDir, name), skipFamilies).kind === 'run',
    );
    assert.ok(runnable.length > 0, `no runnable cases found in ${corpusDir}`);
  });

  test('conformance: every corpus leg is non-empty', () => {
    // A whole-corpus count cannot see one leg vanishing. Losing every
    // `query.sjon` marker would drop the entire PatternQuery leg from
    // these hosts and still leave the count healthy — the same hole
    // `hosts/rust/build.rs` had (it checked inline and legacy, not query).
    const counts = { legacy: 0, inline: 0, query: 0 };
    for (const name of entries) {
      const c = classifyCase(name, readMarkers(corpusDir, name), skipFamilies);
      if (c.kind !== 'run') continue;
      counts[c.runner] += 1;
    }
    for (const [leg, n] of Object.entries(counts)) {
      assert.ok(n > 0, `corpus leg "${leg}" has no cases in ${corpusDir} — markers lost?`);
    }
  });

  test('conformance: every case dir is classified (run or reasoned-skip)', () => {
    const unclassified = entries.filter(
      (name) =>
        classifyCase(name, readMarkers(corpusDir, name), skipFamilies).kind === 'unclassified',
    );
    assert.deepEqual(
      unclassified,
      [],
      `unclassified case dirs — add a runner marker or a SKIP_FAMILIES entry: ${unclassified.join(', ')}`,
    );
  });

  test('conformance: no skip family is dead', () => {
    for (const fam of skipFamilies) {
      const matched = entries.filter((n) => fam.match(n));
      assert.ok(
        matched.length > 0,
        `skip family "${fam.label}" matches no case dir — stale, remove it or fix the matcher`,
      );
    }
  });

  test('classifier: unknown family runs, no-marker dir is unclassified', () => {
    assert.equal(skipReason('mystery-new-family', skipFamilies), null);
    assert.deepEqual(
      classifyCase(
        'mystery-new-family',
        { hasSchema: false, hasDocument: false, hasQuery: false },
        skipFamilies,
      ),
      { kind: 'unclassified' },
    );
  });

  test('conformance: no case dir has ambiguous markers', () => {
    const ambiguous = entries.filter(
      (name) => classifyCase(name, readMarkers(corpusDir, name), skipFamilies).kind === 'ambiguous',
    );
    assert.deepEqual(
      ambiguous,
      [],
      `case dirs with conflicting runner markers (schema + document/query) — a legacy case and a document/query case can't share a dir: ${ambiguous.join(', ')}`,
    );
  });

  test('classifier: a schema + document/query dir is ambiguous, not silently routed', () => {
    // A legacy (schema) marker is mutually exclusive with the document
    // family. The TS runners used to pick legacy by precedence while Rust's
    // build.rs picked query — a per-host split the hard error closes.
    // document+query alone stays a valid query case.
    assert.equal(
      classifyCase('sq', { hasSchema: true, hasDocument: false, hasQuery: true }, skipFamilies)
        .kind,
      'ambiguous',
    );
    assert.equal(
      classifyCase('sd', { hasSchema: true, hasDocument: true, hasQuery: false }, skipFamilies)
        .kind,
      'ambiguous',
    );
    assert.equal(
      classifyCase('dq', { hasSchema: false, hasDocument: true, hasQuery: true }, skipFamilies)
        .kind,
      'run',
    );
  });
}

// --- diagnostic comparison ----------------------------------------------

export interface ExpectedDiagnostic {
  readonly code: string;
  readonly path: readonly string[];
  readonly severity: 'err' | 'warning';
}

/** The minimal shape of a host diagnostic the comparison + formatter read. */
export interface ActualDiagnostic {
  readonly code: string;
  readonly severity: string;
  readonly path: readonly string[];
  readonly message: string;
}

export function formatDiags(diags: readonly ActualDiagnostic[]): string {
  return `[${diags.map((d) => `${d.code}@[${d.path.join(' ')}]: ${d.message}`).join('; ')}]`;
}

/**
 * Compare a host's diagnostic stream against expected on `(code, severity,
 * path)` — the cross-host parity contract. The count check and each field
 * check carry the same messages every runner used inline, so a failure
 * reads identically across hosts.
 */
export function assertDiagnosticsMatch(
  name: string,
  actual: readonly ActualDiagnostic[],
  expected: readonly ExpectedDiagnostic[],
): void {
  assert.equal(
    actual.length,
    expected.length,
    `${name}: diagnostic count mismatch. Got: ${formatDiags(actual)}`,
  );
  for (let i = 0; i < expected.length; i++) {
    const e = expected[i]!;
    const a = actual[i]!;
    assert.equal(
      a.code,
      e.code,
      `${name} #${i}: code mismatch (got ${a.code}, want ${e.code}); message=${a.message}`,
    );
    assert.equal(
      a.severity,
      e.severity,
      `${name} #${i}: severity mismatch (got ${a.severity}, want ${e.severity})`,
    );
    assert.deepEqual(
      [...a.path],
      [...e.path],
      `${name} #${i}: path mismatch (got [${a.path.join(' ')}], want [${e.path.join(' ')}])`,
    );
  }
}
