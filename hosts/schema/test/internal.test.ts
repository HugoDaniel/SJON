// Internal helpers. The *compile-time* exhaustiveness guarantee that
// `assertNever` provides is enforced by `tsc` (a new `ShapeIR` variant that a
// serializer switch forgets fails to typecheck). These tests cover only the
// runtime backstop — the path taken when a value is forged past the type
// system (cast through `unknown`).

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { assertNever, isFormObject, isRecord } from '../src/internal.ts';

test('assertNever throws, naming the unhandled variant', () => {
  assert.throws(() => assertNever('rogue-kind' as never), /unhandled variant "rogue-kind"/);
});

test('isRecord accepts plain objects, rejects null / arrays / primitives', () => {
  assert.equal(isRecord({}), true);
  assert.equal(isRecord({ $form: 'x' }), true);
  assert.equal(isRecord(null), false);
  assert.equal(isRecord([]), false);
  assert.equal(isRecord([{ $form: 'x' }]), false);
  assert.equal(isRecord('s'), false);
  assert.equal(isRecord(3), false);
  assert.equal(isRecord(undefined), false);
});

test('isFormObject requires a $form key on a plain (non-array) object', () => {
  assert.equal(isFormObject({ $form: 'todo' }), true);
  assert.equal(isFormObject({ $ns: 'x' }), false);
  assert.equal(isFormObject({}), false);
  assert.equal(isFormObject([{ $form: 'todo' }]), false);
  assert.equal(isFormObject(null), false);
});
