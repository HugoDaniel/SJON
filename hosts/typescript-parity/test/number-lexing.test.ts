// Number lexing — the port's numeric rules, pinned against the Zig lexer.
//
// These used to be a documented approximation: the numeric portion swept
// every plausible byte and the unit suffix ran to the next delimiter,
// with a comment saying the corpus "sits clear of that overlap". Two
// features made the approximation load-bearing rather than cosmetic:
//
//   * hex integers, where `0xFF` must be 255 and not the value 0 with a
//     unit of `xFF`;
//   * digit-leading member spellings, where a member's *unit* is part of
//     its identity — so reading `1em` as `1e` plus unit `m` silently
//     misses the member `1em`, and `2d-array` must carry the whole
//     hyphenated unit.
//
// The corpus pins the cases a schema can observe. This file pins the
// lexing itself, including the negative space the corpus cannot express
// (a spelling that must stay TWO tokens).

import { test } from 'node:test';
import * as assert from 'node:assert/strict';

import { parse } from '../src/parser.ts';
import type { Node } from '../src/ast.ts';

function nodes(src: string): readonly Node[] {
  return parse(src);
}

/** The one number node in `src`, asserted to be the only root. */
function oneNumber(src: string): { value: number; unit?: string; integerBits?: bigint } {
  const roots = nodes(src);
  assert.equal(roots.length, 1, `expected one root for ${src}`);
  const n = roots[0]!;
  assert.equal(n.tag, 'number', `expected a number for ${src}`);
  return n as { value: number; unit?: string; integerBits?: bigint };
}

test('unit suffix: letters, and a hyphen only before another letter', () => {
  assert.deepEqual(oneNumber('2d'), {
    tag: 'number',
    value: 2,
    unit: 'd',
    span: { start: 0, end: 2 },
  });

  const arr = oneNumber('2d-array');
  assert.equal(arr.value, 2);
  assert.equal(arr.unit, 'd-array');

  const perFrame = oneNumber('5ms-per-frame');
  assert.equal(perFrame.value, 5);
  assert.equal(perFrame.unit, 'ms-per-frame');

  const pct = oneNumber('50%');
  assert.equal(pct.value, 50);
  assert.equal(pct.unit, '%');
});

test('a hyphen before a non-letter ends the token — `1em-2` is TWO nodes', () => {
  // The negative space, and the reason the hyphen rule is narrow: a
  // permissive "hyphens allowed inside a unit" rule would make this one
  // node with the unit `em-2`, and the Zig lexer would disagree.
  const roots = nodes('1em-2');
  assert.equal(roots.length, 2);
  assert.deepEqual(
    roots.map((n) => [n.tag, (n as { value?: number }).value, (n as { unit?: string }).unit]),
    [
      ['number', 1, 'em'],
      ['number', -2, undefined],
    ],
  );

  // Same with a digit-leading-looking tail.
  const pair = nodes('2d-2');
  assert.equal(pair.length, 2);
  assert.equal((pair[0] as { unit?: string }).unit, 'd');
  assert.equal((pair[1] as { value: number }).value, -2);

  // A *trailing* hyphen (`2d-`) also ends the unit at `2d`, but it then
  // leaves a bare `-` as the next value, which this port throws on for
  // reasons unrelated to units — see `parse-recovery.test.ts`'s
  // "an invalid number literal throws". Asserting it here would pin that
  // boundary in the wrong file.
  assert.throws(() => nodes('2d-'));
});

test('`e` starts an exponent only before a digit or sign', () => {
  // `1em` is the value 1 with unit `em`. The old sweep consumed the `e`
  // into the numeric run and left `m` as the unit, which is a different
  // member.
  const em = oneNumber('1em');
  assert.equal(em.value, 1);
  assert.equal(em.unit, 'em');

  const exp = oneNumber('1e9');
  assert.equal(exp.value, 1e9);
  assert.equal(exp.unit, undefined);

  const both = oneNumber('1.5e2hz');
  assert.equal(both.value, 150);
  assert.equal(both.unit, 'hz');

  const signed = oneNumber('1.5e-10');
  assert.equal(signed.value, 1.5e-10);
  assert.equal(signed.unit, undefined);
});

test('digit-group underscores are stripped from the numeric portion', () => {
  // The old sweep never consumed `_` at all, so `1_000ms` came out as the
  // value 1 with no unit and `_000ms` as a stray symbol.
  const grouped = oneNumber('1_000ms');
  assert.equal(grouped.value, 1000);
  assert.equal(grouped.unit, 'ms');

  const plain = oneNumber('1_000_000');
  assert.equal(plain.value, 1000000);
  assert.equal(plain.integerBits, 1000000n);
});

test('adjacent unit numbers split the way the lexer splits them', () => {
  // `90deg5px` is `90deg` then `5px`: a digit ends the unit.
  const roots = nodes('90deg5px');
  assert.equal(roots.length, 2);
  assert.deepEqual(
    roots.map((n) => (n as { unit?: string }).unit),
    ['deg', 'px'],
  );
});

test('hex takes no unit and terminates at the first non-hex byte', () => {
  const hex = oneNumber('0xFF');
  assert.equal(hex.value, 255);
  assert.equal(hex.unit, undefined);

  // `ms` is a symbol here, not a unit — hex is an integer literal.
  const roots = nodes('0xFFms');
  assert.equal(roots.length, 2);
  assert.equal((roots[0] as { value: number }).value, 255);
  assert.equal(roots[1]?.tag, 'symbol');
});
