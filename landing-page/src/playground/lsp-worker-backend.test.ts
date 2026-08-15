// Tests for the worker backend's lifecycle (lsp-worker-backend.ts).
//
// Everything here is about a worker that fails *after* being constructed —
// times out mid-boot, or dies once running. Those are the cases with no
// observer: the transport's fallback covers a worker that never starts (see
// lsp-transport.test.ts), and the worker's own try/catch covers a request that
// throws inside it. What was left was the worker vanishing between the two.
//
// `Worker` is a browser global with no Node equivalent, so these install a
// double. Every test carries an explicit `timeout` — a regression in the
// settle-on-death path shows up as a promise that never resolves, and
// node:test would otherwise wait forever rather than fail.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createWorkerBackend } from './lsp-worker-backend.ts';
import type { WorkerInbound, WorkerOutbound } from './lsp-types';

interface FakeWorkerHandle {
  readonly posted: WorkerInbound[];
  terminated: number;
  emit(data: WorkerOutbound): void;
  emitError(message: string): void;
}

/** The most recently constructed fake, for the test that just made one. */
let latest: FakeWorkerHandle | null = null;

type Listener = (event: unknown) => void;

class FakeWorker implements FakeWorkerHandle {
  readonly posted: WorkerInbound[] = [];
  terminated = 0;
  private readonly listeners = new Map<string, Listener[]>();

  constructor() {
    latest = this;
  }

  addEventListener(kind: string, fn: Listener): void {
    const existing = this.listeners.get(kind);
    if (existing) existing.push(fn);
    else this.listeners.set(kind, [fn]);
  }

  postMessage(msg: WorkerInbound): void {
    this.posted.push(msg);
  }

  terminate(): void {
    this.terminated += 1;
  }

  /** Deliver a `worker -> main` frame. */
  emit(data: WorkerOutbound): void {
    for (const fn of this.listeners.get('message') ?? []) fn({ data });
  }

  /** Deliver an `error` event — an uncaught throw inside the worker, or the
   *  worker's script failing to load. */
  emitError(message: string): void {
    for (const fn of this.listeners.get('error') ?? []) fn({ message, error: new Error(message) });
  }
}

/**
 * Install the double for one test.
 *
 * The cast is unavoidable: `Worker` is not declared on Node's `globalThis`,
 * and the point is to put something there that the module under test will
 * reach for by name.
 */
function withFakeWorker(): { handle: () => FakeWorkerHandle; restore: () => void } {
  const slot = globalThis as { Worker?: unknown };
  const original = slot.Worker;
  slot.Worker = FakeWorker;
  latest = null;
  return {
    handle: () => {
      assert.ok(latest, 'no Worker was constructed');
      return latest;
    },
    restore: () => {
      slot.Worker = original;
      latest = null;
    },
  };
}

test(
  'init resolves on the ready frame and keeps the serverInfo it carried',
  { timeout: 2000 },
  async () => {
    const fake = withFakeWorker();
    try {
      const backend = createWorkerBackend({ wasmUrl: '/sjon-lsp.wasm' });
      const ready = backend.init();
      assert.deepEqual(fake.handle().posted, [{ kind: 'init', wasmUrl: '/sjon-lsp.wasm' }]);

      fake.handle().emit({ kind: 'ready', serverInfo: { name: 'sjon-lsp', version: '0.1.0' } });
      await ready;

      assert.deepEqual(backend.getServerInfo?.(), { name: 'sjon-lsp', version: '0.1.0' });
    } finally {
      fake.restore();
    }
  },
);

test('init rejects on a fatal frame', { timeout: 2000 }, async () => {
  const fake = withFakeWorker();
  try {
    const backend = createWorkerBackend();
    const ready = backend.init();
    fake.handle().emit({ kind: 'fatal', error: 'Incorrect response MIME type' });
    await assert.rejects(() => ready, /Incorrect response MIME type/);
  } finally {
    fake.restore();
  }
});

test('an init that times out terminates the worker it gave up on', { timeout: 2000 }, async (t) => {
  // The slow-not-dead case. Rejecting alone left the worker to finish booting
  // a WASM instance nobody holds a reference to, right as the transport stands
  // up the inline backend beside it.
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const fake = withFakeWorker();
  try {
    const backend = createWorkerBackend();
    const ready = backend.init();
    const settled = assert.rejects(() => ready, /timed out after 5000ms/);
    t.mock.timers.tick(5000);
    await settled;

    assert.equal(fake.handle().terminated, 1, 'the timed-out worker must be terminated');
  } finally {
    fake.restore();
  }
});

test(
  'a worker that dies after ready settles every in-flight request',
  { timeout: 2000 },
  async () => {
    // Nothing else can answer them: the promise `request()` returns is settled
    // only by a matching frame from a worker that is now gone. Left pending, the
    // panel waiting on it stops updating for the life of the page — and this
    // test would hang rather than fail without its explicit timeout.
    const fake = withFakeWorker();
    try {
      const backend = createWorkerBackend();
      const ready = backend.init();
      fake.handle().emit({ kind: 'ready' });
      await ready;

      const hover = backend.request('textDocument/hover', {});
      const outline = backend.request('textDocument/documentSymbol', {});
      fake.handle().emitError('worker crashed');

      assert.equal(await hover, null);
      assert.equal(await outline, null);
    } finally {
      fake.restore();
    }
  },
);

test('a post-ready death is reported to error listeners', { timeout: 2000 }, async () => {
  const fake = withFakeWorker();
  try {
    const backend = createWorkerBackend();
    const seen: unknown[] = [];
    backend.on('error', (e) => seen.push(e));
    const ready = backend.init();
    fake.handle().emit({ kind: 'ready' });
    await ready;

    fake.handle().emitError('worker crashed');
    assert.equal(seen.length, 1);
  } finally {
    fake.restore();
  }
});

test('destroy disposes the worker and settles what was in flight', { timeout: 2000 }, async () => {
  const fake = withFakeWorker();
  try {
    const backend = createWorkerBackend();
    const ready = backend.init();
    fake.handle().emit({ kind: 'ready' });
    await ready;

    const pending = backend.request('textDocument/hover', {});
    backend.destroy();

    assert.equal(await pending, null);
    assert.equal(fake.handle().terminated, 1);
    assert.deepEqual(fake.handle().posted.at(-1), { kind: 'dispose' });
  } finally {
    fake.restore();
  }
});

test(
  'an err frame resolves its request to null and reports the error',
  { timeout: 2000 },
  async () => {
    const fake = withFakeWorker();
    try {
      const backend = createWorkerBackend();
      const seen: unknown[] = [];
      backend.on('error', (e) => seen.push(e));
      const ready = backend.init();
      fake.handle().emit({ kind: 'ready' });
      await ready;

      const req = backend.request('textDocument/hover', {});
      const posted = fake.handle().posted.at(-1);
      assert.equal(posted?.kind, 'req');
      fake
        .handle()
        .emit({ kind: 'err', id: posted?.kind === 'req' ? posted.id : 0, error: 'nope' });

      assert.equal(await req, null);
      assert.equal(seen.length, 1);
    } finally {
      fake.restore();
    }
  },
);
