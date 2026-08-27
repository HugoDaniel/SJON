// Wire-level characterization of `textDocument/diagnostic` (LSP 3.17 pull
// diagnostics) against the real `sjon-lsp.wasm`. Pins the report protocol
// (`src/lsp/wasm.zig:246-303`) and item shape (`:1244-1273`): a `full` report
// carries a `resultId` (`"{version}:{schemaGen}"`) + `items`; re-pulling with a
// matching `previousResultId` yields `unchanged`. The playground only ever pulls
// `full` (lsp-integration.ts), but the server's whole contract is pinned here so
// a serializer drift is caught. These are characterization tests — green on
// arrival, no red.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeLsp, didOpen, isRecord } from './lsp-harness.ts';

const URI = 'inmemory://diag.sjon';

test('a full report carries a resultId + a shaped diagnostic item', async () => {
  const lsp = await makeLsp();
  // `+` expects numbers; the string arg is a validator (not parse) error.
  didOpen(lsp, URI, '(+ 1 "hi")');

  const report = lsp.request('textDocument/diagnostic', { textDocument: { uri: URI } });
  assert.ok(isRecord(report));
  assert.equal(report['kind'], 'full');
  assert.equal(typeof report['resultId'], 'string');
  assert.ok((report['resultId'] as string).length > 0);

  const items = report['items'];
  assert.ok(Array.isArray(items));
  assert.equal(items.length, 1);

  const d = items[0];
  assert.ok(isRecord(d));
  assert.ok(isRecord(d['range']), 'has a range');
  assert.equal(d['severity'], 1, 'error severity');
  assert.equal(d['source'], 'sjon');
  assert.equal(d['code'], 'expr_type_mismatch');
  assert.ok(typeof d['message'] === 'string' && (d['message'] as string).includes('number'));
});

test('re-pulling with a matching previousResultId yields an unchanged report', async () => {
  const lsp = await makeLsp();
  didOpen(lsp, URI, '(+ 1 "hi")');

  const first = lsp.request('textDocument/diagnostic', { textDocument: { uri: URI } });
  assert.ok(isRecord(first));
  const resultId = first['resultId'];

  // Same doc version + schema generation → the report is unchanged.
  const second = lsp.request('textDocument/diagnostic', {
    textDocument: { uri: URI },
    previousResultId: resultId,
  });
  assert.ok(isRecord(second));
  assert.equal(second['kind'], 'unchanged');
  assert.equal(second['resultId'], resultId);
});

// A provider-backed cross-ref whose provider ships no `:impl` and, being a
// pane rather than a project plugin, no wasm either. `sjon-lsp.wasm` is
// instantiated with `{}` and declares no imports, so it could not call out
// to one even if it had it — this is the browser's permanent condition, not
// a property of this manifest.
const PROVIDER_SCHEMA = [
  '(plugin :name glsl :version "1.0.0"',
  '  (cross-ref-provider :name lines)',
  '  (form :name shader',
  '    (key :name name :type symbol :optional false)',
  '    (key :name src :type string :optional false))',
  '  (value-kind :name uniform-name :underlying symbol',
  '    :cross-ref (cross-ref :target shader :provider lines))',
  '  (form :name bind',
  '    (key :name uniform :type uniform-name :optional false)))',
].join('\n');

test('a provider this host can never run renders as a hint, not an error', async () => {
  const lsp = await makeLsp();
  lsp.request('sjon/setSchemas', {
    schemas: [{ uri: 'inmemory://schema/0', text: PROVIDER_SCHEMA }],
  });
  didOpen(lsp, URI, '(shader :name main :src "u_time")\n(bind :uniform u_time)');

  const report = lsp.request('textDocument/diagnostic', { textDocument: { uri: URI } });
  assert.ok(isRecord(report));
  const items = report['items'];
  assert.ok(Array.isArray(items));
  assert.equal(items.length, 1);

  const d = items[0];
  assert.ok(isRecord(d));
  assert.equal(d['code'], 'cross_ref_provider_unavailable');
  // LSP `DiagnosticSeverity.Hint`. The validator graded this an error and
  // the wire code says so; the downgrade is this layer's, and it is the
  // difference between "your file is wrong" and "this host didn't check".
  assert.equal(d['severity'], 4, 'hint severity');
  // The reference itself stays quiet — the bucket is poisoned, not empty.
  assert.ok((d['message'] as string).includes('was not run'));
});

test('a clean document reports full with an empty item list', async () => {
  const lsp = await makeLsp();
  didOpen(lsp, URI, '(+ 1 2)');

  const report = lsp.request('textDocument/diagnostic', { textDocument: { uri: URI } });
  assert.ok(isRecord(report));
  assert.equal(report['kind'], 'full');
  assert.deepEqual(report['items'], []);
});
