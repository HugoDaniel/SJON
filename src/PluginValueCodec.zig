//! Binary `Expr.Value` codec for the executable plugin ABI.
//!
//! Wire format per `docs/executable-plugin-abi.md` §9 — seven
//! tagged variants, all integers little-endian. Distinct tags for
//! string vs keyword (no JSON-style `$kw` discriminator). Vectors
//! carry a u32 count plus that many nested encoded values. Forms
//! carry head + namespace + child list + kvpair list. Numbers cross
//! verbatim as raw IEEE-754 `f64` bits, including NaN / ±inf.
//!
//! The codec is pure Zig and has no engine dependency. Every host
//! (Zig native, Web/TS, Rust) speaks the same byte sequence; this file
//! is the Zig-side reference implementation. Hostile encoder and decoder
//! inputs are both bounded by `MAX_VALUE_DEPTH`.
//!
//! Memory model: callers should pass an arena for the decode allocator.
//! On a partial-decode error (truncated bytes, depth exceeded, invalid
//! tag) any slices already allocated for the in-progress value are
//! stranded — the per-call arena pattern in `PluginRuntime` adapters
//! drops them when the call ends.

const std = @import("std");
const Expr = @import("Expr.zig");
const Date = @import("Date.zig");
const Time = @import("Time.zig");

const Allocator = std.mem.Allocator;

/// Wire tag for each `Expr.Value` variant. The numeric values are part
/// of the v2 ABI — changing one bumps the ABI version.
pub const Tag = enum(u8) {
    number = 0x01,
    boolean = 0x02,
    nil = 0x03,
    string = 0x04,
    keyword = 0x05,
    vector = 0x06,
    /// Added in v2. Carries `[u32 head_len][head][u32 ns_len][ns][u32
    /// child_count][value]*[u32 kv_count][[u32 key_len][key][value]]*`.
    form = 0x07,
    /// Calendar date `(year:i16, month:u8, day:u8)`. Payload is 4 bytes:
    /// `[i16 LE year][u8 month][u8 day]`. Mirrors `Binary.Tag.date`
    /// shape on the substrate wire.
    date = 0x08,
    /// Clock time `(hour:u8, minute:u8, second:u8, millisecond:u16)`.
    /// Payload is 5 bytes: `[u8 hour][u8 minute][u8 second][u16 LE ms]`.
    /// Mirrors `Binary.Tag.time` shape on the substrate wire.
    time = 0x09,
};

/// Defensive cap on nested-vector decoder recursion. Plugins can be
/// hostile or buggy; refusing pathological depth keeps the host stack
/// bounded.
pub const MAX_VALUE_DEPTH: u8 = 32;

/// Header size of a result frame (4 bytes ok + 4 bytes len). Spelled
/// `HEADER_SIZE` to match `wasm_common.HEADER_SIZE` and
/// `Binary.HEADER_SIZE` — every "fixed-size prefix in bytes" constant
/// in the project shares this name and `u32` type.
pub const HEADER_SIZE: u32 = 8;

pub const Error = error{
    OutOfMemory,
    InvalidTag,
    InvalidBoolean,
    UnexpectedEof,
    DepthExceeded,
};

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

/// Append the binary encoding of `value` to `buf`. Fails on allocation or
/// on `error.DepthExceeded` when `value` nests past `MAX_VALUE_DEPTH`:
/// plugin args reach here mid-eval, before the evaluator's final
/// deepCopyValue caps depth, so the encoder enforces the same bound the
/// decoder does rather than trusting arg shape.
pub fn encodeValue(
    a: Allocator,
    buf: *std.ArrayList(u8),
    value: Expr.Value,
) error{ OutOfMemory, DepthExceeded }!void {
    return encodeValueDepth(a, buf, value, 0);
}

/// Depth-guarded encoder body, symmetric with `decodeValueDepth`. Refuses a
/// value nested past `MAX_VALUE_DEPTH` so a mid-eval plugin argument (not
/// yet capped by the evaluator's final deepCopyValue) cannot drive
/// unbounded host-stack recursion here.
fn encodeValueDepth(
    a: Allocator,
    buf: *std.ArrayList(u8),
    value: Expr.Value,
    depth: u8,
) error{ OutOfMemory, DepthExceeded }!void {
    if (depth >= MAX_VALUE_DEPTH) return error.DepthExceeded;
    switch (value) {
        .number => |n| {
            try buf.append(a, @intFromEnum(Tag.number));
            const bits: u64 = @bitCast(n);
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, bits, .little);
            try buf.appendSlice(a, &b);
        },
        // Plugin ABI has no exact-integer tag yet; collapse to f64 on
        // the wire so the codec stays bidirectionally stable. Lossy
        // beyond 2^53 — matches the arithmetic-collapse contract used
        // by `expectNumber` / `applySum`.
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
            for (xs) |xv| try encodeValueDepth(a, buf, xv, depth + 1);
        },
        .form => |f| {
            try buf.append(a, @intFromEnum(Tag.form));
            try writeU32(a, buf, @intCast(f.head.len));
            try buf.appendSlice(a, f.head);
            try writeU32(a, buf, @intCast(f.namespace.len));
            try buf.appendSlice(a, f.namespace);
            try writeU32(a, buf, @intCast(f.children.len));
            for (f.children) |child| try encodeValueDepth(a, buf, child, depth + 1);
            try writeU32(a, buf, @intCast(f.kvpairs.len));
            for (f.kvpairs) |pair| {
                try writeU32(a, buf, @intCast(pair.key.len));
                try buf.appendSlice(a, pair.key);
                try encodeValueDepth(a, buf, pair.value, depth + 1);
            }
        },
    }
}

/// Encode an argument list per §9.2: `[u32 count][value][value]…`.
pub fn encodeArgs(
    a: Allocator,
    buf: *std.ArrayList(u8),
    args: []const Expr.Value,
) error{ OutOfMemory, DepthExceeded }!void {
    try writeU32(a, buf, @intCast(args.len));
    for (args) |v| try encodeValue(a, buf, v);
}

/// Encode a successful result frame per §9.3 — `[u32 ok=1][u32 len][value]`.
/// Returned slice is owned by the caller (allocated from `a`).
pub fn encodeOkFrame(
    a: Allocator,
    value: Expr.Value,
) error{ OutOfMemory, DepthExceeded }![]u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(a);
    try encodeValue(a, &payload, value);
    return try assembleFrame(a, true, payload.items);
}

/// Encode a structured-error frame per §9.3:
/// `[u32 ok=0][u32 len][u32 code_len][code][u32 detail_len][detail]`.
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
    // The payload length is stored in the frame's u32 length field.
    std.debug.assert(payload.len <= std.math.maxInt(u32));
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

// ---------------------------------------------------------------------------
// Decoder
// ---------------------------------------------------------------------------

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

/// Decoded value plus the number of bytes consumed. Strings, keywords,
/// and vector backing arrays are duplicated into `a`.
pub const DecodedValue = struct {
    value: Expr.Value,
    consumed: usize,
};

/// Decode one `Expr.Value` from the head of `bytes`. Strings, keywords,
/// and vector backing arrays are duplicated into `a`; the input may be
/// freed once this returns. Nested vectors deeper than `MAX_VALUE_DEPTH`
/// surface as `error.DepthExceeded`. Trailing bytes past the decoded
/// value are reported via `DecodedValue.consumed` and not consumed.
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

/// Decode an argument list per §9.2. Returned slice is allocated from
/// `a`; element strings/keywords/vectors are also `a`-owned.
pub fn decodeArgs(a: Allocator, bytes: []const u8) Error![]Expr.Value {
    var cur = Cursor{ .bytes = bytes };
    const n = try cur.readU32();
    const xs = try a.alloc(Expr.Value, n);
    for (0..n) |i| xs[i] = try decodeValueDepth(a, &cur, 0);
    return xs;
}

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

/// Decoded result-frame header. `ok = false` means the payload is a
/// structured error (decode further with `decodeStructuredError`);
/// `ok = true` means the payload is an `Expr.Value` (`decodeValue`).
pub const Frame = struct {
    ok: bool,
    payload: []const u8,
};

/// Decode a result-frame header per §9.3 — `[u32 ok][u32 len][u8... payload]`.
/// Returns `error.UnexpectedEof` if `bytes` is shorter than `HEADER_SIZE`
/// or shorter than the declared payload length. The returned `payload`
/// slice borrows from `bytes`; do not retain past the input's lifetime.
/// Complexity: O(1).
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

/// Decode the `ok=0` payload per §9.3 — `[u32 code_len][code][u32
/// detail_len][detail]`. Returned slices are duplicated into `a`.
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

// ===========================================================================
// Tests
// ===========================================================================

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

test "round-trip: number (finite)" {
    const out = try roundTrip(.{ .number = 42.0 });
    try testing.expect(Expr.Value.equals(out, .{ .number = 42.0 }));
}

test "round-trip: number (NaN bit-pattern preserved)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try encodeValue(testing.allocator, &buf, .{ .number = std.math.nan(f64) });
    const out = try decodeValue(testing.allocator, buf.items);
    try testing.expect(std.math.isNan(out.value.number));
}

test "round-trip: number (positive infinity)" {
    const out = try roundTrip(.{ .number = std.math.inf(f64) });
    try testing.expect(std.math.isPositiveInf(out.number));
}

test "round-trip: boolean" {
    const t = try roundTrip(.{ .boolean = true });
    const f = try roundTrip(.{ .boolean = false });
    try testing.expect(Expr.Value.equals(t, .{ .boolean = true }));
    try testing.expect(Expr.Value.equals(f, .{ .boolean = false }));
}

test "round-trip: nil" {
    const out = try roundTrip(.nil);
    try testing.expect(out == .nil);
}

test "round-trip: string vs keyword keep distinct tags" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try encodeValue(testing.allocator, &buf, .{ .string = "ok" });
    try testing.expectEqual(@intFromEnum(Tag.string), buf.items[0]);

    var buf2: std.ArrayList(u8) = .empty;
    defer buf2.deinit(testing.allocator);
    try encodeValue(testing.allocator, &buf2, .{ .keyword = "ok" });
    try testing.expectEqual(@intFromEnum(Tag.keyword), buf2.items[0]);
}

test "round-trip: keyword payload" {
    const out = try roundTrip(.{ .keyword = "ok" });
    defer freeValue(testing.allocator, out);
    try testing.expect(out == .keyword);
    try testing.expectEqualStrings("ok", out.keyword);
}

test "round-trip: 3-vector of numbers" {
    const xs = [_]Expr.Value{
        .{ .number = 1.0 },
        .{ .number = 2.0 },
        .{ .number = 3.0 },
    };
    const out = try roundTrip(.{ .vector = &xs });
    defer freeValue(testing.allocator, out);
    try testing.expect(out == .vector);
    try testing.expectEqual(@as(usize, 3), out.vector.len);
    try testing.expectEqual(@as(f64, 2.0), out.vector[1].number);
}

test "byte-level: (double 21) args buffer matches spec example" {
    // §9.4: [01 00 00 00] count=1, [01] number tag, [00 00 00 00 00 00 35 40] f64 21.0.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try encodeArgs(testing.allocator, &buf, &.{.{ .number = 21.0 }});
    const expected = [_]u8{
        0x01, 0x00, 0x00, 0x00, // count = 1
        0x01, // number tag
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x35, 0x40, // f64 21.0
    };
    try testing.expectEqualSlices(u8, &expected, buf.items);
}

test "byte-level: (double 21) → 42 result frame matches spec example" {
    // §9.4: [01 00 00 00] ok=1, [09 00 00 00] len=9, [01] tag, [...f64 42.0].
    const bytes = try encodeOkFrame(testing.allocator, .{ .number = 42.0 });
    defer testing.allocator.free(bytes);
    const expected = [_]u8{
        0x01, 0x00, 0x00, 0x00, // ok = 1
        0x09, 0x00, 0x00, 0x00, // len = 9
        0x01, // number tag
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x45, 0x40, // f64 42.0
    };
    try testing.expectEqualSlices(u8, &expected, bytes);
}

test "byte-level: keyword :ok result frame matches spec example" {
    const bytes = try encodeOkFrame(testing.allocator, .{ .keyword = "ok" });
    defer testing.allocator.free(bytes);
    const expected = [_]u8{
        0x01, 0x00, 0x00, 0x00, // ok = 1
        0x07, 0x00, 0x00, 0x00, // len = 7  (1 tag + 4 strlen + 2 utf8)
        0x05, // keyword tag
        0x02, 0x00, 0x00, 0x00, // strlen = 2
        'o',  'k',
    };
    try testing.expectEqualSlices(u8, &expected, bytes);
}

test "decodeFrame: ok=1 splits header and payload" {
    const bytes = try encodeOkFrame(testing.allocator, .nil);
    defer testing.allocator.free(bytes);
    const frame = try decodeFrame(bytes);
    try testing.expect(frame.ok);
    try testing.expectEqual(@as(usize, 1), frame.payload.len);
    try testing.expectEqual(@intFromEnum(Tag.nil), frame.payload[0]);
}

test "decodeFrame: ok=0 carries structured error" {
    const bytes = try encodeErrFrame(testing.allocator, "domain", "negative root");
    defer testing.allocator.free(bytes);
    const frame = try decodeFrame(bytes);
    try testing.expect(!frame.ok);
    const err = try decodeStructuredError(testing.allocator, frame.payload);
    defer testing.allocator.free(err.code);
    defer testing.allocator.free(err.detail);
    try testing.expectEqualStrings("domain", err.code);
    try testing.expectEqualStrings("negative root", err.detail);
}

test "decodeArgs: empty list" {
    const bytes = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const xs = try decodeArgs(testing.allocator, &bytes);
    defer testing.allocator.free(xs);
    try testing.expectEqual(@as(usize, 0), xs.len);
}

test "decodeArgs: round-trip three values" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try encodeArgs(testing.allocator, &buf, &.{
        .{ .number = 1.0 },
        .{ .boolean = true },
        .nil,
    });
    const xs = try decodeArgs(testing.allocator, buf.items);
    defer testing.allocator.free(xs);
    try testing.expectEqual(@as(usize, 3), xs.len);
    try testing.expect(xs[0] == .number);
    try testing.expect(xs[1] == .boolean);
    try testing.expect(xs[2] == .nil);
}

test "decoder: invalid tag rejected" {
    const bytes = [_]u8{0x99};
    try testing.expectError(error.InvalidTag, decodeValue(testing.allocator, &bytes));
}

test "decoder: invalid boolean byte rejected" {
    const bytes = [_]u8{ @intFromEnum(Tag.boolean), 0x02 };
    try testing.expectError(error.InvalidBoolean, decodeValue(testing.allocator, &bytes));
}

test "decoder: truncated string fails with UnexpectedEof" {
    // string tag + length=5 but only 2 bytes after.
    const bytes = [_]u8{
        @intFromEnum(Tag.string),
        0x05,
        0x00,
        0x00,
        0x00,
        'h',
        'i',
    };
    try testing.expectError(error.UnexpectedEof, decodeValue(testing.allocator, &bytes));
}

test "round-trip: bare form with no children or kvpairs" {
    const out = try roundTrip(.{ .form = .{
        .head = "todo",
        .namespace = "",
        .children = &.{},
        .kvpairs = &.{},
    } });
    defer freeValue(testing.allocator, out);
    try testing.expect(out == .form);
    try testing.expectEqualStrings("todo", out.form.head);
    try testing.expectEqualStrings("", out.form.namespace);
    try testing.expectEqual(@as(usize, 0), out.form.children.len);
    try testing.expectEqual(@as(usize, 0), out.form.kvpairs.len);
}

test "round-trip: qualified form preserves namespace" {
    const out = try roundTrip(.{ .form = .{
        .head = "circle",
        .namespace = "shapes",
        .children = &.{},
        .kvpairs = &.{},
    } });
    defer freeValue(testing.allocator, out);
    try testing.expectEqualStrings("shapes", out.form.namespace);
}

test "round-trip: form with positional children" {
    const children = [_]Expr.Value{
        .{ .number = 1.0 },
        .{ .number = 2.0 },
    };
    const out = try roundTrip(.{ .form = .{
        .head = "pair",
        .namespace = "",
        .children = &children,
        .kvpairs = &.{},
    } });
    defer freeValue(testing.allocator, out);
    try testing.expectEqual(@as(usize, 2), out.form.children.len);
    try testing.expectEqual(@as(f64, 1.0), out.form.children[0].number);
    try testing.expectEqual(@as(f64, 2.0), out.form.children[1].number);
}

test "round-trip: form with keyword kvpair" {
    const kvs = [_]Expr.KvPair{
        .{ .key = "id", .value = .{ .number = 7.0 } },
        .{ .key = "done", .value = .{ .boolean = true } },
    };
    const out = try roundTrip(.{ .form = .{
        .head = "todo",
        .namespace = "",
        .children = &.{},
        .kvpairs = &kvs,
    } });
    defer freeValue(testing.allocator, out);
    try testing.expectEqual(@as(usize, 2), out.form.kvpairs.len);
    try testing.expectEqualStrings("id", out.form.kvpairs[0].key);
    try testing.expectEqual(@as(f64, 7.0), out.form.kvpairs[0].value.number);
    try testing.expectEqualStrings("done", out.form.kvpairs[1].key);
    try testing.expect(out.form.kvpairs[1].value.boolean);
}

test "round-trip: vector-of-form (the count-done arg shape)" {
    const todos = [_]Expr.Value{
        .{ .form = .{
            .head = "todo",
            .namespace = "",
            .children = &.{},
            .kvpairs = &.{
                .{ .key = "id", .value = .{ .number = 1 } },
                .{ .key = "done", .value = .{ .boolean = false } },
            },
        } },
        .{ .form = .{
            .head = "todo",
            .namespace = "",
            .children = &.{},
            .kvpairs = &.{
                .{ .key = "id", .value = .{ .number = 2 } },
                .{ .key = "done", .value = .{ .boolean = true } },
            },
        } },
    };
    const out = try roundTrip(.{ .vector = &todos });
    defer freeValue(testing.allocator, out);
    try testing.expectEqual(@as(usize, 2), out.vector.len);
    try testing.expect(out.vector[0] == .form);
    try testing.expectEqual(@as(f64, 1), out.vector[0].form.kvpairs[0].value.number);
    try testing.expect(out.vector[1].form.kvpairs[1].value.boolean);
}

test "decoder: depth limit catches deeply-nested forms" {
    // Build encoded bytes for MAX_VALUE_DEPTH+1 nested forms via a
    // single child each. Form descent must count for the depth cap.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var i: usize = 0;
    while (i <= MAX_VALUE_DEPTH) : (i += 1) {
        try buf.append(testing.allocator, @intFromEnum(Tag.form));
        try writeU32(testing.allocator, &buf, 1); // head_len
        try buf.append(testing.allocator, 'x');
        try writeU32(testing.allocator, &buf, 0); // ns_len
        try writeU32(testing.allocator, &buf, 1); // child_count = 1
    }
    try buf.append(testing.allocator, @intFromEnum(Tag.nil));
    // After the innermost nil, every outer form still needs its
    // (empty) kvpair count to be well-formed.
    var j: usize = 0;
    while (j <= MAX_VALUE_DEPTH) : (j += 1) {
        try writeU32(testing.allocator, &buf, 0);
    }
    try testing.expectError(error.DepthExceeded, decodeValue(arena.allocator(), buf.items));
}

fn nestVec(a: Allocator, depth: usize) !Expr.Value {
    var v: Expr.Value = .nil;
    for (0..depth) |_| {
        const one = try a.alloc(Expr.Value, 1);
        one[0] = v;
        v = .{ .vector = one };
    }
    return v;
}

test "encoder: depth limit catches deeply-nested vectors" {
    // Symmetric with the decoder cap: encodeValue must refuse a value
    // nested past MAX_VALUE_DEPTH. Plugin args are mid-eval values, not yet
    // capped by the evaluator's deepCopyValue, so the encoder guards itself.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Under the cap encodes cleanly...
    var ok_buf: std.ArrayList(u8) = .empty;
    defer ok_buf.deinit(testing.allocator);
    try encodeValue(testing.allocator, &ok_buf, try nestVec(a, MAX_VALUE_DEPTH - 2));

    // ...over the cap trips DepthExceeded before overflowing the stack.
    var bad_buf: std.ArrayList(u8) = .empty;
    defer bad_buf.deinit(testing.allocator);
    try testing.expectError(error.DepthExceeded, encodeValue(testing.allocator, &bad_buf, try nestVec(a, MAX_VALUE_DEPTH + 8)));
}

test "decoder: depth limit catches deeply-nested vectors" {
    // Build encoded bytes for MAX_VALUE_DEPTH+1 nested vectors. The
    // partial decode strands per-vector backing arrays — an arena is the
    // documented allocator contract for the decoder, so use one here so
    // the leak detector sees it released cleanly.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var i: usize = 0;
    while (i <= MAX_VALUE_DEPTH) : (i += 1) {
        try buf.append(testing.allocator, @intFromEnum(Tag.vector));
        try writeU32(testing.allocator, &buf, 1);
    }
    // Innermost: tag=nil so the byte stream is well-formed apart from depth.
    try buf.append(testing.allocator, @intFromEnum(Tag.nil));
    try testing.expectError(error.DepthExceeded, decodeValue(arena.allocator(), buf.items));
}
