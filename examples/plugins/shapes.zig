//! Reference plugin: `shapes`, a tiny 2-D drawing vocabulary.
//!
//! This file is meant to be **read alongside `src/Plugin.zig`**: it
//! exercises every plugin extension point SJON exposes today, and is
//! wired into `zig build test` so it can't drift from the runtime.
//!
//! What it shows:
//!
//!   * `forms`:         `(canvas …)`, `(circle …)`, `(rect …)`, `(group …)`,
//!                      `(scene …)`. Mix of `.positional = .any` and
//!                      `.positional = .none`; `scene` sets `.open = true`
//!                      to opt out of unknown-key checks.
//!   * `value_kinds`:   `length` (number) and `point` (vector). Referenced
//!                      from key `value_type` declarations as
//!                      `.{ .named = .{ .name = "length" } }`.
//!   * `expr_funcs`:    `golden` and `deg`. Declared so the validator can
//!                      recognise them in expression position; the actual
//!                      evaluator dispatch for plugin funcs is a v0.3
//!                      concern (today they return
//!                      `error.PluginFuncNotImplemented` from `Expr.eval`).
//!                      Names are deliberately domain-flavoured so they
//!                      can't collide with core's stdlib (e.g. `tau`).
//!
//! Lifting this into a downstream package: copy this file into your own
//! repo and add a path dependency on `sjon` in your `build.zig.zon`. The
//! README next to this file walks through the pattern.

const std = @import("std");
const sjon = @import("sjon");
const Plugin = sjon.Plugin;

/// The `shapes` plugin descriptor. Pass it alongside `sjon.plugins.core.plugin`
/// to `Schema.init` to compose them into one schema.
pub const plugin: Plugin.Plugin = .{
    .name = "shapes",
    .forms = &forms,
    .expr_funcs = &expr_funcs,
    .value_kinds = &value_kinds,
};

// ---------------------------------------------------------------------------
// Forms
// ---------------------------------------------------------------------------

const forms = [_]Plugin.FormSpec{
    .{
        .name = "canvas",
        .description = "Drawing surface. Positional children are shapes.",
        .keys = &.{
            .{ .name = "w", .value_type = .{ .named = .{ .name = "length" } } },
            .{ .name = "h", .value_type = .{ .named = .{ .name = "length" } } },
            .{ .name = "bg", .value_type = .string, .description = "Named background colour (\"black\", \"#202028\", …)." },
        },
        .positional = .any,
    },
    .{
        .name = "circle",
        .description = "Filled circle at :center with given :radius.",
        .keys = &.{
            .{ .name = "center", .value_type = .{ .named = .{ .name = "point" } } },
            .{ .name = "radius", .value_type = .{ .named = .{ .name = "length" } } },
            .{ .name = "fill", .value_type = .{ .named = .{ .name = "fill-rule" } }, .description = "Optional :evenodd or :nonzero fill rule." },
        },
        .positional = .none,
    },
    .{
        .name = "rect",
        .description = "Axis-aligned rectangle from :origin spanning :size.",
        .keys = &.{
            .{ .name = "origin", .value_type = .{ .named = .{ .name = "point" } } },
            .{ .name = "size", .value_type = .vector },
        },
        .positional = .none,
    },
    .{
        .name = "group",
        .description = "Named container of shapes; positional children are shapes.",
        .keys = &.{
            .{ .name = "name", .value_type = .string },
        },
        .positional = .any,
    },
    .{
        .name = "scene",
        .description = "Top-level scene. `open = true` so authors can attach " ++
            "ad-hoc metadata keywords without the validator complaining.",
        .keys = &.{
            .{ .name = "title", .value_type = .string },
        },
        .positional = .any,
        .open = true,
    },
    .{
        .name = "badge",
        .description = "Tiny labelled mark. `:shape` is HeadSet-pinned: " ++
            "only `(circle …)` or `(rect …)` are accepted as the focal form.",
        .keys = &.{
            .{ .name = "label", .value_type = .string },
            .{ .name = "shape", .value_type = .{ .named = .{ .name = "shape-form" } } },
        },
        .positional = .none,
    },
};

comptime {
    for (forms) |f| std.debug.assert(f.keys.len <= Plugin.MAX_FORM_KEYS);
}

// ---------------------------------------------------------------------------
// Value kinds
// ---------------------------------------------------------------------------

const value_kinds = [_]Plugin.ValueKind{
    .{
        .name = "length",
        .underlying = .number,
        .description = "Non-negative scalar in canvas units.",
    },
    .{
        .name = "point",
        .underlying = .vector,
        .description = "[x y] vector in canvas coordinates.",
    },
    .{
        .name = "fill-rule",
        .underlying = .symbol,
        .members = .{ .members = &.{ .{ .name = "evenodd" }, .{ .name = "nonzero" } } },
        .description = "SVG-style fill rule. One of `evenodd` or `nonzero`.",
    },
    .{
        .name = "shape-form",
        .underlying = .form,
        .heads = .{ .heads = &.{ .{ .name = "circle" }, .{ .name = "rect" } } },
        .description = "Form-as-slot: `(circle …)` or `(rect …)`. Used by " ++
            "`(badge :shape …)` to pin the focal element's identity.",
    },
};

// ---------------------------------------------------------------------------
// Expression functions (declared; evaluator dispatch is a v0.3 concern)
// ---------------------------------------------------------------------------

const expr_funcs = [_]Plugin.ExprFunc{
    .{
        .name = "golden",
        .arity = .{ .fixed = 0 },
        .description = "Golden ratio (placeholder). Declared so the validator " ++
            "recognises it; evaluator dispatch lands with v0.3 plugin hooks.",
    },
    .{
        .name = "deg",
        .arity = .{ .fixed = 1 },
        .description = "Degrees → radians. Declared; not yet evaluable.",
    },
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Schema = sjon.Schema;
const Validator = sjon.Validator;
const Binary = sjon.Binary;
const Expr = sjon.Expr;

fn coreSchema() Schema.Schema {
    return Schema.Schema.init(&.{ sjon.plugins.core.plugin, plugin });
}

test "plugin descriptor: name + counts" {
    try testing.expectEqualStrings("shapes", plugin.name);
    try testing.expectEqual(@as(usize, 6), plugin.forms.len);
    try testing.expectEqual(@as(usize, 4), plugin.value_kinds.len);
    try testing.expectEqual(@as(usize, 2), plugin.expr_funcs.len);
}

test "schema: bare lookup of `circle` resolves to shapes plugin" {
    const schema = coreSchema();
    const hit = schema.lookupForm("circle", null);
    try testing.expect(hit == .found);
    try testing.expectEqualStrings("shapes", hit.found.plugin.name);
    try testing.expectEqualStrings("circle", hit.found.form.name);
}

test "schema: qualified lookup `shapes/rect` works" {
    const schema = coreSchema();
    const hit = schema.lookupForm("rect", "shapes");
    try testing.expect(hit == .found);
    try testing.expectEqualStrings("shapes", hit.found.plugin.name);
}

test "schema: qualified lookup with wrong namespace misses" {
    const schema = coreSchema();
    const hit = schema.lookupForm("rect", "core");
    try testing.expect(hit == .not_found);
}

test "schema: ambiguous bare name when two plugins claim it" {
    const decoy: Plugin.Plugin = .{
        .name = "other",
        .forms = &.{.{ .name = "circle" }},
    };
    const schema = Schema.Schema.init(&.{ plugin, decoy });
    const hit = schema.lookupForm("circle", null);
    try testing.expect(hit == .ambiguous);
    try testing.expectEqual(@as(u8, 2), hit.ambiguous.len);
}

test "schema: lookupValueKind finds shapes/length" {
    const schema = coreSchema();
    const hit = schema.lookupValueKind("length", null);
    try testing.expect(hit == .found);
    try testing.expectEqualStrings("length", hit.found.name);
    try testing.expectEqual(Plugin.ValueKind.Underlying.number, hit.found.underlying);
}

test "schema: lookupValueKind misses on unknown name" {
    const schema = coreSchema();
    try testing.expect(schema.lookupValueKind("noexist", null) == .not_found);
}

test "schema: lookupExprFunc finds shapes/golden" {
    const schema = coreSchema();
    const hit = schema.lookupExprFunc("golden", null);
    try testing.expect(hit == .found);
    try testing.expectEqualStrings("shapes", hit.found.plugin.name);
    try testing.expectEqual(@as(u8, 0), hit.found.func.arity.fixed);
}

test "validator: a clean scene has no diagnostics" {
    const a = testing.allocator;
    const src: [:0]const u8 =
        \\(scene :title "demo"
        \\  (canvas :w 320 :h 240 :bg "black"
        \\    (circle :center [160 120] :radius 32)
        \\    (rect   :origin [0 0]      :size [320 4])))
    ;
    var tree = try sjon.parse(a, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    var result = try sjon.validate(a, tree, coreSchema());
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "validator: unknown keyword on circle is flagged" {
    const a = testing.allocator;
    const src: [:0]const u8 =
        \\(circle :center [0 0] :radius 1 :fillColor "red")
    ;
    var tree = try sjon.parse(a, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    var result = try sjon.validate(a, tree, coreSchema());
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try testing.expect(result.hasErrors());
}

test "validator: positional child on a `.none` form is flagged" {
    const a = testing.allocator;
    const src: [:0]const u8 = "(circle :center [0 0] :radius 1 \"stray\")";
    var tree = try sjon.parse(a, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    var result = try sjon.validate(a, tree, coreSchema());
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.diagnostics.len);
}

test "validator: open form (scene) silently accepts unknown keys" {
    const a = testing.allocator;
    const src: [:0]const u8 =
        \\(scene :title "demo" :author "ada" :built-at "2026-04")
    ;
    var tree = try sjon.parse(a, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    var result = try sjon.validate(a, tree, coreSchema());
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "validator: forms compose with core expressions in keyword positions" {
    // Demonstrates that a key value can itself be a safe expression: the
    // validator just walks it and checks the head, no special-casing needed.
    const a = testing.allocator;
    const src: [:0]const u8 =
        \\(circle :center [0 0] :radius (* 2 (+ 1 0.5)))
    ;
    var tree = try sjon.parse(a, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    var result = try sjon.validate(a, tree, coreSchema());
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "binary IR: round-trip preserves a shapes scene under stripped flags" {
    const a = testing.allocator;
    const src: [:0]const u8 =
        \\(scene :title "demo"
        \\  (canvas :w 320 :h 240 :bg "black"
        \\    (circle :center [160 120] :radius 32)
        \\    (group  :name "ui"
        \\      (rect :origin [0 0] :size [320 4])
        \\      (rect :origin [0 236] :size [320 4]))))
    ;
    var tree = try sjon.parse(a, src);
    defer tree.deinit();

    const bin = try sjon.toBinary(a, tree, Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();

    var rebuilt = try sjon.fromBinary(a, bin.data, .{});
    defer rebuilt.deinit();

    const before = try sjon.print(a, tree, .{});
    defer before.deinit();
    const after = try sjon.print(a, rebuilt, .{});
    defer after.deinit();
    try testing.expectEqualStrings(before.data, after.data);

    var v_text = try sjon.validate(a, tree, coreSchema());
    defer v_text.deinit();
    var v_bin = try sjon.validateBinary(a, bin.data, coreSchema());
    defer v_bin.deinit();
    try testing.expectEqual(v_text.diagnostics.len, v_bin.diagnostics.len);
    try testing.expectEqual(@as(usize, 0), v_bin.diagnostics.len);
}

test "validator: circle with :fill evenodd is accepted" {
    const a = testing.allocator;
    const src: [:0]const u8 = "(circle :center [0 0] :radius 1 :fill evenodd)";
    var tree = try sjon.parse(a, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    var result = try sjon.validate(a, tree, coreSchema());
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "validator: circle with :fill diagonal is rejected with member-set diagnostic" {
    const a = testing.allocator;
    const src: [:0]const u8 = "(circle :center [0 0] :radius 1 :fill diagonal)";
    var tree = try sjon.parse(a, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    var result = try sjon.validate(a, tree, coreSchema());
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    const msg = result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "`fill-rule`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`diagonal`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`evenodd`") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "`nonzero`") != null);
}

test "validator: badge with :shape (circle) accepted by HeadSet" {
    const a = testing.allocator;
    const src: [:0]const u8 = "(badge :label \"hi\" :shape (circle :center [0 0] :radius 1))";
    var tree = try sjon.parse(a, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    var result = try sjon.validate(a, tree, coreSchema());
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "validator: badge with :shape (group) rejected by HeadSet" {
    const a = testing.allocator;
    const src: [:0]const u8 = "(badge :label \"x\" :shape (group :name \"oops\"))";
    var tree = try sjon.parse(a, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    var result = try sjon.validate(a, tree, coreSchema());
    defer result.deinit();
    try testing.expect(result.hasErrors());
    const msg = result.diagnostics[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "group") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "circle") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "rect") != null);
}

test "expression: declared plugin func is recognised by lookup but not evaluated" {
    // The validator accepts `(golden)` because it's declared; the evaluator
    // returns `error.PluginFuncNotImplemented` because dispatch hasn't
    // been wired in v0.2. This test pins both behaviours so v0.3 can
    // intentionally flip it.
    const a = testing.allocator;
    const src: [:0]const u8 = "(golden)";
    var tree = try sjon.parse(a, src);
    defer tree.deinit();

    var v = try sjon.validate(a, tree, coreSchema());
    defer v.deinit();
    try testing.expectEqual(@as(usize, 0), v.diagnostics.len);

    const env: Expr.Env = .{};
    try testing.expectError(
        error.PluginFuncNotImplemented,
        sjon.evalExpr(a, tree, tree.root[0], &env, coreSchema()),
    );
}
