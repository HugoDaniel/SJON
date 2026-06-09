const std = @import("std");
const Ast = @import("Ast.zig");
const Schema = @import("Schema.zig");
const Plugin = @import("Plugin.zig");
const Validator = @import("Validator.zig");
const Expr = @import("Expr.zig");
const BinaryCursor = @import("BinaryCursor.zig");
const core = @import("plugins/core.zig");
const common = @import("wasm_common.zig");
const version = @import("version.zig").string;

const wasm_allocator = std.heap.wasm_allocator;
const core_schema: Schema.Schema = Schema.Schema.init(&.{core.plugin});

export fn sjon_alloc(len: u32) callconv(.c) ?[*]u8 {
    if (len == 0) return null;
    const slice = wasm_allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn sjon_free(ptr: [*]u8, len: u32) callconv(.c) void {
    if (len == 0) return;
    wasm_allocator.free(ptr[0..len]);
}

export fn sjon_describe() callconv(.c) ?[*]u8 {
    const text =
        \\{"name":"sjon-binary","version":"
    ++ version ++
        \\","exports":["validate_binary","eval_expr_binary","describe"],"plugins":["core"]}
    ;
    return common.frame(wasm_allocator, true, text) catch null;
}

export fn sjon_validate_binary(bin_ptr: [*]const u8, bin_len: u32) callconv(.c) ?[*]u8 {
    return runValidateBinary(bin_ptr[0..bin_len]) catch |err| common.frameError(wasm_allocator, err) catch null;
}

export fn sjon_eval_expr_binary(bin_ptr: [*]const u8, bin_len: u32) callconv(.c) ?[*]u8 {
    return runEvalExprBinary(bin_ptr[0..bin_len]) catch |err| common.frameError(wasm_allocator, err) catch null;
}

fn runValidateBinary(bin_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var result = try Validator.validateBinary(wasm_allocator, bin_bytes, core_schema);
    defer result.deinit();

    const json_text = try common.validatorBinaryJson(a, result);
    return try common.frame(wasm_allocator, true, json_text);
}

fn runEvalExprBinary(bin_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const env: Expr.Env = .{};
    var result = try Expr.evalBinary(wasm_allocator, bin_bytes, &env, core_schema);
    defer result.deinit();

    const json_text = try common.valueToJson(a, result.value);
    return try common.frame(wasm_allocator, true, json_text);
}

comptime {
    _ = Ast;
    _ = Plugin;
    _ = BinaryCursor;
}
