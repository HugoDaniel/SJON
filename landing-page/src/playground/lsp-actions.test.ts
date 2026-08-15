// Headless unit tests for the LSP code-action / TextEdit mappers. No DOM:
// every assertion runs against an `EditorState`, so the pure mapping is the
// unit under test and the CodeMirror `Action.apply` closure is a thin wrapper
// over it. Run with `node --test --experimental-strip-types`.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { EditorState } from '@codemirror/state';
import type { Text } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';

import {
  codeActionToChanges,
  lintActionsFor,
  lspEditsToChanges,
  type LspCodeAction,
  type LspTextEdit,
} from './lsp-actions.ts';
import type { LspDiagnostic } from './lsp-types.ts';

const URI = 'inmemory://playground.sjon';
const OTHER_URI = 'inmemory://schema/0';

function docOf(text: string): Text {
  return EditorState.create({ doc: text }).doc;
}

/** Apply mapped changes to `text` and return the resulting document. */
function applied(text: string, action: LspCodeAction, uri = URI): string {
  const state = EditorState.create({ doc: text });
  const changes = codeActionToChanges(state.doc, action, uri);
  assert.ok(changes, 'expected the action to map to a changeset');
  return state.update({ changes }).state.doc.toString();
}

/** A single-line TextEdit, in the server's 0-based line/character shape. */
function edit(line: number, from: number, to: number, newText: string): LspTextEdit {
  return {
    range: { start: { line, character: from }, end: { line, character: to } },
    newText,
  };
}

function diag(line: number, from: number, to: number, code: string): LspDiagnostic {
  return {
    range: { start: { line, character: from }, end: { line, character: to } },
    severity: 1,
    code,
    message: code,
  };
}

function actionWith(
  title: string,
  edits: LspTextEdit[],
  diagnostics: LspDiagnostic[] = [],
): LspCodeAction {
  return { title, kind: 'quickfix', diagnostics, edit: { changes: { [URI]: edits } } };
}

test('maps LSP code actions to CodeMirror lint actions', () => {
  const doc = docOf('(clip :nme 1)');
  const d = diag(0, 6, 10, 'unknown_key');
  const actions: LspCodeAction[] = [actionWith('Rename to :name', [edit(0, 6, 10, ':name')], [d])];

  const lint = lintActionsFor(doc, d, actions, URI);
  assert.equal(lint.length, 1);
  assert.equal(lint[0]?.name, 'Rename to :name');
  assert.equal(typeof lint[0]?.apply, 'function');
});

test('maps LSP TextEdits to a CodeMirror changeset', () => {
  const out = applied('(clip :nme 1)', actionWith('fix', [edit(0, 6, 10, ':name')]));
  assert.equal(out, '(clip :name 1)');
});

test('applies every edit of a multi-edit action against original offsets', () => {
  // Deliberately out of document order: the server emits edits in whatever
  // order it walked the tree, and each range is stated against the document
  // as it was *before* any of them applied.
  const action = actionWith('materialize', [
    edit(0, 12, 12, ' :depth 3'),
    edit(0, 5, 5, ' :fps 60'),
  ]);
  assert.equal(applied('(clip :nme 1)', action), '(clip :fps 60 :nme 1 :depth 3)');
});

test('drops actions whose edits target another uri', () => {
  const doc = docOf('(clip :nme 1)');
  const foreign: LspCodeAction = {
    title: 'edit the schema instead',
    edit: { changes: { [OTHER_URI]: [edit(0, 0, 1, 'X')] } },
  };
  assert.equal(codeActionToChanges(doc, foreign, URI), null);
});

test('an action carrying no edits maps to nothing', () => {
  const doc = docOf('(clip :nme 1)');
  assert.equal(codeActionToChanges(doc, { title: 'command-only' }, URI), null);
  assert.equal(codeActionToChanges(doc, actionWith('empty', []), URI), null);
});

test('an edit that replaces a span with itself is dropped', () => {
  // textDocument/formatting answers with one whole-document replacement
  // whether or not anything changed, so "already formatted" arrives as a
  // full-size edit that must not reach the document.
  const src = '(clip :name 1)';
  const doc = docOf(src);
  const noop: LspTextEdit = {
    range: { start: { line: 0, character: 0 }, end: { line: 0, character: src.length } },
    newText: src,
  };
  assert.deepEqual(lspEditsToChanges(doc, [noop]), []);
  assert.equal(codeActionToChanges(doc, actionWith('reformat', [noop]), URI), null);
});

test('attaches an action only to the diagnostic it names', () => {
  const doc = docOf('(clip :nme 1)\n(clip :fp 2)');
  const first = diag(0, 6, 10, 'unknown_key');
  const second = diag(1, 6, 9, 'unknown_key');
  const actions: LspCodeAction[] = [
    actionWith('Rename to :name', [edit(0, 6, 10, ':name')], [first]),
    actionWith('Rename to :fps', [edit(1, 6, 9, ':fps')], [second]),
  ];

  assert.deepEqual(
    lintActionsFor(doc, first, actions, URI).map((a) => a.name),
    ['Rename to :name'],
  );
  assert.deepEqual(
    lintActionsFor(doc, second, actions, URI).map((a) => a.name),
    ['Rename to :fps'],
  );
});

/** A stand-in for the EditorView a lint action is handed: enough of one to
 *  observe whether `apply` dispatched, without a DOM. */
function fakeView(state: EditorState): { view: EditorView; dispatched: () => number } {
  let calls = 0;
  const view = {
    state,
    dispatch: () => {
      calls += 1;
    },
  };
  return { view: view as unknown as EditorView, dispatched: () => calls };
}

test('a fix applies its edits to the document it was mapped against', () => {
  const state = EditorState.create({ doc: '(clip :nme 1)' });
  const d = diag(0, 6, 10, 'unknown_key');
  const [fix] = lintActionsFor(
    state.doc,
    d,
    [actionWith('fix', [edit(0, 6, 10, ':name')], [d])],
    URI,
  );
  const { view, dispatched } = fakeView(state);
  fix?.apply(view, 6, 10);
  assert.equal(dispatched(), 1);
});

test('a fix declines to apply after the document has changed', () => {
  // The offsets belong to the document the server validated. If the user has
  // typed since, applying them would corrupt text they can see — the guard
  // makes the click a no-op and lets the next validation re-offer the fix.
  const state = EditorState.create({ doc: '(clip :nme 1)' });
  const d = diag(0, 6, 10, 'unknown_key');
  const [fix] = lintActionsFor(
    state.doc,
    d,
    [actionWith('fix', [edit(0, 6, 10, ':name')], [d])],
    URI,
  );
  const moved = state.update({ changes: { from: 0, to: 0, insert: '\n' } }).state;
  const { view, dispatched } = fakeView(moved);
  fix?.apply(view, 6, 10);
  assert.equal(dispatched(), 0);
});

test('a diagnostic-free action draws no lint action', () => {
  // The materialize-defaults refactor is offered from the cursor, not from a
  // diagnostic — it has no lint entry to hang off, so the gutter ignores it.
  const doc = docOf('(clip :name 1)');
  const d = diag(0, 6, 11, 'unknown_key');
  const loose: LspCodeAction = actionWith('Materialize defaults', [edit(0, 13, 13, ' :fps 60')]);
  assert.deepEqual(lintActionsFor(doc, d, [loose], URI), []);
});
