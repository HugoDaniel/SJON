// v.* atom value constructors: object shape, bare-token guards, and
// assignability to the plan-01 brands + serializeValue's SjonValue.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import * as v from '../src/value-ctor.ts';
import { serializeValue } from '../src/value.ts';
import type { SjonValue } from '../src/value.ts';
import type { CrossRef, Keyword, SjonDate, SjonTime, SjonUnit, Symbol_ } from '../src/infer.ts';

// Compile-time assignability probe (tsc checks it; node strips it).
function expectAssignableTo<Target>(_value: Target): void {
  void _value;
}

test('constructors build the canonical $-tagged objects', () => {
  assert.deepEqual(v.sym('red'), { $sym: 'red' });
  assert.deepEqual(v.kw('mode'), { $kw: 'mode' });
  assert.deepEqual(v.date('2024-01-31'), { $date: '2024-01-31' });
  assert.deepEqual(v.time('12:30:00'), { $time: '12:30:00' });
  assert.deepEqual(v.unit(90, 'deg'), { $num: [90, 'deg'] });
  assert.deepEqual(v.ref('account'), { $sym: 'account' });
});

test('constructed values serialize to canonical SJON text', () => {
  assert.equal(serializeValue(v.sym('red')), 'red');
  assert.equal(serializeValue(v.kw('mode')), ':mode');
  assert.equal(serializeValue(v.date('2024-01-31')), '2024-01-31');
  assert.equal(serializeValue(v.time('12:30:00')), '12:30:00');
  assert.equal(serializeValue(v.unit(90, 'deg')), '90deg');
  assert.equal(serializeValue(v.unit(-50, '%')), '-50%');
  assert.equal(serializeValue(v.ref('account')), 'account');
});

test('operator-like and namespaced symbols are legal', () => {
  assert.equal(serializeValue(v.sym('+')), '+');
  assert.equal(serializeValue(v.sym('-')), '-'); // lone minus is a symbol
  assert.equal(serializeValue(v.sym('route-move')), 'route-move');
  assert.equal(serializeValue(v.sym('masagin/verb')), 'masagin/verb');
  assert.equal(serializeValue(v.sym('C#4')), 'C#4'); // # legal inside, not as head
});

test('v.sym rejects illegal symbol content', () => {
  assert.throws(() => v.sym(''), /cannot be empty/);
  assert.throws(() => v.sym('true'), /reserved literal/);
  assert.throws(() => v.sym('nil'), /reserved literal/);
  assert.throws(() => v.sym('-5'), /negative number/);
  assert.throws(() => v.sym('1abc'), /must start with/); // digit head
  assert.throws(() => v.sym('#tag'), /must start with/); // # head
  assert.throws(() => v.sym('a b'), /illegal symbol character/);
  assert.throws(() => v.sym('a(b'), /illegal symbol character/);
});

test('v.kw rejects illegal keyword content (incl. # and reserved is fine)', () => {
  assert.throws(() => v.kw(''), /cannot be empty/);
  assert.throws(() => v.kw('a#b'), /illegal keyword character/); // # not in keyword_body
  assert.throws(() => v.kw('a b'), /illegal keyword character/);
  // Reserved words and leading digits ARE legal keywords (no classify step).
  assert.equal(serializeValue(v.kw('true')), ':true');
  assert.equal(serializeValue(v.kw('123')), ':123');
});

test('v.date / v.time reject whitespace + delimiters', () => {
  assert.throws(() => v.date(''), /cannot be empty/);
  assert.throws(() => v.date('not a date'), /whitespace or a delimiter/);
  assert.throws(() => v.time('12 30'), /whitespace or a delimiter/);
});

test('v.unit rejects empty / number-like units', () => {
  assert.throws(() => v.unit(5, ''), /cannot be empty/);
  assert.throws(() => v.unit(5, '5x'), /cannot start with a digit/);
  assert.throws(() => v.unit(5, '.5'), /cannot start with a digit/);
  assert.throws(() => v.unit(5, '-x'), /cannot start with a digit/);
});

// --- Assignability (compile-time) ------------------------------------------

function _assignability(): void {
  // Literal generics are preserved.
  expectAssignableTo<Symbol_<'red'>>(v.sym('red'));
  expectAssignableTo<Keyword<'mode'>>(v.kw('mode'));
  expectAssignableTo<SjonDate>(v.date('2024-01-31'));
  expectAssignableTo<SjonTime>(v.time('12:30:00'));
  expectAssignableTo<SjonUnit<'deg'>>(v.unit(90, 'deg'));
  expectAssignableTo<CrossRef<'account'>>(v.ref<'account', string>('a1'));
  // Every constructed value flows into a SjonValue slot (serializeValue input,
  // a form field, a sjon`` hole).
  expectAssignableTo<SjonValue>(v.sym('red'));
  expectAssignableTo<SjonValue>(v.kw('mode'));
  expectAssignableTo<SjonValue>(v.date('2024-01-31'));
  expectAssignableTo<SjonValue>(v.unit(90, 'deg'));
  expectAssignableTo<SjonValue>(v.ref('account'));
}
void _assignability;
