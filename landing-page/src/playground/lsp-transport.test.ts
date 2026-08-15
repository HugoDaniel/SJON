// Tests for the LSP transport's backend selection and fallback
// (lsp-transport.ts).
//
// The fallback is the reason the published playground was merely degraded
// rather than blank during its one outage, and it had no test at all — the
// `_workerFactory` / `_inlineFactory` seams exist for exactly this and nothing
// used them. Fake backends throughout: no Worker, no WASM, no DOM.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createLspTransport } from './lsp-transport.ts';
import { STALE } from './lsp-types.ts';
import type {
  DiagnosticsListener,
  DiagnosticsPayload,
  ErrorListener,
  LspBackend,
} from './lsp-types.ts';

interface FakeBackend extends LspBackend {
  readonly label: string;
  readonly calls: string[];
  destroyed: number;
  emitDiagnostics(payload: DiagnosticsPayload): void;
}

/** A backend that answers every request with its own label. */
function fakeBackend(label: string, opts: { initThrows?: boolean } = {}): FakeBackend {
  const diagnostics: DiagnosticsListener[] = [];
  const errors: ErrorListener[] = [];
  const calls: string[] = [];
  const backend: FakeBackend = {
    label,
    calls,
    destroyed: 0,
    init() {
      calls.push('init');
      if (opts.initThrows) return Promise.reject(new Error(`${label} init failed`));
      return Promise.resolve();
    },
    request(method: string) {
      calls.push(`request:${method}`);
      return Promise.resolve(`${label}:${method}`);
    },
    notify(method: string) {
      calls.push(`notify:${method}`);
    },
    on(kind: 'diagnostics' | 'error', fn: DiagnosticsListener | ErrorListener) {
      if (kind === 'diagnostics') diagnostics.push(fn as DiagnosticsListener);
      else errors.push(fn as ErrorListener);
    },
    off() {
      /* unused by these tests */
    },
    destroy() {
      backend.destroyed += 1;
    },
    emitDiagnostics(payload: DiagnosticsPayload) {
      for (const fn of diagnostics) fn(payload);
    },
  };
  return backend;
}

test('a worker that boots is used, and the inline backend is never built', async () => {
  const worker = fakeBackend('worker');
  let inlineBuilt = 0;
  const transport = await createLspTransport({
    mode: 'worker',
    _workerFactory: () => Promise.resolve(worker),
    _inlineFactory: () => {
      inlineBuilt += 1;
      return Promise.resolve(fakeBackend('inline'));
    },
  });
  await transport.init();

  assert.equal(transport.mode, 'worker');
  assert.equal(inlineBuilt, 0);
  assert.equal(await transport.request('textDocument/hover', {}, 1), 'worker:textDocument/hover');
});

test('a worker whose init rejects falls back to inline, and requests flow', async () => {
  const worker = fakeBackend('worker', { initThrows: true });
  const inline = fakeBackend('inline');
  const seen: unknown[] = [];
  const transport = await createLspTransport({
    mode: 'worker',
    _workerFactory: () => Promise.resolve(worker),
    _inlineFactory: () => Promise.resolve(inline),
  });
  transport.on('error', (e) => seen.push(e));
  await transport.init();

  assert.equal(transport.mode, 'inline', 'the transport must report where it actually landed');
  assert.equal(await transport.request('textDocument/hover', {}, 1), 'inline:textDocument/hover');
  assert.equal(seen.length, 1, 'the failure is reported, not swallowed');
});

test('a worker factory that throws outright still falls back', async () => {
  // Distinct from an init rejection: `new Worker(...)` throwing synchronously
  // leaves the transport with no backend at all to tear down.
  const inline = fakeBackend('inline');
  const transport = await createLspTransport({
    mode: 'worker',
    _workerFactory: () => Promise.reject(new Error('Worker is not defined')),
    _inlineFactory: () => Promise.resolve(inline),
  });
  await transport.init();

  assert.equal(transport.mode, 'inline');
  assert.equal(await transport.request('textDocument/hover', {}, 1), 'inline:textDocument/hover');
});

test('the failed worker backend is destroyed rather than abandoned', async () => {
  // The 5 s init timeout is the slow-not-dead case: the backend rejected but
  // its Worker is still booting a WASM instance. Dropping the reference would
  // leave it running beside the inline backend for the life of the page.
  const worker = fakeBackend('worker', { initThrows: true });
  const transport = await createLspTransport({
    mode: 'worker',
    _workerFactory: () => Promise.resolve(worker),
    _inlineFactory: () => Promise.resolve(fakeBackend('inline')),
  });
  await transport.init();

  assert.equal(worker.destroyed, 1);
});

test('when both backends fail, init rejects rather than pretending to be ready', async () => {
  const transport = await createLspTransport({
    mode: 'worker',
    _workerFactory: () => Promise.resolve(fakeBackend('worker', { initThrows: true })),
    _inlineFactory: () => Promise.resolve(fakeBackend('inline', { initThrows: true })),
  });

  await assert.rejects(() => transport.init(), /inline init failed/);
  // And it stays unready: requests answer STALE instead of hanging or throwing.
  assert.equal(await transport.request('textDocument/hover', {}, 1), STALE);
});

test('an inline-mode failure does not reject, it leaves the transport unready', async () => {
  // Asymmetric on purpose: `mode: 'worker'` promises a fallback, so failing
  // both is fatal. Plain inline mode has nowhere to fall back to, and boot
  // catches the difference (see lsp-failure.ts).
  const transport = await createLspTransport({
    mode: 'inline',
    _inlineFactory: () => Promise.resolve(fakeBackend('inline', { initThrows: true })),
  });
  await transport.init();
  assert.equal(await transport.request('textDocument/hover', {}, 1), STALE);
});

test('diagnostics from the fallback backend reach listeners wired before init', async () => {
  // The wiring runs once per backend; a listener registered on the transport
  // before boot must survive the swap.
  const inline = fakeBackend('inline');
  const transport = await createLspTransport({
    mode: 'worker',
    _workerFactory: () => Promise.resolve(fakeBackend('worker', { initThrows: true })),
    _inlineFactory: () => Promise.resolve(inline),
  });
  const received: DiagnosticsPayload[] = [];
  transport.on('diagnostics', (p) => received.push(p));
  await transport.init();

  inline.emitDiagnostics({ uri: 'file:///doc.sjon', diagnostics: [] });
  assert.equal(received.length, 1);
  assert.equal(received[0]?.uri, 'file:///doc.sjon');
});

test('a superseded request resolves to STALE instead of a stale answer', async () => {
  const transport = await createLspTransport({
    mode: 'fake',
    backend: fakeBackend('fake'),
  });
  await transport.init();
  transport.bumpVersion(5);
  assert.equal(await transport.request('textDocument/hover', {}, 2), STALE);
  assert.equal(await transport.request('textDocument/hover', {}, 5), 'fake:textDocument/hover');
});
