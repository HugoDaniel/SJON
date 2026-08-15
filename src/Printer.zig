//! SJON Printer.
//!
//! Iterative descent — no recursion — over an `Ast.Tree` (SoA AST). Output
//! is built into a `std.ArrayList(u8)` driven by a `tasks` stack.
//!
//! Modes (`Ast.Mode`):
//!   * `canonical` — deterministic; comments dropped. The format is chosen
//!     so `print(parse(s)) == s` whenever `s` is already canonical, and
//!     `parse(print(t)) ≡ t` always. **Default.**
//!   * `compact`   — alias for `canonical`. Printer has no smaller shape;
//!     width is tuned via `wrap_at`, not the mode.
//!   * `full`      — preserves comments and significant whitespace. Forms /
//!     vectors that contain comments anywhere in their subtree are forced
//!     multi-line so each comment can sit on its own line.
//!
//! Layout strategy (canonical):
//!   Pre-pass computes the would-be single-line length of every node into a
//!   dense `lengths: []u32` indexed by `NodeIndex`. A form / vector renders
//!   single-line iff its single-line length is ≤ `opts.wrap_at`. Otherwise it
//!   renders multi-line with each child on its own indented line; the closing
//!   delimiter trails the last child on the same line. Compactness is decided
//!   independently per node, so a long outer form can break while still
//!   rendering its short inner forms inline.
//!
//! The printer walks the SoA `Ast.Tree` exclusively.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const StringEscape = @import("StringEscape.zig");

const Tree = Ast.Tree;
const NodeIndex = Ast.NodeIndex;
const Tag = Ast.Tag;
const StringIndex = Ast.StringIndex;

/// Tunables for `print`. All fields have sensible defaults; pass `.{}` to
/// accept everything.
///
/// Complexity: `print` runs O(n) where n = node count. There are two
/// passes — a length pre-pass (`computeLengths`) and the emit pass —
/// each visiting every node once via the explicit `tasks` stack.
///
/// Allocations: `gpa` backs the output buffer, a transient `[]u32`
/// lengths cache (`nodes.len * 4` bytes), and (full mode only) a
/// transient `[]bool` inner-comments mask. All released before return;
/// the caller owns the returned `[]u8`.
pub const Options = struct {
    /// Which printer pass to run. `canonical` (default) is deterministic
    /// and drops comments; `full` preserves comments and forces
    /// trivia-bearing forms multi-line. `compact` aliases `canonical`.
    mode: Ast.Mode = .canonical,
    /// Spaces per indentation level for multi-line forms / vectors.
    indent: u8 = 2,
    /// Soft column budget. Forms / vectors whose single-line representation
    /// stays at or below this many bytes render on one line.
    wrap_at: u16 = 60,

    /// Construct the preset matching `mode` with default `indent` /
    /// `wrap_at`. Parallel to `Binary.ToBinaryOptions.forMode` so the
    /// encoder family has one blessed construction style.
    pub fn forMode(mode: Ast.Mode) Options {
        return .{ .mode = mode };
    }
};

/// Print a `Tree` to a freshly-allocated, caller-owned `Ast.Bytes`
/// (`bytes.deinit()` to release). Always succeeds unless allocation fails.
pub fn print(gpa: Allocator, tree: Tree, opts: Options) Allocator.Error!Ast.Bytes {
    // Node indices are u32 throughout the SoA tree, so a well-formed tree never
    // holds more than u32-max nodes; the per-node length table below indexes by
    // that width.
    std.debug.assert(tree.nodes.len <= std.math.maxInt(u32));
    const node_count: u32 = @intCast(tree.nodes.len);

    const lengths = try gpa.alloc(u32, node_count);
    defer gpa.free(lengths);
    @memset(lengths, 0);
    try computeLengths(gpa, &tree, lengths);

    var has_inner: []bool = &.{};
    // Register the free up-front so OOM in the body still cleans up.
    // `gpa.free` is a no-op for the initial empty slice.
    defer gpa.free(has_inner);
    if (opts.mode == .full) {
        has_inner = try gpa.alloc(bool, node_count);
        @memset(has_inner, false);
        try computeHasInnerComments(gpa, &tree, has_inner);
    }

    const ctx: PrintCtx = .{
        .tree = &tree,
        .lengths = lengths,
        .has_inner_comments = has_inner,
        .opts = opts,
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var tasks: std.ArrayList(Task) = .empty;
    defer tasks.deinit(gpa);

    // Push tree-level trailing comments first (they pop after root nodes).
    // Each trailing comment goes on its own line; print() adds the final \n.
    if (opts.mode == .full) {
        const trailing = tree.tree_trailing_comments;
        if (!trailing.isEmpty()) {
            const texts = tree.commentTexts(trailing);
            var ti: usize = texts.len;
            while (ti > 0) : (ti -= 1) {
                if (ti < texts.len) try tasks.append(gpa, .raw_newline);
                try tasks.append(gpa, .{ .text = texts[ti - 1] });
            }
            if (tree.root.len > 0) try tasks.append(gpa, .raw_newline);
        }
    }

    // Push top-level nodes in reverse so the first one pops first.
    var i: usize = tree.root.len;
    while (i > 0) : (i -= 1) {
        if (i < tree.root.len) try tasks.append(gpa, .raw_newline);
        try tasks.append(gpa, .{ .expand = .{ .node = tree.root[i - 1], .depth = 0 } });
    }

    while (tasks.pop()) |t| try executeTask(gpa, &out, &tasks, t, ctx);

    if (tree.root.len > 0 or !tree.tree_trailing_comments.isEmpty()) {
        try out.append(gpa, '\n');
    }

    return .{ .gpa = gpa, .data = try out.toOwnedSlice(gpa) };
}

/// Read-only context threaded through executeTask for ergonomics.
const PrintCtx = struct {
    tree: *const Tree,
    lengths: []const u32,
    has_inner_comments: []const bool,
    opts: Options,
};

// ---------------------------------------------------------------------------
// Tasks
// ---------------------------------------------------------------------------

const Task = union(enum) {
    /// Visit a node — emit any leading comments first (full mode only),
    /// then expand the actual content via `expand_actual`.
    expand: ExpandNode,
    /// Direct expansion: emit a leaf or push children for a compound.
    /// Bypasses leading-comments handling.
    expand_actual: ExpandNode,
    /// Emit a literal byte slice (slice must outlive the print() call;
    /// arena-owned AST data is fine, as are static `"…"` literals).
    text: []const u8,
    /// Emit a single space.
    raw_space,
    /// Emit a single newline.
    raw_newline,
    /// Emit `\n` followed by `n` spaces.
    indent: u32,

    const ExpandNode = struct { node: NodeIndex, depth: u32 };
};

fn executeTask(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    tasks: *std.ArrayList(Task),
    task: Task,
    ctx: PrintCtx,
) Allocator.Error!void {
    switch (task) {
        .text => |s| try out.appendSlice(gpa, s),
        .raw_space => try out.append(gpa, ' '),
        .raw_newline => try out.append(gpa, '\n'),
        .indent => |n| {
            try out.append(gpa, '\n');
            var k: u32 = 0;
            while (k < n) : (k += 1) try out.append(gpa, ' ');
        },
        .expand => |e| try expandWithLeading(gpa, out, tasks, e, ctx),
        .expand_actual => |e| try expandActual(gpa, out, tasks, e.node, e.depth, ctx),
    }
}

fn expandWithLeading(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    tasks: *std.ArrayList(Task),
    e: Task.ExpandNode,
    ctx: PrintCtx,
) Allocator.Error!void {
    if (ctx.opts.mode == .full) {
        const range = ctx.tree.leading_comments_index[e.node.raw()];
        if (!range.isEmpty()) {
            // Push expand_actual then comment tasks in reverse — comments
            // pop first, then expand_actual after the last indent.
            try tasks.append(gpa, .{ .expand_actual = e });
            const texts = ctx.tree.commentTexts(range);
            var i: usize = texts.len;
            while (i > 0) : (i -= 1) {
                try tasks.append(gpa, .{ .indent = e.depth });
                try tasks.append(gpa, .{ .text = texts[i - 1] });
            }
            return;
        }
    }
    try expandActual(gpa, out, tasks, e.node, e.depth, ctx);
}

fn expandActual(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    tasks: *std.ArrayList(Task),
    node: NodeIndex,
    depth: u32,
    ctx: PrintCtx,
) Allocator.Error!void {
    const tag = ctx.tree.tagOf(node);
    switch (tag) {
        .number, .number_i64, .number_u64 => try writeNumberFromTree(gpa, out, ctx.tree, node),
        .number_with_unit => {
            const nu = ctx.tree.numberWithUnitOf(node);
            try writeNumber(gpa, out, nu.value);
            try out.appendSlice(gpa, nu.unit);
        },
        .string => {
            const si: StringIndex = @enumFromInt(ctx.tree.dataOf(node).single);
            try writeString(gpa, out, ctx.tree.stringSlice(si));
        },
        .keyword => {
            const si: StringIndex = @enumFromInt(ctx.tree.dataOf(node).single);
            try out.append(gpa, ':');
            try out.appendSlice(gpa, ctx.tree.stringSlice(si));
        },
        .symbol => {
            const si: StringIndex = @enumFromInt(ctx.tree.dataOf(node).single);
            try out.appendSlice(gpa, ctx.tree.stringSlice(si));
        },
        .boolean_true => try out.appendSlice(gpa, "true"),
        .boolean_false => try out.appendSlice(gpa, "false"),
        .nil => try out.appendSlice(gpa, "nil"),
        .date => {
            const d = ctx.tree.dateOf(node);
            var buf: [10]u8 = undefined;
            d.formatCanonical(&buf);
            try out.appendSlice(gpa, &buf);
        },
        .time => {
            const t = ctx.tree.timeOf(node);
            var buf: [12]u8 = undefined;
            const n = t.formatCanonical(&buf);
            try out.appendSlice(gpa, buf[0..n]);
        },
        .form => try pushForm(gpa, tasks, node, depth, ctx),
        .vector => try pushVector(gpa, tasks, node, depth, ctx),
        .kvpair => try pushKvPair(gpa, tasks, node, depth, ctx),
    }
}

fn isCompact(node: NodeIndex, ctx: PrintCtx) bool {
    if (ctx.opts.mode == .full and ctx.has_inner_comments[node.raw()]) {
        return false;
    }
    return ctx.lengths[node.raw()] <= ctx.opts.wrap_at;
}

fn pushForm(
    gpa: Allocator,
    tasks: *std.ArrayList(Task),
    node: NodeIndex,
    depth: u32,
    ctx: PrintCtx,
) Allocator.Error!void {
    const compact = isCompact(node, ctx);
    const child_depth: u32 = depth + ctx.opts.indent;
    const hdr = ctx.tree.formHeader(node);

    // Push close paren first (pops last).
    try tasks.append(gpa, .{ .text = ")" });

    // Trailing comments inside the form (full mode only). They appear after
    // the last child but before `)`, each on its own indented line. The
    // line break before `)` is mandatory — line comments otherwise eat the
    // closing paren.
    if (ctx.opts.mode == .full) {
        const trailing_range = ctx.tree.trailing_comments_index[node.raw()];
        if (!trailing_range.isEmpty()) {
            try tasks.append(gpa, .{ .indent = child_depth });
            const texts = ctx.tree.commentTexts(trailing_range);
            var ti: usize = texts.len;
            while (ti > 0) : (ti -= 1) {
                try tasks.append(gpa, .{ .text = texts[ti - 1] });
                try tasks.append(gpa, .{ .indent = child_depth });
            }
        }
    }

    // Push children in reverse, each preceded by a separator (space for
    // single-line, indent for multi-line). The separator lands BEFORE the
    // child once popped, so even the first child gets its own indented
    // line in multi-line layout.
    var j: usize = hdr.children.len;
    while (j > 0) : (j -= 1) {
        try tasks.append(gpa, .{ .expand = .{
            .node = hdr.children[j - 1],
            .depth = if (compact) depth else child_depth,
        } });
        if (compact) {
            try tasks.append(gpa, .raw_space);
        } else {
            try tasks.append(gpa, .{ .indent = child_depth });
        }
    }

    // Head text. Namespaced heads emit `<ns>/<name>`.
    try tasks.append(gpa, .{ .text = hdr.head });
    if (hdr.namespace) |ns| {
        try tasks.append(gpa, .{ .text = "/" });
        try tasks.append(gpa, .{ .text = ns });
    }
    try tasks.append(gpa, .{ .text = "(" });
}

fn pushVector(
    gpa: Allocator,
    tasks: *std.ArrayList(Task),
    node: NodeIndex,
    depth: u32,
    ctx: PrintCtx,
) Allocator.Error!void {
    const compact = isCompact(node, ctx);
    const child_depth: u32 = depth + ctx.opts.indent;
    const elements = ctx.tree.vectorElements(node);

    try tasks.append(gpa, .{ .text = "]" });

    // Trailing comments inside the vector (full mode only). Same contract as
    // the form path: after the last element but before `]`, each on its own
    // indented line, with a mandatory break so a line comment cannot eat `]`.
    if (ctx.opts.mode == .full) {
        const trailing_range = ctx.tree.trailing_comments_index[node.raw()];
        if (!trailing_range.isEmpty()) {
            try tasks.append(gpa, .{ .indent = child_depth });
            const texts = ctx.tree.commentTexts(trailing_range);
            var ti: usize = texts.len;
            while (ti > 0) : (ti -= 1) {
                try tasks.append(gpa, .{ .text = texts[ti - 1] });
                try tasks.append(gpa, .{ .indent = child_depth });
            }
        }
    }

    var j: usize = elements.len;
    while (j > 0) : (j -= 1) {
        try tasks.append(gpa, .{ .expand = .{
            .node = elements[j - 1],
            .depth = if (compact) depth else child_depth,
        } });
        if (compact) {
            // Space before every element except the first — `[a b c]`,
            // not `[ a b c]`.
            if (j > 1) try tasks.append(gpa, .raw_space);
        } else {
            try tasks.append(gpa, .{ .indent = child_depth });
        }
    }

    try tasks.append(gpa, .{ .text = "[" });
}

fn pushKvPair(
    gpa: Allocator,
    tasks: *std.ArrayList(Task),
    node: NodeIndex,
    depth: u32,
    ctx: PrintCtx,
) Allocator.Error!void {
    const kvh = ctx.tree.kvpairHeader(node);
    // Emit `:key value`. Static parts pushed reverse-of-execution: pops
    // yield `:`, key, space, value-expand.
    try tasks.append(gpa, .{ .expand = .{ .node = kvh.value, .depth = depth } });
    try tasks.append(gpa, .raw_space);
    try tasks.append(gpa, .{ .text = kvh.key });
    try tasks.append(gpa, .{ .text = ":" });
}

// ---------------------------------------------------------------------------
// Single-line length pre-pass
// ---------------------------------------------------------------------------

/// Iterative post-order walk that fills `lengths[NodeIndex.raw()]` with each
/// node's would-be single-line rendered length in bytes. Forms / vectors /
/// kvpairs aggregate their children's lengths plus the separators and
/// delimiters they would emit.
fn computeLengths(
    gpa: Allocator,
    tree: *const Tree,
    lengths: []u32,
) Allocator.Error!void {
    const Frame = struct {
        node: NodeIndex,
        cursor: u32,
    };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);

    for (tree.root) |r| {
        try stack.append(gpa, .{ .node = r, .cursor = 0 });

        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const tag = tree.tagOf(top.node);

            const next_child: ?NodeIndex = switch (tag) {
                .form => blk: {
                    const hdr = tree.formHeader(top.node);
                    if (top.cursor < hdr.children.len) break :blk hdr.children[top.cursor];
                    break :blk null;
                },
                .vector => blk: {
                    const elems = tree.vectorElements(top.node);
                    if (top.cursor < elems.len) break :blk elems[top.cursor];
                    break :blk null;
                },
                .kvpair => blk: {
                    if (top.cursor < 1) {
                        const kvh = tree.kvpairHeader(top.node);
                        break :blk kvh.value;
                    }
                    break :blk null;
                },
                else => null,
            };

            if (next_child) |c| {
                top.cursor += 1;
                try stack.append(gpa, .{ .node = c, .cursor = 0 });
                continue;
            }

            const len: u32 = switch (tag) {
                .number, .number_i64, .number_u64 => numberLenFromTree(tree, top.node),
                .number_with_unit => blk: {
                    const nu = tree.numberWithUnitOf(top.node);
                    break :blk numberLen(nu.value) + lenU32(nu.unit);
                },
                .string => blk: {
                    const si: StringIndex = @enumFromInt(tree.dataOf(top.node).single);
                    break :blk stringLen(tree.stringSlice(si));
                },
                .keyword => blk: {
                    const si: StringIndex = @enumFromInt(tree.dataOf(top.node).single);
                    break :blk 1 + lenU32(tree.stringSlice(si));
                },
                .symbol => blk: {
                    const si: StringIndex = @enumFromInt(tree.dataOf(top.node).single);
                    break :blk lenU32(tree.stringSlice(si));
                },
                .boolean_true => 4,
                .boolean_false => 5,
                .nil => 3,
                .date => @intCast(tree.dateOf(top.node).canonicalLen()),
                .time => @intCast(tree.timeOf(top.node).canonicalLen()),
                .form => blk: {
                    // `(` + optional `<ns>/` + head + per-child (` ` +
                    // child_len) + `)`.
                    const hdr = tree.formHeader(top.node);
                    var total: u32 = 2 + lenU32(hdr.head);
                    if (hdr.namespace) |ns| total += lenU32(ns) + 1;
                    for (hdr.children) |ch| {
                        total += 1 + lengths[ch.raw()];
                    }
                    break :blk total;
                },
                .vector => blk: {
                    const elems = tree.vectorElements(top.node);
                    var total: u32 = 2; // `[]`
                    for (elems, 0..) |e, idx| {
                        if (idx > 0) total += 1; // space separator
                        total += lengths[e.raw()];
                    }
                    break :blk total;
                },
                .kvpair => blk: {
                    // `:` + key + ` ` + value
                    const kvh = tree.kvpairHeader(top.node);
                    break :blk 2 + lenU32(kvh.key) + lengths[kvh.value.raw()];
                },
            };
            lengths[top.node.raw()] = len;
            _ = stack.pop();
        }
    }
}

inline fn lenU32(s: []const u8) u32 {
    return @intCast(s.len);
}

// ---------------------------------------------------------------------------
// Inner-comments pre-pass (full mode only)
// ---------------------------------------------------------------------------

/// A node has "inner comments" when its rendering must reserve space for
/// at least one comment somewhere inside it — meaning a single-line layout
/// is impossible. Conditions per node:
///   * form: trailing_comments_index, OR any direct child has leading
///     comments, OR any direct child is itself in the set.
///   * vector: trailing_comments_index, OR any element has leading
///     comments, OR any element in the set.
///   * kvpair: value has leading comments, OR value is in the set.
///   * atoms: never (atoms have no children to comment between).
fn computeHasInnerComments(
    gpa: Allocator,
    tree: *const Tree,
    set: []bool,
) Allocator.Error!void {
    const Frame = struct {
        node: NodeIndex,
        cursor: u32,
    };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);

    for (tree.root) |r| {
        try stack.append(gpa, .{ .node = r, .cursor = 0 });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const tag = tree.tagOf(top.node);

            const next_child: ?NodeIndex = switch (tag) {
                .form => blk: {
                    const hdr = tree.formHeader(top.node);
                    if (top.cursor < hdr.children.len) break :blk hdr.children[top.cursor];
                    break :blk null;
                },
                .vector => blk: {
                    const elems = tree.vectorElements(top.node);
                    if (top.cursor < elems.len) break :blk elems[top.cursor];
                    break :blk null;
                },
                .kvpair => blk: {
                    if (top.cursor < 1) {
                        const kvh = tree.kvpairHeader(top.node);
                        break :blk kvh.value;
                    }
                    break :blk null;
                },
                else => null,
            };

            if (next_child) |c| {
                top.cursor += 1;
                try stack.append(gpa, .{ .node = c, .cursor = 0 });
                continue;
            }

            const has_inner: bool = switch (tag) {
                .form => blk: {
                    if (!tree.trailing_comments_index[top.node.raw()].isEmpty()) break :blk true;
                    const hdr = tree.formHeader(top.node);
                    for (hdr.children) |ch| {
                        if (!tree.leading_comments_index[ch.raw()].isEmpty()) break :blk true;
                        if (set[ch.raw()]) break :blk true;
                    }
                    break :blk false;
                },
                .vector => blk: {
                    if (!tree.trailing_comments_index[top.node.raw()].isEmpty()) break :blk true;
                    const elems = tree.vectorElements(top.node);
                    for (elems) |e| {
                        if (!tree.leading_comments_index[e.raw()].isEmpty()) break :blk true;
                        if (set[e.raw()]) break :blk true;
                    }
                    break :blk false;
                },
                .kvpair => blk: {
                    const kvh = tree.kvpairHeader(top.node);
                    if (!tree.leading_comments_index[kvh.value.raw()].isEmpty()) break :blk true;
                    if (set[kvh.value.raw()]) break :blk true;
                    break :blk false;
                },
                else => false,
            };
            if (has_inner) set[top.node.raw()] = true;
            _ = stack.pop();
        }
    }
}

// ---------------------------------------------------------------------------
// Atom writers — print and length must agree on output bytes.
// ---------------------------------------------------------------------------

fn formatNumberInto(buf: []u8, x: f64) []const u8 {
    if (std.math.isNan(x)) return "nan";
    if (std.math.isInf(x)) return if (x > 0) "inf" else "-inf";
    // 2^53 — the f64 exact-integer ceiling, here for integer-elision on
    // canonical output. `Json.numberToJson` holds the twin copy; `Expr`
    // has its own (`TWO_53`, hash normalization) and `SchemaExport` its
    // own (`Model.F64_PRECISE_INT_CEILING`, precision-loss warnings).
    // Deliberately unshared — each is pinned by its own corpus.
    const safe_int_max: f64 = @floatFromInt(@as(i64, 1) << 53);
    if (@floor(x) == x and @abs(x) < safe_int_max) {
        const i: i64 = @intFromFloat(x);
        return std.fmt.bufPrint(buf, "{d}", .{i}) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "{d}", .{x}) catch unreachable;
}

fn writeNumber(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    x: f64,
) Allocator.Error!void {
    var buf: [64]u8 = undefined;
    const s = formatNumberInto(&buf, x);
    try out.appendSlice(gpa, s);
}

fn numberLen(x: f64) u32 {
    var buf: [64]u8 = undefined;
    return @intCast(formatNumberInto(&buf, x).len);
}

/// Tag-aware number formatter. `.number` uses the legacy f64 formatter
/// (2^53-guarded integer-elision). `.number_i64` and `.number_u64`
/// print the exact decimal — no 2^53 guard needed, the source bytes
/// survive parse → AST → print round-trip.
fn formatNumberFromTreeInto(buf: []u8, tree: *const Ast.Tree, idx: NodeIndex) []const u8 {
    return switch (tree.tagOf(idx)) {
        .number => formatNumberInto(buf, tree.numberOf(idx)),
        .number_i64 => std.fmt.bufPrint(buf, "{d}", .{tree.numberI64Of(idx)}) catch unreachable,
        .number_u64 => std.fmt.bufPrint(buf, "{d}", .{tree.numberU64Of(idx)}) catch unreachable,
        else => unreachable,
    };
}

fn writeNumberFromTree(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    tree: *const Ast.Tree,
    idx: NodeIndex,
) Allocator.Error!void {
    var buf: [64]u8 = undefined;
    const s = formatNumberFromTreeInto(&buf, tree, idx);
    try out.appendSlice(gpa, s);
}

fn numberLenFromTree(tree: *const Ast.Tree, idx: NodeIndex) u32 {
    var buf: [64]u8 = undefined;
    return @intCast(formatNumberFromTreeInto(&buf, tree, idx).len);
}

fn writeString(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    s: []const u8,
) Allocator.Error!void {
    try StringEscape.appendQuoted(out, gpa, s);
}

fn stringLen(s: []const u8) u32 {
    return StringEscape.quotedLen(s);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Parser = @import("Parser.zig");

fn printSource(source: [:0]const u8) !Ast.Bytes {
    var tree = try Parser.parse(testing.allocator, source);
    defer tree.deinit();
    return try print(testing.allocator, tree, .{});
}

fn printSourceOpts(source: [:0]const u8, opts: Options) !Ast.Bytes {
    var tree = try Parser.parse(testing.allocator, source);
    defer tree.deinit();
    return try print(testing.allocator, tree, opts);
}

fn expectPrint(source: [:0]const u8, expected: []const u8) !void {
    const got = try printSource(source);
    defer got.deinit();
    try testing.expectEqualStrings(expected, got.data);
}

fn expectPrintOpts(source: [:0]const u8, opts: Options, expected: []const u8) !void {
    const got = try printSourceOpts(source, opts);
    defer got.deinit();
    try testing.expectEqualStrings(expected, got.data);
}

test "atoms: number, integer-valued, negative, float" {
    try expectPrint("42", "42\n");
    try expectPrint("-7", "-7\n");
    try expectPrint("3.5", "3.5\n");
    try expectPrint("0", "0\n");
}

test "atoms: string is requoted with escapes" {
    try expectPrint(
        \\"hi\nthere"
    , "\"hi\\nthere\"\n");
}

test "atoms: keyword, symbol, boolean, nil" {
    try expectPrint(":foo", ":foo\n");
    try expectPrint("+", "+\n");
    try expectPrint("true", "true\n");
    try expectPrint("false", "false\n");
    try expectPrint("nil", "nil\n");
}

test "compact form on one line" {
    try expectPrint("(scene :bpm 130)", "(scene :bpm 130)\n");
}

test "compact form with positional flag" {
    try expectPrint("(camera :ortho :zoom 2)", "(camera :ortho :zoom 2)\n");
}

test "compact vector" {
    try expectPrint("[1 2 3]", "[1 2 3]\n");
}

test "compact form with namespace" {
    try expectPrint("(masagin/verb :ops 1)", "(masagin/verb :ops 1)\n");
}

test "canonical prints unit-suffixed numbers" {
    try expectPrint("90deg", "90deg\n");
    try expectPrint("0.5em", "0.5em\n");
    try expectPrint("-50%", "-50%\n");
    try expectPrint("250ms", "250ms\n");
    try expectPrint("4b", "4b\n");
}

test "unit numbers round-trip through canonical print" {
    try expectPrint(
        "(scene :angle 90deg :z 0.5em -50%)",
        "(scene :angle 90deg :z 0.5em -50%)\n",
    );
    try expectPrint(
        "[4b 90deg 50% 250ms]",
        "[4b 90deg 50% 250ms]\n",
    );
}

test "exponent + unit round-trips" {
    // `1.5e2hz` should re-lex back to (150, "hz") after canonical print.
    // The canonical formatter prints `150` for safe integers, so the
    // round-trip lands at "150hz" (semantically equivalent).
    try expectPrint("1.5e2hz", "150hz\n");
}

test "lossless preserves leading line comment on unit number" {
    const got = try printSourceOpts(
        \\; angle
        \\90deg
    , .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings(
        \\; angle
        \\90deg
        \\
    , got.data);
}

test "lossless preserves comment on KP whose value is a unit number" {
    const got = try printSourceOpts(
        \\(scene
        \\  ; tempo
        \\  :bpm 130hz)
    , .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings(
        \\(scene
        \\  ; tempo
        \\  :bpm 130hz)
        \\
    , got.data);
}

test "lossless idempotence with unit numbers under reparse" {
    // Reprint of a printed tree must be byte-equal: pin idempotence on
    // a representative input that hits every unit shape.
    const src =
        \\(scene
        \\  :angle 90deg
        \\  :z 0.5em
        \\  :delay 250ms
        \\  -50%
        \\  [4b 90deg 50% 250ms])
    ;
    const once = try printSourceOpts(src, .{ .mode = .full });
    defer once.deinit();
    const once_z = try testing.allocator.dupeZ(u8, once.data);
    defer testing.allocator.free(once_z);
    const twice = try printSourceOpts(once_z, .{ .mode = .full });
    defer twice.deinit();
    try testing.expectEqualStrings(once.data, twice.data);
}

test "canonical wraps long form with unit-bearing keyword pairs" {
    // The wrapper applies regardless of unit; pin that unit numbers
    // inside KPs do not foul up the layout calculation.
    try expectPrintOpts("(scene :angle 90deg :z 0.5em :delay 250ms)", .{ .wrap_at = 24 },
        \\(scene
        \\  :angle 90deg
        \\  :z 0.5em
        \\  :delay 250ms)
        \\
    );
}

test "vector of unit numbers wraps at narrow width" {
    try expectPrintOpts("[4b 90deg 50% 250ms]", .{ .wrap_at = 12 },
        \\[
        \\  4b
        \\  90deg
        \\  50%
        \\  250ms]
        \\
    );
}

test "print canonical output for unit number is byte-equal to source" {
    // Pure SoA path: parse → print is canonical-byte-equal for
    // a canonical input.
    const src = "(scene :angle 90deg)";
    var tree2 = try Parser.parse(testing.allocator, src);
    defer tree2.deinit();
    const got = try print(testing.allocator, tree2, .{});
    defer got.deinit();
    try testing.expectEqualStrings("(scene :angle 90deg)\n", got.data);
}

test "short nested form fits inline at default width" {
    // Both fit comfortably under wrap_at=60.
    try expectPrint("(scene (canvas))", "(scene (canvas))\n");
    try expectPrint("[[0 0] [1 0] [1 1]]", "[[0 0] [1 0] [1 1]]\n");
    try expectPrint(
        "(shape :delay (delay :p+s (b 4)))",
        "(shape :delay (delay :p+s (b 4)))\n",
    );
}

test "long form breaks at narrow wrap_at" {
    try expectPrintOpts("(scene (canvas))", .{ .wrap_at = 8 },
        \\(scene
        \\  (canvas))
        \\
    );
}

test "long form keeps short children inline at narrow wrap_at" {
    // The outer `(shape …)` is 33 bytes single-line; the inner
    // `(delay :p+s (b 4))` is 18. With wrap_at = 20 only the outer breaks.
    try expectPrintOpts("(shape :delay (delay :p+s (b 4)))", .{ .wrap_at = 20 },
        \\(shape
        \\  :delay (delay :p+s (b 4)))
        \\
    );
}

test "vector of vectors breaks when over budget" {
    try expectPrintOpts("[[0 0] [1 0] [1 1]]", .{ .wrap_at = 10 },
        \\[
        \\  [0 0]
        \\  [1 0]
        \\  [1 1]]
        \\
    );
}

test "multiple top-level forms separated by newline" {
    try expectPrint("1 2 3", "1\n2\n3\n");
}

test "empty form stays single-line" {
    try expectPrint("(canvas)", "(canvas)\n");
}

test "indent option respected with narrow wrap_at" {
    try expectPrintOpts("(scene (canvas))", .{ .indent = 4, .wrap_at = 8 },
        \\(scene
        \\    (canvas))
        \\
    );
}

test "scene fixture: canonical layout matches expected" {
    // Note the parser's greedy keyword pairing: in the input
    // `(stack :mode :mask (shape …) (shape …))`, `:mode` becomes a
    // positional flag (because another `:kw` follows it), and `:mask`
    // pairs with the following `(shape …)` form. So the canonical
    // layout shows `:mask` on the same line as the `(shape` it owns.
    const src =
        \\(scene :bpm 130
        \\  (canvas :name "main"
        \\    (camera :ortho :zoom (* 2 (b 1)))
        \\    (stack :mode :mask
        \\      (shape :sdf :radius 0.5
        \\        :delay (delay :p+s (b 4))
        \\        :lifespan (b 16))
        \\      (shape :path :points [[0 0] [1 0] [1 1]]))))
    ;
    const expected =
        \\(scene
        \\  :bpm 130
        \\  (canvas
        \\    :name "main"
        \\    (camera :ortho :zoom (* 2 (b 1)))
        \\    (stack
        \\      :mode
        \\      :mask (shape
        \\        :sdf
        \\        :radius 0.5
        \\        :delay (delay :p+s (b 4))
        \\        :lifespan (b 16))
        \\      (shape :path :points [[0 0] [1 0] [1 1]]))))
        \\
    ;
    const got = try printSource(src);
    defer got.deinit();
    try testing.expectEqualStrings(expected, got.data);
}

test "scene fixture canonical print is idempotent" {
    // Verify that print(parse(s)) is stable: re-parsing and re-printing
    // produces the same bytes.
    const src =
        \\(scene :bpm 130
        \\  (canvas :name "main"
        \\    (camera :ortho :zoom (* 2 (b 1)))
        \\    (stack :mode :mask
        \\      (shape :sdf :radius 0.5
        \\        :delay (delay :p+s (b 4))
        \\        :lifespan (b 16))
        \\      (shape :path :points [[0 0] [1 0] [1 1]]))))
    ;
    const once = try printSource(src);
    defer once.deinit();

    const once_z = try testing.allocator.dupeZ(u8, once.data);
    defer testing.allocator.free(once_z);

    const twice = try printSource(once_z);
    defer twice.deinit();

    try testing.expectEqualStrings(once.data, twice.data);
}

test "canonical drops comments" {
    const got = try printSourceOpts(
        \\; preamble
        \\(scene :bpm 130)
    , .{ .mode = .canonical });
    defer got.deinit();
    try testing.expectEqualStrings("(scene :bpm 130)\n", got.data);
}

test "lossless preserves leading line comment on top-level node" {
    const got = try printSourceOpts(
        \\; preamble
        \\(scene :bpm 130)
    , .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings(
        \\; preamble
        \\(scene :bpm 130)
        \\
    , got.data);
}

test "lossless preserves head-position comment after open paren" {
    // A comment between `(` and the head symbol was silently dropped by
    // `nextSignificant`. It now leads the form node (printed before `(`).
    const got = try printSourceOpts(
        \\(; note
        \\foo 1)
    , .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings(
        \\; note
        \\(foo 1)
        \\
    , got.data);
}

test "lossless preserves comment inside form forcing multi-line" {
    const got = try printSourceOpts(
        \\(scene
        \\  ; tempo
        \\  :bpm 130)
    , .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings(
        \\(scene
        \\  ; tempo
        \\  :bpm 130)
        \\
    , got.data);
}

test "lossless: comment forces ancestor multi-line even when short" {
    // Without comments, `(a (b))` fits on one line. The inner comment
    // forces both forms to break.
    const got = try printSourceOpts(
        \\(a (b
        \\  ; here
        \\  1))
    , .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings(
        \\(a
        \\  (b
        \\    ; here
        \\    1))
        \\
    , got.data);
}

test "lossless preserves block comment" {
    const got = try printSourceOpts(
        \\(scene
        \\  #| explain |#
        \\  :bpm 130)
    , .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings(
        \\(scene
        \\  #| explain |#
        \\  :bpm 130)
        \\
    , got.data);
}

test "lossless preserves trailing comment inside form" {
    const got = try printSourceOpts(
        \\(scene 1 ; trail
        \\)
    , .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings(
        \\(scene
        \\  1
        \\  ; trail
        \\  )
        \\
    , got.data);
}

test "lossless preserves trailing comment inside vector" {
    // A trailing comment before `]` was dropped: finalizeFrame's vector
    // arm ignored the drained comments. It now attaches like the form path,
    // forcing the vector multi-line so the line comment can sit on its own row.
    const got = try printSourceOpts(
        \\[1 2 ; c
        \\]
    , .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings(
        \\[
        \\  1
        \\  2
        \\  ; c
        \\  ]
        \\
    , got.data);
}

test "lossless preserves trailing comment after final form" {
    const got = try printSourceOpts(
        \\42
        \\; bye
    , .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings(
        \\42
        \\; bye
        \\
    , got.data);
}

test "lossless print is idempotent through reparse" {
    const src =
        \\; greeting
        \\(scene
        \\  ; tempo
        \\  :bpm 130
        \\  ; about to declare canvas
        \\  (canvas :name "main"))
        \\; bye
    ;
    const once = try printSourceOpts(src, .{ .mode = .full });
    defer once.deinit();

    const once_z = try testing.allocator.dupeZ(u8, once.data);
    defer testing.allocator.free(once_z);

    const twice = try printSourceOpts(once_z, .{ .mode = .full });
    defer twice.deinit();
    try testing.expectEqualStrings(once.data, twice.data);
}

test "lossless: comment before flag positional" {
    const got = try printSourceOpts(
        \\(camera
        \\  ; pick projection
        \\  :ortho :zoom 2)
    , .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings(
        \\(camera
        \\  ; pick projection
        \\  :ortho
        \\  :zoom 2)
        \\
    , got.data);
}

// ---------------------------------------------------------------------------
// Tree-direct print tests — verify that parse → print produces the
// same bytes as parse → print (which itself bridges through Tree).
// ---------------------------------------------------------------------------

test "print: lossless output matches canonical-mode parsing" {
    // Sanity check: lossless mode preserves comments inline.
    const sources = [_][:0]const u8{
        "; preamble\n(scene :bpm 130)",
        "(scene\n  ; tempo\n  :bpm 130)",
        "(camera\n  ; pick projection\n  :ortho :zoom 2)",
        "42\n; bye",
    };
    for (sources) |src| {
        var tree2 = try Parser.parse(testing.allocator, src);
        defer tree2.deinit();
        const out = try print(testing.allocator, tree2, .{ .mode = .full });
        defer out.deinit();
        try testing.expect(out.data.len > 0);
    }
}

// ---------------------------------------------------------------------------
// Long-tail printer tests — empty trees, every escape, indent / wrap_at
// extremes, floating-point edge values, and round-trip stability under
// each mode. Pinned alongside the layout tests above.
// ---------------------------------------------------------------------------

test "empty tree prints to empty buffer" {
    // No roots, no trailing comments → no bytes (not even a trailing
    // newline). Printer is lossless on the empty case.
    const empty: [:0]const u8 = "";
    var tree = try Parser.parse(testing.allocator, empty);
    defer tree.deinit();
    const got = try print(testing.allocator, tree, .{});
    defer got.deinit();
    try testing.expectEqualStrings("", got.data);
}

test "tree-trailing-only input round-trips its comments in lossless" {
    const src: [:0]const u8 = "; only a comment";
    const got = try printSourceOpts(src, .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings("; only a comment\n", got.data);
}

test "string: every escape rendered correctly" {
    // Pin every byte the writer treats specially. The decoded source has
    // the runtime bytes; the printer must re-escape each one.
    const src =
        \\"a\nb\tc\rd\\e\"f\0g"
    ;
    try expectPrint(src, "\"a\\nb\\tc\\rd\\\\e\\\"f\\0g\"\n");
}

test "string: empty literal prints as `\"\"`" {
    try expectPrint("\"\"", "\"\"\n");
}

test "string: long content does not affect length pre-pass byte budget" {
    // ~67-byte content (60 `x`s + `\"end`) on a string atom. The printer
    // must size the buffer correctly via stringLen (no truncation, no
    // overrun) — the requoted output preserves the embedded quote escape.
    const long_src = "\"" ++ ("x" ** 60) ++ "\\\"end\"";
    try expectPrint(long_src, "\"" ++ ("x" ** 60) ++ "\\\"end\"\n");
}

test "number: integer-valued floats elide decimals" {
    // safe_int_max guard: integer-valued doubles up to 2^53 should print
    // without `.0`. Beyond it falls back to fmt's float formatting.
    try expectPrint("100", "100\n");
    try expectPrint("1000000", "1000000\n");
    try expectPrint("-12345", "-12345\n");
}

test "number: very small fractional prints with float syntax" {
    try expectPrint("0.001", "0.001\n");
}

test "number: zero prints as `0`, not `0.0`" {
    try expectPrint("0", "0\n");
    try expectPrint("0.0", "0\n");
}

test "number: i64.max round-trips exactly through print" {
    try expectPrint("9223372036854775807", "9223372036854775807\n");
}

test "number: i64.min round-trips exactly through print" {
    try expectPrint("-9223372036854775808", "-9223372036854775808\n");
}

test "number: u64.max round-trips exactly through print" {
    try expectPrint("18446744073709551615", "18446744073709551615\n");
}

test "number: 2^54 prints as exact integer (number_i64 path skips 2^53 guard)" {
    try expectPrint("18014398509481984", "18014398509481984\n");
}

test "wrap_at = 0 forces every form to break" {
    // Aggressive: even a 6-byte form must break when wrap_at is 0.
    try expectPrintOpts("(a b)", .{ .wrap_at = 0 },
        \\(a
        \\  b)
        \\
    );
}

test "wrap_at = max forces single-line for any reasonable input" {
    // Soft budget set absurdly high — the wrapper never trips.
    try expectPrintOpts(
        "(scene :bpm 130 (canvas :name \"main\" [1 2 3]))",
        .{ .wrap_at = std.math.maxInt(u16) },
        "(scene :bpm 130 (canvas :name \"main\" [1 2 3]))\n",
    );
}

test "indent = 0 still produces correct multi-line layout" {
    // Zero indent means children sit at column 0 on subsequent lines.
    // Pin: the printer doesn't crash and emits readable (if cramped) output.
    try expectPrintOpts("(a b c d e f g h i j k l m n)", .{ .indent = 0, .wrap_at = 8 },
        \\(a
        \\b
        \\c
        \\d
        \\e
        \\f
        \\g
        \\h
        \\i
        \\j
        \\k
        \\l
        \\m
        \\n)
        \\
    );
}

test "indent = 8 widens each level by 8 spaces" {
    try expectPrintOpts("(scene (canvas))", .{ .indent = 8, .wrap_at = 8 },
        \\(scene
        \\        (canvas))
        \\
    );
}

test "indent = 16 (max documented) doesn't trip an assert" {
    // root.zig asserts opts.indent <= 16. Pin the upper bound here.
    try expectPrintOpts("(scene (canvas))", .{ .indent = 16, .wrap_at = 8 },
        \\(scene
        \\                (canvas))
        \\
    );
}

test "single-atom roots print one per line in canonical mode" {
    try expectPrint("1 2 3", "1\n2\n3\n");
    try expectPrint("nil true false", "nil\ntrue\nfalse\n");
    try expectPrint(":foo :bar :baz", ":foo\n:bar\n:baz\n");
}

test "deeply nested form fits on one line if budget allows" {
    // Five levels deep — still under default wrap_at=60.
    try expectPrint(
        "(a (b (c (d (e)))))",
        "(a (b (c (d (e)))))\n",
    );
}

test "empty inner vector inside form stays inline" {
    try expectPrint("(scene [])", "(scene [])\n");
}

test "vector containing only kwargs flattens (k+v as elements)" {
    // Vectors don't pair: every keyword stays a positional element, and
    // values follow. Pin the canonical layout matches the parsed shape.
    try expectPrint("[:foo 1 :bar 2]", "[:foo 1 :bar 2]\n");
}

test "qualified head with breaking children retains namespace" {
    try expectPrintOpts("(masagin/verb :a 1 :b 2 :c 3)", .{ .wrap_at = 16 },
        \\(masagin/verb
        \\  :a 1
        \\  :b 2
        \\  :c 3)
        \\
    );
}

test "compact alias matches canonical mode byte-for-byte" {
    // .compact aliases .canonical per the file header. Pin by parity.
    const src = "(scene :bpm 130 (canvas :name \"main\" [1 2 3]))";
    const a = try printSourceOpts(src, .{ .mode = .canonical });
    defer a.deinit();
    const b = try printSourceOpts(src, .{ .mode = .compact });
    defer b.deinit();
    try testing.expectEqualStrings(a.data, b.data);
}

test "round-trip is stable across modes for canonical input" {
    // Canonical input parsed and printed in each mode must reach a fixed
    // point on the next print. Pin: the printer is idempotent.
    const src = "(scene :bpm 130 (canvas :name \"main\" [1 2 3]))";
    inline for (&[_]Ast.Mode{ .canonical, .compact, .full }) |mode| {
        const once = try printSourceOpts(src, .{ .mode = mode });
        defer once.deinit();
        const once_z = try testing.allocator.dupeZ(u8, once.data);
        defer testing.allocator.free(once_z);
        const twice = try printSourceOpts(once_z, .{ .mode = mode });
        defer twice.deinit();
        try testing.expectEqualStrings(once.data, twice.data);
    }
}

test "lossless: multiple comments between siblings each on own line" {
    const got = try printSourceOpts(
        \\(scene
        \\  ; one
        \\  ; two
        \\  ; three
        \\  :bpm 130)
    , .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings(
        \\(scene
        \\  ; one
        \\  ; two
        \\  ; three
        \\  :bpm 130)
        \\
    , got.data);
}

test "lossless: comment tree-trailing after multi-root inputs" {
    const got = try printSourceOpts(
        \\1
        \\2
        \\3
        \\; goodbye
    , .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings(
        \\1
        \\2
        \\3
        \\; goodbye
        \\
    , got.data);
}

test "string with embedded null byte requotes as `\\0`" {
    // The decoder expands `\0` to NUL; the printer must re-escape it.
    // Pin: round trip leaves the source byte-equal modulo trailing \n.
    const src: [:0]const u8 = "\"a\\0b\"";
    try expectPrint(src, "\"a\\0b\"\n");
}

test "stringLen and writeString agree on output size (sanity)" {
    // Probe the length pre-pass: numberLen / stringLen / etc must equal
    // the length writeNumber / writeString actually emit. Pin via direct
    // call.
    const cases = [_][]const u8{
        "",
        "plain",
        "with\nnewline",
        "\"quoted\"",
        "back\\slash",
        "tab\there",
        "null\x00byte",
        "all: \" \\ \n \t \r \x00",
    };
    for (cases) |s| {
        const expected_len = stringLen(s);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try writeString(testing.allocator, &out, s);
        try testing.expectEqual(expected_len, @as(u32, @intCast(out.items.len)));
    }
}

test "numberLen and writeNumber agree on output size (sanity)" {
    const cases = [_]f64{ 0, 1, -1, 42, -1234, 3.14, -0.001, 1e9, 1e-9 };
    for (cases) |x| {
        const expected_len = numberLen(x);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try writeNumber(testing.allocator, &out, x);
        try testing.expectEqual(expected_len, @as(u32, @intCast(out.items.len)));
    }
}

test "numberLenFromTree and writeNumberFromTree agree across all number tags" {
    // The length pre-pass must equal the byte count of the actual write
    // for every number-shape tag. A divergence here silently misaligns
    // the wrap-budget arithmetic.
    const sources = [_][:0]const u8{
        "0",
        "42",
        "-12345",
        "3.14",
        "1e9",
        "9223372036854775807",
        "-9223372036854775808",
        "18446744073709551615",
    };
    inline for (sources) |src| {
        var tree = try Parser.parse(testing.allocator, src);
        defer tree.deinit();
        const idx = tree.root[0];
        const expected_len = numberLenFromTree(&tree, idx);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try writeNumberFromTree(testing.allocator, &out, &tree, idx);
        try testing.expectEqual(expected_len, @as(u32, @intCast(out.items.len)));
    }
}

test "wrap_at exactly equal to single-line length keeps inline" {
    // Boundary: `(a b c)` is 7 bytes; wrap_at=7 should still keep it
    // single-line (≤ wrap_at, not <).
    try expectPrintOpts("(a b c)", .{ .wrap_at = 7 }, "(a b c)\n");
}

test "wrap_at one less than single-line length forces break" {
    try expectPrintOpts("(a b c)", .{ .wrap_at = 6 },
        \\(a
        \\  b
        \\  c)
        \\
    );
}

test "round-trip stable at wrap_at extremes (0 and maxInt)" {
    // Pin idempotency at both layout extremes: print(parse(s)) must
    // reach a fixed point on the next pass regardless of width budget.
    const src = "(scene :bpm 130 (canvas :name \"main\" [1 2 3]))";
    inline for (&[_]u16{ 0, std.math.maxInt(u16) }) |wrap_at| {
        const once = try printSourceOpts(src, .{ .wrap_at = wrap_at });
        defer once.deinit();
        const once_z = try testing.allocator.dupeZ(u8, once.data);
        defer testing.allocator.free(once_z);
        const twice = try printSourceOpts(once_z, .{ .wrap_at = wrap_at });
        defer twice.deinit();
        try testing.expectEqualStrings(once.data, twice.data);
    }
}

// ---------------------------------------------------------------------------
// Per-module corner sweep (plan #4): every value-kind atom round-trips
// through `parse → print → parse → print` byte-equal twice; comment
// position immediately after a form head is preserved as the first
// child's leading in lossless mode. Targets the gaps the broader
// canonical-print idempotence test (root.zig) does not assert per-kind.
// ---------------------------------------------------------------------------

test "every value-kind atom: print → parse → print is byte-equal (canonical idempotence)" {
    // One fixture per atomic kind plus two compound kinds. The first
    // print acts as the canonical-mode normaliser (e.g. `1.0e10` →
    // `1e10`, raw `"""..."""` → escaped `"..."`); the second print
    // must equal the first byte-for-byte. Pin so a future printer
    // tweak that introduces non-idempotent formatting (e.g. always
    // appending a comment, or floating between `1.0` and `1`)
    // surfaces immediately.
    const cases = [_][:0]const u8{
        "nil",
        "true",
        "false",
        "0",
        "42",
        "-1",
        "3.14",
        "1.5e10",
        "90deg",
        "50%",
        "1.5e2hz",
        "\"esc\\nape\"",
        "\"\"\"raw body\"\"\"",
        ":kw",
        "+",
        "ns/op",
        "[]",
        "[1 2 3]",
        "()",
        "(form :k 1)",
    };
    inline for (cases) |src| {
        const once = try printSource(src);
        defer once.deinit();
        const once_z = try testing.allocator.dupeZ(u8, once.data);
        defer testing.allocator.free(once_z);
        const twice = try printSource(once_z);
        defer twice.deinit();
        std.testing.expectEqualStrings(once.data, twice.data) catch |err| {
            std.debug.print("\nidempotence break for fixture {s}\n  first:  {s}\n  second: {s}\n", .{ src, once.data, twice.data });
            return err;
        };
    }
}

test "lossless: comment between form head and first child attaches as child's leading" {
    // `(scene ; banner\n :bpm 130)` — the comment sits in the head-span
    // window (after `scene`, before `:bpm`). The parser attaches it as
    // the first child's leading; lossless print must emit it on its
    // own line above `:bpm`. Pin so a refactor that drops head-span
    // comments (or attaches them to the form trailing instead) is
    // caught by a re-parse + re-print fixed-point check.
    const src: [:0]const u8 =
        \\(scene ; banner
        \\  :bpm 130)
    ;
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    const out = try print(testing.allocator, tree, Options{ .mode = .full });
    defer out.deinit();
    try testing.expect(std.mem.indexOf(u8, out.data, "; banner") != null);
    try testing.expect(std.mem.indexOf(u8, out.data, ":bpm 130") != null);

    // Re-parse the lossless output and re-print: must be byte-equal.
    const out_z = try testing.allocator.dupeZ(u8, out.data);
    defer testing.allocator.free(out_z);
    var reparsed = try Parser.parse(testing.allocator, out_z);
    defer reparsed.deinit();
    try testing.expect(!reparsed.hasErrors());
    const out2 = try print(testing.allocator, reparsed, Options{ .mode = .full });
    defer out2.deinit();
    try testing.expectEqualStrings(out.data, out2.data);
}
