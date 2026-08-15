// Pattern time core — the integer tick grid the PatternQuery engine computes
// musical time on. Native port of `src/Pattern.zig`; the algorithms here must
// stay bit-identical to the Zig substrate (the conformance corpus is the
// cross-host pin).
//
// Ticks are integers on a fixed grid of `PPC` pulses per cycle, bounded by
// `MAX_TICK = 2^53` — the largest integer a JS `number` represents exactly,
// so a `number` tick is lossless within range. Overflow detection and floor
// division go through BigInt intermediates (the analogue of Zig's i128
// widening + `@divFloor`), so negative cycles and the 2^53 ceiling behave
// exactly as on the Zig side.

/** Pulses per cycle. Cross-host constant — divisible by every integer 1..16
 *  (and by 11, 13), so euclid(p, ≤16) / triplets / 5-/7-tuples land exactly. */
export const PPC = 720720;

/** Magnitude ceiling for checked tick arithmetic: 2^53. `|t| <= MAX_TICK`
 *  after every checked op, identically in all hosts. */
export const MAX_TICK = 2 ** 53;

const PPC_BIG = BigInt(PPC);
const MAX_TICK_BIG = BigInt(MAX_TICK);

export type Tick = number;

/** A checked tick op produced a value with `|v| > MAX_TICK`. Surfaced by the
 *  query engine as a `pattern_tick_overflow` diagnostic, never thrown to the
 *  end consumer. Mirrors Zig's `error.TickOverflow`. */
export class TickOverflowError extends Error {
  constructor() {
    super('pattern time exceeded the 2^53 tick ceiling');
    this.name = 'TickOverflowError';
  }
}

/** Floor division on BigInt (`b > 0`); JS `/` truncates toward zero, so a
 *  negative dividend needs the `- 1` correction. Matches Zig `@divFloor`. */
function floorDivBig(a: bigint, b: bigint): bigint {
  let q = a / b;
  if (a % b !== 0n && a < 0n) q -= 1n;
  return q;
}

function checkRange(wide: bigint): number {
  if (wide > MAX_TICK_BIG || wide < -MAX_TICK_BIG) throw new TickOverflowError();
  return Number(wide);
}

/** Checked addition under the `MAX_TICK` ceiling. */
export function checkedAdd(a: Tick, b: Tick): Tick {
  return checkRange(BigInt(a) + BigInt(b));
}

/** Checked multiplication under the `MAX_TICK` ceiling. */
export function checkedMul(a: Tick, b: Tick): Tick {
  return checkRange(BigInt(a) * BigInt(b));
}

/** `floor(t * num / den)` with an exact BigInt intermediate. `den` must be
 *  positive (denominators derive from grid constants, never raw input). */
export function mulDiv(t: Tick, num: number, den: number): Tick {
  if (den <= 0) throw new Error('mulDiv den must be positive');
  return checkRange(floorDivBig(BigInt(t) * BigInt(num), BigInt(den)));
}

/** Exact floor division `floor(a / b)` (`b > 0`) over integers, via BigInt so
 *  it stays correct on negatives and large magnitudes. Matches Zig `@divFloor`. */
export function floorDiv(a: number, b: number): number {
  if (b <= 0) throw new Error('floorDiv divisor must be positive');
  return Number(floorDivBig(BigInt(a), BigInt(b)));
}

/** Cycle index containing tick `t` (floor division — tick -1 is in cycle -1). */
export function cycleOf(t: Tick): number {
  return Number(floorDivBig(BigInt(t), PPC_BIG));
}

/** Position of `t` within its cycle, always in `[0, PPC)`. */
export function cyclePos(t: Tick): Tick {
  return t - cycleOf(t) * PPC;
}

/** First tick of the cycle containing `t` (`cycleOf(t) * PPC`). */
export function cycleStart(t: Tick): Tick {
  return cycleOf(t) * PPC;
}

/** Half-open tick interval `[begin, end)` with `begin <= end`. Zero-width
 *  spans are legal points (continuous-signal samples). */
export interface Span {
  readonly begin: Tick;
  readonly end: Tick;
}

/** Construct a span, asserting `begin <= end` (engine code builds spans from
 *  already-ordered ticks; a reversed pair is a programmer error). */
export function span(begin: Tick, end: Tick): Span {
  if (begin > end) throw new Error(`span begin ${begin} > end ${end}`);
  return { begin, end };
}

export function spanEql(a: Span, b: Span): boolean {
  return a.begin === b.begin && a.end === b.end;
}

/** Intersection with Strudel's zero-width edge rule: a point on the *end* of
 *  a non-zero-width input does not count; a point at a begin, or meeting a
 *  zero-width span, does. Returns `null` when the spans don't intersect. */
export function intersection(self: Span, other: Span): Span | null {
  const b = Math.max(self.begin, other.begin);
  const e = Math.min(self.end, other.end);
  if (b > e) return null;
  if (b === e) {
    if (b === self.end && self.begin < self.end) return null;
    if (b === other.end && other.begin < other.end) return null;
  }
  return { begin: b, end: e };
}

/** Iterate the per-cycle pieces of a span (the `splitQueries` cut points):
 *  each yielded span lies within a single cycle, pieces are adjacent and
 *  cover `[begin, end)` exactly. A zero-width span yields itself once. */
export function* cycles(s: Span): Generator<Span> {
  if (s.begin === s.end) {
    yield s;
    return;
  }
  let cursor = s.begin;
  while (cursor < s.end) {
    const boundary = cycleStart(cursor) + PPC;
    const pieceEnd = Math.min(boundary, s.end);
    yield { begin: cursor, end: pieceEnd };
    cursor = pieceEnd;
  }
}

/** The timing pair carried by a hap: an optional `whole` (the event's full
 *  extent) and the `part` intersecting the query window. `whole === null` is
 *  a continuous-signal sample (no discrete onset). Mirrors `Pattern.TimedSpan`. */
export interface TimedSpan {
  readonly whole: Span | null;
  readonly part: Span;
}

export function hasOnset(t: TimedSpan): boolean {
  return t.whole !== null && t.whole.begin === t.part.begin;
}

export function timedSpanEql(a: TimedSpan, b: TimedSpan): boolean {
  if (!spanEql(a.part, b.part)) return false;
  if (a.whole !== null) return b.whole !== null && spanEql(a.whole, b.whole);
  return b.whole === null;
}
