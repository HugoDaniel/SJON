//! SJON `Time` — the clock-time primitive.
//!
//! Clock-time only, no date, no time zone, no leap seconds. Stored as
//! a `(hour:u8, minute:u8, second:u8, millisecond:u16)` component
//! struct (6 bytes natural; 5 bytes useful). Packs into the low 40
//! bits of `Ast.Data.immediate`. Range `00:00:00.000 .. 23:59:59.999`.
//!
//! Invariants — every constructed `Time` satisfies:
//!   * `hour <= 23`
//!   * `minute <= 59`
//!   * `second <= 59`
//!   * `millisecond <= 999`
//!
//! Constructors (`init`, `parse`, `unpack`) are the only ways to
//! produce a `Time`. Internal code must not bypass them — raw struct-
//! literal construction of an unvalidated `Time` is a bug. `unpack`
//! is unchecked but only ever fed bits produced by `pack`, so the
//! round-trip stays inside the invariant.
//!
//! Lexical forms (both accepted, no other shapes):
//!   * `HH:MM:SS`     — exactly 8 ASCII chars, leading zeros required.
//!   * `HH:MM:SS.fff` — 12 ASCII chars, exactly 3 fractional digits.
//!
//! Anything else fails `parse` with `InvalidFormat`. The lexer
//! recognises both shapes (via `matchTimeTail`) and emits
//! `Token.Tag.time`; the parser then re-uses `parse` to materialize
//! the value.
//!
//! Canonical output is **shortest-form**: 8 chars when
//! `millisecond == 0`, 12 chars otherwise. `12:34:56.000` round-trips
//! to `12:34:56`; `12:34:56.789` round-trips byte-for-byte. Printer
//! and JSON emitter both apply this rule — keep them aligned.
//!
//! No arithmetic in v1. `addSeconds`, `addMillis`, `diffMillis` are
//! deferred until a concrete plugin need pulls them in. Same reason
//! as `Date`: display dominates over arithmetic in the substrate.
//!
//! Future `DateTime`: a combined zoned/zonless datetime is out of
//! scope here. Note that `2026-05-19T12:34:56` does **not** currently
//! lex as `[date, T, time]` — the existing `.symbol_body` state
//! greedily eats alphanumerics, so `T12` becomes a single symbol
//! token and `:34`, `:56` decompose into kwarg-shaped tokens. Adding
//! a `Tag.datetime` later would mean another bounded-lookahead trigger
//! sitting *after* the date lookahead, not a recomposition of time.

const std = @import("std");

const Time = @This();

hour: u8,
minute: u8,
second: u8,
millisecond: u16,

comptime {
    // The Time value rides in `Ast.Data.immediate` (an 8-byte slot)
    // and in a 5-byte payload on the wire. Pin the natural size so a
    // stdlib alignment change can't silently grow the AST node or
    // the wire payload.
    std.debug.assert(@sizeOf(Time) == 6);
}

/// Constructor / parse failures. `OutOfMemory` is not on this set —
/// `Time` is a value type and never allocates.
pub const Error = error{
    InvalidHour,
    InvalidMinute,
    InvalidSecond,
    InvalidMillisecond,
    /// String didn't match either `HH:MM:SS` or `HH:MM:SS.fff` shape
    /// (length, separator positions, ASCII-digit composition).
    InvalidFormat,
};

/// Construct a validated `Time`. Single source of truth for the
/// `(hour, minute, second, millisecond)` invariant — `parse` and
/// host bridges all funnel through here.
pub fn init(hour: u8, minute: u8, second: u8, millisecond: u16) Error!Time {
    if (hour > 23) return error.InvalidHour;
    if (minute > 59) return error.InvalidMinute;
    if (second > 59) return error.InvalidSecond;
    if (millisecond > 999) return error.InvalidMillisecond;
    return .{
        .hour = hour,
        .minute = minute,
        .second = second,
        .millisecond = millisecond,
    };
}

/// Parse strict ISO 8601 clock form. Accepts exactly two shapes:
/// `HH:MM:SS` (8 chars) or `HH:MM:SS.fff` (12 chars, exactly 3
/// fractional digits). No whitespace, no leading sign, no timezone
/// designator, no microsecond precision — the substrate is
/// intentionally narrow. Leading zeros are required (so `1:34:56`
/// fails; `01:34:56` succeeds).
pub fn parse(s: []const u8) Error!Time {
    if (s.len != 8 and s.len != 12) return error.InvalidFormat;
    if (s[2] != ':' or s[5] != ':') return error.InvalidFormat;
    inline for (.{ 0, 1, 3, 4, 6, 7 }) |i| {
        if (s[i] < '0' or s[i] > '9') return error.InvalidFormat;
    }
    var ms: u16 = 0;
    if (s.len == 12) {
        if (s[8] != '.') return error.InvalidFormat;
        inline for (.{ 9, 10, 11 }) |i| {
            if (s[i] < '0' or s[i] > '9') return error.InvalidFormat;
        }
        ms = @as(u16, s[9] - '0') * 100 +
            @as(u16, s[10] - '0') * 10 +
            @as(u16, s[11] - '0');
    }
    const h: u8 = (s[0] - '0') * 10 + (s[1] - '0');
    const m: u8 = (s[3] - '0') * 10 + (s[4] - '0');
    const sec: u8 = (s[6] - '0') * 10 + (s[7] - '0');
    return init(h, m, sec, ms);
}

pub fn eql(a: Time, b: Time) bool {
    return a.hour == b.hour and
        a.minute == b.minute and
        a.second == b.second and
        a.millisecond == b.millisecond;
}

pub fn order(a: Time, b: Time) std.math.Order {
    if (a.hour != b.hour) return std.math.order(a.hour, b.hour);
    if (a.minute != b.minute) return std.math.order(a.minute, b.minute);
    if (a.second != b.second) return std.math.order(a.second, b.second);
    return std.math.order(a.millisecond, b.millisecond);
}

/// Length of `formatCanonical` output: 8 when `millisecond == 0`,
/// 12 otherwise. Used by `Printer` for its length pre-pass.
pub fn canonicalLen(self: Time) usize {
    return if (self.millisecond == 0) 8 else 12;
}

/// Writes shortest-form canonical: 8 ASCII bytes (`HH:MM:SS`) when
/// `millisecond == 0`, 12 ASCII bytes (`HH:MM:SS.fff`) otherwise.
/// Returns the number of bytes written. Buffer is sized for the
/// long form so callers can stack-allocate without branching.
pub fn formatCanonical(self: Time, buf: *[12]u8) usize {
    std.debug.assert(self.hour <= 23);
    std.debug.assert(self.minute <= 59);
    std.debug.assert(self.second <= 59);
    std.debug.assert(self.millisecond <= 999);
    buf[0] = '0' + (self.hour / 10);
    buf[1] = '0' + (self.hour % 10);
    buf[2] = ':';
    buf[3] = '0' + (self.minute / 10);
    buf[4] = '0' + (self.minute % 10);
    buf[5] = ':';
    buf[6] = '0' + (self.second / 10);
    buf[7] = '0' + (self.second % 10);
    if (self.millisecond == 0) return 8;
    buf[8] = '.';
    buf[9] = '0' + @as(u8, @intCast(self.millisecond / 100));
    buf[10] = '0' + @as(u8, @intCast((self.millisecond / 10) % 10));
    buf[11] = '0' + @as(u8, @intCast(self.millisecond % 10));
    return 12;
}

/// Pack the time into a 64-bit immediate suitable for
/// `Ast.Data.immediate`. Layout (low 40 bits used):
///   * bits  0..7  : `hour`
///   * bits  8..15 : `minute`
///   * bits 16..23 : `second`
///   * bits 24..39 : `millisecond`
/// The high 24 bits are zero and reserved for future microsecond
/// precision.
pub fn pack(self: Time) u64 {
    return @as(u64, self.hour) |
        (@as(u64, self.minute) << 8) |
        (@as(u64, self.second) << 16) |
        (@as(u64, self.millisecond) << 24);
}

/// Inverse of `pack`. Truncates the input; high bits are ignored.
/// The returned `Time` is **not** re-validated — `pack` is only
/// called on constructed (i.e. validated) `Time` values, so the
/// round-trip is already inside the invariant. Calling `unpack` on
/// an arbitrary `u64` is a programmer error.
pub fn unpack(bits: u64) Time {
    return .{
        .hour = @truncate(bits),
        .minute = @truncate(bits >> 8),
        .second = @truncate(bits >> 16),
        .millisecond = @truncate(bits >> 24),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "init: valid times" {
    const t = try init(12, 34, 56, 789);
    try testing.expectEqual(@as(u8, 12), t.hour);
    try testing.expectEqual(@as(u8, 34), t.minute);
    try testing.expectEqual(@as(u8, 56), t.second);
    try testing.expectEqual(@as(u16, 789), t.millisecond);
}

test "init: boundary values" {
    _ = try init(0, 0, 0, 0);
    _ = try init(23, 59, 59, 999);
}

test "init: rejects hour 24" {
    try testing.expectError(error.InvalidHour, init(24, 0, 0, 0));
}

test "init: rejects hour 25" {
    try testing.expectError(error.InvalidHour, init(25, 0, 0, 0));
}

test "init: rejects minute 60" {
    try testing.expectError(error.InvalidMinute, init(0, 60, 0, 0));
}

test "init: rejects second 60" {
    try testing.expectError(error.InvalidSecond, init(0, 0, 60, 0));
}

test "init: rejects millisecond 1000" {
    try testing.expectError(error.InvalidMillisecond, init(0, 0, 0, 1000));
}

test "parse: canonical 8-char form" {
    const t = try parse("12:34:56");
    try testing.expectEqual(@as(u8, 12), t.hour);
    try testing.expectEqual(@as(u8, 34), t.minute);
    try testing.expectEqual(@as(u8, 56), t.second);
    try testing.expectEqual(@as(u16, 0), t.millisecond);
}

test "parse: canonical 12-char form" {
    const t = try parse("12:34:56.789");
    try testing.expectEqual(@as(u8, 12), t.hour);
    try testing.expectEqual(@as(u8, 34), t.minute);
    try testing.expectEqual(@as(u8, 56), t.second);
    try testing.expectEqual(@as(u16, 789), t.millisecond);
}

test "parse: boundaries" {
    _ = try parse("00:00:00");
    _ = try parse("23:59:59.999");
    _ = try parse("00:00:00.000");
}

test "parse: rejects 24:00:00" {
    try testing.expectError(error.InvalidHour, parse("24:00:00"));
}

test "parse: rejects 12:60:00" {
    try testing.expectError(error.InvalidMinute, parse("12:60:00"));
}

test "parse: rejects 12:34:60" {
    try testing.expectError(error.InvalidSecond, parse("12:34:60"));
}

test "parse: rejects missing leading zero" {
    try testing.expectError(error.InvalidFormat, parse("1:34:56"));
}

test "parse: rejects wrong length" {
    try testing.expectError(error.InvalidFormat, parse(""));
    try testing.expectError(error.InvalidFormat, parse("12:34"));
    try testing.expectError(error.InvalidFormat, parse("12:34:5"));
    try testing.expectError(error.InvalidFormat, parse("12:34:56."));
    try testing.expectError(error.InvalidFormat, parse("12:34:56.1"));
    try testing.expectError(error.InvalidFormat, parse("12:34:56.12"));
    try testing.expectError(error.InvalidFormat, parse("12:34:56.1234"));
}

test "parse: rejects wrong separator" {
    try testing.expectError(error.InvalidFormat, parse("12-34-56"));
    try testing.expectError(error.InvalidFormat, parse("12.34.56"));
    try testing.expectError(error.InvalidFormat, parse("123456.x"));
}

test "parse: rejects non-ascii digits" {
    try testing.expectError(error.InvalidFormat, parse("1a:34:56"));
    try testing.expectError(error.InvalidFormat, parse("12:34:56.1a3"));
}

test "eql and order: hour boundary" {
    const a = try init(12, 34, 56, 0);
    const b = try init(13, 0, 0, 0);
    try testing.expect(!a.eql(b));
    try testing.expectEqual(std.math.Order.lt, a.order(b));
}

test "eql and order: minute / second / ms boundaries" {
    const a = try init(12, 34, 56, 100);
    const b = try init(12, 34, 56, 200);
    const c = try init(12, 34, 57, 0);
    const d = try init(12, 35, 0, 0);
    try testing.expectEqual(std.math.Order.lt, a.order(b));
    try testing.expectEqual(std.math.Order.lt, b.order(c));
    try testing.expectEqual(std.math.Order.lt, c.order(d));
    try testing.expect(a.eql(try init(12, 34, 56, 100)));
}

test "canonicalLen: 8 when ms is zero, 12 otherwise" {
    try testing.expectEqual(@as(usize, 8), (try init(12, 34, 56, 0)).canonicalLen());
    try testing.expectEqual(@as(usize, 12), (try init(12, 34, 56, 1)).canonicalLen());
    try testing.expectEqual(@as(usize, 12), (try init(0, 0, 0, 999)).canonicalLen());
}

test "formatCanonical: 8-char form when ms is zero" {
    const t = try init(12, 34, 56, 0);
    var buf: [12]u8 = undefined;
    const n = t.formatCanonical(&buf);
    try testing.expectEqual(@as(usize, 8), n);
    try testing.expectEqualStrings("12:34:56", buf[0..n]);
}

test "formatCanonical: 12-char form when ms is non-zero" {
    const t = try init(12, 34, 56, 789);
    var buf: [12]u8 = undefined;
    const n = t.formatCanonical(&buf);
    try testing.expectEqual(@as(usize, 12), n);
    try testing.expectEqualStrings("12:34:56.789", buf[0..n]);
}

test "formatCanonical: boundaries" {
    var buf: [12]u8 = undefined;
    var n = (try init(0, 0, 0, 0)).formatCanonical(&buf);
    try testing.expectEqualStrings("00:00:00", buf[0..n]);
    n = (try init(23, 59, 59, 999)).formatCanonical(&buf);
    try testing.expectEqualStrings("23:59:59.999", buf[0..n]);
    n = (try init(0, 0, 0, 1)).formatCanonical(&buf);
    try testing.expectEqualStrings("00:00:00.001", buf[0..n]);
}

test "pack / unpack: round trip" {
    const cases = [_]Time{
        try init(0, 0, 0, 0),
        try init(12, 34, 56, 0),
        try init(12, 34, 56, 789),
        try init(23, 59, 59, 999),
        try init(0, 0, 0, 1),
        try init(1, 2, 3, 4),
    };
    for (cases) |t| {
        const bits = t.pack();
        const back = unpack(bits);
        try testing.expect(t.eql(back));
    }
}

test "pack: layout — components live in expected bits" {
    const t = try init(0x12, 0x1A, 0x2B, 0x123);
    const bits = t.pack();
    try testing.expectEqual(@as(u64, 0x12), bits & 0xFF);
    try testing.expectEqual(@as(u64, 0x1A), (bits >> 8) & 0xFF);
    try testing.expectEqual(@as(u64, 0x2B), (bits >> 16) & 0xFF);
    try testing.expectEqual(@as(u64, 0x123), (bits >> 24) & 0xFFFF);
    try testing.expectEqual(@as(u64, 0), bits >> 40);
}
