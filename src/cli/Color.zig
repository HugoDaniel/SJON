//! ANSI color/style table.
//!
//! A `Style` enum plus a stateless `Styler` that writes SGR escapes
//! when `enabled`. Policy resolution (`--color=auto|always|never`,
//! `NO_COLOR` / `SJON_NO_COLOR`, TTY detection) lives in `Cli.zig`
//! (`resolveColor`); this module just accepts the resolved boolean.
//!
//! The codes follow the standard 16-color ANSI subset — no 256-color
//! or truecolor escapes. That's deliberate: rich format output
//! prioritizes legibility under any terminal, and we lose nothing by
//! sticking with the common floor.
//!
//! Usage:
//!
//! ```zig
//! const styler = Color.Styler{ .enabled = true };
//! try styler.write(writer, .red);
//! try writer.writeAll("error");
//! try styler.write(writer, .reset);
//! ```

const std = @import("std");
const Writer = std.Io.Writer;

/// ANSI style tags. Append-only; reordering changes binary output of
/// every existing call site.
pub const Style = enum {
    reset,
    bold,
    dim,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_red,
    bright_yellow,
    bright_blue,
};

/// Stateless styler. `enabled = false` makes every `write` a no-op.
pub const Styler = struct {
    enabled: bool,

    /// Write the SGR escape for `style` to `out`. No-op when
    /// `self.enabled` is false. Always followed by user content; pair
    /// each non-`reset` write with a `reset` to avoid bleeding style
    /// into surrounding output.
    pub fn write(self: Styler, out: *Writer, style: Style) Writer.Error!void {
        if (!self.enabled) return;
        try out.writeAll(sgr(style));
    }

    /// Write `text` wrapped in `style` + `reset`. Convenience for the
    /// common "color one short token" pattern.
    pub fn writeStyled(self: Styler, out: *Writer, style: Style, text: []const u8) Writer.Error!void {
        try self.write(out, style);
        try out.writeAll(text);
        try self.write(out, .reset);
    }
};

/// Map a Style to its SGR escape sequence.
fn sgr(style: Style) []const u8 {
    return switch (style) {
        .reset => "\x1b[0m",
        .bold => "\x1b[1m",
        .dim => "\x1b[2m",
        .red => "\x1b[31m",
        .green => "\x1b[32m",
        .yellow => "\x1b[33m",
        .blue => "\x1b[34m",
        .magenta => "\x1b[35m",
        .cyan => "\x1b[36m",
        .white => "\x1b[37m",
        .bright_red => "\x1b[91m",
        .bright_yellow => "\x1b[93m",
        .bright_blue => "\x1b[94m",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Color.Styler: write is no-op when disabled" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    const s: Styler = .{ .enabled = false };
    try s.write(&buf.writer, .red);
    try testing.expectEqual(@as(usize, 0), buf.written().len);
}

test "Color.Styler: writeStyled wraps in reset when enabled" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    const s: Styler = .{ .enabled = true };
    try s.writeStyled(&buf.writer, .red, "X");
    try testing.expectEqualStrings("\x1b[31mX\x1b[0m", buf.written());
}
