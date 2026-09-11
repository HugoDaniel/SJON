// Edit data model + gate — backend-free. The action builders, structural
// equality, and the differ are pure; the gate is checked with a validate-only
// backend (no `applyEdit`). The full engine round-trip (trivia preservation,
// real error mapping) lives in `hosts/web/test/schema-edit.test.ts`.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import * as edit from '../src/edit.ts';
import { diffToActions, sjonValueEqual } from '../src/edit.ts';
import * as s from '../src/builder.ts';
import { applyOne, requireEditBackend } from '../src/backend.ts';
import type { ValidateBackend } from '../src/backend.ts';
import type { SjonValue } from '../src/value.ts';

// --- Action builders --------------------------------------------------------

test('edit.* builders produce the engine action shapes', () => {
  assert.deepEqual(edit.setKey(['items', 0], 'done', true), {
    op: 'set_keyword',
    path: ['items', 0],
    key: 'done',
    value: true,
  });
  assert.deepEqual(edit.removeKey([], 'draft'), { op: 'remove_keyword', path: [], key: 'draft' });
  assert.deepEqual(edit.removeChild(['items'], 2), {
    op: 'remove_positional',
    path: ['items'],
    index: 2,
  });
});

test('insertChild omits `index` when appending, includes it when positioned', () => {
  const appended = edit.insertChild(['items'], 1);
  assert.equal('index' in appended, false);
  const positioned = edit.insertChild(['items'], 1, 0);
  assert.equal((positioned as { index?: number }).index, 0);
});

test('replace([], …) throws — the engine cannot replace the root', () => {
  assert.throws(() => edit.replace([], 1), /cannot replace the document root/);
  assert.deepEqual(edit.replace(['title'], 'x'), { op: 'replace', path: ['title'], value: 'x' });
});

test('wrap composes a node into a new parent, hole naming the slot', () => {
  assert.deepEqual(edit.wrap(['x'], { $form: '+', $children: [null, 0.1] }, [0]), {
    op: 'wrap',
    path: ['x'],
    value: { $form: '+', $children: [null, 0.1] },
    hole: [0],
  });
  // Unlike replace, an empty path is legal: wrapping the root is the point.
  assert.deepEqual(edit.wrap([], { $form: 'transform', $children: [null] }, [0]), {
    op: 'wrap',
    path: [],
    value: { $form: 'transform', $children: [null] },
    hole: [0],
  });
  // A string hole step names a kvpair key on the new parent.
  assert.deepEqual(edit.wrap([], { $form: 'outer', inner: null }, ['inner']), {
    op: 'wrap',
    path: [],
    value: { $form: 'outer', inner: null },
    hole: ['inner'],
  });
});

test('wrap(…, []) throws — a wrap with no hole would drop the node it wraps', () => {
  assert.throws(() => edit.wrap(['x'], { $form: 'w', $children: [null] }, []), /non-empty hole/);
});

test('atRoot points an action at one root of a multi-root document', () => {
  assert.deepEqual(edit.atRoot(edit.setKey([], 'bpm', 140), 1), {
    op: 'set_keyword',
    path: [],
    key: 'bpm',
    value: 140,
    root: 1,
  });
  // Builders produce root-less actions: omitting `root` is what makes the
  // engine refuse a multi-root document instead of guessing.
  assert.equal('root' in edit.setKey([], 'bpm', 140), false);
  // It composes with every op, wrap included, and overwrites rather than
  // stacking when applied twice.
  assert.deepEqual(edit.atRoot(edit.atRoot(edit.removeKey([], 'k'), 1), 2), {
    op: 'remove_keyword',
    path: [],
    key: 'k',
    root: 2,
  });
});

test('insertRoot / removeRoot address the root list, not a node inside a root', () => {
  assert.deepEqual(edit.insertRoot({ $form: 'camera', fov: 60 }), {
    op: 'insert_root',
    value: { $form: 'camera', fov: 60 },
  });
  assert.deepEqual(edit.insertRoot(1, 0), { op: 'insert_root', value: 1, index: 0 });
  assert.deepEqual(edit.removeRoot(2), { op: 'remove_root', index: 2 });
  // No `path`, ever — the engine refuses one, and `[]` would say "the root
  // form", which is the container a new root is a sibling of.
  assert.equal('path' in edit.insertRoot(1), false);
  assert.equal('path' in edit.removeRoot(0), false);
  // Appending omits `index` entirely (exactOptionalPropertyTypes).
  assert.equal('index' in edit.insertRoot(1), false);
});

// --- Structural equality ----------------------------------------------------

test('sjonValueEqual: scalars, branded atoms, arrays, key-order-independent forms', () => {
  assert.equal(sjonValueEqual(42, 42), true);
  assert.equal(sjonValueEqual(42, 43), false);
  assert.equal(sjonValueEqual({ $sym: 'a' }, { $sym: 'a' }), true);
  assert.equal(sjonValueEqual({ $sym: 'a' }, { $kw: 'a' }), false);
  assert.equal(sjonValueEqual({ $num: [90, 'deg'] }, { $num: [90, 'deg'] }), true);
  assert.equal(sjonValueEqual({ $num: [90, 'deg'] }, { $num: [91, 'deg'] }), false);
  assert.equal(sjonValueEqual([1, 2, 3], [1, 2, 3]), true);
  assert.equal(sjonValueEqual([1, 2], [1, 2, 3]), false);
  assert.equal(
    sjonValueEqual({ $form: 'p', x: 1, y: 2 }, { $form: 'p', y: 2, x: 1 }),
    true,
    'key order does not matter',
  );
  assert.equal(sjonValueEqual({ $form: 'p', x: 1 }, { $form: 'p', x: 1, y: 2 }), false);
});

// --- The differ -------------------------------------------------------------

test('diffToActions: only changed/new keys; undefined left alone; tags skipped', () => {
  const current: SjonValue = { $form: 'doc', $ns: 'd', title: 'old', count: 1, keep: true };
  const actions = diffToActions(current, {
    title: 'new', // changed → emit
    count: 1, // unchanged → skip
    added: 'z', // new → emit
    skip: undefined, // leave alone → skip
    $form: 'evil', // structural tag → skip
  });
  assert.deepEqual(actions, [
    { op: 'set_keyword', path: [], key: 'title', value: 'new' },
    { op: 'set_keyword', path: [], key: 'added', value: 'z' },
  ]);
});

// --- The WASM gate ----------------------------------------------------------

const validateOnly: ValidateBackend = { validate: () => ({ diagnostics: [] }) };

test('requireEditBackend throws a clear gate error without applyEdit', () => {
  assert.throws(() => requireEditBackend(validateOnly), /editing is WASM-gated/);
});

test('applyOne gates on a validate-only backend', () => {
  assert.throws(() => applyOne('(x)', edit.setKey([], 'a', 1), validateOnly), /WASM-gated/);
});

test('FormNode edit methods gate on a validate-only backend', () => {
  const Doc = s.form('doc', { title: s.string() });
  assert.throws(
    () => Doc.setKey('(doc :title "x")', 'title', 'y', { backend: validateOnly }),
    /WASM-gated/,
  );
  assert.throws(() => Doc.open('(doc :title "x")', { backend: validateOnly }), /WASM-gated/);
});
