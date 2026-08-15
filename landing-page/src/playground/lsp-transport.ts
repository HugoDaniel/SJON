/**
 * SJON LSP transport abstraction.
 *
 * Lifted from pngine/web/editor/src/lib/lsp-transport.js verbatim — the
 * transport is language-agnostic, only the backends below resolve to the
 * sjon_lsp_* WASM exports.
 *
 * Presents the same async API to lsp-integration.ts regardless of where the
 * WASM actually runs (main-thread inline, Web Worker, or an in-memory fake
 * used in tests). Three guarantees:
 *
 *   1. Every `request()` returns a Promise that either resolves to a fresh
 *      LSP result, or to the sentinel `STALE` when the caller's document
 *      version has been superseded.
 *   2. `publishDiagnostics` notifications are demultiplexed via `on()`.
 *   3. Worker boot is non-blocking: if it fails, the transport silently
 *      falls back to the inline backend.
 *
 * Backends expose `LspBackend` (see ./lsp-types). The transport adds version
 * tracking, the stale sentinel, and listener mux.
 */

import type {
  BackendFactory,
  DiagnosticsListener,
  DiagnosticsPayload,
  ErrorListener,
  ListenerKind,
  LspBackend,
  LspTransport,
  LspTransportMode,
  LspTransportOpts,
  ServerInfo,
  StaleSentinel,
} from './lsp-types';
// Value imports carry `.ts` (the type-only ones above do not need it): this
// module is now driven directly by `node --test --experimental-strip-types`,
// whose resolver does not guess extensions. Same convention as lsp-eval.ts,
// lsp-outline.ts, lsp-hover.ts.
import { STALE } from './lsp-types.ts';

export { STALE } from './lsp-types.ts';
export type { LspTransport, LspTransportOpts, LspTransportMode, StaleSentinel };

interface TransportListeners {
  diagnostics: Set<DiagnosticsListener>;
  error: Set<ErrorListener>;
}

export async function createLspTransport(opts: LspTransportOpts): Promise<LspTransport> {
  const mode: LspTransportMode = opts.mode || 'inline';
  const listeners: TransportListeners = {
    diagnostics: new Set(),
    error: new Set(),
  };
  let backend: LspBackend | null = null;
  let effectiveMode: LspTransportMode = mode;
  let currentVersion = 0;
  let ready = false;
  let destroyed = false;

  function wireBackend(be: LspBackend): void {
    const forwardDiag: DiagnosticsListener = (payload: DiagnosticsPayload) => {
      for (const fn of listeners.diagnostics) {
        try {
          fn(payload);
        } catch (e) {
          emitError(e);
        }
      }
    };
    const forwardErr: ErrorListener = (e: unknown) => emitError(e);
    be.on('diagnostics', forwardDiag);
    be.on('error', forwardErr);
  }

  function emitError(e: unknown): void {
    for (const fn of listeners.error) {
      try {
        fn(e);
      } catch {
        /* listener failure is non-fatal */
      }
    }
  }

  async function makeBackend(chosenMode: LspTransportMode): Promise<LspBackend> {
    if (chosenMode === 'fake') {
      const be = opts.backend;
      if (!be) throw new Error('mode=fake requires opts.backend');
      return be;
    }
    if (chosenMode === 'worker') {
      const factory: BackendFactory = opts._workerFactory || defaultWorkerFactory;
      return await factory(opts);
    }
    const factory: BackendFactory = opts._inlineFactory || defaultInlineFactory;
    return await factory(opts);
  }

  const transport: LspTransport = {
    get mode(): LspTransportMode {
      return effectiveMode;
    },

    async init(): Promise<void> {
      if (ready || destroyed) return;
      try {
        backend = await makeBackend(mode);
        await backend.init();
        wireBackend(backend);
        ready = true;
      } catch (e) {
        emitError(e);
        // Tear the failed backend down before replacing it. A worker backend
        // whose `init()` rejected is not necessarily dead — the 5 s timeout is
        // precisely the slow-not-dead case — and its Worker goes on booting a
        // second WASM instance beside the inline one about to be created here.
        // Nothing observes it and nothing ever collects it.
        if (backend) {
          try {
            backend.destroy();
          } catch {
            /* best-effort teardown */
          }
          backend = null;
        }
        if (mode === 'worker') {
          effectiveMode = 'inline';
          const factory: BackendFactory = opts._inlineFactory || defaultInlineFactory;
          backend = await factory(opts);
          await backend.init();
          wireBackend(backend);
          ready = true;
        } else {
          ready = false;
        }
      }
    },

    async request(
      method: string,
      params: unknown,
      version: number,
    ): Promise<unknown | StaleSentinel> {
      if (!ready || destroyed || !backend) return STALE;
      const myVersion = version | 0;
      const result = await backend.request(method, params);
      if (myVersion < currentVersion) return STALE;
      return result;
    },

    notify(method: string, params: unknown, version: number): void {
      if (!ready || destroyed || !backend) return;
      const v = version | 0;
      if (v > currentVersion) currentVersion = v;
      backend.notify(method, params);
    },

    on(kind: ListenerKind, fn: DiagnosticsListener | ErrorListener): void {
      if (kind === 'diagnostics') {
        listeners.diagnostics.add(fn as DiagnosticsListener);
      } else if (kind === 'error') {
        listeners.error.add(fn as ErrorListener);
      }
    },

    off(kind: ListenerKind, fn: DiagnosticsListener | ErrorListener): void {
      if (kind === 'diagnostics') {
        listeners.diagnostics.delete(fn as DiagnosticsListener);
      } else if (kind === 'error') {
        listeners.error.delete(fn as ErrorListener);
      }
    },

    bumpVersion(v: number): void {
      const n = v | 0;
      if (n > currentVersion) currentVersion = n;
    },

    getServerInfo(): ServerInfo | null {
      return backend?.getServerInfo?.() ?? null;
    },

    destroy(): void {
      destroyed = true;
      ready = false;
      listeners.diagnostics.clear();
      listeners.error.clear();
      if (backend) {
        try {
          backend.destroy();
        } catch {
          /* best-effort teardown */
        }
      }
      backend = null;
    },
  };

  return transport;
}

const defaultInlineFactory: BackendFactory = async (opts) => {
  const { createInlineBackend } = await import('./lsp-inline-backend');
  return createInlineBackend(opts);
};

const defaultWorkerFactory: BackendFactory = async (opts) => {
  const { createWorkerBackend } = await import('./lsp-worker-backend');
  return createWorkerBackend(opts);
};
