const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Expr = @import("Expr.zig");
const Plugin = @import("Plugin.zig");
const PluginValueCodec = @import("PluginValueCodec.zig");

const Allocator = std.mem.Allocator;
const wasm_allocator = std.heap.wasm_allocator;

const is_wasm32 = builtin.target.cpu.arch == .wasm32;
const native_plugin_exec = !is_wasm32 and build_options.plugin_exec;

const PluginRuntime = if (native_plugin_exec) @import("PluginRuntime.zig") else opaque {};

const imports = if (is_wasm32) struct {
    pub extern "env" fn sjon_host_invoke_plugin(req_ptr: u32, req_len: u32) callconv(.c) ?[*]u8;
} else struct {};

pub const TRAP_CODE = "_internal_trap";
pub const ALLOC_CODE = "_alloc";

pub const LastFailure = struct {
    code_buf: [128]u8 = undefined,
    detail_buf: [512]u8 = undefined,
    code_len: usize = 0,
    detail_len: usize = 0,

    pub fn code(self: *const LastFailure) []const u8 {
        return self.code_buf[0..self.code_len];
    }

    pub fn detail(self: *const LastFailure) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }

    pub fn reset(self: *LastFailure) void {
        self.code_len = 0;
        self.detail_len = 0;
    }
};

pub var last_failure: LastFailure = .{};

fn recordFailure(code: []const u8, detail: []const u8) void {
    const code_n = @min(code.len, last_failure.code_buf.len);
    @memcpy(last_failure.code_buf[0..code_n], code[0..code_n]);
    last_failure.code_len = code_n;
    const detail_n = @min(detail.len, last_failure.detail_buf.len);
    @memcpy(last_failure.detail_buf[0..detail_n], detail[0..detail_n]);
    last_failure.detail_len = detail_n;
}

pub fn lastFailure() *const LastFailure {
    return &last_failure;
}

pub fn invoke(
    a: Allocator,
    runtime: ?*anyopaque,
    plugin_name: []const u8,
    export_name: []const u8,
    declared_result: ?Plugin.ValueType,
    args: []const Expr.Value,
) Expr.Error!Expr.Value {
    if (comptime is_wasm32) {
        return invokeViaHostImport(a, plugin_name, export_name, declared_result, args);
    }
    if (comptime !native_plugin_exec) {
        return error.PluginFuncNotImplemented;
    }
    const rt_opaque = runtime orelse return error.PluginFuncNotImplemented;
    const rt: *PluginRuntime = @ptrCast(@alignCast(rt_opaque));
    return invokeViaNativeRuntime(a, rt, plugin_name, export_name, declared_result, args);
}

fn invokeViaHostImport(
    a: Allocator,
    plugin_name: []const u8,
    export_name: []const u8,
    declared_result: ?Plugin.ValueType,
    args: []const Expr.Value,
) Expr.Error!Expr.Value {
    last_failure.reset();

    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(a);
    try appendU32(a, &request, @intCast(plugin_name.len));
    try request.appendSlice(a, plugin_name);
    try appendU32(a, &request, @intCast(export_name.len));
    try request.appendSlice(a, export_name);
    PluginValueCodec.encodeArgs(a, &request, args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    const req_buf = try wasm_allocator.alloc(u8, request.items.len);
    defer wasm_allocator.free(req_buf);
    @memcpy(req_buf, request.items);

    const result_ptr = imports.sjon_host_invoke_plugin(
        @intFromPtr(req_buf.ptr),
        @intCast(req_buf.len),
    ) orelse {
        recordFailure(ALLOC_CODE, "host invoker returned null pointer");
        return error.PluginFuncAllocFailed;
    };

    var header: [PluginValueCodec.HEADER_SIZE]u8 = undefined;
    @memcpy(&header, result_ptr[0..PluginValueCodec.HEADER_SIZE]);
    const ok = std.mem.readInt(u32, header[0..4], .little);
    const len = std.mem.readInt(u32, header[4..8], .little);
    const total = @as(usize, PluginValueCodec.HEADER_SIZE) + @as(usize, len);
    defer wasm_allocator.free(result_ptr[0..total]);

    const payload = result_ptr[PluginValueCodec.HEADER_SIZE..total];
    return decodeResponseFrame(a, ok, payload, declared_result);
}

fn invokeViaNativeRuntime(
    a: Allocator,
    rt: *PluginRuntime,
    plugin_name: []const u8,
    export_name: []const u8,
    declared_result: ?Plugin.ValueType,
    args: []const Expr.Value,
) Expr.Error!Expr.Value {
    last_failure.reset();

    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(a);
    PluginValueCodec.encodeArgs(a, &request, args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    const frame = rt.invoke(a, plugin_name, export_name, request.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Trap => {
            recordFailure(TRAP_CODE, rt.lastInvokeDetail());
            return error.PluginFuncTrapped;
        },
        error.AllocFailed => {
            recordFailure(ALLOC_CODE, rt.lastInvokeDetail());
            return error.PluginFuncAllocFailed;
        },
    };
    defer a.free(frame);

    if (frame.len < PluginValueCodec.HEADER_SIZE) {
        recordFailure("malformed_value_frame", "frame too short for header");
        return error.PluginFuncFailed;
    }
    const ok = std.mem.readInt(u32, frame[0..4], .little);
    const len = std.mem.readInt(u32, frame[4..8], .little);
    if (frame.len < @as(usize, PluginValueCodec.HEADER_SIZE) + @as(usize, len)) {
        recordFailure("malformed_value_frame", "frame truncated");
        return error.PluginFuncFailed;
    }
    const payload = frame[PluginValueCodec.HEADER_SIZE..][0..len];
    return decodeResponseFrame(a, ok, payload, declared_result);
}

fn decodeResponseFrame(
    a: Allocator,
    ok: u32,
    payload: []const u8,
    declared_result: ?Plugin.ValueType,
) Expr.Error!Expr.Value {
    if (ok != 1) {
        const structured = PluginValueCodec.decodeStructuredError(a, payload) catch {
            recordFailure("malformed_error_frame", "host returned malformed structured-error frame");
            return error.PluginFuncFailed;
        };
        recordFailure(structured.code, structured.detail);
        if (std.mem.eql(u8, structured.code, TRAP_CODE)) return error.PluginFuncTrapped;
        if (std.mem.eql(u8, structured.code, ALLOC_CODE)) return error.PluginFuncAllocFailed;
        return error.PluginFuncFailed;
    }

    const decoded = PluginValueCodec.decodeValue(a, payload) catch |err| {
        const msg = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTag => "value frame has invalid tag",
            error.InvalidBoolean => "value frame has invalid boolean byte",
            error.UnexpectedEof => "value frame truncated",
            error.DepthExceeded => "value frame exceeds nested-vector depth limit",
        };
        recordFailure("malformed_value_frame", msg);
        return error.PluginFuncFailed;
    };

    if (declared_result) |rt| {
        if (!matchesType(decoded.value, rt)) {
            recordResultTypeMismatch(rt, decoded.value);
            return error.PluginFuncResultType;
        }
    }

    return decoded.value;
}

fn appendU32(a: Allocator, buf: *std.ArrayList(u8), n: u32) Allocator.Error!void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, n, .little);
    try buf.appendSlice(a, &b);
}

fn matchesType(value: Expr.Value, expected: Plugin.ValueType) bool {
    return switch (expected) {
        .any => true,
        .number => value == .number,
        .string => value == .string,
        .symbol => value == .keyword,
        .boolean => value == .boolean,
        .nil => value == .nil,
        .vector => value == .vector,
        .form, .expr, .named => false,
    };
}

fn typeLabel(t: Plugin.ValueType) []const u8 {
    return switch (t) {
        .any => "any",
        .number => "number",
        .string => "string",
        .symbol => "symbol",
        .boolean => "boolean",
        .nil => "nil",
        .vector => "vector",
        .form => "form",
        .expr => "expr",
        .named => |n| n.name,
    };
}

fn valueLabel(v: Expr.Value) []const u8 {
    return switch (v) {
        .number, .integer_i64, .integer_u64 => "number",
        .boolean => "boolean",
        .nil => "nil",
        .date => "date",
        .time => "time",
        .string => "string",
        .keyword => "symbol",
        .vector => "vector",
        .form => "form",
    };
}

fn recordResultTypeMismatch(expected: Plugin.ValueType, actual: Expr.Value) void {
    const expected_label = typeLabel(expected);
    const actual_label = valueLabel(actual);
    var detail_buf: [512]u8 = undefined;
    const detail = std.fmt.bufPrint(
        &detail_buf,
        "plugin returned {s} but :result declared {s}",
        .{ actual_label, expected_label },
    ) catch detail_buf[0..0];
    recordFailure("type", detail);
}
