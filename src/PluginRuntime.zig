//! Native instance pool for executable WASM plugins. One per host load —
//! `Host.zig` owns a single `PluginRuntime` for the lifetime of a
//! `validateDocument` / `loadProject` call and uses it to instantiate
//! every `(use-plugin …)` whose resolver returns paired WASM bytes.
//!
//! Layers, top-down:
//!
//!   ┌────────────────────┐  emits plugin_func_* diagnostics
//!   │ Host.runEvalPass   │  / plugin_abi_mismatch, etc.
//!   └─────────┬──────────┘
//!             │ Expr.applyFunction → wasm_plugin_invoker.invoke
//!   ┌─────────▼──────────┐  per-call alloc/copy/call/copy/free
//!   │ PluginRuntime      │  (spec §11), pre-flight (spec §16)
//!   └─────────┬──────────┘
//!             │ Engine/Module/Linker/Store/Func/Memory
//!   ┌─────────▼──────────┐  thin extern "c" wrapper
//!   │ runtimes.wasmtime  │  over the wasmtime C API
//!   └────────────────────┘
//!
//! Mirrors `hosts/rust/src/wasm.rs:384–731` field-for-field — the spec
//! parity matrix in `docs/executable-plugin-abi.md` §15.3 (Rust) and
//! §15.1 (Zig native, post-this-milestone) is identical from here up.
//!
//! Memory model: keys (plugin names, export names) live in an
//! arena owned by the runtime — caller-owned slices in `register()` are
//! duped into the arena so the runtime survives the manifest source
//! arena being freed. Per-instance stores own their wasmtime resources;
//! `deinit` walks every instance and drops its store before dropping the
//! shared engine.
//!
//! First-wins de-duplication: if `register()` is called twice with the
//! same `plugin_name`, the second call drops its store and returns
//! cleanly. The host's manifest-load dedupe (`duplicate_plugin_name`)
//! fires on the same path and removes the second `(use-plugin …)` from
//! the schema — keeping the first-registered instance avoids dispatching
//! into a stale or about-to-be-rejected module.

const std = @import("std");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const wasmtime = @import("runtimes/wasmtime.zig");

comptime {
    std.debug.assert(build_options.plugin_exec);
}

/// Host-side cap on plugin-returned frame length. A plugin that claims
/// a payload of >16 MiB is host-attacking the mirror buffer (see
/// `examples/plugins/double/double.zig`'s `huge` export); we refuse
/// before allocating. Matches `MAX_PLUGIN_RESULT_FRAME` on the Rust
/// host (`hosts/rust/src/wasm.rs`) and the Web invoker.
pub const MAX_PLUGIN_RESULT_FRAME: usize = 16 * 1024 * 1024;

/// Required ABI version reported by `sjon_plugin_abi_version()`. See
/// `docs/executable-plugin-abi.md` §6.
pub const PLUGIN_ABI_VERSION: u32 = 2;

pub const RegisterError = error{
    /// Pre-flight rejected the plugin. Caller reads `lastRegisterFailure()`
    /// for the `(code, detail)` to feed into a host diagnostic.
    Rejected,
} || Allocator.Error;

pub const InvokeError = error{
    /// Wasmtime trapped during the export call OR an out-of-bounds
    /// memory operation. Caller surfaces this as `plugin_func_trapped`.
    Trap,
    /// `sjon_plugin_alloc` returned null, the export returned a null
    /// frame pointer, or the framed length exceeded the host cap.
    /// Caller surfaces this as `plugin_func_alloc_failed`.
    AllocFailed,
} || Allocator.Error;

/// The module's conventional aggregate error — the union of its registration
/// (`RegisterError`) and invocation (`InvokeError`) surfaces.
pub const Error = RegisterError || InvokeError;

/// Failure record populated by `register()` when pre-flight rejects.
/// `code` is the wire diagnostic code; `detail` is arena-allocated by
/// the runtime so its lifetime matches the runtime's. The host copies
/// the detail into its own diagnostic-arena when emitting.
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
    /// Map of declared export name → typed func handle. Keys are
    /// arena-allocated by the runtime.
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

/// Pre-flight + register one plugin. Order per `docs/executable-plugin-abi.md`
/// §16 / `hosts/rust/src/wasm.rs:384–516`:
///
///   1. `Module::from_binary`. Compile failure → `plugin_abi_mismatch`.
///   2. `module.imports()`. Non-empty → `plugin_import_forbidden`
///      with the offending `module.name` so the diagnostic is
///      actionable.
///   3. New store + `linker.instantiate` against an empty linker.
///      The empty-linker step is a second safety net — step 2 already
///      filtered modules with imports, so this should never fail in
///      practice.
///   4. `sjon_plugin_abi_version()` — must exist, signature `() ->
///      i32`, returning `PLUGIN_ABI_VERSION` (`2`).
///   5. Required exports: `sjon_plugin_alloc` `(i32) -> i32`,
///      `sjon_plugin_free` `(i32, i32) -> void`, `memory`.
///   6. Per declared export name: `(i32, i32) -> i32`.
///   7. First-wins insertion keyed on `plugin_name`.
///
/// `declared_exports` lists the manifest's `:impl "wasm:<name>"` export
/// names — populated upstream by walking the loaded `Plugin.expr_funcs`
/// after `ManifestLoader` runs.
pub fn register(
    self: *PluginRuntime,
    gpa: Allocator,
    plugin_name: []const u8,
    bytes: []const u8,
    declared_exports: []const []const u8,
) RegisterError!void {
    self.last_register_failure = .{};

    // 1. Compile.
    var module = wasmtime.Module.compile(self.engine, bytes) catch return self.rejectAbi(
        "plugin \"{s}\" failed to compile: {s}",
        .{ plugin_name, wasmtime.lastDetail() },
    );
    defer module.deinit();

    // 2. Imports must be empty.
    var imports = module.imports(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // A null importtype pointer in the returned vec — bug-shaped
        // input; treat as compile-failure-grade input rejection.
        error.ModuleLoad => return self.rejectAbi(
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

    // 3. New store + instantiate.
    var store = wasmtime.Store.init(self.engine) catch return error.OutOfMemory;
    errdefer store.deinit();
    const instance = self.linker.instantiate(store, module) catch return self.rejectAbi(
        "plugin \"{s}\" failed to instantiate: {s}",
        .{ plugin_name, wasmtime.lastDetail() },
    );

    // 4. ABI version check.
    const abi_func = wasmtime.requireFunc(store, instance, "sjon_plugin_abi_version", &.{}, &.{.i32}) catch |err| switch (err) {
        error.MissingExport, error.WrongExternKind => return self.rejectMissing(
            "plugin \"{s}\" is missing the required `sjon_plugin_abi_version` export",
            .{plugin_name},
        ),
        error.SignatureMismatch => return self.rejectAbi(
            "plugin \"{s}\" export `sjon_plugin_abi_version` has the wrong signature; expected `() -> i32`",
            .{plugin_name},
        ),
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
    };
    const reported: u32 = @bitCast(abi_buf[0].i32);
    if (reported != PLUGIN_ABI_VERSION) {
        return self.rejectAbi(
            "plugin \"{s}\" reports ABI version {d}; host implements {d}",
            .{ plugin_name, reported, PLUGIN_ABI_VERSION },
        );
    }

    // 5. Required standard exports.
    const alloc_func = wasmtime.requireFunc(store, instance, "sjon_plugin_alloc", &.{.i32}, &.{.i32}) catch |err| switch (err) {
        error.MissingExport, error.WrongExternKind => return self.rejectMissing(
            "plugin \"{s}\" is missing the required `sjon_plugin_alloc` export",
            .{plugin_name},
        ),
        error.SignatureMismatch => return self.rejectAbi(
            "plugin \"{s}\" export `sjon_plugin_alloc` has the wrong signature; expected `(i32) -> i32`",
            .{plugin_name},
        ),
    };
    const free_func = wasmtime.requireFunc(store, instance, "sjon_plugin_free", &.{ .i32, .i32 }, &.{}) catch |err| switch (err) {
        error.MissingExport, error.WrongExternKind => return self.rejectMissing(
            "plugin \"{s}\" is missing the required `sjon_plugin_free` export",
            .{plugin_name},
        ),
        error.SignatureMismatch => return self.rejectAbi(
            "plugin \"{s}\" export `sjon_plugin_free` has the wrong signature; expected `(i32, i32) -> void`",
            .{plugin_name},
        ),
    };
    // Both of `requireMemory`'s failures — absent, and present but not a
    // memory — are `plugin_export_missing` per spec §16 ("required
    // exports are keyed by name AND kind"), so there is nothing to
    // switch on.
    const memory = wasmtime.requireMemory(store, instance, "memory") catch return self.rejectMissing(
        "plugin \"{s}\" is missing the required `memory` export",
        .{plugin_name},
    );

    // 6. Per-impl exports.
    var exports: std.StringHashMapUnmanaged(wasmtime.FuncHandle) = .empty;
    errdefer exports.deinit(gpa);
    const arena_a = self.arena.allocator();
    for (declared_exports) |export_name| {
        const func = wasmtime.requireFunc(store, instance, export_name, &.{ .i32, .i32 }, &.{.i32}) catch |err| switch (err) {
            error.MissingExport, error.WrongExternKind => return self.rejectMissing(
                "plugin \"{s}\" manifest declares `:impl \"wasm:{s}\"` but the binary has no such export",
                .{ plugin_name, export_name },
            ),
            error.SignatureMismatch => return self.rejectAbi(
                "plugin \"{s}\" export `{s}` has the wrong signature; expected `(i32, i32) -> i32`",
                .{ plugin_name, export_name },
            ),
        };
        const key = try arena_a.dupe(u8, export_name);
        try exports.put(gpa, key, func);
    }

    // 7. First-wins. If the plugin name is already known, drop the new
    // instance — the second `(use-plugin …)` is about to be rejected
    // upstream as `duplicate_plugin_name` and we MUST keep the live
    // instance pointer the dispatcher already uses.
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

/// Per-call dispatch per `docs/executable-plugin-abi.md` §11. Returns
/// the framed result `[u32 ok][u32 len][payload]` allocated from `gpa`
/// — caller owns it and MUST `gpa.free`. On `error.Trap` /
/// `error.AllocFailed`, read `lastInvokeDetail()` for the human
/// message.
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

    // `sjon_plugin_alloc(0)` returns null by spec. The encoder always
    // sends at least `[u32 count=0]` (4 bytes), so `args.len == 0` only
    // happens on a host bug; the `max(1)` guards alloc against that.
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
        // SAFETY: `alloc_func` is the handle `register` step 5 obtained
        // from `requireFunc(…, &.{.i32}, &.{.i32})`, which returns
        // `MissingExport` unless the export exists with exactly that
        // signature. The call below passes 1 arg and 1 result. wasmtime
        // can only disagree if the store outlived the instance, which
        // `Instance` owns together.
        error.SignatureMismatch => unreachable,
    };
    const args_ptr: u32 = @bitCast(alloc_buf[0].i32);
    if (args_ptr == 0) {
        return self.invokeFail("plugin sjon_plugin_alloc({d}) returned null", .{args_alloc_len});
    }

    // From here on every error path must call `sjon_plugin_free` to
    // hand args memory back to the plugin.
    if (args.len > 0) {
        wasmtime.memoryWrite(inst.store, inst.memory, @intCast(args_ptr), args) catch {
            self.callFree(inst, args_ptr, args_alloc_len);
            return self.invokeTrap("failed to write args into plugin memory (sjon_plugin_alloc returned an out-of-bounds pointer)", .{});
        };
    }

    var call_buf: [2]wasmtime.ValRaw = .{
        .{ .i32 = @bitCast(args_ptr) },
        .{ .i32 = @bitCast(@as(u32, @intCast(args.len))) }, // len ≤ maxInt(u32) checked above; the i32 is the wasm ABI's view of that u32
    };
    wasmtime.callUnchecked(inst.store, export_fn, &call_buf, 2, 1) catch |err| switch (err) {
        error.Trap => {
            // Capture wasmtime detail BEFORE callFree (which clobbers
            // module-global `wasmtime.lastDetail`).
            const trap_detail = self.captureTrap("");
            _ = trap_detail;
            self.callFree(inst, args_ptr, args_alloc_len);
            return error.Trap;
        },
        // SAFETY: as above — `export_fn` came from `requireFunc(…,
        // &.{ .i32, .i32 }, &.{.i32})` in step 6, and this call passes
        // 2 args / 1 result.
        error.SignatureMismatch => unreachable,
    };
    const result_ptr: u32 = @bitCast(call_buf[0].i32);
    if (result_ptr == 0) {
        self.callFree(inst, args_ptr, args_alloc_len);
        return self.invokeFail("plugin export returned null pointer", .{});
    }

    // Read [u32 ok][u32 len] header.
    var header_bytes: [8]u8 = undefined;
    wasmtime.memoryRead(inst.store, inst.memory, @intCast(result_ptr), &header_bytes) catch {
        self.callFree(inst, args_ptr, args_alloc_len);
        return self.invokeTrap("plugin export returned an out-of-bounds frame pointer", .{});
    };
    const len: usize = @intCast(std.mem.readInt(u32, header_bytes[4..8], .little));

    if (len > MAX_PLUGIN_RESULT_FRAME) {
        // Don't trust the size — don't call `sjon_plugin_free` on the
        // bogus frame. The plugin's own arena leak is the plugin's
        // problem; the host's job is to refuse the allocation.
        self.callFree(inst, args_ptr, args_alloc_len);
        return self.invokeFail(
            "plugin export returned a framed result of {d} bytes; host caps plugin frames at {d} bytes",
            .{ len, MAX_PLUGIN_RESULT_FRAME },
        );
    }

    // Mirror buffer for the caller. Free args before allocating to
    // smooth out total memory pressure.
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

    // Plugin owns the framed buffer; release it now (spec §11).
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

/// Copies `prefix` + `wasmtime.lastDetail()` into the runtime's invoke
/// detail buffer. Returns the slice (mostly for callers that want to
/// inspect it). Used before invalidating wasmtime.lastDetail with a
/// nested callUnchecked (the free-on-error path).
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

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;
const PluginValueCodec = @import("PluginValueCodec.zig");
const Expr = @import("Expr.zig");

// Fixture bytes read at test time via `std.testing.io` — same pattern
// the conformance runner uses (`src/conformance_tests.zig`). `zig build
// test` runs from the project root, so cwd-relative paths resolve. We
// can't `@embedFile` these because the fixtures live outside the
// PluginRuntime module's package root (`src/`); the build-side
// `--embed-dir` option is for the C `#embed` directive, not Zig's
// `@embedFile`.
fn readFixture(gpa: Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .unlimited);
}

const DOUBLE_PATH = "examples/plugins/double/plugin.wasm";
const ABI99_PATH = "conformance/cases/plugin-exec-abi-mismatch/manifests/shapes.wasm";
const FORBIDDEN_PATH = "conformance/cases/plugin-exec-import-forbidden/manifests/forbidden.wasm";

test "PluginRuntime: register double.wasm + invoke `double` returns 2x" {
    const gpa = testing.allocator;
    const bytes = try readFixture(gpa, DOUBLE_PATH);
    defer gpa.free(bytes);

    var rt = try PluginRuntime.init(gpa);
    defer rt.deinit(gpa);

    const exports = [_][]const u8{"double"};
    try rt.register(gpa, "double", bytes, &exports);

    // Encode args: one number value 7.0.
    var args_buf: std.ArrayList(u8) = .empty;
    defer args_buf.deinit(gpa);
    try PluginValueCodec.encodeArgs(gpa, &args_buf, &.{.{ .number = 7.0 }});

    const frame = try rt.invoke(gpa, "double", "double", args_buf.items);
    defer gpa.free(frame);

    // Verify framed result: [u32 ok=1][u32 len=9][tag=0x01][f64=14.0].
    try testing.expect(frame.len == 17);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, frame[0..4], .little));
    try testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, frame[4..8], .little));

    var decode_arena = std.heap.ArenaAllocator.init(gpa);
    defer decode_arena.deinit();
    const decoded = try PluginValueCodec.decodeValue(decode_arena.allocator(), frame[8..]);
    try testing.expectEqual(@as(f64, 14.0), decoded.value.number);
}

test "PluginRuntime: ABI version 99 surfaces plugin_abi_mismatch" {
    const gpa = testing.allocator;
    const bytes = try readFixture(gpa, ABI99_PATH);
    defer gpa.free(bytes);

    var rt = try PluginRuntime.init(gpa);
    defer rt.deinit(gpa);

    try testing.expectError(error.Rejected, rt.register(gpa, "shapes", bytes, &.{}));
    const failure = rt.lastRegisterFailure();
    try testing.expectEqual(Ast.Diagnostic.Code.plugin_abi_mismatch, failure.code);
    try testing.expect(failure.detail.len > 0);
    try testing.expect(std.mem.indexOf(u8, failure.detail, "99") != null);
}

test "PluginRuntime: declared export not present surfaces plugin_export_missing" {
    const gpa = testing.allocator;
    const bytes = try readFixture(gpa, DOUBLE_PATH);
    defer gpa.free(bytes);

    var rt = try PluginRuntime.init(gpa);
    defer rt.deinit(gpa);

    const exports = [_][]const u8{"does_not_exist"};
    try testing.expectError(error.Rejected, rt.register(gpa, "double", bytes, &exports));
    const failure = rt.lastRegisterFailure();
    try testing.expectEqual(Ast.Diagnostic.Code.plugin_export_missing, failure.code);
    try testing.expect(std.mem.indexOf(u8, failure.detail, "does_not_exist") != null);
}

test "PluginRuntime: forbidden import surfaces plugin_import_forbidden" {
    const gpa = testing.allocator;
    const bytes = try readFixture(gpa, FORBIDDEN_PATH);
    defer gpa.free(bytes);

    var rt = try PluginRuntime.init(gpa);
    defer rt.deinit(gpa);

    try testing.expectError(error.Rejected, rt.register(gpa, "forbidden", bytes, &.{}));
    const failure = rt.lastRegisterFailure();
    try testing.expectEqual(Ast.Diagnostic.Code.plugin_import_forbidden, failure.code);
    try testing.expect(failure.detail.len > 0);
}

test "PluginRuntime: second register of same plugin_name is first-wins" {
    const gpa = testing.allocator;
    const bytes = try readFixture(gpa, DOUBLE_PATH);
    defer gpa.free(bytes);

    var rt = try PluginRuntime.init(gpa);
    defer rt.deinit(gpa);

    const exports = [_][]const u8{"double"};
    try rt.register(gpa, "p", bytes, &exports);
    // Second register call returns cleanly without overwriting.
    try rt.register(gpa, "p", bytes, &exports);
    try testing.expectEqual(@as(usize, 1), rt.instances.count());
}

test "PluginRuntime: invoke against unregistered plugin returns AllocFailed" {
    const gpa = testing.allocator;
    var rt = try PluginRuntime.init(gpa);
    defer rt.deinit(gpa);

    try testing.expectError(
        error.AllocFailed,
        rt.invoke(gpa, "nope", "double", "\x00\x00\x00\x00"),
    );
    try testing.expect(rt.lastInvokeDetail().len > 0);
}

test "PluginRuntime: invoke trap path surfaces Trap with captured message" {
    const gpa = testing.allocator;
    const bytes = try readFixture(gpa, DOUBLE_PATH);
    defer gpa.free(bytes);

    var rt = try PluginRuntime.init(gpa);
    defer rt.deinit(gpa);

    const exports = [_][]const u8{"trap"};
    try rt.register(gpa, "p", bytes, &exports);

    var args_buf: std.ArrayList(u8) = .empty;
    defer args_buf.deinit(gpa);
    try PluginValueCodec.encodeArgs(gpa, &args_buf, &.{});

    try testing.expectError(
        error.Trap,
        rt.invoke(gpa, "p", "trap", args_buf.items),
    );
    try testing.expect(rt.lastInvokeDetail().len > 0);
}

test "PluginRuntime: oversized result frame returns AllocFailed" {
    const gpa = testing.allocator;
    const bytes = try readFixture(gpa, DOUBLE_PATH);
    defer gpa.free(bytes);

    var rt = try PluginRuntime.init(gpa);
    defer rt.deinit(gpa);

    const exports = [_][]const u8{"huge"};
    try rt.register(gpa, "p", bytes, &exports);

    var args_buf: std.ArrayList(u8) = .empty;
    defer args_buf.deinit(gpa);
    try PluginValueCodec.encodeArgs(gpa, &args_buf, &.{});

    try testing.expectError(
        error.AllocFailed,
        rt.invoke(gpa, "p", "huge", args_buf.items),
    );
    try testing.expect(std.mem.indexOf(u8, rt.lastInvokeDetail(), "caps") != null);
}

// FailingAllocator stress over the Zig-side allocations in
// `init` + `register` + `invoke` against the happy-path double.wasm.
// The wasmtime C library uses its own allocator, so this only exercises
// the Zig-owned allocations: the arena that keys the instance map, the
// register/invoke detail buffers, and the response copy in `invoke`.
// Contract: each fail_index either induces error.OutOfMemory or runs
// to completion — never panics, never leaks, always converges.
test "OOM: PluginRuntime init+register+invoke converges" {
    const gpa = testing.allocator;
    const bytes = try readFixture(gpa, DOUBLE_PATH);
    defer gpa.free(bytes);

    var args_buf: std.ArrayList(u8) = .empty;
    defer args_buf.deinit(gpa);
    try PluginValueCodec.encodeArgs(gpa, &args_buf, &.{.{ .number = 7.0 }});

    const MAX_FAIL_INDEX: usize = 4096;
    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const a = failing.allocator();

        var rt = PluginRuntime.init(a) catch |err| {
            try testing.expect(failing.has_induced_failure);
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        defer rt.deinit(a);

        const exports = [_][]const u8{"double"};
        rt.register(a, "double", bytes, &exports) catch |err| {
            if (err == error.OutOfMemory) {
                try testing.expect(failing.has_induced_failure);
                continue;
            }
            return err;
        };

        const frame = rt.invoke(a, "double", "double", args_buf.items) catch |err| {
            if (err == error.OutOfMemory) {
                try testing.expect(failing.has_induced_failure);
                continue;
            }
            return err;
        };
        defer a.free(frame);

        if (failing.has_induced_failure) continue;
        try testing.expect(frame.len == 17);
        return;
    }
    return error.OomLoopDidNotConverge;
}
