//! Composition / round-trip property tests.
//!
//! Single-module test suites cover their own encoder/decoder in
//! isolation; this file is the cross-module contract. For every
//! top-level form in `fixtures/json_roundtrip.sjon`, asserts:
//!
//!   1. `parse → print(canonical)` is a fixed point: a second pass
//!      produces byte-identical output.
//!   2. `parse → toJson(canonical) → fromJson → print(canonical)`
//!      ≡ `parse → print(canonical)` (JSON canonical preserves shape).
//!   3. `parse → toBinary(.full) → fromBinary → print(canonical)`
//!      ≡ `parse → print(canonical)` (Binary lossless preset round-
//!      trips back to the same canonical shape).
//!   4. `validate(parse(s), schema)` ≡
//!      `validateBinary(toBinary(parse(s)), schema)` — same
//!      `(code, path)` sequence for both dispatch paths.
//!   5. `evalExpr(parse(s)) ≡ evalExprBinary(toBinary(parse(s)))`
//!      where text-eval succeeds (fixtures that error under text-eval
//!      are skipped — the contract is "when one path produces a Value,
//!      both produce the same Value"; per-error parity is covered by
//!      the binary-eval suite).
//!
//! Plus two pinned smoke tests, each running outside the per-fixture
//! loop because they exercise specific compositions:
//!
//!   * No-op `applyEdit` (set_keyword to current value) followed by
//!     `print(full)` must equal `print(parse(src), full)` — the
//!     Edit reducer respects identity for keyword-set with the
//!     existing value.
//!   * End-to-end pipeline:
//!     `parse → validate → eval → toJson → fromJson → toBinary →
//!     fromBinary → print → applyEdit → re-validate` over one
//!     curated input — every step well-formed, final diagnostics
//!     empty.
//!
//! Catches inter-module drift the per-module suites cannot see (e.g.
//! a JSON encoder change that survives Json_tests round-trip but
//! breaks Binary parity, or a Binary flag tweak that diverges from
//! the Tree-walk validator).

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Parser = @import("Parser.zig");
const Printer = @import("Printer.zig");
const Json = @import("Json.zig");
const Binary = @import("Binary.zig");
const Validator = @import("Validator.zig");
const Expr = @import("Expr.zig");
const Edit = @import("Edit.zig");
const Schema = @import("Schema.zig");
const core = @import("plugins/core.zig");

// ---------------------------------------------------------------------------
// Per-fixture iteration helpers.
//
// The fixture file is a single SJON document with many top-level roots.
// To run encoder round-trips on each root in isolation we slice the
// source bytes by the root's `Span` and re-parse — every encoder we
// exercise (`toJson`, `toBinary`) needs a single-root tree.
// ---------------------------------------------------------------------------

const FIXTURE_PATH = "fixtures/json_roundtrip.sjon";

fn loadSentinel(a: Allocator, path: []const u8) ![:0]u8 {
    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    defer a.free(bytes);
    const buf = try a.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf;
}

/// Re-parse one root's source bytes into a single-root tree. Caller
/// owns both the returned tree (`tree.deinit()`) and the sentinel
/// source buffer (`a.free(sub_src)`).
fn reparseRoot(
    a: Allocator,
    src: []const u8,
    span: Ast.Span,
) !struct { sub_src: [:0]u8, tree: Ast.Tree } {
    const slice = src[span.start..span.end];
    const sub_src = try a.allocSentinel(u8, slice.len, 0);
    errdefer a.free(sub_src);
    @memcpy(sub_src, slice);

    var tree = try Parser.parse(a, sub_src);
    errdefer tree.deinit();

    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(@as(usize, 1), tree.root.len);

    return .{ .sub_src = sub_src, .tree = tree };
}

fn canonicalPrint(a: Allocator, tree: Ast.Tree) !Ast.Bytes {
    return Printer.print(a, tree, .{});
}

// ---------------------------------------------------------------------------
// Property 1 — `parse → print(canonical)` is a fixed point.
//
// The canonical-print idempotence test in `root.zig` already pins this
// over the same fixture; duplicated here so that the composition suite
// is self-contained: a future reorganisation that splits the fixture
// across two suites still keeps property 1 alongside properties 2-5.
// ---------------------------------------------------------------------------

test "composition: canonical-print is a fixed point on every fixture root" {
    const a = testing.allocator;
    const src = try loadSentinel(a, FIXTURE_PATH);
    defer a.free(src);

    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expect(tree.root.len > 0);

    for (tree.root, 0..) |idx, i| {
        var sub = try reparseRoot(a, src, tree.spanOf(idx));
        defer a.free(sub.sub_src);
        defer sub.tree.deinit();

        const first = try canonicalPrint(a, sub.tree);
        defer first.deinit();

        const sentinel_first = try a.allocSentinel(u8, first.data.len, 0);
        defer a.free(sentinel_first);
        @memcpy(sentinel_first, first.data);

        var reparsed = try Parser.parse(a, sentinel_first);
        defer reparsed.deinit();
        try testing.expect(!reparsed.hasErrors());

        const second = try canonicalPrint(a, reparsed);
        defer second.deinit();

        testing.expectEqualStrings(first.data, second.data) catch |err| {
            std.debug.print(
                "\nfixed-point break at fixture #{d}:\n  first:  {s}\n  second: {s}\n",
                .{ i, first.data, second.data },
            );
            return err;
        };
    }
}

// ---------------------------------------------------------------------------
// Property 2 — JSON canonical round-trip preserves canonical shape.
// ---------------------------------------------------------------------------

test "composition: JSON canonical round-trip equals canonical print on every fixture root" {
    const a = testing.allocator;
    const src = try loadSentinel(a, FIXTURE_PATH);
    defer a.free(src);

    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    for (tree.root, 0..) |idx, i| {
        var sub = try reparseRoot(a, src, tree.spanOf(idx));
        defer a.free(sub.sub_src);
        defer sub.tree.deinit();

        var json_result = try Json.toJson(a, sub.tree, .{});
        defer json_result.deinit();
        var rebuilt = try Json.fromJson(a, json_result.value, .{});
        defer rebuilt.deinit();

        const before = try canonicalPrint(a, sub.tree);
        defer before.deinit();
        const after = try canonicalPrint(a, rebuilt);
        defer after.deinit();

        testing.expectEqualStrings(before.data, after.data) catch |err| {
            std.debug.print(
                "\nJSON round-trip drift at fixture #{d}:\n  before: {s}\n  after:  {s}\n",
                .{ i, before.data, after.data },
            );
            return err;
        };
    }
}

// ---------------------------------------------------------------------------
// Property 3 — Binary lossless round-trip preserves canonical shape.
//
// `.full` is the lossless preset: spans + every comment site. Comments
// are stripped by canonical printing anyway, but spans surviving the
// round trip is what guarantees binary IR re-decode lands on the same
// AST shape the parser would produce.
// ---------------------------------------------------------------------------

test "composition: Binary lossless round-trip equals canonical print on every fixture root" {
    const a = testing.allocator;
    const src = try loadSentinel(a, FIXTURE_PATH);
    defer a.free(src);

    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    for (tree.root, 0..) |idx, i| {
        var sub = try reparseRoot(a, src, tree.spanOf(idx));
        defer a.free(sub.sub_src);
        defer sub.tree.deinit();

        const bin = try Binary.toBinary(a, sub.tree, Binary.ToBinaryOptions.forMode(.full));
        defer bin.deinit();
        var rebuilt = try Binary.fromBinary(a, bin.data, .{});
        defer rebuilt.deinit();

        const before = try canonicalPrint(a, sub.tree);
        defer before.deinit();
        const after = try canonicalPrint(a, rebuilt);
        defer after.deinit();

        testing.expectEqualStrings(before.data, after.data) catch |err| {
            std.debug.print(
                "\nBinary round-trip drift at fixture #{d}:\n  before: {s}\n  after:  {s}\n",
                .{ i, before.data, after.data },
            );
            return err;
        };
    }
}

// ---------------------------------------------------------------------------
// Property 4 — validate text/binary parity on every fixture root.
//
// Both dispatch paths must produce the same diagnostic sequence in
// `(code, path)` order. The fixture corpus is mostly *not* schema-
// constrained against `core` (no `(scene …)` form etc.), so most
// roots produce a non-empty diagnostic list — that is the point: we
// assert the text and binary paths agree on the *content* of that
// list, not that it is empty.
// ---------------------------------------------------------------------------

fn pathsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |sa, sb| {
        if (!std.mem.eql(u8, sa, sb)) return false;
    }
    return true;
}

fn debugPrintPath(path: []const []const u8) void {
    std.debug.print("[", .{});
    for (path, 0..) |s, j| {
        if (j > 0) std.debug.print(" ", .{});
        std.debug.print("{s}", .{s});
    }
    std.debug.print("]", .{});
}

test "composition: validate ≡ validateBinary on every fixture root" {
    const a = testing.allocator;
    const src = try loadSentinel(a, FIXTURE_PATH);
    defer a.free(src);

    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    const schema = Schema.Schema.init(&.{core.plugin});

    for (tree.root, 0..) |idx, i| {
        var sub = try reparseRoot(a, src, tree.spanOf(idx));
        defer a.free(sub.sub_src);
        defer sub.tree.deinit();

        var via_text = try Validator.validate(a, sub.tree, schema);
        defer via_text.deinit();

        const bin = try Binary.toBinary(a, sub.tree, Binary.ToBinaryOptions.forMode(.canonical));
        defer bin.deinit();
        var via_bin = try Validator.validateBinary(a, bin.data, schema);
        defer via_bin.deinit();

        try testing.expectEqual(via_text.diagnostics.len, via_bin.diagnostics.len);
        for (via_text.diagnostics, via_bin.diagnostics, 0..) |dt, db, j| {
            testing.expectEqual(dt.code, db.code) catch |err| {
                std.debug.print(
                    "\nfixture #{d} diagnostic #{d} code mismatch: text={s} bin={s}\n",
                    .{ i, j, @tagName(dt.code), @tagName(db.code) },
                );
                return err;
            };
            if (!pathsEqual(dt.path, db.path)) {
                std.debug.print(
                    "\nfixture #{d} diagnostic #{d} path mismatch (code {s}):\n  text: ",
                    .{ i, j, @tagName(dt.code) },
                );
                debugPrintPath(dt.path);
                std.debug.print("\n  bin:  ", .{});
                debugPrintPath(db.path);
                std.debug.print("\n", .{});
                return error.PathMismatch;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Property 5 — eval text/binary parity.
//
// Most fixture roots are not safe expressions (e.g. `(scene :bpm 130 …)`
// has no expr-func backing). For each, attempt text-eval; on success
// require binary-eval to produce an equal `Value`. Errors from
// `evalExpr` are skipped — per-error parity is covered in the binary
// suite, and indiscriminate eval over arbitrary fixtures would
// dominate this test with noise.
// ---------------------------------------------------------------------------

test "composition: evalExpr ≡ evalExprBinary on every successfully-evaluating fixture root" {
    const a = testing.allocator;
    const src = try loadSentinel(a, FIXTURE_PATH);
    defer a.free(src);

    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    const schema = Schema.Schema.init(&.{core.plugin});
    const env: Expr.Env = .{};
    var evaluated: usize = 0;

    for (tree.root, 0..) |idx, i| {
        var sub = try reparseRoot(a, src, tree.spanOf(idx));
        defer a.free(sub.sub_src);
        defer sub.tree.deinit();

        var via_text = Expr.eval(a, &sub.tree, sub.tree.root[0], &env, schema) catch continue;
        defer via_text.deinit();

        const bin = try Binary.toBinary(a, sub.tree, Binary.ToBinaryOptions.forMode(.canonical));
        defer bin.deinit();

        var via_bin = try Expr.evalBinary(a, bin.data, &env, schema);
        defer via_bin.deinit();

        testing.expect(Expr.Value.equals(via_text.value, via_bin.value)) catch |err| {
            std.debug.print("\neval parity break at fixture #{d}\n", .{i});
            return err;
        };
        evaluated += 1;
    }

    // At least the atom roots (nil, true, false, 42, 3.5, "hello") and
    // the `(let [r 0.5] (vec3 r r r))` form must evaluate cleanly. If
    // none did, something pessimised the eval path silently.
    try testing.expect(evaluated >= 6);
}

// ---------------------------------------------------------------------------
// Pinned: no-op `applyEdit` preserves print(full).
//
// `set_keyword` to a key's existing value is the canonical no-op. The
// fixtures here are hand-curated (one per primitive value kind that
// can round-trip through the JSON action shape) so the action JSON
// stays simple and obvious. The contract: applying a no-op edit and
// re-printing in full mode must produce the same bytes as just
// printing the parsed source in full mode.
// ---------------------------------------------------------------------------

test "composition: no-op set_keyword preserves print(full)" {
    const a = testing.allocator;

    const cases = [_]struct {
        src: [:0]const u8,
        action: []const u8,
    }{
        .{
            .src = "(scene :bpm 130)",
            .action = "{\"op\":\"set_keyword\",\"path\":[],\"key\":\"bpm\",\"value\":130}",
        },
        .{
            .src = "(scene :name \"main\")",
            .action = "{\"op\":\"set_keyword\",\"path\":[],\"key\":\"name\",\"value\":\"main\"}",
        },
        .{
            .src = "(thing :flag true)",
            .action = "{\"op\":\"set_keyword\",\"path\":[],\"key\":\"flag\",\"value\":true}",
        },
        .{
            // JSON `null` decodes to SJON `nil`; the source must already
            // spell `nil` for the edit to be a true no-op (SJON `null`
            // is a bare symbol, distinct from `nil`).
            .src = "(thing :tag nil)",
            .action = "{\"op\":\"set_keyword\",\"path\":[],\"key\":\"tag\",\"value\":null}",
        },
    };

    for (cases) |c| {
        // Reference: print(parse(src), full).
        var tree = try Parser.parse(a, c.src);
        defer tree.deinit();
        const reference = try Printer.print(a, tree, .{ .mode = .full });
        defer reference.deinit();

        // Edit pipeline: applyEdit defaults to .full mode.
        const edited = try Edit.applyEditFromJsonString(a, c.src, c.action, .{});
        defer edited.deinit();

        testing.expectEqualStrings(reference.data, edited.data) catch |err| {
            std.debug.print(
                "\nno-op edit drift:\n  src:    {s}\n  ref:    {s}\n  edited: {s}\n",
                .{ c.src, reference.data, edited.data },
            );
            return err;
        };
    }
}

// ---------------------------------------------------------------------------
// Pinned: end-to-end smoke test.
//
// Runs one curated input through every public encoder in a single
// pipeline, asserting each step is well-formed. Catches the worst
// kind of drift — one where a single module's tests still pass but
// a longer composition no longer terminates / returns garbage.
// ---------------------------------------------------------------------------

test "composition: parse → validate → eval → JSON → Binary → print → applyEdit → re-validate" {
    const a = testing.allocator;
    const src: [:0]const u8 = "(+ 1 2 3)";

    const schema = Schema.Schema.init(&.{core.plugin});

    // Step 1 — parse.
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    // Step 2 — validate. `(+ …)` resolves through `core`.
    var v1 = try Validator.validate(a, tree, schema);
    defer v1.deinit();
    try testing.expect(!v1.hasErrors());

    // Step 3 — eval. `(+ 1 2 3)` = 6.
    const env: Expr.Env = .{};
    var ev = try Expr.eval(a, &tree, tree.root[0], &env, schema);
    defer ev.deinit();
    try testing.expect(ev.value.toF64() != null);
    try testing.expectEqual(@as(f64, 6.0), ev.value.toF64().?);

    // Step 4 — toJson / fromJson round-trip.
    var json_result = try Json.toJson(a, tree, .{});
    defer json_result.deinit();
    var from_json = try Json.fromJson(a, json_result.value, .{});
    defer from_json.deinit();

    // Step 5 — toBinary / fromBinary round-trip on the JSON-rebuilt tree.
    const bin = try Binary.toBinary(a, from_json, Binary.ToBinaryOptions.forMode(.full));
    defer bin.deinit();
    var from_bin = try Binary.fromBinary(a, bin.data, .{});
    defer from_bin.deinit();

    // Step 6 — print in canonical mode. The reference shape `(+ 1 2 3)`
    // round-trips through every encoder unchanged.
    const printed = try Printer.print(a, from_bin, .{});
    defer printed.deinit();
    try testing.expectEqualStrings("(+ 1 2 3)\n", printed.data);

    // Step 7 — applyEdit. Wrap the printed bytes in a sentinel-terminated
    // buffer (applyEdit demands `[:0]const u8`) and replace the head
    // with `(+ 1 2 4)` via insert_positional + remove_positional. The
    // simpler `replace path:[3]` of the trailing `3` with `4` keeps the
    // edit one operation.
    const action_json = "{\"op\":\"replace\",\"path\":[2],\"value\":4}";
    const edited = try Edit.applyEditFromJsonString(a, src, action_json, .{});
    defer edited.deinit();

    // Step 8 — re-validate the edited bytes. Still resolves cleanly.
    const edited_sentinel = try a.allocSentinel(u8, edited.data.len, 0);
    defer a.free(edited_sentinel);
    @memcpy(edited_sentinel, edited.data);
    var edited_tree = try Parser.parse(a, edited_sentinel);
    defer edited_tree.deinit();
    try testing.expect(!edited_tree.hasErrors());

    var v2 = try Validator.validate(a, edited_tree, schema);
    defer v2.deinit();
    try testing.expect(!v2.hasErrors());

    // The edited expression evaluates to 1 + 2 + 4 = 7.
    var ev2 = try Expr.eval(a, &edited_tree, edited_tree.root[0], &env, schema);
    defer ev2.deinit();
    try testing.expect(ev2.value.toF64() != null);
    try testing.expectEqual(@as(f64, 7.0), ev2.value.toF64().?);
}
