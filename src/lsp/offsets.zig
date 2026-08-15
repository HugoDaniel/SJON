//! Byte-offset ↔ LSP `Position` conversion for the WASM target.
//!
//! Native uses `lsp.offsets` from lsp-kit. The WASM target deliberately
//! avoids lsp-kit (to keep the artifact small and freestanding-clean),
//! so this is a small drop-in equivalent covering only what the SJON
//! LSP currently emits.
//!
//! One place it is deliberately *not* a drop-in: line terminators. LSP
//! counts `\n`, `\r\n` and a lone `\r`; lsp-kit counts `\n` only. This copy
//! faces the playground, whose editor (CodeMirror) splits on all three, so
//! it implements the spec rule — see `isLineBreak`. `main.zig`'s
//! `OffsetMapper` records why native keeps lsp-kit's narrower rule.

const std = @import("std");

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Encoding = enum { @"utf-8", @"utf-16", @"utf-32" };

/// True when `source[i]` ends a line. LSP counts all three terminators —
/// `\n`, `\r\n`, and a lone `\r` — so a `\r` is a break only when it is not
/// the first half of a pair; the `\n` of a `\r\n` does that pair's counting.
/// Both directions below share this predicate so they cannot drift.
fn isLineBreak(source: []const u8, i: usize) bool {
    return switch (source[i]) {
        '\n' => true,
        '\r' => i + 1 >= source.len or source[i + 1] != '\n',
        else => false,
    };
}

/// Index of the first terminator byte at or after `line_start`, or
/// `source.len` for the last line. This is where the line's *content* ends;
/// the terminator itself is not part of it.
fn lineContentEnd(source: []const u8, line_start: usize) usize {
    var i: usize = line_start;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n' or source[i] == '\r') return i;
    }
    return source.len;
}

/// Convert a byte index into the (line, character) pair LSP uses.
/// `character` is counted in code units of `encoding`.
pub fn indexToPosition(source: []const u8, index: usize, encoding: Encoding) Position {
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    const stop = @min(index, source.len);
    while (i < stop) : (i += 1) {
        if (isLineBreak(source, i)) {
            line += 1;
            line_start = i + 1;
        }
    }
    // `stop` can land on the `\n` of a `\r\n`, which is no more nameable as
    // a Position than the middle of a codepoint is — the pair is one
    // indivisible break. Clamp to the line's content so such an index
    // reports the end of the line it terminates.
    const line_slice = source[line_start..@min(stop, lineContentEnd(source, line_start))];
    const character: u32 = switch (encoding) {
        .@"utf-8" => @intCast(line_slice.len),
        .@"utf-16" => countUtf16CodeUnits(line_slice),
        .@"utf-32" => countCodepoints(line_slice),
    };
    return .{ .line = line, .character = character };
}

fn countUtf16CodeUnits(bytes: []const u8) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            // Malformed UTF-8: count the byte as one code unit and advance.
            n += 1;
            i += 1;
            continue;
        };
        if (i + len > bytes.len) break;
        const cp = std.unicode.utf8Decode(bytes[i .. i + len]) catch {
            n += 1;
            i += 1;
            continue;
        };
        n += if (cp >= 0x10000) @as(u32, 2) else 1;
        i += len;
    }
    return n;
}

fn countCodepoints(bytes: []const u8) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            n += 1;
            i += 1;
            continue;
        };
        // A sequence clipped by the end of the slice is not a codepoint yet.
        // Its three siblings all refuse one; counting it here made utf-32 the
        // one encoding whose two directions disagreed — the character came
        // back on the way out and `codepointsToByteCount` refused it on the
        // way in, leaving the trailing bytes unaddressable.
        if (i + len > bytes.len) break;
        i += len;
        n += 1;
    }
    return n;
}

/// Convert an LSP `Position` back to a byte index. Out-of-range lines clamp
/// to the end of the source; out-of-range characters clamp to the end of the
/// line (a typical client behaviour when the cursor sits on virtual whitespace).
pub fn positionToIndex(source: []const u8, position: Position, encoding: Encoding) usize {
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len and line < position.line) : (i += 1) {
        if (isLineBreak(source, i)) {
            line += 1;
            line_start = i + 1;
        }
    }
    if (line < position.line) return source.len;

    const line_slice = source[line_start..lineContentEnd(source, line_start)];
    const offset_in_line = nCodeUnitsToByteCount(line_slice, position.character, encoding);
    return line_start + offset_in_line;
}

fn nCodeUnitsToByteCount(bytes: []const u8, n: u32, encoding: Encoding) usize {
    return switch (encoding) {
        .@"utf-8" => @min(n, bytes.len),
        .@"utf-16" => utf16CodeUnitsToByteCount(bytes, n),
        .@"utf-32" => codepointsToByteCount(bytes, n),
    };
}

fn utf16CodeUnitsToByteCount(bytes: []const u8, n: u32) usize {
    var consumed: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len and consumed < n) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            consumed += 1;
            i += 1;
            continue;
        };
        if (i + len > bytes.len) break;
        const cp = std.unicode.utf8Decode(bytes[i .. i + len]) catch {
            consumed += 1;
            i += 1;
            continue;
        };
        const units: u32 = if (cp >= 0x10000) 2 else 1;
        if (consumed + units > n) break;
        consumed += units;
        i += len;
    }
    return i;
}

fn codepointsToByteCount(bytes: []const u8, n: u32) usize {
    var consumed: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len and consumed < n) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            consumed += 1;
            i += 1;
            continue;
        };
        if (i + len > bytes.len) break;
        consumed += 1;
        i += len;
    }
    return i;
}

test "indexToPosition: ASCII single line" {
    const src = "abcdef";
    const p = indexToPosition(src, 3, .@"utf-16");
    try std.testing.expectEqual(@as(u32, 0), p.line);
    try std.testing.expectEqual(@as(u32, 3), p.character);
}

test "indexToPosition: across newline" {
    const src = "abc\ndef";
    const p = indexToPosition(src, 5, .@"utf-16");
    try std.testing.expectEqual(@as(u32, 1), p.line);
    try std.testing.expectEqual(@as(u32, 1), p.character);
}

test "indexToPosition: surrogate-pair char counts as 2 utf-16 units" {
    // U+1F600 = 4 UTF-8 bytes ("\xF0\x9F\x98\x80"), 2 UTF-16 code units.
    const src = "a\xF0\x9F\x98\x80b";
    const p = indexToPosition(src, src.len, .@"utf-16");
    try std.testing.expectEqual(@as(u32, 0), p.line);
    try std.testing.expectEqual(@as(u32, 4), p.character); // a + 2 + b
}

test "positionToIndex: round-trips ASCII" {
    const src = "abc\ndef\nghi";
    inline for (.{ 0, 3, 4, 7, 11 }) |idx| {
        const p = indexToPosition(src, idx, .@"utf-16");
        try std.testing.expectEqual(@as(usize, idx), positionToIndex(src, p, .@"utf-16"));
    }
}

test "positionToIndex: surrogate-pair character indexing" {
    const src = "a\xF0\x9F\x98\x80b"; // a + emoji + b
    const p: Position = .{ .line = 0, .character = 3 }; // after emoji
    try std.testing.expectEqual(@as(usize, 5), positionToIndex(src, p, .@"utf-16"));
}

test "positionToIndex: out-of-range clamps to source end" {
    const src = "abc";
    const p: Position = .{ .line = 99, .character = 0 };
    try std.testing.expectEqual(@as(usize, 3), positionToIndex(src, p, .@"utf-16"));
}

// ---------------------------------------------------------------------------
// Encodings and malformed input
//
// Every test above this block uses `.@"utf-16"` over valid UTF-8, so the
// `.@"utf-8"` and `.@"utf-32"` switch arms and every `catch` recovery arm in
// the four counting helpers went unexecuted. None of them is decorative: the
// client negotiates the encoding, and a document is arbitrary bytes until
// something validates it — which nothing on this path does.
//
// One recovery rule, in all four helpers: a byte that cannot start or finish
// a codepoint counts as one unit and advances one byte, and a sequence
// clipped by the end of the slice is not counted at all. That keeps every
// position monotone and in-bounds on garbage, and keeps each encoding's two
// directions agreeing with each other — the property `positionToIndex`'s
// callers actually slice with.
// ---------------------------------------------------------------------------

test "encodings: the same text has a different character count in each" {
    // "a" + é (2 bytes) + € (3) + 😀 (4): 10 bytes, 5 utf-16 units
    // (the emoji is a surrogate pair), 4 codepoints.
    const src = "a\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80";
    try std.testing.expectEqual(@as(u32, 10), indexToPosition(src, src.len, .@"utf-8").character);
    try std.testing.expectEqual(@as(u32, 5), indexToPosition(src, src.len, .@"utf-16").character);
    try std.testing.expectEqual(@as(u32, 4), indexToPosition(src, src.len, .@"utf-32").character);
}

test "encodings: positionToIndex inverts indexToPosition in all three" {
    const src = "a\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80\nx";
    const cases = [_]struct { enc: Encoding, character: u32, index: usize }{
        // After é, after €, after 😀 — the same three bytes, named three ways.
        .{ .enc = .@"utf-8", .character = 3, .index = 3 },
        .{ .enc = .@"utf-16", .character = 2, .index = 3 },
        .{ .enc = .@"utf-32", .character = 2, .index = 3 },
        .{ .enc = .@"utf-8", .character = 6, .index = 6 },
        .{ .enc = .@"utf-16", .character = 3, .index = 6 },
        .{ .enc = .@"utf-32", .character = 3, .index = 6 },
        .{ .enc = .@"utf-8", .character = 10, .index = 10 },
        .{ .enc = .@"utf-16", .character = 5, .index = 10 },
        .{ .enc = .@"utf-32", .character = 4, .index = 10 },
    };
    for (cases) |c| {
        const p: Position = .{ .line = 0, .character = c.character };
        try std.testing.expectEqual(c.index, positionToIndex(src, p, c.enc));
        try std.testing.expectEqual(c.character, indexToPosition(src, c.index, c.enc).character);
    }
}

test "encodings: a character mid-surrogate-pair clamps to the pair's start" {
    // 😀 costs two utf-16 units; naming the first of them cannot split the
    // codepoint, so it resolves to the byte the pair starts at.
    const src = "a\xF0\x9F\x98\x80b";
    try std.testing.expectEqual(@as(usize, 1), positionToIndex(src, .{ .line = 0, .character = 1 }, .@"utf-16"));
    try std.testing.expectEqual(@as(usize, 1), positionToIndex(src, .{ .line = 0, .character = 2 }, .@"utf-16"));
    try std.testing.expectEqual(@as(usize, 5), positionToIndex(src, .{ .line = 0, .character = 3 }, .@"utf-16"));
}

test "malformed: a lone continuation byte counts as one unit everywhere" {
    // 0x80 cannot start a sequence, so `utf8ByteSequenceLength` rejects it —
    // the length-check recovery arm.
    const src = "a\x80b";
    inline for (.{ Encoding.@"utf-8", Encoding.@"utf-16", Encoding.@"utf-32" }) |enc| {
        try std.testing.expectEqual(@as(u32, 3), indexToPosition(src, src.len, enc).character);
        try std.testing.expectEqual(@as(usize, 3), positionToIndex(src, .{ .line = 0, .character = 3 }, enc));
    }
}

test "malformed: an overlong sequence counts as its bytes, not as a codepoint" {
    // 0xC0 is a *well-formed length byte* (2), so only `utf8Decode` rejects
    // this — the decode recovery arm, which a length-only check never reaches.
    const src = "\xC0\x80";
    try std.testing.expectEqual(@as(u32, 2), indexToPosition(src, src.len, .@"utf-16").character);
    try std.testing.expectEqual(@as(usize, 2), positionToIndex(src, .{ .line = 0, .character = 2 }, .@"utf-16"));
}

test "malformed: a surrogate half counts as its bytes" {
    // 0xED 0xA0 0x80 is CESU-8's encoding of U+D800 — length-valid, decode-invalid.
    const src = "\xED\xA0\x80";
    try std.testing.expectEqual(@as(u32, 3), indexToPosition(src, src.len, .@"utf-16").character);
    try std.testing.expectEqual(@as(usize, 3), positionToIndex(src, .{ .line = 0, .character = 3 }, .@"utf-16"));
}

test "malformed: a sequence clipped by the end of input is refused by both directions" {
    // The regression guard for the `countCodepoints` fix: a truncated tail
    // used to be a codepoint on the way out and not one on the way back,
    // which made the last bytes of the document unaddressable in utf-32.
    const src = "abc\xE2\x82"; // 3 ASCII + the first two bytes of €
    inline for (.{ Encoding.@"utf-16", Encoding.@"utf-32" }) |enc| {
        const p = indexToPosition(src, src.len, enc);
        try std.testing.expectEqual(@as(u32, 3), p.character);
        try std.testing.expectEqual(@as(usize, 3), positionToIndex(src, p, enc));
    }
    // utf-8 counts bytes, so it addresses the tail exactly.
    try std.testing.expectEqual(@as(u32, 5), indexToPosition(src, src.len, .@"utf-8").character);
    try std.testing.expectEqual(@as(usize, 5), positionToIndex(src, .{ .line = 0, .character = 5 }, .@"utf-8"));
}

test "malformed: garbage on one line leaves the next line's positions exact" {
    // The property that makes recovery worth having at all: a bad byte must
    // not desynchronise everything after it.
    const src = "\xFF\xFE\nabc";
    const p = indexToPosition(src, 5, .@"utf-16");
    try std.testing.expectEqual(@as(u32, 1), p.line);
    try std.testing.expectEqual(@as(u32, 2), p.character);
    try std.testing.expectEqual(@as(usize, 5), positionToIndex(src, p, .@"utf-16"));
}

// ---------------------------------------------------------------------------
// Line terminators
//
// LSP mandates `\n`, `\r\n` and a lone `\r`. CRLF used to work by accident
// (the scan found the `\n` and the `\r` fell inside the previous line's
// content); a lone `\r` was invisible, so a classic-Mac document was one
// giant line here while a conforming client — CodeMirror in the playground
// splits on all three — counted many, and every span landed on wrong text.
// ---------------------------------------------------------------------------

test "line terminators: a lone \\r starts a new line in both directions" {
    const src = "a\rb";
    const p = indexToPosition(src, 2, .@"utf-16");
    try std.testing.expectEqual(@as(u32, 1), p.line);
    try std.testing.expectEqual(@as(u32, 0), p.character);
    try std.testing.expectEqual(@as(usize, 2), positionToIndex(src, p, .@"utf-16"));
}

test "line terminators: \\r\\n counts once, not twice" {
    const src = "a\r\nb\r\nc";
    try std.testing.expectEqual(@as(u32, 1), indexToPosition(src, 3, .@"utf-16").line);
    try std.testing.expectEqual(@as(u32, 2), indexToPosition(src, 6, .@"utf-16").line);
    try std.testing.expectEqual(@as(usize, 3), positionToIndex(src, .{ .line = 1, .character = 0 }, .@"utf-16"));
    try std.testing.expectEqual(@as(usize, 6), positionToIndex(src, .{ .line = 2, .character = 0 }, .@"utf-16"));
}

test "line terminators: a character past the content clamps before the terminator" {
    // The terminator is not part of the line, so a client naming a character
    // beyond the text lands on the `\r`, not after it — otherwise an edit
    // would splice into the middle of a CRLF pair.
    const src = "ab\r\ncd";
    try std.testing.expectEqual(@as(usize, 2), positionToIndex(src, .{ .line = 0, .character = 99 }, .@"utf-16"));
    try std.testing.expectEqual(@as(usize, 2), positionToIndex(src, .{ .line = 0, .character = 3 }, .@"utf-16"));
}

test "line terminators: the \\n of a \\r\\n reports the end of the line it closes" {
    // Index 3 is inside the two-byte break — no more nameable than the
    // middle of a codepoint. It reports the end of line 0's content.
    const src = "ab\r\ncd";
    const p = indexToPosition(src, 3, .@"utf-16");
    try std.testing.expectEqual(@as(u32, 0), p.line);
    try std.testing.expectEqual(@as(u32, 2), p.character);
}

test "line terminators: a trailing \\r opens a final empty line" {
    const src = "ab\r";
    const p = indexToPosition(src, 3, .@"utf-16");
    try std.testing.expectEqual(@as(u32, 1), p.line);
    try std.testing.expectEqual(@as(u32, 0), p.character);
    try std.testing.expectEqual(@as(usize, 3), positionToIndex(src, p, .@"utf-16"));
}

test "line terminators: mixed \\n, \\r\\n and \\r in one document" {
    const src = "a\nb\r\nc\rd";
    inline for (.{ 0, 1, 2, 3, 5, 6, 7, 8 }) |idx| {
        const p = indexToPosition(src, idx, .@"utf-16");
        try std.testing.expectEqual(@as(usize, idx), positionToIndex(src, p, .@"utf-16"));
    }
    try std.testing.expectEqual(@as(u32, 3), indexToPosition(src, src.len, .@"utf-16").line);
}

test "line terminators: an \\n-only document is byte-identical to before" {
    // The regression guard for the change: nothing about `\n` documents may
    // have moved, since every span this server has ever emitted came from
    // one.
    const src = "abc\ndef\n\nghi";
    for (0..src.len + 1) |idx| {
        const p = indexToPosition(src, idx, .@"utf-16");
        var line: u32 = 0;
        var line_start: usize = 0;
        for (src[0..idx], 0..) |c, k| {
            if (c == '\n') {
                line += 1;
                line_start = k + 1;
            }
        }
        try std.testing.expectEqual(line, p.line);
        try std.testing.expectEqual(@as(u32, @intCast(idx - line_start)), p.character);
        try std.testing.expectEqual(@as(usize, idx), positionToIndex(src, p, .@"utf-16"));
    }
}
