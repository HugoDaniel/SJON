//! `lines` — the conformance corpus's fixture name-extractor, and the
//! single definition of *what counts as a name* for both routes a
//! provider can take.
//!
//! The behaviour is boring on purpose: split the source on `\n`, trim
//! ASCII whitespace, and every non-empty line is a name, order preserved.
//! What the corpus is testing is the **seam** — declare a provider, pin
//! it, extract, register, resolve, fail, be absent — not GLSL parsing.
//! Real providers (GLSL uniforms, SQL columns, regex groups) are
//! downstream plugin authors' work, written against this same contract.
//!
//! **Why a scanner and not two `extract` functions.** `lines_provider.zig`
//! compiles this file into a freestanding wasm module and writes its
//! answer straight into the result frame (two passes: measure, then
//! write), while `lines_plugin.zig` links it natively as a
//! `Plugin.CrossRefProvider.impl`. Both drive `Scan`, so the two routes
//! cannot drift on the one question that matters — which bytes are a
//! name. A fixture whose portable and native halves disagreed would make
//! every corpus case that uses it prove nothing.
//!
//! Dependency-free by construction: this file is reachable from a
//! freestanding wasm root, so it imports `std` and nothing else. In
//! particular it re-spells `ExtractError` rather than importing
//! `Plugin` — Zig error sets are structural, so the native `impl`
//! coercion still typechecks.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Same set as `Plugin.CrossRefProvider.ExtractError`, spelled locally.
pub const ExtractError = error{ OutOfMemory, ExtractionFailed };

/// Trimmed from both ends of every line. `\r` is in the set so a source
/// authored with CRLF endings extracts the same names as one without —
/// a corpus fixture that answered differently on two checkouts would be
/// a very slow bug to find.
pub const whitespace = " \t\r";

/// A line that is exactly this makes the provider refuse: `extract`
/// returns `error.ExtractionFailed` and the portable route frames an
/// `ok=0` structured error. It is how `cross-ref-provider-extraction-
/// failed` reaches `cross_ref_extraction_failed` from a source a human
/// can read, without needing a genuinely malformed blob.
pub const failure_marker = "!malformed";

/// Walks a source and yields the names in it. `next()` returns null both
/// at end of source *and* at the refusal marker — check `refused`
/// afterwards to tell the two apart.
pub const Scan = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    refused: bool = false,

    pub fn next(self: *Scan) ?[]const u8 {
        while (self.lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, whitespace);
            if (line.len == 0) continue;
            if (std.mem.eql(u8, line, failure_marker)) {
                self.refused = true;
                return null;
            }
            return line;
        }
        return null;
    }
};

pub fn scan(source: []const u8) Scan {
    return .{ .lines = std.mem.splitScalar(u8, source, '\n') };
}

/// The native route's extractor: `Plugin.CrossRefProvider.Extract`.
///
/// Names are copied onto `a` rather than borrowed from `source`, per that
/// contract — the caller is entitled to a result that outlives its input.
/// Duplicates are *kept*: collapsing them is the extraction table's job
/// (a blob's internal redundancy is not a document error), and a fixture
/// that deduped here would hide whether that rule is still enforced.
pub fn extract(a: Allocator, source: []const u8) ExtractError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = scan(source);
    while (it.next()) |name| try out.append(a, try a.dupe(u8, name));
    if (it.refused) return error.ExtractionFailed;
    return out.items;
}

// -- the overflow twin ------------------------------------------------

/// Longest `n<i>` this fixture can spell — `n` plus a `usize` in decimal.
pub const max_overflow_name_len = 1 + 20;

/// Most names this fixture will spell, whatever the source asks for.
/// Comfortably clear of `ProviderExtraction.MAX_EXTRACTED_NAMES` (4096)
/// so "way over the ceiling" stays expressible, and small enough that
/// the portable route's frame arithmetic cannot overflow a wasm32
/// `usize` — a fixture is not the place to discover that.
pub const max_overflow_count = 1 << 16;

/// The overflow provider reads its source as a decimal *count* and emits
/// that many distinct names. Taking the count from the document rather
/// than hard-coding `MAX_EXTRACTED_NAMES + 1` keeps the ceiling in one
/// place (`ProviderExtraction.MAX_EXTRACTED_NAMES`) and lets the corpus
/// case carry a one-line source that says plainly what it is asking for.
///
/// A source that is not a decimal count is a refusal, not a zero: a
/// silent empty member set would turn every reference in the document
/// into `not_cross_ref` and bury the real problem.
pub fn overflowCount(source: []const u8) ExtractError!usize {
    // `\n` joins the trim set here and nowhere else: for `lines` a
    // newline is the separator and trimming it would be meaningless, but
    // an overflow source is one whole count, and a document that spells
    // it across a line break is asking for the same number.
    const n = std.fmt.parseInt(usize, std.mem.trim(u8, source, whitespace ++ "\n"), 10) catch
        return error.ExtractionFailed;
    if (n > max_overflow_count) return error.ExtractionFailed;
    return n;
}

/// `n0`, `n1`, … — written into caller storage so the portable route can
/// spell a name without an allocator.
pub fn overflowName(buf: *[max_overflow_name_len]u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "n{d}", .{i}) catch unreachable;
}

/// The native twin of `extract` for the overflow provider.
pub fn extractOverflow(a: Allocator, source: []const u8) ExtractError![]const []const u8 {
    const count = try overflowCount(source);
    const out = try a.alloc([]const u8, count);
    var buf: [max_overflow_name_len]u8 = undefined;
    for (out, 0..) |*slot, i| slot.* = try a.dupe(u8, overflowName(&buf, i));
    return out;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn expectNames(source: []const u8, expected: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const got = try extract(arena.allocator(), source);
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
}

test "lines: one name per non-empty line, order preserved" {
    try expectNames("u_time\nu_mouse\nu_res", &.{ "u_time", "u_mouse", "u_res" });
}

test "lines: an empty source has no names, and that is not a failure" {
    // The distinction matters downstream: an empty member set makes every
    // reference miss, whereas a failure poisons the bucket and suppresses
    // those misses. A fixture that conflated them could not tell the two
    // corpus cases apart.
    try expectNames("", &.{});
    try expectNames("\n\n\n", &.{});
}

test "lines: trailing newline does not invent a name" {
    try expectNames("u_time\n", &.{"u_time"});
}

test "lines: whitespace-only lines are skipped and names are trimmed" {
    try expectNames("  u_time  \n\t\n   \n\tu_mouse", &.{ "u_time", "u_mouse" });
}

test "lines: CRLF endings extract the same names as LF" {
    try expectNames("u_time\r\nu_mouse\r\n", &.{ "u_time", "u_mouse" });
}

test "lines: duplicates survive extraction" {
    // Collapsing them is `ProviderExtraction.collectNames`' decision, not
    // the provider's; pinned here so a "helpful" fixture cannot quietly
    // take that decision over.
    try expectNames("u_time\nu_time", &.{ "u_time", "u_time" });
}

test "lines: the marker line refuses, wherever it sits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.ExtractionFailed, extract(arena.allocator(), failure_marker));
    try testing.expectError(error.ExtractionFailed, extract(arena.allocator(), "u_time\n!malformed\nu_mouse"));
    // Trimmed before comparison, so indentation does not smuggle it past.
    try testing.expectError(error.ExtractionFailed, extract(arena.allocator(), "   !malformed  "));
    // But it only matches a whole line — a name that merely contains it
    // is an ordinary name.
    try expectNames("!malformed-ish", &.{"!malformed-ish"});
}

test "lines: the scanner reports refusal separately from exhaustion" {
    var done = scan("u_time");
    try testing.expectEqualStrings("u_time", done.next().?);
    try testing.expect(done.next() == null);
    try testing.expect(!done.refused);

    var refused = scan("u_time\n" ++ failure_marker);
    try testing.expectEqualStrings("u_time", refused.next().?);
    try testing.expect(refused.next() == null);
    try testing.expect(refused.refused);
}

test "lines-overflow: emits exactly the count its source asks for" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const got = try extractOverflow(arena.allocator(), "3");
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("n0", got[0]);
    try testing.expectEqualStrings("n1", got[1]);
    try testing.expectEqualStrings("n2", got[2]);

    // Surrounding whitespace is the same non-event it is for `lines`.
    try testing.expectEqual(@as(usize, 1), (try extractOverflow(arena.allocator(), " 1\n")).len);
}

test "lines-overflow: a non-count source refuses rather than emitting nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.ExtractionFailed, extractOverflow(arena.allocator(), "lots"));
    try testing.expectError(error.ExtractionFailed, extractOverflow(arena.allocator(), "-1"));
    try testing.expectError(error.ExtractionFailed, extractOverflow(arena.allocator(), ""));

    // The fixture's own cap, so a typo in a corpus source cannot ask the
    // portable route for a frame it has no arithmetic for. One under is
    // still honoured, so this is the cap and not the parse.
    try testing.expectError(
        error.ExtractionFailed,
        extractOverflow(arena.allocator(), std.fmt.comptimePrint("{d}", .{max_overflow_count + 1})),
    );
    try testing.expectEqual(max_overflow_count, (try overflowCount(
        std.fmt.comptimePrint("{d}", .{max_overflow_count}),
    )));
}

test "lines-overflow: names are spelled the same with and without an allocator" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // `overflowName` is what the portable route uses; `extractOverflow`
    // is what the native one uses. The corpus only proves anything if
    // they agree.
    const got = try extractOverflow(arena.allocator(), "5");
    var buf: [max_overflow_name_len]u8 = undefined;
    for (got, 0..) |name, i| try testing.expectEqualStrings(overflowName(&buf, i), name);
}
