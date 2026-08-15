//! Pattern time core — the shared integer tick grid that SJON-adjacent
//! engines (the pattern query walker in `PatternQuery.zig`, the animation
//! driver, the audio engine) compute musical time on.
//!
//! Time is `i64` ticks on a fixed grid of `PPC` pulses per cycle. A fixed
//! integer grid is the exact, driftless substitute for Strudel's rational
//! time: absolute tick = `cycle * PPC + intra`, with `cycle =
//! @divFloor(t, PPC)` and `intra = @mod(t, PPC)`. Floor division matches
//! JS `Math.floor` and Rust `div_euclid` on negative cycles, so the same
//! arithmetic is reproducible bit-for-bit in every host.
//!
//! Invariants:
//!   * `PPC = 720720` is a documented cross-host constant, divisible by
//!     every integer 1–16 (and so by 11 and 13) — euclid(p, ≤16),
//!     5-/7-tuples, and triplets land on exact ticks. Asserted `comptime`;
//!     a mismatch in any port is exactly the silent divergence a
//!     conformance corpus exists to catch.
//!   * Overflow is a diagnostic, not drift: checked arithmetic trips
//!     `error.TickOverflow` at the `MAX_TICK = 2^53` magnitude ceiling, so
//!     even a TypeScript `number` fallback stays exact. The checked ops are
//!     total over all of `i64` (they widen to `i128` internally); inputs
//!     never need pre-validation.
//!   * `Span` is half-open `[begin, end)` with `begin <= end`. The
//!     zero-width intersection rule follows Strudel's `timespan.mjs`: a
//!     point intersection sitting on the *end* of a non-zero-width span
//!     does not intersect it.
//!
//! Pure `std`-only module: no allocation, no syntax, no diagnostics — it
//! introduces no new wire surface and is consumed by both WASM artifacts.

const std = @import("std");

/// Pulses per cycle. Cross-host constant; see module header.
pub const PPC: i64 = 720720;

comptime {
    // Layout pin for the grid: exact subdivision for every n in 1…16.
    // 11 and 13 (5-/7-tuple companions) are members of that range.
    for (1..17) |n| {
        std.debug.assert(@rem(PPC, @as(i64, @intCast(n))) == 0);
    }
}

/// Absolute time in ticks. `i64` everywhere; see `MAX_TICK` for the
/// portable magnitude ceiling enforced by the checked ops.
pub const Tick = i64;

/// Magnitude ceiling for checked tick arithmetic: `2^53`, the largest
/// integer range a JS/TS `number` represents exactly. `|t| <= MAX_TICK`
/// after every checked op, identically in all hosts.
pub const MAX_TICK: i64 = 1 << 53;

comptime {
    // The ceiling must leave i64 headroom (so `MAX_TICK` itself, and
    // sums just past it, are representable while being rejected).
    std.debug.assert(MAX_TICK < std.math.maxInt(i64) / 2);
    std.debug.assert(@rem(MAX_TICK, 2) == 0);
}

/// Explicit error set. `TickOverflow` = a checked op produced a value
/// with `|v| > MAX_TICK`; callers surface it as a diagnostic
/// (e.g. `pattern_tick_overflow`), never a panic — tick values originate
/// in user documents.
pub const Error = error{TickOverflow};

/// Cycle index containing tick `t` (Strudel `.sam()` analogue). Floor
/// division: tick `-1` is in cycle `-1`, not cycle `0`. Total over `i64`.
pub fn cycleOf(t: Tick) i64 {
    const c = @divFloor(t, PPC);
    std.debug.assert(c * PPC <= t);
    std.debug.assert(t - c * PPC < PPC);
    return c;
}

/// Position of `t` within its cycle (Strudel `.cyclePos()` analogue).
/// Always in `[0, PPC)`, including for negative `t`. Total over `i64`.
pub fn cyclePos(t: Tick) Tick {
    const p = @mod(t, PPC);
    std.debug.assert(p >= 0);
    std.debug.assert(p < PPC);
    return p;
}

/// First tick of the cycle containing `t` (`cycleOf(t) * PPC`).
/// Total over `i64`; the product is exact because `|cycleOf(t)| * PPC`
/// never exceeds `|t| + PPC`.
pub fn cycleStart(t: Tick) Tick {
    const s = t - cyclePos(t);
    std.debug.assert(cyclePos(s) == 0);
    std.debug.assert(s <= t);
    return s;
}

/// Checked addition under the `MAX_TICK` ceiling.
pub fn checkedAdd(a: Tick, b: Tick) Error!Tick {
    const wide = @as(i128, a) + @as(i128, b);
    if (wide > MAX_TICK or wide < -MAX_TICK) return error.TickOverflow;
    const r: Tick = @intCast(wide);
    std.debug.assert(r <= MAX_TICK);
    std.debug.assert(r >= -MAX_TICK);
    return r;
}

/// Checked multiplication under the `MAX_TICK` ceiling. Widens to `i128`
/// internally, so it is total over all `i64` inputs (no UB on extreme
/// arguments — they trip the error instead).
pub fn checkedMul(a: Tick, b: Tick) Error!Tick {
    const wide = @as(i128, a) * @as(i128, b);
    if (wide > MAX_TICK or wide < -MAX_TICK) return error.TickOverflow;
    const r: Tick = @intCast(wide);
    std.debug.assert(r <= MAX_TICK);
    std.debug.assert(r >= -MAX_TICK);
    return r;
}

/// `floor(t * num / den)` with an exact `i128` intermediate — the one
/// primitive time scaling (`fast`/`slow`, meter conversion) is built on.
/// Floor (not trunc) so negative times scale consistently with
/// `cycleOf`'s floor-division convention.
///
/// `den` must be positive: denominators derive from grid constants
/// (`PPC`, meter divisors), never from raw user input — asserted, not
/// an error.
pub fn mulDiv(t: Tick, num: i64, den: i64) Error!Tick {
    std.debug.assert(den > 0);
    const wide = @divFloor(@as(i128, t) * @as(i128, num), @as(i128, den));
    if (wide > MAX_TICK or wide < -MAX_TICK) return error.TickOverflow;
    const r: Tick = @intCast(wide);
    std.debug.assert(r <= MAX_TICK);
    std.debug.assert(r >= -MAX_TICK);
    return r;
}

/// Half-open tick interval `[begin, end)`. Zero-width (`begin == end`)
/// spans are legal and represent points (continuous-signal samples).
pub const Span = struct {
    begin: Tick,
    end: Tick,

    /// Construct with the `begin <= end` invariant asserted. Spans are
    /// built by engine code from already-ordered ticks; a reversed pair
    /// is a programmer error, not user input.
    pub fn init(begin: Tick, end: Tick) Span {
        std.debug.assert(begin <= end);
        return .{ .begin = begin, .end = end };
    }

    /// Reject a *query window* whose endpoints sit outside the `MAX_TICK`
    /// magnitude ceiling, before any walk touches them.
    ///
    /// The checked ops (`checkedAdd` and friends) widen to `i128` and are
    /// total, but the walk itself does not go through them: `cycleStart(t)
    /// + PPC` in `CycleIterator.next` and `t - cyclePos(t)` in `cycleStart`
    /// are plain `i64` arithmetic, chosen so the hot iterator carries no
    /// per-step check. That is only sound while endpoints are known to be
    /// in range — a window near `i64` extremes overflows both. Window
    /// endpoints come straight from user input (`--begin=` / `--end=`, the
    /// `sjon_query_pattern` export), so this is the guard that makes the
    /// module header's "inputs never need pre-validation" true.
    pub fn checkTickBounds(self: Span) Error!void {
        if (self.begin > MAX_TICK or self.begin < -MAX_TICK) return error.TickOverflow;
        if (self.end > MAX_TICK or self.end < -MAX_TICK) return error.TickOverflow;
    }

    pub fn width(self: Span) Tick {
        std.debug.assert(self.begin <= self.end);
        return self.end - self.begin;
    }

    /// Structural equality — both endpoints match. (Plain-struct equality
    /// already works for `std.testing.expectEqual`; this is the named form
    /// engine code reads on, mirroring `TimedSpan.eql`.)
    pub fn eql(self: Span, other: Span) bool {
        return self.begin == other.begin and self.end == other.end;
    }

    /// Intersection with Strudel's zero-width edge rule: a point
    /// intersection located at the *end* of a non-zero-width input does
    /// not count (the half-open interval excludes its end), but a point
    /// at a span's *begin*, or meeting a zero-width span, does.
    /// Returns `null` when the spans do not intersect.
    pub fn intersection(self: Span, other: Span) ?Span {
        std.debug.assert(self.begin <= self.end);
        std.debug.assert(other.begin <= other.end);
        const b = @max(self.begin, other.begin);
        const e = @min(self.end, other.end);
        if (b > e) return null;
        if (b == e) {
            if (b == self.end and self.begin < self.end) return null;
            if (b == other.end and other.begin < other.end) return null;
        }
        const r = Span.init(b, e);
        std.debug.assert(r.begin >= self.begin);
        std.debug.assert(r.end <= self.end);
        std.debug.assert(r.begin >= other.begin);
        std.debug.assert(r.end <= other.end);
        return r;
    }

    /// Iterator over the per-cycle pieces of this span — the
    /// `splitQueries` cut points: each yielded span lies within a single
    /// cycle, pieces are adjacent and cover `[begin, end)` exactly. A
    /// zero-width span yields itself once. No allocation.
    pub fn cycles(self: Span) CycleIterator {
        std.debug.assert(self.begin <= self.end);
        return .{ .cursor = self.begin, .span = self, .done_zero_width = false };
    }
};

/// See `Span.cycles`. Single-pass; `next()` returns `null` when the span
/// is exhausted.
pub const CycleIterator = struct {
    cursor: Tick,
    span: Span,
    done_zero_width: bool,

    pub fn next(self: *CycleIterator) ?Span {
        if (self.span.begin == self.span.end) {
            if (self.done_zero_width) return null;
            self.done_zero_width = true;
            return self.span;
        }
        if (self.cursor >= self.span.end) return null;
        const boundary = cycleStart(self.cursor) + PPC;
        const piece_end = @min(boundary, self.span.end);
        const piece = Span.init(self.cursor, piece_end);
        self.cursor = piece_end;
        std.debug.assert(piece.width() > 0);
        std.debug.assert(cycleOf(piece.begin) == cycleOf(piece.end - 1));
        return piece;
    }
};

/// The timing pair carried by a hap: an optional `whole` (the event's
/// full extent) and the `part` actually intersecting the query window.
/// Deliberately value-less — the hap's payload type lives with the
/// consumer (`PatternQuery.Hap`), so this time core stays std-only and
/// shareable by the animation driver and audio engine.
///
/// Mirrors Strudel's `Hap` timing fields:
///   * `whole == null` is a continuous-signal sample (no discrete onset).
///   * `whole != null` is a discrete event; `part` is then always a
///     sub-span of `whole`.
///   * "has onset" — the event's start lies inside the window — iff
///     `whole != null and whole.begin == part.begin`.
pub const TimedSpan = struct {
    whole: ?Span,
    part: Span,

    /// True when this hap carries the onset of its event (Strudel
    /// `hap.hasOnset()`): a discrete `whole` whose begin coincides with
    /// the `part` begin. Continuous samples (`whole == null`) never have
    /// an onset.
    pub fn hasOnset(self: TimedSpan) bool {
        const w = self.whole orelse return false;
        return w.begin == self.part.begin;
    }

    /// Structural equality. `whole` matches when both are null or both are
    /// equal spans; `part` matches exactly.
    pub fn eql(self: TimedSpan, other: TimedSpan) bool {
        if (!self.part.eql(other.part)) return false;
        if (self.whole) |a| {
            const b = other.whole orelse return false;
            return a.eql(b);
        }
        return other.whole == null;
    }
};

test "PPC subdivides exactly for 1..16" {
    inline for (1..17) |n| {
        try std.testing.expectEqual(@as(i64, 0), @rem(PPC, @as(i64, @intCast(n))));
    }
}

test "cycleOf / cyclePos floor semantics on negative ticks" {
    try std.testing.expectEqual(@as(i64, 0), cycleOf(0));
    try std.testing.expectEqual(@as(i64, 0), cycleOf(PPC - 1));
    try std.testing.expectEqual(@as(i64, 1), cycleOf(PPC));
    try std.testing.expectEqual(@as(i64, -1), cycleOf(-1));
    try std.testing.expectEqual(@as(i64, -1), cycleOf(-PPC));
    try std.testing.expectEqual(@as(i64, -2), cycleOf(-PPC - 1));

    try std.testing.expectEqual(@as(Tick, PPC - 1), cyclePos(-1));
    try std.testing.expectEqual(@as(Tick, 0), cyclePos(-PPC));
    try std.testing.expectEqual(@as(Tick, 5), cyclePos(PPC + 5));

    try std.testing.expectEqual(@as(Tick, -PPC), cycleStart(-1));
    try std.testing.expectEqual(@as(Tick, PPC), cycleStart(PPC + 5));
}

test "checked ops trip TickOverflow at the 2^53 ceiling" {
    try std.testing.expectEqual(@as(Tick, MAX_TICK), try checkedAdd(MAX_TICK - 1, 1));
    try std.testing.expectError(error.TickOverflow, checkedAdd(MAX_TICK, 1));
    try std.testing.expectError(error.TickOverflow, checkedAdd(-MAX_TICK, -1));

    try std.testing.expectEqual(@as(Tick, MAX_TICK), try checkedMul(@divExact(MAX_TICK, 2), 2));
    try std.testing.expectError(error.TickOverflow, checkedMul(MAX_TICK, 2));
    try std.testing.expectError(error.TickOverflow, checkedMul(-MAX_TICK, 2));
    // Extreme i64 inputs are handled (i128 widening), not UB.
    try std.testing.expectError(error.TickOverflow, checkedMul(std.math.minInt(i64), std.math.minInt(i64)));
}

test "Span.checkTickBounds admits the ceiling and rejects past it" {
    // Inclusive at `±MAX_TICK`, matching `checkedAdd`'s ceiling exactly.
    try Span.init(-MAX_TICK, MAX_TICK).checkTickBounds();
    try Span.init(0, PPC).checkTickBounds();

    try std.testing.expectError(error.TickOverflow, (Span{ .begin = 0, .end = MAX_TICK + 1 }).checkTickBounds());
    try std.testing.expectError(error.TickOverflow, (Span{ .begin = -MAX_TICK - 1, .end = 0 }).checkTickBounds());

    // The shapes that reach the engine from a host checking only `begin <= end`:
    // unchecked `cycleStart(t) + PPC` overflows on both.
    const max = std.math.maxInt(i64);
    const min = std.math.minInt(i64);
    try std.testing.expectError(error.TickOverflow, (Span{ .begin = max - 10, .end = max - 5 }).checkTickBounds());
    try std.testing.expectError(error.TickOverflow, (Span{ .begin = min, .end = 0 }).checkTickBounds());
}

test "mulDiv scales exactly and floors negatives" {
    try std.testing.expectEqual(@as(Tick, PPC * 2), try mulDiv(PPC, 2, 1));
    try std.testing.expectEqual(@as(Tick, @divExact(PPC, 2)), try mulDiv(PPC, 1, 2));
    // Floor, not trunc: -3/2 = -2.
    try std.testing.expectEqual(@as(Tick, -2), try mulDiv(-3, 1, 2));
    try std.testing.expectEqual(@as(Tick, 2), try mulDiv(3, 1, 2) + 1);
    try std.testing.expectError(error.TickOverflow, mulDiv(MAX_TICK, 3, 2));
}

test "Span.intersection overlap, disjoint, containment" {
    const a = Span.init(0, 100);
    const b = Span.init(50, 200);
    const ab = a.intersection(b).?;
    try std.testing.expectEqual(@as(Tick, 50), ab.begin);
    try std.testing.expectEqual(@as(Tick, 100), ab.end);

    try std.testing.expectEqual(@as(?Span, null), Span.init(0, 10).intersection(Span.init(20, 30)));

    const inner = Span.init(10, 20);
    const outer = Span.init(0, 100);
    try std.testing.expectEqual(inner, inner.intersection(outer).?);
}

test "Span.intersection zero-width edge rule" {
    const a = Span.init(0, 100);
    // Point at a's end: excluded (half-open).
    try std.testing.expectEqual(@as(?Span, null), a.intersection(Span.init(100, 200)));
    // Point at a's begin but at the *other* span's end: still excluded —
    // the rule applies to either input's end.
    const at_begin = Span.init(-50, 0).intersection(a);
    try std.testing.expectEqual(@as(?Span, null), at_begin);
    // Zero-width span inside a non-zero span: the point survives.
    const point = Span.init(40, 40);
    try std.testing.expectEqual(point, point.intersection(a).?);
    try std.testing.expectEqual(point, a.intersection(point).?);
    // Zero-width span sitting exactly on a's end: excluded.
    const end_point = Span.init(100, 100);
    try std.testing.expectEqual(@as(?Span, null), end_point.intersection(a));
    // Two identical points intersect as the point.
    try std.testing.expectEqual(point, point.intersection(point).?);
}

test "Span.cycles splits at cycle boundaries, covers exactly" {
    var it = Span.init(PPC - 10, PPC + 10).cycles();
    try std.testing.expectEqual(Span.init(PPC - 10, PPC), it.next().?);
    try std.testing.expectEqual(Span.init(PPC, PPC + 10), it.next().?);
    try std.testing.expectEqual(@as(?Span, null), it.next());

    // Negative-to-positive boundary.
    var it2 = Span.init(-10, 10).cycles();
    try std.testing.expectEqual(Span.init(-10, 0), it2.next().?);
    try std.testing.expectEqual(Span.init(0, 10), it2.next().?);
    try std.testing.expectEqual(@as(?Span, null), it2.next());

    // Multi-cycle interior piece is a whole cycle.
    var it3 = Span.init(5, 2 * PPC + 5).cycles();
    try std.testing.expectEqual(Span.init(5, PPC), it3.next().?);
    try std.testing.expectEqual(Span.init(PPC, 2 * PPC), it3.next().?);
    try std.testing.expectEqual(Span.init(2 * PPC, 2 * PPC + 5), it3.next().?);
    try std.testing.expectEqual(@as(?Span, null), it3.next());

    // Zero-width span yields itself exactly once.
    var it4 = Span.init(7, 7).cycles();
    try std.testing.expectEqual(Span.init(7, 7), it4.next().?);
    try std.testing.expectEqual(@as(?Span, null), it4.next());
}

test "Span.eql endpoint match" {
    try std.testing.expect(Span.init(0, 10).eql(Span.init(0, 10)));
    try std.testing.expect(!Span.init(0, 10).eql(Span.init(0, 11)));
    try std.testing.expect(!Span.init(1, 10).eql(Span.init(0, 10)));
    // Zero-width points compare by position.
    try std.testing.expect(Span.init(5, 5).eql(Span.init(5, 5)));
    try std.testing.expect(!Span.init(5, 5).eql(Span.init(6, 6)));
}

test "TimedSpan onset + equality" {
    const part = Span.init(10, 20);
    // Discrete event whose whole starts at the part begin → has onset.
    const onset: TimedSpan = .{ .whole = Span.init(10, 30), .part = part };
    try std.testing.expect(onset.hasOnset());
    // Fragment clipped at the front: whole begins before the part → no onset.
    const fragment: TimedSpan = .{ .whole = Span.init(5, 30), .part = part };
    try std.testing.expect(!fragment.hasOnset());
    // Continuous sample (no whole) never has an onset.
    const sample: TimedSpan = .{ .whole = null, .part = Span.init(15, 15) };
    try std.testing.expect(!sample.hasOnset());

    // Equality distinguishes whole == part, whole != part, and whole == null.
    const whole_eq_part: TimedSpan = .{ .whole = part, .part = part };
    try std.testing.expect(whole_eq_part.eql(.{ .whole = Span.init(10, 20), .part = Span.init(10, 20) }));
    try std.testing.expect(!whole_eq_part.eql(onset));
    try std.testing.expect(!onset.eql(.{ .whole = null, .part = part }));
    try std.testing.expect((TimedSpan{ .whole = null, .part = part }).eql(.{ .whole = null, .part = part }));
}
