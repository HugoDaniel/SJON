const std = @import("std");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const wasmtime = @import("runtimes/wasmtime.zig");

comptime {
    std.debug.assert(build_options.plugin_exec);
}

pub const MAX_PLUGIN_RESULT_FRAME: usize = 16 * 1024 * 1024;

pub const PLUGIN_ABI_VERSION: u32 = 2;

pub const RegisterError = error{
    Rejected,
} || Allocator.Error;

pub const InvokeError = error{
    Trap,
    AllocFailed,
} || Allocator.Error;

pub const RegisterFailure = struct {
    code: Ast.Diagnostic.Code = .plugin_abi_mismatch,
    detail: []const u8 = "",
};

const Instance = struct {
    store: wasmtime.Store,
    instance: wasmtime.InstanceHandle,
    memory: wasmtime.MemoryHandle,
    alloc_func: wasmtime.FuncHandle,
    free_func: wasmtime.FuncHandle,
    exports: std.StringHashMapUnmanaged(wasmtime.FuncHandle),

    fn deinit(self: *Instance, gpa: Allocator) void {
        self.exports.deinit(gpa);
        self.store.deinit();
        self.* = undefined;
    }
};

const PluginRuntime = @This();

arena: std.heap.ArenaAllocator,
engine: wasmtime.Engine,
linker: wasmtime.Linker,
instances: std.StringHashMapUnmanaged(Instance) = .empty,
last_register_failure: RegisterFailure = .{},
last_invoke_detail_buf: [512]u8 = undefined,
last_invoke_detail_len: usize = 0,

pub fn init(gpa: Allocator) Allocator.Error!PluginRuntime {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var engine = wasmtime.Engine.init() catch return error.OutOfMemory;
    errdefer engine.deinit();
    const linker = wasmtime.Linker.init(engine) catch return error.OutOfMemory;
    return .{
        .arena = arena,
        .engine = engine,
        .linker = linker,
    };
}

pub fn deinit(self: *PluginRuntime, gpa: Allocator) void {
    var it = self.instances.iterator();
    while (it.next()) |entry| entry.value_ptr.deinit(gpa);
    self.instances.deinit(gpa);
    self.linker.deinit();
    self.engine.deinit();
    self.arena.deinit();
    self.* = undefined;
}

pub fn register(
    self: *PluginRuntime,
    gpa: Allocator,
    plugin_name: []const u8,
    bytes: []const u8,
    declared_exports: []const []const u8,
) RegisterError!void {
    self.last_register_failure = .{};

    var module = wasmtime.Module.compile(self.engine, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ModuleLoad => return self.rejectAbi(
            "plugin \"{s}\" failed to compile: {s}",
            .{ plugin_name, wasmtime.lastDetail() },
        ),
        else => unreachable,
    };
    defer module.deinit();

    var imports = module.imports(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return self.rejectAbi(
            "plugin \"{s}\" imports section is unreadable",
            .{plugin_name},
        ),
    };
    defer imports.deinit();
    if (imports.descs.len > 0) {
        const first = imports.descs[0];
        return self.rejectImport(
            "plugin \"{s}\" declares forbidden import `{s}.{s}` (v1 plugins MUST have an empty import set)",
            .{ plugin_name, first.module, first.name },
        );
    }

    var store = wasmtime.Store.init(self.engine) catch return error.OutOfMemory;
    errdefer store.deinit();
    const instance = self.linker.instantiate(store, module) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InstantiateFailed, error.InstantiateTrap => return self.rejectAbi(
            "plugin \"{s}\" failed to instantiate: {s}",
            .{ plugin_name, wasmtime.lastDetail() },
        ),
        else => unreachable,
    };

    const abi_func = wasmtime.requireFunc(store, instance, "sjon_plugin_abi_version", &.{}, &.{.i32}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MissingExport, error.WrongExternKind => return self.rejectMissing(
            "plugin \"{s}\" is missing the required `sjon_plugin_abi_version` export",
            .{plugin_name},
        ),
        error.SignatureMismatch => return self.rejectAbi(
            "plugin \"{s}\" export `sjon_plugin_abi_version` has the wrong signature; expected `() -> i32`",
            .{plugin_name},
        ),
        else => unreachable,
    };
    var abi_buf: [1]wasmtime.ValRaw = .{.{ .i32 = 0 }};
    wasmtime.callUnchecked(store, abi_func, &abi_buf, 0, 1) catch |err| switch (err) {
        error.Trap => return self.rejectAbi(
            "plugin \"{s}\" sjon_plugin_abi_version() trapped: {s}",
            .{ plugin_name, wasmtime.lastDetail() },
        ),
        error.SignatureMismatch => return self.rejectAbi(
            "plugin \"{s}\" sjon_plugin_abi_version() type error: {s}",
            .{ plugin_name, wasmtime.lastDetail() },
        ),
        else => unreachable,
    };
    const reported: u32 = @bitCast(abi_buf[0].i32);
    if (reported != PLUGIN_ABI_VERSION) {
        return self.rejectAbi(
            "plugin \"{s}\" reports ABI version {d}; host implements {d}",
            .{ plugin_name, reported, PLUGIN_ABI_VERSION },
        );
    }

    const alloc_func = wasmtime.requireFunc(store, instance, "sjon_plugin_alloc", &.{.i32}, &.{.i32}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MissingExport, error.WrongExternKind => return self.rejectMissing(
            "plugin \"{s}\" is missing the required `sjon_plugin_alloc` export",
            .{plugin_name},
        ),
        error.SignatureMismatch => return self.rejectAbi(
            "plugin \"{s}\" export `sjon_plugin_alloc` has the wrong signature; expected `(i32) -> i32`",
            .{plugin_name},
        ),
        else => unreachable,
    };
    const free_func = wasmtime.requireFunc(store, instance, "sjon_plugin_free", &.{ .i32, .i32 }, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MissingExport, error.WrongExternKind => return self.rejectMissing(
            "plugin \"{s}\" is missing the required `sjon_plugin_free` export",
            .{plugin_name},
        ),
        error.SignatureMismatch => return self.rejectAbi(
            "plugin \"{s}\" export `sjon_plugin_free` has the wrong signature; expected `(i32, i32) -> void`",
            .{plugin_name},
        ),
        else => unreachable,
    };
    const memory = wasmtime.requireMemory(store, instance, "memory") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MissingExport, error.WrongExternKind => return self.rejectMissing(
            "plugin \"{s}\" is missing the required `memory` export",
            .{plugin_name},
        ),
        else => unreachable,
    };

    var exports: std.StringHashMapUnmanaged(wasmtime.FuncHandle) = .empty;
    errdefer exports.deinit(gpa);
    const arena_a = self.arena.allocator();
    for (declared_exports) |export_name| {
        const func = wasmtime.requireFunc(store, instance, export_name, &.{ .i32, .i32 }, &.{.i32}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MissingExport, error.WrongExternKind => return self.rejectMissing(
                "plugin \"{s}\" manifest declares `:impl \"wasm:{s}\"` but the binary has no such export",
                .{ plugin_name, export_name },
            ),
            error.SignatureMismatch => return self.rejectAbi(
                "plugin \"{s}\" export `{s}` has the wrong signature; expected `(i32, i32) -> i32`",
                .{ plugin_name, export_name },
            ),
            else => unreachable,
        };
        const key = try arena_a.dupe(u8, export_name);
        try exports.put(gpa, key, func);
    }

    if (self.instances.contains(plugin_name)) {
        exports.deinit(gpa);
        store.deinit();
        return;
    }

    const plugin_key = try arena_a.dupe(u8, plugin_name);
    try self.instances.put(gpa, plugin_key, .{
        .store = store,
        .instance = instance,
        .memory = memory,
        .alloc_func = alloc_func,
        .free_func = free_func,
        .exports = exports,
    });
}

pub fn lastRegisterFailure(self: *const PluginRuntime) RegisterFailure {
    return self.last_register_failure;
}

fn rejectAbi(self: *PluginRuntime, comptime fmt: []const u8, args: anytype) RegisterError {
    const detail = std.fmt.allocPrint(self.arena.allocator(), fmt, args) catch return error.OutOfMemory;
    self.last_register_failure = .{ .code = .plugin_abi_mismatch, .detail = detail };
    return error.Rejected;
}
fn rejectMissing(self: *PluginRuntime, comptime fmt: []const u8, args: anytype) RegisterError {
    const detail = std.fmt.allocPrint(self.arena.allocator(), fmt, args) catch return error.OutOfMemory;
    self.last_register_failure = .{ .code = .plugin_export_missing, .detail = detail };
    return error.Rejected;
}
fn rejectImport(self: *PluginRuntime, comptime fmt: []const u8, args: anytype) RegisterError {
    const detail = std.fmt.allocPrint(self.arena.allocator(), fmt, args) catch return error.OutOfMemory;
    self.last_register_failure = .{ .code = .plugin_import_forbidden, .detail = detail };
    return error.Rejected;
}

pub fn invoke(
    self: *PluginRuntime,
    gpa: Allocator,
    plugin_name: []const u8,
    export_name: []const u8,
    args: []const u8,
) InvokeError![]u8 {
    self.last_invoke_detail_len = 0;

    const inst = self.instances.getPtr(plugin_name) orelse {
        return self.invokeFail("no instance for plugin \"{s}\" (was pre-flight skipped?)", .{plugin_name});
    };
    const export_fn = inst.exports.get(export_name) orelse {
        return self.invokeFail("plugin \"{s}\" has no export \"{s}\"", .{ plugin_name, export_name });
    };

    const args_alloc_len_usize: usize = @max(args.len, 1);
    if (args_alloc_len_usize > std.math.maxInt(u32)) {
        return self.invokeFail("args buffer is larger than u32 max", .{});
    }
    const args_alloc_len: u32 = @intCast(args_alloc_len_usize);

    var alloc_buf: [1]wasmtime.ValRaw = .{.{ .i32 = @bitCast(args_alloc_len) }};
    wasmtime.callUnchecked(inst.store, inst.alloc_func, &alloc_buf, 1, 1) catch |err| switch (err) {
        error.Trap => {
            _ = self.captureTrap("plugin sjon_plugin_alloc trapped: ");
            return error.Trap;
        },
        error.SignatureMismatch => unreachable,
        else => unreachable,
    };
    const args_ptr: u32 = @bitCast(alloc_buf[0].i32);
    if (args_ptr == 0) {
        return self.invokeFail("plugin sjon_plugin_alloc({d}) returned null", .{args_alloc_len});
    }

    if (args.len > 0) {
        wasmtime.memoryWrite(inst.store, inst.memory, @intCast(args_ptr), args) catch {
            self.callFree(inst, args_ptr, args_alloc_len);
            return self.invokeTrap("failed to write args into plugin memory (sjon_plugin_alloc returned an out-of-bounds pointer)", .{});
        };
    }

    var call_buf: [2]wasmtime.ValRaw = .{
        .{ .i32 = @bitCast(args_ptr) },
        .{ .i32 = @intCast(args.len) },
    };
    wasmtime.callUnchecked(inst.store, export_fn, &call_buf, 2, 1) catch |err| switch (err) {
        error.Trap => {
            const trap_detail = self.captureTrap("");
            _ = trap_detail;
            self.callFree(inst, args_ptr, args_alloc_len);
            return error.Trap;
        },
        error.SignatureMismatch => unreachable,
        else => unreachable,
    };
    const result_ptr: u32 = @bitCast(call_buf[0].i32);
    if (result_ptr == 0) {
        self.callFree(inst, args_ptr, args_alloc_len);
        return self.invokeFail("plugin export returned null pointer", .{});
    }

    var header_bytes: [8]u8 = undefined;
    wasmtime.memoryRead(inst.store, inst.memory, @intCast(result_ptr), &header_bytes) catch {
        self.callFree(inst, args_ptr, args_alloc_len);
        return self.invokeTrap("plugin export returned an out-of-bounds frame pointer", .{});
    };
    const len: usize = @intCast(std.mem.readInt(u32, header_bytes[4..8], .little));

    if (len > MAX_PLUGIN_RESULT_FRAME) {
        self.callFree(inst, args_ptr, args_alloc_len);
        return self.invokeFail(
            "plugin export returned a framed result of {d} bytes; host caps plugin frames at {d} bytes",
            .{ len, MAX_PLUGIN_RESULT_FRAME },
        );
    }

    self.callFree(inst, args_ptr, args_alloc_len);
    const out = try gpa.alloc(u8, 8 + len);
    errdefer gpa.free(out);
    @memcpy(out[0..8], &header_bytes);
    if (len > 0) {
        const payload_off: usize = @as(usize, @intCast(result_ptr)) + 8;
        wasmtime.memoryRead(inst.store, inst.memory, payload_off, out[8..]) catch {
            const frame_len: u32 = @intCast(8 + len);
            self.callFree(inst, result_ptr, frame_len);
            return self.invokeTrap("plugin export framed result payload extends past linear memory", .{});
        };
    }

    const frame_len: u32 = @intCast(8 + len);
    self.callFree(inst, result_ptr, frame_len);
    return out;
}

fn callFree(self: *PluginRuntime, inst: *Instance, ptr: u32, len: u32) void {
    _ = self;
    var buf: [2]wasmtime.ValRaw = .{
        .{ .i32 = @bitCast(ptr) },
        .{ .i32 = @bitCast(len) },
    };
    wasmtime.callUnchecked(inst.store, inst.free_func, &buf, 2, 0) catch {};
}

fn invokeFail(self: *PluginRuntime, comptime fmt: []const u8, args: anytype) InvokeError {
    const detail = std.fmt.bufPrint(&self.last_invoke_detail_buf, fmt, args) catch self.last_invoke_detail_buf[0..0];
    self.last_invoke_detail_len = detail.len;
    return error.AllocFailed;
}
fn invokeTrap(self: *PluginRuntime, comptime fmt: []const u8, args: anytype) InvokeError {
    const detail = std.fmt.bufPrint(&self.last_invoke_detail_buf, fmt, args) catch self.last_invoke_detail_buf[0..0];
    self.last_invoke_detail_len = detail.len;
    return error.Trap;
}

fn captureTrap(self: *PluginRuntime, prefix: []const u8) []const u8 {
    const wt = wasmtime.lastDetail();
    var w: usize = 0;
    const cap = self.last_invoke_detail_buf.len;
    const pfx_n = @min(prefix.len, cap);
    @memcpy(self.last_invoke_detail_buf[0..pfx_n], prefix[0..pfx_n]);
    w += pfx_n;
    const remaining = cap - w;
    const det_n = @min(wt.len, remaining);
    @memcpy(self.last_invoke_detail_buf[w..][0..det_n], wt[0..det_n]);
    w += det_n;
    self.last_invoke_detail_len = w;
    return self.last_invoke_detail_buf[0..w];
}

pub fn lastInvokeDetail(self: *const PluginRuntime) []const u8 {
    return self.last_invoke_detail_buf[0..self.last_invoke_detail_len];
}

const testing = std.testing;
const PluginValueCodec = @import("PluginValueCodec.zig");
const Expr = @import("Expr.zig");

fn readFixture(gpa: Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .unlimited);
}

const DOUBLE_PATH = "examples/plugins/double/plugin.wasm";
const ABI99_PATH = "conformance/cases/plugin-exec-abi-mismatch/manifests/shapes.wasm";
const FORBIDDEN_PATH = "conformance/cases/plugin-exec-import-forbidden/manifests/forbidden.wasm";
