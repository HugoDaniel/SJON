const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MAX_DISTANCE: u16 = 3;

pub const Suggestion = struct {
    name: []const u8,
    distance: u16,
};

pub fn suggest(
    arena: Allocator,
    needle: []const u8,
    candidates: []const []const u8,
    max_results: usize,
) Allocator.Error![]Suggestion {
    if (candidates.len == 0 or max_results == 0) return &.{};
    var scored: std.ArrayList(Suggestion) = .empty;
    for (candidates) |c| {
        if (std.mem.eql(u8, c, needle)) continue;
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

pub fn distance(a: []const u8, b: []const u8) u16 {
    if (a.len == 0) return @intCast(b.len);
    if (b.len == 0) return @intCast(a.len);

    const cap = @min(@max(a.len, b.len), 64);
    if (a.len > cap or b.len > cap) {
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

const testing = std.testing;
