// serializeValue golden: a value in SJON's canonical JSON shape → canonical
// SJON text. The emit rules are pinned against the Zig core (`src/Json.zig`,
// `src/Printer.zig`); see value.ts for the line references. Parity with the
// WASM `fromValue` is asserted as parse-equality in the web host's
// conformance suite — here we pin the exact bytes.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { quoteSjonString, serializeValue } from '../src/value.ts';
import type { SjonValue } from '../src/value.ts';

test('scalars: nil / booleans', () => {
  assert.equal(serializeValue(null), 'nil');
  assert.equal(serializeValue(true), 'true');
  assert.equal(serializeValue(false), 'false');
});

test('numbers elide integer .0 and keep fractionals', () => {
  assert.equal(serializeValue(0), '0');
  assert.equal(serializeValue(42), '42');
  assert.equal(serializeValue(-7), '-7');
  assert.equal(serializeValue(1.5), '1.5');
  assert.equal(serializeValue(-0), '0'); // matches Zig's intFromFloat(-0) → "0"
  assert.equal(serializeValue(100), '100');
});

test('non-finite numbers emit nan / inf / -inf (not null)', () => {
  assert.equal(serializeValue(Number.NaN), 'nan');
  assert.equal(serializeValue(Number.POSITIVE_INFINITY), 'inf');
  assert.equal(serializeValue(Number.NEGATIVE_INFINITY), '-inf');
});

test('bigint emits exact digits', () => {
  assert.equal(serializeValue(10n), '10');
  assert.equal(serializeValue(9007199254740993n), '9007199254740993'); // > 2^53
});

test('strings escape ONLY " \\ \\n \\r \\t \\0 (the #1 parity rule)', () => {
  assert.equal(serializeValue('hello'), '"hello"');
  assert.equal(serializeValue('a"b'), '"a\\"b"');
  assert.equal(serializeValue('a\\b'), '"a\\\\b"');
  assert.equal(serializeValue('a\nb'), '"a\\nb"');
  assert.equal(serializeValue('a\rb'), '"a\\rb"');
  assert.equal(serializeValue('a\tb'), '"a\\tb"');
  assert.equal(serializeValue('a\0b'), '"a\\0b"');
});

test('strings pass every other byte through raw (unlike JSON.stringify)', () => {
  // Backspace (0x08) and form-feed (0x0c) are escaped by JSON.stringify but
  // passed raw by SJON. This is the divergence value.ts exists to honour.
  const bs = String.fromCharCode(8); // backspace
  const ff = String.fromCharCode(12); // form-feed
  assert.equal(serializeValue(bs), `"${bs}"`);
  assert.equal(serializeValue(ff), `"${ff}"`);
  assert.notEqual(serializeValue(bs), JSON.stringify(bs)); // raw byte vs "\\b"
  // Non-ASCII passes raw — no \uXXXX escapes.
  assert.equal(serializeValue('café — 日本語 😀'), '"café — 日本語 😀"');
  // quoteSjonString is the shared primitive.
  assert.equal(quoteSjonString('x\ty'), '"x\\ty"');
});

test('symbols emit bare; keywords emit :name; dates/times raw', () => {
  assert.equal(serializeValue({ $sym: 'foo' }), 'foo');
  assert.equal(serializeValue({ $kw: 'mode' }), ':mode');
  assert.equal(serializeValue({ $date: '2024-01-31' }), '2024-01-31');
  assert.equal(serializeValue({ $time: '12:30:00' }), '12:30:00');
});

test('unit numbers emit <n><unit>', () => {
  assert.equal(serializeValue({ $num: [90, 'deg'] }), '90deg');
  assert.equal(serializeValue({ $num: [0.5, 'em'] }), '0.5em');
  assert.equal(serializeValue({ $num: [-50, '%'] }), '-50%');
  assert.equal(serializeValue({ $num: [250, 'ms'] }), '250ms');
});

test('vectors render [a b c], nested', () => {
  assert.equal(serializeValue([1, 2, 3]), '[1 2 3]');
  assert.equal(serializeValue([]), '[]');
  assert.equal(
    serializeValue([
      [1, 2],
      [3, 4],
    ]),
    '[[1 2] [3 4]]',
  );
  assert.equal(serializeValue(['a', { $sym: 'b' }, true]), '["a" b true]');
});

test('exprs render (op …args) with the op bare at index 0', () => {
  assert.equal(serializeValue({ $expr: ['+', 1, 2] }), '(+ 1 2)');
  // Nested expr — the user's canonical example.
  assert.equal(serializeValue({ $expr: ['+', 1, { $expr: ['*', 2, 3] }] }), '(+ 1 (* 2 3))');
  // Zero-arg constant.
  assert.equal(serializeValue({ $expr: ['pi'] }), '(pi)');
  // Qualified expr carries a sibling $ns → (ns/op …).
  assert.equal(serializeValue({ $expr: ['verb', 1], $ns: 'masagin' }), '(masagin/verb 1)');
});

test('forms render (ns/head :key v … child …) — namespace first', () => {
  assert.equal(serializeValue({ $form: 'verb', $ns: 'masagin', ops: 1 }), '(masagin/verb :ops 1)');
  // No $ns → bare head.
  assert.equal(serializeValue({ $form: 'point', x: 1, y: 2 }), '(point :x 1 :y 2)');
  // $children emit positionally after the kvpairs.
  assert.equal(
    serializeValue({ $form: 'group', $ns: 'g', label: 'a', $children: [1, 2] }),
    '(g/group :label "a" 1 2)',
  );
});

test('forms omit keys whose value is undefined (absent optionals)', () => {
  const form: SjonValue = { $form: 'p', a: 1, b: undefined };
  assert.equal(serializeValue(form), '(p :a 1)');
});

test('a user key spelled $$foo unescapes to :$foo (Json.zig escapeKey inverse)', () => {
  assert.equal(serializeValue({ $form: 'f', $$weird: 1 }), '(f :$weird 1)');
});

test('nested form/expr/atom values compose', () => {
  const v: SjonValue = {
    $form: 'scene',
    $ns: 'demo',
    angle: { $num: [90, 'deg'] },
    color: { $sym: 'red' },
    size: { $expr: ['*', 2, { $expr: ['pi'] }] },
    tags: ['a', 'b'],
  };
  assert.equal(
    serializeValue(v),
    '(demo/scene :angle 90deg :color red :size (* 2 (pi)) :tags ["a" "b"])',
  );
});

test('structurally impossible values throw (programmer error, not diagnostic)', () => {
  assert.throws(
    () => serializeValue({ plain: 'object' } as unknown as SjonValue),
    /no SJON discriminator/,
  );
  assert.throws(
    () => serializeValue([undefined] as unknown as SjonValue),
    /not a representable value/,
  );
  assert.throws(() => serializeValue({ $expr: [] } as unknown as SjonValue), /non-empty array/);
  assert.throws(
    () => serializeValue({ $num: [1] } as unknown as SjonValue),
    /\[number, unitString\]/,
  );
});
