//! Playground deep-link codec — the Zig twin of
//! `landing-page/src/playground/hash-state.ts` (the reference; read it
//! first when touching this). Format: `<base>#s=<b64url(doc)>` +
//! optional `&sc=<b64url(JSON array of schema texts)>`, unpadded
//! URL-safe base64 over UTF-8 bytes. The two sides are pinned against
//! each other by a fixture drift gate (`share-link.fixture.txt`,
//! decoded by a landing-page `node:test`), the same single-source
//! discipline as `classifier.json`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{OutOfMemory};

/// Where share links point unless `--base=` overrides. One constant so
/// the docs audit (and the drift gate) can see it.
pub const DEFAULT_BASE = "https://hugodaniel.com/pages/sjon/playground";

/// Final-URL length past which `sjon share` prints a stderr note: the
/// playground itself is fine (the fragment never reaches a server),
/// but chat apps and some servers strain past ~8 KiB.
pub const SIZE_WARN_BYTES: usize = 8 * 1024;

/// Build the full URL: `base#s=…[&sc=…]`. Pure bytes-in, URL-out — no
/// parsing, no validation; sharing a broken document is the point.
pub fn buildUrl(
    a: Allocator,
    base: []const u8,
    doc: []const u8,
    schemas: []const []const u8,
) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, base);
    try buf.appendSlice(a, "#s=");
    try appendB64Url(&buf, a, doc);
    if (schemas.len > 0) {
        var json: std.Io.Writer.Allocating = .init(a);
        defer json.deinit();
        var w: std.json.Stringify = .{ .writer = &json.writer };
        w.write(schemas) catch return error.OutOfMemory;
        try buf.appendSlice(a, "&sc=");
        try appendB64Url(&buf, a, json.written());
    }
    return buf.toOwnedSlice(a);
}

fn appendB64Url(buf: *std.ArrayList(u8), a: Allocator, bytes: []const u8) Error!void {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const dst = try a.alloc(u8, enc.calcSize(bytes.len));
    defer a.free(dst);
    const written = enc.encode(dst, bytes);
    try buf.appendSlice(a, written);
}

test "buildUrl: byte-pinned against hash-state.ts expectations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Multibyte content — UTF-8 bytes, not codepoints.
    const bare = try buildUrl(a, "B", "(café)", &.{});
    try std.testing.expectEqualStrings("B#s=KGNhZsOpKQ", bare);

    // Schema texts as a minified JSON array, argument order preserved.
    const with_schemas = try buildUrl(a, "B", "(café)", &.{ "(x)", "(y)" });
    try std.testing.expectEqualStrings("B#s=KGNhZsOpKQ&sc=WyIoeCkiLCIoeSkiXQ", with_schemas);
}

test "share-link fixture matches the landing-page drift gate byte-for-byte" {
    // The same checked-in URL the landing-page `node:test` decodes
    // (`hash-state.test.ts`); emitting anything else means the two
    // codecs drifted.
    const io = std.testing.io;
    // Not `catch return error.SkipZigTest`: this is the only thing pinning
    // the Zig emitter against the TS decoder, and a skip on read failure
    // meant renaming or moving the fixture silently disabled that half of
    // the drift gate — green build, no coverage, no signal. A missing
    // fixture is a broken gate, so it fails.
    const fixture_path = "landing-page/src/playground/share-link.fixture.txt";
    const fixture = std.Io.Dir.cwd().readFileAlloc(
        io,
        fixture_path,
        std.testing.allocator,
        .limited(4096),
    ) catch |err| {
        std.debug.print(
            "share-link drift gate: cannot read {s}: {s}\n" ++
                "  (tests run with the repo root as cwd; if the fixture moved, update this path\n" ++
                "   and `landing-page/src/playground/hash-state.test.ts`, which decodes the same file)\n",
            .{ fixture_path, @errorName(err) },
        );
        return err;
    };
    defer std.testing.allocator.free(fixture);
    const expected = std.mem.trimEnd(u8, fixture, "\n");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const url = try buildUrl(arena.allocator(), DEFAULT_BASE, "(café)", &.{ "(x)", "(y)" });
    try std.testing.expectEqualStrings(expected, url);
}
