// Wire-level characterization of `textDocument/completion` against the real
// `sjon-lsp.wasm`. Pins the contract lsp-completion.ts depends on: a *bare item
// array* (never a `CompletionList`), `documentation` as a plain string, and — in
// an expression-argument slot — snippet items (`insertTextFormat: 2`) whose
// `insertText` lspSnippetToCmTemplate rewrites. Serializer at `src/lsp/wasm.zig:
// 491-544`; heads-after-`(` behaviour at `Handler_tests.zig:181`. Characterization
// — green on arrival, no red.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeLsp, didOpen, isRecord } from './lsp-harness.ts';

const URI = 'inmemory://comp.sjon';

test('completion after `(` returns a bare array of core expression heads', async () => {
  const lsp = await makeLsp();
  didOpen(lsp, URI, '(');

  const result = lsp.request('textDocument/completion', {
    textDocument: { uri: URI },
    position: { line: 0, character: 1 },
  });
  // Bare array — not `{ isIncomplete, items }`.
  assert.ok(Array.isArray(result));
  assert.ok(result.length > 0);

  const plus = result.find((i) => isRecord(i) && i['label'] === '+');
  assert.ok(isRecord(plus), 'lists the `+` head');
  assert.equal(plus['kind'], 3, 'CompletionItemKind.Function');
  assert.equal(plus['detail'], 'expr (core)');
  assert.equal(typeof plus['documentation'], 'string');
});

test('completion in an expression slot offers snippet items', async () => {
  const lsp = await makeLsp();
  // Inside `(let …)` the head completions arrive as call snippets.
  didOpen(lsp, URI, '(let ');

  const result = lsp.request('textDocument/completion', {
    textDocument: { uri: URI },
    position: { line: 0, character: 5 },
  });
  assert.ok(Array.isArray(result));

  const plus = result.find((i) => isRecord(i) && i['label'] === '+');
  assert.ok(isRecord(plus));
  assert.equal(plus['insertText'], '(+ $1)');
  assert.equal(plus['insertTextFormat'], 2, 'LSP snippet format');
  // CM matches against filterText; the server sends the bare head.
  assert.equal(plus['filterText'], '+');
});
