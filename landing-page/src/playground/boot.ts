/**
 * Playground entry — mounts the document editor, starts the LSP, wires
 * the schema-tabs controller, and keeps the URL hash in sync so the doc
 * and every schema pane survive reload and are shareable via "Copy link".
 *
 * Called once from /playground.astro via `mountPlayground(element)`,
 * where `element` is `#sjon-editor` (the document pane's mount point).
 * The tab shell and panes are found via `element.closest('.editor-frame')`.
 */

import { createPlaygroundEditor } from './codemirror-setup';
import type { PlaygroundEditor } from './codemirror-setup';
import {
  initLSP,
  setMainView,
  syncDocument,
  destroyLSP,
  requestHover,
  requestSignatureHelp,
  requestFormatting,
  setOutlineSink,
  setEvalSink,
  offsetToLspPos,
} from './lsp-integration';
import { applyLspEdits } from './lsp-actions';
import { flattenSymbols, renderOutline } from './lsp-outline';
import { evalEntriesToRows, renderEvalRows } from './lsp-eval';
import { decodeHashState, encodeHashState } from './hash-state';
import type { HashState } from './hash-state';
import { DEFAULT_EXAMPLE, PLAYGROUND_EXAMPLES } from './examples';
import { sjonCompletionSource } from './lsp-completion';
import { createSchemaTabs } from './schema-tabs';
import type { SchemaTabsController } from './schema-tabs';
import { FAILURE_BANNER_SELECTOR, showLspFailure } from './lsp-failure';
import { path } from '../lib/url';

const HASH_DEBOUNCE_MS = 400;

/** Read the live hash into playground state. The codec itself is pure and
 *  lives in `hash-state.ts`; this is the one impure step. */
function readHashState(): HashState {
  if (typeof window === 'undefined') return { doc: null, schemas: [] };
  return decodeHashState(window.location.hash);
}

export async function mountPlayground(host: HTMLElement): Promise<PlaygroundEditor> {
  if (!host) throw new Error('mountPlayground: missing host element');
  const frame = host.closest('.editor-frame');
  if (!(frame instanceof HTMLElement)) {
    throw new Error('mountPlayground: missing .editor-frame shell');
  }

  const decoded = readHashState();
  const initialCode = decoded.doc ?? host.dataset['initialSource'] ?? DEFAULT_EXAMPLE.doc;

  let editorRef: PlaygroundEditor | null = null;
  let tabsRef: SchemaTabsController | null = null;
  let hashTimer: ReturnType<typeof setTimeout> | null = null;

  function writeHashNow(): void {
    if (typeof window === 'undefined' || !editorRef) return;
    const doc = editorRef.getValue();
    const schemaTexts = tabsRef ? tabsRef.getSchemaTexts() : [];
    const hash = encodeHashState(doc, schemaTexts);
    const url = `${window.location.pathname}${window.location.search}#${hash}`;
    window.history.replaceState(null, '', url);
  }

  function updateHash(): void {
    if (hashTimer !== null) clearTimeout(hashTimer);
    hashTimer = setTimeout(() => {
      hashTimer = null;
      writeHashNow();
    }, HASH_DEBOUNCE_MS);
  }

  function flushHash(): void {
    if (hashTimer !== null) {
      clearTimeout(hashTimer);
      hashTimer = null;
    }
    writeHashNow();
  }

  const exampleSelect = frame.querySelector<HTMLSelectElement>('[data-pg-examples]');

  /** Point the picker at whatever is actually loaded.
   *
   * The picker is a label for the current document, not a one-way command:
   * a share link, a reload, or one keystroke can all leave it naming an
   * example the editor no longer holds. Matching on the document text keeps
   * the two honest, and falls back to the hidden placeholder ("Custom") for
   * anything the visitor has made their own. */
  function syncPickerToDoc(source: string): void {
    if (!exampleSelect) return;
    exampleSelect.value = PLAYGROUND_EXAMPLES.find((e) => e.doc === source)?.id ?? '';
  }

  const editor = createPlaygroundEditor(host, {
    initialCode,
    onChange: (source: string) => {
      syncDocument(source);
      updateHash();
      syncPickerToDoc(source);
    },
    completionSource: sjonCompletionSource,
    hoverSource: (doc, pos) => requestHover(doc.toString(), offsetToLspPos(doc, pos)),
    signatureSource: (doc, pos) => requestSignatureHelp(doc.toString(), offsetToLspPos(doc, pos)),
  });
  editorRef = editor;
  setMainView(editor.view);
  syncPickerToDoc(initialCode);

  const tabs = createSchemaTabs(frame, { onStateChange: updateHash });
  tabsRef = tabs;

  // Replay deep-linked schema panes before the first sync.
  for (const text of decoded.schemas) tabs.addSchema(text);

  // Copy-link: flush the hash (it may be mid-debounce) then copy the URL.
  const copyBtn = frame.querySelector<HTMLElement>('[data-pg-copy]');
  if (copyBtn) {
    copyBtn.addEventListener('click', () => {
      flushHash();
      void navigator.clipboard
        .writeText(window.location.href)
        .then(() => {
          const original = copyBtn.textContent;
          copyBtn.textContent = 'Copied!';
          setTimeout(() => {
            copyBtn.textContent = original;
          }, 1200);
        })
        .catch(() => {
          /* clipboard denied — no-op */
        });
    });
  }

  // Outline: the server's symbol tree, flattened into a clickable strip.
  // Collapsed until the toggle asks for it, but the sink stays attached either
  // way — the rows are then already current when it opens, and re-syncing on
  // toggle would mean a round-trip between the click and anything appearing.
  const outlinePanel = frame.querySelector<HTMLElement>('[data-pg-outline]');
  const outlineRows = frame.querySelector<HTMLElement>('[data-pg-outline-rows]');
  const outlineToggle = frame.querySelector<HTMLElement>('[data-pg-outline-toggle]');
  if (outlinePanel && outlineRows) {
    setOutlineSink((syms) => {
      const editor = editorRef;
      if (!editor) return;
      const rows = flattenSymbols(editor.view.state.doc, syms);
      if (rows.length === 0) {
        outlineRows.replaceChildren();
        const empty = document.createElement('p');
        empty.className = 'pg-outline__empty';
        empty.textContent = 'No forms yet.';
        outlineRows.appendChild(empty);
        return;
      }
      renderOutline(outlineRows, rows, editor.view);
    });
  }
  if (outlineToggle && outlinePanel) {
    outlineToggle.addEventListener('click', () => {
      const open = outlinePanel.hidden;
      outlinePanel.hidden = !open;
      outlineToggle.setAttribute('aria-expanded', String(open));
    });
  }

  // Values: every expression root's computed result, refreshed on the same
  // cadence as the diagnostics. This is the panel that makes the page's
  // "evaluates as you type" claim visible — up to now the evaluator ran on
  // every keystroke and showed its work nowhere.
  const evalRows = frame.querySelector<HTMLElement>('[data-pg-eval-rows]');
  if (evalRows) {
    setEvalSink((entries) => {
      const editor = editorRef;
      if (!editor) return;
      const rows = evalEntriesToRows(editor.view.state.doc, entries);
      if (rows.length === 0) {
        evalRows.replaceChildren();
        const empty = document.createElement('p');
        empty.className = 'pg-eval__empty';
        empty.textContent = 'No expressions to evaluate.';
        evalRows.appendChild(empty);
        return;
      }
      renderEvalRows(evalRows, rows, editor.view);
    });
  }

  // Examples: swap the document and every schema pane in one go. The registry
  // is the same data `zig build check-examples` validates against the server,
  // so nothing reachable from this picker can rot into a wall of squiggles
  // without failing a build gate first.
  //
  // Document and schemas each have their own debounced sync path, so a switch
  // would otherwise spend a frame validating the new document against the
  // previous example's schemas. The explicit `resync()` closes that window:
  // it installs the schema set and re-pulls the document behind it, which is
  // the same ordering boot uses for a deep-linked share link.
  if (exampleSelect) {
    exampleSelect.addEventListener('change', () => {
      const example = PLAYGROUND_EXAMPLES.find((e) => e.id === exampleSelect.value);
      const ed = editorRef;
      if (!example || !ed) return;
      ed.view.dispatch({
        changes: { from: 0, to: ed.view.state.doc.length, insert: example.doc },
        selection: { anchor: 0 },
        scrollIntoView: true,
      });
      tabs.replaceSchemas(example.schemas);
      void tabs.resync();
      ed.view.focus();
    });
  }

  // Format: pull TextEdits for the live document and apply them in one
  // transaction (so a single undo reverts the whole reformat). Momentary
  // label feedback mirrors copy-link's, and covers the case worth reporting —
  // already-formatted source, where the server returns no edits and nothing
  // visibly happens.
  const formatBtn = frame.querySelector<HTMLElement>('[data-pg-format]');
  if (formatBtn) {
    formatBtn.addEventListener('click', () => {
      const editor = editorRef;
      if (!editor) return;
      void requestFormatting(editor.getValue()).then((edits) => {
        const changed = edits ? applyLspEdits(editor.view, edits) : false;
        const original = formatBtn.textContent;
        formatBtn.textContent = changed ? 'Formatted' : 'No changes';
        setTimeout(() => {
          formatBtn.textContent = original;
        }, 1200);
      });
    });
  }

  try {
    await initLSP(path('/sjon-lsp.wasm'), {
      // Unhide the stale-asset banner when the running wasm disagrees with the
      // build-staged sidecar (developer edited Zig but skipped
      // `zig build landing-page-assets`, or a proxy served an old copy).
      onStale: () => {
        const badge = frame.querySelector<HTMLElement>('[data-pg-stale]');
        if (badge) badge.hidden = false;
      },
    });
    syncDocument(editor.getValue());
    // Install any replayed schemas and re-validate the doc against them.
    await tabs.resync();
  } catch (e) {
    // Both backends are gone at this point — the worker one and the inline
    // fallback behind it. The editor still mounted, so the page looks alive
    // while every server-fed panel stays empty forever; say so on screen
    // rather than only in a console nobody has open.
    console.error('[playground] LSP boot failed:', e);
    showLspFailure(frame.querySelector<HTMLElement>(FAILURE_BANNER_SELECTOR), e);
  }

  if (typeof window !== 'undefined') {
    window.addEventListener('beforeunload', () => {
      try {
        destroyLSP();
      } catch {
        /* best-effort */
      }
      tabs.destroy();
      editor.destroy();
    });
  }

  return editor;
}
