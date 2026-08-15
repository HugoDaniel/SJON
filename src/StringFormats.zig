//! Named, closed string-format checkers used by `:string-bounds :format …`.
//!
//! Each `check*` returns `bool`. Inputs are well-formed UTF-8 byte
//! slices (parser invariant). Format semantics are deliberately
//! pragmatic-not-pedantic — they catch obvious typos and shape errors
//! at validate time, not standards-grade conformance. Authors who need
//! stricter checking can layer a host-level validator on top.
//!
//! Closed list documented in `docs/LANGUAGE.md`:
//!   * `email`  — exactly one `@`; both sides non-empty; right side
//!     contains at least one `.` not at start/end.
//!   * `uri`    — `<scheme>:<tail>` with scheme `[A-Za-z][A-Za-z0-9+.-]*`
//!     and non-empty tail.
//!   * `path`   — non-empty; no `\x00`, no `\n`, no leading whitespace.
//!   * `uuid`   — exactly 36 bytes, `8-4-4-4-12` hex with dashes at
//!     positions 8/13/18/23.
//!   * `semver` — `MAJOR.MINOR.PATCH` (no leading zeros on any field),
//!     optional `-<pre>` and `+<build>` per semver.org grammar.

const std = @import("std");
const Plugin = @import("Plugin.zig");

pub const Format = Plugin.ValueKind.StringBounds.Format;

/// Switch on `format` and delegate to the matching checker.
pub fn check(format: Format, text: []const u8) bool {
    return switch (format) {
        .email => checkEmail(text),
        .uri => checkUri(text),
        .path => checkPath(text),
        .uuid => checkUuid(text),
        .semver => checkSemver(text),
    };
}

/// Parse a `:format` symbol's bare name into a `Format`. Returns null
/// on unknown text — the meta-schema's `string-format-tag` member-set
/// already rejects unknown symbols at load time, so callers that go
/// through the loader treat null as unreachable.
/// Every tag's wire spelling is its Zig name, so `stringToEnum` *is* the
/// mapping — the `eql` chain this replaced was a hand-written copy of the
/// enum that a sixth format would have silently failed to grow.
pub fn fromName(text: []const u8) ?Format {
    return std.meta.stringToEnum(Format, text);
}

/// `@`-once, non-empty local, dotted host.
fn checkEmail(text: []const u8) bool {
    var at_count: usize = 0;
    var at_pos: usize = 0;
    for (text, 0..) |c, i| if (c == '@') {
        at_count += 1;
        at_pos = i;
    };
    if (at_count != 1) return false;
    const local = text[0..at_pos];
    const host = text[at_pos + 1 ..];
    if (local.len == 0 or host.len == 0) return false;
    if (host[0] == '.' or host[host.len - 1] == '.') return false;
    var saw_dot: bool = false;
    for (host) |c| if (c == '.') {
        saw_dot = true;
        break;
    };
    return saw_dot;
}

/// `<scheme>:<tail>` with scheme starting with a letter, body
/// alphanumeric / `+`/ `.` / `-`, and non-empty tail. RFC 3986 §3.1.
fn checkUri(text: []const u8) bool {
    if (text.len < 2) return false;
    if (!std.ascii.isAlphabetic(text[0])) return false;
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == ':') break;
        const ok = std.ascii.isAlphanumeric(c) or c == '+' or c == '.' or c == '-';
        if (!ok) return false;
    }
    if (i >= text.len) return false; // no `:` found
    if (i + 1 >= text.len) return false; // empty tail
    return true;
}

/// Non-empty; no NUL, no newline, no leading whitespace. Liberal on
/// the rest — separator conventions vary per host.
fn checkPath(text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.ascii.isWhitespace(text[0])) return false;
    for (text) |c| {
        if (c == 0 or c == '\n') return false;
    }
    return true;
}

/// RFC 4122 textual representation: 36 bytes, lowercase or uppercase
/// hex with dashes at positions 8, 13, 18, 23.
fn checkUuid(text: []const u8) bool {
    if (text.len != 36) return false;
    for (text, 0..) |c, i| {
        switch (i) {
            8, 13, 18, 23 => if (c != '-') return false,
            else => if (!std.ascii.isHex(c)) return false,
        }
    }
    return true;
}

/// SemVer 2.0.0 grammar: `MAJOR.MINOR.PATCH[-<pre>][+<build>]`.
/// `MAJOR.MINOR.PATCH` are non-negative integers without leading zeros
/// (single `0` is allowed). Pre-release identifiers are dot-separated
/// alphanumeric / hyphen segments; numeric segments forbid leading
/// zeros. Build metadata is dot-separated alphanumeric / hyphen
/// segments with no leading-zero constraint.
fn checkSemver(text: []const u8) bool {
    var rest = text;

    // MAJOR.MINOR.PATCH
    var dot: usize = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
    if (!isNumericIdent(rest[0..dot])) return false;
    rest = rest[dot + 1 ..];
    dot = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
    if (!isNumericIdent(rest[0..dot])) return false;
    rest = rest[dot + 1 ..];

    // PATCH ends at '-' (pre-release), '+' (build), or end of string.
    var patch_end: usize = rest.len;
    for (rest, 0..) |c, i| if (c == '-' or c == '+') {
        patch_end = i;
        break;
    };
    if (!isNumericIdent(rest[0..patch_end])) return false;
    rest = rest[patch_end..];

    // Optional pre-release.
    if (rest.len > 0 and rest[0] == '-') {
        rest = rest[1..];
        const plus = std.mem.indexOfScalar(u8, rest, '+') orelse rest.len;
        if (!isValidPreRelease(rest[0..plus])) return false;
        rest = rest[plus..];
    }

    // Optional build metadata.
    if (rest.len > 0 and rest[0] == '+') {
        rest = rest[1..];
        if (!isValidBuild(rest)) return false;
        rest = rest[rest.len..];
    }

    return rest.len == 0;
}

fn isNumericIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s.len > 1 and s[0] == '0') return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isAlphanumeric(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn hasNonDigit(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return true;
    return false;
}

fn isValidPreRelease(s: []const u8) bool {
    if (s.len == 0) return false;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |seg| {
        if (seg.len == 0) return false;
        if (!isAlphanumeric(seg)) return false;
        // Numeric segments forbid leading zeros (but `-` mixed in makes it
        // alphanumeric, not numeric, and is unconstrained).
        if (!hasNonDigit(seg)) {
            if (seg.len > 1 and seg[0] == '0') return false;
        }
    }
    return true;
}

fn isValidBuild(s: []const u8) bool {
    if (s.len == 0) return false;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |seg| {
        if (seg.len == 0) return false;
        if (!isAlphanumeric(seg)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "email: pass" {
    try testing.expect(checkEmail("a@b.c"));
    try testing.expect(checkEmail("ada+test@example.com"));
}

test "email: fail" {
    try testing.expect(!checkEmail(""));
    try testing.expect(!checkEmail("noat.com"));
    try testing.expect(!checkEmail("@host.com"));
    try testing.expect(!checkEmail("user@"));
    try testing.expect(!checkEmail("user@host")); // no dot
    try testing.expect(!checkEmail("user@.com")); // leading dot
    try testing.expect(!checkEmail("user@com.")); // trailing dot
    try testing.expect(!checkEmail("u@@h.c")); // two `@`
}

test "uri: pass" {
    try testing.expect(checkUri("https://example.com"));
    try testing.expect(checkUri("file:///tmp/x"));
    try testing.expect(checkUri("a+b.c-d:tail"));
}

test "uri: fail" {
    try testing.expect(!checkUri(""));
    try testing.expect(!checkUri("nocolon"));
    try testing.expect(!checkUri("1abc:tail")); // scheme must start alpha
    try testing.expect(!checkUri("abc:")); // empty tail
    try testing.expect(!checkUri(":empty"));
}

test "path: pass" {
    try testing.expect(checkPath("a"));
    try testing.expect(checkPath("/usr/local/bin"));
    try testing.expect(checkPath("./relative/path"));
}

test "path: fail" {
    try testing.expect(!checkPath(""));
    try testing.expect(!checkPath(" leading-space"));
    try testing.expect(!checkPath("multi\nline"));
    try testing.expect(!checkPath("nul\x00byte"));
}

test "uuid: pass" {
    try testing.expect(checkUuid("00000000-0000-0000-0000-000000000000"));
    try testing.expect(checkUuid("550e8400-e29b-41d4-a716-446655440000"));
    try testing.expect(checkUuid("550E8400-E29B-41D4-A716-446655440000"));
}

test "uuid: fail" {
    try testing.expect(!checkUuid(""));
    try testing.expect(!checkUuid("550e8400-e29b-41d4-a716-44665544000")); // 35
    try testing.expect(!checkUuid("550e8400-e29b-41d4-a716-4466554400000")); // 37
    try testing.expect(!checkUuid("550e8400-e29b-41d4-a716_446655440000")); // bad sep
    try testing.expect(!checkUuid("550e8400-e29b-41d4-a716-44665544000z")); // non-hex
}

test "semver: pass" {
    try testing.expect(checkSemver("0.0.0"));
    try testing.expect(checkSemver("1.2.3"));
    try testing.expect(checkSemver("1.2.3-alpha"));
    try testing.expect(checkSemver("1.2.3-alpha.1"));
    try testing.expect(checkSemver("1.2.3+build.1"));
    try testing.expect(checkSemver("1.2.3-rc.1+build.123"));
    try testing.expect(checkSemver("10.20.30"));
}

test "semver: fail" {
    try testing.expect(!checkSemver(""));
    try testing.expect(!checkSemver("1"));
    try testing.expect(!checkSemver("1.2"));
    try testing.expect(!checkSemver("01.0.0")); // leading zero on MAJOR
    try testing.expect(!checkSemver("1.02.0"));
    try testing.expect(!checkSemver("1.2.3-"));
    try testing.expect(!checkSemver("1.2.3-01")); // numeric pre-release with leading zero
    try testing.expect(!checkSemver("v1.2.3"));
    try testing.expect(!checkSemver("1.2.3+"));
}

test "fromName: round-trip" {
    try testing.expectEqual(Format.email, fromName("email").?);
    try testing.expectEqual(Format.uri, fromName("uri").?);
    try testing.expectEqual(Format.path, fromName("path").?);
    try testing.expectEqual(Format.uuid, fromName("uuid").?);
    try testing.expectEqual(Format.semver, fromName("semver").?);
    try testing.expect(fromName("unknown") == null);
}

test "check: delegates by tag" {
    try testing.expect(check(.email, "a@b.c"));
    try testing.expect(!check(.semver, "v1.2.3"));
}
