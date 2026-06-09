const std = @import("std");
const Ast = @import("Ast.zig");
const Resolver = @import("Resolver.zig");
const common = @import("wasm_common.zig");

const Allocator = std.mem.Allocator;
const wasm_allocator = std.heap.wasm_allocator;

extern "env" fn sjon_host_resolve(ref_ptr: u32, ref_len: u32) callconv(.c) ?[*]u8;

const ctx_marker: u8 = 0;

pub fn build() Resolver.Resolver {
    return .{ .ctx = @ptrCast(@constCast(&ctx_marker)), .resolve = resolveCallback };
}

fn resolveCallback(
    ctx: *anyopaque,
    ref: Resolver.Reference,
    arena: Allocator,
) Allocator.Error!Resolver.Resolution {
    _ = ctx;

    const ref_json = try referenceToJson(arena, ref);
    const ref_buf = try wasm_allocator.alloc(u8, ref_json.len);
    defer wasm_allocator.free(ref_buf);
    @memcpy(ref_buf, ref_json);

    const result_ptr = sjon_host_resolve(@intFromPtr(ref_buf.ptr), @intCast(ref_buf.len)) orelse {
        return failure(arena, .unresolved_plugin, ref, "JS resolver returned null pointer");
    };

    var header: [common.HEADER_SIZE]u8 = undefined;
    @memcpy(&header, result_ptr[0..common.HEADER_SIZE]);
    const ok = std.mem.readInt(u32, header[0..4], .little);
    const len = std.mem.readInt(u32, header[4..8], .little);
    const total = @as(usize, common.HEADER_SIZE) + @as(usize, len);
    defer wasm_allocator.free(result_ptr[0..total]);

    const payload = result_ptr[common.HEADER_SIZE..total];

    if (ok != 1) {
        return failure(arena, .unresolved_plugin, ref, payload);
    }

    return parseResolution(arena, payload, ref);
}

fn referenceToJson(arena: Allocator, ref: Resolver.Reference) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "{\"name\":");
    try common.appendJsonString(&buf, arena, ref.name);
    try buf.appendSlice(arena, ",\"explicitPath\":");
    if (ref.explicit_path) |p| {
        try common.appendJsonString(&buf, arena, p);
    } else {
        try buf.appendSlice(arena, "null");
    }
    try buf.appendSlice(arena, ",\"version\":");
    if (ref.version) |v| {
        try common.appendJsonString(&buf, arena, v);
    } else {
        try buf.appendSlice(arena, "null");
    }
    try buf.appendSlice(arena, ",\"hash\":");
    if (ref.hash) |h| {
        try common.appendJsonString(&buf, arena, h);
    } else {
        try buf.appendSlice(arena, "null");
    }
    try buf.appendSlice(arena, ",\"span\":{\"start\":");
    try common.appendUint(&buf, arena, ref.span.start);
    try buf.appendSlice(arena, ",\"end\":");
    try common.appendUint(&buf, arena, ref.span.end);
    try buf.appendSlice(arena, "}}");
    return try buf.toOwnedSlice(arena);
}

fn parseResolution(
    arena: Allocator,
    payload: []const u8,
    ref: Resolver.Reference,
) Allocator.Error!Resolver.Resolution {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, payload, .{}) catch {
        return failure(arena, .unresolved_plugin, ref, "JS resolver returned malformed JSON Resolution");
    };
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return failure(arena, .unresolved_plugin, ref, "JS resolver Resolution is not an object"),
    };
    const kind_value = obj.get("kind") orelse {
        return failure(arena, .unresolved_plugin, ref, "JS resolver Resolution missing `kind`");
    };
    const kind = switch (kind_value) {
        .string => |s| s,
        else => return failure(arena, .unresolved_plugin, ref, "JS resolver Resolution `kind` is not a string"),
    };

    if (std.mem.eql(u8, kind, "manifest")) {
        const source_value = obj.get("source") orelse {
            return failure(arena, .unresolved_plugin, ref, "JS resolver `manifest` missing `source`");
        };
        const source_str = switch (source_value) {
            .string => |s| s,
            else => return failure(arena, .unresolved_plugin, ref, "JS resolver `manifest` `source` is not a string"),
        };
        var wasm_bytes: ?[]const u8 = null;
        if (obj.get("wasm")) |w| switch (w) {
            .null => {},
            .array => |arr| {
                const buf = try arena.alloc(u8, arr.items.len);
                for (arr.items, 0..) |item, i| switch (item) {
                    .integer => |n| {
                        if (n < 0 or n > 255) {
                            return failure(arena, .unresolved_plugin, ref, "JS resolver `manifest` `wasm` element out of u8 range");
                        }
                        buf[i] = @intCast(n);
                    },
                    else => return failure(arena, .unresolved_plugin, ref, "JS resolver `manifest` `wasm` element is not an integer"),
                };
                wasm_bytes = buf;
            },
            else => return failure(arena, .unresolved_plugin, ref, "JS resolver `manifest` `wasm` must be null or a u8 array"),
        };
        return .{ .manifest = .{
            .source = try arena.dupe(u8, source_str),
            .wasm = wasm_bytes,
        } };
    }

    if (std.mem.eql(u8, kind, "failure")) {
        const code_value = obj.get("code") orelse {
            return failure(arena, .unresolved_plugin, ref, "JS resolver `failure` missing `code`");
        };
        const code_str = switch (code_value) {
            .string => |s| s,
            else => return failure(arena, .unresolved_plugin, ref, "JS resolver `failure` `code` is not a string"),
        };
        const detail_value = obj.get("detail") orelse {
            return failure(arena, .unresolved_plugin, ref, "JS resolver `failure` missing `detail`");
        };
        const detail_str = switch (detail_value) {
            .string => |s| s,
            else => return failure(arena, .unresolved_plugin, ref, "JS resolver `failure` `detail` is not a string"),
        };
        return .{ .failure = .{
            .code = parseFailureCode(code_str),
            .detail = try arena.dupe(u8, detail_str),
        } };
    }

    return failure(arena, .unresolved_plugin, ref, "JS resolver Resolution has unknown `kind`");
}

fn failure(
    arena: Allocator,
    code: Ast.Diagnostic.Code,
    ref: Resolver.Reference,
    detail: []const u8,
) Allocator.Error!Resolver.Resolution {
    const message = try std.fmt.allocPrint(
        arena,
        "{s} for `(use-plugin \"{s}\" …)`",
        .{ detail, ref.name },
    );
    return .{ .failure = .{ .code = code, .detail = message } };
}

fn parseFailureCode(s: []const u8) Ast.Diagnostic.Code {
    if (std.mem.eql(u8, s, "plugin_version_mismatch")) return .plugin_version_mismatch;
    if (std.mem.eql(u8, s, "plugin_hash_mismatch")) return .plugin_hash_mismatch;
    if (std.mem.eql(u8, s, "plugin_abi_mismatch")) return .plugin_abi_mismatch;
    if (std.mem.eql(u8, s, "plugin_export_missing")) return .plugin_export_missing;
    if (std.mem.eql(u8, s, "plugin_import_forbidden")) return .plugin_import_forbidden;
    return .unresolved_plugin;
}
