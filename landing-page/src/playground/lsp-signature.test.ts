// Headless unit tests for the SJON signature-help bridge. No DOM: the pure
// mapping (`isLspSignatureHelp`, `activeParamRange`, `splitSignatureLabel`) and
// the `signatureField` StateField/effect semantics are exercised against a bare
// `EditorState`. The tooltip DOM (`create`) is never invoked here — it's covered
// by the e2e wire test. Run with `node --test --experimental-strip-types`.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { EditorState } from '@codemirror/state';

import {
  isLspSignatureHelp,
  activeParamRange,
  splitSignatureLabel,
  signatureField,
  setSignatureEffect,
  type LspSignatureHelp,
} from './lsp-signature.ts';

const HELP: LspSignatureHelp = {
  signatures: [
    { label: 'mix3 number number number', parameters: [{ label: [5, 11] }, { label: [12, 18] }] },
  ],
  activeSignature: 0,
  activeParameter: 1,
};

// ----- isLspSignatureHelp ---------------------------------------------------

test('isLspSignatureHelp accepts the server shape', () => {
  assert.ok(isLspSignatureHelp(HELP));
  // activeParameter is optional.
  assert.ok(
    isLspSignatureHelp({
      signatures: [{ label: 'f', parameters: [] }],
      activeSignature: 0,
    }),
  );
});

test('isLspSignatureHelp rejects malformed values', () => {
  assert.equal(isLspSignatureHelp(null), false);
  assert.equal(isLspSignatureHelp({}), false);
  assert.equal(isLspSignatureHelp({ signatures: 'no', activeSignature: 0 }), false);
  assert.equal(isLspSignatureHelp({ signatures: [], activeSignature: '0' }), false);
  // A parameter whose label isn't a 2-number tuple.
  assert.equal(
    isLspSignatureHelp({
      signatures: [{ label: 'f', parameters: [{ label: [1] }] }],
      activeSignature: 0,
    }),
    false,
  );
});

// ----- activeParamRange -----------------------------------------------------

test('activeParamRange returns the active parameter tuple', () => {
  assert.deepEqual(activeParamRange(HELP), [12, 18]);
});

test('activeParamRange is null when there is no active parameter', () => {
  const noActive: LspSignatureHelp = { signatures: HELP.signatures, activeSignature: 0 };
  assert.equal(activeParamRange(noActive), null);
});

test('activeParamRange is null when the index is out of range', () => {
  assert.equal(activeParamRange({ ...HELP, activeParameter: 9 }), null);
  assert.equal(activeParamRange({ ...HELP, activeSignature: 3 }), null);
});

// ----- splitSignatureLabel --------------------------------------------------

test('splitSignatureLabel slices the label around the active param', () => {
  assert.deepEqual(splitSignatureLabel('mix3 number number number', [5, 11]), {
    before: 'mix3 ',
    active: 'number',
    after: ' number number',
  });
});

test('splitSignatureLabel with a null range puts the whole label in before', () => {
  assert.deepEqual(splitSignatureLabel('mix3 …', null), {
    before: 'mix3 …',
    active: '',
    after: '',
  });
});

test('splitSignatureLabel clamps an out-of-bounds range to the label length', () => {
  assert.deepEqual(splitSignatureLabel('abc', [1, 99]), { before: 'a', active: 'bc', after: '' });
  assert.deepEqual(splitSignatureLabel('abc', [99, 99]), { before: 'abc', active: '', after: '' });
});

// ----- signatureField -------------------------------------------------------

test('signatureField holds null until an effect sets it, then clears', () => {
  const state = EditorState.create({ doc: 'hello', extensions: [signatureField] });
  assert.equal(state.field(signatureField), null);

  const st = { help: HELP, pos: 3 };
  const set = state.update({ effects: setSignatureEffect.of(st) }).state;
  assert.equal(set.field(signatureField), st);

  const cleared = set.update({ effects: setSignatureEffect.of(null) }).state;
  assert.equal(cleared.field(signatureField), null);
});

test('signatureField remaps its anchor across a document change', () => {
  const state = EditorState.create({ doc: 'hello', extensions: [signatureField] });
  const set = state.update({ effects: setSignatureEffect.of({ help: HELP, pos: 3 }) }).state;

  // Insert two chars before the anchor — pos 3 maps to 5.
  const shifted = set.update({ changes: { from: 0, insert: 'xy' } }).state;
  const v = shifted.field(signatureField);
  assert.ok(v);
  assert.equal(v.pos, 5);
});
