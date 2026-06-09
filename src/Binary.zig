const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Date = @import("Date.zig");
const Time = @import("Time.zig");

pub const wire_version: u8 = 0x04;

pub const wire_magic: [4]u8 = .{ 'S', 'J', '1', '\n' };

pub const HEADER_SIZE: u32 = 16;

pub const MAX_TREE_DEPTH: u32 = 1024;

comptime {
    if (MAX_TREE_DEPTH < @import("Parser.zig").MAX_PARSE_DEPTH)
        @compileError("Binary.MAX_TREE_DEPTH must be >= Parser.MAX_PARSE_DEPTH");
}

pub const MAX_NODES: u32 = 1 << 20;

pub const MAX_STRING_POOL_ENTRIES: u32 = 1 << 16;

pub const MAX_STRING_LENGTH: u32 = 1 << 20;

pub const MAX_COMMENTS_PER_NODE: u32 = 256;

pub const MAX_COMMENT_TEXT_LENGTH: u32 = 1 << 16;

pub const MAX_FILE_SIZE: u32 = 1 << 28;

pub const Tag = enum(u8) {
    nil = 0x00,
    bool_false = 0x01,
    bool_true = 0x02,
    number = 0x03,
    string = 0x04,
    keyword = 0x05,
    symbol = 0x06,
    vector = 0x07,
    form_bare = 0x08,
    form_qualified = 0x09,
    number_with_unit = 0x0A,
    number_i64 = 0x0B,
    number_u64 = 0x0C,
    date = 0x0D,
    time = 0x0E,
    _,

    pub fn toValueKind(self: Tag) Ast.ValueKind {
        return switch (self) {
            .nil => .nil,
            .bool_false, .bool_true => .boolean,
            .number, .number_i64, .number_u64 => .number,
            .number_with_unit => .number_with_unit,
            .date => .date,
            .time => .time,
            .string => .string,
            .keyword => .keyword,
            .symbol => .symbol,
            .vector => .vector,
            .form_bare, .form_qualified => .form,
            _ => unreachable,
        };
    }

    pub fn fromAst(ast_tag: Ast.Tag, has_namespace: bool) Tag {
        return switch (ast_tag) {
            .nil => .nil,
            .boolean_true => .bool_true,
            .boolean_false => .bool_false,
            .number => .number,
            .number_i64 => .number_i64,
            .number_u64 => .number_u64,
            .number_with_unit => .number_with_unit,
            .date => .date,
            .time => .time,
            .string => .string,
            .keyword => .keyword,
            .symbol => .symbol,
            .vector => .vector,
            .form => if (has_namespace) .form_qualified else .form_bare,
            .kvpair => unreachable,
        };
    }
};

pub const ChildTag = enum(u8) {
    positional = 0x10,
    keyword = 0x11,
    _,
};

pub const Flag = struct {
    pub const with_spans: u8 = 1 << 0;
    pub const with_head_spans: u8 = 1 << 1;
    pub const with_kvpair_key_spans: u8 = 1 << 2;
    pub const with_node_comments: u8 = 1 << 3;
    pub const with_kvpair_comments: u8 = 1 << 4;
    pub const with_tree_trailing_comments: u8 = 1 << 5;
    pub const reserved_mask: u8 = 0xC0;
};

comptime {
    std.debug.assert(HEADER_SIZE == 16);
    std.debug.assert(wire_magic.len == 4);
    std.debug.assert(@sizeOf(@TypeOf(wire_version)) == 1);

    std.debug.assert(@sizeOf(Tag) == 1);
    std.debug.assert(@sizeOf(ChildTag) == 1);

    const known: u8 = Flag.with_spans | Flag.with_head_spans |
        Flag.with_kvpair_key_spans | Flag.with_node_comments |
        Flag.with_kvpair_comments | Flag.with_tree_trailing_comments;
    std.debug.assert((known & Flag.reserved_mask) == 0);
    std.debug.assert((known | Flag.reserved_mask) == 0xFF);
}

pub const Error = error{
    OutOfMemory,
    InvalidMagic,
    InvalidVersion,
    InvalidFlags,
    InvalidTag,
    InvalidNamespace,
    Truncated,
    DepthExceeded,
    PoolIndexOutOfRange,
    NodeCountExceeded,
    StringTooLong,
    CommentTooLong,
};

pub const ToBinaryOptions = struct {
    with_spans: bool = true,
    with_head_spans: bool = true,
    with_kvpair_key_spans: bool = true,
    with_node_comments: bool = false,
    with_kvpair_comments: bool = false,
    with_tree_trailing_comments: bool = false,

    pub fn forMode(mode: Ast.Mode) ToBinaryOptions {
        return switch (mode) {
            .canonical => .{},
            .compact => .{
                .with_spans = false,
                .with_head_spans = false,
                .with_kvpair_key_spans = false,
            },
            .full => .{
                .with_spans = true,
                .with_head_spans = true,
                .with_kvpair_key_spans = true,
                .with_node_comments = true,
                .with_kvpair_comments = true,
                .with_tree_trailing_comments = true,
            },
        };
    }

    pub fn flags(self: ToBinaryOptions) u8 {
        var v: u8 = 0;
        if (self.with_spans) v |= Flag.with_spans;
        if (self.with_head_spans) v |= Flag.with_head_spans;
        if (self.with_kvpair_key_spans) v |= Flag.with_kvpair_key_spans;
        if (self.with_node_comments) v |= Flag.with_node_comments;
        if (self.with_kvpair_comments) v |= Flag.with_kvpair_comments;
        if (self.with_tree_trailing_comments) v |= Flag.with_tree_trailing_comments;
        return v;
    }

    pub fn anyCommentsFlag(self: ToBinaryOptions) bool {
        return self.with_node_comments or self.with_kvpair_comments or self.with_tree_trailing_comments;
    }
};

pub const FromBinaryOptions = struct {
    allow_unknown_versions: bool = false,
};

pub const FlagSet = struct {
    with_spans: bool,
    with_head_spans: bool,
    with_kvpair_key_spans: bool,
    with_node_comments: bool,
    with_kvpair_comments: bool,
    with_tree_trailing_comments: bool,

    pub fn fromByte(b: u8) Error!FlagSet {
        if ((b & Flag.reserved_mask) != 0) return error.InvalidFlags;
        return .{
            .with_spans = (b & Flag.with_spans) != 0,
            .with_head_spans = (b & Flag.with_head_spans) != 0,
            .with_kvpair_key_spans = (b & Flag.with_kvpair_key_spans) != 0,
            .with_node_comments = (b & Flag.with_node_comments) != 0,
            .with_kvpair_comments = (b & Flag.with_kvpair_comments) != 0,
            .with_tree_trailing_comments = (b & Flag.with_tree_trailing_comments) != 0,
        };
    }

    pub fn anyComments(self: FlagSet) bool {
        return self.with_node_comments or self.with_kvpair_comments or self.with_tree_trailing_comments;
    }
};

pub fn toBinary(gpa: Allocator, tree2: Ast.Tree, opts: ToBinaryOptions) Error!Ast.Bytes {
    std.debug.assert(tree2.root.len <= MAX_NODES);
    std.debug.assert((opts.flags() & Flag.reserved_mask) == 0);

    var pool_arena = std.heap.ArenaAllocator.init(gpa);
    defer pool_arena.deinit();
    const a = pool_arena.allocator();

    var string_pool: PoolBuilder = .{};
    var comment_pool: PoolBuilder = .{};

    try collectStrings(a, tree2, opts, &string_pool, &comment_pool);
    try string_pool.finalize(a);
    if (opts.anyCommentsFlag()) try comment_pool.finalize(a);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, &wire_magic);
    try out.append(gpa, wire_version);
    try out.append(gpa, opts.flags());
    try out.appendSlice(gpa, &.{ 0, 0 });
    try out.appendSlice(gpa, &.{ 0, 0, 0, 0 });
    try out.appendSlice(gpa, &.{ 0, 0, 0, 0 });

    const pool_offset: u32 = @intCast(out.items.len);
    try writePool(gpa, &out, string_pool.items.items);
    if (opts.anyCommentsFlag()) try writePool(gpa, &out, comment_pool.items.items);

    const roots_offset: u32 = @intCast(out.items.len);
    try writeVarint(gpa, &out, @intCast(tree2.root.len));
    try emitNodeStream(gpa, &out, tree2, opts, &string_pool, &comment_pool);

    if (opts.with_tree_trailing_comments) {
        try emitCommentsByRange(gpa, &out, tree2, tree2.tree_trailing_comments, opts, &comment_pool);
    }

    if (out.items.len > MAX_FILE_SIZE) return error.NodeCountExceeded;

    std.mem.writeInt(u32, out.items[8..12], pool_offset, .little);
    std.mem.writeInt(u32, out.items[12..16], roots_offset, .little);

    return .{ .gpa = gpa, .data = try out.toOwnedSlice(gpa) };
}

pub fn fromBinary(gpa: Allocator, bytes: []const u8, opts: FromBinaryOptions) Error!Ast.Tree {
    std.debug.assert(bytes.len <= MAX_FILE_SIZE);
    if (bytes.len < HEADER_SIZE) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], &wire_magic)) return error.InvalidMagic;
    const version = bytes[4];
    if (version != wire_version and !opts.allow_unknown_versions) return error.InvalidVersion;
    const flags = try FlagSet.fromByte(bytes[5]);
    if (bytes[6] != 0 or bytes[7] != 0) return error.InvalidFlags;
    const pool_offset = std.mem.readInt(u32, bytes[8..12], .little);
    const roots_offset = std.mem.readInt(u32, bytes[12..16], .little);
    if (pool_offset != HEADER_SIZE) return error.InvalidMagic;
    if (roots_offset > bytes.len or roots_offset < pool_offset) return error.Truncated;

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var pos: u32 = pool_offset;
    const string_pool = try readPool(a, bytes, &pos);
    const comment_pool: PoolView = if (flags.anyComments())
        try readPool(a, bytes, &pos)
    else
        .{ .entries = &.{} };

    if (pos != roots_offset) return error.Truncated;

    const root_count = try readVarint(bytes, &pos);
    if (root_count > MAX_NODES) return error.NodeCountExceeded;

    var builder: Ast.TreeBuilder = .{ .a = a };

    var decoder: Decoder = .{
        .gpa = gpa,
        .bytes = bytes,
        .pos = pos,
        .flags = flags,
        .string_pool = string_pool,
        .comment_pool = comment_pool,
        .builder = &builder,
    };
    defer decoder.deinit();

    const roots = try a.alloc(Ast.NodeIndex, root_count);
    var i: u32 = 0;
    while (i < root_count) : (i += 1) {
        roots[i] = try decoder.readOneNode(0);
    }

    const tree_trailing: Ast.CommentRange = if (flags.with_tree_trailing_comments)
        try decoder.readCommentsListAsRange()
    else
        .empty;

    if (builder.string_index.items.len == 0) {
        try builder.string_index.append(a, 0);
    }

    return Ast.Tree{
        .arena = arena,
        .source = "",
        .nodes = builder.nodes.toOwnedSlice(),
        .extra_data = builder.extra_data.items,
        .strings = builder.strings.items,
        .string_index = builder.string_index.items,
        .root = roots,
        .leading_comments_index = builder.leading_index.items,
        .trailing_comments_index = builder.trailing_index.items,
        .comments = builder.comments.toOwnedSlice(),
        .tree_trailing_comments = tree_trailing,
        .diagnostics = &.{},
    };
}

pub fn writeVarint(gpa: Allocator, out: *std.ArrayList(u8), v: u32) Allocator.Error!void {
    var x: u32 = v;
    while (true) {
        const low: u8 = @intCast(x & 0x7F);
        x >>= 7;
        if (x == 0) {
            try out.append(gpa, low);
            return;
        }
        try out.append(gpa, low | 0x80);
    }
}

pub fn readVarint(bytes: []const u8, pos: *u32) Error!u32 {
    std.debug.assert(pos.* <= bytes.len);
    var result: u64 = 0;
    var shift: u6 = 0;
    var i: u32 = pos.*;
    var byte_count: u32 = 0;
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        byte_count += 1;
        result |= @as(u64, b & 0x7F) << shift;
        if ((b & 0x80) == 0) {
            if (result > std.math.maxInt(u32)) return error.NodeCountExceeded;
            pos.* = i + 1;
            return @intCast(result);
        }
        if (byte_count >= 5) return error.NodeCountExceeded;
        shift += 7;
    }
    return error.Truncated;
}

pub fn varintLen(v: u32) u32 {
    if (v < (@as(u32, 1) << 7)) return 1;
    if (v < (@as(u32, 1) << 14)) return 2;
    if (v < (@as(u32, 1) << 21)) return 3;
    if (v < (@as(u32, 1) << 28)) return 4;
    return 5;
}

const PoolBuilder = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,
    items: std.ArrayList([]const u8) = .empty,
    finalized: bool = false,

    fn add(self: *PoolBuilder, a: Allocator, s: []const u8) Error!void {
        if (s.len > MAX_STRING_LENGTH) return error.StringTooLong;
        if (self.map.contains(s)) return;
        if (self.items.items.len >= MAX_STRING_POOL_ENTRIES) return error.NodeCountExceeded;
        try self.map.put(a, s, @intCast(self.items.items.len));
        try self.items.append(a, s);
    }

    fn finalize(self: *PoolBuilder, a: Allocator) Error!void {
        std.mem.sort([]const u8, self.items.items, {}, lessByLengthThenBytes);
        self.map.clearRetainingCapacity();
        for (self.items.items, 0..) |s, i| {
            try self.map.put(a, s, @intCast(i));
        }
        self.finalized = true;
    }

    fn indexOf(self: *const PoolBuilder, s: []const u8) Error!u32 {
        return self.map.get(s) orelse error.PoolIndexOutOfRange;
    }

    fn lessByLengthThenBytes(_: void, a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return a.len < b.len;
        return std.mem.order(u8, a, b) == .lt;
    }
};

fn writePool(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    items: []const []const u8,
) Error!void {
    var byte_size: u32 = 0;
    for (items) |s| {
        byte_size += varintLen(@intCast(s.len)) + @as(u32, @intCast(s.len));
    }
    try writeVarint(gpa, out, @intCast(items.len));
    try writeVarint(gpa, out, byte_size);
    for (items) |s| {
        try writeVarint(gpa, out, @intCast(s.len));
        try out.appendSlice(gpa, s);
    }
}

fn collectStrings(
    a: Allocator,
    tree: Ast.Tree,
    opts: ToBinaryOptions,
    string_pool: *PoolBuilder,
    comment_pool: *PoolBuilder,
) Error!void {
    var stack: std.ArrayList(Ast.NodeIndex) = .empty;
    defer stack.deinit(a);

    var i: usize = tree.root.len;
    while (i > 0) : (i -= 1) try stack.append(a, tree.root[i - 1]);

    if (opts.with_tree_trailing_comments) {
        try collectCommentRange(a, tree, tree.tree_trailing_comments, comment_pool);
    }

    while (stack.pop()) |idx| {
        if (opts.with_node_comments) {
            try collectCommentRange(a, tree, tree.leading_comments_index[idx.raw()], comment_pool);
        }
        switch (tree.tagOf(idx)) {
            .nil, .boolean_true, .boolean_false, .number => {},
            .number_i64, .number_u64 => {},
            .date => {},
            .time => {},
            .number_with_unit => {
                const nu = tree.numberWithUnitOf(idx);
                try string_pool.add(a, nu.unit);
            },
            .string, .keyword, .symbol => {
                const si: Ast.StringIndex = @enumFromInt(tree.dataOf(idx).single);
                try string_pool.add(a, tree.stringSlice(si));
            },
            .vector => {
                const elements = tree.vectorElements(idx);
                var j: usize = elements.len;
                while (j > 0) : (j -= 1) try stack.append(a, elements[j - 1]);
            },
            .form => {
                const hdr = tree.formHeader(idx);
                if (hdr.namespace) |ns| {
                    if (ns.len == 0) return error.InvalidNamespace;
                    try string_pool.add(a, ns);
                }
                try string_pool.add(a, hdr.head);
                if (opts.with_node_comments) {
                    try collectCommentRange(a, tree, tree.trailing_comments_index[idx.raw()], comment_pool);
                }
                var j: usize = hdr.children.len;
                while (j > 0) : (j -= 1) {
                    const child_idx = hdr.children[j - 1];
                    if (tree.tagOf(child_idx) == .kvpair) {
                        if (opts.with_kvpair_comments) {
                            try collectCommentRange(a, tree, tree.leading_comments_index[child_idx.raw()], comment_pool);
                        }
                        const kp = tree.kvpairHeader(child_idx);
                        try string_pool.add(a, kp.key);
                        try stack.append(a, kp.value);
                    } else {
                        try stack.append(a, child_idx);
                    }
                }
            },
            .kvpair => unreachable,
        }
    }
}

fn collectCommentRange(
    a: Allocator,
    tree: Ast.Tree,
    range: Ast.CommentRange,
    comment_pool: *PoolBuilder,
) Error!void {
    const texts = tree.commentTexts(range);
    for (texts) |t| {
        if (t.len > MAX_COMMENT_TEXT_LENGTH) return error.CommentTooLong;
        try comment_pool.add(a, t);
    }
}

const EmitTask = union(enum) {
    node: NodeEmit,
    child: ChildEmit,
    trailing_comments: TrailingEmit,

    const NodeEmit = struct { idx: Ast.NodeIndex, depth: u32 };
    const ChildEmit = struct { idx: Ast.NodeIndex, depth: u32 };
    const TrailingEmit = struct { range: Ast.CommentRange };
};

fn emitNodeStream(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    tree: Ast.Tree,
    opts: ToBinaryOptions,
    string_pool: *const PoolBuilder,
    comment_pool: *const PoolBuilder,
) Error!void {
    var tasks: std.ArrayList(EmitTask) = .empty;
    defer tasks.deinit(gpa);

    var i: usize = tree.root.len;
    while (i > 0) : (i -= 1) {
        try tasks.append(gpa, .{ .node = .{ .idx = tree.root[i - 1], .depth = 0 } });
    }

    while (tasks.pop()) |task| {
        switch (task) {
            .node => |t| try emitOneNode(gpa, out, tree, t.idx, t.depth, opts, string_pool, comment_pool, &tasks),
            .child => |t| try emitOneChild(gpa, out, tree, t.idx, t.depth, opts, string_pool, comment_pool, &tasks),
            .trailing_comments => |t| try emitCommentsByRange(gpa, out, tree, t.range, opts, comment_pool),
        }
    }
}

fn emitOneNode(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    tree: Ast.Tree,
    idx: Ast.NodeIndex,
    depth: u32,
    opts: ToBinaryOptions,
    string_pool: *const PoolBuilder,
    comment_pool: *const PoolBuilder,
    tasks: *std.ArrayList(EmitTask),
) Error!void {
    if (depth > MAX_TREE_DEPTH) return error.DepthExceeded;

    const ast_tag = tree.tagOf(idx);
    const has_namespace = ast_tag == .form and tree.formHeader(idx).namespace != null;
    const wire_tag = Tag.fromAst(ast_tag, has_namespace);
    try out.append(gpa, @intFromEnum(wire_tag));

    if (opts.with_spans) try writeSpan(gpa, out, tree.spanOf(idx));

    if (opts.with_node_comments) {
        try emitCommentsByRange(gpa, out, tree, tree.leading_comments_index[idx.raw()], opts, comment_pool);
    }

    switch (ast_tag) {
        .nil, .boolean_true, .boolean_false => {},
        .number => try writeF64LE(gpa, out, tree.numberOf(idx)),
        .number_i64 => try writeI64LE(gpa, out, tree.numberI64Of(idx)),
        .number_u64 => try writeU64LE(gpa, out, tree.numberU64Of(idx)),
        .number_with_unit => {
            const nu = tree.numberWithUnitOf(idx);
            try writeF64LE(gpa, out, nu.value);
            try writeVarint(gpa, out, try string_pool.indexOf(nu.unit));
        },
        .date => {
            const d = tree.dateOf(idx);
            const y_bits: u16 = @bitCast(d.year);
            try out.append(gpa, @truncate(y_bits));
            try out.append(gpa, @truncate(y_bits >> 8));
            try out.append(gpa, d.month);
            try out.append(gpa, d.day);
        },
        .time => {
            const t = tree.timeOf(idx);
            try out.append(gpa, t.hour);
            try out.append(gpa, t.minute);
            try out.append(gpa, t.second);
            try out.append(gpa, @truncate(t.millisecond));
            try out.append(gpa, @truncate(t.millisecond >> 8));
        },
        .string, .keyword, .symbol => {
            const si: Ast.StringIndex = @enumFromInt(tree.dataOf(idx).single);
            try writeVarint(gpa, out, try string_pool.indexOf(tree.stringSlice(si)));
        },
        .vector => {
            const elements = tree.vectorElements(idx);
            try writeVarint(gpa, out, @intCast(elements.len));
            var i: usize = elements.len;
            while (i > 0) : (i -= 1) {
                try tasks.append(gpa, .{ .node = .{ .idx = elements[i - 1], .depth = depth + 1 } });
            }
        },
        .form => {
            const hdr = tree.formHeader(idx);
            if (opts.with_head_spans) try writeSpan(gpa, out, hdr.head_span);
            if (hdr.namespace) |ns| {
                if (ns.len == 0) return error.InvalidNamespace;
                try writeVarint(gpa, out, try string_pool.indexOf(ns));
            }
            try writeVarint(gpa, out, try string_pool.indexOf(hdr.head));
            try writeVarint(gpa, out, @intCast(hdr.children.len));

            if (opts.with_node_comments) {
                try tasks.append(gpa, .{ .trailing_comments = .{ .range = tree.trailing_comments_index[idx.raw()] } });
            }
            var i: usize = hdr.children.len;
            while (i > 0) : (i -= 1) {
                try tasks.append(gpa, .{ .child = .{ .idx = hdr.children[i - 1], .depth = depth + 1 } });
            }
        },
        .kvpair => unreachable,
    }
}

fn emitOneChild(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    tree: Ast.Tree,
    idx: Ast.NodeIndex,
    depth: u32,
    opts: ToBinaryOptions,
    string_pool: *const PoolBuilder,
    comment_pool: *const PoolBuilder,
    tasks: *std.ArrayList(EmitTask),
) Error!void {
    if (depth > MAX_TREE_DEPTH) return error.DepthExceeded;
    if (tree.tagOf(idx) == .kvpair) {
        const kp = tree.kvpairHeader(idx);
        try out.append(gpa, @intFromEnum(ChildTag.keyword));
        if (opts.with_kvpair_key_spans) try writeSpan(gpa, out, kp.key_span);
        if (opts.with_kvpair_comments) {
            try emitCommentsByRange(gpa, out, tree, tree.leading_comments_index[idx.raw()], opts, comment_pool);
        }
        try writeVarint(gpa, out, try string_pool.indexOf(kp.key));
        try tasks.append(gpa, .{ .node = .{ .idx = kp.value, .depth = depth } });
    } else {
        try out.append(gpa, @intFromEnum(ChildTag.positional));
        try tasks.append(gpa, .{ .node = .{ .idx = idx, .depth = depth } });
    }
}

fn emitCommentsByRange(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    tree: Ast.Tree,
    range: Ast.CommentRange,
    opts: ToBinaryOptions,
    comment_pool: *const PoolBuilder,
) Error!void {
    const count = range.len();
    if (count > MAX_COMMENTS_PER_NODE) return error.NodeCountExceeded;
    try writeVarint(gpa, out, count);
    if (count == 0) return;
    const spans = tree.commentSpans(range);
    const texts = tree.commentTexts(range);
    const kinds = tree.commentKinds(range);
    for (0..count) |i| {
        try out.append(gpa, switch (kinds[i]) {
            .line => @as(u8, 0),
            .block => @as(u8, 1),
        });
        if (opts.with_spans) try writeSpan(gpa, out, spans[i]);
        try writeVarint(gpa, out, try comment_pool.indexOf(texts[i]));
    }
}

fn writeU32LE(gpa: Allocator, out: *std.ArrayList(u8), v: u32) Error!void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try out.appendSlice(gpa, &buf);
}

fn writeF64LE(gpa: Allocator, out: *std.ArrayList(u8), v: f64) Error!void {
    const bits: u64 = @bitCast(v);
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, bits, .little);
    try out.appendSlice(gpa, &buf);
}

fn writeI64LE(gpa: Allocator, out: *std.ArrayList(u8), v: i64) Error!void {
    const bits: u64 = @bitCast(v);
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, bits, .little);
    try out.appendSlice(gpa, &buf);
}

fn writeU64LE(gpa: Allocator, out: *std.ArrayList(u8), v: u64) Error!void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    try out.appendSlice(gpa, &buf);
}

fn writeSpan(gpa: Allocator, out: *std.ArrayList(u8), span: Ast.Span) Error!void {
    try writeU32LE(gpa, out, span.start);
    try writeU32LE(gpa, out, span.end);
}

const PoolView = struct {
    entries: []const []const u8,

    fn lookup(self: PoolView, idx: u32) Error![]const u8 {
        if (idx >= self.entries.len) return error.PoolIndexOutOfRange;
        return self.entries[idx];
    }
};

fn readPool(
    arena: Allocator,
    bytes: []const u8,
    pos: *u32,
) Error!PoolView {
    const count = try readVarint(bytes, pos);
    if (count > MAX_STRING_POOL_ENTRIES) return error.NodeCountExceeded;
    _ = try readVarint(bytes, pos);
    if (count == 0) return .{ .entries = &.{} };
    const entries = try arena.alloc([]const u8, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const len = try readVarint(bytes, pos);
        if (len > MAX_STRING_LENGTH) return error.StringTooLong;
        if (len > bytes.len - pos.*) return error.Truncated;
        entries[i] = try arena.dupe(u8, bytes[pos.*..][0..len]);
        pos.* += len;
    }
    return .{ .entries = entries };
}

pub fn tagFromByte(b: u8) Error!Tag {
    return switch (b) {
        0x00 => .nil,
        0x01 => .bool_false,
        0x02 => .bool_true,
        0x03 => .number,
        0x04 => .string,
        0x05 => .keyword,
        0x06 => .symbol,
        0x07 => .vector,
        0x08 => .form_bare,
        0x09 => .form_qualified,
        0x0A => .number_with_unit,
        0x0B => .number_i64,
        0x0C => .number_u64,
        0x0D => .date,
        0x0E => .time,
        else => error.InvalidTag,
    };
}

fn childTagFromByte(b: u8) Error!ChildTag {
    return switch (b) {
        0x10 => .positional,
        0x11 => .keyword,
        else => error.InvalidTag,
    };
}

const DecodeTask = union(enum) {
    decode_node: u32,
    decode_child: u32,
    finalize_vector: VectorFin,
    finalize_form: FormFin,
    finalize_positional: void,
    finalize_keyword: KeywordFin,

    const VectorFin = struct {
        count: u32,
        span: Ast.Span,
        leading_range: Ast.CommentRange,
    };
    const FormFin = struct {
        count: u32,
        head_idx: Ast.StringIndex,
        ns_idx: Ast.StringIndex,
        span: Ast.Span,
        head_span: Ast.Span,
        leading_range: Ast.CommentRange,
    };
    const KeywordFin = struct {
        key_idx: Ast.StringIndex,
        key_span: Ast.Span,
        leading_range: Ast.CommentRange,
    };
};

const Decoder = struct {
    gpa: Allocator,
    bytes: []const u8,
    pos: u32,
    flags: FlagSet,
    string_pool: PoolView,
    comment_pool: PoolView,
    builder: *Ast.TreeBuilder,
    tasks: std.ArrayList(DecodeTask) = .empty,
    node_stack: std.ArrayList(Ast.NodeIndex) = .empty,
    child_stack: std.ArrayList(Ast.NodeIndex) = .empty,

    fn deinit(self: *Decoder) void {
        self.tasks.deinit(self.gpa);
        self.node_stack.deinit(self.gpa);
        self.child_stack.deinit(self.gpa);
    }

    fn readOneNode(self: *Decoder, depth: u32) Error!Ast.NodeIndex {
        if (depth > MAX_TREE_DEPTH) return error.DepthExceeded;
        try self.tasks.append(self.gpa, .{ .decode_node = depth });
        while (self.tasks.pop()) |task| try self.executeTask(task);
        if (self.node_stack.items.len != 1) return error.Truncated;
        return self.node_stack.pop().?;
    }

    fn executeTask(self: *Decoder, task: DecodeTask) Error!void {
        switch (task) {
            .decode_node => |depth| try self.readNodeImpl(depth),
            .decode_child => |depth| try self.readChildImpl(depth),
            .finalize_vector => |v| try self.finishVector(v),
            .finalize_form => |f| try self.finishForm(f),
            .finalize_positional => try self.finishPositional(),
            .finalize_keyword => |k| try self.finishKeyword(k),
        }
    }

    fn readNodeImpl(self: *Decoder, depth: u32) Error!void {
        if (depth > MAX_TREE_DEPTH) return error.DepthExceeded;
        if (self.pos >= self.bytes.len) return error.Truncated;
        const tag_byte = self.bytes[self.pos];
        self.pos += 1;

        const span: Ast.Span = if (self.flags.with_spans) try self.readSpan() else .{ .start = 0, .end = 0 };
        const leading_range: Ast.CommentRange = if (self.flags.with_node_comments)
            try self.readCommentsListAsRange()
        else
            .empty;

        const tag: Tag = try tagFromByte(tag_byte);
        switch (tag) {
            .nil => try self.pushAtom(.nil, span, .{ .immediate = 0 }, leading_range),
            .bool_false => try self.pushAtom(.boolean_false, span, .{ .immediate = 0 }, leading_range),
            .bool_true => try self.pushAtom(.boolean_true, span, .{ .immediate = 0 }, leading_range),
            .number => {
                const x = try self.readF64();
                try self.pushAtom(.number, span, .{ .immediate = @bitCast(x) }, leading_range);
            },
            .number_i64 => {
                const x = try self.readI64();
                try self.pushAtom(.number_i64, span, .{ .immediate = @bitCast(x) }, leading_range);
            },
            .number_u64 => {
                const x = try self.readU64();
                try self.pushAtom(.number_u64, span, .{ .immediate = x }, leading_range);
            },
            .number_with_unit => {
                const x = try self.readF64();
                const unit_idx = try readVarint(self.bytes, &self.pos);
                const unit = try self.string_pool.lookup(unit_idx);
                const unit_si = try self.builder.addString(unit);
                const bits: u64 = @bitCast(x);
                const hdr_at: u32 = @intCast(self.builder.extra_data.items.len);
                try self.builder.extra_data.appendSlice(self.builder.a, &.{
                    @truncate(bits),
                    @truncate(bits >> 32),
                    unit_si.raw(),
                });
                try self.pushAtom(.number_with_unit, span, .{ .single = hdr_at }, leading_range);
            },
            .date => {
                const d = try self.readDatePayload();
                try self.pushAtom(.date, span, .{ .immediate = d.pack() }, leading_range);
            },
            .time => {
                const t = try self.readTimePayload();
                try self.pushAtom(.time, span, .{ .immediate = t.pack() }, leading_range);
            },
            .string => {
                const idx = try readVarint(self.bytes, &self.pos);
                const s = try self.string_pool.lookup(idx);
                const si = try self.builder.addString(s);
                try self.pushAtom(.string, span, .{ .single = si.raw() }, leading_range);
            },
            .keyword => {
                const idx = try readVarint(self.bytes, &self.pos);
                const s = try self.string_pool.lookup(idx);
                const si = try self.builder.addString(s);
                try self.pushAtom(.keyword, span, .{ .single = si.raw() }, leading_range);
            },
            .symbol => {
                const idx = try readVarint(self.bytes, &self.pos);
                const s = try self.string_pool.lookup(idx);
                const si = try self.builder.addString(s);
                try self.pushAtom(.symbol, span, .{ .single = si.raw() }, leading_range);
            },
            .vector => {
                const count = try readVarint(self.bytes, &self.pos);
                if (count > MAX_NODES) return error.NodeCountExceeded;
                try self.tasks.append(self.gpa, .{ .finalize_vector = .{
                    .count = count,
                    .span = span,
                    .leading_range = leading_range,
                } });
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    try self.tasks.append(self.gpa, .{ .decode_node = depth + 1 });
                }
            },
            .form_bare, .form_qualified => {
                const head_span: Ast.Span = if (self.flags.with_head_spans)
                    try self.readSpan()
                else
                    .{ .start = 0, .end = 0 };
                const ns_idx: Ast.StringIndex = if (tag == .form_qualified) blk: {
                    const idx = try readVarint(self.bytes, &self.pos);
                    const s = try self.string_pool.lookup(idx);
                    if (s.len == 0) return error.InvalidNamespace;
                    break :blk try self.builder.addString(s);
                } else .invalid;
                const head_pool_idx = try readVarint(self.bytes, &self.pos);
                const head_str = try self.string_pool.lookup(head_pool_idx);
                const head_idx = try self.builder.addString(head_str);
                const child_count = try readVarint(self.bytes, &self.pos);
                if (child_count > MAX_NODES) return error.NodeCountExceeded;

                try self.tasks.append(self.gpa, .{ .finalize_form = .{
                    .count = child_count,
                    .head_idx = head_idx,
                    .ns_idx = ns_idx,
                    .span = span,
                    .head_span = head_span,
                    .leading_range = leading_range,
                } });
                var i: u32 = 0;
                while (i < child_count) : (i += 1) {
                    try self.tasks.append(self.gpa, .{ .decode_child = depth + 1 });
                }
            },
            else => return error.InvalidTag,
        }
    }

    fn readChildImpl(self: *Decoder, depth: u32) Error!void {
        if (depth > MAX_TREE_DEPTH) return error.DepthExceeded;
        if (self.pos >= self.bytes.len) return error.Truncated;
        const tag_byte = self.bytes[self.pos];
        self.pos += 1;
        const tag: ChildTag = try childTagFromByte(tag_byte);
        switch (tag) {
            .positional => {
                try self.tasks.append(self.gpa, .{ .finalize_positional = {} });
                try self.tasks.append(self.gpa, .{ .decode_node = depth });
            },
            .keyword => {
                const key_span: Ast.Span = if (self.flags.with_kvpair_key_spans)
                    try self.readSpan()
                else
                    .{ .start = 0, .end = 0 };
                const kp_leading_range: Ast.CommentRange = if (self.flags.with_kvpair_comments)
                    try self.readCommentsListAsRange()
                else
                    .empty;
                const key_pool_idx = try readVarint(self.bytes, &self.pos);
                const key_str = try self.string_pool.lookup(key_pool_idx);
                const key_idx = try self.builder.addString(key_str);
                try self.tasks.append(self.gpa, .{ .finalize_keyword = .{
                    .key_idx = key_idx,
                    .key_span = key_span,
                    .leading_range = kp_leading_range,
                } });
                try self.tasks.append(self.gpa, .{ .decode_node = depth });
            },
            else => return error.InvalidTag,
        }
    }

    fn pushAtom(
        self: *Decoder,
        tag: Ast.Tag,
        span: Ast.Span,
        data: Ast.Data,
        leading_range: Ast.CommentRange,
    ) Error!void {
        const idx = try self.builder.appendNode(.{ .tag = tag, .span = span, .data = data });
        self.builder.setLeading(idx, leading_range);
        try self.node_stack.append(self.gpa, idx);
    }

    fn finishVector(self: *Decoder, v: DecodeTask.VectorFin) Error!void {
        if (self.node_stack.items.len < v.count) return error.Truncated;
        const start: u32 = @intCast(self.builder.extra_data.items.len);
        try self.builder.extra_data.appendNTimes(self.builder.a, 0, v.count);
        var i: usize = v.count;
        while (i > 0) {
            i -= 1;
            const ci = self.node_stack.pop().?;
            self.builder.extra_data.items[start + i] = ci.raw();
        }
        const end: u32 = @intCast(self.builder.extra_data.items.len);
        const idx = try self.builder.appendNode(.{
            .tag = .vector,
            .span = v.span,
            .data = .{ .pair = .{ .a = start, .b = end } },
        });
        self.builder.setLeading(idx, v.leading_range);
        try self.node_stack.append(self.gpa, idx);
    }

    fn finishForm(self: *Decoder, f: DecodeTask.FormFin) Error!void {
        if (self.child_stack.items.len < f.count) return error.Truncated;
        const trailing_range: Ast.CommentRange = if (self.flags.with_node_comments)
            try self.readCommentsListAsRange()
        else
            .empty;

        const hdr_at: u32 = @intCast(self.builder.extra_data.items.len);
        try self.builder.extra_data.appendSlice(self.builder.a, &.{
            f.head_idx.raw(),
            f.ns_idx.raw(),
            f.head_span.start,
            f.head_span.end,
            f.count,
        });
        const child_start: u32 = @intCast(self.builder.extra_data.items.len);
        try self.builder.extra_data.appendNTimes(self.builder.a, 0, f.count);
        var i: usize = f.count;
        while (i > 0) {
            i -= 1;
            const ci = self.child_stack.pop().?;
            self.builder.extra_data.items[child_start + i] = ci.raw();
        }

        const idx = try self.builder.appendNode(.{
            .tag = .form,
            .span = f.span,
            .data = .{ .single = hdr_at },
        });
        self.builder.setLeading(idx, f.leading_range);
        self.builder.setTrailing(idx, trailing_range);
        try self.node_stack.append(self.gpa, idx);
    }

    fn finishPositional(self: *Decoder) Error!void {
        const n = self.node_stack.pop() orelse return error.Truncated;
        try self.child_stack.append(self.gpa, n);
    }

    fn finishKeyword(self: *Decoder, k: DecodeTask.KeywordFin) Error!void {
        const value = self.node_stack.pop() orelse return error.Truncated;
        const value_span = self.builder.nodes.items(.span)[value.raw()];
        const hdr_at: u32 = @intCast(self.builder.extra_data.items.len);
        try self.builder.extra_data.appendSlice(self.builder.a, &.{
            k.key_idx.raw(),
            value.raw(),
            k.key_span.start,
            k.key_span.end,
        });
        const idx = try self.builder.appendNode(.{
            .tag = .kvpair,
            .span = .{ .start = k.key_span.start, .end = value_span.end },
            .data = .{ .single = hdr_at },
        });
        self.builder.setLeading(idx, k.leading_range);
        try self.child_stack.append(self.gpa, idx);
    }

    fn readSpan(self: *Decoder) Error!Ast.Span {
        if (self.bytes.len - self.pos < 8) return error.Truncated;
        const start = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .little);
        const end = std.mem.readInt(u32, self.bytes[self.pos + 4 ..][0..4], .little);
        self.pos += 8;
        return .{ .start = start, .end = end };
    }

    fn readF64(self: *Decoder) Error!f64 {
        if (self.bytes.len - self.pos < 8) return error.Truncated;
        const bits = std.mem.readInt(u64, self.bytes[self.pos..][0..8], .little);
        self.pos += 8;
        return @bitCast(bits);
    }

    fn readI64(self: *Decoder) Error!i64 {
        if (self.bytes.len - self.pos < 8) return error.Truncated;
        const bits = std.mem.readInt(u64, self.bytes[self.pos..][0..8], .little);
        self.pos += 8;
        return @bitCast(bits);
    }

    fn readU64(self: *Decoder) Error!u64 {
        if (self.bytes.len - self.pos < 8) return error.Truncated;
        const v = std.mem.readInt(u64, self.bytes[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    fn readDatePayload(self: *Decoder) Error!Date {
        if (self.bytes.len - self.pos < 4) return error.Truncated;
        const y_lo = self.bytes[self.pos + 0];
        const y_hi = self.bytes[self.pos + 1];
        const month = self.bytes[self.pos + 2];
        const day = self.bytes[self.pos + 3];
        self.pos += 4;
        const y_bits: u16 = @as(u16, y_lo) | (@as(u16, y_hi) << 8);
        const year: i16 = @bitCast(y_bits);
        return Date.init(year, month, day) catch error.InvalidTag;
    }

    fn readTimePayload(self: *Decoder) Error!Time {
        if (self.bytes.len - self.pos < 5) return error.Truncated;
        const hour = self.bytes[self.pos + 0];
        const minute = self.bytes[self.pos + 1];
        const second = self.bytes[self.pos + 2];
        const ms_lo = self.bytes[self.pos + 3];
        const ms_hi = self.bytes[self.pos + 4];
        self.pos += 5;
        const ms: u16 = @as(u16, ms_lo) | (@as(u16, ms_hi) << 8);
        return Time.init(hour, minute, second, ms) catch error.InvalidTag;
    }

    fn readCommentsListAsRange(self: *Decoder) Error!Ast.CommentRange {
        const count = try readVarint(self.bytes, &self.pos);
        if (count > MAX_COMMENTS_PER_NODE) return error.NodeCountExceeded;
        if (count == 0) return .empty;
        const start: u32 = @intCast(self.builder.comments.len);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (self.pos >= self.bytes.len) return error.Truncated;
            const kind_byte = self.bytes[self.pos];
            self.pos += 1;
            const kind: Ast.Comment.Kind = switch (kind_byte) {
                0 => .line,
                1 => .block,
                else => return error.InvalidTag,
            };
            const span: Ast.Span = if (self.flags.with_spans) try self.readSpan() else .{ .start = 0, .end = 0 };
            const text_idx = try readVarint(self.bytes, &self.pos);
            const text = try self.comment_pool.lookup(text_idx);
            const owned = try self.builder.a.dupe(u8, text);
            try self.builder.comments.append(self.builder.a, .{
                .span = span,
                .text = owned,
                .kind = kind,
            });
        }
        const end: u32 = @intCast(self.builder.comments.len);
        return .{ .start = start, .end = end };
    }
};
