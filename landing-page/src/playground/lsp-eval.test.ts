// Headless unit tests for the evaluated-output mapper. The unit is the pure
// projection: `sjon/evalDocument` entries → the rows the output panel paints.
// Fixtures mirror the wasm serializer's shape (wasm.zig `appendEvalEntries`):
// every entry carries a `range` plus exactly one of `value` / `error`.
// Run with `node --test --experimental-strip-types`.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { EditorState } from '@codemirror/state';
import type { Text } from '@codemirror/state';

import { evalEntriesToRows, type LspEvalEntry } from './lsp-eval.ts';

//                     0         1         2         3
//                     0123456789012345678901234567890123
const SRC = '(+ 2 3)\n(let [x 1]\n  (vec2 x 2))';

function docOf(text: string): Text {
  return EditorState.create({ doc: text }).doc;
}

function entry(
  range: [number, number, number, number],
  outcome: { value: string } | { error: string },
): LspEvalEntry {
  const [sl, sc, el, ec] = range;
  return {
    range: { start: { line: sl, character: sc }, end: { line: el, character: ec } },
    ...outcome,
  };
}

test('maps evalDocument entries to panel rows', () => {
  const doc = docOf(SRC);
  const rows = evalEntriesToRows(doc, [
    entry([0, 0, 0, 7], { value: '5' }),
    entry([1, 0, 2, 13], { value: '[1 2]' }),
  ]);

  assert.deepEqual(
    rows.map((r) => [r.label, r.kind, r.text]),
    [
      ['1', 'value', '5'],
      // A root spanning several lines is labelled by its range, not by its
      // first line — the panel row has to be findable in the editor beside it.
      ['2–3', 'value', '[1 2]'],
    ],
  );

  // Offsets target the whole expression: clicking a row selects what produced
  // the value.
  assert.deepEqual([rows[0]?.from, rows[0]?.to], [0, 7]);
  assert.equal(doc.sliceString(rows[1]?.from ?? 0, rows[1]?.to ?? 0), '(let [x 1]\n  (vec2 x 2))');
});

test('renders error-kind entries as muted rows, not values', () => {
  const doc = docOf(SRC);
  const rows = evalEntriesToRows(doc, [
    entry([0, 0, 0, 7], { error: 'invalid' }),
    entry([1, 0, 2, 13], { error: 'limit' }),
  ]);

  // `kind` is what the renderer styles on, and no row carries a value: a
  // failure and a stale value must never appear together.
  assert.deepEqual(
    rows.map((r) => r.kind),
    ['error', 'error'],
  );
  assert.deepEqual(
    rows.map((r) => r.text),
    ['has errors', 'too large to evaluate'],
  );
});

test('panel model empty for docs with no expressions', () => {
  // A document of pure data yields no entries at all — the panel's empty
  // state, not a panel of empty rows.
  assert.deepEqual(evalEntriesToRows(docOf('(scene :name "a")'), []), []);
});

test('an unknown failure tag still reads as a reason, never as undefined', () => {
  // `Handler.EvalEntry.Failure` tags are wire identifiers: append-only, so a
  // server newer than this page can send one this mapper has never seen.
  const rows = evalEntriesToRows(docOf(SRC), [entry([0, 0, 0, 7], { error: 'quantum' })]);
  assert.equal(rows[0]?.kind, 'error');
  assert.equal(rows[0]?.text, 'not evaluated');
});

test('entries missing both value and error are dropped', () => {
  // Exactly one of the two is always present in practice; a row with neither
  // has nothing to show, and showing it blank would read as "evaluated to
  // nothing".
  const rows = evalEntriesToRows(docOf(SRC), [
    { range: { start: { line: 0, character: 0 }, end: { line: 0, character: 7 } } },
    entry([0, 0, 0, 7], { value: '5' }),
  ] as LspEvalEntry[]);
  assert.equal(rows.length, 1);
  assert.equal(rows[0]?.text, '5');
});

test('rows clamp to a document the response has fallen behind', () => {
  // The panel refreshes on the diagnostics debounce, so a batch can outlive
  // the text it describes by a keystroke.
  const rows = evalEntriesToRows(docOf('(+ 1 2)'), [entry([9, 0, 9, 4], { value: '3' })]);
  assert.deepEqual([rows[0]?.from, rows[0]?.to], [7, 7]);
});
