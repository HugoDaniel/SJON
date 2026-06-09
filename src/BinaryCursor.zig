const std = @import("std");
const Ast = @import("Ast.zig");
const Binary = @import("Binary.zig");
const Date = @import("Date.zig");
const Time = @import("Time.zig");

pub const Error = Binary.Error;

pub const NodeKind = Ast.ValueKind;

pub const NumberWithUnit = struct {
    value: f64,
    unit: []const u8,
};

pub const NodeView = struct {
    kind: NodeKind,
    span: ?Ast.Span,
    leading_comment_count: u32,
    tag_byte: u8,
};

pub const ChildKind = Binary.ChildTag;

pub const ChildEntry = struct {
    kind: ChildKind,
    key: ?[]const u8 = null,
    key_span: ?Ast.Span = null,
    value: NodeView,
};

comptime {
    std.debug.assert(@sizeOf(NodeKind) == 1);
    std.debug.assert(@sizeOf(NodeView) <= 32);
    std.debug.assert(@sizeOf(ChildEntry) <= 96);
}

pub const FormView = struct {
    head: []const u8,
    namespace: ?[]const u8,
    head_span: ?Ast.Span,
    trailing_comment_count: u32,
    children: ChildIter,
};

pub const Cursor = struct {
    bytes: []const u8,
    flags: Binary.FlagSet,
    pool_offset: u32,
    pool_count: u32,
    comment_pool_offset: u32,
    comment_pool_count: u32,
    roots_offset: u32,
    pos: u32,

    pub fn init(bytes: []const u8) Error!Cursor {
        if (bytes.len > Binary.MAX_FILE_SIZE) return error.NodeCountExceeded;
        if (bytes.len < Binary.HEADER_SIZE) return error.Truncated;
        if (!std.mem.eql(u8, bytes[0..4], &Binary.wire_magic)) return error.InvalidMagic;
        if (bytes[4] != Binary.wire_version) return error.InvalidVersion;
        const flags = try Binary.FlagSet.fromByte(bytes[5]);
        if (bytes[6] != 0 or bytes[7] != 0) return error.InvalidFlags;
        const pool_offset = std.mem.readInt(u32, bytes[8..12], .little);
        const roots_offset = std.mem.readInt(u32, bytes[12..16], .little);
        if (pool_offset != Binary.HEADER_SIZE) return error.InvalidMagic;
        if (roots_offset > bytes.len or roots_offset < pool_offset) return error.Truncated;

        var p: u32 = pool_offset;
        const pool_count = try Binary.readVarint(bytes, &p);
        if (pool_count > Binary.MAX_STRING_POOL_ENTRIES) return error.NodeCountExceeded;
        const pool_byte_size = try Binary.readVarint(bytes, &p);
        if (pool_byte_size > bytes.len - p) return error.Truncated;
        const after_string_pool = p + pool_byte_size;

        var comment_pool_offset: u32 = 0;
        var comment_pool_count: u32 = 0;
        if (flags.anyComments()) {
            comment_pool_offset = after_string_pool;
            var q = after_string_pool;
            comment_pool_count = try Binary.readVarint(bytes, &q);
            if (comment_pool_count > Binary.MAX_STRING_POOL_ENTRIES) return error.NodeCountExceeded;
            const cmt_byte_size = try Binary.readVarint(bytes, &q);
            if (cmt_byte_size > bytes.len - q) return error.Truncated;
        }

        std.debug.assert(pool_offset == Binary.HEADER_SIZE);
        std.debug.assert(roots_offset >= pool_offset);
        std.debug.assert(roots_offset <= bytes.len);
        return .{
            .bytes = bytes,
            .flags = flags,
            .pool_offset = pool_offset,
            .pool_count = pool_count,
            .comment_pool_offset = comment_pool_offset,
            .comment_pool_count = comment_pool_count,
            .roots_offset = roots_offset,
            .pos = roots_offset,
        };
    }

    pub fn rootIter(c: *Cursor) Error!RootIter {
        c.pos = c.roots_offset;
        const root_count = try Binary.readVarint(c.bytes, &c.pos);
        if (root_count > Binary.MAX_NODES) return error.NodeCountExceeded;
        return .{ .cursor = c, .remaining = root_count };
    }

    pub fn lookupString(c: *const Cursor, idx: u32) Error![]const u8 {
        return resolvePool(c.bytes, c.pool_offset, c.pool_count, idx);
    }

    pub fn lookupComment(c: *const Cursor, idx: u32) Error![]const u8 {
        if (!c.flags.anyComments()) return error.PoolIndexOutOfRange;
        return resolvePool(c.bytes, c.comment_pool_offset, c.comment_pool_count, idx);
    }
};

fn resolvePool(bytes: []const u8, pool_offset: u32, pool_count: u32, idx: u32) Error![]const u8 {
    if (idx >= pool_count) return error.PoolIndexOutOfRange;
    var p = pool_offset;
    _ = try Binary.readVarint(bytes, &p);
    _ = try Binary.readVarint(bytes, &p);
    var i: u32 = 0;
    while (i < idx) : (i += 1) {
        const len = try Binary.readVarint(bytes, &p);
        if (len > bytes.len - p) return error.Truncated;
        p += len;
    }
    const len = try Binary.readVarint(bytes, &p);
    if (len > bytes.len - p) return error.Truncated;
    return bytes[p..][0..len];
}

fn nextNodeView(c: *Cursor) Error!NodeView {
    const entry_pos = c.pos;
    if (c.pos >= c.bytes.len) return error.Truncated;
    const tag_byte = c.bytes[c.pos];
    c.pos += 1;
    std.debug.assert(c.pos > entry_pos);
    const span: ?Ast.Span = if (c.flags.with_spans) try readSpanRaw(c) else null;
    const leading_count: u32 = if (c.flags.with_node_comments) blk: {
        const n = try Binary.readVarint(c.bytes, &c.pos);
        if (n > Binary.MAX_COMMENTS_PER_NODE) return error.NodeCountExceeded;
        try skipNComments(c, n);
        break :blk n;
    } else 0;

    const wire_tag = try Binary.tagFromByte(tag_byte);
    const kind: NodeKind = wire_tag.toValueKind();

    return .{
        .kind = kind,
        .span = span,
        .leading_comment_count = leading_count,
        .tag_byte = tag_byte,
    };
}

fn readSpanRaw(c: *Cursor) Error!Ast.Span {
    if (c.bytes.len - c.pos < 8) return error.Truncated;
    const start = std.mem.readInt(u32, c.bytes[c.pos..][0..4], .little);
    const end = std.mem.readInt(u32, c.bytes[c.pos + 4 ..][0..4], .little);
    c.pos += 8;
    return .{ .start = start, .end = end };
}

fn skipNComments(c: *Cursor, n: u32) Error!void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (c.pos >= c.bytes.len) return error.Truncated;
        const kind = c.bytes[c.pos];
        if (kind > 1) return error.InvalidTag;
        c.pos += 1;
        if (c.flags.with_spans) _ = try readSpanRaw(c);
        _ = try Binary.readVarint(c.bytes, &c.pos);
    }
}

pub const RootIter = struct {
    cursor: *Cursor,
    remaining: u32,

    pub fn next(self: *RootIter) Error!?NodeView {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        return try nextNodeView(self.cursor);
    }
};

pub const VectorIter = struct {
    cursor: *Cursor,
    remaining: u32,

    pub fn next(self: *VectorIter) Error!?NodeView {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        return try nextNodeView(self.cursor);
    }
};

pub const ChildIter = struct {
    cursor: *Cursor,
    remaining: u32,
    trailing_count: u32 = 0,
    trailing_consumed: bool = false,

    pub fn next(self: *ChildIter) Error!?ChildEntry {
        if (self.remaining == 0) {
            try self.consumeTrailing();
            return null;
        }
        self.remaining -= 1;
        return try readChildEntry(self.cursor);
    }

    fn consumeTrailing(self: *ChildIter) Error!void {
        if (self.trailing_consumed) return;
        self.trailing_consumed = true;
        if (self.cursor.flags.with_node_comments) {
            const n = try Binary.readVarint(self.cursor.bytes, &self.cursor.pos);
            if (n > Binary.MAX_COMMENTS_PER_NODE) return error.NodeCountExceeded;
            self.trailing_count = n;
            try skipNComments(self.cursor, n);
        }
    }
};

fn readChildEntry(c: *Cursor) Error!ChildEntry {
    if (c.pos >= c.bytes.len) return error.Truncated;
    const tag_byte = c.bytes[c.pos];
    c.pos += 1;
    switch (tag_byte) {
        0x10 => {
            const view = try nextNodeView(c);
            return .{ .kind = .positional, .value = view };
        },
        0x11 => {
            const key_span: ?Ast.Span = if (c.flags.with_kvpair_key_spans)
                try readSpanRaw(c)
            else
                null;
            if (c.flags.with_kvpair_comments) {
                const n = try Binary.readVarint(c.bytes, &c.pos);
                if (n > Binary.MAX_COMMENTS_PER_NODE) return error.NodeCountExceeded;
                try skipNComments(c, n);
            }
            const key_idx = try Binary.readVarint(c.bytes, &c.pos);
            const key = try resolvePool(c.bytes, c.pool_offset, c.pool_count, key_idx);
            const view = try nextNodeView(c);
            return .{
                .kind = .keyword,
                .key = key,
                .key_span = key_span,
                .value = view,
            };
        },
        else => return error.InvalidTag,
    }
}

pub fn readNumber(c: *Cursor, view: NodeView) Error!f64 {
    if (view.kind != .number) return error.InvalidTag;
    if (c.bytes.len - c.pos < 8) return error.Truncated;
    const bits = std.mem.readInt(u64, c.bytes[c.pos..][0..8], .little);
    c.pos += 8;
    return switch (view.tag_byte) {
        0x03 => @bitCast(bits),
        0x0B => @floatFromInt(@as(i64, @bitCast(bits))),
        0x0C => @floatFromInt(bits),
        else => unreachable,
    };
}

pub fn readNumberI64(c: *Cursor, view: NodeView) Error!i64 {
    if (view.tag_byte != 0x0B) return error.InvalidTag;
    if (c.bytes.len - c.pos < 8) return error.Truncated;
    const bits = std.mem.readInt(u64, c.bytes[c.pos..][0..8], .little);
    c.pos += 8;
    return @bitCast(bits);
}

pub fn readNumberU64(c: *Cursor, view: NodeView) Error!u64 {
    if (view.tag_byte != 0x0C) return error.InvalidTag;
    if (c.bytes.len - c.pos < 8) return error.Truncated;
    const v = std.mem.readInt(u64, c.bytes[c.pos..][0..8], .little);
    c.pos += 8;
    return v;
}

pub fn readDate(c: *Cursor, view: NodeView) Error!Date {
    if (view.kind != .date) return error.InvalidTag;
    if (c.bytes.len - c.pos < 4) return error.Truncated;
    const y_lo = c.bytes[c.pos + 0];
    const y_hi = c.bytes[c.pos + 1];
    const month = c.bytes[c.pos + 2];
    const day = c.bytes[c.pos + 3];
    c.pos += 4;
    const y_bits: u16 = @as(u16, y_lo) | (@as(u16, y_hi) << 8);
    const year: i16 = @bitCast(y_bits);
    return Date.init(year, month, day) catch error.InvalidTag;
}

pub fn readTime(c: *Cursor, view: NodeView) Error!Time {
    if (view.kind != .time) return error.InvalidTag;
    if (c.bytes.len - c.pos < 5) return error.Truncated;
    const hour = c.bytes[c.pos + 0];
    const minute = c.bytes[c.pos + 1];
    const second = c.bytes[c.pos + 2];
    const ms_lo = c.bytes[c.pos + 3];
    const ms_hi = c.bytes[c.pos + 4];
    c.pos += 5;
    const ms: u16 = @as(u16, ms_lo) | (@as(u16, ms_hi) << 8);
    return Time.init(hour, minute, second, ms) catch error.InvalidTag;
}

pub fn readNumberWithUnit(c: *Cursor, view: NodeView) Error!NumberWithUnit {
    if (view.kind != .number_with_unit) return error.InvalidTag;
    if (c.bytes.len - c.pos < 8) return error.Truncated;
    std.debug.assert(c.pos <= c.bytes.len);
    const bits = std.mem.readInt(u64, c.bytes[c.pos..][0..8], .little);
    c.pos += 8;
    const unit_idx = try Binary.readVarint(c.bytes, &c.pos);
    const unit = try resolvePool(c.bytes, c.pool_offset, c.pool_count, unit_idx);
    std.debug.assert(unit.len > 0);
    return .{ .value = @bitCast(bits), .unit = unit };
}

pub fn readBoolean(c: *Cursor, view: NodeView) Error!bool {
    _ = c;
    return switch (view.tag_byte) {
        0x01 => false,
        0x02 => true,
        else => error.InvalidTag,
    };
}

pub fn readNil(c: *Cursor, view: NodeView) Error!void {
    _ = c;
    if (view.kind != .nil) return error.InvalidTag;
}

pub fn readString(c: *Cursor, view: NodeView) Error![]const u8 {
    if (view.kind != .string) return error.InvalidTag;
    const idx = try Binary.readVarint(c.bytes, &c.pos);
    return resolvePool(c.bytes, c.pool_offset, c.pool_count, idx);
}

pub fn readKeyword(c: *Cursor, view: NodeView) Error![]const u8 {
    if (view.kind != .keyword) return error.InvalidTag;
    const idx = try Binary.readVarint(c.bytes, &c.pos);
    return resolvePool(c.bytes, c.pool_offset, c.pool_count, idx);
}

pub fn readSymbol(c: *Cursor, view: NodeView) Error![]const u8 {
    if (view.kind != .symbol) return error.InvalidTag;
    const idx = try Binary.readVarint(c.bytes, &c.pos);
    return resolvePool(c.bytes, c.pool_offset, c.pool_count, idx);
}

pub fn readVector(c: *Cursor, view: NodeView) Error!VectorIter {
    if (view.kind != .vector) return error.InvalidTag;
    const count = try Binary.readVarint(c.bytes, &c.pos);
    if (count > Binary.MAX_NODES) return error.NodeCountExceeded;
    return .{ .cursor = c, .remaining = count };
}

pub fn readForm(c: *Cursor, view: NodeView) Error!FormView {
    if (view.kind != .form) return error.InvalidTag;
    const head_span: ?Ast.Span = if (c.flags.with_head_spans)
        try readSpanRaw(c)
    else
        null;
    const namespace: ?[]const u8 = if (view.tag_byte == 0x09) blk: {
        const idx = try Binary.readVarint(c.bytes, &c.pos);
        const ns = try resolvePool(c.bytes, c.pool_offset, c.pool_count, idx);
        if (ns.len == 0) return error.InvalidNamespace;
        break :blk ns;
    } else null;
    const head_idx = try Binary.readVarint(c.bytes, &c.pos);
    const head = try resolvePool(c.bytes, c.pool_offset, c.pool_count, head_idx);
    const child_count = try Binary.readVarint(c.bytes, &c.pos);
    if (child_count > Binary.MAX_NODES) return error.NodeCountExceeded;
    return .{
        .head = head,
        .namespace = namespace,
        .head_span = head_span,
        .trailing_comment_count = 0,
        .children = .{ .cursor = c, .remaining = child_count },
    };
}

pub fn peekFormHead(c: *Cursor, view: NodeView) Error![]const u8 {
    if (view.kind != .form) return error.InvalidTag;
    const saved_pos = c.pos;
    if (c.flags.with_head_spans) _ = try readSpanRaw(c);
    if (view.tag_byte == 0x09) _ = try Binary.readVarint(c.bytes, &c.pos);
    const head_idx = try Binary.readVarint(c.bytes, &c.pos);
    const head = try resolvePool(c.bytes, c.pool_offset, c.pool_count, head_idx);
    c.pos = saved_pos;
    return head;
}

pub fn peekSymbol(c: *Cursor, view: NodeView) Error![]const u8 {
    if (view.kind != .symbol) return error.InvalidTag;
    const saved_pos = c.pos;
    const idx = try Binary.readVarint(c.bytes, &c.pos);
    const sym = try resolvePool(c.bytes, c.pool_offset, c.pool_count, idx);
    c.pos = saved_pos;
    return sym;
}

pub fn peekKeyword(c: *Cursor, view: NodeView) Error![]const u8 {
    if (view.kind != .keyword) return error.InvalidTag;
    const saved_pos = c.pos;
    defer c.pos = saved_pos;
    return try readKeyword(c, view);
}

pub fn setPos(c: *Cursor, pos: u32) void {
    std.debug.assert(pos <= c.bytes.len);
    c.pos = pos;
}

const SKIP_STACK_CAP: u32 = Binary.MAX_TREE_DEPTH * 2;

const SkipFrame = struct {
    remaining: u32,
    kind: Kind,
    const Kind = enum(u8) { vector, form_children, form_trailing };
};

pub fn skipBody(c: *Cursor, view: NodeView) Error!void {
    var frames: [SKIP_STACK_CAP]SkipFrame = undefined;
    var depth: u32 = 0;

    try consumeAndPushFrames(c, view, &frames, &depth);

    while (depth > 0) {
        const frame = &frames[depth - 1];
        switch (frame.kind) {
            .vector => {
                if (frame.remaining == 0) {
                    depth -= 1;
                    continue;
                }
                frame.remaining -= 1;
                const sub = try nextNodeView(c);
                try consumeAndPushFrames(c, sub, &frames, &depth);
            },
            .form_children => {
                if (frame.remaining == 0) {
                    depth -= 1;
                    continue;
                }
                frame.remaining -= 1;
                const sub = try readChildEntryAsView(c);
                try consumeAndPushFrames(c, sub, &frames, &depth);
            },
            .form_trailing => {
                if (c.flags.with_node_comments) {
                    const n = try Binary.readVarint(c.bytes, &c.pos);
                    if (n > Binary.MAX_COMMENTS_PER_NODE) return error.NodeCountExceeded;
                    try skipNComments(c, n);
                }
                depth -= 1;
            },
        }
    }
}

fn consumeAndPushFrames(
    c: *Cursor,
    view: NodeView,
    frames: []SkipFrame,
    depth: *u32,
) Error!void {
    switch (view.kind) {
        .nil, .boolean => {},
        .number => _ = try readNumber(c, view),
        .number_with_unit => _ = try readNumberWithUnit(c, view),
        .date => _ = try readDate(c, view),
        .time => _ = try readTime(c, view),
        .string => _ = try readString(c, view),
        .keyword => _ = try readKeyword(c, view),
        .symbol => _ = try readSymbol(c, view),
        .vector => {
            const count = try Binary.readVarint(c.bytes, &c.pos);
            if (count > Binary.MAX_NODES) return error.NodeCountExceeded;
            if (depth.* >= frames.len) return error.DepthExceeded;
            frames[depth.*] = .{ .remaining = count, .kind = .vector };
            depth.* += 1;
        },
        .form => {
            if (c.flags.with_head_spans) _ = try readSpanRaw(c);
            if (view.tag_byte == 0x09) _ = try Binary.readVarint(c.bytes, &c.pos);
            _ = try Binary.readVarint(c.bytes, &c.pos);
            const child_count = try Binary.readVarint(c.bytes, &c.pos);
            if (child_count > Binary.MAX_NODES) return error.NodeCountExceeded;
            if (depth.* + 1 >= frames.len) return error.DepthExceeded;
            frames[depth.*] = .{ .remaining = 0, .kind = .form_trailing };
            depth.* += 1;
            frames[depth.*] = .{ .remaining = child_count, .kind = .form_children };
            depth.* += 1;
        },
    }
}

fn readChildEntryAsView(c: *Cursor) Error!NodeView {
    if (c.pos >= c.bytes.len) return error.Truncated;
    const tag_byte = c.bytes[c.pos];
    c.pos += 1;
    switch (tag_byte) {
        0x10 => return try nextNodeView(c),
        0x11 => {
            if (c.flags.with_kvpair_key_spans) _ = try readSpanRaw(c);
            if (c.flags.with_kvpair_comments) {
                const n = try Binary.readVarint(c.bytes, &c.pos);
                if (n > Binary.MAX_COMMENTS_PER_NODE) return error.NodeCountExceeded;
                try skipNComments(c, n);
            }
            _ = try Binary.readVarint(c.bytes, &c.pos);
            return try nextNodeView(c);
        },
        else => return error.InvalidTag,
    }
}

const testing = std.testing;
const Parser = @import("Parser.zig");

fn encodeWithStripped(src: [:0]const u8) !Ast.Bytes {
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    return try Binary.toBinary(testing.allocator, tree, Binary.ToBinaryOptions.forMode(.compact));
}

fn walkTreeKinds(
    a: std.mem.Allocator,
    tree: *const Ast.Tree,
    nodes: []const Ast.NodeIndex,
    out: *std.ArrayList(NodeKind),
) !void {
    for (nodes) |idx| {
        const tag = tree.tagOf(idx);
        const k: NodeKind = switch (tag) {
            .nil => .nil,
            .boolean_true, .boolean_false => .boolean,
            .number, .number_i64, .number_u64 => .number,
            .number_with_unit => .number_with_unit,
            .date => .date,
            .time => .time,
            .string => .string,
            .keyword => .keyword,
            .symbol => .symbol,
            .vector => .vector,
            .form => .form,
            .kvpair => {
                const kp = tree.kvpairHeader(idx);
                try walkTreeKinds(a, tree, &.{kp.value}, out);
                continue;
            },
        };
        try out.append(a, k);
        switch (tag) {
            .vector => try walkTreeKinds(a, tree, tree.vectorElements(idx), out),
            .form => {
                const hdr = tree.formHeader(idx);
                try walkTreeKinds(a, tree, hdr.children, out);
            },
            else => {},
        }
    }
}

fn walkCursorKinds(
    a: std.mem.Allocator,
    c: *Cursor,
    view: NodeView,
    out: *std.ArrayList(NodeKind),
) !void {
    try out.append(a, view.kind);
    switch (view.kind) {
        .nil => try readNil(c, view),
        .boolean => _ = try readBoolean(c, view),
        .number => _ = try readNumber(c, view),
        .number_with_unit => _ = try readNumberWithUnit(c, view),
        .date => _ = try readDate(c, view),
        .time => _ = try readTime(c, view),
        .string => _ = try readString(c, view),
        .keyword => _ = try readKeyword(c, view),
        .symbol => _ = try readSymbol(c, view),
        .vector => {
            var vec = try readVector(c, view);
            while (try vec.next()) |sub_view| {
                try walkCursorKinds(a, c, sub_view, out);
            }
        },
        .form => {
            var fv = try readForm(c, view);
            while (try fv.children.next()) |entry| {
                try walkCursorKinds(a, c, entry.value, out);
            }
        },
    }
}
