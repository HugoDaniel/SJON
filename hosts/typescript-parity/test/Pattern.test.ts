// Pattern time-core fidelity pin — ported 1:1 from the inline tests in
// `src/Pattern.zig`. These lock the tick grid, floor-division semantics on
// negative cycles, the 2^53 overflow ceiling, the zero-width intersection
// edge rule, and the splitQueries iterator to the Zig substrate. If any of
// these drift, the cross-host pattern conformance corpus would silently
// diverge — exactly what this pin prevents.

import test from 'node:test';
import assert from 'node:assert';

import {
  MAX_TICK,
  PPC,
  TickOverflowError,
  type Span,
  type TimedSpan,
  checkedAdd,
  checkedMul,
  cycleOf,
  cyclePos,
  cycleStart,
  cycles,
  hasOnset,
  intersection,
  mulDiv,
  span,
  spanEql,
  timedSpanEql,
} from '../src/Pattern.ts';

function collect(s: Span): Span[] {
  return [...cycles(s)];
}

test('PPC subdivides exactly for 1..16', () => {
  for (let n = 1; n <= 16; n++) assert.equal(PPC % n, 0);
});

test('cycleOf / cyclePos floor semantics on negative ticks', () => {
  assert.equal(cycleOf(0), 0);
  assert.equal(cycleOf(PPC - 1), 0);
  assert.equal(cycleOf(PPC), 1);
  assert.equal(cycleOf(-1), -1);
  assert.equal(cycleOf(-PPC), -1);
  assert.equal(cycleOf(-PPC - 1), -2);

  assert.equal(cyclePos(-1), PPC - 1);
  assert.equal(cyclePos(-PPC), 0);
  assert.equal(cyclePos(PPC + 5), 5);

  assert.equal(cycleStart(-1), -PPC);
  assert.equal(cycleStart(PPC + 5), PPC);
});

test('checked ops trip TickOverflow at the 2^53 ceiling', () => {
  assert.equal(checkedAdd(MAX_TICK - 1, 1), MAX_TICK);
  assert.throws(() => checkedAdd(MAX_TICK, 1), TickOverflowError);
  assert.throws(() => checkedAdd(-MAX_TICK, -1), TickOverflowError);

  assert.equal(checkedMul(MAX_TICK / 2, 2), MAX_TICK);
  assert.throws(() => checkedMul(MAX_TICK, 2), TickOverflowError);
  assert.throws(() => checkedMul(-MAX_TICK, 2), TickOverflowError);
});

test('mulDiv scales exactly and floors negatives', () => {
  assert.equal(mulDiv(PPC, 2, 1), PPC * 2);
  assert.equal(mulDiv(PPC, 1, 2), PPC / 2);
  // Floor, not trunc: -3/2 = -2.
  assert.equal(mulDiv(-3, 1, 2), -2);
  assert.equal(mulDiv(3, 1, 2) + 1, 2);
  assert.throws(() => mulDiv(MAX_TICK, 3, 2), TickOverflowError);
});

test('intersection overlap, disjoint, containment', () => {
  const ab = intersection(span(0, 100), span(50, 200));
  assert.ok(ab !== null && ab.begin === 50 && ab.end === 100);

  assert.equal(intersection(span(0, 10), span(20, 30)), null);

  const inner = span(10, 20);
  const got = intersection(inner, span(0, 100));
  assert.ok(got !== null && spanEql(got, inner));
});

test('intersection zero-width edge rule', () => {
  const a = span(0, 100);
  // Point at a's end: excluded (half-open).
  assert.equal(intersection(a, span(100, 200)), null);
  // Point at a's begin but at the other span's end: still excluded.
  assert.equal(intersection(span(-50, 0), a), null);
  // Zero-width span inside a non-zero span: the point survives.
  const point = span(40, 40);
  assert.ok(spanEql(intersection(point, a)!, point));
  assert.ok(spanEql(intersection(a, point)!, point));
  // Zero-width span on a's end: excluded.
  assert.equal(intersection(span(100, 100), a), null);
  // Two identical points intersect as the point.
  assert.ok(spanEql(intersection(point, point)!, point));
});

test('cycles splits at cycle boundaries, covers exactly', () => {
  assert.deepEqual(collect(span(PPC - 10, PPC + 10)), [span(PPC - 10, PPC), span(PPC, PPC + 10)]);
  assert.deepEqual(collect(span(-10, 10)), [span(-10, 0), span(0, 10)]);
  assert.deepEqual(collect(span(5, 2 * PPC + 5)), [
    span(5, PPC),
    span(PPC, 2 * PPC),
    span(2 * PPC, 2 * PPC + 5),
  ]);
  // Zero-width span yields itself once.
  assert.deepEqual(collect(span(7, 7)), [span(7, 7)]);
});

test('TimedSpan onset + equality', () => {
  const part = span(10, 20);
  const onset: TimedSpan = { whole: span(10, 30), part };
  assert.ok(hasOnset(onset));
  const fragment: TimedSpan = { whole: span(5, 30), part };
  assert.ok(!hasOnset(fragment));
  const sample: TimedSpan = { whole: null, part: span(15, 15) };
  assert.ok(!hasOnset(sample));

  const wholeEqPart: TimedSpan = { whole: part, part };
  assert.ok(timedSpanEql(wholeEqPart, { whole: span(10, 20), part: span(10, 20) }));
  assert.ok(!timedSpanEql(wholeEqPart, onset));
  assert.ok(!timedSpanEql(onset, { whole: null, part }));
  assert.ok(timedSpanEql({ whole: null, part }, { whole: null, part }));
});
