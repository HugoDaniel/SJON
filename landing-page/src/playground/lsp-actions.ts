/**
 * LSP code actions and TextEdits → CodeMirror.
 *
 * Framework-only, like `lsp-folding.ts`: this module never touches the LSP
 * transport, so it unit-tests headlessly against an `EditorState`. The wiring
 * layer (`lsp-integration.ts`) fetches the actions and hands them here.
 *
 * Two consumers share the TextEdit path: quick-fixes attached to lint
 * diagnostics, and the toolbar's Format button (`textDocument/formatting`
 * returns a bare `TextEdit[]`). They differ only in where the edits come
 * from, which is why `lspEditsToChanges` is the seam.
 */

import type { ChangeSpec, Text } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import type { Action as CmAction } from '@codemirror/lint';

import { rangeToOffsets } from './lsp-types.ts';
import type { LspDiagnostic, LspRange } from './lsp-types';

/** A `TextEdit` as the server serializes it: a range plus its replacement. */
export interface LspTextEdit {
  range: LspRange;
  newText: string;
}

/** The `WorkspaceEdit` subset the SJON server emits — always `changes`,
 *  keyed by document URI, never the `documentChanges` variant. */
export interface LspWorkspaceEdit {
  changes?: Record<string, LspTextEdit[]>;
}

/** A `textDocument/codeAction` result item. `edit` is optional in LSP (an
 *  action may carry a `command` instead); SJON only ever sends edits, and an
 *  action without them maps to nothing rather than to a no-op menu entry. */
export interface LspCodeAction {
  title: string;
  kind?: string;
  isPreferred?: boolean;
  diagnostics?: LspDiagnostic[];
  edit?: LspWorkspaceEdit;
}

function isTextEdit(x: unknown): x is LspTextEdit {
  if (typeof x !== 'object' || x === null) return false;
  const e = x as { range?: unknown; newText?: unknown };
  if (typeof e.newText !== 'string') return false;
  const r = e.range as { start?: unknown; end?: unknown } | undefined;
  return typeof r === 'object' && r !== null && !!r.start && !!r.end;
}

/** Structural guard for one `textDocument/codeAction` item. */
export function isLspCodeAction(x: unknown): x is LspCodeAction {
  return typeof x === 'object' && x !== null && typeof (x as { title: unknown }).title === 'string';
}

/**
 * Map a server TextEdit list to CodeMirror change specs.
 *
 * **No sorting, and no back-to-front pass.** Both LSP and CodeMirror state
 * every edit's range against the document *as it was before any of them
 * applied*, and `ChangeSet.of` reconciles a batch given in any order — so
 * translating each range independently is already correct. Applying them
 * one-by-one instead (dispatch per edit) is what would need the reverse
 * ordering, and is exactly what this avoids.
 *
 * Edits that replace a span with what it already contains are dropped, so
 * "no edits" and "no effect" are the same answer to a caller.
 * `textDocument/formatting` returns one whole-document replacement every
 * time, changed or not; dispatching that unconditionally would push an undo
 * step and reset the selection each time the user pressed Format on
 * already-tidy source.
 */
export function lspEditsToChanges(doc: Text, edits: readonly LspTextEdit[]): ChangeSpec[] {
  const changes: ChangeSpec[] = [];
  for (const e of edits) {
    if (!isTextEdit(e)) continue;
    const { from, to } = rangeToOffsets(doc, e.range);
    if (doc.sliceString(from, to) === e.newText) continue;
    changes.push({ from, to, insert: e.newText });
  }
  return changes;
}

/**
 * The changes one code action makes to the document at `uri`, or null when it
 * makes none — no `edit` at all, an empty list, or a `changes` map that only
 * names *other* documents. The URI check is what keeps a schema-pane edit from
 * being applied to the main document; the SJON server scopes every action to
 * the document it was requested for, but a client that trusts that silently
 * corrupts the wrong buffer the day it stops being true.
 */
export function codeActionToChanges(
  doc: Text,
  action: LspCodeAction,
  uri: string,
): ChangeSpec[] | null {
  const edits = action.edit?.changes?.[uri];
  if (!Array.isArray(edits) || edits.length === 0) return null;
  const changes = lspEditsToChanges(doc, edits);
  return changes.length > 0 ? changes : null;
}

/** Apply a TextEdit list to `view` in a single transaction. Returns false when
 *  there was nothing to apply, so a caller can report "already formatted"
 *  rather than flashing an empty undo step. */
export function applyLspEdits(view: EditorView, edits: readonly LspTextEdit[]): boolean {
  const changes = lspEditsToChanges(view.state.doc, edits);
  if (changes.length === 0) return false;
  view.dispatch({ changes });
  return true;
}

/** Identity of a diagnostic for action-matching: its span plus its code.
 *  The server re-serializes the diagnostics an action fixes with the very
 *  same writer `textDocument/diagnostic` uses, so these keys line up exactly. */
function diagnosticKey(d: LspDiagnostic): string {
  const { start, end } = d.range;
  return `${start.line}:${start.character}-${end.line}:${end.character}#${d.code ?? ''}`;
}

/**
 * The lint actions belonging to one diagnostic.
 *
 * A code action names the diagnostics it fixes, so a whole-document
 * `codeAction` response can be fanned out across the lint entries in one
 * round-trip instead of one request per diagnostic. An action naming *no*
 * diagnostic is not a quick-fix at all — the materialize-defaults refactor is
 * offered from the cursor position — and has no lint entry to attach to, so
 * it is skipped here and surfaced through its own affordance.
 */
export function lintActionsFor(
  doc: Text,
  diagnostic: LspDiagnostic,
  actions: readonly LspCodeAction[],
  uri: string,
): CmAction[] {
  const key = diagnosticKey(diagnostic);
  const out: CmAction[] = [];
  for (const action of actions) {
    if (!action.diagnostics?.some((d) => diagnosticKey(d) === key)) continue;
    const changes = codeActionToChanges(doc, action, uri);
    // An action that maps to nothing never reaches the menu.
    if (changes === null) continue;
    out.push({
      name: action.title,
      apply: (view: EditorView) => {
        // The offsets in `changes` are the server's, stated against the
        // document it validated. Between that response landing and this
        // click the user may have typed — the sync is debounced, so a stale
        // batch can outlive its document by a keystroke or two. `Text` is
        // immutable and replaced on every change, so identity is an exact
        // "unchanged since mapping" test. Refusing is the whole point:
        // applying a rename at drifted offsets corrupts the document
        // silently, and the next validation pass re-offers the fix anyway.
        if (view.state.doc !== doc) return;
        view.dispatch({ changes });
      },
    });
  }
  return out;
}
