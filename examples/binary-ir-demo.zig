//! End-to-end demo of the SJON Binary IR (v0.2).
//!
//! Walks a compact scene through every binary entry point:
//!   parse text  →  sjon.toBinary  →  bytes
//!   bytes       →  sjon.fromBinary →  Ast.Tree (SoA, self-contained)
//!   bytes       →  BinaryCursor    →  zero-allocation walk
//!   Tree        →  sjon.print      →  canonical text
//!
//! Run with `zig build demo-binary`. Wired into `zig build test` so the
//! demo can't bit-rot — any wire-format drift trips here in CI.
//!
//! Exits 0 on success; non-zero with a Zig stack trace on any divergence.

const std = @import("std");
const sjon = @import("sjon");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src: [:0]const u8 = "(scene :bpm 130 (canvas :name \"main\" [1 2 3]))";
    var tree = try sjon.parse(a, src);
    defer tree.deinit();

    // Encode under both presets to exercise the flag-gating.
    const bin_lossless = try sjon.toBinary(a, tree, sjon.Binary.ToBinaryOptions.forMode(.full));
    defer bin_lossless.deinit();
    const bin_stripped = try sjon.toBinary(a, tree, sjon.Binary.ToBinaryOptions.forMode(.compact));
    defer bin_stripped.deinit();

    // Decode and confirm canonical text matches the direct print — the
    // binary path must reach the same canonical layout.
    var rebuilt = try sjon.fromBinary(a, bin_lossless.data, .{});
    defer rebuilt.deinit();

    const direct_text = try sjon.print(a, tree, .{});
    defer direct_text.deinit();
    const round_trip_text = try sjon.print(a, rebuilt, .{});
    defer round_trip_text.deinit();
    if (!std.mem.eql(u8, direct_text.data, round_trip_text.data)) return error.RoundTripDivergence;

    // Walk the stripped binary via the zero-allocation cursor and confirm
    // the visited node count matches the source tree's root count.
    var cursor = try sjon.BinaryCursor.Cursor.init(bin_stripped.data);
    var iter = try cursor.rootIter();
    var node_count: u32 = 0;
    while (try iter.next()) |view| {
        node_count += 1;
        try sjon.BinaryCursor.skipBody(&cursor, view);
    }
    if (node_count != tree.root.len) return error.NodeCountMismatch;
}
