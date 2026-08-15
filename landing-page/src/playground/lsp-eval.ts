/**
 * Evaluated-output panel for the SJON playground.
 *
 * Framework-only, the `lsp-outline.ts` pattern: the pure mapper
 * `evalEntriesToRows` turns `sjon/evalDocument`'s entries into the rows the
 * panel paints, and `renderEvalRows` paints them. Neither touches the LSP
 * transport — `lsp-integration.ts` fetches, `boot.ts` composes.
 *
 * The server evaluates every *maximal* expression root in the document and
 * returns each one's range plus exactly one of `value` (rendered SJON text)
 * and `error` (a failure tag). Values arrive already rendered by the same
 * printer that feeds hover and the ghost-default inlay hints, so this module
 * deliberately does not re-format them: one value, one rendering, wherever it
 * appears.
 */

import type { Text } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';

import { rangeToOffsets } from './lsp-types.ts';
import type { LspRange } from './lsp-types';

/**
 * One entry of a `sjon/evalDocument` response. `value` and `error` are
 * alternatives, never both — the server emits whichever applies, so a client
 * switches on which key is present and cannot show a stale value beside a
 * failure.
 */
export interface LspEvalEntry {
  range: LspRange;
  value?: string;
  error?: string;
}

/** A row of the output panel: what it says, how to style it, and what
 *  clicking it selects. */
export interface EvalRow {
  /** Line number, or `start–end` when the root spans several lines. */
  label: string;
  /** `value` styles as a result; `error` styles muted. */
  kind: 'value' | 'error';
  /** The rendered value, or the reason there isn't one. */
  text: string;
  from: number;
  to: number;
}

/**
 * Human wording for a `Handler.EvalEntry.Failure` tag.
 *
 * The tags are wire identifiers and append-only, so a server newer than this
 * page can send one this table has never seen — the fallback keeps such a row
 * a *reason* rather than an `undefined`. The wordings say what the reader can
 * do about it: "has errors" points at the squiggles they can already see,
 * where the evaluator's own distinction between a type error and a trap would
 * not.
 */
const FAILURE_TEXT: Record<string, string> = {
  invalid: 'has errors',
  unsupported: 'no runtime for this plugin',
  limit: 'too large to evaluate',
  failed: 'evaluation failed',
};

const FAILURE_FALLBACK = 'not evaluated';

/** `11`, or `11–16` when the expression spans lines. Multi-line roots are
 *  ordinary in SJON — a `let` block is one expression — and labelling one by
 *  its first line alone makes it unfindable in the editor beside the panel. */
function lineLabel(doc: Text, from: number, to: number): string {
  const first = doc.lineAt(from).number;
  const last = doc.lineAt(to).number;
  return first === last ? String(first) : `${first}–${last}`;
}

/**
 * Project the server's entries onto panel rows, in document order.
 *
 * Offsets clamp to `doc` (`rangeToOffsets`), because the panel refreshes on
 * the diagnostics debounce and a batch can outlive the text it describes by a
 * keystroke — a row pointing past the end would throw on click.
 *
 * An entry carrying neither `value` nor `error` is dropped rather than shown
 * blank: an empty row reads as "this evaluated to nothing", which is a claim
 * the response never made.
 */
export function evalEntriesToRows(doc: Text, entries: readonly LspEvalEntry[]): EvalRow[] {
  const rows: EvalRow[] = [];
  for (const e of entries) {
    if (!e || !e.range || !e.range.start || !e.range.end) continue;
    const { from, to } = rangeToOffsets(doc, e.range);
    const label = lineLabel(doc, from, to);
    if (typeof e.value === 'string') {
      rows.push({ label, kind: 'value', text: e.value, from, to });
    } else if (typeof e.error === 'string') {
      rows.push({
        label,
        kind: 'error',
        text: FAILURE_TEXT[e.error] ?? FAILURE_FALLBACK,
        from,
        to,
      });
    }
  }
  return rows;
}

/**
 * Paint `rows` into `host`.
 *
 * Rebuilt wholesale per refresh, like the outline: the list is one row per
 * expression and diffing it would buy nothing but a chance to go stale.
 * Clicking a row selects the expression that produced the value and scrolls it
 * into view, so the panel reads as an annotation of the document rather than a
 * separate artifact.
 *
 * Text goes in through `textContent`: values are computed from user input and
 * can contain anything the document can, including markup-looking strings.
 */
export function renderEvalRows(host: HTMLElement, rows: readonly EvalRow[], view: EditorView) {
  host.replaceChildren();
  for (const row of rows) {
    const item = document.createElement('button');
    item.type = 'button';
    item.className = row.kind === 'value' ? 'pg-eval__row' : 'pg-eval__row pg-eval__row--muted';

    const line = document.createElement('span');
    line.className = 'pg-eval__line';
    line.textContent = row.label;

    const text = document.createElement('span');
    text.className = 'pg-eval__text';
    text.textContent = row.text;

    item.append(line, text);
    item.addEventListener('click', () => {
      // Clamp again at click time: the rows were mapped against an older
      // document if the user kept typing.
      const max = view.state.doc.length;
      const from = Math.min(row.from, max);
      const to = Math.min(row.to, max);
      view.dispatch({ selection: { anchor: from, head: to }, scrollIntoView: true });
      view.focus();
    });
    host.appendChild(item);
  }
}
