const std = @import("std");
const sjon = @import("sjon");
const Ast = sjon.Ast;
const Schema = sjon.Schema;
const DidYouMean = @import("DidYouMean.zig");

const Allocator = std.mem.Allocator;

pub const HintKind = enum { note, hint, help };

pub const Hint = struct {
    kind: HintKind,
    body: []const u8,
};

pub const Context = struct {
    arena: Allocator,
    diagnostic: *const Ast.Diagnostic,
    schema: ?*const Schema.Schema = null,
    known_plugin_names: ?[]const []const u8 = null,
    actual_hash: ?[]const u8 = null,
};

pub fn forDiagnostic(ctx: Context) Allocator.Error![]const Hint {
    return switch (ctx.diagnostic.code) {
        .unresolved_plugin => try hintsForUnresolvedPlugin(ctx),
        .plugin_hash_mismatch => try hintsForPluginHashMismatch(ctx),
        .unknown_form => try hintsForUnknownForm(ctx),
        .unknown_key => try hintsForUnknownKey(ctx),
        .arity_mismatch => try hintsForArityMismatch(ctx),
        else => &.{},
    };
}

fn hintsForUnresolvedPlugin(ctx: Context) Allocator.Error![]const Hint {
    const names = ctx.known_plugin_names orelse return &.{};
    const needle = extractQuotedName(ctx.diagnostic.message) orelse return &.{};
    const suggestions = try DidYouMean.suggest(ctx.arena, needle, names, 3);
    if (suggestions.len == 0) return &.{};
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(ctx.arena, "Did you mean `");
    try buf.appendSlice(ctx.arena, suggestions[0].name);
    try buf.appendSlice(ctx.arena, "`?");
    if (suggestions.len > 1) {
        try buf.appendSlice(ctx.arena, " (also: ");
        for (suggestions[1..], 0..) |s, i| {
            if (i > 0) try buf.appendSlice(ctx.arena, ", ");
            try buf.append(ctx.arena, '`');
            try buf.appendSlice(ctx.arena, s.name);
            try buf.append(ctx.arena, '`');
        }
        try buf.append(ctx.arena, ')');
    }
    const hints = try ctx.arena.alloc(Hint, 1);
    hints[0] = .{ .kind = .note, .body = try buf.toOwnedSlice(ctx.arena) };
    return hints;
}

fn hintsForPluginHashMismatch(ctx: Context) Allocator.Error![]const Hint {
    const hints = try ctx.arena.alloc(Hint, 2);
    hints[0] = .{
        .kind = .hint,
        .body = "Run `sjon plugin hash <wasm>` to compute the current digest.",
    };
    if (ctx.actual_hash) |actual| {
        hints[1] = .{
            .kind = .hint,
            .body = try std.fmt.allocPrint(
                ctx.arena,
                "Replace the pin with `sha256-{s}` if the new bytes are intentional.",
                .{actual},
            ),
        };
        return hints;
    }
    hints[1] = .{
        .kind = .help,
        .body = "See `sjon explain plugin_hash_mismatch` for the full rule.",
    };
    return hints;
}

fn hintsForUnknownForm(ctx: Context) Allocator.Error![]const Hint {
    const schema = ctx.schema orelse return &.{};
    const needle = extractQuotedName(ctx.diagnostic.message) orelse return &.{};
    var heads: std.ArrayList([]const u8) = .empty;
    for (schema.plugins) |plugin| {
        for (plugin.forms) |form| {
            try heads.append(ctx.arena, form.name);
        }
    }
    const suggestions = try DidYouMean.suggest(ctx.arena, needle, heads.items, 3);
    if (suggestions.len == 0) return &.{};
    const hints = try ctx.arena.alloc(Hint, 1);
    hints[0] = .{
        .kind = .note,
        .body = try std.fmt.allocPrint(ctx.arena, "Did you mean `{s}`?", .{suggestions[0].name}),
    };
    return hints;
}

fn hintsForUnknownKey(ctx: Context) Allocator.Error![]const Hint {
    const hints = try ctx.arena.alloc(Hint, 1);
    hints[0] = .{
        .kind = .help,
        .body = "See `sjon explain unknown_key`. Discriminated forms reject variant keys that appear before the discriminant kvpair.",
    };
    return hints;
}

fn hintsForArityMismatch(ctx: Context) Allocator.Error![]const Hint {
    const hints = try ctx.arena.alloc(Hint, 1);
    hints[0] = .{
        .kind = .help,
        .body = "Function arity declarations come in three shapes — `(fixed N)`, `(at-least N)`, and `(range :min M :max N)`. See `sjon explain arity_mismatch`.",
    };
    return hints;
}

fn extractQuotedName(msg: []const u8) ?[]const u8 {
    const first = std.mem.indexOfScalar(u8, msg, '`') orelse return null;
    const after = msg[first + 1 ..];
    const close = std.mem.indexOfScalar(u8, after, '`') orelse return null;
    return after[0..close];
}

const testing = std.testing;
