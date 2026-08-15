// Wire-level tests for `textDocument/foldingRange` against the real
// `sjon-lsp.wasm`. The playground consumes this route to drive CodeMirror's
// fold gutter; these tests pin the JSON-RPC contract the client relies on:
// 0-based `{startLine, endLine}` pairs, single-line spans filtered out, and
// `null` for an unknown document. The JSON-RPC pump lives in lsp-harness.ts.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeLsp, didOpen, didChange, type RawLsp } from './lsp-harness.ts';

interface WireFold {
  startLine: number;
  endLine: number;
}

function isWireFold(x: unknown): x is WireFold {
  return (
    typeof x === 'object' &&
    x !== null &&
    typeof (x as { startLine?: unknown }).startLine === 'number' &&
    typeof (x as { endLine?: unknown }).endLine === 'number'
  );
}

function foldingRanges(lsp: RawLsp, uri: string): unknown {
  return lsp.request('textDocument/foldingRange', { textDocument: { uri } });
}

test('foldingRange: a multi-line form yields one 0-based range', async () => {
  const lsp = await makeLsp();
  const uri = 'inmemory://multi.sjon';
  didOpen(lsp, uri, '(scene\n  :w 1\n  :h 2)');

  const result = foldingRanges(lsp, uri);
  assert.ok(Array.isArray(result));
  assert.equal(result.length, 1);
  assert.ok(isWireFold(result[0]));
  assert.equal(result[0].startLine, 0);
  assert.equal(result[0].endLine, 2);
});

test('foldingRange: a single-line document is filtered to an empty list', async () => {
  const lsp = await makeLsp();
  const uri = 'inmemory://single.sjon';
  didOpen(lsp, uri, '(+ 1 2)');

  const result = foldingRanges(lsp, uri);
  // Every span is single-line, so the transport drops them all.
  assert.deepEqual(result, []);
});

test('foldingRange: nested multi-line forms are reported outermost-first', async () => {
  const lsp = await makeLsp();
  const uri = 'inmemory://nested.sjon';
  didOpen(lsp, uri, '(a\n  (b\n    1))');

  const result = foldingRanges(lsp, uri);
  assert.ok(Array.isArray(result));
  assert.equal(result.length, 2);
  assert.ok(isWireFold(result[0]) && isWireFold(result[1]));
  // Outer form spans lines 0..2; the inner `(b ...)` spans 1..2.
  assert.deepEqual(result[0], { startLine: 0, endLine: 2 });
  assert.deepEqual(result[1], { startLine: 1, endLine: 2 });
});

test('foldingRange: an unknown document URI returns null', async () => {
  const lsp = await makeLsp();
  // Never opened.
  const result = foldingRanges(lsp, 'inmemory://does-not-exist.sjon');
  assert.equal(result, null);
});

test('foldingRange: each range carries exactly startLine + endLine', async () => {
  const lsp = await makeLsp();
  const uri = 'inmemory://shape.sjon';
  didOpen(lsp, uri, '(a\n  (b\n    1))');

  const result = foldingRanges(lsp, uri);
  assert.ok(Array.isArray(result));
  assert.ok(result.length > 0);
  for (const item of result) {
    assert.ok(item !== null && typeof item === 'object');
    const keys = Object.keys(item as Record<string, unknown>).sort();
    // No `startCharacter` / `endCharacter` / `kind` — the line-only contract.
    assert.deepEqual(keys, ['endLine', 'startLine']);
  }
});

test('foldingRange: folds appear after a single-line doc grows multi-line', async () => {
  const lsp = await makeLsp();
  const uri = 'inmemory://grow.sjon';
  didOpen(lsp, uri, '(+ 1 2)');
  assert.deepEqual(foldingRanges(lsp, uri), []);

  // Edit the document so the form now straddles three lines.
  didChange(lsp, uri, 2, '(+\n 1\n 2)');
  const result = foldingRanges(lsp, uri);
  assert.ok(Array.isArray(result));
  assert.equal(result.length, 1);
  assert.ok(isWireFold(result[0]));
  assert.deepEqual(result[0], { startLine: 0, endLine: 2 });
});
