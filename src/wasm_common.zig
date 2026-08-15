//! Shared WASM helpers — output framing + hand-rolled JSON writers.
//!
//! Both `sjon.wasm` (kitchen-sink) and `sjon-binary.wasm` (size-
//! constrained) import this module. None of the helpers pull in
//! `std.json`; numbers go through `std.fmt.bufPrint("{d}", x)` which
//! does pull `std.fmt`'s float formatter, but that's the only place.
//!
//! Output framing: every output-returning WASM function returns a
//! pointer to `[u32 ok][u32 len][u8... payload]` allocated in the
//! linear memory. Caller (JS) reads `ok`, `len`, copies `len` bytes,
//! then frees `8 + len` via `sjon_free`.
//!
//! Phase 13: the diagnostic-emitting helpers
//! (`parseDiagnosticsJson`, `validatorDiagnosticsJson`) take a
//! `[]const Ast.Diagnostic` slice rather than a tree.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Expr = @import("Expr.zig");
const Validator = @import("Validator.zig");
const Schema = @import("Schema.zig");
const core = @import("plugins/core.zig");

/// The single-plugin schema the binary-path exports validate / evaluate
/// against — just the built-in `core` plugin. Shared by both artifacts (each
/// used to spell it locally); `plugins/core` is already in the read-only
/// `sjon-binary.wasm` closure, so hoisting it here adds no import to it.
pub const core_schema: Schema.Schema = Schema.Schema.init(&.{core.plugin});

/// Header size of a framed output buffer (4 bytes ok + 4 bytes len).
/// Spelled `HEADER_SIZE` to match `Binary.HEADER_SIZE` and
/// `PluginValueCodec.HEADER_SIZE` — every "fixed-size prefix in bytes"
/// constant in the project shares this name.
pub const HEADER_SIZE: u32 = 8;

/// Allocate and populate a framed output buffer. Returns the pointer to
/// the buffer; caller (JS) must `sjon_free(ptr, HEADER_SIZE + payload.len)`.
pub fn frame(allocator: Allocator, ok: bool, payload: []const u8) Allocator.Error![*]u8 {
    const total: usize = HEADER_SIZE + payload.len;
    const buf = try allocator.alloc(u8, total);
    std.mem.writeInt(u32, buf[0..4], if (ok) 1 else 0, .little);
    std.mem.writeInt(u32, buf[4..8], @intCast(payload.len), .little);
    @memcpy(buf[HEADER_SIZE..], payload);
    return buf.ptr;
}

/// Frame an error: payload is the error name (e.g. `"InvalidEncoding"`).
pub fn frameError(allocator: Allocator, err: anyerror) Allocator.Error![*]u8 {
    const name = @errorName(err);
    return try frame(allocator, false, name);
}

// ---------------------------------------------------------------------------
// JSON output writers — hand-rolled, no `std.json` dependency.
// ---------------------------------------------------------------------------

/// Append an `Expr.Value` as JSON. Keywords are encoded as `{"$kw":"…"}`
/// to disambiguate from strings (matches the strict JSON bridge).
///
/// Recurses on the host stack over vectors / forms. Only ever called on a
/// `Result.value`, which eval capped to `Expr.MAX_VALUE_DEPTH` via its
/// final `deepCopyValue` — so the recursion is transitively bounded and
/// needs no depth parameter of its own.
pub fn appendValue(buf: *std.ArrayList(u8), a: Allocator, v: Expr.Value) Allocator.Error!void {
    switch (v) {
        .nil => try buf.appendSlice(a, "null"),
        .boolean => |b| try buf.appendSlice(a, if (b) "true" else "false"),
        .number => |x| {
            if (std.math.isNan(x)) {
                try buf.appendSlice(a, "\"nan\"");
            } else if (std.math.isInf(x)) {
                try buf.appendSlice(a, if (x > 0) "\"inf\"" else "\"-inf\"");
            } else {
                // Sized from std's own published bound, not a guess:
                // `{d}` on an f64 renders full decimal notation — 1e308 is
                // 310 characters, the smallest denormal 326. The old
                // [64]u8 made `catch unreachable` a lie, and this encoder
                // is what the playground's result envelope runs through.
                var num_buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "{d}", .{x}) catch unreachable;
                try buf.appendSlice(a, s);
            }
        },
        .integer_i64 => |x| {
            var num_buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, "{d}", .{x}) catch unreachable;
            try buf.appendSlice(a, s);
        },
        .integer_u64 => |x| {
            var num_buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, "{d}", .{x}) catch unreachable;
            try buf.appendSlice(a, s);
        },
        .string => |s| try appendJsonString(buf, a, s),
        .date => |d| {
            var date_buf: [10]u8 = undefined;
            d.formatCanonical(&date_buf);
            try buf.appendSlice(a, "{\"$date\":\"");
            try buf.appendSlice(a, &date_buf);
            try buf.appendSlice(a, "\"}");
        },
        .time => |t| {
            var time_buf: [12]u8 = undefined;
            const n = t.formatCanonical(&time_buf);
            try buf.appendSlice(a, "{\"$time\":\"");
            try buf.appendSlice(a, time_buf[0..n]);
            try buf.appendSlice(a, "\"}");
        },
        .keyword => |k| {
            try buf.appendSlice(a, "{\"$kw\":");
            try appendJsonString(buf, a, k);
            try buf.append(a, '}');
        },
        .vector => |xs| {
            try buf.append(a, '[');
            for (xs, 0..) |xv, i| {
                if (i > 0) try buf.append(a, ',');
                try appendValue(buf, a, xv);
            }
            try buf.append(a, ']');
        },
        .form => |f| {
            // Tagged-shape encoding mirroring `Json.toJson`'s form
            // output but with the four form-value fields named.
            // `$ns` is omitted when the form is bare so consumers
            // don't have to special-case the empty namespace.
            try buf.appendSlice(a, "{\"$form\":");
            try appendJsonString(buf, a, f.head);
            if (f.namespace.len > 0) {
                try buf.appendSlice(a, ",\"$ns\":");
                try appendJsonString(buf, a, f.namespace);
            }
            try buf.appendSlice(a, ",\"children\":[");
            for (f.children, 0..) |child, i| {
                if (i > 0) try buf.append(a, ',');
                try appendValue(buf, a, child);
            }
            try buf.appendSlice(a, "],\"kvpairs\":{");
            for (f.kvpairs, 0..) |pair, i| {
                if (i > 0) try buf.append(a, ',');
                try appendJsonString(buf, a, pair.key);
                try buf.append(a, ':');
                try appendValue(buf, a, pair.value);
            }
            try buf.appendSlice(a, "}}");
        },
    }
}

/// Append a JSON-quoted string (escapes `"\` and control chars).
pub fn appendJsonString(buf: *std.ArrayList(u8), a: Allocator, s: []const u8) Allocator.Error!void {
    try buf.append(a, '"');
    try appendJsonStringBody(buf, a, s);
    try buf.append(a, '"');
}

/// Append `s`'s JSON-escaped bytes WITHOUT the surrounding quotes —
/// escapes `"\`, the named control chars, and `\uXXXX` for the rest.
/// Callers that need a complete JSON string use `appendJsonString`;
/// callers splicing a value into an already-open string (e.g. behind a
/// fixed prefix) use this so control chars can't break out of the string.
pub fn appendJsonStringBody(buf: *std.ArrayList(u8), a: Allocator, s: []const u8) Allocator.Error!void {
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(a, "\\\""),
        '\\' => try buf.appendSlice(a, "\\\\"),
        '\n' => try buf.appendSlice(a, "\\n"),
        '\r' => try buf.appendSlice(a, "\\r"),
        '\t' => try buf.appendSlice(a, "\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
            var esc_buf: [8]u8 = undefined;
            const s2 = std.fmt.bufPrint(&esc_buf, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(a, s2);
        },
        else => try buf.append(a, c),
    };
}

/// Append a u32 as decimal text.
pub fn appendUint(buf: *std.ArrayList(u8), a: Allocator, n: u32) Allocator.Error!void {
    var num_buf: [10]u8 = undefined;
    const s = std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch unreachable;
    try buf.appendSlice(a, s);
}

/// Append one diagnostic as
/// `{"span":{"start":N,"end":N},"severity":"…","code":"…","message":"…"}`.
/// `code` is the bare snake_case `Ast.Diagnostic.Code` tag name (e.g.
/// `"unknown_form"`); `"unspecified"` for parser diagnostics that have
/// no validator-side code.
pub fn appendDiagnostic(
    buf: *std.ArrayList(u8),
    a: Allocator,
    d: Ast.Diagnostic,
) Allocator.Error!void {
    try buf.appendSlice(a, "{\"span\":{\"start\":");
    try appendUint(buf, a, d.span.start);
    try buf.appendSlice(a, ",\"end\":");
    try appendUint(buf, a, d.span.end);
    try buf.appendSlice(a, "},\"severity\":\"");
    try buf.appendSlice(a, switch (d.severity) {
        .err => "err",
        .warning => "warning",
    });
    try buf.appendSlice(a, "\",\"code\":\"");
    try buf.appendSlice(a, @tagName(d.code));
    try buf.appendSlice(a, "\",\"message\":");
    try appendJsonString(buf, a, d.message);
    try buf.append(a, '}');
}

/// Encode a parse diagnostics slice as `{"diagnostics":[…]}`.
pub fn parseDiagnosticsJson(a: Allocator, diagnostics: []const Ast.Diagnostic) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\"diagnostics\":[");
    for (diagnostics, 0..) |d, i| {
        if (i > 0) try buf.append(a, ',');
        try appendDiagnostic(&buf, a, d);
    }
    try buf.appendSlice(a, "]}");
    return buf.toOwnedSlice(a);
}

/// Encode `{"parse_diagnostics":[…],"diagnostics":[…]}` from a parse
/// diagnostics slice + validator result.
pub fn validatorDiagnosticsJson(
    a: Allocator,
    parse_diagnostics: []const Ast.Diagnostic,
    result: Validator.Result,
) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\"parse_diagnostics\":[");
    for (parse_diagnostics, 0..) |d, i| {
        if (i > 0) try buf.append(a, ',');
        try appendDiagnostic(&buf, a, d);
    }
    try buf.appendSlice(a, "],\"diagnostics\":[");
    for (result.diagnostics, 0..) |d, i| {
        if (i > 0) try buf.append(a, ',');
        try appendDiagnostic(&buf, a, d);
    }
    try buf.appendSlice(a, "]}");
    return buf.toOwnedSlice(a);
}

/// Encode just the validator's diagnostics, with an empty
/// `parse_diagnostics` array. Used by the binary path: it has no parse
/// phase, so there are no parse diagnostics by definition.
pub fn validatorBinaryJson(a: Allocator, result: Validator.Result) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\"parse_diagnostics\":[],\"diagnostics\":[");
    for (result.diagnostics, 0..) |d, i| {
        if (i > 0) try buf.append(a, ',');
        try appendDiagnostic(&buf, a, d);
    }
    try buf.appendSlice(a, "]}");
    return buf.toOwnedSlice(a);
}

/// Encode an `Expr.Value` to a freshly-allocated JSON string.
pub fn valueToJson(a: Allocator, v: Expr.Value) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try appendValue(&buf, a, v);
    return buf.toOwnedSlice(a);
}

// ===========================================================================
// WASM entry helpers — boilerplate shared by both wasm artifacts
// (`sjon.wasm` + `sjon-binary.wasm`): `sjon_alloc` / `sjon_free` (the JS
// memory bridge, exported by both and force-referenced from each entry),
// `guard` (frames the error tail), and the two binary-IR operation bodies
// the read path shares. `guard` and the bodies take an explicit allocator
// — entries pass their linear-memory `wasm_allocator`, native tests pass
// `testing.allocator`. The tree-path bodies stay in `wasm.zig` alone: they
// need Parser / Printer / Json / Edit, deliberately absent from the
// read-only artifact and from this leaf.
// ===========================================================================

/// Linear-memory allocator backing the `sjon_alloc` / `sjon_free` bridge.
/// On wasm it is the real page allocator; native builds (this leaf's own
/// tests, the CLI that links root.zig → wasm_common) compile the exports
/// but never call them, so the `else` branch only needs to be a valid,
/// always-available allocator. `.wasm32` is comptime-selected, so the
/// shipped artifacts are byte-for-byte unchanged.
const wasm_allocator = if (builtin.target.cpu.arch == .wasm32)
    std.heap.wasm_allocator
else
    std.heap.page_allocator;

/// Allocate a `len`-byte input buffer in the wasm linear memory for the JS
/// host to fill; returns null on a zero length or OOM. Both artifacts
/// export this (force-referenced via `comptime` from each entry). Pair
/// every call with `sjon_free`.
pub export fn sjon_alloc(len: u32) callconv(.c) ?[*]u8 {
    if (len == 0) return null;
    const slice = wasm_allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

/// Free a buffer previously handed across the ABI. `len` is its exact byte
/// length — for a framed output that is `HEADER_SIZE + payload.len`.
pub export fn sjon_free(ptr: [*]u8, len: u32) callconv(.c) void {
    if (len == 0) return;
    wasm_allocator.free(ptr[0..len]);
}

// NOTE: the binary-path exports `sjon_validate_binary` / `sjon_eval_expr_binary`
// stay in the two entries (`wasm.zig`, `wasm_binary.zig`) — NOT here. An
// `export fn` in this shared leaf is force-emitted into *every* artifact that
// imports it, including `sjon-lsp.wasm` (which imports this leaf only for the
// JSON writers). That would drag `Validator.validateBinary` / `Expr.evalBinary`
// into the LSP artifact and add an `env` import it can't satisfy. The shared
// pieces they need — `runValidateBinary` / `runEvalExprBinary` / `core_schema`
// — live here and are pulled in by reference, so nothing is duplicated except
// the two three-line export wrappers, which are irreducibly per-artifact.

/// Frame the outcome of a WASM operation body for return across the C ABI:
/// pass the payload pointer through on success, or frame the error's name
/// (falling back to `null` only if framing itself OOMs). Collapses the
/// `catch |err| frameError(a, err) catch null` tail every export shares.
///
/// `result` is an already-evaluated error union — Zig is eager, so
/// `guard(a, runFoo(x))` runs `runFoo` at the call site exactly as the
/// inlined `runFoo(x) catch …` did: identical behavior, one line.
pub fn guard(gpa: Allocator, result: anyerror![*]u8) ?[*]u8 {
    return result catch |err| frameError(gpa, err) catch null;
}

/// Validate a binary-IR buffer and frame `{parse_diagnostics,diagnostics}`
/// JSON — `parse_diagnostics` is always empty on the binary path (there is
/// no parse phase). Both artifacts share this verbatim: the kitchen-sink
/// build reached it through `root.validateBinary`, which just re-exports
/// `Validator.validateBinary`. `gpa` backs both the validator work and the
/// framed output; a scratch arena holds the intermediate JSON.
pub fn runValidateBinary(
    gpa: Allocator,
    bin_bytes: []const u8,
    schema: Schema.Schema,
) (Validator.Error || Allocator.Error)![*]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var result = try Validator.validateBinary(gpa, bin_bytes, schema);
    defer result.deinit();

    const json_text = try validatorBinaryJson(a, result);
    return try frame(gpa, true, json_text);
}

/// Evaluate a single-root binary-IR buffer and frame the result value as
/// JSON, using the default empty `Expr.Env` (both artifacts' only caller
/// passes it). Both artifacts share this verbatim: the kitchen-sink build
/// reached it through `root.evalExprBinary`, which just re-exports
/// `Expr.evalBinary`. Returns `error.MultipleRoots` for a multi-root buffer.
pub fn runEvalExprBinary(
    gpa: Allocator,
    bin_bytes: []const u8,
    schema: Schema.Schema,
) (Expr.BinaryError || Allocator.Error)![*]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const env: Expr.Env = .{};
    var result = try Expr.evalBinary(gpa, bin_bytes, &env, schema);
    defer result.deinit();

    const json_text = try valueToJson(a, result.value);
    return try frame(gpa, true, json_text);
}

// ===========================================================================
// Tests — the framing + JSON-writer layer. Every writer takes an explicit
// allocator, so this is all native (no `wasm_allocator`, no wasm target).
// `Date`/`Time` are already in the read-only closure via Ast / Expr, so the
// test-only imports add no file to it.
// ===========================================================================

const testing = std.testing;
const Date = @import("Date.zig");
const Time = @import("Time.zig");

fn expectValueJson(a: Allocator, v: Expr.Value, expected: []const u8) !void {
    const json = try valueToJson(a, v);
    defer a.free(json);
    try testing.expectEqualStrings(expected, json);
}

test "frame: [u32 ok][u32 len][payload] little-endian layout" {
    const a = testing.allocator;
    const ptr = try frame(a, true, "hi");
    const buf: []u8 = ptr[0 .. HEADER_SIZE + 2];
    defer a.free(buf);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, buf[0..4], .little));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, buf[4..8], .little));
    try testing.expectEqualStrings("hi", buf[HEADER_SIZE..]);
}

test "frame: not-ok with an empty payload is header-only, len 0" {
    const a = testing.allocator;
    const ptr = try frame(a, false, "");
    const buf: []u8 = ptr[0..HEADER_SIZE];
    defer a.free(buf);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[0..4], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[4..8], .little));
}

test "frameError: payload is the error name, ok=0" {
    const a = testing.allocator;
    const ptr = try frameError(a, error.InvalidEncoding);
    const name = "InvalidEncoding";
    const buf: []u8 = ptr[0 .. HEADER_SIZE + name.len];
    defer a.free(buf);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[0..4], .little));
    try testing.expectEqual(@as(u32, name.len), std.mem.readInt(u32, buf[4..8], .little));
    try testing.expectEqualStrings(name, buf[HEADER_SIZE..]);
}

test "appendJsonString round-trips every escape class through std.json" {
    const a = testing.allocator;
    // quote, backslash, newline, CR, tab, NUL, 0x1f, DEL (0x7f — passes
    // through, > control range), then plain text.
    const original = "q\"b\\s\nl\rf\tab\x00\x1f\x7f ok";
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try appendJsonString(&buf, a, original);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\u0000") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\u001f") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\\n") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, buf.items, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(original, parsed.value.string);
}

test "appendJsonStringBody: no surrounding quotes, still escapes control chars" {
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try appendJsonStringBody(&buf, a, "a\nb");
    try testing.expectEqualStrings("a\\nb", buf.items);
}

test "appendValue: scalar shapes" {
    const a = testing.allocator;
    try expectValueJson(a, .nil, "null");
    try expectValueJson(a, .{ .boolean = true }, "true");
    try expectValueJson(a, .{ .boolean = false }, "false");
    try expectValueJson(a, .{ .number = 1.5 }, "1.5");
    try expectValueJson(a, .{ .integer_i64 = -42 }, "-42");
    try expectValueJson(a, .{ .integer_u64 = 18446744073709551615 }, "18446744073709551615");
    try expectValueJson(a, .{ .string = "hi\n" }, "\"hi\\n\"");
    try expectValueJson(a, .{ .keyword = "kw" }, "{\"$kw\":\"kw\"}");
}

test "appendValue: a string's invalid UTF-8 passes through raw" {
    const a = testing.allocator;
    // The lexer is byte-oriented and `\u{…}` escapes are deliberately
    // absent (`Parser.zig`), so a raw 0xFF written between quotes in a
    // source document reaches `Expr.Value.string` intact and leaves here
    // intact: 0xFF is not a control character, so `appendJsonString`
    // does not escape it, and nothing upstream validates the encoding.
    //
    // The payload this produces is therefore NOT guaranteed to be valid
    // UTF-8, which matters because every JS consumer decodes it with
    // TextDecoder and TextDecoder replaces an invalid byte with U+FFFD.
    // So a document carrying one gets a different string on the Zig side
    // than in the browser or in Node — silently, with no diagnostic on
    // either side. The corpus cannot catch this: two of the four runners
    // read `document.sjon` through a UTF-8 decoder, so the bad byte is
    // already U+FFFD before the host is called. This test is the pin.
    //
    // Changing it is a wire-format decision (escape? replace? reject at
    // lex time with a new diagnostic code?), so the behavior is recorded
    // here rather than quietly altered.
    try expectValueJson(a, .{ .string = "a\xFFb" }, "\"a\xFFb\"");
    try testing.expect(!std.unicode.utf8ValidateSlice("a\xFFb"));
}

test "appendValue: non-finite numbers become quoted sentinels" {
    const a = testing.allocator;
    try expectValueJson(a, .{ .number = std.math.nan(f64) }, "\"nan\"");
    try expectValueJson(a, .{ .number = std.math.inf(f64) }, "\"inf\"");
    try expectValueJson(a, .{ .number = -std.math.inf(f64) }, "\"-inf\"");
}

test "appendValue: date + time tagged shapes" {
    const a = testing.allocator;
    try expectValueJson(a, .{ .date = try Date.init(2026, 7, 4) }, "{\"$date\":\"2026-07-04\"}");
    try expectValueJson(a, .{ .time = try Time.init(12, 34, 56, 0) }, "{\"$time\":\"12:34:56\"}");
}

test "appendValue: vector" {
    const a = testing.allocator;
    const elems = [_]Expr.Value{ .{ .number = 1 }, .{ .boolean = true }, .nil };
    try expectValueJson(a, .{ .vector = &elems }, "[1,true,null]");
}

test "appendValue: form shape mirrors the documented $form encoding" {
    const a = testing.allocator;
    const children = [_]Expr.Value{.{ .integer_i64 = 1 }};
    const kvs = [_]Expr.KvPair{.{ .key = "k", .value = .{ .string = "v" } }};
    // Bare form: `$ns` omitted.
    try expectValueJson(a, .{ .form = .{
        .head = "todo",
        .namespace = "",
        .children = &children,
        .kvpairs = &kvs,
    } }, "{\"$form\":\"todo\",\"children\":[1],\"kvpairs\":{\"k\":\"v\"}}");
    // Qualified form: `$ns` present, empty children/kvpairs.
    try expectValueJson(a, .{ .form = .{
        .head = "todo",
        .namespace = "app",
        .children = &.{},
        .kvpairs = &.{},
    } }, "{\"$form\":\"todo\",\"$ns\":\"app\",\"children\":[],\"kvpairs\":{}}");
}

test "parseDiagnosticsJson round-trips span / severity / code / message" {
    const a = testing.allocator;
    const diags = [_]Ast.Diagnostic{
        .{ .span = .{ .start = 3, .end = 7 }, .severity = .err, .code = .unknown_form, .message = "bad \"head\"" },
        .{ .span = .{ .start = 0, .end = 0 }, .severity = .warning, .code = .unspecified, .message = "note" },
    };
    const json = try parseDiagnosticsJson(a, &diags);
    defer a.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("diagnostics").?.array;
    try testing.expectEqual(@as(usize, 2), arr.items.len);
    const d0 = arr.items[0].object;
    try testing.expectEqual(@as(i64, 3), d0.get("span").?.object.get("start").?.integer);
    try testing.expectEqual(@as(i64, 7), d0.get("span").?.object.get("end").?.integer);
    try testing.expectEqualStrings("err", d0.get("severity").?.string);
    try testing.expectEqualStrings("unknown_form", d0.get("code").?.string);
    try testing.expectEqualStrings("bad \"head\"", d0.get("message").?.string);
    try testing.expectEqualStrings("warning", arr.items[1].object.get("severity").?.string);
}

test "appendValue: an extreme float does not overflow the render buffer" {
    // This encoder is what the wasm result envelope — and therefore the
    // playground — runs every evaluated value through. `{d}` on an f64
    // renders full decimal notation (1e308 is 310 characters), so the old
    // [64]u8 made its `catch unreachable` a live panic.
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try appendValue(&buf, a, .{ .number = std.math.floatMax(f64) });
    try testing.expect(buf.items.len > 300);
    buf.clearRetainingCapacity();
    try appendValue(&buf, a, .{ .number = std.math.floatTrueMin(f64) });
    try testing.expect(buf.items.len > 300);
}
