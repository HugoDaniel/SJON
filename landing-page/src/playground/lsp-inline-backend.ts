/**
 * Inline backend — runs sjon-lsp.wasm directly on the main thread.
 *
 * Worker boot fallback. Each request/notify blocks the main thread on the
 * WASM pump; the worker backend is the fast path, this is the safety net.
 *
 * Intentionally "dumb": no version gating, no stale sentinel, no listener
 * multiplex — those live in lsp-transport.ts on top.
 */

import type {
  DiagnosticsListener,
  DiagnosticsPayload,
  ErrorListener,
  JsonRpcResponse,
  ListenerKind,
  LspBackend,
  LspTransportOpts,
  PublishDiagnosticsNotification,
  ServerInfo,
  SjonLspExports,
} from './lsp-types';
import { parseServerInfo } from './lsp-meta';
import { compileWasmResponse } from './wasm-compile';

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** Pull `serverInfo` out of an `initialize` result, or null if absent. */
function serverInfoOf(result: unknown): ServerInfo | null {
  if (typeof result !== 'object' || result === null) return null;
  return parseServerInfo((result as { serverInfo?: unknown }).serverInfo);
}

interface InlineListeners {
  diagnostics: DiagnosticsListener[];
  error: ErrorListener[];
}

function isPublishDiagnostics(r: JsonRpcResponse): r is PublishDiagnosticsNotification {
  return (
    r.method === 'textDocument/publishDiagnostics' &&
    typeof r.params === 'object' &&
    r.params !== null
  );
}

export function createInlineBackend(opts: LspTransportOpts = {}): LspBackend {
  const { wasmUrl } = opts;
  let wasm: SjonLspExports | null = null;
  let reqId = 100;
  let serverInfo: ServerInfo | null = null;
  const listeners: InlineListeners = { diagnostics: [], error: [] };

  function emitFromResponses(responses: JsonRpcResponse[]): void {
    for (const r of responses) {
      if (!isPublishDiagnostics(r)) continue;
      const payload: DiagnosticsPayload = {
        uri: r.params.uri,
        diagnostics: r.params.diagnostics ?? [],
      };
      for (const fn of listeners.diagnostics) {
        try {
          fn(payload);
        } catch (e) {
          for (const ef of listeners.error) {
            try {
              ef(e);
            } catch {
              /* listener failure is non-fatal */
            }
          }
        }
      }
    }
  }

  function pump(json: string): JsonRpcResponse[] {
    if (!wasm) throw new Error('inline backend not initialised');
    const w = wasm;
    const encoded = encoder.encode(json);
    const ptr = w.sjon_lsp_alloc(encoded.length);
    if (!ptr) throw new Error('WASM alloc failed');
    new Uint8Array(w.memory.buffer, ptr, encoded.length).set(encoded);
    w.sjon_lsp_send(ptr, encoded.length);
    w.sjon_lsp_dealloc(ptr, encoded.length);

    const responses: JsonRpcResponse[] = [];
    for (;;) {
      const rptr = w.sjon_lsp_recv();
      if (!rptr) break;
      const len = new DataView(w.memory.buffer).getUint32(rptr, true);
      const msg = decoder.decode(new Uint8Array(w.memory.buffer, rptr + 4, len));
      w.sjon_lsp_dealloc(rptr, len + 4);
      responses.push(JSON.parse(msg) as JsonRpcResponse);
    }
    return responses;
  }

  return {
    async init(): Promise<void> {
      const url = wasmUrl || '/sjon-lsp.wasm';
      const response = await fetch(url);
      const mod = await compileWasmResponse(response);
      const instance = await WebAssembly.instantiate(mod, {});
      wasm = instance.exports as unknown as SjonLspExports;
      const initResponses = pump(
        JSON.stringify({
          jsonrpc: '2.0',
          id: 1,
          method: 'initialize',
          params: { capabilities: {} },
        }),
      );
      for (const r of initResponses) {
        if (r.id === 1) {
          serverInfo = serverInfoOf(r.result);
          break;
        }
      }
      emitFromResponses(initResponses);
      emitFromResponses(
        pump(
          JSON.stringify({
            jsonrpc: '2.0',
            method: 'initialized',
            params: {},
          }),
        ),
      );
    },

    async request(method: string, params: unknown): Promise<unknown> {
      if (!wasm) return null;
      const id = reqId++;
      const responses = pump(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
      emitFromResponses(responses);
      for (const r of responses) if (r.id === id) return r.result;
      return null;
    },

    notify(method: string, params: unknown): void {
      if (!wasm) return;
      const responses = pump(JSON.stringify({ jsonrpc: '2.0', method, params }));
      emitFromResponses(responses);
    },

    getServerInfo(): ServerInfo | null {
      return serverInfo;
    },

    on(kind: ListenerKind, fn: DiagnosticsListener | ErrorListener): void {
      if (kind === 'diagnostics') {
        listeners.diagnostics.push(fn as DiagnosticsListener);
      } else if (kind === 'error') {
        listeners.error.push(fn as ErrorListener);
      }
    },

    off(kind: ListenerKind, fn: DiagnosticsListener | ErrorListener): void {
      if (kind === 'diagnostics') {
        listeners.diagnostics = listeners.diagnostics.filter((f) => f !== fn);
      } else if (kind === 'error') {
        listeners.error = listeners.error.filter((f) => f !== fn);
      }
    },

    destroy(): void {
      listeners.diagnostics = [];
      listeners.error = [];
      wasm = null;
    },
  };
}
