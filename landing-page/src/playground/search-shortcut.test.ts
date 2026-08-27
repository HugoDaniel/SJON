// The one keyboard collision between the editor and the site around it.
//
// Starlight's search modal binds `(meta|ctrl)+k` on `window`; on macOS
// CodeMirror binds `Ctrl-k` to `deleteToLineEnd`. CodeMirror calls
// `preventDefault` on a key it handled but not `stopPropagation`, so without
// the guard one `Ctrl-K` in the editor does both things at once.
//
// The predicate is the whole fix, and it is easy to over-apply: swallowing
// `Cmd-K`, or swallowing `Ctrl-K` off macOS, takes away a shortcut rather than
// fixing one.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isEditorSearchShortcutCollision } from './search-shortcut.ts';

const key = (over: Partial<{ ctrlKey: boolean; metaKey: boolean; key: string }> = {}) => ({
  ctrlKey: false,
  metaKey: false,
  key: 'k',
  ...over,
});

test('Ctrl-K on macOS belongs to the editor', () => {
  assert.equal(isEditorSearchShortcutCollision(key({ ctrlKey: true }), true), true);
});

test('Ctrl-K off macOS belongs to search', () => {
  // Nothing in the editor claims it there, and it is the shortcut Starlight
  // advertises — swallowing it would remove the only keyboard route to search.
  assert.equal(isEditorSearchShortcutCollision(key({ ctrlKey: true }), false), false);
});

test('Cmd-K always belongs to search', () => {
  assert.equal(isEditorSearchShortcutCollision(key({ metaKey: true }), true), false);
  assert.equal(isEditorSearchShortcutCollision(key({ metaKey: true }), false), false);
});

test('Ctrl-Cmd-K is left alone', () => {
  assert.equal(isEditorSearchShortcutCollision(key({ ctrlKey: true, metaKey: true }), true), false);
});

test('other keys are left alone', () => {
  for (const k of ['j', 'K', 'Enter', 'ArrowDown']) {
    assert.equal(
      isEditorSearchShortcutCollision(key({ ctrlKey: true, key: k }), true),
      false,
      `Ctrl-${k} should not be swallowed`,
    );
  }
});

test('an unmodified k is left alone', () => {
  assert.equal(isEditorSearchShortcutCollision(key(), true), false);
});
