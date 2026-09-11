//! Zero-allocation read cursor over a Binary IR file.
//!
//! Walks `bytes` in a single linear pass — never allocates, never copies,
//! always borrows. The input buffer must outlive the cursor. Consumers
//! that need O(1) random access to a *tree* should decode via
//! `Binary.fromBinary` instead (which owns its strings).
//!
//! **Pool lookup, and the opt-in index.** By default resolving pool index
//! `idx` costs `O(idx)` varint reads, because the entries are length-
//! prefixed and the walk starts at the pool head. Every form head,
//! keyword key, symbol, string, keyword and unit resolves through it, so
//! a document with `N` pool entries and `M` string-bearing nodes costs
//! `O(M x N)` — quadratic, and reachable by a legal file
//! (`MAX_STRING_POOL_ENTRIES` is 65536).
//!
//! `indexPools` fixes that without breaking "never allocates": the
//! *caller* sizes one `[]u32` (`poolIndexLen()` entries, 4 bytes each)
//! and owns it, and the cursor borrows it for the rest of its life. With
//! the index attached a lookup is one varint read. Opt in with:
//!
//! ```zig
//! var cursor = try BinaryCursor.Cursor.init(bytes);
//! const pool_index = try gpa.alloc(u32, cursor.poolIndexLen());
//! defer gpa.free(pool_index);
//! cursor.indexPools(pool_index);
//! ```
//!
//! Iterator contract: when `RootIter.next` / `VectorIter.next` /
//! `ChildIter.next` returns a non-null `NodeView` (or `ChildEntry`
//! carrying one), the cursor sits at the **variant payload** of that
//! node. The caller MUST consume the payload by calling exactly one of
//! `readNumber`, `readNumberI64`, `readNumberU64`, `readNumberWithUnit`,
//! `readDate`, `readTime`, `readString`, `readKeyword`, `readSymbol`,
//! `readBoolean`, `readNil`, `readVector`, `readForm`, or `skipBody` before
//! calling `.next()` again. Failing to do so leaves the cursor in an
//! unpredictable state.
//!
//! Wire tag 0x03 (`number`) carries an f64; tags 0x0B (`number_i64`) and
//! 0x0C (`number_u64`) carry exact integers. All three project to
//! `view.kind == .number`; callers that need exact bits branch on
//! `view.tag` and call `readNumberI64` / `readNumberU64`. The
//! polymorphic `readNumber` accepts all three, lossy-casting integer
//! payloads to f64 — same precision semantics as `Ast.Tree.numberOf`.
//!
//! When a form's `ChildIter.next()` returns null, the cursor has
//! transparently consumed any form-trailing comments. The caller lands
//! at the next sibling without further bookkeeping. The same is true
//! for `VectorIter.next()`: from wire v5 on, vectors carry a trailing-
//! comment field symmetric with forms, and the iterator consumes it on
//! exhaustion.

const std = @import("std");
const Ast = @import("Ast.zig");
const fmt = @import("BinaryFormat.zig");
const Date = @import("Date.zig");
const Time = @import("Time.zig");

pub const Error = fmt.Error;

/// Coarse-grained kind matching `Ast.Node` payload variants.
/// Aliased to `Ast.ValueKind` — the cursor's read-API discriminator
/// is the abstract value-shape vocabulary. Boolean true / false
/// collapse to a single kind; the actual value lives on
/// `NodeView.tag`. Form bare / qualified collapse too;
/// the namespace lives on `FormView.namespace`.
pub const NodeKind = Ast.ValueKind;

/// Result of `readNumberWithUnit`. The `unit` slice borrows from the
/// cursor's underlying bytes (string pool entry).
pub const NumberWithUnit = struct {
    value: f64,
    unit: []const u8,
};

/// Header summary of one node. `tag` is the decoded wire tag;
/// `read*` functions branch on it to disambiguate `bool_true / bool_false`
/// and `form_bare / form_qualified` without re-reading the byte.
pub const NodeView = struct {
    kind: NodeKind,
    /// Byte span when `with_spans` is set; `null` otherwise.
    span: ?Ast.Span,
    /// Number of leading comments. Always 0 when `with_node_comments` is
    /// off. Comments themselves are skipped during the iterator step;
    /// they are not exposed via the cursor.
    leading_comment_count: u32,
    /// Decoded wire tag. Consumers usually match on `kind`; branch on
    /// `tag` only for the sub-splits `kind` folds away (the three number
    /// tags, bool true/false, form bare/qualified).
    tag: fmt.Tag,
};

/// Discriminator for one entry in a form's children list. Aliased to
/// `Binary.ChildTag` — wire-format and read-API agree on the vocabulary
/// (`positional`, `keyword`); the wire-byte annotation on `ChildTag` is
/// inert at this layer (no `@intFromEnum` calls happen on read entries).
pub const ChildKind = fmt.ChildTag;

/// One form-child entry. The `value` field's `NodeView` describes the
/// child's value node (positional element, or keyword pair's RHS).
pub const ChildEntry = struct {
    kind: ChildKind,
    /// Borrowed key name without leading `:`. Set iff `kind == .keyword`.
    key: ?[]const u8 = null,
    /// Span of the key token. Set iff `kind == .keyword` AND
    /// `with_kvpair_key_spans` is on.
    key_span: ?Ast.Span = null,
    /// View of the child value node. Cursor is at this value's variant
    /// payload; consume via cursor.read* / skipBody.
    value: NodeView,
};

comptime {
    // Iterator views are stack-passed across the cursor's hot path; pin
    // their sizes so a stdlib alignment change can't silently bloat the
    // walker. Spans dominate when present (`?Ast.Span` ≈ 16B).
    std.debug.assert(@sizeOf(NodeKind) == 1);
    std.debug.assert(@sizeOf(NodeView) <= 32);
    std.debug.assert(@sizeOf(ChildEntry) <= 96);
}

/// Form-header view. `children` is a primed iterator; iterating it to
/// completion advances the cursor past the form's trailing comments and
/// records their count in `children.trailing_count`.
pub const FormView = struct {
    /// Borrowed head text (e.g. `"camera"` for `(camera …)`).
    head: []const u8,
    /// Borrowed namespace, when the form is qualified.
    namespace: ?[]const u8,
    /// Span of the head token, when `with_head_spans` is on.
    head_span: ?Ast.Span,
    children: ChildIter,
};

// ---------------------------------------------------------------------------
// Cursor
// ---------------------------------------------------------------------------

pub const Cursor = struct {
    bytes: []const u8,
    flags: fmt.FlagSet,
    pool_offset: u32,
    pool_count: u32,
    /// Zero when `flags.anyComments()` is false.
    comment_pool_offset: u32,
    comment_pool_count: u32,
    roots_offset: u32,
    pos: u32,
    /// Byte position of each string-pool entry's length varint, or null
    /// for the linear walk. Borrowed from the caller by `indexPools`,
    /// never owned and never freed by the cursor.
    string_offsets: ?[]const u32 = null,
    /// The same, for the comment pool. Stays null when the file carries
    /// no comment pool.
    comment_offsets: ?[]const u32 = null,

    /// Validate the header and locate the string pool, comment pool, and
    /// roots block. Does not allocate.
    pub fn init(bytes: []const u8) Error!Cursor {
        // Exact version required — the unknown-version opt-in is a
        // tree-decoder-only concession, so the cursor passes `false`.
        const header = try fmt.parseHeader(bytes, false);
        const flags = header.flags;
        const pool_offset = header.pool_offset;
        const roots_offset = header.roots_offset;

        var p: u32 = pool_offset;
        const pool_count = try fmt.readVarint(bytes, &p);
        if (pool_count > fmt.MAX_STRING_POOL_ENTRIES) return error.NodeCountExceeded;
        const pool_byte_size = try fmt.readVarint(bytes, &p);
        if (pool_byte_size > bytes.len - p) return error.Truncated;
        const after_string_pool = p + pool_byte_size;
        try walkPool(bytes, p, pool_count, after_string_pool, null);

        var comment_pool_offset: u32 = 0;
        var comment_pool_count: u32 = 0;
        var pools_end: u32 = after_string_pool;
        if (flags.anyComments()) {
            comment_pool_offset = after_string_pool;
            var q = after_string_pool;
            comment_pool_count = try fmt.readVarint(bytes, &q);
            if (comment_pool_count > fmt.MAX_STRING_POOL_ENTRIES) return error.NodeCountExceeded;
            const cmt_byte_size = try fmt.readVarint(bytes, &q);
            if (cmt_byte_size > bytes.len - q) return error.Truncated;
            pools_end = q + cmt_byte_size;
            try walkPool(bytes, q, comment_pool_count, pools_end, null);
        }

        // Reject slack bytes between the pools and the roots block. A
        // well-formed encoder writes roots_offset exactly at the pool
        // end, and `Binary.fromBinary` enforces the same equality with
        // its own `pos != roots_offset` check — without this the two
        // decoders would admit different frames (they once did).
        if (pools_end != roots_offset) return error.Truncated;

        // Header validation above already guaranteed these via error
        // returns; assert as a post-condition so future refactors of
        // the header layout can't silently drop a check.
        std.debug.assert(pool_offset == fmt.HEADER_SIZE);
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

    /// Reset position to the start of the roots block, read the root
    /// count, and return an iterator. Multiple `rootIter()` calls are
    /// allowed — each rewinds back to the start.
    pub fn rootIter(c: *Cursor) Error!RootIter {
        c.pos = c.roots_offset;
        const root_count = try fmt.readVarint(c.bytes, &c.pos);
        if (root_count > fmt.MAX_NODES) return error.NodeCountExceeded;
        return .{ .cursor = c, .remaining = root_count };
    }

    /// Borrow the string at pool index `idx`. The returned slice points
    /// into `c.bytes`.
    ///
    /// `O(1)` once `indexPools` has been called, `O(idx)` varint reads
    /// otherwise.
    pub fn lookupString(c: *const Cursor, idx: u32) Error![]const u8 {
        return resolvePool(c.bytes, c.pool_offset, c.pool_count, c.string_offsets, idx);
    }

    /// Borrow the comment text at comment-pool index `idx`. Returns
    /// `error.PoolIndexOutOfRange` when the file has no comment pool.
    pub fn lookupComment(c: *const Cursor, idx: u32) Error![]const u8 {
        if (!c.flags.anyComments()) return error.PoolIndexOutOfRange;
        return resolvePool(c.bytes, c.comment_pool_offset, c.comment_pool_count, c.comment_offsets, idx);
    }

    /// How many `u32`s `indexPools` needs: one per entry across both
    /// pools. Zero for a file with an empty string pool and no comments,
    /// in which case `indexPools` may be handed an empty slice.
    pub fn poolIndexLen(c: *const Cursor) usize {
        return @as(usize, c.pool_count) + @as(usize, c.comment_pool_count);
    }

    /// Attach a caller-owned offset index, turning every subsequent
    /// `lookupString` / `lookupComment` (and every internal head, key,
    /// symbol and unit resolution) into a single varint read.
    ///
    /// `buf` must be exactly `poolIndexLen()` long and must outlive the
    /// cursor; the cursor borrows it and never frees it. Calling this
    /// twice is allowed and idempotent. The cursor still allocates
    /// nothing — the buffer is the caller's.
    ///
    /// Complexity: `O(total pool entries)`, the same single walk `init`
    /// already does to validate the pools.
    pub fn indexPools(c: *Cursor, buf: []u32) void {
        std.debug.assert(buf.len == c.poolIndexLen());

        // SAFETY: `init` read these same two varints off these same bytes
        // and then ran `walkPool` over the result, returning successfully
        // — a cursor cannot exist otherwise. So neither the reads nor the
        // re-walk can fail here, and the recorded offsets are the ones
        // the validating walk visited (it is the same loop, in its second
        // mode) rather than a second opinion that could disagree.
        var p = c.pool_offset;
        _ = fmt.readVarint(c.bytes, &p) catch unreachable; // entry_count
        const byte_size = fmt.readVarint(c.bytes, &p) catch unreachable;
        const strings = buf[0..c.pool_count];
        walkPool(c.bytes, p, c.pool_count, p + byte_size, strings) catch unreachable;
        c.string_offsets = strings;

        if (c.flags.anyComments()) {
            var q = c.comment_pool_offset;
            _ = fmt.readVarint(c.bytes, &q) catch unreachable; // entry_count
            const cmt_size = fmt.readVarint(c.bytes, &q) catch unreachable;
            const comments = buf[c.pool_count..];
            walkPool(c.bytes, q, c.comment_pool_count, q + cmt_size, comments) catch unreachable;
            c.comment_offsets = comments;
        }

        std.debug.assert(c.string_offsets != null);
        std.debug.assert(c.flags.anyComments() == (c.comment_offsets != null));
    }
};

/// Require `count` length-prefixed entries starting at `p` to end exactly
/// at `end` — the pool's declared byte size. `Binary.readPool` enforces
/// the same equality, so the two decoders admit the same frames; without
/// it the cursor took `byte_size` on trust and a short pool let a string
/// index resolve into the roots block. O(count).
///
/// Two modes, one loop. With `offsets` null this is the validating walk
/// `init` does once. With `offsets` non-null (length exactly `count`) it
/// also records where each entry's length varint starts, which is what
/// `indexPools` hands to `resolvePool`. Sharing the loop is the point:
/// an index built by a second traversal could disagree with the walk
/// that validated the pool, and this one cannot.
fn walkPool(bytes: []const u8, start: u32, count: u32, end: u32, offsets: ?[]u32) Error!void {
    std.debug.assert(end <= bytes.len);
    std.debug.assert(offsets == null or offsets.?.len == count);
    var p = start;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (offsets) |o| o[i] = p;
        const len = try fmt.readVarint(bytes, &p);
        if (len > fmt.MAX_STRING_LENGTH) return error.StringTooLong;
        if (len > bytes.len - p) return error.Truncated;
        p += len;
    }
    if (p != end) return error.Truncated;
}

/// Borrow pool entry `idx`. With `offsets` attached the entry's position
/// is a lookup and the cost is one varint; without it the entries are
/// walked from the pool head, `O(idx)`. The bounds check comes first
/// either way, so an out-of-range index is `PoolIndexOutOfRange` in both
/// modes and never an index into `offsets`.
fn resolvePool(
    bytes: []const u8,
    pool_offset: u32,
    pool_count: u32,
    offsets: ?[]const u32,
    idx: u32,
) Error![]const u8 {
    if (idx >= pool_count) return error.PoolIndexOutOfRange;
    var p = if (offsets) |o| o[idx] else blk: {
        var q = pool_offset;
        _ = try fmt.readVarint(bytes, &q); // entry_count
        _ = try fmt.readVarint(bytes, &q); // byte_size
        var i: u32 = 0;
        while (i < idx) : (i += 1) {
            const len = try fmt.readVarint(bytes, &q);
            if (len > bytes.len - q) return error.Truncated;
            q += len;
        }
        break :blk q;
    };
    const len = try fmt.readVarint(bytes, &p);
    if (len > bytes.len - p) return error.Truncated;
    return bytes[p..][0..len];
}

// ---------------------------------------------------------------------------
// Internal: read tag/span/leading_comments header for one node.
// ---------------------------------------------------------------------------

fn nextNodeView(c: *Cursor) Error!NodeView {
    const entry_pos = c.pos;
    if (c.pos >= c.bytes.len) return error.Truncated;
    const tag_byte = c.bytes[c.pos];
    c.pos += 1;
    // Forward-only cursor: every successful `nextNodeView` consumes at
    // least the tag byte. A non-advancing return would loop the caller.
    std.debug.assert(c.pos > entry_pos);
    const span: ?Ast.Span = if (c.flags.with_spans) try readSpanRaw(c) else null;
    const leading_count: u32 = if (c.flags.with_node_comments) blk: {
        const n = try fmt.readVarint(c.bytes, &c.pos);
        if (n > fmt.MAX_COMMENTS_PER_NODE) return error.NodeCountExceeded;
        try skipNComments(c, n);
        break :blk n;
    } else 0;

    const wire_tag = try fmt.tagFromByte(tag_byte);
    const kind: NodeKind = wire_tag.toValueKind();

    return .{
        .kind = kind,
        .span = span,
        .leading_comment_count = leading_count,
        .tag = wire_tag,
    };
}

/// The cursor's local name for a raw span read at the current position;
/// delegates to the shared `fmt.readSpan` so cursor and tree decoder cannot
/// drift on the 8-byte span layout.
fn readSpanRaw(c: *Cursor) Error!Ast.Span {
    return fmt.readSpan(c.bytes, &c.pos);
}

fn skipNComments(c: *Cursor, n: u32) Error!void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (c.pos >= c.bytes.len) return error.Truncated;
        const kind = c.bytes[c.pos];
        if (kind > 1) return error.InvalidTag;
        c.pos += 1;
        if (c.flags.with_spans) _ = try readSpanRaw(c);
        _ = try fmt.readVarint(c.bytes, &c.pos);
    }
}

// ---------------------------------------------------------------------------
// Iterators
// ---------------------------------------------------------------------------

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
    /// Number of trailing comments observed; written when the iterator is
    /// exhausted (0 until then). From wire v5 on, vectors carry a trailing-
    /// comment field symmetric with forms — read this off the iterator after
    /// it returns null, mirroring `ChildIter.trailing_count`.
    trailing_count: u32 = 0,
    trailing_consumed: bool = false,

    pub fn next(self: *VectorIter) Error!?NodeView {
        if (self.remaining == 0) {
            try self.consumeTrailing();
            return null;
        }
        self.remaining -= 1;
        return try nextNodeView(self.cursor);
    }

    fn consumeTrailing(self: *VectorIter) Error!void {
        if (self.trailing_consumed) return;
        self.trailing_consumed = true;
        self.trailing_count = try consumeTrailingComments(self.cursor);
    }
};

pub const ChildIter = struct {
    cursor: *Cursor,
    remaining: u32,
    /// Number of trailing comments observed; written when the iterator
    /// is exhausted (0 until then). This is the live trailing-comment
    /// count for the form — read it off `form.children` after iterating.
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
        self.trailing_count = try consumeTrailingComments(self.cursor);
    }
};

/// Read a node's trailing-comment count and skip its comment entries,
/// advancing `c.pos` past the field. Returns 0 (consuming nothing) when
/// `with_node_comments` is unset. Shared by `ChildIter` (form trailing),
/// `VectorIter` (vector trailing), and `skipBody`'s trailing frame so the
/// three end-of-body reads can't drift.
fn consumeTrailingComments(c: *Cursor) Error!u32 {
    if (!c.flags.with_node_comments) return 0;
    const n = try fmt.readVarint(c.bytes, &c.pos);
    if (n > fmt.MAX_COMMENTS_PER_NODE) return error.NodeCountExceeded;
    try skipNComments(c, n);
    return n;
}

fn readChildEntry(c: *Cursor) Error!ChildEntry {
    if (c.pos >= c.bytes.len) return error.Truncated;
    const child_tag = try fmt.childTagFromByte(c.bytes[c.pos]);
    c.pos += 1;
    switch (child_tag) {
        .positional => {
            const view = try nextNodeView(c);
            return .{ .kind = .positional, .value = view };
        },
        .keyword => {
            const key_span: ?Ast.Span = if (c.flags.with_kvpair_key_spans)
                try readSpanRaw(c)
            else
                null;
            if (c.flags.with_kvpair_comments) {
                const n = try fmt.readVarint(c.bytes, &c.pos);
                if (n > fmt.MAX_COMMENTS_PER_NODE) return error.NodeCountExceeded;
                try skipNComments(c, n);
            }
            const key_idx = try fmt.readVarint(c.bytes, &c.pos);
            const key = try resolvePool(c.bytes, c.pool_offset, c.pool_count, c.string_offsets, key_idx);
            const view = try nextNodeView(c);
            return .{
                .kind = .keyword,
                .key = key,
                .key_span = key_span,
                .value = view,
            };
        },
        else => unreachable,
    }
}

// ---------------------------------------------------------------------------
// Variant-payload consumers — each advances `pos` past its node's payload.
//
// Precondition for every `read*`: the cursor sits at the variant payload of
// `view` (i.e. immediately after the iterator's `nextNodeView` produced it
// and after any leading-comment skip the iterator did). On success `c.pos`
// advances past the payload; on `error.InvalidTag` / `error.Truncated` the
// cursor is left in an unspecified position and must not be reused.
// ---------------------------------------------------------------------------

/// Read a numeric payload as f64. Accepts all three integer-shaped wire
/// tags (`number` 0x03, `number_i64` 0x0B, `number_u64` 0x0C) — integer
/// payloads are lossy-cast to f64 (exact within 2^53). Returns
/// `error.InvalidTag` when `view.kind != .number`, or `error.Truncated`
/// if the buffer is short. Callers that need exact integer bits dispatch
/// on `view.tag` and use `readNumberI64` / `readNumberU64` instead.
/// Complexity: O(1) — single 8-byte little-endian read.
pub fn readNumber(c: *Cursor, view: NodeView) Error!f64 {
    if (view.kind != .number) return error.InvalidTag;
    const bits = try fmt.readU64(c.bytes, &c.pos);
    return switch (view.tag) {
        .number => @bitCast(bits),
        .number_i64 => @floatFromInt(@as(i64, @bitCast(bits))),
        .number_u64 => @floatFromInt(bits),
        else => unreachable, // view.kind == .number gates the three tags above
    };
}

/// Read an exact signed-64-bit payload. Returns `error.InvalidTag` unless
/// the wire tag is `number_i64` (0x0B). On success the cursor advances 8
/// bytes; on `error.Truncated` the cursor is left at the truncation site.
/// Complexity: O(1).
pub fn readNumberI64(c: *Cursor, view: NodeView) Error!i64 {
    if (view.tag != .number_i64) return error.InvalidTag;
    return try fmt.readI64(c.bytes, &c.pos);
}

/// Read an exact unsigned-64-bit payload. Returns `error.InvalidTag`
/// unless the wire tag is `number_u64` (0x0C). On success the cursor
/// advances 8 bytes; on `error.Truncated` the cursor is left at the
/// truncation site. Complexity: O(1).
pub fn readNumberU64(c: *Cursor, view: NodeView) Error!u64 {
    if (view.tag != .number_u64) return error.InvalidTag;
    return try fmt.readU64(c.bytes, &c.pos);
}

/// Read a calendar-date payload `[i16 LE year][u8 month][u8 day]`.
/// Returns `error.InvalidTag` unless `view.kind == .date`. On success
/// the cursor advances 4 bytes. The returned `Date` is validated;
/// out-of-range payloads surface as `error.InvalidTag` (the wire
/// invariant is that emitted dates are constructed, so this is
/// effectively a corrupt-frame signal). Complexity: O(1).
pub fn readDate(c: *Cursor, view: NodeView) Error!Date {
    if (view.kind != .date) return error.InvalidTag;
    return try fmt.readDatePayload(c.bytes, &c.pos);
}

/// Read a clock-time payload `[u8 hour][u8 minute][u8 second][u16 LE ms]`.
/// Returns `error.InvalidTag` unless `view.kind == .time`. On success
/// the cursor advances 5 bytes. The returned `Time` is validated;
/// out-of-range payloads surface as `error.InvalidTag` (the wire
/// invariant is that emitted times are constructed, so this is
/// effectively a corrupt-frame signal). Complexity: O(1).
pub fn readTime(c: *Cursor, view: NodeView) Error!Time {
    if (view.kind != .time) return error.InvalidTag;
    return try fmt.readTimePayload(c.bytes, &c.pos);
}

/// Read a `number_with_unit` payload. The cursor must be positioned on the
/// payload (just past the tag byte); on success the cursor advances past
/// the f64 and varint. Returns `error.InvalidTag` if `view` does not name a
/// unit-bearing number, or `error.Truncated` if the underlying buffer is
/// short.
///
/// Complexity: O(1) — single readInt + varint decode + pool lookup.
/// The returned `unit` slice borrows from `c.bytes` (the string pool).
pub fn readNumberWithUnit(c: *Cursor, view: NodeView) Error!NumberWithUnit {
    if (view.kind != .number_with_unit) return error.InvalidTag;
    std.debug.assert(c.pos <= c.bytes.len); // precondition of the subtraction below
    if (c.bytes.len - c.pos < 8) return error.Truncated;
    const bits = std.mem.readInt(u64, c.bytes[c.pos..][0..8], .little);
    c.pos += 8;
    const unit_idx = try fmt.readVarint(c.bytes, &c.pos);
    const unit = try resolvePool(c.bytes, c.pool_offset, c.pool_count, c.string_offsets, unit_idx);
    // The pool may legitimately hold `""` (an empty string literal), so a
    // crafted frame can point a unit at it. The tree decoder and the JSON
    // bridge both refuse an empty unit; the cursor must too — `Ast`'s
    // `numberWithUnitOf` asserts the invariant downstream.
    if (unit.len == 0) return error.InvalidTag;
    return .{ .value = @bitCast(bits), .unit = unit };
}

/// Read a boolean — the value lives on the wire tag (`bool_false` /
/// `bool_true`), so no payload is consumed and `c.pos` does not move.
/// Returns `error.InvalidTag` for any other tag. Complexity: O(1).
pub fn readBoolean(c: *Cursor, view: NodeView) Error!bool {
    _ = c;
    return switch (view.tag) {
        .bool_false => false,
        .bool_true => true,
        else => error.InvalidTag,
    };
}

/// Read a `nil` payload — empty by construction, so `c.pos` does not
/// move. Returns `error.InvalidTag` when `view.kind != .nil`.
/// Complexity: O(1).
pub fn readNil(c: *Cursor, view: NodeView) Error!void {
    _ = c;
    if (view.kind != .nil) return error.InvalidTag;
}

/// Read a string payload (varint pool index → pool entry). The returned
/// slice borrows from `c.bytes` (the string pool); valid for the cursor's
/// lifetime, never copied.
/// Complexity: O(idx) for the pool walk; the cursor never builds an index.
pub fn readString(c: *Cursor, view: NodeView) Error![]const u8 {
    if (view.kind != .string) return error.InvalidTag;
    const idx = try fmt.readVarint(c.bytes, &c.pos);
    return resolvePool(c.bytes, c.pool_offset, c.pool_count, c.string_offsets, idx);
}

/// Read a keyword payload (varint pool index → pool entry). Returned
/// slice borrows from `c.bytes` and excludes the leading `:` (the pool
/// stores bare names). Same complexity / lifetime as `readString`.
pub fn readKeyword(c: *Cursor, view: NodeView) Error![]const u8 {
    if (view.kind != .keyword) return error.InvalidTag;
    const idx = try fmt.readVarint(c.bytes, &c.pos);
    return resolvePool(c.bytes, c.pool_offset, c.pool_count, c.string_offsets, idx);
}

/// Read a symbol payload (varint pool index → pool entry). Returned
/// slice borrows from `c.bytes`. Same complexity / lifetime as
/// `readString`.
pub fn readSymbol(c: *Cursor, view: NodeView) Error![]const u8 {
    if (view.kind != .symbol) return error.InvalidTag;
    const idx = try fmt.readVarint(c.bytes, &c.pos);
    return resolvePool(c.bytes, c.pool_offset, c.pool_count, c.string_offsets, idx);
}

/// Read a vector header and return a primed iterator over its elements.
/// The iterator borrows the cursor — iterating it advances `c.pos`. Caller
/// must drive the iterator to completion (or use `skipBody`) before the
/// next `nextNodeView` call. Returns `error.NodeCountExceeded` for vectors
/// declaring more than `Binary.MAX_NODES` elements.
/// Complexity: O(1) header read; per-element cost is paid by the iterator.
pub fn readVector(c: *Cursor, view: NodeView) Error!VectorIter {
    if (view.kind != .vector) return error.InvalidTag;
    const count = try fmt.readVarint(c.bytes, &c.pos);
    if (count > fmt.MAX_NODES) return error.NodeCountExceeded;
    return .{ .cursor = c, .remaining = count };
}

/// Read a form header and return a primed `FormView`. Borrowed slices
/// (`head`, `namespace`) point into the string pool; valid for the
/// cursor's lifetime. The `children` iterator borrows the cursor —
/// iterating it advances `c.pos` and (when `view`'s comment flags are
/// set) transparently skips form-trailing comments at end-of-children.
/// Returns `error.NodeCountExceeded` for forms declaring more children
/// than `Binary.MAX_NODES`, `error.InvalidNamespace` for an empty
/// namespace pool entry on a qualified form.
/// Complexity: O(1) header read plus pool walks for `head` / `namespace`.
pub fn readForm(c: *Cursor, view: NodeView) Error!FormView {
    if (view.kind != .form) return error.InvalidTag;
    const head_span: ?Ast.Span = if (c.flags.with_head_spans)
        try readSpanRaw(c)
    else
        null;
    const namespace: ?[]const u8 = if (view.tag == .form_qualified) blk: {
        const idx = try fmt.readVarint(c.bytes, &c.pos);
        const ns = try resolvePool(c.bytes, c.pool_offset, c.pool_count, c.string_offsets, idx);
        if (ns.len == 0) return error.InvalidNamespace;
        break :blk ns;
    } else null;
    const head_idx = try fmt.readVarint(c.bytes, &c.pos);
    const head = try resolvePool(c.bytes, c.pool_offset, c.pool_count, c.string_offsets, head_idx);
    const child_count = try fmt.readVarint(c.bytes, &c.pos);
    if (child_count > fmt.MAX_NODES) return error.NodeCountExceeded;
    return .{
        .head = head,
        .namespace = namespace,
        .head_span = head_span,
        .children = .{ .cursor = c, .remaining = child_count },
    };
}

/// Read the head string of a form node without advancing the cursor.
/// Precondition: `view.kind == .form` and the cursor sits at the form's
/// payload start (just after `nextNodeView` produced `view`). On return,
/// `c.pos` is restored, so a subsequent `readForm(view)` consumes the
/// same form normally. Used by the validator to discover a positional-
/// rejection target's head before the child eval frame runs `readForm`.
pub fn peekFormHead(c: *Cursor, view: NodeView) Error![]const u8 {
    if (view.kind != .form) return error.InvalidTag;
    const saved_pos = c.pos;
    if (c.flags.with_head_spans) _ = try readSpanRaw(c);
    if (view.tag == .form_qualified) _ = try fmt.readVarint(c.bytes, &c.pos);
    const head_idx = try fmt.readVarint(c.bytes, &c.pos);
    const head = try resolvePool(c.bytes, c.pool_offset, c.pool_count, c.string_offsets, head_idx);
    c.pos = saved_pos;
    return head;
}

/// Read a symbol value's text without advancing the cursor. Mirror of
/// `peekFormHead` for the discriminated-form fast path: the validator
/// needs the symbol's text *before* the child eval frame consumes it,
/// so it can resolve which variant the form belongs to. On return,
/// `c.pos` is restored so the eval frame's own `readSymbol(view)` runs
/// normally.
pub fn peekSymbol(c: *Cursor, view: NodeView) Error![]const u8 {
    if (view.kind != .symbol) return error.InvalidTag;
    const saved_pos = c.pos;
    const idx = try fmt.readVarint(c.bytes, &c.pos);
    const sym = try resolvePool(c.bytes, c.pool_offset, c.pool_count, c.string_offsets, idx);
    c.pos = saved_pos;
    return sym;
}

/// Read a keyword value's text (colon-stripped) without advancing the
/// cursor. Mirror of `peekSymbol` for the positional flag-set fast path:
/// the validator needs the flag keyword's text *before* the child eval
/// frame consumes the leaf, so it can test `(flag-set …)` membership.
/// Delegates to `readKeyword` (which advances `c.pos`) between a
/// save/restore, so on return `c.pos` is unchanged and the eval frame's
/// own `readKeyword(view)` runs normally.
pub fn peekKeyword(c: *Cursor, view: NodeView) Error![]const u8 {
    if (view.kind != .keyword) return error.InvalidTag;
    const saved_pos = c.pos;
    defer c.pos = saved_pos;
    return try readKeyword(c, view);
}

/// Reset the cursor's byte position to a previously-recorded value
/// within the same buffer. Intended for **binder-form replay only**:
/// the caller must have drained the surrounding form (via
/// `skipBody` + a terminal `iter.next()` returning null) to a stable
/// post-form position before invoking this, so no sibling frame
/// still holds an expectation about cursor position. Pool metadata
/// (string pool, comment pool, flags) is unchanged — `setPos`
/// repositions within the same wire buffer.
///
/// Misuse (calling from a non-binder context, or while a sibling
/// frame still holds expectations about cursor position) is
/// undefined behavior — runtime-unenforced, same status as the
/// next/read-or-skipBody pairing contract documented at the top of
/// the module. The assertion below catches obvious out-of-buffer
/// writes; the discipline catches everything else.
pub fn setPos(c: *Cursor, pos: u32) void {
    std.debug.assert(pos <= c.bytes.len);
    c.pos = pos;
}

// ---------------------------------------------------------------------------
// skipBody — advance the cursor past the variant payload of `view`,
// recursively skipping any nested children. No allocation.
// ---------------------------------------------------------------------------

const SKIP_STACK_CAP: u32 = fmt.MAX_TREE_DEPTH * 2;

const SkipFrame = struct {
    remaining: u32,
    kind: Kind,
    const Kind = enum(u8) { vector, form_children, trailing_comments };
};

/// Advance past `view`'s payload without producing values, recursively
/// skipping nested vectors and forms. Used by callers that need to
/// reach the next sibling without inspecting the current node (e.g. the
/// validator skipping a malformed subtree). The internal frame stack
/// caps recursion at `Binary.MAX_TREE_DEPTH * 2`; deeper inputs surface
/// as `error.DepthExceeded`. No allocation.
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
            .trailing_comments => {
                _ = try consumeTrailingComments(c);
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
            const count = try fmt.readVarint(c.bytes, &c.pos);
            if (count > fmt.MAX_NODES) return error.NodeCountExceeded;
            if (depth.* + 1 >= frames.len) return error.DepthExceeded;
            // Push trailing first so it pops after elements are exhausted
            // (mirroring the form arm — vectors carry trailing comments from
            // wire v5 on).
            frames[depth.*] = .{ .remaining = 0, .kind = .trailing_comments };
            depth.* += 1;
            frames[depth.*] = .{ .remaining = count, .kind = .vector };
            depth.* += 1;
        },
        .form => {
            if (c.flags.with_head_spans) _ = try readSpanRaw(c);
            if (view.tag == .form_qualified) _ = try fmt.readVarint(c.bytes, &c.pos);
            _ = try fmt.readVarint(c.bytes, &c.pos); // head_idx
            const child_count = try fmt.readVarint(c.bytes, &c.pos);
            if (child_count > fmt.MAX_NODES) return error.NodeCountExceeded;
            if (depth.* + 1 >= frames.len) return error.DepthExceeded;
            // Push trailing first so it pops after children are exhausted.
            frames[depth.*] = .{ .remaining = 0, .kind = .trailing_comments };
            depth.* += 1;
            frames[depth.*] = .{ .remaining = child_count, .kind = .form_children };
            depth.* += 1;
        },
    }
}

fn readChildEntryAsView(c: *Cursor) Error!NodeView {
    if (c.pos >= c.bytes.len) return error.Truncated;
    const child_tag = try fmt.childTagFromByte(c.bytes[c.pos]);
    c.pos += 1;
    switch (child_tag) {
        .positional => return try nextNodeView(c),
        .keyword => {
            if (c.flags.with_kvpair_key_spans) _ = try readSpanRaw(c);
            if (c.flags.with_kvpair_comments) {
                const n = try fmt.readVarint(c.bytes, &c.pos);
                if (n > fmt.MAX_COMMENTS_PER_NODE) return error.NodeCountExceeded;
                try skipNComments(c, n);
            }
            _ = try fmt.readVarint(c.bytes, &c.pos); // key_idx
            return try nextNodeView(c);
        },
        else => unreachable,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn encodeWithStripped(src: [:0]const u8) !Ast.Bytes {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    return try Binary.toBinary(testing.allocator, tree, Binary.ToBinaryOptions.forMode(.compact));
}

test "cursor: header parsing fails on bad magic" {
    var bytes: [16]u8 = undefined;
    @memset(&bytes, 0);
    bytes[0] = 'X';
    bytes[4] = fmt.wire_version;
    try testing.expectError(error.InvalidMagic, Cursor.init(&bytes));
}

test "cursor: walks nil" {
    const bin = try encodeWithStripped("nil");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectEqual(NodeKind.nil, view.kind);
    try readNil(&cursor, view);
    try testing.expect(try iter.next() == null);
}

test "cursor: walks boolean true / false" {
    {
        const bin = try encodeWithStripped("true");
        defer bin.deinit();
        var cursor = try Cursor.init(bin.data);
        var iter = try cursor.rootIter();
        const view = (try iter.next()) orelse unreachable;
        try testing.expectEqual(NodeKind.boolean, view.kind);
        try testing.expect(try readBoolean(&cursor, view));
    }
    {
        const bin = try encodeWithStripped("false");
        defer bin.deinit();
        var cursor = try Cursor.init(bin.data);
        var iter = try cursor.rootIter();
        const view = (try iter.next()) orelse unreachable;
        try testing.expect(!try readBoolean(&cursor, view));
    }
}

test "cursor: walks number bit-exact" {
    const bin = try encodeWithStripped("42.5");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectEqual(@as(f64, 42.5), try readNumber(&cursor, view));
}

test "cursor: walks number_with_unit" {
    const bin = try encodeWithStripped("90deg");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectEqual(NodeKind.number_with_unit, view.kind);
    const nu = try readNumberWithUnit(&cursor, view);
    try testing.expectEqual(@as(f64, 90), nu.value);
    try testing.expectEqualStrings("deg", nu.unit);
}

test "cursor: number_with_unit unit borrows from bin" {
    const bin = try encodeWithStripped("250ms");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    const nu = try readNumberWithUnit(&cursor, view);
    const u_ptr = @intFromPtr(nu.unit.ptr);
    const bin_start = @intFromPtr(bin.data.ptr);
    try testing.expect(u_ptr >= bin_start and u_ptr < bin_start + bin.data.len);
}

test "cursor: a unit pointing at an empty pool entry is InvalidTag, not an assert" {
    // Same crafted frame as the tree decoder's test: `""` is pool entry 0,
    // and the frame's last byte is `1px`'s unit varint (entry 1). Aiming it
    // at entry 0 used to trip `assert(unit.len > 0)` on read.
    const bin = try encodeWithStripped("\"\" 1px");
    defer bin.deinit();
    var poisoned = try testing.allocator.dupe(u8, bin.data);
    defer testing.allocator.free(poisoned);
    try testing.expectEqual(@as(u8, 1), poisoned[poisoned.len - 1]);
    poisoned[poisoned.len - 1] = 0;

    var cursor = try Cursor.init(poisoned);
    var iter = try cursor.rootIter();
    const first = (try iter.next()) orelse unreachable;
    try skipBody(&cursor, first);
    const view = (try iter.next()) orelse unreachable;
    try testing.expectEqual(NodeKind.number_with_unit, view.kind);
    try testing.expectError(error.InvalidTag, readNumberWithUnit(&cursor, view));
}

test "cursor: borrows string" {
    const bin = try encodeWithStripped("\"hello\"");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    const s = try readString(&cursor, view);
    try testing.expectEqualStrings("hello", s);
    // s must alias bin
    const s_ptr = @intFromPtr(s.ptr);
    const bin_start = @intFromPtr(bin.data.ptr);
    try testing.expect(s_ptr >= bin_start and s_ptr < bin_start + bin.data.len);
}

test "cursor: walks vector" {
    const bin = try encodeWithStripped("[1 2 3]");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    var vec = try readVector(&cursor, view);
    var sum: f64 = 0;
    while (try vec.next()) |elem_view| {
        sum += try readNumber(&cursor, elem_view);
    }
    try testing.expectEqual(@as(f64, 6), sum);
}

test "cursor: walks form bare" {
    const bin = try encodeWithStripped("(scene :bpm 130)");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectEqual(NodeKind.form, view.kind);
    var fv = try readForm(&cursor, view);
    try testing.expectEqualStrings("scene", fv.head);
    try testing.expect(fv.namespace == null);
    const child = (try fv.children.next()) orelse unreachable;
    try testing.expectEqual(ChildKind.keyword, child.kind);
    try testing.expectEqualStrings("bpm", child.key.?);
    try testing.expectEqual(@as(f64, 130), try readNumber(&cursor, child.value));
    try testing.expect(try fv.children.next() == null);
}

test "cursor: walks form qualified" {
    const bin = try encodeWithStripped("(masagin/verb :ops 1)");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    var fv = try readForm(&cursor, view);
    try testing.expectEqualStrings("verb", fv.head);
    try testing.expectEqualStrings("masagin", fv.namespace.?);
    while (try fv.children.next()) |entry| try skipBody(&cursor, entry.value);
}

test "cursor: skipBody on nested form" {
    // Two-root tree; the cursor should walk both.
    const bin = try encodeWithStripped("(scene :bpm 130 (canvas [1 2])) 42");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();

    const v1 = (try iter.next()) orelse unreachable;
    try skipBody(&cursor, v1);

    const v2 = (try iter.next()) orelse unreachable;
    try testing.expectEqual(@as(f64, 42), try readNumber(&cursor, v2));
    try testing.expect(try iter.next() == null);
}

test "cursor: skipBody on vector lands at next sibling" {
    const bin = try encodeWithStripped("[1 2 3] 99");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const v1 = (try iter.next()) orelse unreachable;
    try skipBody(&cursor, v1);
    const v2 = (try iter.next()) orelse unreachable;
    try testing.expectEqual(@as(f64, 99), try readNumber(&cursor, v2));
}

test "cursor: skipBody on atom advances correctly" {
    const bin = try encodeWithStripped("\"first\" 7");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const v1 = (try iter.next()) orelse unreachable;
    try skipBody(&cursor, v1);
    const v2 = (try iter.next()) orelse unreachable;
    try testing.expectEqual(@as(f64, 7), try readNumber(&cursor, v2));
}

test "cursor: walks examples/basic.sjon" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const a = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "examples/basic.sjon", a, .unlimited);
    defer a.free(bytes);
    const src = try a.allocSentinel(u8, bytes.len, 0);
    defer a.free(src);
    @memcpy(src, bytes);

    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try Binary.toBinary(a, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();

    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    var node_count: u32 = 0;
    while (try iter.next()) |view| {
        node_count += 1;
        try skipBody(&cursor, view);
    }
    try testing.expectEqual(@as(u32, @intCast(tree.root.len)), node_count);
}

test "cursor: walks examples/with-expressions.sjon visiting same kinds as tree" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const a = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "examples/with-expressions.sjon", a, .unlimited);
    defer a.free(bytes);
    const src = try a.allocSentinel(u8, bytes.len, 0);
    defer a.free(src);
    @memcpy(src, bytes);

    var tree2 = try Parser.parse(a, src);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();

    // Build expected pre-order kind sequence from the Tree.
    var expected: std.ArrayList(NodeKind) = .empty;
    defer expected.deinit(a);
    try walkTreeKinds(a, &tree2, tree2.root, &expected);

    // Walk the cursor pre-order and collect kinds.
    var got: std.ArrayList(NodeKind) = .empty;
    defer got.deinit(a);

    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    while (try iter.next()) |view| {
        try walkCursorKinds(a, &cursor, view, &got);
    }

    try testing.expectEqualSlices(NodeKind, expected.items, got.items);
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
            // Cursor wire format treats kvpair children as child-keyword
            // entries, not standalone nodes — drill through to the value.
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

test "cursor: indexed and unindexed pool lookups agree, entry for entry" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const a = testing.allocator;
    // `.full` so both pools are populated: strings from the heads, keys,
    // symbols and units, comments from the three comment positions.
    const src =
        \\; a leading comment
        \\(camera :ortho true :zoom 2 ; and one on the kvpair
        \\  (lens :focal-length 35mm :name "wide")
        \\  ; a comment among the children
        \\  [1 2 3])
    ;
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try Binary.toBinary(a, tree, Binary.ToBinaryOptions.forMode(.full));
    defer bin.deinit();

    var plain = try Cursor.init(bin.data);
    var indexed = try Cursor.init(bin.data);
    const pool_index = try a.alloc(u32, indexed.poolIndexLen());
    defer a.free(pool_index);
    indexed.indexPools(pool_index);

    // The document has to actually exercise both pools, or the loops
    // below would pass vacuously.
    try testing.expect(plain.pool_count > 1);
    try testing.expect(plain.comment_pool_count > 1);
    try testing.expectEqual(plain.poolIndexLen(), pool_index.len);

    var i: u32 = 0;
    while (i < plain.pool_count) : (i += 1) {
        try testing.expectEqualStrings(try plain.lookupString(i), try indexed.lookupString(i));
    }
    var j: u32 = 0;
    while (j < plain.comment_pool_count) : (j += 1) {
        try testing.expectEqualStrings(try plain.lookupComment(j), try indexed.lookupComment(j));
    }

    // The internal resolutions take the index too, not only the two
    // public lookups: a form head goes through `resolvePool` as well.
    var iter = try indexed.rootIter();
    const view = (try iter.next()) orelse unreachable;
    var fv = try readForm(&indexed, view);
    try testing.expectEqualStrings("camera", fv.head);
    while (try fv.children.next()) |entry| try skipBody(&indexed, entry.value);
}

test "cursor: an out-of-range pool index stays out of range with an index attached" {
    const a = testing.allocator;
    const bin = try encodeWithStripped("(camera :ortho :zoom 2)");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    const pool_index = try a.alloc(u32, cursor.poolIndexLen());
    defer a.free(pool_index);
    cursor.indexPools(pool_index);

    try testing.expectEqualStrings("camera", try cursor.lookupString(2));
    // The bounds check runs before either resolution path, so the index
    // is never itself indexed out of range.
    try testing.expectError(error.PoolIndexOutOfRange, cursor.lookupString(cursor.pool_count));
    try testing.expectError(error.PoolIndexOutOfRange, cursor.lookupString(99));
    // The compact preset carries no comment pool, so the flag guard still
    // fires ahead of the (absent) comment index.
    try testing.expectError(error.PoolIndexOutOfRange, cursor.lookupComment(0));
}

test "cursor: poolIndexLen is zero when neither pool has an entry" {
    const a = testing.allocator;
    const bin = try encodeWithStripped("42 true nil");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    try testing.expectEqual(@as(usize, 0), cursor.poolIndexLen());

    // An empty index is still an index: attaching it is legal, and every
    // lookup is out of range with or without it.
    const pool_index = try a.alloc(u32, 0);
    defer a.free(pool_index);
    cursor.indexPools(pool_index);
    try testing.expectError(error.PoolIndexOutOfRange, cursor.lookupString(0));
}

test "cursor: lookupString resolves first / last entries" {
    const bin = try encodeWithStripped("(camera :ortho :zoom 2)");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    // Pool: zoom(0), ortho(1), camera(2) (sorted by length).
    try testing.expectEqualStrings("zoom", try cursor.lookupString(0));
    try testing.expectEqualStrings("ortho", try cursor.lookupString(1));
    try testing.expectEqualStrings("camera", try cursor.lookupString(2));
    try testing.expectError(error.PoolIndexOutOfRange, cursor.lookupString(3));
}

test "cursor: spans preserved when with_spans=true" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const a = testing.allocator;
    const src = "(scene :bpm 130)";
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try Binary.toBinary(a, tree, .{ .with_spans = true, .with_head_spans = true, .with_kvpair_key_spans = true });
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expect(view.span != null);
    try testing.expectEqual(@as(u32, 0), view.span.?.start);
    try testing.expectEqual(@as(u32, @intCast(src.len)), view.span.?.end);
    var fv = try readForm(&cursor, view);
    try testing.expect(fv.head_span != null);
    while (try fv.children.next()) |entry| try skipBody(&cursor, entry.value);
}

test "cursor: lossless flags expose comment counts" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const a = testing.allocator;
    const src =
        \\; greeting
        \\(scene :bpm 130)
    ;
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try Binary.toBinary(a, tree, Binary.ToBinaryOptions.forMode(.full));
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectEqual(@as(u32, 1), view.leading_comment_count);
    try skipBody(&cursor, view);
}

test "cursor: skipBody on number_with_unit advances correctly" {
    const bin = try encodeWithStripped("90deg 7");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const v1 = (try iter.next()) orelse unreachable;
    try testing.expectEqual(NodeKind.number_with_unit, v1.kind);
    try skipBody(&cursor, v1);
    const v2 = (try iter.next()) orelse unreachable;
    try testing.expectEqual(@as(f64, 7), try readNumber(&cursor, v2));
}

test "cursor: walks vector containing unit numbers" {
    const bin = try encodeWithStripped("[4b 90deg 50% 250ms]");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectEqual(NodeKind.vector, view.kind);
    var vec = try readVector(&cursor, view);
    var seen: u32 = 0;
    while (try vec.next()) |elem| {
        try testing.expectEqual(NodeKind.number_with_unit, elem.kind);
        const nu = try readNumberWithUnit(&cursor, elem);
        try testing.expect(nu.unit.len > 0);
        seen += 1;
    }
    try testing.expectEqual(@as(u32, 4), seen);
}

test "cursor: walks form with KP value being a unit number" {
    const bin = try encodeWithStripped("(scene :angle 90deg)");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    var fv = try readForm(&cursor, view);
    try testing.expectEqualStrings("scene", fv.head);
    const child = (try fv.children.next()) orelse unreachable;
    try testing.expectEqual(ChildKind.keyword, child.kind);
    try testing.expectEqualStrings("angle", child.key.?);
    try testing.expectEqual(NodeKind.number_with_unit, child.value.kind);
    const nu = try readNumberWithUnit(&cursor, child.value);
    try testing.expectEqual(@as(f64, 90), nu.value);
    try testing.expectEqualStrings("deg", nu.unit);
    try testing.expect(try fv.children.next() == null);
}

test "cursor: lookupString resolves unit-pool entry" {
    const bin = try encodeWithStripped("90deg");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    // Single-entry pool with just the unit string.
    try testing.expectEqualStrings("deg", try cursor.lookupString(0));
    try testing.expectError(error.PoolIndexOutOfRange, cursor.lookupString(1));
}

test "cursor: walkCursorKinds returns identical sequence for unit tree" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    // The walker must visit number_with_unit as its own kind, not
    // collapse it onto .number — this pins exhaustive switch arms.
    const a = testing.allocator;
    const src =
        \\(scene
        \\  :angle 90deg
        \\  :z 0.5em
        \\  [4b 50% 250ms])
    ;
    var tree2 = try Parser.parse(a, src);
    defer tree2.deinit();
    const bin = try Binary.toBinary(a, tree2, Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();

    var expected: std.ArrayList(NodeKind) = .empty;
    defer expected.deinit(a);
    try walkTreeKinds(a, &tree2, tree2.root, &expected);

    var got: std.ArrayList(NodeKind) = .empty;
    defer got.deinit(a);
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    while (try iter.next()) |view| try walkCursorKinds(a, &cursor, view, &got);

    try testing.expectEqualSlices(NodeKind, expected.items, got.items);

    // And number_with_unit must actually appear in the sequence.
    var saw_unit = false;
    for (got.items) |k| {
        if (k == .number_with_unit) {
            saw_unit = true;
            break;
        }
    }
    try testing.expect(saw_unit);
}

test "cursor: readNumberWithUnit rejects wrong NodeKind" {
    // A plain .number cannot be read as number_with_unit.
    const bin = try encodeWithStripped("42");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectEqual(NodeKind.number, view.kind);
    try testing.expectError(error.InvalidTag, readNumberWithUnit(&cursor, view));
}

// ---------------------------------------------------------------------------
// Long-tail BinaryCursor tests — read* type-mismatch contracts, lookupString
// boundaries, and rootIter rewind behavior. Cursor's invariants matter
// because the streaming validator and evaluator both lean on them.
// ---------------------------------------------------------------------------

test "cursor: readNumber rejects a non-number view" {
    const bin = try encodeWithStripped("nil");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectError(error.InvalidTag, readNumber(&cursor, view));
}

test "cursor: readBoolean rejects a non-boolean view" {
    const bin = try encodeWithStripped("42");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectError(error.InvalidTag, readBoolean(&cursor, view));
}

test "cursor: readNil rejects a non-nil view" {
    const bin = try encodeWithStripped("42");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectError(error.InvalidTag, readNil(&cursor, view));
}

test "cursor: readString rejects a non-string view" {
    const bin = try encodeWithStripped("42");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectError(error.InvalidTag, readString(&cursor, view));
}

test "cursor: readKeyword rejects a non-keyword view" {
    const bin = try encodeWithStripped("42");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectError(error.InvalidTag, readKeyword(&cursor, view));
}

test "cursor: readSymbol rejects a non-symbol view" {
    const bin = try encodeWithStripped("42");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectError(error.InvalidTag, readSymbol(&cursor, view));
}

test "cursor: readVector rejects a non-vector view" {
    const bin = try encodeWithStripped("42");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectError(error.InvalidTag, readVector(&cursor, view));
}

test "cursor: readForm rejects a non-form view" {
    const bin = try encodeWithStripped("42");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectError(error.InvalidTag, readForm(&cursor, view));
}

test "cursor: rootIter rewinds on each call" {
    // Two calls must each visit every root.
    const bin = try encodeWithStripped("1 2 3");
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);

    // First pass: consume all roots.
    {
        var iter = try cursor.rootIter();
        var count: u32 = 0;
        while (try iter.next()) |view| {
            try skipBody(&cursor, view);
            count += 1;
        }
        try testing.expectEqual(@as(u32, 3), count);
    }
    // Second pass: should see the same count.
    {
        var iter = try cursor.rootIter();
        var count: u32 = 0;
        while (try iter.next()) |view| {
            try skipBody(&cursor, view);
            count += 1;
        }
        try testing.expectEqual(@as(u32, 3), count);
    }
}

test "cursor: lookupString returns PoolIndexOutOfRange beyond pool count" {
    const bin = try encodeWithStripped("\"a\" \"b\" \"c\"");
    defer bin.deinit();
    const cursor = try Cursor.init(bin.data);
    // Pool has exactly 3 distinct entries — index 3 must be rejected.
    try testing.expectError(error.PoolIndexOutOfRange, cursor.lookupString(3));
    try testing.expectError(error.PoolIndexOutOfRange, cursor.lookupString(99));
}

test "cursor: lookupComment without comments flag raises PoolIndexOutOfRange" {
    // The compact preset has no comment pool; lookupComment must surface
    // a clear error rather than silently returning bogus bytes.
    const bin = try encodeWithStripped("(scene)");
    defer bin.deinit();
    const cursor = try Cursor.init(bin.data);
    try testing.expectError(error.PoolIndexOutOfRange, cursor.lookupComment(0));
}

test "cursor: rejects bytes shorter than HEADER_SIZE with Truncated" {
    const short = [_]u8{ 'S', 'J', '1', '\n' };
    try testing.expectError(error.Truncated, Cursor.init(&short));
}

test "cursor: rejects bad magic with InvalidMagic" {
    var bytes: [16]u8 = .{0} ** 16;
    @memcpy(bytes[0..4], "WRNG");
    try testing.expectError(error.InvalidMagic, Cursor.init(&bytes));
}

test "cursor: rejects unknown wire version with InvalidVersion" {
    var bytes: [16]u8 = .{0} ** 16;
    @memcpy(bytes[0..4], &fmt.wire_magic);
    bytes[4] = 0xFF;
    try testing.expectError(error.InvalidVersion, Cursor.init(&bytes));
}

test "cursor: empty roots — rootIter yields zero" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const a = testing.allocator;
    var tree = try Parser.parse(a, "");
    defer tree.deinit();
    const bin = try Binary.toBinary(a, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    try testing.expect(try iter.next() == null);
}

test "cursor: walks a deeply nested form structure without overflow" {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    // 100 levels deep — verify the streaming cursor keeps O(1) state.
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const depth: usize = 100;
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < depth) : (i += 1) try buf.appendSlice(aa, "(x ");
    i = 0;
    while (i < depth) : (i += 1) try buf.append(aa, ')');
    try buf.append(aa, 0);
    const src: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try Binary.toBinary(a, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var cursor = try Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const root = (try iter.next()) orelse unreachable;
    try skipBody(&cursor, root);
    try testing.expect(try iter.next() == null);
}
