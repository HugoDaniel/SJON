// Headless unit tests for the document-outline mapper. The unit is the pure
// flatten: nested LSP DocumentSymbols → the indented, offset-carrying rows the
// outline strip renders. Run with `node --test --experimental-strip-types`.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { EditorState } from '@codemirror/state';
import type { Text } from '@codemirror/state';

import { flattenSymbols, type LspDocumentSymbol } from './lsp-outline.ts';

const SRC = '(scene :name "a"\n  (clip :name "b"))';

function docOf(text: string): Text {
  return EditorState.create({ doc: text }).doc;
}

function sym(
  name: string,
  range: [number, number, number, number],
  selection: [number, number, number, number],
  children: LspDocumentSymbol[] = [],
): LspDocumentSymbol {
  const [rsl, rsc, rel, rec] = range;
  const [ssl, ssc, sel, sec] = selection;
  return {
    name,
    kind: 9,
    range: { start: { line: rsl, character: rsc }, end: { line: rel, character: rec } },
    selectionRange: { start: { line: ssl, character: ssc }, end: { line: sel, character: sec } },
    children,
  };
}

test('flattens nested document symbols into indented outline entries', () => {
  const doc = docOf(SRC);
  const tree = [
    sym('scene', [0, 0, 1, 18], [0, 1, 0, 6], [sym('clip', [1, 2, 1, 17], [1, 3, 1, 7])]),
  ];

  const rows = flattenSymbols(doc, tree);
  assert.deepEqual(
    rows.map((r) => [r.name, r.depth]),
    [
      ['scene', 0],
      ['clip', 1],
    ],
  );
});

test('outline entry click target is the symbol’s selectionRange', () => {
  // The row must reveal the *name*, not select the whole form — a click that
  // selected the entire subtree would replace the user's selection with
  // something they cannot see the end of.
  const doc = docOf(SRC);
  const rows = flattenSymbols(doc, [sym('scene', [0, 0, 1, 18], [0, 1, 0, 6])]);

  const row = rows[0];
  assert.ok(row);
  assert.deepEqual([row.from, row.to], [1, 6]); // "scene", not the form.
  assert.equal(doc.sliceString(row.from, row.to), 'scene');
});

test('flatten preserves document order across sibling subtrees', () => {
  const doc = docOf('(a)\n(b (c))\n(d)');
  const rows = flattenSymbols(doc, [
    sym('a', [0, 0, 0, 3], [0, 1, 0, 2]),
    sym('b', [1, 0, 1, 7], [1, 1, 1, 2], [sym('c', [1, 3, 1, 6], [1, 4, 1, 5])]),
    sym('d', [2, 0, 2, 3], [2, 1, 2, 2]),
  ]);
  assert.deepEqual(
    rows.map((r) => `${'  '.repeat(r.depth)}${r.name}`),
    ['a', 'b', '  c', 'd'],
  );
});

test('flatten tolerates a malformed or empty symbol list', () => {
  const doc = docOf(SRC);
  assert.deepEqual(flattenSymbols(doc, []), []);
  assert.deepEqual(
    flattenSymbols(doc, [{ name: 'no ranges' } as unknown as LspDocumentSymbol]),
    [],
  );
});
