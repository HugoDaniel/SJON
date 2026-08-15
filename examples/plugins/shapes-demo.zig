//! End-to-end demo: parse → validate → print → encode → cursor walk → decode → re-print.
//!
//! Run with `zig build shapes-demo`. The same code path runs as a unit
//! test (`shapes-demo: end-to-end on examples/plugins/shapes-scene.sjon`)
//! under `zig build test`, so it can't drift from the SJON public API
//! without a CI failure.

const std = @import("std");
const sjon = @import("sjon");
const shapes = @import("shapes.zig");

const print = std.debug.print;

/// The sample scene is baked in at compile time so the demo and the
/// regression test see byte-identical input. `@embedFile` returns
/// `*const [N:0]u8`; coerced here to a sentinel-terminated slice that
/// `sjon.parse` can consume directly.
const scene_src: [:0]const u8 = @embedFile("shapes-scene.sjon");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // ----- 1. Parse ---------------------------------------------------------
    var tree = try sjon.parse(gpa, scene_src);
    defer tree.deinit();
    if (tree.hasErrors()) {
        print("parse failed: {} diagnostics\n", .{tree.diagnostics.len});
        for (tree.diagnostics) |d| print("  [{}-{}] {s}\n", .{ d.span.start, d.span.end, d.message });
        return error.ParseFailed;
    }
    print("parsed {} root form(s)\n", .{tree.root.len});

    // ----- 2. Validate against `core + shapes` ------------------------------
    const schema = sjon.Schema.Schema.init(&.{ sjon.plugins.core.plugin, shapes.plugin });
    var vresult = try sjon.validate(gpa, tree, schema);
    defer vresult.deinit();
    print("validator: {} diagnostic(s)\n", .{vresult.diagnostics.len});
    for (vresult.diagnostics) |d| {
        print("  [{}-{}] {s}\n", .{ d.span.start, d.span.end, d.message });
    }
    if (vresult.hasErrors()) return error.ValidationFailed;

    // ----- 3. Print canonical -----------------------------------------------
    const canonical = try sjon.print(gpa, tree, .{ .mode = .canonical });
    defer canonical.deinit();
    print("\n--- canonical ({} bytes) ---\n{s}\n", .{ canonical.data.len, canonical.data });

    // ----- 4. Encode binary IR ---------------------------------------------
    const bin_stripped = try sjon.toBinary(gpa, tree, sjon.Binary.ToBinaryOptions.forMode(.compact));
    defer bin_stripped.deinit();
    const bin_lossless = try sjon.toBinary(gpa, tree, sjon.Binary.ToBinaryOptions.forMode(.full));
    defer bin_lossless.deinit();
    print(
        "\nbinary: stripped={} bytes, lossless={} bytes, source={} bytes\n",
        .{ bin_stripped.data.len, bin_lossless.data.len, scene_src.len },
    );

    // ----- 5. Walk the binary via the zero-allocation cursor ----------------
    var counts = ShapeCounts{};
    try countShapesViaCursor(bin_stripped.data, &counts);
    print(
        "cursor walk: {} canvas / {} circle / {} rect / {} group\n",
        .{ counts.canvas, counts.circle, counts.rect, counts.group },
    );

    // ----- 6. Decode + re-print + parity check ------------------------------
    var rebuilt = try sjon.fromBinary(gpa, bin_stripped.data, .{});
    defer rebuilt.deinit();

    const reprinted = try sjon.print(gpa, rebuilt, .{ .mode = .canonical });
    defer reprinted.deinit();

    if (!std.mem.eql(u8, canonical.data, reprinted.data)) {
        print("PARITY FAILURE: decoded canonical print differs from original\n", .{});
        return error.ParityFailed;
    }
    print("\nbinary round-trip parity: OK\n", .{});
}

// ---------------------------------------------------------------------------
// Cursor walk
// ---------------------------------------------------------------------------

const ShapeCounts = struct {
    canvas: u32 = 0,
    circle: u32 = 0,
    rect: u32 = 0,
    group: u32 = 0,
};

fn countShapesViaCursor(bytes: []const u8, counts: *ShapeCounts) !void {
    var cursor = try sjon.BinaryCursor.Cursor.init(bytes);
    var roots = try cursor.rootIter();
    while (try roots.next()) |view| {
        try walkView(&cursor, view, counts);
    }
}

fn walkView(cursor: *sjon.BinaryCursor.Cursor, view: sjon.BinaryCursor.NodeView, counts: *ShapeCounts) !void {
    switch (view.kind) {
        .form => {
            var fv = try sjon.BinaryCursor.readForm(cursor, view);
            if (std.mem.eql(u8, fv.head, "canvas")) counts.canvas += 1 else if (std.mem.eql(u8, fv.head, "circle")) counts.circle += 1 else if (std.mem.eql(u8, fv.head, "rect")) counts.rect += 1 else if (std.mem.eql(u8, fv.head, "group")) counts.group += 1;
            while (try fv.children.next()) |child| {
                try walkView(cursor, child.value, counts);
            }
        },
        .vector => {
            var vv = try sjon.BinaryCursor.readVector(cursor, view);
            while (try vv.next()) |elem| try walkView(cursor, elem, counts);
        },
        else => try sjon.BinaryCursor.skipBody(cursor, view),
    }
}

// ---------------------------------------------------------------------------
// Tests — same code path as `main`, runs under `zig build test`.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "shapes-demo: end-to-end on examples/plugins/shapes-scene.sjon" {
    const a = testing.allocator;

    var tree = try sjon.parse(a, scene_src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());

    const schema = sjon.Schema.Schema.init(&.{ sjon.plugins.core.plugin, shapes.plugin });
    var v = try sjon.validate(a, tree, schema);
    defer v.deinit();
    try testing.expectEqual(@as(usize, 0), v.diagnostics.len);

    const bin = try sjon.toBinary(a, tree, sjon.Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();

    var counts = ShapeCounts{};
    try countShapesViaCursor(bin.data, &counts);
    try testing.expectEqual(@as(u32, 1), counts.canvas);
    try testing.expectEqual(@as(u32, 3), counts.circle);
    try testing.expectEqual(@as(u32, 4), counts.rect);
    try testing.expectEqual(@as(u32, 1), counts.group);

    var rebuilt = try sjon.fromBinary(a, bin.data, .{});
    defer rebuilt.deinit();

    const orig = try sjon.print(a, tree, .{ .mode = .canonical });
    defer orig.deinit();
    const after = try sjon.print(a, rebuilt, .{ .mode = .canonical });
    defer after.deinit();
    try testing.expectEqualStrings(orig.data, after.data);
}
