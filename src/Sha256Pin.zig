//! `Sha256Pin` — the canonical `sha256-<64 lowercase hex>` pin format in
//! one leaf, so producers and validators can't drift on what "canonical"
//! means.
//!
//! SJON stamps and pins wasm bytes with a SHA-256 digest rendered as
//! `sha256-` followed by 64 lowercase hex chars (71 bytes total). The
//! shape surfaces in several places: the manifest `:wasm-sha256`
//! self-stamp, the `(use-plugin … :hash …)` consumer pin, the lockfile
//! `:*-hash` fields, and the `sjon plugin hash` CLI output. Before this
//! module the length rule + lowercase-hex alphabet were re-encoded in
//! `ManifestLoader` and `Host` independently (a documented "mirror"),
//! and the `sha256-<hex>` render was hand-rolled per site. This leaf is
//! the single source of truth: the well-formedness predicate, the
//! parse-to-bytes, and the render-from-digest all live here.
//!
//! Leaf module — imports only `std`. It stays outside the SJON module
//! graph so anything (including the read-only wasm closure guarded by
//! `audit-wasm-imports`) can adopt it without pulling in a dependency.

const std = @import("std");

pub const Sha256 = std.crypto.hash.sha2.Sha256;

/// Canonical prefix. A well-formed pin is `PREFIX ++ <HEX_LEN lowercase hex>`.
pub const PREFIX = "sha256-";

/// Hex-digit count for a 32-byte digest.
pub const HEX_LEN: usize = Sha256.digest_length * 2;

/// Total byte length of a well-formed pin (`sha256-` + 64 hex = 71).
pub const PIN_LEN: usize = PREFIX.len + HEX_LEN;

comptime {
    // Layout pin: the concrete total the format-string sites assume.
    std.debug.assert(PIN_LEN == 71);
    std.debug.assert(HEX_LEN == 64);
}

/// True when `pin` is exactly `sha256-<64 lowercase hex>`. Rejects the
/// wrong prefix, wrong length, and any non-lowercase-hex character.
/// Pure — no allocation, no side effects.
pub fn isWellFormed(pin: []const u8) bool {
    if (pin.len != PIN_LEN) return false;
    if (!std.mem.startsWith(u8, pin, PREFIX)) return false;
    for (pin[PREFIX.len..]) |c| {
        const is_lower_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!is_lower_hex) return false;
    }
    return true;
}

/// Parse a canonical pin into its 32 raw digest bytes, or null on any
/// rule violation (wrong prefix, wrong length, non-hex or uppercase-hex
/// character). `hexToBytes` cannot fail once `isWellFormed` passes (even
/// length, all-lowercase-hex) — the `catch` keeps the function total.
pub fn parse(pin: []const u8) ?[Sha256.digest_length]u8 {
    if (!isWellFormed(pin)) return null;
    var bytes: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, pin[PREFIX.len..]) catch return null;
    return bytes;
}

/// Render a raw digest as the canonical pin. Allocation-free: returns
/// the fixed-size `[PIN_LEN]u8` by value; callers slice (`&result`) or
/// dupe into an arena as needed.
pub fn renderDigest(digest: [Sha256.digest_length]u8) [PIN_LEN]u8 {
    var out: [PIN_LEN]u8 = undefined;
    @memcpy(out[0..PREFIX.len], PREFIX);
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(out[PREFIX.len..], &hex);
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "isWellFormed accepts canonical, rejects malformed" {
    try testing.expect(isWellFormed("sha256-0000000000000000000000000000000000000000000000000000000000000000"));
    try testing.expect(isWellFormed("sha256-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
    // Too short.
    try testing.expect(!isWellFormed("sha256-short"));
    // Wrong prefix.
    try testing.expect(!isWellFormed("md5-0000000000000000000000000000000000000000000000000000000000000000"));
    // Uppercase hex rejected — canonical pin is lowercase.
    try testing.expect(!isWellFormed("sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"));
    // Non-hex character in the digest.
    try testing.expect(!isWellFormed("sha256-000000000000000000000000000000000000000000000000000000000000000g"));
    // One char too long.
    try testing.expect(!isWellFormed("sha256-00000000000000000000000000000000000000000000000000000000000000000"));
    // Empty / prefix-only.
    try testing.expect(!isWellFormed(""));
    try testing.expect(!isWellFormed("sha256-"));
}

test "parse returns 32 raw bytes for a canonical pin" {
    const bytes = parse("sha256-" ++ ("ab" ** 32)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 32), bytes.len);
    for (bytes) |b| try testing.expectEqual(@as(u8, 0xab), b);
    // Malformed pins parse to null (isWellFormed gate).
    try testing.expect(parse("sha256-short") == null);
    try testing.expect(parse("SHA256-0000000000000000000000000000000000000000000000000000000000000000") == null);
}

test "renderDigest produces the canonical pin" {
    const digest = [_]u8{0xab} ** Sha256.digest_length;
    const pin = renderDigest(digest);
    try testing.expectEqualStrings("sha256-" ++ ("ab" ** 32), &pin);
}

test "parse and renderDigest round-trip" {
    // digest → pin → digest
    var digest: [Sha256.digest_length]u8 = undefined;
    for (&digest, 0..) |*b, i| b.* = @intCast(i);
    const pin = renderDigest(digest);
    const parsed = parse(&pin) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &digest, &parsed);

    // pin → digest → pin
    const canonical = "sha256-" ++ ("3c" ** 32);
    const back = renderDigest(parse(canonical) orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings(canonical, &back);
}
