const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn fileUriToPath(arena: Allocator, uri: []const u8) Allocator.Error!?[]const u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return null;
    var rest = uri["file://".len..];
    if (rest.len == 0) return null;
    if (rest[0] != '/') {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        rest = rest[slash..];
    }

    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, rest.len);
    var i: usize = 0;
    while (i < rest.len) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            const hi = hexDigit(rest[i + 1]);
            const lo = hexDigit(rest[i + 2]);
            if (hi == null or lo == null) {
                try out.append(arena, rest[i]);
                i += 1;
                continue;
            }
            try out.append(arena, (@as(u8, hi.?) << 4) | @as(u8, lo.?));
            i += 3;
        } else {
            try out.append(arena, rest[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(arena);
}

fn hexDigit(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

const testing = std.testing;
