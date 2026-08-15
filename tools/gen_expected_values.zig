//! Generator for the `conformance/cases/<case>/expected.values.json`
//! sibling files.
//!
//! A value-carrying fixture's `expected.sjon` holds a human-readable
//! `(values (value :index N :result <lit>))` block. This tool turns each
//! block into a machine-readable JSON sibling so the Web and Rust hosts can
//! compare evaluated results through their ONE stock JSON parser instead of
//! each re-implementing a literal→JSON decoder (the A.1 duplication).
//!
//! The sibling's value tokens are produced by `wasm_common.appendValue` —
//! the SAME encoder the WASM envelope uses for `evaluated_results`. So the
//! host compares appendValue(fixture-literal) against appendValue(runtime-
//! value): byte-identical whenever the two values are structurally equal,
//! which is exactly what the corpus already guarantees. The Zig conformance
//! runner keeps its native `Expr.Value.equals` check (this generator is
//! DERIVED from that decoder, so a runner comparing generated JSON would
//! self-certify generator bugs — the native leg is the independent check).
//!
//! Run modes (mirrors `tools/gen_meta_schema.zig`):
//!   - default: for every case, (re)derive the expected sibling bytes and
//!     compare against what's committed. Exit 1 on ANY drift — a stale
//!     sibling, a case that gained a `(values …)` block but has no sibling,
//!     or a sibling left behind after a `(values …)` block was removed.
//!     `zig build test` invokes this, so editing a fixture's values without
//!     regenerating fails the build (there is no CI).
//!   - `--regen`: write each sibling and delete any orphaned one, so a human
//!     can review the diff and re-commit. Run after an intentional edit.

const std = @import("std");
const sjon = @import("sjon");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const CASES_DIR = "conformance/cases";
const EXPECTED_NAME = "expected.sjon";
const SIBLING_NAME = "expected.values.json";

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

    var names = try discoverCaseDirs(gpa, io);
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }

    var verified: usize = 0;
    var wrote: usize = 0;
    var drift: usize = 0;

    var path_buf: [std.fs.max_name_bytes + 64]u8 = undefined;

    for (names.items) |name| {
        // --- parse the case's expected.sjon (skip a dir without one) ---
        const expected_path = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{ CASES_DIR, name, EXPECTED_NAME }) catch continue;
        const src = readSentinel(gpa, io, expected_path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer gpa.free(src);

        var tree = try sjon.parse(gpa, src);
        defer tree.deinit();
        if (tree.hasErrors()) {
            try stderr.print("gen-expected-values: {s}/{s} has parse errors\n", .{ name, EXPECTED_NAME });
            drift += 1;
            continue;
        }

        // Per-case arena for the duped value strings.
        var case_arena = std.heap.ArenaAllocator.init(gpa);
        defer case_arena.deinit();
        var values = sjon.ConformanceExpected.parseExpectedValues(case_arena.allocator(), &tree) catch |err| {
            try stderr.print("gen-expected-values: {s} malformed (values …) block: {s}\n", .{ name, @errorName(err) });
            drift += 1;
            continue;
        };
        defer values.deinit(case_arena.allocator());

        const sibling_path = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{ CASES_DIR, name, SIBLING_NAME }) catch continue;

        if (values.items.len == 0) {
            // No values block → there must be no sibling. Delete an orphan
            // (regen) or flag it (verify).
            if (regen) {
                Io.Dir.cwd().deleteFile(io, sibling_path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
                // Re-probe to report only genuine deletions.
                continue;
            }
            const orphan = blk: {
                Io.Dir.cwd().access(io, sibling_path, .{}) catch break :blk false;
                break :blk true;
            };
            if (orphan) {
                try stderr.print(
                    "gen-expected-values: {s}/{s} exists but the fixture has no (values …) block — stale; run `zig build gen-expected-values -- --regen`\n",
                    .{ name, SIBLING_NAME },
                );
                drift += 1;
            }
            continue;
        }

        // Values block present → derive the sibling bytes.
        const want = try renderSibling(gpa, values.items);
        defer gpa.free(want);

        if (regen) {
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = sibling_path, .data = want });
            wrote += 1;
            continue;
        }

        const have = Io.Dir.cwd().readFileAlloc(io, sibling_path, gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => {
                try stderr.print(
                    "gen-expected-values: {s}/{s} is missing (fixture carries a (values …) block) — run `zig build gen-expected-values -- --regen`\n",
                    .{ name, SIBLING_NAME },
                );
                drift += 1;
                continue;
            },
            else => return err,
        };
        defer gpa.free(have);

        if (std.mem.eql(u8, have, want)) {
            verified += 1;
        } else {
            try stderr.print(
                "gen-expected-values: {s}/{s} is stale (have {d} bytes, want {d}) — run `zig build gen-expected-values -- --regen` and commit\n",
                .{ name, SIBLING_NAME, have.len, want.len },
            );
            drift += 1;
        }
    }

    if (regen) {
        try stderr.print("gen-expected-values: wrote {d}, deleted orphans as needed\n", .{wrote});
        return 0;
    }
    if (drift != 0) {
        try stderr.print("gen-expected-values: {d} sibling(s) drifted — see above\n", .{drift});
        return 1;
    }
    try stderr.print("gen-expected-values: {d} sibling(s) verified\n", .{verified});
    return 0;
}

/// Render one case's value block as its `expected.values.json` sibling: a
/// top-level object keyed by decimal forest index (ascending), each value
/// encoded verbatim by `wasm_common.appendValue` — the envelope encoder —
/// one entry per line, trailing newline. Returns owned bytes (caller frees).
fn renderSibling(gpa: Allocator, values: []const sjon.ConformanceExpected.ExpectedValue) ![]u8 {
    // Sort a local copy by forest index so the file order is deterministic
    // regardless of the block's authored order.
    const sorted = try gpa.dupe(sjon.ConformanceExpected.ExpectedValue, values);
    defer gpa.free(sorted);
    std.mem.sort(sjon.ConformanceExpected.ExpectedValue, sorted, {}, struct {
        fn lt(_: void, a: sjon.ConformanceExpected.ExpectedValue, b: sjon.ConformanceExpected.ExpectedValue) bool {
            return a.forest_index < b.forest_index;
        }
    }.lt);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "{\n");
    for (sorted, 0..) |ev, i| {
        var key_buf: [24]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{d}", .{ev.forest_index}) catch unreachable;
        try buf.appendSlice(gpa, "  \"");
        try buf.appendSlice(gpa, key);
        try buf.appendSlice(gpa, "\": ");
        try sjon.wasm_common.appendValue(&buf, gpa, ev.value);
        if (i + 1 < sorted.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }
    try buf.appendSlice(gpa, "}\n");
    return buf.toOwnedSlice(gpa);
}

fn readSentinel(gpa: Allocator, io: Io, path: []const u8) ![:0]u8 {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    const buf = try gpa.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf;
}

/// Case directories under `conformance/cases`, sorted, hidden dirs skipped
/// (the gitignored `.zig-cache`). Mirrors the runner's `discoverCases`.
fn discoverCaseDirs(gpa: Allocator, io: Io) !std.ArrayList([]u8) {
    var dir = try Io.Dir.cwd().openDir(io, CASES_DIR, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.startsWith(u8, entry.name, ".")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }

    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lt);

    return names;
}
