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

// `heldSymbol` — a document being typed. The same pair is pinned in the Rust
// host (`host_d7_exec.rs`) and in the Zig `Host_tests`: without the option the
// three refinement axes report; with it the result is empty. Only the pair is
// the contract — the first half is what keeps the second from being "accept
// everything".

const heldDoc = `(plugin :name hold :version "1.0.0"
  (form :name kernel
    (key :name name :type symbol))
  (form :name warp
    (key :name by :type kernel-ref)
    (key :name amount :type number)
    (key :name blend :type blend-mode :optional true))
  (value-kind :name kernel-ref
    :underlying symbol
    :cross-ref (cross-ref :target kernel :name-key name))
  (value-kind :name blend-mode
    :underlying symbol
    :members (member-set (member :name over) (member :name add))))

(kernel :name flow)
(warp :by _ :amount _ :blend _)
`;

test('validateDocument: without heldSymbol, `_` fails on every refinement axis', async () => {
  const host = await SjonHost.load(wasmPath);
  const r = host.validateDocument(heldDoc, { projectRoot: null, projectFile: null });
  const codes = new Set(r.diagnostics.map((d) => d.code));
  assert.ok(codes.has('not_cross_ref'));
  assert.ok(codes.has('wrong_underlying'));
  assert.ok(codes.has('not_member'));
});

test('validateDocument: with heldSymbol, the same document is clean', async () => {
  const host = await SjonHost.load(wasmPath);
  const r = host.validateDocument(heldDoc, {
    projectRoot: null,
    projectFile: null,
    heldSymbol: '_',
  });
  assert.deepEqual(r.diagnostics, []);
});

test('validateDocument: two held cross-ref names do not collide', async () => {
  const host = await SjonHost.load(wasmPath);
  const src = `(plugin :name hold :version "1.0.0"
  (form :name kernel
    (key :name name :type symbol))
  (value-kind :name kernel-ref
    :underlying symbol
    :cross-ref (cross-ref :target kernel :name-key name)))

(kernel :name _)
(kernel :name _)
`;
  const r = host.validateDocument(src, {
    projectRoot: null,
    projectFile: null,
    heldSymbol: '_',
  });
  assert.deepEqual(r.diagnostics, []);
});
