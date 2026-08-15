//! Size-capped file reads for the native CLI and filesystem resolver.
//!
//! Every on-disk read those two layers perform — documents, manifests,
//! lockfiles, wasm blobs, project files — routes through here so an
//! oversized (or maliciously large) file fails with a clean
//! `error.StreamTooLong` instead of an unbounded allocation. The wire
//! ceiling `MAX_FILE_SIZE` is the production limit; `max_bytes` is a
//! parameter so tests can trip the cap with a tiny file rather than a
//! 256 MiB one.
//!
//! `std`-only leaf (no SJON imports beyond the shared size constant), so
//! it never reaches the freestanding wasm artifacts — which have no
//! filesystem anyway. Reads are always cwd-relative, matching every
//! call site (`Io.Dir.cwd()`); absolute paths pass through unchanged.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Production read ceiling — the binary IR's own `MAX_FILE_SIZE`
/// (256 MiB), the largest input any SJON stage accepts.
pub const MAX_FILE_SIZE: usize = @import("BinaryFormat.zig").MAX_FILE_SIZE;

pub const Error = Io.Dir.ReadFileAllocError;

/// Read `path` fully as a NUL-sentinelled slice, capped at `max_bytes`.
/// A file reaching or exceeding the cap returns `error.StreamTooLong`.
pub fn readFileZ(io: Io, path: []const u8, gpa: Allocator, max_bytes: usize) Error![:0]u8 {
    return Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(max_bytes), .of(u8), 0);
}

/// Read `path` fully, capped at `max_bytes`. A file reaching or exceeding
/// the cap returns `error.StreamTooLong`.
pub fn readFile(io: Io, path: []const u8, gpa: Allocator, max_bytes: usize) Error![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes));
}

test "readFile: a file at/over the cap errors cleanly, never truncates (D.18)" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const content = "x" ** 100;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big.bin", .data = content });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/big.bin", .{&tmp.sub_path});

    // A 16-byte cap over 100 bytes of content: a clean error, not a
    // silent truncation, not a panic.
    try testing.expectError(error.StreamTooLong, readFile(testing.io, path, a, 16));
    try testing.expectError(error.StreamTooLong, readFileZ(testing.io, path, a, 16));

    // Under the production ceiling the same read returns every byte.
    const ok = try readFile(testing.io, path, a, MAX_FILE_SIZE);
    try testing.expectEqual(@as(usize, 100), ok.len);
    const okz = try readFileZ(testing.io, path, a, MAX_FILE_SIZE);
    try testing.expectEqual(@as(usize, 100), okz.len);
    try testing.expectEqual(@as(u8, 0), okz[okz.len]);
}
