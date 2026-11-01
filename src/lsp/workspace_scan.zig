//! Workspace enumeration for the native language server.
//!
//! `Handler` is deliberately filesystem-free: it takes `(uri, source)`
//! pairs and knows nothing about where they came from. This module is the
//! other half of that seam — the part that walks a directory tree and
//! reads bytes — kept separate from `main.zig` so the walk's rules
//! (what to skip, when to stop, how a path becomes a URI) are testable
//! without standing up a JSON-RPC server.
//!
//! The walk is iterative. A recursive one would put a directory depth
//! nobody controls onto the host stack, which is the same hazard the
//! parser and validator carry frame stacks to avoid.
//!
//! **No clipping happens here.** Everything found is returned, and
//! `Handler.ingestWorkspaceFilesWithCap` applies the file ceiling after
//! sorting by URI. Clipping during the walk would make the surviving set
//! depend on directory iteration order, which is not stable across
//! filesystems.

const std = @import("std");
const Handler = @import("Handler");
const sjon = @import("sjon");
const uri = @import("uri");

const Allocator = std.mem.Allocator;

/// Ceiling on directory entries one scan will visit. Distinct from
/// `Handler.MAX_WORKSPACE_FILES`, which bounds files *kept*: this bounds
/// the walk itself, so a workspace with a pathological tree cannot make
/// one request run unboundedly even if almost none of its files are
/// `.sjon`. A parameter on `Options` so tests can trip it with a handful
/// of files rather than a hundred thousand.
pub const MAX_SCAN_ENTRIES: usize = 100_000;

/// One workspace pull's shared bounds. A single value spans every
/// initialization root and every per-document schema context: scanning
/// counts directory entries against `max_scan_entries`, and ingestion
/// counts never-open documents against `max_files`. Tests supply smaller
/// values; the shipped defaults match the historical per-surface ceilings.
pub const WorkspaceLimits = struct {
    max_scan_entries: usize = MAX_SCAN_ENTRIES,
    max_files: usize = Handler.MAX_WORKSPACE_FILES,
};

/// A decrementing entry budget shared by the roots of one workspace pull.
/// Keeping the remaining count outside `collect` is what stops N roots
/// from multiplying the entry ceiling by N.
pub const Budget = struct {
    remaining_entries: usize,
    /// True once any root was cut short. Sticky across roots so the
    /// transport warns once for the whole pull.
    stopped_early: bool = false,

    pub fn init(max_entries: usize) Budget {
        return .{ .remaining_entries = max_entries };
    }
};

/// Directory names never descended into. Build outputs and package
/// directories hold generated or vendored `.sjon` files that are not the
/// user's to fix, and reporting diagnostics on them buries the ones that
/// are. Dot-directories are skipped by rule rather than by name.
pub const skipped_dirs = [_][]const u8{ "zig-out", "node_modules", "target", "dist" };

pub const Options = struct {
    max_entries: usize = MAX_SCAN_ENTRIES,
};

/// What one scan found, plus whether it saw the whole tree.
pub const Scan = struct {
    files: []const Handler.WorkspaceFile,
    /// True when the entry ceiling cut the walk short. Reported rather
    /// than logged here so this module stays a pure function of the
    /// filesystem — narrating to the user is the transport's job, and a
    /// module that logs is a module whose tests print noise.
    stopped_early: bool,
};

/// Enumerate `**/*.sjon` under `root`, read fresh from disk.
///
/// The one-root compatibility wrapper: it creates a private entry budget
/// from `options`. A workspace pull with several roots calls
/// `collectWithBudget` with one shared `Budget` instead.
///
/// Unreadable directories and files are skipped rather than fatal: one
/// permission error should not cost the whole workspace its diagnostics.
/// Everything is allocated in `arena`, including the returned slice.
pub fn collect(
    arena: Allocator,
    io: std.Io,
    root: []const u8,
    options: Options,
) Allocator.Error!Scan {
    var budget = Budget.init(options.max_entries);
    return collectWithBudget(arena, io, root, &budget);
}

/// Enumerate `**/*.sjon` under `root`, decrementing `budget` for each
/// directory entry visited. The budget is caller-owned so every root of a
/// multi-root workspace shares one ceiling; when it reaches zero the walk
/// stops at the next entry and reports `stopped_early`.
///
/// Everything is allocated in `arena`, including the returned slice.
pub fn collectWithBudget(
    arena: Allocator,
    io: std.Io,
    root: []const u8,
    budget: *Budget,
) Allocator.Error!Scan {
    var out: std.ArrayList(Handler.WorkspaceFile) = .empty;

    // Explicit queue of absolute directory paths, consumed by index so
    // appends during iteration are safe.
    var queue: std.ArrayList([]const u8) = .empty;
    try queue.append(arena, try arena.dupe(u8, root));

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const dir_path = queue.items[head];
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (budget.remaining_entries == 0) {
                budget.stopped_early = true;
                return .{ .files = try out.toOwnedSlice(arena), .stopped_early = true };
            }
            budget.remaining_entries -= 1;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;

            const child = try std.fs.path.join(arena, &.{ dir_path, entry.name });
            switch (entry.kind) {
                .directory => {
                    for (skipped_dirs) |skip| {
                        if (std.mem.eql(u8, entry.name, skip)) break;
                    } else try queue.append(arena, child);
                },
                .file => {
                    if (!std.mem.endsWith(u8, entry.name, ".sjon")) continue;
                    const source = sjon.CappedRead.readFile(
                        io,
                        child,
                        arena,
                        sjon.CappedRead.MAX_FILE_SIZE,
                    ) catch continue;
                    try out.append(arena, .{
                        .uri = try uri.pathToFileUri(arena, child),
                        .source = source,
                    });
                },
                else => {},
            }
        }
    }
    return .{
        .files = try out.toOwnedSlice(arena),
        .stopped_early = budget.stopped_early,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Does the result contain a file whose URI ends with `suffix`?
fn hasFile(files: []const Handler.WorkspaceFile, suffix: []const u8) bool {
    for (files) |f| {
        if (std.mem.endsWith(u8, f.uri, suffix)) return true;
    }
    return false;
}

test "collect: finds nested .sjon files and ignores other extensions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "top.sjon", .data = "(a)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "ignored" });
    try tmp.dir.createDirPath(io, "nested/deeper");
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/deeper/leaf.sjon", .data = "(b)" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    const scan = try collect(a, io, root, .{});
    const files = scan.files;
    try testing.expect(!scan.stopped_early);
    try testing.expectEqual(@as(usize, 2), files.len);
    try testing.expect(hasFile(files, "/top.sjon"));
    try testing.expect(hasFile(files, "/nested/deeper/leaf.sjon"));

    // Source comes back with the file, so the handler never re-reads.
    for (files) |f| {
        if (std.mem.endsWith(u8, f.uri, "/top.sjon")) {
            try testing.expectEqualStrings("(a)", f.source);
        }
    }
}

test "collect: skips build outputs, package dirs, and dot-directories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "keep.sjon", .data = "(a)" });
    for ([_][]const u8{ "zig-out", "node_modules", "target", "dist", ".git" }) |dir_name| {
        try tmp.dir.createDirPath(io, dir_name);
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/buried.sjon", .{dir_name});
        defer testing.allocator.free(path);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "(b)" });
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    const files = (try collect(a, io, root, .{})).files;
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expect(hasFile(files, "/keep.sjon"));
}

test "collect: a dot-file is skipped but a dotted name is not" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    // The rule is "starts with a dot", not "contains one" — a file
    // called `my.config.sjon` is ordinary and must survive.
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden.sjon", .data = "(a)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "my.config.sjon", .data = "(b)" });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    const files = (try collect(a, io, root, .{})).files;
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expect(hasFile(files, "/my.config.sjon"));
}

test "collect: the entry ceiling stops the walk instead of running unbounded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    for (0..6) |i| {
        const name = try std.fmt.allocPrint(testing.allocator, "f{d}.sjon", .{i});
        defer testing.allocator.free(name);
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "(a)" });
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    // Ceiling below the file count: the walk returns what it had rather
    // than continuing, and reports that it stopped so the transport can
    // say so instead of passing a partial workspace off as a whole one.
    const clipped = try collect(a, io, root, .{ .max_entries = 3 });
    try testing.expect(clipped.files.len < 6);
    try testing.expect(clipped.stopped_early);

    // Same tree, ceiling above the count: everything, and no warning.
    const full = try collect(a, io, root, .{});
    try testing.expectEqual(@as(usize, 6), full.files.len);
    try testing.expect(!full.stopped_early);
}

test "collect: a missing root yields no files rather than an error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const scan = try collect(a, testing.io, ".zig-cache/tmp/definitely-not-here", .{});
    try testing.expectEqual(@as(usize, 0), scan.files.len);
    try testing.expect(!scan.stopped_early);
}

test "workspace contexts: scan entry budget is shared across roots" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.createDirPath(io, "root-a");
    try tmp.dir.createDirPath(io, "root-b");
    for ([_][]const u8{ "a1.sjon", "a2.sjon", "a3.sjon" }) |name| {
        const sub_path = try std.fmt.allocPrint(testing.allocator, "root-a/{s}", .{name});
        defer testing.allocator.free(sub_path);
        try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = "(a)" });
    }
    for ([_][]const u8{ "b1.sjon", "b2.sjon", "b3.sjon" }) |name| {
        const sub_path = try std.fmt.allocPrint(testing.allocator, "root-b/{s}", .{name});
        defer testing.allocator.free(sub_path);
        try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = "(b)" });
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first_root = try std.fmt.allocPrint(
        a,
        ".zig-cache/tmp/{s}/root-a",
        .{&tmp.sub_path},
    );
    const second_root = try std.fmt.allocPrint(
        a,
        ".zig-cache/tmp/{s}/root-b",
        .{&tmp.sub_path},
    );

    // The limits value is the production default and is shared by every
    // root of one workspace pull.
    const limits: WorkspaceLimits = .{};
    try testing.expectEqual(@as(usize, 100_000), limits.max_scan_entries);
    try testing.expectEqual(
        @as(usize, Handler.MAX_WORKSPACE_FILES),
        limits.max_files,
    );

    var budget = Budget.init(4);
    const first = try collectWithBudget(a, io, first_root, &budget);
    const second = try collectWithBudget(a, io, second_root, &budget);

    try testing.expectEqual(@as(usize, 0), budget.remaining_entries);
    try testing.expectEqual(@as(usize, 4), first.files.len + second.files.len);
    try testing.expect(!first.stopped_early);
    try testing.expect(second.stopped_early);
    try testing.expect(budget.stopped_early);
}
