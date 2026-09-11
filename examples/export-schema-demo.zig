//! Schema-export end-to-end golden runner.
//!
//! Exports JSON Schema + TypeScript + IR for two reference plugins:
//!   - `shapes` (static plugin literal in `examples/plugins/shapes.zig`)
//!   - `double` (manifest-loaded from `examples/plugins/double/plugin.sjon`)
//!
//! Run modes:
//!   - default: compares the freshly-emitted bytes against the
//!     checked-in `.golden` files. Fails (exit 1) on any diff. This is
//!     what `zig build test` invokes.
//!   - `--regen`: writes the freshly-emitted bytes to the golden paths
//!     so a human can review the diff and re-commit. Use after an
//!     intentional change to the exporter or to a reference plugin.

const std = @import("std");
const sjon = @import("sjon");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const shapes = @import("plugins/shapes.zig");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var regen = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--regen")) regen = true;
    }

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file = Io.File.stderr();
    var stderr_writer = stderr_file.writer(io, &stderr_buf);
    defer stderr_writer.interface.flush() catch {};
    const stderr = &stderr_writer.interface;

    var any_diff = false;

    // --- shapes (static plugin) ---
    {
        const schema = sjon.Schema.Schema.init(&.{shapes.plugin});
        var result = try sjon.SchemaExport.exportSchema(gpa, schema, .{
            .target = .{ .json_schema = true, .ts_types = true, .intermediate = true, .markdown = true },
        });
        defer result.deinit();
        try handlePair(gpa, io, regen, stderr, "examples/plugins/shapes.schema.json.golden", result.json_schema_bytes.?, &any_diff);
        try handlePair(gpa, io, regen, stderr, "examples/plugins/shapes.d.ts.golden", result.ts_types_bytes.?, &any_diff);
        try handlePair(gpa, io, regen, stderr, "examples/plugins/shapes.export.json.golden", result.intermediate_bytes.?, &any_diff);
        try handlePair(gpa, io, regen, stderr, "examples/plugins/shapes.md.golden", result.markdown_bytes.?, &any_diff);
    }

    // --- double (manifest-loaded) ---
    try exportManifestFixture(gpa, io, regen, stderr, "examples/plugins/double/plugin.sjon", "examples/plugins/double/double", &any_diff, .{});

    // --- M2 fixtures (one per construct), manifest-loaded ---
    try exportManifestFixture(gpa, io, regen, stderr, "examples/plugins/kit/plugin.sjon", "examples/plugins/kit/kit", &any_diff, .{});
    try exportManifestFixture(gpa, io, regen, stderr, "examples/plugins/kit-xor/plugin.sjon", "examples/plugins/kit-xor/kit-xor", &any_diff, .{});
    try exportManifestFixture(gpa, io, regen, stderr, "examples/plugins/audio/plugin.sjon", "examples/plugins/audio/audio", &any_diff, .{});
    try exportManifestFixture(gpa, io, regen, stderr, "examples/plugins/enum-rich/plugin.sjon", "examples/plugins/enum-rich/enum-rich", &any_diff, .{});
    // Digit-leading member spellings (`1d`, `2d`): the one member shape
    // whose wire encoding is `$num` rather than `$sym`, so the JSON-Schema
    // and `.d.ts` goldens are where that is visible.
    try exportManifestFixture(gpa, io, regen, stderr, "examples/plugins/dimensions/plugin.sjon", "examples/plugins/dimensions/dimensions", &any_diff, .{ .markdown = true });

    // --- M3 fixtures (one per construct), manifest-loaded ---
    try exportManifestFixture(gpa, io, regen, stderr, "examples/plugins/bounds/plugin.sjon", "examples/plugins/bounds/bounds", &any_diff, .{});
    try exportManifestFixture(gpa, io, regen, stderr, "examples/plugins/units/plugin.sjon", "examples/plugins/units/units", &any_diff, .{});
    try exportManifestFixture(gpa, io, regen, stderr, "examples/plugins/xref/plugin.sjon", "examples/plugins/xref/xref", &any_diff, .{ .markdown = true });
    try exportManifestFixture(gpa, io, regen, stderr, "examples/plugins/xkey/plugin.sjon", "examples/plugins/xkey/xkey", &any_diff, .{});
    // Slot-local forms: an inline anonymous union (form_locals) on canvas.:shape.
    try exportManifestFixture(gpa, io, regen, stderr, "examples/plugins/local-forms/plugin.sjon", "examples/plugins/local-forms/local-forms", &any_diff, .{});
    try exportManifestFixture(gpa, io, regen, stderr, "examples/plugins/head-counts/plugin.sjon", "examples/plugins/head-counts/head-counts", &any_diff, .{ .markdown = true });
    // Markdown on: a closed head-set slot is the one place the page has to
    // render *positional* local bodies, which it silently never did.
    try exportManifestFixture(gpa, io, regen, stderr, "examples/plugins/headset-locals/plugin.sjon", "examples/plugins/headset-locals/headset-locals", &any_diff, .{ .markdown = true });
    // --- Value-kind refinements: GPU repr + variable-arity vectors + unit
    //     reject (gpu), and the scalar-or-ref shorthand. ---
    try exportManifestFixture(gpa, io, regen, stderr, "examples/plugins/gpu/plugin.sjon", "examples/plugins/gpu/gpu", &any_diff, .{});
    try exportManifestFixture(gpa, io, regen, stderr, "examples/plugins/scalar-or-ref/plugin.sjon", "examples/plugins/scalar-or-ref/scalar-or-ref", &any_diff, .{});
    // --- S14: a variant selected by several discriminant values. Markdown
    //     too, since the heading spells the set. ---
    try exportManifestFixture(gpa, io, regen, stderr, "examples/plugins/variant-set/plugin.sjon", "examples/plugins/variant-set/variant-set", &any_diff, .{ .markdown = true });
    // --- An opaque slot (`:walk-opaque true`). The exporters have nothing
    //     to say about the flag, and the goldens are the proof: the slot
    //     exports as any form-shaped slot does. The fixture is wired here
    //     so a manifest that stops loading fails the build. ---
    try exportManifestFixture(gpa, io, regen, stderr, "examples/plugins/opaque-slot/plugin.sjon", "examples/plugins/opaque-slot/opaque-slot", &any_diff, .{});
    // --- Defaults declared on variant keys, and a discriminant that defaults
    //     to a value selecting a variant. Markdown too, since the page is
    //     where a reader sees which keys a variant carries and what they
    //     default to. ---
    try exportManifestFixture(gpa, io, regen, stderr, "examples/plugins/variant-defaults/plugin.sjon", "examples/plugins/variant-defaults/variant-defaults", &any_diff, .{ .markdown = true });
    // --- M3 multi-plugin per-plugin layout (pair-a/pair-b) ---
    try exportPerPluginPair(gpa, io, regen, stderr, &any_diff);

    if (any_diff and !regen) {
        try stderr.writeAll("export-schema-demo: at least one golden differs; run with --regen to update\n");
        return 1;
    }
    return 0;
}

/// Extra golden targets a manifest fixture can opt into. Markdown is
/// off by default because it is off by default in the tool too, since it is
/// reachable only through `sjon export-schema --target=markdown`, and is
/// a parity boundary (CLI-only prose, never carried by the envelope).
const FixtureTargets = struct { markdown: bool = false };

/// Parse `manifest_path`, run schema-export against the loaded plugin,
/// then compare (or regenerate) the three golden files at
/// `<base>.schema.json.golden`, `<base>.d.ts.golden`, and
/// `<base>.export.json.golden`, plus `<base>.md.golden` when
/// `targets.markdown`. Reused by every manifest-sourced fixture
/// (double + the M2 set).
fn exportManifestFixture(
    gpa: Allocator,
    io: Io,
    regen: bool,
    stderr: *Io.Writer,
    manifest_path: []const u8,
    base: []const u8,
    any_diff: *bool,
    targets: FixtureTargets,
) !void {
    const src = try readSentinel(gpa, io, manifest_path);
    defer gpa.free(src);

    var tree = try sjon.parse(gpa, src);
    defer tree.deinit();

    var loaded = try sjon.ManifestLoader.load(gpa, tree);
    defer loaded.deinit();
    if (loaded.hasErrors()) {
        try stderr.print("{s}: manifest load failed ({d} diagnostic(s))\n", .{ manifest_path, loaded.diagnostics.len });
        any_diff.* = true;
        return;
    }

    const schema: sjon.Schema.Schema = .{ .plugins = &.{loaded.plugin} };
    var result = try sjon.SchemaExport.exportSchema(gpa, schema, .{
        .target = .{
            .json_schema = true,
            .ts_types = true,
            .intermediate = true,
            .markdown = targets.markdown,
        },
    });
    defer result.deinit();

    var path_buf: [256]u8 = undefined;

    const schema_path = try std.fmt.bufPrint(&path_buf, "{s}.schema.json.golden", .{base});
    try handlePair(gpa, io, regen, stderr, schema_path, result.json_schema_bytes.?, any_diff);

    const ts_path = try std.fmt.bufPrint(&path_buf, "{s}.d.ts.golden", .{base});
    try handlePair(gpa, io, regen, stderr, ts_path, result.ts_types_bytes.?, any_diff);

    const ir_path = try std.fmt.bufPrint(&path_buf, "{s}.export.json.golden", .{base});
    try handlePair(gpa, io, regen, stderr, ir_path, result.intermediate_bytes.?, any_diff);

    if (targets.markdown) {
        const md_path = try std.fmt.bufPrint(&path_buf, "{s}.md.golden", .{base});
        try handlePair(gpa, io, regen, stderr, md_path, result.markdown_bytes.?, any_diff);
    }
}

/// Load `pair-a` + `pair-b` together, run schema-export in per-plugin
/// layout, and diff (or write) the per-plugin goldens. Exercises cross-
/// plugin `$ref` and `import type` resolution. The aggregated goldens
/// are emitted under `pair-aggregate.*` for sanity.
fn exportPerPluginPair(
    gpa: Allocator,
    io: Io,
    regen: bool,
    stderr: *Io.Writer,
    any_diff: *bool,
) !void {
    const src_a = try readSentinel(gpa, io, "examples/plugins/pair-a/plugin.sjon");
    defer gpa.free(src_a);
    const src_b = try readSentinel(gpa, io, "examples/plugins/pair-b/plugin.sjon");
    defer gpa.free(src_b);

    var tree_a = try sjon.parse(gpa, src_a);
    defer tree_a.deinit();
    var tree_b = try sjon.parse(gpa, src_b);
    defer tree_b.deinit();

    var loaded_a = try sjon.ManifestLoader.load(gpa, tree_a);
    defer loaded_a.deinit();
    var loaded_b = try sjon.ManifestLoader.load(gpa, tree_b);
    defer loaded_b.deinit();
    if (loaded_a.hasErrors() or loaded_b.hasErrors()) {
        try stderr.writeAll("pair-a/pair-b: manifest load failed\n");
        any_diff.* = true;
        return;
    }

    const plugins = [_]sjon.Plugin.Plugin{ loaded_a.plugin, loaded_b.plugin };
    const schema: sjon.Schema.Schema = .{ .plugins = &plugins };
    var result = try sjon.SchemaExport.exportSchema(gpa, schema, .{
        .layout = .per_plugin,
        .target = .{ .json_schema = true, .ts_types = true, .intermediate = true },
    });
    defer result.deinit();

    // Per-plugin goldens.
    if (result.per_plugin) |per| {
        var path_buf: [256]u8 = undefined;
        for (per) |art| {
            const schema_path = try std.fmt.bufPrint(&path_buf, "examples/plugins/{s}/{s}.schema.json.golden", .{ art.plugin, art.plugin });
            try handlePair(gpa, io, regen, stderr, schema_path, art.json_schema_bytes.?, any_diff);
            const ts_path = try std.fmt.bufPrint(&path_buf, "examples/plugins/{s}/{s}.d.ts.golden", .{ art.plugin, art.plugin });
            try handlePair(gpa, io, regen, stderr, ts_path, art.ts_types_bytes.?, any_diff);
            const ir_path = try std.fmt.bufPrint(&path_buf, "examples/plugins/{s}/{s}.export.json.golden", .{ art.plugin, art.plugin });
            try handlePair(gpa, io, regen, stderr, ir_path, art.intermediate_bytes.?, any_diff);
        }
    }

    // Aggregated goldens for the pair (single-document view).
    try handlePair(gpa, io, regen, stderr, "examples/plugins/pair-a/pair-aggregate.schema.json.golden", result.json_schema_bytes.?, any_diff);
    try handlePair(gpa, io, regen, stderr, "examples/plugins/pair-a/pair-aggregate.d.ts.golden", result.ts_types_bytes.?, any_diff);
    try handlePair(gpa, io, regen, stderr, "examples/plugins/pair-a/pair-aggregate.export.json.golden", result.intermediate_bytes.?, any_diff);
}

fn readSentinel(gpa: Allocator, io: Io, path: []const u8) ![:0]u8 {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    const buf = try gpa.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf;
}

fn handlePair(
    gpa: Allocator,
    io: Io,
    regen: bool,
    stderr: *Io.Writer,
    path: []const u8,
    bytes: []const u8,
    any_diff: *bool,
) !void {
    if (regen) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
        try stderr.print("wrote {s} ({d} bytes)\n", .{ path, bytes.len });
        return;
    }
    const existing = Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        else => {
            try stderr.print("export-schema-demo: cannot read golden {s}: {s}\n", .{ path, @errorName(err) });
            any_diff.* = true;
            return;
        },
    };
    defer gpa.free(existing);
    if (std.mem.eql(u8, existing, bytes)) return;
    any_diff.* = true;
    try stderr.print(
        "export-schema-demo: golden differs: {s} (expected {d} bytes, got {d} bytes)\n",
        .{ path, existing.len, bytes.len },
    );
    try printFirstDiffLine(stderr, existing, bytes);
}

fn printFirstDiffLine(stderr: *Io.Writer, expected: []const u8, actual: []const u8) !void {
    var line: usize = 1;
    var col: usize = 1;
    const n = @min(expected.len, actual.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (expected[i] != actual[i]) break;
        if (expected[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    try stderr.print("  first diff at line {d} col {d}\n", .{ line, col });
    const ctx: usize = 60;
    const lo: usize = if (i >= ctx) i - ctx else 0;
    const hi_e: usize = @min(expected.len, i + ctx);
    const hi_a: usize = @min(actual.len, i + ctx);
    try stderr.print("  expected: {s}\n", .{expected[lo..hi_e]});
    try stderr.print("  actual:   {s}\n", .{actual[lo..hi_a]});
}
