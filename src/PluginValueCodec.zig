const std = @import("std");
const Expr = @import("Expr.zig");
const Date = @import("Date.zig");
const Time = @import("Time.zig");

const Allocator = std.mem.Allocator;

pub const Tag = enum(u8) {
    number = 0x01,
    boolean = 0x02,
    nil = 0x03,
    string = 0x04,
    keyword = 0x05,
    vector = 0x06,
    form = 0x07,
    date = 0x08,
    time = 0x09,
};

pub const MAX_VALUE_DEPTH: u8 = 32;

pub const HEADER_SIZE: u32 = 8;

pub const Error = error{
    OutOfMemory,
    InvalidTag,
    InvalidBoolean,
    UnexpectedEof,
    DepthExceeded,
};

pub fn encodeValue(
    a: Allocator,
    buf: *std.ArrayList(u8),
    value: Expr.Value,
) Allocator.Error!void {
    switch (value) {
        .number => |n| {
            try buf.append(a, @intFromEnum(Tag.number));
            const bits: u64 = @bitCast(n);
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, bits, .little);
            try buf.appendSlice(a, &b);
        },
        .integer_i64 => |n| {
            try buf.append(a, @intFromEnum(Tag.number));
            const bits: u64 = @bitCast(@as(f64, @floatFromInt(n)));
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, bits, .little);
            try buf.appendSlice(a, &b);
        },
        .integer_u64 => |n| {
            try buf.append(a, @intFromEnum(Tag.number));
            const bits: u64 = @bitCast(@as(f64, @floatFromInt(n)));
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, bits, .little);
            try buf.appendSlice(a, &b);
        },
        .boolean => |x| {
            try buf.append(a, @intFromEnum(Tag.boolean));
            try buf.append(a, if (x) 1 else 0);
        },
        .nil => {
            try buf.append(a, @intFromEnum(Tag.nil));
        },
        .date => |d| {
            try buf.append(a, @intFromEnum(Tag.date));
            const y_bits: u16 = @bitCast(d.year);
            try buf.append(a, @truncate(y_bits));
            try buf.append(a, @truncate(y_bits >> 8));
            try buf.append(a, d.month);
            try buf.append(a, d.day);
        },
        .time => |t| {
            try buf.append(a, @intFromEnum(Tag.time));
            try buf.append(a, t.hour);
            try buf.append(a, t.minute);
            try buf.append(a, t.second);
            try buf.append(a, @truncate(t.millisecond));
            try buf.append(a, @truncate(t.millisecond >> 8));
        },
        .string => |s| try writeLenPrefixed(a, buf, .string, s),
        .keyword => |k| try writeLenPrefixed(a, buf, .keyword, k),
        .vector => |xs| {
            try buf.append(a, @intFromEnum(Tag.vector));
            try writeU32(a, buf, @intCast(xs.len));
            for (xs) |xv| try encodeValue(a, buf, xv);
        },
        .form => |f| {
            try buf.append(a, @intFromEnum(Tag.form));
            try writeU32(a, buf, @intCast(f.head.len));
            try buf.appendSlice(a, f.head);
            try writeU32(a, buf, @intCast(f.namespace.len));
            try buf.appendSlice(a, f.namespace);
            try writeU32(a, buf, @intCast(f.children.len));
            for (f.children) |child| try encodeValue(a, buf, child);
            try writeU32(a, buf, @intCast(f.kvpairs.len));
            for (f.kvpairs) |pair| {
                try writeU32(a, buf, @intCast(pair.key.len));
                try buf.appendSlice(a, pair.key);
                try encodeValue(a, buf, pair.value);
            }
        },
    }
}

pub fn encodeArgs(
    a: Allocator,
    buf: *std.ArrayList(u8),
    args: []const Expr.Value,
) Allocator.Error!void {
    try writeU32(a, buf, @intCast(args.len));
    for (args) |v| try encodeValue(a, buf, v);
}

pub fn encodeOkFrame(
    a: Allocator,
    value: Expr.Value,
) Allocator.Error![]u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(a);
    try encodeValue(a, &payload, value);
    return try assembleFrame(a, true, payload.items);
}

pub fn encodeErrFrame(
    a: Allocator,
    code: []const u8,
    detail: []const u8,
) Allocator.Error![]u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(a);
    try writeU32(a, &payload, @intCast(code.len));
    try payload.appendSlice(a, code);
    try writeU32(a, &payload, @intCast(detail.len));
    try payload.appendSlice(a, detail);
    return try assembleFrame(a, false, payload.items);
}

fn assembleFrame(a: Allocator, ok: bool, payload: []const u8) Allocator.Error![]u8 {
    const total = HEADER_SIZE + payload.len;
    const out = try a.alloc(u8, total);
    std.mem.writeInt(u32, out[0..4], if (ok) 1 else 0, .little);
    std.mem.writeInt(u32, out[4..8], @intCast(payload.len), .little);
    @memcpy(out[HEADER_SIZE..], payload);
    return out;
}

fn writeLenPrefixed(
    a: Allocator,
    buf: *std.ArrayList(u8),
    tag: Tag,
    s: []const u8,
) Allocator.Error!void {
    try buf.append(a, @intFromEnum(tag));
    try writeU32(a, buf, @intCast(s.len));
    try buf.appendSlice(a, s);
}

fn writeU32(
    a: Allocator,
    buf: *std.ArrayList(u8),
    n: u32,
) Allocator.Error!void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, n, .little);
    try buf.appendSlice(a, &b);
}

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn need(self: *Cursor, n: usize) Error!void {
        if (self.pos + n > self.bytes.len) return error.UnexpectedEof;
    }

    fn readByte(self: *Cursor) Error!u8 {
        try self.need(1);
        const b = self.bytes[self.pos];
        self.pos += 1;
        return b;
    }

    fn readU32(self: *Cursor) Error!u32 {
        try self.need(4);
        const v = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    fn readF64(self: *Cursor) Error!f64 {
        try self.need(8);
        const bits = std.mem.readInt(u64, self.bytes[self.pos..][0..8], .little);
        self.pos += 8;
        return @bitCast(bits);
    }

    fn readBytes(self: *Cursor, n: u32) Error![]const u8 {
        try self.need(n);
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
};

pub const DecodedValue = struct {
    value: Expr.Value,
    consumed: usize,
};

pub fn decodeValue(a: Allocator, bytes: []const u8) Error!DecodedValue {
    var cur = Cursor{ .bytes = bytes };
    const v = try decodeValueDepth(a, &cur, 0);
    return .{ .value = v, .consumed = cur.pos };
}

fn decodeValueDepth(a: Allocator, cur: *Cursor, depth: u8) Error!Expr.Value {
    if (depth >= MAX_VALUE_DEPTH) return error.DepthExceeded;
    const t = try cur.readByte();
    return switch (t) {
        @intFromEnum(Tag.number) => .{ .number = try cur.readF64() },
        @intFromEnum(Tag.boolean) => blk: {
            const b = try cur.readByte();
            if (b > 1) return error.InvalidBoolean;
            break :blk .{ .boolean = b == 1 };
        },
        @intFromEnum(Tag.nil) => .nil,
        @intFromEnum(Tag.date) => blk: {
            const y_lo = try cur.readByte();
            const y_hi = try cur.readByte();
            const month = try cur.readByte();
            const day = try cur.readByte();
            const y_bits: u16 = @as(u16, y_lo) | (@as(u16, y_hi) << 8);
            const year: i16 = @bitCast(y_bits);
            const d = Date.init(year, month, day) catch return error.InvalidTag;
            break :blk .{ .date = d };
        },
        @intFromEnum(Tag.time) => blk: {
            const hour = try cur.readByte();
            const minute = try cur.readByte();
            const second = try cur.readByte();
            const ms_lo = try cur.readByte();
            const ms_hi = try cur.readByte();
            const ms: u16 = @as(u16, ms_lo) | (@as(u16, ms_hi) << 8);
            const time_val = Time.init(hour, minute, second, ms) catch return error.InvalidTag;
            break :blk .{ .time = time_val };
        },
        @intFromEnum(Tag.string) => blk: {
            const n = try cur.readU32();
            const s = try cur.readBytes(n);
            break :blk .{ .string = try a.dupe(u8, s) };
        },
        @intFromEnum(Tag.keyword) => blk: {
            const n = try cur.readU32();
            const s = try cur.readBytes(n);
            break :blk .{ .keyword = try a.dupe(u8, s) };
        },
        @intFromEnum(Tag.vector) => blk: {
            const n = try cur.readU32();
            const xs = try a.alloc(Expr.Value, n);
            for (0..n) |i| xs[i] = try decodeValueDepth(a, cur, depth + 1);
            break :blk .{ .vector = xs };
        },
        @intFromEnum(Tag.form) => blk: {
            const head_len = try cur.readU32();
            const head = try cur.readBytes(head_len);
            const head_owned = try a.dupe(u8, head);
            const ns_len = try cur.readU32();
            const ns = try cur.readBytes(ns_len);
            const ns_owned = try a.dupe(u8, ns);
            const child_count = try cur.readU32();
            const children = try a.alloc(Expr.Value, child_count);
            for (0..child_count) |i| children[i] = try decodeValueDepth(a, cur, depth + 1);
            const kv_count = try cur.readU32();
            const kvs = try a.alloc(Expr.KvPair, kv_count);
            for (0..kv_count) |i| {
                const key_len = try cur.readU32();
                const key = try cur.readBytes(key_len);
                const key_owned = try a.dupe(u8, key);
                const v = try decodeValueDepth(a, cur, depth + 1);
                kvs[i] = .{ .key = key_owned, .value = v };
            }
            break :blk .{ .form = .{
                .head = head_owned,
                .namespace = ns_owned,
                .children = children,
                .kvpairs = kvs,
            } };
        },
        else => error.InvalidTag,
    };
}

pub fn decodeArgs(a: Allocator, bytes: []const u8) Error![]Expr.Value {
    var cur = Cursor{ .bytes = bytes };
    const n = try cur.readU32();
    const xs = try a.alloc(Expr.Value, n);
    for (0..n) |i| xs[i] = try decodeValueDepth(a, &cur, 0);
    return xs;
}

pub const Frame = struct {
    ok: bool,
    payload: []const u8,
};

pub fn decodeFrame(bytes: []const u8) Error!Frame {
    if (bytes.len < HEADER_SIZE) return error.UnexpectedEof;
    const ok = std.mem.readInt(u32, bytes[0..4], .little);
    const len = std.mem.readInt(u32, bytes[4..8], .little);
    if (bytes.len < HEADER_SIZE + len) return error.UnexpectedEof;
    return .{ .ok = ok == 1, .payload = bytes[HEADER_SIZE .. HEADER_SIZE + len] };
}

pub const StructuredError = struct {
    code: []const u8,
    detail: []const u8,
};

pub fn decodeStructuredError(
    a: Allocator,
    payload: []const u8,
) Error!StructuredError {
    var cur = Cursor{ .bytes = payload };
    const code_len = try cur.readU32();
    const code = try cur.readBytes(code_len);
    const detail_len = try cur.readU32();
    const detail = try cur.readBytes(detail_len);
    return .{
        .code = try a.dupe(u8, code),
        .detail = try a.dupe(u8, detail),
    };
}

const testing = std.testing;

fn roundTrip(value: Expr.Value) !Expr.Value {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try encodeValue(testing.allocator, &buf, value);
    const out = try decodeValue(testing.allocator, buf.items);
    try testing.expectEqual(buf.items.len, out.consumed);
    return out.value;
}

fn freeValue(a: Allocator, v: Expr.Value) void {
    switch (v) {
        .string => |s| a.free(s),
        .keyword => |k| a.free(k),
        .vector => |xs| {
            for (xs) |xv| freeValue(a, xv);
            a.free(xs);
        },
        .form => |f| {
            a.free(f.head);
            a.free(f.namespace);
            for (f.children) |child| freeValue(a, child);
            a.free(f.children);
            for (f.kvpairs) |pair| {
                a.free(pair.key);
                freeValue(a, pair.value);
            }
            a.free(f.kvpairs);
        },
        else => {},
    }
}
