// Form.create / .toSjon / .toCanonicalSjon: tag-stamping, optional omission,
// composition with e.*/v.*, and the WASM-gated canonical path.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import * as s from '../src/builder.ts';
import * as e from '../src/expr.ts';
import * as v from '../src/value-ctor.ts';
import { serializeValue } from '../src/value.ts';
import type { ValidateBackend } from '../src/backend.ts';
import type { SjonValue } from '../src/value.ts';

function expectAssignableTo<Target>(_value: Target): void {
  void _value;
}

// ns defaults to head, so this form's $ns === 'point'. A form with a distinct
// plugin namespace is exercised below (Profile).
const Point = s.form('point', { x: s.number(), y: s.number(), label: s.string().optional() });
const Profile = s.form('profile', { handle: s.string(), age: s.number().optional() }, 'bounds');

test('create stamps $form/$ns from the schema and copies fields', () => {
  assert.deepEqual(Point.create({ x: 1, y: 2, label: 'a' }), {
    $form: 'point',
    $ns: 'point',
    x: 1,
    y: 2,
    label: 'a',
  });
  assert.deepEqual(Profile.create({ handle: 'h', age: 30 }), {
    $form: 'profile',
    $ns: 'bounds',
    handle: 'h',
    age: 30,
  });
});

test('create omits absent optionals (no undefined keys)', () => {
  const val = Point.create({ x: 1, y: 2 });
  assert.deepEqual(val, { $form: 'point', $ns: 'point', x: 1, y: 2 });
  assert.equal('label' in val, false);
});

test('create ignores any $form/$ns smuggled into the input (schema is authoritative)', () => {
  const sneaky = { x: 1, y: 2, $form: 'evil', $ns: 'evil' } as unknown as Parameters<
    typeof Point.create
  >[0];
  assert.deepEqual(Point.create(sneaky), { $form: 'point', $ns: 'point', x: 1, y: 2 });
});

test('toSjon serializes the constructed value — namespace-first (ns/head)', () => {
  // $ns is always stamped (FormOut requires it; plan-01 parse stamps it too),
  // so the head is qualified. A default-ns form reads as `head/head`.
  assert.equal(Point.toSjon({ x: 1, y: 2 }), '(point/point :x 1 :y 2)');
  assert.equal(Point.toSjon({ x: 1, y: 2, label: 'hi' }), '(point/point :x 1 :y 2 :label "hi")');
  // A distinct plugin namespace reads naturally.
  assert.equal(Profile.toSjon({ handle: 'h' }), '(bounds/profile :handle "h")');
});

test('constructed forms compose with e.* and v.* fields', () => {
  const Calc = s.form('calc', { value: s.expr() });
  assert.equal(Calc.toSjon({ value: e.add(1, e.mul(2, 3)) }), '(calc/calc :value (+ 1 (* 2 3)))');

  const Cfg = s.form('cfg', {
    tags: s.vector(s.string()),
    mode: s.symbolMembers(['a', 'b'] as const),
  });
  assert.equal(
    Cfg.toSjon({ tags: ['x', 'y'], mode: v.sym('a') }),
    '(cfg/cfg :tags ["x" "y"] :mode a)',
  );
});

test('a constructed form nests as another value (assignable to SjonValue)', () => {
  const inner = Profile.create({ handle: 'h' });
  assert.equal(
    serializeValue([inner, inner] as SjonValue),
    '[(bounds/profile :handle "h") (bounds/profile :handle "h")]',
  );
});

test('toCanonicalSjon routes through backend.fromValue', () => {
  const backend: ValidateBackend = {
    validate: () => ({ diagnostics: [] }),
    fromValue: (value) => `CANON:${serializeValue(value as SjonValue)}`,
  };
  assert.equal(Point.toCanonicalSjon({ x: 1, y: 2 }, { backend }), 'CANON:(point/point :x 1 :y 2)');
});

test('toCanonicalSjon throws on a backend without fromValue', () => {
  const validateOnly: ValidateBackend = { validate: () => ({ diagnostics: [] }) };
  assert.throws(
    () => Point.toCanonicalSjon({ x: 1, y: 2 }, { backend: validateOnly }),
    /no `fromValue`/,
  );
});

// --- Compile-time probes ----------------------------------------------------

function _probes(): void {
  const val = Point.create({ x: 1, y: 2 });
  expectAssignableTo<SjonValue>(val);
  expectAssignableTo<{
    readonly $form: 'point';
    readonly $ns: 'point';
    readonly x: number;
    readonly y: number;
    readonly label?: string;
  }>(val);
  // @ts-expect-error x is a required field
  Point.create({ y: 2 });
  // @ts-expect-error wrong field type
  Point.create({ x: 'no', y: 2 });
  // @ts-expect-error undeclared keys are rejected (excess property check)
  Point.create({ x: 1, y: 2, nope: true });
}
void _probes;
