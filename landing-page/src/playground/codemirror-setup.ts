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

const paperTheme = EditorView.theme({
  '&': {
    fontFamily: 'var(--mono)',
    fontSize: '14px',
    height: '100%',
    color: 'var(--ink)',
  },
  '.cm-scroller': { fontFamily: 'var(--mono)', overflow: 'auto' },
  '.cm-content': { padding: '12px 0', caretColor: 'var(--accent)' },
  '.cm-cursor': { borderLeftColor: 'var(--accent)' },
  '.cm-activeLine': { backgroundColor: 'rgba(240, 100, 73, 0.04)' },
  '.cm-gutters': {
    backgroundColor: 'var(--surface-mute)',
    color: 'var(--ink-soft)',
    border: 'none',
    borderRight: '1px solid var(--rule-mute)',
  },
  '.cm-activeLineGutter': { backgroundColor: 'rgba(240, 100, 73, 0.06)' },
  '.cm-foldGutter, .cm-foldGutter .cm-gutterElement': { color: 'var(--ink-soft)' },
  '.cm-foldGutter .cm-gutterElement:hover': { color: 'var(--accent)' },
  '.cm-foldPlaceholder': {
    backgroundColor: 'var(--surface-mute)',
    color: 'var(--ink-soft)',
    border: '1px solid var(--rule-mute)',
    borderRadius: '3px',
    margin: '0 2px',
    padding: '0 4px',
  },
  '&.cm-focused .cm-selectionBackground, .cm-selectionBackground': {
    backgroundColor: 'rgba(85, 124, 168, 0.18)',
  },
  '.cm-matchingBracket, &.cm-focused .cm-matchingBracket': {
    backgroundColor: 'rgba(240, 100, 73, 0.18)',
    outline: '1px solid var(--accent)',
  },
  '.cm-lintRange-error': {
    backgroundImage: 'none',
    textDecoration: 'underline wavy var(--accent)',
    textDecorationThickness: '1.5px',
    textUnderlineOffset: '3px',
  },
  '.cm-lintRange-warning': {
    backgroundImage: 'none',
    textDecoration: 'underline wavy #d9a441',
    textDecorationThickness: '1.5px',
    textUnderlineOffset: '3px',
  },
  '.cm-tooltip-lint': {
    backgroundColor: 'var(--paper)',
    border: '1px solid var(--ink)',
    color: 'var(--ink)',
    fontFamily: 'var(--body)',
    fontSize: '13px',
    padding: '4px 8px',
    maxWidth: '420px',
  },
  // Hover cards (lsp-hover.ts). CM tags the wrapper `.cm-tooltip-hover`; the
  // rendered markdown lives in an inner `.cm-sjon-hover` div.
  '.cm-tooltip.cm-tooltip-hover': {
    backgroundColor: 'var(--paper)',
    border: '1px solid var(--ink)',
    color: 'var(--ink)',
    borderRadius: '3px',
  },
  '.cm-sjon-hover': {
    fontFamily: 'var(--body)',
    fontSize: '13px',
    lineHeight: '1.45',
    padding: '6px 10px',
    maxWidth: '420px',
  },
  '.cm-sjon-hover p': { margin: '0 0 6px' },
  '.cm-sjon-hover p:last-child': { marginBottom: '0' },
  '.cm-sjon-hover ul, .cm-sjon-hover ol': { margin: '4px 0', paddingLeft: '18px' },
  '.cm-sjon-hover code': { fontFamily: 'var(--mono)', fontSize: '12px' },
  '.cm-sjon-hover a': { color: 'var(--accent)' },
  // Signature help card (lsp-signature.ts): monospace label with the active
  // parameter emphasised, optional prose doc below.
  '.cm-sjon-signature': {
    backgroundColor: 'var(--paper)',
    border: '1px solid var(--ink)',
    borderRadius: '3px',
    color: 'var(--ink)',
    padding: '5px 9px',
    maxWidth: '480px',
  },
  '.cm-sjon-signature-label': { fontFamily: 'var(--mono)', fontSize: '12.5px' },
  '.cm-sjon-signature-active': { color: 'var(--accent)', fontWeight: '700' },
  '.cm-sjon-signature-doc': {
    fontFamily: 'var(--body)',
    fontSize: '12px',
    color: 'var(--ink-soft)',
    marginTop: '4px',
  },
  '.cm-diagnostic': { padding: '2px 6px' },
  '.cm-diagnostic-error': { borderLeft: '3px solid var(--accent)' },
  '.cm-diagnostic-warning': { borderLeft: '3px solid #d9a441' },
  '.cm-tooltip.cm-tooltip-autocomplete': {
    backgroundColor: 'var(--paper)',
    border: '1px solid var(--ink)',
    color: 'var(--ink)',
    fontFamily: 'var(--mono)',
    fontSize: '13px',
  },
  '.cm-tooltip-autocomplete ul li[aria-selected]': {
    backgroundColor: 'rgba(240, 100, 73, 0.12)',
    color: 'var(--ink)',
  },
  '.cm-completionInfo': {
    backgroundColor: 'var(--paper)',
    border: '1px solid var(--ink)',
    color: 'var(--ink)',
    fontFamily: 'var(--body)',
    fontSize: '13px',
    padding: '4px 8px',
    maxWidth: '420px',
  },
});

const paperHighlight = HighlightStyle.define([
  { tag: tags.keyword, color: '#7a4ca0', fontWeight: '600' },
  { tag: tags.atom, color: '#557ca8' },
  { tag: tags.number, color: '#a05a2c' },
  { tag: tags.string, color: '#476b3a' },
  { tag: tags.special(tags.string), color: '#476b3a' },
  { tag: tags.comment, color: 'var(--ink-soft)', fontStyle: 'italic' },
  { tag: tags.variableName, color: 'var(--ink)' },
  { tag: tags.standard(tags.variableName), color: '#7a4ca0' },
  { tag: tags.meta, color: 'var(--accent-cool)' },
  // `:keys` (propertyName) and the structural `()`/`[]` (punctuation) — the two
  // tokens the SJON grammar emits that the prior Clojure approximation did not
  // surface distinctly. Punctuation is muted so `--accent` stays UI-only.
  { tag: tags.propertyName, color: '#2d7d8a' },
  { tag: tags.punctuation, color: 'var(--ink-soft)' },
]);

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
      paperTheme,
      syntaxHighlighting(paperHighlight),
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
