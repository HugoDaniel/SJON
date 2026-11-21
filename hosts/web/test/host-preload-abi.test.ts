// Raw-ABI tests for the P3 preloaded-schema handle surface. These drive
// the `sjon.wasm` exports directly — `sjon_preload_schema`,
// `sjon_schema_free`, and the `preloadedHandle` option key of
// `sjon_host_validate_document` / `sjon_host_eval_expr` — through the
// framing protocol, never through a `SjonHost.preload` wrapper (which is
// Task 3's deliverable). The wire shape pinned here is what Task 3's Web
// wrapper and Task 4's Rust mirror both code against.
//
// The behaviours, in the plan's order: one/two-source report shape;
// source-index alignment when the second source is malformed; a
// non-plugin source as `ok=1` + `invalid_manifest` at span 0..0;
// aggregate diagnostics across sources; additive inline declaration with
// document-local validation spans; two independent preloads;
// stale/unknown/foreign numeric IDs refused as `InvalidSchemaHandle`;
// free/double-free safety; declarative expr-func evaluation through a
// handle; `sjon_describe` naming both exports; and the `InvalidOptions`
// refusals for malformed input JSON and option values.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonWasm } from '../sjon-reader.ts';
import type { HostDiagnostic, PluginSummary } from '../types.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** The `sjon_preload_schema` report frame, decoded. */
interface PreloadReport {
  readonly handle: number;
  readonly hasErrors: boolean;
  readonly diagnostics: readonly HostDiagnostic[];
  readonly sourceDiagnostics: readonly (readonly HostDiagnostic[])[];
  readonly aggregateDiagnostics: readonly HostDiagnostic[];
  readonly loadedPlugins: readonly PluginSummary[];
}

/** One framed export answer: `ok` plus the decoded payload text. */
interface Frame {
  readonly ok: boolean;
  readonly payload: string;
}

async function loadRaw(): Promise<SjonWasm> {
  // A fresh instance per helper call site: instance state (linear memory,
  // module globals) is the handle table's ownership scope, so the
  // cross-instance tests below need instances they fully control.
  const instance = await SjonWasm._instantiate(wasmPath);
  return new SjonWasm(instance);
}

function exportFn(wasm: SjonWasm, name: string): (...args: number[]) => number {
  const fn = wasm.exports[name];
  assert.ok(typeof fn === 'function', `export ${name} is absent from sjon.wasm`);
  return fn as (...args: number[]) => number;
}

/** Drive `sjon_preload_schema` over raw `src_bytes` (not necessarily JSON). */
function preloadBytes(wasm: SjonWasm, srcBytes: Uint8Array): Frame {
  const inPtr = wasm._alloc(srcBytes);
  try {
    const fn = exportFn(wasm, 'sjon_preload_schema');
    const { ok, payload } = wasm._readFramed(fn(inPtr, srcBytes.length));
    return { ok, payload: decoder.decode(payload) };
  } finally {
    wasm._free(inPtr, srcBytes.length);
  }
}

function preload(wasm: SjonWasm, sources: readonly string[]): Frame {
  return preloadBytes(wasm, encoder.encode(JSON.stringify(sources)));
}

function preloadOk(wasm: SjonWasm, sources: readonly string[]): PreloadReport {
  const frame = preload(wasm, sources);
  assert.ok(frame.ok, `expected ok=1, got ok=0 "${frame.payload}"`);
  return JSON.parse(frame.payload) as PreloadReport;
}

/** Drive `sjon_host_validate_document` with a raw options object. */
function validateRaw(
  wasm: SjonWasm,
  source: string,
  opts: Readonly<Record<string, unknown>>,
): Frame {
  return twoBufferCall(wasm, 'sjon_host_validate_document', source, opts);
}

/** Drive `sjon_host_eval_expr` with a raw options object. */
function evalRaw(wasm: SjonWasm, source: string, opts: Readonly<Record<string, unknown>>): Frame {
  return twoBufferCall(wasm, 'sjon_host_eval_expr', source, opts);
}

function twoBufferCall(
  wasm: SjonWasm,
  name: string,
  source: string,
  opts: Readonly<Record<string, unknown>>,
): Frame {
  const src = encoder.encode(source);
  const ob = encoder.encode(JSON.stringify(opts));
  const srcPtr = wasm._alloc(src);
  const optsPtr = wasm._alloc(ob);
  try {
    const fn = exportFn(wasm, name);
    const { ok, payload } = wasm._readFramed(fn(srcPtr, src.length, optsPtr, ob.length));
    return { ok, payload: decoder.decode(payload) };
  } finally {
    wasm._free(srcPtr, src.length);
    wasm._free(optsPtr, ob.length);
  }
}

/** Drive `sjon_schema_free(handle)`; a no-op free must not trap. */
function freeRaw(wasm: SjonWasm, handle: number): void {
  (exportFn(wasm, 'sjon_schema_free') as (h: number) => void)(handle);
}

// ---------------------------------------------------------------------------
// Fixtures — the same sources the native `Host.preloadSchema` tests pin
// (src/Host.zig "preloadSchema (F9)"), so the ABI report and the native
// `PreloadedSchema` stay observably the same contract.
// ---------------------------------------------------------------------------

const shapesManifest = `(plugin :name shapes :version "1.0.0"
  (form :name box
    (key :name w :type number :optional false)
    (key :name label :type string :optional true)))`;

const bystanderManifest = '(plugin :name bystander :version "1.0.0")';

// Two top-level roots: passes per-root parsing, fails the loader's
// single-(plugin …) shape gate → `invalid_manifest` whose message names
// the input ordinal ("preloaded manifest source 1").
const twoRootsManifest = `(plugin :name a :version "1.0.0")
(plugin :name b :version "1.0.0")`;

// A non-plugin source: parses cleanly, passes meta-validation, and then
// fails the loader's single-(plugin …) shape gate at the root count → the
// canonical `invalid_manifest` at span 0..0. (A single non-plugin *root*
// like `(widget …)` never reaches that gate — meta-validation rejects it
// first with its own `unknown_form`, which is also the native behavior.)
const nonPluginManifest = '; a comment is not a (plugin …) manifest';

// Loads cleanly, but `:target ghost` resolves to no form in the combined
// aggregate → an `.aggregate`-phase `unknown_cross_ref_target`.
const danglerManifest = `(plugin :name dangler :version "1.0.0"
  (value-kind :name ref-kind
    :underlying symbol
    :cross-ref (cross-ref :target ghost)))`;

// A declaration-only (declarative) expr-func: no `:impl`, so the schema
// knows `double`'s signature but nothing can execute it. Evaluating
// `(double 21)` through this schema surfaces `plugin_func_failed`
// (Expr.applyFunction's declaration-only refusal); without the schema the
// same form evaluates as form-as-data.
const declarativeEvalManifest = `(plugin :name ev :version "1.0.0"
  (expr-func :name double :arity (fixed 1) :params [number] :result number))`;

// ---------------------------------------------------------------------------

test('raw ABI: sjon_describe names preload_schema and schema_free', async () => {
  const wasm = await loadRaw();
  assert.equal(typeof wasm.exports['sjon_preload_schema'], 'function');
  assert.equal(typeof wasm.exports['sjon_schema_free'], 'function');
  const describe = wasm._callJsonNullary('sjon_describe') as { exports: string[] };
  assert.ok(describe.exports.includes('preload_schema'), JSON.stringify(describe.exports));
  assert.ok(describe.exports.includes('schema_free'), JSON.stringify(describe.exports));
});

test('raw ABI: one clean source reports handle, streams, and loaded plugins', async () => {
  const wasm = await loadRaw();
  const report = preloadOk(wasm, [shapesManifest]);
  assert.ok(Number.isInteger(report.handle));
  assert.ok(report.handle > 0, `handle must be a positive u32, got ${report.handle}`);
  assert.equal(report.hasErrors, false);
  assert.deepEqual(report.diagnostics, []);
  assert.deepEqual(report.sourceDiagnostics, [[]]);
  assert.deepEqual(report.aggregateDiagnostics, []);
  assert.deepEqual(report.loadedPlugins, [{ name: 'shapes', version: null, formCount: 1 }]);

  // The empty source list is the degenerate clean preload: a valid handle
  // over an empty schema (native "empty source list" pin).
  const empty = preloadOk(wasm, []);
  assert.ok(empty.handle > 0);
  assert.equal(empty.hasErrors, false);
  assert.deepEqual(empty.sourceDiagnostics, []);
  assert.deepEqual(empty.loadedPlugins, []);

  // Distinct handles: the empty preload neither replaced nor stacked.
  assert.notEqual(empty.handle, report.handle);
});

test('raw ABI: a malformed second source keeps input-index alignment', async () => {
  const wasm = await loadRaw();
  const report = preloadOk(wasm, [shapesManifest, twoRootsManifest]);

  // One report per input, in input order — the failure at index 1 does
  // not compact the slice or shift the clean first source.
  assert.equal(report.sourceDiagnostics.length, 2);
  assert.deepEqual(report.sourceDiagnostics[0], []);
  const second = report.sourceDiagnostics[1]!;
  assert.equal(second.length, 1);
  assert.equal(second[0]!.code, 'invalid_manifest');
  assert.equal(second[0]!.phase, 'manifest');
  // The anchor names the input ordinal the failure came from.
  assert.ok(
    second[0]!.message.includes('source 1'),
    `message must name the input index: ${second[0]!.message}`,
  );

  // The clean first plugin still loaded; the failing source contributed none.
  assert.deepEqual(
    report.loadedPlugins.map((p) => p.name),
    ['shapes'],
  );
  assert.equal(report.hasErrors, true);
  // `diagnostics` is the flattened per-source view followed by aggregate.
  assert.deepEqual(report.diagnostics, second);
  assert.deepEqual(report.aggregateDiagnostics, []);
});

test('raw ABI: a non-plugin source is ok=1 with invalid_manifest at span 0..0', async () => {
  const wasm = await loadRaw();
  const frame = preload(wasm, [nonPluginManifest]);
  assert.equal(frame.ok, true, `non-plugin source must frame ok=1, got ${frame.payload}`);
  const report = JSON.parse(frame.payload) as PreloadReport;
  assert.equal(report.hasErrors, true);
  assert.deepEqual(report.loadedPlugins, []);
  assert.equal(report.diagnostics.length, 1);
  const d = report.diagnostics[0]!;
  assert.equal(d.code, 'invalid_manifest');
  assert.equal(d.phase, 'manifest');
  assert.deepEqual(d.span, { start: 0, end: 0 });
});

test('raw ABI: aggregate diagnostics ride their own stream across sources', async () => {
  const wasm = await loadRaw();
  const report = preloadOk(wasm, [danglerManifest, bystanderManifest]);

  // Both sources loaded cleanly — no per-source report for either.
  assert.deepEqual(report.sourceDiagnostics, [[], []]);
  // The combined-set failure is aggregate-phase and separate.
  assert.ok(report.aggregateDiagnostics.length > 0);
  for (const d of report.aggregateDiagnostics) {
    assert.equal(d.phase, 'aggregate');
  }
  assert.ok(
    report.aggregateDiagnostics.some((d) => d.code === 'unknown_cross_ref_target'),
    report.aggregateDiagnostics.map((d) => d.code).join(','),
  );
  // Flattened view: source reports first, then aggregate.
  assert.deepEqual(report.diagnostics, report.aggregateDiagnostics);
  assert.equal(report.hasErrors, true);
});

test('raw ABI: validating through a handle is additive with inline declarations', async () => {
  const wasm = await loadRaw();
  const { handle } = preloadOk(wasm, [shapesManifest]);

  // The preloaded plugin plus an inline declaration compose: both forms
  // resolve, and loadedPlugins is preloaded ++ document-loaded.
  const composed = `(plugin :name extra :version "1.0.0"
  (form :name tag (key :name t :type symbol)))

(box :w 1)
(tag :t hello)
`;
  const r = validateRaw(wasm, composed, { preloadedHandle: handle });
  assert.ok(r.ok, r.payload);
  const result = JSON.parse(r.payload) as {
    diagnostics: HostDiagnostic[];
    loadedPlugins: PluginSummary[];
  };
  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(
    result.loadedPlugins.map((p) => p.name),
    ['shapes', 'extra'],
  );

  // The same document without the handle: `box` is out of scope — the
  // handle is what brought it in.
  const bare = validateRaw(wasm, composed, {});
  assert.ok(bare.ok, bare.payload);
  assert.deepEqual(
    (JSON.parse(bare.payload) as { diagnostics: HostDiagnostic[] }).diagnostics.map((d) => d.code),
    ['unknown_form'],
  );

  // `null` is today's behaviour, same as absent.
  const nullHandle = validateRaw(wasm, '(box :w 1)\n', { preloadedHandle: null });
  assert.ok(nullHandle.ok, nullHandle.payload);
  assert.deepEqual(
    (JSON.parse(nullHandle.payload) as { diagnostics: HostDiagnostic[] }).diagnostics.map(
      (d) => d.code,
    ),
    ['unknown_form'],
  );
});

test('raw ABI: validation diagnostics through a handle stay document-local', async () => {
  const wasm = await loadRaw();
  const { handle } = preloadOk(wasm, [shapesManifest]);

  const doc = '(box :w "nope")\n';
  const r = validateRaw(wasm, doc, { preloadedHandle: handle });
  assert.ok(r.ok, r.payload);
  const { diagnostics } = JSON.parse(r.payload) as { diagnostics: HostDiagnostic[] };
  assert.deepEqual(
    diagnostics.map((d) => d.code),
    ['wrong_underlying'],
  );
  // No span rebasing: every span indexes the document's own UTF-8 bytes.
  const docBytes = encoder.encode(doc).byteLength;
  for (const d of diagnostics) {
    assert.ok(
      d.span.end <= docBytes,
      `${d.code} span ${d.span.start}..${d.span.end} leaves the document (${docBytes} bytes)`,
    );
  }

  // A second document-local shape on the same handle (it survives calls).
  const r2 = validateRaw(wasm, '(box)\n', { preloadedHandle: handle });
  assert.ok(r2.ok, r2.payload);
  assert.deepEqual(
    (JSON.parse(r2.payload) as { diagnostics: HostDiagnostic[] }).diagnostics.map((d) => d.code),
    ['missing_required_key'],
  );
});

test('raw ABI: two preloads are independent, non-replacing handles', async () => {
  const wasm = await loadRaw();
  const first = preloadOk(wasm, [shapesManifest]);
  const second = preloadOk(wasm, [bystanderManifest]);

  assert.ok(first.handle > 0);
  assert.ok(second.handle > 0);
  assert.notEqual(second.handle, first.handle);

  // The first handle still resolves its own schema after the second
  // preload — and never gained the second's plugins.
  const viaFirst = validateRaw(wasm, '(box :w 1)\n', { preloadedHandle: first.handle });
  assert.ok(viaFirst.ok, viaFirst.payload);
  const viaFirstResult = JSON.parse(viaFirst.payload) as {
    diagnostics: HostDiagnostic[];
    loadedPlugins: PluginSummary[];
  };
  assert.deepEqual(viaFirstResult.diagnostics, []);
  assert.deepEqual(
    viaFirstResult.loadedPlugins.map((p) => p.name),
    ['shapes'],
  );

  // The second handle works too, without the first's forms in scope.
  const viaSecond = validateRaw(wasm, '(box :w 1)\n', { preloadedHandle: second.handle });
  assert.ok(viaSecond.ok, viaSecond.payload);
  assert.deepEqual(
    (JSON.parse(viaSecond.payload) as { diagnostics: HostDiagnostic[] }).diagnostics.map(
      (d) => d.code,
    ),
    ['unknown_form'],
  );
});

test('raw ABI: stale, unknown, and foreign numeric IDs return InvalidSchemaHandle', async () => {
  const wasm = await loadRaw();
  const { handle } = preloadOk(wasm, [shapesManifest]);

  // Unknown: never issued by this instance.
  const unknown = validateRaw(wasm, '(box :w 1)\n', { preloadedHandle: handle + 1000 });
  assert.equal(unknown.ok, false);
  assert.equal(unknown.payload, 'InvalidSchemaHandle');

  // Stale: freed, then used.
  freeRaw(wasm, handle);
  const stale = validateRaw(wasm, '(box :w 1)\n', { preloadedHandle: handle });
  assert.equal(stale.ok, false);
  assert.equal(stale.payload, 'InvalidSchemaHandle');

  // Foreign: a handle minted by a different instance has no entry in this
  // one's table — raw IDs carry no owner token at this layer, so the
  // refusal is the only honest answer. The second instance's numeric ID
  // deliberately equals the freed local one: the foreign ID and the stale
  // local ID are indistinguishable, and both must miss.
  const other = await loadRaw();
  const otherReport = preloadOk(other, [shapesManifest]);
  assert.ok(otherReport.handle > 0);
  const foreign = validateRaw(wasm, '(box :w 1)\n', { preloadedHandle: otherReport.handle });
  assert.equal(foreign.ok, false);
  assert.equal(foreign.payload, 'InvalidSchemaHandle');

  // The eval path refuses the same way — it borrows from the same table.
  const evalStale = evalRaw(wasm, '(+ 1 2)', { preloadedHandle: handle });
  assert.equal(evalStale.ok, false);
  assert.equal(evalStale.payload, 'InvalidSchemaHandle');
});

test('raw ABI: free and double-free are safe no-ops, never traps', async () => {
  const wasm = await loadRaw();
  const { handle } = preloadOk(wasm, [shapesManifest]);

  freeRaw(wasm, 0); // zero is never a handle
  freeRaw(wasm, 4242); // unknown
  freeRaw(wasm, handle); // the real free
  freeRaw(wasm, handle); // stale — freed exactly once

  // The instance is still healthy: a fresh preload mints a new distinct
  // handle and validates through it.
  const fresh = preloadOk(wasm, [shapesManifest]);
  assert.ok(fresh.handle > 0);
  assert.notEqual(fresh.handle, handle);
  const r = validateRaw(wasm, '(box :w 1)\n', { preloadedHandle: fresh.handle });
  assert.ok(r.ok, r.payload);
  assert.deepEqual((JSON.parse(r.payload) as { diagnostics: HostDiagnostic[] }).diagnostics, []);
});

test('raw ABI: declarative expr-func evaluation dispatches through a handle', async () => {
  const wasm = await loadRaw();
  const { handle } = preloadOk(wasm, [declarativeEvalManifest]);

  // With the handle, `double` resolves in the evaluator's schema — as a
  // declaration-only function, so the call reports the declarative
  // refusal (`plugin_func_failed`) instead of producing a value. The
  // refusal itself proves the preloaded schema reached the evaluator.
  const withHandle = evalRaw(wasm, '(double 21)', { preloadedHandle: handle });
  assert.ok(withHandle.ok, withHandle.payload);
  const result = JSON.parse(withHandle.payload) as {
    value: unknown;
    diagnostics: HostDiagnostic[];
    loadedPlugins: PluginSummary[];
  };
  assert.equal(result.value, null);
  assert.deepEqual(
    result.diagnostics.map((d) => d.code),
    ['plugin_func_failed'],
  );
  assert.equal(result.diagnostics[0]!.phase, 'validation');
  assert.deepEqual(
    result.loadedPlugins.map((p) => p.name),
    ['ev'],
  );

  // Without the handle the same expression evaluates as form-as-data:
  // the contrast pins that the handle (not the option parser) supplied
  // the schema the evaluator consulted.
  const bare = evalRaw(wasm, '(double 21)', {});
  assert.ok(bare.ok, bare.payload);
  const bareResult = JSON.parse(bare.payload) as {
    value: unknown;
    diagnostics: HostDiagnostic[];
  };
  assert.deepEqual(bareResult.diagnostics, []);
  assert.deepEqual(bareResult.value, { $form: 'double', children: [21], kvpairs: {} });

  // Core evaluation is unaffected while a handle is borrowed.
  const core = evalRaw(wasm, '(+ 1 2)', { preloadedHandle: handle });
  assert.ok(core.ok, core.payload);
  assert.equal((JSON.parse(core.payload) as { value: unknown }).value, 3);
});

test('raw ABI: malformed preload input and option values return InvalidOptions', async () => {
  const wasm = await loadRaw();

  // Not JSON at all.
  const notJson = preloadBytes(wasm, encoder.encode('(not json'));
  assert.equal(notJson.ok, false);
  assert.equal(notJson.payload, 'InvalidOptions');

  // Valid JSON, but not an array of sources.
  const notArray = preloadBytes(wasm, encoder.encode('"just a string"'));
  assert.equal(notArray.ok, false);
  assert.equal(notArray.payload, 'InvalidOptions');

  // Array members must all be strings. The mixed array is serialized by
  // hand and driven through the raw-bytes path — `preload`'s `string[]`
  // parameter is the type the ABI expects, which is precisely what this
  // input violates.
  const nonString = preloadBytes(wasm, encoder.encode(JSON.stringify([shapesManifest, 42])));
  assert.equal(nonString.ok, false);
  assert.equal(nonString.payload, 'InvalidOptions');

  // preloadedHandle accepts positive integral u32 IDs only.
  for (const bad of [0, 1.5, '3']) {
    const r = validateRaw(wasm, '(box :w 1)\n', { preloadedHandle: bad });
    assert.equal(r.ok, false, `preloadedHandle ${JSON.stringify(bad)} must be refused`);
    assert.equal(r.payload, 'InvalidOptions');
  }
});
