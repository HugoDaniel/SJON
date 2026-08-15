/**
 * Inlay hints for the SJON playground editor.
 *
 * Framework-only, like `lsp-folding.ts`: a StateField holds the hints the
 * server last reported, rendered as CodeMirror widget decorations. The LSP
 * layer pushes specs in through `setInlayHints`.
 *
 * SJON's server emits two families today — the plugin a bare form head came
 * from, and (since the materialized-defaults work) ghost `:key value` text for
 * keys the author omitted but the schema defaults. The second is why hints
 * matter here at all: it is the one feature that shows the *effective*
 * document without rewriting the one the user typed.
 *
 * Widgets are non-interactive and marked `side: 1`, so a hint sitting at the
 * same offset as the cursor renders after it and never swallows a click.
 */

import { StateField, StateEffect } from '@codemirror/state';
import type { Extension, Text } from '@codemirror/state';
import { Decoration, WidgetType, EditorView } from '@codemirror/view';
import type { DecorationSet } from '@codemirror/view';

import { posToOffset } from './lsp-types.ts';
import type { LspPosition } from './lsp-types';

/** A `textDocument/inlayHint` item, in the subset the wasm serializer emits.
 *  `paddingLeft`/`paddingRight` are sent only when true; `kind` only when the
 *  server has one (SJON's plugin-source hints deliberately have none). */
export interface LspInlayHint {
  position: LspPosition;
  label: string;
  kind?: number;
  paddingLeft?: boolean;
  paddingRight?: boolean;
}

/** A hint resolved against the document: where it goes and how to render it. */
export interface InlayWidgetSpec {
  offset: number;
  label: string;
  /** LSP `InlayHintKind` (1 = Type, 2 = Parameter), or null when unspecified. */
  kind: number | null;
  paddingLeft: boolean;
  paddingRight: boolean;
}

function isHint(x: unknown): x is LspInlayHint {
  if (typeof x !== 'object' || x === null) return false;
  const h = x as { position?: unknown; label?: unknown };
  if (typeof h.label !== 'string') return false;
  const p = h.position as { line?: unknown; character?: unknown } | undefined;
  return typeof p === 'object' && p !== null && typeof p.line === 'number';
}

/**
 * Resolve server hints to document offsets, dropping malformed entries.
 *
 * Order is preserved rather than sorted: the server emits hints in tree order
 * and `Decoration.set` is told to sort, so re-ordering here would only hide a
 * server-side ordering bug from the one place that would notice it.
 */
export function inlayHintsToWidgets(doc: Text, hints: readonly LspInlayHint[]): InlayWidgetSpec[] {
  const specs: InlayWidgetSpec[] = [];
  for (const h of hints) {
    if (!isHint(h)) continue;
    specs.push({
      offset: posToOffset(doc, h.position.line, h.position.character),
      label: h.label,
      kind: typeof h.kind === 'number' ? h.kind : null,
      paddingLeft: h.paddingLeft === true,
      paddingRight: h.paddingRight === true,
    });
  }
  return specs;
}

/** The rendered hint: an inert span carrying the label. `ignoreEvent` keeps
 *  clicks flowing to the editor beneath, and `eq` lets CodeMirror reuse the
 *  DOM node across refreshes that produce the same hint. */
class InlayWidget extends WidgetType {
  // An explicit field, not a constructor parameter property: those are not
  // erasable syntax, and this module is loaded by node's strip-only
  // type-stripping in `pnpm test`.
  readonly spec: InlayWidgetSpec;

  constructor(spec: InlayWidgetSpec) {
    super();
    this.spec = spec;
  }

  override eq(other: InlayWidget): boolean {
    return (
      other.spec.label === this.spec.label &&
      other.spec.kind === this.spec.kind &&
      other.spec.paddingLeft === this.spec.paddingLeft &&
      other.spec.paddingRight === this.spec.paddingRight
    );
  }

  toDOM(): HTMLElement {
    const el = document.createElement('span');
    el.className = 'cm-sjon-inlay';
    if (this.spec.paddingLeft) el.style.paddingInlineStart = '0.4em';
    if (this.spec.paddingRight) el.style.paddingInlineEnd = '0.4em';
    el.textContent = this.spec.label;
    return el;
  }

  override ignoreEvent(): boolean {
    return false;
  }
}

function decorationsFor(specs: readonly InlayWidgetSpec[], docLength: number): DecorationSet {
  const ranges = specs
    .filter((s) => s.offset >= 0 && s.offset <= docLength)
    .map((s) => Decoration.widget({ widget: new InlayWidget(s), side: 1 }).range(s.offset));
  return Decoration.set(ranges, true);
}

/** Effect carrying a fresh set of resolved hints into the field. */
export const setInlayHintsEffect = StateEffect.define<readonly InlayWidgetSpec[]>();

interface InlayState {
  specs: readonly InlayWidgetSpec[];
  decorations: DecorationSet;
}

/**
 * The hints last reported by the server, plus their decorations.
 *
 * Both are kept because they answer different questions: `specs` is what the
 * server said, `decorations` is where those hints currently sit. Between
 * refreshes the decorations are *mapped* through each document change rather
 * than recomputed — hints arrive on the diagnostics debounce, so without
 * mapping every keystroke would leave them pinned to stale offsets until the
 * next response landed. The specs deliberately are not re-resolved on the way
 * through: a hint's position is only meaningful against the document the
 * server saw, and mapping is exactly the operation that carries it forward.
 */
export const inlayHintsField = StateField.define<InlayState>({
  create: () => ({ specs: [], decorations: Decoration.none }),
  update(value, tr) {
    for (const e of tr.effects) {
      if (e.is(setInlayHintsEffect)) {
        return { specs: e.value, decorations: decorationsFor(e.value, tr.newDoc.length) };
      }
    }
    if (!tr.docChanged) return value;
    return { specs: value.specs, decorations: value.decorations.map(tr.changes) };
  },
  provide: (f) => EditorView.decorations.from(f, (v) => v.decorations),
});

/** Push a fresh set of resolved hints into `view`. */
export function setInlayHints(view: EditorView, specs: readonly InlayWidgetSpec[]): void {
  view.dispatch({ effects: setInlayHintsEffect.of(specs) });
}

/** The inlay bundle: the field (which provides its own decorations) plus the
 *  hint styling. */
export const sjonInlayHintsExtension: Extension = [
  inlayHintsField,
  EditorView.theme({
    '.cm-sjon-inlay': {
      color: 'var(--ink-soft, #6b6b6b)',
      backgroundColor: 'color-mix(in srgb, currentColor 8%, transparent)',
      borderRadius: '3px',
      fontSize: '0.9em',
      opacity: '0.85',
      // Ghost text is a reading aid, never a selection target — a hint caught
      // in a drag-select would otherwise land in the user's clipboard as if
      // they had typed it.
      userSelect: 'none',
    },
  }),
];
