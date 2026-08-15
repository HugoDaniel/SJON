// Wire-level characterization of the `initialize` handshake against the real
// `sjon-lsp.wasm`. The playground's staleness guard (lsp-meta.ts) reads the
// running server's `serverInfo` to detect a stale artifact, and the hover /
// signatureHelp features Part 5 wires depend on those capabilities being
// advertised. These tests pin the exact JSON the serializer emits
// (`src/lsp/wasm.zig:187-207`) so a drift in either surface is caught here.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeRawLsp, isRecord } from './lsp-harness.ts';

test('initialize: advertises serverInfo name + version', async () => {
  const lsp = await makeRawLsp();
  const result = lsp.request('initialize', { capabilities: {} });
  assert.ok(isRecord(result), 'initialize result is an object');

  const serverInfo = result['serverInfo'];
  assert.ok(isRecord(serverInfo), 'serverInfo present');
  assert.equal(serverInfo['name'], 'sjon-lsp');
  // Version is `src/version.zig` (currently 1.0.0); assert the shape, not the
  // exact number, so a version bump doesn't break this test — the staleness
  // guard compares two live reads, it never hard-codes a version.
  assert.equal(typeof serverInfo['version'], 'string');
  assert.ok((serverInfo['version'] as string).length > 0);
});

test('initialize: advertises hover + signatureHelp capabilities', async () => {
  const lsp = await makeRawLsp();
  const result = lsp.request('initialize', { capabilities: {} });
  assert.ok(isRecord(result));

  const caps = result['capabilities'];
  assert.ok(isRecord(caps), 'capabilities present');

  // Hover: a bare `true`.
  assert.equal(caps['hoverProvider'], true);

  // SignatureHelp: an object with the trigger `(` and retrigger ` `.
  const sig = caps['signatureHelpProvider'];
  assert.ok(isRecord(sig), 'signatureHelpProvider present');
  assert.deepEqual(sig['triggerCharacters'], ['(']);
  assert.deepEqual(sig['retriggerCharacters'], [' ']);

  // Completion + folding are already wired in the playground; pin them too so
  // the capability block stays a single source of truth for the client.
  const completion = caps['completionProvider'];
  assert.ok(isRecord(completion));
  assert.deepEqual(completion['triggerCharacters'], ['(', ':', '[']);
  assert.equal(caps['foldingRangeProvider'], true);
});

test('initialize: positionEncoding defaults to utf-16', async () => {
  const lsp = await makeRawLsp();
  // No `general.positionEncodings` in the client capabilities → the server
  // keeps its utf-16 default (what the CodeMirror offset mapping assumes).
  const result = lsp.request('initialize', { capabilities: {} });
  assert.ok(isRecord(result));
  const caps = result['capabilities'];
  assert.ok(isRecord(caps));
  assert.equal(caps['positionEncoding'], 'utf-16');
});
