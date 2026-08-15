// HostOptions parity: `projectDiagnostics` prepend order + `failurePolicy`'s
// no-op-on-diagnostics contract. The same two facts are pinned in
// `hosts/typescript-parity/test/host.test.ts`, so all three hosts agree that a
// caller-injected diagnostic lands first and that the failure preference never
// changes the emitted stream (only the CLI reads it for an exit code).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonHost } from '../SjonHost.ts';
import type { HostDiagnostic } from '../types.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');

const injectedDiag: HostDiagnostic = {
  span: { start: 0, end: 0 },
  severity: 'err',
  code: 'invalid_manifest',
  message: 'injected project diagnostic',
  phase: 'manifest',
  path: [],
  declarationSpan: null,
};

test('validateDocument: injected projectDiagnostics are prepended before the host stream', async () => {
  const host = await SjonHost.load(wasmPath);
  // `(widget …)` with no schema yields one `unknown_form`; the injected project
  // diagnostic must precede it — the `[...projectDiagnostics, ...result]` order.
  const r = host.validateDocument('(widget :name w0)\n', {
    projectRoot: null,
    projectFile: null,
    projectDiagnostics: [injectedDiag],
  });
  assert.equal(r.diagnostics.length, 2);
  assert.deepEqual(r.diagnostics[0], injectedDiag);
  assert.equal(r.diagnostics[1]!.code, 'unknown_form');
});

test('validateDocument: failurePolicy is a pass-through preference with no diagnostic effect', async () => {
  const host = await SjonHost.load(wasmPath);
  const base = { projectRoot: null, projectFile: null } as const;
  const strict = host.validateDocument('(widget :name w0)\n', { ...base, failurePolicy: 'strict' });
  const lenient = host.validateDocument('(widget :name w0)\n', {
    ...base,
    failurePolicy: 'lenient',
  });
  assert.deepEqual(
    strict.diagnostics.map((d) => d.code),
    lenient.diagnostics.map((d) => d.code),
  );
  assert.deepEqual(
    strict.diagnostics.map((d) => d.code),
    ['unknown_form'],
  );
});
