const std = @import("std");
const Writer = std.Io.Writer;

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

pub const Styler = struct {
    enabled: bool,

    pub fn write(self: Styler, out: *Writer, style: Style) !void {
        if (!self.enabled) return;
        try out.writeAll(sgr(style));
    }

    pub fn writeStyled(self: Styler, out: *Writer, style: Style, text: []const u8) !void {
        try self.write(out, style);
        try out.writeAll(text);
        try self.write(out, .reset);
    }
};

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

pub const Policy = enum { auto, always, never };

pub fn resolve(
    policy: Policy,
    is_tty: bool,
    env_get: *const fn (name: []const u8) ?[]const u8,
) bool {
    return switch (policy) {
        .always => true,
        .never => false,
        .auto => blk: {
            if (!is_tty) break :blk false;
            if (env_get("NO_COLOR")) |v| if (v.len > 0) break :blk false;
            if (env_get("SJON_NO_COLOR")) |v| if (v.len > 0) break :blk false;
            break :blk true;
        },
    };
}

const testing = std.testing;

fn noEnv(_: []const u8) ?[]const u8 {
    return null;
}

fn allEnv(_: []const u8) ?[]const u8 {
    return "1";
}

fn onlyNoColor(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "NO_COLOR")) return "1";
    return null;
}
