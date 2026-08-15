// Shared JSON-RPC pump for the `sjon-lsp.wasm` end-to-end tests.
//
// NOT a `*.test.ts` file, so node's `--test` glob skips it; the sibling
// `lsp-*.test.ts` files import it. The pump (alloc → send → drain
// `[u32 len][bytes]` frames → dealloc) mirrors
// `landing-page/src/playground/lsp-inline-backend.ts`; the wasm is the one
// `zig build wasm-lsp` installs to `zig-out/bin/`.

import path from 'node:path';
import { promises as fs } from 'node:fs';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
export const wasmPath = path.join(root, 'zig-out/bin/sjon-lsp.wasm');

interface LspExports {
  memory: WebAssembly.Memory;
  sjon_lsp_alloc: (len: number) => number;
  sjon_lsp_dealloc: (ptr: number, len: number) => void;
  sjon_lsp_send: (ptr: number, len: number) => void;
  sjon_lsp_recv: () => number;
}

export interface RpcResponse {
  id?: number | string | null;
  result?: unknown;
  method?: string;
  params?: unknown;
}

/** A live LSP instance: `request` returns the matching response's `result`
 *  (or `undefined` if none), `notify` is fire-and-forget. Both pump the
 *  message through the wasm synchronously on this thread. */
export interface RawLsp {
  request: (method: string, params: unknown) => unknown;
  notify: (method: string, params: unknown) => void;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** Inferred type guard, the one canonical copy for the `lsp-*.test.ts` suite.
 *  The `!Array.isArray` arm is load-bearing: `typeof [] === 'object'` and
 *  `[] !== null`, so without it a JSON array would narrow to a record. */
export function isRecord(x: unknown): x is Record<string, unknown> {
  return typeof x === 'object' && x !== null && !Array.isArray(x);
}

/** Fresh wasm instance with NO handshake — the caller drives `initialize`
 *  itself (used by the initialize test, which inspects that result). */
export async function makeRawLsp(): Promise<RawLsp> {
  const bytes = await fs.readFile(wasmPath);
  const mod = await WebAssembly.compile(bytes);
  const instance = await WebAssembly.instantiate(mod, {});
  const w = instance.exports as unknown as LspExports;

  function pump(msg: object): RpcResponse[] {
    const encoded = encoder.encode(JSON.stringify(msg));
    const ptr = w.sjon_lsp_alloc(encoded.length);
    if (!ptr) throw new Error('WASM alloc failed');
    new Uint8Array(w.memory.buffer, ptr, encoded.length).set(encoded);
    w.sjon_lsp_send(ptr, encoded.length);
    w.sjon_lsp_dealloc(ptr, encoded.length);

    const out: RpcResponse[] = [];
    for (;;) {
      const rptr = w.sjon_lsp_recv();
      if (!rptr) break;
      const len = new DataView(w.memory.buffer).getUint32(rptr, true);
      const text = decoder.decode(new Uint8Array(w.memory.buffer, rptr + 4, len));
      w.sjon_lsp_dealloc(rptr, len + 4);
      out.push(JSON.parse(text) as RpcResponse);
    }
    return out;
  }

  let id = 1;
  return {
    request(method: string, params: unknown): unknown {
      const myId = id++;
      const responses = pump({ jsonrpc: '2.0', id: myId, method, params });
      for (const r of responses) if (r.id === myId) return r.result;
      return undefined;
    },
    notify(method: string, params: unknown): void {
      pump({ jsonrpc: '2.0', method, params });
    },
  };
}

/** A `RawLsp` with the `initialize` / `initialized` handshake already done —
 *  the common case for feature tests (hover, signature, folding, …). */
export async function makeLsp(): Promise<RawLsp> {
  const lsp = await makeRawLsp();
  lsp.request('initialize', { capabilities: {} });
  lsp.notify('initialized', {});
  return lsp;
}

export function didOpen(lsp: RawLsp, uri: string, text: string): void {
  lsp.notify('textDocument/didOpen', {
    textDocument: { uri, languageId: 'sjon', version: 1, text },
  });
}

export function didChange(lsp: RawLsp, uri: string, version: number, text: string): void {
  lsp.notify('textDocument/didChange', {
    textDocument: { uri, version },
    contentChanges: [{ text }],
  });
}
