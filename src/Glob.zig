//! Simple glob matcher for `:documents` / `:ignore` patterns.
//!
//! Dialect (intentionally minimal — negation lives in `:ignore`, not in
//! patterns themselves):
//!
//!   - `*`    matches any sequence of characters within one path segment
//!            (never crosses `/`).
//!   - `**`   matches any sequence of characters, including `/` — used
//!            for recursive directory walks (`docs/**/*.sjon`).
//!   - `?`    matches exactly one character within one path segment.
//!   - `{a,b,c}`  alternation; matches any of the comma-separated
//!                branches. No nesting.
//!   - Literal characters match themselves.
//!
//! Not implemented (deliberate):
//!   - Character classes (`[abc]`).
//!   - Pattern negation (use `:ignore` for excludes).
//!   - Escaping (paths shouldn't contain `*`/`?` literally; we don't
//!     bend over backwards to support pathological filenames).
//!
//! Memory model: `match` is pure; callers pass owned bytes for both
//! pattern and path. No allocations.
//!
//! Work: every `matchInner` entry counts one step against
//! `MAX_MATCH_STEPS`; past it the match fails closed. Depth alone does not
//! bound time — see the constant.
//!
//! Recursion: `matchInner` recurses on strictly-shorter pattern suffixes
//! (each `*`/`**`/`{…}` consumes ≥1 pattern byte before recursing), so the
//! depth is bounded by the number of wildcard/brace constructs, itself
//! ≤ `pattern.len`. `match` caps `pattern.len` at `MAX_PATTERN_LEN` (512),
//! making that a hard depth ceiling — this matcher is *not* one of the four
//! frame-stack walkers the project mandates (Parser/Validator/Expr/Cursor);
//! it uses bounded host recursion, which the recursion policy permits when
//! the bound is enforced and stated (it is, here).
//!
//! Known limitation (not a stack issue): the `*`/`**` handlers backtrack
//! over path positions, so an adversarial in-segment pattern like
//! `a*a*a*…` against a long segment is worst-case exponential in *time*.
//! The length cap bounds the exponent but not the base; a step/backtrack
//! budget (or an NFA rewrite) is the real fix — deferred as a follow-up.

const std = @import("std");

/// Upper bound on pattern length. Recursion depth is bounded by the number
/// of wildcard/brace constructs in the pattern, which is ≤ `pattern.len`, so
/// this doubles as the recursion-depth ceiling (≤ 512 small frames, safe on
/// the native stack and wasm-ld's 64 KiB shadow stack). Patterns come from
/// user-editable `sjon-project.sjon`, so the bound is load-bearing, not
/// cosmetic. Over-length patterns fail closed (match nothing).
pub const MAX_PATTERN_LEN: usize = 512;

/// Ceiling on matcher work per `match` call, counted once per
/// `matchInner` entry. The depth cap above bounds the *stack*; it does
/// not bound *time*: every `**` retries the rest of the pattern at every
/// remaining path offset, so `n` stacked `**` segments cost O(len^n) —
/// twelve of them against a 100-character path never returned. Past the
/// ceiling the match fails closed, exactly like an over-length pattern,
/// so a hostile `:documents` entry costs at most this many steps. A real
/// pattern (`docs/**/*.sjon` over a long path) is a few thousand.
pub const MAX_MATCH_STEPS: u32 = 1 << 20;

/// Returns true when `path` matches `pattern` under the dialect above.
/// `path` is treated as already POSIX-normalized (forward slashes,
/// no leading `./`). A pattern longer than `MAX_PATTERN_LEN` matches
/// nothing (fail-closed) — see the constant's note.
pub fn match(pattern: []const u8, path: []const u8) bool {
    // Fail closed on over-length patterns: this bounds `matchInner`'s
    // recursion depth (≤ pattern.len ≤ MAX_PATTERN_LEN) so a hostile
    // project-file pattern can't blow the host stack.
    if (pattern.len > MAX_PATTERN_LEN) return false;
    var steps: u32 = 0;
    return matchInner(pattern, path, &steps);
}

/// Recursive matcher. Each recursive call is on a strictly-shorter pattern
/// suffix (or brace sub-slice), so depth ≤ pattern.len ≤ `MAX_PATTERN_LEN`
/// once `match`'s entry cap has run. Callers other than `match` must have
/// already enforced that cap.
fn matchInner(pattern: []const u8, path: []const u8, steps: *u32) bool {
    // Fail closed once the per-call work ceiling is spent (see
    // `MAX_MATCH_STEPS`); every recursive entry pays one step.
    if (steps.* >= MAX_MATCH_STEPS) return false;
    steps.* += 1;
    var pi: usize = 0;
    var si: usize = 0;
    while (pi < pattern.len) {
        const c = pattern[pi];

        if (c == '*' and pi + 1 < pattern.len and pattern[pi + 1] == '*') {
            // `**` — match zero or more path components (including `/`).
            // Skip a trailing `/` so `docs/**/*.sjon` makes intuitive sense.
            pi += 2;
            if (pi < pattern.len and pattern[pi] == '/') pi += 1;
            const rest = pattern[pi..];
            if (rest.len == 0) return true; // `**` at end matches all
            // Try matching the rest at every position in path (including
            // boundaries between path segments — `**` permits any depth).
            var k: usize = si;
            while (k <= path.len) : (k += 1) {
                if (matchInner(rest, path[k..], steps)) return true;
            }
            return false;
        }

        if (c == '*') {
            // Single `*` — matches within one segment.
            pi += 1;
            const rest = pattern[pi..];
            if (rest.len == 0) {
                // Rest of path must not contain `/`.
                return std.mem.indexOfScalar(u8, path[si..], '/') == null;
            }
            var k: usize = si;
            while (k <= path.len) : (k += 1) {
                if (k > si and path[k - 1] == '/') return false;
                if (matchInner(rest, path[k..], steps)) return true;
            }
            return false;
        }

        if (c == '?') {
            if (si >= path.len or path[si] == '/') return false;
            pi += 1;
            si += 1;
            continue;
        }

        if (c == '{') {
            // Alternation. Find the matching `}` and try each branch.
            const close = std.mem.indexOfScalarPos(u8, pattern, pi + 1, '}') orelse {
                // Malformed pattern — treat `{` literally.
                if (si >= path.len or path[si] != '{') return false;
                pi += 1;
                si += 1;
                continue;
            };
            const branches = pattern[pi + 1 .. close];
            const rest = pattern[close + 1 ..];
            var bi: usize = 0;
            while (bi <= branches.len) {
                const next_comma = std.mem.indexOfScalarPos(u8, branches, bi, ',') orelse branches.len;
                const branch = branches[bi..next_comma];
                // Construct the spliced pattern: branch + rest. Avoid
                // allocation by matching the branch first, then the rest.
                if (matchInnerSpliced(branch, rest, path[si..], steps)) return true;
                if (next_comma == branches.len) break;
                bi = next_comma + 1;
            }
            return false;
        }

        // Literal.
        if (si >= path.len or path[si] != c) return false;
        pi += 1;
        si += 1;
    }
    return si == path.len;
}

/// Match `branch ++ rest` against `path` without allocating. Used by
/// the alternation handler to splice branch options inline.
fn matchInnerSpliced(branch: []const u8, rest: []const u8, path: []const u8, steps: *u32) bool {
    // Match `branch` against path's prefix, then `rest` against the
    // remainder. `branch` itself never contains `**`, `*`, `?`, or `{`
    // (the brace handler is responsible) — but we tolerate them anyway
    // for forward-compat.
    if (!startsWithLiteral(branch, path)) {
        // If the branch contains wildcards, fall through to a recursive
        // match by trying every split. This handles `{a*,b}` even though
        // the spec doesn't require it.
        var k: usize = 0;
        while (k <= path.len) : (k += 1) {
            if (matchInner(branch, path[0..k], steps) and matchInner(rest, path[k..], steps)) return true;
        }
        return false;
    }
    return matchInner(rest, path[branch.len..], steps);
}

/// Cheap literal-prefix check: returns true when `lit` (containing no
/// wildcards) is a prefix of `path`.
fn startsWithLiteral(lit: []const u8, path: []const u8) bool {
    for (lit) |c| {
        if (c == '*' or c == '?' or c == '{') return false;
    }
    return std.mem.startsWith(u8, path, lit);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Glob: over-length pattern fails closed" {
    // Without the cap, a 513-char literal pattern matches char-for-char and
    // recurses one frame per literal — unbounded stack from a project file.
    const over = "a" ** (MAX_PATTERN_LEN + 1);
    try testing.expect(!match(over, over));
    // Exactly at the cap still matches — the boundary is inclusive.
    const at_cap = "a" ** MAX_PATTERN_LEN;
    try testing.expect(match(at_cap, at_cap));
}

test "Glob: over-cap **-tower is rejected by the length cap" {
    // 200 `**/` segments = 600 bytes > cap → fails closed before recursing,
    // so the exponential `**`-tower blowup is never entered.
    const tower = "**/" ** 200;
    try testing.expect(!match(tower, "a/b/c/x"));
}

test "Glob: a **-tower under the length cap is bounded by the step ceiling" {
    // Twelve `**/` segments are 36 bytes — well under MAX_PATTERN_LEN — and
    // each retries the rest at every offset of the path, O(len^12). This
    // did not return within a minute; now it fails closed at
    // MAX_MATCH_STEPS. A pattern that does match is unaffected.
    const tower = "**/" ** 12 ++ "x";
    const long_path = "a/" ** 50 ++ "y";
    try testing.expect(!match(tower, long_path));
    try testing.expect(match("**/" ** 12 ++ "y", "a/b/c/y"));
}

test "Glob: modest **-tower matches at any depth and terminates" {
    try testing.expect(match("**/**/**/x.sjon", "a/b/c/x.sjon"));
    try testing.expect(!match("**/**/y.sjon", "a/b/c/x.sjon"));
}

test "Glob: near-cap single-star pattern terminates" {
    // 256 `a*` pairs = 512 bytes (exactly at the cap, so accepted). The path
    // has no `a`, so the first literal fails in O(1); the point is that a
    // cap-length pattern is admitted and returns promptly.
    const pat = "a*" ** (MAX_PATTERN_LEN / 2);
    try testing.expect(!match(pat, "zzz"));
}

test "Glob: nested braces do not crash (unsupported, still terminates)" {
    // Nesting isn't in the dialect: the inner `}` closes the outer brace and
    // the trailing `}` falls through as a literal. We only require a prompt,
    // definite result — no hang, no panic.
    _ = match("{a,{b,c}}", "b");
    _ = match("{a,{b,c}}", "a");
}

test "Glob: literal match" {
    try testing.expect(match("docs/intro.sjon", "docs/intro.sjon"));
    try testing.expect(!match("docs/intro.sjon", "docs/other.sjon"));
}

test "Glob: single star within segment" {
    try testing.expect(match("docs/*.sjon", "docs/intro.sjon"));
    try testing.expect(!match("docs/*.sjon", "docs/sub/intro.sjon"));
    try testing.expect(!match("docs/*.sjon", "docs/intro.txt"));
}

test "Glob: double star crosses segments" {
    try testing.expect(match("docs/**/*.sjon", "docs/intro.sjon"));
    try testing.expect(match("docs/**/*.sjon", "docs/sub/intro.sjon"));
    try testing.expect(match("docs/**/*.sjon", "docs/sub/deep/intro.sjon"));
    try testing.expect(!match("docs/**/*.sjon", "notdocs/intro.sjon"));
}

test "Glob: question mark matches exactly one char" {
    try testing.expect(match("file?.sjon", "file1.sjon"));
    try testing.expect(!match("file?.sjon", "file12.sjon"));
    try testing.expect(!match("file?.sjon", "file.sjon"));
}

test "Glob: brace alternation" {
    try testing.expect(match("{docs,examples}/intro.sjon", "docs/intro.sjon"));
    try testing.expect(match("{docs,examples}/intro.sjon", "examples/intro.sjon"));
    try testing.expect(!match("{docs,examples}/intro.sjon", "other/intro.sjon"));
}

test "Glob: trailing double-star matches anything" {
    try testing.expect(match("docs/**", "docs/intro.sjon"));
    try testing.expect(match("docs/**", "docs/sub/intro.sjon"));
    try testing.expect(match("docs/**", "docs/"));
}

test "Glob: empty pattern matches empty path" {
    try testing.expect(match("", ""));
    try testing.expect(!match("", "anything"));
}

test "Glob: no wildcards in non-matching path" {
    try testing.expect(!match("foo.sjon", "bar.sjon"));
}

test "Glob: star matches empty" {
    try testing.expect(match("a*b", "ab"));
    try testing.expect(match("*.sjon", ".sjon"));
}

test "Glob: leading ** matches files at any depth" {
    try testing.expect(match("**/foo.sjon", "foo.sjon"));
    try testing.expect(match("**/foo.sjon", "a/foo.sjon"));
    try testing.expect(match("**/foo.sjon", "a/b/foo.sjon"));
    try testing.expect(!match("**/foo.sjon", "bar.sjon"));
}

test "Glob: multiple ** segments" {
    try testing.expect(match("a/**/b/**/c", "a/b/c"));
    try testing.expect(match("a/**/b/**/c", "a/x/b/y/c"));
    try testing.expect(match("a/**/b/**/c", "a/x/y/b/p/q/c"));
    try testing.expect(!match("a/**/b/**/c", "a/x/c"));
}

test "Glob: question mark does not cross slash" {
    try testing.expect(!match("a?b", "a/b"));
    try testing.expect(match("a?b", "axb"));
}

test "Glob: dot-leading filenames" {
    try testing.expect(match("*.sjon", ".sjon"));
    try testing.expect(match("*.sjon", ".hidden.sjon"));
}

test "Glob: trailing slash literal" {
    try testing.expect(match("a/", "a/"));
    try testing.expect(!match("a/", "a"));
    try testing.expect(!match("a", "a/"));
}

test "Glob: empty brace alternation" {
    // Either matches empty branch.
    try testing.expect(match("{,a}", ""));
    try testing.expect(match("{,a}", "a"));
    try testing.expect(match("{a,}", ""));
}

test "Glob: unmatched brace treated literally" {
    try testing.expect(match("{abc", "{abc"));
    try testing.expect(!match("{abc", "abc"));
}

test "Glob: triple-star degrades to double-star" {
    // `*` followed by `**` — first sees `**` and matches anywhere.
    try testing.expect(match("***", "anything"));
    try testing.expect(match("***", ""));
}

test "Glob: deep path with trailing **" {
    try testing.expect(match("**", "a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p"));
    try testing.expect(match("docs/**", "docs/a/b/c/d/e"));
}

test "Glob: matches own segment but not deeper" {
    try testing.expect(match("docs/*", "docs/foo"));
    try testing.expect(!match("docs/*", "docs/foo/bar"));
}
