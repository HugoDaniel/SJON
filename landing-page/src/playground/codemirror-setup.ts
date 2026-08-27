/**
 * CodeMirror setup for the SJON playground.
 *
 * Adapted from pngine/web/editor/src/lib/codemirror-setup.js — trimmed to the
 * single-buffer scope. Prelude widget, external-update annotation, and the
 * multi-line tab handler are dropped; the fold service is reinstated here via
 * `sjonFoldingExtension`, fed by the LSP `textDocument/foldingRange` route.
 */

import { EditorView, keymap, lineNumbers, drawSelection } from '@codemirror/view';
import type { KeyBinding } from '@codemirror/view';
import { EditorState, Compartment } from '@codemirror/state';
import {
  history,
  historyKeymap,
  defaultKeymap,
  indentLess,
  indentMore,
} from '@codemirror/commands';
import {
  syntaxHighlighting,
  HighlightStyle,
  bracketMatching,
  indentUnit,
} from '@codemirror/language';
import { tags } from '@lezer/highlight';
import { lintGutter } from '@codemirror/lint';
import { autocompletion } from '@codemirror/autocomplete';
import type { CompletionSource } from '@codemirror/autocomplete';
import { sjonLanguage } from '@sjon/highlight';
import { sjonFoldingExtension } from './lsp-folding';
import { sjonInlayHintsExtension } from './lsp-inlays';
import { sjonHoverExtension } from './lsp-hover';
import type { HoverSource } from './lsp-hover';
import { sjonSignatureExtension } from './lsp-signature';
import type { SignatureSource } from './lsp-signature';
import { isEditorSearchShortcutCollision, onMacPlatform } from './search-shortcut';

/**
 * The editor's palette, named rather than spelled out.
 *
 * Every colour and face below is a `--sjon-cm-*` custom property defined in
 * `src/styles/playground.css`; none is a literal. That is not tidiness, it is
 * the whole theme-switching mechanism: `EditorView.theme()` emits plain CSS
 * text and the browser resolves `var()` at paint, not CodeMirror at
 * configure-time. Redefine the block under a different theme and a live editor
 * recolours on the spot — no reconfigure, no `MutationObserver`, no flash, and
 * `prefers-color-scheme` keeps working on its own.
 */
const editorTheme = EditorView.theme({
  '&': {
    fontFamily: 'var(--sjon-cm-font-mono)',
    fontSize: '14px',
    height: '100%',
    color: 'var(--sjon-cm-fg)',
  },
  '.cm-scroller': { fontFamily: 'var(--sjon-cm-font-mono)', overflow: 'auto' },
  '.cm-content': { padding: '12px 0', caretColor: 'var(--sjon-cm-caret)' },
  '.cm-cursor': { borderLeftColor: 'var(--sjon-cm-caret)' },
  '.cm-activeLine': { backgroundColor: 'var(--sjon-cm-active-line)' },
  '.cm-gutters': {
    backgroundColor: 'var(--sjon-cm-gutter-bg)',
    color: 'var(--sjon-cm-gutter-fg)',
    border: 'none',
    borderRight: '1px solid var(--sjon-cm-gutter-border)',
  },
  '.cm-activeLineGutter': { backgroundColor: 'var(--sjon-cm-active-line-gutter)' },
  '.cm-foldGutter, .cm-foldGutter .cm-gutterElement': { color: 'var(--sjon-cm-gutter-fg)' },
  '.cm-foldGutter .cm-gutterElement:hover': { color: 'var(--sjon-cm-accent)' },
  '.cm-foldPlaceholder': {
    backgroundColor: 'var(--sjon-cm-inset-bg)',
    color: 'var(--sjon-cm-fg-soft)',
    border: '1px solid var(--sjon-cm-border-soft)',
    borderRadius: '3px',
    margin: '0 2px',
    padding: '0 4px',
  },
  // Two selectors, because the focused case has to out-run a base rule.
  // `@codemirror/view` paints a focused selection through
  // `&light.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground`
  // — five classes. A plain `&.cm-focused .cm-selectionBackground` is three, and
  // specificity is settled before StyleModule order ever gets a say, so the
  // focused selection came out CodeMirror's `#d7d4f0` lavender rather than this
  // blue. Mirroring the base selector's shape levels the specificity, and our
  // module mounts after the base one, so the tie falls our way.
  '&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground':
    {
      backgroundColor: 'var(--sjon-cm-selection)',
    },
  '.cm-matchingBracket, &.cm-focused .cm-matchingBracket': {
    backgroundColor: 'var(--sjon-cm-bracket-bg)',
    outline: '1px solid var(--sjon-cm-accent)',
  },
  '.cm-lintRange-error': {
    backgroundImage: 'none',
    textDecoration: 'underline wavy var(--sjon-cm-error)',
    textDecorationThickness: '1.5px',
    textUnderlineOffset: '3px',
  },
  '.cm-lintRange-warning': {
    backgroundImage: 'none',
    textDecoration: 'underline wavy var(--sjon-cm-warning)',
    textDecorationThickness: '1.5px',
    textUnderlineOffset: '3px',
  },
  // Base-theme neutralisers.
  //
  // This theme registers without `{dark: true}`, so `@codemirror/view` and
  // `@codemirror/autocomplete` keep their `&light` base rules live no matter
  // what the page's theme says — and a couple of unconditional rules paint
  // literal black. Each rule below out-runs one of those, so every colour in
  // the editor comes from the block above and nothing is pinned to a light
  // page. Specificity is matched, not exceeded: `&light .x` and our `.x` both
  // land at two classes, and our module mounts last, so the tie falls our way.
  //
  // Verified unreachable and therefore absent: `.cm-panels{,-top,-bottom}`,
  // `.cm-button`, `.cm-textfield` (no search or lint panel is installed — the
  // lint integration is `lintGutter` plus diagnostics) and `.cm-tooltip-arrow`
  // (nothing here passes `arrow: true`).
  '.cm-specialChar': { color: 'var(--sjon-cm-special)' },
  // Unconditional `1.2px solid black` in the base theme, so it survives even a
  // dark editor. It mimics the text cursor, so it follows the caret colour.
  '.cm-dropCursor': { borderLeftColor: 'var(--sjon-cm-caret)' },
  // Reachable: LSP completions apply through `snippet()` (lsp-completion.ts).
  '.cm-snippetField': { backgroundColor: 'var(--sjon-cm-snippet-field)' },
  // Every card below re-states its own background and border at equal or
  // greater specificity, so this is the floor rather than the paint. It exists
  // so a tooltip nobody styled cannot fall back to `#f5f5f5` / `#bbb`.
  '.cm-tooltip': {
    backgroundColor: 'var(--sjon-cm-panel-bg)',
    border: '1px solid var(--sjon-cm-panel-border)',
  },
  '.cm-tooltip-section:not(:first-child)': {
    borderTop: '1px solid var(--sjon-cm-border-soft)',
  },
  '.cm-tooltip-lint': {
    backgroundColor: 'var(--sjon-cm-panel-bg)',
    border: '1px solid var(--sjon-cm-panel-border)',
    color: 'var(--sjon-cm-fg)',
    fontFamily: 'var(--sjon-cm-font-ui)',
    fontSize: '13px',
    padding: '4px 8px',
    maxWidth: '420px',
  },
  // Hover cards (lsp-hover.ts). CM tags the wrapper `.cm-tooltip-hover`; the
  // rendered markdown lives in an inner `.cm-sjon-hover` div.
  '.cm-tooltip.cm-tooltip-hover': {
    backgroundColor: 'var(--sjon-cm-panel-bg)',
    border: '1px solid var(--sjon-cm-panel-border)',
    color: 'var(--sjon-cm-fg)',
    borderRadius: '3px',
  },
  '.cm-sjon-hover': {
    fontFamily: 'var(--sjon-cm-font-ui)',
    fontSize: '13px',
    lineHeight: '1.45',
    padding: '6px 10px',
    maxWidth: '420px',
  },
  '.cm-sjon-hover p': { margin: '0 0 6px' },
  '.cm-sjon-hover p:last-child': { marginBottom: '0' },
  '.cm-sjon-hover ul, .cm-sjon-hover ol': { margin: '4px 0', paddingLeft: '18px' },
  '.cm-sjon-hover code': { fontFamily: 'var(--sjon-cm-font-mono)', fontSize: '12px' },
  '.cm-sjon-hover a': { color: 'var(--sjon-cm-link)' },
  // Signature help card (lsp-signature.ts): monospace label with the active
  // parameter emphasised, optional prose doc below.
  '.cm-sjon-signature': {
    backgroundColor: 'var(--sjon-cm-panel-bg)',
    border: '1px solid var(--sjon-cm-panel-border)',
    borderRadius: '3px',
    color: 'var(--sjon-cm-fg)',
    padding: '5px 9px',
    maxWidth: '480px',
  },
  '.cm-sjon-signature-label': { fontFamily: 'var(--sjon-cm-font-mono)', fontSize: '12.5px' },
  '.cm-sjon-signature-active': { color: 'var(--sjon-cm-accent)', fontWeight: '700' },
  '.cm-sjon-signature-doc': {
    fontFamily: 'var(--sjon-cm-font-ui)',
    fontSize: '12px',
    color: 'var(--sjon-cm-fg-soft)',
    marginTop: '4px',
  },
  '.cm-diagnostic': { padding: '2px 6px' },
  '.cm-diagnostic-error': { borderLeft: '3px solid var(--sjon-cm-error)' },
  '.cm-diagnostic-warning': { borderLeft: '3px solid var(--sjon-cm-warning)' },
  '.cm-tooltip.cm-tooltip-autocomplete': {
    backgroundColor: 'var(--sjon-cm-panel-bg)',
    border: '1px solid var(--sjon-cm-panel-border)',
    color: 'var(--sjon-cm-fg)',
    fontFamily: 'var(--sjon-cm-font-mono)',
    fontSize: '13px',
  },
  '.cm-tooltip-autocomplete ul li[aria-selected]': {
    backgroundColor: 'var(--sjon-cm-selected-bg)',
    color: 'var(--sjon-cm-fg)',
  },
  '.cm-completionInfo': {
    backgroundColor: 'var(--sjon-cm-panel-bg)',
    border: '1px solid var(--sjon-cm-panel-border)',
    color: 'var(--sjon-cm-fg)',
    fontFamily: 'var(--sjon-cm-font-ui)',
    fontSize: '13px',
    padding: '4px 8px',
    maxWidth: '420px',
  },
});

/** Syntax colours, through the same indirection and for the same reason. */
const editorHighlight = HighlightStyle.define([
  { tag: tags.keyword, color: 'var(--sjon-cm-keyword)', fontWeight: '600' },
  { tag: tags.atom, color: 'var(--sjon-cm-atom)' },
  { tag: tags.number, color: 'var(--sjon-cm-number)' },
  { tag: tags.string, color: 'var(--sjon-cm-string)' },
  { tag: tags.special(tags.string), color: 'var(--sjon-cm-string)' },
  { tag: tags.comment, color: 'var(--sjon-cm-comment)', fontStyle: 'italic' },
  { tag: tags.variableName, color: 'var(--sjon-cm-fg)' },
  { tag: tags.standard(tags.variableName), color: 'var(--sjon-cm-keyword)' },
  { tag: tags.meta, color: 'var(--sjon-cm-meta)' },
  // `:keys` (propertyName) and the structural `()`/`[]` (punctuation) — the two
  // tokens the SJON grammar emits that the prior Clojure approximation did not
  // surface distinctly. Punctuation is muted so the accent stays UI-only.
  { tag: tags.propertyName, color: 'var(--sjon-cm-key)' },
  { tag: tags.punctuation, color: 'var(--sjon-cm-punctuation)' },
]);

// An *observer*, not a handler, and that distinction is the whole thing.
// `InputState.runHandlers` runs observers unconditionally and then walks the
// handlers, breaking out of that walk the moment `defaultPrevented` is set —
// and the keymap is itself a handler that sets it. A handler registered here
// would therefore never see the key it exists to catch. An observer also
// matches the intent: this does not want to claim `Ctrl-K` or stop the editor
// from acting on it, only to keep it from continuing on up to `window`.
// See `search-shortcut.ts` for what it is keeping it from.
const searchShortcutGuard = EditorView.domEventObservers({
  keydown(event) {
    if (isEditorSearchShortcutCollision(event, onMacPlatform())) event.stopPropagation();
  },
});

const tabBinding: KeyBinding = {
  key: 'Tab',
  run: (target: EditorView) => {
    const sel = target.state.selection.main;
    if (
      !sel.empty &&
      target.state.doc.lineAt(sel.from).number !== target.state.doc.lineAt(sel.to).number
    ) {
      return indentMore(target);
    }
    target.dispatch(
      target.state.update(target.state.replaceSelection(target.state.facet(indentUnit))),
    );
    return true;
  },
  shift: indentLess,
};

const playgroundKeymap: KeyBinding[] = [tabBinding, ...defaultKeymap, ...historyKeymap];

export interface PlaygroundEditorOpts {
  initialCode?: string;
  onChange?: (source: string) => void;
  /** When set, autocompletion is enabled with this as the sole source —
   *  keeps this module LSP-free; boot.ts is the composition point. */
  completionSource?: CompletionSource;
  /** When set, LSP hover is enabled via this source (same composition seam as
   *  `completionSource`). Schema panes pass nothing → hover stays dark. */
  hoverSource?: HoverSource;
  /** When set, LSP signature help is enabled via this source. Schema panes pass
   *  nothing → signature help stays dark. */
  signatureSource?: SignatureSource;
}

export interface PlaygroundEditor {
  view: EditorView;
  getValue: () => string;
  destroy: () => void;
}

export function createPlaygroundEditor(
  parentEl: HTMLElement,
  {
    initialCode = '',
    onChange,
    completionSource,
    hoverSource,
    signatureSource,
  }: PlaygroundEditorOpts,
): PlaygroundEditor {
  let debounceTimer: ReturnType<typeof setTimeout> | null = null;
  const lspCompartment = new Compartment();

  const state = EditorState.create({
    doc: initialCode,
    extensions: [
      lineNumbers(),
      lintGutter(),
      sjonFoldingExtension,
      // Inert until the LSP layer pushes hints (schema panes never get any),
      // so it costs a schema pane nothing to carry the field.
      sjonInlayHintsExtension,
      drawSelection(),
      EditorState.allowMultipleSelections.of(true),
      sjonLanguage,
      indentUnit.of('  '),
      editorTheme,
      syntaxHighlighting(editorHighlight),
      bracketMatching(),
      history({ newGroupDelay: 500, minDepth: 10000 }),
      EditorView.updateListener.of((update) => {
        if (!update.docChanged) return;
        if (debounceTimer !== null) clearTimeout(debounceTimer);
        debounceTimer = setTimeout(() => {
          if (onChange) onChange(update.state.doc.toString());
        }, 300);
      }),
      keymap.of(playgroundKeymap),
      searchShortcutGuard,
      EditorView.lineWrapping,
      // `autocompletion()` brings its own keymap (Ctrl-Space, arrows,
      // Enter, Escape — active only while the panel is open) and the
      // snippet-field Tab keymap installs at high precedence only while
      // fields are active, so `tabBinding` stays the fallback.
      lspCompartment.of([
        ...(completionSource ? [autocompletion({ override: [completionSource] })] : []),
        ...(hoverSource ? [sjonHoverExtension(hoverSource)] : []),
        ...(signatureSource ? [sjonSignatureExtension(signatureSource)] : []),
      ]),
    ],
  });

  const view = new EditorView({ state, parent: parentEl });

  return {
    view,
    getValue(): string {
      return view.state.doc.toString();
    },
    destroy(): void {
      if (debounceTimer !== null) clearTimeout(debounceTimer);
      view.destroy();
    },
  };
}
