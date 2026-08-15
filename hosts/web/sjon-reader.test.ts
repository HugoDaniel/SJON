// node:test suite for the SJON WASM consumer. Run with:
//
//   node --test hosts/web/
//
// or via the integrated build step:
//
//   zig build wasm-consumer-test
//
// Both load `zig-out/bin/sjon.wasm` + `zig-out/bin/sjon-binary.wasm`,
// so they require `zig build wasm-all` to have run first (the build
// step does this automatically).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { SjonEncoder, SjonReader, SjonWasmError } from './sjon-reader.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const encPath = path.join(root, 'zig-out/bin/sjon.wasm');
const readerPath = path.join(root, 'zig-out/bin/sjon-binary.wasm');

// A single instance per artifact is shared across tests — this matches
// how a real consumer would deploy them, and keeps the suite fast.
const encoder = await SjonEncoder.load(encPath);
const reader = await SjonReader.load(readerPath);

// ---------------------------------------------------------------------------
// describe()
// ---------------------------------------------------------------------------

test('encoder.describe() returns kitchen-sink metadata', () => {
  const d = encoder.describe();
  assert.equal(d.name, 'sjon');
  assert.match(d.version, /^\d+\.\d+\.\d+$/);
  assert.deepEqual(d.plugins, ['core', 'pattern']);
  // Every documented export must be present.
  for (const x of [
    'parse',
    'print',
    'validate',
    'eval_expr',
    'query_pattern',
    'to_json',
    'from_json',
    'apply_edit',
    'to_binary',
    'from_binary',
    'validate_binary',
    'eval_expr_binary',
    'describe',
  ]) {
    assert.ok(d.exports.includes(x), `missing export ${x}`);
  }
});

test('reader.describe() returns the binary-only artifact metadata', () => {
  const d = reader.describe();
  assert.equal(d.name, 'sjon-binary');
  assert.deepEqual(d.plugins, ['core', 'pattern']);
  // Critically, the reader does NOT advertise text-side exports.
  for (const x of ['parse', 'print', 'to_json', 'apply_edit', 'to_binary']) {
    assert.ok(!d.exports.includes(x), `reader leaked text-side export: ${x}`);
  }
  for (const x of ['validate_binary', 'eval_expr_binary', 'query_pattern_binary', 'describe']) {
    assert.ok(d.exports.includes(x), `reader missing ${x}`);
  }
});

// ---------------------------------------------------------------------------
// alloc / free hygiene
// ---------------------------------------------------------------------------

test('alloc/free survives many small allocations without leaking', () => {
  // The WASM allocator's heap will grow unboundedly if free is broken;
  // this loop encodes / decodes 256 small buffers and checks the
  // memory.buffer size hasn't ballooned.
  const startBytes = encoder.memory.buffer.byteLength;
  for (let i = 0; i < 256; i++) {
    const bin = encoder.toBinary(`(point :x ${i} :y ${i + 1})`);
    assert.ok(bin.length > 0);
    const text = encoder.fromBinary(bin);
    assert.ok(text.includes('point'));
  }
  const endBytes = encoder.memory.buffer.byteLength;
  // Allow some growth but flag a 4× blowout.
  assert.ok(
    endBytes <= startBytes * 4 + 1024 * 1024,
    `memory grew from ${startBytes} → ${endBytes} bytes`,
  );
});

// ---------------------------------------------------------------------------
// to_binary / from_binary round-trip
// ---------------------------------------------------------------------------

test('encoder round-trips a small scene through binary IR', () => {
  const source = '(scene :bpm 130 (canvas :name "main" [1 2 3]))';
  const bin = encoder.toBinary(source);
  assert.ok(bin instanceof Uint8Array);
  assert.ok(bin.length >= 16, 'binary is at least header-sized');
  // Magic: "SJ1\n" — pin the wire format from the JS side.
  assert.equal(bin[0], 0x53);
  assert.equal(bin[1], 0x4a);
  assert.equal(bin[2], 0x31);
  assert.equal(bin[3], 0x0a);
  // Wire version pinned to 5 (bumped when `vector` gained a trailing-
  // comment field symmetric with forms; pre-v5 frames have no such field
  // and are rejected by `fromBinary` / cursor consumers).
  assert.equal(bin[4], 0x05);

  const text = encoder.fromBinary(bin);
  // The canonical form may add layout (newlines / indents) but must
  // contain every input token.
  for (const tok of ['scene', ':bpm', '130', 'canvas', ':name', 'main', '[1 2 3]']) {
    assert.ok(text.includes(tok), `canonical text missing token ${tok}`);
  }
});

// ---------------------------------------------------------------------------
// validate_binary
// ---------------------------------------------------------------------------

test('reader.validateBinary on a clean core-only expression reports no diagnostics', () => {
  // The WASM artifacts ship the `core` plugin only — no domain forms.
  // `(let [x 1] (* x 2))` lives entirely inside that vocabulary.
  const bin = encoder.toBinary('(let [x 1] (* x 2))');
  const report = reader.validateBinary(bin);
  assert.deepEqual(report.parse_diagnostics, []);
  assert.deepEqual(report.diagnostics, []);
});

test('reader.validateBinary surfaces diagnostics on an unknown form', () => {
  // `(unknownform :foo 1)` parses cleanly — there are no syntax errors —
  // but the validator can't resolve `unknownform` against the `core`-only
  // schema, so it must emit at least one diagnostic.
  const bin = encoder.toBinary('(unknownform :foo 1)');
  const report = reader.validateBinary(bin);
  assert.deepEqual(report.parse_diagnostics, []);
  assert.ok(report.diagnostics.length >= 1, 'expected at least one diagnostic');
  const msg = report.diagnostics[0]!.message;
  assert.ok(/unknown/i.test(msg), `unexpected diagnostic message: ${msg}`);
});

test("reader.validateBinary diagnostic on a domain form (scene) — core schema doesn't know it", () => {
  // Reinforces the "core only" boundary: data forms like `scene` and
  // `canvas` are domain plugin territory and the shipped wasm doesn't
  // include them. A real consumer would either supply a richer schema
  // (build a custom wasm artifact) or pre-validate at the producer.
  const bin = encoder.toBinary('(scene :bpm 130 (canvas :name "main"))');
  const report = reader.validateBinary(bin);
  assert.ok(report.diagnostics.length >= 2, 'expected scene + canvas diagnostics');
  assert.ok(report.diagnostics.every((d) => d.severity === 'err'));
});

test('reader.tryValidateBinary returns errorName on a corrupted binary', () => {
  // Truncate to fewer than 16 header bytes — must trip InvalidMagic / Truncated.
  const corrupt = new Uint8Array([0x53, 0x4a, 0x31, 0x0a, 0x01, 0x00]);
  const r = reader.tryValidateBinary(corrupt);
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.match(r.errorName, /(Truncated|InvalidMagic|InvalidVersion|InvalidFlags)/);
  }
});

test('reader.validateBinary throws SjonWasmError on a corrupted binary', () => {
  const corrupt = new Uint8Array([0xff, 0xff, 0xff, 0xff]);
  assert.throws(
    () => reader.validateBinary(corrupt),
    (err) => {
      assert.ok(err instanceof SjonWasmError);
      assert.equal(err.fnName, 'sjon_validate_binary');
      return true;
    },
  );
});

// ---------------------------------------------------------------------------
// eval_expr_binary
// ---------------------------------------------------------------------------

test('reader.evalExprBinary computes (+ 1 2 (* 3 4)) = 15', () => {
  const bin = encoder.toBinary('(+ 1 2 (* 3 4))');
  const value = reader.evalExprBinary(bin);
  assert.equal(value, 15);
});

test('reader.evalExprBinary handles vec3 → JSON array', () => {
  const bin = encoder.toBinary('(vec3 1 2 3)');
  const value = reader.evalExprBinary(bin);
  assert.deepEqual(value, [1, 2, 3]);
});

test('reader.evalExprBinary surfaces MultipleRoots for multi-root input', () => {
  const bin = encoder.toBinary('1 2 3'); // three roots
  assert.throws(
    () => reader.evalExprBinary(bin),
    (err) => {
      assert.ok(err instanceof SjonWasmError);
      assert.equal(err.fnName, 'sjon_eval_expr_binary');
      assert.equal(err.errorName, 'MultipleRoots');
      return true;
    },
  );
});

test('reader.evalExprBinary surfaces DivisionByZero from the evaluator', () => {
  const bin = encoder.toBinary('(/ 1 0)');
  assert.throws(
    () => reader.evalExprBinary(bin),
    (err) => err instanceof SjonWasmError && err.errorName === 'DivisionByZero',
  );
});

// ---------------------------------------------------------------------------
// encoder.evalExpr (text path) parity check
// ---------------------------------------------------------------------------

test('encoder.evalExpr === reader.evalExprBinary for the same expression', () => {
  const expressions = [
    '(+ 1 2 3)',
    '(- 10 4)',
    '(* 2 3 4)',
    '(if (< 1 2) 100 200)',
    '(let [r 0.5] (vec3 r r r))',
    '(clamp 1.5 0 1)',
    '(lerp 10 20 0.25)',
  ];
  for (const src of expressions) {
    const direct = encoder.evalExpr(src);
    const viaBinary = reader.evalExprBinary(encoder.toBinary(src));
    assert.deepEqual(viaBinary, direct, `divergence on ${src}`);
  }
});

// ---------------------------------------------------------------------------
// Empty-input edge cases
// ---------------------------------------------------------------------------

test("encoder.validate('') yields a parse diagnostic-free clean tree", () => {
  const r = encoder.validate('');
  assert.deepEqual(r.parse_diagnostics, []);
  assert.deepEqual(r.diagnostics, []);
});

// ---------------------------------------------------------------------------
// Browser-style loadFromBytes — mirrors the fs-based load() under Node by
// reading the wasm file into memory first, then instantiating from bytes.
// In the browser the bytes come from `fetch(url).then(r => r.arrayBuffer())`.
// ---------------------------------------------------------------------------

test('SjonEncoder.loadFromBytes produces a working encoder', async () => {
  const bytes = await fs.readFile(encPath);
  const enc = await SjonEncoder.loadFromBytes(bytes);
  assert.equal(enc.describe().name, 'sjon');
  const bin = enc.toBinary('(+ 1 2 3)');
  assert.equal(enc.evalExpr('(+ 1 2 3)'), 6);
  assert.equal(bin[0], 0x53); // "S" — Binary IR magic byte 0
});

test('SjonReader.loadFromBytes produces a working reader', async () => {
  const bytes = await fs.readFile(readerPath);
  const rd = await SjonReader.loadFromBytes(bytes);
  assert.equal(rd.describe().name, 'sjon-binary');
  const bin = encoder.toBinary('(* 6 7)');
  assert.equal(rd.evalExprBinary(bin), 42);
});

// ---------------------------------------------------------------------------
// toJson / applyEdit — text-side projection and reducer surface that the
// web-todo demo (examples/web-todo/) leans on for render + dispatch.
// ---------------------------------------------------------------------------

test('encoder.toJson (compact) collapses keywords / symbols to strings', () => {
  // `:tag :origin` would be greedy-paired as two positional keyword
  // flags (LANGUAGE.md §5.4); wrap keyword values in a vector to
  // keep them as the slot value of a kvpair.
  const json = encoder.toJson('(point :name p0 :tag [:origin])', { mode: 'compact' });
  assert.deepEqual(json, { $form: 'point', name: 'p0', tag: ['origin'] });
});

test('encoder.toJson (canonical, default) preserves the kw/sym trichotomy', () => {
  const json = encoder.toJson('(point :name p0 :tag [:origin])');
  assert.deepEqual(json, {
    $form: 'point',
    name: { $sym: 'p0' },
    tag: [{ $kw: 'origin' }],
  });
});

test('encoder.applyEdit set_keyword toggles a boolean leaf', () => {
  const before = '(todo :id 1 :text "buy milk" :done false)';
  const after = encoder.applyEdit(before, {
    op: 'set_keyword',
    path: [],
    key: 'done',
    value: true,
  });
  assert.match(after, /:done\s+true/);
  assert.ok(!/:done\s+false/.test(after), `done=false should be replaced: ${after}`);
});

test('encoder.applyEdit insert_positional appends a (todo …) into :items', () => {
  const before = `(todo-app :filter all :next-id 2 :items [
  (todo :id 1 :text "first" :done false)
])`;
  const after = encoder.applyEdit(before, {
    op: 'insert_positional',
    path: ['items'],
    value: { $form: 'todo', id: 2, text: 'second', done: false },
  });
  assert.match(after, /:id\s+2/);
  assert.match(after, /"second"/);
});
