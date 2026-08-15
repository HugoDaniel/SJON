/**
 * LSP → CodeMirror signature-help bridge for the playground.
 *
 * CodeMirror ships no signature-help UI, so this module owns one — mirroring
 * lsp-folding.ts's shape: a StateField holding the active `SignatureState` and
 * a `showTooltip` provider that turns it into a floating card. The trigger
 * logic (open on `(`, retrigger on ` ` / caret movement) lives here too; the
 * actual round-trip is injected as a `SignatureSource` so this module — like
 * lsp-hover.ts / lsp-folding.ts — never imports the LSP transport.
 *
 * The server (`textDocument/signatureHelp`, serialized at `src/lsp/wasm.zig:
 * 606-639`) returns `{signatures:[{label, documentation?, parameters:[{label:
 * [start,end]}]}], activeSignature, activeParameter?}`. Each parameter's label
 * is a `[start,end]` byte-offset pair into its signature's `label` string
 * (ASCII-safe, per Handler.zig), which `splitSignatureLabel` uses to bold the
 * active argument.
 */

import { StateField, StateEffect } from '@codemirror/state';
import type { Extension, Text } from '@codemirror/state';
import { showTooltip, keymap, EditorView } from '@codemirror/view';
import type { Tooltip, ViewUpdate } from '@codemirror/view';

/** One parameter: a `[start, end]` byte range into the signature label. */
export interface LspSignatureParameter {
  label: [number, number];
}

export interface LspSignatureInfo {
  label: string;
  documentation?: { kind?: string; value: string };
  parameters: LspSignatureParameter[];
}

/** The `textDocument/signatureHelp` result the WASM serializer emits. */
export interface LspSignatureHelp {
  signatures: LspSignatureInfo[];
  activeSignature: number;
  /** Omitted (never `undefined`) when the cursor sits between arguments. */
  activeParameter?: number;
}

/** Fetches signature help for `pos` in `doc`, or null. Injected by boot.ts. */
export type SignatureSource = (doc: Text, pos: number) => Promise<LspSignatureHelp | null>;

/** What the field holds while a card is showing: the help plus the caret offset
 *  the tooltip anchors above (remapped as the doc changes). */
export interface SignatureState {
  help: LspSignatureHelp;
  pos: number;
}

// ----- pure mapping ---------------------------------------------------------

function isParam(x: unknown): x is LspSignatureParameter {
  if (typeof x !== 'object' || x === null) return false;
  const label = (x as { label: unknown }).label;
  return (
    Array.isArray(label) &&
    label.length === 2 &&
    typeof label[0] === 'number' &&
    typeof label[1] === 'number'
  );
}

/** Structural guard for a server signature-help result. */
export function isLspSignatureHelp(x: unknown): x is LspSignatureHelp {
  if (typeof x !== 'object' || x === null) return false;
  const rec = x as { signatures: unknown; activeSignature: unknown };
  if (!Array.isArray(rec.signatures) || typeof rec.activeSignature !== 'number') return false;
  return rec.signatures.every((s) => {
    if (typeof s !== 'object' || s === null) return false;
    const sig = s as { label: unknown; parameters: unknown };
    return (
      typeof sig.label === 'string' &&
      Array.isArray(sig.parameters) &&
      sig.parameters.every(isParam)
    );
  });
}

/** The `[start, end]` label range of the currently-active parameter, or null
 *  when there's no active parameter / the indices are out of range. */
export function activeParamRange(help: LspSignatureHelp): [number, number] | null {
  if (help.activeParameter === undefined) return null;
  const sig = help.signatures[help.activeSignature];
  if (sig === undefined) return null;
  const param = sig.parameters[help.activeParameter];
  return param === undefined ? null : param.label;
}

/** Split `label` into the text before / at / after the active-param range, so
 *  the middle can be emphasised. A null range (or one past the label) leaves the
 *  whole label in `before`; out-of-bounds offsets are clamped. */
export function splitSignatureLabel(
  label: string,
  range: [number, number] | null,
): { before: string; active: string; after: string } {
  if (range === null) return { before: label, active: '', after: '' };
  const start = Math.max(0, Math.min(range[0], label.length));
  const end = Math.max(start, Math.min(range[1], label.length));
  return {
    before: label.slice(0, start),
    active: label.slice(start, end),
    after: label.slice(end),
  };
}

// ----- state field + tooltip ------------------------------------------------

/** Carries the latest signature help into the field, or null to dismiss. */
export const setSignatureEffect = StateEffect.define<SignatureState | null>();

/**
 * Holds the active signature card. Replaced wholesale on `setSignatureEffect`;
 * on an unrelated doc change the anchor is remapped so the tooltip tracks the
 * caret instead of hanging over stale text.
 */
export const signatureField = StateField.define<SignatureState | null>({
  create: () => null,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setSignatureEffect)) return e.value;
    if (value !== null && tr.docChanged) {
      return { help: value.help, pos: tr.changes.mapPos(value.pos) };
    }
    return value;
  },
  provide: (f) => showTooltip.from(f, (st) => (st === null ? null : signatureTooltip(st))),
});

function signatureTooltip(st: SignatureState): Tooltip | null {
  const help = st.help;
  const sig = help.signatures[help.activeSignature] ?? help.signatures[0];
  if (sig === undefined) return null;
  const { before, active, after } = splitSignatureLabel(sig.label, activeParamRange(help));
  const docValue = sig.documentation?.value ?? '';
  return {
    pos: st.pos,
    above: true,
    create: () => {
      const dom = document.createElement('div');
      dom.className = 'cm-sjon-signature';
      const labelEl = document.createElement('div');
      labelEl.className = 'cm-sjon-signature-label';
      labelEl.append(document.createTextNode(before));
      if (active.length > 0) {
        const strong = document.createElement('span');
        strong.className = 'cm-sjon-signature-active';
        strong.textContent = active;
        labelEl.append(strong);
      }
      labelEl.append(document.createTextNode(after));
      dom.append(labelEl);
      if (docValue.length > 0) {
        const docEl = document.createElement('div');
        docEl.className = 'cm-sjon-signature-doc';
        // Docs are short prose; render literally (textContent) — no markup.
        docEl.textContent = docValue;
        dom.append(docEl);
      }
      return { dom };
    },
  };
}

// ----- trigger logic --------------------------------------------------------

/** True when this update ends with a freshly-typed `(` or ` ` before the caret
 *  — the signature open / retrigger characters the server advertises. */
function typedTriggerChar(update: ViewUpdate): boolean {
  if (!update.docChanged) return false;
  const pos = update.state.selection.main.head;
  if (pos === 0) return false;
  const ch = update.state.doc.sliceString(pos - 1, pos);
  return ch === '(' || ch === ' ';
}

// Monotonic request counter: retriggers race caret movement, so only the
// newest request's response is applied — an older one (whether help or null)
// is dropped, never mistaken for a genuine "no signature here" dismissal.
let sigRequestSeq = 0;

function requestSignature(view: EditorView, source: SignatureSource): void {
  const mySeq = ++sigRequestSeq;
  const pos = view.state.selection.main.head;
  void source(view.state.doc, pos).then((help) => {
    if (mySeq !== sigRequestSeq) return; // superseded by a fresher request
    // The field is always installed alongside this extension.
    const showing = view.state.field(signatureField) !== null;
    if (help === null) {
      if (showing) view.dispatch({ effects: setSignatureEffect.of(null) });
      return;
    }
    view.dispatch({
      effects: setSignatureEffect.of({ help, pos: view.state.selection.main.head }),
    });
  });
}

/**
 * Signature help driven by `source`. Requests on a typed trigger char, and —
 * while a card is open — on caret movement or edits, so the active parameter
 * tracks the cursor. The own-effect guard stops the `setSignatureEffect`
 * dispatch from re-triggering itself. Escape dismisses an open card (and only
 * then, so it still falls through to other Escape handlers otherwise).
 */
export function sjonSignatureExtension(source: SignatureSource): Extension {
  return [
    signatureField,
    EditorView.updateListener.of((update) => {
      // Skip the transaction that carried our own effect (loop guard).
      if (update.transactions.some((tr) => tr.effects.some((e) => e.is(setSignatureEffect)))) {
        return;
      }
      const open = update.state.field(signatureField) !== null;
      const typed = typedTriggerChar(update);
      const moved = update.selectionSet || update.docChanged;
      if (typed || (open && moved)) requestSignature(update.view, source);
    }),
    keymap.of([
      {
        key: 'Escape',
        run: (view) => {
          if (view.state.field(signatureField) === null) return false;
          view.dispatch({ effects: setSignatureEffect.of(null) });
          return true;
        },
      },
    ]),
  ];
}
