const std = @import("std");
const Plugin = @import("Plugin.zig");
const Ast = @import("Ast.zig");

const Allocator = std.mem.Allocator;

pub const Schema = struct {
    plugins: []const Plugin.Plugin,

    pub fn init(plugins: []const Plugin.Plugin) Schema {
        const self: Schema = .{ .plugins = plugins };
        self.assertFormKeyCaps();
        return self;
    }

    pub fn assertFormKeyCaps(self: Schema) void {
        for (self.plugins) |*p| {
            for (p.forms) |*f| {
                assertOneFormKeyCaps(p.name, f);
            }
        }
    }

    fn assertOneFormKeyCaps(plugin_name: []const u8, f: *const Plugin.FormSpec) void {
        if (f.keys.len > Plugin.MAX_FORM_KEYS) {
            std.debug.panic(
                "plugin '{s}' form '{s}' has {d} keys; Plugin.MAX_FORM_KEYS is {d}",
                .{ plugin_name, f.name, f.keys.len, Plugin.MAX_FORM_KEYS },
            );
        }
        for (f.keys) |*k| {
            for (k.local_forms) |*lf| assertOneFormKeyCaps(plugin_name, lf);
        }
        if (f.variants) |variants| {
            for (variants) |*v| {
                if (v.keys.len > Plugin.MAX_FORM_KEYS) {
                    std.debug.panic(
                        "plugin '{s}' form '{s}' variant '{s}' has {d} keys; Plugin.MAX_FORM_KEYS is {d}",
                        .{ plugin_name, f.name, v.when, v.keys.len, Plugin.MAX_FORM_KEYS },
                    );
                }
                for (v.keys) |*k| {
                    for (k.local_forms) |*lf| assertOneFormKeyCaps(plugin_name, lf);
                }
            }
        }
    }

    pub fn hasPlugin(self: Schema, ns: []const u8) bool {
        for (self.plugins) |*p| {
            if (std.mem.eql(u8, p.name, ns)) return true;
        }
        return false;
    }

    pub fn lookupForm(
        self: Schema,
        name: []const u8,
        namespace: ?[]const u8,
    ) FormLookup {
        if (namespace) |ns| {
            for (self.plugins) |*p| {
                if (!std.mem.eql(u8, p.name, ns)) continue;
                for (p.forms) |*f| {
                    if (std.mem.eql(u8, f.name, name)) {
                        return .{ .found = .{ .plugin = p, .form = f } };
                    }
                }
                return .not_found;
            }
            return .not_found;
        }
        var first: ?FormHit = null;
        var amb: Ambiguous = .{ .buf = undefined, .len = 0 };
        for (self.plugins) |*p| {
            for (p.forms) |*f| {
                if (!std.mem.eql(u8, f.name, name)) continue;
                if (first == null) {
                    first = .{ .plugin = p, .form = f };
                } else {
                    if (amb.len == 0) {
                        amb.buf[0] = first.?.plugin;
                        amb.len = 1;
                    }
                    if (amb.len < amb.buf.len) {
                        amb.buf[amb.len] = p;
                        amb.len += 1;
                    }
                }
                break;
            }
        }
        if (amb.len > 0) return .{ .ambiguous = amb };
        if (first) |h| return .{ .found = h };
        return .not_found;
    }

    pub fn lookupExprFunc(
        self: Schema,
        name: []const u8,
        namespace: ?[]const u8,
    ) ExprLookup {
        if (namespace) |ns| {
            for (self.plugins) |*p| {
                if (!std.mem.eql(u8, p.name, ns)) continue;
                for (p.expr_funcs) |*f| {
                    if (std.mem.eql(u8, f.name, name)) {
                        return .{ .found = .{ .plugin = p, .func = f } };
                    }
                }
                return .not_found;
            }
            return .not_found;
        }
        var first: ?ExprHit = null;
        var amb: Ambiguous = .{ .buf = undefined, .len = 0 };
        for (self.plugins) |*p| {
            for (p.expr_funcs) |*f| {
                if (!std.mem.eql(u8, f.name, name)) continue;
                if (first == null) {
                    first = .{ .plugin = p, .func = f };
                } else {
                    if (amb.len == 0) {
                        amb.buf[0] = first.?.plugin;
                        amb.len = 1;
                    }
                    if (amb.len < amb.buf.len) {
                        amb.buf[amb.len] = p;
                        amb.len += 1;
                    }
                }
                break;
            }
        }
        if (amb.len > 0) return .{ .ambiguous = amb };
        if (first) |h| return .{ .found = h };
        return .not_found;
    }

    pub fn validateCrossRefs(
        self: Schema,
        a: Allocator,
    ) Allocator.Error![]const Ast.Diagnostic {
        var diags: std.ArrayList(Ast.Diagnostic) = .empty;
        for (self.plugins) |*plugin| {
            for (plugin.value_kinds) |*kind| {
                const cr = kind.cross_ref orelse continue;
                try checkCrossRef(self, a, &diags, plugin, kind, cr);
            }
        }
        return diags.toOwnedSlice(a);
    }

    pub fn validateUnions(
        self: Schema,
        a: Allocator,
    ) Allocator.Error![]const Ast.Diagnostic {
        var diags: std.ArrayList(Ast.Diagnostic) = .empty;
        for (self.plugins) |*plugin| {
            for (plugin.value_kinds) |*kind| {
                const us = kind.union_of orelse continue;
                try checkUnion(self, a, &diags, plugin, kind, us);
            }
        }
        return diags.toOwnedSlice(a);
    }

    pub fn validateForms(
        self: Schema,
        a: Allocator,
    ) Allocator.Error![]const Ast.Diagnostic {
        var diags: std.ArrayList(Ast.Diagnostic) = .empty;
        for (self.plugins) |*plugin| {
            for (plugin.forms) |*form| {
                if (form.discriminant_idx == null) continue;
                try checkForm(self, a, &diags, plugin, form);
            }
        }
        return diags.toOwnedSlice(a);
    }

    pub fn validateLowering(
        self: Schema,
        a: Allocator,
    ) Allocator.Error![]const Ast.Diagnostic {
        var diags: std.ArrayList(Ast.Diagnostic) = .empty;
        for (self.plugins) |*plugin| {
            for (plugin.forms) |*form| {
                const low = form.lowering orelse continue;
                try checkLowering(self, a, &diags, plugin, form, low);
            }
        }
        try checkLoweringCycles(self, a, &diags);
        return diags.toOwnedSlice(a);
    }

    pub fn validateDefaults(
        self: Schema,
        a: Allocator,
    ) Allocator.Error![]const Ast.Diagnostic {
        var diags: std.ArrayList(Ast.Diagnostic) = .empty;
        for (self.plugins) |*plugin| {
            for (plugin.forms) |*form| {
                for (form.keys) |*key| {
                    const dflt = key.default orelse continue;
                    if (dflt != .expression) continue;
                    try checkDefaultExpression(self, a, &diags, plugin, form, key, dflt.expression);
                }
            }
        }
        return diags.toOwnedSlice(a);
    }

    pub fn lookupValueKind(
        self: Schema,
        name: []const u8,
        namespace: ?[]const u8,
    ) ValueKindLookup {
        if (namespace) |ns| {
            for (self.plugins) |*p| {
                if (!std.mem.eql(u8, p.name, ns)) continue;
                for (p.value_kinds) |*v| {
                    if (std.mem.eql(u8, v.name, name)) return .{ .found = v };
                }
                return .not_found;
            }
            return .not_found;
        }
        var first: ?*const Plugin.ValueKind = null;
        var first_plugin: ?*const Plugin.Plugin = null;
        var amb: Ambiguous = .{ .buf = undefined, .len = 0 };
        for (self.plugins) |*p| {
            for (p.value_kinds) |*v| {
                if (!std.mem.eql(u8, v.name, name)) continue;
                if (first == null) {
                    first = v;
                    first_plugin = p;
                } else {
                    if (amb.len == 0) {
                        amb.buf[0] = first_plugin.?;
                        amb.len = 1;
                    }
                    if (amb.len < amb.buf.len) {
                        amb.buf[amb.len] = p;
                        amb.len += 1;
                    }
                }
                break;
            }
        }
        if (amb.len > 0) return .{ .ambiguous = amb };
        if (first) |v| return .{ .found = v };
        return .not_found;
    }
};

pub const Resolved = struct {
    positional: []const Ast.NodeIndex,
    signature: ?Plugin.ExprFunc.Signature = null,
};

pub const ResolveError = union(enum) {
    mixed: struct { span: Ast.Span },
    labels_not_supported: struct { span: Ast.Span, key: []const u8 },
    unknown_label: struct { span: Ast.Span, key: []const u8 },
    duplicate_label: struct { span: Ast.Span, key: []const u8 },
    missing_label: struct { name: []const u8 },
};

pub const ResolveResult = union(enum) {
    ok: Resolved,
    err: ResolveError,
};

pub fn resolveExprArgs(
    a: Allocator,
    func: Plugin.ExprFunc,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
) Allocator.Error!ResolveResult {
    var n_kv: usize = 0;
    var first_kv_span: Ast.Span = .{ .start = 0, .end = 0 };
    var first_kv_key: []const u8 = "";
    for (hdr.children) |c| {
        if (tree.tagOf(c) == .kvpair) {
            if (n_kv == 0) {
                const kvh = tree.kvpairHeader(c);
                first_kv_span = kvh.key_span;
                first_kv_key = kvh.key;
            }
            n_kv += 1;
        }
    }
    const n_pos = hdr.children.len - n_kv;

    if (n_kv == 0) {
        return .{ .ok = .{ .positional = hdr.children, .signature = null } };
    }
    if (n_pos != 0) {
        return .{ .err = .{ .mixed = .{ .span = first_kv_span } } };
    }

    var any_labeled = false;
    var sigs_it = func.signatureIter();
    while (sigs_it.next()) |sig| {
        if (!sig.labeledEnabled()) continue;
        any_labeled = true;
        if (matchSignatureLabels(sig, tree, hdr)) {
            return try buildLabeledPositional(a, sig, tree, hdr);
        }
    }

    if (!any_labeled) {
        return .{ .err = .{ .labels_not_supported = .{
            .span = first_kv_span,
            .key = first_kv_key,
        } } };
    }

    return diagnoseLabelMismatch(func, tree, hdr);
}

fn matchSignatureLabels(
    sig: Plugin.ExprFunc.Signature,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
) bool {
    const names = sig.param_names orelse return false;
    if (hdr.children.len != names.len) return false;
    var seen: u32 = 0;
    for (hdr.children) |c| {
        const kvh = tree.kvpairHeader(c);
        const idx = sig.indexOfLabel(kvh.key) orelse return false;
        const bit: u32 = @as(u32, 1) << @intCast(idx);
        if (seen & bit != 0) return false;
        seen |= bit;
    }
    const all: u32 = if (names.len == 32) 0xFFFF_FFFF else (@as(u32, 1) << @intCast(names.len)) - 1;
    return seen == all;
}

fn buildLabeledPositional(
    a: Allocator,
    sig: Plugin.ExprFunc.Signature,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
) Allocator.Error!ResolveResult {
    const names = sig.param_names.?;
    const out = try a.alloc(Ast.NodeIndex, names.len);
    for (hdr.children) |c| {
        const kvh = tree.kvpairHeader(c);
        const idx = sig.indexOfLabel(kvh.key).?;
        out[idx] = kvh.value;
    }
    return .{ .ok = .{ .positional = out, .signature = sig } };
}

fn diagnoseLabelMismatch(
    func: Plugin.ExprFunc,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
) ResolveResult {
    for (hdr.children, 0..) |c, i| {
        const kvh = tree.kvpairHeader(c);
        for (hdr.children[i + 1 ..]) |d| {
            const kvd = tree.kvpairHeader(d);
            if (std.mem.eql(u8, kvh.key, kvd.key)) {
                return .{ .err = .{ .duplicate_label = .{
                    .span = kvd.key_span,
                    .key = kvd.key,
                } } };
            }
        }
    }
    for (hdr.children) |c| {
        const kvh = tree.kvpairHeader(c);
        if (!labelKnownInAnyLabeledSig(func, kvh.key)) {
            return .{ .err = .{ .unknown_label = .{
                .span = kvh.key_span,
                .key = kvh.key,
            } } };
        }
    }
    var sigs_it = func.signatureIter();
    while (sigs_it.next()) |sig| {
        if (!sig.labeledEnabled()) continue;
        const names = sig.param_names.?;
        for (names) |n| {
            if (!callHasLabel(tree, hdr, n)) {
                return .{ .err = .{ .missing_label = .{ .name = n } } };
            }
        }
    }
    return .{ .err = .{ .missing_label = .{ .name = "" } } };
}

fn labelKnownInAnyLabeledSig(func: Plugin.ExprFunc, name: []const u8) bool {
    var it = func.signatureIter();
    while (it.next()) |sig| {
        if (!sig.labeledEnabled()) continue;
        if (sig.indexOfLabel(name) != null) return true;
    }
    return false;
}

fn callHasLabel(tree: *const Ast.Tree, hdr: Ast.FormHeader, name: []const u8) bool {
    for (hdr.children) |c| {
        const kvh = tree.kvpairHeader(c);
        if (std.mem.eql(u8, kvh.key, name)) return true;
    }
    return false;
}

fn checkCrossRef(
    schema: Schema,
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    plugin: *const Plugin.Plugin,
    kind: *const Plugin.ValueKind,
    cr: Plugin.ValueKind.CrossRef,
) Allocator.Error!void {
    var target_ns: ?[]const u8 = null;
    var target_name: []const u8 = cr.target_form;
    if (std.mem.indexOfScalar(u8, cr.target_form, '/')) |slash| {
        target_ns = cr.target_form[0..slash];
        target_name = cr.target_form[slash + 1 ..];
    }
    switch (schema.lookupForm(target_name, target_ns)) {
        .not_found => {
            try diags.append(a, .{
                .span = .{ .start = 0, .end = 0 },
                .message = try std.fmt.allocPrint(
                    a,
                    "value-kind `{s}` cross-ref `:target {s}` does not resolve to any form",
                    .{ kind.name, cr.target_form },
                ),
                .severity = .err,
                .code = .unknown_cross_ref_target,
                .path = try aggregatePath(a, plugin.name, kind.name),
            });
        },
        .ambiguous => |amb| {
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendSlice(a, "value-kind `");
            try buf.appendSlice(a, kind.name);
            try buf.appendSlice(a, "` cross-ref `:target ");
            try buf.appendSlice(a, cr.target_form);
            try buf.appendSlice(a, "` is ambiguous — defined by [");
            for (amb.slice(), 0..) |p, i| {
                if (i > 0) try buf.appendSlice(a, ", ");
                try buf.appendSlice(a, p.name);
            }
            try buf.appendSlice(a, "]; qualify with `<ns>/");
            try buf.appendSlice(a, target_name);
            try buf.appendSlice(a, "`");
            try diags.append(a, .{
                .span = .{ .start = 0, .end = 0 },
                .message = try buf.toOwnedSlice(a),
                .severity = .err,
                .code = .ambiguous_cross_ref_target,
                .path = try aggregatePath(a, plugin.name, kind.name),
            });
        },
        .found => |hit| {
            var found_key = false;
            var symbol_typed = false;
            for (hit.form.keys) |k| {
                if (!std.mem.eql(u8, k.name, cr.name_key)) continue;
                found_key = true;
                symbol_typed = isSymbolValueType(schema, k.value_type);
                break;
            }
            if (!found_key or !symbol_typed) {
                try diags.append(a, .{
                    .span = .{ .start = 0, .end = 0 },
                    .message = try std.fmt.allocPrint(
                        a,
                        "value-kind `{s}` cross-ref `:name-key {s}` is not a symbol-typed key on form `{s}`",
                        .{ kind.name, cr.name_key, target_name },
                    ),
                    .severity = .err,
                    .code = .cross_ref_name_key_unknown,
                    .path = try aggregatePath(a, plugin.name, kind.name),
                });
            }
            if (cr.acyclic) {
                var has_self_edge = false;
                for (hit.form.keys) |k| {
                    if (selfEdgeShape(schema, k.value_type, kind.name) != null) {
                        has_self_edge = true;
                        break;
                    }
                }
                if (!has_self_edge) {
                    if (hit.form.variants) |vs| {
                        outer: for (vs) |v| {
                            for (v.keys) |k| {
                                if (selfEdgeShape(schema, k.value_type, kind.name) != null) {
                                    has_self_edge = true;
                                    break :outer;
                                }
                            }
                        }
                    }
                }
                if (!has_self_edge) {
                    try diags.append(a, .{
                        .span = .{ .start = 0, .end = 0 },
                        .message = try std.fmt.allocPrint(
                            a,
                            "value-kind `{s}` declares `:acyclic true` but form `{s}` has no key whose type resolves to `{s}` — the cycle check has no edges to follow",
                            .{ kind.name, target_name, kind.name },
                        ),
                        .severity = .err,
                        .code = .acyclic_without_self_edge,
                        .path = try aggregatePath(a, plugin.name, kind.name),
                    });
                }
            }
        },
    }

    if (cr.scope_form) |sf| {
        var scope_ns: ?[]const u8 = null;
        var scope_name: []const u8 = sf;
        if (std.mem.indexOfScalar(u8, sf, '/')) |slash| {
            scope_ns = sf[0..slash];
            scope_name = sf[slash + 1 ..];
        }
        switch (schema.lookupForm(scope_name, scope_ns)) {
            .not_found => {
                try diags.append(a, .{
                    .span = .{ .start = 0, .end = 0 },
                    .message = try std.fmt.allocPrint(
                        a,
                        "value-kind `{s}` cross-ref `:scope {s}` does not resolve to any form",
                        .{ kind.name, sf },
                    ),
                    .severity = .err,
                    .code = .unknown_cross_ref_scope,
                    .path = try aggregatePath(a, plugin.name, kind.name),
                });
            },
            .ambiguous => |amb| {
                var buf: std.ArrayList(u8) = .empty;
                try buf.appendSlice(a, "value-kind `");
                try buf.appendSlice(a, kind.name);
                try buf.appendSlice(a, "` cross-ref `:scope ");
                try buf.appendSlice(a, sf);
                try buf.appendSlice(a, "` is ambiguous — defined by [");
                for (amb.slice(), 0..) |p, i| {
                    if (i > 0) try buf.appendSlice(a, ", ");
                    try buf.appendSlice(a, p.name);
                }
                try buf.appendSlice(a, "]; qualify with `<ns>/");
                try buf.appendSlice(a, scope_name);
                try buf.appendSlice(a, "`");
                try diags.append(a, .{
                    .span = .{ .start = 0, .end = 0 },
                    .message = try buf.toOwnedSlice(a),
                    .severity = .err,
                    .code = .ambiguous_cross_ref_scope,
                    .path = try aggregatePath(a, plugin.name, kind.name),
                });
            },
            .found => {},
        }
    }
}

fn aggregatePath(
    a: Allocator,
    plugin_name: []const u8,
    kind_name: []const u8,
) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, 3);
    out[0] = try a.dupe(u8, plugin_name);
    out[1] = try a.dupe(u8, kind_name);
    out[2] = try a.dupe(u8, "cross-ref");
    return out;
}

fn unionAggregatePath(
    a: Allocator,
    plugin_name: []const u8,
    kind_name: []const u8,
) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, 3);
    out[0] = try a.dupe(u8, plugin_name);
    out[1] = try a.dupe(u8, kind_name);
    out[2] = try a.dupe(u8, "union");
    return out;
}

fn checkUnion(
    schema: Schema,
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    plugin: *const Plugin.Plugin,
    kind: *const Plugin.ValueKind,
    us: Plugin.ValueKind.UnionShape,
) Allocator.Error!void {
    for (us.alternatives) |alt| {
        if (alt.name.len <= 7 and isPrimitiveTypeName(alt.name)) continue;
        switch (schema.lookupValueKind(alt.name, alt.namespace)) {
            .not_found => {
                try diags.append(a, .{
                    .span = .{ .start = 0, .end = 0 },
                    .message = try std.fmt.allocPrint(
                        a,
                        "value-kind `{s}` `:union` alternative `{s}` does not resolve to any value-kind",
                        .{ kind.name, alt.name },
                    ),
                    .severity = .err,
                    .code = .unknown_element_kind,
                    .path = try unionAggregatePath(a, plugin.name, kind.name),
                });
            },
            .ambiguous => |amb| {
                var buf: std.ArrayList(u8) = .empty;
                try buf.appendSlice(a, "value-kind `");
                try buf.appendSlice(a, kind.name);
                try buf.appendSlice(a, "` `:union` alternative `");
                try buf.appendSlice(a, alt.name);
                try buf.appendSlice(a, "` is ambiguous — defined by [");
                const claimants = amb.slice();
                for (claimants, 0..) |p, i| {
                    if (i > 0) try buf.appendSlice(a, ", ");
                    try buf.appendSlice(a, p.name);
                }
                try buf.appendSlice(a, "]");
                if (claimants.len > 0) {
                    try buf.appendSlice(a, "; qualify with `");
                    try buf.appendSlice(a, claimants[0].name);
                    try buf.appendSlice(a, "/");
                    try buf.appendSlice(a, alt.name);
                    try buf.appendSlice(a, "`");
                }
                try diags.append(a, .{
                    .span = .{ .start = 0, .end = 0 },
                    .message = try buf.toOwnedSlice(a),
                    .severity = .err,
                    .code = .ambiguous_element_kind,
                    .path = try unionAggregatePath(a, plugin.name, kind.name),
                });
            },
            .found => |alt_kind| {
                if (alt_kind.underlying == .union_of) {
                    try diags.append(a, .{
                        .span = .{ .start = 0, .end = 0 },
                        .message = try std.fmt.allocPrint(
                            a,
                            "value-kind `{s}` `:union` alternative `{s}` is itself a union — nesting is not allowed",
                            .{ kind.name, alt.name },
                        ),
                        .severity = .err,
                        .code = .nested_union,
                        .path = try unionAggregatePath(a, plugin.name, kind.name),
                    });
                }
            },
        }
    }
}

fn formAggregatePath(
    a: Allocator,
    plugin_name: []const u8,
    form_name: []const u8,
    leaf: []const u8,
) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, 3);
    out[0] = try a.dupe(u8, plugin_name);
    out[1] = try a.dupe(u8, form_name);
    out[2] = try a.dupe(u8, leaf);
    return out;
}

fn resolveDiscriminantMembers(
    schema: Schema,
    vt: Plugin.ValueType,
) ?[]const Plugin.ValueKind.MemberSet.Member {
    return switch (vt) {
        .named => |ref| sub: {
            const kind = switch (schema.lookupValueKind(ref.name, ref.namespace)) {
                .found => |k| k,
                else => break :sub null,
            };
            if (kind.underlying != .symbol) break :sub null;
            const ms = kind.members orelse break :sub null;
            if (ms.members.len == 0) break :sub null;
            break :sub ms.members;
        },
        else => null,
    };
}

fn checkForm(
    schema: Schema,
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    plugin: *const Plugin.Plugin,
    form: *const Plugin.FormSpec,
) Allocator.Error!void {
    const idx = form.discriminant_idx.?;
    if (idx >= form.keys.len) return;
    const dkey = form.keys[idx];

    const members = resolveDiscriminantMembers(schema, dkey.value_type);
    if (members == null) {
        try diags.append(a, .{
            .span = .{ .start = 0, .end = 0 },
            .message = try std.fmt.allocPrint(
                a,
                "form `{s}` discriminant `:{s}` must resolve to a value-kind with `:underlying symbol` and a non-empty `:members` set",
                .{ form.name, dkey.name },
            ),
            .severity = .err,
            .code = .discriminant_not_closed_enum,
            .path = try formAggregatePath(a, plugin.name, form.name, "discriminant"),
        });
        return;
    }
    const ms = members.?;

    const variants = form.variants orelse &.{};
    for (variants) |v| {
        var found = false;
        for (ms) |m| {
            if (std.mem.eql(u8, v.when, m.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try diags.append(a, .{
                .span = .{ .start = 0, .end = 0 },
                .message = try std.fmt.allocPrint(
                    a,
                    "form `{s}` variant `:when {s}` is not a member of discriminant `:{s}`",
                    .{ form.name, v.when, dkey.name },
                ),
                .severity = .err,
                .code = .unknown_discriminant_value,
                .path = try formAggregatePath(a, plugin.name, form.name, "variant"),
            });
        }
    }

    for (variants, 0..) |v, vi| {
        for (v.keys) |vk| {
            for (form.keys) |ck| {
                if (std.mem.eql(u8, vk.name, ck.name)) {
                    try diags.append(a, .{
                        .span = .{ .start = 0, .end = 0 },
                        .message = try std.fmt.allocPrint(
                            a,
                            "form `{s}` variant `:when {s}` redeclares key `:{s}` (also in common keys)",
                            .{ form.name, v.when, vk.name },
                        ),
                        .severity = .err,
                        .code = .variant_key_collision,
                        .path = try formAggregatePath(a, plugin.name, form.name, "variant"),
                    });
                }
            }
            for (variants[0..vi]) |prior| {
                for (prior.keys) |pk| {
                    if (std.mem.eql(u8, vk.name, pk.name)) {
                        try diags.append(a, .{
                            .span = .{ .start = 0, .end = 0 },
                            .message = try std.fmt.allocPrint(
                                a,
                                "form `{s}` variant `:when {s}` redeclares key `:{s}` (also in variant `:when {s}`)",
                                .{ form.name, v.when, vk.name, prior.when },
                            ),
                            .severity = .err,
                            .code = .variant_key_collision,
                            .path = try formAggregatePath(a, plugin.name, form.name, "variant"),
                        });
                    }
                }
            }
        }
    }
}

fn checkDefaultExpression(
    schema: Schema,
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    plugin: *const Plugin.Plugin,
    form: *const Plugin.FormSpec,
    key: *const Plugin.KeySpec,
    expr: Plugin.KeySpec.Default.Expression,
) Allocator.Error!void {
    const Validator = @import("Validator.zig");
    const resolution = Validator.resolveFormExpressionBinary(schema, expr.head, expr.namespace, expr.arg_count);
    switch (resolution) {
        .unresolved => return,
        .data_form => {
            try diags.append(a, .{
                .span = .{ .start = 0, .end = 0 },
                .message = try std.fmt.allocPrint(
                    a,
                    "default for `:{s}` resolves to data form `{s}`; computed defaults must be expression forms",
                    .{ key.name, expr.head },
                ),
                .severity = .err,
                .code = .wrong_underlying,
                .path = try keyAggregatePath(a, plugin.name, form.name, key.name, "default"),
            });
        },
        .expr => |e| {
            const declared = e.result orelse return;
            switch (Validator.declaredResultMatchesExpected(schema, declared, key.value_type)) {
                .yes, .unknown => {},
                .no => {
                    try diags.append(a, .{
                        .span = .{ .start = 0, .end = 0 },
                        .message = try std.fmt.allocPrint(
                            a,
                            "default for `:{s}` expects {s}, expression head `{s}` declares result {s}",
                            .{
                                key.name,
                                Validator.typeLabel(key.value_type),
                                expr.head,
                                Validator.typeLabel(declared),
                            },
                        ),
                        .severity = .err,
                        .code = .wrong_underlying,
                        .path = try keyAggregatePath(a, plugin.name, form.name, key.name, "default"),
                    });
                },
            }
        },
    }
}

fn keyAggregatePath(
    a: Allocator,
    plugin_name: []const u8,
    form_name: []const u8,
    key_name: []const u8,
    leaf: []const u8,
) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, 4);
    out[0] = try a.dupe(u8, plugin_name);
    out[1] = try a.dupe(u8, form_name);
    out[2] = try a.dupe(u8, key_name);
    out[3] = try a.dupe(u8, leaf);
    return out;
}

fn checkLowering(
    schema: Schema,
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    plugin: *const Plugin.Plugin,
    form: *const Plugin.FormSpec,
    low: Plugin.LoweringSpec,
) Allocator.Error!void {
    for (low.produces) |head| {
        var head_ns: ?[]const u8 = null;
        var head_name: []const u8 = head;
        if (std.mem.indexOfScalar(u8, head, '/')) |slash| {
            head_ns = head[0..slash];
            head_name = head[slash + 1 ..];
        }
        switch (schema.lookupForm(head_name, head_ns)) {
            .not_found => {
                const absent_plugin = head_ns != null and !schema.hasPlugin(head_ns.?);
                try diags.append(a, .{
                    .span = .{ .start = 0, .end = 0 },
                    .message = if (absent_plugin) try std.fmt.allocPrint(
                        a,
                        "form `{s}` `:lowering` produces head `{s}` whose plugin `{s}` is not loaded",
                        .{ form.name, head, head_ns.? },
                    ) else try std.fmt.allocPrint(
                        a,
                        "form `{s}` `:lowering` produces head `{s}` does not resolve to any declared form",
                        .{ form.name, head },
                    ),
                    .severity = .err,
                    .code = if (absent_plugin) .lowering_target_plugin_absent else .unknown_form,
                    .path = try formAggregatePath(a, plugin.name, form.name, "lowering"),
                });
            },
            .ambiguous => |amb| {
                var buf: std.ArrayList(u8) = .empty;
                try buf.appendSlice(a, "form `");
                try buf.appendSlice(a, form.name);
                try buf.appendSlice(a, "` `:lowering` produces head `");
                try buf.appendSlice(a, head);
                try buf.appendSlice(a, "` is ambiguous — defined by [");
                for (amb.slice(), 0..) |p, i| {
                    if (i > 0) try buf.appendSlice(a, ", ");
                    try buf.appendSlice(a, p.name);
                }
                try buf.appendSlice(a, "]; qualify with `<ns>/");
                try buf.appendSlice(a, head_name);
                try buf.appendSlice(a, "`");
                try diags.append(a, .{
                    .span = .{ .start = 0, .end = 0 },
                    .message = try buf.toOwnedSlice(a),
                    .severity = .err,
                    .code = .ambiguous_form,
                    .path = try formAggregatePath(a, plugin.name, form.name, "lowering"),
                });
            },
            .found => {},
        }
    }
}

pub const LoweringGraphNode = struct {
    name: []const u8,
    plugin_name: []const u8,
    form_name: []const u8,
    edges: []const []const u8,
};

pub fn buildLoweringGraph(
    self: Schema,
    arena: Allocator,
) Allocator.Error![]const LoweringGraphNode {
    var nodes: std.ArrayList(LoweringGraphNode) = .empty;
    for (self.plugins) |*plugin| {
        for (plugin.forms) |*form| {
            const low = form.lowering orelse continue;
            var edges: std.ArrayList([]const u8) = .empty;
            for (low.produces) |head| {
                var head_ns: ?[]const u8 = null;
                var head_name: []const u8 = head;
                if (std.mem.indexOfScalar(u8, head, '/')) |slash| {
                    head_ns = head[0..slash];
                    head_name = head[slash + 1 ..];
                }
                switch (self.lookupForm(head_name, head_ns)) {
                    .found => |hit| try edges.append(
                        arena,
                        try std.fmt.allocPrint(arena, "{s}/{s}", .{ hit.plugin.name, hit.form.name }),
                    ),
                    else => {},
                }
            }
            try nodes.append(arena, .{
                .name = try std.fmt.allocPrint(arena, "{s}/{s}", .{ plugin.name, form.name }),
                .plugin_name = plugin.name,
                .form_name = form.name,
                .edges = try edges.toOwnedSlice(arena),
            });
        }
    }
    return nodes.toOwnedSlice(arena);
}

fn checkLoweringCycles(
    self: Schema,
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
) Allocator.Error!void {
    const Validator = @import("Validator.zig");

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const sa = arena.allocator();

    const nodes = try buildLoweringGraph(self, sa);
    if (nodes.len == 0) return;

    const Emit = struct {
        a: Allocator,
        diags: *std.ArrayList(Ast.Diagnostic),

        fn onCycle(
            self_e: @This(),
            ns: []const LoweringGraphNode,
            cycle: []const Validator.DfsFrame,
        ) Allocator.Error!void {
            const entry = ns[cycle[0].node_idx];
            var path_buf: std.ArrayList(u8) = .empty;
            defer path_buf.deinit(self_e.a);
            for (cycle, 0..) |sf, i| {
                if (i > 0) try path_buf.appendSlice(self_e.a, " -> ");
                try path_buf.appendSlice(self_e.a, ns[sf.node_idx].name);
            }
            try path_buf.appendSlice(self_e.a, " -> ");
            try path_buf.appendSlice(self_e.a, ns[cycle[0].node_idx].name);

            try self_e.diags.append(self_e.a, .{
                .span = .{ .start = 0, .end = 0 },
                .message = try std.fmt.allocPrint(
                    self_e.a,
                    "form `{s}` `:lowering` produces a cyclic lowering graph: `{s}`",
                    .{ entry.form_name, path_buf.items },
                ),
                .severity = .err,
                .code = .lowering_cycle,
                .path = try formAggregatePath(self_e.a, entry.plugin_name, entry.form_name, "lowering"),
            });
        }
    };

    try Validator.detectGraphCycles(LoweringGraphNode, a, nodes, Emit{
        .a = a,
        .diags = diags,
    }, Emit.onCycle);
}

fn isSymbolValueType(schema: Schema, vt: Plugin.ValueType) bool {
    return switch (vt) {
        .symbol, .any => true,
        .named => |ref| sub: {
            if (std.mem.eql(u8, ref.name, "symbol") or std.mem.eql(u8, ref.name, "any")) break :sub true;
            break :sub switch (schema.lookupValueKind(ref.name, ref.namespace)) {
                .found => |k| k.underlying == .symbol,
                else => false,
            };
        },
        else => false,
    };
}

pub const EdgeShape = enum { scalar, vector };

pub const AcyclicSpec = struct {
    kind_name: []const u8,
    target_form: []const u8,
    name_key: []const u8,
    scope_form: ?[]const u8,
    edges: []const EdgeKey,

    pub const EdgeKey = struct {
        name: []const u8,
        shape: EdgeShape,
    };
};

pub fn collectAcyclicSpecs(
    self: Schema,
    gpa: Allocator,
) Allocator.Error![]AcyclicSpec {
    var out: std.ArrayList(AcyclicSpec) = .empty;
    errdefer out.deinit(gpa);
    for (self.plugins) |*plugin| {
        for (plugin.value_kinds) |*kind| {
            const cr = kind.cross_ref orelse continue;
            if (!cr.acyclic) continue;
            var ns: ?[]const u8 = null;
            var name = cr.target_form;
            if (std.mem.indexOfScalar(u8, cr.target_form, '/')) |slash| {
                ns = cr.target_form[0..slash];
                name = cr.target_form[slash + 1 ..];
            }
            const form_hit = switch (self.lookupForm(name, ns)) {
                .found => |h| h,
                else => continue,
            };
            var edges: std.ArrayList(AcyclicSpec.EdgeKey) = .empty;
            errdefer edges.deinit(gpa);
            for (form_hit.form.keys) |k| {
                if (std.mem.eql(u8, k.name, cr.name_key)) continue;
                if (selfEdgeShape(self, k.value_type, kind.name)) |shape| {
                    try edges.append(gpa, .{ .name = k.name, .shape = shape });
                }
            }
            if (form_hit.form.variants) |vs| {
                for (vs) |v| {
                    for (v.keys) |k| {
                        if (std.mem.eql(u8, k.name, cr.name_key)) continue;
                        if (selfEdgeShape(self, k.value_type, kind.name)) |shape| {
                            try edges.append(gpa, .{ .name = k.name, .shape = shape });
                        }
                    }
                }
            }
            if (edges.items.len == 0) {
                edges.deinit(gpa);
                continue;
            }
            const canonical = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ form_hit.plugin.name, form_hit.form.name });
            errdefer gpa.free(canonical);

            var scope_canonical: ?[]const u8 = null;
            if (cr.scope_form) |sf| {
                var sns: ?[]const u8 = null;
                var snm: []const u8 = sf;
                if (std.mem.indexOfScalar(u8, sf, '/')) |slash| {
                    sns = sf[0..slash];
                    snm = sf[slash + 1 ..];
                }
                if (self.lookupForm(snm, sns) == .found) {
                    const sh = self.lookupForm(snm, sns).found;
                    scope_canonical = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ sh.plugin.name, sh.form.name });
                }
            }
            errdefer if (scope_canonical) |sc| gpa.free(sc);

            try out.append(gpa, .{
                .kind_name = kind.name,
                .target_form = canonical,
                .name_key = cr.name_key,
                .scope_form = scope_canonical,
                .edges = try edges.toOwnedSlice(gpa),
            });
        }
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeAcyclicSpecs(gpa: Allocator, specs: []AcyclicSpec) void {
    for (specs) |s| {
        gpa.free(s.target_form);
        if (s.scope_form) |sf| gpa.free(sf);
        gpa.free(s.edges);
    }
    gpa.free(specs);
}

fn selfEdgeShape(
    schema: Schema,
    vt: Plugin.ValueType,
    target_kind: []const u8,
) ?EdgeShape {
    var current = vt;
    var saw_vector = false;
    var depth: u8 = 0;
    while (depth < MAX_KIND_DEPTH) : (depth += 1) {
        const ref = switch (current) {
            .named => |n| n,
            else => return null,
        };
        if (std.mem.eql(u8, ref.name, target_kind)) {
            return if (saw_vector) .vector else .scalar;
        }
        if (ref.name.len <= 7 and isPrimitiveTypeName(ref.name)) return null;
        const vk = switch (schema.lookupValueKind(ref.name, ref.namespace)) {
            .found => |k| k,
            else => return null,
        };
        if (vk.vector) |vs| {
            if (saw_vector) return null;
            saw_vector = true;
            if (std.mem.eql(u8, vs.element.name, target_kind)) return .vector;
            if (vs.element.name.len <= 7 and isPrimitiveTypeName(vs.element.name)) return null;
            current = .{ .named = vs.element };
            continue;
        }
        return null;
    }
    return null;
}

fn isPrimitiveTypeName(name: []const u8) bool {
    const primitives = [_][]const u8{
        "any",     "number", "string", "symbol",
        "boolean", "nil",    "vector", "form",
        "expr",
    };
    for (primitives) |p| {
        if (std.mem.eql(u8, name, p)) return true;
    }
    return false;
}

pub const MAX_AMBIGUOUS: usize = 16;

pub const MAX_KIND_DEPTH: u8 = 8;

pub const FormHit = struct {
    plugin: *const Plugin.Plugin,
    form: *const Plugin.FormSpec,
};

pub const ExprHit = struct {
    plugin: *const Plugin.Plugin,
    func: *const Plugin.ExprFunc,
};

pub const Ambiguous = struct {
    buf: [MAX_AMBIGUOUS]*const Plugin.Plugin,
    len: u8,

    pub fn slice(self: *const Ambiguous) []const *const Plugin.Plugin {
        return self.buf[0..self.len];
    }
};

pub fn LookupResult(comptime Hit: type) type {
    return union(enum) {
        found: Hit,
        not_found,
        ambiguous: Ambiguous,
    };
}

pub const FormLookup = LookupResult(FormHit);

pub const ExprLookup = LookupResult(ExprHit);

pub const ValueKindLookup = LookupResult(*const Plugin.ValueKind);

const testing = std.testing;
const core = @import("plugins/core.zig");

fn freeDiagnostics(a: std.mem.Allocator, diags: []const Ast.Diagnostic) void {
    for (diags) |d| {
        a.free(d.message);
        for (d.path) |s| a.free(s);
        a.free(d.path);
    }
    a.free(diags);
}

const expr_pi: Plugin.ExprFunc = .{
    .name = "pi",
    .arity = .{ .fixed = 0 },
    .result = .number,
};
const expr_pi_string: Plugin.ExprFunc = .{
    .name = "pi-str",
    .arity = .{ .fixed = 0 },
    .result = .string,
};
const expr_opaque: Plugin.ExprFunc = .{
    .name = "let",
    .arity = .{ .at_least = 1 },
    .result = null,
};
