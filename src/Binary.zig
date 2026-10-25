//! SJON Binary IR — wire format, encoder, and decoder.
//!
//! Hand-rolled, deterministic, little-endian binary representation of an
//! `Ast.Tree`. Numbers are 8 raw IEEE-754 bytes (no `std.fmt` round-trip),
//! identifiers and string literals live in a per-tree deduplicated pool
//! sorted by `(length, bytes)`, and spans / comments are flag-gated. The
//! same canonical tree always serialises to byte-identical output.
//!
//! Two artifacts consume the format:
//!
//!   * `sjon.wasm` — kitchen-sink, gains four binary exports.
//!   * `sjon-binary.wasm` — read-only, no parser / printer / json.
//!
//! Wire layout (little-endian throughout, lengths in bytes):
//!
//!   [header 16]
//!     [magic "SJ1\n"          4]
//!     [wire_version           1]
//!     [flags                  1]
//!     [reserved               2]
//!     [pool_offset (u32 LE)   4]
//!     [roots_offset (u32 LE)  4]
//!   [string pool]
//!   [comment-text pool]            -- only if any with_*_comments flag set
//!   [roots block]
//!     [varint root_count]
//!     [root_count × node]
//!   [tree trailing comments]       -- only if with_tree_trailing_comments
//!     [varint count]
//!     [count × comment]
//!
//! Each `node`:
//!
//!   [tag 1]
//!   [span 8]                       -- iff with_spans
//!   [varint leading_comment_count] -- iff with_node_comments
//!   [comment entries …]            --   ditto
//!   [variant payload …]
//!
//! Variant payloads:
//!
//!   nil               (empty)
//!   bool false        (empty)
//!   bool true         (empty)
//!   number            [f64 LE 8]
//!   number_with_unit  [f64 LE 8] [varint unit_pool_idx]
//!   number_i64        [i64 LE 8]                              -- wire >= v2
//!   number_u64        [u64 LE 8]                              -- wire >= v2
//!   date              [i16 LE 2] [u8 month] [u8 day]          -- wire >= v3
//!   time              [u8 hour] [u8 min] [u8 sec] [u16 LE ms] -- wire >= v4
//!   string            [varint pool_idx]
//!   keyword           [varint pool_idx]
//!   symbol            [varint pool_idx]
//!   vector            [varint count] [count × node]
//!                     [varint trailing_comment_count iff with_node_comments]
//!                     [comment entries …]
//!   form-bare         [head_span 8 iff with_head_spans]
//!                     [varint head_idx]
//!                     [varint child_count]
//!                     [child entries × child_count]
//!                     [varint trailing_comment_count iff with_node_comments]
//!                     [comment entries …]
//!   form-qualified    [head_span 8 iff with_head_spans]
//!                     [varint ns_idx] [varint head_idx]
//!                     [varint child_count] [child entries × child_count]
//!                     [varint trailing_comment_count iff with_node_comments]
//!                     [comment entries …]
//!
//! Child entries:
//!
//!   child-positional  [tag 1] [node]
//!   child-keyword     [tag 1]
//!                     [key_span 8 iff with_kvpair_key_spans]
//!                     [varint kp_leading_comment_count iff with_kvpair_comments]
//!                     [comment entries …]
//!                     [varint key_idx]
//!                     [node = value]
//!
//! Comment entry:
//!
//!   [u8 kind]                  -- 0 = line, 1 = block
//!   [span 8 iff with_spans]
//!   [varint text_idx]          -- index into the comment-text pool
//!
//! String / comment-text pool layout:
//!
//!   [varint entry_count]
//!   [varint byte_size]         -- sum of (varint_len + bytes) over entries
//!   [entry_count × entry]
//!     entry = [varint len] [u8 × len]   -- UTF-8, no terminator

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Date = @import("Date.zig");
const Time = @import("Time.zig");

// ---------------------------------------------------------------------------
// Wire-format vocabulary — extracted to the leaf `BinaryFormat.zig` (std +
// Ast only) so the read-only `sjon-binary.wasm` closure (via BinaryCursor)
// can reach the wire constants / tags / varint codec without importing this
// write-side module. Re-exported verbatim so every `Binary.<name>` referencer
// (root.zig, fuzz.zig, cli/Cli.zig, BinaryCursor, the tests) is untouched;
// error-set identity `BinaryCursor.Error == Binary.Error == fmt.Error` is
// preserved by aliasing.
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
pub const writeVarint = fmt.writeVarint;
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

// ---------------------------------------------------------------------------
// Tree decoder — extracted to the leaf `BinaryDecoder.zig` (std + Ast +
// BinaryFormat only) so a read-only consumer decodes without the write side
// (ask 30 / M4). Re-exported verbatim: every `Binary.fromBinary` /
// `Binary.FromBinaryOptions` referencer (root.zig, Binary_tests.zig,
// fuzz.zig, oom_tests.zig, cli) is untouched. The
// `MAX_TREE_DEPTH >= Parser.MAX_PARSE_DEPTH` comptime pin below stays HERE
// (write side): the leaf never imports the parser.
// ---------------------------------------------------------------------------
const BinaryDecoder = @import("BinaryDecoder.zig");

pub const FromBinaryOptions = BinaryDecoder.FromBinaryOptions;
pub const fromBinary = BinaryDecoder.fromBinary;

// `MAX_TREE_DEPTH >= Parser.MAX_PARSE_DEPTH` keeps binaries from decoding
// trees the parser couldn't produce. The bound lives in the leaf; the
// cross-check against Parser stays here so BinaryFormat never imports the
// parser (which would drag it into the read-only closure).
comptime {
    if (MAX_TREE_DEPTH < @import("Parser.zig").MAX_PARSE_DEPTH)
        @compileError("Binary.MAX_TREE_DEPTH must be >= Parser.MAX_PARSE_DEPTH");
}

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

/// Encoder options. Default (`.{}`) is `forMode(.canonical)`: spans on,
/// comments off — the compact runtime preset. Use `forMode(.full)` for
/// every span and every comment site (round-trippable), or
/// `forMode(.compact)` for the smallest output (no spans, no comments).
/// Individual booleans can be overridden directly for fine-grained
/// profiles; `forMode` returns the matching preset.
pub const ToBinaryOptions = struct {
    /// Emit `Node.span` inline (8 bytes per node).
    with_spans: bool = true,
    /// Emit `Form.head_span` inline (8 bytes per form).
    with_head_spans: bool = true,
    /// Emit `KeywordPair.key_span` inline (8 bytes per pair).
    with_kvpair_key_spans: bool = true,
    /// Emit `Node.leading_comments` and the container `trailing_comments`
    /// of forms and (since wire v5) vectors.
    with_node_comments: bool = false,
    /// Emit `KeywordPair.leading_comments`.
    with_kvpair_comments: bool = false,
    /// Emit `Tree.trailing_comments` after the roots block.
    with_tree_trailing_comments: bool = false,

    /// Construct the preset matching `mode`:
    ///   * `.canonical` — spans on, comments off (current runtime default).
    ///   * `.compact`   — no spans, no comments. Smallest output.
    ///   * `.full`      — every span and every comment site preserved;
    ///                    binary round-trips back to a structurally
    ///                    equivalent tree.
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

    /// Pack the option set into the 1-byte `flags` header field.
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

    /// True iff any comment-site flag is on; gates the comment-text pool.
    pub fn anyCommentsFlag(self: ToBinaryOptions) bool {
        return self.with_node_comments or self.with_kvpair_comments or self.with_tree_trailing_comments;
    }
};

// ---------------------------------------------------------------------------
// Public API — the encoder (toBinary) and the decoder (fromBinary).
// ---------------------------------------------------------------------------

/// Encode a `Tree` to a freshly-allocated, caller-owned `Ast.Bytes`.
/// O(n) emit; output ≤ `MAX_FILE_SIZE` bytes. A tree wider than the wire
/// admits — more than `MAX_NODES` roots, or one container with more than
/// `MAX_NODES` children — is `error.NodeCountExceeded`: the parser has no
/// width ceiling, so this is user input, and the decoders refuse such a
/// frame anyway. Refusing here keeps every frame the encoder emits
/// readable by both decoders.
pub fn toBinary(gpa: Allocator, tree2: Ast.Tree, opts: ToBinaryOptions) Error!Ast.Bytes {
    if (tree2.root.len > MAX_NODES) return error.NodeCountExceeded;
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

// ---------------------------------------------------------------------------
// Pool builder — collects unique strings, sorts lex, hands out indices.
// ---------------------------------------------------------------------------

const PoolBuilder = struct {
    /// String → index. Pre-finalize this is insertion order; post-finalize
    /// it's the final sorted index.
    map: std.StringHashMapUnmanaged(u32) = .empty,
    /// Strings in declaration order; finalize() sorts them in place.
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

// ---------------------------------------------------------------------------
// String collection — first pass over the tree.
// ---------------------------------------------------------------------------

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
            // Exact-integer tags carry a raw 8-byte payload — no string interning.
            .number_i64, .number_u64 => {},
            // Date payload is 4 raw bytes — no string interning either.
            .date => {},
            // Time payload is 5 raw bytes — no string interning either.
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
                if (opts.with_node_comments) {
                    try collectCommentRange(a, tree, tree.trailing_comments_index[idx.raw()], comment_pool);
                }
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
                        // Kvpair children are emitted inline as child-keyword
                        // wire entries — never popped from the stack as nodes.
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
            if (elements.len > MAX_NODES) return error.NodeCountExceeded;
            try writeVarint(gpa, out, @intCast(elements.len));
            // Trailing comments follow the elements on the wire (mirroring the
            // form arm below). Push the task before the element tasks so it pops
            // last — after the whole sub-tree — landing the count at end-of-body.
            if (opts.with_node_comments) {
                try tasks.append(gpa, .{ .trailing_comments = .{ .range = tree.trailing_comments_index[idx.raw()] } });
            }
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
            if (hdr.children.len > MAX_NODES) return error.NodeCountExceeded;
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

// ---------------------------------------------------------------------------
// Low-level byte writers
// ---------------------------------------------------------------------------

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

test {
    _ = @import("Binary_tests.zig");
}
