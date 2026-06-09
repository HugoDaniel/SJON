const std = @import("std");

pub fn match(pattern: []const u8, path: []const u8) bool {
    return matchInner(pattern, path);
}

fn matchInner(pattern: []const u8, path: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    while (pi < pattern.len) {
        const c = pattern[pi];

        if (c == '*' and pi + 1 < pattern.len and pattern[pi + 1] == '*') {
            pi += 2;
            if (pi < pattern.len and pattern[pi] == '/') pi += 1;
            const rest = pattern[pi..];
            if (rest.len == 0) return true;
            var k: usize = si;
            while (k <= path.len) : (k += 1) {
                if (matchInner(rest, path[k..])) return true;
            }
            return false;
        }

        if (c == '*') {
            pi += 1;
            const rest = pattern[pi..];
            if (rest.len == 0) {
                return std.mem.indexOfScalar(u8, path[si..], '/') == null;
            }
            var k: usize = si;
            while (k <= path.len) : (k += 1) {
                if (k > si and path[k - 1] == '/') return false;
                if (matchInner(rest, path[k..])) return true;
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
            const close = std.mem.indexOfScalarPos(u8, pattern, pi + 1, '}') orelse {
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
                if (matchInnerSpliced(branch, rest, path[si..])) return true;
                if (next_comma == branches.len) break;
                bi = next_comma + 1;
            }
            return false;
        }

        if (si >= path.len or path[si] != c) return false;
        pi += 1;
        si += 1;
    }
    return si == path.len;
}

fn matchInnerSpliced(branch: []const u8, rest: []const u8, path: []const u8) bool {
    if (!startsWithLiteral(branch, path)) {
        var k: usize = 0;
        while (k <= path.len) : (k += 1) {
            if (matchInner(branch, path[0..k]) and matchInner(rest, path[k..])) return true;
        }
        return false;
    }
    return matchInner(rest, path[branch.len..]);
}

fn startsWithLiteral(lit: []const u8, path: []const u8) bool {
    for (lit) |c| {
        if (c == '*' or c == '?' or c == '{') return false;
    }
    return std.mem.startsWith(u8, path, lit);
}

const testing = std.testing;
