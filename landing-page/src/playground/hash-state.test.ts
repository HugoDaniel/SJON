// Headless unit tests for the shareable-URL codec. The unit is the pure
// string↔state projection lifted out of `boot.ts`; nothing here touches
// `window`. Run with `node --test --experimental-strip-types`.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { b64urlDecode, b64urlEncode, decodeHashState, encodeHashState } from './hash-state.ts';

test('base64url round-trips text the encoder must survive', () => {
  for (const s of [
    '',
    '(+ 1 2)',
    '(scene :name "café" :note "ünïcödé — ✓")',
    '(a\n  :b [1 2 3]\n  :c "quotes \\" and / slashes + pluses")',
  ]) {
    assert.equal(b64urlDecode(b64urlEncode(s)), s);
  }
});

test('base64url output is URL-safe and unpadded', () => {
  // `?` and `~` are chosen to force `+` and `/` out of plain base64.
  const encoded = b64urlEncode('(x :a "??~~~?" :b "ÿþ")');
  assert.match(encoded, /^[A-Za-z0-9_-]*$/);
});

test('a document with schemas round-trips through the hash', () => {
  const doc = '(circle :radius 8)';
  const schemas = ['(plugin :name a :version "1.0.0")', '(plugin :name b :version "2.0.0")'];
  const state = decodeHashState('#' + encodeHashState(doc, schemas));
  assert.equal(state.doc, doc);
  assert.deepEqual(state.schemas, schemas);
});

test('a document with no schemas omits the sc key entirely', () => {
  const hash = encodeHashState('(+ 1 2)', []);
  assert.ok(!hash.includes('sc='), `expected no sc key, got ${hash}`);
  assert.deepEqual(decodeHashState(hash), { doc: '(+ 1 2)', schemas: [] });
});

test('the bare #s= form tutorial deep-links use still decodes', () => {
  const state = decodeHashState('#s=' + b64urlEncode('(+ 1 2)'));
  assert.equal(state.doc, '(+ 1 2)');
  assert.deepEqual(state.schemas, []);
});

test('a truncated share link degrades to defaults rather than throwing', () => {
  for (const hash of ['', '#', '#s', '#s=!!!not-base64!!!', '#sc=' + b64urlEncode('not json')]) {
    const state = decodeHashState(hash);
    assert.deepEqual(state.schemas, []);
  }
});

test('a non-array sc payload is ignored, not spread into schemas', () => {
  const state = decodeHashState('#sc=' + b64urlEncode(JSON.stringify({ a: 1 })));
  assert.deepEqual(state.schemas, []);
});

test('the CLI share fixture decodes to the expected document and schemas', () => {
  // Drift gate for `sjon share` (src/cli/ShareLink.zig): the checked-in
  // fixture URL is asserted byte-identical by a Zig test on the emit
  // side and decoded here on the consume side. If either codec moves,
  // one of the two gates goes red.
  // Path via import.meta.url — the test runs from landing-page/ under
  // `pnpm test` but from the repo root under `zig build verify`.
  const url = readFileSync(
    join(dirname(fileURLToPath(import.meta.url)), 'share-link.fixture.txt'),
    'utf8',
  ).trim();
  const hash = url.slice(url.indexOf('#'));
  const state = decodeHashState(hash);
  assert.equal(state.doc, '(café)');
  assert.deepEqual(state.schemas, ['(x)', '(y)']);
});
