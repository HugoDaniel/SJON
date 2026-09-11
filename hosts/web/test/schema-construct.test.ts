// Plan-02 conformance lock (web / WASM side).
//
//  1. Round-trip oracle: the pure-TS `serializeValue` must parse equal to the
//     real WASM `fromValue` — `toJson(serializeValue(v)) ≡ toJson(fromValue(v))`
//     over a `$`-tag corpus. This is what proves the backend-free keystone is
//     faithful to the engine without claiming byte-identity.
//  2. Default export agreement: the WASM (Zig) exporter emits a defaulted key
//     as OPTIONAL (`field?: T`) — the authoring shape — matching the tsp
//     exporter and the builder's `s.input`.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonHost } from '../SjonHost.ts';
import { createWasmBackend } from '../SjonSchemaBackend.ts';
import { e, s, serializeValue, v } from '@sjon-lang/schema';
import type { SjonValue } from '@sjon-lang/schema';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..', '..');
const wasmPath = path.join(root, 'zig-out/bin/sjon.wasm');

let cached: ReturnType<typeof createWasmBackend> | null = null;
async function getBackend() {
  if (!cached) cached = createWasmBackend(await SjonHost.load(wasmPath));
  return cached;
}

// A representative slice of every `$`-tag shape serializeValue handles.
const CORPUS: readonly SjonValue[] = [
  42,
  -7,
  3.14,
  0,
  'hello',
  'a"b\\c',
  'tab\there',
  'café — 日本語 😀',
  true,
  false,
  null,
  v.sym('red'),
  v.kw('mode'),
  v.date('2024-01-31'),
  v.time('12:30:00'),
  v.unit(90, 'deg'),
  v.unit(-50, '%'),
  v.unit(0.5, 'em'),
  [1, 2, 3],
  ['a', v.sym('b'), true],
  [
    [1, 2],
    [3, 4],
  ],
  e.add(1, e.mul(2, 3)),
  e.vec3(1, 2, 3),
  e.pi(),
  { $form: 'pt', x: 1, y: 2 },
  { $form: 'pt', $ns: 'g', x: 1, y: 2 },
  { $form: 'g', $ns: 'g', label: 'a', $children: [1, 2] },
  { $form: 'f', $$weird: 1 },
];

test('round-trip oracle: serializeValue parses equal to WASM fromValue', async () => {
  const be = await getBackend();
  for (const value of CORPUS) {
    const viaPure = be.toJson!(serializeValue(value));
    const viaWasm = be.toJson!(be.fromValue!(value));
    assert.deepEqual(
      viaPure,
      viaWasm,
      `oracle mismatch for ${JSON.stringify(value)}\n  pure: ${serializeValue(value)}\n  wasm: ${be.fromValue!(value)}`,
    );
  }
});

test('WASM exporter emits a defaulted key as optional (authoring shape)', async () => {
  const be = await getBackend();
  const manifest = `(plugin :name p :version "1.0.0"
  (form :name doc
    (key :name id :type string :optional false)
    (key :name title :type string :optional false :default "Untitled")))`;
  const dts = be.exportSchema!(manifest).tsTypes ?? '';
  assert.match(dts, /\btitle\?: string/); // defaulted ⇒ optional (Zig effectiveOptional)
  assert.match(dts, /\bid: string/); // truly required → no `?`
});

test('builder .default() round-trips to an optional export key (s.input ≡ export)', async () => {
  const be = await getBackend();
  const Doc = s.form('doc', { id: s.string(), title: s.string().default('Untitled') });
  const dts = Doc.toDts({ backend: be });
  assert.match(dts, /\btitle\?: string/);
  assert.match(dts, /\bid: string/);
});
