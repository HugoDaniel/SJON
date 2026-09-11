//! Expected-value decoder for the conformance corpus.
//!
//! A value-carrying `expected.sjon` fixture pairs its `(diagnostics …)`
//! form with an optional `(values …)` form:
//!
//!     (values
//!       (value :index 0 :result 18446744073709551615)
//!       (value :index 1 :result (point :x 1 :y 2)))
//!
//! Each `(value :index N :result <literal>)` asserts that the runtime's
//! `EvalResult` at forest index `N` equals the literal. This module turns
//! that literal subtree into an `Expr.Value` (`treeToValue`) and collects
//! the whole block (`parseExpectedValues`), so both the conformance runner
//! (`src/conformance_tests.zig`, which compares via `Expr.Value.equals`)
//! and the sibling-file generator (`tools/gen_expected_values.zig`, which
//! re-encodes each value through `wasm_common.appendValue`) share ONE
//! decoder. Extracted from the runner so the generator can reuse it without
//! pulling in `std.testing`; deps are `Ast` + `Expr` only.

const std = @import("std");
const Ast = @import("Ast.zig");
const Expr = @import("Expr.zig");

const Allocator = std.mem.Allocator;

/// Failures decoding a `(values …)` block. `MalformedExpected` covers any
/// structural deviation — a non-form child, a missing `:index`/`:result`, a
/// negative or non-integer index, or a literal node kind `treeToValue`
/// rejects. `OutOfMemory` is the only allocator failure.
pub const Error = error{MalformedExpected} || Allocator.Error;

/// One parsed expected value. `forest_index` matches
/// `Host.EvalResult.forest_index` on the actual side; `value` is built from
/// the literal subtree in the expected.sjon `(value :index N :result <lit>)`
/// entry. Strings/keywords inside `value` are duped into the caller's arena
/// so they outlive the source tree if needed.
pub const ExpectedValue = struct {
    forest_index: usize,
    value: Expr.Value,
};

/// Locate a top-level form by head among `tree.root`. Returns the node
/// index or `null` if no such form exists. Expected.sjon files have 1 or
/// 2 top-level forms — `(diagnostics …)` always, `(values …)` optionally.
pub fn findRootForm(tree: *const Ast.Tree, head: []const u8) ?Ast.NodeIndex {
    for (tree.root) |idx| {
        if (tree.tagOf(idx) != .form) continue;
        const hdr = tree.formHeader(idx);
        if (std.mem.eql(u8, hdr.head, head)) return idx;
    }
    return null;
}

/// Parse the optional `(values …)` block from expected.sjon. Returns an
/// empty list when no such form exists (most cases). Each entry has
/// `(value :index N :result <literal>)` — `:index` is a non-negative
/// integer keying into `HostResult.evaluated_results.forest_index`;
/// `:result` is any SJON literal (number, keyword, string, vector,
/// form, boolean, nil, date, time). Strings/keywords are duped into `a`
/// so the caller can drop the source tree.
///
/// **`a` must be an arena.** Each `ExpectedValue.value` holds `treeToValue`
/// allocations (strings, vector and form backings) that `deinit(a)` on the
/// returned list does not release, and a mid-loop `MalformedExpected`
/// abandons the values built so far. Same contract as
/// `parseExpectedDiagnostics`; both in-repo callers pass arenas.
pub fn parseExpectedValues(
    a: Allocator,
    tree: *const Ast.Tree,
) Error!std.ArrayList(ExpectedValue) {
    var out: std.ArrayList(ExpectedValue) = .empty;
    errdefer out.deinit(a);

    const values_root = findRootForm(tree, "values") orelse return out;
    const values_hdr = tree.formHeader(values_root);
    // Same rule as `parseExpectedDiagnostics`: a child that is not a
    // `(value …)` form is a fixture mistake, not something to skip past.
    for (values_hdr.children) |ci| {
        if (tree.tagOf(ci) != .form) return error.MalformedExpected;
        const vh = tree.formHeader(ci);
        if (!std.mem.eql(u8, vh.head, "value")) return error.MalformedExpected;

        var index: ?usize = null;
        var result: ?Expr.Value = null;
        // `:result :keyword` form: SJON's parser treats a kvpair where
        // the value would be another keyword as two positional keyword
        // "flags" (`Ast.zig` §"flag" rule), so `:result :hello` parses
        // as `[keyword("result"), keyword("hello")]` rather than a
        // kvpair. Track whether we just saw the literal `:result` flag
        // so the next positional keyword becomes the result value.
        var pending_result_flag = false;
        for (vh.children) |kc| {
            switch (tree.tagOf(kc)) {
                .kvpair => {
                    const kv = tree.kvpairHeader(kc);
                    pending_result_flag = false;
                    if (std.mem.eql(u8, kv.key, "index")) {
                        const t = tree.tagOf(kv.value);
                        if (t != .number and t != .number_i64 and t != .number_u64) return error.MalformedExpected;
                        const n = tree.numberOf(kv.value);
                        // Range-check before `@intFromFloat`: an integer-valued
                        // `n` past u32 (or `inf`) is a malformed fixture, not
                        // a panic. `forest_index` is a `u32`-sized position.
                        if (n < 0 or @floor(n) != n) return error.MalformedExpected;
                        if (n > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return error.MalformedExpected;
                        index = @intFromFloat(n);
                    } else if (std.mem.eql(u8, kv.key, "result")) {
                        result = try treeToValue(a, tree, kv.value);
                    }
                },
                .keyword => {
                    const kw = tree.keywordText(kc);
                    if (pending_result_flag and result == null) {
                        result = .{ .keyword = try a.dupe(u8, kw) };
                        pending_result_flag = false;
                    } else if (std.mem.eql(u8, kw, "result")) {
                        pending_result_flag = true;
                    } else {
                        pending_result_flag = false;
                    }
                },
                else => {
                    pending_result_flag = false;
                },
            }
        }
        try out.append(a, .{
            .forest_index = index orelse return error.MalformedExpected,
            .value = result orelse return error.MalformedExpected,
        });
    }
    return out;
}

/// Convert a literal AST subtree to an `Expr.Value`. Mirrors the literal
/// arm of `Expr.eval`: numbers, keywords, strings, booleans, nil, dates,
/// times, plus recursive vectors/forms. Symbols and any other node kind
/// error out — fixture literals must be self-contained (no environment
/// lookup). Allocates strings/keywords/form-keys/vector-element backing
/// into `a`.
///
/// Host-stack recursive under the `docs/zig-discipline.md` bounded-
/// recursion carve-out, citing `Parser.MAX_PARSE_DEPTH` (1024): `tree`
/// always comes from the parser — this reads `expected.sjon`, a file in
/// the repo — so the descent is bounded by the ceiling that built it.
/// No `depth` parameter is threaded for the same reason `Ast.cloneNode`
/// threads none.
pub fn treeToValue(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) Error!Expr.Value {
    return switch (tree.tagOf(idx)) {
        .number => .{ .number = tree.numberOf(idx) },
        .number_i64 => .{ .integer_i64 = tree.numberI64Of(idx) },
        .number_u64 => .{ .integer_u64 = tree.numberU64Of(idx) },
        .keyword => .{ .keyword = try a.dupe(u8, tree.keywordText(idx)) },
        .string => .{ .string = try a.dupe(u8, tree.stringText(idx)) },
        .boolean_true => .{ .boolean = true },
        .boolean_false => .{ .boolean = false },
        .nil => .nil,
        .date => .{ .date = tree.dateOf(idx) },
        .time => .{ .time = tree.timeOf(idx) },
        .vector => blk: {
            const elems = tree.vectorElements(idx);
            const dup = try a.alloc(Expr.Value, elems.len);
            for (elems, 0..) |ei, i| dup[i] = try treeToValue(a, tree, ei);
            break :blk .{ .vector = dup };
        },
        .form => blk: {
            const hdr = tree.formHeader(idx);
            const head = try a.dupe(u8, hdr.head);
            const ns = if (hdr.namespace) |n| try a.dupe(u8, n) else "";
            // Partition children into positional values and kvpairs,
            // mirroring `Expr.eval`'s form-value construction.
            var positionals: std.ArrayList(Expr.Value) = .empty;
            defer positionals.deinit(a);
            var kvs: std.ArrayList(Expr.KvPair) = .empty;
            defer kvs.deinit(a);
            for (hdr.children) |ci| {
                if (tree.tagOf(ci) == .kvpair) {
                    const kv = tree.kvpairHeader(ci);
                    try kvs.append(a, .{
                        .key = try a.dupe(u8, kv.key),
                        .value = try treeToValue(a, tree, kv.value),
                    });
                } else {
                    try positionals.append(a, try treeToValue(a, tree, ci));
                }
            }
            break :blk .{ .form = .{
                .head = head,
                .namespace = ns,
                .children = try positionals.toOwnedSlice(a),
                .kvpairs = try kvs.toOwnedSlice(a),
            } };
        },
        else => error.MalformedExpected,
    };
}

test "parseExpectedValues: u64 max literal decodes to integer_u64" {
    const Parser = @import("Parser.zig");
    const a = std.testing.allocator;
    var tree = try Parser.parse(a, "(diagnostics)\n(values (value :index 0 :result 18446744073709551615))");
    defer tree.deinit();
    var vals = try parseExpectedValues(a, &tree);
    defer vals.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), vals.items.len);
    try std.testing.expectEqual(@as(usize, 0), vals.items[0].forest_index);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), vals.items[0].value.integer_u64);
}

test "parseExpectedValues: an :index beyond u32 is MalformedExpected, not an @intFromFloat panic" {
    const Parser = @import("Parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][:0]const u8{
        "(values (value :index 18446744073709551615 :result 1))",
        "(values (value :index 4294967296 :result 1))",
        "(values (value :index 1e999 :result 1))",
    }) |src| {
        var tree = try Parser.parse(std.testing.allocator, src);
        defer tree.deinit();
        try std.testing.expectError(error.MalformedExpected, parseExpectedValues(arena.allocator(), &tree));
    }
}

test "parseExpectedValues: i64 min literal decodes to integer_i64" {
    const Parser = @import("Parser.zig");
    const a = std.testing.allocator;
    var tree = try Parser.parse(a, "(diagnostics)\n(values (value :index 0 :result -9223372036854775808))");
    defer tree.deinit();
    var vals = try parseExpectedValues(a, &tree);
    defer vals.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), vals.items.len);
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), vals.items[0].value.integer_i64);
}

test "parseExpectedValues: date literal decodes to a date value" {
    const Parser = @import("Parser.zig");
    const a = std.testing.allocator;
    var tree = try Parser.parse(a, "(diagnostics)\n(values (value :index 2 :result 2026-05-19))");
    defer tree.deinit();
    var vals = try parseExpectedValues(a, &tree);
    defer vals.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), vals.items.len);
    try std.testing.expectEqual(@as(usize, 2), vals.items[0].forest_index);
    const d = vals.items[0].value.date;
    try std.testing.expectEqual(@as(i16, 2026), d.year);
    try std.testing.expectEqual(@as(u8, 5), d.month);
    try std.testing.expectEqual(@as(u8, 19), d.day);
}

test "parseExpectedValues: nested form literal decodes to a form value" {
    const Parser = @import("Parser.zig");
    const a = std.testing.allocator;
    // Arena so the duped head/keys/kvpair backing frees in one shot.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var tree = try Parser.parse(a, "(diagnostics)\n(values (value :index 0 :result (point :x 1 :y 2)))");
    defer tree.deinit();
    var vals = try parseExpectedValues(arena.allocator(), &tree);
    defer vals.deinit(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), vals.items.len);
    const f = vals.items[0].value.form;
    try std.testing.expectEqualStrings("point", f.head);
    try std.testing.expectEqual(@as(usize, 0), f.children.len);
    try std.testing.expectEqual(@as(usize, 2), f.kvpairs.len);
    try std.testing.expectEqualStrings("x", f.kvpairs[0].key);
    try std.testing.expectEqualStrings("y", f.kvpairs[1].key);
}

test "parseExpectedValues: no values form yields an empty list" {
    const Parser = @import("Parser.zig");
    const a = std.testing.allocator;
    var tree = try Parser.parse(a, "(diagnostics)");
    defer tree.deinit();
    var vals = try parseExpectedValues(a, &tree);
    defer vals.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), vals.items.len);
}

test "the expected.sjon vocabulary is closed — every deviation is an error" {
    const Parser = @import("Parser.zig");
    // `parseExpectedDiagnostics` is arena-only (see its doc comment) —
    // the strict checks made its error return reachable, and a rejected
    // fixture can abandon an already-allocated numeric path step.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Each source below is a fixture typo that this reader used to
    // absorb: the entry, the key, or the element was skipped, and the
    // assertion silently got weaker instead of failing. `:severity
    // warnign` asserting `err` is the one that motivated §7.
    const bad_diagnostics: []const [:0]const u8 = &.{
        // Inside (diagnostics …): a non-form child, an unknown head.
        "(diagnostics 7)",
        "(diagnostics (diagnostc :code unknown_form))",
        // Inside (diagnostic …): a positional, an unknown key, a
        // wrongly-shaped :code, a missing :code.
        "(diagnostics (diagnostic unknown_form))",
        "(diagnostics (diagnostic :code unknown_form :pat [a]))",
        "(diagnostics (diagnostic :code \"unknown_form\"))",
        "(diagnostics (diagnostic :path [a]))",
    };
    for (bad_diagnostics) |src| {
        var tree = try Parser.parse(a, src);
        defer tree.deinit();
        try std.testing.expectError(error.MalformedExpected, parseExpectedDiagnostics(a, &tree));
    }
    // Same rule on the sibling block, which has its own reader.
    const bad_values: []const [:0]const u8 = &.{
        "(diagnostics)\n(values 7)",
        "(diagnostics)\n(values (val :index 0 :result 1))",
    };
    for (bad_values) |src| {
        var tree = try Parser.parse(a, src);
        defer tree.deinit();
        try std.testing.expectError(error.MalformedExpected, parseExpectedValues(a, &tree));
    }
    // An unknown code and an unknown severity keep their own errors —
    // they name what is wrong more precisely than "malformed".
    {
        var tree = try Parser.parse(a, "(diagnostics (diagnostic :code no_such_code))");
        defer tree.deinit();
        try std.testing.expectError(error.UnknownExpectedCode, parseExpectedDiagnostics(a, &tree));
    }
    {
        var tree = try Parser.parse(a, "(diagnostics (diagnostic :code unknown_form :severity warnign))");
        defer tree.deinit();
        try std.testing.expectError(error.UnknownExpectedSeverity, parseExpectedDiagnostics(a, &tree));
    }
}

/// One parsed expected diagnostic. The `code` is the bare symbol name
/// (e.g. `"unknown_form"`) resolved via `std.meta.stringToEnum`. The
/// `path` is borrowed from the expected.sjon tree — caller keeps that
/// tree alive for the lifetime of these structs. Shared by the corpus
/// runner and `sjon plugin test`, so the two can never drift on what
/// an expectation means.
pub const ExpectedDiagnostic = struct {
    code: Ast.Diagnostic.Code,
    path: []const []const u8,
    /// Defaults to `.err` so existing fixtures need no change. Set to
    /// `.warning` to assert against a warning-severity diagnostic such
    /// as `deprecated_member`.
    severity: Ast.Diagnostic.Severity = .err,
};

/// Failures parsing a `(diagnostics …)` block.
pub const ParseDiagnosticsError = error{
    MalformedExpected,
    UnknownExpectedCode,
    UnknownExpectedSeverity,
} || Allocator.Error;

/// Parse the required `(diagnostics …)` block of an expected.sjon
/// document (1–2 top-level forms: `(diagnostics …)` required,
/// `(values …)` optional; anything else is malformed).
///
/// **`a` must be an arena.** Numeric path steps are `allocPrint`ed into
/// it, and on any error return — a malformed entry after an earlier one
/// already allocated — those buffers are not individually freed. Both
/// callers (`conformance_tests.zig`, `sjon plugin test`) pass one; this
/// is stated because the strict vocabulary check below made the error
/// return reachable where it previously was not.
pub fn parseExpectedDiagnostics(
    a: Allocator,
    tree: *const Ast.Tree,
) ParseDiagnosticsError!std.ArrayList(ExpectedDiagnostic) {
    var out: std.ArrayList(ExpectedDiagnostic) = .empty;
    errdefer out.deinit(a);

    // Expected.sjon carries 1 or 2 top-level forms: `(diagnostics …)`
    // required, `(values …)` optional. Reject anything else (including
    // bare data or unrelated top-level heads) — fixtures are
    // conventionally one form per shape.
    if (tree.root.len == 0 or tree.root.len > 2) return error.MalformedExpected;
    for (tree.root) |idx| {
        if (tree.tagOf(idx) != .form) return error.MalformedExpected;
        const hdr = tree.formHeader(idx);
        if (!std.mem.eql(u8, hdr.head, "diagnostics") and
            !std.mem.eql(u8, hdr.head, "values")) return error.MalformedExpected;
    }
    const root = findRootForm(tree, "diagnostics") orelse return error.MalformedExpected;
    const root_hdr = tree.formHeader(root);

    // Nothing inside `(diagnostics …)` is skipped. A child that is not a
    // `(diagnostic …)` form, a positional where a kvpair belongs, or a key
    // outside {code, severity, path} is a mistake in the fixture — and a
    // skipped one weakens the assertion it was meant to strengthen rather
    // than failing.
    for (root_hdr.children) |ci| {
        if (tree.tagOf(ci) != .form) return error.MalformedExpected;
        const dh = tree.formHeader(ci);
        if (!std.mem.eql(u8, dh.head, "diagnostic")) return error.MalformedExpected;

        var code: ?Ast.Diagnostic.Code = null;
        var path: []const []const u8 = &.{};
        var severity: Ast.Diagnostic.Severity = .err;
        for (dh.children) |kc| {
            if (tree.tagOf(kc) != .kvpair) return error.MalformedExpected;
            const kv = tree.kvpairHeader(kc);
            if (std.mem.eql(u8, kv.key, "code")) {
                if (tree.tagOf(kv.value) != .symbol) return error.MalformedExpected;
                const sym = tree.symbolText(kv.value);
                code = std.meta.stringToEnum(Ast.Diagnostic.Code, sym) orelse
                    return error.UnknownExpectedCode;
            } else if (std.mem.eql(u8, kv.key, "severity")) {
                if (tree.tagOf(kv.value) != .symbol) return error.MalformedExpected;
                const sym = tree.symbolText(kv.value);
                severity = std.meta.stringToEnum(Ast.Diagnostic.Severity, sym) orelse
                    return error.UnknownExpectedSeverity;
            } else if (std.mem.eql(u8, kv.key, "path")) {
                if (tree.tagOf(kv.value) != .vector) return error.MalformedExpected;
                const elems = tree.vectorElements(kv.value);
                const buf = try a.alloc([]const u8, elems.len);
                for (elems, 0..) |ei, i| {
                    buf[i] = switch (tree.tagOf(ei)) {
                        .symbol => tree.symbolText(ei),
                        // Vector indices appear as bare numbers like `1`
                        // in path slots — produce the same decimal-string
                        // shape `indexStep` allocates on the validator side.
                        .number => try std.fmt.allocPrint(a, "{d}", .{tree.numberOf(ei)}),
                        .number_i64 => try std.fmt.allocPrint(a, "{d}", .{tree.numberI64Of(ei)}),
                        .number_u64 => try std.fmt.allocPrint(a, "{d}", .{tree.numberU64Of(ei)}),
                        .string => tree.stringText(ei),
                        else => return error.MalformedExpected,
                    };
                }
                path = buf;
            } else return error.MalformedExpected;
        }
        try out.append(a, .{
            .code = code orelse return error.MalformedExpected,
            .path = path,
            .severity = severity,
        });
    }
    return out;
}

/// Element-wise path equality — the corpus comparison rule.
pub fn pathEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |sa, sb| {
        if (!std.mem.eql(u8, sa, sb)) return false;
    }
    return true;
}
