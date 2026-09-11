// Closure-binder sugar (M3) end-to-end: the build-time arrow desugaring emits a
// first-order binder AST that the *real* WASM engine evaluates correctly. The
// schema-package tests pin the desugared shape; this pins that the shape runs.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonHost } from '../SjonHost.ts';
import { e, serializeValue } from '@sjon-lang/schema';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');

let cached: SjonHost | null = null;
async function getHost() {
  if (!cached) cached = await SjonHost.load(wasmPath);
  return cached;
}

test('map arrow sugar evaluates element-wise', async () => {
  const host = await getHost();
  const src = serializeValue(e.map([1, 2, 3], (x) => e.mul(x, 2)));
  assert.deepEqual(host.encoder.evalExpr(src), [2, 4, 6]);
});

test('filter arrow sugar keeps the truthy elements', async () => {
  const host = await getHost();
  const src = serializeValue(e.filter([1, 2, 3, 4], (x) => e.gt(x, 2)));
  assert.deepEqual(host.encoder.evalExpr(src), [3, 4]);
});

test('fold arrow sugar threads the accumulator', async () => {
  const host = await getHost();
  const src = serializeValue(e.fold(0, [1, 2, 3, 4], (acc, x) => e.add(acc, x)));
  assert.equal(host.encoder.evalExpr(src), 10);
});

test('nested map sugar evaluates with distinct bindings', async () => {
  const host = await getHost();
  // For each x in [1,2], map y in [10,20] to x+y → [[11,21],[12,22]].
  const src = serializeValue(e.map([1, 2], (x) => e.map([10, 20], (y) => e.add(x, y))));
  assert.deepEqual(host.encoder.evalExpr(src), [
    [11, 21],
    [12, 22],
  ]);
});
