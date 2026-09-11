//! SJON Binary IR — wire-format vocabulary (leaf module).
//!
//! The version / magic / size ceilings, the node `Tag` and `ChildTag`
//! enums, the header `Flag` bits + decoded `FlagSet`, the shared `Error`
//! set, the LEB128 varint codec, the fixed-width payload readers, and
//! `tagFromByte` — everything a *reader* needs to make sense of the wire
//! bytes, with no encoder / decoder body.
//!
//! Extracted out of `Binary.zig` so the read-only `sjon-binary.wasm`
//! artifact (via `BinaryCursor`) can reach this vocabulary without pulling
//! in the write-side `Binary` encoder/decoder — that whole module (and its
//! `std.json`-adjacent, tree-building code) must stay out of the read-only
//! closure. This leaf imports only `std`, `Ast`, and the leaf `Date` / `Time`
//! value types (themselves already inside the read-only closure). `Binary.zig`
//! re-exports every declaration here verbatim, so `Binary.<name>` referencers are
//! unaffected and `BinaryCursor.Error == Binary.Error == BinaryFormat.Error`
//! by aliasing.
//!
//! The single wire-format concern that does NOT live here is the
//! `MAX_TREE_DEPTH >= Parser.MAX_PARSE_DEPTH` cross-check: that assert
//! references `Parser`, and importing the parser into this leaf would
//! defeat the extraction, so it stays in `Binary.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Date = @import("Date.zig");
const Time = @import("Time.zig");

// ---------------------------------------------------------------------------
// Wire-format constants
// ---------------------------------------------------------------------------

/// Wire-format version. Decoder rejects unknown versions unless the caller
/// opts in via `FromBinaryOptions.allow_unknown_versions`. v2 adds the
/// exact-integer wire tags `number_i64` (0x0B) and `number_u64` (0x0C);
/// v3 adds `date` (0x0D); v4 adds `time` (0x0E); v5 gives `vector` a
/// trailing-comment field (symmetric with forms) under `with_node_comments`.
/// v1 frames never carry the v2+ tags, v2 frames never carry `date` / `time`,
/// v3 frames never carry `time`, and pre-v5 vectors carry no trailing
/// comments. The decoder accepts exactly `wire_version`, so a given tag or
/// vector is always parsed one way — the lineage above is descriptive, not a
/// per-version branch.
pub const wire_version: u8 = 0x05;

/// Magic bytes at offset 0 of every binary file. The trailing newline trips
/// editors that try to display the file as text and surfaces accidental
/// truncation in CR/LF translation.
pub const wire_magic: [4]u8 = .{ 'S', 'J', '1', '\n' };

/// Fixed header size in bytes.
pub const HEADER_SIZE: u32 = 16;

/// Maximum tree-nesting depth honoured by both encoder and decoder. Must be
/// `>= Parser.MAX_PARSE_DEPTH` so binaries never decode trees the parser
/// couldn't produce; `Binary.zig` cross-checks that against `Parser` with a
/// comptime assert (kept there so this leaf never imports the parser).
/// 1024 levels is two orders of magnitude beyond any realistic hand-written
/// input; bound exists to make depth-bomb inputs fail fast.
pub const MAX_TREE_DEPTH: u32 = 1024;

/// Hard upper bound on total node count in a single binary (1 Mi nodes).
/// Sized so a wire-format counter fits in u32 with three orders of
/// magnitude headroom over the largest fixture (~5 KB SJON ≈ 200 nodes).
pub const MAX_NODES: u32 = 1 << 20;

/// Hard upper bound on string-pool entry count (64 Ki distinct strings).
/// Pool index is a varint that decodes into u32; this cap lets the decoder
/// reject pathological inputs before allocation grows unbounded.
pub const MAX_STRING_POOL_ENTRIES: u32 = 1 << 16;

/// Hard upper bound on a single string's length, in bytes (1 MiB).
/// SJON identifiers and string literals are not designed to carry binary
/// blobs; clamping here lets the decoder allocate a single chunk safely.
pub const MAX_STRING_LENGTH: u32 = 1 << 20;

/// Hard upper bound on comment count attached to a single node / pair.
/// Lossless trees rarely exceed a handful; 256 is a soft engineering cap
/// that keeps the decoder's per-node allocation predictable.
pub const MAX_COMMENTS_PER_NODE: u32 = 256;

/// Hard upper bound on a single comment's text length (64 KiB). Comments
/// are pooled the same way as strings; same rationale, smaller cap.
pub const MAX_COMMENT_TEXT_LENGTH: u32 = 1 << 16;

/// Hard upper bound on total binary file size, in bytes (256 MiB).
/// `wasm32` linear memory tops out at 4 GiB; this cap lets the decoder
/// reject files that would saturate the wasm sandbox before reading them.
pub const MAX_FILE_SIZE: u32 = 1 << 28;

/// Single-byte tag introducing a `Node` payload variant. The wire
/// vocabulary refines `Ast.ValueKind` with two splits that earn wire
/// bytes (no separate flag bytes per node):
///
/// - `bool_true` (0x02) / `bool_false` (0x01) put the truth value on
///   the tag byte itself — booleans have no payload.
/// - `form_bare` (0x08) / `form_qualified` (0x09) signal namespace
///   presence on the tag byte — qualified forms emit one extra
///   varint (the namespace pool index); bare forms don't.
///
/// Wire-byte values are part of the public format and stable across
/// decoder versions. The open-enum (`_`) catch-all lets `Tag` round-
/// trip an unknown byte through the decoder so `tagFromByte` can
/// reject it precisely with `error.InvalidTag`.
///
/// Project to the abstract spine via `toValueKind()`. Project from
/// `Ast.Tag` via `fromAst(ast_tag, has_namespace)` (the encoder).
/// Decode a wire byte via `tagFromByte(b)`.
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
    /// Number literal with a unit suffix. Payload is `[f64 LE 8][varint
    /// unit_pool_idx]`. Decoders that don't recognise this tag fail with
    /// `error.InvalidTag` (the existing unknown-tag path) — that's the
    /// forward-incompat behavior we want without a wire-version bump.
    number_with_unit = 0x0A,
    /// Exact signed 64-bit integer literal. Payload `[i64 LE 8]`. Wire
    /// version `>= 0x02`; v1 frames never carry this tag and v1-only
    /// decoders raise `error.InvalidTag` on it.
    number_i64 = 0x0B,
    /// Exact unsigned 64-bit integer literal. Payload `[u64 LE 8]`. Only
    /// emitted for values in `(i64.max, u64.max]` — below that the encoder
    /// prefers `number_i64`. Wire version `>= 0x02`.
    number_u64 = 0x0C,
    /// Calendar date `(year:i16, month:u8, day:u8)`. Payload is 4 bytes:
    /// `[i16 LE year][u8 month][u8 day]`. Wire version `>= 0x03`; v2
    /// frames never carry this tag and v2-only decoders raise
    /// `error.InvalidTag` on it.
    date = 0x0D,
    /// Clock time `(hour:u8, minute:u8, second:u8, millisecond:u16)`.
    /// Payload is 5 bytes: `[u8 hour][u8 minute][u8 second][u16 LE ms]`.
    /// Wire version `>= 0x04`; v3 frames never carry this tag and
    /// v3-only decoders raise `error.InvalidTag` on it.
    time = 0x0E,
    _,

    /// Project to the abstract value-shape vocabulary. The wire splits
    /// `boolean` (truth on the byte) and `form` (namespace presence on
    /// the byte); both fold here. Unknown tags are `unreachable` —
    /// `tagFromByte` rejects them with `error.InvalidTag` at decode
    /// time, so a `Tag` value observed in code already passed that gate.
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

    /// Project an `Ast.Tag` plus namespace presence into the wire tag.
    /// The encoder calls this when emitting a node header. `kvpair` is
    /// `unreachable`: kvpairs are structural AST nodes, never wire-
    /// encoded as standalone tags — they appear as `ChildTag.keyword`
    /// entries inside a form's children list instead.
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

/// Single-byte tag introducing a `FormChild` entry. Orthogonal to
/// the value-shape vocabulary — `ChildTag` classifies how a form's
/// child appears in source order (positional element vs `:key value`
/// pair), not what kind of value the child holds. A form's children
/// are a sequence of `[ChildTag] [payload]` entries on the wire;
/// each payload starts with a value `Tag` for the child's value node
/// (positional element, or the value side of the keyword pair).
///
/// Two variants only; the open-enum (`_`) catch-all gives
/// `childTagFromByte` a precise rejection path for unknown bytes.
pub const ChildTag = enum(u8) {
    positional = 0x10,
    keyword = 0x11,
    _,
};

/// Bit positions in the 1-byte `flags` header field. `reserved_mask`
/// covers bits the decoder rejects when set.
pub const Flag = struct {
    pub const with_spans: u8 = 1 << 0;
    pub const with_head_spans: u8 = 1 << 1;
    pub const with_kvpair_key_spans: u8 = 1 << 2;
    pub const with_node_comments: u8 = 1 << 3;
    pub const with_kvpair_comments: u8 = 1 << 4;
    pub const with_tree_trailing_comments: u8 = 1 << 5;
    pub const reserved_mask: u8 = 0xC0;
};

// ---------------------------------------------------------------------------
// Wire-format invariants — comptime-enforced so a typo in a constant or a
// stray padding byte trips at build time, not on a hex-diff against a
// stored fixture. Pinning these here means a reader and writer cannot
// drift relative to the layout described in the module header.
// ---------------------------------------------------------------------------

comptime {
    // Header layout: magic(4) + version(1) + flags(1) + reserved(2) +
    // pool_offset(4) + roots_offset(4) = 16. `Binary.toBinary` writes exactly
    // these offsets; `parseHeader` below reads them back.
    std.debug.assert(HEADER_SIZE == 16);
    std.debug.assert(wire_magic.len == 4);
    std.debug.assert(@sizeOf(@TypeOf(wire_version)) == 1);

    // Tag / ChildTag are deliberately u8 — one wire byte per node header.
    std.debug.assert(@sizeOf(Tag) == 1);
    std.debug.assert(@sizeOf(ChildTag) == 1);

    // Flag mask coverage: every bit in the byte is either an active flag
    // or in `reserved_mask`. If a new flag is introduced without updating
    // `reserved_mask`, this catches it.
    const known: u8 = Flag.with_spans | Flag.with_head_spans |
        Flag.with_kvpair_key_spans | Flag.with_node_comments |
        Flag.with_kvpair_comments | Flag.with_tree_trailing_comments;
    std.debug.assert((known & Flag.reserved_mask) == 0);
    std.debug.assert((known | Flag.reserved_mask) == 0xFF);
}

/// Errors `toBinary` / `fromBinary` may return. `OutOfMemory` is the only
/// allocator failure; the rest are deterministic outcomes the caller can
/// surface as diagnostics.
///
/// `DepthExceeded` is shared with `Expr.Error` and `Validator.Error` —
/// the shared name is a deliberate spine across the depth-bounded
/// walkers; `BinaryCursor.Error == Binary.Error` and
/// `Validator.Error == Binary.Error` re-export this set verbatim. Here
/// it means a binary tree nests deeper than `MAX_TREE_DEPTH` during encode or
/// decode (or, when surfaced through `BinaryCursor`, that the cursor's
/// own frame stack is full).
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

// ---------------------------------------------------------------------------
// Parsed flag set (used by encoder/decoder helpers)
// ---------------------------------------------------------------------------

/// Decoded view of the 1-byte `flags` header field.
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

// ---------------------------------------------------------------------------
// Fixed 16-byte header parse
// ---------------------------------------------------------------------------

/// Validated view of the fixed 16-byte wire header.
pub const Header = struct {
    version: u8,
    flags: FlagSet,
    pool_offset: u32,
    roots_offset: u32,
};

/// Parse and validate the fixed 16-byte header. Shared by the tree
/// decoder (`Binary.fromBinary`) and the streaming cursor
/// (`BinaryCursor.Cursor.init`) so the two cannot drift on which frames
/// they admit. Checks, in order: size ceiling, minimum length, magic,
/// version (must equal `wire_version` unless `allow_unknown_versions`),
/// the two reserved bytes, `pool_offset == HEADER_SIZE`, and
/// `pool_offset <= roots_offset <= bytes.len`.
///
/// Does NOT read the string / comment pools — the caller reads those and
/// must still verify they end exactly at `roots_offset` (no slack). That
/// pools-end check is the one acceptance rule this fixed-header parse
/// can't make, and forgetting it is exactly how the two decoders drifted
/// (the cursor once admitted slack the tree decoder rejected).
pub fn parseHeader(bytes: []const u8, allow_unknown_versions: bool) Error!Header {
    if (bytes.len > MAX_FILE_SIZE) return error.NodeCountExceeded;
    if (bytes.len < HEADER_SIZE) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], &wire_magic)) return error.InvalidMagic;
    const version = bytes[4];
    if (version != wire_version and !allow_unknown_versions) return error.InvalidVersion;
    const flags = try FlagSet.fromByte(bytes[5]);
    if (bytes[6] != 0 or bytes[7] != 0) return error.InvalidFlags;
    const pool_offset = std.mem.readInt(u32, bytes[8..12], .little);
    const roots_offset = std.mem.readInt(u32, bytes[12..16], .little);
    if (pool_offset != HEADER_SIZE) return error.InvalidMagic;
    if (roots_offset > bytes.len or roots_offset < pool_offset) return error.Truncated;
    return .{
        .version = version,
        .flags = flags,
        .pool_offset = pool_offset,
        .roots_offset = roots_offset,
    };
}

// ---------------------------------------------------------------------------
// LEB128 varint helpers (unsigned u32)
// ---------------------------------------------------------------------------

/// Append `v` to `out` as an unsigned LEB128 varint. 7 payload bits per
/// byte; high bit set on every byte except the last.
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

/// Read an unsigned LEB128 varint starting at `pos.*`. On success `pos.*`
/// is advanced past the varint. A truncated stream returns
/// `error.Truncated`; a value too large to fit in u32 returns
/// `error.NodeCountExceeded`.
pub fn readVarint(bytes: []const u8, pos: *u32) Error!u32 {
    // Callers thread `pos` monotonically across many calls; an
    // out-of-range starting position would silently fall through to
    // `error.Truncated` below, masking the wiring bug.
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

/// Number of bytes `writeVarint` would emit for `v`.
pub fn varintLen(v: u32) u32 {
    if (v < (@as(u32, 1) << 7)) return 1;
    if (v < (@as(u32, 1) << 14)) return 2;
    if (v < (@as(u32, 1) << 21)) return 3;
    if (v < (@as(u32, 1) << 28)) return 4;
    return 5;
}

// ---------------------------------------------------------------------------
// Fixed-width payload readers
//
// Each reads one node's fixed-width payload starting at `pos.*`, advances
// `pos.*` past it on success, and returns the decoded value. Shared verbatim
// by the tree decoder (`Binary.Decoder`) and the streaming cursor
// (`BinaryCursor`) so the two byte-for-byte agree on payload layout — the
// single source of truth for how a span / f64 / i64 / u64 / date / time sits
// on the wire. A short buffer returns `error.Truncated`; the caller's own
// wire-`Tag` gate (the cursor's `view.kind` checks; the decoder's own tag
// switch) is a precondition, so these trust that the tag already matched.
//
// Callers thread `pos` monotonically, exactly as with `readVarint` — the same
// `(bytes, *pos)` shape. Precondition `pos.* <= bytes.len` holds by
// construction (a preceding tag read advanced it), so `bytes.len - pos.*`
// never underflows.
// ---------------------------------------------------------------------------

/// Read a source span `[u32 LE start][u32 LE end]` (8 bytes).
pub fn readSpan(bytes: []const u8, pos: *u32) Error!Ast.Span {
    std.debug.assert(pos.* <= bytes.len); // `readVarint` states the same precondition
    if (bytes.len - pos.* < 8) return error.Truncated;
    const start = std.mem.readInt(u32, bytes[pos.*..][0..4], .little);
    const end = std.mem.readInt(u32, bytes[pos.* + 4 ..][0..4], .little);
    pos.* += 8;
    return .{ .start = start, .end = end };
}

/// Read an f64 payload `[f64 LE 8]` — the little-endian u64 bit-reinterpreted.
pub fn readF64(bytes: []const u8, pos: *u32) Error!f64 {
    std.debug.assert(pos.* <= bytes.len); // `readVarint` states the same precondition
    if (bytes.len - pos.* < 8) return error.Truncated;
    const bits = std.mem.readInt(u64, bytes[pos.*..][0..8], .little);
    pos.* += 8;
    return @bitCast(bits);
}

/// Read an exact signed 64-bit payload `[i64 LE 8]`.
pub fn readI64(bytes: []const u8, pos: *u32) Error!i64 {
    std.debug.assert(pos.* <= bytes.len); // `readVarint` states the same precondition
    if (bytes.len - pos.* < 8) return error.Truncated;
    const bits = std.mem.readInt(u64, bytes[pos.*..][0..8], .little);
    pos.* += 8;
    return @bitCast(bits);
}

/// Read an exact unsigned 64-bit payload `[u64 LE 8]`.
pub fn readU64(bytes: []const u8, pos: *u32) Error!u64 {
    std.debug.assert(pos.* <= bytes.len); // `readVarint` states the same precondition
    if (bytes.len - pos.* < 8) return error.Truncated;
    const v = std.mem.readInt(u64, bytes[pos.*..][0..8], .little);
    pos.* += 8;
    return v;
}

/// Read a calendar-date payload `[i16 LE year][u8 month][u8 day]` (4 bytes).
/// The `Date` is validated through `Date.init`; an out-of-range payload
/// surfaces as `error.InvalidTag` (emitted dates are always constructed, so a
/// bad one signals a corrupt frame).
pub fn readDatePayload(bytes: []const u8, pos: *u32) Error!Date {
    std.debug.assert(pos.* <= bytes.len); // `readVarint` states the same precondition
    if (bytes.len - pos.* < 4) return error.Truncated;
    const y_lo = bytes[pos.* + 0];
    const y_hi = bytes[pos.* + 1];
    const month = bytes[pos.* + 2];
    const day = bytes[pos.* + 3];
    pos.* += 4;
    const y_bits: u16 = @as(u16, y_lo) | (@as(u16, y_hi) << 8);
    const year: i16 = @bitCast(y_bits);
    return Date.init(year, month, day) catch error.InvalidTag;
}

/// Read a clock-time payload `[u8 hour][u8 minute][u8 second][u16 LE ms]`
/// (5 bytes). Validated through `Time.init`; an out-of-range payload surfaces
/// as `error.InvalidTag` (same corrupt-frame rationale as `readDatePayload`).
pub fn readTimePayload(bytes: []const u8, pos: *u32) Error!Time {
    std.debug.assert(pos.* <= bytes.len); // `readVarint` states the same precondition
    if (bytes.len - pos.* < 5) return error.Truncated;
    const hour = bytes[pos.* + 0];
    const minute = bytes[pos.* + 1];
    const second = bytes[pos.* + 2];
    const ms_lo = bytes[pos.* + 3];
    const ms_hi = bytes[pos.* + 4];
    pos.* += 5;
    const ms: u16 = @as(u16, ms_lo) | (@as(u16, ms_hi) << 8);
    return Time.init(hour, minute, second, ms) catch error.InvalidTag;
}

// ---------------------------------------------------------------------------
// Wire-byte → Tag decode
// ---------------------------------------------------------------------------

/// Decode one wire-byte into a `Tag`. Unknown bytes yield
/// `error.InvalidTag`. Callers that only need the abstract value-shape
/// can chain `.toValueKind()`; callers that need the wire-precise tag
/// (e.g. the encoder's inverse, the streaming validator) keep the
/// `Tag` value.
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

/// Decode one wire-byte into a `ChildTag` — the sibling of `tagFromByte`
/// for a form's child-entry discriminator (`positional` element vs
/// `:key value` pair). Unknown bytes yield `error.InvalidTag`. Matched
/// against the enum's own byte values so the byte ↔ variant mapping has
/// a single source.
pub fn childTagFromByte(b: u8) Error!ChildTag {
    return switch (b) {
        @intFromEnum(ChildTag.positional) => .positional,
        @intFromEnum(ChildTag.keyword) => .keyword,
        else => error.InvalidTag,
    };
}
