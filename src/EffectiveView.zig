//! Effective document view — read-side composition over an
//! `Ast.Tree` and a `MaterializedDefaults` overlay.
//!
//! The author tree is never rewritten; effective values for omitted
//! defaulted keys live on the overlay. Without this view, consumers reimplement
//! the "author kvpair first, overlay second, otherwise missing"
//! fallback chain every time they want an effective value.
//!
//! The view borrows pointers to both inputs and allocates nothing on
//! construction or per-call lookup. `toExprValue` is the one place
//! that allocates, into a caller-supplied arena.
//!
//! Origin sub-classification (literal_default vs expression_default)
//! stays on the `Entry`; the `EffectiveValue` union answers the
//! coarser question "did the author write this, or did the
//! materializer fill it in?".

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Expr = @import("Expr.zig");
const MaterializedDefaults = @import("MaterializedDefaults.zig");
const testing = std.testing;
const Parser = @import("Parser.zig");

/// Tagged-union answer to "where does the effective value for this
/// `(form, key)` come from?". Author values stay structural (a
/// `NodeIndex` into the tree) because they may be form-shaped, which
/// `Expr.Value` cannot represent. Defaults stay as the overlay's
/// `Expr.Value` since the materializer already converted them.
pub const EffectiveValue = union(enum) {
    author: Ast.NodeIndex,
    default: *const MaterializedDefaults.Entry,
};

/// Failure modes for `toExprValue`. `NotConvertible` covers author
/// values whose tag has no `Expr.Value` analog: forms (data or
/// expression), number-with-unit (no unit variant on `Expr.Value` —
/// see LANGUAGE.md §7.8), and vectors transitively containing any of
/// the above.
pub const ConvertError = error{
    OutOfMemory,
    NotConvertible,
};

/// The module's conventional aggregate error — its sole surface is conversion.
pub const Error = ConvertError;

/// Read-only view over an author tree and the materialization
/// overlay. Pass by value; the struct borrows both pointers and the
/// lifetime is the caller's responsibility (typically the host result
/// arena).
pub const EffectiveView = struct {
    tree: *const Ast.Tree,
    materialized: *const MaterializedDefaults.MaterializedDefaults,

    pub fn init(
        tree: *const Ast.Tree,
        materialized: *const MaterializedDefaults.MaterializedDefaults,
    ) EffectiveView {
        return .{ .tree = tree, .materialized = materialized };
    }

    /// Returns the kvpair value's `NodeIndex` if the author wrote
    /// `:key` on `form`, else `null`. Linear scan over the form's
    /// children — forms typically carry <10 kvpairs, so a hash
    /// would cost more than it saves.
    pub fn getAuthorValue(
        self: EffectiveView,
        form: Ast.NodeIndex,
        key: []const u8,
    ) ?Ast.NodeIndex {
        if (self.tree.tagOf(form) != .form) return null;
        const hdr = self.tree.formHeader(form);
        return MaterializedDefaults.authorValueOnForm(self.tree, hdr, key);
    }

    /// Delegate to the overlay. Returns the materialized entry for
    /// `(form, key)`, or `null` if the schema has no default or the
    /// author wrote the key (the materializer suppresses entries
    /// for explicit author kvpairs).
    pub fn getDefaultValue(
        self: EffectiveView,
        form: Ast.NodeIndex,
        key: []const u8,
    ) ?*const MaterializedDefaults.Entry {
        return self.materialized.defaultFor(form, key);
    }

    /// Author kvpair wins, else overlay entry, else `null` (the key
    /// is absent from both the document and any applicable default).
    pub fn getEffectiveValue(
        self: EffectiveView,
        form: Ast.NodeIndex,
        key: []const u8,
    ) ?EffectiveValue {
        if (self.getAuthorValue(form, key)) |idx| return .{ .author = idx };
        if (self.getDefaultValue(form, key)) |entry| return .{ .default = entry };
        return null;
    }
};

/// Convert an `EffectiveValue` to a fresh `Expr.Value` owned by
/// `arena`. Returns `NotConvertible` when the author node is a form,
/// expression, or carries a unit suffix. Default-arm values are
/// deep-copied so the result outlives the overlay.
///
/// Author `Tag.symbol` maps to `Expr.Value.keyword`, mirroring the
/// overlay's `Default.symbol` → `keyword` normalization in
/// `MaterializedDefaults.literalToValue`. Consumers needing the
/// source-level symbol-vs-keyword distinction must read the tree
/// directly.
pub fn toExprValue(
    ev: EffectiveValue,
    arena: Allocator,
    tree: *const Ast.Tree,
) ConvertError!Expr.Value {
    return switch (ev) {
        .author => |idx| try astNodeToExprValue(arena, tree, idx),
        .default => |entry| try Expr.deepCopyValueAssumeBounded(arena, entry.value),
    };
}

/// Convert one author-written AST node to an `Expr.Value`.
///
/// Recurses on `.vector` over the host stack. Bounded recursion under the
/// `docs/zig-discipline.md` carve-out: `tree` is parser-built, so its
/// nesting is already capped at `Parser.MAX_PARSE_DEPTH` — the same bound
/// `Ast.cloneNode` and the LSP `Handler`'s enclosing-node scans cite. The
/// `.default` arm next door goes through
/// `Expr.deepCopyValueAssumeBounded`, whose values are capped at
/// `Expr.MAX_VALUE_DEPTH` instead; the two arms are bounded by different
/// ceilings because they descend different things.
fn astNodeToExprValue(
    arena: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) ConvertError!Expr.Value {
    return switch (tree.tagOf(idx)) {
        // Lossy fallback for integer tags until the Expr passthrough
        // commit adds integer_i64 / integer_u64 Value variants. Round-
        // trip through f64 is exact for values within 2^53.
        .number, .number_i64, .number_u64 => .{ .number = tree.numberOf(idx) },
        .boolean_true => .{ .boolean = true },
        .boolean_false => .{ .boolean = false },
        .nil => .nil,
        .date => .{ .date = tree.dateOf(idx) },
        .time => .{ .time = tree.timeOf(idx) },
        .string => .{ .string = try arena.dupe(u8, tree.stringText(idx)) },
        .keyword => blk: {
            const si: Ast.StringIndex = @enumFromInt(tree.dataOf(idx).single);
            break :blk .{ .keyword = try arena.dupe(u8, tree.stringSlice(si)) };
        },
        .symbol => .{ .keyword = try arena.dupe(u8, tree.symbolText(idx)) },
        .vector => blk: {
            const elements = tree.vectorElements(idx);
            const dup = try arena.alloc(Expr.Value, elements.len);
            for (elements, 0..) |elem_idx, i| {
                dup[i] = try astNodeToExprValue(arena, tree, elem_idx);
            }
            break :blk .{ .vector = dup };
        },
        .form, .number_with_unit => ConvertError.NotConvertible,
        .kvpair => unreachable,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn buildOverlay(arena: Allocator, entries: []const MaterializedDefaults.Entry) !MaterializedDefaults.MaterializedDefaults {
    const dup = try arena.dupe(MaterializedDefaults.Entry, entries);
    return .{ .entries = dup };
}

test "EffectiveView.getAuthorValue: returns kvpair value when author wrote :key" {
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(circle :radius 7)");
    defer doc.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    const view = EffectiveView.init(&doc, &overlay);

    const form_idx = doc.root[0];
    const got = view.getAuthorValue(form_idx, "radius");
    try testing.expect(got != null);
    try testing.expectEqual(@as(f64, 7), doc.numberOf(got.?));
}

test "EffectiveView.getAuthorValue: returns null when :key absent" {
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(circle)");
    defer doc.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    const view = EffectiveView.init(&doc, &overlay);

    try testing.expect(view.getAuthorValue(doc.root[0], "radius") == null);
}

test "EffectiveView.getAuthorValue: returns null when target is not a form" {
    const a = testing.allocator;
    var doc = try Parser.parse(a, "42");
    defer doc.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    const view = EffectiveView.init(&doc, &overlay);

    try testing.expect(view.getAuthorValue(doc.root[0], "radius") == null);
}

test "EffectiveView.getEffectiveValue: author present, no default → .author" {
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(circle :radius 7)");
    defer doc.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    const view = EffectiveView.init(&doc, &overlay);

    const ev = view.getEffectiveValue(doc.root[0], "radius") orelse return error.TestUnexpectedNull;
    try testing.expect(ev == .author);
    try testing.expectEqual(@as(f64, 7), doc.numberOf(ev.author));
}

test "EffectiveView.getEffectiveValue: author absent, literal default → .default" {
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(circle)");
    defer doc.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const overlay = try buildOverlay(arena.allocator(), &.{.{
        .form = doc.root[0],
        .key = "radius",
        .value = .{ .number = 32 },
        .origin = .literal_default,
    }});
    const view = EffectiveView.init(&doc, &overlay);

    const ev = view.getEffectiveValue(doc.root[0], "radius") orelse return error.TestUnexpectedNull;
    try testing.expect(ev == .default);
    try testing.expectEqual(MaterializedDefaults.Origin.literal_default, ev.default.origin);
    try testing.expectEqual(@as(f64, 32), ev.default.value.number);
}

test "EffectiveView.getEffectiveValue: author absent, expression default → .default" {
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(circle)");
    defer doc.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const overlay = try buildOverlay(arena.allocator(), &.{.{
        .form = doc.root[0],
        .key = "radius",
        .value = .{ .number = 32 },
        .origin = .expression_default,
    }});
    const view = EffectiveView.init(&doc, &overlay);

    const ev = view.getEffectiveValue(doc.root[0], "radius") orelse return error.TestUnexpectedNull;
    try testing.expect(ev == .default);
    try testing.expectEqual(MaterializedDefaults.Origin.expression_default, ev.default.origin);
}

test "EffectiveView.getEffectiveValue: author absent, no default → null" {
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(circle)");
    defer doc.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    const view = EffectiveView.init(&doc, &overlay);

    try testing.expect(view.getEffectiveValue(doc.root[0], "radius") == null);
}

test "EffectiveView.getEffectiveValue: author wins over default" {
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(circle :radius 7)");
    defer doc.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // The materializer would never produce an entry when the author
    // wrote :radius, but if a consumer constructs an inconsistent
    // overlay (or some future code path skips suppression),
    // EffectiveView still resolves author-first.
    const overlay = try buildOverlay(arena.allocator(), &.{.{
        .form = doc.root[0],
        .key = "radius",
        .value = .{ .number = 32 },
        .origin = .literal_default,
    }});
    const view = EffectiveView.init(&doc, &overlay);

    const ev = view.getEffectiveValue(doc.root[0], "radius") orelse return error.TestUnexpectedNull;
    try testing.expect(ev == .author);
    try testing.expectEqual(@as(f64, 7), doc.numberOf(ev.author));
}

test "toExprValue: author number" {
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(circle :radius 7)");
    defer doc.deinit();
    const overlay = MaterializedDefaults.MaterializedDefaults{};
    const view = EffectiveView.init(&doc, &overlay);
    const ev = view.getEffectiveValue(doc.root[0], "radius").?;

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const v = try toExprValue(ev, arena.allocator(), &doc);
    try testing.expect(v == .number);
    try testing.expectEqual(@as(f64, 7), v.number);
}

test "toExprValue: author string" {
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(scene :title \"demo\")");
    defer doc.deinit();
    const overlay = MaterializedDefaults.MaterializedDefaults{};
    const view = EffectiveView.init(&doc, &overlay);
    const ev = view.getEffectiveValue(doc.root[0], "title").?;

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const v = try toExprValue(ev, arena.allocator(), &doc);
    try testing.expect(v == .string);
    try testing.expectEqualStrings("demo", v.string);
}

test "toExprValue: author symbol maps to keyword" {
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(scene :kind kick)");
    defer doc.deinit();
    const overlay = MaterializedDefaults.MaterializedDefaults{};
    const view = EffectiveView.init(&doc, &overlay);
    const ev = view.getEffectiveValue(doc.root[0], "kind").?;

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const v = try toExprValue(ev, arena.allocator(), &doc);
    try testing.expect(v == .keyword);
    try testing.expectEqualStrings("kick", v.keyword);
}

test "toExprValue: author booleans and nil" {
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(form :t true :f false :n nil)");
    defer doc.deinit();
    const overlay = MaterializedDefaults.MaterializedDefaults{};
    const view = EffectiveView.init(&doc, &overlay);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const t = try toExprValue(view.getEffectiveValue(doc.root[0], "t").?, arena.allocator(), &doc);
    try testing.expect(t == .boolean and t.boolean == true);

    const f = try toExprValue(view.getEffectiveValue(doc.root[0], "f").?, arena.allocator(), &doc);
    try testing.expect(f == .boolean and f.boolean == false);

    const n = try toExprValue(view.getEffectiveValue(doc.root[0], "n").?, arena.allocator(), &doc);
    try testing.expect(n == .nil);
}

test "toExprValue: author vector of numbers" {
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(circle :center [1 2 3])");
    defer doc.deinit();
    const overlay = MaterializedDefaults.MaterializedDefaults{};
    const view = EffectiveView.init(&doc, &overlay);
    const ev = view.getEffectiveValue(doc.root[0], "center").?;

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const v = try toExprValue(ev, arena.allocator(), &doc);
    try testing.expect(v == .vector);
    try testing.expectEqual(@as(usize, 3), v.vector.len);
    try testing.expectEqual(@as(f64, 1), v.vector[0].number);
    try testing.expectEqual(@as(f64, 2), v.vector[1].number);
    try testing.expectEqual(@as(f64, 3), v.vector[2].number);
}

test "toExprValue: author form returns NotConvertible" {
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(badge :shape (circle))");
    defer doc.deinit();
    const overlay = MaterializedDefaults.MaterializedDefaults{};
    const view = EffectiveView.init(&doc, &overlay);
    const ev = view.getEffectiveValue(doc.root[0], "shape").?;

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try testing.expectError(ConvertError.NotConvertible, toExprValue(ev, arena.allocator(), &doc));
}

test "toExprValue: author number_with_unit returns NotConvertible" {
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(rotate :by 90deg)");
    defer doc.deinit();
    const overlay = MaterializedDefaults.MaterializedDefaults{};
    const view = EffectiveView.init(&doc, &overlay);
    const ev = view.getEffectiveValue(doc.root[0], "by").?;

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try testing.expectError(ConvertError.NotConvertible, toExprValue(ev, arena.allocator(), &doc));
}

test "toExprValue: vector containing form returns NotConvertible" {
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(scene :items [1 (circle) 3])");
    defer doc.deinit();
    const overlay = MaterializedDefaults.MaterializedDefaults{};
    const view = EffectiveView.init(&doc, &overlay);
    const ev = view.getEffectiveValue(doc.root[0], "items").?;

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try testing.expectError(ConvertError.NotConvertible, toExprValue(ev, arena.allocator(), &doc));
}

test "toExprValue: default literal deep-copies into arena" {
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(circle)");
    defer doc.deinit();

    var overlay_arena = std.heap.ArenaAllocator.init(a);
    defer overlay_arena.deinit();
    const owned_str = try overlay_arena.allocator().dupe(u8, "red");
    const overlay = try buildOverlay(overlay_arena.allocator(), &.{.{
        .form = doc.root[0],
        .key = "fill",
        .value = .{ .string = owned_str },
        .origin = .literal_default,
    }});
    const view = EffectiveView.init(&doc, &overlay);
    const ev = view.getEffectiveValue(doc.root[0], "fill").?;

    var dst_arena = std.heap.ArenaAllocator.init(a);
    defer dst_arena.deinit();
    const v = try toExprValue(ev, dst_arena.allocator(), &doc);
    try testing.expect(v == .string);
    try testing.expectEqualStrings("red", v.string);
    // Independent copy: pointer is in dst_arena, not overlay_arena.
    try testing.expect(@intFromPtr(v.string.ptr) != @intFromPtr(owned_str.ptr));
}

test "toExprValue: default vector deep-copies elements" {
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(circle)");
    defer doc.deinit();

    var overlay_arena = std.heap.ArenaAllocator.init(a);
    defer overlay_arena.deinit();
    const vec = try overlay_arena.allocator().alloc(Expr.Value, 2);
    vec[0] = .{ .number = 1 };
    vec[1] = .{ .number = 2 };
    const overlay = try buildOverlay(overlay_arena.allocator(), &.{.{
        .form = doc.root[0],
        .key = "center",
        .value = .{ .vector = vec },
        .origin = .literal_default,
    }});
    const view = EffectiveView.init(&doc, &overlay);
    const ev = view.getEffectiveValue(doc.root[0], "center").?;

    var dst_arena = std.heap.ArenaAllocator.init(a);
    defer dst_arena.deinit();
    const v = try toExprValue(ev, dst_arena.allocator(), &doc);
    try testing.expect(v == .vector);
    try testing.expectEqual(@as(usize, 2), v.vector.len);
    try testing.expectEqual(@as(f64, 1), v.vector[0].number);
    try testing.expectEqual(@as(f64, 2), v.vector[1].number);
}

// End-to-end: materialize defaults via the real host pipeline and
// read effective values through the view. Pins the contract that
// `Host.HostResult.materialized_defaults` and `tree` compose into a
// working `EffectiveView`.
test "EffectiveView: end-to-end via Host.validateDocument" {
    const Host = @import("Host.zig");
    const a = testing.allocator;
    const src: [:0]const u8 =
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name fps :type number :default 60)))
        \\(scene)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    try testing.expect(!r.hasErrors());

    var form_idx: ?Ast.NodeIndex = null;
    for (r.data_forest) |idx| {
        if (r.tree.tagOf(idx) == .form) {
            form_idx = idx;
            break;
        }
    }
    const form = form_idx orelse return error.TestNoDataForm;

    const view = EffectiveView.init(&r.tree, &r.materialized_defaults);
    const ev = view.getEffectiveValue(form, "fps") orelse return error.TestNoEffectiveValue;
    try testing.expect(ev == .default);
    try testing.expectEqual(@as(f64, 60), ev.default.value.number);
}
