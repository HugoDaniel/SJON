//! Applying `textDocument/didChange` content changes to a document.
//!
//! LSP incremental sync sends a *batch* of changes per notification, and
//! the batch has one rule that is easy to get wrong: each change's range
//! is expressed against the text the **previous** changes in the same
//! batch produced, not against the text the server had when the
//! notification arrived. Resolving every range against the original
//! document works for single-change batches — which is most of them — and
//! silently corrupts the rest. That rule, plus the clamping needed to
//! survive a range the client got wrong, is what this module owns.
//!
//! It lives apart from both transports because both need it and neither
//! can be tested end-to-end today (`main.zig` has no harness until plan
//! 10). Position→byte conversion is *not* shared: native uses lsp-kit's
//! `lsp.offsets`, wasm uses `offsets.zig`, and a transport that computed
//! edit offsets with a different converter than it reports diagnostics
//! with would be a subtle way to disagree with itself. So the converter
//! arrives as a parameter and each transport passes its own.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// A `(line, character)` pair. `character` is counted in code units of
/// whatever encoding the caller's mapper was built for — this module
/// never interprets it.
pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

/// One entry of an LSP `contentChanges` array. A null `range` is the
/// spec's whole-document form: `text` replaces everything.
pub const Change = struct {
    range: ?Range = null,
    text: []const u8,
};

/// Apply `changes` in order to `original`, returning the resulting text.
///
/// `mapper` converts a `Position` to a byte index and must expose a
/// **public** `toIndex(self, source: []const u8, pos: Position) usize`.
/// It is called against the *working* text, so it observes earlier
/// changes in the batch — that is the whole reason it is a callback
/// rather than a precomputed table of offsets.
///
/// Ranges are clamped rather than trusted: a client that sends an
/// out-of-bounds or inverted range gets a no-op or a truncated edit, not
/// a panic. The document is the user's work, and a malformed payload is
/// not a reason to take the server down with it.
///
/// The result is allocated in `gpa` and owned by the caller. O(n·m) in
/// document size and change count, which is the shape of the underlying
/// splice; batches are small.
pub fn applyChanges(
    gpa: Allocator,
    original: []const u8,
    changes: []const Change,
    mapper: anytype,
) Allocator.Error![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    try text.appendSlice(gpa, original);

    for (changes) |change| {
        const range = change.range orelse {
            // Whole-document replacement. Still a batch member, so a
            // later ranged change resolves against *this* text.
            text.clearRetainingCapacity();
            try text.appendSlice(gpa, change.text);
            continue;
        };

        const start = @min(mapper.toIndex(text.items, range.start), text.items.len);
        // A well-formed range has start <= end. An inverted one would
        // underflow the length arithmetic below, so collapse it to an
        // insertion at `start` instead.
        const end = @max(start, @min(mapper.toIndex(text.items, range.end), text.items.len));
        std.debug.assert(start <= end);
        std.debug.assert(end <= text.items.len);

        try text.replaceRange(gpa, start, end - start, change.text);
    }

    return text.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// UTF-8 mapper: `character` counts bytes. Enough for every test that
/// isn't specifically about encoding — the real UTF-16 conversion is
/// covered where it meets a real converter, in `wasm.zig`'s dispatch
/// tests.
const ByteMapper = struct {
    pub fn toIndex(_: ByteMapper, source: []const u8, pos: Position) usize {
        var line: u32 = 0;
        var i: usize = 0;
        while (i < source.len and line < pos.line) : (i += 1) {
            if (source[i] == '\n') line += 1;
        }
        const line_end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
        return @min(i + pos.character, line_end);
    }
};

fn apply(changes: []const Change, original: []const u8) ![]u8 {
    return applyChanges(testing.allocator, original, changes, ByteMapper{});
}

test "applyChanges: a ranged change splices in place" {
    const out = try apply(&.{.{
        .range = .{ .start = .{ .line = 0, .character = 12 }, .end = .{ .line = 0, .character = 14 } },
        .text = "30",
    }}, "(scene :fps 60)");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("(scene :fps 30)", out);
}

test "applyChanges: each change sees the previous one's result" {
    // The second range means something different against `(bb)` than
    // against `(a)`. Resolving both against the original would edit `)`.
    const out = try apply(&.{
        .{
            .range = .{ .start = .{ .line = 0, .character = 1 }, .end = .{ .line = 0, .character = 2 } },
            .text = "bb",
        },
        .{
            .range = .{ .start = .{ .line = 0, .character = 2 }, .end = .{ .line = 0, .character = 3 } },
            .text = "c",
        },
    }, "(a)");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("(bc)", out);
}

test "applyChanges: a range-less change replaces the whole document" {
    const out = try apply(&.{.{ .text = "(zzz)" }}, "(a)\n(b)\n(c)");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("(zzz)", out);
}

test "applyChanges: a whole-document change mid-batch rebases what follows" {
    // Spec-legal and worth pinning: the ranged change after a full
    // replace must address the replacement, not the original.
    const out = try apply(&.{
        .{ .text = "(xyz)" },
        .{
            .range = .{ .start = .{ .line = 0, .character = 1 }, .end = .{ .line = 0, .character = 4 } },
            .text = "q",
        },
    }, "(a)");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("(q)", out);
}

test "applyChanges: an empty batch returns the document unchanged" {
    const out = try apply(&.{}, "(a)");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("(a)", out);
}

test "applyChanges: a multi-line range splices across the newline" {
    const out = try apply(&.{.{
        .range = .{ .start = .{ .line = 0, .character = 1 }, .end = .{ .line = 1, .character = 1 } },
        .text = "X",
    }}, "(a)\n(b)");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("(Xb)", out);
}

test "applyChanges: an insertion is a zero-width range" {
    const out = try apply(&.{.{
        .range = .{ .start = .{ .line = 0, .character = 2 }, .end = .{ .line = 0, .character = 2 } },
        .text = "bc",
    }}, "(a)");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("(abc)", out);
}

test "applyChanges: an inverted range collapses to an insertion" {
    // end < start is malformed. It must not underflow `end - start`.
    const out = try apply(&.{.{
        .range = .{ .start = .{ .line = 0, .character = 2 }, .end = .{ .line = 0, .character = 1 } },
        .text = "Z",
    }}, "(a)");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("(aZ)", out);
}

test "applyChanges: a range past the end clamps to the document" {
    const out = try apply(&.{.{
        .range = .{ .start = .{ .line = 9, .character = 0 }, .end = .{ .line = 9, .character = 5 } },
        .text = "!",
    }}, "(a)");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("(a)!", out);
}

test "applyChanges: deleting is a range with empty text" {
    const out = try apply(&.{.{
        .range = .{ .start = .{ .line = 0, .character = 1 }, .end = .{ .line = 0, .character = 2 } },
        .text = "",
    }}, "(a)");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("()", out);
}
