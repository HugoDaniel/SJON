const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");

const Tree = Ast.Tree;
const NodeIndex = Ast.NodeIndex;
const Tag = Ast.Tag;
const StringIndex = Ast.StringIndex;

pub const Options = struct {
    mode: Ast.Mode = .canonical,
    indent: u8 = 2,
    wrap_at: u16 = 60,

    pub fn forMode(mode: Ast.Mode) Options {
        return .{ .mode = mode };
    }
};

pub fn print(gpa: Allocator, tree: Tree, opts: Options) Allocator.Error!Ast.Bytes {
    const node_count: u32 = @intCast(tree.nodes.len);

    const lengths = try gpa.alloc(u32, node_count);
    defer gpa.free(lengths);
    @memset(lengths, 0);
    try computeLengths(gpa, &tree, lengths);

    var has_inner: []bool = &.{};
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

const PrintCtx = struct {
    tree: *const Tree,
    lengths: []const u32,
    has_inner_comments: []const bool,
    opts: Options,
};

const Task = union(enum) {
    expand: ExpandNode,
    expand_actual: ExpandNode,
    text: []const u8,
    raw_space,
    raw_newline,
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

    try tasks.append(gpa, .{ .text = ")" });

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

    var j: usize = elements.len;
    while (j > 0) : (j -= 1) {
        try tasks.append(gpa, .{ .expand = .{
            .node = elements[j - 1],
            .depth = if (compact) depth else child_depth,
        } });
        if (compact) {
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
    try tasks.append(gpa, .{ .expand = .{ .node = kvh.value, .depth = depth } });
    try tasks.append(gpa, .raw_space);
    try tasks.append(gpa, .{ .text = kvh.key });
    try tasks.append(gpa, .{ .text = ":" });
}

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
                .date => 10,
                .time => @intCast(tree.timeOf(top.node).canonicalLen()),
                .form => blk: {
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
                    var total: u32 = 2;
                    for (elems, 0..) |e, idx| {
                        if (idx > 0) total += 1;
                        total += lengths[e.raw()];
                    }
                    break :blk total;
                },
                .kvpair => blk: {
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

fn formatNumberInto(buf: []u8, x: f64) []const u8 {
    if (std.math.isNan(x)) return "nan";
    if (std.math.isInf(x)) return if (x > 0) "inf" else "-inf";
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
    try out.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            0 => try out.appendSlice(gpa, "\\0"),
            else => try out.append(gpa, c),
        }
    }
    try out.append(gpa, '"');
}

fn stringLen(s: []const u8) u32 {
    var len: u32 = 2;
    for (s) |c| {
        len += switch (c) {
            '"', '\\', '\n', '\r', '\t', 0 => @as(u32, 2),
            else => @as(u32, 1),
        };
    }
    return len;
}

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
