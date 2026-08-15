//! Canonical-SJON rendering of evaluated `Expr.Value`s — what `sjon
//! eval` prints per expression root (and what the REPL will echo).
//!
//! Faithful, unlike the LSP Handler's `appendExprValue`: that renderer
//! splices its output back into author source, so it abbreviates forms
//! to `(head …)` and elides deep vectors. Here stdout is a data
//! product — forms render completely and strings escape — so the text
//! re-lexes to the value it came from.
//!
//! Recurses on the host stack over vectors / forms with no depth
//! parameter — the same transitive bound as `wasm_common.appendValue`:
//! every value reaching this writer came out of eval's final
//! `deepCopyValue`, which capped it at `Expr.MAX_VALUE_DEPTH`.

const std = @import("std");
const sjon = @import("sjon");
const Expr = sjon.Expr;
const StringEscape = sjon.StringEscape;

const Allocator = std.mem.Allocator;

pub const Error = error{OutOfMemory};

/// Append `v` as canonical SJON source text.
pub fn append(buf: *std.ArrayList(u8), a: Allocator, v: Expr.Value) Error!void {
    switch (v) {
        .number => |x| try appendNumber(buf, a, x),
        .integer_i64 => |x| try appendInt(buf, a, i64, x),
        .integer_u64 => |x| try appendInt(buf, a, u64, x),
        .boolean => |b| try buf.appendSlice(a, if (b) "true" else "false"),
        .nil => try buf.appendSlice(a, "nil"),
        .string => |s| try appendString(buf, a, s),
        .keyword => |k| {
            try buf.append(a, ':');
            try buf.appendSlice(a, k);
        },
        .date => |d| {
            var tmp: [10]u8 = undefined;
            d.formatCanonical(&tmp);
            try buf.appendSlice(a, &tmp);
        },
        .time => |t| {
            var tmp: [12]u8 = undefined;
            const n = t.formatCanonical(&tmp);
            try buf.appendSlice(a, tmp[0..n]);
        },
        .vector => |xs| {
            try buf.append(a, '[');
            for (xs, 0..) |x, i| {
                if (i > 0) try buf.append(a, ' ');
                try append(buf, a, x);
            }
            try buf.append(a, ']');
        },
        .form => |f| {
            try buf.append(a, '(');
            if (f.namespace.len > 0) {
                try buf.appendSlice(a, f.namespace);
                try buf.append(a, '/');
            }
            try buf.appendSlice(a, f.head);
            for (f.children) |c| {
                try buf.append(a, ' ');
                try append(buf, a, c);
            }
            for (f.kvpairs) |kv| {
                try buf.appendSlice(a, " :");
                try buf.appendSlice(a, kv.key);
                try buf.append(a, ' ');
                try append(buf, a, kv.value);
            }
            try buf.append(a, ')');
        },
    }
}

fn appendInt(buf: *std.ArrayList(u8), a: Allocator, comptime T: type, x: T) Error!void {
    var tmp: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{x}) catch unreachable;
    try buf.appendSlice(a, s);
}

/// Render an f64 so it re-lexes as a float: a bare integral rendering
/// (`2`) would come back as `integer_i64`, so append `.0`. NaN / ±inf
/// can't normally reach a Result value but are rendered defensively to
/// keep the writer total (mirrors `PatternQuery.appendNumber`).
fn appendNumber(buf: *std.ArrayList(u8), a: Allocator, x: f64) Error!void {
    if (std.math.isNan(x)) return buf.appendSlice(a, "nan");
    if (std.math.isInf(x)) return buf.appendSlice(a, if (x > 0) "inf" else "-inf");
    // Sized from std's own published bound rather than a guess: `{d}` on
    // an f64 renders full decimal notation, so 1e308 is 310 characters and
    // the smallest denormal is 326. The old [64]u8 made `catch unreachable`
    // a lie — `sjon eval` on `(* 1e300 1e8)` panicked outright.
    var tmp: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{x}) catch unreachable;
    try buf.appendSlice(a, s);
    if (std.mem.indexOfAny(u8, s, ".eE") == null) try buf.appendSlice(a, ".0");
}

fn appendString(buf: *std.ArrayList(u8), a: Allocator, s: []const u8) Error!void {
    try StringEscape.appendQuoted(buf, a, s);
}

// ---------------------------------------------------------------------

const testing = std.testing;

fn expectText(expected: []const u8, v: Expr.Value) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: std.ArrayList(u8) = .empty;
    try append(&buf, arena.allocator(), v);
    try testing.expectEqualStrings(expected, buf.items);
}

test "ValueText: scalars render canonically" {
    try expectText("3", .{ .integer_i64 = 3 });
    try expectText("2.5", .{ .number = 2.5 });
    try expectText("2.0", .{ .number = 2.0 });
    try expectText("true", .{ .boolean = true });
    try expectText("nil", .nil);
    try expectText(":kind", .{ .keyword = "kind" });
}

test "ValueText: strings escape the delimiter and controls" {
    try expectText("\"a\\\"b\\n\"", .{ .string = "a\"b\n" });
    // NUL must round-trip as `\0` — the same escape set as
    // `Printer.writeString`; a raw NUL byte would not re-lex.
    try expectText("\"a\\0b\"", .{ .string = "a\x00b" });
}

test "ValueText: dates, times, u64, and non-finite numbers render canonically" {
    try expectText("18446744073709551615", .{ .integer_u64 = std.math.maxInt(u64) });
    try expectText("nan", .{ .number = std.math.nan(f64) });
    try expectText("inf", .{ .number = std.math.inf(f64) });
    try expectText("-inf", .{ .number = -std.math.inf(f64) });
    try expectText("2026-07-20", .{ .date = try sjon.Date.init(2026, 7, 20) });
    // Time is 8 chars at whole seconds, 12 with milliseconds.
    try expectText("12:34:56", .{ .time = try sjon.Time.init(12, 34, 56, 0) });
    try expectText("12:34:56.500", .{ .time = try sjon.Time.init(12, 34, 56, 500) });
}

test "ValueText: vectors and forms render completely" {
    const inner = [_]Expr.Value{ .{ .integer_i64 = 1 }, .{ .integer_i64 = 2 } };
    try expectText("[1 2]", .{ .vector = &inner });

    const children = [_]Expr.Value{.{ .integer_i64 = 4 }};
    const kvs = [_]Expr.KvPair{.{ .key = "r", .value = .{ .number = 1.5 } }};
    try expectText("(circle 4 :r 1.5)", .{ .form = .{
        .head = "circle",
        .namespace = "",
        .children = &children,
        .kvpairs = &kvs,
    } });
}

test "ValueText: an extreme float renders without overflowing its buffer" {
    // `{d}` on an f64 renders full decimal notation, so the largest finite
    // value is 310 characters and the smallest denormal 326 — both far
    // past the [64]u8 this used to write into, whose `catch unreachable`
    // turned `sjon eval` on `(* 1e300 1e8)` into a panic.
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try append(&buf, a, .{ .number = std.math.floatMax(f64) });
    try testing.expect(buf.items.len > 300);
    // Still re-lexes as a float, which is the whole contract of the `.0`
    // suffix rule above.
    try testing.expect(std.mem.indexOfAny(u8, buf.items, ".eE") != null);

    buf.clearRetainingCapacity();
    try append(&buf, a, .{ .number = std.math.floatTrueMin(f64) });
    try testing.expect(buf.items.len > 300);
}
