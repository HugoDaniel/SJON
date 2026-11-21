// Task 5 pins the two public entry policies.
//
// `readResult` is total for SJON text: malformed source yields every
// recovered root plus every diagnostic, never a throw. `read` is one
// err-severity check over that single parse: it returns the clean roots or
// throws one `ReadError` whose `result` is the identical parse. Neither
// entry may parse twice or disagree, so the tests compare the two entries'
// trees and diagnostics against each other.
//
// A non-string argument is a programmer `TypeError`, not a syntax
// diagnostic and not a silent coercion. The reader's declared input is a JS
// string (`ReadResult`/`read` signatures); `TextEncoder` would otherwise
// turn `42`, `null`, or a boxed `String` into source text and parse it.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  read,
  readResult,
  ReadError,
  type FormNode,
  type Node,
  type NumberNode,
  type Span,
} from '../src/index.ts';

function span(start: number, end: number): Span {
  return { start, end };
}

function numberNode(start: number, end: number, value: number): NumberNode {
  return { tag: 'number', span: span(start, end), value, unit: null, integer: BigInt(value) };
}

function formNode(
  start: number,
  end: number,
  head: string,
  headSpan: Span,
  children: readonly Node[],
): FormNode {
  return { tag: 'form', span: span(start, end), head, namespace: null, headSpan, children };
}

function captureReadError(source: string): ReadError {
  try {
    read(source);
  } catch (error) {
    assert.ok(error instanceof ReadError, `expected ReadError, got ${String(error)}`);
    return error;
  }
  assert.fail('read did not throw');
}

function assertTypeError(run: () => unknown): void {
  assert.throws(run, TypeError);
}

test('readResult is total and keeps every recovered root beside the diagnostics', () => {
  const source = ') (a) 42 (b';
  // Reaching the assertions at all is the totality half: malformed SJON must
  // not throw out of readResult.
  const result = readResult(source);

  assert.deepEqual(result.roots, [
    formNode(2, 5, 'a', span(3, 4), []),
    numberNode(6, 8, 42),
    formNode(9, 11, 'b', span(10, 11), []),
  ]);
  assert.deepEqual(
    result.diagnostics.map((diagnostic) => ({
      message: diagnostic.message,
      span: diagnostic.span,
      path: diagnostic.path,
    })),
    [
      { message: 'unexpected close delimiter at top level', span: span(0, 1), path: [] },
      { message: 'unclosed delimiter at end of input', span: span(11, 11), path: ['b'] },
    ],
  );
});

test('read returns the same clean roots readResult reports', () => {
  const source = '(camera :ortho :zoom 2)';
  const result = readResult(source);

  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(read(source), result.roots);
});

test('read throws one ReadError whose result is the same parse as readResult', () => {
  const source = '(a [1';
  const result = readResult(source);
  assert.equal(result.diagnostics.length, 2);

  const error = captureReadError(source);
  assert.equal(error.name, 'ReadError');
  assert.deepEqual(error.result.roots, result.roots);
  assert.deepEqual(error.result.diagnostics, result.diagnostics);
  assert.match(error.message, /unspecified/);
});

test('read refuses every err-severity atom diagnostic, not only structural ones', () => {
  for (const source of [
    '(a 18446744073709551616)',
    '(a 2026-13-01)',
    '(a 24:00:00)',
    '(a "\\q")',
  ]) {
    const result = readResult(source);
    assert.ok(
      result.diagnostics.some((diagnostic) => diagnostic.severity === 'err'),
      `${source}: expected an err diagnostic`,
    );
    assert.throws(() => read(source), ReadError, `${source}: read must refuse the partial tree`);
  }
});

test('read returns a fresh roots array per call', () => {
  const first = read('(a)');
  const second = read('(a)');

  assert.notEqual(first, second);
  assert.deepEqual(first, second);
});

test('non-string sources are a TypeError from both entries', () => {
  const nonStrings: readonly unknown[] = [42, null, undefined, true, {}, [], new String('(a)')];

  for (const value of nonStrings) {
    assertTypeError(() => readResult(value as string));
    assertTypeError(() => read(value as string));
  }
});
