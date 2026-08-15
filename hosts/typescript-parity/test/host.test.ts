// Tests for `validateDocument` — exercise each pass (manifest /
// aggregate / validation), each Resolution variant via mock resolvers,
// and the partition routing. The conformance harness covers the
// fixture matrix; these tests pin the host's contract.

import { test } from 'node:test';
import * as assert from 'node:assert/strict';

import { validateDocument, evalExpr, EvalExprError, type HostDiagnostic } from '../src/Host.ts';
import type { Reference, Resolution, ResolverFn } from '../src/Resolver.ts';

function errs(diags: readonly HostDiagnostic[]): readonly HostDiagnostic[] {
  return diags.filter((d) => d.severity === 'err');
}

function codes(diags: readonly HostDiagnostic[]): readonly string[] {
  return diags.map((d) => d.code);
}

test('validateDocument: empty source produces no diagnostics', () => {
  const r = validateDocument('', { projectRoot: null, resolver: null, projectFile: null });
  assert.equal(r.diagnostics.length, 0);
  assert.equal(r.loadedPlugins.length, 0);
  assert.equal(r.declarations.length, 0);
  assert.equal(r.references.length, 0);
  assert.equal(r.dataForest.length, 0);
});

test('validateDocument: bare data with no schema → unknown_form', () => {
  const r = validateDocument('(widget :name w0)\n', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), ['unknown_form']);
  assert.equal(errs(r.diagnostics)[0]!.phase, 'validation');
});

test('validateDocument: inline manifest then data validates cleanly', () => {
  const src = `
(plugin :name probe :version "1.0.0"
  (form :name widget
    (key :name name :type symbol :optional false)))

(widget :name w0)
`;
  const r = validateDocument(src, { projectRoot: null, resolver: null, projectFile: null });
  assert.deepEqual(codes(errs(r.diagnostics)), []);
  assert.equal(r.loadedPlugins.length, 1);
  assert.equal(r.loadedPlugins[0]!.name, 'probe');
});

test('validateDocument: inline manifest data error → validation phase emits missing_required_key', () => {
  const src = `
(plugin :name probe :version "1.0.0"
  (form :name widget
    (key :name name :type symbol :optional false)))

(widget)
`;
  const r = validateDocument(src, { projectRoot: null, resolver: null, projectFile: null });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['missing_required_key']);
  assert.equal(e[0]!.phase, 'validation');
});

test('validateDocument: use-plugin with no resolver → unresolved_plugin', () => {
  const r = validateDocument('(use-plugin "missing")\n', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['unresolved_plugin']);
  assert.equal(e[0]!.phase, 'manifest');
  assert.notEqual(e[0]!.declarationSpan, null);
});

test('validateDocument: mock resolver returning a manifest loads + validates', () => {
  const resolver: ResolverFn = (ref) => {
    assert.equal(ref.name, 'shapes');
    return {
      kind: 'manifest',
      source:
        '(plugin :name shapes :version "1.0.0" (form :name circle (key :name r :type number :optional false)))',
      wasm: null,
    };
  };
  const r = validateDocument('(use-plugin "shapes")\n(circle :r 4)\n', {
    projectRoot: null,
    resolver,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), []);
  assert.equal(r.loadedPlugins.length, 1);
});

// The resolver contract is shape-identical to the Zig reference, web and
// Rust: a success is a manifest that MAY carry a paired WASM sidecar.
// This host cannot execute one, so it refuses the pair — but it must
// refuse the reference-shaped thing, not a bare-wasm shape of its own
// invention. The corpus cannot pin this (plugin-exec families are
// skipped here), which is exactly how the old three-arm union drifted.
test('validateDocument: a manifest with paired wasm is refused, not half-loaded', () => {
  const manifest =
    '(plugin :name shapes :version "1.0.0" (form :name circle (key :name r :type number :optional false)))';
  const resolver: ResolverFn = () => ({
    kind: 'manifest',
    source: manifest,
    wasm: new Uint8Array([0x00, 0x61, 0x73, 0x6d]),
  });
  const r = validateDocument('(use-plugin "shapes")\n', {
    projectRoot: null,
    resolver,
    projectFile: null,
  });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['unresolved_plugin']);
  assert.match(e[0]!.message, /declarative-only/);
  // Refused, not partially applied: the declarative half must not reach
  // the schema, or the document would validate against a plugin whose
  // `:impl "wasm:…"` functions cannot run.
  assert.equal(r.loadedPlugins.length, 0);
});

test('validateDocument: the same manifest without wasm loads', () => {
  const manifest =
    '(plugin :name shapes :version "1.0.0" (form :name circle (key :name r :type number :optional false)))';
  const resolver: ResolverFn = () => ({ kind: 'manifest', source: manifest, wasm: null });
  const r = validateDocument('(use-plugin "shapes")\n(circle :r 4)\n', {
    projectRoot: null,
    resolver,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), []);
  assert.equal(r.loadedPlugins.length, 1);
});

test('validateDocument: mock resolver returning failure surfaces code+detail', () => {
  const resolver: ResolverFn = (ref: Reference): Resolution => ({
    kind: 'failure',
    code: 'unresolved_plugin',
    detail: `no plugin named ${ref.name} in mock`,
  });
  const r = validateDocument('(use-plugin "shapes")\n', {
    projectRoot: null,
    resolver,
    projectFile: null,
  });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['unresolved_plugin']);
  assert.match(e[0]!.message, /no plugin named shapes in mock/);
});

test('validateDocument: parse-fail reference (missing name) skips resolver call', () => {
  let resolverCalls = 0;
  const resolver: ResolverFn = () => {
    resolverCalls++;
    return { kind: 'failure', code: 'unresolved_plugin', detail: 'unreachable' };
  };
  const r = validateDocument('(use-plugin)\n', {
    projectRoot: null,
    resolver,
    projectFile: null,
  });
  assert.equal(resolverCalls, 0, 'parse-fail reference must not invoke the resolver');
  assert.deepEqual(codes(errs(r.diagnostics)), ['invalid_manifest']);
});

test('validateDocument: name mismatch on resolved manifest emits plugin_name_mismatch', () => {
  // Reference asks for "shapes" but the resolver returns a manifest declaring `:name circles`.
  const resolver: ResolverFn = () => ({
    kind: 'manifest',
    source: '(plugin :name circles :version "1.0.0")',
    wasm: null,
  });
  const r = validateDocument('(use-plugin "shapes" :path "./circles.sjon")\n', {
    projectRoot: null,
    resolver,
    projectFile: null,
  });
  const e = errs(r.diagnostics);
  assert.deepEqual(codes(e), ['plugin_name_mismatch']);
  assert.equal(r.loadedPlugins.length, 0);
});

test('validateDocument: mixed inline + reference (partial-load shape)', () => {
  // One inline declaration loads, one reference is unresolved (no
  // resolver). The data form against the loaded plugin still validates.
  const src = `
(plugin :name shapes :version "1.0.0"
  (form :name circle
    (key :name r :type number :optional false)))

(use-plugin "missing")

(circle :r 4)
`;
  const r = validateDocument(src, { projectRoot: null, resolver: null, projectFile: null });
  const e = errs(r.diagnostics);
  // Only the unresolved reference should fail; data form against `shapes` validates.
  assert.deepEqual(codes(e), ['unresolved_plugin']);
  assert.equal(r.loadedPlugins.length, 1);
});

test('validateDocument: phases emit in manifest → aggregate → validation order', () => {
  // Construct a doc that emits one of each: manifest (use-plugin without
  // resolver → unresolved_plugin), validation (unknown_form on bare
  // data). Aggregate-phase diagnostics need a cross-ref schema; we skip
  // that complexity here and just verify the two phases we have are in
  // the expected slots.
  const r = validateDocument('(use-plugin "missing")\n(widget)\n', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  const e = errs(r.diagnostics);
  assert.equal(e.length, 2);
  assert.equal(e[0]!.phase, 'manifest');
  assert.equal(e[1]!.phase, 'validation');
});

// ---------------------------------------------------------------------------
// evalExpr — declarative-only stub (TS-parity has no Expr evaluator).
// ---------------------------------------------------------------------------

test('evalExpr: throws NoExpression when the document has no data-forest form', () => {
  assert.throws(
    () =>
      evalExpr('(plugin :name solo :version "1.0.0" (form :name w :open true))', {
        projectRoot: null,
        resolver: null,
        projectFile: null,
      }),
    (err) => err instanceof EvalExprError && err.code === 'NoExpression',
  );
});

test('evalExpr: throws MultipleExpressions when more than one data form is present', () => {
  assert.throws(
    () =>
      evalExpr('(+ 1 2)\n(+ 3 4)', {
        projectRoot: null,
        resolver: null,
        projectFile: null,
      }),
    (err) => err instanceof EvalExprError && err.code === 'MultipleExpressions',
  );
});

test('evalExpr: declarative-only — value is null, diagnostics carry parse/manifest only', () => {
  const r = evalExpr('(+ 1 2 3)', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  assert.equal(r.value, null);
  // validation-phase diagnostics (e.g. unknown_form on `+` because the
  // TS host has no core schema) are filtered out — the TS host's job
  // here is parity on the prep phases only.
  assert.deepEqual(
    r.diagnostics.map((d) => d.phase),
    [],
  );
});

test('evalExpr: surfaces manifest-phase resolver failure', () => {
  const r = evalExpr('(use-plugin "missing")\n(+ 1 2)', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  assert.equal(r.value, null);
  assert.deepEqual(codes(errs(r.diagnostics)), ['unresolved_plugin']);
  assert.equal(r.diagnostics[0]!.phase, 'manifest');
});

// ----- Numeric-bounds long-tail tests for the TypeScript-parity host -----
//
// The conformance harness exercises the corpus; these dedicated tests
// pin the TS host's behaviour on the edges the Zig validator's
// long-tail tests already cover. Every test runs end-to-end through
// `validateDocument` so the manifest + aggregate + validation passes
// all participate, mirroring the corpus pipeline.

function makePlugin(body: string): string {
  return `(plugin :name p :version "1.0.0"\n${body})\n`;
}

test('bounds: :min :max accepts in-range and rejects out-of-range', () => {
  const schema = makePlugin(`
  (form :name set
    (key :name v :type opacity :optional false))
  (value-kind :name opacity :underlying number
    :numeric (numeric-bounds :min 0 :max 1))`);

  const ok = validateDocument(schema + '(set :v 0.5)', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(ok.diagnostics)), []);

  const bad = validateDocument(schema + '(set :v 1.5)', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(bad.diagnostics)), ['number_above_max']);
});

test('bounds: :exclusive-min rejects the boundary value', () => {
  const schema = makePlugin(`
  (form :name set
    (key :name v :type x :optional false))
  (value-kind :name x :underlying number
    :numeric (numeric-bounds :min 0 :exclusive-min true))`);

  const r = validateDocument(schema + '(set :v 0)', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), ['number_at_or_below_exclusive_min']);
});

test('bounds: :integer true rejects fractional value', () => {
  const schema = makePlugin(`
  (form :name set
    (key :name v :type c :optional false))
  (value-kind :name c :underlying number
    :numeric (numeric-bounds :integer true))`);

  const r = validateDocument(schema + '(set :v 3.5)', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), ['number_not_integer']);
});

test('bounds: :integer true accepts u64-range integer literal beyond i64.max', () => {
  // Parser stashes integerBits as a bigint for in-u64-range literals;
  // valueIsInteger returns true without falling back to f64 (which
  // would lose precision above 2^53).
  const schema = makePlugin(`
  (form :name set
    (key :name v :type c :optional false))
  (value-kind :name c :underlying number
    :numeric (numeric-bounds :integer true))`);

  const r = validateDocument(schema + '(set :v 9223372036854775808)', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), []);
});

test('bounds: exact-int u64 above f64 max catches the off-by-one (bigint path)', () => {
  // 2^53 + 1 doesn't fit f64 exactly; compareToBound uses bigint when
  // both bound and value are exact integers. Pins the TS parity with
  // the Zig exact-int branch.
  const schema = makePlugin(`
  (form :name set
    (key :name v :type c :optional false))
  (value-kind :name c :underlying number
    :numeric (numeric-bounds :max 9007199254740992 :exclusive-max true))`);

  const r = validateDocument(schema + '(set :v 9007199254740993)', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), ['number_at_or_above_exclusive_max']);
});

test('bounds: NaN slips past :min/:max (JS comparison semantics, parity with Zig)', () => {
  // SJON source can't write NaN literally; emulate via expression
  // arithmetic: 0 / 0 evaluates to NaN, but the host's TS-parity
  // pipeline only validates data forms — there's no expression
  // evaluator in validateDocument. Skip the NaN edge in TS (the
  // conformance corpus has no such fixture; the Zig validator's
  // synthesised-Tree test covers the corner).
  //
  // Sanity-check the JS-level behaviour of the comparison: `NaN < x`
  // and `NaN > x` are both false, mirroring the Zig fix.
  // biome-ignore lint/correctness/useIsNan: intentionally asserting that relational comparison with NaN yields false (the behaviour under test, not an accidental NaN compare).
  assert.equal(NaN < 0, false);
  // biome-ignore lint/correctness/useIsNan: intentionally asserting that relational comparison with NaN yields false (the behaviour under test, not an accidental NaN compare).
  assert.equal(NaN > 0, false);
});

test('bounds: unit-bearing bound + matching unit-bearing value passes', () => {
  const schema = makePlugin(`
  (form :name delay
    (key :name wait :type duration :optional false))
  (value-kind :name duration :underlying number
    :unit (unit-shape :required true :allowed [ms])
    :numeric (numeric-bounds :min 0ms :max 10000ms))`);

  const r = validateDocument(schema + '(delay :wait 500ms)', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), []);
});

test('bounds: bare-bound + unit-bearing value rejects on bound_unit_mismatch', () => {
  const schema = makePlugin(`
  (form :name set
    (key :name v :type d :optional false))
  (value-kind :name d :underlying number
    :numeric (numeric-bounds :min 0ms))`);

  const r = validateDocument(schema + '(set :v 5)', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), ['numeric_bound_unit_mismatch']);
});

test('bounds: bound_unit_mismatch is case-sensitive on the unit string', () => {
  // Units are opaque byte-equal — `Ms` and `ms` are distinct.
  const schema = makePlugin(`
  (form :name set
    (key :name v :type d :optional false))
  (value-kind :name d :underlying number
    :numeric (numeric-bounds :min 0ms))`);

  const r = validateDocument(schema + '(set :v 5Ms)', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), ['numeric_bound_unit_mismatch']);
});

test('bounds: unit_required upstream of bounds — :unit fires first', () => {
  const schema = makePlugin(`
  (form :name delay
    (key :name wait :type duration :optional false))
  (value-kind :name duration :underlying number
    :unit (unit-shape :required true :allowed [ms])
    :numeric (numeric-bounds :min 0ms :max 100ms))`);

  const r = validateDocument(schema + '(delay :wait 999)', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), ['unit_required']);
});

test('bounds: integer check fires before range check (priority order)', () => {
  const schema = makePlugin(`
  (form :name set
    (key :name v :type x :optional false))
  (value-kind :name x :underlying number
    :numeric (numeric-bounds :min 0 :integer true))`);

  const r = validateDocument(schema + '(set :v -0.5)', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), ['number_not_integer']);
});

test('bounds: equal-bound single-point range accepts the point', () => {
  const schema = makePlugin(`
  (form :name set
    (key :name v :type pin :optional false))
  (value-kind :name pin :underlying number
    :numeric (numeric-bounds :min 5 :max 5))`);

  const r = validateDocument(schema + '(set :v 5)', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), []);
});

test('bounds: vector-of-bounded catches element-level violation', () => {
  const schema = makePlugin(`
  (form :name layer
    (key :name opacities :type opacities :optional false))
  (value-kind :name opacity :underlying number
    :numeric (numeric-bounds :min 0 :max 1))
  (value-kind :name opacities :underlying vector
    :vector (vector-shape :element opacity))`);

  const r = validateDocument(schema + '(layer :opacities [0.0 1.0 1.5])', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), ['number_above_max']);
});

test('bounds: vector-of-bounded passes when all elements in range', () => {
  const schema = makePlugin(`
  (form :name layer
    (key :name opacities :type opacities :optional false))
  (value-kind :name opacity :underlying number
    :numeric (numeric-bounds :min 0 :max 1))
  (value-kind :name opacities :underlying vector
    :vector (vector-shape :element opacity))`);

  const r = validateDocument(schema + '(layer :opacities [0.0 0.5 1.0])', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  assert.deepEqual(codes(errs(r.diagnostics)), []);
});

test('bounds: loader emits numeric_bounds_invalid for :exclusive-min without :min', () => {
  const r = validateDocument(
    makePlugin(`
  (value-kind :name x :underlying number
    :numeric (numeric-bounds :exclusive-min true))`),
    { projectRoot: null, resolver: null, projectFile: null },
  );
  assert.ok(codes(errs(r.diagnostics)).includes('numeric_bounds_invalid'));
});

test('bounds: loader emits numeric_bounds_invalid for :min > :max with same unit', () => {
  const r = validateDocument(
    makePlugin(`
  (value-kind :name x :underlying number
    :numeric (numeric-bounds :min 1 :max 0))`),
    { projectRoot: null, resolver: null, projectFile: null },
  );
  assert.ok(codes(errs(r.diagnostics)).includes('numeric_bounds_invalid'));
});

test('bounds: loader emits numeric_bounds_invalid for non-number underlying', () => {
  const r = validateDocument(
    makePlugin(`
  (value-kind :name x :underlying string
    :numeric (numeric-bounds :min 0))`),
    { projectRoot: null, resolver: null, projectFile: null },
  );
  assert.ok(codes(errs(r.diagnostics)).includes('numeric_bounds_invalid'));
});

test('bounds: diagnostic message includes value and bound', () => {
  const schema = makePlugin(`
  (form :name set
    (key :name v :type nn :optional false))
  (value-kind :name nn :underlying number
    :numeric (numeric-bounds :min 0))`);

  const r = validateDocument(schema + '(set :v -3)', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  const d = errs(r.diagnostics).find((x) => x.code === 'number_below_min');
  assert.ok(d, 'expected number_below_min diagnostic');
  assert.match(d!.message, /below minimum/);
  assert.match(d!.message, /-3/);
});

test('bounds: diagnostic message names the suffix unit when bound has one', () => {
  const schema = makePlugin(`
  (form :name set
    (key :name v :type dur :optional false))
  (value-kind :name dur :underlying number
    :unit (unit-shape :required true :allowed [ms])
    :numeric (numeric-bounds :max 1000ms))`);

  const r = validateDocument(schema + '(set :v 1500ms)', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
  });
  const d = errs(r.diagnostics).find((x) => x.code === 'number_above_max');
  assert.ok(d, 'expected number_above_max diagnostic');
  assert.match(d!.message, /1500/);
  assert.match(d!.message, /1000ms/);
});

// --- HostOptions parity: projectDiagnostics prepend + failurePolicy ---------

const injectedDiag: HostDiagnostic = {
  code: 'invalid_manifest',
  message: 'injected project diagnostic',
  path: [],
  span: { start: 0, end: 0 },
  severity: 'err',
  phase: 'manifest',
  declarationSpan: null,
};

test('validateDocument: injected projectDiagnostics are prepended before the host stream', () => {
  // `(widget …)` with no schema produces one `unknown_form`; the injected
  // project diagnostic must land in front of it, matching web's
  // `[...projectDiagnostics, ...result]` order.
  const r = validateDocument('(widget :name w0)\n', {
    projectRoot: null,
    resolver: null,
    projectFile: null,
    projectDiagnostics: [injectedDiag],
  });
  assert.equal(r.diagnostics.length, 2);
  assert.deepEqual(r.diagnostics[0], injectedDiag);
  assert.equal(r.diagnostics[1]!.code, 'unknown_form');
});

test('validateDocument: failurePolicy is a pass-through preference with no diagnostic effect', () => {
  const base = { projectRoot: null, resolver: null, projectFile: null } as const;
  const strict = validateDocument('(widget :name w0)\n', { ...base, failurePolicy: 'strict' });
  const lenient = validateDocument('(widget :name w0)\n', { ...base, failurePolicy: 'lenient' });
  // The policy never gates emission — the two streams are identical, and both
  // equal the no-policy stream.
  assert.deepEqual(codes(strict.diagnostics), codes(lenient.diagnostics));
  assert.deepEqual(codes(strict.diagnostics), ['unknown_form']);
});
