//! Generator for `landing-page/src/data/errors.json` — the diagnostic
//! catalogue the landing page renders one page per code from.
//!
//! `src/Explanations.zig` is the single source of truth for a code's prose;
//! it already backs `sjon explain CODE` and (since 03/CP3) LSP hover. The
//! landing page is the third consumer, and the only one that can't `@import`
//! Zig — hence this emitter rather than a hand-kept copy. `codeDescription`
//! (03/CP4 half 2) points editors at those pages, so a code without a page
//! is a dead link in every LSP client: the drift gate below is what keeps
//! the two in step.
//!
//! Entries are emitted in **enum declaration order**, not the order the
//! `Explanations` table happens to be authored in. That order is the
//! wire-stable one (`Ast.Diagnostic.Code` is append-only), so a new code
//! lands at the end of the file and the diff shows exactly one added block.
//! Walking the enum also makes this a second completeness check: a code with
//! no entry aborts the emit rather than silently omitting a page.
//!
//! Run modes (mirrors `tools/gen_meta_schema.zig`):
//!   - default: re-derive the bytes and compare against what's committed.
//!     Exit 1 on drift or a missing file. `zig build test` invokes this, so
//!     editing an explanation without regenerating fails the build (there is
//!     no CI).
//!   - `--regen`: write the file so a human can review the diff and commit.
//!
//! The output is biome-ignored (`biome.json`) for the same reason
//! `hosts/schema/src/expr.gen.ts` is: the emitter owns the bytes, and a
//! formatter rewriting them would fail the drift gate on a clean tree.

const std = @import("std");
const sjon = @import("sjon");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const OUT_PATH = "landing-page/src/data/errors.json";

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

    const want = try render(gpa, stderr);
    defer gpa.free(want);

    if (regen) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = OUT_PATH, .data = want });
        try stderr.print("gen-explanations: wrote {s} ({d} bytes)\n", .{ OUT_PATH, want.len });
        return 0;
    }

    const have = Io.Dir.cwd().readFileAlloc(io, OUT_PATH, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.print(
                "gen-explanations: {s} is missing — run `zig build gen-explanations -- --regen`\n",
                .{OUT_PATH},
            );
            return 1;
        },
        else => return err,
    };
    defer gpa.free(have);

    if (!std.mem.eql(u8, have, want)) {
        try stderr.print(
            "gen-explanations: {s} is stale (have {d} bytes, want {d}) — run `zig build gen-explanations -- --regen` and commit\n",
            .{ OUT_PATH, have.len, want.len },
        );
        return 1;
    }

    try stderr.print("gen-explanations: {s} verified\n", .{OUT_PATH});
    return 0;
}

/// Render the catalogue: a JSON array of `{code, short, long}`, one code per
/// entry in `Ast.Diagnostic.Code` declaration order, trailing newline.
/// Returns owned bytes (caller frees).
fn render(gpa: Allocator, stderr: *Io.Writer) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "[\n");

    const fields = @typeInfo(sjon.Ast.Diagnostic.Code).@"enum".fields;
    inline for (fields, 0..) |f, i| {
        // `Explanations` has its own completeness test, so a null here means
        // that test was skipped or the two drifted — either way, emitting a
        // catalogue with a hole would ship a 404 from every editor.
        const entry = sjon.Explanations.lookup(f.name) orelse {
            try stderr.print("gen-explanations: no explanation for `{s}`\n", .{f.name});
            return error.MissingExplanation;
        };

        try buf.appendSlice(gpa, "  {\n    \"code\": ");
        try sjon.wasm_common.appendJsonString(&buf, gpa, f.name);
        try buf.appendSlice(gpa, ",\n    \"short\": ");
        try sjon.wasm_common.appendJsonString(&buf, gpa, entry.short);
        try buf.appendSlice(gpa, ",\n    \"long\": ");
        try sjon.wasm_common.appendJsonString(&buf, gpa, entry.long);
        try buf.appendSlice(gpa, "\n  }");
        if (i + 1 < fields.len) try buf.append(gpa, ',');
        try buf.append(gpa, '\n');
    }

    try buf.appendSlice(gpa, "]\n");
    return buf.toOwnedSlice(gpa);
}
