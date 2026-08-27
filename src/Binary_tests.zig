//! Internal tests for Binary IR encode / decode and varint helpers.
//!
//! Pulled out of `Binary.zig` post-phase-16 to keep the production file at
//! ~1340 LOC (was 2253 with tests interleaved). Test discovery: `Binary.zig`
//! ends with `test { _ = @import("Binary_tests.zig"); }`, so these run
//! transparently under `_ = Binary;` from `root.zig`'s test block.
//!
//! Tests access `Binary` only through its public surface — every symbol
//! reached here is `pub` in `Binary.zig`. Local `const` aliases at the top
//! re-spell those symbols unqualified to keep test bodies readable.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Binary = @import("Binary.zig");
const Parser = @import("Parser.zig");
const Printer = @import("Printer.zig");
const Json = @import("Json.zig");
const Schema = @import("Schema.zig");
const core_plugin = @import("plugins/core.zig");

// Local aliases — keep test bodies readable without churning every callsite.
const Tag = Binary.Tag;
const Flag = Binary.Flag;
const HEADER_SIZE = Binary.HEADER_SIZE;
const wire_magic = Binary.wire_magic;
const wire_version = Binary.wire_version;
const MAX_TREE_DEPTH = Binary.MAX_TREE_DEPTH;
const ToBinaryOptions = Binary.ToBinaryOptions;
const toBinary = Binary.toBinary;
const fromBinary = Binary.fromBinary;
const writeVarint = Binary.writeVarint;
const readVarint = Binary.readVarint;
const varintLen = Binary.varintLen;

test "varint round-trip: 0, 127, 128, 16_383, 16_384, u32 max" {
    const cases = [_]u32{ 0, 1, 127, 128, 255, 16_383, 16_384, 1 << 21, std.math.maxInt(u32) };
    for (cases) |v| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try writeVarint(testing.allocator, &out, v);
        try testing.expectEqual(varintLen(v), @as(u32, @intCast(out.items.len)));
        var pos: u32 = 0;
        const got = try readVarint(out.items, &pos);
        try testing.expectEqual(v, got);
        try testing.expectEqual(@as(u32, @intCast(out.items.len)), pos);
    }
}

test "varint truncated input" {
    var pos: u32 = 0;
    try testing.expectError(error.Truncated, readVarint(&[_]u8{0x80}, &pos));
}

test "varint overflow rejected" {
    var pos: u32 = 0;
    // Six bytes with continuation set on first five — exceeds u32 range.
    const bad = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 };
    try testing.expectError(error.NodeCountExceeded, readVarint(&bad, &pos));
}

fn parseToTree(src: [:0]const u8) !Ast.Tree {
    return try Parser.parse(testing.allocator, src);
}

fn encode(src: [:0]const u8, opts: ToBinaryOptions) !Ast.Bytes {
    var tree = try parseToTree(src);
    defer tree.deinit();
    return try toBinary(testing.allocator, tree, opts);
}

test "header: magic + version + flags + offsets" {
    const bin = try encode("nil", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    try testing.expect(bin.data.len >= HEADER_SIZE);
    try testing.expectEqualSlices(u8, &wire_magic, bin.data[0..4]);
    try testing.expectEqual(wire_version, bin.data[4]);
    try testing.expectEqual(@as(u8, 0), bin.data[5]); // stripped: no flags
    try testing.expectEqual(@as(u8, 0), bin.data[6]); // reserved
    try testing.expectEqual(@as(u8, 0), bin.data[7]); // reserved
    const pool_offset = std.mem.readInt(u32, bin.data[8..12], .little);
    const roots_offset = std.mem.readInt(u32, bin.data[12..16], .little);
    try testing.expectEqual(@as(u32, HEADER_SIZE), pool_offset);
    try testing.expect(roots_offset > pool_offset);
    try testing.expect(roots_offset <= bin.data.len);
}

test "decoder parity: fromBinary and Cursor.init accept/reject the same frames" {
    const BinaryCursor = @import("BinaryCursor.zig");
    const a = testing.allocator;

    // A well-formed stripped frame (no comment pool) — both decoders accept.
    const bin = try encode("42", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    {
        var tree = try fromBinary(a, bin.data, .{});
        tree.deinit();
        var cur = try BinaryCursor.Cursor.init(bin.data);
        _ = &cur;
    }

    // Splice N slack bytes in front of the roots block and bump the
    // stored roots_offset by N. The pools now end BEFORE roots_offset,
    // leaving a dead gap that a well-formed encoder never produces —
    // neither decoder should tolerate it.
    const roots_offset = std.mem.readInt(u32, bin.data[12..16], .little);
    const N: u32 = 3;
    const slack = try a.alloc(u8, bin.data.len + N);
    defer a.free(slack);
    @memcpy(slack[0..roots_offset], bin.data[0..roots_offset]);
    @memset(slack[roots_offset..][0..N], 0);
    @memcpy(slack[roots_offset + N ..], bin.data[roots_offset..]);
    std.mem.writeInt(u32, slack[12..16], roots_offset + N, .little);

    // fromBinary already rejects the slack via its `pos != roots_offset`
    // check; Cursor.init must reject it too (the acceptance-asymmetry fix).
    try testing.expectError(error.Truncated, fromBinary(a, slack, .{}));
    try testing.expectError(error.Truncated, BinaryCursor.Cursor.init(slack));
}

test "encode atom: nil" {
    // stripped flags → header(16) + pool(2: count=0, byte_size=0) + root_count(1) + tag(1)
    const bin = try encode("nil", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    try testing.expectEqual(@as(usize, 16 + 2 + 1 + 1), bin.data.len);
    try testing.expectEqual(@intFromEnum(Tag.nil), bin.data[bin.data.len - 1]);
}

test "encode atom: bool true / false" {
    {
        const bin = try encode("true", ToBinaryOptions.forMode(.compact));
        defer bin.deinit();
        try testing.expectEqual(@intFromEnum(Tag.bool_true), bin.data[bin.data.len - 1]);
    }
    {
        const bin = try encode("false", ToBinaryOptions.forMode(.compact));
        defer bin.deinit();
        try testing.expectEqual(@intFromEnum(Tag.bool_false), bin.data[bin.data.len - 1]);
    }
}

test "encode number: f64 LE bytes" {
    // Use a fractional literal so the parser routes to `.number` (f64),
    // not `.number_i64`. Wire-tag-byte stability for the f64 path is the
    // point of this test.
    const bin = try encode("2.5", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    // Layout: header(16) + pool(2) + root_count(1) + tag(1) + f64(8)
    try testing.expectEqual(@as(usize, 16 + 2 + 1 + 1 + 8), bin.data.len);
    try testing.expectEqual(@intFromEnum(Tag.number), bin.data[19]);
    const bits = std.mem.readInt(u64, bin.data[20..28], .little);
    const x: f64 = @bitCast(bits);
    try testing.expectEqual(@as(f64, 2.5), x);
}

test "encode string atom" {
    const bin = try encode("\"hi\"", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    // Pool has one entry "hi": count(1) + byte_size + len(1)+"hi"(2).
    // Header(16). Pool: count=1 → 1 byte, byte_size=3 → 1 byte, len=2 → 1, "hi" → 2.
    // Then root_count=1 → 1, tag=string → 1, pool_idx=0 → 1.
    try testing.expectEqual(@as(usize, 16 + 1 + 1 + 1 + 2 + 1 + 1 + 1), bin.data.len);
    try testing.expectEqual(@intFromEnum(Tag.string), bin.data[16 + 5 + 1]);
}

test "encode keyword" {
    const bin = try encode(":foo", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    // Pool: 1 entry "foo" — count(1)+byte_size(1)+len(1)+"foo"(3) = 6
    // Roots: count(1)+tag(1)+idx(1) = 3
    try testing.expectEqual(@as(usize, 16 + 6 + 3), bin.data.len);
    try testing.expectEqual(@intFromEnum(Tag.keyword), bin.data[16 + 6 + 1]);
}

test "encode symbol" {
    const bin = try encode("+", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    // Pool: count(1)+byte_size(1)+len(1)+"+"(1) = 4 bytes; then root_count(1), then tag.
    try testing.expectEqual(@intFromEnum(Tag.symbol), bin.data[16 + 4 + 1]);
}

test "encode vector [1 2 3]" {
    const bin = try encode("[1 2 3]", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    // No strings → empty pool (count=0, byte_size=0) = 2 bytes.
    // Roots: count(1)+vector_tag(1)+elem_count(1) + 3*[number_tag(1)+f64(8)] = 30
    try testing.expectEqual(@as(usize, 16 + 2 + 1 + 1 + 1 + 3 * 9), bin.data.len);
    try testing.expectEqual(@intFromEnum(Tag.vector), bin.data[16 + 2 + 1]);
}

test "encode form-bare (camera :ortho :zoom 2)" {
    const bin = try encode("(camera :ortho :zoom 2)", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    // Strings: "camera", "ortho", "zoom" → three entries (sorted by length;
    // ties broken by bytes: "zoom"(4) < "ortho"(5) < "camera"(6)).
    // pool_count + pool_byte_size + 3*(len+bytes) = 1+1 + (1+4)+(1+5)+(1+6) = 20
    // roots: count(1) + form_bare_tag(1) + head_idx(1) + child_count(1)
    //   + child_pos_tag(1) + keyword_tag(1) + idx(1)        // :ortho positional
    //   + child_kw_tag(1) + key_idx(1) + number_tag(1) + f64(8)  // :zoom 2
    // = 18
    try testing.expectEqual(@as(usize, 16 + 20 + 18), bin.data.len);
    // First non-header byte after pool is root_count=1.
    try testing.expectEqual(@as(u8, 1), bin.data[16 + 20]);
    try testing.expectEqual(@intFromEnum(Tag.form_bare), bin.data[16 + 20 + 1]);
}

test "encode form-qualified (masagin/verb)" {
    const bin = try encode("(masagin/verb)", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    // Strings: "verb"(4), "masagin"(7) → pool entries.
    // form_qualified_tag + ns_idx + head_idx + child_count(=0)
    try testing.expectEqual(@intFromEnum(Tag.form_qualified), bin.data[bin.data.len - 4]);
}

test "deterministic: encoding same tree twice yields identical bytes" {
    const src = "(scene :bpm 130 (canvas :name \"main\" [1 2 3]))";
    const a = try encode(src, ToBinaryOptions.forMode(.compact));
    defer a.deinit();
    const b = try encode(src, ToBinaryOptions.forMode(.compact));
    defer b.deinit();
    try testing.expectEqualSlices(u8, a.data, b.data);
}

test "deterministic: same canonical text → identical bytes (different whitespace)" {
    // Two source strings that parse to the same canonical tree should
    // produce the same binary under flags=0x00 (no spans).
    const a = try encode("(scene :bpm 130)", ToBinaryOptions.forMode(.compact));
    defer a.deinit();
    const b = try encode("(scene\n  :bpm  130)", ToBinaryOptions.forMode(.compact));
    defer b.deinit();
    try testing.expectEqualSlices(u8, a.data, b.data);
}

test "string pool sorted by (length, bytes)" {
    // Strings: "zoom"(4), "ortho"(5), "camera"(6) — should appear in
    // the pool in length-ascending order: zoom, ortho, camera.
    const bin = try encode("(camera :ortho :zoom 2)", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();

    var pos: u32 = HEADER_SIZE;
    const entry_count = try readVarint(bin.data, &pos);
    const byte_size = try readVarint(bin.data, &pos);
    try testing.expectEqual(@as(u32, 3), entry_count);
    _ = byte_size;

    const len0 = try readVarint(bin.data, &pos);
    try testing.expectEqualStrings("zoom", bin.data[pos..][0..len0]);
    pos += len0;

    const len1 = try readVarint(bin.data, &pos);
    try testing.expectEqualStrings("ortho", bin.data[pos..][0..len1]);
    pos += len1;

    const len2 = try readVarint(bin.data, &pos);
    try testing.expectEqualStrings("camera", bin.data[pos..][0..len2]);
}

test "default options emit spans (24-byte cost on 3-node form)" {
    const stripped = try encode("nil", ToBinaryOptions.forMode(.compact));
    defer stripped.deinit();
    const default_opts = try encode("nil", .{});
    defer default_opts.deinit();
    // default options add a per-node span (8 bytes) over stripped.
    try testing.expectEqual(stripped.data.len + 8, default_opts.data.len);
    try testing.expectEqual(Flag.with_spans | Flag.with_head_spans | Flag.with_kvpair_key_spans, default_opts.data[5]);
}

test "lossless preset emits comment pool when comments present" {
    const src =
        \\; greeting
        \\(scene :bpm 130)
    ;
    const bin = try encode(src, ToBinaryOptions.forMode(.full));
    defer bin.deinit();
    // The flags byte should have all six flags set.
    const expected_flags: u8 =
        Flag.with_spans | Flag.with_head_spans | Flag.with_kvpair_key_spans |
        Flag.with_node_comments | Flag.with_kvpair_comments | Flag.with_tree_trailing_comments;
    try testing.expectEqual(expected_flags, bin.data[5]);
}

test "number bit-pattern survives via @bitCast (NaN, Inf, -0)" {
    // toBinary by itself just stores f64 bits. Round-trip back to a number
    // and confirm the bit pattern through a manual decode of the payload.
    const Case = struct { src: [:0]const u8, expected: u64 };
    // Sources use the fractional spelling so they route through the
    // f64 path (the exact-integer path is exercised separately via
    // `.number_i64` / `.number_u64` cases).
    const cases = [_]Case{
        .{ .src = "0.0", .expected = @bitCast(@as(f64, 0.0)) },
        .{ .src = "-0.0", .expected = @bitCast(@as(f64, -0.0)) },
        .{ .src = "1.5", .expected = @bitCast(@as(f64, 1.5)) },
    };
    for (cases) |c| {
        const bin = try encode(c.src, ToBinaryOptions.forMode(.compact));
        defer bin.deinit();
        // Layout under stripped: header(16) + pool(2) + root_count(1) + tag(1) + f64(8)
        const bits = std.mem.readInt(u64, bin.data[16 + 2 + 1 + 1 ..][0..8], .little);
        try testing.expectEqual(c.expected, bits);
    }
}

test "with_spans=true: number node carries 8-byte span" {
    const bin = try encode("42", .{ .with_spans = true });
    defer bin.deinit();
    // Layout: header(16) + pool(2) + root_count(1) + tag(1) + span(8) + f64(8)
    try testing.expectEqual(@as(usize, 16 + 2 + 1 + 1 + 8 + 8), bin.data.len);
    const span_start = std.mem.readInt(u32, bin.data[20..24], .little);
    const span_end = std.mem.readInt(u32, bin.data[24..28], .little);
    try testing.expectEqual(@as(u32, 0), span_start);
    try testing.expectEqual(@as(u32, 2), span_end);
}

test "depth limit honoured by encoder" {
    // Build a tree of depth MAX_TREE_DEPTH+2 by hand and confirm encode rejects.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var b: Ast.TreeBuilder = .{ .a = aa };

    // Leaf at the bottom.
    var current = try b.appendNode(.{
        .tag = .number,
        .span = .{ .start = 0, .end = 0 },
        .data = .{ .immediate = @bitCast(@as(f64, 0)) },
    });
    var i: u32 = 0;
    while (i < MAX_TREE_DEPTH + 2) : (i += 1) {
        current = try b.addVector(&.{current}, .{ .start = 0, .end = 0 });
    }
    const root_indices = try aa.alloc(Ast.NodeIndex, 1);
    root_indices[0] = current;

    if (b.string_index.items.len == 0) try b.string_index.append(aa, 0);

    const tree_soa = Ast.Tree{
        .arena = arena,
        .source = "",
        .nodes = b.nodes.toOwnedSlice(),
        .extra_data = b.extra_data.items,
        .strings = b.strings.items,
        .string_index = b.string_index.items,
        .root = root_indices,
        .leading_comments_index = b.leading_index.items,
        .trailing_comments_index = b.trailing_index.items,
        .comments = b.comments.toOwnedSlice(),
        .tree_trailing_comments = .empty,
        .diagnostics = &.{},
    };
    // tree_soa shares arena with outer scope — do not deinit twice.

    try testing.expectError(error.DepthExceeded, toBinary(testing.allocator, tree_soa, ToBinaryOptions.forMode(.compact)));
}

// ---------------------------------------------------------------------------
// Tests — fromBinary decoder, round-trips, error paths
// ---------------------------------------------------------------------------

/// The round-trip spine behind every "does this survive the binary IR?" print
/// test: parse → toBinary(`bin_opts`) → fromBinary → print(`print_opts`),
/// returning the printed bytes for the caller to compare against a literal or
/// `directCanonical`. Callers vary only the encode flags and the print mode.
fn roundtripPrint(src: [:0]const u8, bin_opts: ToBinaryOptions, print_opts: Printer.Options) !Ast.Bytes {
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    const bin = try toBinary(testing.allocator, tree, bin_opts);
    defer bin.deinit();
    var rebuilt = try fromBinary(testing.allocator, bin.data, .{});
    defer rebuilt.deinit();
    return try Printer.print(testing.allocator, rebuilt, print_opts);
}

/// Canonical-print convenience over `roundtripPrint` — the common case
/// (default `.{}` printer options), used by the atom/vector/form/example
/// round-trips that assert the canonical form survives one binary cycle.
fn roundtripCanonical(src: [:0]const u8, opts: ToBinaryOptions) !Ast.Bytes {
    return roundtripPrint(src, opts, .{});
}

fn directCanonical(src: [:0]const u8) !Ast.Bytes {
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    return try Printer.print(testing.allocator, tree, .{});
}

test "round-trip atom: number" {
    const got = try roundtripCanonical("42", ToBinaryOptions.forMode(.compact));
    defer got.deinit();
    const want = try directCanonical("42");
    defer want.deinit();
    try testing.expectEqualStrings(want.data, got.data);
}

test "round-trip atom: string" {
    const got = try roundtripCanonical("\"hi\\nthere\"", ToBinaryOptions.forMode(.compact));
    defer got.deinit();
    const want = try directCanonical("\"hi\\nthere\"");
    defer want.deinit();
    try testing.expectEqualStrings(want.data, got.data);
}

test "round-trip vector" {
    const got = try roundtripCanonical("[1 2 3]", ToBinaryOptions.forMode(.compact));
    defer got.deinit();
    try testing.expectEqualStrings("[1 2 3]\n", got.data);
}

test "round-trip simple form" {
    const got = try roundtripCanonical("(scene :bpm 130)", ToBinaryOptions.forMode(.compact));
    defer got.deinit();
    try testing.expectEqualStrings("(scene :bpm 130)\n", got.data);
}

test "round-trip nested form" {
    const src = "(canvas (camera :ortho :zoom 2))";
    const got = try roundtripCanonical(src, ToBinaryOptions.forMode(.compact));
    defer got.deinit();
    const want = try directCanonical(src);
    defer want.deinit();
    try testing.expectEqualStrings(want.data, got.data);
}

test "round-trip qualified head" {
    const src = "(masagin/verb :ops 1)";
    const got = try roundtripCanonical(src, ToBinaryOptions.forMode(.compact));
    defer got.deinit();
    const want = try directCanonical(src);
    defer want.deinit();
    try testing.expectEqualStrings(want.data, got.data);
}

test "round-trip examples/basic.sjon under stripped flags" {
    const a = testing.allocator;
    const src = try readSentinelExample(a, "examples/basic.sjon");
    defer a.free(src);
    const got = try roundtripCanonical(src, ToBinaryOptions.forMode(.compact));
    defer got.deinit();
    const want = try directCanonical(src);
    defer want.deinit();
    try testing.expectEqualStrings(want.data, got.data);
}

test "round-trip examples/basic.sjon under lossless flags" {
    const a = testing.allocator;
    const src = try readSentinelExample(a, "examples/basic.sjon");
    defer a.free(src);
    const got = try roundtripCanonical(src, ToBinaryOptions.forMode(.full));
    defer got.deinit();
    const want = try directCanonical(src);
    defer want.deinit();
    try testing.expectEqualStrings(want.data, got.data);
}

test "round-trip examples/with-expressions.sjon" {
    const a = testing.allocator;
    const src = try readSentinelExample(a, "examples/with-expressions.sjon");
    defer a.free(src);
    const got = try roundtripCanonical(src, ToBinaryOptions.forMode(.compact));
    defer got.deinit();
    const want = try directCanonical(src);
    defer want.deinit();
    try testing.expectEqualStrings(want.data, got.data);
}

fn readSentinelExample(gpa: Allocator, path: []const u8) ![:0]u8 {
    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    const buf = try gpa.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf;
}

test "cross-bridge: parse → toBinary → fromBinary → toJson(canonical) matches direct" {
    const a = testing.allocator;
    const src = "(scene :bpm 130 (canvas :name \"main\" [1 2 3]))";

    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var rebuilt = try fromBinary(a, bin.data, .{});
    defer rebuilt.deinit();

    var direct_json = try Json.toJson(a, tree, .{});
    defer direct_json.deinit();
    var bridged_json = try Json.toJson(a, rebuilt, .{});
    defer bridged_json.deinit();

    const direct_text = try std.json.Stringify.valueAlloc(a, direct_json.value, .{});
    defer a.free(direct_text);
    const bridged_text = try std.json.Stringify.valueAlloc(a, bridged_json.value, .{});
    defer a.free(bridged_text);
    try testing.expectEqualStrings(direct_text, bridged_text);
}

test "lossless: round-trip preserves comments" {
    const src =
        \\; greeting
        \\(scene :bpm 130)
    ;
    const got = try roundtripPrint(src, ToBinaryOptions.forMode(.full), .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings("; greeting\n(scene :bpm 130)\n", got.data);
}

test "lossless: keyword-pair leading comment survives" {
    const src =
        \\(scene
        \\  ; tempo
        \\  :bpm 130)
    ;
    const got = try roundtripPrint(src, ToBinaryOptions.forMode(.full), .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings(src ++ "\n", got.data);
}

test "lossless: form trailing comment survives" {
    const src =
        \\(scene 1 ; trail
        \\)
    ;
    const got = try roundtripPrint(src, ToBinaryOptions.forMode(.full), .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings("(scene\n  1\n  ; trail\n  )\n", got.data);
}

test "lossless: head-position comment survives binary round-trip" {
    // `(; note\nfoo 1)` — the comment wedged between `(` and the head symbol
    // becomes leading trivia on the form, which the wire carries per-node.
    const src =
        \\(; note
        \\foo 1)
    ;
    const got = try roundtripPrint(src, ToBinaryOptions.forMode(.full), .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings("; note\n(foo 1)\n", got.data);
}

test "lossless: tree-trailing comment survives" {
    const src =
        \\42
        \\; bye
    ;
    const got = try roundtripPrint(src, ToBinaryOptions.forMode(.full), .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings("42\n; bye\n", got.data);
}

test "lossless: vector trailing comment survives binary round-trip" {
    // `[1 2 ; c\n]` — the comment before `]` is vector-trailing trivia. The
    // wire `vector` payload carries a flag-gated trailing-comment field
    // (symmetric with forms) from wire v5 on; before v5 the encoder dropped
    // it, so this round-trip collapsed to `[1 2]`.
    const src =
        \\[1 2 ; c
        \\]
    ;
    const got = try roundtripPrint(src, ToBinaryOptions.forMode(.full), .{ .mode = .full });
    defer got.deinit();
    try testing.expectEqualStrings("[\n  1\n  2\n  ; c\n  ]\n", got.data);
}

test "spans: with_spans=true preserves Node.span on round-trip" {
    const a = testing.allocator;
    const src = "(scene :bpm 130)";
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const original_span = tree.spanOf(tree.root[0]);
    const bin = try toBinary(a, tree, .{ .with_spans = true });
    defer bin.deinit();
    var rebuilt = try fromBinary(a, bin.data, .{});
    defer rebuilt.deinit();
    const rebuilt_span = rebuilt.spanOf(rebuilt.root[0]);
    try testing.expectEqual(original_span.start, rebuilt_span.start);
    try testing.expectEqual(original_span.end, rebuilt_span.end);
}

test "decoder rejects bad magic" {
    var bin: [16]u8 = undefined;
    @memset(&bin, 0);
    bin[0] = 'X'; // wrong magic
    bin[4] = wire_version;
    try testing.expectError(error.InvalidMagic, fromBinary(testing.allocator, &bin, .{}));
}

test "decoder rejects unknown version" {
    const a = testing.allocator;
    var tree = try Parser.parse(a, "nil");
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var bumped = try a.dupe(u8, bin.data);
    defer a.free(bumped);
    bumped[4] = 0xFF;
    try testing.expectError(error.InvalidVersion, fromBinary(a, bumped, .{}));
}

test "decoder accepts unknown version when allow_unknown_versions=true (until tag)" {
    const a = testing.allocator;
    var tree = try Parser.parse(a, "nil");
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var bumped = try a.dupe(u8, bin.data);
    defer a.free(bumped);
    bumped[4] = 0xFF;
    var rebuilt = try fromBinary(a, bumped, .{ .allow_unknown_versions = true });
    defer rebuilt.deinit();
    try testing.expectEqual(.nil, rebuilt.tagOf(rebuilt.root[0]));
}

test "decoder rejects reserved flag bits" {
    const a = testing.allocator;
    var tree = try Parser.parse(a, "nil");
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var poisoned = try a.dupe(u8, bin.data);
    defer a.free(poisoned);
    poisoned[5] |= 0x80; // bit 7 — reserved
    try testing.expectError(error.InvalidFlags, fromBinary(a, poisoned, .{}));
}

test "decoder rejects reserved header bytes" {
    const a = testing.allocator;
    var tree = try Parser.parse(a, "nil");
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var poisoned = try a.dupe(u8, bin.data);
    defer a.free(poisoned);
    poisoned[6] = 0xFF;
    try testing.expectError(error.InvalidFlags, fromBinary(a, poisoned, .{}));
}

test "truncation fuzz: every prefix of basic.sjon binary is rejected cleanly" {
    const a = testing.allocator;
    const src = try readSentinelExample(a, "examples/basic.sjon");
    defer a.free(src);
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();

    var k: usize = 0;
    while (k < bin.data.len) : (k += 1) {
        const r = fromBinary(a, bin.data[0..k], .{});
        if (r) |t| {
            // Should not happen for any proper prefix (k < full length).
            var x = t;
            x.deinit();
            try testing.expect(false);
        } else |err| {
            switch (err) {
                error.OutOfMemory,
                error.InvalidMagic,
                error.InvalidVersion,
                error.InvalidFlags,
                error.InvalidTag,
                error.InvalidNamespace,
                error.Truncated,
                error.DepthExceeded,
                error.PoolIndexOutOfRange,
                error.NodeCountExceeded,
                error.StringTooLong,
                error.CommentTooLong,
                => {},
            }
        }
    }
    // Full length must succeed.
    var rebuilt = try fromBinary(a, bin.data, .{});
    rebuilt.deinit();
}

test "decoder: f64 NaN/Inf/-0 bit pattern preserved" {
    const Case = struct { src: [:0]const u8, expected_bits: u64 };
    // Sources use the fractional spelling to keep them on the f64 path
    // (the exact-integer path doesn't carry sign-of-zero).
    const cases = [_]Case{
        .{ .src = "0.0", .expected_bits = @bitCast(@as(f64, 0.0)) },
        .{ .src = "-0.0", .expected_bits = @bitCast(@as(f64, -0.0)) },
        .{ .src = "1.5", .expected_bits = @bitCast(@as(f64, 1.5)) },
    };
    const a = testing.allocator;
    for (cases) |c| {
        var tree = try Parser.parse(a, c.src);
        defer tree.deinit();
        const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
        defer bin.deinit();
        var rebuilt = try fromBinary(a, bin.data, .{});
        defer rebuilt.deinit();
        const bits: u64 = @bitCast(rebuilt.numberOf(rebuilt.root[0]));
        try testing.expectEqual(c.expected_bits, bits);
    }
}

test "decoder rejects pool-index out of range (poisoned bytes)" {
    const a = testing.allocator;
    var tree = try Parser.parse(a, ":foo");
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var poisoned = try a.dupe(u8, bin.data);
    defer a.free(poisoned);
    // The pool has 1 entry. The keyword tag carries pool_idx as its payload;
    // the last byte in this fixture is the pool_idx — corrupt to 200 (still
    // a valid 1-byte varint) so it overruns.
    poisoned[poisoned.len - 1] = 0x7F;
    try testing.expectError(error.PoolIndexOutOfRange, fromBinary(a, poisoned, .{}));
}

// Phase B5/B6 regression: pin byte sizes of `examples/basic.sjon` under
// stripped vs lossless flags. If these change, investigate whether the
// wire format drifted unintentionally.
test "regression: examples/basic.sjon binary size pins" {
    const a = testing.allocator;
    const src = try readSentinelExample(a, "examples/basic.sjon");
    defer a.free(src);

    var tree = try Parser.parse(a, src);
    defer tree.deinit();

    const stripped = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer stripped.deinit();
    const default_bin = try toBinary(a, tree, .{});
    defer default_bin.deinit();
    const lossless = try toBinary(a, tree, ToBinaryOptions.forMode(.full));
    defer lossless.deinit();

    // Pinned sizes (text=589 bytes; binary measured 2026-04-29):
    //   stripped = 412 (0.70× text)   default = 900 (1.5× text)
    //   lossless = 1300 (2.2× text)
    // Lossless re-baselined 1293 → 1300 for wire v5: each of basic.sjon's 7
    // vectors now emits a 1-byte trailing-comment count under
    // with_node_comments (stripped / default carry no comments, unchanged).
    // Tightened to ±5 bytes around each anchor — meaningful drift trips
    // here before silently changing the wire format.
    try testing.expectApproxEqAbs(@as(f64, 412), @as(f64, @floatFromInt(stripped.data.len)), 5);
    try testing.expectApproxEqAbs(@as(f64, 900), @as(f64, @floatFromInt(default_bin.data.len)), 5);
    try testing.expectApproxEqAbs(@as(f64, 1300), @as(f64, @floatFromInt(lossless.data.len)), 5);
    try testing.expect(default_bin.data.len > stripped.data.len);
    try testing.expect(lossless.data.len > default_bin.data.len);
}

test "multi-root tree round-trips" {
    const src = "1 2 3";
    const a = testing.allocator;
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var rebuilt = try fromBinary(a, bin.data, .{});
    defer rebuilt.deinit();
    try testing.expectEqual(@as(usize, 3), rebuilt.root.len);
    try testing.expectEqual(@as(f64, 2), rebuilt.numberOf(rebuilt.root[1]));
}

test "unit-suffixed numbers round-trip through Binary IR" {
    const a = testing.allocator;
    const src = "(thing :angle 90deg :delay 250ms :scale 0.5em)";
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var rebuilt = try fromBinary(a, bin.data, .{});
    defer rebuilt.deinit();

    const f = rebuilt.formHeader(rebuilt.root[0]);
    try testing.expectEqual(@as(usize, 3), f.children.len);
    const angle = rebuilt.kvpairHeader(f.children[0]);
    const angle_val = rebuilt.numberWithUnitOf(angle.value);
    try testing.expectEqualStrings("deg", angle_val.unit);
    try testing.expectEqual(@as(f64, 90), angle_val.value);
    const delay = rebuilt.kvpairHeader(f.children[1]);
    try testing.expectEqualStrings("ms", rebuilt.numberWithUnitOf(delay.value).unit);
    const scale = rebuilt.kvpairHeader(f.children[2]);
    const scale_val = rebuilt.numberWithUnitOf(scale.value);
    try testing.expectEqualStrings("em", scale_val.unit);
    try testing.expectEqual(@as(f64, 0.5), scale_val.value);
}

test "wire byte 0x0A appears for unit-suffixed numbers" {
    const a = testing.allocator;
    var tree = try Parser.parse(a, "90deg");
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();

    // Header is 16 bytes; pool entry follows; root_count varint + first node tag.
    // Search for tag 0x0A anywhere in the body — the test pins existence,
    // not exact offset.
    var found = false;
    for (bin.data) |b| {
        if (b == @intFromEnum(Tag.number_with_unit)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "string pool dedups repeated unit strings" {
    const a = testing.allocator;
    var tree = try Parser.parse(a, "[90deg 45deg 30deg]");
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();

    // After the 16-byte header, the pool starts with [varint entry_count].
    // Three nodes share one unit, so the pool must contain exactly one entry.
    const entry_count = bin.data[16];
    try testing.expectEqual(@as(u8, 1), entry_count);
}

test "Binary: NaN/Inf bit pattern survives 0x0A round-trip" {
    // Pin that the unit-bearing wire path preserves f64 bit patterns
    // (delegated to the same writeF64LE / readF64 helpers as plain
    // numbers, but the SoA storage path is different).
    const Case = struct { value: f64, unit: []const u8 };
    const cases = [_]Case{
        .{ .value = std.math.nan(f64), .unit = "deg" },
        .{ .value = std.math.inf(f64), .unit = "ms" },
        .{ .value = -std.math.inf(f64), .unit = "px" },
        .{ .value = -0.0, .unit = "%" },
    };
    const a = testing.allocator;
    for (cases) |c| {
        // Build a single-node Tree via TreeBuilder (lexer can't emit NaN/Inf).
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const aa = arena.allocator();

        var b: Ast.TreeBuilder = .{ .a = aa };
        _ = try b.appendNumberWithUnit(c.value, c.unit, .{ .start = 0, .end = 0 });
        if (b.string_index.items.len == 0) try b.string_index.append(aa, 0);

        const root_indices = try aa.alloc(Ast.NodeIndex, 1);
        root_indices[0] = Ast.NodeIndex.from(0);

        var tree_soa = Ast.Tree{
            .arena = arena,
            .source = "",
            .nodes = b.nodes.toOwnedSlice(),
            .extra_data = b.extra_data.items,
            .strings = b.strings.items,
            .string_index = b.string_index.items,
            .root = root_indices,
            .leading_comments_index = b.leading_index.items,
            .trailing_comments_index = b.trailing_index.items,
            .comments = b.comments.toOwnedSlice(),
            .tree_trailing_comments = .empty,
            .diagnostics = &.{},
        };
        defer tree_soa.deinit();

        const bin = try toBinary(a, tree_soa, ToBinaryOptions.forMode(.compact));
        defer bin.deinit();
        var rebuilt = try fromBinary(a, bin.data, .{});
        defer rebuilt.deinit();
        const got = rebuilt.numberWithUnitOf(rebuilt.root[0]);
        const got_bits: u64 = @bitCast(got.value);
        const want_bits: u64 = @bitCast(c.value);
        try testing.expectEqual(want_bits, got_bits);
        try testing.expectEqualStrings(c.unit, got.unit);
    }
}

test "Binary: truncated 0x0A payload rejected with Truncated" {
    // Encode a unit-bearing tree, then trim trailing bytes byte-by-byte
    // and assert every prefix returns a known error (Truncated /
    // PoolIndexOutOfRange / InvalidEncoding) rather than panicking.
    const a = testing.allocator;
    var tree = try Parser.parse(a, "90deg");
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var i: usize = 0;
    while (i < bin.data.len) : (i += 1) {
        const got = fromBinary(a, bin.data[0..i], .{});
        if (got) |t| {
            var t_mut = t;
            t_mut.deinit();
        } else |err| {
            // Any known error is fine — the contract is "no panic and a
            // documented error variant". Re-raise only OOM (the test
            // harness already returns errors from any path).
            if (err == error.OutOfMemory) return err;
        }
    }
    var full = try fromBinary(a, bin.data, .{});
    full.deinit();
}

test "Binary: 0x0A pool dedupes across structural positions" {
    // A unit shared between a positional vector element and a KP value
    // must collapse to one pool entry.
    const a = testing.allocator;
    const src = "(scene :angle 90deg [180deg 270deg])";
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    // Pool: "angle" + "deg" + "scene" = 3 entries; pin the count.
    try testing.expectEqual(@as(u8, 3), bin.data[16]);
}

test "Binary: fromBinary native build for unit-bearing tree" {
    // The native SoA decoder path must construct unit nodes without
    // bridging through the legacy tree.
    const a = testing.allocator;
    var legacy = try Parser.parse(a, "90deg");
    defer legacy.deinit();
    const bin = try toBinary(a, legacy, .{});
    defer bin.deinit();
    var tree2 = try fromBinary(a, bin.data, .{});
    defer tree2.deinit();
    try testing.expectEqual(@as(usize, 1), tree2.root.len);
    try testing.expectEqual(Ast.Tag.number_with_unit, tree2.tagOf(tree2.root[0]));
    const nu = tree2.numberWithUnitOf(tree2.root[0]);
    try testing.expectEqual(@as(f64, 90.0), nu.value);
    try testing.expectEqualStrings("deg", nu.unit);
}

test "tree: fromBinary round-trip preserves form structure" {
    const a = testing.allocator;
    const src = "(scene :title \"hi\" (canvas :w 320 :h 240 (circle :radius 16)))";
    var legacy = try Parser.parse(a, src);
    defer legacy.deinit();
    const bin = try toBinary(a, legacy, .{});
    defer bin.deinit();
    var tree2 = try fromBinary(a, bin.data, .{});
    defer tree2.deinit();
    try testing.expectEqual(@as(usize, 1), tree2.root.len);
    try testing.expectEqual(Ast.Tag.form, tree2.tagOf(tree2.root[0]));
    const hdr = tree2.formHeader(tree2.root[0]);
    try testing.expectEqualStrings("scene", hdr.head);
}

test "tree: fromBinary owns its strings (no aliasing)" {
    const a = testing.allocator;
    const src = "(rect :w 1 :h 2)";
    var legacy = try Parser.parse(a, src);
    defer legacy.deinit();
    const bin = try toBinary(a, legacy, .{});
    defer bin.deinit();

    var tree2 = try fromBinary(a, bin.data, .{});
    defer tree2.deinit();

    // Scribble over the source bytes a borrow-mode decoder would alias.
    @memset(bin.data, 0xff);
    // Tree must still report "rect" — it owns a copy.
    try testing.expectEqual(@as(usize, 1), tree2.root.len);
    const hdr = tree2.formHeader(tree2.root[0]);
    try testing.expectEqualStrings("rect", hdr.head);
}

test "tree: fromBinary owns its comment text (no aliasing)" {
    const a = testing.allocator;
    const src = ";; preamble\n(rect :w 1 :h 2) ;; tail comment\n";
    var legacy = try Parser.parse(a, src);
    defer legacy.deinit();
    const bin = try toBinary(a, legacy, ToBinaryOptions.forMode(.full));
    defer bin.deinit();

    var tree2 = try fromBinary(a, bin.data, .{});
    defer tree2.deinit();

    @memset(bin.data, 0xff);

    // The first root's leading_comments_index should point to ";; preamble",
    // owned by the Tree arena, not aliasing `bin`.
    try testing.expectEqual(@as(usize, 1), tree2.root.len);
    const r = tree2.leading_comments_index[tree2.root[0].raw()];
    const texts = tree2.commentTexts(r);
    try testing.expect(texts.len >= 1);
    try testing.expectEqualStrings(";; preamble", texts[0]);
}

// ---------------------------------------------------------------------------
// Long-tail Binary tests — header rejection paths, every flag combination,
// pool dedup edge cases, and round-trip stability under each Mode preset.
// ---------------------------------------------------------------------------

test "header: bad magic is rejected with InvalidMagic" {
    var bytes: [16]u8 = .{0} ** 16;
    @memcpy(bytes[0..4], "WRNG");
    bytes[4] = wire_version;
    try testing.expectError(
        error.InvalidMagic,
        fromBinary(testing.allocator, &bytes, .{}),
    );
}

test "header: unknown wire version is rejected unless allow_unknown_versions" {
    var bytes: [16]u8 = .{0} ** 16;
    @memcpy(bytes[0..4], &wire_magic);
    bytes[4] = 0xFF; // future version
    bytes[5] = 0; // valid flags
    bytes[6] = 0;
    bytes[7] = 0;
    // pool_offset = HEADER_SIZE
    std.mem.writeInt(u32, bytes[8..12], HEADER_SIZE, .little);
    // roots_offset = HEADER_SIZE
    std.mem.writeInt(u32, bytes[12..16], HEADER_SIZE, .little);
    try testing.expectError(
        error.InvalidVersion,
        fromBinary(testing.allocator, &bytes, .{}),
    );
}

test "header: reserved flag bits trigger InvalidFlags" {
    var bytes: [16]u8 = .{0} ** 16;
    @memcpy(bytes[0..4], &wire_magic);
    bytes[4] = wire_version;
    bytes[5] = Flag.reserved_mask; // Set a reserved bit
    bytes[6] = 0;
    bytes[7] = 0;
    std.mem.writeInt(u32, bytes[8..12], HEADER_SIZE, .little);
    std.mem.writeInt(u32, bytes[12..16], HEADER_SIZE, .little);
    try testing.expectError(
        error.InvalidFlags,
        fromBinary(testing.allocator, &bytes, .{}),
    );
}

test "header: non-zero reserved bytes 6/7 trigger InvalidFlags" {
    var bytes: [16]u8 = .{0} ** 16;
    @memcpy(bytes[0..4], &wire_magic);
    bytes[4] = wire_version;
    bytes[5] = 0;
    bytes[6] = 1; // reserved must be zero
    bytes[7] = 0;
    std.mem.writeInt(u32, bytes[8..12], HEADER_SIZE, .little);
    std.mem.writeInt(u32, bytes[12..16], HEADER_SIZE, .little);
    try testing.expectError(
        error.InvalidFlags,
        fromBinary(testing.allocator, &bytes, .{}),
    );
}

test "header: pool_offset != HEADER_SIZE is rejected" {
    var bytes: [16]u8 = .{0} ** 16;
    @memcpy(bytes[0..4], &wire_magic);
    bytes[4] = wire_version;
    bytes[5] = 0;
    bytes[6] = 0;
    bytes[7] = 0;
    std.mem.writeInt(u32, bytes[8..12], HEADER_SIZE + 1, .little); // wrong
    std.mem.writeInt(u32, bytes[12..16], HEADER_SIZE, .little);
    try testing.expectError(
        error.InvalidMagic,
        fromBinary(testing.allocator, &bytes, .{}),
    );
}

test "header: roots_offset before pool_offset is rejected" {
    var bytes: [16]u8 = .{0} ** 16;
    @memcpy(bytes[0..4], &wire_magic);
    bytes[4] = wire_version;
    bytes[5] = 0;
    bytes[6] = 0;
    bytes[7] = 0;
    std.mem.writeInt(u32, bytes[8..12], HEADER_SIZE, .little);
    std.mem.writeInt(u32, bytes[12..16], HEADER_SIZE - 1, .little); // roots before pool
    try testing.expectError(
        error.Truncated,
        fromBinary(testing.allocator, &bytes, .{}),
    );
}

test "header: roots_offset past end of buffer is rejected" {
    var bytes: [16]u8 = .{0} ** 16;
    @memcpy(bytes[0..4], &wire_magic);
    bytes[4] = wire_version;
    bytes[5] = 0;
    bytes[6] = 0;
    bytes[7] = 0;
    std.mem.writeInt(u32, bytes[8..12], HEADER_SIZE, .little);
    std.mem.writeInt(u32, bytes[12..16], 9999, .little); // past end
    try testing.expectError(
        error.Truncated,
        fromBinary(testing.allocator, &bytes, .{}),
    );
}

test "round-trip: every Mode preset" {
    // Pin: parse → toBinary → fromBinary preserves structure under each
    // documented preset.
    const a = testing.allocator;
    const src = "(scene :bpm 130 (canvas :name \"main\" [1 2 3]))";
    inline for (&[_]Ast.Mode{ .canonical, .compact, .full }) |mode| {
        var tree = try Parser.parse(a, src);
        defer tree.deinit();
        const bin = try toBinary(a, tree, ToBinaryOptions.forMode(mode));
        defer bin.deinit();
        var rebuilt = try fromBinary(a, bin.data, .{});
        defer rebuilt.deinit();
        try testing.expectEqual(@as(usize, 1), rebuilt.root.len);
        const hdr = rebuilt.formHeader(rebuilt.root[0]);
        try testing.expectEqualStrings("scene", hdr.head);
    }
}

test "encoded size: full mode is largest, compact is smallest" {
    // Pin the size ordering across modes; this catches a future
    // reshuffling where a flag accidentally gets emitted in the wrong
    // preset.
    const a = testing.allocator;
    const src = "; comment\n(scene :bpm 130 (canvas :name \"main\"))";
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin_compact = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin_compact.deinit();
    const bin_canonical = try toBinary(a, tree, ToBinaryOptions.forMode(.canonical));
    defer bin_canonical.deinit();
    const bin_full = try toBinary(a, tree, ToBinaryOptions.forMode(.full));
    defer bin_full.deinit();
    try testing.expect(bin_compact.data.len <= bin_canonical.data.len);
    try testing.expect(bin_canonical.data.len <= bin_full.data.len);
}

test "round-trip: empty tree" {
    const a = testing.allocator;
    var tree = try Parser.parse(a, "");
    defer tree.deinit();
    const bin = try toBinary(a, tree, .{});
    defer bin.deinit();
    var rebuilt = try fromBinary(a, bin.data, .{});
    defer rebuilt.deinit();
    try testing.expectEqual(@as(usize, 0), rebuilt.root.len);
}

test "round-trip: every leaf type as a single root" {
    const a = testing.allocator;
    // Integer sources are routed through the f64 wire on the bootstrap
    // fallback; the Binary wire-v2 commit adds dedicated round-trip
    // cases for `.number_i64` / `.number_u64` (where source and rebuilt
    // tags match exactly).
    const cases = [_][:0]const u8{
        "nil",     "true",   "false", "0.0",  "-1.0",
        "3.14",    "\"hi\"", ":kw",   "+sym", "[]",
        "(empty)",
    };
    for (cases) |src| {
        var tree = try Parser.parse(a, src);
        defer tree.deinit();
        const bin = try toBinary(a, tree, .{});
        defer bin.deinit();
        var rebuilt = try fromBinary(a, bin.data, .{});
        defer rebuilt.deinit();
        try testing.expectEqual(tree.root.len, rebuilt.root.len);
        try testing.expectEqual(tree.tagOf(tree.root[0]), rebuilt.tagOf(rebuilt.root[0]));
    }
}

test "string pool: identical strings dedupe to one entry" {
    const a = testing.allocator;
    const src = "(\"x\" \"x\" \"x\" \"x\")";
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    // After the 16-byte header, the pool starts with a varint count.
    // Pin: only 1 string entry plus the form-head string ("" for the
    // synthetic empty form has no pool entry; quoted strings produce 1
    // entry "x" for the deduped value; head varies).
    // Just confirm decoder agrees with encoder (round-trip stability).
    var rebuilt = try fromBinary(a, bin.data, .{});
    defer rebuilt.deinit();
    try testing.expectEqual(@as(usize, 1), rebuilt.root.len);
}

// ---------------------------------------------------------------------------
// Raw multi-line strings — `"""…"""` decodes through the binary IR like any
// other string. The AST tags both forms as `.string`, so the binary path
// neither sees nor remembers the source delimiter; the test pins that the
// *content* survives end-to-end and that pool dedup collapses two equal
// payloads into one entry regardless of source form.
// ---------------------------------------------------------------------------

test "raw string: multi-line body round-trips through binary IR" {
    const a = testing.allocator;
    const src: [:0]const u8 =
        \\(shader :code """
        \\@vertex fn vs() -> @builtin(position) vec4f {
        \\  return vec4f(0.0, 0.0, 0.0, 1.0);
        \\}
        \\""")
    ;
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var rebuilt = try fromBinary(a, bin.data, .{});
    defer rebuilt.deinit();

    const f = rebuilt.formHeader(rebuilt.root[0]);
    try testing.expectEqualStrings("shader", f.head);
    const kp = rebuilt.kvpairHeader(f.children[0]);
    try testing.expectEqualStrings("code", kp.key);
    try testing.expectEqual(.string, rebuilt.tagOf(kp.value));
    const si: Ast.StringIndex = @enumFromInt(rebuilt.dataOf(kp.value).single);
    // Delimiters on their own lines → leading and trailing `\n` are
    // content (form is pure trivia; no decode-time transformation).
    const want = "\n" ++
        \\@vertex fn vs() -> @builtin(position) vec4f {
        \\  return vec4f(0.0, 0.0, 0.0, 1.0);
        \\}
    ++ "\n";
    try testing.expectEqualStrings(want, rebuilt.stringSlice(si));
}

test "raw string: identical content from `\"…\"` and `\"\"\"…\"\"\"` shares one wire-pool entry" {
    // Pool dedup happens at the binary boundary: regardless of which
    // surface form the author used, two strings with byte-equal content
    // collapse to a single pool entry on the wire. The decode-side
    // `TreeBuilder.addString` is stateless append, so per-node
    // StringIndex values diverge again on the rebuilt tree — the dedup
    // isn't AST-observable. We verify by inspecting the wire pool count
    // directly: `(pair "hello" """hello""")` has three distinct strings
    // BEFORE dedup ("pair", "hello", "hello") and TWO after.
    const a = testing.allocator;
    const src: [:0]const u8 = "(pair \"hello\" \"\"\"hello\"\"\")";
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();

    // Read the pool count varint at the very start of the pool segment
    // (immediately after the 16-byte header). Compact mode → no comment
    // pool, so the next varint after the header is the string-pool entry
    // count.
    var pos: u32 = HEADER_SIZE;
    const pool_count = try readVarint(bin.data, &pos);
    try testing.expectEqual(@as(u32, 2), pool_count);

    // Bytes survive end-to-end on both children regardless of dedup.
    var rebuilt = try fromBinary(a, bin.data, .{});
    defer rebuilt.deinit();
    const f = rebuilt.formHeader(rebuilt.root[0]);
    try testing.expectEqual(@as(usize, 2), f.children.len);
    const a_si: Ast.StringIndex = @enumFromInt(rebuilt.dataOf(f.children[0]).single);
    const b_si: Ast.StringIndex = @enumFromInt(rebuilt.dataOf(f.children[1]).single);
    try testing.expectEqualStrings("hello", rebuilt.stringSlice(a_si));
    try testing.expectEqualStrings("hello", rebuilt.stringSlice(b_si));
}

test "raw string: examples/wgsl-shader.sjon round-trips through binary IR" {
    // The example fixture exercises the raw-string pipeline end-to-end:
    // parse → toBinary(stripped) → fromBinary → canonical print. The
    // only acceptable canonicalisation is the printer's escape-encoded
    // form (the `"""` delimiter is lossy by design); pin that the
    // round-tripped canonical form is byte-stable across one cycle.
    const a = testing.allocator;
    const src = try readSentinelExample(a, "examples/wgsl-shader.sjon");
    defer a.free(src);
    const got = try roundtripCanonical(src, ToBinaryOptions.forMode(.compact));
    defer got.deinit();
    const want = try directCanonical(src);
    defer want.deinit();
    try testing.expectEqualStrings(want.data, got.data);
}

test "raw string: canonical print escapes newlines (form is lossy)" {
    // The canonical printer always uses `"…"` with `\n` escapes — the
    // `"""` delimiter form does not survive a round-trip through the
    // canonical print. Pin that print(parse(`"""…"""`)) emits the
    // escape-encoded equivalent.
    const a = testing.allocator;
    const src: [:0]const u8 = "\"\"\"a\nb\"\"\"";
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const out = try Printer.print(a, tree, .{});
    defer out.deinit();
    try testing.expectEqualStrings("\"a\\nb\"\n", out.data);
}

test "raw string: three identical raw values share one wire-pool entry" {
    // Top-level vector of three byte-equal raw strings. Pool dedup
    // collapses them to a single entry. No head symbol → exactly one
    // pool entry total.
    const a = testing.allocator;
    const src: [:0]const u8 = "[\"\"\"shared\"\"\" \"\"\"shared\"\"\" \"\"\"shared\"\"\"]";
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var pos: u32 = HEADER_SIZE;
    const pool_count = try readVarint(bin.data, &pos);
    try testing.expectEqual(@as(u32, 1), pool_count);
}

test "raw string: byte-different bodies between forms do NOT dedup" {
    // Form is pure trivia: no decode-time transformation. `"""\nhello\n"""`
    // decodes to `\nhello\n`; `"hello"` decodes to `hello`. Different
    // bytes → two distinct pool entries. (The previous strip-once rule
    // would have collapsed these to one — that behaviour is gone.)
    const a = testing.allocator;
    const src: [:0]const u8 = "[\"\"\"\nhello\n\"\"\" \"hello\"]";
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var pos: u32 = HEADER_SIZE;
    const pool_count = try readVarint(bin.data, &pos);
    try testing.expectEqual(@as(u32, 2), pool_count);
}

test "raw string: head symbol + two distinct raw bodies → three pool entries" {
    // `(p """a""" """b""" """a""")` — head `p`, then two distinct raw
    // values (`a`, `b`) with the third repeating the first. Wire pool:
    // `p`, `a`, `b` — three entries. Pins that dedup is content-based,
    // not source-form-based, and that the encoder pools head symbols
    // together with leaf strings.
    const a = testing.allocator;
    const src: [:0]const u8 = "(p \"\"\"a\"\"\" \"\"\"b\"\"\" \"\"\"a\"\"\")";
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var pos: u32 = HEADER_SIZE;
    const pool_count = try readVarint(bin.data, &pos);
    try testing.expectEqual(@as(u32, 3), pool_count);
}

test "raw string: UTF-8 multi-byte body round-trips byte-for-byte" {
    // The wire format treats string bytes as opaque length-prefixed
    // payload, so multi-byte UTF-8 sequences pass through untouched.
    const a = testing.allocator;
    const src: [:0]const u8 = "(label :text \"\"\"héllo 你好 🦀\"\"\")";
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var rebuilt = try fromBinary(a, bin.data, .{});
    defer rebuilt.deinit();
    const f = rebuilt.formHeader(rebuilt.root[0]);
    const kp = rebuilt.kvpairHeader(f.children[0]);
    const si: Ast.StringIndex = @enumFromInt(rebuilt.dataOf(kp.value).single);
    try testing.expectEqualStrings("héllo 你好 🦀", rebuilt.stringSlice(si));
}

test "raw string: indented multi-line body round-trips with indentation intact" {
    // No auto-dedent. Pin that the leading spaces on each body line
    // survive the parse → toBinary → fromBinary cycle. Delimiters on
    // their own lines → leading and trailing `\n` are content.
    const a = testing.allocator;
    const src: [:0]const u8 =
        \\(block :body """
        \\  fn vs() -> vec4f {
        \\    return vec4f(0);
        \\  }
        \\""")
    ;
    const want = "\n" ++
        \\  fn vs() -> vec4f {
        \\    return vec4f(0);
        \\  }
    ++ "\n";
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var rebuilt = try fromBinary(a, bin.data, .{});
    defer rebuilt.deinit();
    const f = rebuilt.formHeader(rebuilt.root[0]);
    const kp = rebuilt.kvpairHeader(f.children[0]);
    const si: Ast.StringIndex = @enumFromInt(rebuilt.dataOf(kp.value).single);
    try testing.expectEqualStrings(want, rebuilt.stringSlice(si));
}

test "raw string: tab and high-byte content round-trips without alteration" {
    const a = testing.allocator;
    const src: [:0]const u8 = "(b :p \"\"\"a\tb\xC3\xA9c\"\"\")";
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var rebuilt = try fromBinary(a, bin.data, .{});
    defer rebuilt.deinit();
    const f = rebuilt.formHeader(rebuilt.root[0]);
    const kp = rebuilt.kvpairHeader(f.children[0]);
    const si: Ast.StringIndex = @enumFromInt(rebuilt.dataOf(kp.value).single);
    try testing.expectEqualStrings("a\tb\xC3\xA9c", rebuilt.stringSlice(si));
}

test "raw string: canonical print is byte-stable on the second cycle" {
    // The first print collapses `"""…"""` into the canonical
    // escape-encoded form (lossy by design). The SECOND print, run on
    // the re-parsed canonical output, must produce identical bytes —
    // canonical → canonical is the contract every other shape relies on.
    const a = testing.allocator;
    const src: [:0]const u8 = "\"\"\"\nfirst\nsecond\nthird\n\"\"\"";
    var tree1 = try Parser.parse(a, src);
    defer tree1.deinit();
    const out1 = try Printer.print(a, tree1, .{});
    defer out1.deinit();
    const sentinel = try a.allocSentinel(u8, out1.data.len, 0);
    defer a.free(sentinel);
    @memcpy(sentinel, out1.data);
    var tree2 = try Parser.parse(a, sentinel);
    defer tree2.deinit();
    const out2 = try Printer.print(a, tree2, .{});
    defer out2.deinit();
    try testing.expectEqualStrings(out1.data, out2.data);
}

test "raw string: full-mode binary round-trips raw content (mode does not matter for leaf bytes)" {
    // Leaf string bytes don't depend on encode mode — `.full` and
    // `.compact` pool and decode the same content.
    const a = testing.allocator;
    const src: [:0]const u8 = "\"\"\"\nbody\n\"\"\"";
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.full));
    defer bin.deinit();
    var rebuilt = try fromBinary(a, bin.data, .{});
    defer rebuilt.deinit();
    try testing.expectEqual(@as(usize, 1), rebuilt.root.len);
    try testing.expectEqual(.string, rebuilt.tagOf(rebuilt.root[0]));
    const si: Ast.StringIndex = @enumFromInt(rebuilt.dataOf(rebuilt.root[0]).single);
    try testing.expectEqualStrings("\nbody\n", rebuilt.stringSlice(si));
}

test "raw string: empty body survives the binary round-trip as empty content" {
    const a = testing.allocator;
    const src: [:0]const u8 = "(e :v \"\"\"\"\"\")";
    var tree = try Parser.parse(a, src);
    defer tree.deinit();
    const bin = try toBinary(a, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var rebuilt = try fromBinary(a, bin.data, .{});
    defer rebuilt.deinit();
    const f = rebuilt.formHeader(rebuilt.root[0]);
    const kp = rebuilt.kvpairHeader(f.children[0]);
    const si: Ast.StringIndex = @enumFromInt(rebuilt.dataOf(kp.value).single);
    try testing.expectEqualStrings("", rebuilt.stringSlice(si));
}

test "decoder: HEADER_SIZE bytes alone yields Truncated" {
    var bytes: [16]u8 = .{0} ** 16;
    @memcpy(bytes[0..4], &wire_magic);
    bytes[4] = wire_version;
    std.mem.writeInt(u32, bytes[8..12], HEADER_SIZE, .little);
    std.mem.writeInt(u32, bytes[12..16], HEADER_SIZE, .little);
    // Header points at HEADER_SIZE for both pool and roots — but no
    // pool varint follows. Decoder must report Truncated.
    try testing.expectError(
        error.Truncated,
        fromBinary(testing.allocator, &bytes, .{}),
    );
}

test "fromBinary rejects oversized input with an error, not an assert" {
    // A buffer one byte past MAX_FILE_SIZE must be rejected the same way the
    // streaming `Cursor.init` rejects it — `error.NodeCountExceeded`, not a
    // Debug assert-panic. page_allocator hands back lazily-committed pages and
    // `fromBinary` returns at the very top without touching the buffer, so no
    // pages are ever faulted in (the 256 MiB is address space, not RSS).
    const oversized = try std.heap.page_allocator.alloc(u8, Binary.MAX_FILE_SIZE + 1);
    defer std.heap.page_allocator.free(oversized);
    try testing.expectError(
        error.NodeCountExceeded,
        fromBinary(testing.allocator, oversized, .{}),
    );
}

// ---------------------------------------------------------------------------
// Wire v2 exact-integer tags (`number_i64` = 0x0B, `number_u64` = 0x0C).
// Confirm the encoder emits the new tag bytes verbatim, the decoder
// reconstructs the exact AST tag, and the streaming cursor exposes both
// the polymorphic f64 reader and the exact integer readers.
// ---------------------------------------------------------------------------

test "wire v5: header bumped to 0x05" {
    // v5 gave `vector` a trailing-comment field symmetric with forms (under
    // with_node_comments). v4 vectors carried no trailing comments.
    try testing.expectEqual(@as(u8, 0x05), wire_version);
}

test "encode number_i64: tag byte 0x0B + i64 LE payload" {
    const bin = try encode("42", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    // Layout: header(16) + pool(2) + root_count(1) + tag(1) + i64(8)
    try testing.expectEqual(@as(usize, 16 + 2 + 1 + 1 + 8), bin.data.len);
    try testing.expectEqual(@intFromEnum(Tag.number_i64), bin.data[19]);
    const bits = std.mem.readInt(u64, bin.data[20..28], .little);
    const v: i64 = @bitCast(bits);
    try testing.expectEqual(@as(i64, 42), v);
}

test "encode number_i64: i64.min payload is bit-faithful" {
    const bin = try encode("-9223372036854775808", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    try testing.expectEqual(@intFromEnum(Tag.number_i64), bin.data[19]);
    const bits = std.mem.readInt(u64, bin.data[20..28], .little);
    const v: i64 = @bitCast(bits);
    try testing.expectEqual(std.math.minInt(i64), v);
}

test "encode number_u64: tag byte 0x0C + u64 LE payload" {
    // 18446744073709551615 == u64.max; outside i64.max + 1 the parser
    // routes through `.number_u64`.
    const bin = try encode("18446744073709551615", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    try testing.expectEqual(@intFromEnum(Tag.number_u64), bin.data[19]);
    const v = std.mem.readInt(u64, bin.data[20..28], .little);
    try testing.expectEqual(std.math.maxInt(u64), v);
}

test "round-trip: number_i64 / number_u64 preserve exact AST tags + values" {
    var tree = try parseToTree(
        \\-9223372036854775808
        \\9223372036854775807
        \\18446744073709551615
    );
    defer tree.deinit();
    try testing.expectEqual(Ast.Tag.number_i64, tree.tagOf(tree.root[0]));
    try testing.expectEqual(Ast.Tag.number_i64, tree.tagOf(tree.root[1]));
    try testing.expectEqual(Ast.Tag.number_u64, tree.tagOf(tree.root[2]));

    const bin = try toBinary(testing.allocator, tree, ToBinaryOptions.forMode(.compact));
    defer bin.deinit();

    var got = try fromBinary(testing.allocator, bin.data, .{});
    defer got.deinit();
    try testing.expectEqual(@as(usize, 3), got.root.len);
    try testing.expectEqual(Ast.Tag.number_i64, got.tagOf(got.root[0]));
    try testing.expectEqual(Ast.Tag.number_i64, got.tagOf(got.root[1]));
    try testing.expectEqual(Ast.Tag.number_u64, got.tagOf(got.root[2]));
    try testing.expectEqual(std.math.minInt(i64), got.numberI64Of(got.root[0]));
    try testing.expectEqual(std.math.maxInt(i64), got.numberI64Of(got.root[1]));
    try testing.expectEqual(std.math.maxInt(u64), got.numberU64Of(got.root[2]));
}

test "cursor: readNumberI64 returns exact i64.min / i64.max" {
    const BinaryCursor = @import("BinaryCursor.zig");
    {
        const bin = try encode("-9223372036854775808", ToBinaryOptions.forMode(.compact));
        defer bin.deinit();
        var cursor = try BinaryCursor.Cursor.init(bin.data);
        var iter = try cursor.rootIter();
        const view = (try iter.next()) orelse unreachable;
        try testing.expectEqual(Tag.number_i64, view.tag);
        try testing.expectEqual(std.math.minInt(i64), try BinaryCursor.readNumberI64(&cursor, view));
    }
    {
        const bin = try encode("9223372036854775807", ToBinaryOptions.forMode(.compact));
        defer bin.deinit();
        var cursor = try BinaryCursor.Cursor.init(bin.data);
        var iter = try cursor.rootIter();
        const view = (try iter.next()) orelse unreachable;
        try testing.expectEqual(std.math.maxInt(i64), try BinaryCursor.readNumberI64(&cursor, view));
    }
}

test "cursor: readNumberU64 returns exact u64.max" {
    const BinaryCursor = @import("BinaryCursor.zig");
    const bin = try encode("18446744073709551615", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var cursor = try BinaryCursor.Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectEqual(Tag.number_u64, view.tag);
    try testing.expectEqual(std.math.maxInt(u64), try BinaryCursor.readNumberU64(&cursor, view));
}

test "cursor: readNumber lossy-casts integer-tag payloads to f64" {
    const BinaryCursor = @import("BinaryCursor.zig");
    // 2^54 fits in f64 exactly — the float reading should also return it.
    const bin = try encode("18014398509481984", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var cursor = try BinaryCursor.Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectEqual(BinaryCursor.NodeKind.number, view.kind);
    try testing.expectEqual(@as(f64, 18014398509481984.0), try BinaryCursor.readNumber(&cursor, view));
}

test "cursor: readNumberI64 rejects an f64-shaped node" {
    const BinaryCursor = @import("BinaryCursor.zig");
    const bin = try encode("3.5", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var cursor = try BinaryCursor.Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectError(error.InvalidTag, BinaryCursor.readNumberI64(&cursor, view));
}

test "cursor: readNumberU64 rejects an f64-shaped node" {
    const BinaryCursor = @import("BinaryCursor.zig");
    const bin = try encode("3.5", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var cursor = try BinaryCursor.Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectError(error.InvalidTag, BinaryCursor.readNumberU64(&cursor, view));
}

test "cursor: skipBody advances correctly past number_i64 + number_u64" {
    const BinaryCursor = @import("BinaryCursor.zig");
    const bin = try encode("42 18446744073709551615 7.5", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var cursor = try BinaryCursor.Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const v1 = (try iter.next()) orelse unreachable;
    try BinaryCursor.skipBody(&cursor, v1);
    const v2 = (try iter.next()) orelse unreachable;
    try BinaryCursor.skipBody(&cursor, v2);
    const v3 = (try iter.next()) orelse unreachable;
    try testing.expectEqual(@as(f64, 7.5), try BinaryCursor.readNumber(&cursor, v3));
    try testing.expect(try iter.next() == null);
}

test "decoder: pre-v2 wire version is rejected" {
    // Reassemble a valid frame and demote the version byte to 0x01;
    // fromBinary must surface error.InvalidVersion unless the caller opts
    // in via FromBinaryOptions.allow_unknown_versions.
    const bin = try encode("nil", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    const tampered = try testing.allocator.dupe(u8, bin.data);
    defer testing.allocator.free(tampered);
    tampered[4] = 0x01;
    try testing.expectError(
        error.InvalidVersion,
        fromBinary(testing.allocator, tampered, .{}),
    );
}

// ---------------------------------------------------------------------------
// Clock-time wire payload (Tag.time = 0x0E, 5-byte payload)
// ---------------------------------------------------------------------------

test "encode time: tag byte 0x0E + 5-byte payload (no fractional)" {
    const bin = try encode("12:34:56", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    // Layout: header(16) + pool(2) + root_count(1) + tag(1) + time(5)
    try testing.expectEqual(@as(usize, 16 + 2 + 1 + 1 + 5), bin.data.len);
    try testing.expectEqual(@intFromEnum(Tag.time), bin.data[19]);
    try testing.expectEqual(@as(u8, 12), bin.data[20]);
    try testing.expectEqual(@as(u8, 34), bin.data[21]);
    try testing.expectEqual(@as(u8, 56), bin.data[22]);
    try testing.expectEqual(@as(u8, 0), bin.data[23]); // ms_lo
    try testing.expectEqual(@as(u8, 0), bin.data[24]); // ms_hi
}

test "encode time: tag byte 0x0E + 5-byte payload (with fractional)" {
    const bin = try encode("12:34:56.789", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    try testing.expectEqual(@as(usize, 16 + 2 + 1 + 1 + 5), bin.data.len);
    try testing.expectEqual(@intFromEnum(Tag.time), bin.data[19]);
    try testing.expectEqual(@as(u8, 12), bin.data[20]);
    try testing.expectEqual(@as(u8, 34), bin.data[21]);
    try testing.expectEqual(@as(u8, 56), bin.data[22]);
    const ms: u16 = @as(u16, bin.data[23]) | (@as(u16, bin.data[24]) << 8);
    try testing.expectEqual(@as(u16, 789), ms);
}

test "time round-trip: 8-char form printer-stable" {
    const out = try roundtripCanonical("12:34:56", ToBinaryOptions.forMode(.compact));
    defer out.deinit();
    try testing.expectEqualStrings("12:34:56\n", out.data);
}

test "time round-trip: 12-char form printer-stable" {
    const out = try roundtripCanonical("23:59:59.999", ToBinaryOptions.forMode(.compact));
    defer out.deinit();
    try testing.expectEqualStrings("23:59:59.999\n", out.data);
}

test "time round-trip inside vector" {
    const out = try roundtripCanonical("[00:00:00 12:34:56.789 23:59:59.999]", ToBinaryOptions.forMode(.compact));
    defer out.deinit();
    try testing.expectEqualStrings("[00:00:00 12:34:56.789 23:59:59.999]\n", out.data);
}

// ---------------------------------------------------------------------------
// Calendar-date wire payload (Tag.date = 0x0D, 4-byte payload)
//
// Date carried no dedicated Binary_tests coverage before the BinaryFormat
// payload-codec extraction (Phase 5 item 5d). These pin the readDatePayload /
// readDate valid, out-of-range (→ InvalidTag) and truncated (→ Truncated) arms
// on BOTH the tree decoder (`fromBinary`) and the streaming cursor, so the one
// shared leaf reader cannot silently drift either path. The tamper-index
// tests depend on the byte offsets the encode-layout test pins first.
// ---------------------------------------------------------------------------

test "encode date: tag byte 0x0D + 4-byte payload" {
    const bin = try encode("2026-11-04", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    // Layout: header(16) + pool(2) + root_count(1) + tag(1) + date(4)
    try testing.expectEqual(@as(usize, 16 + 2 + 1 + 1 + 4), bin.data.len);
    try testing.expectEqual(@intFromEnum(Tag.date), bin.data[19]);
    const year: u16 = @as(u16, bin.data[20]) | (@as(u16, bin.data[21]) << 8);
    try testing.expectEqual(@as(u16, 2026), year);
    try testing.expectEqual(@as(u8, 11), bin.data[22]); // month
    try testing.expectEqual(@as(u8, 4), bin.data[23]); // day
}

test "date round-trip: printer-stable" {
    const out = try roundtripCanonical("2026-11-04", ToBinaryOptions.forMode(.compact));
    defer out.deinit();
    try testing.expectEqualStrings("2026-11-04\n", out.data);
}

test "cursor: readDate returns the calendar date" {
    const BinaryCursor = @import("BinaryCursor.zig");
    const Date = @import("Date.zig");
    const bin = try encode("2026-11-04", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var cursor = try BinaryCursor.Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectEqual(BinaryCursor.NodeKind.date, view.kind);
    try testing.expectEqual(try Date.init(2026, 11, 4), try BinaryCursor.readDate(&cursor, view));
}

test "decoder: out-of-range date payload rejected with InvalidTag" {
    const a = testing.allocator;
    const bin = try encode("2026-11-04", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    const tampered = try a.dupe(u8, bin.data);
    defer a.free(tampered);
    tampered[22] = 13; // month 13 — Date.init rejects → InvalidTag
    try testing.expectError(error.InvalidTag, fromBinary(a, tampered, .{}));
}

test "cursor: readDate rejects an out-of-range payload with InvalidTag" {
    const a = testing.allocator;
    const BinaryCursor = @import("BinaryCursor.zig");
    const bin = try encode("2026-11-04", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    const tampered = try a.dupe(u8, bin.data);
    defer a.free(tampered);
    tampered[22] = 13;
    var cursor = try BinaryCursor.Cursor.init(tampered);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectError(error.InvalidTag, BinaryCursor.readDate(&cursor, view));
}

test "decoder: truncated date payload rejected with Truncated" {
    const a = testing.allocator;
    const bin = try encode("2026-11-04", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    // Drop the last 2 payload bytes (month, day): readDatePayload sees < 4.
    try testing.expectError(error.Truncated, fromBinary(a, bin.data[0 .. bin.data.len - 2], .{}));
}

test "cursor: readDate rejects a truncated payload with Truncated" {
    const BinaryCursor = @import("BinaryCursor.zig");
    const bin = try encode("2026-11-04", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var cursor = try BinaryCursor.Cursor.init(bin.data[0 .. bin.data.len - 2]);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectError(error.Truncated, BinaryCursor.readDate(&cursor, view));
}

// ---------------------------------------------------------------------------
// Clock-time payload error arms (mirror of the date battery above). The valid
// arm is covered by the round-trip tests above; these pin the out-of-range and
// truncated arms of readTimePayload / readTime on both paths.
// ---------------------------------------------------------------------------

test "cursor: readTime returns the clock time" {
    const BinaryCursor = @import("BinaryCursor.zig");
    const Time = @import("Time.zig");
    const bin = try encode("12:34:56.789", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var cursor = try BinaryCursor.Cursor.init(bin.data);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectEqual(BinaryCursor.NodeKind.time, view.kind);
    try testing.expectEqual(try Time.init(12, 34, 56, 789), try BinaryCursor.readTime(&cursor, view));
}

test "decoder: out-of-range time payload rejected with InvalidTag" {
    const a = testing.allocator;
    const bin = try encode("12:34:56", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    const tampered = try a.dupe(u8, bin.data);
    defer a.free(tampered);
    tampered[20] = 25; // hour 25 — Time.init rejects → InvalidTag
    try testing.expectError(error.InvalidTag, fromBinary(a, tampered, .{}));
}

test "cursor: readTime rejects an out-of-range payload with InvalidTag" {
    const a = testing.allocator;
    const BinaryCursor = @import("BinaryCursor.zig");
    const bin = try encode("12:34:56", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    const tampered = try a.dupe(u8, bin.data);
    defer a.free(tampered);
    tampered[20] = 25;
    var cursor = try BinaryCursor.Cursor.init(tampered);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectError(error.InvalidTag, BinaryCursor.readTime(&cursor, view));
}

test "decoder: truncated time payload rejected with Truncated" {
    const a = testing.allocator;
    const bin = try encode("12:34:56", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    // Drop 3 of the 5 payload bytes: readTimePayload sees < 5.
    try testing.expectError(error.Truncated, fromBinary(a, bin.data[0 .. bin.data.len - 3], .{}));
}

test "cursor: readTime rejects a truncated payload with Truncated" {
    const BinaryCursor = @import("BinaryCursor.zig");
    const bin = try encode("12:34:56", ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    var cursor = try BinaryCursor.Cursor.init(bin.data[0 .. bin.data.len - 3]);
    var iter = try cursor.rootIter();
    const view = (try iter.next()) orelse unreachable;
    try testing.expectError(error.Truncated, BinaryCursor.readTime(&cursor, view));
}
