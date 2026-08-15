// Headless unit tests for the inlay-hint mapper and its decoration field.
// The pure unit is `inlayHintsToWidgets` (LSP positions → document offsets +
// render flags); the field is exercised through an EditorState, no DOM.
// Run with `node --test --experimental-strip-types`.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { EditorState } from '@codemirror/state';
import type { Text } from '@codemirror/state';

import {
  inlayHintsToWidgets,
  inlayHintsField,
  setInlayHintsEffect,
  sjonInlayHintsExtension,
  type LspInlayHint,
} from './lsp-inlays.ts';

const SRC = '(clip :name "a")';

function docOf(text: string): Text {
  return EditorState.create({ doc: text }).doc;
}

function hint(character: number, label: string, extra: Partial<LspInlayHint> = {}): LspInlayHint {
  return { position: { line: 0, character }, label, ...extra };
}

test('maps inlay hints to positioned widget specs', () => {
  const doc = docOf(SRC);
  const specs = inlayHintsToWidgets(doc, [
    hint(15, ':fps 60', { kind: 2, paddingLeft: true }),
    hint(1, 'clip', { kind: 1 }),
  ]);

  assert.deepEqual(specs, [
    { offset: 15, label: ':fps 60', kind: 2, paddingLeft: true, paddingRight: false },
    { offset: 1, label: 'clip', kind: 1, paddingLeft: false, paddingRight: false },
  ]);
});

test('inlay hint padding flags default to false when the server omits them', () => {
  // The wasm serializer emits paddingLeft/paddingRight only when true, so
  // "absent" is the common case and must not read as undefined downstream.
  const [spec] = inlayHintsToWidgets(docOf(SRC), [hint(5, 'x')]);
  assert.equal(spec?.paddingLeft, false);
  assert.equal(spec?.paddingRight, false);
  assert.equal(spec?.kind, null);
});

test('inlay hints clamp to the document and drop malformed entries', () => {
  const doc = docOf(SRC);
  const specs = inlayHintsToWidgets(doc, [
    hint(999, 'past the end'),
    { label: 'no position' } as unknown as LspInlayHint,
    { position: { line: 0, character: 2 } } as unknown as LspInlayHint,
  ]);
  assert.deepEqual(
    specs.map((s) => [s.offset, s.label]),
    [[doc.length, 'past the end']],
  );
});

test('inlayHintsField holds specs until an effect replaces them', () => {
  const state = EditorState.create({ doc: SRC, extensions: [sjonInlayHintsExtension] });
  assert.deepEqual(state.field(inlayHintsField).specs, []);

  const specs = inlayHintsToWidgets(state.doc, [hint(15, ':fps 60', { paddingLeft: true })]);
  const next = state.update({ effects: setInlayHintsEffect.of(specs) }).state;
  assert.equal(next.field(inlayHintsField).specs.length, 1);
  assert.equal(next.field(inlayHintsField).decorations.size, 1);
});

test('inlay decorations survive a document change by mapping through it', () => {
  // Hints refresh on the diagnostics debounce, so between refreshes an edit
  // must move them rather than leave them pinned to stale offsets.
  const state = EditorState.create({ doc: SRC, extensions: [sjonInlayHintsExtension] });
  const specs = inlayHintsToWidgets(state.doc, [hint(15, ':fps 60')]);
  const withHints = state.update({ effects: setInlayHintsEffect.of(specs) }).state;

  const edited = withHints.update({ changes: { from: 0, to: 0, insert: 'XX' } }).state;
  const ranges = edited.field(inlayHintsField).decorations;
  const iter = ranges.iter();
  assert.equal(iter.from, 17); // 15 + the two inserted characters.
});
