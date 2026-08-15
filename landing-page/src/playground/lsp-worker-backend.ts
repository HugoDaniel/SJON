/**
 * Worker backend — main-thread client for lsp-worker.ts.
 *
 * Implements the backend contract from lsp-transport.ts. Each request()
 * returns a Promise resolved when the worker posts back a matching res/err
 * message; notifications are fire-and-forget; publishDiagnostics arrives as
 * `diags` messages and is forwarded to every listener registered via
 * on('diagnostics', ...).
 *
 * The transport layer above enforces version gating; this backend just
 * returns a value per request.
 */

import type {
  DiagnosticsListener,
  DiagnosticsPayload,
  ErrorListener,
  ListenerKind,
  LspBackend,
  LspTransportOpts,
  ServerInfo,
  WorkerInbound,
  WorkerOutbound,
} from './lsp-types';

interface WorkerListeners {
  diagnostics: DiagnosticsListener[];
  error: ErrorListener[];
}

/** Nothing rejects a pending request: an unanswerable one resolves to `null`,
 *  which is the "no result" every consumer already handles. */
interface PendingEntry {
  resolve: (value: unknown) => void;
}

export function createWorkerBackend(opts: LspTransportOpts = {}): LspBackend {
  const { wasmUrl } = opts;
  let worker: Worker | null = null;
  let readyResolve: (() => void) | null = null;
  let readyReject: ((reason?: unknown) => void) | null = null;
  const pending = new Map<number, PendingEntry>();
  const listeners: WorkerListeners = { diagnostics: [], error: [] };
  let nextId = 1;
  let serverInfo: ServerInfo | null = null;

  function emitErr(e: unknown): void {
    const err = e instanceof Error ? e : new Error(String(e));
    for (const fn of listeners.error) {
      try {
        fn(err);
      } catch {
        /* listener failure is non-fatal */
      }
    }
  }

  function handleMessage(ev: MessageEvent<WorkerOutbound>): void {
    const msg = ev.data;
    if (!msg || !msg.kind) return;
    switch (msg.kind) {
      case 'ready': {
        serverInfo = msg.serverInfo ?? null;
        if (readyResolve) {
          readyResolve();
          readyResolve = null;
          readyReject = null;
        }
        return;
      }
      case 'res': {
        const entry = pending.get(msg.id);
        if (!entry) return;
        pending.delete(msg.id);
        entry.resolve(msg.result);
        return;
      }
      case 'err': {
        const entry = pending.get(msg.id);
        if (!entry) return;
        pending.delete(msg.id);
        emitErr(new Error(msg.error));
        entry.resolve(null);
        return;
      }
      case 'diags': {
        const payload: DiagnosticsPayload = {
          uri: msg.uri,
          diagnostics: msg.diagnostics,
        };
        for (const fn of listeners.diagnostics) {
          try {
            fn(payload);
          } catch (e) {
            emitErr(e);
          }
        }
        return;
      }
      case 'fatal': {
        emitErr(new Error(msg.error));
        if (readyReject) {
          readyReject(new Error(msg.error));
          readyReject = null;
          readyResolve = null;
        }
        return;
      }
    }
  }

  function postToWorker(msg: WorkerInbound): void {
    if (!worker) return;
    worker.postMessage(msg);
  }

  /**
   * Answer every in-flight request with `null`.
   *
   * A request whose worker has gone away has no other ending: the Promise was
   * created in `request()` and only `handleMessage` settles it, so without
   * this the caller awaits forever and the panel behind it stops updating for
   * the life of the page. `null` rather than a rejection because that is what
   * an `err` frame already resolves to — consumers treat it as "no answer",
   * and a rejection here would surface as an unhandled one at every call site.
   */
  function settlePending(): void {
    for (const entry of pending.values()) entry.resolve(null);
    pending.clear();
  }

  /** Terminate the worker and forget it. Idempotent — both the init timeout
   *  and `destroy()` reach it, and the transport calls `destroy()` on the
   *  backend it just gave up on. */
  function teardownWorker(): void {
    if (!worker) return;
    try {
      worker.terminate();
    } catch {
      /* already terminated */
    }
    worker = null;
  }

  return {
    init(): Promise<void> {
      return new Promise<void>((resolve, reject) => {
        try {
          worker = new Worker(new URL('./lsp-worker.ts', import.meta.url), {
            type: 'module',
          });
        } catch (e) {
          reject(e);
          return;
        }
        readyResolve = resolve;
        readyReject = reject;
        const timeoutId = setTimeout(() => {
          if (readyReject) {
            const r = readyReject;
            readyReject = null;
            readyResolve = null;
            // Kill it before handing the failure up. A worker that missed the
            // deadline is usually still booting, and the caller's next move is
            // to stand up the inline backend — leaving this one to finish would
            // mean two live WASM instances, one of them unreachable.
            teardownWorker();
            r(new Error('worker init timed out after 5000ms'));
          }
        }, 5000);
        const clearReadyTimeout = (): void => clearTimeout(timeoutId);
        const origResolve = readyResolve;
        const origReject = readyReject;
        readyResolve = () => {
          clearReadyTimeout();
          origResolve();
        };
        readyReject = (e: unknown) => {
          clearReadyTimeout();
          origReject(e);
        };
        worker.addEventListener('message', handleMessage);
        worker.addEventListener('error', (e: ErrorEvent) => {
          const err = e.error instanceof Error ? e.error : new Error(e.message || 'worker error');
          emitErr(err);
          if (readyReject) {
            const r = readyReject;
            readyReject = null;
            readyResolve = null;
            r(err);
            return;
          }
          // Died after `ready`, so nobody is waiting on init and the transport
          // has already committed to this backend. Everything in flight has to
          // be answered here or it never is.
          settlePending();
        });
        postToWorker(wasmUrl !== undefined ? { kind: 'init', wasmUrl } : { kind: 'init' });
      });
    },

    request(method: string, params: unknown): Promise<unknown> {
      if (!worker) return Promise.resolve(null);
      const id = nextId++;
      return new Promise<unknown>((resolve) => {
        pending.set(id, { resolve });
        postToWorker({ kind: 'req', id, method, params });
      });
    },

    notify(method: string, params: unknown): void {
      if (!worker) return;
      postToWorker({ kind: 'notif', method, params });
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
      if (worker) {
        try {
          postToWorker({ kind: 'dispose' });
        } catch {
          /* already gone */
        }
        teardownWorker();
      }
      settlePending();
      listeners.diagnostics = [];
      listeners.error = [];
    },
  };
}
