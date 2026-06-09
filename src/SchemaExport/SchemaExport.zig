const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Plugin = @import("../Plugin.zig");
const Schema = @import("../Schema.zig");

pub const Model = @import("Model.zig");
pub const Warnings = @import("Warnings.zig");
pub const JsonSchema = @import("JsonSchema.zig");
pub const TsTypes = @import("TsTypes.zig");
pub const Discriminators = @import("Discriminators.zig");

pub const Target = struct {
    json_schema: bool = true,
    ts_types: bool = true,
    intermediate: bool = false,
};

pub const Layout = enum { aggregated, per_plugin };

pub const JsonSchemaDraft = enum { @"2020-12" };

pub const ExportOptions = struct {
    target: Target = .{},
    layout: Layout = .aggregated,
    draft: JsonSchemaDraft = .@"2020-12",
    run_aggregate_validators: bool = false,
};

pub const ExportResult = struct {
    arena: ArenaAllocator,
    model: Model.Model,
    json_schema_bytes: ?[]const u8,
    ts_types_bytes: ?[]const u8,
    intermediate_bytes: ?[]const u8,
    warnings: []const Warnings.Warning,
    per_plugin: ?[]const Model.PerPluginArtifact = null,

    pub fn deinit(self: *ExportResult) void {
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const ExportResult) bool {
        return Warnings.anyError(self.warnings);
    }
};

pub const Error = error{OutOfMemory};

pub fn exportSchema(
    gpa: Allocator,
    schema: Schema.Schema,
    options: ExportOptions,
) Error!ExportResult {
    var arena = ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var warnings: std.ArrayList(Warnings.Warning) = .empty;

    if (options.run_aggregate_validators) {
        try collectAggregateWarnings(gpa, a, schema, &warnings);
    }

    const model = try lowerSchema(a, schema, &warnings);

    const deduped = try dedupeWarnings(a, warnings.items);

    var json_schema_bytes: ?[]const u8 = null;
    var ts_types_bytes: ?[]const u8 = null;
    var intermediate_bytes: ?[]const u8 = null;

    if (options.target.json_schema) {
        json_schema_bytes = try JsonSchema.emit(a, model, deduped);
    }
    if (options.target.ts_types) {
        ts_types_bytes = try TsTypes.emit(a, model, deduped);
    }
    if (options.target.intermediate) {
        intermediate_bytes = try emitIntermediate(a, model, deduped);
    }

    var per_plugin: ?[]const Model.PerPluginArtifact = null;
    if (options.layout == .per_plugin and model.plugins.len > 0) {
        per_plugin = try emitPerPlugin(a, model, deduped, options.target);
    }

    return .{
        .arena = arena,
        .model = model,
        .json_schema_bytes = json_schema_bytes,
        .ts_types_bytes = ts_types_bytes,
        .intermediate_bytes = intermediate_bytes,
        .warnings = deduped,
        .per_plugin = per_plugin,
    };
}

fn emitPerPlugin(
    a: Allocator,
    model: Model.Model,
    warnings: []const Warnings.Warning,
    target: Target,
) Error![]const Model.PerPluginArtifact {
    const out = try a.alloc(Model.PerPluginArtifact, model.plugins.len);
    for (model.plugins, 0..) |p, i| {
        const filtered = try filterWarningsForPlugin(a, warnings, p.name);
        out[i] = .{
            .plugin = p.name,
            .json_schema_bytes = if (target.json_schema)
                try JsonSchema.emitForPlugin(a, model, p, filtered)
            else
                null,
            .ts_types_bytes = if (target.ts_types)
                try TsTypes.emitForPlugin(a, model, p, filtered)
            else
                null,
            .intermediate_bytes = if (target.intermediate)
                try emitIntermediateForPlugin(a, model, p, filtered)
            else
                null,
        };
    }
    return out;
}

fn filterWarningsForPlugin(
    a: Allocator,
    warnings: []const Warnings.Warning,
    plugin_name: []const u8,
) Error![]const Warnings.Warning {
    var out: std.ArrayList(Warnings.Warning) = .empty;
    for (warnings) |w| {
        if (w.plugin_name == null or std.mem.eql(u8, w.plugin_name.?, plugin_name)) {
            try out.append(a, w);
        }
    }
    return out.toOwnedSlice(a);
}

fn emitIntermediateForPlugin(
    a: Allocator,
    model: Model.Model,
    p: Model.Plugin_,
    warnings: []const Warnings.Warning,
) Error![]const u8 {
    const single: Model.Model = .{
        .plugins = &[_]Model.Plugin_{p},
        .version = model.version,
    };
    return emitIntermediate(a, single, warnings);
}

fn dedupeWarnings(
    a: Allocator,
    input: []const Warnings.Warning,
) Error![]const Warnings.Warning {
    var out: std.ArrayList(Warnings.Warning) = .empty;
    outer: for (input) |w| {
        for (out.items) |existing| {
            if (existing.code != w.code) continue;
            if (!std.mem.eql(u8, existing.message, w.message)) continue;
            if (!optStrEql(existing.plugin_name, w.plugin_name)) continue;
            if (!optStrEql(existing.form_name, w.form_name)) continue;
            if (!optStrEql(existing.key_name, w.key_name)) continue;
            if (!optStrEql(existing.kind_name, w.kind_name)) continue;
            continue :outer;
        }
        try out.append(a, w);
    }
    return out.toOwnedSlice(a);
}

fn optStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn collectAggregateWarnings(
    gpa: Allocator,
    a: Allocator,
    schema: Schema.Schema,
    warnings: *std.ArrayList(Warnings.Warning),
) Error!void {
    const cross = try schema.validateCrossRefs(gpa);
    defer freeDiagnostics(gpa, cross);
    try foldDiagnostics(a, warnings, cross);

    const unions = try schema.validateUnions(gpa);
    defer freeDiagnostics(gpa, unions);
    try foldDiagnostics(a, warnings, unions);

    const forms = try schema.validateForms(gpa);
    defer freeDiagnostics(gpa, forms);
    try foldDiagnostics(a, warnings, forms);

    const lowering = try schema.validateLowering(gpa);
    defer freeDiagnostics(gpa, lowering);
    try foldDiagnostics(a, warnings, lowering);

    const defaults = try schema.validateDefaults(gpa);
    defer freeDiagnostics(gpa, defaults);
    try foldDiagnostics(a, warnings, defaults);
}

fn foldDiagnostics(
    a: Allocator,
    warnings: *std.ArrayList(Warnings.Warning),
    diags: []const @import("../Ast.zig").Diagnostic,
) Error!void {
    for (diags) |d| {
        try warnings.append(a, .{
            .code = .aggregate_phase_error,
            .severity = if (d.severity == .err) .err else .warn,
            .message = try a.dupe(u8, d.message),
            .plugin_name = if (d.path.len > 0) try a.dupe(u8, d.path[0]) else null,
            .form_name = if (d.path.len > 1) try a.dupe(u8, d.path[1]) else null,
            .key_name = if (d.path.len > 2) try a.dupe(u8, d.path[2]) else null,
        });
    }
}

fn freeDiagnostics(gpa: Allocator, diags: []const @import("../Ast.zig").Diagnostic) void {
    for (diags) |d| {
        gpa.free(d.message);
        for (d.path) |p| gpa.free(p);
        gpa.free(d.path);
    }
    gpa.free(diags);
}

fn lowerSchema(
    a: Allocator,
    schema: Schema.Schema,
    warnings: *std.ArrayList(Warnings.Warning),
) Error!Model.Model {
    const plugins_out = try a.alloc(Model.Plugin_, schema.plugins.len);
    for (schema.plugins, 0..) |p, i| {
        plugins_out[i] = try lowerPlugin(a, schema, p, warnings);
    }
    return .{ .plugins = plugins_out };
}

fn lowerPlugin(
    a: Allocator,
    schema: Schema.Schema,
    plugin: Plugin.Plugin,
    warnings: *std.ArrayList(Warnings.Warning),
) Error!Model.Plugin_ {
    const forms_out = try a.alloc(Model.Form, plugin.forms.len);
    for (plugin.forms, 0..) |f, i| {
        forms_out[i] = try lowerForm(a, schema, plugin, f, warnings);
    }

    const kinds_out = try a.alloc(Model.ValueKindEntry, plugin.value_kinds.len);
    for (plugin.value_kinds, 0..) |vk, i| {
        kinds_out[i] = .{
            .name = try a.dupe(u8, vk.name),
            .description = try a.dupe(u8, vk.description),
            .shape = try lowerValueKind(a, schema, plugin, vk, warnings),
            .origin_plugin = try a.dupe(u8, plugin.name),
        };
    }

    return .{
        .name = try a.dupe(u8, plugin.name),
        .version = try a.dupe(u8, plugin.version),
        .forms = forms_out,
        .value_kinds = kinds_out,
    };
}

fn lowerForm(
    a: Allocator,
    schema: Schema.Schema,
    plugin: Plugin.Plugin,
    form: Plugin.FormSpec,
    warnings: *std.ArrayList(Warnings.Warning),
) Error!Model.Form {
    const keys_out = try a.alloc(Model.Key, form.keys.len);
    for (form.keys, 0..) |k, i| {
        keys_out[i] = try lowerKey(a, schema, plugin, form, k, warnings);
    }

    const positional: Model.Positional = switch (form.positional) {
        .none => .none,
        .any => .any,
        .kind => |ref| blk: {
            const shape = try resolveNamedShape(a, schema, plugin, ref.name, ref.namespace, warnings, .{
                .plugin_name = plugin.name,
                .form_name = form.name,
            });
            break :blk .{ .kind = shape };
        },
        .flag_set => .any,
    };

    const positional_flags: ?[]const Model.PositionalFlag = switch (form.positional) {
        .flag_set => |fs| blk: {
            const out = try a.alloc(Model.PositionalFlag, fs.flags.len);
            for (fs.flags, 0..) |flag, i| out[i] = .{
                .name = try a.dupe(u8, flag.name),
                .description = try a.dupe(u8, flag.description),
                .link = if (flag.link) |l| try a.dupe(u8, l) else null,
            };
            break :blk out;
        },
        else => null,
    };

    var discriminator: ?Model.Discriminator = null;
    if (form.discriminant_idx) |idx| {
        if (idx < form.keys.len) {
            const variants = form.variants orelse &.{};
            const variants_out = try a.alloc(Model.Variant, variants.len);
            for (variants, 0..) |v, i| {
                const vk_keys = try a.alloc(Model.Key, v.keys.len);
                for (v.keys, 0..) |k, j| {
                    vk_keys[j] = try lowerKey(a, schema, plugin, form, k, warnings);
                }
                variants_out[i] = .{
                    .when = try a.dupe(u8, v.when),
                    .keys = vk_keys,
                };
            }
            discriminator = .{
                .key_name = try a.dupe(u8, form.keys[idx].name),
                .variants = variants_out,
            };
            try warnings.append(a, .{
                .code = .variants_emitted_via_if_then,
                .severity = .info,
                .message = try std.fmt.allocPrint(
                    a,
                    "discriminated form `{s}` — variants emitted as allOf+if/then; source-order (variant keys must follow the discriminant) is not enforced by JSON Schema",
                    .{form.name},
                ),
                .plugin_name = try a.dupe(u8, plugin.name),
                .form_name = try a.dupe(u8, form.name),
            });
        }
    }

    var exclusive: []const Model.ExclusiveGroup = &.{};
    if (form.exclusive_groups.len > 0) {
        const groups = try a.alloc(Model.ExclusiveGroup, form.exclusive_groups.len);
        var any_multi_key = false;
        for (form.exclusive_groups, 0..) |g, i| {
            const alts = try a.alloc([]const []const u8, g.alternatives.len);
            for (g.alternatives, 0..) |alt, j| {
                if (alt.keys.len > 1) any_multi_key = true;
                const keys = try a.alloc([]const u8, alt.keys.len);
                for (alt.keys, 0..) |kn, k| keys[k] = try a.dupe(u8, kn);
                alts[j] = keys;
            }
            groups[i] = .{ .cardinality = g.cardinality, .alternatives = alts };
        }
        exclusive = groups;
        try warnings.append(a, .{
            .code = .exclusive_group_unenforceable,
            .severity = .info,
            .message = try std.fmt.allocPrint(
                a,
                "form `{s}` exclusive groups emitted structurally (`oneOf` for exactly_one, `not:{{allOf}}` for at_most_one); source-order constraints between variant keys and discriminants remain SJON-only",
                .{form.name},
            ),
            .plugin_name = try a.dupe(u8, plugin.name),
            .form_name = try a.dupe(u8, form.name),
        });
        if (any_multi_key) {
            try warnings.append(a, .{
                .code = .multi_key_exclusive_emitted,
                .severity = .info,
                .message = try std.fmt.allocPrint(
                    a,
                    "form `{s}` has at least one multi-key bundle in an exclusive group; emitted as `{{required: [<bundle>]}}` per bundle. Bundle atomicity (partial bundles fail) requires SJON-aware runtime validation",
                    .{form.name},
                ),
                .plugin_name = try a.dupe(u8, plugin.name),
                .form_name = try a.dupe(u8, form.name),
            });
        }
    }

    var lowering_out: ?Model.Lowering = null;
    if (form.lowering) |low| {
        const produces = try a.alloc([]const u8, low.produces.len);
        for (low.produces, 0..) |p, i| produces[i] = try a.dupe(u8, p);
        lowering_out = .{
            .hook = try a.dupe(u8, low.hook),
            .produces = produces,
        };
    }

    return .{
        .name = try a.dupe(u8, form.name),
        .description = try a.dupe(u8, form.description),
        .keys = keys_out,
        .positional = positional,
        .open = form.open,
        .discriminator = discriminator,
        .exclusive_groups = exclusive,
        .lowering = lowering_out,
        .positional_flags = positional_flags,
    };
}

fn lowerKey(
    a: Allocator,
    schema: Schema.Schema,
    plugin: Plugin.Plugin,
    form: Plugin.FormSpec,
    key: Plugin.KeySpec,
    warnings: *std.ArrayList(Warnings.Warning),
) Error!Model.Key {
    var shape = try lowerValueType(a, schema, plugin, key.value_type, warnings, .{
        .plugin_name = plugin.name,
        .form_name = form.name,
        .key_name = key.name,
    });

    if (key.local_forms.len > 0) {
        const locals = try a.alloc(Model.Form, key.local_forms.len);
        for (key.local_forms, 0..) |lf, i| {
            locals[i] = try lowerForm(a, schema, plugin, lf, warnings);
        }
        shape = .{ .form_locals = locals };
        try warnings.append(a, .{
            .code = .local_forms_emitted_inline,
            .severity = .info,
            .message = try std.fmt.allocPrint(
                a,
                "slot `:{s}` on form `{s}` declares {d} local form(s) — emitted as an inline union plus an open generic branch for the additive global fallback; local-first/global resolution order is SJON-only",
                .{ key.name, form.name, key.local_forms.len },
            ),
            .plugin_name = try a.dupe(u8, plugin.name),
            .form_name = try a.dupe(u8, form.name),
            .key_name = try a.dupe(u8, key.name),
        });
    }

    var default_out: ?Model.Default = null;
    if (key.default) |d| {
        default_out = try lowerDefault(a, plugin, form, key, d, warnings);
    }

    return .{
        .name = try a.dupe(u8, key.name),
        .optional = key.effectiveOptional(),
        .description = try a.dupe(u8, key.description),
        .value = shape,
        .default = default_out,
    };
}

const Context = struct {
    plugin_name: []const u8,
    form_name: ?[]const u8 = null,
    key_name: ?[]const u8 = null,
    kind_name: ?[]const u8 = null,
};

fn lowerValueType(
    a: Allocator,
    schema: Schema.Schema,
    plugin: Plugin.Plugin,
    vt: Plugin.ValueType,
    warnings: *std.ArrayList(Warnings.Warning),
    ctx: Context,
) Error!Model.ValueShape {
    return switch (vt) {
        .any => .any,
        .number => .number,
        .string => .string,
        .symbol => .symbol,
        .boolean => .boolean,
        .nil => .nil,
        .vector => .{ .vector = .{
            .len = null,
            .element = try valueShapePtr(a, .any),
        } },
        .form => .form_any,
        .expr => blk: {
            try warnings.append(a, .{
                .code = .expression_slot_annotation_only,
                .severity = .info,
                .message = try std.fmt.allocPrint(
                    a,
                    "slot declared as `expr` — schema validates `$expr` envelope only",
                    .{},
                ),
                .plugin_name = try a.dupe(u8, ctx.plugin_name),
                .form_name = if (ctx.form_name) |n| try a.dupe(u8, n) else null,
                .key_name = if (ctx.key_name) |n| try a.dupe(u8, n) else null,
            });
            break :blk .expr;
        },
        .named => |ref| try resolveNamedShape(a, schema, plugin, ref.name, ref.namespace, warnings, ctx),
    };
}

fn resolveNamedShape(
    a: Allocator,
    schema: Schema.Schema,
    plugin: Plugin.Plugin,
    name: []const u8,
    namespace: ?[]const u8,
    warnings: *std.ArrayList(Warnings.Warning),
    ctx: Context,
) Error!Model.ValueShape {
    if (primitiveShortcut(name)) |shape| return shape;
    return switch (schema.lookupValueKind(name, namespace)) {
        .found => |kind| try lowerValueKind(a, schema, plugin, kind.*, warnings),
        .not_found, .ambiguous => blk: {
            const display = try formatQualified(a, name, namespace);
            try warnings.append(a, .{
                .code = .aggregate_phase_error,
                .severity = .err,
                .message = try std.fmt.allocPrint(
                    a,
                    "value-type reference `{s}` does not resolve to any value-kind",
                    .{display},
                ),
                .plugin_name = try a.dupe(u8, ctx.plugin_name),
                .form_name = if (ctx.form_name) |n| try a.dupe(u8, n) else null,
                .key_name = if (ctx.key_name) |n| try a.dupe(u8, n) else null,
                .kind_name = try a.dupe(u8, display),
            });
            break :blk .{ .unresolved_named = .{
                .name = try a.dupe(u8, name),
                .namespace = if (namespace) |ns| try a.dupe(u8, ns) else null,
            } };
        },
    };
}

fn formatQualified(a: Allocator, name: []const u8, namespace: ?[]const u8) Error![]const u8 {
    if (namespace) |ns| {
        return try std.fmt.allocPrint(a, "{s}/{s}", .{ ns, name });
    }
    return try a.dupe(u8, name);
}

fn primitiveShortcut(name: []const u8) ?Model.ValueShape {
    if (std.mem.eql(u8, name, "any")) return .any;
    if (std.mem.eql(u8, name, "number")) return .number;
    if (std.mem.eql(u8, name, "string")) return .string;
    if (std.mem.eql(u8, name, "symbol")) return .symbol;
    if (std.mem.eql(u8, name, "boolean")) return .boolean;
    if (std.mem.eql(u8, name, "nil")) return .nil;
    if (std.mem.eql(u8, name, "form")) return .form_any;
    if (std.mem.eql(u8, name, "expr")) return .expr;
    if (std.mem.eql(u8, name, "vector")) return null;
    return null;
}

fn lowerValueKind(
    a: Allocator,
    schema: Schema.Schema,
    plugin: Plugin.Plugin,
    vk: Plugin.ValueKind,
    warnings: *std.ArrayList(Warnings.Warning),
) Error!Model.ValueShape {
    const ctx: Context = .{
        .plugin_name = plugin.name,
        .kind_name = vk.name,
    };
    if (vk.cross_ref) |cr| {
        try warnings.append(a, .{
            .code = .cross_ref_unenforceable,
            .severity = .warn,
            .message = try std.fmt.allocPrint(
                a,
                "value-kind `{s}` cross-ref: schema validates symbol shape only; closed-set membership requires SJON-aware validator",
                .{vk.name},
            ),
            .plugin_name = try a.dupe(u8, plugin.name),
            .kind_name = try a.dupe(u8, vk.name),
        });
        try warnings.append(a, .{
            .code = .cross_ref_annotation_only,
            .severity = .info,
            .message = try std.fmt.allocPrint(
                a,
                "value-kind `{s}` cross-ref annotation surfaces target-form=`{s}` name-key=`{s}` acyclic={s} scope-form=`{s}`; none are enforceable by JSON Schema",
                .{
                    vk.name,
                    cr.target_form,
                    cr.name_key,
                    if (cr.acyclic) "true" else "false",
                    if (cr.scope_form) |sf| sf else "",
                },
            ),
            .plugin_name = try a.dupe(u8, plugin.name),
            .kind_name = try a.dupe(u8, vk.name),
        });
        if (cr.acyclic) {
            try warnings.append(a, .{
                .code = .acyclic_unenforceable,
                .severity = .warn,
                .message = try std.fmt.allocPrint(
                    a,
                    "value-kind `{s}` declares `:acyclic true`; cycle detection cannot be enforced by JSON Schema",
                    .{vk.name},
                ),
                .plugin_name = try a.dupe(u8, plugin.name),
                .kind_name = try a.dupe(u8, vk.name),
            });
        }
        return .{ .cross_ref = .{
            .target_form = try a.dupe(u8, cr.target_form),
            .name_key = try a.dupe(u8, cr.name_key),
            .acyclic = cr.acyclic,
            .scope_form = if (cr.scope_form) |sf| try a.dupe(u8, sf) else null,
        } };
    }
    if (vk.union_of) |us| {
        try warnings.append(a, .{
            .code = .union_emitted_via_anyof,
            .severity = .info,
            .message = try std.fmt.allocPrint(
                a,
                "value-kind `{s}` union_of emitted as JSON Schema `anyOf` over resolved alternatives; SJON's first-match dispatch order is preserved in `x-sjon-union-alternatives`",
                .{vk.name},
            ),
            .plugin_name = try a.dupe(u8, plugin.name),
            .kind_name = try a.dupe(u8, vk.name),
        });
        const alts = try a.alloc(Model.UnionAlternative, us.alternatives.len);
        for (us.alternatives, 0..) |alt, i| {
            alts[i] = .{
                .name = try a.dupe(u8, alt.name),
                .shape = try resolveNamedShape(a, schema, plugin, alt.name, alt.namespace, warnings, ctx),
            };
        }
        return .{ .union_of = alts };
    }

    return switch (vk.underlying) {
        .number => lowerNumberKind(a, plugin, vk, warnings),
        .string => lowerStringKind(a, plugin, vk, warnings),
        .symbol => lowerSymbolKind(a, plugin, vk, warnings),
        .form => lowerFormKind(a, schema, plugin, vk, warnings),
        .vector => try lowerVectorKind(a, schema, plugin, vk, warnings),
        .union_of => unreachable,
    };
}

fn lowerNumberKind(
    a: Allocator,
    plugin: Plugin.Plugin,
    vk: Plugin.ValueKind,
    warnings: *std.ArrayList(Warnings.Warning),
) Error!Model.ValueShape {
    const bounds: ?Model.NumericBounds = if (vk.numeric == null and vk.repr == null)
        null
    else blk: {
        var b: Model.NumericBounds = if (vk.numeric) |nb|
            try copyNumericBounds(a, nb)
        else
            .{};
        b.repr = vk.repr;
        break :blk b;
    };

    if (vk.unit) |u| if (!u.reject) {
        try warnings.append(a, .{
            .code = .number_with_unit_emitted_via_prefix_items,
            .severity = .info,
            .message = try std.fmt.allocPrint(
                a,
                "value-kind `{s}` emitted as JSON Schema object with `$num` prefixItems [magnitude, unit] (required={s}, allowed-units={d}); SJON-aware tooling reads the canonical form via the JSON bridge",
                .{ vk.name, if (u.required) "true" else "false", u.allowed.len },
            ),
            .plugin_name = try a.dupe(u8, plugin.name),
            .kind_name = try a.dupe(u8, vk.name),
        });
        const allowed = try a.alloc([]const u8, u.allowed.len);
        for (u.allowed, 0..) |s, i| allowed[i] = try a.dupe(u8, s);
        if (bounds) |b| try maybeWarnExactIntOverflow(a, plugin, vk, b, warnings);
        return .{ .number_with_unit = .{
            .required = u.required,
            .allowed = allowed,
            .bounds = bounds,
        } };
    };

    if (bounds) |b| {
        if (vk.numeric != null) {
            try warnings.append(a, .{
                .code = .numeric_bounds_emitted_via_min_max,
                .severity = .info,
                .message = try std.fmt.allocPrint(
                    a,
                    "value-kind `{s}` numeric bounds emitted via `minimum`/`maximum`/`exclusiveMinimum`/`exclusiveMaximum` (integer={s}); SJON-aware tooling additionally reads `x-sjon-exact-bound` for >2^53 values",
                    .{ vk.name, if (b.integer) "true" else "false" },
                ),
                .plugin_name = try a.dupe(u8, plugin.name),
                .kind_name = try a.dupe(u8, vk.name),
            });
        }
        try maybeWarnExactIntOverflow(a, plugin, vk, b, warnings);
        return .{ .number_bounded = b };
    }
    return .number;
}

fn copyNumericBounds(a: Allocator, nb: Plugin.ValueKind.NumericBounds) Error!Model.NumericBounds {
    return .{
        .min = if (nb.min) |b| try copyBound(a, b) else null,
        .max = if (nb.max) |b| try copyBound(a, b) else null,
        .exclusive_min = nb.exclusive_min,
        .exclusive_max = nb.exclusive_max,
        .integer = nb.integer,
    };
}

fn copyBound(a: Allocator, b: Plugin.ValueKind.NumericBounds.Bound) Error!Model.NumericBounds.Bound {
    return .{
        .value = b.value,
        .unit = if (b.unit) |u| try a.dupe(u8, u) else null,
        .exact_int = b.exact_int,
    };
}

const F64_PRECISE_INT_CEILING: f64 = 9007199254740992.0;

fn maybeWarnExactIntOverflow(
    a: Allocator,
    plugin: Plugin.Plugin,
    vk: Plugin.ValueKind,
    bounds: Model.NumericBounds,
    warnings: *std.ArrayList(Warnings.Warning),
) Error!void {
    if (bounds.min) |b| {
        if (b.exact_int and @abs(b.value) > F64_PRECISE_INT_CEILING) {
            try warnings.append(a, .{
                .code = .numeric_bound_exceeds_double_range,
                .severity = .info,
                .message = try std.fmt.allocPrint(
                    a,
                    "value-kind `{s}` min bound {d} exceeds 2^53; non-bigint JSON Schema validators may lose precision — see `x-sjon-exact-bound.min`",
                    .{ vk.name, b.value },
                ),
                .plugin_name = try a.dupe(u8, plugin.name),
                .kind_name = try a.dupe(u8, vk.name),
            });
        }
    }
    if (bounds.max) |b| {
        if (b.exact_int and @abs(b.value) > F64_PRECISE_INT_CEILING) {
            try warnings.append(a, .{
                .code = .numeric_bound_exceeds_double_range,
                .severity = .info,
                .message = try std.fmt.allocPrint(
                    a,
                    "value-kind `{s}` max bound {d} exceeds 2^53; non-bigint JSON Schema validators may lose precision — see `x-sjon-exact-bound.max`",
                    .{ vk.name, b.value },
                ),
                .plugin_name = try a.dupe(u8, plugin.name),
                .kind_name = try a.dupe(u8, vk.name),
            });
        }
    }
}

fn lowerStringKind(
    a: Allocator,
    plugin: Plugin.Plugin,
    vk: Plugin.ValueKind,
    warnings: *std.ArrayList(Warnings.Warning),
) Error!Model.ValueShape {
    if (vk.members) |ms| {
        return try emitMemberSet(a, plugin, vk, ms, warnings, .string_underlying);
    }
    if (vk.string_bounds) |sb| {
        try warnings.append(a, .{
            .code = .string_bounds_emitted_via_keywords,
            .severity = .info,
            .message = try std.fmt.allocPrint(
                a,
                "value-kind `{s}` string bounds emitted via `minLength`/`maxLength`/`pattern`/`format`; codepoint-vs-UTF16 length and SJON-deferred regex semantics carry their own caveats",
                .{vk.name},
            ),
            .plugin_name = try a.dupe(u8, plugin.name),
            .kind_name = try a.dupe(u8, vk.name),
        });
        return .{ .string_with_bounds = .{
            .min_len = sb.min_len,
            .max_len = sb.max_len,
            .pattern = if (sb.pattern) |p| try a.dupe(u8, p) else null,
            .format = sb.format,
        } };
    }
    return .string;
}

fn lowerSymbolKind(
    a: Allocator,
    plugin: Plugin.Plugin,
    vk: Plugin.ValueKind,
    warnings: *std.ArrayList(Warnings.Warning),
) Error!Model.ValueShape {
    if (vk.members) |ms| {
        return try emitMemberSet(a, plugin, vk, ms, warnings, .symbol_underlying);
    }
    return .symbol;
}

fn lowerFormKind(
    a: Allocator,
    schema: Schema.Schema,
    plugin: Plugin.Plugin,
    vk: Plugin.ValueKind,
    warnings: *std.ArrayList(Warnings.Warning),
) Error!Model.ValueShape {
    if (vk.heads) |hs| {
        try warnings.append(a, .{
            .code = .head_set_emitted_via_oneof_refs,
            .severity = .info,
            .message = try std.fmt.allocPrint(
                a,
                "value-kind `{s}` head-set emitted as `oneOf` of `$ref`s into `#/$defs/form.<plugin>.<head>`",
                .{vk.name},
            ),
            .plugin_name = try a.dupe(u8, plugin.name),
            .kind_name = try a.dupe(u8, vk.name),
        });
        const refs = try a.alloc(Model.FormRef, hs.names.len);
        for (hs.names, 0..) |n, i| {
            const owner = switch (schema.lookupForm(n, null)) {
                .found => |hit| hit.plugin.name,
                .not_found, .ambiguous => blk: {
                    try warnings.append(a, .{
                        .code = .aggregate_phase_error,
                        .severity = .err,
                        .message = try std.fmt.allocPrint(
                            a,
                            "head-set member `{s}` on value-kind `{s}` does not resolve to a unique form",
                            .{ n, vk.name },
                        ),
                        .plugin_name = try a.dupe(u8, plugin.name),
                        .kind_name = try a.dupe(u8, vk.name),
                    });
                    break :blk "";
                },
            };
            refs[i] = .{
                .plugin = try a.dupe(u8, owner),
                .name = try a.dupe(u8, n),
            };
        }
        return .{ .form_heads = refs };
    }
    return .form_any;
}

fn lowerVectorKind(
    a: Allocator,
    schema: Schema.Schema,
    plugin: Plugin.Plugin,
    vk: Plugin.ValueKind,
    warnings: *std.ArrayList(Warnings.Warning),
) Error!Model.ValueShape {
    const vs = vk.vector orelse return .{ .vector = .{
        .len = null,
        .element = try valueShapePtr(a, .any),
    } };
    const elem_shape = try resolveNamedShape(a, schema, plugin, vs.element.name, vs.element.namespace, warnings, .{
        .plugin_name = plugin.name,
        .kind_name = vk.name,
    });
    const elem_ptr = try a.create(Model.ValueShape);
    elem_ptr.* = elem_shape;
    return .{ .vector = .{
        .len = vs.len,
        .min_len = vs.min_len,
        .max_len = vs.max_len,
        .element = elem_ptr,
    } };
}

const UnderlyingKind = enum { symbol_underlying, string_underlying };

fn emitMemberSet(
    a: Allocator,
    plugin: Plugin.Plugin,
    vk: Plugin.ValueKind,
    ms: Plugin.ValueKind.MemberSet,
    warnings: *std.ArrayList(Warnings.Warning),
    underlying: UnderlyingKind,
) Error!Model.ValueShape {
    var any_rich = false;
    for (ms.members) |m| {
        if (m.label.len > 0 or m.description.len > 0 or m.deprecated or m.deprecation_message.len > 0) {
            any_rich = true;
            break;
        }
    }
    if (any_rich) {
        try warnings.append(a, .{
            .code = .rich_members_emitted_with_annotations,
            .severity = .info,
            .message = try std.fmt.allocPrint(
                a,
                "value-kind `{s}` member-set carries rich metadata — emitted as per-member `oneOf` with title/description/deprecated annotations",
                .{vk.name},
            ),
            .plugin_name = try a.dupe(u8, plugin.name),
            .kind_name = try a.dupe(u8, vk.name),
        });
        const members = try a.alloc(Model.Member, ms.members.len);
        for (ms.members, 0..) |m, i| {
            members[i] = .{
                .name = try a.dupe(u8, m.name),
                .label = try a.dupe(u8, m.label),
                .description = try a.dupe(u8, m.description),
                .deprecated = m.deprecated,
                .deprecation_message = try a.dupe(u8, m.deprecation_message),
            };
        }
        return switch (underlying) {
            .symbol_underlying => .{ .symbol_members_rich = members },
            .string_underlying => .{ .string_members_rich = members },
        };
    }
    const names = try a.alloc([]const u8, ms.members.len);
    for (ms.members, 0..) |m, i| names[i] = try a.dupe(u8, m.name);
    return switch (underlying) {
        .symbol_underlying => .{ .symbol_members = names },
        .string_underlying => .{ .string_members = names },
    };
}

fn valueShapePtr(a: Allocator, shape: Model.ValueShape) Error!*const Model.ValueShape {
    const p = try a.create(Model.ValueShape);
    p.* = shape;
    return p;
}

fn lowerDefault(
    a: Allocator,
    plugin: Plugin.Plugin,
    form: Plugin.FormSpec,
    key: Plugin.KeySpec,
    d: Plugin.KeySpec.Default,
    warnings: *std.ArrayList(Warnings.Warning),
) Error!Model.Default {
    return switch (d) {
        .nil => .nil,
        .boolean => |v| .{ .boolean = v },
        .number => |v| .{ .number = v },
        .string => |v| .{ .string = try a.dupe(u8, v) },
        .symbol => |v| .{ .symbol = try a.dupe(u8, v) },
        .vector => |vs| blk: {
            const out = try a.alloc(Model.Default, vs.len);
            for (vs, 0..) |child, i| {
                out[i] = try lowerDefault(a, plugin, form, key, child, warnings);
            }
            break :blk .{ .vector = out };
        },
        .expression => |e| blk: {
            try warnings.append(a, .{
                .code = .expression_default_annotation_only,
                .severity = .info,
                .message = try std.fmt.allocPrint(
                    a,
                    "default for `:{s}` on form `{s}` is an expression (`{s}`); schema annotates head + arg-count only",
                    .{ key.name, form.name, e.head },
                ),
                .plugin_name = try a.dupe(u8, plugin.name),
                .form_name = try a.dupe(u8, form.name),
                .key_name = try a.dupe(u8, key.name),
            });
            break :blk .{ .expression = .{
                .head = try a.dupe(u8, e.head),
                .namespace = if (e.namespace) |ns| try a.dupe(u8, ns) else null,
                .arg_count = e.arg_count,
            } };
        },
    };
}

fn emitIntermediate(
    a: Allocator,
    model: Model.Model,
    warnings: []const Warnings.Warning,
) Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    var w: std.json.Stringify = .{
        .writer = &aw.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    writeIntermediateBody(&w, model, warnings) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    aw.writer.writeByte('\n') catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeIntermediateBody(
    w: *std.json.Stringify,
    model: Model.Model,
    warnings: []const Warnings.Warning,
) std.Io.Writer.Error!void {
    try w.beginObject();
    try w.objectField("version");
    try w.write(model.version);
    try w.objectField("plugins");
    try w.beginArray();
    for (model.plugins) |p| try writePluginJson(w, p);
    try w.endArray();
    try w.objectField("warnings");
    try w.beginArray();
    for (warnings) |wn| try writeWarningJson(w, wn);
    try w.endArray();
    try w.endObject();
}

fn writePluginJson(w: *std.json.Stringify, p: Model.Plugin_) std.Io.Writer.Error!void {
    try w.beginObject();
    try w.objectField("name");
    try w.write(p.name);
    try w.objectField("version");
    try w.write(p.version);
    try w.objectField("forms");
    try w.beginArray();
    for (p.forms) |f| try writeFormJson(w, f);
    try w.endArray();
    try w.objectField("value_kinds");
    try w.beginArray();
    for (p.value_kinds) |vk| try writeKindEntryJson(w, vk);
    try w.endArray();
    try w.endObject();
}

fn writeFormJson(w: *std.json.Stringify, f: Model.Form) std.Io.Writer.Error!void {
    try w.beginObject();
    try w.objectField("name");
    try w.write(f.name);
    try w.objectField("description");
    try w.write(f.description);
    try w.objectField("open");
    try w.write(f.open);
    try w.objectField("positional");
    try writePositionalJson(w, f.positional);
    try w.objectField("keys");
    try w.beginArray();
    for (f.keys) |k| try writeKeyJson(w, k);
    try w.endArray();
    try w.endObject();
}

fn writePositionalJson(w: *std.json.Stringify, p: Model.Positional) std.Io.Writer.Error!void {
    switch (p) {
        .none => try w.write("none"),
        .any => try w.write("any"),
        .kind => |shape| {
            try w.beginObject();
            try w.objectField("kind");
            try writeShapeJson(w, shape);
            try w.endObject();
        },
    }
}

fn writeKeyJson(w: *std.json.Stringify, k: Model.Key) std.Io.Writer.Error!void {
    try w.beginObject();
    try w.objectField("name");
    try w.write(k.name);
    try w.objectField("optional");
    try w.write(k.optional);
    try w.objectField("description");
    try w.write(k.description);
    try w.objectField("value");
    try writeShapeJson(w, k.value);
    if (k.default) |d| {
        try w.objectField("default");
        try writeDefaultJson(w, d);
    }
    try w.endObject();
}

fn writeKindEntryJson(w: *std.json.Stringify, vk: Model.ValueKindEntry) std.Io.Writer.Error!void {
    try w.beginObject();
    try w.objectField("name");
    try w.write(vk.name);
    try w.objectField("description");
    try w.write(vk.description);
    try w.objectField("shape");
    try writeShapeJson(w, vk.shape);
    try w.endObject();
}

fn writeShapeJson(w: *std.json.Stringify, shape: Model.ValueShape) std.Io.Writer.Error!void {
    switch (shape) {
        .any => try writeTagOnly(w, "any"),
        .nil => try writeTagOnly(w, "nil"),
        .boolean => try writeTagOnly(w, "boolean"),
        .number => try writeTagOnly(w, "number"),
        .number_i64 => try writeTagOnly(w, "number_i64"),
        .number_u64 => try writeTagOnly(w, "number_u64"),
        .string => try writeTagOnly(w, "string"),
        .symbol => try writeTagOnly(w, "symbol"),
        .date => try writeTagOnly(w, "date"),
        .time => try writeTagOnly(w, "time"),
        .keyword => try writeTagOnly(w, "keyword"),
        .form_any => try writeTagOnly(w, "form"),
        .expr => try writeTagOnly(w, "expr"),
        .symbol_members => |names| try writeMembersJson(w, "symbol_members", names),
        .string_members => |names| try writeMembersJson(w, "string_members", names),
        .symbol_members_rich => |members| try writeRichMembersJson(w, "symbol_members_rich", members),
        .string_members_rich => |members| try writeRichMembersJson(w, "string_members_rich", members),
        .form_heads => |refs| {
            try w.beginObject();
            try w.objectField("kind");
            try w.write("form_heads");
            try w.objectField("refs");
            try w.beginArray();
            for (refs) |r| {
                try w.beginObject();
                try w.objectField("plugin");
                try w.write(r.plugin);
                try w.objectField("name");
                try w.write(r.name);
                try w.endObject();
            }
            try w.endArray();
            try w.endObject();
        },
        .form_locals => |forms| {
            try w.beginObject();
            try w.objectField("kind");
            try w.write("form_locals");
            try w.objectField("forms");
            try w.beginArray();
            for (forms) |f| try writeFormJson(w, f);
            try w.endArray();
            try w.endObject();
        },
        .vector => |vs| {
            try w.beginObject();
            try w.objectField("kind");
            try w.write("vector");
            try w.objectField("len");
            if (vs.len) |n| try w.write(n) else try w.write(null);
            try w.objectField("element");
            try writeShapeJson(w, vs.element.*);
            try w.endObject();
        },
        .number_with_unit => |u| {
            try w.beginObject();
            try w.objectField("kind");
            try w.write("number_with_unit");
            try w.objectField("required");
            try w.write(u.required);
            try w.objectField("allowed");
            try w.beginArray();
            for (u.allowed) |s| try w.write(s);
            try w.endArray();
            if (u.bounds) |b| {
                try w.objectField("bounds");
                try writeBoundsJson(w, b);
            }
            try w.endObject();
        },
        .number_bounded => |b| {
            try w.beginObject();
            try w.objectField("kind");
            try w.write("number_bounded");
            try w.objectField("bounds");
            try writeBoundsJson(w, b);
            try w.endObject();
        },
        .string_with_bounds => |sb| {
            try w.beginObject();
            try w.objectField("kind");
            try w.write("string_with_bounds");
            try w.objectField("min_len");
            if (sb.min_len) |n| try w.write(n) else try w.write(null);
            try w.objectField("max_len");
            if (sb.max_len) |n| try w.write(n) else try w.write(null);
            try w.objectField("pattern");
            if (sb.pattern) |p| try w.write(p) else try w.write(null);
            try w.objectField("format");
            if (sb.format) |f| try w.write(@tagName(f)) else try w.write(null);
            try w.endObject();
        },
        .cross_ref => |cr| {
            try w.beginObject();
            try w.objectField("kind");
            try w.write("cross_ref");
            try w.objectField("target_form");
            try w.write(cr.target_form);
            try w.objectField("name_key");
            try w.write(cr.name_key);
            try w.objectField("acyclic");
            try w.write(cr.acyclic);
            try w.objectField("scope_form");
            if (cr.scope_form) |sf| try w.write(sf) else try w.write(null);
            try w.endObject();
        },
        .union_of => |alts| {
            try w.beginObject();
            try w.objectField("kind");
            try w.write("union_of");
            try w.objectField("alternatives");
            try w.beginArray();
            for (alts) |alt| {
                try w.beginObject();
                try w.objectField("name");
                try w.write(alt.name);
                try w.objectField("shape");
                try writeShapeJson(w, alt.shape);
                try w.endObject();
            }
            try w.endArray();
            try w.endObject();
        },
        .unresolved_named => |u| {
            try w.beginObject();
            try w.objectField("kind");
            try w.write("unresolved_named");
            try w.objectField("name");
            try w.write(u.name);
            if (u.namespace) |ns| {
                try w.objectField("namespace");
                try w.write(ns);
            }
            try w.endObject();
        },
    }
}

fn writeTagOnly(w: *std.json.Stringify, name: []const u8) std.Io.Writer.Error!void {
    try w.beginObject();
    try w.objectField("kind");
    try w.write(name);
    try w.endObject();
}

fn writeMembersJson(w: *std.json.Stringify, tag: []const u8, names: []const []const u8) std.Io.Writer.Error!void {
    try w.beginObject();
    try w.objectField("kind");
    try w.write(tag);
    try w.objectField("names");
    try w.beginArray();
    for (names) |n| try w.write(n);
    try w.endArray();
    try w.endObject();
}

fn writeRichMembersJson(w: *std.json.Stringify, tag: []const u8, members: []const Model.Member) std.Io.Writer.Error!void {
    try w.beginObject();
    try w.objectField("kind");
    try w.write(tag);
    try w.objectField("members");
    try w.beginArray();
    for (members) |m| {
        try w.beginObject();
        try w.objectField("name");
        try w.write(m.name);
        if (m.label.len > 0) {
            try w.objectField("label");
            try w.write(m.label);
        }
        if (m.description.len > 0) {
            try w.objectField("description");
            try w.write(m.description);
        }
        if (m.deprecated) {
            try w.objectField("deprecated");
            try w.write(m.deprecated);
        }
        if (m.deprecation_message.len > 0) {
            try w.objectField("deprecation_message");
            try w.write(m.deprecation_message);
        }
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();
}

fn writeDefaultJson(w: *std.json.Stringify, d: Model.Default) std.Io.Writer.Error!void {
    switch (d) {
        .nil => try w.write(null),
        .boolean => |b| try w.write(b),
        .number => |n| try w.write(n),
        .string => |s| try w.write(s),
        .symbol => |s| {
            try w.beginObject();
            try w.objectField("$sym");
            try w.write(s);
            try w.endObject();
        },
        .vector => |vs| {
            try w.beginArray();
            for (vs) |child| try writeDefaultJson(w, child);
            try w.endArray();
        },
        .expression => |e| {
            try w.beginObject();
            try w.objectField("$expr_snapshot");
            try w.beginObject();
            try w.objectField("head");
            try w.write(e.head);
            try w.objectField("namespace");
            if (e.namespace) |ns| try w.write(ns) else try w.write(null);
            try w.objectField("arg_count");
            try w.write(e.arg_count);
            try w.endObject();
            try w.endObject();
        },
    }
}

fn writeBoundsJson(w: *std.json.Stringify, b: Model.NumericBounds) std.Io.Writer.Error!void {
    try w.beginObject();
    if (b.min) |min| {
        try w.objectField("min");
        try writeBoundEntry(w, min);
    }
    if (b.max) |max| {
        try w.objectField("max");
        try writeBoundEntry(w, max);
    }
    if (b.exclusive_min) {
        try w.objectField("exclusive_min");
        try w.write(true);
    }
    if (b.exclusive_max) {
        try w.objectField("exclusive_max");
        try w.write(true);
    }
    if (b.integer) {
        try w.objectField("integer");
        try w.write(true);
    }
    try w.endObject();
}

fn writeBoundEntry(w: *std.json.Stringify, b: Model.NumericBounds.Bound) std.Io.Writer.Error!void {
    try w.beginObject();
    try w.objectField("value");
    try w.write(b.value);
    if (b.unit) |u| {
        try w.objectField("unit");
        try w.write(u);
    }
    if (b.exact_int) {
        try w.objectField("exact_int");
        try w.write(true);
    }
    try w.endObject();
}

fn writeWarningJson(w: *std.json.Stringify, wn: Warnings.Warning) std.Io.Writer.Error!void {
    try w.beginObject();
    try w.objectField("code");
    try w.write(@tagName(wn.code));
    try w.objectField("severity");
    try w.write(@tagName(wn.severity));
    try w.objectField("message");
    try w.write(wn.message);
    if (wn.plugin_name) |p| {
        try w.objectField("plugin_name");
        try w.write(p);
    }
    if (wn.form_name) |f| {
        try w.objectField("form_name");
        try w.write(f);
    }
    if (wn.key_name) |k| {
        try w.objectField("key_name");
        try w.write(k);
    }
    if (wn.kind_name) |k| {
        try w.objectField("kind_name");
        try w.write(k);
    }
    try w.endObject();
}

const testing = std.testing;
