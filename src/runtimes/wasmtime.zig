const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;

comptime {
    std.debug.assert(build_options.plugin_exec);
}

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

const ByteVec = extern struct {
    size: usize,
    data: ?[*]u8,
};

const ImportTypeVec = extern struct {
    size: usize,
    data: ?[*]?*c_importtype_t,
};

const ValtypeVec = extern struct {
    size: usize,
    data: ?[*]?*c_valtype_t,
};

pub const FuncHandle = extern struct {
    store_id: u64,
    _private: ?*anyopaque,
};

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

const GlobalHandle = extern struct {
    store_id: u64,
    _p1: u32,
    _p2: u32,
    _p3: u32,
};

const TableHandle = extern struct {
    store_id: u64,
    _p1: u32,
    _inner_pad: [4]u8 = .{ 0, 0, 0, 0 },
    _p2: u32,
};

const TagHandle = extern struct {
    store_id: u64,
    _p: u32,
};

pub const InstanceHandle = extern struct {
    store_id: u64,
    _private: usize,
};

const ExternUnion = extern union {
    func: FuncHandle,
    global: GlobalHandle,
    table: TableHandle,
    memory: MemoryHandle,
    sharedmemory: ?*anyopaque,
    tag: TagHandle,
};

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

pub const ValKind = enum(u8) {
    i32 = 0,
    i64 = 1,
    f32 = 2,
    f64 = 3,
    _,
};

extern "c" fn wasm_engine_new() ?*c_engine_t;
extern "c" fn wasm_engine_delete(engine: *c_engine_t) void;
extern "c" fn wasmtime_store_new(
    engine: *c_engine_t,
    data: ?*anyopaque,
    finalizer: ?*const fn (?*anyopaque) callconv(.c) void,
) ?*c_store_t;
extern "c" fn wasmtime_store_delete(store: *c_store_t) void;
extern "c" fn wasmtime_store_context(store: *c_store_t) *c_context_t;

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

extern "c" fn wasm_importtype_module(importtype: *const c_importtype_t) *const ByteVec;
extern "c" fn wasm_importtype_name(importtype: *const c_importtype_t) *const ByteVec;
extern "c" fn wasm_importtype_vec_delete(vec: *ImportTypeVec) void;

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

extern "c" fn wasmtime_memory_data(store: *c_context_t, memory: *const MemoryHandle) [*]u8;
extern "c" fn wasmtime_memory_data_size(
    store: *const c_context_t,
    memory: *const MemoryHandle,
) usize;

extern "c" fn wasmtime_error_message(err: *const c_error_t, out: *ByteVec) void;
extern "c" fn wasmtime_error_delete(err: *c_error_t) void;
extern "c" fn wasm_trap_message(trap: *const c_trap_t, out: *ByteVec) void;
extern "c" fn wasm_trap_delete(trap: *c_trap_t) void;
extern "c" fn wasm_byte_vec_delete(vec: *ByteVec) void;

pub const Error = error{
    EngineInitFailed,
    StoreInitFailed,
    LinkerInitFailed,
    ModuleLoad,
    ImportForbidden,
    InstantiateFailed,
    InstantiateTrap,
    MissingExport,
    SignatureMismatch,
    WrongExternKind,
    Trap,
    AllocFailed,
    MemoryOutOfBounds,
} || Allocator.Error;

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

pub const Engine = struct {
    ptr: *c_engine_t,

    pub fn init() Error!Engine {
        const ptr = wasm_engine_new() orelse return error.EngineInitFailed;
        return .{ .ptr = ptr };
    }

    pub fn deinit(self: *Engine) void {
        wasm_engine_delete(self.ptr);
        self.* = undefined;
    }
};

pub const Store = struct {
    ptr: *c_store_t,
    ctx: *c_context_t,

    pub fn init(engine: Engine) Error!Store {
        const ptr = wasmtime_store_new(engine.ptr, null, null) orelse return error.StoreInitFailed;
        return .{ .ptr = ptr, .ctx = wasmtime_store_context(ptr) };
    }

    pub fn deinit(self: *Store) void {
        wasmtime_store_delete(self.ptr);
        self.* = undefined;
    }
};

pub const Module = struct {
    ptr: *c_module_t,

    pub fn compile(engine: Engine, bytes: []const u8) Error!Module {
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

    pub fn imports(self: Module, gpa: Allocator) Error!Imports {
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

pub const Linker = struct {
    ptr: *c_linker_t,

    pub fn init(engine: Engine) Error!Linker {
        const ptr = wasmtime_linker_new(engine.ptr) orelse return error.LinkerInitFailed;
        return .{ .ptr = ptr };
    }

    pub fn deinit(self: *Linker) void {
        wasmtime_linker_delete(self.ptr);
        self.* = undefined;
    }

    pub fn instantiate(self: Linker, store: Store, module: Module) Error!InstanceHandle {
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

pub fn getExport(
    store: Store,
    instance: InstanceHandle,
    name: []const u8,
) ?Extern {
    var item: Extern = undefined;
    const ok = wasmtime_instance_export_get(store.ctx, &instance, name.ptr, name.len, &item);
    return if (ok) item else null;
}

pub fn requireFunc(
    store: Store,
    instance: InstanceHandle,
    name: []const u8,
    params: []const ValKind,
    results: []const ValKind,
) Error!FuncHandle {
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
) Error!MemoryHandle {
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

pub fn callUnchecked(
    store: Store,
    func: FuncHandle,
    buf: []ValRaw,
    args_len: usize,
    results_len: usize,
) Error!void {
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
) Error!void {
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
) Error!void {
    const mem = memoryData(store, memory);
    if (offset > mem.len or src.len > mem.len - offset) {
        recordDetail("write past linear-memory bounds");
        return error.MemoryOutOfBounds;
    }
    @memcpy(mem[offset..][0..src.len], src);
}

const testing = std.testing;

const ping_module = [_]u8{
    0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F, 0x03,
    0x02, 0x01, 0x00, 0x07, 0x08, 0x01, 0x04, 'p',
    'i',  'n',  'g',  0x00, 0x00, 0x0A, 0x06, 0x01,
    0x04, 0x00, 0x41, 0x2A, 0x0B,
};
