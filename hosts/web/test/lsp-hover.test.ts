// Wire-level characterization of `textDocument/hover` against the real
// `sjon-lsp.wasm`. Pins the JSON the serializer emits (`src/lsp/wasm.zig:
// 411-429`) and the Handler's hover contract (`Handler_tests.zig:108-179`):
// a markdown card + a byte-accurate range over the head, null off any node.
// The playground's lsp-hover.ts renders that markdown; this guards the source.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeLsp, didOpen, isRecord } from './lsp-harness.ts';

const URI = 'inmemory://hover.sjon';

// Pins the harness `isRecord`'s array-rejection arm — several LSP responses are
// bare item arrays, so a guard that narrowed `[]` to a record would mislead.
test('isRecord rejects arrays and null, accepts plain objects', () => {
  assert.equal(isRecord([]), false);
  assert.equal(isRecord(null), false);
  assert.equal(isRecord({}), true);
});

test('hover on a core expr head returns markdown + a head-spanning range', async () => {
  const lsp = await makeLsp();
  didOpen(lsp, URI, '(+ 1 2)');

  // Cursor on the `+` (character 1).
  const hover = lsp.request('textDocument/hover', {
    textDocument: { uri: URI },
    position: { line: 0, character: 1 },
  });
  assert.ok(isRecord(hover), 'hover result is an object');

  const contents = hover['contents'];
  assert.ok(isRecord(contents), 'contents present');
  assert.equal(contents['kind'], 'markdown');
  const value = contents['value'];
  assert.equal(typeof value, 'string');
  // The core `+` is an expression func; its card names both.
  assert.ok((value as string).includes('core'), `mentions the plugin: ${value as string}`);
  assert.ok((value as string).includes('expression'), `names the kind: ${value as string}`);

  // Range covers exactly the `+` head — bytes 1..2 → {0,1}-{0,2}.
  assert.deepEqual(hover['range'], {
    start: { line: 0, character: 1 },
    end: { line: 0, character: 2 },
  });
});

test('hover on an unknown head is null', async () => {
  const lsp = await makeLsp();
  didOpen(lsp, URI, '(wibble)');
  const hover = lsp.request('textDocument/hover', {
    textDocument: { uri: URI },
    position: { line: 0, character: 1 },
  });
  assert.equal(hover, null);
});

test('hover past every node is null', async () => {
  const lsp = await makeLsp();
  didOpen(lsp, URI, '(+ 1 2)\n');
  // Line 1, character 0 = byte 8, the position after the trailing newline.
  const hover = lsp.request('textDocument/hover', {
    textDocument: { uri: URI },
    position: { line: 1, character: 0 },
  });
  assert.equal(hover, null);
});
