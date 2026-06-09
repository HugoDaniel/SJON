const std = @import("std");
const Plugin = @import("Plugin.zig");

pub const Format = Plugin.ValueKind.StringBounds.Format;

pub fn check(format: Format, text: []const u8) bool {
    return switch (format) {
        .email => checkEmail(text),
        .uri => checkUri(text),
        .path => checkPath(text),
        .uuid => checkUuid(text),
        .semver => checkSemver(text),
    };
}

pub fn fromName(text: []const u8) ?Format {
    if (std.mem.eql(u8, text, "email")) return .email;
    if (std.mem.eql(u8, text, "uri")) return .uri;
    if (std.mem.eql(u8, text, "path")) return .path;
    if (std.mem.eql(u8, text, "uuid")) return .uuid;
    if (std.mem.eql(u8, text, "semver")) return .semver;
    return null;
}

pub fn checkEmail(text: []const u8) bool {
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

pub fn checkUri(text: []const u8) bool {
    if (text.len < 2) return false;
    if (!std.ascii.isAlphabetic(text[0])) return false;
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == ':') break;
        const ok = std.ascii.isAlphanumeric(c) or c == '+' or c == '.' or c == '-';
        if (!ok) return false;
    }
    if (i >= text.len) return false;
    if (i + 1 >= text.len) return false;
    return true;
}

pub fn checkPath(text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.ascii.isWhitespace(text[0])) return false;
    for (text) |c| {
        if (c == 0 or c == '\n') return false;
    }
    return true;
}

pub fn checkUuid(text: []const u8) bool {
    if (text.len != 36) return false;
    for (text, 0..) |c, i| {
        switch (i) {
            8, 13, 18, 23 => if (c != '-') return false,
            else => if (!std.ascii.isHex(c)) return false,
        }
    }
    return true;
}

pub fn checkSemver(text: []const u8) bool {
    var rest = text;

    var dot: usize = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
    if (!isNumericIdent(rest[0..dot])) return false;
    rest = rest[dot + 1 ..];
    dot = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
    if (!isNumericIdent(rest[0..dot])) return false;
    rest = rest[dot + 1 ..];

    var patch_end: usize = rest.len;
    for (rest, 0..) |c, i| if (c == '-' or c == '+') {
        patch_end = i;
        break;
    };
    if (!isNumericIdent(rest[0..patch_end])) return false;
    rest = rest[patch_end..];

    if (rest.len > 0 and rest[0] == '-') {
        rest = rest[1..];
        const plus = std.mem.indexOfScalar(u8, rest, '+') orelse rest.len;
        if (!isValidPreRelease(rest[0..plus])) return false;
        rest = rest[plus..];
    }

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

const testing = std.testing;
