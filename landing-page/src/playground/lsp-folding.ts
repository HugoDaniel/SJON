/**
 * Code-folding extension for the SJON playground editor.
 *
 * Framework-only: this module never touches the LSP transport. It owns a
 * StateField holding the fold ranges last reported by the server and a
 * `foldService` that turns those ranges into CodeMirror folds. The LSP layer
 * (`lsp-integration.ts`) pushes ranges in through `setFoldRanges`, mirroring
 * how `completionSource` keeps `codemirror-setup.ts` LSP-free.
 *
 * The server (`textDocument/foldingRange`) emits 0-based `{startLine, endLine}`
 * pairs with single-line spans already filtered out. We map each to a CM
 * `{from, to}` byte range and let CodeMirror's own `foldState` own the
 * collapsed/expanded bits — so re-pushing ranges on every keystroke never
 * disturbs what the user has folded.
 */

import { StateField, StateEffect } from '@codemirror/state';
import type { EditorState, Extension } from '@codemirror/state';
import { foldService, foldGutter, codeFolding, foldKeymap } from '@codemirror/language';
import { keymap } from '@codemirror/view';
import type { EditorView } from '@codemirror/view';

/** A foldable region as the server reports it: 0-based, inclusive line span. */
export interface FoldRange {
  startLine: number;
  endLine: number;
}

/** Effect carrying the latest server-reported fold ranges into the field. */
export const setFoldsEffect = StateEffect.define<readonly FoldRange[]>();

/**
 * Holds the fold ranges from the most recent `textDocument/foldingRange`.
 * Replaced wholesale on each `setFoldsEffect`; this is *not* the collapsed
 * state (that lives in CodeMirror's `foldState`), only the catalogue of what
 * *can* be folded.
 */
export const foldRangesField = StateField.define<readonly FoldRange[]>({
  create: () => [],
  update(value, tr) {
    for (const e of tr.effects) {
      if (e.is(setFoldsEffect)) return e.value;
    }
    return value;
  },
});

/**
 * Map one server fold range to a CodeMirror byte range, or null when it can't
 * be applied to `state`'s current document. Pure — exported for unit tests.
 *
 * The fold runs from the *end* of the start line (so the form head stays
 * visible behind the `…` placeholder) through the end of the last line. LSP
 * lines are 0-based; CM's `doc.line()` is 1-based. `endLine` is clamped to the
 * document's last line in case the doc shrank since the range was computed.
 */
export function lspFoldToCmRange(
  state: EditorState,
  r: FoldRange,
): { from: number; to: number } | null {
  // The server already drops single-line spans; guard defensively.
  if (r.endLine <= r.startLine) return null;
  const lastLine = state.doc.lines - 1; // 0-based index of the final line.
  if (r.startLine < 0 || r.startLine > lastLine) return null;
  const endLine = Math.min(r.endLine, lastLine);
  // Clamping may have collapsed the span onto (or behind) its start line.
  if (endLine <= r.startLine) return null;
  return {
    from: state.doc.line(r.startLine + 1).to,
    to: state.doc.line(endLine + 1).to,
  };
}

/** Consults `foldRangesField`: a line is foldable iff a range starts on it. */
const sjonFoldService = foldService.of((state, lineStart) => {
  const lineNo = state.doc.lineAt(lineStart).number - 1;
  for (const r of state.field(foldRangesField)) {
    if (r.startLine === lineNo) return lspFoldToCmRange(state, r);
  }
  return null;
});

/** Push a fresh set of server fold ranges into `view`. */
export function setFoldRanges(view: EditorView, ranges: readonly FoldRange[]): void {
  view.dispatch({ effects: setFoldsEffect.of(ranges) });
}

/**
 * The full folding bundle: the range field, CodeMirror's fold state +
 * gutter, the SJON fold service, and the fold keymap (Ctrl-Shift-[ / ]).
 *
 * `foldGutter` only rebuilds its chevron markers on doc / viewport / fold-state
 * / syntax-tree changes — NOT when an arbitrary StateField updates. Our server
 * ranges arrive via `setFoldsEffect` on a transaction with no doc change, so
 * without `foldingChanged` the gutter would show no fold markers until the next
 * unrelated edit or cursor move. The hook recomputes markers exactly when
 * `foldRangesField` changes (i.e. when a fresh `foldingRange` response lands).
 */
export const sjonFoldingExtension: Extension = [
  foldRangesField,
  codeFolding(),
  foldGutter({
    foldingChanged: (update) =>
      update.startState.field(foldRangesField) !== update.state.field(foldRangesField),
  }),
  sjonFoldService,
  keymap.of(foldKeymap),
];
