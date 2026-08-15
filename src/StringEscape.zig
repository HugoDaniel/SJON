//! The SJON string escape set, in one place.
//!
//! Rendering a string back into source text is a correctness boundary, not
//! a formatting choice: the output is re-parsed (by the author's editor,
//! by `sjon fmt`, by the next validation pass), so an unescaped `"` inside
//! a value is a syntax error injected into someone's document. Every
//! renderer that emits a quoted SJON string must agree on this set exactly.
//!
//! It did not stay that way on its own. Three renderers grew independently
//! — `Printer.writeString`, `cli/ValueText.appendString`, and
//! `EffectiveDocument`'s two default-splicing arms — and the third escaped
//! nothing at all, which meant a legal manifest default like
//! `:default "say \"hi\""` spliced `:msg "say "hi""` into the author's
//! file through `sjon effective` and the LSP materialize action. The first
//! two agreed only because a test said so, and a NUL fix (`8d7b8b3`)
//! landed in one and missed the other.
//!
//! So the set lives here, and callers spend it rather than restate it.
//!
//! The escaped characters are exactly those the lexer recognises in an
//! escape sequence (`Parser`/`Lexer` reject `\u{…}` deliberately — raw
//! bytes are how non-ASCII travels), which is what makes
//! `parse(render(v)) == v` hold: every byte this emits is one the reader
//! maps straight back.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Append `s` to `out` as a complete quoted SJON string literal —
/// surrounding quotes included — escaping every byte that needs it.
///
/// O(n) in `s`, one pass, no intermediate allocation beyond `out`'s own
/// growth. `quotedLen(s)` is the exact number of bytes this appends.
pub fn appendQuoted(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    const before = out.items.len;
    try out.ensureUnusedCapacity(gpa, quotedLen(s));
    out.appendAssumeCapacity('"');
    for (s) |c| {
        if (escapeOf(c)) |esc| {
            out.appendSliceAssumeCapacity(esc);
        } else {
            out.appendAssumeCapacity(c);
        }
    }
    out.appendAssumeCapacity('"');
    std.debug.assert(out.items.len - before == quotedLen(s));
    std.debug.assert(out.items[before] == '"');
}

/// Byte length `appendQuoted` will produce for `s`, quotes included.
///
/// Pinned to `appendQuoted` by that function's own post-condition assert,
/// so the two cannot drift the way `Printer.writeString` and its separate
/// `stringLen` could.
pub fn quotedLen(s: []const u8) u32 {
    var len: u32 = 2; // surrounding quotes
    for (s) |c| len += if (escapeOf(c)) |esc| @intCast(esc.len) else 1;
    return len;
}

/// The escape sequence for `c`, or null when `c` is emitted verbatim.
///
/// The single source of the set. Bytes ≥ 0x80 pass through untouched:
/// SJON strings are byte-oriented and UTF-8 travels raw.
fn escapeOf(c: u8) ?[]const u8 {
    return switch (c) {
        '"' => "\\\"",
        '\\' => "\\\\",
        '\n' => "\\n",
        '\r' => "\\r",
        '\t' => "\\t",
        0 => "\\0",
        else => null,
    };
}

// ---------------------------------------------------------------------

const testing = std.testing;

test "appendQuoted escapes exactly the reader's escape set" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    try appendQuoted(&out, testing.allocator, "say \"hi\"");
    try testing.expectEqualStrings("\"say \\\"hi\\\"\"", out.items);

    out.clearRetainingCapacity();
    try appendQuoted(&out, testing.allocator, "a\\b");
    try testing.expectEqualStrings("\"a\\\\b\"", out.items);

    out.clearRetainingCapacity();
    try appendQuoted(&out, testing.allocator, "l1\nl2\r\tx");
    try testing.expectEqualStrings("\"l1\\nl2\\r\\tx\"", out.items);

    out.clearRetainingCapacity();
    try appendQuoted(&out, testing.allocator, &[_]u8{ 'a', 0, 'b' });
    try testing.expectEqualStrings("\"a\\0b\"", out.items);
}

test "appendQuoted passes non-ASCII bytes through verbatim" {
    // UTF-8 travels raw — `\u{…}` is deliberately not in the reader's
    // vocabulary, so escaping here would produce unreadable output.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendQuoted(&out, testing.allocator, "héllo → 🎛");
    try testing.expectEqualStrings("\"héllo → 🎛\"", out.items);
}

test "quotedLen matches what appendQuoted appends" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    const cases = [_][]const u8{
        "",
        "plain",
        "\"",
        "\\",
        "\n\r\t",
        &[_]u8{0},
        "héllo",
        "every: \" \\ \n \r \t and NUL",
    };
    for (cases) |s| {
        out.clearRetainingCapacity();
        try appendQuoted(&out, testing.allocator, s);
        try testing.expectEqual(quotedLen(s), @as(u32, @intCast(out.items.len)));
    }
}

test "every escape emitted is one byte the lexer maps back" {
    // The round-trip property the set exists for, spelled out over the
    // whole byte range: whatever `escapeOf` returns must start with a
    // backslash and name a sequence the reader recognises.
    const recognised = "\"\\nrt0";
    var c: u16 = 0;
    while (c <= 0xFF) : (c += 1) {
        const esc = escapeOf(@intCast(c)) orelse continue;
        try testing.expectEqual(@as(usize, 2), esc.len);
        try testing.expectEqual(@as(u8, '\\'), esc[0]);
        try testing.expect(std.mem.indexOfScalar(u8, recognised, esc[1]) != null);
    }
}
