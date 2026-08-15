/// <reference lib="webworker" />
/**
 * SJON-LSP Web Worker.
 *
 * Owns the WASM module. All LSP calls from the main thread arrive here as
 * structured messages, are pumped through the WASM synchronously on this
 * thread, and are posted back. The main thread's keystroke path is never
 * blocked by the WASM work.
 *
 * Protocol (see lsp-worker-backend.ts for the mirror):
 *   main -> worker: { kind: 'init', wasmUrl }
 *                 | { kind: 'req', id, method, params }
 *                 | { kind: 'notif', method, params }
 *                 | { kind: 'dispose' }
 *   worker -> main: { kind: 'ready' }
 *                 | { kind: 'res', id, result }
 *                 | { kind: 'err', id, error }
 *                 | { kind: 'diags', uri, diagnostics }
 *                 | { kind: 'fatal', error }
 *
 * Self-contained — no relative runtime imports — because Vite bundles the
 * worker as its own chunk via
 * `new Worker(new URL('./lsp-worker.ts', import.meta.url), { type: 'module' })`.
 */

import type {
  JsonRpcResponse,
  PublishDiagnosticsNotification,
  ServerInfo,
  SjonLspExports,
  WorkerInbound,
  WorkerOutbound,
} from './lsp-types';

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/**
 * Compile a fetched wasm response, streaming it only when the host allows.
 *
 * `WebAssembly.compileStreaming` refuses any `Content-Type` that is not
 * `application/wasm`, and hugodaniel.com — where this playground is published
 * — serves `.wasm` as `application/octet-stream`. That killed the live page:
 * the worker died on boot with *"Incorrect response MIME type"* and the
 * fallback inline backend, which had the same bug, died right behind it.
 * `astro dev` and `astro preview` both set the type correctly, so nothing
 * local could reproduce it.
 *
 * Inlined (not imported from ./wasm-compile) for the same reason
 * `readServerInfo` below is — this worker is bundled as a self-contained
 * chunk with no relative runtime imports. **Keep the two in step**;
 * `wasm-compile.test.ts` lifts this function body out of the source text and
 * runs it against the same table as the module copy, so editing one alone
 * goes red. Rename it or fold it into an import and that gate reports it
 * missing rather than silently passing.
 */
async function compileWasmResponse(response: Response): Promise<WebAssembly.Module> {
  if (!response.ok) {
    throw new Error(`wasm fetch failed: ${response.url || '(no url)'} → HTTP ${response.status}`);
  }
  // Exact match, deliberately narrower than the spec: engines disagree about
  // parameters and casing, and guessing wrong the permissive way is the bug.
  if (response.headers.get('content-type')?.trim() === 'application/wasm') {
    return WebAssembly.compileStreaming(response);
  }
  return WebAssembly.compile(await response.arrayBuffer());
}

/** Pull `serverInfo` out of an `initialize` result, or null. Inlined (not
 *  imported from lsp-meta) because this worker is bundled as a self-contained
 *  chunk with no relative runtime imports. */
function readServerInfo(result: unknown): ServerInfo | null {
  if (typeof result !== 'object' || result === null) return null;
  const info = (result as { serverInfo?: unknown }).serverInfo;
  if (typeof info !== 'object' || info === null) return null;
  const rec = info as { name?: unknown; version?: unknown };
  return typeof rec.name === 'string' && typeof rec.version === 'string'
    ? { name: rec.name, version: rec.version }
    : null;
}

let wasm: SjonLspExports | null = null;
let ready = false;

// `self` inside a module worker is `DedicatedWorkerGlobalScope`. We narrow it
// here so `postMessage` / `onmessage` typings are correct without leaking the
// lib name across the rest of the module.
const workerSelf = self as unknown as DedicatedWorkerGlobalScope;

function post(msg: WorkerOutbound): void {
  workerSelf.postMessage(msg);
}

function isPublishDiagnostics(r: JsonRpcResponse): r is PublishDiagnosticsNotification {
  return (
    r.method === 'textDocument/publishDiagnostics' &&
    typeof r.params === 'object' &&
    r.params !== null
  );
}

function pump(json: string): JsonRpcResponse[] {
  if (!wasm) throw new Error('worker not initialised');
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

function emitDiags(responses: JsonRpcResponse[]): void {
  for (const r of responses) {
    if (!isPublishDiagnostics(r)) continue;
    post({
      kind: 'diags',
      uri: r.params.uri,
      diagnostics: r.params.diagnostics ?? [],
    });
  }
}

let reqIdCounter = 1;

workerSelf.onmessage = async (ev: MessageEvent<WorkerInbound>): Promise<void> => {
  const msg = ev.data;
  try {
    switch (msg.kind) {
      case 'init': {
        const response = await fetch(msg.wasmUrl || '/sjon-lsp.wasm');
        const mod = await compileWasmResponse(response);
        const instance = await WebAssembly.instantiate(mod, {});
        wasm = instance.exports as unknown as SjonLspExports;
        const initId = reqIdCounter++;
        const initResponses = pump(
          JSON.stringify({
            jsonrpc: '2.0',
            id: initId,
            method: 'initialize',
            params: { capabilities: {} },
          }),
        );
        let serverInfo: ServerInfo | null = null;
        for (const r of initResponses) {
          if (r.id === initId) {
            serverInfo = readServerInfo(r.result);
            break;
          }
        }
        emitDiags(initResponses);
        emitDiags(
          pump(
            JSON.stringify({
              jsonrpc: '2.0',
              method: 'initialized',
              params: {},
            }),
          ),
        );
        ready = true;
        // `exactOptionalPropertyTypes`: omit the key rather than post
        // `serverInfo: null`.
        post(serverInfo !== null ? { kind: 'ready', serverInfo } : { kind: 'ready' });
        return;
      }
      case 'req': {
        if (!ready) {
          post({ kind: 'res', id: msg.id, result: null });
          return;
        }
        const wasmId = reqIdCounter++;
        const responses = pump(
          JSON.stringify({
            jsonrpc: '2.0',
            id: wasmId,
            method: msg.method,
            params: msg.params,
          }),
        );
        emitDiags(responses);
        let result: unknown = null;
        for (const r of responses)
          if (r.id === wasmId) {
            result = r.result;
            break;
          }
        post({ kind: 'res', id: msg.id, result });
        return;
      }
      case 'notif': {
        if (!ready) return;
        const responses = pump(
          JSON.stringify({
            jsonrpc: '2.0',
            method: msg.method,
            params: msg.params,
          }),
        );
        emitDiags(responses);
        return;
      }
      case 'dispose': {
        wasm = null;
        ready = false;
        return;
      }
    }
  } catch (e) {
    const errMsg = e instanceof Error ? e.message : String(e);
    if (msg && msg.kind === 'req') {
      post({ kind: 'err', id: msg.id, error: errMsg });
    } else {
      post({ kind: 'fatal', error: errMsg });
    }
  }
};
