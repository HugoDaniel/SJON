//! Dispatch `:impl "wasm:<export>"` plugin functions across all three
//! host shapes:
//!
//!   * **wasm32 build (`sjon.wasm` running under Web / Rust hosts)** —
//!     uses the `env.sjon_host_invoke_plugin` import so the host adapter
//!     (browser `WebAssembly.Instance`, Rust wasmtime) does the per-call
//!     alloc/copy/call/free dance against its own plugin pool.
//!   * **native Zig + `-Dplugin-exec=true` + non-null `runtime`** —
//!     dispatches into the local `PluginRuntime` (`src/PluginRuntime.zig`)
//!     which owns a wasmtime engine + per-plugin store via
//!     `src/runtimes/wasmtime.zig`. Activated by Host.zig in commit 5
//!     of the native-parity milestone.
//!   * **everything else** (native with the option off, or the option on
//!     but no runtime was constructed) — returns
//!     `error.PluginFuncNotImplemented`, matching the historical
//!     "Zig native stays declarative-only" behavior.
//!
//! Wire format of the request payload (wasm32 host import path):
//!
//!   [u32 plugin_name_len][plugin_name utf-8]
//!   [u32 export_name_len][export_name utf-8]
//!   [u32 args_count][value][value]…           (PluginValueCodec.encodeArgs)
//!
//! Wire format of the response in BOTH paths:
//!
//!   [u32 ok][u32 len][payload]
//!     ok=1 → payload is one `PluginValueCodec.decodeValue` value
//!     ok=0 → payload is `[u32 code_len][code][u32 detail_len][detail]`
//!            with synthetic `_internal_trap` / `_alloc` codes
//!            distinguishing host-synthesized failures from plugin-
//!            reported `(code, detail)` pairs.
//!
//! The native path doesn't go through the wire protocol's "wrap plugin
//! name + export name" prefix (that prefix is only needed when the
//! wasm32 build needs to tell its host which plugin to dispatch into —
//! the native runtime can be passed the plugin name directly). Both
//! paths share the same response framing so the failure-decoding logic
//! is the same; only the call-site prefix and trap-mapping differ.
//!
//! Plugin instance lifetime is per-host-load (instances live as long as
//! the `SjonHost` / `sjon_host::SjonHost` / `Host` that loaded them).
//! Hot reload is out of scope for ABI v2 (see §19).

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

/// Whether this wasm artifact's embedder supplies the plugin-invoke
/// import. True for `sjon.wasm`, whose hosts (`hosts/web/SjonHost.ts`,
/// the Rust wasmtime host) provide it; false for `sjon-lsp.wasm`, which
/// the playground instantiates with **no imports at all**.
///
/// Declaring an unserviceable import is not a harmless extra symbol —
/// `WebAssembly.instantiate(mod, {})` throws on it, so an artifact that
/// declares one it cannot be given simply fails to load. When this is
/// false the wasm path stays declarative-only, exactly like a native
/// build without `-Dplugin-exec`.
const wasm_plugin_host = is_wasm32 and build_options.wasm_plugin_host;

/// Lazy import of the PluginRuntime — only resolved on native builds
/// that opted into executable-plugin support. Keeps the WASM build
/// from transitively linking libwasmtime.
const PluginRuntime = if (native_plugin_exec) @import("PluginRuntime.zig") else opaque {};

/// Host-supplied import. Returns a pointer to a framed buffer allocated
/// via `sjon_alloc`; this module frees it after read. Wrapped in a
/// conditional struct so native builds never declare an unresolved
/// external symbol.
const imports = if (wasm_plugin_host) struct {
    pub extern "env" fn sjon_host_invoke_plugin(req_ptr: u32, req_len: u32) callconv(.c) ?[*]u8;
} else struct {};

/// Synthetic error codes the host uses to disambiguate its own failures
/// from plugin-reported `(code, detail)` pairs. Leading underscore is
/// reserved per the spec (plugins MUST NOT emit codes starting with `_`).
pub const TRAP_CODE = "_internal_trap";
pub const ALLOC_CODE = "_alloc";

/// Captured structured-failure detail from the most recent invoke that
/// returned a `PluginFuncFailed` / `PluginFuncTrapped` / `PluginFuncResultType`
/// / `PluginFuncAllocFailed` error. `Expr.Error` is a closed enum and
/// can't carry payload data; host wrappers read this state when one of
/// those errors surfaces from `Expr.eval` to format the diagnostic.
///
/// Fixed-size buffers because (a) the storage outlives any per-call
/// arena, (b) bounded length keeps WASM memory predictable, (c) the
/// detail message is for human consumption — long enough is enough.
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

/// Read the most recently captured failure code/detail. Cleared at the
/// start of every `invoke` call.
pub fn lastFailure() *const LastFailure {
    return &last_failure;
}

/// Dispatch a `:impl "wasm:<export>"` plugin function. Routes to one of
/// the three paths documented in the module header — `runtime` is the
/// opaque `*PluginRuntime` pointer threaded through `Expr.eval` from
/// the host (null when the host didn't construct one or when the build
/// has `plugin_exec=false`).
pub fn invoke(
    a: Allocator,
    runtime: ?*anyopaque,
    plugin_name: []const u8,
    export_name: []const u8,
    declared_result: ?Plugin.ValueType,
    args: []const Expr.Value,
) Expr.Error!Expr.Value {
    if (comptime is_wasm32) {
        // WASM build: hand off to the host import. The wasm32 path
        // ignores `runtime` (host owns its own plugin pool) — Zig
        // doesn't flag unused function parameters so no explicit
        // discard needed.
        //
        // Written as an `if` *expression* so the untaken branch is never
        // analyzed: an early `return` guard would leave the call below
        // reachable to the compiler, which is enough to emit the extern
        // and put the import back in an artifact that cannot service it.
        return if (comptime wasm_plugin_host)
            invokeViaHostImport(a, plugin_name, export_name, declared_result, args)
        else
            error.PluginFuncNotImplemented;
    }
    if (comptime !native_plugin_exec) {
        // Native build without `-Dplugin-exec`: stay declarative-only.
        return error.PluginFuncNotImplemented;
    }
    // Native build with `-Dplugin-exec=true`: dispatch through the
    // PluginRuntime if the host gave us one. A null runtime here means
    // either (a) the host hasn't wired up the runtime yet (commit 4)
    // or (b) the test/CLI path bypassed the host plumbing — in either
    // case we keep the historical "declarative-only" behavior.
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
        // A plugin arg nested past the codec cap fails gracefully rather
        // than overflowing the host stack in encodeValue.
        error.DepthExceeded => return error.DepthExceeded,
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

/// Native runtime dispatch. Encodes args with the existing wire codec,
/// calls `PluginRuntime.invoke`, and feeds the framed response through
/// the same `decodeResponseFrame` helper the wasm32 path uses — wire
/// format is identical because the runtime mirrors the §11 sequence.
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
        // A plugin arg nested past the codec cap fails gracefully rather
        // than overflowing the host stack in encodeValue.
        error.DepthExceeded => return error.DepthExceeded,
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

/// Common post-call decoding: ok=0 → structured-error (with synthetic
/// `_internal_trap` / `_alloc` codes for host-synthesized failures);
/// ok=1 → decode the value and check `declared_result`. Identical wire
/// format means the native and wasm32 paths share this tail.
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
        // .form / .expr are AST-level types and cannot appear as runtime
        // Expr.Value variants; .named refers to a plugin-defined value
        // kind which the codec can't produce either. A manifest declaring
        // any of these as :result is a static error; here we reject the
        // mismatch so the user sees a clear plugin_func_result_type.
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
