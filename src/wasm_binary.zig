//! Read-only WASM artifact — consumer of Binary IR.
//!
//! Imports only the subset of SJON needed to decode and walk binary
//! trees: Ast, Schema, Plugin, Validator, Expr, BinaryCursor, Pattern,
//! PatternQuery, the built-in `core` + `pattern` plugins, and the shared
//! wasm_common helpers.
//!
//! Deliberately does NOT import root.zig (which would pull Parser,
//! Printer, Json, Edit), Json.zig, or Edit.zig. That keeps the artifact
//! free of `std.json` and `std.fmt`-float-via-Printer cost. PatternQuery
//! and its deps (Pattern, BinaryCursor, Schema) honor the same boundary —
//! it reads binary only through BinaryCursor and hand-rolls its `(haps …)`
//! text, never touching Printer / the write-side Binary encoder.
//!
//! Exports: `sjon_alloc`, `sjon_free`, `sjon_describe`,
//! `sjon_validate_binary`, `sjon_eval_expr_binary`,
//! `sjon_query_pattern_binary`. Same framing as the kitchen-sink
//! `sjon.wasm` artifact.

const std = @import("std");
const Ast = @import("Ast.zig");
const Schema = @import("Schema.zig");
const Plugin = @import("Plugin.zig");
const BinaryCursor = @import("BinaryCursor.zig");
const Pattern = @import("Pattern.zig");
const PatternQuery = @import("PatternQuery.zig");
const core = @import("plugins/core.zig");
const pattern = @import("plugins/pattern.zig");
const common = @import("wasm_common.zig");
const version = @import("version.zig").string;

const wasm_allocator = std.heap.wasm_allocator;
const core_schema = common.core_schema;
const pattern_schema: Schema.Schema = Schema.Schema.init(&.{ core.plugin, pattern.plugin });

// ---------------------------------------------------------------------------
// Allocation helpers — the JS input/output memory bridge. `sjon_alloc` /
// `sjon_free` live in the shared `wasm_common` leaf (identical in the
// kitchen-sink artifact); force-reference them so the exports land here.
// ---------------------------------------------------------------------------

comptime {
    _ = common.sjon_alloc;
    _ = common.sjon_free;
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

export fn sjon_describe() callconv(.c) ?[*]u8 {
    const text =
        \\{"name":"sjon-binary","version":"
    ++ version ++
        \\","exports":["validate_binary","eval_expr_binary","query_pattern_binary","describe"],"plugins":["core","pattern"]}
    ;
    return common.frame(wasm_allocator, true, text) catch null;
}

export fn sjon_validate_binary(bin_ptr: [*]const u8, bin_len: u32) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, common.runValidateBinary(wasm_allocator, bin_ptr[0..bin_len], core_schema));
}

export fn sjon_eval_expr_binary(bin_ptr: [*]const u8, bin_len: u32) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, common.runEvalExprBinary(wasm_allocator, bin_ptr[0..bin_len], core_schema));
}

/// Query a binary-IR pattern over `[begin, end)` ticks with RNG `seed`,
/// returning framed `(haps …)` text (or `(diagnostics …)`). i64 args ↔ JS
/// BigInt. Decodes via BinaryCursor only — no parser, no write-side Binary.
export fn sjon_query_pattern_binary(
    bin_ptr: [*]const u8,
    bin_len: u32,
    begin: i64,
    end: i64,
    seed: i64,
) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runQueryPatternBinary(bin_ptr[0..bin_len], begin, end, seed));
}

// ---------------------------------------------------------------------------
// Operation bodies
// ---------------------------------------------------------------------------

fn runQueryPatternBinary(bin_bytes: []const u8, begin: i64, end: i64, seed: i64) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (begin > end) return error.InvalidWindow;
    var result = try PatternQuery.queryBinary(wasm_allocator, bin_bytes, pattern_schema, .{ .begin = begin, .end = end }, seed);
    defer result.deinit();

    const text = try PatternQuery.resultToText(a, result);
    return try common.frame(wasm_allocator, true, text);
}

// ---------------------------------------------------------------------------
// Comptime: keep the BinaryCursor and Plugin / Ast namespaces visible to
// downstream native consumers that link against this artifact's source as
// a library (DCE still strips uncalled functions from the WASM binary).
// ---------------------------------------------------------------------------

comptime {
    _ = Ast;
    _ = Plugin;
    _ = BinaryCursor;
    _ = Pattern;
    _ = PatternQuery;
}
