// sjon`` tagged template: hole serialization, composition, and the
// injection-safety guarantee (a string hole is a quoted token, never structure).

import { test } from 'node:test';
import assert from 'node:assert/strict';

import * as e from '../src/expr.ts';
import { sjon } from '../src/template.ts';
import * as v from '../src/value-ctor.ts';
import type { SjonValue } from '../src/value.ts';

test('literal text is emitted verbatim; no holes', () => {
  assert.equal(sjon`(pi)`, '(pi)');
  assert.equal(sjon`(point :x 1 :y 2)`, '(point :x 1 :y 2)');
});

test('scalar holes serialize by type', () => {
  assert.equal(sjon`(point :x ${1} :y ${2})`, '(point :x 1 :y 2)');
  assert.equal(sjon`(flag ${true})`, '(flag true)');
  assert.equal(sjon`(empty ${null})`, '(empty nil)');
});

test('atom + expr holes compose', () => {
  assert.equal(sjon`(color ${v.sym('red')})`, '(color red)');
  assert.equal(sjon`(angle ${v.unit(90, 'deg')})`, '(angle 90deg)');
  assert.equal(sjon`(size ${e.mul(2, v.sym('w'))})`, '(size (* 2 w))');
  assert.equal(sjon`(+ 1 ${e.mul(2, 3)})`, '(+ 1 (* 2 3))');
});

test('a string hole becomes a quoted token — it cannot inject structure', () => {
  // The dangerous parens live inside the quoted string, so the surrounding
  // form stays intact: one form with one string-valued key.
  assert.equal(sjon`(x ${') evil ('})`, '(x ") evil (")');
  assert.equal(sjon`(label ${'hi "there"'})`, '(label "hi \\"there\\"")');
});

test('a form-value hole nests as a sub-form', () => {
  const inner: SjonValue = { $form: 'inner', $ns: 'n', a: 1 };
  assert.equal(sjon`(wrap ${inner})`, '(wrap (n/inner :a 1))');
});

test('multiple holes interleave with the surrounding text', () => {
  const out = sjon`(seg ${1} to ${v.sym('end')} via ${e.add(1, 2)})`;
  assert.equal(out, '(seg 1 to end via (+ 1 2))');
});
