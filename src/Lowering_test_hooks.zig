const std = @import("std");
const Allocator = std.mem.Allocator;
const Lowering = @import("Lowering.zig");
const Ast = @import("Ast.zig");
const EffectiveView = @import("EffectiveView.zig");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const Expr = @import("Expr.zig");
const Parser = @import("Parser.zig");
const MaterializedDefaults = @import("MaterializedDefaults.zig");
const core = @import("plugins/core.zig");

pub const test_identity_v1: Lowering.LoweringHook = .{
    .id = "test/identity-v1",
    .lower = lowerIdentity,
};

fn lowerIdentity(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const new_head = try std.fmt.allocPrint(arena, "{s}-normal", .{input.head});

    var kvpairs: std.ArrayList(Lowering.EmittedKvpair) = .empty;

    for (input.form_spec.keys) |key| {
        const ev = input.view.getEffectiveValue(input.form_idx, key.name) orelse continue;
        const value = effectiveValueToEmitted(arena, input.view.tree, ev) catch continue;
        try kvpairs.append(arena, .{
            .key = try arena.dupe(u8, key.name),
            .value = value,
        });
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
    ev: EffectiveView.EffectiveValue,
) !Lowering.EmittedValue {
    return switch (ev) {
        .author => |idx| astNodeToEmitted(arena, tree, idx),
        .default => |entry| exprValueToEmitted(arena, entry.value),
    };
}

fn astNodeToEmitted(
    arena: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) !Lowering.EmittedValue {
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

fn exprValueToEmitted(arena: Allocator, v: anytype) !Lowering.EmittedValue {
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

pub const test_bundle_v1: Lowering.LoweringHook = .{
    .id = "test/bundle-v1",
    .lower = lowerBundle,
};

fn lowerBundle(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const name = (try input.symbol("name")) orelse return error.HookFailed;
    const target = (try input.symbol("target")) orelse return error.HookFailed;
    const kind_opt = try input.symbol("kind");

    var asset_kvs: std.ArrayList(Lowering.EmittedKvpair) = .empty;
    try asset_kvs.append(arena, .{
        .key = try arena.dupe(u8, "name"),
        .value = .{ .symbol = try std.fmt.allocPrint(arena, "{s}-asset", .{name}) },
    });
    if (kind_opt) |kind| {
        try asset_kvs.append(arena, .{
            .key = try arena.dupe(u8, "kind"),
            .value = .{ .symbol = kind },
        });
    }
    try out.append(arena, .{
        .head = try arena.dupe(u8, "asset"),
        .kvpairs = try asset_kvs.toOwnedSlice(arena),
        .children = &.{},
        .source_form_idx = input.form_idx,
    });

    var link_kvs: std.ArrayList(Lowering.EmittedKvpair) = .empty;
    try link_kvs.append(arena, .{ .key = try arena.dupe(u8, "from"), .value = .{ .symbol = name } });
    try link_kvs.append(arena, .{ .key = try arena.dupe(u8, "to"), .value = .{ .symbol = target } });
    try out.append(arena, .{
        .head = try arena.dupe(u8, "link"),
        .kvpairs = try link_kvs.toOwnedSlice(arena),
        .children = &.{},
        .source_form_idx = input.form_idx,
    });
}

pub const test_probe_v1: Lowering.LoweringHook = .{
    .id = "test/probe-v1",
    .lower = lowerProbe,
};

fn lowerProbe(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    var kvpairs: std.ArrayList(Lowering.EmittedKvpair) = .empty;

    for (input.form_spec.keys) |key| {
        const maybe_value: ?Lowering.EmittedValue = switch (key.value_type) {
            .symbol => if (try input.symbol(key.name)) |s| .{ .symbol = s } else null,
            .string => if (try input.string(key.name)) |s| .{ .string = s } else null,
            .number => if (try input.number(key.name)) |n| .{ .number = n } else null,
            .boolean => if (try input.boolean(key.name)) |b| .{ .boolean = b } else null,
            else => null,
        };
        if (maybe_value) |v| {
            try kvpairs.append(arena, .{
                .key = try arena.dupe(u8, key.name),
                .value = v,
            });
        }
    }

    try out.append(arena, .{
        .head = try arena.dupe(u8, "echo"),
        .kvpairs = try kvpairs.toOwnedSlice(arena),
        .children = &.{},
        .source_form_idx = input.form_idx,
    });
}

pub const test_probe_wrong_call_v1: Lowering.LoweringHook = .{
    .id = "test/probe-wrong-call-v1",
    .lower = lowerProbeWrongCall,
};

fn lowerProbeWrongCall(
    _: Allocator,
    input: *const Lowering.LoweringInput,
    _: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    _ = try input.symbol("n");
}

pub const test_fanout_v1: Lowering.LoweringHook = .{
    .id = "test/fanout-v1",
    .lower = lowerFanout,
};

fn lowerFanout(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    try out.append(arena, .{
        .head = try arena.dupe(u8, "left"),
        .source_form_idx = input.form_idx,
    });
    try out.append(arena, .{
        .head = try arena.dupe(u8, "right"),
        .source_form_idx = input.form_idx,
    });
}

pub const test_to_row_v1: Lowering.LoweringHook = .{
    .id = "test/to-row-v1",
    .lower = lowerToRow,
};

fn lowerToRow(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    try out.append(arena, .{
        .head = try arena.dupe(u8, "row"),
        .source_form_idx = input.form_idx,
    });
}

pub const test_nest_emit_v1: Lowering.LoweringHook = .{
    .id = "test/nest-emit-v1",
    .lower = lowerNestEmit,
};

fn lowerNestEmit(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const child = try arena.alloc(Lowering.EmittedValue, 1);
    child[0] = .{ .form = .{
        .head = try arena.dupe(u8, "leaf"),
        .source_form_idx = input.form_idx,
    } };
    try out.append(arena, .{
        .head = try arena.dupe(u8, "wrap"),
        .children = child,
        .source_form_idx = input.form_idx,
    });
}

pub const webgpu_render_graph_v1: Lowering.LoweringHook = .{
    .id = "webgpu/render-graph-v1",
    .lower = lowerRenderGraph,
};

fn lowerRenderGraph(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const view = input.view;
    const hdr = view.tree.formHeader(input.form_idx);

    var id: usize = 0;
    for (hdr.children) |child| {
        if (view.tree.tagOf(child) != .form) continue;
        if (!std.mem.eql(u8, view.tree.formHeader(child).head, "pass")) continue;

        const pass_name = (try passSymbol(arena, view, child, "name")) orelse return error.HookFailed;
        const multisample = try passBoolean(view, child, "multisample");

        {
            const kvs = try arena.alloc(Lowering.EmittedKvpair, 1);
            kvs[0] = .{
                .key = try arena.dupe(u8, "name"),
                .value = .{ .symbol = try std.fmt.allocPrint(arena, "tex-{d}", .{id}) },
            };
            try out.append(arena, .{
                .head = try arena.dupe(u8, "gpu-texture"),
                .kvpairs = kvs,
                .source_form_idx = input.form_idx,
            });
        }

        {
            var kvs: std.ArrayList(Lowering.EmittedKvpair) = .empty;
            try kvs.append(arena, .{ .key = try arena.dupe(u8, "name"), .value = .{ .symbol = pass_name } });
            if (id > 0) {
                try kvs.append(arena, .{
                    .key = try arena.dupe(u8, "reads"),
                    .value = .{ .symbol = try std.fmt.allocPrint(arena, "tex-{d}", .{id - 1}) },
                });
            }
            try out.append(arena, .{
                .head = try arena.dupe(u8, "gpu-render-pass"),
                .kvpairs = try kvs.toOwnedSlice(arena),
                .source_form_idx = input.form_idx,
            });
        }

        if (multisample) {
            const kvs = try arena.alloc(Lowering.EmittedKvpair, 1);
            kvs[0] = .{ .key = try arena.dupe(u8, "pass"), .value = .{ .symbol = pass_name } };
            try out.append(arena, .{
                .head = try arena.dupe(u8, "gpu-auto-blit"),
                .kvpairs = kvs,
                .source_form_idx = input.form_idx,
            });
        }

        id += 1;
    }

    if (id == 0) return error.HookFailed;
}

fn passSymbol(
    arena: Allocator,
    view: EffectiveView.EffectiveView,
    form_idx: Ast.NodeIndex,
    key: []const u8,
) Lowering.LoweringError!?[]const u8 {
    const ev = view.getEffectiveValue(form_idx, key) orelse return null;
    return switch (ev) {
        .author => |node| switch (view.tree.tagOf(node)) {
            .symbol => try arena.dupe(u8, view.tree.symbolText(node)),
            .keyword => try arena.dupe(u8, view.tree.keywordText(node)),
            else => error.HookFailed,
        },
        .default => |entry| switch (entry.value) {
            .keyword => |k| try arena.dupe(u8, k),
            else => error.HookFailed,
        },
    };
}

fn passBoolean(
    view: EffectiveView.EffectiveView,
    form_idx: Ast.NodeIndex,
    key: []const u8,
) Lowering.LoweringError!bool {
    const ev = view.getEffectiveValue(form_idx, key) orelse return false;
    return switch (ev) {
        .author => |node| switch (view.tree.tagOf(node)) {
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

pub const test_synth_terminal_v1: Lowering.LoweringHook = .{
    .id = "test/synth-terminal-v1",
    .lower = lowerSynthTerminal,
};

fn lowerSynthTerminal(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const kvs = try arena.alloc(Lowering.EmittedKvpair, 1);
    kvs[0] = .{
        .key = try arena.dupe(u8, "name"),
        .value = .{ .symbol = try arena.dupe(u8, "default-sampler") },
    };
    try out.append(arena, .{
        .head = try arena.dupe(u8, "gpu-sampler"),
        .kvpairs = kvs,
        .source_form_idx = input.form_idx,
    });
}

pub const test_synth_positional_v1: Lowering.LoweringHook = .{
    .id = "test/synth-positional-v1",
    .lower = lowerSynthPositional,
};

fn lowerSynthPositional(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const children = try arena.alloc(Lowering.EmittedValue, 1);
    children[0] = .{ .symbol = try arena.dupe(u8, "shader") };
    try out.append(arena, .{
        .head = try arena.dupe(u8, "module"),
        .children = children,
        .source_form_idx = input.form_idx,
    });
}

pub const webgpu_render_pipeline_v1: Lowering.LoweringHook = .{
    .id = "webgpu/render-pipeline-v1",
    .lower = lowerRenderPipeline,
};

fn lowerRenderPipeline(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const view = input.view;
    var kvs: std.ArrayList(Lowering.EmittedKvpair) = .empty;

    if (try input.string("label")) |label| {
        try kvs.append(arena, .{ .key = try arena.dupe(u8, "label"), .value = .{ .string = label } });
    }

    const sample_count = (try input.numberEval("sample-count")) orelse return error.HookFailed;
    try kvs.append(arena, .{ .key = try arena.dupe(u8, "sample-count"), .value = .{ .number = sample_count } });

    const hdr = view.tree.formHeader(input.form_idx);
    for (hdr.children) |child| {
        if (view.tree.tagOf(child) != .form) continue;
        if (!std.mem.eql(u8, view.tree.formHeader(child).head, "depth-stencil")) continue;
        if (try passSymbol(arena, view, child, "format")) |fmt| {
            try kvs.append(arena, .{ .key = try arena.dupe(u8, "depth-format"), .value = .{ .symbol = fmt } });
        }
        break;
    }

    try out.append(arena, .{
        .head = try arena.dupe(u8, "gpu-render-pipeline-descriptor"),
        .kvpairs = try kvs.toOwnedSlice(arena),
        .source_form_idx = input.form_idx,
    });
}

pub const test_eval_env_v1: Lowering.LoweringHook = .{
    .id = "test/eval-env-v1",
    .lower = lowerEvalEnv,
};

fn lowerEvalEnv(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const count = (try input.numberEval("count")) orelse return error.HookFailed;
    var kvs: std.ArrayList(Lowering.EmittedKvpair) = .empty;
    try kvs.append(arena, .{ .key = try arena.dupe(u8, "count"), .value = .{ .number = count } });
    try out.append(arena, .{
        .head = try arena.dupe(u8, "descriptor"),
        .kvpairs = try kvs.toOwnedSlice(arena),
        .source_form_idx = input.form_idx,
    });
}

fn evalEnvSchema(a: Allocator) Allocator.Error!Schema.Schema {
    const thing_keys = try a.alloc(Plugin.KeySpec, 1);
    thing_keys[0] = .{ .name = "count", .value_type = .number, .optional = true };
    const produces = try a.alloc([]const u8, 1);
    produces[0] = "descriptor";
    const forms = try a.alloc(Plugin.FormSpec, 2);
    forms[0] = .{
        .name = "thing",
        .keys = thing_keys,
        .lowering = .{ .hook = "test/eval-env-v1", .produces = produces },
    };
    forms[1] = .{ .name = "descriptor", .open = true };
    const plugins_slice = try a.alloc(Plugin.Plugin, 2);
    plugins_slice[0] = core.plugin;
    plugins_slice[1] = .{ .name = "test", .forms = forms };
    return .{ .plugins = plugins_slice };
}

const EvalEnvOutcome = struct {
    count: ?f64 = null,
    first_diag: ?Ast.Diagnostic.Code = null,
    invocations: usize = 0,
    diagnostics: usize = 0,
};

fn runEvalEnv(
    gpa: Allocator,
    schema: Schema.Schema,
    src: [:0]const u8,
    env: *const Expr.Env,
) !EvalEnvOutcome {
    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();

    var overlay_arena = std.heap.ArenaAllocator.init(gpa);
    defer overlay_arena.deinit();
    var mat = try MaterializedDefaults.materializeDefaults(gpa, overlay_arena.allocator(), &tree, tree.root, schema);
    defer mat.deinit(gpa);

    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, test_eval_env_v1);

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try Lowering.runLoweringPassWithEnv(gpa, pass_arena.allocator(), &tree, tree.root, schema, &mat.materialized, &registry, .{}, env);
    defer pr.deinit(gpa);

    var out: EvalEnvOutcome = .{ .invocations = pr.invocations.len, .diagnostics = pr.diagnostics.len };
    if (pr.invocations.len > 0 and pr.invocations[0].forms.len > 0) {
        const kvs = pr.invocations[0].forms[0].kvpairs;
        if (kvs.len > 0) out.count = kvs[0].value.number;
    }
    if (pr.diagnostics.len > 0) out.first_diag = pr.diagnostics[0].code;
    return out;
}

fn evalEnvSchemaWithDefault(
    a: Allocator,
    value_type: Plugin.ValueType,
    default: Plugin.KeySpec.Default,
) Allocator.Error!Schema.Schema {
    const thing_keys = try a.alloc(Plugin.KeySpec, 1);
    thing_keys[0] = .{ .name = "count", .value_type = value_type, .default = default, .optional = true };
    const produces = try a.alloc([]const u8, 1);
    produces[0] = "descriptor";
    const forms = try a.alloc(Plugin.FormSpec, 2);
    forms[0] = .{
        .name = "thing",
        .keys = thing_keys,
        .lowering = .{ .hook = "test/eval-env-v1", .produces = produces },
    };
    forms[1] = .{ .name = "descriptor", .open = true };
    const plugins_slice = try a.alloc(Plugin.Plugin, 2);
    plugins_slice[0] = core.plugin;
    plugins_slice[1] = .{ .name = "test", .forms = forms };
    return .{ .plugins = plugins_slice };
}
