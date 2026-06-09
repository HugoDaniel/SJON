const std = @import("std");

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Encoding = enum { @"utf-8", @"utf-16", @"utf-32" };

pub fn indexToPosition(source: []const u8, index: usize, encoding: Encoding) Position {
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    const stop = @min(index, source.len);
    while (i < stop) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    const line_slice = source[line_start..stop];
    const character: u32 = switch (encoding) {
        .@"utf-8" => @intCast(line_slice.len),
        .@"utf-16" => countUtf16CodeUnits(line_slice),
        .@"utf-32" => countCodepoints(line_slice),
    };
    return .{ .line = line, .character = character };
}

fn countUtf16CodeUnits(bytes: []const u8) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            n += 1;
            i += 1;
            continue;
        };
        if (i + len > bytes.len) break;
        const cp = std.unicode.utf8Decode(bytes[i .. i + len]) catch {
            n += 1;
            i += 1;
            continue;
        };
        n += if (cp >= 0x10000) @as(u32, 2) else 1;
        i += len;
    }
    return n;
}

fn countCodepoints(bytes: []const u8) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            n += 1;
            i += 1;
            continue;
        };
        i += len;
        n += 1;
    }
    return n;
}

pub fn positionToIndex(source: []const u8, position: Position, encoding: Encoding) usize {
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len and line < position.line) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    if (line < position.line) return source.len;

    const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
    const line_slice = source[line_start..line_end];
    const offset_in_line = nCodeUnitsToByteCount(line_slice, position.character, encoding);
    return line_start + offset_in_line;
}

fn nCodeUnitsToByteCount(bytes: []const u8, n: u32, encoding: Encoding) usize {
    return switch (encoding) {
        .@"utf-8" => @min(n, bytes.len),
        .@"utf-16" => utf16CodeUnitsToByteCount(bytes, n),
        .@"utf-32" => codepointsToByteCount(bytes, n),
    };
}

fn utf16CodeUnitsToByteCount(bytes: []const u8, n: u32) usize {
    var consumed: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len and consumed < n) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            consumed += 1;
            i += 1;
            continue;
        };
        if (i + len > bytes.len) break;
        const cp = std.unicode.utf8Decode(bytes[i .. i + len]) catch {
            consumed += 1;
            i += 1;
            continue;
        };
        const units: u32 = if (cp >= 0x10000) 2 else 1;
        if (consumed + units > n) break;
        consumed += units;
        i += len;
    }
    return i;
}

fn codepointsToByteCount(bytes: []const u8, n: u32) usize {
    var consumed: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len and consumed < n) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            consumed += 1;
            i += 1;
            continue;
        };
        if (i + len > bytes.len) break;
        consumed += 1;
        i += len;
    }
    return i;
}
