//! SJON schema exporter — public surface.
//!
//! Walks a `Schema.Schema` and produces a `Model` IR plus the
//! requested target artifacts (JSON Schema 2020-12, TypeScript `.d.ts`,
//! or the IR itself). Lossy-mapping decisions live in the per-construct
//! `loweringFor*` helpers; backends consume the IR mechanically.
//!
//! Memory model: every call allocates a fresh arena; `ExportResult.deinit()`
//! releases it. Strings inside the IR, warnings, and byte buffers all
//! point into that arena, so the caller does not need to keep `schema`
//! or any source bytes alive past the call.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Plugin = @import("../Plugin.zig");
const Schema = @import("../Schema.zig");

pub const Model = @import("Model.zig");
pub const Warnings = @import("Warnings.zig");
pub const JsonSchema = @import("JsonSchema.zig");
pub const TsTypes = @import("TsTypes.zig");
pub const Markdown = @import("Markdown.zig");
pub const Discriminators = @import("Discriminators.zig");

/// Targets the exporter knows how to emit.
pub const Target = struct {
    json_schema: bool = true,
    ts_types: bool = true,
    intermediate: bool = false,
    /// Markdown reference pages (devx C2). Off by default — asked for
    /// by name, never part of `both`.
    markdown: bool = false,
};

/// Layout strategy for multi-plugin schemas. M1 only honours
/// `aggregated`; the per-plugin layout is M3 (it requires cross-file
/// `$ref` resolution and is wired then).
pub const Layout = enum { aggregated, per_plugin };

/// JSON Schema draft. M1 only accepts 2020-12; the option exists so
/// CLI parsing can return a usage error for other values rather than
/// silently falling back.
pub const JsonSchemaDraft = enum { @"2020-12" };

/// All knobs the exporter exposes. Defaults are M1-safe.
pub const ExportOptions = struct {
    target: Target = .{},
    layout: Layout = .aggregated,
    draft: JsonSchemaDraft = .@"2020-12",
    /// When true the lowering pass calls every aggregate validator
    /// (cross-refs, unions, forms, lowering, defaults) and folds their
    /// diagnostics into the warning stream. Off by default so callers
    /// who already ran `Host.validateDocument` don't double-pay the
    /// aggregate cost.
    run_aggregate_validators: bool = false,
};

/// Owned result of an `exportSchema` call.
pub const ExportResult = struct {
    arena: ArenaAllocator,
    model: Model.Model,
    json_schema_bytes: ?[]const u8,
    ts_types_bytes: ?[]const u8,
    intermediate_bytes: ?[]const u8,
    markdown_bytes: ?[]const u8 = null,
    warnings: []const Warnings.Warning,
    /// Populated when `ExportOptions.layout == .per_plugin`. One artifact
    /// per plugin in declaration order. The single-buffer aggregated
    /// fields above stay populated too — they hold a single-document view
    /// (concatenated `$defs`, unioned `oneOf`); per-plugin emit additionally
    /// produces sibling-file-friendly artifacts whose `$ref` paths point
    /// at relative file names rather than into one shared `$defs`.
    per_plugin: ?[]const Model.PerPluginArtifact = null,

    pub fn deinit(self: *ExportResult) void {
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const ExportResult) bool {
        return Warnings.anyError(self.warnings);
    }
};

pub const Error = error{OutOfMemory};

/// Lower a `Schema.Schema` into the IR and emit every requested
/// target. Caller owns the returned `ExportResult` and must call
/// `deinit()` exactly once.
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

    // Dedupe before emit so the artifacts and the in-memory warnings
    // list agree on the same set.
    const deduped = try dedupeWarnings(a, warnings.items);

    var json_schema_bytes: ?[]const u8 = null;
    var ts_types_bytes: ?[]const u8 = null;
    var intermediate_bytes: ?[]const u8 = null;
    var markdown_bytes: ?[]const u8 = null;

    if (options.target.json_schema) {
        json_schema_bytes = try JsonSchema.emit(a, model, deduped);
    }
    if (options.target.ts_types) {
        ts_types_bytes = try TsTypes.emit(a, model, deduped);
    }
    if (options.target.intermediate) {
        intermediate_bytes = try emitIntermediate(a, model, deduped);
    }
    if (options.target.markdown) {
        markdown_bytes = try Markdown.emit(a, model, deduped);
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
        .markdown_bytes = markdown_bytes,
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
            .markdown_bytes = if (target.markdown)
                try Markdown.emitForPlugin(a, model, p, filtered)
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
        // Aggregate warnings without a plugin scope land in every plugin's
        // artifact so a downstream reader sees them everywhere; otherwise
        // only the matching plugin gets the warning.
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

/// Drop adjacent and global duplicates from the warning stream. A kind
/// referenced from a key gets lowered twice (once inline at the key
/// site, once in the plugin's value_kinds loop) and emits the same
/// warning each time. Same with kinds referenced from multiple keys.
/// Dedupe by `(code, message, plugin, form, key, kind)` tuple — the
/// warning surface stays informative without becoming a wall of
/// duplicates.
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

// ---------------------------------------------------------------------------
// Aggregate-phase forwarding.
// ---------------------------------------------------------------------------

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

const freeDiagnostics = @import("../Ast.zig").Diagnostic.freeOwnedSlice;

// ---------------------------------------------------------------------------
// Schema → Model lowering.
// ---------------------------------------------------------------------------

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
            // No slot: this pass exists for the value-kind table the
            // Markdown and `--target=intermediate` channels render, and a
            // head-set kind is reusable across slots with different local
            // registries. `locals = null` says so, and downgrades an
            // unresolved head to a note (see `Context.locals`).
            .shape = try lowerValueKind(a, schema, plugin, vk, warnings, .{ .plugin_name = plugin.name }),
            .origin_plugin = try a.dupe(u8, plugin.name),
        };
    }

    return .{
        .name = try a.dupe(u8, plugin.name),
        .version = try a.dupe(u8, plugin.version),
        .forms = forms_out,
        .value_kinds = kinds_out,
        .expr_funcs = try lowerExprFuncs(a, plugin.expr_funcs),
    };
}

/// Presentation-lower every expr-func: one `ExprFuncEntry` per source
/// func, signature text pre-rendered per overload (the mono encoding
/// becomes a one-signature overload set).
fn lowerExprFuncs(a: Allocator, src: []const Plugin.ExprFunc) Error![]const Model.ExprFuncEntry {
    const out = try a.alloc(Model.ExprFuncEntry, src.len);
    for (src, 0..) |f, i| {
        var sigs: std.ArrayList([]const u8) = .empty;
        if (f.signatures) |overloads| {
            for (overloads) |sig| try sigs.append(a, try renderSignatureText(a, f.name, sig));
        } else {
            try sigs.append(a, try renderSignatureText(a, f.name, .{
                .arity = f.arity,
                .params = f.params,
                .param_names = f.param_names,
                .rest = f.rest,
                .result = f.result,
            }));
        }
        out[i] = .{
            .name = try a.dupe(u8, f.name),
            .description = try a.dupe(u8, f.description),
            .signatures = try sigs.toOwnedSlice(a),
        };
    }
    return out;
}

/// Render one signature as `(name p1 p2 …rest) -> result`: typed slots
/// spell their `ValueType` (named refs keep the user's qualification),
/// labeled slots prefix `name: `, opaque slots render `_`, a variadic
/// tail renders `…` (typed when `rest` is). Result omitted when
/// undeclared.
fn renderSignatureText(a: Allocator, name: []const u8, sig: Plugin.ExprFunc.Signature) Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(a, '(');
    try buf.appendSlice(a, name);
    const fixed_count: usize = if (sig.params) |ps| ps.len else switch (sig.arity) {
        .fixed => |k| k,
        .at_least => |k| k,
        .range => |r| r.min,
    };
    var i: usize = 0;
    while (i < fixed_count) : (i += 1) {
        try buf.append(a, ' ');
        if (sig.param_names) |names| {
            if (i < names.len) {
                try buf.appendSlice(a, names[i]);
                try buf.appendSlice(a, ": ");
            }
        }
        if (sig.params) |ps| {
            try appendValueTypeName(&buf, a, ps[i]);
        } else {
            try buf.append(a, '_');
        }
    }
    const variadic = sig.rest != null or switch (sig.arity) {
        .fixed => false,
        .at_least => true,
        .range => |r| r.max > r.min,
    };
    if (variadic) {
        try buf.appendSlice(a, " …");
        if (sig.rest) |r| try appendValueTypeName(&buf, a, r);
    }
    try buf.append(a, ')');
    if (sig.result) |r| {
        try buf.appendSlice(a, " -> ");
        try appendValueTypeName(&buf, a, r);
    }
    return buf.toOwnedSlice(a);
}

fn appendValueTypeName(buf: *std.ArrayList(u8), a: Allocator, t: Plugin.ValueType) Error!void {
    switch (t) {
        .named => |ref| {
            if (ref.namespace) |ns| {
                try buf.appendSlice(a, ns);
                try buf.append(a, '/');
            }
            try buf.appendSlice(a, ref.name);
        },
        else => try buf.appendSlice(a, @tagName(t)),
    }
}

test "renderSignatureText: typed, labeled, variadic, opaque" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Typed + labeled + result.
    const lerp = try renderSignatureText(a, "lerp", .{
        .arity = .{ .fixed = 3 },
        .params = &.{ .number, .number, .number },
        .param_names = &.{ "a", "b", "t" },
        .result = .number,
    });
    try std.testing.expectEqualStrings("(lerp a: number b: number t: number) -> number", lerp);

    // Opaque fixed arity renders placeholders.
    const deg = try renderSignatureText(a, "deg", .{ .arity = .{ .fixed = 1 } });
    try std.testing.expectEqualStrings("(deg _)", deg);

    // Variadic tail with a typed rest.
    const sum = try renderSignatureText(a, "+", .{
        .arity = .{ .at_least = 1 },
        .rest = .number,
        .result = .number,
    });
    try std.testing.expectEqualStrings("(+ _ …number) -> number", sum);

    // Named result keeps the user's qualification.
    const mk = try renderSignatureText(a, "mk", .{
        .arity = .{ .fixed = 0 },
        .result = .{ .named = .{ .name = "point", .namespace = "shapes" } },
    });
    try std.testing.expectEqualStrings("(mk) -> shapes/point", mk);
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

    // Positional slot-local forms (`FormSpec.local_forms`) are the positional
    // mirror of key-slot locals (see `lowerKey`): inline `(form …)` children
    // that the slot resolves local-first, then additively against the global
    // catalog. Lowered *before* the positional kind, because a head-set
    // resolution embeds these bodies — each via `lowerForm`, so a
    // discriminated local keeps its if/then, with recursion bounded by
    // `MAX_LOCAL_FORM_DEPTH` (finite manifest tree).
    const locals: []Model.Form = if (form.local_forms.len == 0) &.{} else blk: {
        const out = try a.alloc(Model.Form, form.local_forms.len);
        for (form.local_forms, 0..) |lf, i| {
            out[i] = try lowerForm(a, schema, plugin, lf, warnings);
        }
        break :blk out;
    };

    var positional: Model.Positional = switch (form.positional) {
        .none => .none,
        .any => .any,
        .kind => |ref| blk: {
            const shape = try resolveNamedShape(a, schema, plugin, ref.name, ref.namespace, warnings, .{
                .plugin_name = plugin.name,
                .form_name = form.name,
                .locals = form.local_forms,
                .lowered_locals = locals,
            });
            break :blk .{ .kind = shape };
        },
        // Positional keyword flags don't constrain a child *value shape*,
        // so widen to `.any`; the names + metadata ride alongside as the
        // `x-sjon-positional-flags` annotation (see `positional_flags`).
        .flag_set => .any,
    };

    if (form.local_forms.len > 0) {
        // Two shapes, and which one applies is decided by whether the
        // declared positional already constrains *heads*.
        //
        //   * A head-set (`.form_heads`) closes the slot by head text, and
        //     the resolution above has already embedded each local body
        //     into the matching member. Keeping it is what preserves the
        //     narrowing, the `x-sjon-head-set` annotation and the per-head
        //     `contains` bounds — all three of which the old unconditional
        //     override dropped.
        //   * Anything else places no head constraint, so the locals open
        //     the slot additively: the inline union plus a trailing open
        //     generic branch for any global form.
        //
        // The loader guarantees only `.any` and `.kind` reach here with a
        // non-empty registry: `.flag_set` beside locals is `invalid_manifest`
        // and a bare `.none` is rewritten to `.any` so the locals aren't
        // dead behind `positional_not_allowed` (`ManifestLoader.zig:707-716`).
        const head_set: ?[]const Model.FormRef = switch (positional) {
            .kind => |shape| switch (shape) {
                .form_heads => |hs| hs.refs,
                else => null,
            },
            .none, .any => null,
        };
        if (head_set) |refs| {
            // A local outside the set is dead: narrowing rejects the head
            // (`not_head_member`) before resolution reaches the registry,
            // so the body is declared and unreachable. The exporter is
            // the only pass holding both the set and the registry at once,
            // which is why it is the one that notices.
            for (form.local_forms) |lf| {
                var in_set = false;
                for (refs) |ref| {
                    if (std.mem.eql(u8, ref.name, lf.name)) {
                        in_set = true;
                        break;
                    }
                }
                if (in_set) continue;
                try warnings.append(a, .{
                    .code = .local_form_outside_head_set,
                    .severity = .warn,
                    .message = try std.fmt.allocPrint(
                        a,
                        "positional slot-local form `{s}` on `{s}` is outside the slot's head-set, so no child can ever reach it — add `{s}` to the head-set or delete the local",
                        .{ lf.name, form.name, lf.name },
                    ),
                    .plugin_name = try a.dupe(u8, plugin.name),
                    .form_name = try a.dupe(u8, form.name),
                });
            }
        } else {
            positional = .{ .kind = .{ .form_locals = locals } };
        }
        try warnings.append(a, .{
            .code = .local_forms_emitted_inline,
            .severity = .info,
            .message = if (head_set) |refs| try std.fmt.allocPrint(
                a,
                "positional slot on form `{s}` declares {d} local form(s) behind a {d}-head head-set — emitted as a closed inline union with no global fallback branch; a head outside the set is `not_head_member`",
                .{ form.name, form.local_forms.len, refs.len },
            ) else try std.fmt.allocPrint(
                a,
                "positional slot on form `{s}` declares {d} local form(s) — emitted as an inline union plus an open generic branch for the additive global fallback; local-first/global resolution order is SJON-only",
                .{ form.name, form.local_forms.len },
            ),
            .plugin_name = try a.dupe(u8, plugin.name),
            .form_name = try a.dupe(u8, form.name),
            // key_name intentionally null — this is the form's positional slot,
            // not a keyed slot.
        });
    }

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
                const when = try a.alloc([]const u8, v.when.len);
                for (v.when, 0..) |w, j| when[j] = try a.dupe(u8, w);
                variants_out[i] = .{
                    .when = when,
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
        // A slot, with an empty registry — always empty, because the
        // loader rejects keyed locals on anything but `:type form`
        // (`ManifestLoader.zig:1312`), so a keyed slot can never carry
        // both a head-set and locals. Non-null so the resolution judges.
        .locals = &.{},
    });

    // Slot-local forms live on the key, not the type: a `:type form` slot
    // (lowered to `.form_any` above) carrying inline locals is re-shaped to
    // an inline anonymous union (`.form_locals`). Each local is lowered via
    // `lowerForm` so a discriminated local still gets its if/then; recursion
    // is bounded by `MAX_LOCAL_FORM_DEPTH` (finite manifest tree). The
    // additive global fallback is the backends' trailing open branch.
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

    var requires_out: [][]const u8 = &.{};
    if (key.requires.len != 0) {
        requires_out = try a.alloc([]const u8, key.requires.len);
        for (key.requires, 0..) |r, i| requires_out[i] = try a.dupe(u8, r);
    }

    return .{
        .name = try a.dupe(u8, key.name),
        .optional = key.effectiveOptional(),
        .description = try a.dupe(u8, key.description),
        .value = shape,
        .default = default_out,
        .requires = requires_out,
    };
}

/// Where a value-kind is being lowered *from*. Carries the names that
/// scope a warning, plus the slot-local form registry a head-set
/// resolution needs.
const Context = struct {
    plugin_name: []const u8,
    form_name: ?[]const u8 = null,
    key_name: ?[]const u8 = null,
    kind_name: ?[]const u8 = null,
    /// The enclosing slot's `FormSpec.local_forms`, source side, or
    /// `null` when there is **no slot** — `lowerPlugin`'s standalone pass
    /// over every value-kind, which exists for the Markdown and
    /// `--target=intermediate` channels.
    ///
    /// `null` versus empty is load-bearing and is why this is an optional
    /// slice rather than a slice: "this slot declares no locals" is a
    /// verdict a head-set resolution can act on, and "there is no slot"
    /// is the absence of one. Only the first may call a head unresolvable.
    locals: ?[]const Plugin.FormSpec = null,
    /// The same registry, already lowered, index-parallel to `locals`. A
    /// `.local` head embeds one of these, so `lowerForm` lowers its
    /// locals *before* resolving the positional kind.
    lowered_locals: []const Model.Form = &.{},

    /// True when a slot is in hand and the head-set resolution is
    /// therefore complete enough to call a head unresolvable.
    fn judges(self: Context) bool {
        return self.locals != null;
    }

    /// The slot-local form matching `head`, and its lowered body, or null.
    /// Bare names only — a qualified head bypasses locals in the
    /// validator (`Validator.validateFormHead` step 0) and must here too.
    fn matchLocal(self: Context, head: []const u8) ?*const Model.Form {
        const reg = self.locals orelse return null;
        std.debug.assert(reg.len == self.lowered_locals.len);
        for (reg, 0..) |lf, i| {
            if (std.mem.eql(u8, lf.name, head)) return &self.lowered_locals[i];
        }
        return null;
    }
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
        .found => |kind| try lowerValueKind(a, schema, plugin, kind.*, warnings, ctx),
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

/// Build `"<namespace>/<name>"` (or just `"<name>"` when namespace is
/// null) into a freshly-allocated buffer. Used so diagnostic prose
/// echoes the user's surface text.
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
    if (std.mem.eql(u8, name, "vector")) return null; // need element type
    return null;
}

fn lowerValueKind(
    a: Allocator,
    schema: Schema.Schema,
    plugin: Plugin.Plugin,
    vk: Plugin.ValueKind,
    warnings: *std.ArrayList(Warnings.Warning),
    /// The site this kind is being lowered *for*. Pins the kind name and
    /// carries the caller's slot (and its local registry) down to
    /// `lowerFormKind`, which is the one arm whose output depends on it.
    /// Callers pass their own context rather than one minted here, so a
    /// head-set kind reached through a union alternative still knows
    /// which slot it landed in.
    outer: Context,
) Error!Model.ValueShape {
    const ctx: Context = blk: {
        var c = outer;
        c.kind_name = vk.name;
        break :blk c;
    };
    // 1) Refinements that completely replace the underlying mapping.
    if (vk.cross_ref) |cr| {
        // The provider route is unenforceable for one more reason than the
        // identity one, and it is worth naming: the identity route's member
        // set is at least *derivable* from a document, while the provider's
        // is produced by running an extractor the export target has no way
        // to call.
        try warnings.append(a, .{
            .code = .cross_ref_unenforceable,
            .severity = .warn,
            .message = if (cr.provider) |p| try std.fmt.allocPrint(
                a,
                "value-kind `{s}` cross-ref: schema validates symbol shape only; the member set is extracted from each target's `:{s}` string by provider `{s}` during validation, so it is not knowable at export time",
                .{ vk.name, cr.source_key, p },
            ) else try std.fmt.allocPrint(
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
            // Each route lists the fields that route can carry: `name-key`
            // and `acyclic` are identity-only (the loader rejects a
            // non-default `name-key` beside a provider, and cycle edges
            // need per-name declaration sites the provider route lacks).
            .message = if (cr.provider) |p| try std.fmt.allocPrint(
                a,
                "value-kind `{s}` cross-ref annotation surfaces target-form=`{s}` provider=`{s}` source-key=`{s}` scope-form=`{s}`; none are enforceable by JSON Schema",
                .{
                    vk.name,
                    try cr.describeTargets(a),
                    p,
                    cr.source_key,
                    if (cr.scope_form) |sf| sf else "",
                },
            ) else try std.fmt.allocPrint(
                a,
                "value-kind `{s}` cross-ref annotation surfaces target-form=`{s}` name-key=`{s}` acyclic={s} scope-form=`{s}`; none are enforceable by JSON Schema",
                .{
                    vk.name,
                    try cr.describeTargets(a),
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
        return .{
            .cross_ref = .{
                .targets = try dupeTargets(a, cr.targets),
                .name_key = try a.dupe(u8, cr.name_key),
                .acyclic = cr.acyclic,
                .scope_form = if (cr.scope_form) |sf| try a.dupe(u8, sf) else null,
                // Both or neither: `source_key` carries a default the identity
                // route never uses, so mirroring it unconditionally would put a
                // meaningless `"src"` in every identity-route annotation.
                .provider = if (cr.provider) |p| try a.dupe(u8, p) else null,
                .source_key = if (cr.provider == null) null else try a.dupe(u8, cr.source_key),
            },
        };
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

    // 2) Underlying-driven mapping.
    return switch (vk.underlying) {
        .number => lowerNumberKind(a, plugin, vk, warnings),
        .string => lowerStringKind(a, plugin, vk, warnings),
        .symbol => lowerSymbolKind(a, plugin, vk, warnings),
        .form => lowerFormKind(a, schema, plugin, vk, warnings, ctx),
        .vector => try lowerVectorKind(a, schema, plugin, vk, warnings),
        .union_of => unreachable, // handled above
    };
}

/// Copy a cross-ref's target list onto `a`, entries included. The model
/// owns its strings (the schema it was lowered from may outlive nothing),
/// so a shallow slice copy would not do.
fn dupeTargets(a: Allocator, targets: []const []const u8) Allocator.Error![]const []const u8 {
    std.debug.assert(targets.len >= 1);
    const out = try a.alloc([]const u8, targets.len);
    for (targets, 0..) |t, i| out[i] = try a.dupe(u8, t);
    std.debug.assert(out.len == targets.len);
    return out;
}

fn lowerNumberKind(
    a: Allocator,
    plugin: Plugin.Plugin,
    vk: Plugin.ValueKind,
    warnings: *std.ArrayList(Warnings.Warning),
) Error!Model.ValueShape {
    // Merge `:numeric` and `:repr` into one `NumericBounds`. Either may be
    // present independently: `:numeric` carries min/max/integer, `:repr`
    // adds the GPU type tag. A repr-only kind yields a `NumericBounds` with
    // null min/max and just `repr` set (still a `number_bounded` shape).
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

    // A `:reject` unit-shape demands bare numbers (units forbidden), so it
    // exports as a plain number / bounded-number, never the number_with_unit
    // object shape. Only a non-reject unit emits a unit.
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
        // The min/max warning is only meaningful when `:numeric` supplied
        // actual bounds; a repr-only kind has null min/max and emits just
        // the `x-sjon-gpu-repr` annotation (no JSON Schema range keywords).
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
        .multiple_of = if (nb.multiple_of) |b| try copyBound(a, b) else null,
    };
}

fn copyBound(a: Allocator, b: Plugin.ValueKind.NumericBounds.Bound) Error!Model.NumericBounds.Bound {
    return .{
        .value = b.value,
        .unit = if (b.unit) |u| try a.dupe(u8, u) else null,
        .exact_int = b.exact_int,
    };
}

fn maybeWarnExactIntOverflow(
    a: Allocator,
    plugin: Plugin.Plugin,
    vk: Plugin.ValueKind,
    bounds: Model.NumericBounds,
    warnings: *std.ArrayList(Warnings.Warning),
) Error!void {
    if (bounds.min) |b| {
        if (b.exceedsF64Precision()) {
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
        if (b.exceedsF64Precision()) {
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

/// Lower a `.form`-underlying value-kind. With `:heads` this is the
/// head-set resolution: one `Model.FormRef` per accepted head, resolved
/// the way `Validator.validateFormHead` resolves the child that will
/// carry it — **slot-local first, global catalog second**.
///
/// `ctx.locals` is what makes that possible, and what decides whether a
/// miss is reported at all. See `Context.locals`: a slot judges, the
/// standalone value-kind pass stays quiet.
fn lowerFormKind(
    a: Allocator,
    schema: Schema.Schema,
    plugin: Plugin.Plugin,
    vk: Plugin.ValueKind,
    warnings: *std.ArrayList(Warnings.Warning),
    ctx: Context,
) Error!Model.ValueShape {
    const hs = vk.heads orelse return .form_any;

    const refs = try a.alloc(Model.FormRef, hs.heads.len);
    var local_count: usize = 0;
    for (hs.heads, 0..) |entry, i| {
        const n = entry.name;
        const owner, const body: Model.FormRef.Body = if (ctx.matchLocal(n)) |lf| blk: {
            local_count += 1;
            // A slot-local belongs to the plugin whose form declares it,
            // which is the plugin being lowered — locals never cross a
            // plugin boundary.
            break :blk .{ plugin.name, .{ .local = lf } };
        } else hit: {
            const lookup = schema.lookupForm(n, null);
            const ambiguous = lookup == .ambiguous;
            switch (lookup) {
                .found => |f| break :hit .{ f.plugin.name, Model.FormRef.Body.global },
                .not_found, .ambiguous => {},
            }
            // Only a slot may call a head unresolvable, and only a slot
            // says anything about one. The standalone value-kind pass
            // (`lowerPlugin`, feeding the Markdown and IR channels) sees
            // every head-set with `locals == null`, so a head-set written
            // *for* a locals slot — the closed-positional-set recipe, and
            // the shape this whole change exists for — would otherwise
            // emit one note per member on every export, saying only that
            // the question belongs elsewhere. The slots it belongs to all
            // answer it, at `.err`. What that gives up is a head-set kind
            // no slot references at all: its typo goes unreported, which
            // is dead schema reported by nothing else either.
            if (ctx.judges()) {
                try warnings.append(a, .{
                    .code = .head_set_member_unresolved,
                    .severity = .err,
                    .message = if (ambiguous) try std.fmt.allocPrint(
                        a,
                        "head-set member `{s}` on value-kind `{s}` is declared by more than one plugin; qualify it or rename one",
                        .{ n, vk.name },
                    ) else try std.fmt.allocPrint(
                        a,
                        "head-set member `{s}` on value-kind `{s}` resolves to no form in scope at this slot — no slot-local `(form :name {s} …)` and no global one",
                        .{ n, vk.name, n },
                    ),
                    .plugin_name = try a.dupe(u8, plugin.name),
                    .form_name = if (ctx.form_name) |f| try a.dupe(u8, f) else null,
                    .key_name = if (ctx.key_name) |k| try a.dupe(u8, k) else null,
                    .kind_name = try a.dupe(u8, vk.name),
                });
            }
            break :hit .{ "", Model.FormRef.Body.unresolved };
        };
        refs[i] = .{
            .plugin = try a.dupe(u8, owner),
            .name = try a.dupe(u8, n),
            .min = entry.min,
            .max = entry.max,
            .body = body,
        };
    }

    // Scoped to slots for the same reason the miss above is: the note
    // describes how a *slot's* `$children` was emitted, and the
    // standalone value-kind pass emits no `$children` anywhere. Left
    // unscoped it fired twice per locals-backed head-set — once with the
    // slot's message and once with the generic one, which is exactly the
    // pair `dedupeWarnings` used to collapse before the messages could
    // differ. A global-only head-set on several slots still collapses to
    // one line, because its message and fields are slot-independent.
    const shape: Model.HeadSetShape = .{ .refs = refs, .min_children = hs.min_children, .max_children = hs.max_children };
    if (!ctx.judges()) return .{ .form_heads = shape };
    try warnings.append(a, .{
        .code = .head_set_emitted_via_oneof_refs,
        .severity = .info,
        .message = if (local_count == 0) try std.fmt.allocPrint(
            a,
            "value-kind `{s}` head-set emitted as `oneOf` of `$ref`s into `#/$defs/form.<plugin>.<head>`",
            .{vk.name},
        ) else try std.fmt.allocPrint(
            a,
            "value-kind `{s}` head-set emitted as a closed `oneOf` — {d} of {d} head(s) resolve to slot-local forms and are emitted inline, the rest as `$ref`s into `#/$defs/form.<plugin>.<head>`",
            .{ vk.name, local_count, hs.heads.len },
        ),
        .plugin_name = try a.dupe(u8, plugin.name),
        .form_name = if (local_count == 0) null else if (ctx.form_name) |f| try a.dupe(u8, f) else null,
        .kind_name = try a.dupe(u8, vk.name),
    });
    return .{ .form_heads = shape };
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
        // A vector *element* is a value, not a form child, so no
        // slot-local registry ever reaches it (the validator attaches one
        // only to a direct `.form` child of the slot). Empty rather than
        // null: the resolution here is complete, so it may judge.
        .locals = &.{},
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
    var any_annotated = false;
    var any_numeric = false;
    for (ms.members) |m| {
        if (m.label.len > 0 or m.description.len > 0 or m.deprecated or m.deprecation_message.len > 0) {
            any_annotated = true;
        }
        // A digit-leading spelling forces the rich shape whether or not it
        // carries annotations: it is written as a unit-bearing number, so
        // the compact `enum` of `{"$sym": …}` entries cannot express it and
        // would reject a document the validator accepts.
        if (m.numeric_spelling != null) any_numeric = true;
    }
    if (any_annotated or any_numeric) {
        try warnings.append(a, .{
            .code = .rich_members_emitted_with_annotations,
            .severity = .info,
            .message = if (any_numeric and any_annotated) try std.fmt.allocPrint(
                a,
                "value-kind `{s}` member-set carries rich metadata and digit-leading spellings — emitted as per-member `oneOf` with title/description/deprecated annotations and `$num` wire shapes",
                .{vk.name},
            ) else if (any_numeric) try std.fmt.allocPrint(
                a,
                "value-kind `{s}` member-set carries digit-leading spellings — emitted as per-member `oneOf`, with each digit-leading member pinned to its `$num` wire shape rather than `$sym`",
                .{vk.name},
            ) else try std.fmt.allocPrint(
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
                .numeric_spelling = if (m.numeric_spelling) |s| .{
                    .magnitude = s.value,
                    .unit = try a.dupe(u8, s.unit),
                } else null,
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

// ---------------------------------------------------------------------------
// Defaults — only literal shapes survive; expression snapshots become a
// warning + an `expression` IR entry carrying head/namespace/arg_count.
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Intermediate JSON dump — the IR serialised in a self-describing shape.
// Used for third-party tooling that wants to consume the IR without
// committing to JSON Schema or TypeScript.
// ---------------------------------------------------------------------------

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
    // Omitted when empty so a schema with no dependencies serializes
    // byte-identically to before.
    if (k.requires.len != 0) {
        try w.objectField("requires");
        try w.beginArray();
        for (k.requires) |r| try w.write(r);
        try w.endArray();
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
        .form_heads => |hs| {
            try w.beginObject();
            try w.objectField("kind");
            try w.write("form_heads");
            try w.objectField("refs");
            try w.beginArray();
            for (hs.refs) |r| {
                try w.beginObject();
                try w.objectField("plugin");
                try w.write(r.plugin);
                try w.objectField("name");
                try w.write(r.name);
                // Counts only when declared, so an unbounded head-set's IR
                // is byte-identical to before. The `--target=intermediate`
                // channel is a first-class consumer surface (the TS host's
                // own export port reads it), so dropping a bound here would
                // silently make it unable to see the feature.
                if (r.min != 0) {
                    try w.objectField("min");
                    try w.write(r.min);
                }
                if (r.max) |mx| {
                    try w.objectField("max");
                    try w.write(mx);
                }
                // Resolution route. Omitted for `.global`, which is what
                // every head-set carried before slot-aware resolution, so
                // a global-only head-set's IR stays byte-identical. An IR
                // consumer that only knows the old shape therefore finds
                // the key *absent* rather than reading a local body as a
                // global `$ref` it cannot resolve — the same
                // omit-when-inapplicable idiom `scope-form` and S4b's
                // `target-forms` follow.
                switch (r.body) {
                    .global => {},
                    .local => |lf| {
                        try w.objectField("resolved");
                        try w.write("local");
                        try w.objectField("local");
                        try writeFormJson(w, lf.*);
                    },
                    .unresolved => {
                        try w.objectField("resolved");
                        try w.write("unresolved");
                    },
                }
                try w.endObject();
            }
            try w.endArray();
            // The set's own count, beside the members rather than inside
            // one of them — it belongs to the set, and an IR consumer
            // that read it off a member would be reading a per-head
            // claim. Omitted when absent, so a pre-S10 head-set's IR is
            // byte-identical. Fifth plan running to need this: the
            // `--target=intermediate` channel is a consumer surface, not
            // a summary.
            if (hs.min_children != 0) {
                try w.objectField("min-children");
                try w.write(hs.min_children);
            }
            if (hs.max_children) |mx| {
                try w.objectField("max-children");
                try w.write(mx);
            }
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
            try w.objectField("targets");
            try w.beginArray();
            for (cr.targets) |t| try w.write(t);
            try w.endArray();
            try w.objectField("name_key");
            try w.write(cr.name_key);
            try w.objectField("acyclic");
            try w.write(cr.acyclic);
            try w.objectField("scope_form");
            if (cr.scope_form) |sf| try w.write(sf) else try w.write(null);
            // The IR mirror spells absence as an explicit null (unlike the
            // JSON Schema annotation, which omits the key) — a consumer
            // reading the IR sees the same field set for every cross-ref.
            try w.objectField("provider");
            if (cr.provider) |p| try w.write(p) else try w.write(null);
            try w.objectField("source_key");
            if (cr.source_key) |sk| try w.write(sk) else try w.write(null);
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
        // A digit-leading spelling has to reach an IR consumer: without
        // it the consumer sees the name `2d` and cannot tell that a
        // document writes it as a number rather than a symbol. The TS
        // host's own export port reads this IR.
        if (m.numeric_spelling) |s| {
            try w.objectField("numeric_spelling");
            try w.beginObject();
            try w.objectField("magnitude");
            try w.write(s.magnitude);
            try w.objectField("unit");
            try w.write(s.unit);
            try w.endObject();
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
    if (b.multiple_of) |mo| {
        try w.objectField("multiple_of");
        try writeBoundEntry(w, mo);
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

// ---------------------------------------------------------------------------
// Tests — exercise lowering against a synthetic plugin.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "lowering: empty schema produces a zero-plugin model" {
    const a = testing.allocator;
    const schema: Schema.Schema = .{ .plugins = &.{} };
    var result = try exportSchema(a, schema, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.model.plugins.len);
    try testing.expectEqual(@as(usize, 0), result.warnings.len);
}

test "lowering: primitive key shapes" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "prims",
        .forms = &.{
            .{
                .name = "row",
                .keys = &.{
                    .{ .name = "n", .value_type = .number },
                    .{ .name = "s", .value_type = .string },
                    .{ .name = "b", .value_type = .boolean },
                    .{ .name = "v", .value_type = .vector },
                    .{ .name = "f", .value_type = .form },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.model.plugins.len);
    const form = result.model.plugins[0].forms[0];
    try testing.expectEqualStrings("row", form.name);
    try testing.expectEqual(Model.ValueShape.number, form.keys[0].value);
    try testing.expectEqual(Model.ValueShape.string, form.keys[1].value);
    try testing.expectEqual(Model.ValueShape.boolean, form.keys[2].value);
    try testing.expect(form.keys[3].value == .vector);
    try testing.expectEqual(Model.ValueShape.form_any, form.keys[4].value);
}

test "lowering: required vs optional via effectiveOptional" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{
            .{
                .name = "f",
                .keys = &.{
                    .{ .name = "req", .value_type = .string, .optional = false },
                    .{ .name = "opt", .value_type = .string, .optional = true },
                    .{ .name = "defaulted", .value_type = .string, .optional = false, .default = .{ .string = "fallback" } },
                },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{});
    defer result.deinit();
    const keys = result.model.plugins[0].forms[0].keys;
    try testing.expect(!keys[0].optional);
    try testing.expect(keys[1].optional);
    try testing.expect(keys[2].optional); // defaulted ⇒ effectively optional
}

test "lowering: named ref to a compact symbol member-set" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{
            .{
                .name = "f",
                .keys = &.{.{ .name = "fill", .value_type = .{ .named = .{ .name = "fill-rule" } } }},
            },
        },
        .value_kinds = &.{
            .{
                .name = "fill-rule",
                .underlying = .symbol,
                .members = .{ .members = &.{ .{ .name = "evenodd" }, .{ .name = "nonzero" } } },
            },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{});
    defer result.deinit();
    const key = result.model.plugins[0].forms[0].keys[0];
    try testing.expect(key.value == .symbol_members);
    try testing.expectEqual(@as(usize, 2), key.value.symbol_members.len);
    try testing.expectEqualStrings("evenodd", key.value.symbol_members[0]);
    try testing.expectEqualStrings("nonzero", key.value.symbol_members[1]);
}

test "lowering: typed vector via named element kind" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{
            .name = "f",
            .keys = &.{.{ .name = "p", .value_type = .{ .named = .{ .name = "point" } } }},
        }},
        .value_kinds = &.{
            .{ .name = "point", .underlying = .vector, .vector = .{ .len = 2, .element = .{ .name = "number" } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{});
    defer result.deinit();
    const key = result.model.plugins[0].forms[0].keys[0];
    try testing.expect(key.value == .vector);
    try testing.expectEqual(@as(?u16, 2), key.value.vector.len);
    try testing.expectEqual(Model.ValueShape.number, key.value.vector.element.*);
}

test "lowering: open form sets the IR's open flag" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{ .name = "scene", .open = true }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{});
    defer result.deinit();
    try testing.expect(result.model.plugins[0].forms[0].open);
}

test "lowering: literal defaults survive" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{
            .name = "f",
            .keys = &.{
                .{ .name = "s", .value_type = .string, .default = .{ .string = "hi" } },
                .{ .name = "n", .value_type = .number, .default = .{ .number = 3.5 } },
                .{ .name = "b", .value_type = .boolean, .default = .{ .boolean = true } },
                .{ .name = "v", .value_type = .vector, .default = .{ .vector = &.{ .{ .number = 1 }, .{ .number = 2 } } } },
            },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{});
    defer result.deinit();
    const keys = result.model.plugins[0].forms[0].keys;
    try testing.expect(keys[0].default.? == .string);
    try testing.expectEqualStrings("hi", keys[0].default.?.string);
    try testing.expectEqual(@as(f64, 3.5), keys[1].default.?.number);
    try testing.expectEqual(true, keys[2].default.?.boolean);
    try testing.expect(keys[3].default.? == .vector);
    try testing.expectEqual(@as(usize, 2), keys[3].default.?.vector.len);
}

test "lowering: head-set resolves plugin per head and emits info warning" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{
            .{ .name = "circle" },
            .{ .name = "rect" },
            .{
                .name = "badge",
                .keys = &.{.{ .name = "shape", .value_type = .{ .named = .{ .name = "shape-form" } } }},
            },
        },
        .value_kinds = &.{
            .{ .name = "shape-form", .underlying = .form, .heads = .{ .heads = &.{ .{ .name = "circle" }, .{ .name = "rect" } } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{});
    defer result.deinit();
    const badge = result.model.plugins[0].forms[2];
    const key = badge.keys[0];
    try testing.expect(key.value == .form_heads);
    try testing.expectEqual(@as(usize, 2), key.value.form_heads.refs.len);
    try testing.expectEqualStrings("circle", key.value.form_heads.refs[0].name);
    try testing.expectEqualStrings("x", key.value.form_heads.refs[0].plugin);
    try testing.expectEqualStrings("rect", key.value.form_heads.refs[1].name);
    try testing.expectEqualStrings("x", key.value.form_heads.refs[1].plugin);
    // The head-set info warning replaces the M1 deferred_construct (warn).
    var saw_info = false;
    for (result.warnings) |wn| {
        if (wn.code == .head_set_emitted_via_oneof_refs and wn.kind_name != null and std.mem.eql(u8, wn.kind_name.?, "shape-form")) {
            try testing.expectEqual(Warnings.Severity.info, wn.severity);
            saw_info = true;
        }
        if (wn.code == .deferred_construct and wn.kind_name != null and std.mem.eql(u8, wn.kind_name.?, "shape-form")) {
            return error.UnexpectedDeferredWarning;
        }
    }
    try testing.expect(saw_info);
}

/// Count warnings matching `code` at `severity`, ignoring everything else.
fn countWarnings(warnings: []const Warnings.Warning, code: Warnings.Code, severity: Warnings.Severity) usize {
    var n: usize = 0;
    for (warnings) |wn| {
        if (wn.code == code and wn.severity == severity) n += 1;
    }
    return n;
}

test "lowering: an unresolvable head-set member errors once, at the slot" {
    // Two lowerings reach the same head-set: the slot that references the
    // kind, and `lowerPlugin`'s standalone pass over every value-kind (the
    // one that feeds the Markdown and `--target=intermediate` channels).
    // Only the first has a slot in hand, and only a slot can know which
    // forms are in scope — a head-set kind is plugin-wide and reusable.
    // So the slot judges and the kind table stays quiet; exactly one
    // report, not two, and it names the slot.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "g",
        .forms = &.{
            .{ .name = "real" },
            .{ .name = "root", .positional = .{ .kind = .{ .name = "items" } } },
        },
        .value_kinds = &.{.{
            .name = "items",
            .underlying = .form,
            .heads = .{ .heads = &.{ .{ .name = "real" }, .{ .name = "ghost" } } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{});
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), countWarnings(result.warnings, .head_set_member_unresolved, .err));
    try testing.expectEqual(@as(usize, 0), countWarnings(result.warnings, .head_set_member_unresolved, .info));
    // The generic code this split replaced is gone from the head-set path;
    // its two remaining jobs (real aggregate diagnostics, an unresolvable
    // value-kind reference) are untouched.
    try testing.expectEqual(@as(usize, 0), countWarnings(result.warnings, .aggregate_phase_error, .err));
    // And it names the slot, which the kind-scoped message it replaced
    // could not.
    for (result.warnings) |wn| {
        if (wn.code != .head_set_member_unresolved) continue;
        try testing.expectEqualStrings("root", wn.form_name.?);
        try testing.expectEqualStrings("items", wn.kind_name.?);
    }
    try testing.expect(result.hasErrors());
}

test "lowering: a head-set kind no slot references reports nothing at all" {
    // The cost of the rule above, stated so it cannot be mistaken for an
    // oversight: nothing can judge a kind nobody uses, so its typo goes
    // unreported. The alternative was one note per member on every
    // locals-backed head-set — noise on the shape this exists to support,
    // to cover dead schema nothing else reports either.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "g",
        .forms = &.{.{ .name = "real" }},
        .value_kinds = &.{.{
            .name = "unused",
            .underlying = .form,
            .heads = .{ .heads = &.{.{ .name = "ghost" }} },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), countWarnings(result.warnings, .head_set_member_unresolved, .err));
    try testing.expectEqual(@as(usize, 0), countWarnings(result.warnings, .head_set_member_unresolved, .info));
    try testing.expect(!result.hasErrors());
}

test "lowering: a vector element and a union alternative are slots, so they judge" {
    // Neither can ever carry a slot-local registry — no registry reaches a
    // vector element or a union alternative's *own* resolution — so their
    // resolution is complete and an unresolved head there is an error.
    // `null` means "no slot"; empty means "a slot with no locals", and
    // these are the second.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "g",
        .forms = &.{
            .{ .name = "vec-holder", .keys = &.{.{ .name = "xs", .value_type = .{ .named = .{ .name = "listy" } } }} },
        },
        .value_kinds = &.{
            .{ .name = "heads", .underlying = .form, .heads = .{ .heads = &.{.{ .name = "ghost" }} } },
            .{ .name = "listy", .underlying = .vector, .vector = .{ .element = .{ .name = "heads" } } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{});
    defer result.deinit();
    try testing.expect(countWarnings(result.warnings, .head_set_member_unresolved, .err) >= 1);
    try testing.expect(result.hasErrors());
}

/// The closed-positional-set recipe (`docs/portable-manifest-v1.md`
/// §5.2): a head-set gating a positional slot whose locals supply the
/// bodies. `bind-group-layout` is PNGine's shape, minus a level.
const headset_locals_plugin: Plugin.Plugin = .{
    .name = "p",
    .forms = &.{
        .{
            .name = "root",
            .positional = .{ .kind = .{ .name = "res" } },
            .local_forms = &.{
                .{ .name = "buffer", .keys = &.{.{ .name = "kind", .value_type = .symbol }} },
                .{ .name = "storage-texture", .keys = &.{.{ .name = "format", .value_type = .symbol }} },
            },
        },
    },
    .value_kinds = &.{.{
        .name = "res",
        .underlying = .form,
        .heads = .{ .heads = &.{ .{ .name = "buffer" }, .{ .name = "storage-texture" } } },
    }},
};

test "lowering: a head-set slot resolves its members against the slot's locals first" {
    // The bug S7b filed: the locals override *replaced* the head-set
    // instead of supplying its bodies, so a head whose only form is a
    // slot-local reported as unresolvable and the narrowing was dropped.
    // The validator applies both mechanisms in order, and so must this.
    const a = testing.allocator;
    const schema = Schema.Schema.init(&.{headset_locals_plugin});
    var result = try exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();

    // No global `(form :name buffer …)` exists anywhere, and that is fine.
    try testing.expectEqual(@as(usize, 0), countWarnings(result.warnings, .head_set_member_unresolved, .err));
    try testing.expect(!result.hasErrors());

    // The slot keeps its head-set shape, with both heads resolved local.
    const root = result.model.plugins[0].forms[0];
    try testing.expect(root.positional == .kind);
    const shape = root.positional.kind;
    try testing.expect(shape == .form_heads);
    try testing.expectEqual(@as(usize, 2), shape.form_heads.refs.len);
    for (shape.form_heads.refs) |ref| {
        try testing.expect(ref.body == .local);
        try testing.expectEqualStrings("p", ref.plugin);
    }
    // Each local's body came along, not just its name.
    try testing.expectEqualStrings("kind", shape.form_heads.refs[0].body.local.keys[0].name);
    try testing.expectEqualStrings("format", shape.form_heads.refs[1].body.local.keys[0].name);

    // And the emitted `$children` is CLOSED: `oneOf` over the two heads,
    // with no trailing open branch. That branch is what made the slot
    // accept `(ghost …)` — a head the validator rejects outright.
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"x-sjon-head-set\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"x-sjon-local-forms\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"anyOf\"") == null);
}

test "lowering: a bounded head on a locals slot exports its counts" {
    // S1's `contains` / `minContains` / `maxContains` never reached a slot
    // that declared locals, because `writeChildrenBounds` reads
    // `.form_heads` and the override had thrown it away. Same erasure as
    // the narrowing above, counted twice.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{
            .name = "doc",
            .positional = .{ .kind = .{ .name = "sect" } },
            .local_forms = &.{.{ .name = "pin", .keys = &.{.{ .name = "at", .value_type = .number }} }},
        }},
        .value_kinds = &.{.{
            .name = "sect",
            .underlying = .form,
            .heads = .{ .heads = &.{ .{ .name = "pin", .min = 1, .max = 1 }, .{ .name = "note" } } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"minContains\": 1") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"maxContains\": 1") != null);
    // A local head's `contains` is the head-pin, not a `$ref` into a
    // `$def` that does not exist.
    try testing.expect(std.mem.indexOf(u8, bytes, "#/$defs/form.p.pin") == null);
    // `note` is in the set but declared nowhere: err at the slot, and the
    // set still lists it.
    try testing.expectEqual(@as(usize, 1), countWarnings(result.warnings, .head_set_member_unresolved, .err));
}

test "lowering: a slot-local head shadows a same-named global" {
    // The other corpus case's claim (`positional-local-headset-resolves-local`),
    // at the export layer: local-first means the global is not referenced.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{
            .{
                .name = "bind-group",
                .positional = .{ .kind = .{ .name = "bg-set" } },
                .local_forms = &.{.{ .name = "entry", .keys = &.{.{ .name = "binding", .value_type = .number }} }},
            },
            // The shadow target: a global `entry` with a different key.
            .{ .name = "entry", .keys = &.{.{ .name = "at", .value_type = .symbol }} },
        },
        .value_kinds = &.{.{
            .name = "bg-set",
            .underlying = .form,
            .heads = .{ .heads = &.{.{ .name = "entry" }} },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const shape = result.model.plugins[0].forms[0].positional.kind;
    try testing.expect(shape.form_heads.refs[0].body == .local);
    try testing.expectEqualStrings("binding", shape.form_heads.refs[0].body.local.keys[0].name);
    // The slot does not `$ref` the global `entry` — that is what
    // "local-first" means, and a `$ref` there would validate the wrong
    // body (`:at`, not `:binding`). The global keeps its own `$defs`
    // entry and the document's root `oneOf` still points at it, so the
    // claim is scoped to the slot: no member of *this* head-set is
    // `.global`.
    for (shape.form_heads.refs) |ref| try testing.expect(ref.body != .global);
    // The global is still exported in its own right.
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"form.p.entry\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"at\"") != null);
}

test "lowering: a positional local outside the head-set is reported as dead" {
    // Head-set narrowing runs before resolution ever reaches the local
    // registry, so a local whose name is outside the set can never match:
    // `(dead …)` is `not_head_member`, and the body is declared and
    // unreachable. Nothing said so before — and the exporter is the only
    // pass that holds both the set and the registry at once.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{
            .name = "root",
            .positional = .{ .kind = .{ .name = "only-a" } },
            .local_forms = &.{
                .{ .name = "a", .keys = &.{.{ .name = "q", .value_type = .number }} },
                .{ .name = "dead", .keys = &.{.{ .name = "z", .value_type = .number }} },
            },
        }},
        .value_kinds = &.{.{
            .name = "only-a",
            .underlying = .form,
            .heads = .{ .heads = &.{.{ .name = "a" }} },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), countWarnings(result.warnings, .local_form_outside_head_set, .warn));
    // `.warn`, not `.err`: the manifest loads and every other local works.
    try testing.expect(!result.hasErrors());
    var named = false;
    for (result.warnings) |wn| {
        if (wn.code != .local_form_outside_head_set) continue;
        try testing.expectEqualStrings("root", wn.form_name.?);
        try testing.expect(std.mem.indexOf(u8, wn.message, "dead") != null);
        named = true;
    }
    try testing.expect(named);

    // The dead local is not emitted either — the slot accepts exactly the
    // head set, and a branch no document can reach would misdescribe it.
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"z\"") == null);
}

test "lowering: an unreachable local is only unreachable behind a head-set" {
    // The negative half. Without a head-set the same two locals are both
    // live, so the warning must not fire on the far more common shape.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{
            .name = "root",
            .positional = .any,
            .local_forms = &.{ .{ .name = "a" }, .{ .name = "dead" } },
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), countWarnings(result.warnings, .local_form_outside_head_set, .warn));
}

test "lowering: locals with no head-set stay the open inline union" {
    // The regression pin for the half that was already right. `.any` +
    // locals — including the implied `.any` the loader writes when locals
    // appear with no `:positional` — resolves local-first and then falls
    // back to *any* global form, so the open branch is correct there and
    // must not be closed by the head-set work.
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{
            .name = "canvas",
            .positional = .any,
            .local_forms = &.{.{ .name = "dot", .keys = &.{.{ .name = "r", .value_type = .number }} }},
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{ .target = .{ .json_schema = true, .ts_types = false } });
    defer result.deinit();
    const shape = result.model.plugins[0].forms[0].positional.kind;
    try testing.expect(shape == .form_locals);
    const bytes = result.json_schema_bytes.?;
    try testing.expect(std.mem.indexOf(u8, bytes, "\"anyOf\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"x-sjon-head-set\"") == null);
}

test "lowering: unit-shape :reject exports as a plain number, not number_with_unit" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{
            .name = "f",
            .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "bare" } } }},
        }},
        .value_kinds = &.{
            .{ .name = "bare", .underlying = .number, .unit = .{ .reject = true } },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{});
    defer result.deinit();
    const key = result.model.plugins[0].forms[0].keys[0];
    // A reject unit-kind is unitless — it must NOT surface as the
    // number_with_unit object shape; bare `.number` is the projection.
    try testing.expect(key.value == .number);
    // …and it emits no number_with_unit prefixItems warning for this kind.
    for (result.warnings) |wn| {
        if (wn.code == .number_with_unit_emitted_via_prefix_items and
            wn.kind_name != null and std.mem.eql(u8, wn.kind_name.?, "bare"))
        {
            return error.UnexpectedUnitWarning;
        }
    }
}

test "lowering: unresolved named ref upgrades to err warning" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{.{
            .name = "f",
            .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "nope" } } }},
        }},
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{});
    defer result.deinit();
    try testing.expect(result.hasErrors());
    const key = result.model.plugins[0].forms[0].keys[0];
    try testing.expect(key.value == .unresolved_named);
}

test "lowering: deterministic plugin and form ordering matches declaration" {
    const a = testing.allocator;
    const p: Plugin.Plugin = .{
        .name = "x",
        .forms = &.{
            .{ .name = "alpha" },
            .{ .name = "beta" },
            .{ .name = "gamma" },
        },
    };
    const schema = Schema.Schema.init(&.{p});
    var result = try exportSchema(a, schema, .{});
    defer result.deinit();
    const forms = result.model.plugins[0].forms;
    try testing.expectEqualStrings("alpha", forms[0].name);
    try testing.expectEqualStrings("beta", forms[1].name);
    try testing.expectEqualStrings("gamma", forms[2].name);
}

test {
    _ = Discriminators;
    _ = Warnings;
    _ = Model;
    _ = JsonSchema;
    _ = TsTypes;
}
