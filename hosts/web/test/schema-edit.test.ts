// Plan-03 edit / write-back conformance (web / WASM side). The headline is
// trivia preservation: the engine's `.full` re-print keeps comments/formatting
// OUTSIDE the edited subtree, so `open → mutate → save` beats re-create. Also
// covers the stateful handle, the patch differ, validate-on-save, and the
// SjonEditError remapping — all over the real engine.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonHost } from '../SjonHost.ts';
import { createWasmBackend } from '../SjonSchemaBackend.ts';
import { SjonEditError, SjonValidationError, edit, s } from '@sjon/schema';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');

let cached: ReturnType<typeof createWasmBackend> | null = null;
async function getBackend() {
  if (!cached) cached = createWasmBackend(await SjonHost.load(wasmPath));
  return cached;
}

const Profile = s.form('profile', {
  handle: s.string(),
  score: s.number().optional(),
  bio: s.string().optional(),
});

// A document carrying comments the edit must NOT disturb.
const SRC = `(profile/profile
  ; the user's handle — keep this comment
  :handle "ada"
  :score 42
  :bio "hello")`;

test('setKey preserves comments outside the edited subtree (the headline)', async () => {
  const be = await getBackend();
  const out = Profile.setKey(SRC, 'handle', 'bob', { backend: be });
  assert.match(out, /; the user's handle — keep this comment/, 'comment survives');
  const parsed = Profile.parse(out, { backend: be });
  assert.equal(parsed.handle, 'bob');
  assert.equal(parsed.score, 42, 'untouched sibling preserved');
});

test('removeKey drops a key and keeps the rest + comments', async () => {
  const be = await getBackend();
  const out = Profile.removeKey(SRC, 'score', { backend: be });
  assert.match(out, /; the user's handle/);
  const parsed = Profile.parse(out, { backend: be });
  assert.equal('score' in parsed, false);
  assert.equal(parsed.handle, 'ada');
});

test('the stateful handle applies chained edits and preserves trivia', async () => {
  const be = await getBackend();
  const doc = Profile.open(SRC, { backend: be }).set('handle', 'bob').remove('score');
  // `.value` reflects the edits eagerly (no re-parse).
  assert.equal(doc.value.handle, 'bob');
  assert.equal('score' in doc.value, false);
  // `.save()` folds over the ORIGINAL source, so the comment survives.
  const out = doc.save();
  assert.match(out, /; the user's handle/);
  const parsed = Profile.parse(out, { backend: be });
  assert.equal(parsed.handle, 'bob');
  assert.equal('score' in parsed, false);
  assert.equal(parsed.bio, 'hello');
});

test('save({validate:true}) throws SjonValidationError on a schema-violating edit', async () => {
  const be = await getBackend();
  // The low-level escape hatch can set an ill-typed value; validate-on-save catches it.
  const doc = Profile.open(SRC, { backend: be }).edit(edit.setKey([], 'handle', 42));
  assert.throws(() => doc.save({ validate: true }), SjonValidationError);
  // Without validate, the (structurally fine) edit just applies.
  assert.equal(typeof doc.save(), 'string');
});

test('patch applies the minimal set of changed/new keys, comments intact', async () => {
  const be = await getBackend();
  const out = Profile.patch(SRC, { handle: 'carol', score: 99 }, { backend: be });
  assert.match(out, /; the user's handle/);
  const parsed = Profile.parse(out, { backend: be });
  assert.equal(parsed.handle, 'carol');
  assert.equal(parsed.score, 99);
  assert.equal(parsed.bio, 'hello', 'unmentioned key untouched');
});

test('a bad edit path maps to SjonEditError (throwing + safe variants)', async () => {
  const be = await getBackend();
  const badPath = edit.replace(['no-such-key'], 1);
  let thrown: unknown;
  try {
    Profile.applyEdit(SRC, badPath, { backend: be });
  } catch (e) {
    thrown = e;
  }
  assert.ok(thrown instanceof SjonEditError, 'throws a typed SjonEditError');
  assert.equal(typeof (thrown as SjonEditError).code, 'string');
  const safe = Profile.safeApplyEdit(SRC, badPath, { backend: be });
  assert.equal(safe.success, false);
  if (!safe.success) assert.equal(typeof safe.error.code, 'string');
});

// A document the parser only *recovered*: two unclosed roots come back as one
// nested form, which the engine used to edit and hand back without a word.
const BROKEN = '(scene :w 800\n(camera :fov 60\n';

test('both edit exports refuse a document that does not parse', async () => {
  const be = await getBackend();
  const action = edit.setKey([], 'h', 600);

  for (const [label, run] of [
    ['sjon_apply_edit', () => be.applyEdit!(BROKEN, action)],
    ['sjon_apply_edits', () => be.applyEdits!(BROKEN, [action])],
    // An empty batch still re-prints, so it still refuses.
    ['sjon_apply_edits (empty)', () => be.applyEdits!(BROKEN, [])],
  ] as const) {
    let thrown: unknown;
    try {
      run();
    } catch (e) {
      thrown = e;
    }
    assert.ok(thrown instanceof Error, `${label} throws`);
    // The framed name crosses the envelope unchanged, so a host reads
    // `ParseErrors` with no mapping of its own.
    assert.match((thrown as Error).message, /ParseErrors/, label);
  }
});

// --- Batched edits (sjon_apply_edits) --------------------------------------

test('backend.applyEdits is wired (the batched capability is present)', async () => {
  const be = await getBackend();
  assert.equal(typeof be.applyEdits, 'function', 'WASM backend exposes batched edits');
});

test('one batched applyEdits call == threading applyEdit per action', async () => {
  const be = await getBackend();
  const actions = [
    edit.setKey([], 'handle', 'bob'),
    edit.setKey([], 'score', 7),
    edit.removeKey([], 'bio'),
  ];
  const batched = be.applyEdits!(SRC, actions);
  let folded = SRC;
  for (const a of actions) folded = be.applyEdit!(folded, a);
  assert.equal(batched, folded, 'batched fold is observably identical to per-action');
  assert.match(batched, /; the user's handle/, 'trivia outside the edits survives the batch');
  const parsed = Profile.parse(batched, { backend: be });
  assert.equal(parsed.handle, 'bob');
  assert.equal(parsed.score, 7);
  assert.equal('bio' in parsed, false);
});

test('layout: preserve moves only the edited span; reprint re-lays the document', async () => {
  const be = await getBackend();
  const actions = [edit.setKey([], 'score', 7)];

  const spliced = be.applyEdits!(SRC, actions, { layout: 'preserve' });
  // Every line but the edited one is byte-identical, comment included.
  const before = SRC.split('\n');
  const after = spliced.split('\n');
  assert.equal(after.length, before.length, 'no line was added or removed');
  for (const [i, line] of before.entries()) {
    if (line.includes(':score')) continue;
    assert.equal(after[i], line, `line ${i} untouched`);
  }
  assert.match(spliced, /:score 7/);

  // The default stays the re-print, which is free to move those bytes.
  const reprinted = be.applyEdits!(SRC, actions);
  assert.equal(reprinted, be.applyEdits!(SRC, actions, { layout: 'reprint' }));
  assert.notEqual(reprinted, spliced, 'the two layouts are not the same bytes');
  assert.equal(Profile.parse(spliced, { backend: be }).score, 7);
});

test('patch routes a multi-key change through the batched path', async () => {
  const be = await getBackend();
  // Two keys differ → diffToActions yields two actions → applyAll takes the
  // batched path. Result must match the equivalent per-action fold.
  const out = Profile.patch(SRC, { handle: 'carol', score: 99 }, { backend: be });
  const folded = be.applyEdits!(SRC, [
    edit.setKey([], 'handle', 'carol'),
    edit.setKey([], 'score', 99),
  ]);
  assert.equal(out, folded);
  assert.match(out, /; the user's handle/);
});

test('a bad action inside a batch still surfaces SjonEditError', async () => {
  const be = await getBackend();
  // open → queue a good edit then a bad-path one → save folds the batch.
  // The batched call fails, applyAll falls back to the per-action fold, and
  // the offending action surfaces as a typed SjonEditError.
  const doc = Profile.open(SRC, { backend: be })
    .set('handle', 'bob')
    .edit(edit.replace(['no-such-key'], 1));
  assert.throws(() => doc.save(), SjonEditError);
});

// --- The forest ops (insert_root / remove_root) -----------------------------

test('insert_root and remove_root reach the document root list through WASM', async () => {
  const be = await getBackend();
  // A two-root document with the author's own blank line between the roots.
  const forest = '(use-plugin "core")\n\n(profile/profile :handle "ada")';

  const appended = be.applyEdits!(forest, [edit.insertRoot({ $form: 'note', text: 'hi' })], {
    layout: 'preserve',
  });
  assert.equal(
    appended,
    '(use-plugin "core")\n\n(profile/profile :handle "ada")\n\n(note :text "hi")',
    'the blank line the document already uses comes back on the insert',
  );

  // A removed root takes the run that *precedes* it, so removing the first
  // one leaves the blank line that followed it — the same shape as removing
  // a form's first child. `sjon fmt` is the tidy-up.
  const removed = be.applyEdits!(forest, [edit.removeRoot(0)], { layout: 'preserve' });
  assert.equal(removed, '\n\n(profile/profile :handle "ada")');

  // Remove-then-insert in one batch is a replace, and it round-trips a
  // document all the way to none and back.
  const replaced = be.applyEdits!('(only)\n', [
    edit.removeRoot(0),
    edit.insertRoot({ $form: 'fresh' }),
  ]);
  assert.equal(replaced, '(fresh)\n');
});

test('the forest ops refuse a path — the engine says so, not the type alone', async () => {
  const be = await getBackend();
  // `edit.insertRoot` cannot spell this, which is the point of the type; a
  // hand-written action can, and the engine refuses it rather than dropping
  // the field.
  assert.throws(
    () => be.applyEdits!('(a)', [{ op: 'insert_root', path: [], value: 1 } as never]),
    /InvalidPath/,
  );
});
