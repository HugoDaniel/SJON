//! Thin Zig wrapper around the wasmtime C API. The `PluginRuntime`
//! adapter (`src/PluginRuntime.zig`) consumes this layer to instantiate
//! `:impl "wasm:<name>"` sidecars natively, matching the Rust host's
//! `wasmtime::Module + Linker + Store` pipeline (`hosts/rust/src/wasm.rs`)
//! field-for-field — same pre-flight order, same diagnostic taxonomy,
//! same per-call alloc/copy/call/copy/free contract (spec §11).
//!
//! Module layout choice: `src/runtimes/<name>.zig` rather than a flat
//! `src/wasm_runtime.zig` so a future second backend (wasm3, pure-Zig)
//! can live alongside under the same `PluginRuntime` interface without
//! renaming files. Matches the slot reserved in
//! `docs/executable-plugin-abi.md` §15.1.
//!
//! Lifetime contract:
//!   * `Engine` is process-wide-shareable; one instance is created in
//!     `PluginRuntime.init` and reused across every plugin pool entry.
//!   * `Store` owns its `Instance` for the duration of the host load —
//!     the `Func`/`Memory` handles below are 8-byte POD identifiers into
//!     that store and are only valid while the store lives.
//!   * `Module` can be dropped after `Linker.instantiate` succeeds; we
//!     keep it borrow-style alive for the duration of `register` and
//!     drop it before returning to the caller.
//!   * Trap handling: `wasmtime_func_call_unchecked` and
//!     `wasmtime_linker_instantiate` use the out-parameter trap form, so
//!     traps NEVER longjmp through Zig — we read the trap pointer, copy
//!     the message, and free both.
//!
//! Call ABI choice: SJON's plugin functions are uniformly
//! `(i32, i32) -> i32` (export bodies), `(i32) -> i32` (alloc), `(i32,
//! i32) -> void` (free), or `() -> i32` (abi_version). We pre-check the
//! signature once via `wasmtime_func_type` at pre-flight, then dispatch
//! every call through `wasmtime_func_call_unchecked` with the 16-byte
//! `wasmtime_val_raw_t` — avoids the conf.h-dependent size of
//! `wasmtime_val_t` (16 or 24 bytes depending on GC features) and the
//! per-call typed-call overhead. Safe because the signature check
//! upstream is single-source-of-truth.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;

comptime {
    // This file links libwasmtime — only meaningful on builds where the
    // option is enabled. Including it in `plugin_exec = false` builds
    // would be a static-link mistake.
    std.debug.assert(build_options.plugin_exec);
}

// ---------------------------------------------------------------------
// Opaque C handles. Zero-runtime cost — `extern struct {}` is a one-byte
// type that the C API treats as a pointer target.
// ---------------------------------------------------------------------

const c_engine_t = opaque {};
const c_store_t = opaque {};
const c_context_t = opaque {};
const c_module_t = opaque {};
const c_linker_t = opaque {};
const c_error_t = opaque {};
const c_trap_t = opaque {};
const c_functype_t = opaque {};
const c_valtype_t = opaque {};
const c_importtype_t = opaque {};
const c_externtype_t = opaque {};

/// `wasm_byte_vec_t` / `wasm_name_t` — same shape: { size, data }.
const ByteVec = extern struct {
    size: usize,
    data: ?[*]u8,
};

/// `wasm_importtype_vec_t` — { size, data } where data is a pointer
/// to an array of importtype pointers.
const ImportTypeVec = extern struct {
    size: usize,
    data: ?[*]?*c_importtype_t,
};

/// `wasm_valtype_vec_t` — { size, data } where data points to an array
/// of valtype pointers.
const ValtypeVec = extern struct {
    size: usize,
    data: ?[*]?*c_valtype_t,
};

/// Mirrors `wasmtime_func` (extern.h:26) — POD 16-byte identifier into a
/// store. `store_id == 0` is the null-funcref encoding.
pub const FuncHandle = extern struct {
    store_id: u64,
    _private: ?*anyopaque,
};

/// Mirrors `wasmtime_memory` (extern.h:62). The C definition uses an
/// anonymous nested struct (`struct { u64 store_id; u32 __private1; }`)
/// followed by an outer `u32 __private2` sibling — that inner anon-struct
/// gets padded up to its 8-byte alignment, so the outer u32 sits at
/// offset 16, not 12. The flat Zig translation `{ u64, u32, u32 }` would
/// place that final u32 at offset 12 and shift wasmtime's `__private2`
/// reads/writes by 4 bytes — which crashes wasmtime's defined-memories
/// assertion (`assertion failed: index.as_u32() < self.num_defined_memories`)
/// on the first memory access.
pub const MemoryHandle = extern struct {
    store_id: u64,
    _private1: u32,
    _inner_pad: [4]u8 = .{ 0, 0, 0, 0 },
    _private2: u32,
};

comptime {
    std.debug.assert(@sizeOf(MemoryHandle) == 24);
    std.debug.assert(@alignOf(MemoryHandle) == 8);
}

/// Mirrors `wasmtime_global` — flat struct, no anon nesting. 20 bytes
/// of fields padded to 24 by struct alignment.
const GlobalHandle = extern struct {
    store_id: u64,
    _p1: u32,
    _p2: u32,
    _p3: u32,
};

/// Mirrors `wasmtime_table` — same anon-struct layout trick as
/// memory; same 24-byte total.
const TableHandle = extern struct {
    store_id: u64,
    _p1: u32,
    _inner_pad: [4]u8 = .{ 0, 0, 0, 0 },
    _p2: u32,
};

/// Mirrors `wasmtime_tag` — flat 12-byte (u64+u32), aligned to 8 → 16
/// bytes total.
const TagHandle = extern struct {
    store_id: u64,
    _p: u32,
};

/// Mirrors `wasmtime_instance` (instance.h:26).
pub const InstanceHandle = extern struct {
    store_id: u64,
    _private: usize,
};

/// `wasmtime_extern_union_t`. Sized to the largest variant — `GlobalHandle`
/// at 24 bytes (the C union member set includes globals).
const ExternUnion = extern union {
    func: FuncHandle,
    global: GlobalHandle,
    table: TableHandle,
    memory: MemoryHandle,
    sharedmemory: ?*anyopaque,
    tag: TagHandle,
};

/// `wasmtime_extern_t` — { kind: u8, of: union }. C layout uses 8-byte
/// alignment for `of`, so kind sits in a padded byte at offset 0 with
/// the union starting at offset 8.
const Extern = extern struct {
    kind: u8,
    _pad: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 },
    of: ExternUnion,
};

const EXTERN_FUNC: u8 = 0;
const EXTERN_GLOBAL: u8 = 1;
const EXTERN_TABLE: u8 = 2;
const EXTERN_MEMORY: u8 = 3;
const EXTERN_SHAREDMEMORY: u8 = 4;
const EXTERN_TAG: u8 = 5;

/// `wasmtime_val_raw_t` (val.h:290) — 16-byte untyped union. The "stride
/// unit" `wasmtime_func_call_unchecked` reads/writes per arg slot.
pub const ValRaw = extern union {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
    v128: [16]u8,
    funcref: ?*anyopaque,
};

comptime {
    std.debug.assert(@sizeOf(ValRaw) == 16);
    std.debug.assert(@alignOf(ValRaw) == 8);
}

/// `wasm_valkind_t` — both wasm.h and wasmtime/val.h use the same byte
/// values for the common types we care about (i32=0). Anyref/exnref/
/// externref are GC-only and irrelevant to SJON's `(i32, i32) -> i32`
/// signature.
pub const ValKind = enum(u8) {
    i32 = 0,
    i64 = 1,
    f32 = 2,
    f64 = 3,
    _,
};

// ---------------------------------------------------------------------
// C API declarations. `extern "c"` matches the `WASM_API_EXTERN` macro
// (which expands to `extern "C"` in C++ and is a no-op in C). One block
// per logical surface for readability.
// ---------------------------------------------------------------------

// Engine + Store
extern "c" fn wasm_engine_new() ?*c_engine_t;
extern "c" fn wasm_engine_delete(engine: *c_engine_t) void;
extern "c" fn wasmtime_store_new(
    engine: *c_engine_t,
    data: ?*anyopaque,
    finalizer: ?*const fn (?*anyopaque) callconv(.c) void,
) ?*c_store_t;
extern "c" fn wasmtime_store_delete(store: *c_store_t) void;
extern "c" fn wasmtime_store_context(store: *c_store_t) *c_context_t;

// Module
extern "c" fn wasmtime_module_new(
    engine: *c_engine_t,
    wasm: [*]const u8,
    wasm_len: usize,
    module_out: *?*c_module_t,
) ?*c_error_t;
extern "c" fn wasmtime_module_delete(module: *c_module_t) void;
extern "c" fn wasmtime_module_imports(
    module: *const c_module_t,
    out: *ImportTypeVec,
) void;

// Importtype accessors (standard wasm-c-api in wasm.h)
extern "c" fn wasm_importtype_module(importtype: *const c_importtype_t) *const ByteVec;
extern "c" fn wasm_importtype_name(importtype: *const c_importtype_t) *const ByteVec;
extern "c" fn wasm_importtype_vec_delete(vec: *ImportTypeVec) void;

// Linker + Instance
extern "c" fn wasmtime_linker_new(engine: *c_engine_t) ?*c_linker_t;
extern "c" fn wasmtime_linker_delete(linker: *c_linker_t) void;
extern "c" fn wasmtime_linker_instantiate(
    linker: *const c_linker_t,
    store: *c_context_t,
    module: *const c_module_t,
    instance_out: *InstanceHandle,
    trap_out: *?*c_trap_t,
) ?*c_error_t;
extern "c" fn wasmtime_instance_export_get(
    store: *c_context_t,
    instance: *const InstanceHandle,
    name: [*]const u8,
    name_len: usize,
    item_out: *Extern,
) bool;

// Func type-check + call
extern "c" fn wasmtime_func_type(
    store: *const c_context_t,
    func: *const FuncHandle,
) *c_functype_t;
extern "c" fn wasm_functype_delete(functype: *c_functype_t) void;
extern "c" fn wasm_functype_params(functype: *const c_functype_t) *const ValtypeVec;
extern "c" fn wasm_functype_results(functype: *const c_functype_t) *const ValtypeVec;
extern "c" fn wasm_valtype_kind(valtype: *const c_valtype_t) u8;
extern "c" fn wasmtime_func_call_unchecked(
    store: *c_context_t,
    func: *const FuncHandle,
    args_and_results: ?[*]ValRaw,
    args_and_results_len: usize,
    trap_out: *?*c_trap_t,
) ?*c_error_t;

// Memory
extern "c" fn wasmtime_memory_data(store: *c_context_t, memory: *const MemoryHandle) [*]u8;
extern "c" fn wasmtime_memory_data_size(
    store: *const c_context_t,
    memory: *const MemoryHandle,
) usize;

// Error + Trap accessors
extern "c" fn wasmtime_error_message(err: *const c_error_t, out: *ByteVec) void;
extern "c" fn wasmtime_error_delete(err: *c_error_t) void;
extern "c" fn wasm_trap_message(trap: *const c_trap_t, out: *ByteVec) void;
extern "c" fn wasm_trap_delete(trap: *c_trap_t) void;
extern "c" fn wasm_byte_vec_delete(vec: *ByteVec) void;

// ---------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------

// One set per operation, not one set for the binding.
//
// A single wide `Error` used to cover all eleven entry points, and the
// cost landed entirely on the caller: `PluginRuntime.register` handles
// each failure with a *different* diagnostic, so every `catch |err|
// switch` there had to end in `else => unreachable` for the nine or ten
// variants that call could not produce. Ten unreachables that no test
// can reach, each asserting a fact only this file knows.
//
// Narrowed, the switches are exhaustive and the `else` arms are gone —
// the compiler now proves what the comments used to claim. Adding a
// failure mode to an operation below is a compile error at its call
// site, which is exactly where the new diagnostic has to be chosen.
//
// None of these include `Allocator.Error` except `ImportsError`: these
// are thin `extern "c"` wrappers, and `Module.imports` is the only one
// that allocates host-side (the `ImportDesc` array).

/// `Engine.init` — the process-wide wasmtime engine failed to come up.
pub const EngineInitError = error{EngineInitFailed};
/// `Store.init` — a per-instance store failed to come up.
pub const StoreInitError = error{StoreInitFailed};
/// `Linker.init` — the (deliberately empty) linker failed to come up.
pub const LinkerInitError = error{LinkerInitFailed};
/// `Module.compile` — the bytes are not a module wasmtime will accept.
/// Detail in `lastDetail()`.
pub const CompileError = error{ModuleLoad};
/// `Module.imports` — `ModuleLoad` for a null importtype in the returned
/// vec (bug-shaped input), plus the host-side allocation.
pub const ImportsError = error{ModuleLoad} || Allocator.Error;
/// `Linker.instantiate` — the two ways instantiation ends badly:
/// wasmtime refused it (`InstantiateFailed`) or the module's start
/// function trapped (`InstantiateTrap`).
pub const InstantiateError = error{ InstantiateFailed, InstantiateTrap };
/// `requireFunc` — absent, present-but-not-a-function, or present with
/// the wrong arity / param / result types.
pub const RequireFuncError = error{ MissingExport, WrongExternKind, SignatureMismatch };
/// `requireMemory` — as `RequireFuncError` minus the signature check;
/// a memory export has no signature to disagree about.
pub const RequireMemoryError = error{ MissingExport, WrongExternKind };
/// `callUnchecked` — the guest trapped, or wasmtime rejected the call
/// against the function's real type. The latter is a host bug (every
/// handle came through `requireFunc`), but it is wasmtime's answer, not
/// ours, so it stays a value rather than an assertion.
pub const CallError = error{ Trap, SignatureMismatch };
/// `memoryRead` / `memoryWrite` — the guest handed back a pointer or
/// length that does not fit its own linear memory.
pub const MemoryError = error{MemoryOutOfBounds};

/// Everything the binding can surface, for callers that genuinely want
/// the union (fuzz harnesses, `catch |err|` sites that only log). Built
/// from the sets above so it cannot drift from them.
pub const Error = EngineInitError ||
    StoreInitError ||
    LinkerInitError ||
    CompileError ||
    ImportsError ||
    InstantiateError ||
    RequireFuncError ||
    RequireMemoryError ||
    CallError ||
    MemoryError;

// ---------------------------------------------------------------------
// Failure-detail buffer
//
// `Error` is a closed enum and can't carry a message. The wasmtime call
// might fail with a 200-byte trap explanation we want to surface in
// `plugin_func_trapped` diagnostics. Per-thread/per-call buffer the way
// `wasm_plugin_invoker.LastFailure` does — module-level state, cleared
// at the start of every public entry point. The PluginRuntime layer
// copies the message into its own failure buffer before returning to
// callers, so concurrent callers don't race on this scratch space.
// ---------------------------------------------------------------------

var detail_storage: [512]u8 = undefined;
var detail_len: usize = 0;

pub fn lastDetail() []const u8 {
    return detail_storage[0..detail_len];
}

fn resetDetail() void {
    detail_len = 0;
}

fn recordDetail(msg: []const u8) void {
    var trimmed = msg;
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == 0) trimmed.len -= 1;
    const n = @min(trimmed.len, detail_storage.len);
    @memcpy(detail_storage[0..n], trimmed[0..n]);
    detail_len = n;
}

fn recordErrMessage(err: *c_error_t) void {
    var vec: ByteVec = .{ .size = 0, .data = null };
    wasmtime_error_message(err, &vec);
    defer wasm_byte_vec_delete(&vec);
    if (vec.data) |p| recordDetail(p[0..vec.size]);
}

fn recordTrapMessage(trap: *c_trap_t) void {
    var vec: ByteVec = .{ .size = 0, .data = null };
    wasm_trap_message(trap, &vec);
    defer wasm_byte_vec_delete(&vec);
    if (vec.data) |p| recordDetail(p[0..vec.size]);
}

// ---------------------------------------------------------------------
// Engine — global wasmtime engine; one per host load. Owns nothing
// except the C engine handle.
// ---------------------------------------------------------------------

pub const Engine = struct {
    ptr: *c_engine_t,

    pub fn init() EngineInitError!Engine {
        const ptr = wasm_engine_new() orelse return error.EngineInitFailed;
        return .{ .ptr = ptr };
    }

    pub fn deinit(self: *Engine) void {
        wasm_engine_delete(self.ptr);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------
// Store — one per plugin instance. Owns the instance, its memory, and
// (transitively) every function handle we obtained via export_get.
// ---------------------------------------------------------------------

pub const Store = struct {
    ptr: *c_store_t,
    ctx: *c_context_t,

    pub fn init(engine: Engine) StoreInitError!Store {
        const ptr = wasmtime_store_new(engine.ptr, null, null) orelse return error.StoreInitFailed;
        return .{ .ptr = ptr, .ctx = wasmtime_store_context(ptr) };
    }

    pub fn deinit(self: *Store) void {
        wasmtime_store_delete(self.ptr);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------
// Module + import iteration
// ---------------------------------------------------------------------

pub const Module = struct {
    ptr: *c_module_t,

    pub fn compile(engine: Engine, bytes: []const u8) CompileError!Module {
        resetDetail();
        var out: ?*c_module_t = null;
        const err = wasmtime_module_new(engine.ptr, bytes.ptr, bytes.len, &out);
        if (err) |e| {
            recordErrMessage(e);
            wasmtime_error_delete(e);
            return error.ModuleLoad;
        }
        return .{ .ptr = out orelse return error.ModuleLoad };
    }

    pub fn deinit(self: *Module) void {
        wasmtime_module_delete(self.ptr);
        self.* = undefined;
    }

    pub const ImportDesc = struct {
        module: []const u8,
        name: []const u8,
    };

    /// Snapshot of the module's import section. Used by pre-flight to
    /// surface `plugin_import_forbidden` BEFORE instantiation — if we
    /// call `linker.instantiate` with an empty linker against a module
    /// that imports anything, wasmtime would surface a generic "unknown
    /// import" error which we couldn't distinguish from "linker has the
    /// wrong import set" (an internal bug, not user-facing).
    ///
    /// Returned slices borrow into wasmtime-owned storage held inside
    /// the returned `Imports` value. Caller MUST `deinit` to release.
    pub fn imports(self: Module, gpa: Allocator) ImportsError!Imports {
        var vec: ImportTypeVec = .{ .size = 0, .data = null };
        wasmtime_module_imports(self.ptr, &vec);

        const descs = try gpa.alloc(ImportDesc, vec.size);
        if (vec.data) |arr| {
            var i: usize = 0;
            while (i < vec.size) : (i += 1) {
                const it = arr[i] orelse return error.ModuleLoad;
                const mod_name = wasm_importtype_module(it);
                const item_name = wasm_importtype_name(it);
                descs[i] = .{
                    .module = if (mod_name.data) |p| p[0..mod_name.size] else "",
                    .name = if (item_name.data) |p| p[0..item_name.size] else "",
                };
            }
        }

        return .{ .gpa = gpa, .vec = vec, .descs = descs };
    }
};

/// Lifetime envelope for `Module.imports()`. The `descs` slices borrow
/// into `vec`-owned bytes — releasing `vec` invalidates them, so deinit
/// happens together.
pub const Imports = struct {
    gpa: Allocator,
    vec: ImportTypeVec,
    descs: []Module.ImportDesc,

    pub fn deinit(self: *Imports) void {
        self.gpa.free(self.descs);
        wasm_importtype_vec_delete(&self.vec);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------
// Linker + Instance — instantiate against an empty linker so any
// declared import surfaces as the WHOLE-MODULE-level diagnostic
// `plugin_import_forbidden`. We do that check on the Module side first
// (pre-instantiation) so the diagnostic message can name the first
// offending import; the empty-linker instantiate is the second safety
// net.
// ---------------------------------------------------------------------

pub const Linker = struct {
    ptr: *c_linker_t,

    pub fn init(engine: Engine) LinkerInitError!Linker {
        const ptr = wasmtime_linker_new(engine.ptr) orelse return error.LinkerInitFailed;
        return .{ .ptr = ptr };
    }

    pub fn deinit(self: *Linker) void {
        wasmtime_linker_delete(self.ptr);
        self.* = undefined;
    }

    pub fn instantiate(self: Linker, store: Store, module: Module) InstantiateError!InstanceHandle {
        resetDetail();
        var instance: InstanceHandle = undefined;
        var trap: ?*c_trap_t = null;
        const err = wasmtime_linker_instantiate(
            self.ptr,
            store.ctx,
            module.ptr,
            &instance,
            &trap,
        );
        if (err) |e| {
            recordErrMessage(e);
            wasmtime_error_delete(e);
            return error.InstantiateFailed;
        }
        if (trap) |t| {
            recordTrapMessage(t);
            wasm_trap_delete(t);
            return error.InstantiateTrap;
        }
        return instance;
    }
};

// ---------------------------------------------------------------------
// Instance — export lookup. Returns Extern.kind so the caller can check
// "is this a func?" vs "is this a memory?" — pre-flight rejects with
// `plugin_export_missing` (wrong kind: e.g. `memory` exported as a
// global) which surfaces under the same wire code as actually-missing.
// ---------------------------------------------------------------------

pub fn getExport(
    store: Store,
    instance: InstanceHandle,
    name: []const u8,
) ?Extern {
    var item: Extern = undefined;
    const ok = wasmtime_instance_export_get(store.ctx, &instance, name.ptr, name.len, &item);
    return if (ok) item else null;
}

/// Look up an export and require it to be a function with the given
/// signature. Distinguishes:
///   * not found → MissingExport (`plugin_export_missing` upstream)
///   * present but not a func → WrongExternKind (also rendered as
///     `plugin_export_missing` per spec §16's "required exports are
///     keyed by name AND kind")
///   * present with the wrong arity / wrong param-or-result kind →
///     SignatureMismatch (`plugin_abi_mismatch` upstream)
pub fn requireFunc(
    store: Store,
    instance: InstanceHandle,
    name: []const u8,
    params: []const ValKind,
    results: []const ValKind,
) RequireFuncError!FuncHandle {
    resetDetail();
    const ext = getExport(store, instance, name) orelse {
        recordDetail("export not found");
        return error.MissingExport;
    };
    if (ext.kind != EXTERN_FUNC) {
        recordDetail("export is not a function");
        return error.WrongExternKind;
    }
    const func = ext.of.func;

    const ft = wasmtime_func_type(store.ctx, &func);
    defer wasm_functype_delete(ft);
    const got_params = wasm_functype_params(ft);
    const got_results = wasm_functype_results(ft);

    if (got_params.size != params.len or got_results.size != results.len) {
        recordDetail("function arity does not match expected signature");
        return error.SignatureMismatch;
    }
    if (got_params.data) |arr| {
        for (params, 0..) |want, i| {
            const got_vt = arr[i] orelse return error.SignatureMismatch;
            if (wasm_valtype_kind(got_vt) != @intFromEnum(want)) {
                recordDetail("function param type does not match expected signature");
                return error.SignatureMismatch;
            }
        }
    }
    if (got_results.data) |arr| {
        for (results, 0..) |want, i| {
            const got_vt = arr[i] orelse return error.SignatureMismatch;
            if (wasm_valtype_kind(got_vt) != @intFromEnum(want)) {
                recordDetail("function result type does not match expected signature");
                return error.SignatureMismatch;
            }
        }
    }
    return func;
}

pub fn requireMemory(
    store: Store,
    instance: InstanceHandle,
    name: []const u8,
) RequireMemoryError!MemoryHandle {
    resetDetail();
    const ext = getExport(store, instance, name) orelse {
        recordDetail("memory export not found");
        return error.MissingExport;
    };
    if (ext.kind != EXTERN_MEMORY) {
        recordDetail("export is not a memory");
        return error.WrongExternKind;
    }
    return ext.of.memory;
}

// ---------------------------------------------------------------------
// Call — single entry point covering every signature SJON uses. Args
// and results share a single `ValRaw` slot buffer (the wasmtime API's
// "args_and_results" model). Caller pre-sized to max(nargs, nresults).
// ---------------------------------------------------------------------

/// Invoke `func` with `args` pre-loaded into `buf[0..args_len]`. On
/// return, `buf[0..results_len]` carries the results. `buf.len` MUST be
/// `>= max(args_len, results_len)` — wasmtime treats the slice as a
/// combined buffer.
pub fn callUnchecked(
    store: Store,
    func: FuncHandle,
    buf: []ValRaw,
    args_len: usize,
    results_len: usize,
) CallError!void {
    resetDetail();
    std.debug.assert(buf.len >= @max(args_len, results_len));
    var trap: ?*c_trap_t = null;
    const slice_len = @max(args_len, results_len);
    const slice_ptr: ?[*]ValRaw = if (slice_len == 0) null else buf.ptr;
    const err = wasmtime_func_call_unchecked(store.ctx, &func, slice_ptr, slice_len, &trap);
    if (err) |e| {
        recordErrMessage(e);
        wasmtime_error_delete(e);
        return error.SignatureMismatch;
    }
    if (trap) |t| {
        recordTrapMessage(t);
        wasm_trap_delete(t);
        return error.Trap;
    }
}

// ---------------------------------------------------------------------
// Memory — bounded read/write helpers. Plugin exports return pointers
// into the plugin's own linear memory; the host copies bytes out via
// these helpers.
// ---------------------------------------------------------------------

pub fn memoryData(store: Store, memory: MemoryHandle) []u8 {
    const ptr = wasmtime_memory_data(store.ctx, &memory);
    const size = wasmtime_memory_data_size(store.ctx, &memory);
    return ptr[0..size];
}

pub fn memoryRead(
    store: Store,
    memory: MemoryHandle,
    offset: usize,
    dst: []u8,
) MemoryError!void {
    const mem = memoryData(store, memory);
    if (offset > mem.len or dst.len > mem.len - offset) {
        recordDetail("read past linear-memory bounds");
        return error.MemoryOutOfBounds;
    }
    @memcpy(dst, mem[offset..][0..dst.len]);
}

pub fn memoryWrite(
    store: Store,
    memory: MemoryHandle,
    offset: usize,
    src: []const u8,
) MemoryError!void {
    const mem = memoryData(store, memory);
    if (offset > mem.len or src.len > mem.len - offset) {
        recordDetail("write past linear-memory bounds");
        return error.MemoryOutOfBounds;
    }
    @memcpy(mem[offset..][0..src.len], src);
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

/// Hand-rolled minimal WASM module: `(module (func (export "ping")
/// (result i32) (i32.const 42)))`. 37 bytes. Layout per
/// https://webassembly.github.io/spec/core/binary/modules.html.
const ping_module = [_]u8{
    // magic + version
    0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
    // type section (id=1, size=5): 1 functype () -> i32
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F,
    // function section (id=3, size=2): 1 fn with type idx 0
    0x03,
    0x02, 0x01, 0x00,
    // export section (id=7, size=8): export "ping" → func idx 0
    0x07, 0x08, 0x01, 0x04, 'p',
    'i',  'n',  'g',  0x00, 0x00,
    // code section (id=10, size=6): 1 body, 4 bytes: 0 locals; i32.const 42; end
    0x0A, 0x06, 0x01,
    0x04, 0x00, 0x41, 0x2A, 0x0B,
};

test "wasmtime: compile + instantiate + call ping module returns 42" {
    var engine = try Engine.init();
    defer engine.deinit();

    var module = try Module.compile(engine, &ping_module);
    defer module.deinit();

    var imports = try module.imports(testing.allocator);
    defer imports.deinit();
    try testing.expectEqual(@as(usize, 0), imports.descs.len);

    var store = try Store.init(engine);
    defer store.deinit();

    var linker = try Linker.init(engine);
    defer linker.deinit();

    const instance = try linker.instantiate(store, module);

    const func = try requireFunc(store, instance, "ping", &.{}, &.{.i32});

    var buf: [1]ValRaw = .{.{ .i32 = 0 }};
    try callUnchecked(store, func, &buf, 0, 1);
    try testing.expectEqual(@as(i32, 42), buf[0].i32);
}

test "wasmtime: missing export surfaces MissingExport" {
    var engine = try Engine.init();
    defer engine.deinit();

    var module = try Module.compile(engine, &ping_module);
    defer module.deinit();

    var store = try Store.init(engine);
    defer store.deinit();

    var linker = try Linker.init(engine);
    defer linker.deinit();

    const instance = try linker.instantiate(store, module);

    try testing.expectError(
        error.MissingExport,
        requireFunc(store, instance, "does_not_exist", &.{}, &.{.i32}),
    );
}

test "wasmtime: signature mismatch surfaces SignatureMismatch" {
    var engine = try Engine.init();
    defer engine.deinit();

    var module = try Module.compile(engine, &ping_module);
    defer module.deinit();

    var store = try Store.init(engine);
    defer store.deinit();

    var linker = try Linker.init(engine);
    defer linker.deinit();

    const instance = try linker.instantiate(store, module);

    // `ping` is `() -> i32`; asking for `(i32) -> i32` must reject.
    try testing.expectError(
        error.SignatureMismatch,
        requireFunc(store, instance, "ping", &.{.i32}, &.{.i32}),
    );
}

test "wasmtime: malformed wasm bytes surface ModuleLoad" {
    var engine = try Engine.init();
    defer engine.deinit();

    try testing.expectError(error.ModuleLoad, Module.compile(engine, "not wasm at all"));
    // Failure detail buffer should have a wasmtime-supplied message.
    try testing.expect(lastDetail().len > 0);
}
