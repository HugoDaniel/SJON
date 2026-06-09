const std = @import("std");
const Ast = @import("Ast.zig");
const Binary = @import("Binary.zig");
const Plugin = @import("Plugin.zig");
const Validator = @import("Validator.zig");
const Schema = @import("Schema.zig");
const MetaSchema = @import("MetaSchema.zig");
const StringFormats = @import("StringFormats.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
    NotAPluginManifest,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    plugin: Plugin.Plugin,
    diagnostics: []const Ast.Diagnostic,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const Result) bool {
        for (self.diagnostics) |d| if (d.severity == .err) return true;
        return false;
    }
};

pub fn load(gpa: Allocator, tree: Ast.Tree) Error!Result {
    var v = Validator.validate(gpa, tree, MetaSchema.schema) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
    };
    defer v.deinit();

    if (v.hasErrors()) {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const owned_diags = try copyDiagnostics(arena.allocator(), v.diagnostics);
        return Result{
            .arena = arena,
            .plugin = .{ .name = "" },
            .diagnostics = owned_diags,
        };
    }

    return loadUnchecked(gpa, tree);
}

pub fn loadUnchecked(gpa: Allocator, tree: Ast.Tree) Error!Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    if (tree.root.len != 1) return Error.NotAPluginManifest;
    const root = tree.root[0];
    if (tree.tagOf(root) != .form) return Error.NotAPluginManifest;
    const hdr = tree.formHeader(root);
    if (!std.mem.eql(u8, hdr.head, "plugin")) return Error.NotAPluginManifest;

    var diags: std.ArrayList(Ast.Diagnostic) = .empty;
    const plugin = try buildPlugin(a, &tree, hdr, &diags);

    return Result{
        .arena = arena,
        .plugin = plugin,
        .diagnostics = try diags.toOwnedSlice(a),
    };
}

fn copyDiagnostics(a: Allocator, src: []const Ast.Diagnostic) Allocator.Error![]const Ast.Diagnostic {
    const out = try a.alloc(Ast.Diagnostic, src.len);
    for (src, 0..) |d, i| {
        const path = try a.alloc([]const u8, d.path.len);
        for (d.path, 0..) |step, j| path[j] = try a.dupe(u8, step);
        out[i] = .{
            .span = d.span,
            .message = try a.dupe(u8, d.message),
            .severity = d.severity,
            .code = d.code,
            .path = path,
        };
    }
    return out;
}

fn buildPlugin(
    a: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.Plugin {
    var name: []const u8 = "";
    var version: []const u8 = "";
    var wasm_file: ?[]const u8 = null;
    var wasm_sha256: ?[]const u8 = null;
    var authors: []const []const u8 = &.{};
    var license: []const u8 = "";
    var homepage: []const u8 = "";
    var repository: []const u8 = "";
    var keywords: []const []const u8 = &.{};
    var sjon_format: []const u8 = "";

    var forms = std.ArrayList(Plugin.FormSpec).empty;
    var expr_funcs = std.ArrayList(Plugin.ExprFunc).empty;
    var value_kinds = std.ArrayList(Plugin.ValueKind).empty;

    for (hdr.children) |ci| {
        switch (tree.tagOf(ci)) {
            .kvpair => {
                const kv = tree.kvpairHeader(ci);
                if (std.mem.eql(u8, kv.key, "name")) {
                    name = try a.dupe(u8, tree.symbolText(kv.value));
                } else if (std.mem.eql(u8, kv.key, "version")) {
                    if (tree.tagOf(kv.value) == .string) {
                        version = try a.dupe(u8, tree.stringText(kv.value));
                    }
                } else if (std.mem.eql(u8, kv.key, "wasm-file")) {
                    if (tree.tagOf(kv.value) == .string) {
                        wasm_file = try a.dupe(u8, tree.stringText(kv.value));
                    }
                } else if (std.mem.eql(u8, kv.key, "wasm-sha256")) {
                    if (tree.tagOf(kv.value) == .string) {
                        const pin = try a.dupe(u8, tree.stringText(kv.value));
                        if (!isWellFormedSha256Pin(pin)) {
                            try diags.append(a, .{
                                .span = tree.spanOf(kv.value),
                                .severity = .err,
                                .code = .plugin_wasm_self_hash_malformed,
                                .message = try std.fmt.allocPrint(
                                    a,
                                    ":wasm-sha256 must be `sha256-<64 lowercase hex chars>`; got `{s}`",
                                    .{pin},
                                ),
                                .path = try singletonPath(a, "plugin"),
                            });
                        }
                        wasm_sha256 = pin;
                    }
                } else if (std.mem.eql(u8, kv.key, "authors")) {
                    if (tree.tagOf(kv.value) == .vector) {
                        authors = try parseAuthorsList(a, tree, kv.value);
                    }
                } else if (std.mem.eql(u8, kv.key, "license")) {
                    if (tree.tagOf(kv.value) == .string) {
                        const lic = try a.dupe(u8, tree.stringText(kv.value));
                        if (!isRecognizedSpdx(lic)) {
                            try diags.append(a, .{
                                .span = tree.spanOf(kv.value),
                                .severity = .warning,
                                .code = .license_unrecognized,
                                .message = try std.fmt.allocPrint(
                                    a,
                                    ":license `{s}` is not a canonical SPDX identifier",
                                    .{lic},
                                ),
                                .path = try singletonPath(a, "plugin"),
                            });
                        }
                        license = lic;
                    }
                } else if (std.mem.eql(u8, kv.key, "homepage")) {
                    if (tree.tagOf(kv.value) == .string) {
                        homepage = try a.dupe(u8, tree.stringText(kv.value));
                    }
                } else if (std.mem.eql(u8, kv.key, "repository")) {
                    if (tree.tagOf(kv.value) == .string) {
                        repository = try a.dupe(u8, tree.stringText(kv.value));
                    }
                } else if (std.mem.eql(u8, kv.key, "keywords")) {
                    if (tree.tagOf(kv.value) == .vector) {
                        keywords = try parseSymbolList(a, tree, kv.value);
                        if (keywords.len > Plugin.MAX_KEYWORDS) {
                            try diags.append(a, .{
                                .span = tree.spanOf(kv.value),
                                .severity = .warning,
                                .code = .too_many_keywords,
                                .message = try std.fmt.allocPrint(
                                    a,
                                    ":keywords has {d} entries; advisory cap is {d}",
                                    .{ keywords.len, Plugin.MAX_KEYWORDS },
                                ),
                                .path = try singletonPath(a, "plugin"),
                            });
                        }
                    }
                } else if (std.mem.eql(u8, kv.key, "sjon")) {
                    if (tree.tagOf(kv.value) == .string) {
                        const decl = try a.dupe(u8, tree.stringText(kv.value));
                        if (compareSjonFormat(decl, Plugin.SUPPORTED_SJON_FORMAT) == .gt) {
                            try diags.append(a, .{
                                .span = tree.spanOf(kv.value),
                                .severity = .err,
                                .code = .sjon_format_unsupported,
                                .message = try std.fmt.allocPrint(
                                    a,
                                    "manifest declares `:sjon {s}` but host implements {s}",
                                    .{ decl, Plugin.SUPPORTED_SJON_FORMAT },
                                ),
                                .path = try singletonPath(a, "plugin"),
                            });
                        }
                        sjon_format = decl;
                    }
                }
            },
            .form => {
                const sub = tree.formHeader(ci);
                if (std.mem.eql(u8, sub.head, "value-kind")) {
                    try value_kinds.append(a, try buildValueKind(a, tree, sub, diags));
                } else if (std.mem.eql(u8, sub.head, "form")) {
                    try forms.append(a, try buildForm(a, tree, sub, diags, 1));
                } else if (std.mem.eql(u8, sub.head, "expr-func")) {
                    try expr_funcs.append(a, try buildExprFunc(a, tree, sub, diags));
                }
            },
            else => {},
        }
    }

    return .{
        .name = name,
        .version = version,
        .wasm_file = wasm_file,
        .wasm_sha256 = wasm_sha256,
        .authors = authors,
        .license = license,
        .homepage = homepage,
        .repository = repository,
        .keywords = keywords,
        .sjon_format = sjon_format,
        .forms = try forms.toOwnedSlice(a),
        .expr_funcs = try expr_funcs.toOwnedSlice(a),
        .value_kinds = try value_kinds.toOwnedSlice(a),
    };
}

fn parseAuthorsList(a: Allocator, tree: *const Ast.Tree, idx: Ast.NodeIndex) Error![]const []const u8 {
    const elements = tree.vectorElements(idx);
    const out = try a.alloc([]const u8, elements.len);
    for (elements, 0..) |ei, i| {
        out[i] = switch (tree.tagOf(ei)) {
            .string => try a.dupe(u8, tree.stringText(ei)),
            .symbol => try a.dupe(u8, tree.symbolText(ei)),
            else => try a.dupe(u8, ""),
        };
    }
    return out;
}

fn isWellFormedSha256Pin(pin: []const u8) bool {
    const prefix = "sha256-";
    const hex_len: usize = 64;
    if (pin.len != prefix.len + hex_len) return false;
    if (!std.mem.startsWith(u8, pin, prefix)) return false;
    for (pin[prefix.len..]) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return false;
    }
    return true;
}

fn isRecognizedSpdx(lic: []const u8) bool {
    const canonical = [_][]const u8{
        "MIT",           "Apache-2.0",        "BSD-2-Clause",  "BSD-3-Clause",
        "MPL-2.0",       "ISC",               "GPL-2.0-only",  "GPL-2.0-or-later",
        "GPL-3.0-only",  "GPL-3.0-or-later",  "LGPL-2.1-only", "LGPL-2.1-or-later",
        "LGPL-3.0-only", "LGPL-3.0-or-later", "AGPL-3.0-only", "AGPL-3.0-or-later",
        "Unlicense",     "CC0-1.0",           "0BSD",          "Zlib",
    };
    for (canonical) |c| {
        if (std.mem.eql(u8, c, lic)) return true;
    }
    return false;
}

fn compareSjonFormat(declared: []const u8, supported: []const u8) std.math.Order {
    const dv = parseSimpleVersion(declared) orelse return .eq;
    const sv = parseSimpleVersion(supported) orelse return .eq;
    if (dv.major != sv.major) return std.math.order(dv.major, sv.major);
    return std.math.order(dv.minor, sv.minor);
}

const SimpleVersion = struct { major: u32, minor: u32 };

fn parseSimpleVersion(s: []const u8) ?SimpleVersion {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse return null;
    const major = std.fmt.parseInt(u32, s[0..dot], 10) catch return null;
    const minor = std.fmt.parseInt(u32, s[dot + 1 ..], 10) catch return null;
    return .{ .major = major, .minor = minor };
}

fn singletonPath(a: Allocator, step: []const u8) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, 1);
    out[0] = try a.dupe(u8, step);
    return out;
}

fn buildValueKind(
    a: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.ValueKind {
    var kind: Plugin.ValueKind = .{ .name = "", .underlying = .symbol };
    var vector_idx: ?Ast.NodeIndex = null;
    var unit_idx: ?Ast.NodeIndex = null;
    var cross_ref_idx: ?Ast.NodeIndex = null;
    var union_idx: ?Ast.NodeIndex = null;
    var numeric_idx: ?Ast.NodeIndex = null;
    var string_bounds_idx: ?Ast.NodeIndex = null;
    var repr_idx: ?Ast.NodeIndex = null;
    var scalar_or_ref_idx: ?Ast.NodeIndex = null;
    var is_scalar_or_ref = false;

    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "name")) {
            kind.name = try a.dupe(u8, tree.symbolText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "underlying")) {
            if (std.mem.eql(u8, tree.symbolText(kv.value), "scalar-or-ref")) {
                is_scalar_or_ref = true;
            } else {
                kind.underlying = try parseUnderlying(tree, kv.value);
            }
        } else if (std.mem.eql(u8, kv.key, "description")) {
            kind.description = try a.dupe(u8, tree.stringText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "vector")) {
            vector_idx = kv.value;
        } else if (std.mem.eql(u8, kv.key, "unit")) {
            unit_idx = kv.value;
        } else if (std.mem.eql(u8, kv.key, "numeric")) {
            numeric_idx = kv.value;
        } else if (std.mem.eql(u8, kv.key, "string-bounds")) {
            string_bounds_idx = kv.value;
        } else if (std.mem.eql(u8, kv.key, "repr")) {
            repr_idx = kv.value;
        } else if (std.mem.eql(u8, kv.key, "scalar-or-ref")) {
            scalar_or_ref_idx = kv.value;
        } else if (std.mem.eql(u8, kv.key, "members")) {
            kind.members = try buildMemberSet(a, tree, kv.value, kind.name, diags);
        } else if (std.mem.eql(u8, kv.key, "heads")) {
            kind.heads = try buildHeadSet(a, tree, kv.value);
        } else if (std.mem.eql(u8, kv.key, "cross-ref")) {
            cross_ref_idx = kv.value;
        } else if (std.mem.eql(u8, kv.key, "union")) {
            union_idx = kv.value;
        }
    }

    if (vector_idx) |vi| {
        const vs = try buildVectorShape(a, tree, vi, kind.name, diags);
        try checkVectorShapeConsistency(a, tree, vi, kind, vs, diags);
        kind.vector = vs;
    }
    if (unit_idx) |ui| {
        const u = try buildUnitShape(a, tree, ui);
        try checkUnitShapeConsistency(a, tree, ui, kind, u, diags);
        kind.unit = u;
    }
    if (cross_ref_idx) |ci| {
        kind.cross_ref = try buildCrossRef(a, tree, ci, kind, diags);
    }
    if (numeric_idx) |ni| {
        const bounds = try buildNumericBounds(a, tree, ni);
        try checkNumericBoundsConsistency(a, tree, ni, kind, bounds, diags);
        kind.numeric = bounds;
    }
    if (string_bounds_idx) |si| {
        const sb = try buildStringBounds(a, tree, si);
        try checkStringBoundsConsistency(a, tree, si, kind, sb, diags);
        kind.string_bounds = sb;
    }
    if (repr_idx) |ri| {
        const r = try buildReprShape(tree, ri);
        try checkReprShapeConsistency(a, tree, ri, kind, diags);
        kind.repr = r;
    }
    if (union_idx) |ui| {
        kind.union_of = try buildUnionShape(a, tree, ui, kind, diags);
    } else if (kind.underlying == .union_of) {
        const message = try std.fmt.allocPrint(
            a,
            "value-kind `{s}` declares `:underlying union` but no `:union (union-shape …)` slot",
            .{kind.name},
        );
        try diags.append(a, .{
            .span = hdr.head_span,
            .message = message,
            .severity = .err,
            .code = .wrong_underlying,
            .path = try buildPath(a, &.{ kind.name, "union" }),
        });
    }
    if (is_scalar_or_ref) {
        if (scalar_or_ref_idx) |si| {
            kind.union_of = try buildScalarOrRefShape(a, tree, si);
            kind.underlying = .union_of;
        } else {
            try diags.append(a, .{
                .span = hdr.head_span,
                .message = try std.fmt.allocPrint(
                    a,
                    "value-kind `{s}` declares `:underlying scalar-or-ref` but no `:scalar-or-ref (scalar-or-ref-shape …)` slot",
                    .{kind.name},
                ),
                .severity = .err,
                .code = .invalid_manifest,
                .path = try buildPath(a, &.{ kind.name, "scalar-or-ref" }),
            });
        }
    } else if (scalar_or_ref_idx) |si| {
        try diags.append(a, .{
            .span = tree.spanOf(si),
            .message = try std.fmt.allocPrint(
                a,
                "value-kind `{s}` declares `:scalar-or-ref` but `:underlying` is `{s}`, not `scalar-or-ref`",
                .{ kind.name, @tagName(kind.underlying) },
            ),
            .severity = .err,
            .code = .invalid_manifest,
            .path = try buildPath(a, &.{ kind.name, "scalar-or-ref" }),
        });
    }
    return kind;
}

fn buildScalarOrRefShape(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) Error!Plugin.ValueKind.UnionShape {
    const hdr = tree.formHeader(idx);
    var base: ?Plugin.QualifiedRef = null;
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "base")) {
            base = try parseQualifiedRef(a, tree.symbolText(kv.value));
        }
    }
    const alts = if (base) |b| two: {
        const slice = try a.alloc(Plugin.QualifiedRef, 2);
        slice[0] = b;
        slice[1] = .{ .name = "symbol", .namespace = null };
        break :two slice;
    } else one: {
        const slice = try a.alloc(Plugin.QualifiedRef, 1);
        slice[0] = .{ .name = "symbol", .namespace = null };
        break :one slice;
    };
    return .{ .alternatives = alts };
}

fn buildForm(
    a: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    diags: *std.ArrayList(Ast.Diagnostic),
    depth: usize,
) Error!Plugin.FormSpec {
    var spec: Plugin.FormSpec = .{ .name = "" };
    var keys = std.ArrayList(Plugin.KeySpec).empty;
    var key_count: usize = 0;
    var variants = std.ArrayList(Plugin.Variant).empty;
    var groups = std.ArrayList(BuiltGroup).empty;
    var discriminant_span: ?Ast.Span = null;
    var lowering_idx: ?Ast.NodeIndex = null;

    for (hdr.children) |ci| {
        switch (tree.tagOf(ci)) {
            .kvpair => {
                const kv = tree.kvpairHeader(ci);
                if (std.mem.eql(u8, kv.key, "name")) {
                    spec.name = try a.dupe(u8, tree.symbolText(kv.value));
                } else if (std.mem.eql(u8, kv.key, "description")) {
                    spec.description = try a.dupe(u8, tree.stringText(kv.value));
                } else if (std.mem.eql(u8, kv.key, "open")) {
                    spec.open = (tree.tagOf(kv.value) == .boolean_true);
                } else if (std.mem.eql(u8, kv.key, "positional")) {
                    spec.positional = try parsePositional(a, tree, kv.value, spec.name, diags);
                } else if (std.mem.eql(u8, kv.key, "discriminant")) {
                    spec.discriminant_name = try a.dupe(u8, tree.symbolText(kv.value));
                    discriminant_span = tree.spanOf(kv.value);
                } else if (std.mem.eql(u8, kv.key, "lowering")) {
                    lowering_idx = kv.value;
                }
            },
            .form => {
                const sub = tree.formHeader(ci);
                if (std.mem.eql(u8, sub.head, "key")) {
                    key_count += 1;
                    if (key_count <= Plugin.MAX_FORM_KEYS) {
                        try keys.append(a, try buildKey(a, tree, sub, spec.name, diags, depth));
                    }
                } else if (std.mem.eql(u8, sub.head, "variant")) {
                    try variants.append(a, try buildVariant(a, tree, sub, spec.name, diags, depth));
                } else if (std.mem.eql(u8, sub.head, "exclusive-group")) {
                    try groups.append(a, try buildExclusiveGroup(a, tree, sub));
                }
            },
            else => {},
        }
    }

    if (key_count > Plugin.MAX_FORM_KEYS) {
        try emitTooManyKeys(a, diags, hdr.head_span, spec.name, key_count);
    }

    spec.keys = try keys.toOwnedSlice(a);
    if (variants.items.len > 0) {
        spec.variants = try variants.toOwnedSlice(a);
    }

    if (spec.discriminant_name) |dname| {
        var found: bool = false;
        for (spec.keys, 0..) |k, ki| {
            if (std.mem.eql(u8, k.name, dname)) {
                if (ki < std.math.maxInt(u8)) spec.discriminant_idx = @intCast(ki);
                found = true;
                break;
            }
        }
        if (!found) {
            const message = try std.fmt.allocPrint(a, "form `{s}` declares discriminant `:{s}` but no such key is defined", .{ spec.name, dname });
            try diags.append(a, .{
                .span = discriminant_span orelse hdr.head_span,
                .message = message,
                .severity = .err,
                .code = .unknown_key,
                .path = try buildPath(a, &.{ spec.name, "discriminant" }),
            });
        }
    }

    spec.exclusive_groups = try resolveExclusiveGroups(
        a,
        diags,
        groups.items,
        spec.keys,
        spec.discriminant_name,
        spec.name,
        null,
    );

    if (lowering_idx) |li| {
        spec.lowering = try buildLoweringSpec(a, tree, li, spec.name, diags);
    }

    return spec;
}

fn buildVariant(
    a: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    form_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
    depth: usize,
) Error!Plugin.Variant {
    var variant: Plugin.Variant = .{ .when = "" };
    var keys = std.ArrayList(Plugin.KeySpec).empty;
    var key_count: usize = 0;
    var groups = std.ArrayList(BuiltGroup).empty;

    for (hdr.children) |ci| {
        switch (tree.tagOf(ci)) {
            .kvpair => {
                const kv = tree.kvpairHeader(ci);
                if (std.mem.eql(u8, kv.key, "when")) {
                    variant.when = try a.dupe(u8, tree.symbolText(kv.value));
                }
            },
            .form => {
                const sub = tree.formHeader(ci);
                if (std.mem.eql(u8, sub.head, "key")) {
                    key_count += 1;
                    if (key_count <= Plugin.MAX_FORM_KEYS) {
                        try keys.append(a, try buildKey(a, tree, sub, form_name, diags, depth));
                    }
                } else if (std.mem.eql(u8, sub.head, "exclusive-group")) {
                    try groups.append(a, try buildExclusiveGroup(a, tree, sub));
                }
            },
            else => {},
        }
    }

    if (key_count > Plugin.MAX_FORM_KEYS) {
        try emitTooManyKeys(a, diags, hdr.head_span, form_name, key_count);
    }

    variant.keys = try keys.toOwnedSlice(a);
    variant.exclusive_groups = try resolveExclusiveGroups(
        a,
        diags,
        groups.items,
        variant.keys,
        null,
        form_name,
        variant.when,
    );
    return variant;
}

const BuiltGroup = struct {
    cardinality: Plugin.Cardinality,
    alternatives: []const BuiltAlt,
    span: Ast.Span,
};

const BuiltAlt = struct {
    keys: []const []const u8,
    span: Ast.Span,
};

fn buildExclusiveGroup(
    a: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
) Error!BuiltGroup {
    var cardinality: Plugin.Cardinality = .exactly_one;
    var alts = std.ArrayList(BuiltAlt).empty;

    for (hdr.children) |ci| {
        switch (tree.tagOf(ci)) {
            .kvpair => {
                const kv = tree.kvpairHeader(ci);
                if (std.mem.eql(u8, kv.key, "cardinality")) {
                    const sym = tree.symbolText(kv.value);
                    if (std.mem.eql(u8, sym, "at-most-one")) {
                        cardinality = .at_most_one;
                    } else {
                        cardinality = .exactly_one;
                    }
                }
            },
            .form => {
                const sub = tree.formHeader(ci);
                if (std.mem.eql(u8, sub.head, "alt")) {
                    try alts.append(a, try buildAlternative(a, tree, sub));
                }
            },
            else => {},
        }
    }

    return .{
        .cardinality = cardinality,
        .alternatives = try alts.toOwnedSlice(a),
        .span = hdr.head_span,
    };
}

fn buildAlternative(
    a: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
) Error!BuiltAlt {
    var keys: []const []const u8 = &.{};
    var alt_span: Ast.Span = hdr.head_span;
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "keys")) {
            keys = try parseSymbolList(a, tree, kv.value);
            alt_span = tree.spanOf(kv.value);
        }
    }
    return .{ .keys = keys, .span = alt_span };
}

fn resolveExclusiveGroups(
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    built_groups: []const BuiltGroup,
    keys: []const Plugin.KeySpec,
    discriminant_name: ?[]const u8,
    form_name: []const u8,
    variant_when: ?[]const u8,
) Error![]const Plugin.ExclusiveGroup {
    if (built_groups.len == 0) return &.{};

    var seen_in_any_group: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_in_any_group.deinit(a);

    const out = try a.alloc(Plugin.ExclusiveGroup, built_groups.len);
    for (built_groups, 0..) |bg, gi| {
        if (bg.alternatives.len < 2) {
            try emitExclusiveGroupInvalid(
                a,
                diags,
                bg.span,
                form_name,
                variant_when,
                "needs at least 2 alternatives",
            );
        }

        var seen_in_this_group: std.StringHashMapUnmanaged(void) = .empty;
        defer seen_in_this_group.deinit(a);

        const alts = try a.alloc(Plugin.Alternative, bg.alternatives.len);
        for (bg.alternatives, 0..) |ba, ai| {
            for (ba.keys) |kn| {
                if (indexOfKeyName(keys, kn) == null) {
                    const msg = try std.fmt.allocPrint(
                        a,
                        "exclusive-group alt names `{s}` but no such key is declared",
                        .{kn},
                    );
                    try emitExclusiveGroupInvalid(a, diags, ba.span, form_name, variant_when, msg);
                }
                if (discriminant_name) |dn| {
                    if (std.mem.eql(u8, dn, kn)) {
                        const msg = try std.fmt.allocPrint(
                            a,
                            "exclusive-group must not name discriminant `:{s}`",
                            .{dn},
                        );
                        try emitExclusiveGroupInvalid(a, diags, ba.span, form_name, variant_when, msg);
                    }
                }
                const in_group_gop = try seen_in_this_group.getOrPut(a, kn);
                if (in_group_gop.found_existing) {
                    try emitExclusiveBundleCollision(a, diags, ba.span, form_name, variant_when, kn);
                }
                const gop = try seen_in_any_group.getOrPut(a, kn);
                if (gop.found_existing and !in_group_gop.found_existing) {
                    const msg = try std.fmt.allocPrint(
                        a,
                        "key `{s}` appears in more than one exclusive-group",
                        .{kn},
                    );
                    try emitExclusiveGroupInvalid(a, diags, ba.span, form_name, variant_when, msg);
                }
            }
            alts[ai] = .{ .keys = ba.keys };
        }
        out[gi] = .{ .alternatives = alts, .cardinality = bg.cardinality };
    }
    return out;
}

fn indexOfKeyName(keys: []const Plugin.KeySpec, name: []const u8) ?usize {
    for (keys, 0..) |k, i| {
        if (std.mem.eql(u8, k.name, name)) return i;
    }
    return null;
}

fn emitExclusiveGroupInvalid(
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    span: Ast.Span,
    form_name: []const u8,
    variant_when: ?[]const u8,
    reason: []const u8,
) Error!void {
    const message = if (variant_when) |w|
        try std.fmt.allocPrint(
            a,
            "form `{s}` (variant `:when {s}`): {s}",
            .{ form_name, w, reason },
        )
    else
        try std.fmt.allocPrint(
            a,
            "form `{s}`: {s}",
            .{ form_name, reason },
        );
    const path = if (variant_when) |w|
        try buildPath(a, &.{ form_name, w, "exclusive-group" })
    else
        try buildPath(a, &.{ form_name, "exclusive-group" });
    try diags.append(a, .{
        .span = span,
        .message = message,
        .severity = .err,
        .code = .exclusive_group_invalid,
        .path = path,
    });
}

fn emitExclusiveBundleCollision(
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    span: Ast.Span,
    form_name: []const u8,
    variant_when: ?[]const u8,
    key_name: []const u8,
) Error!void {
    const message = if (variant_when) |w|
        try std.fmt.allocPrint(
            a,
            "form `{s}` (variant `:when {s}`): key `{s}` appears in more than one alt of the same exclusive-group",
            .{ form_name, w, key_name },
        )
    else
        try std.fmt.allocPrint(
            a,
            "form `{s}`: key `{s}` appears in more than one alt of the same exclusive-group",
            .{ form_name, key_name },
        );
    const path = if (variant_when) |w|
        try buildPath(a, &.{ form_name, w, "exclusive-group" })
    else
        try buildPath(a, &.{ form_name, "exclusive-group" });
    try diags.append(a, .{
        .span = span,
        .message = message,
        .severity = .err,
        .code = .exclusive_bundle_collision,
        .path = path,
    });
}

fn buildKey(
    a: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    form_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
    depth: usize,
) Error!Plugin.KeySpec {
    var spec: Plugin.KeySpec = .{ .name = "" };
    var saw_optional = false;
    var default_value_idx: ?Ast.NodeIndex = null;

    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "name")) {
            spec.name = try a.dupe(u8, tree.symbolText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "type")) {
            spec.value_type = try parseValueType(a, tree, kv.value);
        } else if (std.mem.eql(u8, kv.key, "optional")) {
            spec.optional = (tree.tagOf(kv.value) == .boolean_true);
            saw_optional = true;
        } else if (std.mem.eql(u8, kv.key, "default")) {
            default_value_idx = kv.value;
        } else if (std.mem.eql(u8, kv.key, "walk-opaque")) {
            spec.walk_opaque = (tree.tagOf(kv.value) == .boolean_true);
        } else if (std.mem.eql(u8, kv.key, "description")) {
            spec.description = try a.dupe(u8, tree.stringText(kv.value));
        }
    }

    if (default_value_idx) |didx| {
        const dtag = tree.tagOf(didx);
        if (dtag != .form) {
            if (defaultTagMismatch(dtag, spec.value_type)) |expected_label| {
                try emitDefault(
                    a,
                    diags,
                    tree.spanOf(didx),
                    form_name,
                    spec.name,
                    expected_label,
                    tagLabel(dtag),
                );
            }
        }
        if (try parseDefault(a, tree, didx)) |dv| {
            spec.default = dv;
        }
    }

    if (!saw_optional) {
        spec.optional = (default_value_idx != null);
    }

    var has_local: bool = false;
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) == .form) {
            has_local = true;
            break;
        }
    }
    if (has_local) {
        const is_form_slot = switch (spec.value_type) {
            .form => true,
            else => false,
        };
        if (!is_form_slot) {
            try diags.append(a, .{
                .span = hdr.head_span,
                .message = try std.fmt.allocPrint(
                    a,
                    "key `:{s}` declares inline slot-local form(s) but its `:type` is not `form`",
                    .{spec.name},
                ),
                .severity = .err,
                .code = .invalid_manifest,
                .path = try buildPath(a, &.{ form_name, spec.name }),
            });
        } else {
            var local_forms = std.ArrayList(Plugin.FormSpec).empty;
            for (hdr.children) |ci| {
                if (tree.tagOf(ci) != .form) continue;
                const sub = tree.formHeader(ci);
                const child_depth = depth + 1;
                if (child_depth > Plugin.MAX_LOCAL_FORM_DEPTH) {
                    try diags.append(a, .{
                        .span = sub.head_span,
                        .message = try std.fmt.allocPrint(
                            a,
                            "slot-local form `{s}` on `:{s}` nests deeper than MAX_LOCAL_FORM_DEPTH ({d})",
                            .{ sub.head, spec.name, Plugin.MAX_LOCAL_FORM_DEPTH },
                        ),
                        .severity = .err,
                        .code = .invalid_manifest,
                        .path = try buildPath(a, &.{ form_name, spec.name }),
                    });
                    continue;
                }
                const local = try buildForm(a, tree, sub, diags, child_depth);
                var dup: bool = false;
                for (local_forms.items) |existing| {
                    if (std.mem.eql(u8, existing.name, local.name)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) {
                    try diags.append(a, .{
                        .span = sub.head_span,
                        .message = try std.fmt.allocPrint(
                            a,
                            "duplicate slot-local form `{s}` on `:{s}`",
                            .{ local.name, spec.name },
                        ),
                        .severity = .err,
                        .code = .invalid_manifest,
                        .path = try buildPath(a, &.{ form_name, spec.name }),
                    });
                    continue;
                }
                try local_forms.append(a, local);
            }
            if (local_forms.items.len > 0) {
                spec.local_forms = try local_forms.toOwnedSlice(a);
            }
        }
    }

    return spec;
}

fn buildExprFunc(
    a: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.ExprFunc {
    var func: Plugin.ExprFunc = .{ .name = "" };
    var saw_arity = false;
    var saw_params = false;
    var saw_rest = false;
    var saw_result = false;
    var arity_idx: ?Ast.NodeIndex = null;
    var param_names_span: Ast.Span = .{ .start = 0, .end = 0 };
    var saw_param_names = false;

    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "name")) {
            func.name = try a.dupe(u8, tree.symbolText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "arity")) {
            saw_arity = true;
            func.arity = .{ .at_least = 0 };
            arity_idx = kv.value;
        } else if (std.mem.eql(u8, kv.key, "params")) {
            func.params = try parseTypeList(a, tree, kv.value);
            saw_params = true;
        } else if (std.mem.eql(u8, kv.key, "param-names")) {
            func.param_names = try parseSymbolList(a, tree, kv.value);
            saw_param_names = true;
            param_names_span = kv.key_span;
        } else if (std.mem.eql(u8, kv.key, "rest")) {
            func.rest = try parseValueType(a, tree, kv.value);
            saw_rest = true;
        } else if (std.mem.eql(u8, kv.key, "result")) {
            func.result = try parseValueType(a, tree, kv.value);
            saw_result = true;
        } else if (std.mem.eql(u8, kv.key, "description")) {
            func.description = try a.dupe(u8, tree.stringText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "impl")) {
            if (tree.tagOf(kv.value) == .string) {
                const s = tree.stringText(kv.value);
                if (std.mem.startsWith(u8, s, "wasm:")) {
                    const name = s["wasm:".len..];
                    if (name.len > 0) {
                        func.wasm_export_name = try a.dupe(u8, name);
                    }
                }
            }
        }
    }

    if (arity_idx) |aidx| {
        func.arity = try parseArity(a, tree, aidx, &.{ func.name, "arity" }, diags);
    }

    if (saw_param_names) {
        if (validateParamNamesShape(func.arity, func.rest, func.param_names.?)) |kind| {
            try emitParamNamesError(a, diags, param_names_span, func.name, kind);
            func.param_names = null;
        }
    }

    var sig_count: usize = 0;
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .form) continue;
        const sub = tree.formHeader(ci);
        if (std.mem.eql(u8, sub.head, "signature")) sig_count += 1;
    }

    if (sig_count > 0) {
        const mixed = saw_arity or saw_params or saw_rest or saw_result;
        if (mixed) {
            try emitMixedEncoding(a, diags, hdr.head_span, func.name);
        }

        const sigs = try a.alloc(Plugin.ExprFunc.Signature, sig_count);
        var sig_i: usize = 0;
        for (hdr.children) |ci| {
            if (tree.tagOf(ci) != .form) continue;
            const sub = tree.formHeader(ci);
            if (!std.mem.eql(u8, sub.head, "signature")) continue;
            sigs[sig_i] = try buildSignature(a, tree, sub, func.name, diags);
            sig_i += 1;
        }
        func.params = null;
        func.rest = null;
        func.result = null;
        func.signatures = sigs;
    }

    return func;
}

fn buildSignature(
    a: Allocator,
    tree: *const Ast.Tree,
    sig_hdr: Ast.FormHeader,
    expr_func_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.ExprFunc.Signature {
    var sig: Plugin.ExprFunc.Signature = .{ .arity = .{ .at_least = 0 } };
    var param_names_span: Ast.Span = .{ .start = 0, .end = 0 };
    var saw_param_names = false;
    for (sig_hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "arity")) {
            sig.arity = try parseArity(
                a,
                tree,
                kv.value,
                &.{ expr_func_name, "signature", "arity" },
                diags,
            );
        } else if (std.mem.eql(u8, kv.key, "params")) {
            sig.params = try parseTypeList(a, tree, kv.value);
        } else if (std.mem.eql(u8, kv.key, "param-names")) {
            sig.param_names = try parseSymbolList(a, tree, kv.value);
            saw_param_names = true;
            param_names_span = kv.key_span;
        } else if (std.mem.eql(u8, kv.key, "rest")) {
            sig.rest = try parseValueType(a, tree, kv.value);
        } else if (std.mem.eql(u8, kv.key, "result")) {
            sig.result = try parseValueType(a, tree, kv.value);
        }
    }
    if (saw_param_names) {
        if (validateParamNamesShape(sig.arity, sig.rest, sig.param_names.?)) |kind| {
            try emitParamNamesError(a, diags, param_names_span, expr_func_name, kind);
            sig.param_names = null;
        }
    }
    return sig;
}

const ParamNamesShapeError = enum {
    requires_fixed_arity,
    forbids_rest,
    too_long,
    duplicate,
};

fn validateParamNamesShape(
    arity: Plugin.ExprFunc.Arity,
    rest: ?Plugin.ValueType,
    names: []const []const u8,
) ?ParamNamesShapeError {
    const fixed = switch (arity) {
        .fixed => |k| k,
        else => return .requires_fixed_arity,
    };
    if (rest != null) return .forbids_rest;
    if (names.len > fixed) return .too_long;
    for (names, 0..) |n, i| {
        for (names[i + 1 ..]) |m| {
            if (std.mem.eql(u8, n, m)) return .duplicate;
        }
    }
    return null;
}

fn emitParamNamesError(
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    span: Ast.Span,
    expr_func_name: []const u8,
    kind: ParamNamesShapeError,
) Error!void {
    const detail: []const u8 = switch (kind) {
        .requires_fixed_arity => "requires fixed arity",
        .forbids_rest => "is incompatible with `:rest` (variadic tail)",
        .too_long => "has more names than the function's fixed arity",
        .duplicate => "contains duplicate names",
    };
    const message = try std.fmt.allocPrint(
        a,
        "expr-func `{s}`: `:param-names` {s}",
        .{ expr_func_name, detail },
    );
    const path = try buildPath(a, &.{expr_func_name});
    try diags.append(a, .{
        .span = span,
        .message = message,
        .severity = .err,
        .code = .unspecified,
        .path = path,
    });
}

fn parseDefault(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) Error!?Plugin.KeySpec.Default {
    return switch (tree.tagOf(idx)) {
        .number, .number_i64, .number_u64 => Plugin.KeySpec.Default{ .number = tree.numberOf(idx) },
        .number_with_unit => blk: {
            const nu = tree.numberWithUnitOf(idx);
            break :blk Plugin.KeySpec.Default{ .number = nu.value };
        },
        .string => Plugin.KeySpec.Default{ .string = try a.dupe(u8, tree.stringText(idx)) },
        .symbol => Plugin.KeySpec.Default{ .symbol = try a.dupe(u8, tree.symbolText(idx)) },
        .boolean_true => Plugin.KeySpec.Default{ .boolean = true },
        .boolean_false => Plugin.KeySpec.Default{ .boolean = false },
        .nil => Plugin.KeySpec.Default.nil,
        .vector => blk: {
            const elements = tree.vectorElements(idx);
            for (elements) |ei| {
                if (tree.tagOf(ei) == .form) return null;
            }
            const out = try a.alloc(Plugin.KeySpec.Default, elements.len);
            for (elements, 0..) |ei, i| {
                out[i] = (try parseDefault(a, tree, ei)) orelse return null;
            }
            break :blk Plugin.KeySpec.Default{ .vector = out };
        },
        .form => blk: {
            const hdr = tree.formHeader(idx);
            if (hdr.head.len == 0) break :blk null;
            const head_copy = try a.dupe(u8, hdr.head);
            const ns_copy: ?[]const u8 = if (hdr.namespace) |ns|
                try a.dupe(u8, ns)
            else
                null;
            const single_root = [_]Ast.NodeIndex{idx};
            var view: Ast.Tree = tree.*;
            view.root = &single_root;
            const program = Binary.toBinary(a, view, Binary.ToBinaryOptions.forMode(.compact)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.OutOfMemory,
            };
            break :blk Plugin.KeySpec.Default{ .expression = .{
                .head = head_copy,
                .namespace = ns_copy,
                .arg_count = @intCast(hdr.children.len),
                .program = program.data,
            } };
        },
        .date, .time => null,
        .kvpair, .keyword => null,
    };
}

fn defaultTagMismatch(tag: Ast.Tag, expected: Plugin.ValueType) ?[]const u8 {
    return switch (expected) {
        .any, .named => null,
        .number => switch (tag) {
            .number, .number_with_unit, .number_i64, .number_u64 => null,
            else => "number",
        },
        .string => if (tag == .string) null else "string",
        .symbol => if (tag == .symbol) null else "symbol",
        .boolean => switch (tag) {
            .boolean_true, .boolean_false => null,
            else => "boolean",
        },
        .nil => if (tag == .nil) null else "nil",
        .vector => if (tag == .vector) null else "vector",
        .form, .expr => if (tag == .form) null else "form",
    };
}

fn tagLabel(tag: Ast.Tag) []const u8 {
    return switch (tag) {
        .number, .number_with_unit, .number_i64, .number_u64 => "number",
        .string => "string",
        .symbol => "symbol",
        .boolean_true, .boolean_false => "boolean",
        .nil => "nil",
        .date => "date",
        .time => "time",
        .vector => "vector",
        .form => "form",
        .keyword => "keyword",
        .kvpair => "kvpair",
    };
}

fn emitDefault(
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    span: Ast.Span,
    form_name: []const u8,
    key_name: []const u8,
    expected: []const u8,
    got: []const u8,
) Error!void {
    const message = try std.fmt.allocPrint(
        a,
        "default value of `:{s}` expects {s}, got {s}",
        .{ key_name, expected, got },
    );
    const path = try buildPath(a, &.{ form_name, key_name, "default" });
    try diags.append(a, .{
        .span = span,
        .message = message,
        .severity = .err,
        .code = .wrong_underlying,
        .path = path,
    });
}

fn emitTooManyKeys(
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    span: Ast.Span,
    form_name: []const u8,
    declared: usize,
) Error!void {
    const message = try std.fmt.allocPrint(
        a,
        "form `{s}` declares {d} keys, exceeding the maximum of {d}",
        .{ form_name, declared, Plugin.MAX_FORM_KEYS },
    );
    const path = try buildPath(a, &.{form_name});
    try diags.append(a, .{
        .span = span,
        .message = message,
        .severity = .err,
        .code = .too_many_keys,
        .path = path,
    });
}

fn emitNumericOutOfRange(
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    span: Ast.Span,
    path: []const []const u8,
    field: []const u8,
    bound_max: u64,
    value: f64,
) Error!void {
    const message = try std.fmt.allocPrint(
        a,
        "`:{s}` requires a non-negative integer ≤ {d}, got {d}",
        .{ field, bound_max, value },
    );
    try diags.append(a, .{
        .span = span,
        .message = message,
        .severity = .err,
        .code = .wrong_underlying,
        .path = path,
    });
}

fn emitMixedEncoding(
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    span: Ast.Span,
    expr_func_name: []const u8,
) Error!void {
    const message = try std.fmt.allocPrint(
        a,
        "expr-func `{s}` mixes mono-signature fields (:arity/:params/:rest/:result) " ++
            "with `(signature …)` overloads — pick one encoding",
        .{expr_func_name},
    );
    const path = try buildPath(a, &.{expr_func_name});
    try diags.append(a, .{
        .span = span,
        .message = message,
        .severity = .err,
        .code = .unspecified,
        .path = path,
    });
}

fn buildPath(a: Allocator, steps: []const []const u8) Error![]const []const u8 {
    const out = try a.alloc([]const u8, steps.len);
    for (steps, 0..) |s, i| out[i] = try a.dupe(u8, s);
    return out;
}

fn pathConcat(
    a: Allocator,
    prefix: []const []const u8,
    suffix: []const []const u8,
) Error![]const []const u8 {
    const out = try a.alloc([]const u8, prefix.len + suffix.len);
    for (prefix, 0..) |s, i| out[i] = try a.dupe(u8, s);
    for (suffix, 0..) |s, i| out[prefix.len + i] = try a.dupe(u8, s);
    return out;
}

fn boundedInt(comptime T: type, n: f64) ?T {
    if (std.math.isNan(n) or std.math.isInf(n)) return null;
    if (@floor(n) != n) return null;
    const min_f: f64 = @floatFromInt(std.math.minInt(T));
    const max_f: f64 = @floatFromInt(std.math.maxInt(T));
    if (n < min_f or n > max_f) return null;
    return @intFromFloat(n);
}

fn numericValue(tree: *const Ast.Tree, idx: Ast.NodeIndex) f64 {
    return switch (tree.tagOf(idx)) {
        .number, .number_i64, .number_u64 => tree.numberOf(idx),
        .number_with_unit => tree.numberWithUnitOf(idx).value,
        else => unreachable,
    };
}

const PositionalNumber = struct { value: f64, span: Ast.Span };

fn firstPositionalNumber(tree: *const Ast.Tree, hdr: Ast.FormHeader) ?PositionalNumber {
    for (hdr.children) |ci| {
        const tag = tree.tagOf(ci);
        if (tag == .number or tag == .number_with_unit or tag == .number_i64 or tag == .number_u64) {
            return .{ .value = numericValue(tree, ci), .span = tree.spanOf(ci) };
        }
    }
    return null;
}

fn readVectorLen(
    a: Allocator,
    tree: *const Ast.Tree,
    value_idx: Ast.NodeIndex,
    kind_name: []const u8,
    field: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!?u16 {
    const n = numericValue(tree, value_idx);
    if (boundedInt(u16, n)) |v| return v;
    try emitNumericOutOfRange(
        a,
        diags,
        tree.spanOf(value_idx),
        try buildPath(a, &.{ kind_name, "vector", field }),
        field,
        std.math.maxInt(u16),
        n,
    );
    return null;
}

fn buildVectorShape(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.ValueKind.VectorShape {
    const hdr = tree.formHeader(idx);
    var shape: Plugin.ValueKind.VectorShape = .{ .element = .{ .name = "" } };
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "len")) {
            shape.len = try readVectorLen(a, tree, kv.value, kind_name, "len", diags);
        } else if (std.mem.eql(u8, kv.key, "min-len")) {
            shape.min_len = try readVectorLen(a, tree, kv.value, kind_name, "min-len", diags);
        } else if (std.mem.eql(u8, kv.key, "max-len")) {
            shape.max_len = try readVectorLen(a, tree, kv.value, kind_name, "max-len", diags);
        } else if (std.mem.eql(u8, kv.key, "element")) {
            shape.element = try parseQualifiedRef(a, tree.symbolText(kv.value));
        }
    }
    return shape;
}

fn checkVectorShapeConsistency(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind: Plugin.ValueKind,
    shape: Plugin.ValueKind.VectorShape,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!void {
    const span = tree.spanOf(idx);
    if (shape.len != null and (shape.min_len != null or shape.max_len != null)) {
        try diags.append(a, .{
            .span = span,
            .message = try std.fmt.allocPrint(
                a,
                "value-kind `{s}` `:vector` sets a fixed `:len` together with `:min-len`/`:max-len` — a fixed length already subsumes a range",
                .{kind.name},
            ),
            .severity = .err,
            .code = .vector_bounds_invalid,
            .path = try buildPath(a, &.{ kind.name, "vector" }),
        });
    }
    if (shape.min_len) |mn| if (shape.max_len) |mx| {
        if (mn > mx) {
            try diags.append(a, .{
                .span = span,
                .message = try std.fmt.allocPrint(
                    a,
                    "value-kind `{s}` `:vector` has empty range: :min-len {d} > :max-len {d}",
                    .{ kind.name, mn, mx },
                ),
                .severity = .err,
                .code = .vector_bounds_invalid,
                .path = try buildPath(a, &.{ kind.name, "vector" }),
            });
        }
    };
}

fn buildUnitShape(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) Error!Plugin.ValueKind.UnitShape {
    const hdr = tree.formHeader(idx);
    var shape: Plugin.ValueKind.UnitShape = .{};
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "required")) {
            shape.required = (tree.tagOf(kv.value) == .boolean_true);
        } else if (std.mem.eql(u8, kv.key, "reject")) {
            shape.reject = (tree.tagOf(kv.value) == .boolean_true);
        } else if (std.mem.eql(u8, kv.key, "allowed")) {
            shape.allowed = try parseSymbolList(a, tree, kv.value);
        }
    }
    return shape;
}

fn checkUnitShapeConsistency(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind: Plugin.ValueKind,
    unit: Plugin.ValueKind.UnitShape,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!void {
    if (!unit.reject) return;
    const span = tree.spanOf(idx);
    if (unit.required) {
        try diags.append(a, .{
            .span = span,
            .message = try std.fmt.allocPrint(
                a,
                "value-kind `{s}` `:unit` sets both `:reject true` and `:required true` — a slot cannot forbid and demand a unit",
                .{kind.name},
            ),
            .severity = .err,
            .code = .invalid_manifest,
            .path = try buildPath(a, &.{ kind.name, "unit", "reject" }),
        });
    }
    if (unit.allowed.len != 0) {
        try diags.append(a, .{
            .span = span,
            .message = try std.fmt.allocPrint(
                a,
                "value-kind `{s}` `:unit` sets `:reject true` but also lists `:allowed` units — these contradict",
                .{kind.name},
            ),
            .severity = .err,
            .code = .invalid_manifest,
            .path = try buildPath(a, &.{ kind.name, "unit", "reject" }),
        });
    }
}

const repr_by_name = std.StaticStringMap(Plugin.ValueKind.Repr).initComptime(.{
    .{ "f32", .f32 },
    .{ "u32", .u32 },
    .{ "i32", .i32 },
    .{ "u16", .u16 },
    .{ "f16", .f16 },
});

fn buildReprShape(
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) Error!Plugin.ValueKind.Repr {
    const hdr = tree.formHeader(idx);
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "type")) {
            return repr_by_name.get(tree.symbolText(kv.value)) orelse .f32;
        }
    }
    return .f32;
}

fn checkReprShapeConsistency(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind: Plugin.ValueKind,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!void {
    if (kind.underlying == .number) return;
    try diags.append(a, .{
        .span = tree.spanOf(idx),
        .message = try std.fmt.allocPrint(
            a,
            "value-kind `{s}` declares `:repr` but `:underlying` is `{s}`, not `number`",
            .{ kind.name, @tagName(kind.underlying) },
        ),
        .severity = .err,
        .code = .invalid_manifest,
        .path = try buildPath(a, &.{ kind.name, "repr" }),
    });
}

fn buildNumericBounds(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) Error!Plugin.ValueKind.NumericBounds {
    const hdr = tree.formHeader(idx);
    var bounds: Plugin.ValueKind.NumericBounds = .{};
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "min")) {
            bounds.min = try loadBound(a, tree, kv.value);
        } else if (std.mem.eql(u8, kv.key, "max")) {
            bounds.max = try loadBound(a, tree, kv.value);
        } else if (std.mem.eql(u8, kv.key, "exclusive-min")) {
            bounds.exclusive_min = (tree.tagOf(kv.value) == .boolean_true);
        } else if (std.mem.eql(u8, kv.key, "exclusive-max")) {
            bounds.exclusive_max = (tree.tagOf(kv.value) == .boolean_true);
        } else if (std.mem.eql(u8, kv.key, "integer")) {
            bounds.integer = (tree.tagOf(kv.value) == .boolean_true);
        }
    }
    return bounds;
}

fn loadBound(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) Error!Plugin.ValueKind.NumericBounds.Bound {
    return switch (tree.tagOf(idx)) {
        .number => .{
            .value = tree.numberOf(idx),
            .unit = null,
            .exact_int = false,
        },
        .number_i64 => .{
            .value = @floatFromInt(tree.numberI64Of(idx)),
            .unit = null,
            .exact_int = true,
        },
        .number_u64 => .{
            .value = @floatFromInt(tree.numberU64Of(idx)),
            .unit = null,
            .exact_int = true,
        },
        .number_with_unit => sub: {
            const n = tree.numberWithUnitOf(idx);
            break :sub .{
                .value = n.value,
                .unit = try a.dupe(u8, n.unit),
                .exact_int = false,
            };
        },
        else => unreachable,
    };
}

fn checkNumericBoundsConsistency(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind: Plugin.ValueKind,
    bounds: Plugin.ValueKind.NumericBounds,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!void {
    const span = tree.spanOf(idx);
    if (kind.underlying != .number) {
        const message = try std.fmt.allocPrint(
            a,
            "value-kind `{s}` declares `:numeric` but `:underlying` is `{s}`, not `number`",
            .{ kind.name, @tagName(kind.underlying) },
        );
        try diags.append(a, .{
            .span = span,
            .message = message,
            .severity = .err,
            .code = .numeric_bounds_invalid,
            .path = try buildPath(a, &.{ kind.name, "numeric" }),
        });
    }
    if (bounds.exclusive_min and bounds.min == null) {
        const message = try std.fmt.allocPrint(
            a,
            "value-kind `{s}` `:numeric` sets `:exclusive-min true` but `:min` is absent",
            .{kind.name},
        );
        try diags.append(a, .{
            .span = span,
            .message = message,
            .severity = .err,
            .code = .numeric_bounds_invalid,
            .path = try buildPath(a, &.{ kind.name, "numeric", "exclusive-min" }),
        });
    }
    if (bounds.exclusive_max and bounds.max == null) {
        const message = try std.fmt.allocPrint(
            a,
            "value-kind `{s}` `:numeric` sets `:exclusive-max true` but `:max` is absent",
            .{kind.name},
        );
        try diags.append(a, .{
            .span = span,
            .message = message,
            .severity = .err,
            .code = .numeric_bounds_invalid,
            .path = try buildPath(a, &.{ kind.name, "numeric", "exclusive-max" }),
        });
    }
    if (bounds.min) |mn| if (bounds.max) |mx| {
        const same_unit = (mn.unit == null and mx.unit == null) or
            (mn.unit != null and mx.unit != null and std.mem.eql(u8, mn.unit.?, mx.unit.?));
        if (same_unit and mn.value > mx.value) {
            const message = try std.fmt.allocPrint(
                a,
                "value-kind `{s}` `:numeric` has empty range: :min {d} > :max {d}",
                .{ kind.name, mn.value, mx.value },
            );
            try diags.append(a, .{
                .span = span,
                .message = message,
                .severity = .err,
                .code = .numeric_bounds_invalid,
                .path = try buildPath(a, &.{ kind.name, "numeric" }),
            });
        }
    };
}

const RawLen = struct {
    value_raw: f64,
    exact_int: bool,
};

fn buildStringBounds(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) Error!Plugin.ValueKind.StringBounds {
    const hdr = tree.formHeader(idx);
    var bounds: Plugin.ValueKind.StringBounds = .{};
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "min-len")) {
            bounds.min_len = lenFromNumber(tree, kv.value);
        } else if (std.mem.eql(u8, kv.key, "max-len")) {
            bounds.max_len = lenFromNumber(tree, kv.value);
        } else if (std.mem.eql(u8, kv.key, "pattern")) {
            bounds.pattern = try a.dupe(u8, tree.stringText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "format")) {
            bounds.format = StringFormats.fromName(tree.symbolText(kv.value));
        }
    }
    return bounds;
}

fn lenFromNumber(tree: *const Ast.Tree, idx: Ast.NodeIndex) u32 {
    const raw = lenRawFromNumber(tree, idx);
    if (raw.value_raw < 0) return 0;
    if (raw.value_raw > @as(f64, @floatFromInt(std.math.maxInt(u32)))) {
        return std.math.maxInt(u32);
    }
    return @intFromFloat(raw.value_raw);
}

fn lenRawFromNumber(tree: *const Ast.Tree, idx: Ast.NodeIndex) RawLen {
    return switch (tree.tagOf(idx)) {
        .number => .{ .value_raw = tree.numberOf(idx), .exact_int = false },
        .number_i64 => .{ .value_raw = @floatFromInt(tree.numberI64Of(idx)), .exact_int = true },
        .number_u64 => .{ .value_raw = @floatFromInt(tree.numberU64Of(idx)), .exact_int = true },
        .number_with_unit => .{ .value_raw = tree.numberWithUnitOf(idx).value, .exact_int = false },
        else => unreachable,
    };
}

fn checkStringBoundsConsistency(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind: Plugin.ValueKind,
    bounds: Plugin.ValueKind.StringBounds,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!void {
    const span = tree.spanOf(idx);
    if (kind.underlying != .string) {
        try diags.append(a, .{
            .span = span,
            .message = try std.fmt.allocPrint(
                a,
                "value-kind `{s}` declares `:string-bounds` but `:underlying` is `{s}`, not `string`",
                .{ kind.name, @tagName(kind.underlying) },
            ),
            .severity = .err,
            .code = .string_bounds_invalid,
            .path = try buildPath(a, &.{ kind.name, "string-bounds" }),
        });
    }

    if (try findRawLen(tree, idx, "min-len")) |raw| {
        if (raw.value_raw < 0) {
            try diags.append(a, .{
                .span = span,
                .message = try std.fmt.allocPrint(
                    a,
                    "value-kind `{s}` `:string-bounds` has negative :min-len {d}",
                    .{ kind.name, raw.value_raw },
                ),
                .severity = .err,
                .code = .string_bounds_invalid,
                .path = try buildPath(a, &.{ kind.name, "string-bounds", "min-len" }),
            });
        }
    }
    if (try findRawLen(tree, idx, "max-len")) |raw| {
        if (raw.value_raw < 0) {
            try diags.append(a, .{
                .span = span,
                .message = try std.fmt.allocPrint(
                    a,
                    "value-kind `{s}` `:string-bounds` has negative :max-len {d}",
                    .{ kind.name, raw.value_raw },
                ),
                .severity = .err,
                .code = .string_bounds_invalid,
                .path = try buildPath(a, &.{ kind.name, "string-bounds", "max-len" }),
            });
        }
    }

    if (bounds.min_len) |mn| if (bounds.max_len) |mx| {
        if (mn > mx) {
            try diags.append(a, .{
                .span = span,
                .message = try std.fmt.allocPrint(
                    a,
                    "value-kind `{s}` `:string-bounds` has empty range: :min-len {d} > :max-len {d}",
                    .{ kind.name, mn, mx },
                ),
                .severity = .err,
                .code = .string_bounds_invalid,
                .path = try buildPath(a, &.{ kind.name, "string-bounds" }),
            });
        }
    };

    if (bounds.pattern) |p| {
        if (p.len == 0) {
            try diags.append(a, .{
                .span = span,
                .message = try std.fmt.allocPrint(
                    a,
                    "value-kind `{s}` `:string-bounds :pattern` is the empty string",
                    .{kind.name},
                ),
                .severity = .err,
                .code = .string_bounds_invalid,
                .path = try buildPath(a, &.{ kind.name, "string-bounds", "pattern" }),
            });
        }
    }

    if (kind.underlying == .string) if (kind.members) |ms| {
        for (ms.members) |m| {
            const cp = std.unicode.utf8CountCodepoints(m.name) catch m.name.len;
            if (bounds.min_len) |mn| if (cp < mn) {
                try diags.append(a, .{
                    .span = span,
                    .message = try std.fmt.allocPrint(
                        a,
                        "value-kind `{s}` member \"{s}\" has length {d} < :min-len {d}",
                        .{ kind.name, m.name, cp, mn },
                    ),
                    .severity = .err,
                    .code = .string_bounds_invalid,
                    .path = try buildPath(a, &.{ kind.name, "string-bounds", "min-len" }),
                });
            };
            if (bounds.max_len) |mx| if (cp > mx) {
                try diags.append(a, .{
                    .span = span,
                    .message = try std.fmt.allocPrint(
                        a,
                        "value-kind `{s}` member \"{s}\" has length {d} > :max-len {d}",
                        .{ kind.name, m.name, cp, mx },
                    ),
                    .severity = .err,
                    .code = .string_bounds_invalid,
                    .path = try buildPath(a, &.{ kind.name, "string-bounds", "max-len" }),
                });
            };
            if (bounds.format) |fmt| if (!StringFormats.check(fmt, m.name)) {
                try diags.append(a, .{
                    .span = span,
                    .message = try std.fmt.allocPrint(
                        a,
                        "value-kind `{s}` member \"{s}\" does not satisfy :format `{s}`",
                        .{ kind.name, m.name, @tagName(fmt) },
                    ),
                    .severity = .err,
                    .code = .string_bounds_invalid,
                    .path = try buildPath(a, &.{ kind.name, "string-bounds", "format" }),
                });
            };
        }
    };
}

fn findRawLen(tree: *const Ast.Tree, idx: Ast.NodeIndex, key: []const u8) Error!?RawLen {
    const hdr = tree.formHeader(idx);
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, key)) return lenRawFromNumber(tree, kv.value);
    }
    return null;
}

fn buildMemberSet(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.ValueKind.MemberSet {
    const hdr = tree.formHeader(idx);
    var compact_values: ?[]const []const u8 = null;
    var rich_count: usize = 0;
    for (hdr.children) |ci| {
        switch (tree.tagOf(ci)) {
            .kvpair => {
                const kv = tree.kvpairHeader(ci);
                if (std.mem.eql(u8, kv.key, "values")) {
                    compact_values = try parseSymbolList(a, tree, kv.value);
                }
            },
            .form => rich_count += 1,
            else => {},
        }
    }

    const both_present = compact_values != null and rich_count > 0;
    if (both_present) {
        try diags.append(a, .{
            .span = hdr.head_span,
            .message = try std.fmt.allocPrint(
                a,
                "value-kind `{s}` `:members` mixes `:values` and `(member …)` children — pick one shape",
                .{kind_name},
            ),
            .severity = .err,
            .code = .invalid_manifest,
            .path = try buildPath(a, &.{ kind_name, "members" }),
        });
    }

    if (compact_values) |values| {
        const out = try a.alloc(Plugin.ValueKind.MemberSet.Member, values.len);
        for (values, 0..) |n, i| out[i] = .{ .name = n };
        return .{ .members = out };
    }

    if (rich_count > 0) {
        const out = try a.alloc(Plugin.ValueKind.MemberSet.Member, rich_count);
        var wi: usize = 0;
        for (hdr.children) |ci| {
            if (tree.tagOf(ci) != .form) continue;
            out[wi] = try parseMemberDecl(a, tree, ci);
            for (out[0..wi]) |prior| {
                if (std.mem.eql(u8, prior.name, out[wi].name)) {
                    try diags.append(a, .{
                        .span = tree.spanOf(ci),
                        .message = try std.fmt.allocPrint(
                            a,
                            "value-kind `{s}` `:members` declares duplicate member `{s}`",
                            .{ kind_name, out[wi].name },
                        ),
                        .severity = .err,
                        .code = .invalid_manifest,
                        .path = try buildPath(a, &.{ kind_name, "members" }),
                    });
                    break;
                }
            }
            wi += 1;
        }
        return .{ .members = out };
    }

    try diags.append(a, .{
        .span = hdr.head_span,
        .message = try std.fmt.allocPrint(
            a,
            "value-kind `{s}` `:members` declares no members (need `:values …` or `(member …)` children)",
            .{kind_name},
        ),
        .severity = .err,
        .code = .invalid_manifest,
        .path = try buildPath(a, &.{ kind_name, "members" }),
    });
    return .{ .members = &.{} };
}

fn parseMemberDecl(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) Error!Plugin.ValueKind.MemberSet.Member {
    const hdr = tree.formHeader(idx);
    var m: Plugin.ValueKind.MemberSet.Member = .{ .name = "" };
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "name")) {
            m.name = try a.dupe(u8, tree.symbolText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "label")) {
            m.label = try a.dupe(u8, tree.stringText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "description")) {
            m.description = try a.dupe(u8, tree.stringText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "deprecated")) {
            m.deprecated = (tree.tagOf(kv.value) == .boolean_true);
        } else if (std.mem.eql(u8, kv.key, "deprecation-message")) {
            m.deprecation_message = try a.dupe(u8, tree.stringText(kv.value));
        }
    }
    return m;
}

fn buildHeadSet(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) Error!Plugin.ValueKind.HeadSet {
    const hdr = tree.formHeader(idx);
    var names: []const []const u8 = &.{};
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "names")) {
            names = try parseSymbolList(a, tree, kv.value);
        }
    }
    return .{ .names = names };
}

fn buildCrossRef(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind: Plugin.ValueKind,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.ValueKind.CrossRef {
    const hdr = tree.formHeader(idx);
    var cr: Plugin.ValueKind.CrossRef = .{ .target_form = "" };
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "target")) {
            cr.target_form = try a.dupe(u8, tree.symbolText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "name-key")) {
            cr.name_key = try a.dupe(u8, tree.symbolText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "acyclic")) {
            cr.acyclic = (tree.tagOf(kv.value) == .boolean_true);
        } else if (std.mem.eql(u8, kv.key, "scope")) {
            cr.scope_form = try a.dupe(u8, tree.symbolText(kv.value));
        }
    }
    if (kind.underlying != .symbol) {
        const message = try std.fmt.allocPrint(
            a,
            "value-kind `{s}` declares `:cross-ref` but `:underlying` is `{s}`, not `symbol`",
            .{ kind.name, @tagName(kind.underlying) },
        );
        const path = try buildPath(a, &.{ kind.name, "cross-ref" });
        try diags.append(a, .{
            .span = tree.spanOf(idx),
            .message = message,
            .severity = .err,
            .code = .wrong_underlying,
            .path = path,
        });
    }
    return cr;
}

fn buildUnionShape(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind: Plugin.ValueKind,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.ValueKind.UnionShape {
    const hdr = tree.formHeader(idx);
    var alts: []const Plugin.QualifiedRef = &.{};
    var alts_span: Ast.Span = tree.spanOf(idx);
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "alternatives")) {
            alts = try parseQualifiedSymbolList(a, tree, kv.value);
            alts_span = tree.spanOf(kv.value);
        }
    }
    if (kind.underlying != .union_of) {
        const message = try std.fmt.allocPrint(
            a,
            "value-kind `{s}` declares `:union` but `:underlying` is `{s}`, not `union`",
            .{ kind.name, @tagName(kind.underlying) },
        );
        try diags.append(a, .{
            .span = tree.spanOf(idx),
            .message = message,
            .severity = .err,
            .code = .wrong_underlying,
            .path = try buildPath(a, &.{ kind.name, "union" }),
        });
    }
    if (alts.len < 2) {
        const message = try std.fmt.allocPrint(
            a,
            "value-kind `{s}` `:union` requires at least two alternatives, got {d}",
            .{ kind.name, alts.len },
        );
        try diags.append(a, .{
            .span = alts_span,
            .message = message,
            .severity = .err,
            .code = .wrong_underlying,
            .path = try buildPath(a, &.{ kind.name, "union", "alternatives" }),
        });
    }
    for (alts, 0..) |alt, i| {
        for (alts[0..i]) |prev| {
            if (std.mem.eql(u8, alt.name, prev.name)) {
                const message = try std.fmt.allocPrint(
                    a,
                    "value-kind `{s}` `:union` alternative `{s}` listed twice",
                    .{ kind.name, alt.name },
                );
                try diags.append(a, .{
                    .span = alts_span,
                    .message = message,
                    .severity = .err,
                    .code = .wrong_underlying,
                    .path = try buildPath(a, &.{ kind.name, "union", "alternatives" }),
                });
                break;
            }
        }
    }
    return .{ .alternatives = alts };
}

fn parseQualifiedSymbolList(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) Error![]const Plugin.QualifiedRef {
    if (tree.tagOf(idx) != .vector) return &.{};
    const elements = tree.vectorElements(idx);
    const out = try a.alloc(Plugin.QualifiedRef, elements.len);
    for (elements, 0..) |el, i| {
        if (tree.tagOf(el) != .symbol) {
            out[i] = .{ .name = "" };
            continue;
        }
        out[i] = try parseQualifiedRef(a, tree.symbolText(el));
    }
    return out;
}

fn buildLoweringSpec(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    form_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.LoweringSpec {
    const hdr = tree.formHeader(idx);
    var spec: Plugin.LoweringSpec = .{ .hook = "", .produces = &.{} };
    var produces_span: Ast.Span = tree.spanOf(idx);
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "hook")) {
            spec.hook = try a.dupe(u8, tree.symbolText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "produces")) {
            spec.produces = try parseSymbolList(a, tree, kv.value);
            produces_span = tree.spanOf(kv.value);
        }
    }
    if (spec.produces.len == 0) {
        const message = try std.fmt.allocPrint(
            a,
            "form `{s}` `:lowering` requires at least one produced head, got 0",
            .{form_name},
        );
        try diags.append(a, .{
            .span = produces_span,
            .message = message,
            .severity = .err,
            .code = .wrong_underlying,
            .path = try buildPath(a, &.{ form_name, "lowering", "produces" }),
        });
    }
    for (spec.produces, 0..) |name, i| {
        for (spec.produces[0..i]) |prev| {
            if (std.mem.eql(u8, name, prev)) {
                const message = try std.fmt.allocPrint(
                    a,
                    "form `{s}` `:lowering` produces head `{s}` listed twice",
                    .{ form_name, name },
                );
                try diags.append(a, .{
                    .span = produces_span,
                    .message = message,
                    .severity = .err,
                    .code = .wrong_underlying,
                    .path = try buildPath(a, &.{ form_name, "lowering", "produces" }),
                });
                break;
            }
        }
    }
    return spec;
}

fn parseUnderlying(tree: *const Ast.Tree, idx: Ast.NodeIndex) Error!Plugin.ValueKind.Underlying {
    const sym = tree.symbolText(idx);
    if (std.mem.eql(u8, sym, "number")) return .number;
    if (std.mem.eql(u8, sym, "string")) return .string;
    if (std.mem.eql(u8, sym, "vector")) return .vector;
    if (std.mem.eql(u8, sym, "form")) return .form;
    if (std.mem.eql(u8, sym, "symbol")) return .symbol;
    if (std.mem.eql(u8, sym, "union")) return .union_of;
    return .symbol;
}

fn parseValueType(a: Allocator, tree: *const Ast.Tree, idx: Ast.NodeIndex) Error!Plugin.ValueType {
    const sym = tree.symbolText(idx);
    if (std.mem.eql(u8, sym, "any")) return .any;
    if (std.mem.eql(u8, sym, "number")) return .number;
    if (std.mem.eql(u8, sym, "string")) return .string;
    if (std.mem.eql(u8, sym, "symbol")) return .symbol;
    if (std.mem.eql(u8, sym, "boolean")) return .boolean;
    if (std.mem.eql(u8, sym, "nil")) return .nil;
    if (std.mem.eql(u8, sym, "vector")) return .vector;
    if (std.mem.eql(u8, sym, "form")) return .form;
    if (std.mem.eql(u8, sym, "expr")) return .expr;
    return .{ .named = try parseQualifiedRef(a, sym) };
}

fn parsePositional(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    form_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.PositionalSpec {
    if (tree.tagOf(idx) == .form) return try parseFlagSet(a, tree, idx, form_name, diags);
    const sym = tree.symbolText(idx);
    if (std.mem.eql(u8, sym, "any")) return .any;
    return .{ .kind = try parseQualifiedRef(a, sym) };
}

fn parseFlagSet(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    form_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.PositionalSpec {
    const hdr = tree.formHeader(idx);
    var flags: std.ArrayList(Plugin.PositionalSpec.FlagSet.Flag) = .empty;
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .form) continue;
        const flag = try parseFlagDecl(a, tree, ci);
        if (flag.name.len == 0) continue;
        for (flags.items) |prior| {
            if (std.mem.eql(u8, prior.name, flag.name)) {
                try diags.append(a, .{
                    .span = tree.spanOf(ci),
                    .message = try std.fmt.allocPrint(
                        a,
                        "form `{s}` `:positional (flag-set …)` declares duplicate flag `{s}`",
                        .{ form_name, flag.name },
                    ),
                    .severity = .err,
                    .code = .invalid_manifest,
                    .path = try buildPath(a, &.{ form_name, "positional" }),
                });
                break;
            }
        }
        try flags.append(a, flag);
    }
    if (flags.items.len == 0) {
        try diags.append(a, .{
            .span = hdr.head_span,
            .message = try std.fmt.allocPrint(
                a,
                "form `{s}` `:positional (flag-set …)` declares no flags (need `(flag :name …)` children)",
                .{form_name},
            ),
            .severity = .err,
            .code = .invalid_manifest,
            .path = try buildPath(a, &.{ form_name, "positional" }),
        });
    }
    return .{ .flag_set = .{ .flags = try flags.toOwnedSlice(a) } };
}

fn parseFlagDecl(a: Allocator, tree: *const Ast.Tree, idx: Ast.NodeIndex) Error!Plugin.PositionalSpec.FlagSet.Flag {
    const hdr = tree.formHeader(idx);
    var flag: Plugin.PositionalSpec.FlagSet.Flag = .{ .name = "" };
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "name")) {
            flag.name = try a.dupe(u8, tree.symbolText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "description")) {
            flag.description = try a.dupe(u8, tree.stringText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "link")) {
            flag.link = try a.dupe(u8, tree.stringText(kv.value));
        }
    }
    return flag;
}

fn parseQualifiedRef(a: Allocator, sym: []const u8) Error!Plugin.QualifiedRef {
    const split = Parser.splitNamespace(sym);
    return .{
        .name = try a.dupe(u8, split.name),
        .namespace = if (split.namespace) |ns| try a.dupe(u8, ns) else null,
    };
}

fn parseArity(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    arity_path: []const []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.ExprFunc.Arity {
    const hdr = tree.formHeader(idx);
    if (std.mem.eql(u8, hdr.head, "fixed")) {
        const info = firstPositionalNumber(tree, hdr) orelse return .{ .fixed = 0 };
        if (boundedInt(u8, info.value)) |v| return .{ .fixed = v };
        try emitNumericOutOfRange(
            a,
            diags,
            info.span,
            try pathConcat(a, arity_path, &.{"fixed"}),
            "fixed",
            std.math.maxInt(u8),
            info.value,
        );
        return .{ .fixed = 0 };
    }
    if (std.mem.eql(u8, hdr.head, "at-least")) {
        const info = firstPositionalNumber(tree, hdr) orelse return .{ .at_least = 0 };
        if (boundedInt(u8, info.value)) |v| return .{ .at_least = v };
        try emitNumericOutOfRange(
            a,
            diags,
            info.span,
            try pathConcat(a, arity_path, &.{"at-least"}),
            "at-least",
            std.math.maxInt(u8),
            info.value,
        );
        return .{ .at_least = 0 };
    }
    var min: u8 = 0;
    var max: u8 = 0;
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "min")) {
            const n = numericValue(tree, kv.value);
            if (boundedInt(u8, n)) |v| {
                min = v;
            } else {
                try emitNumericOutOfRange(
                    a,
                    diags,
                    tree.spanOf(kv.value),
                    try pathConcat(a, arity_path, &.{ "range", "min" }),
                    "min",
                    std.math.maxInt(u8),
                    n,
                );
            }
        } else if (std.mem.eql(u8, kv.key, "max")) {
            const n = numericValue(tree, kv.value);
            if (boundedInt(u8, n)) |v| {
                max = v;
            } else {
                try emitNumericOutOfRange(
                    a,
                    diags,
                    tree.spanOf(kv.value),
                    try pathConcat(a, arity_path, &.{ "range", "max" }),
                    "max",
                    std.math.maxInt(u8),
                    n,
                );
            }
        }
    }
    return .{ .range = .{ .min = min, .max = max } };
}

fn parseTypeList(a: Allocator, tree: *const Ast.Tree, idx: Ast.NodeIndex) Error![]const Plugin.ValueType {
    const elements = tree.vectorElements(idx);
    const out = try a.alloc(Plugin.ValueType, elements.len);
    for (elements, 0..) |ei, i| {
        out[i] = try parseValueType(a, tree, ei);
    }
    return out;
}

fn parseSymbolList(a: Allocator, tree: *const Ast.Tree, idx: Ast.NodeIndex) Error![]const []const u8 {
    const elements = tree.vectorElements(idx);
    const out = try a.alloc([]const u8, elements.len);
    for (elements, 0..) |ei, i| {
        out[i] = try a.dupe(u8, tree.symbolText(ei));
    }
    return out;
}

const testing = std.testing;
const Parser = @import("Parser.zig");
const Expr = @import("Expr.zig");
const core = @import("plugins/core.zig");

fn parseSource(a: Allocator, src: [:0]const u8) !Ast.Tree {
    return Parser.parse(a, src);
}

fn buildKeysSource(a: Allocator, n: usize) ![:0]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "(plugin :name p :version \"1.0.0\"\n  (form :name f");
    for (0..n) |i| {
        var num_buf: [16]u8 = undefined;
        const num = try std.fmt.bufPrint(&num_buf, "{d}", .{i});
        try buf.appendSlice(a, "\n    (key :name k");
        try buf.appendSlice(a, num);
        try buf.appendSlice(a, " :type any)");
    }
    try buf.appendSlice(a, "))");
    const z = try a.allocSentinel(u8, buf.items.len, 0);
    @memcpy(z, buf.items);
    return z;
}

fn findNumericOutOfRange(
    diags: []const Ast.Diagnostic,
    expected_field: []const u8,
    expected_path: []const []const u8,
) bool {
    for (diags) |d| {
        if (d.code != .wrong_underlying) continue;
        if (std.mem.indexOf(u8, d.message, "non-negative integer") == null) continue;
        if (std.mem.indexOf(u8, d.message, expected_field) == null) continue;
        if (d.path.len != expected_path.len) continue;
        var match = true;
        for (d.path, expected_path) |a_step, e_step| {
            if (!std.mem.eql(u8, a_step, e_step)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn findExclusiveGroupInvalid(
    diags: []const Ast.Diagnostic,
    needle: []const u8,
) bool {
    for (diags) |d| {
        if (d.code != .exclusive_group_invalid) continue;
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

fn findNumericBoundsInvalid(
    diags: []const Ast.Diagnostic,
    needle: []const u8,
) bool {
    for (diags) |d| {
        if (d.code != .numeric_bounds_invalid) continue;
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

fn findStringBoundsInvalid(
    diags: []const Ast.Diagnostic,
    needle: []const u8,
) bool {
    for (diags) |d| {
        if (d.code != .string_bounds_invalid) continue;
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

fn buildNestedLocalSource(a: Allocator, d: usize) ![:0]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "(plugin :name p :version \"1.0.0\"\n  ");
    for (0..d) |i| {
        var num_buf: [16]u8 = undefined;
        const num = try std.fmt.bufPrint(&num_buf, "{d}", .{i});
        if (i < d - 1) {
            try buf.appendSlice(a, "(form :name f");
            try buf.appendSlice(a, num);
            try buf.appendSlice(a, " (key :name k :type form ");
        } else {
            try buf.appendSlice(a, "(form :name f");
            try buf.appendSlice(a, num);
            try buf.appendSlice(a, ")");
        }
    }
    for (0..d - 1) |_| try buf.appendSlice(a, "))");
    try buf.appendSlice(a, ")");
    const z = try a.allocSentinel(u8, buf.items.len, 0);
    @memcpy(z, buf.items);
    return z;
}
