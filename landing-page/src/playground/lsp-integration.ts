/**
 * SJON LSP integration for the playground editor.
 *
 * Multi-view: one main document plus zero or more schema panes (the
 * "+ schema" tabs). The main document is validated against the live
 * schema; schema panes are `(plugin …)` manifests installed via the
 * `sjon/setSchemas` extension, which recomposes that schema.
 *
 * The SJON LSP advertises `diagnosticProvider` (LSP 3.17 pull-diagnostics):
 * the client must issue `textDocument/diagnostic` requests itself; the
 * server never publishes diagnostics unsolicited. After each sync we fire
 * one such request and push the result into CodeMirror's lint layer.
 */

import { setDiagnostics } from '@codemirror/lint';
import type { Diagnostic as CmDiagnostic } from '@codemirror/lint';
import type { EditorView } from '@codemirror/view';
import type { Text } from '@codemirror/state';
import { createLspTransport, STALE } from './lsp-transport';
import { compareWasmIdentity, fetchWasmMeta, wasmUrlWithVersion } from './lsp-meta';
import { setFoldRanges } from './lsp-folding';
import type { FoldRange } from './lsp-folding';
import { inlayHintsToWidgets, setInlayHints } from './lsp-inlays';
import type { LspInlayHint } from './lsp-inlays';
import { isLspHover } from './lsp-hover';
import type { LspHover } from './lsp-hover';
import { isLspSignatureHelp } from './lsp-signature';
import type { LspSignatureHelp } from './lsp-signature';
import { posToOffset } from './lsp-types';
import { isLspCodeAction, lintActionsFor } from './lsp-actions';
import type { LspCodeAction, LspTextEdit } from './lsp-actions';
import type { LspDocumentSymbol } from './lsp-outline';
import type { LspEvalEntry } from './lsp-eval';
import type {
  DiagnosticReport,
  InitLspOpts,
  LspCompletionItem,
  LspDiagnostic,
  LspPosition,
  LspTransport,
  SchemaInput,
  SchemaReport,
  SetSchemasResult,
  StaleSentinel,
} from './lsp-types';

const DOC_URI = 'inmemory://playground.sjon';

let _transport: LspTransport | null = null;
let _ready = false;
let _mainView: EditorView | null = null;
const _schemaViews = new Map<string, EditorView>();
let _docVersion = 0;
let _opened = false;
let _diagRequestSeq = 0;
let _foldRequestSeq = 0;
let _schemaRequestSeq = 0;
let _symbolRequestSeq = 0;
let _inlayRequestSeq = 0;
let _evalRequestSeq = 0;
let _outlineSink: ((syms: LspDocumentSymbol[]) => void) | null = null;
let _evalSink: ((entries: LspEvalEntry[]) => void) | null = null;
let _lastSyncedText: string | null = null;

function isStale(result: unknown): result is StaleSentinel {
  return result === STALE;
}

function lspNotify(method: string, params: unknown): void {
  if (!_ready || !_transport) return;
  try {
    _transport.notify(method, params, _docVersion);
  } catch (e) {
    console.error('[LSP] notify error:', method, e);
  }
}

async function lspRequest(method: string, params: unknown): Promise<unknown> {
  if (!_ready || !_transport) return null;
  try {
    const r = await _transport.request(method, params, _docVersion);
    return r;
  } catch (e) {
    console.error('[LSP] request error:', method, e);
    return null;
  }
}

function lspPosToOffset(doc: Text, pos: LspPosition | undefined): number | null {
  return pos ? posToOffset(doc, pos.line, pos.character) : null;
}

/** Inverse of `posToOffset` (lsp-types.ts). */
export function offsetToLspPos(doc: Text, offset: number): LspPosition {
  const clamped = Math.max(0, Math.min(offset, doc.length));
  const line = doc.lineAt(clamped);
  return { line: line.number - 1, character: clamped - line.from };
}

/** Translate LSP diagnostics into CodeMirror's lint shape and push them
 *  into `view`'s lint layer. Offsets resolve against `view`'s own doc.
 *  `actions`, when given, are fanned out across the entries they name. */
function pushReportToView(
  view: EditorView,
  items: LspDiagnostic[],
  actions: readonly LspCodeAction[] = [],
): void {
  const doc = view.state.doc;
  const cmDiags: CmDiagnostic[] = [];
  for (const d of items) {
    if (!d || !d.range) continue;
    const from = lspPosToOffset(doc, d.range.start);
    let to = lspPosToOffset(doc, d.range.end);
    if (from == null) continue;
    if (to == null || to <= from) to = Math.min(from + 1, doc.length);
    const severity: CmDiagnostic['severity'] =
      d.severity === 1 ? 'error' : d.severity === 2 ? 'warning' : 'info';
    const fixes = actions.length > 0 ? lintActionsFor(doc, d, actions, DOC_URI) : [];
    cmDiags.push({
      from,
      to,
      severity,
      message: d.message || '',
      source: d.code ? `sjon_lsp:${d.code}` : 'sjon_lsp',
      ...(fixes.length > 0 ? { actions: fixes } : {}),
    });
  }
  view.dispatch(setDiagnostics(view.state, cmDiags));
}

function isDiagnosticReport(r: unknown): r is DiagnosticReport {
  return (
    typeof r === 'object' &&
    r !== null &&
    'kind' in r &&
    ((r as { kind: unknown }).kind === 'full' || (r as { kind: unknown }).kind === 'unchanged')
  );
}

function isSetSchemasResult(r: unknown): r is SetSchemasResult {
  return (
    typeof r === 'object' &&
    r !== null &&
    'reports' in r &&
    Array.isArray((r as { reports: unknown }).reports)
  );
}

async function requestDiagnostics(): Promise<void> {
  if (!_mainView) return;
  const seq = ++_diagRequestSeq;
  const result = await lspRequest('textDocument/diagnostic', {
    textDocument: { uri: DOC_URI },
  });
  if (seq !== _diagRequestSeq) return; // Superseded by a fresher sync.
  if (!result || isStale(result)) return;
  if (!isDiagnosticReport(result)) return;
  if (result.kind === 'unchanged') return;
  const items = Array.isArray(result.items) ? result.items : [];
  if (_mainView) pushReportToView(_mainView, items);
  void requestCodeActions(items, seq);
}

/**
 * Fetch the quick-fixes for a freshly-pushed diagnostic batch and re-push the
 * same diagnostics with them attached.
 *
 * Two passes rather than one, deliberately: the squiggles appear the moment
 * validation lands instead of waiting on a second round-trip, and a failed or
 * superseded action request degrades to "no fixes offered" rather than to "no
 * diagnostics at all". `seq` is the diagnostics sequence this batch came from,
 * so a response overtaken by a newer keystroke is dropped instead of
 * repainting the gutter with fixes computed for text the user has left behind.
 *
 * One request covers the whole document. The server derives actions from its
 * own diagnostics (it ignores `context.diagnostics`, which is sent anyway
 * because the request is not well-formed LSP without it) and stamps each with
 * the diagnostics it fixes, so a single response fans out across every entry.
 */
async function requestCodeActions(items: LspDiagnostic[], seq: number): Promise<void> {
  if (!_mainView || items.length === 0) return;
  const doc = _mainView.state.doc;
  const result = await lspRequest('textDocument/codeAction', {
    textDocument: { uri: DOC_URI },
    range: { start: { line: 0, character: 0 }, end: offsetToLspPos(doc, doc.length) },
    context: { diagnostics: items },
  });
  if (seq !== _diagRequestSeq) return; // Superseded by a fresher sync.
  if (!result || isStale(result) || !Array.isArray(result)) return;
  const actions = result.filter(isLspCodeAction);
  if (actions.length === 0 || !_mainView) return;
  pushReportToView(_mainView, items, actions);
}

function isFoldRange(x: unknown): x is FoldRange {
  return (
    typeof x === 'object' &&
    x !== null &&
    typeof (x as { startLine: unknown }).startLine === 'number' &&
    typeof (x as { endLine: unknown }).endLine === 'number'
  );
}

/**
 * Pull foldable regions for the main document and push them into the editor's
 * fold service. Mirrors `requestDiagnostics`: sequence-gated so a stale
 * response from before the latest sync is dropped. An empty array clears the
 * folds (e.g. the doc became single-line); a `null`/stale result is left as a
 * no-op so the last good fold set survives a transient miss.
 */
async function requestFoldingRanges(): Promise<void> {
  if (!_mainView) return;
  const seq = ++_foldRequestSeq;
  const result = await lspRequest('textDocument/foldingRange', {
    textDocument: { uri: DOC_URI },
  });
  if (seq !== _foldRequestSeq) return; // Superseded by a fresher sync.
  if (!result || isStale(result) || !Array.isArray(result)) return;
  const ranges: FoldRange[] = [];
  for (const item of result) {
    if (isFoldRange(item)) ranges.push({ startLine: item.startLine, endLine: item.endLine });
  }
  if (_mainView) setFoldRanges(_mainView, ranges);
}

/**
 * Pull inlay hints for the whole document and push them into the editor.
 *
 * The range is the whole document rather than the viewport: SJON playground
 * documents are small, and a viewport-scoped request would have to be re-fired
 * on every scroll to keep the ghost defaults from vanishing off-screen.
 * Sequence-gated like its siblings; an empty array is meaningful (the last
 * defaulted key was written out) and clears the hints, while a stale or failed
 * response leaves them standing.
 */
async function requestInlayHints(): Promise<void> {
  if (!_mainView) return;
  const seq = ++_inlayRequestSeq;
  const doc = _mainView.state.doc;
  const result = await lspRequest('textDocument/inlayHint', {
    textDocument: { uri: DOC_URI },
    range: { start: { line: 0, character: 0 }, end: offsetToLspPos(doc, doc.length) },
  });
  if (seq !== _inlayRequestSeq) return; // Superseded by a fresher sync.
  if (!result || isStale(result) || !Array.isArray(result) || !_mainView) return;
  setInlayHints(_mainView, inlayHintsToWidgets(_mainView.state.doc, result as LspInlayHint[]));
}

/**
 * Pull the document's symbol tree and hand it to whatever boot.ts registered.
 *
 * A sink rather than a direct push, because the outline's consumer is a DOM
 * panel and this module stays DOM-free — the same seam `completionSource`
 * uses to keep the editor setup LSP-free, pointed the other way. Sequence-
 * gated like the other post-sync pulls; a `null`/stale result leaves the last
 * good outline standing rather than blanking the strip on a transient miss.
 */
async function requestDocumentSymbols(): Promise<void> {
  if (!_mainView || !_outlineSink) return;
  const seq = ++_symbolRequestSeq;
  const result = await lspRequest('textDocument/documentSymbol', {
    textDocument: { uri: DOC_URI },
  });
  if (seq !== _symbolRequestSeq) return; // Superseded by a fresher sync.
  if (!result || isStale(result) || !Array.isArray(result)) return;
  _outlineSink?.(result as LspDocumentSymbol[]);
}

/** Register the outline consumer. Passing null detaches it, which also stops
 *  `documentSymbol` being requested at all. */
export function setOutlineSink(fn: ((syms: LspDocumentSymbol[]) => void) | null): void {
  _outlineSink = fn;
}

function isEvalResult(r: unknown): r is { entries: LspEvalEntry[] } {
  return (
    typeof r === 'object' &&
    r !== null &&
    'entries' in r &&
    Array.isArray((r as { entries: unknown }).entries)
  );
}

/**
 * Pull every expression root's computed value and hand them to the output
 * panel's sink.
 *
 * Sink-routed like `requestDocumentSymbols`, for the same reason: the consumer
 * is a DOM panel and this module stays DOM-free. Sequence-gated, so a response
 * overtaken by a fresher keystroke never repaints the panel with values for
 * text the user has left behind — the one failure mode that would make the
 * panel lie rather than merely lag.
 *
 * An empty entry list is meaningful (the last expression was deleted, or the
 * document is pure data) and clears the panel; a `null`/stale result leaves
 * the last good values standing.
 */
async function requestEvalDocument(): Promise<void> {
  if (!_mainView || !_evalSink) return;
  const seq = ++_evalRequestSeq;
  const result = await lspRequest('sjon/evalDocument', {
    textDocument: { uri: DOC_URI },
  });
  if (seq !== _evalRequestSeq) return; // Superseded by a fresher sync.
  if (!result || isStale(result) || !isEvalResult(result)) return;
  _evalSink?.(result.entries);
}

/** Register the evaluated-output consumer. Passing null detaches it, which
 *  also stops `sjon/evalDocument` being requested at all. */
export function setEvalSink(fn: ((entries: LspEvalEntry[]) => void) | null): void {
  _evalSink = fn;
}

/**
 * Sync the playground document with the LSP server. Idempotent — the first
 * call sends didOpen, subsequent calls send didChange with a bumped version.
 * After the sync, fire a diagnostic request so the gutter updates.
 */
export function syncDocument(source: string): void {
  if (!_ready || !_mainView) return;
  _docVersion++;
  _lastSyncedText = source;
  if (!_opened) {
    lspNotify('textDocument/didOpen', {
      textDocument: { uri: DOC_URI, languageId: 'sjon', version: _docVersion, text: source },
    });
    _opened = true;
  } else {
    lspNotify('textDocument/didChange', {
      textDocument: { uri: DOC_URI, version: _docVersion },
      contentChanges: [{ text: source }],
    });
  }
  void requestDiagnostics();
  void requestFoldingRanges();
  void requestDocumentSymbols();
  void requestInlayHints();
  void requestEvalDocument();
}

/**
 * Request completions for the main document at `position`. The editor's
 * change → sync path is debounced, so the server's copy can be stale at the
 * keystroke that opens the popup; when `sourceText` differs from the last
 * synced text we flush a sync first (whose version bump also keeps the
 * transport's stale-gate coherent). Returns `null` when the transport isn't
 * ready or the result is dropped (stale, error, or no items).
 */
export async function requestCompletion(
  sourceText: string,
  position: LspPosition,
): Promise<LspCompletionItem[] | null> {
  if (!_ready) return null;
  if (sourceText !== _lastSyncedText) syncDocument(sourceText);
  const result = await lspRequest('textDocument/completion', {
    textDocument: { uri: DOC_URI },
    position,
  });
  return Array.isArray(result) ? (result as LspCompletionItem[]) : null;
}

/**
 * Request a hover for the main document at `position`. Mirrors
 * `requestCompletion`: flushes a sync when the keystroke's source is ahead of
 * the server's copy, and returns `null` for a not-ready transport, a stale/
 * dropped result, or a non-hover shape.
 */
export async function requestHover(
  sourceText: string,
  position: LspPosition,
): Promise<LspHover | null> {
  if (!_ready) return null;
  if (sourceText !== _lastSyncedText) syncDocument(sourceText);
  const result = await lspRequest('textDocument/hover', {
    textDocument: { uri: DOC_URI },
    position,
  });
  if (!result || isStale(result)) return null;
  return isLspHover(result) ? result : null;
}

/**
 * Request signature help for the main document at `position`. Thin, like
 * `requestHover`; the extension (lsp-signature.ts) owns the sequence gate that
 * drops responses superseded by a fresher cursor move, since only it can tell a
 * superseded result from a genuine "no signature here" (which dismisses).
 */
export async function requestSignatureHelp(
  sourceText: string,
  position: LspPosition,
): Promise<LspSignatureHelp | null> {
  if (!_ready) return null;
  if (sourceText !== _lastSyncedText) syncDocument(sourceText);
  const result = await lspRequest('textDocument/signatureHelp', {
    textDocument: { uri: DOC_URI },
    position,
  });
  if (!result || isStale(result)) return null;
  return isLspSignatureHelp(result) ? result : null;
}

/**
 * Ask the server to format the main document. Returns the TextEdits, or null
 * when the transport isn't ready or the result is dropped.
 *
 * Flushes a pending sync first, like `requestHover`: the edits carry offsets
 * into the server's copy of the document, so formatting against a copy that
 * lags the editor by a keystroke would splice text at the wrong places. The
 * notification is queued ahead of the request on the same channel, so the
 * server has applied it by the time it formats.
 */
export async function requestFormatting(sourceText: string): Promise<LspTextEdit[] | null> {
  if (!_ready) return null;
  if (sourceText !== _lastSyncedText) syncDocument(sourceText);
  const result = await lspRequest('textDocument/formatting', {
    textDocument: { uri: DOC_URI },
    options: { tabSize: 2, insertSpaces: true },
  });
  if (!result || isStale(result) || !Array.isArray(result)) return null;
  return result as LspTextEdit[];
}

/**
 * Replace the user-authored schema set and refresh every pane. Sends
 * `sjon/setSchemas`, routes each schema's diagnostics back to its pane,
 * then re-pulls the main document (the server recomposed + re-validated
 * against the new schema). Returns the per-schema reports so the caller
 * can relabel tabs from the parsed plugin `:name`; returns `[]` when the
 * request is dropped (stale, superseded, or transport not ready).
 */
export async function syncSchemas(schemas: SchemaInput[]): Promise<SchemaReport[]> {
  if (!_ready || !_transport) return [];

  // Bump the version before sending so the request's version is maximal,
  // keeping the transport's stale-gate from dropping the response in the
  // common case where the doc isn't edited mid-request.
  _docVersion++;
  const seq = ++_schemaRequestSeq;
  const result = await lspRequest('sjon/setSchemas', { schemas });
  if (seq !== _schemaRequestSeq) return []; // Superseded by a fresher set.
  if (!result || isStale(result) || !isSetSchemasResult(result)) return [];

  // Route each report to its pane; clear panes that produced no report.
  const reported = new Set<string>();
  for (const report of result.reports) {
    reported.add(report.uri);
    const view = _schemaViews.get(report.uri);
    if (view) pushReportToView(view, report.items);
  }
  for (const [uri, view] of _schemaViews) {
    if (!reported.has(uri)) pushReportToView(view, []);
  }

  // The composed schema changed — re-validate the main document, and refresh
  // the views that read the schema rather than the syntax. Two do: ghost
  // defaults exist only because a schema declares them, and the evaluated
  // values depend on the schema to decide which forms are expressions at all
  // (a data form shadows an expr func of the same name). (Folding and the
  // outline are purely syntactic and are already current.) Without this the
  // initial boot order — sync, then install deep-linked schemas — leaves both
  // views showing the pre-schema document until the next keystroke.
  await requestDiagnostics();
  void requestInlayHints();
  void requestEvalDocument();

  return result.reports;
}

declare global {
  interface Window {
    __lsp_ready?: boolean;
  }
}

/** The sidecar URL beside a wasm URL: `…/sjon-lsp.wasm` → `…/sjon-lsp.meta.json`
 *  (preserving any base-path prefix `path()` added). */
function metaUrlFor(wasmUrl: string): string {
  return wasmUrl.endsWith('.wasm')
    ? `${wasmUrl.slice(0, -'.wasm'.length)}.meta.json`
    : `${wasmUrl}.meta.json`;
}

export async function initLSP(wasmUrl?: string, opts?: InitLspOpts): Promise<void> {
  const baseUrl = wasmUrl || '/sjon-lsp.wasm';
  const mode = opts?.mode || 'worker';

  // Staleness guard. Fetch the build-staged sidecar, cache-bust the wasm URL
  // with its short hash so a byte-changed artifact dodges the HTTP cache, and
  // keep the recorded serverInfo to compare against the running server after
  // boot. Every degraded path (no sidecar, fetch failure) yields null → no
  // cache-bust, verdict 'unknown', no badge — the guard never blocks boot.
  const meta = await fetchWasmMeta(metaUrlFor(baseUrl));
  const url = wasmUrlWithVersion(baseUrl, meta);

  _transport = await createLspTransport({ mode, wasmUrl: url });
  _transport.on('error', (e: unknown) => console.error('[LSP]', e));
  await _transport.init();
  _ready = true;
  if (typeof window !== 'undefined') window.__lsp_ready = true;

  if (compareWasmIdentity(meta, _transport.getServerInfo()) === 'mismatch') {
    console.warn(
      '[LSP] sjon-lsp.wasm looks stale: the running server disagrees with the ' +
        'staged build. Run `zig build landing-page-assets` to refresh it.',
    );
    opts?.onStale?.();
  }
}

/** Register the main document editor (the always-present "document" tab). */
export function setMainView(view: EditorView): void {
  _mainView = view;
}

/** Register a schema pane's editor under its URI so `syncSchemas` can
 *  route diagnostics back to it. */
export function registerSchemaView(uri: string, view: EditorView): void {
  _schemaViews.set(uri, view);
}

/** Drop a schema pane: clear its lint layer, then forget it. Called when
 *  a tab is removed (before the editor itself is destroyed). */
export function unregisterSchemaView(uri: string): void {
  const view = _schemaViews.get(uri);
  if (view) pushReportToView(view, []);
  _schemaViews.delete(uri);
}

export function destroyLSP(): void {
  if (_opened) lspNotify('textDocument/didClose', { textDocument: { uri: DOC_URI } });
  _opened = false;
  _ready = false;
  _lastSyncedText = null;
  _mainView = null;
  _outlineSink = null;
  _evalSink = null;
  _schemaViews.clear();
  if (_transport) {
    try {
      _transport.destroy();
    } catch {
      /* best-effort teardown */
    }
    _transport = null;
  }
}
