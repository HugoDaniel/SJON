//! Damerau-Levenshtein nearest-neighbour suggestion engine.
//!
//! The single "did you mean?" source for both surfaces: the CLI's rich
//! diagnostic format (`cli/Hints.zig`) and the LSP's quick-fix code
//! actions (`lsp/Handler.zig`). Both suggest replacements for misspelled
//! identifiers — plugin names, form heads, kvpair keys, `not_member`
//! enums, cross-ref targets, expression labels — with identical ranking.
//! Distance ≥ 3 is rejected; a typo turning "shapes" into "kjpwq" should
//! not steer the user.
//!
//! Memory model: `suggest` allocates the result slice via the supplied
//! arena; the strings themselves are borrowed from `candidates`.
//!
//! Frame-stack discipline: pure iteration, no recursion. The
//! Damerau-Levenshtein table is `[2 * (n+1)]u16` (rolling two-row
//! optimization) so it's stack-safe up to candidate names of any
//! length the lexer accepts.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Damerau-Levenshtein distance cap. Anything ≥ this is rejected as
/// "not a suggestion." Tuned to accept single-char typos and one
/// transposition (Damerau's contribution) — beyond that, suggestions
/// confuse more than they help.
pub const MAX_DISTANCE: u16 = 3;

/// One candidate's rank.
pub const Suggestion = struct {
    name: []const u8,
    distance: u16,
};

/// Return up to `max_results` candidates, ordered by ascending
/// distance then alphabetical. Owned slice in `arena`. Empty when no
/// candidate is within `MAX_DISTANCE`.
pub fn suggest(
    arena: Allocator,
    needle: []const u8,
    candidates: []const []const u8,
    max_results: usize,
) Allocator.Error![]Suggestion {
    if (candidates.len == 0 or max_results == 0) return &.{};
    var scored: std.ArrayList(Suggestion) = .empty;
    for (candidates) |c| {
        if (std.mem.eql(u8, c, needle)) continue; // exact match isn't a suggestion
        const d = distance(needle, c);
        if (d >= MAX_DISTANCE) continue;
        try scored.append(arena, .{ .name = c, .distance = d });
    }
    std.mem.sort(Suggestion, scored.items, {}, lessThan);
    if (scored.items.len > max_results) {
        scored.shrinkRetainingCapacity(max_results);
    }
    return try scored.toOwnedSlice(arena);
}

fn lessThan(_: void, a: Suggestion, b: Suggestion) bool {
    if (a.distance != b.distance) return a.distance < b.distance;
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Damerau-Levenshtein with substitution = transposition = insertion
/// = deletion = 1. The classic recurrence — fast enough for the small
/// candidate sets the CLI sees (≤ a few hundred names).
pub fn distance(a: []const u8, b: []const u8) u16 {
    if (a.len == 0) return @intCast(b.len);
    if (b.len == 0) return @intCast(a.len);

    // Cap the matrix at a sensible size — comparing 1000-char names
    // against each other isn't a normal use case and the table would
    // explode.
    const cap = @min(@max(a.len, b.len), 64);
    if (a.len > cap or b.len > cap) {
        // Long strings: fall back to a length-difference heuristic
        // that's always ≥ true distance, so the cutoff still filters.
        return @intCast(@max(a.len, b.len));
    }

    const m = a.len;
    const n = b.len;
    var prev_prev: [65]u16 = undefined;
    var prev: [65]u16 = undefined;
    var curr: [65]u16 = undefined;

    var j: usize = 0;
    while (j <= n) : (j += 1) prev[j] = @intCast(j);

    var i: usize = 1;
    while (i <= m) : (i += 1) {
        curr[0] = @intCast(i);
        j = 1;
        while (j <= n) : (j += 1) {
            const cost: u16 = if (a[i - 1] == b[j - 1]) 0 else 1;
            const del = prev[j] + 1;
            const ins = curr[j - 1] + 1;
            const sub = prev[j - 1] + cost;
            var best = @min(@min(del, ins), sub);
            if (i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]) {
                const trans = prev_prev[j - 2] + 1;
                if (trans < best) best = trans;
            }
            curr[j] = best;
        }
        prev_prev = prev;
        prev = curr;
    }
    return prev[n];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "DidYouMean.distance: identical strings is 0" {
    try testing.expectEqual(@as(u16, 0), distance("foo", "foo"));
}

test "DidYouMean.distance: single edit is 1" {
    try testing.expectEqual(@as(u16, 1), distance("foo", "fox"));
    try testing.expectEqual(@as(u16, 1), distance("foo", "fo"));
    try testing.expectEqual(@as(u16, 1), distance("fo", "foo"));
}

test "DidYouMean.distance: transposition is 1 (Damerau)" {
    try testing.expectEqual(@as(u16, 1), distance("ab", "ba"));
    try testing.expectEqual(@as(u16, 1), distance("hte", "the"));
}

test "DidYouMean.distance: empty cases" {
    try testing.expectEqual(@as(u16, 3), distance("foo", ""));
    try testing.expectEqual(@as(u16, 3), distance("", "foo"));
    try testing.expectEqual(@as(u16, 0), distance("", ""));
}

test "DidYouMean.suggest: returns the nearest neighbours" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const candidates = [_][]const u8{ "shapes", "shape", "shaper", "blob" };
    const out = try suggest(arena.allocator(), "shap", &candidates, 3);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("shape", out[0].name); // distance 1
    try testing.expectEqualStrings("shaper", out[1].name); // distance 2
    try testing.expectEqualStrings("shapes", out[2].name); // distance 2
}

test "DidYouMean.suggest: skips exact match" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const candidates = [_][]const u8{ "exact", "exsct" };
    const out = try suggest(arena.allocator(), "exact", &candidates, 3);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("exsct", out[0].name);
}

test "DidYouMean.suggest: returns empty when no candidate within MAX_DISTANCE" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const candidates = [_][]const u8{ "abcdef", "ghijkl" };
    const out = try suggest(arena.allocator(), "mnopqr", &candidates, 3);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "DidYouMean.suggest: caps results at max_results" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const candidates = [_][]const u8{ "a", "b", "c", "d" };
    const out = try suggest(arena.allocator(), "a", &candidates, 2);
    try testing.expectEqual(@as(usize, 2), out.len);
}

test "DidYouMean.suggest: empty candidates returns empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try suggest(arena.allocator(), "needle", &.{}, 5);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "DidYouMean.suggest: max_results=0 returns empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const candidates = [_][]const u8{ "ab", "ac" };
    const out = try suggest(arena.allocator(), "a", &candidates, 0);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "DidYouMean.suggest: empty needle returns shortest within MAX_DISTANCE" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const candidates = [_][]const u8{ "a", "ab", "abc", "abcd" };
    const out = try suggest(arena.allocator(), "", &candidates, 4);
    // "a" (d=1), "ab" (d=2). "abc" is d=3 which is >= MAX_DISTANCE → excluded.
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("a", out[0].name);
    try testing.expectEqualStrings("ab", out[1].name);
}

test "DidYouMean.suggest: alphabetical secondary sort at equal distance" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const candidates = [_][]const u8{ "carrot", "banana", "apple" };
    // All at distance 6 from "x" but cap kicks in well before — none within MAX_DISTANCE.
    const out = try suggest(arena.allocator(), "x", &candidates, 3);
    try testing.expectEqual(@as(usize, 0), out.len);

    // Equal-distance ties: needle "aple" gets "apple" (d=1).
    const candidates2 = [_][]const u8{ "applet", "apple", "ample" };
    const out2 = try suggest(arena.allocator(), "aple", &candidates2, 3);
    try testing.expectEqual(@as(usize, 3), out2.len);
    // First by distance, then alphabetical.
    try testing.expectEqualStrings("ample", out2[0].name);
    try testing.expectEqualStrings("apple", out2[1].name);
    try testing.expectEqualStrings("applet", out2[2].name);
}

test "DidYouMean.distance: long-string fallback" {
    // Strings longer than 64 chars fall back to the length-difference
    // heuristic. The result is always ≥ the true distance, so the
    // MAX_DISTANCE filter still rejects far-apart names.
    const long_a = "a" ** 100;
    const long_b = "b" ** 100;
    const d = distance(long_a, long_b);
    // Heuristic returns max(len_a, len_b) = 100. MAX_DISTANCE is 3, so
    // this is correctly classified as "not a suggestion."
    try testing.expect(d >= MAX_DISTANCE);
}

test "DidYouMean.distance: substitution cost is 1" {
    try testing.expectEqual(@as(u16, 1), distance("cat", "cut"));
    try testing.expectEqual(@as(u16, 3), distance("cat", "dog"));
}

test "DidYouMean.distance: prefix and suffix matches" {
    try testing.expectEqual(@as(u16, 1), distance("prefix", "prefixs"));
    try testing.expectEqual(@as(u16, 1), distance("aaab", "aab"));
}

test "DidYouMean.suggest: deduplicates against needle but not against itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Two identical candidates — both appear in output because we
    // dedupe only against the needle. This is intentional — the
    // caller's candidate list is its responsibility.
    const candidates = [_][]const u8{ "dup", "dup", "other" };
    const out = try suggest(arena.allocator(), "du", &candidates, 5);
    try testing.expectEqual(@as(usize, 2), out.len); // 2x "dup", "other" outside MAX
}
