/**
 * Document outline for the SJON playground.
 *
 * Framework-only (the `lsp-folding.ts` pattern): the pure mapper
 * `flattenSymbols` turns the server's nested `DocumentSymbol[]` into flat,
 * depth-tagged rows, and `renderOutline` paints them into a host element.
 * Neither touches the LSP transport — `lsp-integration.ts` fetches, boot.ts
 * composes.
 *
 * Flat rows rather than a nested DOM tree: SJON documents nest arbitrarily,
 * and an indent-per-depth list stays scannable where nested `<ul>`s march off
 * the right edge. Depth is carried as a number so the renderer picks the
 * indent, not the mapper.
 */

import type { Text } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';

import { rangeToOffsets } from './lsp-types.ts';
import type { LspRange } from './lsp-types';

/** A `textDocument/documentSymbol` node. SJON emits the nested
 *  `DocumentSymbol` form (never the flat `SymbolInformation` one), every
 *  symbol with kind 9 (Constructor) — so kind carries no signal here. */
export interface LspDocumentSymbol {
  name: string;
  kind?: number;
  range: LspRange;
  selectionRange: LspRange;
  children?: LspDocumentSymbol[];
}

/** One outline row: what to show, how far to indent it, and where clicking
 *  it should take the cursor. */
export interface OutlineEntry {
  name: string;
  depth: number;
  /** Start of the symbol's *name*, from `selectionRange`. */
  from: number;
  /** End of the symbol's name. */
  to: number;
}

function isSymbol(x: unknown): x is LspDocumentSymbol {
  if (typeof x !== 'object' || x === null) return false;
  const s = x as { name?: unknown; selectionRange?: unknown };
  if (typeof s.name !== 'string') return false;
  const sel = s.selectionRange as { start?: unknown; end?: unknown } | undefined;
  return typeof sel === 'object' && sel !== null && !!sel.start && !!sel.end;
}

/**
 * Flatten the symbol tree into document-ordered rows.
 *
 * Pre-order, so a row always follows its parent and precedes its siblings'
 * subtrees — the order the symbols appear in the source. Each row's offsets
 * come from `selectionRange` (the name) rather than `range` (the whole form):
 * clicking an outline row should reveal the thing named, not select a subtree
 * whose end may be off-screen.
 *
 * Malformed nodes are skipped along with their children — a row with no
 * usable target is worse than no row.
 */
export function flattenSymbols(
  doc: Text,
  syms: readonly LspDocumentSymbol[],
  depth = 0,
): OutlineEntry[] {
  const rows: OutlineEntry[] = [];
  for (const s of syms) {
    if (!isSymbol(s)) continue;
    const { from, to } = rangeToOffsets(doc, s.selectionRange);
    rows.push({ name: s.name, depth, from, to });
    if (Array.isArray(s.children) && s.children.length > 0) {
      rows.push(...flattenSymbols(doc, s.children, depth + 1));
    }
  }
  return rows;
}

/**
 * Paint `rows` into `host` as a list of buttons.
 *
 * Rebuilt wholesale on each refresh — the list is small (one row per form)
 * and diffing it would buy nothing but a chance to get stale. Clicking a row
 * selects the symbol's name and scrolls it into view; the editor takes focus
 * so the caret is where the user just pointed.
 */
export function renderOutline(host: HTMLElement, rows: readonly OutlineEntry[], view: EditorView) {
  host.replaceChildren();
  for (const row of rows) {
    const item = document.createElement('button');
    item.type = 'button';
    item.className = 'pg-outline__row';
    item.textContent = row.name;
    item.style.paddingInlineStart = `${0.5 + row.depth * 0.75}rem`;
    item.addEventListener('click', () => {
      // Clamp: the outline is refreshed on the diagnostics debounce, so a row
      // can outlive the text it points at by a keystroke.
      const max = view.state.doc.length;
      const from = Math.min(row.from, max);
      const to = Math.min(row.to, max);
      view.dispatch({ selection: { anchor: from, head: to }, scrollIntoView: true });
      view.focus();
    });
    host.appendChild(item);
  }
}
