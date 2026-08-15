//! Source-snippet rendering for the `rich` diagnostic format.
//!
//! Output anatomy:
//!
//! ```
//! error[unresolved_plugin]: no plugin named `shape` in project
//!    ┌─ examples/scene.sjon:12:14
//!    │
//! 12 │ (use-plugin "shape")
//!    │              ^^^^^ unresolved reference
//!    │
//! ```
//!
//! Inputs: the diagnostic + source bytes + the file label. Optional
//! secondary spans (e.g., "see also" pointers to the project file or
//! the manifest's `:version` line) ride on the same renderer.
//!
//! Column math is byte-based for the first revision, so the gutter
//! width and caret position remain consistent. UTF-8 width walks
//! (combining marks, wide chars) land in a follow-up once the
//! diagnostic corpus needs them.

const std = @import("std");
const sjon = @import("sjon");
const Ast = sjon.Ast;
const Color = @import("Color.zig");

const Writer = std.Io.Writer;

/// One labeled span — primary or secondary. The renderer underlines
/// the byte range and prints `label` after the carets when non-empty.
pub const LabeledSpan = struct {
    span: Ast.Span,
    label: []const u8 = "",
    /// Render hint — primary spans use `^` carets and the diagnostic's
    /// severity color; secondary use `-` underline and dim.
    role: Role = .primary,

    pub const Role = enum { primary, secondary };
};

/// Render a single diagnostic block with one primary span and any
/// number of secondary spans. The caller is responsible for the
/// preceding header line (`error[code]: message`) — this function
/// only emits the snippet frame.
pub fn render(
    out: *Writer,
    file_label: []const u8,
    source: []const u8,
    primary: LabeledSpan,
    secondaries: []const LabeledSpan,
    styler: Color.Styler,
) Writer.Error!void {
    const lc = indexToLineCol(source, primary.span.start);
    const gutter_w = decimalWidth(lc.line);

    // Header: `   ┌─ <file>:<line>:<col>`
    try writeGutterPad(out, gutter_w);
    try styler.write(out, .blue);
    try out.writeAll("┌─ ");
    try styler.write(out, .reset);
    try out.print("{s}:{d}:{d}\n", .{ file_label, lc.line, lc.col });

    // Blank gutter line.
    try writeGutterPad(out, gutter_w);
    try styler.write(out, .blue);
    try out.writeAll("│");
    try styler.write(out, .reset);
    try out.writeAll("\n");

    // The source line itself.
    const line_bytes = extractLine(source, primary.span.start);
    try writePaddedLineNum(out, gutter_w, lc.line);
    try out.writeAll(" ");
    try styler.write(out, .blue);
    try out.writeAll("│ ");
    try styler.write(out, .reset);
    try out.writeAll(line_bytes);
    if (line_bytes.len == 0 or line_bytes[line_bytes.len - 1] != '\n') {
        try out.writeAll("\n");
    }

    // Caret underline line.
    try writeGutterPad(out, gutter_w);
    try styler.write(out, .blue);
    try out.writeAll("│ ");
    try styler.write(out, .reset);
    try writeCarets(out, source, line_bytes, primary, styler);
    if (primary.label.len > 0) {
        try out.writeAll(" ");
        try styler.writeStyled(out, .red, primary.label);
    }
    try out.writeAll("\n");

    // Secondary spans get their own anchored frames. Same machinery,
    // dim color, `-` underline.
    for (secondaries) |sec| {
        try renderSecondary(out, file_label, source, sec, styler);
    }

    // Trailing blank gutter for visual breathing room.
    try writeGutterPad(out, gutter_w);
    try styler.write(out, .blue);
    try out.writeAll("│");
    try styler.write(out, .reset);
    try out.writeAll("\n");
}

/// Pad `width` blanks then print the column separator. Used for the
/// connector lines that don't carry a line number.
fn writeGutterPad(out: *Writer, width: usize) Writer.Error!void {
    var i: usize = 0;
    while (i < width + 1) : (i += 1) try out.writeAll(" ");
}

/// Right-pad a line number to `width` decimal digits with leading
/// spaces. Manual rather than `{d:>}` because Zig's format DSL syntax
/// for runtime-driven width was rejected on first try and the manual
/// version is two lines.
fn writePaddedLineNum(out: *Writer, width: usize, n: u32) Writer.Error!void {
    const actual = decimalWidth(n);
    var pad: usize = if (width > actual) width - actual else 0;
    while (pad > 0) : (pad -= 1) try out.writeAll(" ");
    try out.print("{d}", .{n});
}

fn renderSecondary(
    out: *Writer,
    file_label: []const u8,
    source: []const u8,
    sec: LabeledSpan,
    styler: Color.Styler,
) Writer.Error!void {
    const lc = indexToLineCol(source, sec.span.start);
    const gutter_w = decimalWidth(lc.line);
    try writeGutterPad(out, gutter_w);
    try styler.write(out, .dim);
    try out.print(":: {s}:{d}:{d}\n", .{ file_label, lc.line, lc.col });
    try styler.write(out, .reset);
    const line_bytes = extractLine(source, sec.span.start);
    try writePaddedLineNum(out, gutter_w, lc.line);
    try out.writeAll(" ");
    try styler.write(out, .dim);
    try out.writeAll("│ ");
    try out.writeAll(line_bytes);
    try styler.write(out, .reset);
    if (line_bytes.len == 0 or line_bytes[line_bytes.len - 1] != '\n') {
        try out.writeAll("\n");
    }
    try writeGutterPad(out, gutter_w);
    try styler.write(out, .dim);
    try out.writeAll("│ ");
    try writeUnderline(out, source, line_bytes, sec, '-');
    if (sec.label.len > 0) {
        try out.writeAll(" ");
        try out.writeAll(sec.label);
    }
    try styler.write(out, .reset);
    try out.writeAll("\n");
}

fn writeCarets(
    out: *Writer,
    source: []const u8,
    line_bytes: []const u8,
    span: LabeledSpan,
    styler: Color.Styler,
) Writer.Error!void {
    try styler.write(out, .red);
    try writeUnderline(out, source, line_bytes, span, '^');
    try styler.write(out, .reset);
}

fn writeUnderline(
    out: *Writer,
    source: []const u8,
    line_bytes: []const u8,
    span: LabeledSpan,
    ch: u8,
) Writer.Error!void {
    // Find the start-of-line offset for `span.start` so we can compute
    // the column offset inside the line.
    const line_start = findLineStart(source, span.span.start);
    const col_offset = span.span.start - line_start;
    const span_len_in_line = blk: {
        const end = if (span.span.end > span.span.start) span.span.end else span.span.start + 1;
        const clamped_end = if (end - line_start > line_bytes.len)
            line_bytes.len
        else
            end - line_start;
        if (clamped_end <= col_offset) break :blk 1;
        break :blk clamped_end - col_offset;
    };

    var i: usize = 0;
    while (i < col_offset) : (i += 1) try out.writeAll(" ");
    var k: usize = 0;
    while (k < span_len_in_line) : (k += 1) {
        try out.writeByte(ch);
    }
}

const LineCol = struct { line: u32, col: u32 };

/// Compute (1-based line, 1-based column) for the byte at `idx`.
/// Counts only `'\n'` for line breaks; columns are byte offsets, not
/// codepoints. The CLI's human + JSON diagnostic formatters share this.
pub fn indexToLineCol(source: []const u8, idx: usize) LineCol {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;
    const limit = if (idx > source.len) source.len else idx;
    while (i < limit) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

/// Return the slice of `source` starting at `idx`'s line start and
/// extending to the next `'\n'` (exclusive) or EOF. Includes no
/// trailing newline.
fn extractLine(source: []const u8, idx: usize) []const u8 {
    const start = findLineStart(source, idx);
    var end = idx;
    while (end < source.len and source[end] != '\n') end += 1;
    // Walk back from idx in case start..idx had bytes we haven't seen
    // yet — `findLineStart` already gives the line start, so we just
    // need to extend `end`.
    return source[start..end];
}

fn findLineStart(source: []const u8, idx: usize) usize {
    var s: usize = if (idx > source.len) source.len else idx;
    while (s > 0 and source[s - 1] != '\n') s -= 1;
    return s;
}

fn decimalWidth(n: u32) usize {
    var v: u32 = if (n == 0) 1 else n;
    var w: usize = 0;
    while (v > 0) : (v /= 10) w += 1;
    return w;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "SnippetRenderer.indexToLineCol: first byte is 1:1" {
    const lc = indexToLineCol("hello\nworld", 0);
    try testing.expectEqual(@as(u32, 1), lc.line);
    try testing.expectEqual(@as(u32, 1), lc.col);
}

test "SnippetRenderer.indexToLineCol: after newline" {
    const lc = indexToLineCol("hello\nworld", 6);
    try testing.expectEqual(@as(u32, 2), lc.line);
    try testing.expectEqual(@as(u32, 1), lc.col);
}

test "SnippetRenderer.indexToLineCol: clamps past end" {
    const lc = indexToLineCol("ab", 10);
    try testing.expectEqual(@as(u32, 1), lc.line);
    try testing.expectEqual(@as(u32, 3), lc.col);
}

test "SnippetRenderer.render: primary span produces caret underline" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    const source = "(use-plugin \"shape\")\n";
    const span: Ast.Span = .{ .start = 13, .end = 18 }; // `shape`
    try render(&buf.writer, "scene.sjon", source, .{
        .span = span,
        .label = "unresolved reference",
    }, &.{}, .{ .enabled = false });

    const out = buf.written();
    // Header.
    try testing.expect(std.mem.indexOf(u8, out, "scene.sjon:1:14") != null);
    // Source line.
    try testing.expect(std.mem.indexOf(u8, out, "(use-plugin \"shape\")") != null);
    // Caret underline + label.
    try testing.expect(std.mem.indexOf(u8, out, "^^^^^") != null);
    try testing.expect(std.mem.indexOf(u8, out, "unresolved reference") != null);
}

test "SnippetRenderer.render: zero-length span underlines one char" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    const source = "abc\n";
    try render(&buf.writer, "x.sjon", source, .{
        .span = .{ .start = 1, .end = 1 },
        .label = "",
    }, &.{}, .{ .enabled = false });
    try testing.expect(std.mem.indexOf(u8, buf.written(), "^") != null);
}

test "SnippetRenderer.indexToLineCol: first column of every line" {
    const src = "alpha\nbeta\ngamma\n";
    // Start of line 2 ("b").
    const lc2 = indexToLineCol(src, 6);
    try testing.expectEqual(@as(u32, 2), lc2.line);
    try testing.expectEqual(@as(u32, 1), lc2.col);
    // Start of line 3 ("g").
    const lc3 = indexToLineCol(src, 11);
    try testing.expectEqual(@as(u32, 3), lc3.line);
    try testing.expectEqual(@as(u32, 1), lc3.col);
}

test "SnippetRenderer.indexToLineCol: empty source" {
    const lc = indexToLineCol("", 0);
    try testing.expectEqual(@as(u32, 1), lc.line);
    try testing.expectEqual(@as(u32, 1), lc.col);
}

test "SnippetRenderer.indexToLineCol: byte at EOF" {
    const src = "abc";
    const lc = indexToLineCol(src, src.len);
    try testing.expectEqual(@as(u32, 1), lc.line);
    try testing.expectEqual(@as(u32, 4), lc.col);
}

test "SnippetRenderer.render: span on last line with no trailing newline" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    const source = "line1\nlast"; // no trailing newline
    try render(&buf.writer, "x.sjon", source, .{
        .span = .{ .start = 6, .end = 10 },
        .label = "here",
    }, &.{}, .{ .enabled = false });
    const out = buf.written();
    try testing.expect(std.mem.indexOf(u8, out, "last") != null);
    try testing.expect(std.mem.indexOf(u8, out, "^^^^") != null);
    try testing.expect(std.mem.indexOf(u8, out, "here") != null);
}

test "SnippetRenderer.render: secondary span gets its own anchor" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    const source = "(scene\n  (group :x 1))";
    try render(&buf.writer, "scene.sjon", source, .{
        .span = .{ .start = 1, .end = 6 },
        .label = "outer form",
    }, &.{
        .{
            .span = .{ .start = 10, .end = 15 },
            .label = "inner group",
            .role = .secondary,
        },
    }, .{ .enabled = false });
    const out = buf.written();
    // Both anchors present.
    try testing.expect(std.mem.indexOf(u8, out, "scene.sjon:1:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "scene.sjon:2:") != null);
    // Primary uses ^, secondary uses -.
    try testing.expect(std.mem.indexOf(u8, out, "^") != null);
    try testing.expect(std.mem.indexOf(u8, out, "-") != null);
    try testing.expect(std.mem.indexOf(u8, out, "outer form") != null);
    try testing.expect(std.mem.indexOf(u8, out, "inner group") != null);
}

test "SnippetRenderer.render: multi-line span clamps to first line" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    const source = "(outer\n  (inner))\n";
    // Span covers the entire `(outer …)` form across two lines.
    try render(&buf.writer, "x.sjon", source, .{
        .span = .{ .start = 0, .end = source.len - 1 },
        .label = "whole form",
    }, &.{}, .{ .enabled = false });
    const out = buf.written();
    // First line carets are bounded to the first line's length.
    try testing.expect(std.mem.indexOf(u8, out, "(outer") != null);
}

test "SnippetRenderer.render: ANSI color when styler is enabled" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    const source = "abc\n";
    try render(&buf.writer, "x.sjon", source, .{
        .span = .{ .start = 0, .end = 3 },
        .label = "all",
    }, &.{}, .{ .enabled = true });
    const out = buf.written();
    // ESC byte (0x1b) appears when styler is enabled.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[") != null);
}

test "SnippetRenderer.render: no ANSI when styler disabled" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    const source = "abc\n";
    try render(&buf.writer, "x.sjon", source, .{
        .span = .{ .start = 0, .end = 3 },
        .label = "all",
    }, &.{}, .{ .enabled = false });
    const out = buf.written();
    try testing.expect(std.mem.indexOf(u8, out, "\x1b") == null);
}
