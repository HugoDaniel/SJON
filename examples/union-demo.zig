//! Demo proving Underlying.union_of works end-to-end.
//!
//! Run with: zig build union-demo (after build.zig wires this in).
//! Builds four plugins, validates fresh inputs against them, and
//! prints pass/fail with diagnostics for each case.

const std = @import("std");
const sjon = @import("sjon");

fn run(
    gpa: std.mem.Allocator,
    label: []const u8,
    src: [:0]const u8,
    schema: sjon.Schema.Schema,
    expect_clean: bool,
) !void {
    var tree = try sjon.Parser.parse(gpa, src);
    defer tree.deinit();
    var result = try sjon.Validator.validate(gpa, tree, schema);
    defer result.deinit();

    const ok = (result.diagnostics.len == 0);
    const status = if (ok == expect_clean) "PASS" else "FAIL";
    std.debug.print("[{s}] {s}\n", .{ status, label });
    std.debug.print("  src     : {s}\n", .{src});
    std.debug.print("  expect  : {s}\n", .{if (expect_clean) "0 diagnostics" else ">=1 diagnostic"});
    std.debug.print("  got     : {} diagnostic(s)\n", .{result.diagnostics.len});
    for (result.diagnostics) |d| {
        std.debug.print("    [{s}] {s}\n", .{ @tagName(d.code), d.message });
    }
    std.debug.print("\n", .{});
}

pub fn main() !void {
    // Arena: schema-aggregate diagnostics own multi-piece allocations
    // (path strings + message). Freeing the outer slice misses the
    // pieces; arena makes the demo self-contained.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    // Case A — audio-sketch: vector slot accepting symbol | form.
    const audio_plugin: sjon.Plugin.Plugin = .{
        .name = "audio",
        .forms = &.{
            .{
                .name = "phrase",
                .keys = &.{.{ .name = "notes", .value_type = .{ .named = .{ .name = "notes-vec" } } }},
            },
            .{ .name = "n", .positional = .any },
            .{ .name = "rest", .positional = .any },
        },
        .value_kinds = &.{
            .{
                .name = "note-or-rest",
                .underlying = .symbol,
                .members = .{ .members = &.{ .{ .name = "E4" }, .{ .name = "G4" }, .{ .name = "A4" }, .{ .name = "B4" }, .{ .name = "_" } } },
            },
            .{
                .name = "event",
                .underlying = .form,
                .heads = .{ .heads = &.{ .{ .name = "n" }, .{ .name = "rest" } } },
            },
            .{
                .name = "note-or-event",
                .underlying = .union_of,
                .union_of = .{ .alternatives = &.{ .{ .name = "note-or-rest" }, .{ .name = "event" } } },
            },
            .{
                .name = "notes-vec",
                .underlying = .vector,
                .vector = .{ .element = .{ .name = "note-or-event" } },
            },
        },
    };

    std.debug.print("=== A. audio: vector slot accepting symbol | form ===\n\n", .{});
    const audio_schema = sjon.Schema.Schema.init(&.{audio_plugin});

    try run(gpa, "A1: empty",          "(phrase :notes [])",                                audio_schema, true);
    try run(gpa, "A2: just symbols",   "(phrase :notes [E4 G4 _])",                         audio_schema, true);
    try run(gpa, "A3: just forms",     "(phrase :notes [(n E4) (rest)])",                   audio_schema, true);
    try run(gpa, "A4: mixed",          "(phrase :notes [E4 (n G4 0.5b) _ (rest 0.25b)])",   audio_schema, true);
    try run(gpa, "A5: bad symbol",     "(phrase :notes [E4 X4])",                           audio_schema, false);
    try run(gpa, "A6: bad form head",  "(phrase :notes [(boom)])",                          audio_schema, false);
    try run(gpa, "A7: number element", "(phrase :notes [E4 42])",                           audio_schema, false);

    // Case B — scene-sketch: bare slot accepting number | vec4 | form.
    const scene_plugin: sjon.Plugin.Plugin = .{
        .name = "scene",
        .forms = &.{
            .{
                .name = "set",
                .keys = &.{.{ .name = "value", .value_type = .{ .named = .{ .name = "scalar-or-color-or-expr" } } }},
            },
        },
        .value_kinds = &.{
            .{
                .name = "vec4",
                .underlying = .vector,
                .vector = .{ .len = 4, .element = .{ .name = "number" } },
            },
            .{
                .name = "scalar-or-color-or-expr",
                .underlying = .union_of,
                .union_of = .{ .alternatives = &.{ .{ .name = "number" }, .{ .name = "vec4" }, .{ .name = "form" } } },
            },
        },
    };

    std.debug.print("=== B. scene: bare slot accepting number | vec4 | form ===\n\n", .{});
    // Compose with core plugin so the `form` alternative has a real
    // form vocabulary to match against (`+`, `lerp`, etc.). A bare
    // `form` alternative does not mean "any parens" — it still
    // resolves the head against the schema.
    const scene_schema = sjon.Schema.Schema.init(&.{ sjon.plugins.core.plugin, scene_plugin });

    try run(gpa, "B1: number",         "(set :value 1)",                      scene_schema, true);
    try run(gpa, "B2: vec4",           "(set :value [0.05 0.05 0.08 1])",     scene_schema, true);
    try run(gpa, "B3: core form",      "(set :value (+ 1 2))",                scene_schema, true);
    try run(gpa, "B4: vec3 (wrong len)","(set :value [1 2 3])",               scene_schema, false);
    try run(gpa, "B5: string",         "(set :value \"hi\")",                 scene_schema, false);
    try run(gpa, "B6: undeclared form","(set :value (foo 1 2))",              scene_schema, false);

    // Case C — schema-aggregate validation rejects nested unions.
    const nested_plugin: sjon.Plugin.Plugin = .{
        .name = "demo",
        .value_kinds = &.{
            .{
                .name = "inner",
                .underlying = .union_of,
                .union_of = .{ .alternatives = &.{ .{ .name = "number" }, .{ .name = "string" } } },
            },
            .{
                .name = "outer",
                .underlying = .union_of,
                .union_of = .{ .alternatives = &.{ .{ .name = "inner" }, .{ .name = "form" } } },
            },
        },
    };

    std.debug.print("=== C. schema-aggregate: nested union rejected ===\n\n", .{});
    {
        const nested_schema = sjon.Schema.Schema.init(&.{nested_plugin});
        const diags = try nested_schema.validateUnions(gpa);
        defer gpa.free(diags);
        const status = if (diags.len > 0) "PASS" else "FAIL";
        std.debug.print("[{s}] C1: nested union (outer's `inner` alt is itself a union)\n", .{status});
        std.debug.print("  schema diagnostics: {}\n", .{diags.len});
        for (diags) |d| {
            std.debug.print("    [{s}] {s}\n", .{ @tagName(d.code), d.message });
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("=== summary ===\n", .{});
    std.debug.print("A1-A7 exercise vector-of-union (symbol|form).\n", .{});
    std.debug.print("B1-B5 exercise bare-slot union (number|vec4|form).\n", .{});
    std.debug.print("C1    exercises schema-aggregate nested-union rejection.\n", .{});
}
