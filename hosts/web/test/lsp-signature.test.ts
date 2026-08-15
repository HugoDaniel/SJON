// Wire-level characterization of `textDocument/signatureHelp` against the real
// `sjon-lsp.wasm`. Pins the JSON the serializer emits (`appendSignatureHelp` in
// `src/lsp/wasm.zig`) and the Handler contract: one signature per overload —
// one for a mono function like `+` — each with parameter label ranges, plus an
// active-parameter index while the cursor is on an argument, and null on the
// head / an unknown head. The playground's lsp-signature.ts consumes exactly
// this shape.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeLsp, didOpen, isRecord } from './lsp-harness.ts';

const URI = 'inmemory://sig.sjon';

test('signature help on a core variadic call labels the rest param + active index', async () => {
  const lsp = await makeLsp();
  didOpen(lsp, URI, '(+ 1 2 3)');

  // Cursor inside the second positional arg (`2`, byte 5).
  const help = lsp.request('textDocument/signatureHelp', {
    textDocument: { uri: URI },
    position: { line: 0, character: 5 },
  });
  assert.ok(isRecord(help), 'signatureHelp result is an object');

  const signatures = help['signatures'];
  assert.ok(Array.isArray(signatures));
  assert.equal(signatures.length, 1);

  const sig = signatures[0];
  assert.ok(isRecord(sig));
  const label = sig['label'];
  // Core declares `+` returns a number, so the label carries the result arrow.
  assert.equal(label, '+ ...number → `number`');

  // `+` has no `params`, so the rest type surfaces as the single parameter.
  const params = sig['parameters'];
  assert.ok(Array.isArray(params));
  assert.equal(params.length, 1);
  const p0 = params[0];
  assert.ok(isRecord(p0));
  const range = p0['label'];
  assert.ok(Array.isArray(range) && range.length === 2);
  // The tuple points at `...number` within the label.
  assert.equal((label as string).slice(range[0] as number, range[1] as number), '...number');

  assert.equal(help['activeSignature'], 0);
  assert.equal(help['activeParameter'], 0);
});

test('signature help on the head is null', async () => {
  const lsp = await makeLsp();
  didOpen(lsp, URI, '(+ 1 2)');
  // Cursor on the `+` head (byte 1) — completion territory, not signatures.
  const help = lsp.request('textDocument/signatureHelp', {
    textDocument: { uri: URI },
    position: { line: 0, character: 1 },
  });
  assert.equal(help, null);
});

test('signature help under an unknown head is null', async () => {
  const lsp = await makeLsp();
  didOpen(lsp, URI, '(wibble 1 2)');
  // Cursor inside the args (byte 8) but the head resolves to nothing.
  const help = lsp.request('textDocument/signatureHelp', {
    textDocument: { uri: URI },
    position: { line: 0, character: 8 },
  });
  assert.equal(help, null);
});
