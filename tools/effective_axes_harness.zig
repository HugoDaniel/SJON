const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const sjon = @import("sjon");
const Ast = sjon.Ast;
const Host = sjon.Host;
const Validator = sjon.Validator;

const Mode = enum {
    production,
    axis_a_off,
    axis_b_off,
    axis_c_off,
    axis_d_off,
    all_on,
    all_off,

    fn axes(self: Mode) Validator.EffectiveAxes {
        return switch (self) {
            .production => .{
                .name_index = true,
                .ref_lookup = true,
                .exclusive_group = true,
                .variant = true,
            },
            .axis_a_off => .{
                .name_index = false,
                .ref_lookup = true,
                .exclusive_group = true,
                .variant = true,
            },
            .axis_b_off => .{
                .name_index = true,
                .ref_lookup = false,
                .exclusive_group = true,
                .variant = true,
            },
            .axis_c_off => .{
                .name_index = true,
                .ref_lookup = true,
                .exclusive_group = false,
                .variant = true,
            },
            .axis_d_off => .{
                .name_index = true,
                .ref_lookup = true,
                .exclusive_group = true,
                .variant = false,
            },
            .all_on => .{
                .name_index = true,
                .ref_lookup = true,
                .exclusive_group = true,
                .variant = true,
            },
            .all_off => .{
                .name_index = false,
                .ref_lookup = false,
                .exclusive_group = false,
                .variant = false,
            },
        };
    }

    fn label(self: Mode) []const u8 {
        return switch (self) {
            .production => "production",
            .axis_a_off => "A-off",
            .axis_b_off => "B-off",
            .axis_c_off => "C-off",
            .axis_d_off => "D-off",
            .all_on => "All-on",
            .all_off => "All-off",
        };
    }

    fn fullLabel(self: Mode) []const u8 {
        return switch (self) {
            .production => "production (A+B+C+D on)",
            .axis_a_off => "Axis A off — cross-ref name indexing disabled",
            .axis_b_off => "Axis B off — cross-ref symbol-slot lookup disabled",
            .axis_c_off => "Axis C off — exclusive-group presence disabled",
            .axis_d_off => "Axis D off — variant discriminant disabled",
            .all_on => "All axes on (identical to production)",
            .all_off => "All axes off (cumulative graduation cost)",
        };
    }
};

const Tuple = struct {
    code: Ast.Diagnostic.Code,
    path: []const []const u8,
};

const Diff = struct {
    added: []const Tuple,
    removed: []const Tuple,
    case_changed: bool,
};

const CaseDiffs = struct {
    name: []const u8,
    diffs: [@typeInfo(Mode).@"enum".fields.len]Diff,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const case_names = try discoverCases(a, io);

    var all_diffs: std.ArrayList(CaseDiffs) = .empty;

    for (case_names.items) |name| {
        if (isPluginExecCase(name)) continue;
        const diffs = runCase(gpa, a, io, name) catch |err| {
            std.debug.print("case `{s}` failed: {s}\n", .{ name, @errorName(err) });
            continue;
        };
        try all_diffs.append(a, .{ .name = name, .diffs = diffs });
    }

    try writeReport(a, io, all_diffs.items);
    std.debug.print(
        "wrote tools/effective-axes-snapshot.md ({d} cases scanned)\n",
        .{all_diffs.items.len},
    );
    return 0;
}

fn discoverCases(a: Allocator, io: Io) !std.ArrayList([]const u8) {
    var dir = try Io.Dir.cwd().openDir(io, "conformance/cases", .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        var probe_buf: [std.fs.max_name_bytes + 32]u8 = undefined;
        const schema_probe = std.fmt.bufPrint(&probe_buf, "{s}/schema.sjon", .{entry.name}) catch continue;
        const has_schema = blk: {
            dir.access(io, schema_probe, .{}) catch break :blk false;
            break :blk true;
        };
        var doc_buf: [std.fs.max_name_bytes + 32]u8 = undefined;
        const doc_probe = std.fmt.bufPrint(&doc_buf, "{s}/document.sjon", .{entry.name}) catch continue;
        const has_doc = blk: {
            dir.access(io, doc_probe, .{}) catch break :blk false;
            break :blk true;
        };
        if (!has_schema and !has_doc) continue;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lt);
    return names;
}

fn isPluginExecCase(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "plugin-exec-");
}

fn runCase(
    gpa: Allocator,
    a: Allocator,
    io: Io,
    case_name: []const u8,
) ![@typeInfo(Mode).@"enum".fields.len]Diff {
    const src = try synthesizeCaseSource(a, io, case_name);
    const project_root = try std.fmt.allocPrint(a, "conformance/cases/{s}", .{case_name});
    const project_file_path = try std.fmt.allocPrint(a, "{s}/sjon-project.sjon", .{project_root});
    const has_project_file = blk: {
        Io.Dir.cwd().access(io, project_file_path, .{}) catch break :blk false;
        break :blk true;
    };

    var reference_tuples: []const Tuple = &.{};
    var diffs: [@typeInfo(Mode).@"enum".fields.len]Diff = undefined;
    for (&diffs, 0..) |*slot, i| {
        const mode: Mode = @enumFromInt(i);
        const tuples = try runMode(gpa, a, src, project_root, if (has_project_file) project_file_path else null, io, mode);
        if (mode == .production) {
            reference_tuples = tuples;
            slot.* = .{ .added = &.{}, .removed = &.{}, .case_changed = false };
            continue;
        }
        slot.* = try computeDiff(a, reference_tuples, tuples);
    }
    return diffs;
}

fn synthesizeCaseSource(a: Allocator, io: Io, case_name: []const u8) ![:0]const u8 {
    var path_buf: [256]u8 = undefined;

    const doc_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/document.sjon", .{case_name});
    const has_doc = blk: {
        Io.Dir.cwd().access(io, doc_path, .{}) catch break :blk false;
        break :blk true;
    };
    if (has_doc) {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, doc_path, a, .unlimited);
        const buf = try a.allocSentinel(u8, bytes.len, 0);
        @memcpy(buf, bytes);
        return buf;
    }

    var doc_buf: std.ArrayList(u8) = .empty;

    const schema_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/schema.sjon", .{case_name});
    const schema_bytes = try Io.Dir.cwd().readFileAlloc(io, schema_path, a, .unlimited);
    try doc_buf.appendSlice(a, schema_bytes);
    try doc_buf.append(a, '\n');

    const extras = try listExtras(a, io, case_name);
    for (extras.items) |xname| {
        const xpath = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/{s}", .{ case_name, xname });
        const xbytes = try Io.Dir.cwd().readFileAlloc(io, xpath, a, .unlimited);
        try doc_buf.appendSlice(a, xbytes);
        try doc_buf.append(a, '\n');
    }

    const input_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/input.sjon", .{case_name});
    const input_bytes = try Io.Dir.cwd().readFileAlloc(io, input_path, a, .unlimited);
    try doc_buf.appendSlice(a, input_bytes);

    const buf = try a.allocSentinel(u8, doc_buf.items.len, 0);
    @memcpy(buf, doc_buf.items);
    return buf;
}

fn listExtras(a: Allocator, io: Io, case_name: []const u8) !std.ArrayList([]const u8) {
    var path_buf: [256]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}", .{case_name});
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "extra-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sjon")) continue;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lt);
    return names;
}

fn runMode(
    gpa: Allocator,
    a: Allocator,
    src: [:0]const u8,
    project_root: []const u8,
    project_file: ?[]const u8,
    io: Io,
    mode: Mode,
) ![]const Tuple {
    var hr = try Host.validateDocument(gpa, src, .{
        .project_root = project_root,
        .project_file = project_file,
        .io = io,
        .effective_axes = mode.axes(),
    });
    defer hr.deinit();

    var tuples: std.ArrayList(Tuple) = .empty;
    for (hr.diagnostics) |d| {
        if (d.severity != .err) continue;
        const path = try a.alloc([]const u8, d.path.len);
        for (d.path, 0..) |step, i| path[i] = try a.dupe(u8, step);
        try tuples.append(a, .{ .code = d.code, .path = path });
    }
    std.mem.sort(Tuple, tuples.items, {}, tupleLessThan);
    return tuples.items;
}

fn tupleLessThan(_: void, lhs: Tuple, rhs: Tuple) bool {
    const lhs_code = @tagName(lhs.code);
    const rhs_code = @tagName(rhs.code);
    if (!std.mem.eql(u8, lhs_code, rhs_code)) {
        return std.mem.lessThan(u8, lhs_code, rhs_code);
    }
    const n = @min(lhs.path.len, rhs.path.len);
    for (0..n) |i| {
        if (!std.mem.eql(u8, lhs.path[i], rhs.path[i])) {
            return std.mem.lessThan(u8, lhs.path[i], rhs.path[i]);
        }
    }
    return lhs.path.len < rhs.path.len;
}

fn tupleEqual(lhs: Tuple, rhs: Tuple) bool {
    if (lhs.code != rhs.code) return false;
    if (lhs.path.len != rhs.path.len) return false;
    for (lhs.path, rhs.path) |sl, sr| {
        if (!std.mem.eql(u8, sl, sr)) return false;
    }
    return true;
}

fn computeDiff(a: Allocator, baseline: []const Tuple, candidate: []const Tuple) !Diff {
    var added: std.ArrayList(Tuple) = .empty;
    var removed: std.ArrayList(Tuple) = .empty;

    for (candidate) |c| {
        var found = false;
        for (baseline) |b| if (tupleEqual(c, b)) {
            found = true;
            break;
        };
        if (!found) try added.append(a, c);
    }
    for (baseline) |b| {
        var found = false;
        for (candidate) |c| if (tupleEqual(b, c)) {
            found = true;
            break;
        };
        if (!found) try removed.append(a, b);
    }
    return .{
        .added = added.items,
        .removed = removed.items,
        .case_changed = added.items.len > 0 or removed.items.len > 0,
    };
}

fn writeReport(a: Allocator, io: Io, all_diffs: []const CaseDiffs) !void {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll(
        \\# Effective Validation — Corpus Impact Snapshot
        \\
        \\Generated by `zig build effective-axes-harness`. Each row counts
        \\cases in `conformance/cases/` whose diagnostic-stream differs
        \\from the production reference (axes A + B + C + D all on) when
        \\the named axis is toggled off. Re-run the harness to refresh
        \\the snapshot.
        \\
        \\The `A-off`/`B-off`/`C-off`/`D-off` rows each disable a single
        \\axis (rest stay on) — they measure that axis's corpus
        \\contribution to production. The `All-on` row is identical to
        \\production by construction (kept for symmetry / regression
        \\catch). The `All-off` row diffs production against every axis
        \\flag forced off — it enumerates the cumulative corpus impact
        \\of the full A+B+C+D graduation.
        \\
        \\Diagnostic comparison: error-severity only, reduced to sorted
        \\`(code, path)` tuples. Plugin-exec cases (`plugin-exec-*`) are
        \\skipped — Zig-native cannot run sidecar `.wasm` plugins.
        \\
        \\## Summary
        \\
        \\| Mode | Cases changed | Added diagnostics | Removed diagnostics |
        \\| ---- | ------------- | ----------------- | ------------------- |
        \\
    );
    const modes = [_]Mode{ .axis_a_off, .axis_b_off, .axis_c_off, .axis_d_off, .all_on, .all_off };
    for (modes) |mode| {
        var changed: usize = 0;
        var added_total: usize = 0;
        var removed_total: usize = 0;
        for (all_diffs) |cd| {
            const d = cd.diffs[@intFromEnum(mode)];
            if (d.case_changed) changed += 1;
            added_total += d.added.len;
            removed_total += d.removed.len;
        }
        try w.print("| {s} | {d} | {d} | {d} |\n", .{ mode.label(), changed, added_total, removed_total });
    }
    try w.writeAll("\n");

    for (modes) |mode| {
        try w.print("## {s}\n\n", .{mode.fullLabel()});
        var any_added = false;
        var any_removed = false;
        for (all_diffs) |cd| {
            const d = cd.diffs[@intFromEnum(mode)];
            if (d.added.len > 0) any_added = true;
            if (d.removed.len > 0) any_removed = true;
        }

        if (!any_added and !any_removed) {
            try w.writeAll("No corpus-visible change.\n\n");
            continue;
        }

        if (any_added) {
            try w.writeAll("### Cases gaining diagnostics\n\n");
            for (all_diffs) |cd| {
                const d = cd.diffs[@intFromEnum(mode)];
                if (d.added.len == 0) continue;
                try w.print("- `{s}`:\n", .{cd.name});
                for (d.added) |t| {
                    try w.writeAll("    - `+ ");
                    try w.writeAll(@tagName(t.code));
                    try w.writeAll("` at ");
                    try writePath(w, t.path);
                    try w.writeAll("\n");
                }
            }
            try w.writeAll("\n");
        }

        if (any_removed) {
            try w.writeAll("### Cases losing diagnostics\n\n");
            for (all_diffs) |cd| {
                const d = cd.diffs[@intFromEnum(mode)];
                if (d.removed.len == 0) continue;
                try w.print("- `{s}`:\n", .{cd.name});
                for (d.removed) |t| {
                    try w.writeAll("    - `- ");
                    try w.writeAll(@tagName(t.code));
                    try w.writeAll("` at ");
                    try writePath(w, t.path);
                    try w.writeAll("\n");
                }
            }
            try w.writeAll("\n");
        }
    }

    try w.writeAll(
        \\## Axis E
        \\
        \\No call site exists in the current codebase (host-lowering hooks
        \\are spec-only). Skipped — hooks should read the effective view
        \\by default once the runtime lands.
        \\
        \\## Notes
        \\
        \\Default-driven diagnostics use the synthetic path
        \\`[<form-head>, <key>, "default"]` (matching the existing
        \\`default_eval_failed` path shape). The one exception is
        \\`duplicate_cross_ref_target`, which surfaces on the duplicate
        \\form's name-value span and carries an empty path — that
        \\diagnostic always was span-based and the axis-A default-driven
        \\path reuses the same emitter. If a corpus result suggests a
        \\different convention would read better, the change is one line
        \\in `Validator.checkEffectiveRefLookups` / `registerCrossRefInstance`.
        \\
    );

    try writeAllFile(io, "tools/effective-axes-snapshot.md", out.written());
}

fn writePath(w: *std.Io.Writer, path: []const []const u8) !void {
    try w.writeAll("`[");
    for (path, 0..) |s, i| {
        if (i > 0) try w.writeAll(" ");
        try w.writeAll(s);
    }
    try w.writeAll("]`");
}

fn writeAllFile(io: Io, path: []const u8, bytes: []const u8) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(io, &write_buf);
    try fw.interface.writeAll(bytes);
    try fw.interface.flush();
}
