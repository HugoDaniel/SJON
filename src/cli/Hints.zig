//! Hint registry keyed by `Ast.Diagnostic.Code`.
//!
//! Hints are short, actionable footers attached to a diagnostic in the
//! rich format: "did you mean X?", "the manifest's :version is here",
//! "run `sjon project lock` to update." Each hint has a `kind` tag
//! (`note` / `hint` / `help`) selecting its color and severity in the
//! renderer.
//!
//! Slice 7 ships skeleton + the five highest-value hints:
//!   * `unresolved_plugin`
//!   * `plugin_hash_mismatch`
//!   * `unknown_form`
//!   * `unknown_key`
//!   * `arity_mismatch`
//!
//! The remaining codes from the plan's hint table land alongside their
//! consumer slices.

const std = @import("std");
const sjon = @import("sjon");
const Ast = sjon.Ast;
const Plugin = sjon.Plugin;
const Schema = sjon.Schema;
const DidYouMean = sjon.DidYouMean;
const Explanations = sjon.Explanations;

const Allocator = std.mem.Allocator;

pub const HintKind = enum { note, hint, help };

pub const Hint = struct {
    kind: HintKind,
    /// The hint body. Arena-owned (the caller's arena).
    body: []const u8,
    /// When the suggestion is a machine-applicable string (the
    /// DidYouMean candidate exactly as it would be typed at the
    /// diagnostic's span) it rides separately from the prose so JSON
    /// consumers apply it without parsing the sentence. Null for
    /// prose-only hints.
    replacement: ?[]const u8 = null,
};

/// Context passed to hint builders. The schema is non-null when
/// the diagnostic comes from a phase where the aggregate plugin
/// vocabulary is known; manifest-phase failures may see `null`.
pub const Context = struct {
    arena: Allocator,
    diagnostic: *const Ast.Diagnostic,
    schema: ?*const Schema.Schema = null,
    /// Plugin name lists for `unresolved_plugin`, populated by the
    /// CLI from the resolver's project index. Null when the diagnostic
    /// was emitted outside a project context.
    known_plugin_names: ?[]const []const u8 = null,
    /// When the `Host` already computed an actual hash for a hash
    /// mismatch, the hint builder uses it verbatim instead of asking
    /// the user to recompute.
    actual_hash: ?[]const u8 = null,
};

/// The code-specific registered hints alone. May be empty; the
/// registry doesn't require coverage of every code. JSON output uses
/// this directly (it emits the docs URL as its own structured field).
pub fn registered(ctx: Context) Allocator.Error![]const Hint {
    return switch (ctx.diagnostic.code) {
        .unresolved_plugin => try hintsForUnresolvedPlugin(ctx),
        .plugin_hash_mismatch => try hintsForPluginHashMismatch(ctx),
        .unknown_form => try hintsForUnknownForm(ctx),
        .unknown_key => try hintsForUnknownKey(ctx),
        .arity_mismatch => try hintsForArityMismatch(ctx),
        else => &.{},
    };
}

/// Build the hints for a diagnostic: `registered`, closed by a `help:`
/// footer linking the code's documentation page. The footer is total,
/// since `Explanations.codeHref` has a page for every variant, so the
/// returned slice is never empty.
pub fn forDiagnostic(ctx: Context) Allocator.Error![]const Hint {
    const specific = try registered(ctx);
    var out: std.ArrayList(Hint) = .empty;
    try out.ensureTotalCapacityPrecise(ctx.arena, specific.len + 1);
    out.appendSliceAssumeCapacity(specific);
    out.appendAssumeCapacity(.{
        .kind = .help,
        .body = Explanations.codeHref(ctx.diagnostic.code),
    });
    return try out.toOwnedSlice(ctx.arena);
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
    hints[0] = .{
        .kind = .note,
        .body = try buf.toOwnedSlice(ctx.arena),
        .replacement = suggestions[0].name,
    };
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
    // Collect form heads from the aggregate schema. `Schema.plugins`
    // is the public field; no iterator wrapper exists yet.
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
        .replacement = suggestions[0].name,
    };
    return hints;
}

fn hintsForUnknownKey(ctx: Context) Allocator.Error![]const Hint {
    const hints = try ctx.arena.alloc(Hint, 1);
    if (try suggestNearestKey(ctx)) |note| {
        hints[0] = note;
        return hints;
    }
    hints[0] = .{
        .kind = .help,
        .body = "See `sjon explain unknown_key`. Discriminated forms reject variant keys that appear before the discriminant kvpair.",
    };
    return hints;
}

/// Nearest-key lookup behind `unknown_key`'s hint. The validator's
/// message carries the offending key (first backticked token,
/// `:`-prefixed) and the enclosing form head (second token); the
/// form's declared keys (common and variant alike) are the
/// candidate set. Null when the schema is absent, the form can't be
/// resolved, or no candidate is within `DidYouMean.MAX_DISTANCE`.
fn suggestNearestKey(ctx: Context) Allocator.Error!?Hint {
    const schema = ctx.schema orelse return null;
    const msg = ctx.diagnostic.message;
    const open = std.mem.indexOfScalar(u8, msg, '`') orelse return null;
    const after_open = msg[open + 1 ..];
    const close = std.mem.indexOfScalar(u8, after_open, '`') orelse return null;
    const key_token = after_open[0..close];
    const needle = if (key_token.len > 0 and key_token[0] == ':') key_token[1..] else key_token;
    if (needle.len == 0) return null;
    const form_name = extractQuotedName(after_open[close + 1 ..]) orelse return null;

    const form = findForm(schema, form_name) orelse return null;
    var names: std.ArrayList([]const u8) = .empty;
    for (form.keys) |k| try names.append(ctx.arena, k.name);
    if (form.variants) |variants| {
        for (variants) |v| {
            for (v.keys) |k| try names.append(ctx.arena, k.name);
        }
    }
    const suggestions = try DidYouMean.suggest(ctx.arena, needle, names.items, 3);
    if (suggestions.len == 0) return null;
    return .{
        .kind = .note,
        .body = try std.fmt.allocPrint(ctx.arena, "Did you mean `:{s}`?", .{suggestions[0].name}),
        // The span covers the offending `:key` token, colon included.
        .replacement = try std.fmt.allocPrint(ctx.arena, ":{s}", .{suggestions[0].name}),
    };
}

/// Resolve a bare form head against the aggregate schema. First match
/// wins, since `unknown_key` is only emitted against a form that already
/// resolved, so the head is unambiguous by the time this runs.
fn findForm(schema: *const Schema.Schema, name: []const u8) ?*const Plugin.FormSpec {
    for (schema.plugins) |plugin| {
        for (plugin.forms) |*form| {
            if (std.mem.eql(u8, form.name, name)) return form;
        }
    }
    return null;
}

fn hintsForArityMismatch(ctx: Context) Allocator.Error![]const Hint {
    const hints = try ctx.arena.alloc(Hint, 1);
    hints[0] = .{
        .kind = .help,
        .body = "Function arity declarations come in three shapes: `(fixed N)`, `(at-least N)`, and `(range :min M :max N)`. See `sjon explain arity_mismatch`.",
    };
    return hints;
}

/// Find the first backtick-delimited token in a diagnostic message.
/// Used to recover the offending identifier when only the rendered
/// message text is available.
fn extractQuotedName(msg: []const u8) ?[]const u8 {
    const first = std.mem.indexOfScalar(u8, msg, '`') orelse return null;
    const after = msg[first + 1 ..];
    const close = std.mem.indexOfScalar(u8, after, '`') orelse return null;
    return after[0..close];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Hints.extractQuotedName: pulls first backtick-delimited token" {
    try testing.expectEqualStrings("shape", extractQuotedName("no plugin named `shape` in project").?);
    try testing.expectEqualStrings("foo", extractQuotedName("`foo`").?);
    try testing.expect(extractQuotedName("no backticks") == null);
}

test "Hints.forDiagnostic: unresolved_plugin suggests nearest name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const diag: Ast.Diagnostic = .{
        .code = .unresolved_plugin,
        .message = "no plugin named `shape`",
        .span = .{ .start = 0, .end = 0 },
        .path = &.{},
    };
    const names = [_][]const u8{ "shapes", "audio" };
    const hints = try forDiagnostic(.{
        .arena = arena.allocator(),
        .diagnostic = &diag,
        .known_plugin_names = &names,
    });
    try testing.expectEqual(@as(usize, 2), hints.len);
    try testing.expect(std.mem.indexOf(u8, hints[0].body, "shapes") != null);
    try testing.expectEqual(HintKind.help, hints[1].kind);
    try testing.expect(std.mem.endsWith(u8, hints[1].body, "/unresolved_plugin"));
}

test "Hints.forDiagnostic: plugin_hash_mismatch returns recompute hint + help" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const diag: Ast.Diagnostic = .{
        .code = .plugin_hash_mismatch,
        .message = "pin disagrees",
        .span = .{ .start = 0, .end = 0 },
        .path = &.{},
    };
    const hints = try forDiagnostic(.{
        .arena = arena.allocator(),
        .diagnostic = &diag,
    });
    try testing.expectEqual(@as(usize, 3), hints.len);
    try testing.expectEqual(HintKind.hint, hints[0].kind);
    try testing.expectEqual(HintKind.help, hints[1].kind);
    try testing.expect(std.mem.endsWith(u8, hints[2].body, "/plugin_hash_mismatch"));
}

test "Hints.forDiagnostic: unknown_key suggests nearest declared key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keys = [_]Plugin.KeySpec{ .{ .name = "mode" }, .{ .name = "zoom" } };
    const forms = [_]Plugin.FormSpec{.{ .name = "camera", .keys = &keys }};
    const plugins = [_]Plugin.Plugin{.{ .name = "demo", .forms = &forms }};
    const schema: Schema.Schema = .{ .plugins = &plugins };
    const diag: Ast.Diagnostic = .{
        .code = .unknown_key,
        .message = "unknown keyword `:zom` in form `camera`",
        .span = .{ .start = 0, .end = 0 },
        .path = &.{},
    };
    const hints = try forDiagnostic(.{
        .arena = arena.allocator(),
        .diagnostic = &diag,
        .schema = &schema,
    });
    try testing.expectEqual(@as(usize, 2), hints.len);
    try testing.expectEqual(HintKind.note, hints[0].kind);
    try testing.expectEqualStrings("Did you mean `:zoom`?", hints[0].body);
}

test "Hints.forDiagnostic: unknown_key suggestion covers variant keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const common = [_]Plugin.KeySpec{.{ .name = "kind" }};
    const bass_keys = [_]Plugin.KeySpec{.{ .name = "sequence" }};
    const variants = [_]Plugin.Variant{.{ .when = &.{"bass"}, .keys = &bass_keys }};
    const forms = [_]Plugin.FormSpec{.{
        .name = "track",
        .keys = &common,
        .variants = &variants,
    }};
    const plugins = [_]Plugin.Plugin{.{ .name = "demo", .forms = &forms }};
    const schema: Schema.Schema = .{ .plugins = &plugins };
    const diag: Ast.Diagnostic = .{
        .code = .unknown_key,
        .message = "unknown keyword `:sequnce` in form `track` (variant `:when bass`)",
        .span = .{ .start = 0, .end = 0 },
        .path = &.{},
    };
    const hints = try forDiagnostic(.{
        .arena = arena.allocator(),
        .diagnostic = &diag,
        .schema = &schema,
    });
    try testing.expectEqual(@as(usize, 2), hints.len);
    try testing.expectEqual(HintKind.note, hints[0].kind);
    try testing.expectEqualStrings("Did you mean `:sequence`?", hints[0].body);
}

test "Hints.forDiagnostic: unknown_key without schema falls back to generic help" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const diag: Ast.Diagnostic = .{
        .code = .unknown_key,
        .message = "unknown keyword `:zom` in form `camera`",
        .span = .{ .start = 0, .end = 0 },
        .path = &.{},
    };
    const hints = try forDiagnostic(.{
        .arena = arena.allocator(),
        .diagnostic = &diag,
    });
    try testing.expectEqual(@as(usize, 2), hints.len);
    try testing.expectEqual(HintKind.help, hints[0].kind);
}

test "Hints.forDiagnostic: unknown_key with no close key falls back to generic help" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keys = [_]Plugin.KeySpec{ .{ .name = "mode" }, .{ .name = "zoom" } };
    const forms = [_]Plugin.FormSpec{.{ .name = "camera", .keys = &keys }};
    const plugins = [_]Plugin.Plugin{.{ .name = "demo", .forms = &forms }};
    const schema: Schema.Schema = .{ .plugins = &plugins };
    const diag: Ast.Diagnostic = .{
        .code = .unknown_key,
        .message = "unknown keyword `:qqqqqq` in form `camera`",
        .span = .{ .start = 0, .end = 0 },
        .path = &.{},
    };
    const hints = try forDiagnostic(.{
        .arena = arena.allocator(),
        .diagnostic = &diag,
        .schema = &schema,
    });
    try testing.expectEqual(@as(usize, 2), hints.len);
    try testing.expectEqual(HintKind.help, hints[0].kind);
}

test "Hints.forDiagnostic: unregistered code returns only the docs link" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const diag: Ast.Diagnostic = .{
        .code = .number_overflow_exact_integer,
        .message = "overflow",
        .span = .{ .start = 0, .end = 0 },
        .path = &.{},
    };
    const hints = try forDiagnostic(.{
        .arena = arena.allocator(),
        .diagnostic = &diag,
    });
    try testing.expectEqual(@as(usize, 1), hints.len);
    try testing.expectEqual(HintKind.help, hints[0].kind);
    try testing.expect(std.mem.endsWith(u8, hints[0].body, "/number_overflow_exact_integer"));
}
