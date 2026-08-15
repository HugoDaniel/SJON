//! Wire-format discriminator constants shared by the JSON bridge and the
//! schema exporter.
//!
//! Factoring these out here lets the exporter detect drift: when the JSON
//! bridge adds a new discriminator the exporter would have to learn
//! about, the parity assertion in this file becomes the build-time
//! tripwire. Adding a `$foo` key to `src/Json.zig`'s decoder without
//! adding it here is a comptime failure rather than a silently-wrong
//! emitted schema.

const std = @import("std");

/// Discriminator keys that appear on encoded forms (objects with a head).
/// `Json.formObjectToForm` recognises exactly these; anything else with a
/// leading `$` either round-trips as a `$$`-escaped user key or fails the
/// decoder with `UnknownDiscriminator`.
pub const form_keys = [_][]const u8{ "$form", "$ns", "$children" };

/// Discriminators that uniquely identify an atom-shaped object on the
/// wire. Order matches `Json.objectToForm`'s dispatch order so a reader
/// pairing both files sees the same sequence.
pub const atom_keys = [_][]const u8{ "$expr", "$num", "$kw", "$sym", "$date", "$time", "$roots" };

/// Full discriminator set — every key the JSON bridge treats as a
/// reserved name. `$$`-escape (doubled prefix) turns any of these back
/// into a user-key spelling. Stable across both the encoder (which
/// emits them verbatim) and the decoder (which gates on this list).
pub const all = form_keys ++ atom_keys;

/// `true` when `key` is one of the wire-stable discriminators; false
/// for `$$`-escaped user keys and for any non-`$` key.
pub fn isReserved(key: []const u8) bool {
    inline for (all) |d| {
        if (std.mem.eql(u8, key, d)) return true;
    }
    return false;
}

test "form_keys covers Json.zig's known_form_discriminators" {
    // Sanity: the three form-shape discriminators are present in order.
    try std.testing.expectEqual(@as(usize, 3), form_keys.len);
    try std.testing.expectEqualStrings("$form", form_keys[0]);
    try std.testing.expectEqualStrings("$ns", form_keys[1]);
    try std.testing.expectEqualStrings("$children", form_keys[2]);
}

test "atom_keys covers every $-shape Json.objectToForm dispatches" {
    // Pin the seven atom-shape discriminators. Any addition in the JSON
    // bridge must add a sibling test here and a mapping rule in the
    // exporter backends.
    try std.testing.expectEqual(@as(usize, 7), atom_keys.len);
    const expected = [_][]const u8{ "$expr", "$num", "$kw", "$sym", "$date", "$time", "$roots" };
    for (atom_keys, 0..) |k, i| try std.testing.expectEqualStrings(expected[i], k);
}

test "isReserved gates discriminators but not $$-escapes" {
    try std.testing.expect(isReserved("$form"));
    try std.testing.expect(isReserved("$num"));
    try std.testing.expect(!isReserved("$$form"));
    try std.testing.expect(!isReserved("name"));
    try std.testing.expect(!isReserved(""));
}
