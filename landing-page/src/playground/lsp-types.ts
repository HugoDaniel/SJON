/**
 * Shared types for the SJON LSP playground transport.
 *
 * - LSP wire shapes (Position, Range, Diagnostic, DiagnosticReport)
 * - The transport ↔ backend contract (`LspBackend`, factory opts)
 * - The Worker IPC envelope (`WorkerInbound` ↔ `WorkerOutbound`)
 * - The position↔offset conversion every consumer of those shapes needs
 *
 * Imported across `lsp-transport.ts`, `lsp-inline-backend.ts`,
 * `lsp-worker-backend.ts`, `lsp-worker.ts`, `lsp-integration.ts`, and the
 * mapper modules (`lsp-hover.ts`, `lsp-actions.ts`).
 */

import type { Text } from '@codemirror/state';

// ----- LSP wire shapes (subset of LSP 3.17 we actually touch) ---------------

export interface LspPosition {
  line: number;
  character: number;
}

/**
 * Resolve an LSP position to a CodeMirror offset in `doc`, clamped.
 *
 * Total by construction: an out-of-range line clamps to the document's
 * start/end and an out-of-range character to its line's end, because these
 * positions arrive from a server whose copy of the document may lag the
 * editor's by a keystroke. Returning an offset that is merely *stale* keeps
 * the feature degrading into a slightly-off highlight; throwing would take
 * the whole lint pass down with it.
 *
 * CodeMirror offsets are UTF-16 code units — the unit the server's negotiated
 * `utf-16` encoding counts in — so the mapping is exact, no surrogate
 * handling needed.
 */
export function posToOffset(doc: Text, line: number, character: number): number {
  const lineNo = (line | 0) + 1;
  if (lineNo < 1) return 0;
  if (lineNo > doc.lines) return doc.length;
  const l = doc.line(lineNo);
  const offset = l.from + (character | 0);
  return offset > l.to ? l.to : offset;
}

/** `posToOffset` for a whole range. Never inverted: a server range whose end
 *  precedes its start comes back swapped rather than as a negative span. */
export function rangeToOffsets(doc: Text, range: LspRange): { from: number; to: number } {
  const from = posToOffset(doc, range.start.line, range.start.character);
  const to = posToOffset(doc, range.end.line, range.end.character);
  return from <= to ? { from, to } : { from: to, to: from };
}

export interface LspRange {
  start: LspPosition;
  end: LspPosition;
}

export type LspSeverity = 1 | 2 | 3 | 4;

/** The `serverInfo` an LSP reports from `initialize`. The playground reads it
 *  back through the transport to compare the running server against the
 *  build-staged sidecar (see lsp-meta.ts). */
export interface ServerInfo {
  name: string;
  version: string;
}

export interface LspDiagnostic {
  range: LspRange;
  severity?: LspSeverity;
  code?: string | number;
  message?: string;
}

export interface DiagnosticsPayload {
  uri: string;
  diagnostics: LspDiagnostic[];
}

/** Result shape of `textDocument/diagnostic` (pull diagnostics). */
export type DiagnosticReport =
  | { kind: 'full'; items: LspDiagnostic[] }
  | { kind: 'unchanged'; resultId?: string };

/**
 * One foldable region from `textDocument/foldingRange`. The server emits
 * 0-based line numbers and has already dropped single-line spans; the client
 * maps these onto CodeMirror byte ranges in `lsp-folding.ts`.
 */
export interface LspFoldingRange {
  startLine: number;
  endLine: number;
}

/**
 * Result item of `textDocument/completion`. The WASM serializer emits a
 * bare item array (never a `CompletionList`), `documentation` as a plain
 * string (not `MarkupContent`), and no `textEdit` — the client computes
 * the replacement range itself.
 */
export interface LspCompletionItem {
  label: string;
  /** CompletionItemKind — the server emits 3 (function), 4 (constructor),
   *  5 (field), and 20 (enum member). */
  kind?: number;
  detail?: string;
  documentation?: string;
  insertText?: string;
  /** 1 = plain text, 2 = LSP snippet syntax. Present only with `insertText`. */
  insertTextFormat?: 1 | 2;
  /** `[1]` marks the item deprecated. */
  tags?: number[];
  sortText?: string;
  filterText?: string;
  commitCharacters?: string[];
}

// ----- sjon/setSchemas (non-standard extension) -----------------------------

/** One user-authored schema pane sent to `sjon/setSchemas`. */
export interface SchemaInput {
  uri: string;
  text: string;
}

export interface SetSchemasParams {
  schemas: SchemaInput[];
}

/**
 * Per-schema result. `name` is the parsed plugin `:name` (`""` when the
 * manifest is invalid/unnamed) used for the tab label; `items` are the
 * schema's own parse/meta/aggregate diagnostics, offset against its own
 * `text`.
 */
export interface SchemaReport {
  uri: string;
  name: string;
  items: LspDiagnostic[];
}

export interface SetSchemasResult {
  reports: SchemaReport[];
}

// ----- WASM ABI -------------------------------------------------------------

export interface SjonLspExports {
  memory: WebAssembly.Memory;
  sjon_lsp_alloc: (len: number) => number;
  sjon_lsp_dealloc: (ptr: number, len: number) => void;
  sjon_lsp_send: (ptr: number, len: number) => void;
  sjon_lsp_recv: () => number;
}

// ----- JSON-RPC frames the WASM emits --------------------------------------

export interface JsonRpcResponse {
  jsonrpc?: '2.0';
  id?: number | string | null;
  result?: unknown;
  error?: { code: number; message: string };
  method?: string;
  params?: unknown;
}

export interface PublishDiagnosticsNotification {
  jsonrpc?: '2.0';
  method: 'textDocument/publishDiagnostics';
  params: {
    uri: string;
    diagnostics?: LspDiagnostic[];
  };
}

// ----- Transport / backend contract ----------------------------------------

export type ListenerKind = 'diagnostics' | 'error';

export type DiagnosticsListener = (payload: DiagnosticsPayload) => void;
export type ErrorListener = (err: unknown) => void;

export interface LspBackend {
  init: () => Promise<void>;
  request: (method: string, params: unknown) => Promise<unknown>;
  notify: (method: string, params: unknown) => void;
  on: ((kind: 'diagnostics', fn: DiagnosticsListener) => void) &
    ((kind: 'error', fn: ErrorListener) => void);
  off: ((kind: 'diagnostics', fn: DiagnosticsListener) => void) &
    ((kind: 'error', fn: ErrorListener) => void);
  /** The `serverInfo` captured during the backend's `initialize` handshake,
   *  or null before init / when the server reported none. Optional so a
   *  backend that doesn't track it still satisfies the contract. */
  getServerInfo?: () => ServerInfo | null;
  destroy: () => void;
}

export type BackendFactory = (opts: LspTransportOpts) => Promise<LspBackend>;

export type LspTransportMode = 'inline' | 'worker' | 'fake';

export interface LspTransportOpts {
  /** Selects which backend to construct in `createLspTransport`. */
  mode?: LspTransportMode;
  /** URL of the LSP WASM module. Defaults to `/sjon-lsp.wasm`. */
  wasmUrl?: string;
  /** Required when `mode === 'fake'`: a pre-built backend. */
  backend?: LspBackend;
  /** Test seam: override the worker backend factory. */
  _workerFactory?: BackendFactory;
  /** Test seam: override the inline backend factory. */
  _inlineFactory?: BackendFactory;
}

/** Sentinel returned from `transport.request()` when the doc version moved on. */
export const STALE = { stale: true } as const;
export type StaleSentinel = typeof STALE;

export interface LspTransport {
  readonly mode: LspTransportMode;
  init: () => Promise<void>;
  request: (method: string, params: unknown, version: number) => Promise<unknown | StaleSentinel>;
  notify: (method: string, params: unknown, version: number) => void;
  on: ((kind: 'diagnostics', fn: DiagnosticsListener) => void) &
    ((kind: 'error', fn: ErrorListener) => void);
  off: ((kind: 'diagnostics', fn: DiagnosticsListener) => void) &
    ((kind: 'error', fn: ErrorListener) => void);
  bumpVersion: (v: number) => void;
  /** The running server's `serverInfo`, or null before init / when unknown.
   *  Delegates to the active backend. */
  getServerInfo: () => ServerInfo | null;
  destroy: () => void;
}

// ----- Worker IPC envelope --------------------------------------------------

export type WorkerInbound =
  | { kind: 'init'; wasmUrl?: string }
  | { kind: 'req'; id: number; method: string; params: unknown }
  | { kind: 'notif'; method: string; params: unknown }
  | { kind: 'dispose' };

export type WorkerOutbound =
  | { kind: 'ready'; serverInfo?: ServerInfo }
  | { kind: 'res'; id: number; result: unknown }
  | { kind: 'err'; id: number; error: string }
  | { kind: 'diags'; uri: string; diagnostics: LspDiagnostic[] }
  | { kind: 'fatal'; error: string };

// ----- Playground boot opts -------------------------------------------------

export interface InitLspOpts {
  mode?: LspTransportMode;
  /** Called once after boot when the running server's `serverInfo` disagrees
   *  with the build-staged sidecar — the playground unhides its stale badge. */
  onStale?: () => void;
}
