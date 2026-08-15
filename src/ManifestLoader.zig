//! Reads a v1 portable manifest into an in-memory `Plugin`.
//!
//! Pipeline: source → `parse` → `validate` against `MetaSchema.schema`
//! → walk → owned `Plugin`. The validation step refuses to materialise
//! a manifest that fails the meta-plugin's structural rules; the walk
//! step assumes a validated tree (so it skips defensive checks the
//! validator already performed).
//!
//! Memory: every string and slice the produced `Plugin` references is
//! allocated from `Result.arena`. Callers `defer result.deinit()` and
//! the arena releases the lot. Plugin instances must NOT outlive their
//! `Result`.
//!
//! See `docs/portable-manifest-v1.md` for the wire-form spec and
//! `manifests/meta.sjon` for the canonical example.

const std = @import("std");
const Ast = @import("Ast.zig");
const Binary = @import("Binary.zig");
const Plugin = @import("Plugin.zig");
const Validator = @import("Validator.zig");
const Schema = @import("Schema.zig");
const MetaSchema = @import("MetaSchema.zig");
const StringFormats = @import("StringFormats.zig");
const Sha256Pin = @import("Sha256Pin.zig");
const Parser = @import("Parser.zig");
const Expr = @import("Expr.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
    /// The tree's root was not a single `(plugin …)` form — the loader
    /// only accepts manifests whose top-level shape passes meta-validation.
    NotAPluginManifest,
};

/// Owned result of `load`. Holds the materialised `Plugin` plus the
/// arena backing every string and slice the plugin references.
///
/// Always pair construction with `defer result.deinit()` — the
/// returned `Plugin` borrows from `arena`.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    /// Materialised plugin. Valid only when `diagnostics` carries no
    /// error-severity entries. Borrowed slices live in `arena`.
    plugin: Plugin.Plugin,
    /// Diagnostics emitted by the meta-validation pre-pass. Arena-owned.
    /// Empty on a successful load; non-empty means meta-validation
    /// rejected the manifest and `plugin` is unpopulated. Callers should
    /// check `hasErrors()` before reading `plugin`.
    diagnostics: []const Ast.Diagnostic,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const Result) bool {
        for (self.diagnostics) |d| if (d.severity == .err) return true;
        return false;
    }
};

/// Materialise a manifest tree into an owned `Plugin`. Validates the
/// tree against the meta-plugin first; on validation failure the
/// returned `Result` carries the diagnostics with an unpopulated
/// `plugin`. Callers gate on `result.hasErrors()` before using
/// `result.plugin`.
///
/// Beyond meta-validation, the loader emits a range of semantic
/// diagnostics the meta-schema cannot express — among them
/// `wrong_underlying` (a `(key …)` `:default` whose tag disagrees with
/// its `:type`, or a refinement pinned to the wrong underlying),
/// `numeric_bounds_invalid` / `string_bounds_invalid` /
/// `vector_bounds_invalid` (contradictory or ill-typed bounds),
/// `exclusive_group_invalid` / `exclusive_bundle_collision` (malformed
/// `(exclusive-group …)`), `unspecified` (an `(expr-func …)` mixing the
/// mono- and multi-signature encodings), and the advisories
/// `license_unrecognized` / `too_many_keywords` / `sjon_format_unsupported`
/// / `plugin_wasm_self_hash_malformed`. All are surfaced under the
/// `plugin`/`form-or-expr-func`/`key-or-…` hierarchical path so consumers
/// can navigate to the offending node.
pub fn load(gpa: Allocator, tree: Ast.Tree) Error!Result {
    // Step 1 — meta-validation. If the manifest doesn't pass, stash
    // diagnostics into a fresh arena and bail without building.
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

    // Steps 2–3 — the tree passed meta-validation; build the Plugin.
    return loadUnchecked(gpa, tree);
}

/// Materialise a manifest tree into an owned `Plugin` *without* the
/// Step-1 meta-validation pre-pass that `load` runs. Use this only for
/// trusted build input — chiefly `manifests/meta.sjon` itself, where
/// meta-validation would be circular (it would validate the source of
/// the very schema being built). `tools/gen_meta_schema.zig` is the
/// canonical caller.
///
/// Still safe on the trusted path: the walk assumes a well-shaped tree
/// the way `buildPlugin` always has, and it continues to emit the
/// loader's own structural diagnostics (`wrong_underlying`,
/// `exclusive_group_invalid`, …). Callers gate on `result.hasErrors()`
/// before using `result.plugin`. On untrusted input the result is
/// not-validated-against-meta-shape, not unsafe — prefer `load` there.
pub fn loadUnchecked(gpa: Allocator, tree: Ast.Tree) Error!Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Step 2 — locate the (plugin …) root. `load`'s meta-validation
    // would have guaranteed the shape; here we re-check structurally
    // because that pre-pass was skipped. An empty tree (zero roots)
    // also lands here.
    if (tree.root.len != 1) return Error.NotAPluginManifest;
    const root = tree.root[0];
    if (tree.tagOf(root) != .form) return Error.NotAPluginManifest;
    const hdr = tree.formHeader(root);
    if (!std.mem.eql(u8, hdr.head, "plugin")) return Error.NotAPluginManifest;

    // Step 3 — walk children and build the Plugin, accumulating any
    // structural diagnostics into `diags`.
    var diags: std.ArrayList(Ast.Diagnostic) = .empty;
    const plugin = try buildPlugin(a, &tree, hdr, &diags);

    return Result{
        .arena = arena,
        .plugin = plugin,
        .diagnostics = try diags.toOwnedSlice(a),
    };
}

// ---------------------------------------------------------------------------
// Internal — tree → Plugin.
// ---------------------------------------------------------------------------

fn copyDiagnostics(a: Allocator, src: []const Ast.Diagnostic) Allocator.Error![]const Ast.Diagnostic {
    const out = try a.alloc(Ast.Diagnostic, src.len);
    for (src, out) |d, *o| o.* = try d.dupe(a);
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
    var cross_ref_providers = std.ArrayList(Plugin.CrossRefProvider).empty;

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
                        if (!Sha256Pin.isWellFormed(pin)) {
                            try emitDiag(a, diags, .plugin_wasm_self_hash_malformed, tree.spanOf(kv.value), &.{"plugin"}, ":wasm-sha256 must be `sha256-<64 lowercase hex chars>`; got `{s}`", .{pin});
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
                            try emitWarning(a, diags, .license_unrecognized, tree.spanOf(kv.value), &.{"plugin"}, ":license `{s}` is not a canonical SPDX identifier", .{lic});
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
                            try emitWarning(a, diags, .too_many_keywords, tree.spanOf(kv.value), &.{"plugin"}, ":keywords has {d} entries; advisory cap is {d}", .{ keywords.len, Plugin.MAX_KEYWORDS });
                        }
                    }
                } else if (std.mem.eql(u8, kv.key, "sjon")) {
                    if (tree.tagOf(kv.value) == .string) {
                        const decl = try a.dupe(u8, tree.stringText(kv.value));
                        if (compareSjonFormat(decl, Plugin.SUPPORTED_SJON_FORMAT) == .gt) {
                            try emitDiag(a, diags, .sjon_format_unsupported, tree.spanOf(kv.value), &.{"plugin"}, "manifest declares `:sjon {s}` but host implements {s}", .{ decl, Plugin.SUPPORTED_SJON_FORMAT });
                        }
                        sjon_format = decl;
                    }
                }
                // :description is declarative metadata not stored on
                // Plugin — `:version` is now captured (above) so resolvers
                // can enforce `(use-plugin … :version …)` pins.
            },
            .form => {
                const sub = tree.formHeader(ci);
                if (std.mem.eql(u8, sub.head, "value-kind")) {
                    try value_kinds.append(a, try buildValueKind(a, tree, sub, diags));
                } else if (std.mem.eql(u8, sub.head, "form")) {
                    try forms.append(a, try buildForm(a, tree, sub, diags, 1));
                } else if (std.mem.eql(u8, sub.head, "expr-func")) {
                    try expr_funcs.append(a, try buildExprFunc(a, tree, sub, diags));
                } else if (std.mem.eql(u8, sub.head, "cross-ref-provider")) {
                    try cross_ref_providers.append(a, try buildCrossRefProvider(a, tree, sub));
                }
                // Meta-validation guarantees no other heads slip through.
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
        .cross_ref_providers = try cross_ref_providers.toOwnedSlice(a),
    };
}

/// Parse `(cross-ref-provider :name uniforms :impl "wasm:extract_uniforms")`
/// into a `Plugin.CrossRefProvider`.
///
/// No diagnostics of its own: `:name` is required by the meta-schema, and
/// there is nothing else to disagree with at this layer — whether the
/// provider is *referenced* coherently is `Schema.validateCrossRefs`'
/// question, and whether it can actually run is the host's. Takes no
/// `diags` for exactly that reason; if a check ever appears here, the
/// parameter comes with it.
///
/// `:impl` follows `buildExprFunc`'s rule verbatim: v1 binds the
/// `wasm:<export>` scheme and leaves every other scheme declaration-only
/// rather than guessing. A provider with neither `impl` nor
/// `wasm_export_name` is legal and surfaces at extraction time as
/// `cross_ref_provider_unavailable` — loud, not silent.
fn buildCrossRefProvider(
    a: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
) Error!Plugin.CrossRefProvider {
    var p: Plugin.CrossRefProvider = .{ .name = "" };
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "name")) {
            p.name = try a.dupe(u8, tree.symbolText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "description")) {
            p.description = try a.dupe(u8, tree.stringText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "impl")) {
            if (tree.tagOf(kv.value) == .string) {
                const s = tree.stringText(kv.value);
                if (std.mem.startsWith(u8, s, "wasm:")) {
                    const name = s["wasm:".len..];
                    if (name.len > 0) {
                        p.wasm_export_name = try a.dupe(u8, name);
                    }
                }
            }
        }
    }
    return p;
}

/// Parse a vector accepting either symbols or strings per element —
/// used for `:authors`. Each element is duped into the arena.
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

/// Curated subset of common SPDX identifiers. Anything outside this set
/// produces an advisory `license_unrecognized` warning — manifests with
/// custom or non-OSI license text are still accepted.
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

/// Compare two `:sjon` format versions of the shape `"<major>.<minor>"`.
/// Returns `.less`/`.equal`/`.greater`. Malformed input compares equal
/// so a typo doesn't masquerade as newer (and the loader's earlier
/// `wrong_underlying`/parse step would have caught a missing string).
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

fn buildValueKind(
    a: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.ValueKind {
    var kind: Plugin.ValueKind = .{ .name = "", .underlying = .symbol };
    // Defer shape parsing until `kind.name` and `kind.underlying` are
    // bound — kvpair ordering isn't fixed and the diagnostic path needs
    // both, plus the union/cross-ref guards need the underlying tag.
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
            // `scalar-or-ref` is a surface shorthand, not a real Underlying
            // variant — it desugars to `union [<base> symbol]` after the
            // loop. Leave `kind.underlying` at its default so the
            // `:underlying union` "missing :union slot" guard below doesn't
            // fire on it; the desugar block sets it to `.union_of`.
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
        // Deferred (like numeric / string bounds) so `kind.name` is bound
        // for the consistency diagnostic regardless of kvpair order.
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
        // Deferred like the other shapes so `kind.underlying` is bound for
        // the consistency diagnostic regardless of kvpair order.
        const r = try buildReprShape(tree, ri);
        try checkReprShapeConsistency(a, tree, ri, kind, diags);
        kind.repr = r;
    }
    if (union_idx) |ui| {
        kind.union_of = try buildUnionShape(a, tree, ui, kind, diags);
    } else if (kind.underlying == .union_of) {
        // Symmetric to the cross-ref guard: an underlying that promises a
        // union must carry the alternatives list. No `:union` kvpair to
        // anchor the diagnostic on, so use the form head's span.
        try emitDiag(a, diags, .wrong_underlying, hdr.head_span, &.{ kind.name, "union" }, "value-kind `{s}` declares `:underlying union` but no `:union (union-shape …)` slot", .{kind.name});
    }
    if (is_scalar_or_ref) {
        if (scalar_or_ref_idx) |si| {
            // Pure load-time desugar: store an ordinary `.union_of` so the
            // validator, exporter, and every downstream consumer see a
            // plain `union [<base> symbol]`.
            kind.union_of = try buildScalarOrRefShape(a, tree, si);
            kind.underlying = .union_of;
        } else {
            // `:underlying scalar-or-ref` without the `:scalar-or-ref (…)`
            // slot — mirror the `:underlying union` missing-slot guard.
            try emitDiag(a, diags, .invalid_manifest, hdr.head_span, &.{ kind.name, "scalar-or-ref" }, "value-kind `{s}` declares `:underlying scalar-or-ref` but no `:scalar-or-ref (scalar-or-ref-shape …)` slot", .{kind.name});
        }
    } else if (scalar_or_ref_idx) |si| {
        // `:scalar-or-ref` present but `:underlying` isn't `scalar-or-ref`.
        try emitDiag(a, diags, .invalid_manifest, tree.spanOf(si), &.{ kind.name, "scalar-or-ref" }, "value-kind `{s}` declares `:scalar-or-ref` but `:underlying` is `{s}`, not `scalar-or-ref`", .{ kind.name, @tagName(kind.underlying) });
    }
    return kind;
}

/// Desugar `(scalar-or-ref-shape :base <kind>)` into a `union [<base>
/// symbol]` UnionShape. `scalar-or-ref` is a load-time shorthand — the
/// stored kind is an ordinary `.union_of`, so the validator
/// (try-each-alternative), the exporter (`oneOf` / `Base | Symbol_<…>`),
/// and every downstream consumer inherit for free; the `symbol`
/// alternative resolves via the union machinery's primitive shortcut.
/// A missing `:base` is only reachable on a manifest that bypassed
/// meta-validation (the meta-schema marks `:base` required); the
/// degenerate `[symbol]` fallback keeps the tree well-formed.
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
    /// Nesting depth of this form. Top-level forms are depth 1; a slot-local
    /// form built from one of this form's keys is depth+1. Threaded so
    /// `buildKey` can reject inline locals deeper than
    /// `Plugin.MAX_LOCAL_FORM_DEPTH` and bound the recursion.
    depth: usize,
) Error!Plugin.FormSpec {
    var spec: Plugin.FormSpec = .{ .name = "" };
    var keys = std.ArrayList(Plugin.KeySpec).empty;
    var key_count: usize = 0;
    var variants = std.ArrayList(Plugin.Variant).empty;
    var groups = std.ArrayList(BuiltGroup).empty;
    var discriminant_span: ?Ast.Span = null;
    var lowering_idx: ?Ast.NodeIndex = null;
    // Positional slot-local `(form …)` children (FormSpec.local_forms).
    // Collected here, built after the sweep once `spec.positional` is known
    // (a `:positional` kvpair may follow the form children in source).
    var local_form_nodes = std.ArrayList(Ast.NodeIndex).empty;

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
                } else if (std.mem.eql(u8, sub.head, "form")) {
                    try local_form_nodes.append(a, ci);
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

    // Resolve discriminant_idx — a discriminant referencing a key not in
    // `keys` is structurally an unknown_key against the form declaration.
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
            try emitDiag(a, diags, .unknown_key, discriminant_span orelse hdr.head_span, &.{ spec.name, "discriminant" }, "form `{s}` declares discriminant `:{s}` but no such key is defined", .{ spec.name, dname });
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

    // Positional slot-local form definitions (FormSpec.local_forms). Inline
    // `(form …)` children directly under this form declare forms scoped to its
    // positional slot, resolved local-first by the validator — the positional
    // mirror of `buildKey`'s keyed slot-locals. Built here (after the child
    // sweep) so `spec.name` and `spec.positional` are known regardless of
    // source order. Guards (each `invalid_manifest` unless noted):
    //   * `:positional (flag-set …)` is incompatible with locals — a flag slot
    //     takes keyword flags, not form children;
    //   * locals present with NO `:positional` imply `.any` (otherwise every
    //     local would be dead behind `positional_not_allowed`);
    //   * nesting must not exceed `Plugin.MAX_LOCAL_FORM_DEPTH` (also bounds
    //     the buildForm→buildForm recursion against a hostile manifest);
    //   * local names must be unique within the form.
    if (local_form_nodes.items.len > 0) {
        if (spec.positional == .flag_set) {
            try emitDiag(a, diags, .invalid_manifest, hdr.head_span, &.{ spec.name, "positional" }, "form `{s}` declares inline positional-local form(s) but its `:positional` is a `(flag-set …)`", .{spec.name});
        } else {
            // Imply `.any` when no `:positional` was declared so the locals are
            // reachable. An explicit `.any` / head-set (`.kind`) keeps its
            // declared shape (a head-set names the local heads — the closed
            // positional-set recipe).
            if (spec.positional == .none) spec.positional = .any;

            var local_forms = std.ArrayList(Plugin.FormSpec).empty;
            for (local_form_nodes.items) |ci| {
                const sub = tree.formHeader(ci);
                const child_depth = depth + 1;
                if (child_depth > Plugin.MAX_LOCAL_FORM_DEPTH) {
                    // Reject and do NOT descend — this bounds the recursion.
                    try emitDiag(a, diags, .invalid_manifest, sub.head_span, &.{ spec.name, "positional" }, "positional-local form `{s}` on `{s}` nests deeper than MAX_LOCAL_FORM_DEPTH ({d})", .{ sub.head, spec.name, Plugin.MAX_LOCAL_FORM_DEPTH });
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
                    try emitDiag(a, diags, .invalid_manifest, sub.head_span, &.{ spec.name, "positional" }, "duplicate positional-local form `{s}` on `{s}`", .{ local.name, spec.name });
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

fn buildVariant(
    a: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    form_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
    /// Nesting depth of the enclosing form (see `buildForm`). Variant keys
    /// may also carry slot-local forms, so the depth is threaded onward.
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

/// Intermediate representation captured during the structural walk of
/// `(exclusive-group …)`. The actual `Plugin.ExclusiveGroup` is produced
/// by `resolveExclusiveGroups` after the enclosing scope's `keys` are
/// known — name validation needs them.
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

/// Validates `built_groups` against the enclosing scope and produces
/// the `Plugin.ExclusiveGroup` slice. Emits `exclusive_group_invalid`
/// for malformed declarations:
///   * group has fewer than 2 alternatives
///   * an alt names a key not declared in `keys`
///   * a key appears in two different groups on the same scope
///   * (form scope only) a group names the discriminant key
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

        // Per-group bundle-collision tracking: a key may not appear in
        // two alternatives of the same group, even when one is inside
        // a multi-key bundle. The cross-group case is handled by
        // `seen_in_any_group` below and emits `exclusive_group_invalid`.
        var seen_in_this_group: std.StringHashMapUnmanaged(void) = .empty;
        defer seen_in_this_group.deinit(a);

        const alts = try a.alloc(Plugin.Alternative, bg.alternatives.len);
        for (bg.alternatives, 0..) |ba, ai| {
            // Validate every name in this alt: must exist in `keys` and
            // must not be the discriminant. Track membership for both
            // the in-group bundle-collision check and the cross-group
            // "same key in two groups" check.
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
                    // Reuse across groups keeps the existing code; the
                    // in-group case is the new bundle-collision diagnostic.
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

/// Shared body for the two exclusive-group diagnostics — identical modulo
/// the `code` and the pre-formatted `reason` tail: same `form `{s}`` /
/// `(variant `:when {s}`)` message prefix, same `…/exclusive-group` path.
fn emitExclusiveInvalid(
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    span: Ast.Span,
    form_name: []const u8,
    variant_when: ?[]const u8,
    code: Ast.Diagnostic.Code,
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
        .code = code,
        .path = path,
    });
}

fn emitExclusiveGroupInvalid(
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    span: Ast.Span,
    form_name: []const u8,
    variant_when: ?[]const u8,
    reason: []const u8,
) Error!void {
    try emitExclusiveInvalid(a, diags, span, form_name, variant_when, .exclusive_group_invalid, reason);
}

/// In-group bundle key collision — one key name referenced by two
/// alternatives of the SAME exclusive-group. Distinct from the
/// cross-group case, which keeps `exclusive_group_invalid`.
fn emitExclusiveBundleCollision(
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    span: Ast.Span,
    form_name: []const u8,
    variant_when: ?[]const u8,
    key_name: []const u8,
) Error!void {
    const reason = try std.fmt.allocPrint(
        a,
        "key `{s}` appears in more than one alt of the same exclusive-group",
        .{key_name},
    );
    try emitExclusiveInvalid(a, diags, span, form_name, variant_when, .exclusive_bundle_collision, reason);
}

fn buildKey(
    a: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    form_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
    /// Nesting depth of the form this key belongs to (see `buildForm`). An
    /// inline slot-local `(form …)` child is built at `depth + 1`.
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
            // Opt-in: suppress the validator's recursive descent into a
            // form-shaped value for this slot (the slot-level type-check
            // still runs). Lets expression-shaped contents like
            // `:default (pi)` pass without a spurious `unknown_form`.
            // See docs/portable-manifest-v1.md §5 and Validator.zig.
            spec.walk_opaque = (tree.tagOf(kv.value) == .boolean_true);
        } else if (std.mem.eql(u8, kv.key, "description")) {
            spec.description = try a.dupe(u8, tree.stringText(kv.value));
        }
    }

    // Type-check + materialise the default after the full kvpair sweep,
    // so `:default` and `:type` may appear in either order.
    if (default_value_idx) |didx| {
        const dtag = tree.tagOf(didx);
        // Form defaults are expression-shaped. Load-time only snapshots
        // them; `Schema.validateDefaults` (aggregate phase) verifies the
        // declared `:result` against `value_type`. Literal tag mismatches
        // still fail here.
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

    // Spec rule (docs/portable-manifest-v1.md §5.1): `:optional` defaults
    // to false when no `:default` is present; true when `:default` is.
    // The struct's Zig default (true) suits in-source plugin declarations
    // but contradicts the manifest convention — fix it here.
    if (!saw_optional) {
        spec.optional = (default_value_idx != null);
    }

    // Slot-local form definitions (KeySpec.local_forms). Inline `(form …)`
    // children of a `(key …)` declare forms scoped to this slot, resolved
    // local-first by the validator. Built after the kvpair sweep so
    // `spec.value_type` and `spec.name` are known regardless of source order.
    // Three load-time guards (each `invalid_manifest`):
    //   * the slot must be `:type form` — locals are meaningless elsewhere;
    //   * nesting must not exceed `Plugin.MAX_LOCAL_FORM_DEPTH` (also bounds
    //     the buildForm→buildKey recursion against a hostile manifest);
    //   * local names must be unique within the slot.
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
            try emitDiag(a, diags, .invalid_manifest, hdr.head_span, &.{ form_name, spec.name }, "key `:{s}` declares inline slot-local form(s) but its `:type` is not `form`", .{spec.name});
        } else {
            var local_forms = std.ArrayList(Plugin.FormSpec).empty;
            for (hdr.children) |ci| {
                if (tree.tagOf(ci) != .form) continue;
                const sub = tree.formHeader(ci);
                const child_depth = depth + 1;
                if (child_depth > Plugin.MAX_LOCAL_FORM_DEPTH) {
                    // Reject and do NOT descend — this bounds the recursion.
                    try emitDiag(a, diags, .invalid_manifest, sub.head_span, &.{ form_name, spec.name }, "slot-local form `{s}` on `:{s}` nests deeper than MAX_LOCAL_FORM_DEPTH ({d})", .{ sub.head, spec.name, Plugin.MAX_LOCAL_FORM_DEPTH });
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
                    try emitDiag(a, diags, .invalid_manifest, sub.head_span, &.{ form_name, spec.name }, "duplicate slot-local form `{s}` on `:{s}`", .{ local.name, spec.name });
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
            // Defer until `func.name` is bound — keep a reference and
            // parse arity after the kvpair sweep so diagnostics can name
            // the owning expr-func regardless of kvpair order.
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
            // v1 binds the `wasm:<export>` scheme (D7); other schemes
            // (`host:<binding-ref>`) stay declaration-only — the loader
            // records nothing and downstream layers leave `impl` null.
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
            // Drop names so downstream code doesn't try to use them.
            func.param_names = null;
        }
    }

    // Multi-signature encoding: collect every `(signature …)` positional
    // child. Mixing mono fields (`:arity`/`:params`/`:rest`/`:result`)
    // with `(signature …)` is rejected per docs/portable-manifest-v1.md
    // §6.2; emit a load-time diagnostic and prefer the multi-signature
    // form so the in-memory plugin reflects the richer encoding.
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
        // Promote to overload encoding: clear mono typed fields so the
        // signature iterator never mixes the two encodings, even if a
        // mixed manifest snuck the mono fields in.
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

/// Returns null on success; otherwise the specific shape violation.
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
    try emitDiag(a, diags, .unspecified, span, &.{expr_func_name}, "expr-func `{s}`: `:param-names` {s}", .{ expr_func_name, detail });
}

// ---------------------------------------------------------------------------
// Default values: AST → Plugin.KeySpec.Default + tag-against-type check.
// ---------------------------------------------------------------------------

fn parseDefault(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) Error!?Plugin.KeySpec.Default {
    return switch (tree.tagOf(idx)) {
        // Manifest defaults are config and don't carry exact-integer
        // semantics; collapse to f64. Exact-integer-aware default storage
        // is a future change if a manifest ever needs u64 > 2^53.
        .number, .number_i64, .number_u64 => Plugin.KeySpec.Default{ .number = tree.numberOf(idx) },
        .number_with_unit => blk: {
            // Unit-bearing numbers carry a suffix the Default union
            // doesn't model; keep the bare number value, drop the unit.
            // Kind-narrowed unit checking is the validator's job at
            // consumption time.
            const nu = tree.numberWithUnitOf(idx);
            break :blk Plugin.KeySpec.Default{ .number = nu.value };
        },
        .string => Plugin.KeySpec.Default{ .string = try a.dupe(u8, tree.stringText(idx)) },
        .symbol => Plugin.KeySpec.Default{ .symbol = try a.dupe(u8, tree.symbolText(idx)) },
        .boolean_true => Plugin.KeySpec.Default{ .boolean = true },
        .boolean_false => Plugin.KeySpec.Default{ .boolean = false },
        .nil => Plugin.KeySpec.Default.nil,
        .vector => blk: {
            // Vectors of expression elements are deferred to a follow-up
            // slice — a top-level expression default (e.g. `:default (vec3 0 0 0)`)
            // is the supported path. Reject the whole vector if any
            // element is form-tagged; recursion handles nested vectors.
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
            // Snapshot enough of the expression to let
            // `Schema.validateDefaults` classify it at aggregate phase.
            // Also encode the subtree as one-root Binary IR so the
            // future materialization pass has an evaluable program to
            // hand `Expr.evalBinary` — done here because the manifest
            // tree is still alive; the encoded bytes live in `a`
            // (manifest arena) and outlive the parse tree.
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
            // Binary.toBinary returns an error set wider than the loader's
            // (NodeCountExceeded, StringTooLong, etc.). Those are encoder-
            // budget failures that cannot fire on a parsed default subtree
            // — the parser's own limits keep us inside the encoder's. Map
            // OOM straight through and treat the rest as unreachable; a
            // future slice can introduce a real diagnostic if needed.
            const program = Binary.toBinary(a, view, Binary.ToBinaryOptions.forMode(.compact)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.OutOfMemory,
            };
            std.debug.assert(hdr.children.len <= std.math.maxInt(u32)); // arg_count is u32
            break :blk Plugin.KeySpec.Default{ .expression = .{
                .head = head_copy,
                .namespace = ns_copy,
                .arg_count = @intCast(hdr.children.len),
                .program = program.data,
            } };
        },
        // Date / time defaults are not yet expressible in the
        // `Plugin.KeySpec.Default` union — manifest authors needing one
        // can use an `(expr ...)` form that evaluates to a date/time.
        // Refinement-driven value-kind defaults can land here in a
        // follow-up when a manifest needs them.
        .date, .time => null,
        // `.kvpair` / `.keyword` cannot appear as kvpair values through
        // the parser.
        .kvpair, .keyword => null,
    };
}

/// Returns the expected English category label when `tag` is incompatible
/// with `expected`; null on match. Mirrors `matchValueAgainstType`'s
/// primitive cases — refinement-aware narrowing of named kinds is
/// deferred to the validator (load-time check covers the common shape
/// errors but doesn't recurse into ValueKind underlying/refinement
/// machinery, which would require a fully-built Schema).
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

// ---------------------------------------------------------------------------
// Loader-emitted diagnostics.
// ---------------------------------------------------------------------------

fn emitDefault(
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    span: Ast.Span,
    form_name: []const u8,
    key_name: []const u8,
    expected: []const u8,
    got: []const u8,
) Error!void {
    try emitDiag(a, diags, .wrong_underlying, span, &.{ form_name, key_name, "default" }, "default value of `:{s}` expects {s}, got {s}", .{ key_name, expected, got });
}

fn emitTooManyKeys(
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    span: Ast.Span,
    form_name: []const u8,
    declared: usize,
) Error!void {
    try emitDiag(a, diags, .too_many_keys, span, &.{form_name}, "form `{s}` declares {d} keys, exceeding the maximum of {d}", .{ form_name, declared, Plugin.MAX_FORM_KEYS });
}

/// Emit a `wrong_underlying` diagnostic for a manifest numeric field
/// whose value can't be narrowed to a non-negative integer ≤ `bound_max`.
/// Catches NaN/Inf, fractional, negative, and oversized inputs that
/// `@intFromFloat` would otherwise reject as illegal behavior.
///
/// `path` must already be arena-owned (e.g. via `pathConcat`); it's
/// stored on the diagnostic verbatim.
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
    try emitDiag(a, diags, .unspecified, span, &.{expr_func_name}, "expr-func `{s}` mixes mono-signature fields (:arity/:params/:rest/:result) " ++ "with `(signature …)` overloads — pick one encoding", .{expr_func_name});
}

fn buildPath(a: Allocator, steps: []const []const u8) Error![]const []const u8 {
    return Ast.dupePath(a, steps);
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

/// Append a diagnostic in one call — collapses the recurring
/// span/severity/code/`allocPrint`/`buildPath` block. Message and path are
/// duped into the loader arena (`a`), released by `Result.deinit`; no
/// per-site errdefer because a partial-OOM failure unwinds to `load`'s
/// `errdefer arena.deinit()`. Mirrors `Lowering.emitDiag`'s call shape.
/// `emitDiag` stamps `.err`; `emitWarning` the two advisory codes.
fn emitDiag(
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    code: Ast.Diagnostic.Code,
    span: Ast.Span,
    path_parts: []const []const u8,
    comptime fmt: []const u8,
    args: anytype,
) Error!void {
    return emitDiagSev(a, diags, .err, code, span, path_parts, fmt, args);
}

fn emitWarning(
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    code: Ast.Diagnostic.Code,
    span: Ast.Span,
    path_parts: []const []const u8,
    comptime fmt: []const u8,
    args: anytype,
) Error!void {
    return emitDiagSev(a, diags, .warning, code, span, path_parts, fmt, args);
}

fn emitDiagSev(
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    severity: Ast.Diagnostic.Severity,
    code: Ast.Diagnostic.Code,
    span: Ast.Span,
    path_parts: []const []const u8,
    comptime fmt: []const u8,
    args: anytype,
) Error!void {
    try diags.append(a, .{
        .span = span,
        .message = try std.fmt.allocPrint(a, fmt, args),
        .severity = severity,
        .code = code,
        .path = try buildPath(a, path_parts),
    });
}

// ---------------------------------------------------------------------------
// Numeric narrowing — meta-validation only proves "is a number"; the
// loader has to refuse fractional / negative / NaN / oversized values
// before `@intFromFloat` would invoke illegal behavior.
// ---------------------------------------------------------------------------

/// Narrow `n` to `T` (an unsigned int type) iff it's a finite, integral,
/// non-negative value within `T`'s range. Returns null otherwise.
fn boundedInt(comptime T: type, n: f64) ?T {
    if (std.math.isNan(n) or std.math.isInf(n)) return null;
    if (@floor(n) != n) return null;
    const min_f: f64 = @floatFromInt(std.math.minInt(T));
    const max_f: f64 = @floatFromInt(std.math.maxInt(T));
    if (n < min_f or n > max_f) return null;
    return @intFromFloat(n);
}

/// Read a numeric kvpair / positional value, tolerating every numeric
/// tag (`.number`, `.number_with_unit`, `.number_i64`, `.number_u64`).
/// Meta-validation accepts any for `:number`-typed slots; the integer
/// tags use `numberOf`'s polymorphic f64 conversion (lossy beyond 2^53).
fn numericValue(tree: *const Ast.Tree, idx: Ast.NodeIndex) f64 {
    return switch (tree.tagOf(idx)) {
        .number, .number_i64, .number_u64 => tree.numberOf(idx),
        .number_with_unit => tree.numberWithUnitOf(idx).value,
        else => unreachable,
    };
}

const PositionalNumber = struct { value: f64, span: Ast.Span };

/// First numeric positional child of `hdr`, or null if none. Used by
/// arity heads `(fixed N)` / `(at-least N)`.
fn firstPositionalNumber(tree: *const Ast.Tree, hdr: Ast.FormHeader) ?PositionalNumber {
    for (hdr.children) |ci| {
        const tag = tree.tagOf(ci);
        if (tag.isNumber() or tag == .number_with_unit) {
            return .{ .value = numericValue(tree, ci), .span = tree.spanOf(ci) };
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Refinement sub-shapes.
// ---------------------------------------------------------------------------

/// Read a `(vector-shape …)` length kvpair (`:len` / `:min-len` /
/// `:max-len`) as a bounded `u16`. An out-of-range value emits a range
/// diagnostic and yields null (the field stays unset), matching the
/// original `:len` handling.
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

/// Post-load checks on a parsed `VectorShape`. Diagnostics, not aborts:
///   * `:len` combined with `:min-len`/`:max-len` (a fixed length already
///     subsumes a range — keep arity semantics unambiguous);
///   * `:min-len > :max-len` (empty range).
/// Mirrors `checkNumericBoundsConsistency` / `checkStringBoundsConsistency`.
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
        try emitDiag(a, diags, .vector_bounds_invalid, span, &.{ kind.name, "vector" }, "value-kind `{s}` `:vector` sets a fixed `:len` together with `:min-len`/`:max-len` — a fixed length already subsumes a range", .{kind.name});
    }
    if (shape.min_len) |mn| if (shape.max_len) |mx| {
        if (mn > mx) {
            try emitDiag(a, diags, .vector_bounds_invalid, span, &.{ kind.name, "vector" }, "value-kind `{s}` `:vector` has empty range: :min-len {d} > :max-len {d}", .{ kind.name, mn, mx });
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

/// Post-load checks on a parsed `UnitShape`. Diagnostics, not aborts.
/// `:reject true` (bare numbers only) contradicts both `:required true`
/// (a unit is mandatory) and a non-empty `:allowed` list (specific units
/// are permitted) — either pairing is an authoring mistake, flagged as
/// `invalid_manifest` so the validator never sees an incoherent shape.
/// No-op unless `:reject` is set; an unset `reject` keeps the old
/// required/allowed behaviour untouched.
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
        try emitDiag(a, diags, .invalid_manifest, span, &.{ kind.name, "unit", "reject" }, "value-kind `{s}` `:unit` sets both `:reject true` and `:required true` — a slot cannot forbid and demand a unit", .{kind.name});
    }
    if (unit.allowed.len != 0) {
        try emitDiag(a, diags, .invalid_manifest, span, &.{ kind.name, "unit", "reject" }, "value-kind `{s}` `:unit` sets `:reject true` but also lists `:allowed` units — these contradict", .{kind.name});
    }
}

/// Symbol → `Repr` lookup for the `(repr-shape :type …)` slot. The
/// meta-schema's `repr-type-tag` MemberSet gates entry, so a name outside
/// this set is only reachable on a manifest that bypassed validation.
const repr_by_name = std.StaticStringMap(Plugin.ValueKind.Repr).initComptime(.{
    .{ "f32", .f32 },
    .{ "u32", .u32 },
    .{ "i32", .i32 },
    .{ "u16", .u16 },
    .{ "f16", .f16 },
});

/// Parse `(repr-shape :type <f32|u32|i32|u16|f16>)` into a `Repr`. The
/// `:type` key is `:optional false` in the meta-schema, so a well-typed
/// manifest always carries it; a bypassed manifest falls back to `.f32`
/// (benign — the loader's caller refuses a manifest that produced
/// diagnostics). No allocation: the `Repr` is a plain enum.
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

/// Post-load check on a parsed `Repr`. `:repr` only refines a `.number`
/// underlying; on any other underlying it is an authoring mistake,
/// flagged `invalid_manifest` (mirroring the unit/numeric consistency
/// precedent — there is no repr-specific manifest-clash code). Diagnostic,
/// not abort: the kind is still stored, so the validator simply never
/// fires the repr check on a non-number value.
fn checkReprShapeConsistency(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind: Plugin.ValueKind,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!void {
    if (kind.underlying == .number) return;
    try emitDiag(a, diags, .invalid_manifest, tree.spanOf(idx), &.{ kind.name, "repr" }, "value-kind `{s}` declares `:repr` but `:underlying` is `{s}`, not `number`", .{ kind.name, @tagName(kind.underlying) });
}

/// Parse `(numeric-bounds :min … :max … :exclusive-min … :exclusive-max
/// … :integer …)` into a `Plugin.ValueKind.NumericBounds`. Per-bound
/// shape checks (consistency between `:min`/`:max`/`:exclusive-*` and
/// the owning kind's `:underlying`) happen in `buildValueKind`, since
/// the `:underlying` kvpair may not be parsed yet when this runs.
///
/// Each bound's `exact_int` flag tracks whether the literal was lexed
/// as `Tag.number_i64` / `Tag.number_u64` — the validator picks an
/// integer-space comparison when both bound and value are exact,
/// avoiding f64 round-trip loss near 2^53.
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

/// Read one bound literal: a numeric AST node (any of the four numeric
/// tags). The meta-schema's `:min` / `:max` `KeySpec.value_type =
/// .number` gate already rejects non-numeric values, so the `else`
/// arm here is unreachable on a well-typed manifest.
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
        else => unreachable, // meta-schema's :number gate guarantees a numeric tag.
    };
}

/// Post-load checks on a parsed `NumericBounds`. Diagnostics, not aborts:
///   * `:numeric` on a kind whose `:underlying` is not `number`;
///   * `:exclusive-min true` without `:min` (and the `:max` symmetric);
///   * `:min > :max` when both bounds share a unit (or both are unitless).
/// Bounds with mismatched units are not directly comparable here — that
/// case surfaces later as `numeric_bound_unit_mismatch` at validate time.
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
        try emitDiag(a, diags, .numeric_bounds_invalid, span, &.{ kind.name, "numeric" }, "value-kind `{s}` declares `:numeric` but `:underlying` is `{s}`, not `number`", .{ kind.name, @tagName(kind.underlying) });
    }
    if (bounds.exclusive_min and bounds.min == null) {
        try emitDiag(a, diags, .numeric_bounds_invalid, span, &.{ kind.name, "numeric", "exclusive-min" }, "value-kind `{s}` `:numeric` sets `:exclusive-min true` but `:min` is absent", .{kind.name});
    }
    if (bounds.exclusive_max and bounds.max == null) {
        try emitDiag(a, diags, .numeric_bounds_invalid, span, &.{ kind.name, "numeric", "exclusive-max" }, "value-kind `{s}` `:numeric` sets `:exclusive-max true` but `:max` is absent", .{kind.name});
    }
    if (bounds.min) |mn| if (bounds.max) |mx| {
        const same_unit = (mn.unit == null and mx.unit == null) or
            (mn.unit != null and mx.unit != null and std.mem.eql(u8, mn.unit.?, mx.unit.?));
        if (same_unit and mn.value > mx.value) {
            try emitDiag(a, diags, .numeric_bounds_invalid, span, &.{ kind.name, "numeric" }, "value-kind `{s}` `:numeric` has empty range: :min {d} > :max {d}", .{ kind.name, mn.value, mx.value });
        }
    };
}

/// One parsed `(string-bounds …)` field. `value_raw` preserves the
/// f64 sign + magnitude so the consistency check can flag negatives
/// before truncation to `u32` smears `-1` into `4_294_967_295`.
const RawLen = struct {
    value_raw: f64,
};

/// Parse `(string-bounds :min-len … :max-len … :pattern … :format …)`
/// into a `Plugin.ValueKind.StringBounds`. Lengths are truncated to `u32`
/// (`lenFromNumber`); the raw f64 sign/fractional check runs separately in
/// `checkStringBoundsConsistency` (via `findRawLen`), which flags negatives
/// before truncation smears `-1` into `4_294_967_295`.
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
            // The meta-schema's `string-format-tag` member-set rejects
            // unknown text at load time, so `fromName` is total here.
            bounds.format = StringFormats.fromName(tree.symbolText(kv.value));
        }
    }
    return bounds;
}

/// Truncate a numeric AST node to `u32` for length storage. Negative
/// or fractional values are detected by the consistency check below
/// (which sees the raw f64 via `lenRawFromNumber`).
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
        .number => .{ .value_raw = tree.numberOf(idx) },
        .number_i64 => .{ .value_raw = @floatFromInt(tree.numberI64Of(idx)) },
        .number_u64 => .{ .value_raw = @floatFromInt(tree.numberU64Of(idx)) },
        .number_with_unit => .{ .value_raw = tree.numberWithUnitOf(idx).value },
        else => unreachable, // meta-schema's :number gate guarantees a numeric tag.
    };
}

/// Post-load checks on a parsed `StringBounds`. Diagnostics, not aborts:
///   * `:string-bounds` on a kind whose `:underlying` is not `string`;
///   * negative `:min-len` or `:max-len`;
///   * `:min-len > :max-len` (empty range);
///   * empty `:pattern ""` (no useful semantics);
///   * member cross-check: any literal in `kind.members` that fails
///     the declared length / format constraint.
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
        try emitDiag(a, diags, .string_bounds_invalid, span, &.{ kind.name, "string-bounds" }, "value-kind `{s}` declares `:string-bounds` but `:underlying` is `{s}`, not `string`", .{ kind.name, @tagName(kind.underlying) });
    }

    if (try findRawLen(tree, idx, "min-len")) |raw| {
        if (raw.value_raw < 0) {
            try emitDiag(a, diags, .string_bounds_invalid, span, &.{ kind.name, "string-bounds", "min-len" }, "value-kind `{s}` `:string-bounds` has negative :min-len {d}", .{ kind.name, raw.value_raw });
        }
    }
    if (try findRawLen(tree, idx, "max-len")) |raw| {
        if (raw.value_raw < 0) {
            try emitDiag(a, diags, .string_bounds_invalid, span, &.{ kind.name, "string-bounds", "max-len" }, "value-kind `{s}` `:string-bounds` has negative :max-len {d}", .{ kind.name, raw.value_raw });
        }
    }

    if (bounds.min_len) |mn| if (bounds.max_len) |mx| {
        if (mn > mx) {
            try emitDiag(a, diags, .string_bounds_invalid, span, &.{ kind.name, "string-bounds" }, "value-kind `{s}` `:string-bounds` has empty range: :min-len {d} > :max-len {d}", .{ kind.name, mn, mx });
        }
    };

    if (bounds.pattern) |p| {
        if (p.len == 0) {
            try emitDiag(a, diags, .string_bounds_invalid, span, &.{ kind.name, "string-bounds", "pattern" }, "value-kind `{s}` `:string-bounds :pattern` is the empty string", .{kind.name});
        }
    }

    // Member cross-check: a closed `(member-set …)` whose literals
    // themselves fail the declared bounds is almost certainly an
    // author error — flag at load time so the validator can apply
    // members-or-bounds in either order without divergence.
    if (kind.underlying == .string) if (kind.members) |ms| {
        for (ms.members) |m| {
            const cp = std.unicode.utf8CountCodepoints(m.name) catch m.name.len;
            if (bounds.min_len) |mn| if (cp < mn) {
                try emitDiag(a, diags, .string_bounds_invalid, span, &.{ kind.name, "string-bounds", "min-len" }, "value-kind `{s}` member \"{s}\" has length {d} < :min-len {d}", .{ kind.name, m.name, cp, mn });
            };
            if (bounds.max_len) |mx| if (cp > mx) {
                try emitDiag(a, diags, .string_bounds_invalid, span, &.{ kind.name, "string-bounds", "max-len" }, "value-kind `{s}` member \"{s}\" has length {d} > :max-len {d}", .{ kind.name, m.name, cp, mx });
            };
            if (bounds.format) |fmt| if (!StringFormats.check(fmt, m.name)) {
                try emitDiag(a, diags, .string_bounds_invalid, span, &.{ kind.name, "string-bounds", "format" }, "value-kind `{s}` member \"{s}\" does not satisfy :format `{s}`", .{ kind.name, m.name, @tagName(fmt) });
            };
        }
    };
}

/// Look up the raw f64 value of an optional `:<key>` kvpair on a
/// `(string-bounds …)` form. Returns null when the key is absent.
fn findRawLen(tree: *const Ast.Tree, idx: Ast.NodeIndex, key: []const u8) Error!?RawLen {
    const hdr = tree.formHeader(idx);
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, key)) return lenRawFromNumber(tree, kv.value);
    }
    return null;
}

/// Parse a `(member-set …)` form into a `MemberSet`.
///
/// Two authoring shapes are accepted:
///   * Compact — `(member-set :values [a b c])`, one entry per bare
///     name with only `Member.name` populated.
///   * Rich — `(member-set (member :name a :label "A" …) …)`, each
///     `(member …)` positional child parsed as a full `Member`.
///
/// Mixing both within one `(member-set …)` is an `invalid_manifest`
/// error. The loader still returns a populated set (whichever shape
/// appeared) to keep downstream validation flowing — diagnostics are
/// the contract, not an abort. Likewise an empty `(member-set)` (no
/// `:values`, no `(member …)`) emits `invalid_manifest` at the form
/// head and returns an empty set; the validator treats `members.len
/// == 0` as "no narrowing".
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
        try emitDiag(a, diags, .invalid_manifest, hdr.head_span, &.{ kind_name, "members" }, "value-kind `{s}` `:members` mixes `:values` and `(member …)` children — pick one shape", .{kind_name});
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
                    try emitDiag(a, diags, .invalid_manifest, tree.spanOf(ci), &.{ kind_name, "members" }, "value-kind `{s}` `:members` declares duplicate member `{s}`", .{ kind_name, out[wi].name });
                    break;
                }
            }
            wi += 1;
        }
        return .{ .members = out };
    }

    try emitDiag(a, diags, .invalid_manifest, hdr.head_span, &.{ kind_name, "members" }, "value-kind `{s}` `:members` declares no members (need `:values …` or `(member …)` children)", .{kind_name});
    return .{ .members = &.{} };
}

/// Parse one `(member :name X :label "…" …)` form into a `Member`.
/// The meta-schema enforces `:name` is required and symbol-typed; this
/// helper trusts that and reads the other fields opportunistically.
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

/// Parse `(cross-ref :target <symbol> :name-key <symbol>?)` into a
/// `Plugin.ValueKind.CrossRef`. Per-plugin shape check: the owning kind
/// must have `:underlying symbol`. Cross-plugin resolution of `:target`
/// and `:name-key` typing happens later in the schema-aggregate phase
/// (`Schema.validateCrossRefs`) — at this layer we only have one plugin
/// at a time.
fn buildCrossRef(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind: Plugin.ValueKind,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.ValueKind.CrossRef {
    const hdr = tree.formHeader(idx);
    var cr: Plugin.ValueKind.CrossRef = .{ .target_form = "" };
    // Track *written* keys, not values: `:name-key name` and `:source-key
    // src` are indistinguishable from their defaults once landed, and the
    // exclusions below are about what the author spelled.
    var saw_name_key = false;
    var saw_source_key = false;
    var span_name_key: Ast.Span = .{ .start = 0, .end = 0 };
    var span_source_key: Ast.Span = .{ .start = 0, .end = 0 };
    var span_acyclic: Ast.Span = .{ .start = 0, .end = 0 };
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "target")) {
            cr.target_form = try a.dupe(u8, tree.symbolText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "name-key")) {
            cr.name_key = try a.dupe(u8, tree.symbolText(kv.value));
            saw_name_key = true;
            span_name_key = kv.key_span;
        } else if (std.mem.eql(u8, kv.key, "acyclic")) {
            cr.acyclic = (tree.tagOf(kv.value) == .boolean_true);
            span_acyclic = kv.key_span;
        } else if (std.mem.eql(u8, kv.key, "scope")) {
            cr.scope_form = try a.dupe(u8, tree.symbolText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "provider")) {
            cr.provider = try a.dupe(u8, tree.symbolText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "source-key")) {
            cr.source_key = try a.dupe(u8, tree.symbolText(kv.value));
            saw_source_key = true;
            span_source_key = kv.key_span;
        }
    }

    // Route exclusions (§4.6). Each is `invalid_manifest` — the same code
    // the `:reject`/`:required` unit contradiction uses, since these are
    // the same *class* of error: a shape that is internally incoherent
    // rather than externally unresolvable.
    //
    // Every offending key is also dropped, not merely reported. A partly
    // honoured contradiction is worse than either reading: downstream
    // (`Schema.validateCrossRefs`, the index pass) then only ever sees a
    // spec that took exactly one route.
    if (cr.provider != null) {
        if (saw_name_key) {
            try emitDiag(a, diags, .invalid_manifest, span_name_key, &.{ kind.name, "cross-ref", "name-key" }, "value-kind `{s}` `:cross-ref` sets both `:provider` and `:name-key` — the two extraction routes are exclusive", .{kind.name});
            cr.name_key = "name";
        }
        if (cr.acyclic) {
            try emitDiag(a, diags, .invalid_manifest, span_acyclic, &.{ kind.name, "cross-ref", "acyclic" }, "value-kind `{s}` `:cross-ref` sets both `:provider` and `:acyclic true` — cycle edges are defined per declaration site, and extracted names share one source span", .{kind.name});
            cr.acyclic = false;
        }
    } else if (saw_source_key) {
        try emitDiag(a, diags, .invalid_manifest, span_source_key, &.{ kind.name, "cross-ref", "source-key" }, "value-kind `{s}` `:cross-ref` sets `:source-key` without `:provider` — nothing reads it on the identity route", .{kind.name});
        cr.source_key = "src";
    }

    if (kind.underlying != .symbol) {
        try emitDiag(a, diags, .wrong_underlying, tree.spanOf(idx), &.{ kind.name, "cross-ref" }, "value-kind `{s}` declares `:cross-ref` but `:underlying` is `{s}`, not `symbol`", .{ kind.name, @tagName(kind.underlying) });
    }
    return cr;
}

/// Parse `(union-shape :alternatives [a b c])` into a
/// `Plugin.ValueKind.UnionShape`. Per-plugin shape checks (mirror
/// `buildCrossRef`): the owning kind's `:underlying` must be `union`,
/// and `:alternatives` must list at least two distinct names. Catalog
/// resolution and the no-nested-union check happen later in the
/// schema-aggregate phase (`Schema.validateUnions`).
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
        try emitDiag(a, diags, .wrong_underlying, tree.spanOf(idx), &.{ kind.name, "union" }, "value-kind `{s}` declares `:union` but `:underlying` is `{s}`, not `union`", .{ kind.name, @tagName(kind.underlying) });
    }
    if (alts.len < 2) {
        try emitDiag(a, diags, .wrong_underlying, alts_span, &.{ kind.name, "union", "alternatives" }, "value-kind `{s}` `:union` requires at least two alternatives, got {d}", .{ kind.name, alts.len });
    }
    // Duplicate-name detection. O(n²) is fine — alternatives lists are
    // tiny in practice and this only runs at manifest load.
    for (alts, 0..) |alt, i| {
        for (alts[0..i]) |prev| {
            if (std.mem.eql(u8, alt.name, prev.name)) {
                try emitDiag(a, diags, .wrong_underlying, alts_span, &.{ kind.name, "union", "alternatives" }, "value-kind `{s}` `:union` alternative `{s}` listed twice", .{ kind.name, alt.name });
                break;
            }
        }
    }
    return .{ .alternatives = alts };
}

/// Like `parseSymbolList`, but each entry is a `Plugin.QualifiedRef`.
/// Honours the `plugin/kind` split — `paint/color` becomes
/// `{ name = "color", namespace = "paint" }`; bare `color` becomes
/// `{ name = "color", namespace = null }`. Used by `:union :alternatives`
/// on `(union-shape …)` so collision-resistant manifests can write
/// alternatives that resolve unambiguously even when bare names overlap.
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

/// Parse `(lowering :hook <symbol> :produces [<sym> …])` into a
/// `Plugin.LoweringSpec`. The validator (driven by meta.sjon) already
/// rejects a missing `:hook` or `:produces` kvpair via
/// `missing_required_key`, so this function focuses on content checks
/// the type system can't express:
///
/// - empty `:hook` symbol (e.g. `:hook ""` would not parse, but a
///   bare empty produces list is reachable),
/// - empty `:produces` list,
/// - duplicate entries in `:produces`.
///
/// Cross-plugin resolution of `:produces` entries (every head names a
/// known form, bare entries are unambiguous) is a schema-aggregate
/// concern and lives in `Schema.validateLowering` (later phase).
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
        try emitDiag(a, diags, .wrong_underlying, produces_span, &.{ form_name, "lowering", "produces" }, "form `{s}` `:lowering` requires at least one produced head, got 0", .{form_name});
    }
    // Duplicate-head detection. Same shape as buildUnionShape — produces
    // lists are tiny in practice, O(n²) is the right tradeoff.
    for (spec.produces, 0..) |name, i| {
        for (spec.produces[0..i]) |prev| {
            if (std.mem.eql(u8, name, prev)) {
                try emitDiag(a, diags, .wrong_underlying, produces_span, &.{ form_name, "lowering", "produces" }, "form `{s}` `:lowering` produces head `{s}` listed twice", .{ form_name, name });
                break;
            }
        }
    }
    return spec;
}

// ---------------------------------------------------------------------------
// Atom / list helpers.
// ---------------------------------------------------------------------------

const underlying_by_name = std.StaticStringMap(Plugin.ValueKind.Underlying).initComptime(.{
    .{ "number", .number },
    .{ "string", .string },
    .{ "vector", .vector },
    .{ "form", .form },
    .{ "symbol", .symbol },
    .{ "union", .union_of },
});

fn parseUnderlying(tree: *const Ast.Tree, idx: Ast.NodeIndex) Error!Plugin.ValueKind.Underlying {
    // Meta-validation enforces the underlying-tag MemberSet, so a miss is
    // only reachable on a manifest that bypassed validation. Return a
    // benign default; the loader's caller should refuse the result.
    return underlying_by_name.get(tree.symbolText(idx)) orelse .symbol;
}

const value_type_by_name = std.StaticStringMap(Plugin.ValueType).initComptime(.{
    .{ "any", .any },
    .{ "number", .number },
    .{ "string", .string },
    .{ "symbol", .symbol },
    .{ "boolean", .boolean },
    .{ "nil", .nil },
    .{ "vector", .vector },
    .{ "form", .form },
    .{ "expr", .expr },
});

fn parseValueType(a: Allocator, tree: *const Ast.Tree, idx: Ast.NodeIndex) Error!Plugin.ValueType {
    const sym = tree.symbolText(idx);
    return value_type_by_name.get(sym) orelse .{ .named = try parseQualifiedRef(a, sym) };
}

fn parsePositional(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    form_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.PositionalSpec {
    // A form-valued `:positional` is `(flag-set (flag :name …) …)`; a bare
    // symbol is `any` or a value-kind reference.
    if (tree.tagOf(idx) == .form) return try parseFlagSet(a, tree, idx, form_name, diags);
    const sym = tree.symbolText(idx);
    if (std.mem.eql(u8, sym, "any")) return .any;
    return .{ .kind = try parseQualifiedRef(a, sym) };
}

/// Parse `(flag-set (flag :name done) (flag :name archived))` into a
/// `FlagSet`. Mirrors `buildMemberSet`'s rich-children branch: each
/// positional `(flag …)` child contributes its `:name`. The meta-schema
/// pins the children to the `flag` head, so this trusts the shape and
/// reads `:name` opportunistically. Emits `invalid_manifest` when the set
/// declares no flags.
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
        // Reject a flag name declared twice in one set (mirrors
        // `buildMemberSet`'s duplicate-member scan). The duplicate is
        // still kept so membership checks behave; the diagnostic is the
        // load-time signal.
        for (flags.items) |prior| {
            if (std.mem.eql(u8, prior.name, flag.name)) {
                try emitDiag(a, diags, .invalid_manifest, tree.spanOf(ci), &.{ form_name, "positional" }, "form `{s}` `:positional (flag-set …)` declares duplicate flag `{s}`", .{ form_name, flag.name });
                break;
            }
        }
        try flags.append(a, flag);
    }
    if (flags.items.len == 0) {
        try emitDiag(a, diags, .invalid_manifest, hdr.head_span, &.{ form_name, "positional" }, "form `{s}` `:positional (flag-set …)` declares no flags (need `(flag :name …)` children)", .{form_name});
    }
    return .{ .flag_set = .{ .flags = try flags.toOwnedSlice(a) } };
}

/// Parse one `(flag :name done :description … :link …)` form into a
/// `Flag`. Mirrors `parseMemberDecl`; trusts the meta-schema that `:name`
/// is present and symbol-typed and that `:description`/`:link` are
/// string-typed when present. `name` is "" when `:name` is absent (the
/// caller drops such flags); `description` defaults to "" and `link` to
/// null. The validator matches on `name` alone — the metadata is for
/// hovers, schema export, and docs.
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

/// Parse a possibly-qualified value-kind reference from a symbol text.
/// `plugin/kind` becomes `{ name = "kind", namespace = "plugin" }`; bare
/// `kind` becomes `{ name = "kind", namespace = null }`. Both `name` and
/// `namespace` are arena-owned dupes so the caller does not retain a
/// borrow into the parse tree.
fn parseQualifiedRef(a: Allocator, sym: []const u8) Error!Plugin.QualifiedRef {
    const split = Parser.splitNamespace(sym);
    return .{
        .name = try a.dupe(u8, split.name),
        .namespace = if (split.namespace) |ns| try a.dupe(u8, ns) else null,
    };
}

/// Parse a `(fixed N)` / `(at-least N)` / `(range :min M :max N)` form
/// into an `Arity`. `arity_path` is the diagnostic path of the arity
/// slot itself (e.g. `&.{func, "arity"}` for mono encoding,
/// `&.{func, "signature", "arity"}` for overloads); leaf steps are
/// appended for sub-fields. Out-of-range narrowings emit a
/// `wrong_underlying` diagnostic and fall back to a zero default.
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
    // (range :min M :max N)
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// The bulk of ManifestLoader's tests live in the sibling `ManifestLoader_tests.zig`
// (wired at the bottom of this section). Only the test below stays inline: it
// exercises the private helper `compareSjonFormat` directly, which the sibling
// — reaching ManifestLoader through its public surface — cannot. (Sha256-pin
// well-formedness now lives in the `Sha256Pin` leaf and is tested there.)

const testing = std.testing;

test "ManifestLoader: compareSjonFormat orders correctly" {
    try testing.expectEqual(std.math.Order.eq, compareSjonFormat("1.0", "1.0"));
    try testing.expectEqual(std.math.Order.lt, compareSjonFormat("1.0", "1.1"));
    try testing.expectEqual(std.math.Order.gt, compareSjonFormat("2.0", "1.9"));
    try testing.expectEqual(std.math.Order.gt, compareSjonFormat("1.10", "1.9"));
    // Malformed input is equal — refuses to escalate on parse error.
    try testing.expectEqual(std.math.Order.eq, compareSjonFormat("abc", "1.0"));
}

test {
    _ = @import("ManifestLoader_tests.zig");
}
