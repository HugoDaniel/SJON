//! LSP URI helpers. Pure path/URI conversion — no I/O, no SJON parsing.
//!
//! `file://` URI decode used by `main.zig::resolveWorkspacePath` to
//! translate `InitializeParams.workspaceFolders[0].uri` (or `rootUri`)
//! into a filesystem path that `Host.loadProject` can consume.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Convert a `file://`-scheme URI to a filesystem path, percent-decoded.
/// Returns null when the URI is not a `file://` URI or has no path
/// component. Allocated in `arena`.
pub fn fileUriToPath(arena: Allocator, uri: []const u8) Allocator.Error!?[]const u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return null;
    var rest = uri["file://".len..];
    if (rest.len == 0) return null;
    // file://hostname/path — drop the hostname segment.
    if (rest[0] != '/') {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        rest = rest[slash..];
    }

    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, rest.len);
    var i: usize = 0;
    while (i < rest.len) {
        if (escapeAt(rest, i)) |byte| {
            try out.append(arena, byte);
            i += 3;
        } else {
            try out.append(arena, rest[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(arena);
}

/// The byte a `%XX` escape starting at `i` denotes, or null when `i` does
/// not start a well-formed escape. A bare `%` is then just a byte, which is
/// what lets a URI carrying one survive `fileUriToPath` instead of being
/// rejected — an editor will happily open a file called `100%.sjon`.
fn escapeAt(s: []const u8, i: usize) ?u8 {
    if (s[i] != '%' or i + 2 >= s.len) return null;
    const hi = hexDigit(s[i + 1]) orelse return null;
    const lo = hexDigit(s[i + 2]) orelse return null;
    return (@as(u8, hi) << 4) | @as(u8, lo);
}

/// Convert an absolute filesystem path to a `file://` URI,
/// percent-encoding every byte outside the unreserved set. `/` is left
/// literal so path structure survives.
///
/// The inverse of `fileUriToPath` for the paths this server produces:
/// workspace enumeration builds URIs here, and the handler keys its
/// document map on them, so a file whose name contains a space or a
/// non-ASCII byte has to come back byte-identical.
///
/// POSIX-shaped, like `fileUriToPath`: an absolute path is expected and
/// a relative one is encoded as given rather than rejected — inventing a
/// working directory here would be a worse answer than a URI the caller
/// can see is wrong.
pub fn pathToFileUri(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, path.len + "file://".len);
    try out.appendSlice(arena, "file://");
    for (path) |c| {
        if (isUnreservedPathByte(c)) {
            try out.append(arena, c);
        } else {
            try out.appendSlice(arena, &[_]u8{ '%', hexUpper(c >> 4), hexUpper(@truncate(c)) });
        }
    }
    return try out.toOwnedSlice(arena);
}

/// RFC 3986 unreserved, plus `/` as the retained path separator.
fn isUnreservedPathByte(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/' => true,
        else => false,
    };
}

/// Hash-map context that treats two URIs as one key when they percent-decode
/// to the same bytes.
///
/// There is no single spelling of a `file://` URI. `pathToFileUri` encodes
/// everything outside RFC 3986's unreserved set, while vscode-uri leaves
/// `( ) ! ' * + @ = , ;` literal — so a workspace file the scanner stored as
/// `…%28draft%29.sjon` is the same file the editor later opens as
/// `…(draft).sjon`. Under plain string keys that file exists twice: doubled
/// diagnostics and symbols, split cross-references, and the
/// open-buffer-shadows-disk rule silently not firing because the two keys
/// never meet.
///
/// Comparing decoded bytes rather than rewriting inbound URIs keeps the
/// lookup allocation-free (`getDocument` is `*const Self` and takes no
/// allocator) and covers spellings from clients this repo has never seen,
/// which a widened encode set would not.
///
/// The stored key stays whatever spelling arrived first, and that is what
/// goes back out in responses — every spelling is a valid URI, so a client
/// resolves it to the file it asked about either way.
pub const HashContext = struct {
    pub fn hash(_: HashContext, s: []const u8) u64 {
        // Hashed in runs between escapes rather than byte-at-a-time: the
        // decoded stream differs from the raw one only at `%XX`.
        var h = std.hash.Wyhash.init(0);
        var run_start: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            if (escapeAt(s, i)) |byte| {
                h.update(s[run_start..i]);
                h.update(&[_]u8{byte});
                i += 3;
                run_start = i;
            } else i += 1;
        }
        h.update(s[run_start..]);
        return h.final();
    }

    pub fn eql(_: HashContext, a: []const u8, b: []const u8) bool {
        var i: usize = 0;
        var j: usize = 0;
        while (i < a.len and j < b.len) {
            const ea = escapeAt(a, i);
            const eb = escapeAt(b, j);
            if ((ea orelse a[i]) != (eb orelse b[j])) return false;
            i += if (ea != null) 3 else 1;
            j += if (eb != null) 3 else 1;
        }
        return i == a.len and j == b.len;
    }
};

/// `std.StringHashMapUnmanaged` with `HashContext` in place of the byte-exact
/// one. The document map and its `URI → tree_idx` inverse both use it; a map
/// keyed on a URI that only one of them canonicalises would just move the
/// split one layer down.
pub fn HashMapUnmanaged(comptime V: type) type {
    return std.HashMapUnmanaged([]const u8, V, HashContext, std.hash_map.default_max_load_percentage);
}

fn hexUpper(nibble: u8) u8 {
    const digit: u8 = nibble & 0xF;
    return if (digit < 10) '0' + digit else 'A' + (digit - 10);
}

fn hexDigit(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "fileUriToPath: simple file URI" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = (try fileUriToPath(a, "file:///tmp/foo.sjon")).?;
    try testing.expectEqualStrings("/tmp/foo.sjon", path);
}

test "fileUriToPath: percent-decoded space" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = (try fileUriToPath(a, "file:///tmp/a%20b.sjon")).?;
    try testing.expectEqualStrings("/tmp/a b.sjon", path);
}

test "fileUriToPath: rejects non-file URIs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(?[]const u8, null), try fileUriToPath(a, "https://example.com"));
}

test "pathToFileUri: simple absolute path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "file:///tmp/foo.sjon",
        try pathToFileUri(a, "/tmp/foo.sjon"),
    );
}

test "pathToFileUri: percent-encodes a space and keeps separators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "file:///tmp/a%20b/c.sjon",
        try pathToFileUri(a, "/tmp/a b/c.sjon"),
    );
}

test "pathToFileUri round-trips through fileUriToPath" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The property that matters: the handler keys its document map on
    // these, so anything the walker encodes has to decode back exactly.
    const paths = [_][]const u8{
        "/tmp/plain.sjon",
        "/tmp/with space.sjon",
        "/tmp/dash-dot._~/ok.sjon",
        "/tmp/percent%sign.sjon",
        "/tmp/uni\xc3\xa9.sjon",
        "/tmp/hash#and?query.sjon",
    };
    for (paths) |p| {
        const round = (try fileUriToPath(a, try pathToFileUri(a, p))).?;
        try testing.expectEqualStrings(p, round);
    }
}

// ---------------------------------------------------------------------------
// HashContext
// ---------------------------------------------------------------------------

fn sameKey(a: []const u8, b: []const u8) !void {
    const ctx: HashContext = .{};
    try testing.expect(ctx.eql(a, b));
    // A map is only as good as the agreement between the two: equal keys
    // that hash apart land in different buckets and never meet.
    try testing.expectEqual(ctx.hash(a), ctx.hash(b));
}

fn differentKey(a: []const u8, b: []const u8) !void {
    try testing.expect(!HashContext.eql(.{}, a, b));
}

test "HashContext: the two spellings of one workspace file are one key" {
    // Exactly the collision this exists for: everything `pathToFileUri`
    // encodes that vscode-uri leaves literal.
    try sameKey("file:///t/notes%20%28draft%29.sjon", "file:///t/notes%20(draft).sjon");
    try sameKey("file:///t/a%21b%27c%2Ad%2Be%40f%3Dg%2Ch%3Bi", "file:///t/a!b'c*d+e@f=g,h;i");
    try sameKey("file:///t/uni%C3%A9.sjon", "file:///t/uni\xc3\xa9.sjon");
}

test "HashContext: escape case and mixed spellings agree" {
    try sameKey("file:///t/a%2Bb", "file:///t/a%2bb");
    try sameKey("file:///t/a%20(b)", "file:///t/a %28b%29");
}

test "HashContext: distinct files stay distinct" {
    try differentKey("file:///t/a.sjon", "file:///t/b.sjon");
    try differentKey("file:///t/a.sjon", "file:///t/a.sjon2");
    try differentKey("file:///t/a", "inmemory://t/a");
    // A prefix must not equal its extension even when the tail is an escape.
    try differentKey("file:///t/a", "file:///t/a%20");
    // `%` that isn't an escape is a byte, so these differ by that byte.
    try differentKey("file:///t/100%.sjon", "file:///t/100.sjon");
}

test "HashContext: a bare % is a byte, not a malformed escape" {
    // `%.s` are not hex digits, so the literal spelling and the encoded one
    // are the same key — an editor opening `100%.sjon` finds the scan's entry.
    try sameKey("file:///t/100%25.sjon", "file:///t/100%.sjon");
    // Truncated at the very end, with nothing to read.
    try sameKey("file:///t/a%", "file:///t/a%");
    try differentKey("file:///t/a%", "file:///t/a");
}

test "HashContext: a non-file scheme is compared the same way" {
    // The wasm transport keys in-memory schemas on `inmemory://`; nothing
    // about the context is `file://`-specific.
    try sameKey("inmemory://schema/0.sjon", "inmemory://schema/0.sjon");
    try differentKey("inmemory://schema/0.sjon", "inmemory://schema/1.sjon");
}

test "HashContext: a map deduplicates the spellings" {
    var map: HashMapUnmanaged(u32) = .empty;
    defer map.deinit(testing.allocator);

    try map.put(testing.allocator, "file:///t/notes%20%28draft%29.sjon", 1);
    try map.put(testing.allocator, "file:///t/notes (draft).sjon", 2);
    try testing.expectEqual(@as(u32, 1), map.count());
    try testing.expectEqual(@as(?u32, 2), map.get("file:///t/notes%20(draft).sjon"));
    // The first spelling stays the stored key — that is what responses echo.
    var keys = map.keyIterator();
    try testing.expectEqualStrings("file:///t/notes%20%28draft%29.sjon", keys.next().?.*);
}
