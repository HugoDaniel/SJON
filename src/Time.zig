const std = @import("std");

const Time = @This();

hour: u8,
minute: u8,
second: u8,
millisecond: u16,

comptime {
    std.debug.assert(@sizeOf(Time) == 6);
}

pub const Error = error{
    InvalidHour,
    InvalidMinute,
    InvalidSecond,
    InvalidMillisecond,
    InvalidFormat,
};

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

pub fn canonicalLen(self: Time) usize {
    return if (self.millisecond == 0) 8 else 12;
}

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

pub fn pack(self: Time) u64 {
    return @as(u64, self.hour) |
        (@as(u64, self.minute) << 8) |
        (@as(u64, self.second) << 16) |
        (@as(u64, self.millisecond) << 24);
}

pub fn unpack(bits: u64) Time {
    return .{
        .hour = @truncate(bits),
        .minute = @truncate(bits >> 8),
        .second = @truncate(bits >> 16),
        .millisecond = @truncate(bits >> 24),
    };
}

const testing = std.testing;
