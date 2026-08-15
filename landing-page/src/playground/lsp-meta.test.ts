// Headless unit tests for the LSP-asset staleness helpers (lsp-meta.ts).
//
// Pure logic: no wasm, no DOM, no network. Covers the three moving parts of
// the staleness guard — parsing the build-staged `sjon-lsp.meta.json`,
// cache-busting the wasm URL with its short hash, and the identity verdict
// matrix comparing the build's recorded serverInfo against the running one.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  parseWasmMeta,
  parseServerInfo,
  wasmUrlWithVersion,
  compareWasmIdentity,
} from './lsp-meta.ts';

const GOOD = {
  sha256: 'a'.repeat(64),
  shortHash: 'a'.repeat(12),
  serverInfo: { name: 'sjon-lsp', version: '1.0.0' },
};

test('parseWasmMeta accepts a well-formed record', () => {
  const meta = parseWasmMeta(GOOD);
  assert.ok(meta !== null);
  assert.equal(meta.sha256, GOOD.sha256);
  assert.equal(meta.shortHash, GOOD.shortHash);
  assert.equal(meta.serverInfo.name, 'sjon-lsp');
  assert.equal(meta.serverInfo.version, '1.0.0');
});

test('parseWasmMeta rejects malformed input', () => {
  assert.equal(parseWasmMeta(null), null);
  assert.equal(parseWasmMeta(42), null);
  assert.equal(parseWasmMeta('a string'), null);
  assert.equal(parseWasmMeta({}), null);
  assert.equal(parseWasmMeta({ ...GOOD, sha256: 123 }), null);
  assert.equal(parseWasmMeta({ ...GOOD, shortHash: undefined }), null);
  assert.equal(parseWasmMeta({ ...GOOD, serverInfo: null }), null);
  assert.equal(parseWasmMeta({ ...GOOD, serverInfo: { name: 'x' } }), null);
  assert.equal(parseWasmMeta({ ...GOOD, serverInfo: { version: '1' } }), null);
});

test('wasmUrlWithVersion appends the short hash as a cache-busting query', () => {
  const meta = parseWasmMeta(GOOD);
  assert.equal(wasmUrlWithVersion('/sjon-lsp.wasm', meta), `/sjon-lsp.wasm?v=${GOOD.shortHash}`);
});

test('wasmUrlWithVersion uses & when the base already has a query', () => {
  const meta = parseWasmMeta(GOOD);
  assert.equal(
    wasmUrlWithVersion('/sjon-lsp.wasm?x=1', meta),
    `/sjon-lsp.wasm?x=1&v=${GOOD.shortHash}`,
  );
});

test('wasmUrlWithVersion returns the base unchanged when meta is null', () => {
  assert.equal(wasmUrlWithVersion('/sjon-lsp.wasm', null), '/sjon-lsp.wasm');
});

test('compareWasmIdentity: match when name + version agree', () => {
  const meta = parseWasmMeta(GOOD);
  assert.equal(compareWasmIdentity(meta, { name: 'sjon-lsp', version: '1.0.0' }), 'match');
});

test('compareWasmIdentity: mismatch when the version drifts', () => {
  const meta = parseWasmMeta(GOOD);
  assert.equal(compareWasmIdentity(meta, { name: 'sjon-lsp', version: '0.9.0' }), 'mismatch');
});

test('compareWasmIdentity: mismatch when the name drifts', () => {
  const meta = parseWasmMeta(GOOD);
  assert.equal(compareWasmIdentity(meta, { name: 'other', version: '1.0.0' }), 'mismatch');
});

test('compareWasmIdentity: unknown when either side is absent', () => {
  const meta = parseWasmMeta(GOOD);
  // The guard must never block boot: a missing meta or a server that never
  // reported serverInfo both degrade to 'unknown', not 'mismatch'.
  assert.equal(compareWasmIdentity(null, { name: 'sjon-lsp', version: '1.0.0' }), 'unknown');
  assert.equal(compareWasmIdentity(meta, null), 'unknown');
  assert.equal(compareWasmIdentity(null, null), 'unknown');
});

test('parseServerInfo extracts a well-formed initialize serverInfo', () => {
  const info = parseServerInfo({ name: 'sjon-lsp', version: '1.0.0' });
  assert.ok(info !== null);
  assert.equal(info.name, 'sjon-lsp');
  assert.equal(info.version, '1.0.0');
});

test('parseServerInfo returns null on a malformed value', () => {
  assert.equal(parseServerInfo(undefined), null);
  assert.equal(parseServerInfo(null), null);
  assert.equal(parseServerInfo({ name: 'sjon-lsp' }), null);
  assert.equal(parseServerInfo({ version: '1.0.0' }), null);
  assert.equal(parseServerInfo({ name: 1, version: '1.0.0' }), null);
});
