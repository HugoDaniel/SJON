//! Watched-set fingerprint core for `sjon check --watch` (devx plan 04).
//!
//! Polling, not platform watchers: Zig 0.16 std ships no portable
//! filesystem watcher, and kqueue/inotify backends are out of scope. An
//! mtime+size fingerprint over the project's `**/*.sjon` is simple,
//! portable, and deterministic to test; the trade is one poll interval
//! of latency.
//!
//! The walk mirrors `src/lsp/workspace_scan.zig` (iterative queue —
//! never host-stack recursion over a depth nobody controls — dot-dirs
//! skipped by rule, the same named skip-list) rather than importing it:
//! that module imports `Handler`, which the CLI must not pull in. This
//! module is pure scan → fingerprint map → diff, so it tests in-process
//! against tmp dirs; the loop that consumes it is verb code in
//! `Cli.zig`, written against the "changed → rerun this closure" seam
//! so later verbs can reuse it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{OutOfMemory};

/// Directory names never descended into — same list (and rationale) as
/// `workspace_scan.skipped_dirs`: build outputs and vendored packages
/// hold `.sjon` files that are not the user's to fix.
pub const skipped_dirs = [_][]const u8{ "zig-out", "node_modules", "target", "dist" };

/// Ceiling on directory entries one scan visits, so a pathological tree
/// cannot make a poll tick run unboundedly.
pub const MAX_SCAN_ENTRIES: usize = 100_000;

/// A parameter (as in `workspace_scan.Options`) so tests can trip the
/// ceiling with a handful of files rather than a hundred thousand.
pub const Options = struct {
    max_entries: usize = MAX_SCAN_ENTRIES,
};

/// One file's change fingerprint. Content is deliberately not read —
/// a poll tick over a big project must stay cheap; mtime+size is the
/// classic trade (an editor that rewrites identical bytes re-triggers,
/// which is harmless — the re-run is idempotent).
pub const Fingerprint = struct {
    mtime_ns: i96,
    size: u64,

    fn eql(a: Fingerprint, b: Fingerprint) bool {
        return a.mtime_ns == b.mtime_ns and a.size == b.size;
    }
};

/// One scan's path → fingerprint map. Owns everything via `deinit`.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(Fingerprint),
    /// True when the entry ceiling cut the walk short. Reported rather
    /// than swallowed for the same reason `workspace_scan` reports it:
    /// which entries survive a clipped walk depends on directory
    /// iteration order, so diffing two clipped snapshots can report
    /// phantom changes — the consumer should say the set is partial.
    stopped_early: bool,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }

    pub fn count(self: *const Snapshot) usize {
        return self.map.count();
    }
};

/// Fingerprint every `.sjon` under `root`. Unreadable directories and
/// files are skipped rather than fatal — one permission error must not
/// kill the watch loop — but a skip that narrows the snapshot sets
/// `stopped_early`, because a narrower snapshot is indistinguishable
/// from "those files were deleted" on the next `diff`.
pub fn scan(gpa: Allocator, io: Io, root: []const u8, options: Options) Error!Snapshot {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var map: std.StringHashMapUnmanaged(Fingerprint) = .empty;

    var queue: std.ArrayList([]const u8) = .empty;
    try queue.append(a, try a.dupe(u8, root));

    var visited: usize = 0;
    var head: usize = 0;
    // Set by any skip that silently drops files from the snapshot. Until
    // now only the `max_entries` cap raised it, so a directory that
    // became unreadable — or an iterate that failed mid-directory —
    // shrank the set with the flag still reading "complete", and the next
    // `diff` reported its files as removed.
    var clipped = false;
    while (head < queue.items.len) : (head += 1) {
        const dir_path = queue.items[head];
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
            clipped = true;
            continue;
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (true) {
            const maybe_entry = it.next(io) catch {
                clipped = true;
                break;
            };
            const entry = maybe_entry orelse break;
            visited += 1;
            if (visited > options.max_entries) {
                return .{ .arena = arena, .map = map, .stopped_early = true };
            }
            if (entry.name.len == 0 or entry.name[0] == '.') continue;

            const child = try std.fs.path.join(a, &.{ dir_path, entry.name });
            switch (entry.kind) {
                .directory => {
                    for (skipped_dirs) |skip| {
                        if (std.mem.eql(u8, entry.name, skip)) break;
                    } else try queue.append(a, child);
                },
                .file => {
                    if (!std.mem.endsWith(u8, entry.name, ".sjon")) continue;
                    // Deliberately does NOT set `clipped`: a file that
                    // vanishes between iterate and stat is ordinary churn
                    // (editors write and rename temp files), and raising
                    // the partial-set flag on every save would make it
                    // mean nothing.
                    const st = Io.Dir.cwd().statFile(io, child, .{}) catch continue;
                    try map.put(a, child, .{
                        .mtime_ns = st.mtime.nanoseconds,
                        .size = st.size,
                    });
                },
                else => {},
            }
        }
    }
    return .{ .arena = arena, .map = map, .stopped_early = clipped };
}

/// What changed between two snapshots. Paths borrow from the snapshots'
/// arenas (`added`/`changed` from `new`, `removed` from `old`); the
/// slice headers live in the allocator handed to `diff`. Each list is
/// sorted so the caller's rendering is deterministic regardless of hash
/// iteration order.
pub const Diff = struct {
    added: []const []const u8,
    removed: []const []const u8,
    changed: []const []const u8,

    pub fn isEmpty(self: *const Diff) bool {
        return self.added.len == 0 and self.removed.len == 0 and self.changed.len == 0;
    }
};

pub fn diff(a: Allocator, old: *const Snapshot, new: *const Snapshot) Error!Diff {
    var added: std.ArrayList([]const u8) = .empty;
    var removed: std.ArrayList([]const u8) = .empty;
    var changed: std.ArrayList([]const u8) = .empty;

    var new_it = new.map.iterator();
    while (new_it.next()) |entry| {
        if (old.map.get(entry.key_ptr.*)) |old_fp| {
            if (!old_fp.eql(entry.value_ptr.*)) try changed.append(a, entry.key_ptr.*);
        } else {
            try added.append(a, entry.key_ptr.*);
        }
    }
    var old_it = old.map.iterator();
    while (old_it.next()) |entry| {
        if (!new.map.contains(entry.key_ptr.*)) try removed.append(a, entry.key_ptr.*);
    }

    for ([_]*std.ArrayList([]const u8){ &added, &removed, &changed }) |list| {
        std.mem.sort([]const u8, list.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
    }

    return .{
        .added = try added.toOwnedSlice(a),
        .removed = try removed.toOwnedSlice(a),
        .changed = try changed.toOwnedSlice(a),
    };
}

// ---------------------------------------------------------------------
// Tests — devx plan 04 CP1.
// ---------------------------------------------------------------------

const testing = std.testing;

test "scan fingerprints every .sjon under the root, skipping the skip-list" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "top.sjon", .data = "(a)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "ignored" });
    try tmp.dir.createDirPath(io, "nested/deeper");
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/deeper/leaf.sjon", .data = "(b)" });
    try tmp.dir.createDirPath(io, "node_modules");
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/skip.sjon", .data = "(c)" });
    try tmp.dir.createDirPath(io, ".hidden");
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden/dot.sjon", .data = "(d)" });

    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    var snap = try scan(testing.allocator, io, root, .{});
    defer snap.deinit();
    try testing.expectEqual(@as(usize, 2), snap.count());
    try testing.expect(!snap.stopped_early);
}

test "scan reports when the entry ceiling clipped the walk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    for (0..6) |i| {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "f{d}.sjon", .{i});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "(a)" });
    }

    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    // Ceiling below the file count: a partial set, and it says so.
    var clipped = try scan(testing.allocator, io, root, .{ .max_entries = 3 });
    defer clipped.deinit();
    try testing.expect(clipped.stopped_early);
    try testing.expect(clipped.count() < 6);

    // Same tree, default ceiling: everything, no flag.
    var full = try scan(testing.allocator, io, root, .{});
    defer full.deinit();
    try testing.expect(!full.stopped_early);
    try testing.expectEqual(@as(usize, 6), full.count());
}

test "scan reports an unreadable subdirectory as a partial set" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "top.sjon", .data = "(a)" });
    try tmp.dir.createDirPath(io, "locked");
    try tmp.dir.writeFile(io, .{ .sub_path = "locked/inner.sjon", .data = "(b)" });

    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    // Baseline: both files, complete set.
    {
        var snap = try scan(testing.allocator, io, root, .{});
        defer snap.deinit();
        try testing.expectEqual(@as(usize, 2), snap.count());
        try testing.expect(!snap.stopped_early);
    }

    // Drop the search bit so the subdirectory cannot be opened. Skipping
    // it is correct — one permission error must not end the watch loop —
    // but doing so silently made the next `diff` report `inner.sjon` as
    // *removed*, i.e. a phantom change from a file nobody touched.
    var locked = try tmp.dir.openDir(io, "locked", .{ .iterate = true });
    defer locked.close(io);
    // `@enumFromInt(0)` is "no permissions" on POSIX and a no-op attribute
    // word on Windows; the count check below is what decides whether the
    // skip actually took effect, so this stays portable either way.
    locked.setPermissions(io, @enumFromInt(0)) catch return error.SkipZigTest;
    defer locked.setPermissions(io, .default_dir) catch {};

    var snap = try scan(testing.allocator, io, root, .{});
    defer snap.deinit();
    // Running as root defeats the permission bits entirely; only assert
    // the flag when the skip actually happened.
    if (snap.count() == 2) return error.SkipZigTest;
    try testing.expect(snap.stopped_early);
}

test "diff reports added, removed, and changed paths; unchanged tree diffs empty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "stays.sjon", .data = "(a)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mutates.sjon", .data = "(b)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "leaves.sjon", .data = "(c)" });

    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    var before = try scan(testing.allocator, io, root, .{});
    defer before.deinit();

    // Unchanged tree diffs empty.
    {
        var again = try scan(testing.allocator, io, root, .{});
        defer again.deinit();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const d = try diff(arena.allocator(), &before, &again);
        try testing.expect(d.isEmpty());
    }

    // Grow one file (size change beats mtime granularity), add one,
    // remove one.
    try tmp.dir.writeFile(io, .{ .sub_path = "mutates.sjon", .data = "(b :longer true)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "arrives.sjon", .data = "(d)" });
    try tmp.dir.deleteFile(io, "leaves.sjon");

    var after = try scan(testing.allocator, io, root, .{});
    defer after.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const d = try diff(arena.allocator(), &before, &after);
    try testing.expect(!d.isEmpty());
    try testing.expectEqual(@as(usize, 1), d.added.len);
    try testing.expect(std.mem.endsWith(u8, d.added[0], "arrives.sjon"));
    try testing.expectEqual(@as(usize, 1), d.removed.len);
    try testing.expect(std.mem.endsWith(u8, d.removed[0], "leaves.sjon"));
    try testing.expectEqual(@as(usize, 1), d.changed.len);
    try testing.expect(std.mem.endsWith(u8, d.changed[0], "mutates.sjon"));
}
