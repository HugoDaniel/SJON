//! SJON `Date` — the calendar-date primitive.
//!
//! Date-only, no time of day, no time zone. Stored as a packed
//! `(year:i16, month:u8, day:u8)` triple — fits in 4 bytes and slots
//! cleanly into `Ast.Data.immediate`. Proleptic Gregorian calendar,
//! ISO 8601 leap-year rule. Range `0001-01-01 .. 9999-12-31`.
//!
//! Invariants — every constructed `Date` satisfies:
//!   * `min_year <= year <= max_year` (i.e. `1..9999`)
//!   * `1 <= month <= 12`
//!   * `1 <= day <= daysInMonth(year, month)`
//!
//! Constructors (`init`, `parse`, `fromEpochDay`) are the only ways to
//! produce a `Date`. Internal code must not bypass them — raw struct-
//! literal construction of an unvalidated `Date` is a bug.
//!
//! Lexical form: exactly `YYYY-MM-DD` (10 ASCII chars, leading zeros
//! required). Anything else fails `parse` with `InvalidFormat`. The
//! lexer recognises this shape and emits `Token.Tag.date`; the parser
//! then re-uses `parse` to materialize the value.
//!
//! Epoch-day conversion uses Howard Hinnant's `civil_from_days` /
//! `days_from_civil` algorithm — see
//! https://howardhinnant.github.io/date_algorithms.html. The shifted-
//! era trick keeps both directions branchless and works for the full
//! supported range without overflow.

const std = @import("std");

const Date = @This();

/// Lower bound on `year`. ISO 8601 explicitly excludes year 0; the
/// lexer / parser raise `date_invalid_year` for `0000`.
pub const min_year: i16 = 1;

/// Upper bound on `year`. Matches ISO 8601 basic-profile clamp;
/// extended years (5+ digits, leading sign) are deliberately not
/// supported in v1.
pub const max_year: i16 = 9999;

year: i16,
month: u8,
day: u8,

comptime {
    // The Date value rides in `Ast.Data.immediate` (an 8-byte slot)
    // and in a `[i16][u8][u8]` 4-byte payload on the wire. Pin the
    // packed size so a stdlib alignment change can't silently grow
    // the AST node or the wire payload.
    std.debug.assert(@sizeOf(Date) == 4);
}

/// Constructor / parse failures. `OutOfMemory` is not on this set —
/// `Date` is a value type and never allocates.
pub const Error = error{
    InvalidYear,
    InvalidMonth,
    InvalidDay,
    /// String didn't match the strict `YYYY-MM-DD` shape (length,
    /// separator positions, ASCII-digit composition).
    InvalidFormat,
};

/// Construct a validated `Date`. Single source of truth for the
/// `(year, month, day)` invariant — `parse`, `fromEpochDay`, and
/// host bridges all funnel through here.
pub fn init(year: i16, month: u8, day: u8) Error!Date {
    if (year < min_year or year > max_year) return error.InvalidYear;
    if (month < 1 or month > 12) return error.InvalidMonth;
    if (day < 1 or day > daysInMonth(year, month)) return error.InvalidDay;
    return .{ .year = year, .month = month, .day = day };
}

/// Parse strict ISO 8601 calendar form `YYYY-MM-DD`. No whitespace,
/// no leading sign, no time component, no fractional seconds — the
/// substrate is intentionally narrow. Leading zeros are required
/// (so `2026-5-19` fails; `2026-05-19` succeeds).
pub fn parse(s: []const u8) Error!Date {
    if (s.len != 10) return error.InvalidFormat;
    if (s[4] != '-' or s[7] != '-') return error.InvalidFormat;
    inline for (.{ 0, 1, 2, 3, 5, 6, 8, 9 }) |i| {
        if (s[i] < '0' or s[i] > '9') return error.InvalidFormat;
    }
    const y: i16 =
        @as(i16, s[0] - '0') * 1000 +
        @as(i16, s[1] - '0') * 100 +
        @as(i16, s[2] - '0') * 10 +
        @as(i16, s[3] - '0');
    const m: u8 = (s[5] - '0') * 10 + (s[6] - '0');
    const d: u8 = (s[8] - '0') * 10 + (s[9] - '0');
    return init(y, m, d);
}

/// True iff `year` is a leap year under the proleptic Gregorian rule
/// (divisible by 4, except centuries not divisible by 400). Pure
/// function — defined for the full `i16` range, even years outside
/// the SJON-supported `[1, 9999]` window, so callers using it
/// internally during overflow-safe arithmetic don't need a separate
/// branch.
pub fn isLeapYear(year: i16) bool {
    const m4 = @mod(year, 4) == 0;
    const m100 = @mod(year, 100) == 0;
    const m400 = @mod(year, 400) == 0;
    return m4 and (!m100 or m400);
}

/// Days in `month` of `year` (1-based month). For February the count
/// depends on `isLeapYear(year)`.
pub fn daysInMonth(year: i16, month: u8) u8 {
    std.debug.assert(month >= 1);
    std.debug.assert(month <= 12);
    const table = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2 and isLeapYear(year)) return 29;
    return table[month - 1];
}

/// Day-of-year, 1..365 (or 1..366 in leap years).
pub fn dayOfYear(self: Date) u16 {
    var total: u16 = 0;
    var m: u8 = 1;
    while (m < self.month) : (m += 1) {
        total += daysInMonth(self.year, m);
    }
    return total + self.day;
}

/// Days since the proleptic Gregorian epoch `1970-01-01` (which
/// returns 0). Howard Hinnant's `days_from_civil`: shifts the year
/// origin to March (so leap-day lands at end-of-year), then folds
/// the result via the 400-year cycle of 146097 days.
pub fn epochDay(self: Date) i32 {
    const y_full: i32 = @as(i32, self.year) - @as(i32, @intFromBool(self.month <= 2));
    const era: i32 = @divFloor(y_full, 400);
    const yoe: u32 = @intCast(y_full - era * 400);
    const m_adj: u32 = if (self.month > 2) @as(u32, self.month) - 3 else @as(u32, self.month) + 9;
    const doy: u32 = (153 * m_adj + 2) / 5 + @as(u32, self.day) - 1;
    const doe: u32 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + @as(i32, @intCast(doe)) - 719468;
}

/// Inverse of `epochDay`. Validates the resulting date lies inside
/// `[min_year, max_year]` so callers can chain
/// `fromEpochDay(d.epochDay()) == d` round-trip safely.
pub fn fromEpochDay(d: i32) Error!Date {
    const z: i64 = @as(i64, d) + 719468;
    const era: i64 = @divFloor(z, 146097);
    const doe: u32 = @intCast(z - era * 146097);
    const yoe: u32 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y_full: i64 = @as(i64, yoe) + era * 400;
    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u32 = (5 * doy + 2) / 153;
    const day: u32 = doy - (153 * mp + 2) / 5 + 1;
    const month: u32 = if (mp < 10) mp + 3 else mp - 9;
    const year: i64 = y_full + @as(i64, @intFromBool(month <= 2));
    if (year < min_year or year > max_year) return error.InvalidYear;
    return init(@intCast(year), @intCast(month), @intCast(day));
}

/// ISO 8601 day of week: 1 = Monday, …, 7 = Sunday. Computed from
/// `epochDay` (`1970-01-01` was a Thursday, i.e. weekday 4).
pub fn dayOfWeek(self: Date) u8 {
    const w: i32 = @mod(self.epochDay() + 3, 7);
    return @intCast(@as(i32, w) + 1);
}

pub fn eql(a: Date, b: Date) bool {
    return a.year == b.year and a.month == b.month and a.day == b.day;
}

pub fn order(a: Date, b: Date) std.math.Order {
    if (a.year != b.year) return std.math.order(a.year, b.year);
    if (a.month != b.month) return std.math.order(a.month, b.month);
    return std.math.order(a.day, b.day);
}

/// Length of `formatCanonical` output: always 10 (`YYYY-MM-DD`), fixed
/// width across the whole valid range. Mirrors `Time.canonicalLen` so the
/// `Printer` length pre-pass derives date and time widths through the same
/// interface instead of hard-coding `10` for one and calling the other.
pub fn canonicalLen(self: Date) usize {
    _ = self;
    return 10;
}

/// Writes exactly 10 ASCII bytes: `YYYY-MM-DD`. Buffer-typed so the
/// caller can stack-allocate without ceremony.
pub fn formatCanonical(self: Date, buf: *[10]u8) void {
    std.debug.assert(self.year >= min_year);
    std.debug.assert(self.year <= max_year);
    std.debug.assert(self.month >= 1);
    std.debug.assert(self.month <= 12);
    std.debug.assert(self.day >= 1);
    std.debug.assert(self.day <= 31);
    const y: u16 = @intCast(self.year);
    buf[0] = '0' + @as(u8, @intCast(y / 1000));
    buf[1] = '0' + @as(u8, @intCast((y / 100) % 10));
    buf[2] = '0' + @as(u8, @intCast((y / 10) % 10));
    buf[3] = '0' + @as(u8, @intCast(y % 10));
    buf[4] = '-';
    buf[5] = '0' + @as(u8, @intCast(self.month / 10));
    buf[6] = '0' + @as(u8, @intCast(self.month % 10));
    buf[7] = '-';
    buf[8] = '0' + @as(u8, @intCast(self.day / 10));
    buf[9] = '0' + @as(u8, @intCast(self.day % 10));
}

/// Pack the date into a 32-bit immediate suitable for `Ast.Data.immediate`.
/// Inverse of `unpack`. Layout: `year:i16 LE` in low 16 bits,
/// `month:u8` in next 8 bits, `day:u8` in high 8 bits. The remaining
/// 32 bits of `Data.immediate` are zero.
pub fn pack(self: Date) u64 {
    const y_bits: u16 = @bitCast(self.year);
    return @as(u64, y_bits) |
        (@as(u64, self.month) << 16) |
        (@as(u64, self.day) << 24);
}

/// Inverse of `pack`. Truncates the input; high bits are ignored. The
/// returned `Date` is **not** re-validated — `pack` is only called on
/// constructed (i.e. validated) `Date` values, so the round-trip is
/// already inside the invariant. Calling `unpack` on an arbitrary
/// `u64` is a programmer error.
pub fn unpack(bits: u64) Date {
    return .{
        .year = @bitCast(@as(u16, @truncate(bits))),
        .month = @truncate(bits >> 16),
        .day = @truncate(bits >> 24),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "init: valid dates round trip" {
    const d = try init(2026, 5, 19);
    try testing.expectEqual(@as(i16, 2026), d.year);
    try testing.expectEqual(@as(u8, 5), d.month);
    try testing.expectEqual(@as(u8, 19), d.day);
}

test "init: rejects year 0" {
    try testing.expectError(error.InvalidYear, init(0, 1, 1));
}

test "init: rejects year > max" {
    try testing.expectError(error.InvalidYear, init(10000, 1, 1));
}

test "init: rejects month 0 and 13" {
    try testing.expectError(error.InvalidMonth, init(2026, 0, 1));
    try testing.expectError(error.InvalidMonth, init(2026, 13, 1));
}

test "init: rejects day 0 and 32" {
    try testing.expectError(error.InvalidDay, init(2026, 1, 0));
    try testing.expectError(error.InvalidDay, init(2026, 1, 32));
}

test "init: feb 29 in leap years" {
    _ = try init(2024, 2, 29);
    _ = try init(2000, 2, 29);
}

test "init: feb 29 in non-leap years" {
    try testing.expectError(error.InvalidDay, init(2025, 2, 29));
    try testing.expectError(error.InvalidDay, init(1900, 2, 29));
}

test "init: april 31 rejected" {
    try testing.expectError(error.InvalidDay, init(2026, 4, 31));
}

test "init: feb 30 rejected" {
    try testing.expectError(error.InvalidDay, init(2024, 2, 30));
}

test "parse: canonical form" {
    const d = try parse("2026-05-19");
    try testing.expectEqual(@as(i16, 2026), d.year);
    try testing.expectEqual(@as(u8, 5), d.month);
    try testing.expectEqual(@as(u8, 19), d.day);
}

test "parse: boundaries" {
    _ = try parse("0001-01-01");
    _ = try parse("9999-12-31");
}

test "parse: rejects missing leading zero" {
    try testing.expectError(error.InvalidFormat, parse("2026-5-19"));
    try testing.expectError(error.InvalidFormat, parse("2026-05-9"));
}

test "parse: rejects wrong separator" {
    try testing.expectError(error.InvalidFormat, parse("2026/05/19"));
    try testing.expectError(error.InvalidFormat, parse("2026.05.19"));
}

test "parse: rejects wrong length" {
    try testing.expectError(error.InvalidFormat, parse(""));
    try testing.expectError(error.InvalidFormat, parse("2026-05"));
    try testing.expectError(error.InvalidFormat, parse("2026-05-19T"));
    try testing.expectError(error.InvalidFormat, parse("2026-05-19T00:00"));
}

test "parse: rejects non-ascii digits" {
    try testing.expectError(error.InvalidFormat, parse("20a6-05-19"));
}

test "parse: rejects year 0 and invalid components" {
    try testing.expectError(error.InvalidYear, parse("0000-01-01"));
    try testing.expectError(error.InvalidMonth, parse("2026-13-01"));
    try testing.expectError(error.InvalidDay, parse("2026-02-30"));
    try testing.expectError(error.InvalidDay, parse("2025-02-29"));
}

test "isLeapYear: well-known cases" {
    try testing.expect(isLeapYear(2000));
    try testing.expect(isLeapYear(2024));
    try testing.expect(!isLeapYear(1900));
    try testing.expect(!isLeapYear(2025));
    try testing.expect(!isLeapYear(2100));
    try testing.expect(isLeapYear(2400));
}

test "daysInMonth: every month" {
    try testing.expectEqual(@as(u8, 31), daysInMonth(2026, 1));
    try testing.expectEqual(@as(u8, 28), daysInMonth(2025, 2));
    try testing.expectEqual(@as(u8, 29), daysInMonth(2024, 2));
    try testing.expectEqual(@as(u8, 31), daysInMonth(2026, 3));
    try testing.expectEqual(@as(u8, 30), daysInMonth(2026, 4));
    try testing.expectEqual(@as(u8, 31), daysInMonth(2026, 5));
    try testing.expectEqual(@as(u8, 30), daysInMonth(2026, 6));
    try testing.expectEqual(@as(u8, 31), daysInMonth(2026, 7));
    try testing.expectEqual(@as(u8, 31), daysInMonth(2026, 8));
    try testing.expectEqual(@as(u8, 30), daysInMonth(2026, 9));
    try testing.expectEqual(@as(u8, 31), daysInMonth(2026, 10));
    try testing.expectEqual(@as(u8, 30), daysInMonth(2026, 11));
    try testing.expectEqual(@as(u8, 31), daysInMonth(2026, 12));
}

test "epochDay: 1970-01-01 is zero" {
    const d = try init(1970, 1, 1);
    try testing.expectEqual(@as(i32, 0), d.epochDay());
}

test "epochDay: 1969-12-31 is -1" {
    const d = try init(1969, 12, 31);
    try testing.expectEqual(@as(i32, -1), d.epochDay());
}

test "epochDay: round-trip on known dates" {
    const cases = [_]Date{
        try init(1970, 1, 1),
        try init(1969, 12, 31),
        try init(2000, 1, 1),
        try init(2024, 2, 29),
        try init(2026, 5, 19),
        try init(1, 1, 1),
        try init(9999, 12, 31),
    };
    for (cases) |d| {
        const ed = d.epochDay();
        const back = try fromEpochDay(ed);
        try testing.expect(d.eql(back));
    }
}

test "dayOfWeek: 2026-05-19 is Tuesday" {
    const d = try init(2026, 5, 19);
    try testing.expectEqual(@as(u8, 2), d.dayOfWeek());
}

test "dayOfWeek: 1970-01-01 is Thursday" {
    const d = try init(1970, 1, 1);
    try testing.expectEqual(@as(u8, 4), d.dayOfWeek());
}

test "dayOfYear: jan 1 is 1, dec 31 is 365/366" {
    try testing.expectEqual(@as(u16, 1), (try init(2026, 1, 1)).dayOfYear());
    try testing.expectEqual(@as(u16, 365), (try init(2025, 12, 31)).dayOfYear());
    try testing.expectEqual(@as(u16, 366), (try init(2024, 12, 31)).dayOfYear());
}

test "eql and order" {
    const a = try init(2026, 5, 19);
    const b = try init(2026, 5, 19);
    const c = try init(2026, 5, 20);
    const d = try init(2027, 1, 1);
    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
    try testing.expectEqual(std.math.Order.eq, a.order(b));
    try testing.expectEqual(std.math.Order.lt, a.order(c));
    try testing.expectEqual(std.math.Order.gt, d.order(a));
}

test "formatCanonical: round trip" {
    const d = try init(2026, 5, 19);
    var buf: [10]u8 = undefined;
    d.formatCanonical(&buf);
    try testing.expectEqualStrings("2026-05-19", &buf);
}

test "formatCanonical: boundaries" {
    var buf: [10]u8 = undefined;
    (try init(1, 1, 1)).formatCanonical(&buf);
    try testing.expectEqualStrings("0001-01-01", &buf);
    (try init(9999, 12, 31)).formatCanonical(&buf);
    try testing.expectEqualStrings("9999-12-31", &buf);
}

test "canonicalLen: always 10, equal to formatCanonical width" {
    var buf: [10]u8 = undefined;
    const d = try init(2026, 5, 19);
    d.formatCanonical(&buf);
    // Mirrors Time.canonicalLen so the Printer length pre-pass derives the
    // date width through one interface instead of hard-coding 10.
    try testing.expectEqual(@as(usize, 10), d.canonicalLen());
    try testing.expectEqual(buf.len, d.canonicalLen());
    // Constant across the full valid range (unlike Time's 8-vs-12 split).
    try testing.expectEqual(@as(usize, 10), (try init(1, 1, 1)).canonicalLen());
    try testing.expectEqual(@as(usize, 10), (try init(9999, 12, 31)).canonicalLen());
}

test "pack / unpack: round trip" {
    const d = try init(2026, 5, 19);
    const bits = d.pack();
    const back = unpack(bits);
    try testing.expect(d.eql(back));
}
