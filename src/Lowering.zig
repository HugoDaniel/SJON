const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Ast = @import("Ast.zig");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const EffectiveViewMod = @import("EffectiveView.zig");
const EffectiveView = EffectiveViewMod.EffectiveView;
const MaterializedDefaults = @import("MaterializedDefaults.zig");
const Validator = @import("Validator.zig");
const Parser = @import("Parser.zig");
const Expr = @import("Expr.zig");

pub const LoweringError = error{
    HookFailed,
    OutOfMemory,
};

pub const HookFn = *const fn (
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
) LoweringError!void;

pub const LoweringHook = struct {
    id: []const u8,
    lower: HookFn,
};

pub const RegisterError = error{
    DuplicateHook,
    OutOfMemory,
};

pub const LoweringRegistry = struct {
    hooks: std.StringHashMapUnmanaged(LoweringHook) = .empty,

    pub fn register(
        self: *LoweringRegistry,
        gpa: Allocator,
        hook: LoweringHook,
    ) RegisterError!void {
        const gop = try self.hooks.getOrPut(gpa, hook.id);
        if (gop.found_existing) return RegisterError.DuplicateHook;
        gop.value_ptr.* = hook;
    }

    pub fn lookup(self: *const LoweringRegistry, id: []const u8) ?*const LoweringHook {
        return self.hooks.getPtr(id);
    }

    pub fn deinit(self: *LoweringRegistry, gpa: Allocator) void {
        self.hooks.deinit(gpa);
    }
};

pub const LoweringInput = struct {
    arena: Allocator,
    form_idx: Ast.NodeIndex,
    head: []const u8,
    source_span: Ast.Span,
    view: EffectiveView,
    schema: *const Schema.Schema,
    form_spec: *const Plugin.FormSpec,
    lowering_spec: *const Plugin.LoweringSpec,
    env: *const Expr.Env,

    pub fn symbol(self: *const LoweringInput, key: []const u8) LoweringError!?[]const u8 {
        const ev = self.view.getEffectiveValue(self.form_idx, key) orelse return null;
        return switch (ev) {
            .author => |idx| switch (self.view.tree.tagOf(idx)) {
                .symbol => try self.arena.dupe(u8, self.view.tree.symbolText(idx)),
                .keyword => try self.arena.dupe(u8, self.view.tree.keywordText(idx)),
                else => error.HookFailed,
            },
            .default => |entry| switch (entry.value) {
                .keyword => |k| try self.arena.dupe(u8, k),
                else => error.HookFailed,
            },
        };
    }

    pub fn string(self: *const LoweringInput, key: []const u8) LoweringError!?[]const u8 {
        const ev = self.view.getEffectiveValue(self.form_idx, key) orelse return null;
        return switch (ev) {
            .author => |idx| switch (self.view.tree.tagOf(idx)) {
                .string => try self.arena.dupe(u8, self.view.tree.stringText(idx)),
                else => error.HookFailed,
            },
            .default => |entry| switch (entry.value) {
                .string => |s| try self.arena.dupe(u8, s),
                else => error.HookFailed,
            },
        };
    }

    pub fn number(self: *const LoweringInput, key: []const u8) LoweringError!?f64 {
        const ev = self.view.getEffectiveValue(self.form_idx, key) orelse return null;
        return switch (ev) {
            .author => |idx| switch (self.view.tree.tagOf(idx)) {
                .number, .number_i64, .number_u64 => self.view.tree.numberOf(idx),
                else => error.HookFailed,
            },
            .default => |entry| switch (entry.value) {
                .number => |n| n,
                else => error.HookFailed,
            },
        };
    }

    pub fn numberEval(self: *const LoweringInput, key: []const u8) LoweringError!?f64 {
        const ev = self.view.getEffectiveValue(self.form_idx, key) orelse return null;
        return switch (ev) {
            .author => |idx| switch (self.view.tree.tagOf(idx)) {
                .number, .number_i64, .number_u64 => self.view.tree.numberOf(idx),
                else => blk: {
                    var r = Expr.eval(self.arena, self.view.tree, idx, self.env, self.schema.*) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.HookFailed,
                    };
                    defer r.deinit();
                    break :blk valueToF64(r.value) orelse error.HookFailed;
                },
            },
            .default => |entry| valueToF64(entry.value) orelse error.HookFailed,
        };
    }

    pub fn boolean(self: *const LoweringInput, key: []const u8) LoweringError!?bool {
        const ev = self.view.getEffectiveValue(self.form_idx, key) orelse return null;
        return switch (ev) {
            .author => |idx| switch (self.view.tree.tagOf(idx)) {
                .boolean_true => true,
                .boolean_false => false,
                else => error.HookFailed,
            },
            .default => |entry| switch (entry.value) {
                .boolean => |b| b,
                else => error.HookFailed,
            },
        };
    }
};

fn valueToF64(v: Expr.Value) ?f64 {
    return switch (v) {
        .number => |n| n,
        .integer_i64 => |i| @floatFromInt(i),
        .integer_u64 => |u| @floatFromInt(u),
        else => null,
    };
}

pub const LoweringOutput = struct {
    forms: std.ArrayList(EmittedForm) = .empty,

    pub fn append(
        self: *LoweringOutput,
        arena: Allocator,
        ef: EmittedForm,
    ) Allocator.Error!void {
        try self.forms.append(arena, ef);
    }
};

pub const EmittedForm = struct {
    head: []const u8,
    kvpairs: []const EmittedKvpair = &.{},
    children: []const EmittedValue = &.{},
    source_form_idx: Ast.NodeIndex,
};

pub const EmittedKvpair = struct {
    key: []const u8,
    value: EmittedValue,
};

pub const EmittedValue = union(enum) {
    number: f64,
    string: []const u8,
    symbol: []const u8,
    keyword: []const u8,
    boolean: bool,
    nil,
    vector: []const EmittedValue,
    form: EmittedForm,
};

pub const LoweringProvenance = struct {
    entries: []const Entry = &.{},

    pub const Entry = struct {
        lowered_form_idx: Ast.NodeIndex,
        source_form_idx: Ast.NodeIndex,
        hook_id: []const u8,
    };

    pub fn lookup(self: *const LoweringProvenance, lowered: Ast.NodeIndex) ?Entry {
        for (self.entries) |entry| {
            if (entry.lowered_form_idx == lowered) return entry;
        }
        return null;
    }
};

pub const Invocation = struct {
    source_form_idx: Ast.NodeIndex,
    hook_id: []const u8,
    forms: []const EmittedForm,
};

pub const PassResult = struct {
    invocations: []const Invocation,
    diagnostics: []const Ast.Diagnostic,

    pub fn deinit(self: *PassResult, gpa: Allocator) void {
        for (self.diagnostics) |d| {
            gpa.free(d.message);
            for (d.path) |p| gpa.free(p);
            gpa.free(d.path);
        }
        gpa.free(self.diagnostics);
    }
};

pub const MAX_LOWERING_STAGES: usize = 16;

pub const MAX_LOWERING_STEPS: usize = 1 << 20;

pub fn runLoweringPass(
    gpa: Allocator,
    arena: Allocator,
    tree: *const Ast.Tree,
    data_forest: []const Ast.NodeIndex,
    schema: Schema.Schema,
    materialized: *const MaterializedDefaults.MaterializedDefaults,
    registry: *const LoweringRegistry,
    axes: Validator.EffectiveAxes,
) Allocator.Error!PassResult {
    const empty_env: Expr.Env = .{};
    return runLoweringPassWithEnv(gpa, arena, tree, data_forest, schema, materialized, registry, axes, &empty_env);
}

pub fn runLoweringPassWithEnv(
    gpa: Allocator,
    arena: Allocator,
    tree: *const Ast.Tree,
    data_forest: []const Ast.NodeIndex,
    schema: Schema.Schema,
    materialized: *const MaterializedDefaults.MaterializedDefaults,
    registry: *const LoweringRegistry,
    axes: Validator.EffectiveAxes,
    env: *const Expr.Env,
) Allocator.Error!PassResult {
    var emitted: usize = 0;
    return runLoweringPassBudgeted(gpa, arena, tree, data_forest, schema, materialized, registry, axes, env, &emitted, MAX_LOWERING_STEPS);
}

pub fn runLoweringPassBudgeted(
    gpa: Allocator,
    arena: Allocator,
    tree: *const Ast.Tree,
    data_forest: []const Ast.NodeIndex,
    schema: Schema.Schema,
    materialized: *const MaterializedDefaults.MaterializedDefaults,
    registry: *const LoweringRegistry,
    axes: Validator.EffectiveAxes,
    env: *const Expr.Env,
    emitted: *usize,
    budget: usize,
) Allocator.Error!PassResult {
    var invocations: std.ArrayList(Invocation) = .empty;
    errdefer invocations.deinit(arena);
    var diags: std.ArrayList(Ast.Diagnostic) = .empty;
    errdefer {
        for (diags.items) |d| {
            gpa.free(d.message);
            for (d.path) |p| gpa.free(p);
            gpa.free(d.path);
        }
        diags.deinit(gpa);
    }

    const view = EffectiveView.init(tree, materialized);

    var work: std.ArrayList(Ast.NodeIndex) = .empty;
    defer work.deinit(gpa);
    var seed = data_forest.len;
    while (seed > 0) {
        seed -= 1;
        try work.append(gpa, data_forest[seed]);
    }

    while (work.pop()) |idx| {
        if (tree.tagOf(idx) != .form) continue;
        const hdr = tree.formHeader(idx);
        if (hdr.head.len == 0) continue;

        const hit = schema.lookupForm(hdr.head, hdr.namespace);
        var parent_lowerable = false;
        if (hit == .found) {
            const form_spec = hit.found.form;
            if (form_spec.lowering) |*low| {
                parent_lowerable = true;
                try lowerOneForm(gpa, arena, tree, idx, hdr, form_spec, low, schema, view, registry, axes, env, &invocations, &diags, emitted, budget);
            }
        }

        if (parent_lowerable) {
            for (hdr.children) |child| {
                if (childForm(tree, child)) |cf| try checkNestedLowerable(gpa, tree, cf, schema, &diags);
            }
        }

        var c = hdr.children.len;
        while (c > 0) {
            c -= 1;
            if (childForm(tree, hdr.children[c])) |cf| try work.append(gpa, cf);
        }
    }

    return .{
        .invocations = try invocations.toOwnedSlice(arena),
        .diagnostics = try diags.toOwnedSlice(gpa),
    };
}

fn childForm(tree: *const Ast.Tree, child: Ast.NodeIndex) ?Ast.NodeIndex {
    return switch (tree.tagOf(child)) {
        .form => child,
        .kvpair => blk: {
            const kvh = tree.kvpairHeader(child);
            break :blk if (tree.tagOf(kvh.value) == .form) kvh.value else null;
        },
        else => null,
    };
}

fn checkNestedLowerable(
    gpa: Allocator,
    tree: *const Ast.Tree,
    child: Ast.NodeIndex,
    schema: Schema.Schema,
    diags: *std.ArrayList(Ast.Diagnostic),
) Allocator.Error!void {
    const chdr = tree.formHeader(child);
    if (chdr.head.len == 0) return;
    const chit = schema.lookupForm(chdr.head, chdr.namespace);
    if (chit != .found) return;
    if (chit.found.form.lowering == null) return;
    try emitDiag(gpa, diags, .lowering_nested_lowerable, chdr.head_span, &.{ chdr.head, "lowering" }, "form `({s} …)` declares :lowering but is a positional child of another :lowering form; both hooks fire in the same layer — put :lowering on the container or the child, not both", .{chdr.head});
}

fn lowerOneForm(
    gpa: Allocator,
    arena: Allocator,
    tree: *const Ast.Tree,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    form_spec: *const Plugin.FormSpec,
    lowering_spec: *const Plugin.LoweringSpec,
    schema: Schema.Schema,
    view: EffectiveView,
    registry: *const LoweringRegistry,
    axes: Validator.EffectiveAxes,
    env: *const Expr.Env,
    invocations: *std.ArrayList(Invocation),
    diags: *std.ArrayList(Ast.Diagnostic),
    emitted: *usize,
    budget: usize,
) Allocator.Error!void {
    std.debug.assert(hdr.head.len > 0);
    std.debug.assert(form_spec.lowering != null);

    var sub: Ast.Tree = tree.*;
    var sub_root = [_]Ast.NodeIndex{form_idx};
    sub.root = sub_root[0..];
    var surface = try Validator.validateWithOptions(gpa, sub, schema, .{
        .overlay = view.materialized,
        .axes = axes,
    });
    defer surface.deinit();
    if (hasNonCrossRefError(surface.diagnostics)) return;

    const hook = registry.lookup(lowering_spec.hook) orelse {
        try emitDiag(gpa, diags, .lowering_hook_missing, hdr.head_span, &.{ hdr.head, "lowering" }, "form `({s} …)` declares :lowering :hook \"{s}\" but no hook is registered with that id", .{ hdr.head, lowering_spec.hook });
        return;
    };

    var output: LoweringOutput = .{};
    const input: LoweringInput = .{
        .arena = arena,
        .form_idx = form_idx,
        .head = hdr.head,
        .source_span = hdr.head_span,
        .view = view,
        .schema = &schema,
        .form_spec = form_spec,
        .lowering_spec = lowering_spec,
        .env = env,
    };
    hook.lower(arena, &input, &output) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.HookFailed => {
            try emitDiag(gpa, diags, .lowering_hook_failed, hdr.head_span, &.{ hdr.head, "lowering" }, "lowering hook `{s}` on `({s} …)` returned HookFailed", .{ lowering_spec.hook, hdr.head });
            return;
        },
    };

    var seen_violation = false;
    var totals: Totals = .{};
    for (output.forms.items) |*ef| {
        try validateEmittedForm(gpa, ef, lowering_spec, hdr.head_span, &totals, diags, &seen_violation);
    }

    if (totals.form_count > Plugin.MAX_LOWERED_FORMS or totals.byte_estimate > Plugin.MAX_LOWERED_BYTES) {
        try emitDiag(gpa, diags, .lowering_output_too_large, hdr.head_span, &.{ hdr.head, "lowering" }, "lowering hook `{s}` on `({s} …)` produced {d} form(s) / ~{d} byte(s); limits are {d} / {d}", .{ lowering_spec.hook, hdr.head, totals.form_count, totals.byte_estimate, Plugin.MAX_LOWERED_FORMS, Plugin.MAX_LOWERED_BYTES });
        seen_violation = true;
    }

    emitted.* += totals.form_count;
    if (emitted.* > budget) {
        try emitDiag(gpa, diags, .lowering_output_too_large, hdr.head_span, &.{ hdr.head, "lowering" }, "lowering exceeded the cumulative staging budget of {d} emitted form(s)", .{budget});
        seen_violation = true;
    }

    if (seen_violation) return;

    try invocations.append(arena, .{
        .source_form_idx = form_idx,
        .hook_id = try arena.dupe(u8, lowering_spec.hook),
        .forms = output.forms.items,
    });
}

const Totals = struct {
    form_count: usize = 0,
    byte_estimate: usize = 0,
};

fn hasNonCrossRefError(diags: []const Ast.Diagnostic) bool {
    for (diags) |d| {
        if (d.severity != .err) continue;
        switch (d.code) {
            .not_cross_ref,
            .cross_ref_outside_scope,
            .duplicate_cross_ref_target,
            => continue,
            else => return true,
        }
    }
    return false;
}

fn validateEmittedForm(
    gpa: Allocator,
    ef_root: *const EmittedForm,
    lowering_spec: *const Plugin.LoweringSpec,
    source_span: Ast.Span,
    totals: *Totals,
    diags: *std.ArrayList(Ast.Diagnostic),
    seen_violation: *bool,
) Allocator.Error!void {
    const Frame = struct { ef: *const EmittedForm, depth: usize };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{ .ef = ef_root, .depth = 1 });

    while (stack.pop()) |fr| {
        const ef = fr.ef;
        totals.form_count += 1;
        totals.byte_estimate += ef.head.len;

        if (fr.depth > Plugin.MAX_LOWERED_DEPTH) {
            try emitDiag(gpa, diags, .lowering_output_too_large, source_span, &.{ ef.head, "lowering" }, "lowering output exceeds depth limit {d}", .{Plugin.MAX_LOWERED_DEPTH});
            seen_violation.* = true;
            continue;
        }

        if (!headInProduces(ef.head, lowering_spec.produces)) {
            try emitDiag(gpa, diags, .lowering_produced_invalid_head, source_span, &.{ ef.head, "lowering", "produces" }, "lowering produced form head `{s}` which is not in :produces", .{ef.head});
            seen_violation.* = true;
        }

        for (ef.kvpairs) |kv| {
            totals.byte_estimate += kv.key.len;
            accumulateValueBytes(kv.value, totals);
        }

        var c = ef.children.len;
        while (c > 0) {
            c -= 1;
            switch (ef.children[c]) {
                .form => |*child_form| try stack.append(gpa, .{ .ef = child_form, .depth = fr.depth + 1 }),
                else => accumulateValueBytes(ef.children[c], totals),
            }
        }
    }
}

fn accumulateValueBytes(v: EmittedValue, totals: *Totals) void {
    switch (v) {
        .number, .boolean, .nil => {},
        .string => |s| totals.byte_estimate += s.len,
        .symbol => |s| totals.byte_estimate += s.len,
        .keyword => |s| totals.byte_estimate += s.len,
        .vector => |xs| for (xs) |x| accumulateValueBytes(x, totals),
        .form => |ef| {
            totals.form_count += 1;
            totals.byte_estimate += ef.head.len;
            for (ef.kvpairs) |kv| {
                totals.byte_estimate += kv.key.len;
                accumulateValueBytes(kv.value, totals);
            }
            for (ef.children) |child| accumulateValueBytes(child, totals);
        },
    }
}

fn headInProduces(head: []const u8, produces: []const []const u8) bool {
    for (produces) |p| if (std.mem.eql(u8, p, head)) return true;
    return false;
}

fn emitDiag(
    gpa: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    code: Ast.Diagnostic.Code,
    span: Ast.Span,
    path_parts: []const []const u8,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    const message = try std.fmt.allocPrint(gpa, fmt, args);
    errdefer gpa.free(message);

    const path = try gpa.alloc([]const u8, path_parts.len);
    var filled: usize = 0;
    errdefer {
        for (path[0..filled]) |p| gpa.free(p);
        gpa.free(path);
    }
    for (path_parts, 0..) |p, i| {
        path[i] = try gpa.dupe(u8, p);
        filled = i + 1;
    }

    try diags.append(gpa, .{
        .span = span,
        .message = message,
        .severity = .err,
        .code = code,
        .path = path,
    });
}

pub const LoweredTree = struct {
    tree: Ast.Tree,
    provenance: LoweringProvenance,

    pub fn deinit(self: *LoweredTree) void {
        self.tree.deinit();
    }
};

pub fn buildLoweredTree(
    gpa: Allocator,
    invocations: []const Invocation,
    source_tree: *const Ast.Tree,
) Allocator.Error!LoweredTree {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var b: Ast.TreeBuilder = .{ .a = arena.allocator() };

    var roots: std.ArrayList(Ast.NodeIndex) = .empty;
    var prov_entries: std.ArrayList(LoweringProvenance.Entry) = .empty;

    for (invocations) |inv| {
        const src_span = source_tree.spanOf(inv.source_form_idx);
        const hook_id_dup = try arena.allocator().dupe(u8, inv.hook_id);

        for (inv.forms) |*ef| {
            const idx = try emitFormIntoTree(&b, ef, src_span);
            try roots.append(arena.allocator(), idx);
            try prov_entries.append(arena.allocator(), .{
                .lowered_form_idx = idx,
                .source_form_idx = inv.source_form_idx,
                .hook_id = hook_id_dup,
            });
        }
    }

    const roots_slice = try roots.toOwnedSlice(arena.allocator());
    const prov_slice = try prov_entries.toOwnedSlice(arena.allocator());

    const tree = try b.finalize(&arena, "", roots_slice);

    return .{
        .tree = tree,
        .provenance = .{ .entries = prov_slice },
    };
}

fn emitFormIntoTree(
    b: *Ast.TreeBuilder,
    ef: *const EmittedForm,
    src_span: Ast.Span,
) Allocator.Error!Ast.NodeIndex {
    std.debug.assert(ef.head.len > 0);

    var head_ns: ?[]const u8 = null;
    var head_name: []const u8 = ef.head;
    if (std.mem.indexOfScalar(u8, ef.head, '/')) |slash| {
        head_ns = ef.head[0..slash];
        head_name = ef.head[slash + 1 ..];
    }
    std.debug.assert(head_name.len > 0);

    var children: std.ArrayList(Ast.NodeIndex) = .empty;

    for (ef.kvpairs) |kv| {
        const value_idx = try emitValueIntoTree(b, kv.value, src_span, ef);
        const kv_idx = try b.appendKvpair(kv.key, value_idx, src_span, src_span);
        try children.append(b.a, kv_idx);
    }

    for (ef.children) |child| {
        const cidx = try emitValueIntoTree(b, child, src_span, ef);
        try children.append(b.a, cidx);
    }

    return b.appendForm(head_name, head_ns, src_span, children.items, src_span);
}

fn emitValueIntoTree(
    b: *Ast.TreeBuilder,
    v: EmittedValue,
    src_span: Ast.Span,
    parent: *const EmittedForm,
) Allocator.Error!Ast.NodeIndex {
    return switch (v) {
        .number => |n| try b.appendNumber(n, src_span),
        .string => |s| try b.appendString(s, src_span),
        .symbol => |s| try b.appendSymbol(s, src_span),
        .keyword => |s| try b.appendKeyword(s, src_span),
        .boolean => |x| try b.appendBoolean(x, src_span),
        .nil => try b.appendNil(src_span),
        .vector => |xs| blk: {
            var elems: std.ArrayList(Ast.NodeIndex) = .empty;
            for (xs) |x| {
                const ei = try emitValueIntoTree(b, x, src_span, parent);
                try elems.append(b.a, ei);
            }
            break :blk try b.appendVector(elems.items, src_span);
        },
        .form => |ef| try emitFormIntoTree(b, &ef, src_span),
    };
}

pub fn revalidateLowered(
    gpa: Allocator,
    lowered_tree: Ast.Tree,
    schema: Schema.Schema,
    materialized: *const MaterializedDefaults.MaterializedDefaults,
    axes: Validator.EffectiveAxes,
) Allocator.Error!Validator.Result {
    return Validator.validateWithOptions(gpa, lowered_tree, schema, .{
        .overlay = materialized,
        .axes = axes,
    });
}

fn dummyLowerOk(
    _: Allocator,
    _: *const LoweringInput,
    _: *LoweringOutput,
) LoweringError!void {}

fn dummyLowerFail(
    _: Allocator,
    _: *const LoweringInput,
    _: *LoweringOutput,
) LoweringError!void {
    return LoweringError.HookFailed;
}

fn identityRenameHook(
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
) LoweringError!void {
    const new_head = try std.fmt.allocPrint(arena, "{s}-normal", .{input.head});

    var kvpairs: std.ArrayList(EmittedKvpair) = .empty;
    for (input.form_spec.keys) |key| {
        const ev = input.view.getEffectiveValue(input.form_idx, key.name) orelse continue;
        const value = effectiveValueToEmitted(arena, input.view.tree, ev) catch return LoweringError.HookFailed;
        try kvpairs.append(arena, .{ .key = try arena.dupe(u8, key.name), .value = value });
    }

    try out.append(arena, .{
        .head = new_head,
        .kvpairs = try kvpairs.toOwnedSlice(arena),
        .children = &.{},
        .source_form_idx = input.form_idx,
    });
}

fn effectiveValueToEmitted(
    arena: Allocator,
    tree: *const Ast.Tree,
    ev: EffectiveViewMod.EffectiveValue,
) !EmittedValue {
    return switch (ev) {
        .author => |idx| astNodeToEmitted(arena, tree, idx),
        .default => |entry| exprValueToEmitted(arena, entry.value),
    };
}

fn astNodeToEmitted(arena: Allocator, tree: *const Ast.Tree, idx: Ast.NodeIndex) !EmittedValue {
    return switch (tree.tagOf(idx)) {
        .number, .number_i64, .number_u64 => .{ .number = tree.numberOf(idx) },
        .boolean_true => .{ .boolean = true },
        .boolean_false => .{ .boolean = false },
        .nil => .nil,
        .string => .{ .string = try arena.dupe(u8, tree.stringText(idx)) },
        .symbol => .{ .symbol = try arena.dupe(u8, tree.symbolText(idx)) },
        else => error.HookFailed,
    };
}

fn exprValueToEmitted(arena: Allocator, v: anytype) !EmittedValue {
    return switch (v) {
        .number => .{ .number = v.number },
        .integer_i64 => .{ .number = @as(f64, @floatFromInt(v.integer_i64)) },
        .integer_u64 => .{ .number = @as(f64, @floatFromInt(v.integer_u64)) },
        .boolean => .{ .boolean = v.boolean },
        .nil => .nil,
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        .keyword => |k| .{ .keyword = try arena.dupe(u8, k) },
        else => error.HookFailed,
    };
}

fn failingHook(
    _: Allocator,
    _: *const LoweringInput,
    _: *LoweringOutput,
) LoweringError!void {
    return LoweringError.HookFailed;
}

fn explosionHook(
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
) LoweringError!void {
    var current: EmittedForm = .{
        .head = "sugar-normal",
        .kvpairs = &.{},
        .children = &.{},
        .source_form_idx = input.form_idx,
    };
    var i: usize = 0;
    while (i < 17) : (i += 1) {
        const wrapper = try arena.alloc(EmittedValue, 1);
        wrapper[0] = .{ .form = current };
        current = .{
            .head = "sugar-normal",
            .kvpairs = &.{},
            .children = wrapper,
            .source_form_idx = input.form_idx,
        };
    }
    try out.append(arena, current);
}

fn manyFlatFormsHook(
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
) LoweringError!void {
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try out.append(arena, .{
            .head = "sugar-normal",
            .source_form_idx = input.form_idx,
        });
    }
}

const TestSchemaSetup = struct {
    plugin: Plugin.Plugin,
    schema: Schema.Schema,
};

fn buildSchema(
    gpa: Allocator,
    plugin_arena: *std.heap.ArenaAllocator,
    sugar_keys: []const Plugin.KeySpec,
    normal_keys: []const Plugin.KeySpec,
    hook_id: []const u8,
    produces: []const []const u8,
    sugar_open: bool,
    normal_open: bool,
) !TestSchemaSetup {
    _ = gpa;
    const a = plugin_arena.allocator();

    const sugar_keys_dup = try a.dupe(Plugin.KeySpec, sugar_keys);
    const normal_keys_dup = try a.dupe(Plugin.KeySpec, normal_keys);
    const produces_dup = try a.alloc([]const u8, produces.len);
    for (produces, 0..) |p, i| produces_dup[i] = try a.dupe(u8, p);

    const forms = try a.alloc(Plugin.FormSpec, 2);
    forms[0] = .{
        .name = try a.dupe(u8, "sugar"),
        .keys = sugar_keys_dup,
        .open = sugar_open,
        .lowering = .{
            .hook = try a.dupe(u8, hook_id),
            .produces = produces_dup,
        },
    };
    forms[1] = .{
        .name = try a.dupe(u8, "sugar-normal"),
        .keys = normal_keys_dup,
        .open = normal_open,
    };

    const plugin: Plugin.Plugin = .{
        .name = try a.dupe(u8, "tp"),
        .forms = forms,
    };
    const plugins_slice = try a.alloc(Plugin.Plugin, 1);
    plugins_slice[0] = plugin;

    return .{ .plugin = plugin, .schema = .{ .plugins = plugins_slice } };
}

const LowerSpec = struct { name: []const u8, lower: bool = true, open: bool = true };

fn buildNestedSchema(a: Allocator, specs: []const LowerSpec) Allocator.Error!Schema.Schema {
    var forms: std.ArrayList(Plugin.FormSpec) = .empty;
    for (specs) |s| {
        if (s.lower) {
            const produces = try a.alloc([]const u8, 1);
            produces[0] = try std.fmt.allocPrint(a, "{s}-normal", .{s.name});
            try forms.append(a, .{ .name = s.name, .open = s.open, .lowering = .{ .hook = "test/identity-v1", .produces = produces } });
            try forms.append(a, .{ .name = produces[0], .open = true });
        } else {
            try forms.append(a, .{ .name = s.name, .open = s.open });
        }
    }
    const plugins = try a.alloc(Plugin.Plugin, 1);
    plugins[0] = .{ .name = "tp", .forms = try forms.toOwnedSlice(a) };
    return .{ .plugins = plugins };
}

fn expectNestedHeadsInOrder(diags: []const Ast.Diagnostic, expected_heads: []const []const u8) !void {
    var i: usize = 0;
    for (diags) |d| {
        if (d.code != .lowering_nested_lowerable) continue;
        if (i >= expected_heads.len) return error.TooManyNestedDiagnostics;
        try testing.expectEqual(@as(usize, 2), d.path.len);
        try testing.expectEqualStrings(expected_heads[i], d.path[0]);
        try testing.expectEqualStrings("lowering", d.path[1]);
        i += 1;
    }
    try testing.expectEqual(expected_heads.len, i);
}

fn expectNested(
    gpa: Allocator,
    src: [:0]const u8,
    specs: []const LowerSpec,
    expected_heads: []const []const u8,
    expected_invocations: ?usize,
) !void {
    var schema_arena = std.heap.ArenaAllocator.init(gpa);
    defer schema_arena.deinit();
    const schema = try buildNestedSchema(schema_arena.allocator(), specs);

    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();
    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    try expectNestedHeadsInOrder(pr.diagnostics, expected_heads);
    if (expected_invocations) |n| try testing.expectEqual(n, pr.invocations.len);
}
