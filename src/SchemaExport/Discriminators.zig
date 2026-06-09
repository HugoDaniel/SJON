const std = @import("std");

pub const form_keys = [_][]const u8{ "$form", "$ns", "$children" };

pub const atom_keys = [_][]const u8{ "$expr", "$num", "$kw", "$sym", "$date", "$time", "$roots" };

pub const all = form_keys ++ atom_keys;

pub fn isReserved(key: []const u8) bool {
    inline for (all) |d| {
        if (std.mem.eql(u8, key, d)) return true;
    }
    return false;
}
