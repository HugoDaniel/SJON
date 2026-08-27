//! Markdown reference-page backend — the third `Model` consumer, peer
//! to `JsonSchema` and `TsTypes`. Renders each plugin as the reference
//! page a schema author would hand to their users: forms with key
//! tables, positional specs, variants and local forms, value kinds with
//! member tables, and expression functions with signatures.
//!
//! Rule of thumb: **render what hover renders.** If hover learned a
//! refinement (bounds, units, member deprecations, formats), this page
//! must carry it too, and the shapes golden pins it.
//!
//! Determinism: iteration follows the manifest's declaration order —
//! the reference page reads in the author's order. (The JSON Schema /
//! TS backends sort keys alphabetically for diff-stability instead;
//! both orders are deterministic, they just serve different readers.)
//!
//! Recursion over `ValueShape` (vector elements, union arms, local
//! forms) mirrors the other two backends: bounded by the finite
//! manifest tree, the `docs/zig-discipline.md` carve-out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Model = @import("Model.zig");
const Warnings = @import("Warnings.zig");

pub const Error = error{OutOfMemory};

/// Aggregated emit: every plugin on one page, with an index when there
/// is more than one.
pub fn emit(
    a: Allocator,
    model: Model.Model,
    warnings: []const Warnings.Warning,
) Error![]const u8 {
    _ = warnings; // Warnings ride the export stream, not the reference page.
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    writeAll(&aw.writer, model, null) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return aw.toOwnedSlice();
}

/// Per-plugin emit: one plugin's page, self-contained.
pub fn emitForPlugin(
    a: Allocator,
    model: Model.Model,
    plugin: Model.Plugin_,
    warnings: []const Warnings.Warning,
) Error![]const u8 {
    _ = warnings;
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    writeAll(&aw.writer, model, plugin.name) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return aw.toOwnedSlice();
}

fn writeAll(w: *Writer, model: Model.Model, only_plugin: ?[]const u8) Writer.Error!void {
    var emitted: usize = 0;
    var total: usize = 0;
    for (model.plugins) |p| {
        if (only_plugin) |name| {
            if (!std.mem.eql(u8, p.name, name)) continue;
        }
        total += 1;
    }
    if (only_plugin == null and total > 1) {
        try w.writeAll("# Schema reference\n\n");
        for (model.plugins) |p| {
            try w.print("- [{s}](#{s})\n", .{ p.name, p.name });
        }
        try w.writeAll("\n");
    }
    for (model.plugins) |p| {
        if (only_plugin) |name| {
            if (!std.mem.eql(u8, p.name, name)) continue;
        }
        if (emitted > 0) try w.writeAll("\n");
        try writePlugin(w, p);
        emitted += 1;
    }
}

fn writePlugin(w: *Writer, p: Model.Plugin_) Writer.Error!void {
    try w.print("# {s}", .{p.name});
    if (p.version.len > 0) try w.print(" v{s}", .{p.version});
    try w.writeAll("\n");
    if (p.description.len > 0) try w.print("\n{s}\n", .{p.description});

    if (p.forms.len > 0) {
        try w.writeAll("\n## Forms\n");
        for (p.forms) |f| try writeForm(w, &f, "###");
    }
    if (p.value_kinds.len > 0) {
        try w.writeAll("\n## Value kinds\n");
        for (p.value_kinds) |vk| try writeValueKind(w, vk);
    }
    if (p.expr_funcs.len > 0) {
        try w.writeAll("\n## Expression functions\n\n");
        try w.writeAll("| Function | Signature | Description |\n| --- | --- | --- |\n");
        for (p.expr_funcs) |f| {
            try w.print("| `{s}` | ", .{f.name});
            for (f.signatures, 0..) |sig, i| {
                if (i > 0) try w.writeAll("<br>");
                try w.print("`{s}`", .{sig});
            }
            try w.writeAll(" | ");
            try writeCell(w, f.description);
            try w.writeAll(" |\n");
        }
    }
}

/// One form section. `heading` is the Markdown heading marker (`###`
/// for top-level forms; local forms nest one level deeper).
fn writeForm(w: *Writer, f: *const Model.Form, heading: []const u8) Writer.Error!void {
    try w.print("\n{s} `({s} …)`\n", .{ heading, f.name });
    if (f.description.len > 0) try w.print("\n{s}\n", .{f.description});

    if (f.keys.len > 0) {
        try w.writeAll("\n| Key | Type | Required | Default | Constraints |\n| --- | --- | --- | --- | --- |\n");
        for (f.keys) |k| try writeKeyRow(w, k);
    }

    switch (f.positional) {
        .none => {},
        .any => try w.writeAll("\nPositional children: any.\n"),
        .kind => |shape| {
            try w.writeAll("\nPositional children: `");
            try writeTypeText(w, shape, .raw);
            try w.writeAll("`");
            try writeConstraintSuffix(w, shape);
            try w.writeAll(".\n");
            try writeChildCounts(w, shape);
        },
    }
    if (f.positional_flags) |flags| {
        try w.writeAll("\nPositional flags: ");
        for (flags, 0..) |flag, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("`{s}`", .{flag.name});
        }
        try w.writeAll(".\n");
    }
    if (f.open) try w.writeAll("\nOpen form: unknown keys are accepted.\n");

    if (f.discriminator) |disc| {
        for (disc.variants) |v| {
            // The manifest's own spelling of the gate — one value bare, a
            // set bracketed — so a single-value heading is unchanged.
            try w.print("\n{s}# Variant `:{s} ", .{ heading, disc.key_name });
            if (v.when.len == 1) {
                try w.writeAll(v.when[0]);
            } else {
                try w.writeByte('[');
                for (v.when, 0..) |x, i| {
                    if (i > 0) try w.writeByte(' ');
                    try w.writeAll(x);
                }
                try w.writeByte(']');
            }
            try w.writeAll("`\n");
            if (v.keys.len > 0) {
                try w.writeAll("\n| Key | Type | Required | Default | Constraints |\n| --- | --- | --- | --- | --- |\n");
                for (v.keys) |k| try writeKeyRow(w, k);
            }
        }
    }
    if (f.exclusive_groups.len > 0) {
        for (f.exclusive_groups) |g| {
            try w.print("\nExclusive group ({s}): ", .{@tagName(g.cardinality)});
            for (g.alternatives, 0..) |alt, i| {
                if (i > 0) try w.writeAll(" | ");
                for (alt, 0..) |name, j| {
                    if (j > 0) try w.writeAll(" + ");
                    try w.print("`:{s}`", .{name});
                }
            }
            try w.writeAll(".\n");
        }
    }
    if (f.lowering) |l| {
        try w.print("\nLowering hook `{s}` produces: ", .{l.hook});
        for (l.produces, 0..) |head, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("`{s}`", .{head});
        }
        try w.writeAll(".\n");
    }

    // Slot-local forms render in place, one heading level down, so the
    // page shows the closed local vocabulary next to the slot's form.
    // Every carrier, not just the keyed one: a *positional* locals slot
    // named its locals in the type sentence and then never showed them,
    // which is the one surface a reader of the closed-positional-set
    // recipe (`docs/portable-manifest-v1.md` §5.2) most needs.
    for (f.keys) |k| try writeLocalBodies(w, k.value);
    switch (f.positional) {
        .kind => |shape| try writeLocalBodies(w, shape),
        .none, .any => {},
    }
}

/// Render the inline bodies a shape carries, whichever shape carries
/// them — the open `form_locals` union, or the `.local` members of a
/// closed head-set.
fn writeLocalBodies(w: *Writer, shape: Model.ValueShape) Writer.Error!void {
    switch (shape) {
        .form_locals => |locals| for (locals) |lf| try writeForm(w, &lf, "####"),
        .form_heads => |hs| for (hs.refs) |ref| switch (ref.body) {
            .local => |lf| try writeForm(w, lf, "####"),
            .global, .unresolved => {},
        },
        else => {},
    }
}

fn writeKeyRow(w: *Writer, k: Model.Key) Writer.Error!void {
    try w.print("| `:{s}` | `", .{k.name});
    try writeTypeText(w, k.value, .escaped);
    try w.writeAll("` | ");
    try w.writeAll(if (k.optional) "no" else "yes");
    try w.writeAll(" | ");
    if (k.default) |d| {
        try w.writeAll("`");
        try writeDefaultText(w, d);
        try w.writeAll("`");
    } else {
        try w.writeAll("—");
    }
    try w.writeAll(" | ");
    var any = false;
    try writeConstraintsCell(w, k.value, &any);
    if (k.requires.len != 0) {
        try sep(w, &any);
        try w.writeAll("requires ");
        for (k.requires, 0..) |r, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll("`:");
            try w.writeAll(r);
            try w.writeAll("`");
        }
    }
    if (!any and k.description.len == 0) try w.writeAll("—");
    if (k.description.len > 0) {
        if (any) try w.writeAll("<br>");
        try writeCell(w, k.description);
    }
    try w.writeAll(" |\n");
}

/// How a `|` inside type text renders: `.raw` for prose contexts,
/// `.escaped` (`\|`) inside table cells — GFM's documented way to keep
/// a pipe from splitting the row, honored even inside code spans.
const PipeStyle = enum { raw, escaped };

fn pipe(w: *Writer, style: PipeStyle) Writer.Error!void {
    try w.writeAll(switch (style) {
        .raw => " | ",
        .escaped => " \\| ",
    });
}

/// The compact type name for a shape — the table's `Type` column.
fn writeTypeText(w: *Writer, shape: Model.ValueShape, pipes: PipeStyle) Writer.Error!void {
    switch (shape) {
        .any => try w.writeAll("any"),
        .nil => try w.writeAll("nil"),
        .boolean => try w.writeAll("boolean"),
        .number, .number_bounded => try w.writeAll("number"),
        .number_i64 => try w.writeAll("integer (i64)"),
        .number_u64 => try w.writeAll("integer (u64)"),
        .number_with_unit => try w.writeAll("number+unit"),
        .string, .string_with_bounds => try w.writeAll("string"),
        .symbol => try w.writeAll("symbol"),
        .symbol_members, .symbol_members_rich => try w.writeAll("symbol enum"),
        .string_members, .string_members_rich => try w.writeAll("string enum"),
        .date => try w.writeAll("date"),
        .time => try w.writeAll("time"),
        .keyword => try w.writeAll("keyword"),
        .vector => |v| {
            try w.writeAll("vector<");
            try writeTypeText(w, v.element.*, pipes);
            try w.writeAll(">");
        },
        .form_any => try w.writeAll("form"),
        .form_heads => |hs| {
            try w.writeAll("form: ");
            for (hs.refs, 0..) |h, i| {
                if (i > 0) try pipe(w, pipes);
                // A local head is marked, because "which body does this
                // name mean" is the one thing a reader of a head-set
                // recipe cannot work out from the head alone — the local
                // shadows any same-named global.
                //
                // `.unresolved` deliberately renders plain. In a slot it
                // is already an `.err` with a precise message, so the
                // marker would only repeat it; and in the value-kind
                // table — which has no slot, so every local-only head
                // arrives unresolved — "undeclared" would be false. The
                // marker answers "which body", and only `.local` changes
                // that answer.
                switch (h.body) {
                    .global, .unresolved => try w.print("({s} …)", .{h.name}),
                    .local => try w.print("({s} …, local)", .{h.name}),
                }
            }
        },
        .form_locals => |locals| {
            try w.writeAll("form (local: ");
            for (locals, 0..) |lf, i| {
                if (i > 0) try pipe(w, pipes);
                try w.print("({s} …)", .{lf.name});
            }
            try pipe(w, pipes);
            try w.writeAll("any global)");
        },
        .expr => try w.writeAll("expr"),
        // Provider route reads a `:{source-key}` string and hands it to a
        // named extractor; identity route reads a `:{name-key}` symbol.
        .cross_ref => |x| {
            try w.writeAll("ref → (");
            // A group reads as a disjunction in the head position, which
            // is where the choice actually is: `(a | b :name …)`. One
            // target prints exactly what it always did.
            for (x.targets, 0..) |t, i| {
                if (i > 0) try w.writeAll(" | ");
                try w.writeAll(t);
            }
            if (x.provider) |p|
                try w.print(" :{s} via {s})", .{ x.source_key orelse "", p })
            else
                try w.print(" :{s} …)", .{x.name_key});
        },
        .union_of => |alts| {
            for (alts, 0..) |alt, i| {
                if (i > 0) try pipe(w, pipes);
                try w.writeAll(alt.name);
            }
        },
        .unresolved_named => |u| {
            if (u.namespace) |ns| try w.print("{s}/", .{ns});
            try w.print("{s}?", .{u.name});
        },
    }
}

/// The `Constraints` cell: bounds, units, lengths, patterns, member
/// sets (with deprecation messages) — the same facts hover compresses
/// into its constraint summary. Sets `any.*` true when it wrote
/// anything.
fn writeConstraintsCell(w: *Writer, shape: Model.ValueShape, any: *bool) Writer.Error!void {
    switch (shape) {
        .number_bounded => |nb| try writeNumericBounds(w, nb, any),
        .number_with_unit => |u| {
            if (u.allowed.len > 0) {
                try sep(w, any);
                try w.writeAll("unit ");
                for (u.allowed, 0..) |unit, i| {
                    if (i > 0) try w.writeAll("/");
                    try w.print("`{s}`", .{unit});
                }
                if (!u.required) try w.writeAll(" (optional)");
            } else {
                try sep(w, any);
                try w.writeAll(if (u.required) "unit required" else "unit optional");
            }
            if (u.bounds) |nb| try writeNumericBounds(w, nb, any);
        },
        .string_with_bounds => |sb| {
            if (sb.min_len) |n| {
                try sep(w, any);
                try w.print("min-len {d}", .{n});
            }
            if (sb.max_len) |n| {
                try sep(w, any);
                try w.print("max-len {d}", .{n});
            }
            if (sb.pattern) |pat| {
                try sep(w, any);
                try w.print("pattern `{s}`", .{pat});
            }
            if (sb.format) |fmt| {
                try sep(w, any);
                try w.print("format {s}", .{@tagName(fmt)});
            }
        },
        .symbol_members, .string_members => |names| {
            try sep(w, any);
            try w.writeAll("one of: ");
            for (names, 0..) |n, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("`{s}`", .{n});
            }
        },
        .symbol_members_rich, .string_members_rich => |members| {
            try sep(w, any);
            try w.writeAll("one of: ");
            try writeMemberList(w, members);
        },
        .vector => |v| {
            if (v.len) |n| {
                try sep(w, any);
                try w.print("len {d}", .{n});
            }
            if (v.min_len) |n| {
                try sep(w, any);
                try w.print("min-len {d}", .{n});
            }
            if (v.max_len) |n| {
                try sep(w, any);
                try w.print("max-len {d}", .{n});
            }
            try writeConstraintsCell(w, v.element.*, any);
        },
        .union_of => |alts| {
            for (alts) |alt| try writeConstraintsCell(w, alt.shape, any);
        },
        else => {},
    }
}

fn writeNumericBounds(w: *Writer, nb: Model.NumericBounds, any: *bool) Writer.Error!void {
    if (nb.integer) {
        try sep(w, any);
        try w.writeAll("integer");
    }
    if (nb.min) |b| {
        try sep(w, any);
        try w.print("min {s}{d}", .{ if (nb.exclusive_min) ">" else "", b.value });
        if (b.unit) |u| try w.print(" {s}", .{u});
    }
    if (nb.max) |b| {
        try sep(w, any);
        try w.print("max {s}{d}", .{ if (nb.exclusive_max) "<" else "", b.value });
        if (b.unit) |u| try w.print(" {s}", .{u});
    }
    if (nb.multiple_of) |b| {
        try sep(w, any);
        try w.print("×{d}", .{b.value});
        if (b.unit) |u| try w.print(" {s}", .{u});
    }
    if (nb.repr) |r| {
        try sep(w, any);
        try w.print("repr {s}", .{@tagName(r)});
    }
}

fn sep(w: *Writer, any: *bool) Writer.Error!void {
    if (any.*) try w.writeAll("; ");
    any.* = true;
}

fn writeMemberList(w: *Writer, members: []const Model.Member) Writer.Error!void {
    for (members, 0..) |m, i| {
        if (i > 0) try w.writeAll(", ");
        if (m.deprecated) {
            try w.print("~~`{s}`~~ (deprecated", .{m.name});
            if (m.deprecation_message.len > 0) {
                try w.writeAll(": ");
                try writeCell(w, m.deprecation_message);
            }
            try w.writeAll(")");
        } else {
            try w.print("`{s}`", .{m.name});
        }
        if (m.label.len > 0) try w.print(" — {s}", .{m.label});
    }
}

fn writeDefaultText(w: *Writer, d: Model.Default) Writer.Error!void {
    switch (d) {
        .nil => try w.writeAll("nil"),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .number => |n| try w.print("{d}", .{n}),
        .string => |s| try w.print("\"{s}\"", .{s}),
        .symbol => |s| try w.writeAll(s),
        .vector => |elems| {
            try w.writeAll("[");
            for (elems, 0..) |e, i| {
                if (i > 0) try w.writeAll(" ");
                try writeDefaultText(w, e);
            }
            try w.writeAll("]");
        },
        .expression => |e| {
            try w.writeAll("(");
            if (e.namespace) |ns| try w.print("{s}/", .{ns});
            try w.writeAll(e.head);
            if (e.arg_count > 0) try w.writeAll(" …");
            try w.writeAll(")");
        },
    }
}

/// Positional-line variant of the constraints cell (no table context).
/// Per-head positional counts as a small table under the "Positional
/// children:" sentence, emitted only when some head declares a bound.
///
/// The plan called for "a bounds column in the positional table"; the
/// positional surface is a *sentence*, not a table, so the counts get a
/// table of their own rather than a column in one that doesn't exist. The
/// wording is prose rather than `min..max` notation because this is the
/// one export target read by a human at a terminal — "exactly 1" and "at
/// most 1" are the same facts a `1..1` / `0..1` reader has to translate.
fn writeChildCounts(w: *Writer, shape: Model.ValueShape) Writer.Error!void {
    const hs = switch (shape) {
        .form_heads => |h| h,
        else => return,
    };
    if (!hs.anyBounded()) return;

    try w.writeAll("\n| Head | Count |\n| --- | --- |\n");
    for (hs.refs) |ref| {
        try w.print("| `{s}` | ", .{ref.name});
        try writeCountProse(w, ref.min, ref.max);
        try w.writeAll(" |\n");
    }
    // The set's own count gets a row of its own, named for what it counts
    // rather than for a head — "any of these" is the whole claim, and a
    // reader scanning the Head column has to be able to see that this row
    // is not one more head. It comes last because it is the sum of the
    // rows above it.
    if (hs.isBounded()) {
        try w.writeAll("| *any of these* | ");
        try writeCountProse(w, hs.min_children, hs.max_children);
        try w.writeAll(" |\n");
    }
}

/// "exactly 1" / "at most 1" / "1 to 3" / "at least 2" / "any". Prose
/// rather than `min..max` notation because this is the one export target
/// read by a human at a terminal. Shared by the per-head rows and the
/// set's so the column reads uniformly.
fn writeCountProse(w: *Writer, min: u16, max: ?u16) Writer.Error!void {
    if (max) |mx| {
        if (min == mx) {
            try w.print("exactly {d}", .{mx});
        } else if (min == 0) {
            try w.print("at most {d}", .{mx});
        } else {
            try w.print("{d} to {d}", .{ min, mx });
        }
    } else if (min != 0) {
        try w.print("at least {d}", .{min});
    } else {
        try w.writeAll("any");
    }
}

fn writeConstraintSuffix(w: *Writer, shape: Model.ValueShape) Writer.Error!void {
    var any = false;
    var probe: std.Io.Writer.Discarding = .init(&.{});
    writeConstraintsCell(&probe.writer, shape, &any) catch {};
    if (!any) return;
    any = false;
    try w.writeAll(" (");
    try writeConstraintsCell(w, shape, &any);
    try w.writeAll(")");
}

fn writeValueKind(w: *Writer, vk: Model.ValueKindEntry) Writer.Error!void {
    try w.print("\n### {s}\n", .{vk.name});
    if (vk.description.len > 0) try w.print("\n{s}\n", .{vk.description});
    try w.writeAll("\nType: `");
    try writeTypeText(w, vk.shape, .raw);
    try w.writeAll("`");
    var any = false;
    var probe: std.Io.Writer.Discarding = .init(&.{});
    writeConstraintsCell(&probe.writer, vk.shape, &any) catch {};
    if (any) {
        any = false;
        try w.writeAll(" — ");
        try writeConstraintsCell(w, vk.shape, &any);
    }
    try w.writeAll(".\n");
}

/// Escape a free-text table cell: `|` would break the row, newlines
/// become `<br>`.
fn writeCell(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        '|' => try w.writeAll("\\|"),
        '\n' => try w.writeAll("<br>"),
        else => try w.writeByte(c),
    };
}

// ---------------------------------------------------------------------
// Tests — devx plan 06 CP1 reds, over hand-built IR.
// ---------------------------------------------------------------------

const testing = std.testing;

fn emitOne(a: Allocator, p: Model.Plugin_) Error![]const u8 {
    return emit(a, .{ .plugins = &[_]Model.Plugin_{p} }, &.{});
}

test "markdown export renders a form's keys with type, default, constraints" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keys = [_]Model.Key{
        .{ .name = "radius", .optional = true, .value = .{ .number_bounded = .{
            .min = .{ .value = 0 },
            .integer = true,
        } }, .default = .{ .number = 4 } },
        .{ .name = "label", .optional = false, .value = .string },
    };
    const forms = [_]Model.Form{.{ .name = "circle", .keys = &keys, .positional = .none }};
    const page = try emitOne(arena.allocator(), .{
        .name = "demo",
        .forms = &forms,
        .value_kinds = &.{},
    });
    try testing.expect(std.mem.indexOf(u8, page, "### `(circle …)`") != null);
    try testing.expect(std.mem.indexOf(u8, page, "| `:radius` | `number` | no | `4` | integer; min 0 |") != null);
    try testing.expect(std.mem.indexOf(u8, page, "| `:label` | `string` | yes | — | — |") != null);
}

test "a variant heading spells its :when as the manifest did — one bare, several bracketed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keys = [_]Model.Key{
        .{ .name = "topology", .optional = false, .value = .symbol },
    };
    const strip_keys = [_]Model.Key{
        .{ .name = "strip-index-format", .optional = true, .value = .symbol },
    };
    const variants = [_]Model.Variant{
        .{ .when = &.{ "tri-strip", "line-strip" }, .keys = &strip_keys },
        .{ .when = &.{"line-list"}, .keys = &.{} },
    };
    const forms = [_]Model.Form{.{
        .name = "prim",
        .keys = &keys,
        .positional = .none,
        .discriminator = .{ .key_name = "topology", .variants = &variants },
    }};
    const page = try emitOne(arena.allocator(), .{
        .name = "gfx",
        .forms = &forms,
        .value_kinds = &.{},
    });
    try testing.expect(std.mem.indexOf(u8, page, "# Variant `:topology [tri-strip line-strip]`") != null);
    try testing.expect(std.mem.indexOf(u8, page, "# Variant `:topology line-list`") != null);
}

test "bounded positional heads render as a count table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const heads = [_]Model.FormRef{
        .{ .plugin = "gfx", .name = "vertex", .min = 1, .max = 1 },
        .{ .plugin = "gfx", .name = "fragment", .max = 1 },
        .{ .plugin = "gfx", .name = "spread", .min = 2 },
        .{ .plugin = "gfx", .name = "ranged", .min = 1, .max = 3 },
        .{ .plugin = "gfx", .name = "constant" },
    };
    const forms = [_]Model.Form{.{
        .name = "render-pipeline",
        .keys = &.{},
        .positional = .{ .kind = .{ .form_heads = .{ .refs = &heads } } },
    }};
    const page = try emitOne(arena.allocator(), .{
        .name = "gfx",
        .forms = &forms,
        .value_kinds = &.{},
    });
    // Prose, not `min..max`: this is the one target a human reads at a
    // terminal, and every reader of `1..1` has to translate it anyway.
    try testing.expect(std.mem.indexOf(u8, page, "| `vertex` | exactly 1 |") != null);
    try testing.expect(std.mem.indexOf(u8, page, "| `fragment` | at most 1 |") != null);
    try testing.expect(std.mem.indexOf(u8, page, "| `spread` | at least 2 |") != null);
    try testing.expect(std.mem.indexOf(u8, page, "| `ranged` | 1 to 3 |") != null);
    // Unbounded heads still get a row, so the table is the whole set —
    // a head absent from it would read as "not accepted".
    try testing.expect(std.mem.indexOf(u8, page, "| `constant` | any |") != null);
}

test "a positional locals slot renders its local bodies, head-set or not" {
    // The keyed carrier always rendered its locals in place; the
    // positional one named them in the type sentence and then never
    // showed them, so the closed-positional-set recipe's whole vocabulary
    // was invisible on the page a human reads.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const local: Model.Form = .{
        .name = "entry",
        .keys = &.{.{ .name = "binding", .value = .number, .optional = false }},
        .positional = .none,
    };
    const heads = [_]Model.FormRef{
        .{ .plugin = "p", .name = "entry", .body = .{ .local = &local } },
        .{ .plugin = "p", .name = "buffer" },
    };
    const forms = [_]Model.Form{.{
        .name = "bind-group",
        .keys = &.{},
        .positional = .{ .kind = .{ .form_heads = .{ .refs = &heads } } },
    }};
    const page = try emitOne(arena.allocator(), .{
        .name = "p",
        .forms = &forms,
        .value_kinds = &.{},
    });
    // The body, one heading level down, exactly as a keyed local renders.
    try testing.expect(std.mem.indexOf(u8, page, "#### `(entry …)`") != null);
    try testing.expect(std.mem.indexOf(u8, page, "| `:binding` |") != null);
    // And the type sentence marks which head means a local body, since a
    // local shadows any same-named global.
    try testing.expect(std.mem.indexOf(u8, page, "(entry …, local)") != null);
    try testing.expect(std.mem.indexOf(u8, page, "(buffer …)") != null);
}

test "an all-unbounded positional head-set emits no count table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const heads = [_]Model.FormRef{
        .{ .plugin = "gfx", .name = "vertex" },
        .{ .plugin = "gfx", .name = "fragment" },
    };
    const forms = [_]Model.Form{.{
        .name = "loose",
        .keys = &.{},
        .positional = .{ .kind = .{ .form_heads = .{ .refs = &heads } } },
    }};
    const page = try emitOne(arena.allocator(), .{
        .name = "gfx",
        .forms = &forms,
        .value_kinds = &.{},
    });
    try testing.expect(std.mem.indexOf(u8, page, "Positional children:") != null);
    try testing.expect(std.mem.indexOf(u8, page, "| Head | Count |") == null);
}

test "deprecated members carry their deprecation message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const members = [_]Model.Member{
        .{ .name = "draft" },
        .{ .name = "archived", .deprecated = true, .deprecation_message = "use draft" },
    };
    const kinds = [_]Model.ValueKindEntry{.{
        .name = "status",
        .shape = .{ .symbol_members_rich = &members },
    }};
    const page = try emitOne(arena.allocator(), .{
        .name = "demo",
        .forms = &.{},
        .value_kinds = &kinds,
    });
    try testing.expect(std.mem.indexOf(u8, page, "~~`archived`~~ (deprecated: use draft)") != null);
}

test "expr-funcs render signatures and result types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const funcs = [_]Model.ExprFuncEntry{.{
        .name = "lerp",
        .description = "Linear interpolation.",
        .signatures = &.{"(lerp a: number b: number t: number) -> number"},
    }};
    const page = try emitOne(arena.allocator(), .{
        .name = "demo",
        .forms = &.{},
        .value_kinds = &.{},
        .expr_funcs = &funcs,
    });
    try testing.expect(std.mem.indexOf(u8, page, "## Expression functions") != null);
    try testing.expect(std.mem.indexOf(u8, page, "`(lerp a: number b: number t: number) -> number`") != null);
}

test "table cells escape pipes and newlines so GFM rows survive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const heads = [_]Model.FormRef{
        .{ .plugin = "demo", .name = "circle" },
        .{ .plugin = "demo", .name = "rect" },
    };
    const keys = [_]Model.Key{
        .{ .name = "child", .optional = false, .value = .{ .form_heads = .{ .refs = &heads } } },
        .{ .name = "note", .optional = true, .value = .string, .description = "a|b\nc" },
    };
    const forms = [_]Model.Form{.{ .name = "canvas", .keys = &keys, .positional = .none }};
    const page = try emitOne(arena.allocator(), .{
        .name = "demo",
        .forms = &forms,
        .value_kinds = &.{},
    });
    // A raw ` | ` in either the type column or a description would
    // split the row; `\|` is honored even inside code spans.
    try testing.expect(std.mem.indexOf(u8, page, "form: (circle …) \\| (rect …)") != null);
    try testing.expect(std.mem.indexOf(u8, page, "a\\|b<br>c") != null);
}

test "declaration order is preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const keys = [_]Model.Key{
        .{ .name = "zeta", .optional = false, .value = .number },
        .{ .name = "alpha", .optional = false, .value = .number },
    };
    const forms = [_]Model.Form{
        .{ .name = "omega", .keys = &keys, .positional = .none },
        .{ .name = "alpha-form", .keys = &.{}, .positional = .none },
    };
    const page = try emitOne(arena.allocator(), .{
        .name = "demo",
        .forms = &forms,
        .value_kinds = &.{},
    });
    // Forms and keys appear in manifest order, not sorted.
    const omega_at = std.mem.indexOf(u8, page, "(omega …)").?;
    const alpha_form_at = std.mem.indexOf(u8, page, "(alpha-form …)").?;
    try testing.expect(omega_at < alpha_form_at);
    const zeta_at = std.mem.indexOf(u8, page, ":zeta").?;
    const alpha_at = std.mem.indexOf(u8, page, ":alpha`").?;
    try testing.expect(zeta_at < alpha_at);
}
