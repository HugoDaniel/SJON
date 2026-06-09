const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Date = @import("Date.zig");
const Time = @import("Time.zig");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const BinaryCursor = @import("BinaryCursor.zig");
const wasm_plugin_invoker = @import("wasm_plugin_invoker.zig");
const trig = @import("trig.zig");

pub const MAX_EVAL_DEPTH: u32 = 256;

const MAX_FRAMES: u32 = MAX_EVAL_DEPTH * 4;

const MAX_STEPS: u32 = 1 << 20;

pub const MAX_EVAL_BYTES: usize = 1 << 26;

comptime {
    std.debug.assert(@sizeOf(Value) <= 72);
}

pub const Value = union(enum) {
    number: f64,
    integer_i64: i64,
    integer_u64: u64,
    boolean: bool,
    nil,
    string: []const u8,
    keyword: []const u8,
    date: Date,
    time: Time,
    vector: []const Value,
    form: FormValue,

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            .nil => false,
            else => true,
        };
    }

    pub fn toF64(self: Value) ?f64 {
        return switch (self) {
            .number => |x| x,
            .integer_i64 => |x| @floatFromInt(x),
            .integer_u64 => |x| @floatFromInt(x),
            else => null,
        };
    }

    pub fn equals(a: Value, b: Value) bool {
        const a_num = a.toF64();
        const b_num = b.toF64();
        if (a_num != null and b_num != null) {
            if (@as(std.meta.Tag(Value), a) != @as(std.meta.Tag(Value), b)) {
                return a_num.? == b_num.?;
            }
        }
        if (@as(std.meta.Tag(Value), a) != @as(std.meta.Tag(Value), b)) return false;
        return switch (a) {
            .number => |x| x == b.number,
            .integer_i64 => |x| x == b.integer_i64,
            .integer_u64 => |x| x == b.integer_u64,
            .boolean => |x| x == b.boolean,
            .nil => true,
            .string => |x| std.mem.eql(u8, x, b.string),
            .keyword => |x| std.mem.eql(u8, x, b.keyword),
            .date => |x| x.eql(b.date),
            .time => |x| x.eql(b.time),
            .vector => |xs| blk: {
                if (xs.len != b.vector.len) break :blk false;
                for (xs, b.vector) |xv, yv| if (!equals(xv, yv)) break :blk false;
                break :blk true;
            },
            .form => |fa| blk: {
                const fb = b.form;
                if (!std.mem.eql(u8, fa.head, fb.head)) break :blk false;
                if (!std.mem.eql(u8, fa.namespace, fb.namespace)) break :blk false;
                if (fa.children.len != fb.children.len) break :blk false;
                for (fa.children, fb.children) |xv, yv| if (!equals(xv, yv)) break :blk false;
                if (fa.kvpairs.len != fb.kvpairs.len) break :blk false;
                for (fa.kvpairs, fb.kvpairs) |xp, yp| {
                    if (!std.mem.eql(u8, xp.key, yp.key)) break :blk false;
                    if (!equals(xp.value, yp.value)) break :blk false;
                }
                break :blk true;
            },
        };
    }
};

pub const FormValue = struct {
    head: []const u8,
    namespace: []const u8,
    children: []const Value,
    kvpairs: []const KvPair,
};

pub const KvPair = struct {
    key: []const u8,
    value: Value,
};

pub const Env = struct {
    parent: ?*const Env = null,
    bindings: []const Binding = &.{},

    pub const Binding = struct {
        name: []const u8,
        value: Value,
    };

    pub fn lookup(self: *const Env, name: []const u8) ?Value {
        var i: usize = self.bindings.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.bindings[i].name, name)) return self.bindings[i].value;
        }
        if (self.parent) |p| return p.lookup(name);
        return null;
    }
};

pub const Error = error{
    OutOfMemory,
    TypeMismatch,
    DivisionByZero,
    UnknownFunction,
    AmbiguousFunction,
    ArityMismatch,
    UnknownBinding,
    InvalidLetBinding,
    InvalidCondClause,
    InvalidBinderShape,
    KeywordInExpressionArgs,
    DepthExceeded,
    MemoryBudgetExceeded,
    PluginFuncNotImplemented,
    PluginFuncResultType,
    PluginFuncFailed,
    PluginFuncTrapped,
    PluginFuncAllocFailed,
};

pub const BinaryError = Error || BinaryCursor.Error || error{MultipleRoots};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    value: Value,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }
};

pub fn eval(
    gpa: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    env: *const Env,
    schema: Schema.Schema,
) Error!Result {
    return evalWithRuntime(gpa, tree, idx, env, schema, null);
}

pub fn evalWithRuntime(
    gpa: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    env: *const Env,
    schema: Schema.Schema,
    runtime: ?*anyopaque,
) Error!Result {
    return evalWithRuntimeBudget(gpa, tree, idx, env, schema, runtime, MAX_EVAL_BYTES);
}

pub fn evalWithRuntimeBudget(
    gpa: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    env: *const Env,
    schema: Schema.Schema,
    runtime: ?*anyopaque,
    byte_budget: usize,
) Error!Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(gpa);
    var values: std.ArrayList(Value) = .empty;
    defer values.deinit(gpa);

    try frames.append(gpa, .{ .eval = .{ .idx = idx, .env = env } });

    for (0..MAX_STEPS) |_| {
        if (frames.items.len == 0) break;
        if (frames.items.len > MAX_FRAMES) return error.DepthExceeded;
        if (arena.queryCapacity() > byte_budget) return error.MemoryBudgetExceeded;

        const f = frames.pop().?;
        switch (f) {
            .eval => |e| try processEval(a, gpa, tree, e, &frames, &values, schema),
            .vec_collect => |vc| try processVecCollect(a, gpa, vc, &values),
            .apply_form => |af| try processApplyForm(a, gpa, af, &values, schema, runtime),
            .form_collect => |fc| try processFormCollect(a, gpa, fc, &values),
            .let_commit => |lc| processLetCommit(lc, &values),
            .if_select => |s| try processIfSelect(s, gpa, &frames, &values),
            .cond_select => |s| try processCondSelect(s, gpa, tree, &frames, &values),
            .and_check => |s| try processAndCheck(s, gpa, tree, &frames, &values),
            .or_check => |s| try processOrCheck(s, gpa, tree, &frames, &values),
            .binder_setup => |s| try processBinderSetup(a, gpa, s, &frames, &values),
            .binder_iter => |s| try processBinderIter(a, gpa, s, &frames, &values),
        }
    } else {
        return error.DepthExceeded;
    }

    std.debug.assert(values.items.len == 1);
    const final = try deepCopyValue(a, values.items[0]);
    if (arena.queryCapacity() > byte_budget) return error.MemoryBudgetExceeded;
    return .{ .arena = arena, .value = final };
}

pub fn deepCopyValue(a: Allocator, v: Value) Allocator.Error!Value {
    return switch (v) {
        .number, .integer_i64, .integer_u64, .boolean, .nil, .date, .time => v,
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .keyword => |k| .{ .keyword = try a.dupe(u8, k) },
        .vector => |xs| blk: {
            const dup = try a.alloc(Value, xs.len);
            for (xs, 0..) |x, i| dup[i] = try deepCopyValue(a, x);
            break :blk .{ .vector = dup };
        },
        .form => |f| blk: {
            const head = try a.dupe(u8, f.head);
            const ns = try a.dupe(u8, f.namespace);
            const children = try a.alloc(Value, f.children.len);
            for (f.children, 0..) |c, i| children[i] = try deepCopyValue(a, c);
            const kvs = try a.alloc(KvPair, f.kvpairs.len);
            for (f.kvpairs, 0..) |p, i| kvs[i] = .{
                .key = try a.dupe(u8, p.key),
                .value = try deepCopyValue(a, p.value),
            };
            break :blk .{ .form = .{
                .head = head,
                .namespace = ns,
                .children = children,
                .kvpairs = kvs,
            } };
        },
    };
}

pub const BinderKind = enum(u8) { map, filter, any, all, fold };

const Frame = union(enum) {
    eval: struct { idx: Ast.NodeIndex, env: *const Env },
    vec_collect: struct { count: u32 },
    apply_form: struct {
        head: []const u8,
        namespace: []const u8,
        argc: u32,
        slots: ?[]const u8 = null,
    },
    form_collect: struct {
        head: []const u8,
        namespace: []const u8,
        keys: []const ?[]const u8,
    },
    let_commit: struct {
        name: []const u8,
        env: *Env,
        env_buf: []Env.Binding,
        idx: u32,
    },
    if_select: struct {
        then_idx: Ast.NodeIndex,
        else_idx: Ast.NodeIndex,
        has_else: bool,
        env: *const Env,
    },
    cond_select: struct {
        value_idx: Ast.NodeIndex,
        remaining: []const Ast.NodeIndex,
        env: *const Env,
    },
    and_check: struct {
        remaining: []const Ast.NodeIndex,
        env: *const Env,
    },
    or_check: struct {
        remaining: []const Ast.NodeIndex,
        env: *const Env,
    },
    binder_setup: struct {
        kind: BinderKind,
        binder_name: []const u8,
        binder_acc_name: ?[]const u8,
        body_idx: Ast.NodeIndex,
        env_outer: *const Env,
    },
    binder_iter: struct {
        kind: BinderKind,
        body_idx: Ast.NodeIndex,
        inner_env: *Env,
        env_buf: []Env.Binding,
        xs_vec: []const Value,
        accumulator: []Value,
        accumulator_count: u32,
        i: u32,
        n: u32,
    },
};

fn processEval(
    a: Allocator,
    gpa: Allocator,
    tree: *const Ast.Tree,
    e: anytype,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
    schema: Schema.Schema,
) Error!void {
    const idx = e.idx;
    const env = e.env;
    switch (tree.tagOf(idx)) {
        .number => try values.append(gpa, .{ .number = tree.numberOf(idx) }),
        .number_i64 => try values.append(gpa, .{ .integer_i64 = tree.numberI64Of(idx) }),
        .number_u64 => try values.append(gpa, .{ .integer_u64 = tree.numberU64Of(idx) }),
        .number_with_unit => {
            const nu = tree.numberWithUnitOf(idx);
            try values.append(gpa, .{ .number = nu.value });
        },
        .boolean_true => try values.append(gpa, .{ .boolean = true }),
        .boolean_false => try values.append(gpa, .{ .boolean = false }),
        .nil => try values.append(gpa, .nil),
        .date => try values.append(gpa, .{ .date = tree.dateOf(idx) }),
        .time => try values.append(gpa, .{ .time = tree.timeOf(idx) }),
        .string => {
            const si: Ast.StringIndex = @enumFromInt(tree.dataOf(idx).single);
            try values.append(gpa, .{ .string = tree.stringSlice(si) });
        },
        .keyword => {
            const si: Ast.StringIndex = @enumFromInt(tree.dataOf(idx).single);
            try values.append(gpa, .{ .keyword = tree.stringSlice(si) });
        },
        .symbol => {
            const si: Ast.StringIndex = @enumFromInt(tree.dataOf(idx).single);
            const v = env.lookup(tree.stringSlice(si)) orelse return error.UnknownBinding;
            try values.append(gpa, v);
        },
        .vector => {
            const elements = tree.vectorElements(idx);
            const n: u32 = @intCast(elements.len);
            try frames.append(gpa, .{ .vec_collect = .{ .count = n } });
            var i: usize = elements.len;
            while (i > 0) {
                i -= 1;
                try frames.append(gpa, .{ .eval = .{ .idx = elements[i], .env = env } });
            }
        },
        .form => try scheduleForm(a, gpa, tree, idx, env, frames, values, schema),
        .kvpair => return error.KeywordInExpressionArgs,
    }
}

fn scheduleForm(
    a: Allocator,
    gpa: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    env: *const Env,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
    schema: Schema.Schema,
) Error!void {
    const hdr = tree.formHeader(idx);

    if (hdr.namespace == null) {
        if (eq(hdr.head, "let")) return scheduleLet(a, gpa, tree, hdr, env, frames);
        if (eq(hdr.head, "if")) return scheduleIf(gpa, tree, hdr, env, frames);
        if (eq(hdr.head, "cond")) return scheduleCond(gpa, tree, hdr, env, frames, values);
        if (eq(hdr.head, "and")) return scheduleAnd(gpa, tree, hdr, env, frames, values);
        if (eq(hdr.head, "or")) return scheduleOr(gpa, tree, hdr, env, frames, values);
        if (eq(hdr.head, "map")) return scheduleBinder(.map, gpa, tree, hdr, env, frames);
        if (eq(hdr.head, "filter")) return scheduleBinder(.filter, gpa, tree, hdr, env, frames);
        if (eq(hdr.head, "any")) return scheduleBinder(.any, gpa, tree, hdr, env, frames);
        if (eq(hdr.head, "all")) return scheduleBinder(.all, gpa, tree, hdr, env, frames);
        if (eq(hdr.head, "fold")) return scheduleBinder(.fold, gpa, tree, hdr, env, frames);
    }

    const lookup = schema.lookupExprFunc(hdr.head, hdr.namespace);
    if (lookup == .not_found) return scheduleFormCollect(a, gpa, tree, hdr, env, frames);

    const positional: []const Ast.NodeIndex = positional: {
        switch (lookup) {
            .found => |hit| {
                const r = try Schema.resolveExprArgs(a, hit.func.*, tree, hdr);
                switch (r) {
                    .ok => |ok| break :positional ok.positional,
                    .err => return error.KeywordInExpressionArgs,
                }
            },
            else => break :positional hdr.children,
        }
    };

    for (positional) |c| {
        if (tree.tagOf(c) == .kvpair) return error.KeywordInExpressionArgs;
    }

    const argc: u32 = @intCast(positional.len);
    try frames.append(gpa, .{ .apply_form = .{ .head = hdr.head, .namespace = hdr.namespace orelse "", .argc = argc } });
    var i: usize = positional.len;
    while (i > 0) {
        i -= 1;
        try frames.append(gpa, .{ .eval = .{ .idx = positional[i], .env = env } });
    }
}

fn scheduleFormCollect(
    a: Allocator,
    gpa: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    env: *const Env,
    frames: *std.ArrayList(Frame),
) Error!void {
    const keys = try a.alloc(?[]const u8, hdr.children.len);
    for (hdr.children, 0..) |c, i| {
        if (tree.tagOf(c) == .kvpair) {
            keys[i] = tree.kvpairHeader(c).key;
        } else {
            keys[i] = null;
        }
    }

    try frames.append(gpa, .{ .form_collect = .{
        .head = hdr.head,
        .namespace = hdr.namespace orelse "",
        .keys = keys,
    } });

    var i: usize = hdr.children.len;
    while (i > 0) {
        i -= 1;
        const c = hdr.children[i];
        if (tree.tagOf(c) == .kvpair) {
            const kv = tree.kvpairHeader(c);
            try frames.append(gpa, .{ .eval = .{ .idx = kv.value, .env = env } });
        } else {
            try frames.append(gpa, .{ .eval = .{ .idx = c, .env = env } });
        }
    }
}

fn processFormCollect(
    a: Allocator,
    gpa: Allocator,
    fc: anytype,
    values: *std.ArrayList(Value),
) Error!void {
    const total: u32 = @intCast(fc.keys.len);
    std.debug.assert(values.items.len >= total);
    const base = values.items.len - total;

    var positional_count: u32 = 0;
    for (fc.keys) |k| {
        if (k == null) positional_count += 1;
    }
    const kv_count: u32 = total - positional_count;

    const children = try a.alloc(Value, positional_count);
    const kvs = try a.alloc(KvPair, kv_count);
    var ci: u32 = 0;
    var ki: u32 = 0;
    for (fc.keys, 0..) |k, i| {
        const v = values.items[base + i];
        if (k) |key| {
            kvs[ki] = .{ .key = key, .value = v };
            ki += 1;
        } else {
            children[ci] = v;
            ci += 1;
        }
    }
    std.debug.assert(ci == positional_count);
    std.debug.assert(ki == kv_count);
    values.items.len = base;
    try values.append(gpa, .{ .form = .{
        .head = fc.head,
        .namespace = fc.namespace,
        .children = children,
        .kvpairs = kvs,
    } });
}

fn scheduleLet(
    a: Allocator,
    gpa: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    env: *const Env,
    frames: *std.ArrayList(Frame),
) Error!void {
    if (hdr.children.len != 2) return error.ArityMismatch;
    const binds_idx = hdr.children[0];
    if (tree.tagOf(binds_idx) == .kvpair) return error.InvalidLetBinding;
    if (tree.tagOf(binds_idx) != .vector) return error.InvalidLetBinding;
    const binds = tree.vectorElements(binds_idx);
    if (binds.len % 2 != 0) return error.InvalidLetBinding;

    const pair_count: u32 = @intCast(binds.len / 2);

    const env_buf = try a.alloc(Env.Binding, pair_count);
    const inner_env = try a.create(Env);
    inner_env.* = .{ .parent = env, .bindings = env_buf[0..0] };

    const body_idx = hdr.children[1];
    if (tree.tagOf(body_idx) == .kvpair) return error.InvalidLetBinding;

    try frames.append(gpa, .{ .eval = .{ .idx = body_idx, .env = inner_env } });
    var i: usize = pair_count;
    while (i > 0) {
        i -= 1;
        const name_idx = binds[2 * i];
        const value_idx = binds[2 * i + 1];
        if (tree.tagOf(name_idx) != .symbol) return error.InvalidLetBinding;
        const name_si: Ast.StringIndex = @enumFromInt(tree.dataOf(name_idx).single);
        const name = tree.stringSlice(name_si);
        try frames.append(gpa, .{ .let_commit = .{
            .name = name,
            .env = inner_env,
            .env_buf = env_buf,
            .idx = @intCast(i),
        } });
        try frames.append(gpa, .{ .eval = .{ .idx = value_idx, .env = inner_env } });
    }
}

fn scheduleIf(
    gpa: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    env: *const Env,
    frames: *std.ArrayList(Frame),
) Error!void {
    if (hdr.children.len < 2 or hdr.children.len > 3) return error.ArityMismatch;
    const test_idx = hdr.children[0];
    const then_idx = hdr.children[1];
    if (tree.tagOf(test_idx) == .kvpair) return error.KeywordInExpressionArgs;
    if (tree.tagOf(then_idx) == .kvpair) return error.KeywordInExpressionArgs;
    var has_else = false;
    var else_idx: Ast.NodeIndex = then_idx;
    if (hdr.children.len == 3) {
        else_idx = hdr.children[2];
        if (tree.tagOf(else_idx) == .kvpair) return error.KeywordInExpressionArgs;
        has_else = true;
    }

    try frames.append(gpa, .{ .if_select = .{
        .then_idx = then_idx,
        .else_idx = else_idx,
        .has_else = has_else,
        .env = env,
    } });
    try frames.append(gpa, .{ .eval = .{ .idx = test_idx, .env = env } });
}

fn scheduleCond(
    gpa: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    env: *const Env,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
) Error!void {
    if (hdr.children.len % 2 != 0) return error.InvalidCondClause;
    if (hdr.children.len == 0) {
        try values.append(gpa, .nil);
        return;
    }
    const t_idx = hdr.children[0];
    const v_idx = hdr.children[1];
    if (tree.tagOf(t_idx) == .kvpair) return error.KeywordInExpressionArgs;
    if (tree.tagOf(v_idx) == .kvpair) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .cond_select = .{
        .value_idx = v_idx,
        .remaining = hdr.children[2..],
        .env = env,
    } });
    try frames.append(gpa, .{ .eval = .{ .idx = t_idx, .env = env } });
}

fn scheduleAnd(
    gpa: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    env: *const Env,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
) Error!void {
    if (hdr.children.len == 0) {
        try values.append(gpa, .{ .boolean = true });
        return;
    }
    const first = hdr.children[0];
    if (tree.tagOf(first) == .kvpair) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .and_check = .{ .remaining = hdr.children[1..], .env = env } });
    try frames.append(gpa, .{ .eval = .{ .idx = first, .env = env } });
}

fn scheduleOr(
    gpa: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    env: *const Env,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
) Error!void {
    if (hdr.children.len == 0) {
        try values.append(gpa, .{ .boolean = false });
        return;
    }
    const first = hdr.children[0];
    if (tree.tagOf(first) == .kvpair) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .or_check = .{ .remaining = hdr.children[1..], .env = env } });
    try frames.append(gpa, .{ .eval = .{ .idx = first, .env = env } });
}

fn scheduleBinder(
    kind: BinderKind,
    gpa: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    env: *const Env,
    frames: *std.ArrayList(Frame),
) Error!void {
    if (kind == .fold) {
        if (hdr.children.len != 4) return error.ArityMismatch;
        const binder_idx = hdr.children[0];
        const init_idx = hdr.children[1];
        const xs_idx = hdr.children[2];
        const body_idx = hdr.children[3];

        if (tree.tagOf(binder_idx) != .vector) return error.InvalidBinderShape;
        const binder_elems = tree.vectorElements(binder_idx);
        if (binder_elems.len != 2) return error.InvalidBinderShape;
        if (tree.tagOf(binder_elems[0]) != .symbol) return error.InvalidBinderShape;
        if (tree.tagOf(binder_elems[1]) != .symbol) return error.InvalidBinderShape;
        const acc_si: Ast.StringIndex = @enumFromInt(tree.dataOf(binder_elems[0]).single);
        const x_si: Ast.StringIndex = @enumFromInt(tree.dataOf(binder_elems[1]).single);
        const acc_name = tree.stringSlice(acc_si);
        const x_name = tree.stringSlice(x_si);
        if (std.mem.eql(u8, acc_name, x_name)) return error.InvalidBinderShape;

        if (tree.tagOf(init_idx) == .kvpair) return error.KeywordInExpressionArgs;
        if (tree.tagOf(xs_idx) == .kvpair) return error.KeywordInExpressionArgs;
        if (tree.tagOf(body_idx) == .kvpair) return error.KeywordInExpressionArgs;

        try frames.append(gpa, .{ .binder_setup = .{
            .kind = .fold,
            .binder_name = x_name,
            .binder_acc_name = acc_name,
            .body_idx = body_idx,
            .env_outer = env,
        } });
        try frames.append(gpa, .{ .eval = .{ .idx = xs_idx, .env = env } });
        try frames.append(gpa, .{ .eval = .{ .idx = init_idx, .env = env } });
        return;
    }

    if (hdr.children.len != 3) return error.ArityMismatch;
    const binder_idx = hdr.children[0];
    const xs_idx = hdr.children[1];
    const body_idx = hdr.children[2];

    if (tree.tagOf(binder_idx) != .vector) return error.InvalidBinderShape;
    const binder_elems = tree.vectorElements(binder_idx);
    if (binder_elems.len != 1) return error.InvalidBinderShape;
    if (tree.tagOf(binder_elems[0]) != .symbol) return error.InvalidBinderShape;
    const name_si: Ast.StringIndex = @enumFromInt(tree.dataOf(binder_elems[0]).single);
    const binder_name = tree.stringSlice(name_si);

    if (tree.tagOf(xs_idx) == .kvpair) return error.KeywordInExpressionArgs;
    if (tree.tagOf(body_idx) == .kvpair) return error.KeywordInExpressionArgs;

    try frames.append(gpa, .{ .binder_setup = .{
        .kind = kind,
        .binder_name = binder_name,
        .binder_acc_name = null,
        .body_idx = body_idx,
        .env_outer = env,
    } });
    try frames.append(gpa, .{ .eval = .{ .idx = xs_idx, .env = env } });
}

fn processBinderSetup(
    a: Allocator,
    gpa: Allocator,
    s: anytype,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
) Error!void {
    const fold_extra: usize = if (s.kind == .fold) 1 else 0;
    std.debug.assert(values.items.len >= 1 + fold_extra);
    const xs_val = values.pop().?;
    const xs_vec = try expectVector(xs_val);
    const init_val: ?Value = if (s.kind == .fold) values.pop().? else null;
    const n: u32 = @intCast(xs_vec.len);

    if (n == 0) {
        switch (s.kind) {
            .map, .filter => try values.append(gpa, .{ .vector = &.{} }),
            .any => try values.append(gpa, .{ .boolean = false }),
            .all => try values.append(gpa, .{ .boolean = true }),
            .fold => try values.append(gpa, init_val.?),
        }
        return;
    }

    const env_buf: []Env.Binding = switch (s.kind) {
        .fold => blk: {
            const buf = try a.alloc(Env.Binding, 2);
            buf[0] = .{ .name = s.binder_acc_name.?, .value = init_val.? };
            buf[1] = .{ .name = s.binder_name, .value = xs_vec[0] };
            break :blk buf;
        },
        else => blk: {
            const buf = try a.alloc(Env.Binding, 1);
            buf[0] = .{ .name = s.binder_name, .value = xs_vec[0] };
            break :blk buf;
        },
    };
    const inner_env = try a.create(Env);
    inner_env.* = .{ .parent = s.env_outer, .bindings = env_buf };

    const accumulator: []Value = switch (s.kind) {
        .map, .filter => try a.alloc(Value, n),
        .any, .all, .fold => &.{},
    };

    try frames.append(gpa, .{ .binder_iter = .{
        .kind = s.kind,
        .body_idx = s.body_idx,
        .inner_env = inner_env,
        .env_buf = env_buf,
        .xs_vec = xs_vec,
        .accumulator = accumulator,
        .accumulator_count = 0,
        .i = 0,
        .n = n,
    } });
    try frames.append(gpa, .{ .eval = .{ .idx = s.body_idx, .env = inner_env } });
}

fn processBinderIter(
    a: Allocator,
    gpa: Allocator,
    s: anytype,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
) Error!void {
    std.debug.assert(values.items.len >= 1);
    const body_val = values.pop().?;

    const next_i: u32 = s.i + 1;
    var next_count: u32 = s.accumulator_count;

    switch (s.kind) {
        .map => {
            s.accumulator[s.i] = body_val;
            next_count = next_i;
        },
        .filter => {
            if (body_val.isTruthy()) {
                s.accumulator[s.accumulator_count] = s.xs_vec[s.i];
                next_count = s.accumulator_count + 1;
            }
        },
        .any => {
            if (body_val.isTruthy()) {
                try values.append(gpa, .{ .boolean = true });
                return;
            }
        },
        .all => {
            if (!body_val.isTruthy()) {
                try values.append(gpa, .{ .boolean = false });
                return;
            }
        },
        .fold => {},
    }

    if (next_i == s.n) {
        switch (s.kind) {
            .map => try values.append(gpa, .{ .vector = s.accumulator }),
            .filter => try values.append(gpa, .{ .vector = s.accumulator[0..next_count] }),
            .any => try values.append(gpa, .{ .boolean = false }),
            .all => try values.append(gpa, .{ .boolean = true }),
            .fold => try values.append(gpa, body_val),
        }
        return;
    }

    if (s.kind == .fold) {
        s.env_buf[0].value = body_val;
        s.env_buf[1].value = s.xs_vec[next_i];
    } else {
        s.env_buf[0].value = s.xs_vec[next_i];
    }

    _ = a;
    try frames.append(gpa, .{ .binder_iter = .{
        .kind = s.kind,
        .body_idx = s.body_idx,
        .inner_env = s.inner_env,
        .env_buf = s.env_buf,
        .xs_vec = s.xs_vec,
        .accumulator = s.accumulator,
        .accumulator_count = next_count,
        .i = next_i,
        .n = s.n,
    } });
    try frames.append(gpa, .{ .eval = .{ .idx = s.body_idx, .env = s.inner_env } });
}

fn processVecCollect(
    a: Allocator,
    gpa: Allocator,
    vc: anytype,
    values: *std.ArrayList(Value),
) Error!void {
    const count: usize = vc.count;
    std.debug.assert(values.items.len >= count);
    const elems = try a.alloc(Value, count);
    var i: usize = count;
    while (i > 0) {
        i -= 1;
        elems[i] = values.pop().?;
    }
    try values.append(gpa, .{ .vector = elems });
}

fn processApplyForm(
    a: Allocator,
    gpa: Allocator,
    af: anytype,
    values: *std.ArrayList(Value),
    schema: Schema.Schema,
    runtime: ?*anyopaque,
) Error!void {
    const argc: usize = af.argc;
    std.debug.assert(values.items.len >= argc);
    if (af.slots) |slots| std.debug.assert(slots.len == argc);

    const args = try a.alloc(Value, argc);
    var i: usize = argc;
    while (i > 0) {
        i -= 1;
        args[i] = values.pop().?;
    }
    if (af.slots) |slots| {
        const final = try a.alloc(Value, argc);
        for (0..argc) |k| final[slots[k]] = args[k];
        const result = try applyFunction(a, af.head, af.namespace, final, schema, runtime);
        try values.append(gpa, result);
        return;
    }
    const result = try applyFunction(a, af.head, af.namespace, args, schema, runtime);
    try values.append(gpa, result);
}

fn processLetCommit(
    lc: anytype,
    values: *std.ArrayList(Value),
) void {
    std.debug.assert(values.items.len >= 1);
    std.debug.assert(lc.idx < lc.env_buf.len);

    const v = values.pop().?;
    lc.env_buf[lc.idx] = .{ .name = lc.name, .value = v };
    lc.env.bindings = lc.env_buf[0 .. lc.idx + 1];
}

fn processIfSelect(
    s: anytype,
    gpa: Allocator,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
) Error!void {
    const test_v = values.pop().?;
    if (test_v.isTruthy()) {
        try frames.append(gpa, .{ .eval = .{ .idx = s.then_idx, .env = s.env } });
    } else if (s.has_else) {
        try frames.append(gpa, .{ .eval = .{ .idx = s.else_idx, .env = s.env } });
    } else {
        try values.append(gpa, .nil);
    }
}

fn processCondSelect(
    s: anytype,
    gpa: Allocator,
    tree: *const Ast.Tree,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
) Error!void {
    const test_v = values.pop().?;
    if (test_v.isTruthy()) {
        try frames.append(gpa, .{ .eval = .{ .idx = s.value_idx, .env = s.env } });
        return;
    }
    if (s.remaining.len == 0) {
        try values.append(gpa, .nil);
        return;
    }
    const t_idx = s.remaining[0];
    const v_idx = s.remaining[1];
    if (tree.tagOf(t_idx) == .kvpair) return error.KeywordInExpressionArgs;
    if (tree.tagOf(v_idx) == .kvpair) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .cond_select = .{
        .value_idx = v_idx,
        .remaining = s.remaining[2..],
        .env = s.env,
    } });
    try frames.append(gpa, .{ .eval = .{ .idx = t_idx, .env = s.env } });
}

fn processAndCheck(
    s: anytype,
    gpa: Allocator,
    tree: *const Ast.Tree,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
) Error!void {
    const v = values.pop().?;
    if (!v.isTruthy()) {
        try values.append(gpa, v);
        return;
    }
    if (s.remaining.len == 0) {
        try values.append(gpa, v);
        return;
    }
    const next = s.remaining[0];
    if (tree.tagOf(next) == .kvpair) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .and_check = .{ .remaining = s.remaining[1..], .env = s.env } });
    try frames.append(gpa, .{ .eval = .{ .idx = next, .env = s.env } });
}

fn processOrCheck(
    s: anytype,
    gpa: Allocator,
    tree: *const Ast.Tree,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
) Error!void {
    const v = values.pop().?;
    if (v.isTruthy()) {
        try values.append(gpa, v);
        return;
    }
    if (s.remaining.len == 0) {
        try values.append(gpa, .{ .boolean = false });
        return;
    }
    const next = s.remaining[0];
    if (tree.tagOf(next) == .kvpair) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .or_check = .{ .remaining = s.remaining[1..], .env = s.env } });
    try frames.append(gpa, .{ .eval = .{ .idx = next, .env = s.env } });
}

const FrameBinary = union(enum) {
    eval: struct {
        view: BinaryCursor.NodeView,
        env: *const Env,
    },

    vec_collect: struct { count: u32 },

    apply_form: struct {
        head: []const u8,
        namespace: []const u8,
        argc: u32,
        slots: ?[]const u8 = null,
    },

    let_commit: struct {
        name: []const u8,
        env: *Env,
        env_buf: []Env.Binding,
        idx: u32,
    },

    vec_walk: struct {
        iter: BinaryCursor.VectorIter,
        env: *const Env,
        consumed: u32,
        count: u32,
    },

    form_walk: struct {
        head: []const u8,
        namespace: []const u8,
        iter: BinaryCursor.ChildIter,
        env: *const Env,
        consumed: u32,
        argc: u32,
        labeled_sig: ?Plugin.ExprFunc.Signature = null,
        slots: ?[]u8 = null,
    },

    form_collect_walk: struct {
        head: []const u8,
        namespace: []const u8,
        iter: BinaryCursor.ChildIter,
        env: *const Env,
        consumed: u32,
        argc: u32,
        keys: []?[]const u8,
    },

    let_walk: struct {
        form_iter: BinaryCursor.ChildIter,
        inner_env: *Env,
        env_buf: []Env.Binding,
        binds_iter: BinaryCursor.VectorIter,
        idx: u32,
        pair_count: u32,
    },

    if_after_test: struct {
        iter: BinaryCursor.ChildIter,
        env: *const Env,
        has_else: bool,
    },

    cond_after_pred: struct {
        iter: BinaryCursor.ChildIter,
        env: *const Env,
    },

    and_after_child: struct {
        iter: BinaryCursor.ChildIter,
        env: *const Env,
    },

    binder_setup_binary: struct {
        kind: BinderKind,
        binder_name: []const u8,
        binder_acc_name: ?[]const u8,
        form_iter: BinaryCursor.ChildIter,
        env_outer: *const Env,
        init_val_captured: ?Value,
    },
    fold_capture_init: struct {
        binder_name: []const u8,
        binder_acc_name: []const u8,
        form_iter: BinaryCursor.ChildIter,
        env_outer: *const Env,
    },
    binder_iter_binary: struct {
        kind: BinderKind,
        body_view: BinaryCursor.NodeView,
        body_payload_pos: u32,
        post_form_pos: u32,
        inner_env: *Env,
        env_buf: []Env.Binding,
        xs_vec: []const Value,
        accumulator: []Value,
        accumulator_count: u32,
        i: u32,
        n: u32,
    },
    or_after_child: struct {
        iter: BinaryCursor.ChildIter,
        env: *const Env,
    },

    form_drain: struct { iter: BinaryCursor.ChildIter },
};

pub fn evalBinary(
    gpa: Allocator,
    bytes: []const u8,
    env: *const Env,
    schema: Schema.Schema,
) BinaryError!Result {
    return evalBinaryWithRuntime(gpa, bytes, env, schema, null);
}

pub fn evalBinaryWithRuntime(
    gpa: Allocator,
    bytes: []const u8,
    env: *const Env,
    schema: Schema.Schema,
    runtime: ?*anyopaque,
) BinaryError!Result {
    return evalBinaryWithRuntimeBudget(gpa, bytes, env, schema, runtime, MAX_EVAL_BYTES);
}

pub fn evalBinaryWithRuntimeBudget(
    gpa: Allocator,
    bytes: []const u8,
    env: *const Env,
    schema: Schema.Schema,
    runtime: ?*anyopaque,
    byte_budget: usize,
) BinaryError!Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var cursor = try BinaryCursor.Cursor.init(bytes);
    var root_iter = try cursor.rootIter();
    if (root_iter.remaining != 1) return error.MultipleRoots;
    const root_view = (try root_iter.next()) orelse unreachable;

    var frames: std.ArrayList(FrameBinary) = .empty;
    defer frames.deinit(gpa);
    var values: std.ArrayList(Value) = .empty;
    defer values.deinit(gpa);

    try frames.append(gpa, .{ .eval = .{ .view = root_view, .env = env } });

    for (0..MAX_STEPS) |_| {
        if (frames.items.len == 0) break;
        if (frames.items.len > MAX_FRAMES) return error.DepthExceeded;
        if (arena.queryCapacity() > byte_budget) return error.MemoryBudgetExceeded;

        const f = frames.pop().?;
        switch (f) {
            .eval => |e| try processEvalBinary(a, gpa, &cursor, e, &frames, &values, schema),
            .vec_collect => |vc| try processVecCollect(a, gpa, vc, &values),
            .apply_form => |af| try processApplyForm(a, gpa, af, &values, schema, runtime),
            .let_commit => |lc| processLetCommit(lc, &values),
            .vec_walk => |vw| try processVecWalk(gpa, vw, &frames),
            .form_walk => |fw| try processFormWalk(a, gpa, fw, &frames, schema),
            .form_collect_walk => |fc| try processFormCollectWalk(a, gpa, fc, &frames, &values),
            .let_walk => |lw| try processLetWalk(gpa, &cursor, lw, &frames),
            .if_after_test => |s| try processIfAfterTest(gpa, &cursor, s, &frames, &values),
            .cond_after_pred => |s| try processCondAfterPred(gpa, &cursor, s, &frames, &values),
            .and_after_child => |s| try processAndAfterChild(gpa, s, &frames, &values),
            .or_after_child => |s| try processOrAfterChild(gpa, s, &frames, &values),
            .form_drain => |s| try processFormDrain(s.iter),
            .binder_setup_binary => |s| try processBinderSetupBinary(a, gpa, &cursor, s, &frames, &values),
            .binder_iter_binary => |s| try processBinderIterBinary(gpa, &cursor, s, &frames, &values),
            .fold_capture_init => |s| try processFoldCaptureInit(gpa, s, &frames, &values),
        }
    } else {
        return error.DepthExceeded;
    }

    std.debug.assert(values.items.len == 1);
    const final = try deepCopyValue(a, values.items[0]);
    if (arena.queryCapacity() > byte_budget) return error.MemoryBudgetExceeded;
    return .{ .arena = arena, .value = final };
}

fn processEvalBinary(
    a: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    e: anytype,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
    schema: Schema.Schema,
) BinaryError!void {
    const view = e.view;
    const env = e.env;
    switch (view.kind) {
        .nil => {
            try BinaryCursor.readNil(cursor, view);
            try values.append(gpa, .nil);
        },
        .boolean => {
            const b = try BinaryCursor.readBoolean(cursor, view);
            try values.append(gpa, .{ .boolean = b });
        },
        .number => switch (view.tag_byte) {
            0x03 => {
                const x = try BinaryCursor.readNumber(cursor, view);
                try values.append(gpa, .{ .number = x });
            },
            0x0B => {
                const x = try BinaryCursor.readNumberI64(cursor, view);
                try values.append(gpa, .{ .integer_i64 = x });
            },
            0x0C => {
                const x = try BinaryCursor.readNumberU64(cursor, view);
                try values.append(gpa, .{ .integer_u64 = x });
            },
            else => unreachable,
        },
        .number_with_unit => {
            const nu = try BinaryCursor.readNumberWithUnit(cursor, view);
            try values.append(gpa, .{ .number = nu.value });
        },
        .date => {
            const d = try BinaryCursor.readDate(cursor, view);
            try values.append(gpa, .{ .date = d });
        },
        .time => {
            const t = try BinaryCursor.readTime(cursor, view);
            try values.append(gpa, .{ .time = t });
        },
        .string => {
            const s = try BinaryCursor.readString(cursor, view);
            try values.append(gpa, .{ .string = s });
        },
        .keyword => {
            const k = try BinaryCursor.readKeyword(cursor, view);
            try values.append(gpa, .{ .keyword = k });
        },
        .symbol => {
            const sym = try BinaryCursor.readSymbol(cursor, view);
            const v = env.lookup(sym) orelse return error.UnknownBinding;
            try values.append(gpa, v);
        },
        .vector => {
            const iter = try BinaryCursor.readVector(cursor, view);
            const n = iter.remaining;
            try frames.append(gpa, .{ .vec_walk = .{
                .iter = iter,
                .env = env,
                .consumed = 0,
                .count = n,
            } });
        },
        .form => try scheduleFormBinary(a, gpa, cursor, view, env, frames, values, schema),
    }
}

fn scheduleFormBinary(
    a: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    view: BinaryCursor.NodeView,
    env: *const Env,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
    schema: Schema.Schema,
) BinaryError!void {
    const fv = try BinaryCursor.readForm(cursor, view);
    const head = fv.head;

    if (fv.namespace == null) {
        if (eq(head, "let")) return scheduleLetBinary(a, gpa, cursor, fv, env, frames);
        if (eq(head, "if")) return scheduleIfBinary(gpa, fv, env, frames);
        if (eq(head, "cond")) return scheduleCondBinary(gpa, fv, env, frames, values);
        if (eq(head, "and")) return scheduleAndBinary(gpa, fv, env, frames, values);
        if (eq(head, "or")) return scheduleOrBinary(gpa, fv, env, frames, values);
        if (eq(head, "map")) return scheduleBinderBinary(.map, gpa, cursor, fv, env, frames);
        if (eq(head, "filter")) return scheduleBinderBinary(.filter, gpa, cursor, fv, env, frames);
        if (eq(head, "any")) return scheduleBinderBinary(.any, gpa, cursor, fv, env, frames);
        if (eq(head, "all")) return scheduleBinderBinary(.all, gpa, cursor, fv, env, frames);
        if (eq(head, "fold")) return scheduleBinderBinary(.fold, gpa, cursor, fv, env, frames);
    }

    const argc = fv.children.remaining;

    if (schema.lookupExprFunc(head, fv.namespace) == .not_found) {
        const keys = try a.alloc(?[]const u8, argc);
        for (keys) |*k| k.* = null;
        try frames.append(gpa, .{ .form_collect_walk = .{
            .head = head,
            .namespace = fv.namespace orelse "",
            .iter = fv.children,
            .env = env,
            .consumed = 0,
            .argc = argc,
            .keys = keys,
        } });
        return;
    }

    try frames.append(gpa, .{ .form_walk = .{
        .head = head,
        .namespace = fv.namespace orelse "",
        .iter = fv.children,
        .env = env,
        .consumed = 0,
        .argc = argc,
    } });
}

fn processFormCollectWalk(
    a: Allocator,
    gpa: Allocator,
    fc: anytype,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    var iter = fc.iter;
    if (fc.consumed == fc.argc) {
        _ = try iter.next();
        const base = values.items.len - fc.argc;
        std.debug.assert(values.items.len >= fc.argc);

        var positional_count: u32 = 0;
        for (fc.keys) |k| {
            if (k == null) positional_count += 1;
        }
        const kv_count: u32 = fc.argc - positional_count;

        const children = try a.alloc(Value, positional_count);
        const kvs = try a.alloc(KvPair, kv_count);
        var ci: u32 = 0;
        var ki: u32 = 0;
        for (fc.keys, 0..) |k, i| {
            const v = values.items[base + i];
            if (k) |key| {
                kvs[ki] = .{ .key = key, .value = v };
                ki += 1;
            } else {
                children[ci] = v;
                ci += 1;
            }
        }
        std.debug.assert(ci == positional_count);
        std.debug.assert(ki == kv_count);
        values.items.len = base;
        try values.append(gpa, .{ .form = .{
            .head = fc.head,
            .namespace = fc.namespace,
            .children = children,
            .kvpairs = kvs,
        } });
        return;
    }

    const entry = (try iter.next()) orelse unreachable;
    var keys = fc.keys;
    if (entry.kind == .keyword) {
        keys[fc.consumed] = try a.dupe(u8, entry.key.?);
    }
    try frames.append(gpa, .{ .form_collect_walk = .{
        .head = fc.head,
        .namespace = fc.namespace,
        .iter = iter,
        .env = fc.env,
        .consumed = fc.consumed + 1,
        .argc = fc.argc,
        .keys = keys,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = entry.value, .env = fc.env } });
}

fn processFormWalk(
    a: Allocator,
    gpa: Allocator,
    fw: anytype,
    frames: *std.ArrayList(FrameBinary),
    schema: Schema.Schema,
) BinaryError!void {
    var iter = fw.iter;
    if (fw.consumed == fw.argc) {
        _ = try iter.next();
        try frames.append(gpa, .{ .apply_form = .{
            .head = fw.head,
            .namespace = fw.namespace,
            .argc = fw.argc,
            .slots = fw.slots,
        } });
        return;
    }
    const entry = (try iter.next()) orelse unreachable;

    var labeled_sig = fw.labeled_sig;
    var slots = fw.slots;
    if (entry.kind == .keyword) {
        if (labeled_sig == null) {
            const ns: ?[]const u8 = if (fw.namespace.len == 0) null else fw.namespace;
            switch (schema.lookupExprFunc(fw.head, ns)) {
                .found => |hit| {
                    var it = hit.func.signatureIter();
                    while (it.next()) |sig| {
                        if (sig.labeledEnabled() and sig.checkArity(fw.argc)) {
                            labeled_sig = sig;
                            slots = try a.alloc(u8, fw.argc);
                            break;
                        }
                    }
                },
                else => {},
            }
            if (labeled_sig == null) return error.KeywordInExpressionArgs;
        }
        const slot = labeled_sig.?.indexOfLabel(entry.key.?) orelse return error.KeywordInExpressionArgs;
        slots.?[fw.consumed] = slot;
    } else if (labeled_sig != null) {
        return error.KeywordInExpressionArgs;
    }

    try frames.append(gpa, .{ .form_walk = .{
        .head = fw.head,
        .namespace = fw.namespace,
        .iter = iter,
        .env = fw.env,
        .consumed = fw.consumed + 1,
        .argc = fw.argc,
        .labeled_sig = labeled_sig,
        .slots = slots,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = entry.value, .env = fw.env } });
}

fn processVecWalk(
    gpa: Allocator,
    vw: anytype,
    frames: *std.ArrayList(FrameBinary),
) BinaryError!void {
    var iter = vw.iter;
    if (vw.consumed == vw.count) {
        try frames.append(gpa, .{ .vec_collect = .{ .count = vw.count } });
        return;
    }
    const elem_view = (try iter.next()) orelse unreachable;
    try frames.append(gpa, .{ .vec_walk = .{
        .iter = iter,
        .env = vw.env,
        .consumed = vw.consumed + 1,
        .count = vw.count,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = elem_view, .env = vw.env } });
}

fn scheduleLetBinary(
    a: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    fv: BinaryCursor.FormView,
    env: *const Env,
    frames: *std.ArrayList(FrameBinary),
) BinaryError!void {
    var form_iter = fv.children;
    if (form_iter.remaining != 2) return error.ArityMismatch;

    const binds_entry = (try form_iter.next()) orelse unreachable;
    if (binds_entry.kind == .keyword) return error.InvalidLetBinding;
    if (binds_entry.value.kind != .vector) return error.InvalidLetBinding;
    const binds_iter = try BinaryCursor.readVector(cursor, binds_entry.value);
    if (binds_iter.remaining % 2 != 0) return error.InvalidLetBinding;

    const pair_count: u32 = binds_iter.remaining / 2;

    const env_buf = try a.alloc(Env.Binding, pair_count);
    const inner_env = try a.create(Env);
    inner_env.* = .{ .parent = env, .bindings = env_buf[0..0] };

    try frames.append(gpa, .{ .let_walk = .{
        .form_iter = form_iter,
        .inner_env = inner_env,
        .env_buf = env_buf,
        .binds_iter = binds_iter,
        .idx = 0,
        .pair_count = pair_count,
    } });
}

fn processLetWalk(
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    lw: anytype,
    frames: *std.ArrayList(FrameBinary),
) BinaryError!void {
    var binds_iter = lw.binds_iter;
    var form_iter = lw.form_iter;

    if (lw.idx == lw.pair_count) {
        const body_entry = (try form_iter.next()) orelse unreachable;
        if (body_entry.kind == .keyword) return error.InvalidLetBinding;
        try frames.append(gpa, .{ .form_drain = .{ .iter = form_iter } });
        try frames.append(gpa, .{ .eval = .{ .view = body_entry.value, .env = lw.inner_env } });
        return;
    }

    const name_view = (try binds_iter.next()) orelse return error.InvalidLetBinding;
    if (name_view.kind != .symbol) return error.InvalidLetBinding;
    const name = try BinaryCursor.readSymbol(cursor, name_view);

    const value_view = (try binds_iter.next()) orelse return error.InvalidLetBinding;

    try frames.append(gpa, .{ .let_walk = .{
        .form_iter = form_iter,
        .inner_env = lw.inner_env,
        .env_buf = lw.env_buf,
        .binds_iter = binds_iter,
        .idx = lw.idx + 1,
        .pair_count = lw.pair_count,
    } });
    try frames.append(gpa, .{ .let_commit = .{
        .name = name,
        .env = lw.inner_env,
        .env_buf = lw.env_buf,
        .idx = lw.idx,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = value_view, .env = lw.inner_env } });
}

fn scheduleIfBinary(
    gpa: Allocator,
    fv: BinaryCursor.FormView,
    env: *const Env,
    frames: *std.ArrayList(FrameBinary),
) BinaryError!void {
    var iter = fv.children;
    if (iter.remaining < 2 or iter.remaining > 3) return error.ArityMismatch;
    const has_else = iter.remaining == 3;

    const test_entry = (try iter.next()) orelse unreachable;
    if (test_entry.kind == .keyword) return error.KeywordInExpressionArgs;

    try frames.append(gpa, .{ .if_after_test = .{
        .iter = iter,
        .env = env,
        .has_else = has_else,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = test_entry.value, .env = env } });
}

fn processIfAfterTest(
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    s: anytype,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    const test_v = values.pop().?;
    var iter = s.iter;
    const truthy = test_v.isTruthy();

    const then_entry = (try iter.next()) orelse unreachable;
    if (then_entry.kind == .keyword) return error.KeywordInExpressionArgs;

    if (truthy) {
        try frames.append(gpa, .{ .form_drain = .{ .iter = iter } });
        try frames.append(gpa, .{ .eval = .{ .view = then_entry.value, .env = s.env } });
    } else {
        try BinaryCursor.skipBody(cursor, then_entry.value);
        if (s.has_else) {
            const else_entry = (try iter.next()) orelse unreachable;
            if (else_entry.kind == .keyword) return error.KeywordInExpressionArgs;
            try frames.append(gpa, .{ .form_drain = .{ .iter = iter } });
            try frames.append(gpa, .{ .eval = .{ .view = else_entry.value, .env = s.env } });
        } else {
            _ = try iter.next();
            try values.append(gpa, .nil);
        }
    }
}

fn scheduleCondBinary(
    gpa: Allocator,
    fv: BinaryCursor.FormView,
    env: *const Env,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    var iter = fv.children;
    if (iter.remaining % 2 != 0) return error.InvalidCondClause;
    if (iter.remaining == 0) {
        _ = try iter.next();
        try values.append(gpa, .nil);
        return;
    }
    const pred_entry = (try iter.next()) orelse unreachable;
    if (pred_entry.kind == .keyword) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .cond_after_pred = .{
        .iter = iter,
        .env = env,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = pred_entry.value, .env = env } });
}

fn processCondAfterPred(
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    s: anytype,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    const test_v = values.pop().?;
    var iter = s.iter;
    const truthy = test_v.isTruthy();

    const value_entry = (try iter.next()) orelse unreachable;
    if (value_entry.kind == .keyword) return error.KeywordInExpressionArgs;

    if (truthy) {
        try frames.append(gpa, .{ .form_drain = .{ .iter = iter } });
        try frames.append(gpa, .{ .eval = .{ .view = value_entry.value, .env = s.env } });
        return;
    }
    try BinaryCursor.skipBody(cursor, value_entry.value);
    if (iter.remaining == 0) {
        _ = try iter.next();
        try values.append(gpa, .nil);
        return;
    }
    const next_pred = (try iter.next()) orelse unreachable;
    if (next_pred.kind == .keyword) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .cond_after_pred = .{
        .iter = iter,
        .env = s.env,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = next_pred.value, .env = s.env } });
}

fn scheduleAndBinary(
    gpa: Allocator,
    fv: BinaryCursor.FormView,
    env: *const Env,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    var iter = fv.children;
    if (iter.remaining == 0) {
        _ = try iter.next();
        try values.append(gpa, .{ .boolean = true });
        return;
    }
    const first = (try iter.next()) orelse unreachable;
    if (first.kind == .keyword) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .and_after_child = .{
        .iter = iter,
        .env = env,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = first.value, .env = env } });
}

fn processAndAfterChild(
    gpa: Allocator,
    s: anytype,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    const v = values.pop().?;
    var iter = s.iter;
    if (!v.isTruthy()) {
        try values.append(gpa, v);
        try frames.append(gpa, .{ .form_drain = .{ .iter = iter } });
        return;
    }
    if (iter.remaining == 0) {
        _ = try iter.next();
        try values.append(gpa, v);
        return;
    }
    const next = (try iter.next()) orelse unreachable;
    if (next.kind == .keyword) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .and_after_child = .{
        .iter = iter,
        .env = s.env,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = next.value, .env = s.env } });
}

fn scheduleOrBinary(
    gpa: Allocator,
    fv: BinaryCursor.FormView,
    env: *const Env,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    var iter = fv.children;
    if (iter.remaining == 0) {
        _ = try iter.next();
        try values.append(gpa, .{ .boolean = false });
        return;
    }
    const first = (try iter.next()) orelse unreachable;
    if (first.kind == .keyword) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .or_after_child = .{
        .iter = iter,
        .env = env,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = first.value, .env = env } });
}

fn processOrAfterChild(
    gpa: Allocator,
    s: anytype,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    const v = values.pop().?;
    var iter = s.iter;
    if (v.isTruthy()) {
        try values.append(gpa, v);
        try frames.append(gpa, .{ .form_drain = .{ .iter = iter } });
        return;
    }
    if (iter.remaining == 0) {
        _ = try iter.next();
        try values.append(gpa, .{ .boolean = false });
        return;
    }
    const next = (try iter.next()) orelse unreachable;
    if (next.kind == .keyword) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .or_after_child = .{
        .iter = iter,
        .env = s.env,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = next.value, .env = s.env } });
}

fn processFoldCaptureInit(
    gpa: Allocator,
    s: anytype,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    std.debug.assert(values.items.len >= 1);
    const init_val = values.pop().?;

    var form_iter = s.form_iter;
    const xs_entry = (try form_iter.next()) orelse unreachable;
    if (xs_entry.kind == .keyword) return error.KeywordInExpressionArgs;

    try frames.append(gpa, .{ .binder_setup_binary = .{
        .kind = .fold,
        .binder_name = s.binder_name,
        .binder_acc_name = s.binder_acc_name,
        .form_iter = form_iter,
        .env_outer = s.env_outer,
        .init_val_captured = init_val,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = xs_entry.value, .env = s.env_outer } });
}

fn scheduleBinderBinary(
    kind: BinderKind,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    fv: BinaryCursor.FormView,
    env: *const Env,
    frames: *std.ArrayList(FrameBinary),
) BinaryError!void {
    var form_iter = fv.children;
    const expected_arity: u32 = if (kind == .fold) 4 else 3;
    if (form_iter.remaining != expected_arity) return error.ArityMismatch;

    const binder_entry = (try form_iter.next()) orelse unreachable;
    if (binder_entry.kind == .keyword) return error.InvalidBinderShape;
    if (binder_entry.value.kind != .vector) return error.InvalidBinderShape;
    var binder_iter = try BinaryCursor.readVector(cursor, binder_entry.value);

    if (kind == .fold) {
        if (binder_iter.remaining != 2) return error.InvalidBinderShape;
        const acc_view = (try binder_iter.next()) orelse unreachable;
        if (acc_view.kind != .symbol) return error.InvalidBinderShape;
        const acc_name = try BinaryCursor.readSymbol(cursor, acc_view);
        const x_view = (try binder_iter.next()) orelse unreachable;
        if (x_view.kind != .symbol) return error.InvalidBinderShape;
        const x_name = try BinaryCursor.readSymbol(cursor, x_view);
        if (std.mem.eql(u8, acc_name, x_name)) return error.InvalidBinderShape;

        const init_entry = (try form_iter.next()) orelse unreachable;
        if (init_entry.kind == .keyword) return error.KeywordInExpressionArgs;

        try frames.append(gpa, .{ .fold_capture_init = .{
            .binder_name = x_name,
            .binder_acc_name = acc_name,
            .form_iter = form_iter,
            .env_outer = env,
        } });
        try frames.append(gpa, .{ .eval = .{ .view = init_entry.value, .env = env } });
        return;
    }

    if (binder_iter.remaining != 1) return error.InvalidBinderShape;
    const sym_view = (try binder_iter.next()) orelse unreachable;
    if (sym_view.kind != .symbol) return error.InvalidBinderShape;
    const binder_name = try BinaryCursor.readSymbol(cursor, sym_view);

    const xs_entry = (try form_iter.next()) orelse unreachable;
    if (xs_entry.kind == .keyword) return error.KeywordInExpressionArgs;

    try frames.append(gpa, .{ .binder_setup_binary = .{
        .kind = kind,
        .binder_name = binder_name,
        .binder_acc_name = null,
        .form_iter = form_iter,
        .env_outer = env,
        .init_val_captured = null,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = xs_entry.value, .env = env } });
}

fn processBinderSetupBinary(
    a: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    s: anytype,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    std.debug.assert(values.items.len >= 1);
    const xs_val = values.pop().?;
    const xs_vec = try expectVector(xs_val);
    const init_val: ?Value = s.init_val_captured;
    const n: u32 = @intCast(xs_vec.len);

    var form_iter = s.form_iter;
    const body_entry = (try form_iter.next()) orelse unreachable;
    if (body_entry.kind == .keyword) return error.KeywordInExpressionArgs;
    const body_view = body_entry.value;
    const body_payload_pos: u32 = cursor.pos;

    try BinaryCursor.skipBody(cursor, body_view);
    _ = try form_iter.next();
    const post_form_pos: u32 = cursor.pos;

    if (n == 0) {
        switch (s.kind) {
            .map, .filter => try values.append(gpa, .{ .vector = &.{} }),
            .any => try values.append(gpa, .{ .boolean = false }),
            .all => try values.append(gpa, .{ .boolean = true }),
            .fold => try values.append(gpa, init_val.?),
        }
        return;
    }

    const env_buf: []Env.Binding = switch (s.kind) {
        .fold => blk: {
            const buf = try a.alloc(Env.Binding, 2);
            buf[0] = .{ .name = s.binder_acc_name.?, .value = init_val.? };
            buf[1] = .{ .name = s.binder_name, .value = xs_vec[0] };
            break :blk buf;
        },
        else => blk: {
            const buf = try a.alloc(Env.Binding, 1);
            buf[0] = .{ .name = s.binder_name, .value = xs_vec[0] };
            break :blk buf;
        },
    };
    const inner_env = try a.create(Env);
    inner_env.* = .{ .parent = s.env_outer, .bindings = env_buf };

    const accumulator: []Value = switch (s.kind) {
        .map, .filter => try a.alloc(Value, n),
        .any, .all, .fold => &.{},
    };

    BinaryCursor.setPos(cursor, body_payload_pos);

    try frames.append(gpa, .{ .binder_iter_binary = .{
        .kind = s.kind,
        .body_view = body_view,
        .body_payload_pos = body_payload_pos,
        .post_form_pos = post_form_pos,
        .inner_env = inner_env,
        .env_buf = env_buf,
        .xs_vec = xs_vec,
        .accumulator = accumulator,
        .accumulator_count = 0,
        .i = 0,
        .n = n,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = body_view, .env = inner_env } });
}

fn processBinderIterBinary(
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    s: anytype,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    std.debug.assert(values.items.len >= 1);
    const body_val = values.pop().?;

    const next_i: u32 = s.i + 1;
    var next_count: u32 = s.accumulator_count;
    var done: ?Value = null;

    switch (s.kind) {
        .map => {
            s.accumulator[s.i] = body_val;
            next_count = next_i;
        },
        .filter => {
            if (body_val.isTruthy()) {
                s.accumulator[s.accumulator_count] = s.xs_vec[s.i];
                next_count = s.accumulator_count + 1;
            }
        },
        .any => {
            if (body_val.isTruthy()) done = .{ .boolean = true };
        },
        .all => {
            if (!body_val.isTruthy()) done = .{ .boolean = false };
        },
        .fold => {},
    }

    if (done == null and next_i == s.n) {
        done = switch (s.kind) {
            .map => Value{ .vector = s.accumulator },
            .filter => Value{ .vector = s.accumulator[0..next_count] },
            .any => Value{ .boolean = false },
            .all => Value{ .boolean = true },
            .fold => body_val,
        };
    }

    if (done) |final_v| {
        BinaryCursor.setPos(cursor, s.post_form_pos);
        try values.append(gpa, final_v);
        return;
    }

    if (s.kind == .fold) {
        s.env_buf[0].value = body_val;
        s.env_buf[1].value = s.xs_vec[next_i];
    } else {
        s.env_buf[0].value = s.xs_vec[next_i];
    }

    BinaryCursor.setPos(cursor, s.body_payload_pos);

    try frames.append(gpa, .{ .binder_iter_binary = .{
        .kind = s.kind,
        .body_view = s.body_view,
        .body_payload_pos = s.body_payload_pos,
        .post_form_pos = s.post_form_pos,
        .inner_env = s.inner_env,
        .env_buf = s.env_buf,
        .xs_vec = s.xs_vec,
        .accumulator = s.accumulator,
        .accumulator_count = next_count,
        .i = next_i,
        .n = s.n,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = s.body_view, .env = s.inner_env } });
}

fn processFormDrain(iter_in: BinaryCursor.ChildIter) BinaryError!void {
    var iter = iter_in;
    while (iter.remaining > 0) {
        const entry = (try iter.next()) orelse unreachable;
        try BinaryCursor.skipBody(iter.cursor, entry.value);
    }
    _ = try iter.next();
}

fn applyFunction(
    a: Allocator,
    name: []const u8,
    namespace: []const u8,
    args: []const Value,
    schema: Schema.Schema,
    runtime: ?*anyopaque,
) Error!Value {
    const ns: ?[]const u8 = if (namespace.len == 0) null else namespace;
    return switch (schema.lookupExprFunc(name, ns)) {
        .found => |hit| blk: {
            if (hit.func.wasm_export_name != null and !hit.func.checkArity(args.len)) {
                break :blk error.ArityMismatch;
            }
            break :blk if (hit.func.impl) |impl|
                impl(a, args)
            else if (hit.func.wasm_export_name) |export_name|
                wasm_plugin_invoker.invoke(a, runtime, hit.plugin.name, export_name, hit.func.result, args)
            else
                error.PluginFuncNotImplemented;
        },
        .ambiguous => error.AmbiguousFunction,
        .not_found => error.UnknownFunction,
    };
}

pub fn applySum(_: Allocator, args: []const Value) Error!Value {
    var total: f64 = 0;
    for (args) |v| total += try expectNumber(v);
    return .{ .number = total };
}

pub fn applyDiff(_: Allocator, args: []const Value) Error!Value {
    if (args.len == 0) return error.ArityMismatch;
    if (args.len == 1) return .{ .number = -try expectNumber(args[0]) };
    var total = try expectNumber(args[0]);
    for (args[1..]) |v| total -= try expectNumber(v);
    return .{ .number = total };
}

pub fn applyProduct(_: Allocator, args: []const Value) Error!Value {
    var total: f64 = 1;
    for (args) |v| total *= try expectNumber(v);
    return .{ .number = total };
}

pub fn applyQuotient(_: Allocator, args: []const Value) Error!Value {
    if (args.len < 2) return error.ArityMismatch;
    var total = try expectNumber(args[0]);
    for (args[1..]) |v| {
        const d = try expectNumber(v);
        if (d == 0) return error.DivisionByZero;
        total /= d;
    }
    return .{ .number = total };
}

pub fn applyMod(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const x = try expectNumber(args[0]);
    const y = try expectNumber(args[1]);
    if (y == 0) return error.DivisionByZero;
    return .{ .number = @mod(x, y) };
}

const CmpOp = enum { lt, gt, le, ge };

fn cmp(args: []const Value, op: CmpOp) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const a = try expectNumber(args[0]);
    const b = try expectNumber(args[1]);
    const r = switch (op) {
        .lt => a < b,
        .gt => a > b,
        .le => a <= b,
        .ge => a >= b,
    };
    return .{ .boolean = r };
}

pub fn applyLt(_: Allocator, args: []const Value) Error!Value {
    return cmp(args, .lt);
}
pub fn applyGt(_: Allocator, args: []const Value) Error!Value {
    return cmp(args, .gt);
}
pub fn applyLe(_: Allocator, args: []const Value) Error!Value {
    return cmp(args, .le);
}
pub fn applyGe(_: Allocator, args: []const Value) Error!Value {
    return cmp(args, .ge);
}

pub fn applyEq(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    return .{ .boolean = Value.equals(args[0], args[1]) };
}

pub fn applyNeq(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    return .{ .boolean = !Value.equals(args[0], args[1]) };
}

pub fn applyNot(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return .{ .boolean = !args[0].isTruthy() };
}

fn applyVecN(a: Allocator, args: []const Value, n: usize) Error!Value {
    if (args.len != n) return error.ArityMismatch;
    const elems = try a.alloc(Value, n);
    for (args, 0..) |v, i| elems[i] = .{ .number = try expectNumber(v) };
    return .{ .vector = elems };
}

pub fn applyVec2(a: Allocator, args: []const Value) Error!Value {
    return applyVecN(a, args, 2);
}
pub fn applyVec3(a: Allocator, args: []const Value) Error!Value {
    return applyVecN(a, args, 3);
}
pub fn applyVec4(a: Allocator, args: []const Value) Error!Value {
    return applyVecN(a, args, 4);
}

pub fn applyLerp(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 3) return error.ArityMismatch;
    const x = try expectNumber(args[0]);
    const y = try expectNumber(args[1]);
    const t = try expectNumber(args[2]);
    return .{ .number = x + (y - x) * t };
}

pub fn applyClamp(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 3) return error.ArityMismatch;
    const x = try expectNumber(args[0]);
    const lo = try expectNumber(args[1]);
    const hi = try expectNumber(args[2]);
    return .{ .number = std.math.clamp(x, lo, hi) };
}

fn applyMinMax(args: []const Value, op: enum { min, max }) Error!Value {
    if (args.len == 0) return error.ArityMismatch;
    var best = try expectNumber(args[0]);
    for (args[1..]) |v| {
        const x = try expectNumber(v);
        best = switch (op) {
            .min => @min(best, x),
            .max => @max(best, x),
        };
    }
    return .{ .number = best };
}

pub fn applyMin(_: Allocator, args: []const Value) Error!Value {
    return applyMinMax(args, .min);
}
pub fn applyMax(_: Allocator, args: []const Value) Error!Value {
    return applyMinMax(args, .max);
}

pub fn applyDot(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const a = try expectVector(args[0]);
    const b = try expectVector(args[1]);
    if (a.len != b.len) return error.TypeMismatch;
    var total: f64 = 0;
    for (a, b) |x, y| {
        total += try expectNumber(x) * try expectNumber(y);
    }
    return .{ .number = total };
}

pub fn applyCross(a_alloc: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const a = try expectVector(args[0]);
    const b = try expectVector(args[1]);
    if (a.len != 3 or b.len != 3) return error.TypeMismatch;
    const ax = try expectNumber(a[0]);
    const ay = try expectNumber(a[1]);
    const az = try expectNumber(a[2]);
    const bx = try expectNumber(b[0]);
    const by = try expectNumber(b[1]);
    const bz = try expectNumber(b[2]);
    const out = try a_alloc.alloc(Value, 3);
    out[0] = .{ .number = ay * bz - az * by };
    out[1] = .{ .number = az * bx - ax * bz };
    out[2] = .{ .number = ax * by - ay * bx };
    return .{ .vector = out };
}

pub fn applyLength(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    const v = try expectVector(args[0]);
    var sum_sq: f64 = 0;
    for (v) |x| {
        const n = try expectNumber(x);
        sum_sq += n * n;
    }
    return .{ .number = @sqrt(sum_sq) };
}

pub fn applyAbs(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return .{ .number = @abs(try expectNumber(args[0])) };
}

pub fn applySign(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    const x = try expectNumber(args[0]);
    if (std.math.isNan(x)) return .{ .number = x };
    return .{ .number = if (x > 0) 1.0 else if (x < 0) -1.0 else x };
}

pub fn applyFloor(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return .{ .number = @floor(try expectNumber(args[0])) };
}

pub fn applyCeil(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return .{ .number = @ceil(try expectNumber(args[0])) };
}

pub fn applyRound(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return .{ .number = @round(try expectNumber(args[0])) };
}

pub fn applyFract(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    const x = try expectNumber(args[0]);
    return .{ .number = x - @floor(x) };
}

pub fn applySqrt(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return .{ .number = @sqrt(try expectNumber(args[0])) };
}

pub fn applyPow(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const base = try expectNumber(args[0]);
    const exp_ = try expectNumber(args[1]);
    return .{ .number = std.math.pow(f64, base, exp_) };
}

pub fn applySin(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return .{ .number = trig.sin64(try expectNumber(args[0])) };
}

pub fn applyCos(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return .{ .number = trig.cos64(try expectNumber(args[0])) };
}

pub fn applyTan(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return .{ .number = trig.tan64(try expectNumber(args[0])) };
}

pub fn applyAsin(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return .{ .number = std.math.asin(try expectNumber(args[0])) };
}

pub fn applyAcos(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return .{ .number = std.math.acos(try expectNumber(args[0])) };
}

pub fn applyAtan(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return .{ .number = std.math.atan(try expectNumber(args[0])) };
}

pub fn applyAtan2(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const y = try expectNumber(args[0]);
    const x = try expectNumber(args[1]);
    return .{ .number = std.math.atan2(y, x) };
}

pub fn applyRadians(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return .{ .number = (try expectNumber(args[0])) * (std.math.pi / 180.0) };
}

pub fn applyDegrees(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return .{ .number = (try expectNumber(args[0])) * (180.0 / std.math.pi) };
}

pub fn applyPi(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 0) return error.ArityMismatch;
    return .{ .number = std.math.pi };
}

pub fn applyTau(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 0) return error.ArityMismatch;
    return .{ .number = 2.0 * std.math.pi };
}

pub fn applySaturate(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return .{ .number = std.math.clamp(try expectNumber(args[0]), 0.0, 1.0) };
}

pub fn applyStep(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const edge = try expectNumber(args[0]);
    const x = try expectNumber(args[1]);
    return .{ .number = if (x < edge) 0.0 else 1.0 };
}

pub fn applySmoothstep(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 3) return error.ArityMismatch;
    const edge0 = try expectNumber(args[0]);
    const edge1 = try expectNumber(args[1]);
    const x = try expectNumber(args[2]);
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return .{ .number = t * t * (3.0 - 2.0 * t) };
}

pub fn applyNormalize(a: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    const v = try expectVector(args[0]);
    if (v.len == 0) return error.TypeMismatch;
    var sum_sq: f64 = 0;
    for (v) |x| {
        const n = try expectNumber(x);
        sum_sq += n * n;
    }
    if (sum_sq == 0) return error.TypeMismatch;
    const inv = 1.0 / @sqrt(sum_sq);
    const out = try a.alloc(Value, v.len);
    for (v, 0..) |x, i| {
        const n = try expectNumber(x);
        out[i] = .{ .number = n * inv };
    }
    return .{ .vector = out };
}

pub fn applyDistance(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const a = try expectVector(args[0]);
    const b = try expectVector(args[1]);
    if (a.len != b.len) return error.TypeMismatch;
    if (a.len == 0) return error.TypeMismatch;
    var sum_sq: f64 = 0;
    for (a, b) |x, y| {
        const d = (try expectNumber(x)) - (try expectNumber(y));
        sum_sq += d * d;
    }
    return .{ .number = @sqrt(sum_sq) };
}

pub fn applyReflect(a_alloc: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const i = try expectVector(args[0]);
    const n = try expectVector(args[1]);
    if (i.len != n.len) return error.TypeMismatch;
    if (i.len == 0) return error.TypeMismatch;
    var dot: f64 = 0;
    for (i, n) |ix, nx| {
        dot += (try expectNumber(ix)) * (try expectNumber(nx));
    }
    const out = try a_alloc.alloc(Value, i.len);
    for (i, n, 0..) |ix, nx, k| {
        const ixv = try expectNumber(ix);
        const nxv = try expectNumber(nx);
        out[k] = .{ .number = ixv - 2.0 * dot * nxv };
    }
    return .{ .vector = out };
}

pub fn applyNth(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const v = try expectVector(args[0]);
    const i_f = try expectNumber(args[1]);
    if (!std.math.isFinite(i_f)) return error.TypeMismatch;
    if (@floor(i_f) != i_f) return error.TypeMismatch;
    if (i_f < 0) return error.TypeMismatch;
    if (i_f >= @as(f64, @floatFromInt(v.len))) return error.TypeMismatch;
    const idx: usize = @intFromFloat(i_f);
    return v[idx];
}

pub fn applyCount(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    const v = try expectVector(args[0]);
    return .{ .number = @as(f64, @floatFromInt(v.len)) };
}

const TWO_53: f64 = 9007199254740992.0;

fn splitMix64(z0: u64) u64 {
    var z = z0;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn coreHash(seed: u64, key: u64) u64 {
    return splitMix64(seed +% splitMix64(key));
}

fn toU64(x: f64) u64 {
    if (std.math.isFinite(x) and @floor(x) == x and @abs(x) < TWO_53) {
        return @bitCast(@as(i64, @intFromFloat(x)));
    }
    return @bitCast(x);
}

inline fn unitFloatFromHash(h: u64) f64 {
    return @as(f64, @floatFromInt(h >> 11)) / TWO_53;
}

pub fn applyHash(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const seed = toU64(try expectNumber(args[0]));
    const key = toU64(try expectNumber(args[1]));
    const h = coreHash(seed, key) >> 11;
    return .{ .number = @as(f64, @floatFromInt(h)) };
}

pub fn applyRand01(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const seed = toU64(try expectNumber(args[0]));
    const key = toU64(try expectNumber(args[1]));
    return .{ .number = unitFloatFromHash(coreHash(seed, key)) };
}

pub fn applyRandRange(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 4) return error.ArityMismatch;
    const seed = toU64(try expectNumber(args[0]));
    const key = toU64(try expectNumber(args[1]));
    const lo = try expectNumber(args[2]);
    const hi = try expectNumber(args[3]);
    if (lo > hi) return error.TypeMismatch;
    const r = unitFloatFromHash(coreHash(seed, key));
    return .{ .number = lo + (hi - lo) * r };
}

pub fn applyRandInt(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 4) return error.ArityMismatch;
    const seed = toU64(try expectNumber(args[0]));
    const key = toU64(try expectNumber(args[1]));
    const lo = try expectNumber(args[2]);
    const hi = try expectNumber(args[3]);
    if (!std.math.isFinite(lo) or !std.math.isFinite(hi)) return error.TypeMismatch;
    if (@floor(lo) != lo or @floor(hi) != hi) return error.TypeMismatch;
    if (lo > hi) return error.TypeMismatch;
    const r = unitFloatFromHash(coreHash(seed, key));
    const span = hi - lo + 1.0;
    return .{ .number = lo + @floor(r * span) };
}

pub fn applyRandBool(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 3) return error.ArityMismatch;
    const seed = toU64(try expectNumber(args[0]));
    const key = toU64(try expectNumber(args[1]));
    const p = try expectNumber(args[2]);
    const p_clamped = std.math.clamp(p, 0.0, 1.0);
    const r = unitFloatFromHash(coreHash(seed, key));
    return .{ .boolean = r < p_clamped };
}

pub fn applyRandChoice(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 3) return error.ArityMismatch;
    const seed = toU64(try expectNumber(args[0]));
    const key = toU64(try expectNumber(args[1]));
    const v = try expectVector(args[2]);
    if (v.len == 0) return error.TypeMismatch;
    const r = unitFloatFromHash(coreHash(seed, key));
    const idx_f = @floor(r * @as(f64, @floatFromInt(v.len)));
    const idx: usize = @intFromFloat(idx_f);
    return v[idx];
}

inline fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn isCoreSpecialForm(head: []const u8, namespace: ?[]const u8) bool {
    if (namespace != null) return false;
    return eq(head, "let") or eq(head, "if") or eq(head, "cond") or
        eq(head, "and") or eq(head, "or") or
        eq(head, "map") or eq(head, "filter") or
        eq(head, "any") or eq(head, "all") or
        eq(head, "fold");
}

fn expectNumber(v: Value) Error!f64 {
    return v.toF64() orelse error.TypeMismatch;
}

fn expectVector(v: Value) Error![]const Value {
    return switch (v) {
        .vector => |xs| xs,
        else => error.TypeMismatch,
    };
}
