const std = @import("std");

const Date = @This();

pub const min_year: i16 = 1;

pub const max_year: i16 = 9999;

year: i16,
month: u8,
day: u8,

comptime {
    std.debug.assert(@sizeOf(Date) == 4);
}

pub const Error = error{
    InvalidYear,
    InvalidMonth,
    InvalidDay,
    InvalidFormat,
};

pub fn init(year: i16, month: u8, day: u8) Error!Date {
    if (year < min_year or year > max_year) return error.InvalidYear;
    if (month < 1 or month > 12) return error.InvalidMonth;
    if (day < 1 or day > daysInMonth(year, month)) return error.InvalidDay;
    return .{ .year = year, .month = month, .day = day };
}

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

pub fn isLeapYear(year: i16) bool {
    const m4 = @mod(year, 4) == 0;
    const m100 = @mod(year, 100) == 0;
    const m400 = @mod(year, 400) == 0;
    return m4 and (!m100 or m400);
}

pub fn daysInMonth(year: i16, month: u8) u8 {
    std.debug.assert(month >= 1 and month <= 12);
    const table = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2 and isLeapYear(year)) return 29;
    return table[month - 1];
}

pub fn dayOfYear(self: Date) u16 {
    var total: u16 = 0;
    var m: u8 = 1;
    while (m < self.month) : (m += 1) {
        total += daysInMonth(self.year, m);
    }
    return total + self.day;
}

pub fn epochDay(self: Date) i32 {
    const y_full: i32 = @as(i32, self.year) - @as(i32, @intFromBool(self.month <= 2));
    const era: i32 = @divFloor(y_full, 400);
    const yoe: u32 = @intCast(y_full - era * 400);
    const m_adj: u32 = if (self.month > 2) @as(u32, self.month) - 3 else @as(u32, self.month) + 9;
    const doy: u32 = (153 * m_adj + 2) / 5 + @as(u32, self.day) - 1;
    const doe: u32 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + @as(i32, @intCast(doe)) - 719468;
}

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

pub fn formatCanonical(self: Date, buf: *[10]u8) void {
    std.debug.assert(self.year >= min_year and self.year <= max_year);
    std.debug.assert(self.month >= 1 and self.month <= 12);
    std.debug.assert(self.day >= 1 and self.day <= 31);
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

pub fn pack(self: Date) u64 {
    const y_bits: u16 = @bitCast(self.year);
    return @as(u64, y_bits) |
        (@as(u64, self.month) << 16) |
        (@as(u64, self.day) << 24);
}

pub fn unpack(bits: u64) Date {
    return .{
        .year = @bitCast(@as(u16, @truncate(bits))),
        .month = @truncate(bits >> 16),
        .day = @truncate(bits >> 24),
    };
}

const testing = std.testing;
