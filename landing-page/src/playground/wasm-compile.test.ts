// Headless unit tests for the wasm compile helper (wasm-compile.ts) and for
// the copy of it inlined in lsp-worker.ts.
//
// The bug this guards against is a deployment bug, not a logic bug, so the
// tests are about one thing: which compile path a given `Content-Type` takes.
// hugodaniel.com serves `.wasm` as `application/octet-stream`, and
// `WebAssembly.compileStreaming` rejects anything that is not
// `application/wasm` — that is what took the published playground down.
//
// Both copies run the same table. See `workerCompileWasmResponse` below for
// why there are two copies and how the worker's is reached from here.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { compileWasmResponse } from './wasm-compile.ts';

type CompileFn = (response: Response) => Promise<WebAssembly.Module>;

/**
 * The worker's inlined `compileWasmResponse`, extracted from source and made
 * callable.
 *
 * `lsp-worker.ts` carries its own copy on purpose — it is bundled as a
 * self-contained chunk with no relative runtime imports — and it cannot be
 * imported here, because it derefs `self` at module scope. So the drift gate
 * lifts the function body out of the source text and runs it: the table below
 * exercises the worker's real code, not a transcription of it.
 *
 * This matters because the outage was this exact function being "simplified"
 * in one place. Asserting on the presence of source fragments would pin the
 * spelling; running it pins the behaviour — and Node's own MIME strictness
 * makes a permissive header check fail the `charset=binary` case outright.
 *
 * Only the body is evaluated, never the signature, so no type annotations
 * reach `AsyncFunction` — the body is plain JavaScript.
 */
function extractWorkerCompile(): CompileFn {
  const source = readFileSync(
    join(dirname(fileURLToPath(import.meta.url)), 'lsp-worker.ts'),
    'utf8',
  );
  const signature = 'async function compileWasmResponse(';
  const start = source.indexOf(signature);
  assert.notEqual(
    start,
    -1,
    'lsp-worker.ts no longer inlines compileWasmResponse — if the worker now ' +
      'imports it, delete this gate deliberately rather than letting it rot',
  );

  const open = source.indexOf('{', source.indexOf(')', start));
  let depth = 0;
  let end = -1;
  for (let i = open; i < source.length; i += 1) {
    if (source[i] === '{') depth += 1;
    else if (source[i] === '}') {
      depth -= 1;
      if (depth === 0) {
        end = i;
        break;
      }
    }
  }
  assert.notEqual(end, -1, 'could not find the end of the worker copy');

  // The one cast in this file: `AsyncFunction` is not a global binding, so it
  // has to be reached through the prototype of an async function.
  const AsyncFunction = Object.getPrototypeOf(async function noop(): Promise<void> {})
    .constructor as new (
    arg: string,
    body: string,
  ) => CompileFn;
  return new AsyncFunction('response', source.slice(open + 1, end));
}

const workerCompileWasmResponse = extractWorkerCompile();

const implementations: ReadonlyArray<readonly [string, CompileFn]> = [
  ['wasm-compile.ts', compileWasmResponse],
  ['lsp-worker.ts (inlined copy)', workerCompileWasmResponse],
];

/** The smallest valid wasm module: the magic number and version, nothing else. */
const EMPTY_MODULE = new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]);

const responseTyped = (contentType: string | null): Response =>
  new Response(EMPTY_MODULE, {
    headers: contentType === null ? {} : { 'content-type': contentType },
  });

for (const [name, compile] of implementations) {
  test(`${name}: compiles a response served as application/wasm`, async () => {
    const mod = await compile(responseTyped('application/wasm'));
    assert.ok(mod instanceof WebAssembly.Module);
  });

  test(`${name}: compiles a response served as application/octet-stream`, async () => {
    // The regression. Streaming would reject this outright.
    const mod = await compile(responseTyped('application/octet-stream'));
    assert.ok(mod instanceof WebAssembly.Module);
  });

  test(`${name}: compiles a response with no Content-Type at all`, async () => {
    const mod = await compile(responseTyped(null));
    assert.ok(mod instanceof WebAssembly.Module);
  });

  test(`${name}: compiles an application/wasm header carrying parameters or odd casing`, async () => {
    // The spec says to match the media type's essence case-insensitively and
    // to allow parameters; Node rejects this header from `compileStreaming`
    // anyway. Whichever path the helper picks, the caller must still get a
    // module — so a copy that loosens the check to match the spec fails here.
    const mod = await compile(responseTyped('Application/Wasm; charset=binary'));
    assert.ok(mod instanceof WebAssembly.Module);
  });

  test(`${name}: rejects a response that is not ok, naming the status and url`, async () => {
    const response = new Response('nope', { status: 404 });
    Object.defineProperty(response, 'url', { value: 'https://example.test/sjon-lsp.wasm' });
    // The whole message, not just the status: it reaches the visitor through
    // `showLspFailure`, and matching it here is what holds the two copies to
    // the same wording.
    await assert.rejects(
      () => compile(response),
      /^Error: wasm fetch failed: https:\/\/example\.test\/sjon-lsp\.wasm → HTTP 404$/,
    );
  });
}
