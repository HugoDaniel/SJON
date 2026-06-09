const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Ast = @import("Ast.zig");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const ManifestLoader = @import("ManifestLoader.zig");
const Resolver = @import("Resolver.zig");
const Parser = @import("Parser.zig");
const Validator = @import("Validator.zig");
const Expr = @import("Expr.zig");
const MaterializedDefaults = @import("MaterializedDefaults.zig");
const Lowering = @import("Lowering.zig");
const wasm_plugin_invoker = @import("wasm_plugin_invoker.zig");
const core_plugin = @import("plugins/core.zig");
const SchemaExport = @import("SchemaExport/SchemaExport.zig");
const LoweringGraph = @import("LoweringGraph.zig");

const native_plugin_exec = builtin.target.cpu.arch != .wasm32 and build_options.plugin_exec;

const PluginRuntime = if (native_plugin_exec) @import("PluginRuntime.zig") else opaque {};

const FilesystemResolver = if (builtin.os.tag == .freestanding) struct {
    pub const Stub = void;
} else @import("FilesystemResolver.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{OutOfMemory};

pub const FailurePolicy = enum { strict, lenient };

const empty_lowering_env: Expr.Env = .{};

pub const HostOptions = struct {
    failure_policy: FailurePolicy = .lenient,

    effective_axes: Validator.EffectiveAxes = .{},

    project_root: ?[]const u8 = null,

    project_file: ?[]const u8 = null,

    plugin_search_roots: []const []const u8 = &.{},

    resolver: ?Resolver.Resolver = null,

    io: ?Io = null,

    lowering_registry: ?*const Lowering.LoweringRegistry = null,

    lowering_env: *const Expr.Env = &empty_lowering_env,
};

pub const Phase = enum { manifest, aggregate, lowering, validation };

pub const HostDiagnostic = struct {
    phase: Phase,
    code: Ast.Diagnostic.Code,
    severity: Ast.Diagnostic.Severity,
    message: []const u8,
    span: Ast.Span,
    path: []const []const u8,
    declaration_span: ?Ast.Span = null,
};

pub const EvalResult = struct {
    forest_index: usize,
    value: Expr.Value,
};

pub const HostResult = struct {
    arena: std.heap.ArenaAllocator,

    tree: Ast.Tree,

    plugin_results: []ManifestLoader.Result,

    plugins: []const Plugin.Plugin,

    schema: Schema.Schema,

    declarations: []const Ast.NodeIndex,
    references: []const Ast.NodeIndex,
    data_forest: []const Ast.NodeIndex,

    diagnostics: []const HostDiagnostic,

    evaluated_results: []const EvalResult,

    materialized_defaults: MaterializedDefaults.MaterializedDefaults,

    lowered_tree: ?Ast.Tree = null,

    lowering_provenance: Lowering.LoweringProvenance = .{},

    pub fn deinit(self: *HostResult) void {
        for (self.plugin_results) |*pr| pr.deinit();
        self.tree.deinit();
        if (self.lowered_tree) |*lt| lt.deinit();
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const HostResult) bool {
        for (self.diagnostics) |d| if (d.severity == .err) return true;
        return false;
    }
};

pub const LoadedProject = struct {
    arena: std.heap.ArenaAllocator,
    schema: Schema.Schema,
    plugins: []const Plugin.Plugin,
    plugin_results: []ManifestLoader.Result,
    diagnostics: []const HostDiagnostic,
    project_source: ?[:0]const u8,
    project_uri: ?[]const u8,

    pub fn deinit(self: *LoadedProject) void {
        for (self.plugin_results) |*pr| pr.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn hasErrors(self: *const LoadedProject) bool {
        for (self.diagnostics) |d| if (d.severity == .err) return true;
        return false;
    }
};

pub fn validateDocument(
    gpa: Allocator,
    source: [:0]const u8,
    options: HostOptions,
) Error!HostResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var tree = Parser.parse(gpa, source) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    errdefer tree.deinit();

    var diags: std.ArrayList(HostDiagnostic) = .empty;

    for (tree.diagnostics) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .manifest, null));
    }

    var runtime_storage: if (native_plugin_exec) PluginRuntime else void = undefined;
    var runtime_initialized: bool = false;
    defer if (comptime native_plugin_exec) {
        if (runtime_initialized) runtime_storage.deinit(gpa);
    };

    const part = try partition(a, &tree);

    var plugin_results: std.ArrayList(ManifestLoader.Result) = .empty;
    errdefer for (plugin_results.items) |*pr| pr.deinit();

    for (part.declarations) |decl_idx| {
        const hdr = tree.formHeader(decl_idx);
        const decl_head_span = hdr.head_span;

        var sub: Ast.Tree = tree;
        const sub_roots = try a.alloc(Ast.NodeIndex, 1);
        sub_roots[0] = decl_idx;
        sub.root = sub_roots;

        var loaded = ManifestLoader.load(gpa, sub) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            error.NotAPluginManifest => {
                try diags.append(a, .{
                    .phase = .manifest,
                    .code = .invalid_manifest,
                    .severity = .err,
                    .message = try a.dupe(u8, "(plugin …) declaration rejected by manifest loader"),
                    .span = decl_head_span,
                    .path = &.{},
                    .declaration_span = decl_head_span,
                });
                continue;
            },
        };

        for (loaded.diagnostics) |d| {
            try diags.append(a, try wrapDiagnostic(a, d, .manifest, decl_head_span));
        }

        if (loaded.hasErrors()) {
            loaded.deinit();
            continue;
        }

        try plugin_results.append(a, loaded);
    }

    var owned_default_resolver: ?(if (builtin.os.tag == .freestanding) void else FilesystemResolver) = null;
    defer if (comptime builtin.os.tag != .freestanding) {
        if (owned_default_resolver) |*r| r.deinit();
    };

    const effective_resolver: ?Resolver.Resolver = blk: {
        if (options.resolver) |r| break :blk r;
        if (comptime builtin.os.tag == .freestanding) break :blk null;
        const root = options.project_root orelse break :blk null;
        const io = options.io orelse break :blk null;
        owned_default_resolver = try FilesystemResolver.init(
            gpa,
            io,
            root,
            options.project_file,
        );
        const project_diags = owned_default_resolver.?.takeProjectDiagnostics();
        for (project_diags) |d| {
            try diags.append(a, try wrapProjectDiagnostic(a, d));
        }
        break :blk owned_default_resolver.?.resolver();
    };

    for (part.references) |ref_idx| {
        const ref_hdr = tree.formHeader(ref_idx);
        const ref_head_span = ref_hdr.head_span;

        var parsed = try Resolver.parseReference(a, &tree, ref_idx);
        for (parsed.diagnostics) |d| {
            try diags.append(a, try wrapDiagnostic(a, d, .manifest, ref_head_span));
        }
        if (parsed.hasErrors()) continue;

        const resolver = effective_resolver orelse {
            try diags.append(a, .{
                .phase = .manifest,
                .code = .unresolved_plugin,
                .severity = .err,
                .message = try std.fmt.allocPrint(
                    a,
                    "no resolver configured for `(use-plugin \"{s}\" …)`",
                    .{parsed.reference.name},
                ),
                .span = parsed.reference.span,
                .path = &.{},
                .declaration_span = ref_head_span,
            });
            continue;
        };

        const resolution = try resolver.resolve(resolver.ctx, parsed.reference, a);
        switch (resolution) {
            .manifest => |m| {
                if (try enforceHashPin(a, parsed.reference, ref_head_span, m, &diags)) continue;
                const before_len = plugin_results.items.len;
                try loadResolvedManifest(
                    gpa,
                    a,
                    m.source,
                    m.wasm,
                    parsed.reference,
                    ref_head_span,
                    &plugin_results,
                    &diags,
                );
                if (plugin_results.items.len <= before_len) continue;

                const new_idx = plugin_results.items.len - 1;
                const new_name = plugin_results.items[new_idx].plugin.name;
                var is_duplicate = false;
                for (plugin_results.items[0..before_len]) |*pr| {
                    if (!std.mem.eql(u8, pr.plugin.name, new_name)) continue;
                    try diags.append(a, .{
                        .phase = .manifest,
                        .code = .duplicate_plugin_name,
                        .severity = .err,
                        .message = try std.fmt.allocPrint(
                            a,
                            "(use-plugin \"{s}\" …) resolves to plugin `:name {s}` already loaded by an earlier reference",
                            .{ parsed.reference.name, new_name },
                        ),
                        .span = parsed.reference.span,
                        .path = &.{},
                        .declaration_span = ref_head_span,
                    });
                    var popped = plugin_results.pop().?;
                    popped.deinit();
                    is_duplicate = true;
                    break;
                }
                if (is_duplicate) continue;

                if (m.wasm == null) {
                    const loaded_plugin = &plugin_results.items[plugin_results.items.len - 1].plugin;
                    var missing_count: usize = 0;
                    for (loaded_plugin.expr_funcs) |func| {
                        if (func.wasm_export_name != null) missing_count += 1;
                    }
                    if (missing_count > 0) {
                        try diags.append(a, .{
                            .phase = .manifest,
                            .code = .plugin_wasm_required,
                            .severity = .err,
                            .message = try std.fmt.allocPrint(
                                a,
                                "(use-plugin \"{s}\" …) manifest declares {d} `:impl \"wasm:…\"` export(s) but resolver returned no wasm bytes",
                                .{ parsed.reference.name, missing_count },
                            ),
                            .span = parsed.reference.span,
                            .path = &.{},
                            .declaration_span = ref_head_span,
                        });
                    }
                } else if (comptime native_plugin_exec) {
                    if (try preflightWasmIfPresent(
                        a,
                        gpa,
                        &plugin_results,
                        &diags,
                        parsed.reference,
                        ref_head_span,
                        m,
                        &runtime_storage,
                        &runtime_initialized,
                    )) continue;
                }
            },
            .failure => |failure| {
                try diags.append(a, .{
                    .phase = .manifest,
                    .code = failure.code,
                    .severity = .err,
                    .message = try a.dupe(u8, failure.detail),
                    .span = parsed.reference.span,
                    .path = &.{},
                    .declaration_span = ref_head_span,
                });
            },
        }
    }

    const plugin_results_slice = try plugin_results.toOwnedSlice(a);
    errdefer for (plugin_results_slice) |*pr| pr.deinit();
    const plugins_slice = try a.alloc(Plugin.Plugin, plugin_results_slice.len);
    for (plugin_results_slice, 0..) |pr, i| plugins_slice[i] = pr.plugin;
    const schema: Schema.Schema = .{ .plugins = plugins_slice };

    const eval_plugins = try a.alloc(Plugin.Plugin, plugins_slice.len + 1);
    eval_plugins[0] = core_plugin.plugin;
    for (plugins_slice, 0..) |p, i| eval_plugins[i + 1] = p;
    const eval_schema: Schema.Schema = .{ .plugins = eval_plugins };

    const cross_diags = schema.validateCrossRefs(gpa) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    defer freeAggregateDiagnostics(gpa, cross_diags);
    for (cross_diags) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .aggregate, null));
    }

    const union_diags = schema.validateUnions(gpa) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    defer freeAggregateDiagnostics(gpa, union_diags);
    for (union_diags) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .aggregate, null));
    }

    const form_diags = schema.validateForms(gpa) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    defer freeAggregateDiagnostics(gpa, form_diags);
    for (form_diags) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .aggregate, null));
    }

    const lowering_diags = schema.validateLowering(gpa) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    defer freeAggregateDiagnostics(gpa, lowering_diags);
    for (lowering_diags) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .aggregate, null));
    }

    const default_diags = schema.validateDefaults(gpa) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    defer freeAggregateDiagnostics(gpa, default_diags);
    for (default_diags) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .aggregate, null));
    }

    var mat_result = MaterializedDefaults.materializeDefaults(
        gpa,
        a,
        &tree,
        part.data_forest,
        schema,
    ) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    defer mat_result.deinit(gpa);

    var lowered_tree: ?Ast.Tree = null;
    var lowering_provenance: Lowering.LoweringProvenance = .{};
    errdefer if (lowered_tree) |*t| t.deinit();

    var stage_trees: std.ArrayList(Lowering.LoweredTree) = .empty;
    defer stage_trees.deinit(gpa);
    errdefer for (stage_trees.items) |*lt| lt.deinit();
    var stage_mats: std.ArrayList(MaterializedDefaults.Result) = .empty;
    defer {
        for (stage_mats.items) |*m| m.deinit(gpa);
        stage_mats.deinit(gpa);
    }
    var stage_terminals: std.ArrayList([]const Ast.NodeIndex) = .empty;
    defer stage_terminals.deinit(gpa);

    var unlowered_roots: []const Ast.NodeIndex = part.data_forest;

    if (options.lowering_registry) |registry| {
        try stage_trees.ensureTotalCapacity(gpa, Lowering.MAX_LOWERING_STAGES);
        try stage_mats.ensureTotalCapacity(gpa, Lowering.MAX_LOWERING_STAGES);
        try stage_terminals.ensureTotalCapacity(gpa, Lowering.MAX_LOWERING_STAGES);

        var emitted_total: usize = 0;
        var active_tree: *const Ast.Tree = &tree;
        var active_forest: []const Ast.NodeIndex = part.data_forest;
        var active_overlay: *const MaterializedDefaults.MaterializedDefaults = &mat_result.materialized;
        var active_slot: ?usize = null;

        var stage: usize = 0;
        while (true) : (stage += 1) {
            var pass_result = Lowering.runLoweringPassBudgeted(
                gpa,
                a,
                active_tree,
                active_forest,
                eval_schema,
                active_overlay,
                registry,
                options.effective_axes,
                options.lowering_env,
                &emitted_total,
                Lowering.MAX_LOWERING_STEPS,
            ) catch |err| switch (err) {
                error.OutOfMemory => return Error.OutOfMemory,
            };
            defer pass_result.deinit(gpa);

            for (pass_result.diagnostics) |d| {
                try diags.append(a, try wrapDiagnostic(a, d, .lowering, null));
            }

            var terminal: []const Ast.NodeIndex = undefined;
            var stop = false;
            if (pass_result.invocations.len == 0) {
                terminal = active_forest;
                stop = true;
            } else if (stage + 1 >= Lowering.MAX_LOWERING_STAGES) {
                for (pass_result.invocations) |inv| {
                    const head = active_tree.formHeader(inv.source_form_idx).head;
                    const path = try a.alloc([]const u8, 2);
                    path[0] = try a.dupe(u8, head);
                    path[1] = try a.dupe(u8, "lowering");
                    try diags.append(a, try wrapDiagnostic(a, .{
                        .span = active_tree.spanOf(inv.source_form_idx),
                        .message = try std.fmt.allocPrint(a, "form `({s} …)` would lower beyond the maximum staging depth of {d} layers", .{ head, Lowering.MAX_LOWERING_STAGES }),
                        .severity = .err,
                        .code = .lowering_output_too_large,
                        .path = path,
                    }, .lowering, null));
                }
                terminal = active_forest;
                stop = true;
            } else {
                terminal = try filterUnloweredRoots(a, active_forest, pass_result.invocations);
            }
            if (active_slot) |s| stage_terminals.items[s] = terminal else unlowered_roots = terminal;
            if (stop) break;

            const lt = Lowering.buildLoweredTree(gpa, pass_result.invocations, active_tree) catch |err| switch (err) {
                error.OutOfMemory => return Error.OutOfMemory,
            };
            stage_trees.appendAssumeCapacity(lt);
            const slot = stage_trees.items.len - 1;
            const lmat = MaterializedDefaults.materializeDefaults(
                gpa,
                a,
                &stage_trees.items[slot].tree,
                stage_trees.items[slot].tree.root,
                schema,
            ) catch |err| switch (err) {
                error.OutOfMemory => return Error.OutOfMemory,
            };
            stage_mats.appendAssumeCapacity(lmat);
            stage_terminals.appendAssumeCapacity(&.{});

            active_tree = &stage_trees.items[slot].tree;
            active_forest = active_tree.root;
            active_overlay = &stage_mats.items[slot].materialized;
            active_slot = slot;
        }
    }

    var source_view: Ast.Tree = tree;
    source_view.root = unlowered_roots;

    if (stage_trees.items.len > 0) {
        const n = stage_trees.items.len;
        const forest = try a.alloc(Ast.Tree, 1 + n);
        const overlay_ptrs = try a.alloc(?*const MaterializedDefaults.MaterializedDefaults, 1 + n);
        forest[0] = source_view;
        overlay_ptrs[0] = &mat_result.materialized;
        for (0..n) |i| {
            var view = stage_trees.items[i].tree;
            view.root = stage_terminals.items[i];
            forest[1 + i] = view;
            overlay_ptrs[1 + i] = &stage_mats.items[i].materialized;
        }
        var fr = Validator.validateForestWithOptions(gpa, forest, eval_schema, .{
            .overlays = overlay_ptrs,
            .axes = options.effective_axes,
            .share_scope = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
        };
        defer fr.deinit(gpa);
        for (fr.results) |r| {
            for (r.diagnostics) |d| {
                try diags.append(a, try wrapDiagnostic(a, d, .validation, null));
            }
        }

        const last = n - 1;
        lowered_tree = stage_trees.items[last].tree;
        lowering_provenance = stage_trees.items[last].provenance;
        for (stage_trees.items[0..last]) |*lt| lt.deinit();
        stage_trees.clearRetainingCapacity();
    } else {
        const forest = [_]Ast.Tree{source_view};
        var fr = Validator.validateForestWithOptions(gpa, &forest, eval_schema, .{
            .overlay = &mat_result.materialized,
            .axes = options.effective_axes,
        }) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
        };
        defer fr.deinit(gpa);
        for (fr.results) |r| {
            for (r.diagnostics) |d| {
                try diags.append(a, try wrapDiagnostic(a, d, .validation, null));
            }
        }
    }

    for (mat_result.diagnostics) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .validation, null));
    }
    for (stage_mats.items) |*m| {
        for (m.diagnostics) |d| {
            try diags.append(a, try wrapDiagnostic(a, d, .validation, null));
        }
    }

    var eval_results: std.ArrayList(EvalResult) = .empty;
    const runtime_opt: ?*anyopaque = if (comptime native_plugin_exec)
        (if (runtime_initialized) @ptrCast(&runtime_storage) else null)
    else
        null;
    try runEvalPass(a, gpa, &tree, part.data_forest, eval_schema, &diags, &eval_results, runtime_opt);

    return .{
        .arena = arena,
        .tree = tree,
        .plugin_results = plugin_results_slice,
        .plugins = plugins_slice,
        .schema = schema,
        .declarations = part.declarations,
        .references = part.references,
        .data_forest = part.data_forest,
        .diagnostics = try diags.toOwnedSlice(a),
        .evaluated_results = try eval_results.toOwnedSlice(a),
        .materialized_defaults = mat_result.materialized,
        .lowered_tree = lowered_tree,
        .lowering_provenance = lowering_provenance,
    };
}

pub fn loadProject(
    gpa: Allocator,
    options: HostOptions,
) Error!LoadedProject {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var diags: std.ArrayList(HostDiagnostic) = .empty;
    var plugin_results: std.ArrayList(ManifestLoader.Result) = .empty;
    errdefer for (plugin_results.items) |*pr| pr.deinit();

    var project_source: ?[:0]const u8 = null;
    var project_uri: ?[]const u8 = null;

    if (comptime builtin.os.tag != .freestanding) {
        if (options.project_root) |root| if (options.io) |io| {
            const project_file = if (options.project_file) |pf|
                try a.dupe(u8, pf)
            else
                try buildProjectFilePath(a, root);

            var fs = try FilesystemResolver.init(gpa, io, root, project_file);
            defer fs.deinit();

            const project_diags = fs.takeProjectDiagnostics();
            for (project_diags) |d| {
                try diags.append(a, try wrapProjectDiagnostic(a, d));
            }

            if (fs.getProjectSource()) |src| {
                project_source = try a.dupeZ(u8, src);
                project_uri = try buildFileUri(a, project_file);
            }

            var it = fs.iterateProjectPlugins();
            while (it.next()) |entry| {
                try loadProjectPlugin(gpa, a, entry, &plugin_results, &diags);
            }
        };
    }

    const plugin_results_slice = try plugin_results.toOwnedSlice(a);
    errdefer for (plugin_results_slice) |*pr| pr.deinit();

    const plugins_slice = try a.alloc(Plugin.Plugin, plugin_results_slice.len + 1);
    plugins_slice[0] = core_plugin.plugin;
    for (plugin_results_slice, 0..) |pr, i| plugins_slice[i + 1] = pr.plugin;
    const schema: Schema.Schema = .{ .plugins = plugins_slice };

    return .{
        .arena = arena,
        .schema = schema,
        .plugins = plugins_slice,
        .plugin_results = plugin_results_slice,
        .diagnostics = try diags.toOwnedSlice(a),
        .project_source = project_source,
        .project_uri = project_uri,
    };
}

fn buildProjectFilePath(a: Allocator, root: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, root);
    if (out.items.len == 0 or out.items[out.items.len - 1] != '/') {
        try out.append(a, '/');
    }
    try out.appendSlice(a, FilesystemResolver.PROJECT_FILE_NAME);
    return out.toOwnedSlice(a);
}

fn buildFileUri(a: Allocator, abs_path: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "file://");
    if (abs_path.len == 0 or abs_path[0] != '/') {
        try out.append(a, '/');
    }
    try out.appendSlice(a, abs_path);
    return out.toOwnedSlice(a);
}

fn loadProjectPlugin(
    gpa: Allocator,
    a: Allocator,
    entry: FilesystemResolver.ProjectPluginEntry,
    plugin_results: *std.ArrayList(ManifestLoader.Result),
    diags: *std.ArrayList(HostDiagnostic),
) Allocator.Error!void {
    var manifest_tree = Parser.parse(gpa, entry.manifest_source) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    defer manifest_tree.deinit();

    for (manifest_tree.diagnostics) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .manifest, null));
    }

    var loaded = ManifestLoader.load(gpa, manifest_tree) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        error.NotAPluginManifest => {
            try diags.append(a, .{
                .phase = .manifest,
                .code = .invalid_manifest,
                .severity = .err,
                .message = try std.fmt.allocPrint(
                    a,
                    "manifest at `{s}` is not a (plugin …) form",
                    .{entry.manifest_path},
                ),
                .span = .{ .start = 0, .end = 0 },
                .path = &.{},
                .declaration_span = null,
            });
            return;
        },
    };

    for (loaded.diagnostics) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .manifest, null));
    }

    if (loaded.hasErrors()) {
        loaded.deinit();
        return;
    }

    try plugin_results.append(a, loaded);
}

const Partition = struct {
    declarations: []const Ast.NodeIndex,
    references: []const Ast.NodeIndex,
    data_forest: []const Ast.NodeIndex,
};

fn partition(a: Allocator, tree: *const Ast.Tree) Allocator.Error!Partition {
    var decls: std.ArrayList(Ast.NodeIndex) = .empty;
    var refs: std.ArrayList(Ast.NodeIndex) = .empty;
    var data: std.ArrayList(Ast.NodeIndex) = .empty;

    for (tree.root) |idx| {
        if (tree.tagOf(idx) == .form) {
            const hdr = tree.formHeader(idx);
            if (hdr.namespace == null) {
                if (std.mem.eql(u8, hdr.head, "plugin")) {
                    try decls.append(a, idx);
                    continue;
                }
                if (std.mem.eql(u8, hdr.head, "use-plugin")) {
                    try refs.append(a, idx);
                    continue;
                }
            }
        }
        try data.append(a, idx);
    }

    return .{
        .declarations = try decls.toOwnedSlice(a),
        .references = try refs.toOwnedSlice(a),
        .data_forest = try data.toOwnedSlice(a),
    };
}

fn filterUnloweredRoots(
    a: Allocator,
    forest: []const Ast.NodeIndex,
    invocations: []const Lowering.Invocation,
) Allocator.Error![]const Ast.NodeIndex {
    const filtered = try a.alloc(Ast.NodeIndex, forest.len);
    var n: usize = 0;
    for (forest) |root_idx| {
        var lowered = false;
        for (invocations) |inv| {
            if (inv.source_form_idx == root_idx) {
                lowered = true;
                break;
            }
        }
        if (!lowered) {
            filtered[n] = root_idx;
            n += 1;
        }
    }
    return filtered[0..n];
}

pub fn wrapDiagnostic(
    a: Allocator,
    d: Ast.Diagnostic,
    phase: Phase,
    declaration_span: ?Ast.Span,
) Allocator.Error!HostDiagnostic {
    const path = try a.alloc([]const u8, d.path.len);
    for (d.path, 0..) |step, i| path[i] = try a.dupe(u8, step);
    return .{
        .phase = phase,
        .code = d.code,
        .severity = d.severity,
        .message = try a.dupe(u8, d.message),
        .span = d.span,
        .path = path,
        .declaration_span = declaration_span,
    };
}

pub const HostEvalResult = struct {
    arena: std.heap.ArenaAllocator,
    tree: Ast.Tree,
    plugin_results: []ManifestLoader.Result,
    plugins: []const Plugin.Plugin,
    schema: Schema.Schema,
    diagnostics: []const HostDiagnostic,
    value: ?Expr.Value,
    value_arena: ?std.heap.ArenaAllocator,

    pub fn deinit(self: *HostEvalResult) void {
        if (self.value_arena) |*va| va.deinit();
        for (self.plugin_results) |*pr| pr.deinit();
        self.tree.deinit();
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const HostEvalResult) bool {
        for (self.diagnostics) |d| if (d.severity == .err) return true;
        return false;
    }
};

pub const EvalExprError = Error || error{
    NoExpression,
    MultipleExpressions,
};

pub fn evalExpr(
    gpa: Allocator,
    source: [:0]const u8,
    options: HostOptions,
) EvalExprError!HostEvalResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var tree = Parser.parse(gpa, source) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    errdefer tree.deinit();

    var diags: std.ArrayList(HostDiagnostic) = .empty;

    for (tree.diagnostics) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .manifest, null));
    }

    var runtime_storage: if (native_plugin_exec) PluginRuntime else void = undefined;
    var runtime_initialized: bool = false;
    defer if (comptime native_plugin_exec) {
        if (runtime_initialized) runtime_storage.deinit(gpa);
    };

    const part = try partition(a, &tree);

    var plugin_results: std.ArrayList(ManifestLoader.Result) = .empty;
    errdefer for (plugin_results.items) |*pr| pr.deinit();

    for (part.declarations) |decl_idx| {
        const hdr = tree.formHeader(decl_idx);
        const decl_head_span = hdr.head_span;

        var sub: Ast.Tree = tree;
        const sub_roots = try a.alloc(Ast.NodeIndex, 1);
        sub_roots[0] = decl_idx;
        sub.root = sub_roots;

        var loaded = ManifestLoader.load(gpa, sub) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            error.NotAPluginManifest => {
                try diags.append(a, .{
                    .phase = .manifest,
                    .code = .invalid_manifest,
                    .severity = .err,
                    .message = try a.dupe(u8, "(plugin …) declaration rejected by manifest loader"),
                    .span = decl_head_span,
                    .path = &.{},
                    .declaration_span = decl_head_span,
                });
                continue;
            },
        };

        for (loaded.diagnostics) |d| {
            try diags.append(a, try wrapDiagnostic(a, d, .manifest, decl_head_span));
        }

        if (loaded.hasErrors()) {
            loaded.deinit();
            continue;
        }

        try plugin_results.append(a, loaded);
    }

    var owned_default_resolver: ?(if (builtin.os.tag == .freestanding) void else FilesystemResolver) = null;
    defer if (comptime builtin.os.tag != .freestanding) {
        if (owned_default_resolver) |*r| r.deinit();
    };

    const effective_resolver: ?Resolver.Resolver = blk: {
        if (options.resolver) |r| break :blk r;
        if (comptime builtin.os.tag == .freestanding) break :blk null;
        const root = options.project_root orelse break :blk null;
        const io = options.io orelse break :blk null;
        owned_default_resolver = try FilesystemResolver.init(
            gpa,
            io,
            root,
            options.project_file,
        );
        const project_diags = owned_default_resolver.?.takeProjectDiagnostics();
        for (project_diags) |d| {
            try diags.append(a, try wrapProjectDiagnostic(a, d));
        }
        break :blk owned_default_resolver.?.resolver();
    };

    for (part.references) |ref_idx| {
        const ref_hdr = tree.formHeader(ref_idx);
        const ref_head_span = ref_hdr.head_span;

        var parsed = try Resolver.parseReference(a, &tree, ref_idx);
        for (parsed.diagnostics) |d| {
            try diags.append(a, try wrapDiagnostic(a, d, .manifest, ref_head_span));
        }
        if (parsed.hasErrors()) continue;

        const resolver = effective_resolver orelse {
            try diags.append(a, .{
                .phase = .manifest,
                .code = .unresolved_plugin,
                .severity = .err,
                .message = try std.fmt.allocPrint(
                    a,
                    "no resolver configured for `(use-plugin \"{s}\" …)`",
                    .{parsed.reference.name},
                ),
                .span = parsed.reference.span,
                .path = &.{},
                .declaration_span = ref_head_span,
            });
            continue;
        };

        const resolution = try resolver.resolve(resolver.ctx, parsed.reference, a);
        switch (resolution) {
            .manifest => |m| {
                if (try enforceHashPin(a, parsed.reference, ref_head_span, m, &diags)) continue;
                const before_len = plugin_results.items.len;
                try loadResolvedManifest(
                    gpa,
                    a,
                    m.source,
                    m.wasm,
                    parsed.reference,
                    ref_head_span,
                    &plugin_results,
                    &diags,
                );
                if (plugin_results.items.len <= before_len) continue;

                const new_idx = plugin_results.items.len - 1;
                const new_name = plugin_results.items[new_idx].plugin.name;
                var is_duplicate = false;
                for (plugin_results.items[0..before_len]) |*pr| {
                    if (!std.mem.eql(u8, pr.plugin.name, new_name)) continue;
                    try diags.append(a, .{
                        .phase = .manifest,
                        .code = .duplicate_plugin_name,
                        .severity = .err,
                        .message = try std.fmt.allocPrint(
                            a,
                            "(use-plugin \"{s}\" …) resolves to plugin `:name {s}` already loaded by an earlier reference",
                            .{ parsed.reference.name, new_name },
                        ),
                        .span = parsed.reference.span,
                        .path = &.{},
                        .declaration_span = ref_head_span,
                    });
                    var popped = plugin_results.pop().?;
                    popped.deinit();
                    is_duplicate = true;
                    break;
                }
                if (is_duplicate) continue;

                if (m.wasm == null) {
                    const loaded_plugin = &plugin_results.items[plugin_results.items.len - 1].plugin;
                    var missing_count: usize = 0;
                    for (loaded_plugin.expr_funcs) |func| {
                        if (func.wasm_export_name != null) missing_count += 1;
                    }
                    if (missing_count > 0) {
                        try diags.append(a, .{
                            .phase = .manifest,
                            .code = .plugin_wasm_required,
                            .severity = .err,
                            .message = try std.fmt.allocPrint(
                                a,
                                "(use-plugin \"{s}\" …) manifest declares {d} `:impl \"wasm:…\"` export(s) but resolver returned no wasm bytes",
                                .{ parsed.reference.name, missing_count },
                            ),
                            .span = parsed.reference.span,
                            .path = &.{},
                            .declaration_span = ref_head_span,
                        });
                    }
                } else if (comptime native_plugin_exec) {
                    if (try preflightWasmIfPresent(
                        a,
                        gpa,
                        &plugin_results,
                        &diags,
                        parsed.reference,
                        ref_head_span,
                        m,
                        &runtime_storage,
                        &runtime_initialized,
                    )) continue;
                }
            },
            .failure => |failure| {
                try diags.append(a, .{
                    .phase = .manifest,
                    .code = failure.code,
                    .severity = .err,
                    .message = try a.dupe(u8, failure.detail),
                    .span = parsed.reference.span,
                    .path = &.{},
                    .declaration_span = ref_head_span,
                });
            },
        }
    }

    const plugin_results_slice = try plugin_results.toOwnedSlice(a);
    errdefer for (plugin_results_slice) |*pr| pr.deinit();
    const plugins_slice = try a.alloc(Plugin.Plugin, plugin_results_slice.len);
    for (plugin_results_slice, 0..) |pr, i| plugins_slice[i] = pr.plugin;

    const eval_plugins = try a.alloc(Plugin.Plugin, plugins_slice.len + 1);
    eval_plugins[0] = core_plugin.plugin;
    for (plugins_slice, 0..) |p, i| eval_plugins[i + 1] = p;
    const schema: Schema.Schema = .{ .plugins = plugins_slice };
    const eval_schema: Schema.Schema = .{ .plugins = eval_plugins };

    const cross_diags = schema.validateCrossRefs(gpa) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    defer freeAggregateDiagnostics(gpa, cross_diags);
    for (cross_diags) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .aggregate, null));
    }

    const union_diags = schema.validateUnions(gpa) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    defer freeAggregateDiagnostics(gpa, union_diags);
    for (union_diags) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .aggregate, null));
    }

    const form_diags = schema.validateForms(gpa) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    defer freeAggregateDiagnostics(gpa, form_diags);
    for (form_diags) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .aggregate, null));
    }

    const lowering_diags = schema.validateLowering(gpa) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    defer freeAggregateDiagnostics(gpa, lowering_diags);
    for (lowering_diags) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .aggregate, null));
    }

    const default_diags = schema.validateDefaults(gpa) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    defer freeAggregateDiagnostics(gpa, default_diags);
    for (default_diags) |d| {
        try diags.append(a, try wrapDiagnostic(a, d, .aggregate, null));
    }

    if (part.data_forest.len == 0) return error.NoExpression;
    if (part.data_forest.len > 1) return error.MultipleExpressions;
    const expr_idx = part.data_forest[0];

    var has_pre_eval_error = false;
    for (diags.items) |d| if (d.severity == .err) {
        has_pre_eval_error = true;
        break;
    };

    var value: ?Expr.Value = null;
    var value_arena: ?std.heap.ArenaAllocator = null;
    if (!has_pre_eval_error) {
        const empty_env: Expr.Env = .{};
        const runtime_opt: ?*anyopaque = if (comptime native_plugin_exec)
            (if (runtime_initialized) @ptrCast(&runtime_storage) else null)
        else
            null;
        if (Expr.evalWithRuntime(gpa, &tree, expr_idx, &empty_env, eval_schema, runtime_opt)) |result| {
            value = result.value;
            value_arena = result.arena;
        } else |err| {
            switch (err) {
                error.OutOfMemory => return Error.OutOfMemory,
                else => {
                    const head_span: Ast.Span = blk: {
                        if (tree.tagOf(expr_idx) == .form) {
                            break :blk tree.formHeader(expr_idx).head_span;
                        }
                        break :blk .{ .start = 0, .end = 0 };
                    };
                    const head: []const u8 = blk: {
                        if (tree.tagOf(expr_idx) == .form) {
                            break :blk tree.formHeader(expr_idx).head;
                        }
                        break :blk "<expression>";
                    };
                    const code: ?Ast.Diagnostic.Code = switch (err) {
                        error.OutOfMemory => unreachable,
                        error.PluginFuncResultType => .plugin_func_result_type,
                        error.PluginFuncFailed => .plugin_func_failed,
                        error.PluginFuncTrapped => .plugin_func_trapped,
                        error.PluginFuncAllocFailed => .plugin_func_alloc_failed,
                        error.UnknownFunction => .unknown_form,
                        error.AmbiguousFunction => .ambiguous_form,
                        error.ArityMismatch => .arity_mismatch,
                        error.TypeMismatch => .expr_type_mismatch,
                        error.DivisionByZero => .expr_type_mismatch,
                        error.UnknownBinding => .unknown_form,
                        error.InvalidLetBinding => .expr_type_mismatch,
                        error.InvalidCondClause => .expr_type_mismatch,
                        error.InvalidBinderShape => .expr_type_mismatch,
                        error.KeywordInExpressionArgs => .expr_kvpair_not_allowed,
                        error.DepthExceeded => .recursion_depth,
                        error.MemoryBudgetExceeded => .recursion_depth,
                        error.PluginFuncNotImplemented => .plugin_func_failed,
                    };
                    if (code) |c| {
                        const message = if (c == .plugin_func_result_type or
                            c == .plugin_func_failed or
                            c == .plugin_func_trapped or
                            c == .plugin_func_alloc_failed)
                            try formatRuntimeFailureMessage(a, head, c, wasm_plugin_invoker.lastFailure())
                        else
                            try std.fmt.allocPrint(a, "{s} while evaluating `({s} …)`", .{ @errorName(err), head });
                        try diags.append(a, .{
                            .phase = .validation,
                            .code = c,
                            .severity = .err,
                            .message = message,
                            .span = head_span,
                            .path = &.{},
                            .declaration_span = null,
                        });
                    }
                },
            }
        }
    }

    return .{
        .arena = arena,
        .tree = tree,
        .plugin_results = plugin_results_slice,
        .plugins = plugins_slice,
        .schema = schema,
        .diagnostics = try diags.toOwnedSlice(a),
        .value = value,
        .value_arena = value_arena,
    };
}

fn runEvalPass(
    a: Allocator,
    gpa: Allocator,
    tree: *const Ast.Tree,
    data_forest: []const Ast.NodeIndex,
    schema: Schema.Schema,
    diags: *std.ArrayList(HostDiagnostic),
    eval_results: *std.ArrayList(EvalResult),
    runtime: ?*anyopaque,
) Error!void {
    const empty_env: Expr.Env = .{};
    for (data_forest, 0..) |idx, forest_idx| {
        if (tree.tagOf(idx) != .form) continue;
        const hdr = tree.formHeader(idx);
        const hit = schema.lookupExprFunc(hdr.head, hdr.namespace);
        if (hit != .found and !Expr.isCoreSpecialForm(hdr.head, hdr.namespace)) continue;

        var result = Expr.evalWithRuntime(gpa, tree, idx, &empty_env, schema, runtime) catch |err| {
            const code: ?Ast.Diagnostic.Code = switch (err) {
                error.OutOfMemory => return Error.OutOfMemory,
                error.PluginFuncResultType => .plugin_func_result_type,
                error.PluginFuncFailed => .plugin_func_failed,
                error.PluginFuncTrapped => .plugin_func_trapped,
                error.PluginFuncAllocFailed => .plugin_func_alloc_failed,
                else => null,
            };
            if (code) |c| {
                const failure = wasm_plugin_invoker.lastFailure();
                const message = try formatRuntimeFailureMessage(a, hdr.head, c, failure);
                try diags.append(a, .{
                    .phase = .validation,
                    .code = c,
                    .severity = .err,
                    .message = message,
                    .span = hdr.head_span,
                    .path = &.{},
                    .declaration_span = null,
                });
            }
            continue;
        };
        const cloned = try Expr.deepCopyValue(a, result.value);
        try eval_results.append(a, .{ .forest_index = forest_idx, .value = cloned });
        result.deinit();
    }
}

fn formatRuntimeFailureMessage(
    a: Allocator,
    head: []const u8,
    code: Ast.Diagnostic.Code,
    failure: *const wasm_plugin_invoker.LastFailure,
) Allocator.Error![]const u8 {
    const detail = failure.detail();
    const failure_code = failure.code();
    const prefix: []const u8 = switch (code) {
        .plugin_func_trapped => "plugin function trapped",
        .plugin_func_failed => "plugin function returned a structured failure",
        .plugin_func_result_type => "plugin function result type mismatch",
        .plugin_func_alloc_failed => "plugin function allocation failed",
        else => "plugin function failed",
    };
    if (detail.len > 0 and failure_code.len > 0) {
        return try std.fmt.allocPrint(
            a,
            "{s} in `({s} …)`: [{s}] {s}",
            .{ prefix, head, failure_code, detail },
        );
    }
    if (detail.len > 0) {
        return try std.fmt.allocPrint(
            a,
            "{s} in `({s} …)`: {s}",
            .{ prefix, head, detail },
        );
    }
    return try std.fmt.allocPrint(a, "{s} in `({s} …)`", .{ prefix, head });
}

fn freeAggregateDiagnostics(gpa: Allocator, diags: []const Ast.Diagnostic) void {
    for (diags) |d| {
        gpa.free(d.message);
        for (d.path) |p| gpa.free(p);
        gpa.free(d.path);
    }
    gpa.free(diags);
}

fn wrapForeignDiagnostic(
    a: Allocator,
    d: Ast.Diagnostic,
    reference: Resolver.Reference,
    ref_head_span: Ast.Span,
) Allocator.Error!HostDiagnostic {
    const path = try a.alloc([]const u8, d.path.len);
    for (d.path, 0..) |step, i| path[i] = try a.dupe(u8, step);
    const message = try std.fmt.allocPrint(
        a,
        "in resolved manifest for `(use-plugin \"{s}\" …)` (manifest offset {d}): {s}",
        .{ reference.name, d.span.start, d.message },
    );
    return .{
        .phase = .manifest,
        .code = d.code,
        .severity = d.severity,
        .message = message,
        .span = reference.span,
        .path = path,
        .declaration_span = ref_head_span,
    };
}

fn wrapProjectDiagnostic(
    a: Allocator,
    d: Ast.Diagnostic,
) Allocator.Error!HostDiagnostic {
    const path = try a.alloc([]const u8, d.path.len);
    for (d.path, 0..) |step, i| path[i] = try a.dupe(u8, step);
    return .{
        .phase = .manifest,
        .code = d.code,
        .severity = d.severity,
        .message = try a.dupe(u8, d.message),
        .span = .{ .start = 0, .end = 0 },
        .path = path,
        .declaration_span = null,
    };
}

fn loadResolvedManifest(
    gpa: Allocator,
    a: Allocator,
    bytes: []const u8,
    wasm_bytes: ?[]const u8,
    reference: Resolver.Reference,
    ref_head_span: Ast.Span,
    plugin_results: *std.ArrayList(ManifestLoader.Result),
    diags: *std.ArrayList(HostDiagnostic),
) Allocator.Error!void {
    const sentinel_buf = try a.allocSentinel(u8, bytes.len, 0);
    @memcpy(sentinel_buf, bytes);

    var manifest_tree = Parser.parse(gpa, sentinel_buf) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    defer manifest_tree.deinit();

    for (manifest_tree.diagnostics) |d| {
        try diags.append(a, try wrapForeignDiagnostic(a, d, reference, ref_head_span));
    }

    var loaded = ManifestLoader.load(gpa, manifest_tree) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        error.NotAPluginManifest => {
            try diags.append(a, .{
                .phase = .manifest,
                .code = .invalid_manifest,
                .severity = .err,
                .message = try std.fmt.allocPrint(
                    a,
                    "manifest for `(use-plugin \"{s}\" …)` is not a (plugin …) form",
                    .{reference.name},
                ),
                .span = reference.span,
                .path = &.{},
                .declaration_span = ref_head_span,
            });
            return;
        },
    };

    for (loaded.diagnostics) |d| {
        try diags.append(a, try wrapForeignDiagnostic(a, d, reference, ref_head_span));
    }

    if (loaded.hasErrors()) {
        loaded.deinit();
        return;
    }

    if (!std.mem.eql(u8, loaded.plugin.name, reference.name)) {
        const mismatch_message = std.fmt.allocPrint(
            a,
            "(use-plugin \"{s}\" …) resolved to a manifest whose :name is `{s}`",
            .{ reference.name, loaded.plugin.name },
        ) catch |err| {
            loaded.deinit();
            return err;
        };
        diags.append(a, .{
            .phase = .manifest,
            .code = .plugin_name_mismatch,
            .severity = .err,
            .message = mismatch_message,
            .span = reference.span,
            .path = &.{},
            .declaration_span = ref_head_span,
        }) catch |err| {
            loaded.deinit();
            return err;
        };
        loaded.deinit();
        return;
    }

    if (reference.version) |pinned_version| {
        if (!std.mem.eql(u8, loaded.plugin.version, pinned_version)) {
            const mismatch_message = std.fmt.allocPrint(
                a,
                "(use-plugin \"{s}\" :version \"{s}\") pin differs from manifest :version `{s}`",
                .{ reference.name, pinned_version, loaded.plugin.version },
            ) catch |err| {
                loaded.deinit();
                return err;
            };
            diags.append(a, .{
                .phase = .manifest,
                .code = .plugin_version_mismatch,
                .severity = .err,
                .message = mismatch_message,
                .span = reference.span,
                .path = &.{},
                .declaration_span = ref_head_span,
            }) catch |err| {
                loaded.deinit();
                return err;
            };
            loaded.deinit();
            return;
        }
    }

    if (loaded.plugin.wasm_sha256) |stamp| {
        if (wasm_bytes) |bytes_for_hash| {
            const expected_bytes = parseSha256HexPin(stamp);
            if (expected_bytes) |expected| {
                var actual_bytes: [Sha256.digest_length]u8 = undefined;
                Sha256.hash(bytes_for_hash, &actual_bytes, .{});
                if (!std.mem.eql(u8, &expected, &actual_bytes)) {
                    const actual_hex = std.fmt.bytesToHex(actual_bytes, .lower);
                    diags.append(a, .{
                        .phase = .manifest,
                        .code = .plugin_wasm_self_hash_mismatch,
                        .severity = .err,
                        .message = std.fmt.allocPrint(
                            a,
                            "manifest `:wasm-sha256 {s}` does not match wasm bytes (actual `sha256-{s}`)",
                            .{ stamp, actual_hex },
                        ) catch |err| {
                            loaded.deinit();
                            return err;
                        },
                        .span = reference.span,
                        .path = &.{},
                        .declaration_span = ref_head_span,
                    }) catch |err| {
                        loaded.deinit();
                        return err;
                    };
                    loaded.deinit();
                    return;
                }
            }
        }
    }

    plugin_results.append(a, loaded) catch |err| {
        loaded.deinit();
        return err;
    };
}

const Sha256 = std.crypto.hash.sha2.Sha256;
const HASH_PIN_PREFIX = "sha256-";
const HASH_HEX_LEN = Sha256.digest_length * 2;

fn enforceHashPin(
    a: Allocator,
    ref: Resolver.Reference,
    ref_head_span: Ast.Span,
    m: Resolver.ManifestResolution,
    diags: *std.ArrayList(HostDiagnostic),
) Allocator.Error!bool {
    const pin = ref.hash orelse return false;

    const expected_bytes = parseSha256HexPin(pin) orelse {
        try diags.append(a, .{
            .phase = .manifest,
            .code = .plugin_hash_mismatch,
            .severity = .err,
            .message = try std.fmt.allocPrint(
                a,
                "(use-plugin \"{s}\" :hash \"{s}\") pin is malformed; expected `sha256-<64 lowercase hex chars>`",
                .{ ref.name, pin },
            ),
            .span = ref.span,
            .path = &.{},
            .declaration_span = ref_head_span,
        });
        return true;
    };

    const wasm_bytes = m.wasm orelse {
        try diags.append(a, .{
            .phase = .manifest,
            .code = .plugin_hash_mismatch,
            .severity = .err,
            .message = try std.fmt.allocPrint(
                a,
                "(use-plugin \"{s}\" :hash \"{s}\") pin set but the resolved manifest has no wasm to hash",
                .{ ref.name, pin },
            ),
            .span = ref.span,
            .path = &.{},
            .declaration_span = ref_head_span,
        });
        return true;
    };

    var actual_bytes: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(wasm_bytes, &actual_bytes, .{});

    if (!std.mem.eql(u8, &expected_bytes, &actual_bytes)) {
        const actual_hex = std.fmt.bytesToHex(actual_bytes, .lower);
        try diags.append(a, .{
            .phase = .manifest,
            .code = .plugin_hash_mismatch,
            .severity = .err,
            .message = try std.fmt.allocPrint(
                a,
                "(use-plugin \"{s}\" :hash \"{s}\") pin does not match wasm bytes (actual `sha256-{s}`)",
                .{ ref.name, pin, actual_hex },
            ),
            .span = ref.span,
            .path = &.{},
            .declaration_span = ref_head_span,
        });
        return true;
    }

    return false;
}

fn parseSha256HexPin(pin: []const u8) ?[Sha256.digest_length]u8 {
    if (pin.len != HASH_PIN_PREFIX.len + HASH_HEX_LEN) return null;
    if (!std.mem.startsWith(u8, pin, HASH_PIN_PREFIX)) return null;
    const hex = pin[HASH_PIN_PREFIX.len..];
    for (hex) |c| {
        const is_lower_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!is_lower_hex) return null;
    }
    var bytes: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex) catch return null;
    return bytes;
}

fn preflightWasmIfPresent(
    a: Allocator,
    gpa: Allocator,
    plugin_results: *std.ArrayList(ManifestLoader.Result),
    diags: *std.ArrayList(HostDiagnostic),
    ref: Resolver.Reference,
    ref_head_span: Ast.Span,
    m: Resolver.ManifestResolution,
    runtime_storage: anytype,
    runtime_initialized: *bool,
) Error!bool {
    if (comptime !native_plugin_exec) return false;

    const bytes = m.wasm orelse return false;

    const loaded_idx = plugin_results.items.len - 1;
    const loaded_plugin = &plugin_results.items[loaded_idx].plugin;

    var declared: std.ArrayList([]const u8) = .empty;
    defer declared.deinit(a);
    for (loaded_plugin.expr_funcs) |func| {
        if (func.wasm_export_name) |name| try declared.append(a, name);
    }

    if (!runtime_initialized.*) {
        runtime_storage.* = try PluginRuntime.init(gpa);
        runtime_initialized.* = true;
    }

    runtime_storage.register(gpa, loaded_plugin.name, bytes, declared.items) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        error.Rejected => {
            const failure = runtime_storage.lastRegisterFailure();
            try diags.append(a, .{
                .phase = .manifest,
                .code = failure.code,
                .severity = .err,
                .message = try a.dupe(u8, failure.detail),
                .span = ref.span,
                .path = &.{},
                .declaration_span = ref_head_span,
            });
            var popped = plugin_results.pop().?;
            popped.deinit();
            return true;
        },
    };
    return false;
}

pub fn exportSchema(
    gpa: Allocator,
    schema: Schema.Schema,
    options: SchemaExport.ExportOptions,
) SchemaExport.Error!SchemaExport.ExportResult {
    return try SchemaExport.exportSchema(gpa, schema, options);
}

pub const ExportSchemaBundle = struct {
    host_result: HostResult,
    export_result: SchemaExport.ExportResult,

    pub fn deinit(self: *ExportSchemaBundle) void {
        self.export_result.deinit();
        self.host_result.deinit();
    }

    pub fn hasErrors(self: *const ExportSchemaBundle) bool {
        return self.host_result.hasErrors() or self.export_result.hasErrors();
    }
};

pub fn exportSchemaFromSource(
    gpa: Allocator,
    source: [:0]const u8,
    host_options: HostOptions,
    export_options: SchemaExport.ExportOptions,
) (Error || SchemaExport.Error)!ExportSchemaBundle {
    var host_result = try validateDocument(gpa, source, host_options);
    errdefer host_result.deinit();
    const export_result = try SchemaExport.exportSchema(gpa, host_result.schema, export_options);
    return .{ .host_result = host_result, .export_result = export_result };
}

pub const LoweringGraphBundle = struct {
    host_result: HostResult,
    sjon: []u8,
    gpa: Allocator,

    pub fn deinit(self: *LoweringGraphBundle) void {
        self.gpa.free(self.sjon);
        self.host_result.deinit();
    }

    pub fn hasErrors(self: *const LoweringGraphBundle) bool {
        return self.host_result.hasErrors();
    }
};

pub fn exportLoweringGraphFromSource(
    gpa: Allocator,
    source: [:0]const u8,
    host_options: HostOptions,
) (Error || LoweringGraph.Error)!LoweringGraphBundle {
    var host_result = try validateDocument(gpa, source, host_options);
    errdefer host_result.deinit();
    const sjon = try LoweringGraph.render(gpa, host_result.schema);
    return .{ .host_result = host_result, .sjon = sjon, .gpa = gpa };
}
