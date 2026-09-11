//! Effective-document splicer — the author's source with every form's
//! omitted defaults spliced in as ` :key value` text before the form's
//! closing paren.
//!
//! Extracted from the LSP Handler so the CLI (`sjon effective`) can
//! print the same document without importing the LSP layer; the
//! Handler's `getEffectiveDocument` and materialize code action are
//! thin adapters over `render` / `formInsertion`, so the surfaces can
//! never disagree about what materializing a form produces.
//!
//! A string splice, not a re-print. Printing a materialized tree would
//! mean building one — and would reformat the user's whole document as
//! a side effect of asking what its defaults are. Splicing touches only
//! the bytes being added, so everything the author wrote (their line
//! breaks, their alignment, their comments) survives verbatim and the
//! diff is exactly the defaults.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Expr = @import("Expr.zig");
const Plugin = @import("Plugin.zig");
const MaterializedDefaults = @import("MaterializedDefaults.zig");
const StringEscape = @import("StringEscape.zig");
/// Test-only: the re-parse leg of the "output is valid source" contract.
const Parser = @import("Parser.zig");

pub const Error = error{OutOfMemory};

/// Text to splice into one form to make its defaults explicit, and the
/// offset to splice it at. Null when the form has nothing to add.
pub const Insertion = struct {
    /// Byte offset of the form's closing paren — a pure insertion point,
    /// so `span_start == span_end` wherever this becomes a `TextEdit`.
    offset: u32,
    /// Leading-space-separated `:key value` pairs, in schema order.
    text: []const u8,
};

/// The document as it effectively reads: `source` with every form's
/// omitted defaults spliced in. Returns `source` itself (borrowed, not
/// copied) when there is nothing to splice; otherwise arena-owned.
///
/// Insertions apply back-to-front so each offset still refers to the
/// original source when its turn comes — the standard reason edit lists
/// are applied in reverse, and load-bearing here because nested forms
/// always produce an inner insertion at a lower offset than its
/// parent's.
pub fn render(
    arena: Allocator,
    source: []const u8,
    tree: *const Ast.Tree,
    materialized: *const MaterializedDefaults.MaterializedDefaults,
) Error![]const u8 {
    if (materialized.entries.len == 0) return source;

    var insertions: std.ArrayList(Insertion) = .empty;
    // Linear scan over every node rather than a root walk: only forms
    // with materialized entries yield insertions, the materializer only
    // keys entries by forms it reached from the root forest, and the
    // sort below owns the ordering — so a tree walk would add machinery
    // without changing the output.
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tags.len) : (i += 1) {
        if (tags[i] != .form) continue;
        const idx = Ast.NodeIndex.from(i);
        const ins = (try formInsertion(arena, source, tree, materialized, idx)) orelse continue;
        try insertions.append(arena, ins);
    }
    if (insertions.items.len == 0) return source;

    // Descending by offset — "back-to-front" made true by sorting
    // rather than left incidental to the scan order.
    std.mem.sort(Insertion, insertions.items, {}, struct {
        fn gt(_: void, x: Insertion, y: Insertion) bool {
            return x.offset > y.offset;
        }
    }.gt);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, source);
    for (insertions.items) |ins| {
        try out.insertSlice(arena, ins.offset, ins.text);
    }
    return try out.toOwnedSlice(arena);
}

/// Offset of `form_idx`'s own closing `)`, or null when the parser
/// recovered the form without one. A recovered form's span ends wherever
/// recovery stopped: at EOF, or on an *inner* form's `)`, which
/// `source[span.end - 1] == ')'` alone cannot tell from the form's own —
/// `(a (b :x 1)` passed that check and spliced `a`'s defaults inside `b`.
/// The form's own `)` lies past every child, so the last child's span
/// must end before it. Shared by the splicer, the LSP inlay hints and
/// the definition-hoist action, which all insert before that byte.
///
/// Complexity: O(1). `source` is the text the tree's spans index.
pub fn formClosingParen(source: []const u8, tree: *const Ast.Tree, form_idx: Ast.NodeIndex) ?u32 {
    std.debug.assert(tree.tagOf(form_idx) == .form);
    const span = tree.spanOf(form_idx);
    if (span.end == 0 or span.end > source.len) return null;
    const close = span.end - 1;
    if (source[close] != ')') return null;
    const hdr = tree.formHeader(form_idx);
    if (hdr.children.len > 0) {
        const last = tree.spanOf(hdr.children[hdr.children.len - 1]);
        if (last.end >= span.end) return null;
    }
    std.debug.assert(close >= span.start);
    return close;
}

/// Build `form_idx`'s insertion, or null when there is nothing to
/// insert. Shared by the LSP materialize action (one form, under the
/// cursor) and the effective document (every form).
pub fn formInsertion(
    arena: Allocator,
    source: []const u8,
    tree: *const Ast.Tree,
    materialized: *const MaterializedDefaults.MaterializedDefaults,
    form_idx: Ast.NodeIndex,
) Error!?Insertion {
    if (materialized.entries.len == 0) return null;

    // Only a form the parser saw closed has a `)` to insert before; the
    // LSP ghost hints and the hoist action share the test.
    const close_paren = formClosingParen(source, tree, form_idx) orelse return null;

    var text: std.ArrayList(u8) = .empty;
    for (materialized.entries) |*entry| {
        if (entry.form != form_idx) continue;

        // Rendered into a scratch buffer first: a value that cannot be
        // written back faithfully is skipped, and appending directly
        // would leave its half-rendered text in the output.
        var value: std.ArrayList(u8) = .empty;
        if (!try appendEffectiveValue(arena, &value, entry)) continue;

        try text.appendSlice(arena, " :");
        try text.appendSlice(arena, entry.key);
        try text.append(arena, ' ');
        try text.appendSlice(arena, value.items);
    }
    // Every entry for this form was unrenderable, or it had none.
    if (text.items.len == 0) return null;

    return .{ .offset = close_paren, .text = try text.toOwnedSlice(arena) };
}

/// Render one materialized entry's value as source text. Prefers the
/// manifest's literal default spelling when the entry carries one (it
/// came out of the manifest as source text); computed values render
/// through `appendExprValue`. Returns false when the rendering would be
/// a display approximation rather than source.
///
/// The spelling is read off the entry rather than looked up from the
/// schema by head. The head alone is not enough to find the right
/// `FormSpec` — a slot-local form shadows a same-named global — and
/// looking it up here is what spliced the global `circle`'s `:radius`
/// into a local `circle` that declares `:r`.
pub fn appendEffectiveValue(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    entry: *const MaterializedDefaults.Entry,
) Error!bool {
    if (entry.literal) |d| {
        std.debug.assert(entry.origin == .literal_default);
        // A literal default is source text by construction — it came
        // out of the manifest that way.
        try appendDefaultLiteral(arena, buf, d, 0);
        return true;
    }
    return appendExprValue(arena, buf, entry.value, 0);
}

/// How deep a computed value renders before eliding. Same rationale as
/// `MAX_DEFAULT_RENDER_DEPTH`, and the same bounded-recursion carve-out
/// from `docs/zig-discipline.md`: explicitly depth-capped, each frame a
/// switch with no meaningful locals.
const MAX_VALUE_RENDER_DEPTH = 8;

/// Render an evaluated `Expr.Value` as SJON source text. Returns false
/// when the rendering is a display approximation rather than source:
/// `.form`, which abbreviates to `(head …)`, and any vector containing
/// one. The flag propagates outward so a form buried three levels deep
/// still blocks insertion. (The CLI's `ValueText` is the faithful
/// counterpart for data-product output; this one is splice-safe.)
pub fn appendExprValue(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    v: Expr.Value,
    depth: usize,
) Error!bool {
    switch (v) {
        .number => |n| try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{n})),
        .integer_i64 => |n| try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{n})),
        .integer_u64 => |n| try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{n})),
        .boolean => |b| try buf.appendSlice(arena, if (b) "true" else "false"),
        .nil => try buf.appendSlice(arena, "nil"),
        // Escaped, not spliced raw: this text is inserted into the author's
        // document (`sjon effective`, the LSP materialize action), so an
        // unescaped `"` is a parse error written into their file.
        .string => |s| try StringEscape.appendQuoted(buf, arena, s),
        .keyword => |s| {
            try buf.append(arena, ':');
            try buf.appendSlice(arena, s);
        },
        .date => |d| {
            var tmp: [10]u8 = undefined;
            d.formatCanonical(&tmp);
            try buf.appendSlice(arena, &tmp);
        },
        .time => |t| {
            var tmp: [12]u8 = undefined;
            const n = t.formatCanonical(&tmp);
            try buf.appendSlice(arena, tmp[0..n]);
        },
        .vector => |xs| {
            if (depth >= MAX_VALUE_RENDER_DEPTH) {
                try buf.appendSlice(arena, "[…]");
                return false;
            }
            var faithful = true;
            try buf.append(arena, '[');
            for (xs, 0..) |x, i| {
                if (i > 0) try buf.append(arena, ' ');
                if (!try appendExprValue(arena, buf, x, depth + 1)) faithful = false;
            }
            try buf.append(arena, ']');
            return faithful;
        },
        .form => |f| {
            try buf.append(arena, '(');
            if (f.namespace.len > 0) {
                try buf.appendSlice(arena, f.namespace);
                try buf.append(arena, '/');
            }
            try buf.appendSlice(arena, f.head);
            try buf.appendSlice(arena, " …)");
            return false;
        },
    }
    return true;
}

test "appendExprValue: a form value is a display approximation, and the flag propagates out of vectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const form: Expr.Value = .{ .form = .{
        .head = "circle",
        .namespace = "",
        .children = &.{},
        .kvpairs = &.{},
    } };

    // The abbreviation is not source text — a true return here would
    // let `formInsertion` splice ellipsis glyphs into a user document.
    var buf: std.ArrayList(u8) = .empty;
    try std.testing.expect(!try appendExprValue(a, &buf, form, 0));
    try std.testing.expectEqualStrings("(circle …)", buf.items);

    // Buried inside a vector, the flag still propagates outward.
    var nested: std.ArrayList(u8) = .empty;
    const xs = [_]Expr.Value{ .{ .integer_i64 = 1 }, form };
    try std.testing.expect(!try appendExprValue(a, &nested, .{ .vector = &xs }, 0));

    // A form-free vector stays faithful.
    var plain: std.ArrayList(u8) = .empty;
    const ys = [_]Expr.Value{ .{ .integer_i64 = 1 }, .{ .integer_i64 = 2 } };
    try std.testing.expect(try appendExprValue(a, &plain, .{ .vector = &ys }, 0));
    try std.testing.expectEqualStrings("[1 2]", plain.items);
}

test "rendered strings re-parse: every escape-needing byte survives the splice" {
    // This module's output is spliced into the author's document, so its
    // contract is that it *is* SJON source. Values arrive escape-decoded
    // from the parser, so a default like `:default "say \"hi\""` holds two
    // raw quotes here — splicing them verbatim wrote a parse error into
    // someone's file.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const payloads = [_][]const u8{
        "say \"hi\"",
        "back\\slash",
        "line1\nline2",
        "carriage\rreturn",
        "tab\there",
        &[_]u8{ 'n', 'u', 'l', 0, 'l' },
        "everything: \" \\ \n \r \t and more",
    };

    for (payloads) |raw| {
        // Both renderers — the Expr.Value path (materialized results) and
        // the KeySpec.Default path (manifest literals) — reach user files.
        var from_value: std.ArrayList(u8) = .empty;
        try std.testing.expect(try appendExprValue(a, &from_value, .{ .string = raw }, 0));

        var from_default: std.ArrayList(u8) = .empty;
        try appendDefaultLiteral(a, &from_default, .{ .string = raw }, 0);

        try std.testing.expectEqualStrings(from_value.items, from_default.items);

        // The real assertion: what we emit parses back to what we had.
        const src = try std.fmt.allocPrintSentinel(a, "(f :k {s})", .{from_value.items}, 0);
        var tree = try Parser.parse(std.testing.allocator, src);
        defer tree.deinit();
        try std.testing.expect(!tree.hasErrors());

        const form = tree.formHeader(tree.root[0]);
        const kv = tree.kvpairHeader(form.children[0]);
        try std.testing.expectEqualStrings(raw, tree.stringText(kv.value));
    }
}

test "rendering is idempotent: splicing twice equals splicing once" {
    // A materialized document can be materialized again (the LSP action is
    // not one-shot). If the second pass re-escaped an already-escaped
    // string, `\"` would drift to `\\\"` on every invocation.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw = "say \"hi\"\\and\nmore";

    var once: std.ArrayList(u8) = .empty;
    try std.testing.expect(try appendExprValue(a, &once, .{ .string = raw }, 0));

    const src = try std.fmt.allocPrintSentinel(a, "(f :k {s})", .{once.items}, 0);
    var tree = try Parser.parse(std.testing.allocator, src);
    defer tree.deinit();
    const form = tree.formHeader(tree.root[0]);
    const kv = tree.kvpairHeader(form.children[0]);

    // Re-render what the parser gave back; the bytes must be identical.
    var twice: std.ArrayList(u8) = .empty;
    try std.testing.expect(try appendExprValue(a, &twice, .{ .string = tree.stringText(kv.value) }, 0));
    try std.testing.expectEqualStrings(once.items, twice.items);
}

test "render depth ceilings elide, and elision is never spliced as source" {
    // Both ceilings are what keep these two recursive renderers inside the
    // bounded-recursion carve-out, and neither elision branch had ever been
    // executed by a test. `[…]` is display text, not source — the value
    // path must therefore also report itself unfaithful, or `formInsertion`
    // would splice an ellipsis glyph into the author's document.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // One level past the cap, built from the inside out.
    var value: Expr.Value = .{ .integer_i64 = 1 };
    var default: Plugin.KeySpec.Default = .{ .number = 1 };
    var i: usize = 0;
    while (i < MAX_VALUE_RENDER_DEPTH + 1) : (i += 1) {
        const v = try a.alloc(Expr.Value, 1);
        v[0] = value;
        value = .{ .vector = v };

        const d = try a.alloc(Plugin.KeySpec.Default, 1);
        d[0] = default;
        default = .{ .vector = d };
    }

    // The elision sits at the cap, wrapped in the brackets above it.
    var from_value: std.ArrayList(u8) = .empty;
    try std.testing.expect(!try appendExprValue(a, &from_value, value, 0));
    try std.testing.expect(std.mem.indexOf(u8, from_value.items, "[…]") != null);

    var from_default: std.ArrayList(u8) = .empty;
    try appendDefaultLiteral(a, &from_default, default, 0);
    try std.testing.expect(std.mem.indexOf(u8, from_default.items, "[…]") != null);

    // One level shallower renders in full — the cap is where it bites.
    var shallow: std.ArrayList(u8) = .empty;
    try std.testing.expect(try appendExprValue(a, &shallow, .{ .vector = &.{.{ .integer_i64 = 1 }} }, MAX_VALUE_RENDER_DEPTH - 1));
    try std.testing.expectEqualStrings("[1]", shallow.items);

    // Exactly at the cap, both still render as real source.
    var at_cap: std.ArrayList(u8) = .empty;
    try std.testing.expect(try appendExprValue(a, &at_cap, .{ .integer_i64 = 7 }, MAX_VALUE_RENDER_DEPTH));
    try std.testing.expectEqualStrings("7", at_cap.items);
}

/// How deep a nested default vector renders before eliding. Defaults are
/// hand-written manifest literals — a vector of vectors of vectors is
/// already past what a tooltip can usefully show.
const MAX_DEFAULT_RENDER_DEPTH = 8;

/// Render `d` as the SJON source text an author would write for it.
///
/// Recursive, which the repo's frame-stack discipline permits only under
/// the `docs/zig-discipline.md` carve-out: the recursion is explicitly
/// depth-bounded (`MAX_DEFAULT_RENDER_DEPTH`) and each frame is a switch
/// with no meaningful locals. Only `.vector` recurses — every other
/// variant is a leaf.
///
/// Expression defaults render from the classification snapshot only
/// (`(head …)`), never by decoding the IR program: the rendering says
/// what the default *is*, and what it evaluates to is a materialization
/// concern.
pub fn appendDefaultLiteral(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    d: Plugin.KeySpec.Default,
    depth: usize,
) Error!void {
    switch (d) {
        .number => |n| try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{n})),
        // Manifest defaults arrive escape-*decoded* from the parser, so
        // `:default "say \"hi\""` is the two-quote string here and must be
        // re-escaped on the way back into source text.
        .string => |s| try StringEscape.appendQuoted(buf, arena, s),
        .symbol => |s| try buf.appendSlice(arena, s),
        .boolean => |b| try buf.appendSlice(arena, if (b) "true" else "false"),
        .nil => try buf.appendSlice(arena, "nil"),
        .vector => |elems| {
            if (depth >= MAX_DEFAULT_RENDER_DEPTH) {
                try buf.appendSlice(arena, "[…]");
                return;
            }
            try buf.append(arena, '[');
            for (elems, 0..) |e, i| {
                if (i > 0) try buf.append(arena, ' ');
                try appendDefaultLiteral(arena, buf, e, depth + 1);
            }
            try buf.append(arena, ']');
        },
        .expression => |e| {
            try buf.append(arena, '(');
            if (e.namespace) |ns| {
                try buf.appendSlice(arena, ns);
                try buf.append(arena, '/');
            }
            try buf.appendSlice(arena, e.head);
            // A niladic expression has no arguments to stand in for.
            if (e.arg_count > 0) try buf.appendSlice(arena, " …");
            try buf.append(arena, ')');
        },
    }
}

test "formClosingParen: an unclosed outer form whose recovered span ends on an inner `)` has no paren of its own" {
    const a = std.testing.allocator;

    var open = try Parser.parse(a, "(a (b :x 1)");
    defer open.deinit();
    const outer = open.root[0];
    const inner = open.formHeader(outer).children[0];
    try std.testing.expect(formClosingParen(open.source, &open, outer) == null);
    try std.testing.expectEqual(@as(?u32, 10), formClosingParen(open.source, &open, inner));

    var closed = try Parser.parse(a, "(a (b :x 1))");
    defer closed.deinit();
    try std.testing.expectEqual(@as(?u32, 11), formClosingParen(closed.source, &closed, closed.root[0]));

    var empty = try Parser.parse(a, "(a)");
    defer empty.deinit();
    try std.testing.expectEqual(@as(?u32, 2), formClosingParen(empty.source, &empty, empty.root[0]));

    var bare = try Parser.parse(a, "(a");
    defer bare.deinit();
    try std.testing.expect(formClosingParen(bare.source, &bare, bare.root[0]) == null);
}
