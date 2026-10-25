//! SJON Binary IR — read-only tree decoder (leaf module).
//!
//! `fromBinary` decodes a Binary IR buffer into a self-contained `Ast.Tree`:
//! strings and comment text are duplicated into the tree's arena, so the
//! caller's bytes need not outlive the call. O(n) decode. Extracted out of
//! `Binary.zig` (ask 30 / M4, 2026-10-21) so a read-only consumer can decode
//! without importing the write-side encoder; `Binary.zig` re-exports every
//! declaration here verbatim, so `Binary.fromBinary` referencers are
//! untouched and `BinaryDecoder.Error == Binary.Error == BinaryFormat.Error`
//! by aliasing.
//!
//! Imports only `std`, `Ast`, and the leaf `BinaryFormat` (which reaches the
//! leaf `Date` / `Time` value types). This leaf NEVER imports `Parser`: the
//! `MAX_TREE_DEPTH >= Parser.MAX_PARSE_DEPTH` cross-check stays in
//! `Binary.zig`.
//!
//! TAIL LENIENCY (shipped, pinned): after the roots block and the optional
//! tree-trailing-comments block there is NO final-consumption check — bytes
//! past a complete frame are accepted and ignored. The one-shot cursor and
//! `Validator.validateBinary` share the leniency (measured 2026-10-21, all
//! three surfaces, leak-free). Strictness would be a deliberate behavior
//! change requiring owner sign-off, not a bug fix.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");

// ---------------------------------------------------------------------------
// Wire-format vocabulary — re-exported verbatim from the leaf
// `BinaryFormat.zig` (std + Ast only), exactly as `Binary.zig` re-exports
// it, minus the encoder-only writer (`writeVarint`): everything a *reader*
// needs, with `Error` aliased so
// `BinaryDecoder.Error == Binary.Error == BinaryFormat.Error`.
// ---------------------------------------------------------------------------
const fmt = @import("BinaryFormat.zig");

pub const wire_version = fmt.wire_version;
pub const wire_magic = fmt.wire_magic;
pub const HEADER_SIZE = fmt.HEADER_SIZE;
pub const MAX_TREE_DEPTH = fmt.MAX_TREE_DEPTH;
pub const MAX_NODES = fmt.MAX_NODES;
pub const MAX_STRING_POOL_ENTRIES = fmt.MAX_STRING_POOL_ENTRIES;
pub const MAX_STRING_LENGTH = fmt.MAX_STRING_LENGTH;
pub const MAX_COMMENTS_PER_NODE = fmt.MAX_COMMENTS_PER_NODE;
pub const MAX_COMMENT_TEXT_LENGTH = fmt.MAX_COMMENT_TEXT_LENGTH;
pub const MAX_FILE_SIZE = fmt.MAX_FILE_SIZE;
pub const Tag = fmt.Tag;
pub const ChildTag = fmt.ChildTag;
pub const Flag = fmt.Flag;
pub const Error = fmt.Error;
pub const FlagSet = fmt.FlagSet;
pub const readVarint = fmt.readVarint;
pub const varintLen = fmt.varintLen;
pub const tagFromByte = fmt.tagFromByte;
pub const childTagFromByte = fmt.childTagFromByte;
pub const Header = fmt.Header;
pub const parseHeader = fmt.parseHeader;
pub const readSpan = fmt.readSpan;
pub const readF64 = fmt.readF64;
pub const readI64 = fmt.readI64;
pub const readU64 = fmt.readU64;
pub const readDatePayload = fmt.readDatePayload;
pub const readTimePayload = fmt.readTimePayload;

/// Decoder options.
pub const FromBinaryOptions = struct {
    /// If false (default), reject unknown wire versions. If true, attempt
    /// best-effort forward-compatible reads (any unknown tag still raises
    /// `error.InvalidTag`).
    allow_unknown_versions: bool = false,
};

/// Tree entry point. Builds a SoA `Tree` directly from the wire bytes —
/// no legacy intermediate. Strings and comment text are duplicated into
/// the destination arena, so the returned tree is fully self-contained
/// and the caller does not need to keep `bytes` alive past the call.
/// O(n) decode.
pub fn fromBinary(gpa: Allocator, bytes: []const u8, opts: FromBinaryOptions) Error!Ast.Tree {
    // Oversized input is a diagnosable error, not a programmer bug: these bytes
    // may arrive unvalidated (wasm boundary, on-disk cache), so reject rather
    // than assert — mirroring `BinaryCursor.Cursor.init`, which returns the same
    // `error.NodeCountExceeded` for the same over-limit condition.
    const header = try parseHeader(bytes, opts.allow_unknown_versions);
    const flags = header.flags;
    const roots_offset = header.roots_offset;

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var pos: u32 = header.pool_offset;
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

    return builder.finalizeWith(&arena, "", roots, .{ .tree_trailing_comments = tree_trailing });
}

// ---------------------------------------------------------------------------
// Pool view — decoder-side O(1) index lookup over a parsed pool.
// ---------------------------------------------------------------------------

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
    // The pool declares both its entry count and its byte size, and the
    // two decoders used to validate different halves: the cursor trusted
    // `byte_size` to find the next block, this walker trusted `count` and
    // ignored `byte_size`. A frame that satisfied one and not the other
    // was admitted by exactly one decoder. Both now require the entries
    // to end exactly `byte_size` bytes after the size varint.
    const byte_size = try readVarint(bytes, pos);
    if (byte_size > bytes.len - pos.*) return error.Truncated;
    const entries_end = pos.* + byte_size;
    if (count == 0) {
        if (byte_size != 0) return error.Truncated;
        return .{ .entries = &.{} };
    }
    const entries = try arena.alloc([]const u8, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const len = try readVarint(bytes, pos);
        if (len > MAX_STRING_LENGTH) return error.StringTooLong;
        if (len > bytes.len - pos.*) return error.Truncated;
        entries[i] = try arena.dupe(u8, bytes[pos.*..][0..len]);
        pos.* += len;
    }
    if (pos.* != entries_end) return error.Truncated;
    return .{ .entries = entries };
}

// ---------------------------------------------------------------------------
// Tree native decoder — same wire bytes, builds Tree directly via
// TreeBuilder rather than allocating a legacy pointer tree.
// ---------------------------------------------------------------------------

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

        const span: Ast.Span = if (self.flags.with_spans) try readSpan(self.bytes, &self.pos) else .{ .start = 0, .end = 0 };
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
                const x = try readF64(self.bytes, &self.pos);
                try self.pushAtom(.number, span, .{ .immediate = @bitCast(x) }, leading_range);
            },
            .number_i64 => {
                const x = try readI64(self.bytes, &self.pos);
                try self.pushAtom(.number_i64, span, .{ .immediate = @bitCast(x) }, leading_range);
            },
            .number_u64 => {
                const x = try readU64(self.bytes, &self.pos);
                try self.pushAtom(.number_u64, span, .{ .immediate = x }, leading_range);
            },
            .number_with_unit => {
                const x = try readF64(self.bytes, &self.pos);
                const unit_idx = try readVarint(self.bytes, &self.pos);
                const unit = try self.string_pool.lookup(unit_idx);
                // An empty pool entry is a valid string literal but never a
                // unit: `TreeBuilder.packNumberWithUnit` would accept it and
                // every reader asserts `unit.len > 0`. Same rule as the JSON
                // bridge (`Json.numberWithUnitFromJson`) and the cursor.
                if (unit.len == 0) return error.InvalidTag;
                const hdr_at = try self.builder.packNumberWithUnit(x, unit);
                try self.pushAtom(.number_with_unit, span, .{ .single = hdr_at }, leading_range);
            },
            .date => {
                const d = try readDatePayload(self.bytes, &self.pos);
                try self.pushAtom(.date, span, .{ .immediate = d.pack() }, leading_range);
            },
            .time => {
                const t = try readTimePayload(self.bytes, &self.pos);
                try self.pushAtom(.time, span, .{ .immediate = t.pack() }, leading_range);
            },
            .string => try self.pushStringAtom(.string, span, leading_range),
            .keyword => try self.pushStringAtom(.keyword, span, leading_range),
            .symbol => try self.pushStringAtom(.symbol, span, leading_range),
            .vector => {
                const count = try readVarint(self.bytes, &self.pos);
                if (count > MAX_NODES) return error.NodeCountExceeded;
                // Every element costs at least its tag byte, so a count the
                // remaining bytes cannot carry is already truncated. Checking
                // here, before the task pushes below, keeps a 31-byte frame
                // from reserving MAX_NODES tasks per nesting level.
                if (count > self.bytes.len - self.pos) return error.Truncated;
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
                    try readSpan(self.bytes, &self.pos)
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
                // Same bound as the vector arm: a child is at least one byte.
                if (child_count > self.bytes.len - self.pos) return error.Truncated;

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
                    try readSpan(self.bytes, &self.pos)
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
        // Trailing comments live AFTER the elements in the byte stream
        // (mirroring forms). Read before appending the vector node so all
        // comments end up in source order in builder.comments.
        const trailing_range: Ast.CommentRange = if (self.flags.with_node_comments)
            try self.readCommentsListAsRange()
        else
            .empty;

        const start: u32 = @intCast(self.builder.extra_data.items.len);
        // Children are on node_stack with the LAST element on top; reserve
        // the slot in extra_data and then fill from the end backwards.
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
        self.builder.setTrailing(idx, trailing_range);
        try self.node_stack.append(self.gpa, idx);
    }

    fn finishForm(self: *Decoder, f: DecodeTask.FormFin) Error!void {
        if (self.child_stack.items.len < f.count) return error.Truncated;
        // Trailing comments live AFTER children in the byte stream. Read
        // before we append the form node so all comments end up in source
        // order in builder.comments.
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
        // Reserve child slots; child_stack has them with last-pushed on top.
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

    /// Decode a pooled-string atom. `string` / `keyword` / `symbol` share the
    /// wire shape `[varint pool_idx]` and a single `StringIndex` payload —
    /// they differ only in the AST tag they push.
    fn pushStringAtom(self: *Decoder, ast_tag: Ast.Tag, span: Ast.Span, leading_range: Ast.CommentRange) Error!void {
        const idx = try readVarint(self.bytes, &self.pos);
        const s = try self.string_pool.lookup(idx);
        const si = try self.builder.addString(s);
        try self.pushAtom(ast_tag, span, .{ .single = si.raw() }, leading_range);
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
            const span: Ast.Span = if (self.flags.with_spans) try readSpan(self.bytes, &self.pos) else .{ .start = 0, .end = 0 };
            const text_idx = try readVarint(self.bytes, &self.pos);
            const text = try self.comment_pool.lookup(text_idx);
            // Dupe text into the destination arena so the Tree owns its
            // comment content even when the input bytes are deallocated.
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

// ---------------------------------------------------------------------------
// Tests — the ask 30 / M4 D1 safety suite (moved verbatim from the Step-1
// characterization pin, re-pointed at the direct module; see
// .agent/control/ask30-m4/d1-pre-characterization.log for the pre-move
// GREEN and the per-defect-class RED proofs). The Parser / Binary imports
// are test-only and live brace-indented inside the test bodies (the
// audit_wasm_imports convention): this leaf's column-0 production imports
// stay exactly std, Ast.zig, BinaryFormat.zig.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "BinaryDecoder: hostile wires refuse with the exact typed error, leak-free" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;
    var tree = try Parser.parse(gpa, "(cat \"a\" (pure (+ 1 2)))");
    defer tree.deinit();
    var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer bytes.deinit();
    var str_tree = try Parser.parse(gpa, "\"a\"");
    defer str_tree.deinit();
    var str_bytes = try Binary.toBinary(gpa, str_tree, Binary.ToBinaryOptions.forMode(.compact));
    defer str_bytes.deinit();

    var str_patched = try gpa.dupe(u8, str_bytes.data);
    defer gpa.free(str_patched);
    str_patched[str_patched.len - 1] = 0x7F; // pool index out of range

    const Case = struct { name: []const u8, bytes: []const u8, want: Error };
    const bad_magic = try gpa.dupe(u8, bytes.data);
    defer gpa.free(bad_magic);
    bad_magic[0] ^= 0xFF;
    const bad_version = try gpa.dupe(u8, bytes.data);
    defer gpa.free(bad_version);
    bad_version[4] = 0x63;
    const reserved_flags = try gpa.dupe(u8, bytes.data);
    defer gpa.free(reserved_flags);
    reserved_flags[5] |= 0x80;
    const trailing_flag = try gpa.dupe(u8, bytes.data);
    defer gpa.free(trailing_flag);
    trailing_flag[5] |= 0x20; // with_tree_trailing_comments; no block follows
    const cases = [_]Case{
        .{ .name = "bad-magic", .bytes = bad_magic, .want = error.InvalidMagic },
        .{ .name = "bad-version", .bytes = bad_version, .want = error.InvalidVersion },
        .{ .name = "reserved-flags", .bytes = reserved_flags, .want = error.InvalidFlags },
        .{ .name = "tree-trailing-flag-poisoned", .bytes = trailing_flag, .want = error.Truncated },
        .{ .name = "truncated-half", .bytes = bytes.data[0 .. bytes.data.len / 2], .want = error.Truncated },
        .{ .name = "truncated-header-only", .bytes = bytes.data[0..16], .want = error.Truncated },
        .{ .name = "pool-index-oob", .bytes = str_patched, .want = error.PoolIndexOutOfRange },
    };
    for (cases) |c| {
        try testing.expectError(c.want, fromBinary(gpa, c.bytes, .{}));
    }
}

test "BinaryDecoder: garbage tail is accepted and ignored (shipped leniency, review M2 — do not tighten silently)" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;
    var tree = try Parser.parse(gpa, "(cat \"a\" (pure (+ 1 2)))");
    defer tree.deinit();
    var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer bytes.deinit();
    var tailed = try gpa.alloc(u8, bytes.data.len + 16);
    defer gpa.free(tailed);
    @memcpy(tailed[0..bytes.data.len], bytes.data);
    @memset(tailed[bytes.data.len..], 0xAA);
    var decoded = try fromBinary(gpa, tailed, .{}); // ACCEPT, tail ignored
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 1), decoded.root.len);
}

test "BinaryDecoder: depth boundary — MAX_TREE_DEPTH+8 refuses, valid 1000-deep accepts, leak-free" {
    const gpa = testing.allocator;
    const depth_n: usize = @as(usize, MAX_TREE_DEPTH) + 8;
    // hand-wired wire: header, empty pool, root_count=1, depth_n nested single-child vectors, nil leaf
    const wire = try gpa.alloc(u8, 16 + 2 + 1 + 2 * depth_n + 1);
    defer gpa.free(wire);
    @memset(wire, 0);
    @memcpy(wire[0..4], &wire_magic);
    wire[4] = wire_version;
    std.mem.writeInt(u32, wire[8..12], 16, .little); // pool at 16
    std.mem.writeInt(u32, wire[12..16], 18, .little); // roots at 18
    wire[18] = 1; // root_count
    var off: usize = 19;
    for (0..depth_n) |_| {
        wire[off] = @intFromEnum(Tag.vector);
        wire[off + 1] = 1;
        off += 2;
    }
    wire[off] = @intFromEnum(Tag.nil);
    try testing.expectError(error.DepthExceeded, fromBinary(gpa, wire, .{}));
    // valid separately-serialized 1000-deep control (a slice of the deeper wire would truncate — a different rejection)
    const ctrl_n: usize = 1000;
    const ctrl = try gpa.alloc(u8, 16 + 2 + 1 + 2 * ctrl_n + 1);
    defer gpa.free(ctrl);
    @memset(ctrl, 0);
    @memcpy(ctrl[0..4], &wire_magic);
    ctrl[4] = wire_version;
    std.mem.writeInt(u32, ctrl[8..12], 16, .little);
    std.mem.writeInt(u32, ctrl[12..16], 18, .little);
    ctrl[18] = 1;
    var coff: usize = 19;
    for (0..ctrl_n) |_| {
        ctrl[coff] = @intFromEnum(Tag.vector);
        ctrl[coff + 1] = 1;
        coff += 2;
    }
    ctrl[coff] = @intFromEnum(Tag.nil);
    var decoded = try fromBinary(gpa, ctrl, .{});
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 1), decoded.root.len);
}

test "BinaryDecoder: fromBinary itself admits root_count <= MAX_NODES (root discipline is the prepared entry's, not the decoder's)" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;
    var tree = try Parser.parse(gpa, "1 2");
    defer tree.deinit();
    var bytes = try Binary.toBinary(gpa, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer bytes.deinit();
    var decoded = try fromBinary(gpa, bytes.data, .{}); // multi-root ADMITTED here
    defer decoded.deinit();
    try testing.expectEqual(@as(usize, 2), decoded.root.len);
}
