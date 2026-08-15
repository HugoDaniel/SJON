// Headless unit tests for the SJON fold extension. No DOM: we build an
// `EditorState` directly and exercise the pure mapping (`lspFoldToCmRange`),
// the `foldRangesField` effect, and the `foldService` integration via
// `@codemirror/language`'s `foldable`. Run with
// `node --test --experimental-strip-types`.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { EditorState } from '@codemirror/state';
import { foldable } from '@codemirror/language';

import {
  lspFoldToCmRange,
  foldRangesField,
  setFoldsEffect,
  sjonFoldingExtension,
  type FoldRange,
} from './lsp-folding.ts';

const THREE_LINES = 'aaa\nbbb\nccc'; // line 1: 0..3, line 2: 4..7, line 3: 8..11

function stateWith(doc: string, ranges?: readonly FoldRange[]): EditorState {
  let state = EditorState.create({ doc, extensions: [sjonFoldingExtension] });
  if (ranges) state = state.update({ effects: setFoldsEffect.of(ranges) }).state;
  return state;
}

test('lspFoldToCmRange maps a 0-based span to end-of-first..end-of-last', () => {
  const state = stateWith(THREE_LINES);
  const r = lspFoldToCmRange(state, { startLine: 0, endLine: 2 });
  assert.deepEqual(r, { from: state.doc.line(1).to, to: state.doc.line(3).to });
  // Concretely: end of "aaa" (3) through end of "ccc" (11).
  assert.deepEqual(r, { from: 3, to: 11 });
});

test('foldService offers a fold only on a range start line', () => {
  const state = stateWith(THREE_LINES, [{ startLine: 0, endLine: 2 }]);
  const line0 = state.doc.line(1);
  const fold = foldable(state, line0.from, line0.to);
  assert.deepEqual(fold, { from: 3, to: 11 });
});

test('foldService offers nothing on a non-start line', () => {
  const state = stateWith(THREE_LINES, [{ startLine: 0, endLine: 2 }]);
  const line1 = state.doc.line(2); // 0-based line 1 — inside, not the start.
  assert.equal(foldable(state, line1.from, line1.to), null);
});

test('lspFoldToCmRange clamps endLine past EOF and rejects out-of-range start', () => {
  const state = stateWith(THREE_LINES);
  // endLine well past the last line clamps to the final line.
  assert.deepEqual(lspFoldToCmRange(state, { startLine: 0, endLine: 99 }), {
    from: 3,
    to: 11,
  });
  // A start line beyond the document is not foldable.
  assert.equal(lspFoldToCmRange(state, { startLine: 5, endLine: 9 }), null);
});

test('setFoldsEffect replaces the field contents wholesale', () => {
  const first: readonly FoldRange[] = [{ startLine: 0, endLine: 2 }];
  const state = stateWith(THREE_LINES, first);
  assert.deepEqual(state.field(foldRangesField), first);

  const next: readonly FoldRange[] = [{ startLine: 1, endLine: 2 }];
  const updated = state.update({ effects: setFoldsEffect.of(next) }).state;
  assert.deepEqual(updated.field(foldRangesField), next);
});

test('field identity changes on a fold push but is stable otherwise', () => {
  // The foldGutter `foldingChanged` hook recomputes chevron markers only when
  // the field's reference changes across a transaction — so a setFoldsEffect
  // must yield a fresh reference, and a no-op transaction must not.
  const state = stateWith(THREE_LINES, [{ startLine: 0, endLine: 2 }]);
  const before = state.field(foldRangesField);

  const afterPush = state.update({
    effects: setFoldsEffect.of([{ startLine: 1, endLine: 2 }]),
  }).state;
  assert.notEqual(afterPush.field(foldRangesField), before); // ref changed → gutter recomputes

  const afterNoop = state.update({ selection: { anchor: 0 } }).state;
  assert.equal(afterNoop.field(foldRangesField), before); // ref stable → no needless recompute
});

test('lspFoldToCmRange rejects a single-line span (defensive guard)', () => {
  const state = stateWith(THREE_LINES);
  assert.equal(lspFoldToCmRange(state, { startLine: 1, endLine: 1 }), null);
});
