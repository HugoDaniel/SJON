//! Dependency-free JSON-RPC client for driving the native `sjon-lsp`
//! executable over Content-Length-framed stdio.
//!
//! The harness owns process supervision, framing, request correlation,
//! and server-initiated request replies. Scenario code (`lsp_native_tests.mjs`
//! today, Animader's acceptance suite later) owns fixtures and assertions.
//! It deliberately imports nothing outside Node's standard library and
//! never searches `PATH` for the server: the caller supplies an absolute
//! `serverPath`.
//!
//! Every wait is bounded. Failures include the parsed transcript and the
//! captured stderr so a timeout names what the server actually sent
//! instead of only what was expected.

import { spawn } from 'node:child_process';
import { isAbsolute } from 'node:path';

const MAX_MESSAGE_BYTES = 16 * 1024 * 1024;
const DEFAULT_TIMEOUT_MS = 5000;
const CLOSE_TIMEOUT_MS = 2000;

/** Serialize one JSON value as an LSP base-protocol frame. */
function frame(value) {
  const body = Buffer.from(JSON.stringify(value), 'utf8');
  return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, 'ascii'), body]);
}

/**
 * Spawn the language server and return a connected client.
 *
 * @param {object} options
 * @param {string} options.serverPath absolute path to the server binary
 * @param {string} options.cwd fixture/workspace used by the subprocess
 * @param {NodeJS.ProcessEnv} [options.env]
 * @param {number} [options.timeoutMs]
 * @param {Array<string | {method: string, code?: number, message?: string}>} [options.rejectServerRequests]
 */
export async function spawnLspServer({
  serverPath,
  cwd,
  env = process.env,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  rejectServerRequests = [],
} = {}) {
  if (typeof serverPath !== 'string' || serverPath.length === 0) {
    throw new Error('spawnLspServer: serverPath is required');
  }
  if (!isAbsolute(serverPath)) {
    throw new Error(`spawnLspServer: serverPath must be absolute, got ${serverPath}`);
  }
  if (typeof cwd !== 'string' || cwd.length === 0) {
    throw new Error('spawnLspServer: cwd is required');
  }

  const child = spawn(serverPath, [], {
    cwd,
    env,
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  /** @type {Array<{direction: 'sent' | 'received', kind: string, message: object}>} */
  const transcript = [];
  /** @type {Map<number, {resolve: Function, reject: Function, timer: NodeJS.Timeout, method: string}>} */
  const pending = new Map();
  /** @type {Array<{kind: string, method: string, predicate: Function, resolve: Function, reject: Function, timer: NodeJS.Timeout}>} */
  const waiters = [];
  /** @type {Array<{kind: string, method: string, params: unknown, id?: number}>} */
  const queued = [];
  const exitListeners = [];
  const exitPromise = new Promise((resolve) => {
    exitListeners.push(resolve);
  });

  let nextId = 1;
  let stderrText = '';
  let inbound = Buffer.alloc(0);
  let exited = false;
  let exitDescription = 'not exited';
  let fatalError = null;
  let closePromise = null;

  function failure(message) {
    const lines = transcript.map((record) => {
      const prefix = `${record.direction} ${record.kind}`;
      return `${prefix} ${JSON.stringify(record.message)}`;
    });
    return new Error(
      `${message}\n--- transcript ---\n${lines.join('\n') || '(empty)'}\n--- stderr ---\n${stderrText || '(empty)'}`,
    );
  }

  function fatal(message) {
    if (fatalError !== null) return;
    fatalError = failure(message);
    rejectEverything(fatalError);
    child.kill('SIGKILL');
  }

  function rejectEverything(error) {
    for (const [id, entry] of pending) {
      clearTimeout(entry.timer);
      pending.delete(id);
      entry.reject(error);
    }
    while (waiters.length > 0) {
      const waiter = waiters.pop();
      clearTimeout(waiter.timer);
      waiter.reject(error);
    }
  }

  function record(direction, kind, message) {
    transcript.push({ direction, kind, message });
  }

  function send(message) {
    if (exited) throw failure('cannot write to an exited server');
    record(
      'sent',
      message.method === undefined
        ? 'response'
        : message.id === undefined
          ? 'notification'
          : 'request',
      message,
    );
    child.stdin.write(frame(message));
  }

  function rejectionFor(method) {
    for (const entry of rejectServerRequests) {
      if (typeof entry === 'string') {
        if (entry === method) return { code: -32601, message: 'method not found' };
        continue;
      }
      if (entry && entry.method === method) {
        return {
          code: entry.code ?? -32601,
          message: entry.message ?? 'method not found',
        };
      }
    }
    return null;
  }

  function dispatch(entry) {
    const index = waiters.findIndex(
      (waiter) =>
        waiter.kind === entry.kind &&
        waiter.method === entry.method &&
        waiter.predicate(entry.params),
    );
    if (index < 0) {
      queued.push(entry);
      return;
    }
    const [waiter] = waiters.splice(index, 1);
    clearTimeout(waiter.timer);
    waiter.resolve(entry.params);
  }

  function handleMessage(message) {
    if (message === null || typeof message !== 'object') {
      fatal(`unrecognised server message: ${JSON.stringify(message)}`);
      return;
    }

    if (typeof message.method === 'string') {
      if (Object.hasOwn(message, 'id') && message.id !== null) {
        record('received', 'request', message);
        const rejection = rejectionFor(message.method);
        if (rejection !== null) {
          send({
            jsonrpc: '2.0',
            id: message.id,
            error: { code: rejection.code, message: rejection.message },
          });
        } else {
          send({ jsonrpc: '2.0', id: message.id, result: null });
        }
        dispatch({
          kind: 'request',
          method: message.method,
          params: message.params,
          id: message.id,
        });
      } else {
        record('received', 'notification', message);
        dispatch({ kind: 'notification', method: message.method, params: message.params });
      }
      return;
    }

    if (Object.hasOwn(message, 'id')) {
      record('received', 'response', message);
      const entry = pending.get(message.id);
      if (entry === undefined) return;
      pending.delete(message.id);
      clearTimeout(entry.timer);
      if (message.error !== undefined) {
        entry.reject(
          failure(`JSON-RPC error for ${entry.method}: ${JSON.stringify(message.error)}`),
        );
      } else {
        entry.resolve(message.result);
      }
      return;
    }

    fatal(`unrecognised server message: ${JSON.stringify(message)}`);
  }

  function pump() {
    for (;;) {
      const headerEnd = inbound.indexOf('\r\n\r\n');
      if (headerEnd < 0) {
        if (inbound.length > 8192) {
          fatal('LSP header exceeded 8192 bytes without a \\r\\n\\r\\n terminator');
        }
        return;
      }

      const header = inbound.subarray(0, headerEnd).toString('ascii');
      let contentLength;
      for (const line of header.split('\r\n')) {
        const colon = line.indexOf(':');
        if (colon < 0) {
          fatal(`malformed LSP header line: ${JSON.stringify(line)}`);
          return;
        }
        const name = line.slice(0, colon).trim().toLowerCase();
        if (name !== 'content-length') continue;
        if (contentLength !== undefined) {
          fatal('duplicate Content-Length header');
          return;
        }
        const value = line.slice(colon + 1).trim();
        if (!/^\d+$/.test(value)) {
          fatal(`invalid Content-Length: ${JSON.stringify(value)}`);
          return;
        }
        contentLength = Number(value);
      }

      if (contentLength === undefined) {
        fatal('missing Content-Length header');
        return;
      }
      if (contentLength > MAX_MESSAGE_BYTES) {
        fatal(`Content-Length ${contentLength} exceeds the 16 MiB cap`);
        return;
      }
      if (inbound.length < headerEnd + 4 + contentLength) return;

      const body = inbound.subarray(headerEnd + 4, headerEnd + 4 + contentLength);
      inbound = inbound.subarray(headerEnd + 4 + contentLength);

      let message;
      try {
        message = JSON.parse(body.toString('utf8'));
      } catch (error) {
        fatal(`invalid JSON body: ${error instanceof Error ? error.message : String(error)}`);
        return;
      }
      handleMessage(message);
      if (fatalError !== null) return;
    }
  }

  child.stdout.on('data', (chunk) => {
    inbound = Buffer.concat([inbound, chunk]);
    pump();
  });
  child.stderr.on('data', (chunk) => {
    stderrText += chunk.toString('utf8');
  });
  child.stdin.on('error', (error) => {
    if (!exited) stderrText += `\nstdin error: ${error.message}`;
  });
  child.on('error', (error) => {
    fatal(`failed to spawn ${serverPath}: ${error.message}`);
  });
  child.on('exit', (code, signal) => {
    exited = true;
    exitDescription = signal === null ? `exit code ${code}` : `signal ${signal}`;
    const error = failure(`server exited (${exitDescription})`);
    rejectEverything(error);
    while (exitListeners.length > 0) exitListeners.pop()();
  });

  function waitFor(kind, method, predicate) {
    if (fatalError !== null) return Promise.reject(fatalError);

    const index = queued.findIndex(
      (entry) =>
        entry.kind === kind &&
        entry.method === method &&
        (predicate === undefined || predicate(entry.params)),
    );
    if (index >= 0) {
      return Promise.resolve(queued.splice(index, 1)[0].params);
    }
    if (exited) {
      return Promise.reject(failure(`server already exited (${exitDescription})`));
    }

    return new Promise((resolve, reject) => {
      const waiter = {
        kind,
        method,
        predicate: predicate ?? (() => true),
        resolve,
        reject,
        timer: undefined,
      };
      waiter.timer = setTimeout(() => {
        const at = waiters.indexOf(waiter);
        if (at >= 0) waiters.splice(at, 1);
        reject(failure(`timeout after ${timeoutMs}ms waiting for ${kind} ${method}`));
      }, timeoutMs);
      waiters.push(waiter);
    });
  }

  function request(method, params, options = {}) {
    if (fatalError !== null) return Promise.reject(fatalError);
    if (exited) return Promise.reject(failure(`server already exited (${exitDescription})`));

    const id = nextId;
    nextId += 1;
    const timeout = options.timeout ?? timeoutMs;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (!pending.delete(id)) return;
        reject(failure(`timeout after ${timeout}ms waiting for response to ${method} (id ${id})`));
      }, timeout);
      pending.set(id, { resolve, reject, timer, method });
      const message = { jsonrpc: '2.0', id, method };
      if (params !== undefined) message.params = params;
      send(message);
    });
  }

  function notify(method, params) {
    if (fatalError !== null) throw fatalError;
    if (exited) throw failure(`server already exited (${exitDescription})`);
    const message = { jsonrpc: '2.0', method };
    if (params !== undefined) message.params = params;
    send(message);
  }

  async function initialize({ capabilities = {}, rootUri = null, workspaceFolders } = {}) {
    const params = { processId: null, capabilities, rootUri };
    if (workspaceFolders !== undefined) params.workspaceFolders = workspaceFolders;
    const result = await request('initialize', params);
    notify('initialized', {});
    return result;
  }

  function waitForExit(timeout) {
    if (exited) return Promise.resolve(true);
    return new Promise((resolve) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        resolve(false);
      }, timeout);
      exitPromise.then(() => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(true);
      });
    });
  }

  function close() {
    if (closePromise !== null) return closePromise;
    closePromise = (async () => {
      if (!exited && fatalError === null) {
        try {
          await request('shutdown', undefined, { timeout: CLOSE_TIMEOUT_MS });
        } catch {
          // The process may already be gone; the exit escalation below
          // is what actually guarantees cleanup.
        }
        try {
          notify('exit');
        } catch {
          // Same: exit is best-effort once the server is unreachable.
        }
      }

      if (!(await waitForExit(CLOSE_TIMEOUT_MS))) {
        child.kill('SIGTERM');
        if (!(await waitForExit(CLOSE_TIMEOUT_MS))) {
          child.kill('SIGKILL');
          await waitForExit(CLOSE_TIMEOUT_MS);
        }
      }

      child.stdin.end();
      child.stdout.removeAllListeners();
      child.stderr.removeAllListeners();
      child.removeAllListeners();
    })();
    return closePromise;
  }

  return {
    initialize,
    request,
    notify,
    waitForNotification: (method, predicate) => waitFor('notification', method, predicate),
    waitForRequest: (method, predicate) => waitFor('request', method, predicate),
    transcript: () => transcript.slice(),
    stderr: () => stderrText,
    close,
  };
}
