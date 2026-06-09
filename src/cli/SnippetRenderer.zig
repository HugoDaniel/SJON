const std = @import("std");
const sjon = @import("sjon");
const Ast = sjon.Ast;
const Color = @import("Color.zig");

const Writer = std.Io.Writer;

pub const LabeledSpan = struct {
    span: Ast.Span,
    label: []const u8 = "",
    role: Role = .primary,

    pub const Role = enum { primary, secondary };
};

pub fn render(
    out: *Writer,
    file_label: []const u8,
    source: []const u8,
    primary: LabeledSpan,
    secondaries: []const LabeledSpan,
    styler: Color.Styler,
) !void {
    const lc = indexToLineCol(source, primary.span.start);
    const gutter_w = decimalWidth(lc.line);

    try writeGutterPad(out, gutter_w);
    try styler.write(out, .blue);
    try out.writeAll("┌─ ");
    try styler.write(out, .reset);
    try out.print("{s}:{d}:{d}\n", .{ file_label, lc.line, lc.col });

    try writeGutterPad(out, gutter_w);
    try styler.write(out, .blue);
    try out.writeAll("│");
    try styler.write(out, .reset);
    try out.writeAll("\n");

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

    for (secondaries) |sec| {
        try renderSecondary(out, file_label, source, sec, styler);
    }

    try writeGutterPad(out, gutter_w);
    try styler.write(out, .blue);
    try out.writeAll("│");
    try styler.write(out, .reset);
    try out.writeAll("\n");
}

fn writeGutterPad(out: *Writer, width: usize) !void {
    var i: usize = 0;
    while (i < width + 1) : (i += 1) try out.writeAll(" ");
}

fn writePaddedLineNum(out: *Writer, width: usize, n: u32) !void {
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
) !void {
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
) !void {
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
) !void {
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

fn extractLine(source: []const u8, idx: usize) []const u8 {
    const start = findLineStart(source, idx);
    var end = idx;
    while (end < source.len and source[end] != '\n') end += 1;
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

const testing = std.testing;
