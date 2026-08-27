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
/// `license_unrecognized` / `too_many_keywords` /
/// `plugin_wasm_self_hash_malformed`. All are surfaced under the
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
    var members_idx: ?Ast.NodeIndex = null;
    var is_scalar_or_ref = false;

    // `:name` in its own pass, before anything that reports against it.
    // Two of the shapes below — `:members` and `:heads` — build *inside*
    // the loop and their diagnostics name the kind, so a manifest that
    // spells `:members` before `:name` used to get "value-kind ``" and a
    // path missing its first step. Ordering inside a form is not
    // significant anywhere else in SJON and must not be here either;
    // `hosts/typescript-parity`'s `buildValueKind` already ran this pass,
    // so this is the reference catching up to the port. Last-wins on a
    // repeated `:name`, as the single loop was.
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "name")) {
            kind.name = try a.dupe(u8, tree.symbolText(kv.value));
        }
    }

    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "name")) {
            // Bound in the pass above.
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
            members_idx = kv.value;
            kind.members = try buildMemberSet(a, tree, kv.value, kind.name, diags);
        } else if (std.mem.eql(u8, kv.key, "heads")) {
            kind.heads = try buildHeadSet(a, tree, kv.value, kind.name, diags);
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
            // Pure load-time desugar: store an ordinary `.union_of`, and
            // nothing else. The validator, the exporter, and every other
            // consumer see a plain `union [<base> <ref>]` and cannot tell
            // the shorthand from a union spelled out by hand.
            kind.union_of = try buildScalarOrRefShape(a, tree, si, kind.name, diags);
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
    // Last, so the underlying it quotes is the final one — a
    // `scalar-or-ref` kind reads as `union_of` here, which is what it is.
    if (members_idx) |mi| if (kind.members) |ms| {
        try checkMemberSetConsistency(a, tree, mi, kind, ms, diags);
    };
    return kind;
}

/// Desugar `(scalar-or-ref-shape :base <kind> :ref <kind>?)` into a
/// `union [<base> <ref>]` UnionShape. `scalar-or-ref` is a load-time
/// shorthand — the stored kind is an ordinary `.union_of`, so the
/// validator (try-each-alternative), the exporter (`oneOf` /
/// `Base | Symbol_<…>`), and every downstream consumer inherit for free —
/// reporting included. The two arms are disjoint by node shape, so a
/// number or a symbol always has a determined arm and the validator names
/// that arm's own failure (`number_above_max`, `not_cross_ref`, …); it is
/// the general union rule, not an exception carried for the shorthand.
///
/// `:ref` defaults to the primitive `symbol`, which is what the shorthand
/// meant before the key existed and resolves via the union machinery's
/// primitive shortcut — an *unchecked* name, accepting any spelling. A
/// `:ref` naming a cross-ref kind instead makes the reference half
/// checked, so a misspelling is `not_cross_ref` rather than silently
/// fine. The default is load-bearing for compatibility; do not change it.
///
/// Only one rejection lives here: `:ref` equal to `:base`, which spells a
/// single-alternative union twice (`UnionShape` requires ≥2 distinct
/// alternatives). Whether `:ref` names a *union* kind is deliberately
/// **not** checked here — value-kinds are appended in declaration order
/// (see the `buildValueKind` call site), so this function sees only the
/// kinds declared above it and a check would accept or reject the same
/// manifest depending on where the union sits. `Schema.validateUnions`
/// resolves every alternative against the complete aggregated catalog and
/// emits `nested_union` there, order-independently.
///
/// A missing `:base` is only reachable on a manifest that bypassed
/// meta-validation (the meta-schema marks `:base` required); the
/// degenerate `[symbol]` fallback keeps the tree well-formed and ignores
/// any `:ref`, since substituting into an already-malformed kind buys
/// nothing.
fn buildScalarOrRefShape(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.ValueKind.UnionShape {
    const hdr = tree.formHeader(idx);
    var base: ?Plugin.QualifiedRef = null;
    var ref: Plugin.QualifiedRef = .{ .name = "symbol", .namespace = null };
    var ref_span: ?Ast.Span = null;
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "base")) {
            base = try parseQualifiedRef(a, tree.symbolText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "ref")) {
            ref = try parseQualifiedRef(a, tree.symbolText(kv.value));
            ref_span = tree.spanOf(ci);
        }
    }
    const alts = if (base) |b| two: {
        if (qualifiedRefEql(b, ref)) {
            // `union [x x]` is one alternative spelled twice. Anchor on the
            // `:ref` kvpair — it is the key that made the pair degenerate,
            // and `:base` is the one the author meant to keep.
            try emitDiag(a, diags, .invalid_manifest, ref_span orelse tree.spanOf(idx), &.{ kind_name, "scalar-or-ref" }, "value-kind `{s}` declares `:ref` equal to `:base` (`{s}`); a scalar-or-ref needs two distinct alternatives", .{ kind_name, ref.name });
        }
        const slice = try a.alloc(Plugin.QualifiedRef, 2);
        slice[0] = b;
        slice[1] = ref;
        break :two slice;
    } else one: {
        const slice = try a.alloc(Plugin.QualifiedRef, 1);
        slice[0] = .{ .name = "symbol", .namespace = null };
        break :one slice;
    };
    return .{ .alternatives = alts };
}

/// Byte-equality on both halves of a `QualifiedRef`. Matches the
/// resolution rule elsewhere in the loader: a bare name and a qualified
/// one are different refs even when the qualified one names this plugin,
/// because namespace canonicalisation is a host concern.
fn qualifiedRefEql(x: Plugin.QualifiedRef, y: Plugin.QualifiedRef) bool {
    if (!std.mem.eql(u8, x.name, y.name)) return false;
    if (x.namespace) |xn| {
        const yn = y.namespace orelse return false;
        return std.mem.eql(u8, xn, yn);
    }
    return y.namespace == null;
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
        try checkVariantWhenDisjoint(a, diags, hdr.head_span, spec.name, spec.variants.?);
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
        if (depth > 1) {
            // A slot-local form cannot lower. Nothing downstream would honour
            // the declaration: `Schema.validateLowering` and the produces
            // graph walk only top-level forms, and the lowering worklist
            // resolves a local head to its local body, which is never a hook
            // — so the declaration would be silently dead (or, before the
            // worklist resolved local-first, a same-named global's hook
            // fired on it). Reject rather than carry a lie; the spec keeps
            // `lowering == null` so the invariant holds even in the partial
            // load. `Schema.init` asserts the same for static plugins.
            try emitDiag(a, diags, .invalid_manifest, tree.spanOf(li), &.{ spec.name, "lowering" }, "slot-local form `{s}` declares `:lowering`; a slot-local form cannot lower — declare the sugar as a top-level (form …), or leave the local as plain data", .{spec.name});
        } else {
            spec.lowering = try buildLoweringSpec(a, tree, li, spec.name, diags);
        }
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

    // Deferred to here, not done in `buildKey`: a key may require one
    // declared *after* it, and a variant key may require a base key, so
    // neither scope is complete until the whole form is.
    try checkRequiresConsistency(a, hdr.head_span, spec, null, diags);
    if (spec.variants) |vs| {
        for (vs) |v| try checkRequiresConsistency(a, hdr.head_span, spec, v, diags);
    }

    return spec;
}

/// Reject `:requires` declarations that cannot mean anything useful.
/// Runs once per scope: `variant == null` checks the form's base keys
/// against the base key set; a non-null `variant` checks that variant's
/// keys against its own keys *plus* the base keys (both are
/// unconditionally in scope once the variant is active).
///
/// Five conditions, all `invalid_manifest`:
///
///   * **Self-reference.** `:requires [a]` on key `a` is satisfied by its
///     own presence and constrains nothing.
///   * **Unresolvable.** The named key is not declared in this scope.
///     Catches typos, and catches a base key reaching for a variant key —
///     that dependency would be conditional on the discriminant, which is
///     what `(variant …)` is for.
///   * **Already required.** Requiring a key that is not
///     `effectiveOptional` can never fire: the key is always present, or
///     the form already failed with `missing_required_key`.
///   * **Same exclusive group.** The group says "at most one of these",
///     the dependency says "both". Unsatisfiable.
///   * **Cycle.** `a` requires `b` and `b` requires `a` is satisfiable
///     only by writing both or neither — an `exclusive-group` bundle,
///     spelled worse. Detected by three-colour DFS.
fn checkRequiresConsistency(
    a: Allocator,
    span: Ast.Span,
    spec: Plugin.FormSpec,
    variant: ?Plugin.Variant,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!void {
    const scope_keys = if (variant) |v| v.keys else spec.keys;
    const groups = if (variant) |v| v.exclusive_groups else spec.exclusive_groups;

    for (scope_keys) |k| {
        for (k.requires) |req| {
            if (std.mem.eql(u8, req, k.name)) {
                try emitDiag(a, diags, .invalid_manifest, span, &.{ spec.name, k.name, "requires" }, "form `{s}` key `:{s}` requires itself", .{ spec.name, k.name });
                continue;
            }
            const target = lookupRequiresTarget(spec, variant, req) orelse {
                try emitDiag(a, diags, .invalid_manifest, span, &.{ spec.name, k.name, "requires" }, "form `{s}` key `:{s}` requires `:{s}`, which this form does not declare", .{ spec.name, k.name, req });
                continue;
            };
            if (!target.effectiveOptional()) {
                try emitDiag(a, diags, .invalid_manifest, span, &.{ spec.name, k.name, "requires" }, "form `{s}` key `:{s}` requires `:{s}`, which is already required; the dependency can never fire", .{ spec.name, k.name, req });
                continue;
            }
            if (sameExclusiveGroup(groups, k.name, req)) {
                try emitDiag(a, diags, .invalid_manifest, span, &.{ spec.name, k.name, "requires" }, "form `{s}` key `:{s}` requires `:{s}`, but both are in one exclusive group; the group forbids what the dependency demands", .{ spec.name, k.name, req });
            }
        }
    }

    try checkRequiresCycles(a, span, spec, scope_keys, diags);
}

/// Resolve a `:requires` name within its declaring scope. A base key
/// (`variant == null`) sees base keys only; a variant key sees that
/// variant's keys first, then the base keys.
fn lookupRequiresTarget(
    spec: Plugin.FormSpec,
    variant: ?Plugin.Variant,
    name: []const u8,
) ?Plugin.KeySpec {
    if (variant) |v| {
        for (v.keys) |vk| {
            if (std.mem.eql(u8, vk.name, name)) return vk;
        }
    }
    for (spec.keys) |bk| {
        if (std.mem.eql(u8, bk.name, name)) return bk;
    }
    return null;
}

/// True when both names appear in one `(exclusive-group …)` — in the same
/// alternative or in different ones. Either way the group constrains how
/// many may be present at once, which is what makes the dependency
/// unsatisfiable.
fn sameExclusiveGroup(
    groups: []const Plugin.ExclusiveGroup,
    x: []const u8,
    y: []const u8,
) bool {
    for (groups) |g| {
        var has_x = false;
        var has_y = false;
        for (g.alternatives) |alt| {
            for (alt.keys) |k| {
                if (std.mem.eql(u8, k, x)) has_x = true;
                if (std.mem.eql(u8, k, y)) has_y = true;
            }
        }
        if (has_x and has_y) return true;
    }
    return false;
}

/// Three-colour DFS over the `:requires` graph within one scope, the same
/// shape `Schema.checkLoweringCycles` runs over the produces-graph.
/// Bounded by `MAX_FORM_KEYS` nodes, so the explicit stack is a fixed
/// array and the walk cannot recurse.
///
/// Edges leaving the scope (a variant key requiring a base key) resolve to
/// no index here and are skipped: they cannot close a cycle, because base
/// keys never reach back into a variant.
fn checkRequiresCycles(
    a: Allocator,
    span: Ast.Span,
    spec: Plugin.FormSpec,
    scope_keys: []const Plugin.KeySpec,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!void {
    const n = @min(scope_keys.len, Plugin.MAX_FORM_KEYS);
    if (n == 0) return;

    const Colour = enum { white, grey, black };
    var colour: [Plugin.MAX_FORM_KEYS]Colour = @splat(.white);
    // (node, next-edge-index) pairs; one frame per node on the path, so
    // depth is bounded by `n`.
    var stack: [Plugin.MAX_FORM_KEYS]struct { node: usize, edge: usize } = undefined;

    for (0..n) |root| {
        if (colour[root] != .white) continue;
        var top: usize = 0;
        stack[0] = .{ .node = root, .edge = 0 };
        colour[root] = .grey;
        while (true) {
            const fr = &stack[top];
            const reqs = scope_keys[fr.node].requires;
            if (fr.edge >= reqs.len) {
                colour[fr.node] = .black;
                if (top == 0) break;
                top -= 1;
                continue;
            }
            const req = reqs[fr.edge];
            fr.edge += 1;
            const next = indexOfKey(scope_keys[0..n], req) orelse continue;
            // A self-loop is technically a cycle, but it already has its
            // own, more specific diagnostic — reporting both would say the
            // same thing twice in different words.
            if (next == fr.node) continue;
            switch (colour[next]) {
                .black => {},
                .grey => {
                    // Back edge to a node on the current path.
                    try emitDiag(a, diags, .invalid_manifest, span, &.{ spec.name, scope_keys[fr.node].name, "requires" }, "form `{s}` has a `:requires` cycle through `:{s}` and `:{s}`; a mutual dependency is an exclusive-group bundle, not a dependency", .{ spec.name, scope_keys[fr.node].name, req });
                    colour[next] = .black; // report once per cycle.
                },
                .white => {
                    colour[next] = .grey;
                    top += 1;
                    stack[top] = .{ .node = next, .edge = 0 };
                },
            }
        }
    }
}

fn indexOfKey(keys: []const Plugin.KeySpec, name: []const u8) ?usize {
    for (keys, 0..) |k, i| {
        if (std.mem.eql(u8, k.name, name)) return i;
    }
    return null;
}

/// A discriminant value selects at most one variant. Two variants that
/// both list a value — `:when a` twice, or `:when [a b]` beside
/// `:when [b c]` — leave "which one applies" to declaration order, which
/// is exactly the question the key-collision check exists to keep a schema
/// from asking; the two are the same shape of ambiguity (a slot with two
/// declarations) at the value level, so the second listing is
/// `invalid_manifest`, once per repeated value, anchored on the form. Runs
/// in the loader rather than the aggregate pass because it needs no
/// resolution — the variants of one form are all in hand here.
fn checkVariantWhenDisjoint(
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    span: Ast.Span,
    form_name: []const u8,
    variants: []const Plugin.Variant,
) Error!void {
    for (variants, 0..) |v, vi| {
        std.debug.assert(v.when.len >= 1); // `buildVariant` supplies the placeholder
        for (v.when) |w| {
            // The unnameable placeholder a `:when`-less variant carries
            // (see `buildVariant`) selects nothing and already reported
            // `missing_required_key` at meta-validation; two of them are
            // not a value listed twice.
            if (w.len == 0) continue;
            for (variants[0..vi]) |prior| {
                if (!prior.selects(w)) continue;
                try emitDiag(a, diags, .invalid_manifest, span, &.{ form_name, "variant", "when" }, "form `{s}` variant `:when {s}` lists `{s}`, already selected by variant `:when {s}` — a discriminant value selects at most one variant", .{ form_name, try v.whenText(a), w, try prior.whenText(a) });
                break;
            }
        }
    }
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
    var variant: Plugin.Variant = .{ .when = &.{} };
    var keys = std.ArrayList(Plugin.KeySpec).empty;
    var key_count: usize = 0;
    var groups = std.ArrayList(BuiltGroup).empty;

    for (hdr.children) |ci| {
        switch (tree.tagOf(ci)) {
            .kvpair => {
                const kv = tree.kvpairHeader(ci);
                if (std.mem.eql(u8, kv.key, "when")) {
                    if (try parseVariantWhen(a, tree, kv.value, form_name, diags)) |when| variant.when = when;
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

    // `:when` is `:optional false`, so a missing one is already a
    // `missing_required_key` from meta-validation — but this function must
    // stay total, and `Variant.when` is documented `.len >= 1`. One
    // unnameable value keeps the invariant: no member spells `""`, so the
    // variant is selected by nothing, which is what a `:when`-less variant
    // meant before `when` was a list.
    if (variant.when.len == 0) variant.when = try oneSymbol(a, "");
    std.debug.assert(variant.when.len >= 1);

    variant.keys = try keys.toOwnedSlice(a);
    variant.exclusive_groups = try resolveExclusiveGroups(
        a,
        diags,
        groups.items,
        variant.keys,
        null,
        form_name,
        try variant.whenText(a),
    );
    return variant;
}

/// The `:when` of one `(variant …)`, normalised to the list
/// `Plugin.Variant.when` holds. The meta-schema types the slot as
/// `variant-when`, a union of `symbol` and `symbol-list`, so both shapes
/// arrive here and a third has already reported `union_no_branch_matched`
/// — that one is null, and `buildVariant` keeps whatever it had. Nothing
/// downstream knows which spelling the author wrote, so the two rejections
/// a list can earn — empty, or a value repeated — are decided here, where
/// the spelling is still visible. Both are `invalid_manifest` on the
/// value's span; the list is returned as written either way.
fn parseVariantWhen(
    a: Allocator,
    tree: *const Ast.Tree,
    value: Ast.NodeIndex,
    form_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!?[]const []const u8 {
    switch (tree.tagOf(value)) {
        .symbol => return try oneSymbol(a, tree.symbolText(value)),
        .vector => {},
        else => return null,
    }
    const when = try parseSymbolList(a, tree, value);
    const span = tree.spanOf(value);
    if (when.len == 0) {
        try emitDiag(a, diags, .invalid_manifest, span, &.{ form_name, "variant", "when" }, "form `{s}` variant `:when []` lists no discriminant value — a variant nothing selects can never apply", .{form_name});
    }
    // O(n²) over a hand-written list of enum members.
    for (when, 0..) |w, i| {
        for (when[i + 1 ..]) |u| {
            if (!std.mem.eql(u8, w, u)) continue;
            try emitDiag(a, diags, .invalid_manifest, span, &.{ form_name, "variant", "when" }, "form `{s}` variant `:when` lists `{s}` twice; a value selects the variant once, so the repeat adds nothing and hides a likely typo", .{ form_name, w });
            break;
        }
    }
    return when;
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
        } else if (std.mem.eql(u8, kv.key, "requires")) {
            // Validated against the sibling key set in
            // `checkRequiresConsistency`, once the whole form is built —
            // a key may require one declared after it.
            spec.requires = try parseSymbolList(a, tree, kv.value);
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
/// A digit-leading member spelling only means something on a `.symbol`
/// underlying, where the validator's escape reads a unit-bearing number
/// in a symbol slot. On a `.string` underlying the members are string
/// literals and no numeric value can reach them, so the spelling is dead
/// declaration — say so rather than let it sit there looking effective.
///
/// Deferred past the kvpair loop like every other cross-check: `:members`
/// may be spelled before `:underlying`.
fn checkMemberSetConsistency(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind: Plugin.ValueKind,
    ms: Plugin.ValueKind.MemberSet,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!void {
    if (kind.underlying == .symbol) return;
    for (ms.members) |m| {
        if (m.numeric_spelling == null) continue;
        try emitDiag(a, diags, .invalid_manifest, tree.spanOf(idx), &.{ kind.name, "members" }, "value-kind `{s}` declares the digit-leading member `{s}`, but its `:underlying` is `{s}` — a digit-leading spelling is only reachable on `symbol`", .{ kind.name, m.name, @tagName(kind.underlying) });
    }
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
        } else if (std.mem.eql(u8, kv.key, "multiple-of")) {
            bounds.multiple_of = try loadBound(a, tree, kv.value);
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
    if (bounds.multiple_of) |mo| {
        // Non-positive and non-finite divisors are errors: the check
        // divides by this value, and "every number is a multiple of 0" is
        // not a reading anyone wants either. A *negative* divisor is
        // rejected for a second reason — it means exactly what its
        // magnitude means, so nothing is gained by allowing it, and
        // JSON Schema 2020-12 requires `multipleOf` to be strictly
        // positive. Accepted here it exported a schema no validator will
        // compile, which is a worse failure than the one being avoided.
        if (mo.value <= 0) {
            try emitDiag(a, diags, .numeric_bounds_invalid, span, &.{ kind.name, "numeric", "multiple-of" }, "value-kind `{s}` `:numeric` sets `:multiple-of {d}`; the divisor must be positive", .{ kind.name, mo.value });
        } else if (!std.math.isFinite(mo.value)) {
            try emitDiag(a, diags, .numeric_bounds_invalid, span, &.{ kind.name, "numeric", "multiple-of" }, "value-kind `{s}` `:numeric` sets a non-finite `:multiple-of`; the divisor must be finite", .{kind.name});
        } else if (@floor(mo.value) != mo.value) {
            // A *warning*, not an error: `:multiple-of 0.5` is meaningful,
            // just approximate. Divisibility runs in exact integer space
            // only when both sides are whole, so a fractional divisor falls
            // back to an f64 remainder against an epsilon. Saying so at the
            // declaration steers authors to the exact path — which every
            // alignment rule is already on.
            try emitWarning(a, diags, .numeric_bounds_invalid, span, &.{ kind.name, "numeric", "multiple-of" }, "value-kind `{s}` `:numeric` sets a fractional `:multiple-of {d}`; divisibility is then approximate (integer divisors are exact)", .{ kind.name, mo.value });
        }
    }
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
    var compact_values: ?[]const Plugin.ValueKind.MemberSet.Member = null;
    var rich_count: usize = 0;
    for (hdr.children) |ci| {
        switch (tree.tagOf(ci)) {
            .kvpair => {
                const kv = tree.kvpairHeader(ci);
                if (std.mem.eql(u8, kv.key, "values")) {
                    compact_values = try parseMemberNameList(a, tree, kv.value, kind_name, diags);
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
        return .{ .members = values };
    }

    if (rich_count > 0) {
        const out = try a.alloc(Plugin.ValueKind.MemberSet.Member, rich_count);
        var wi: usize = 0;
        for (hdr.children) |ci| {
            if (tree.tagOf(ci) != .form) continue;
            out[wi] = try parseMemberDecl(a, tree, ci, kind_name, diags);
            for (out[0..wi]) |prior| {
                if (sameMemberIdentity(prior, out[wi])) {
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

/// True when two members name the same thing. Byte-equal names is the
/// long-standing test; a digit-leading pair adds the second half, because
/// `(member :name 2d)` and `(member :name 02d)` canonicalise to the same
/// `name` *and* the same `(value, unit)` — but a future spelling change
/// could make the names differ while the identity the validator matches
/// on stays the same. The identity is the pair, so compare the pair.
fn sameMemberIdentity(
    x: Plugin.ValueKind.MemberSet.Member,
    y: Plugin.ValueKind.MemberSet.Member,
) bool {
    if (x.numeric_spelling) |xs| {
        const ys = y.numeric_spelling orelse return false;
        return xs.value == ys.value and std.mem.eql(u8, xs.unit, ys.unit);
    }
    if (y.numeric_spelling != null) return false;
    return std.mem.eql(u8, x.name, y.name);
}

/// Parse one `(member :name X :label "…" …)` form into a `Member`.
/// The meta-schema enforces `:name` is required; since format 1.3 it is
/// `member-name`-typed, so the spelling may be a symbol *or* a
/// digit-leading unit-bearing number — `parseMemberName` owns that split
/// and its rejections. The other fields are read opportunistically.
fn parseMemberDecl(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.ValueKind.MemberSet.Member {
    const hdr = tree.formHeader(idx);
    var m: Plugin.ValueKind.MemberSet.Member = .{ .name = "" };
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "name")) {
            const spelled = try parseMemberName(a, tree, kv.value, kind_name, diags);
            m.name = spelled.name;
            m.numeric_spelling = spelled.numeric_spelling;
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

/// Build a `HeadSet` from either wire spelling of `:heads`, mirroring
/// `buildMemberSet` exactly:
///
///   * Compact — `(head-set :names [a b c])`, one unbounded entry per
///     bare name.
///   * Rich — `(head-set (head :name a :min 1 :max 1) …)`, each
///     `(head …)` positional child parsed as a full `Head`. This is the
///     only spelling that can carry *per-head* counts.
///
/// `:min-children` / `:max-children` bound the whole set and are legal
/// beside **either** spelling — the aggregate needs no per-head metadata,
/// and "exactly one of these four" is the common case.
///
/// Four `invalid_manifest` conditions, all shaped after `member-set`'s:
/// mixing the two spellings, declaring neither, a duplicate `:name`, and
/// `:min > :max`. A fifth — a `:min` / `:max` that is negative,
/// fractional, or above `u16` — reuses `emitNumericOutOfRange`, so it
/// reads `wrong_underlying` like every other out-of-range integer the
/// loader meets (`(fixed N)`, `(range :min …)`); the condition is
/// identical and a second message shape for it would be the drift.
///
/// Three more come with the set bounds, and the last two are the only
/// checks in this loader that compare the two levels — see
/// `checkAggregateBounds`.
///
/// Diagnostics are the contract, not an abort: a rejected set still
/// returns whatever the author spelled so downstream validation keeps
/// flowing, and an empty result means "no narrowing" to the validator.
fn buildHeadSet(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.ValueKind.HeadSet {
    const hdr = tree.formHeader(idx);
    var compact_names: ?[]const []const u8 = null;
    var rich_count: usize = 0;
    var min_children: u16 = 0;
    var max_children: ?u16 = null;
    for (hdr.children) |ci| {
        switch (tree.tagOf(ci)) {
            .kvpair => {
                const kv = tree.kvpairHeader(ci);
                if (std.mem.eql(u8, kv.key, "names")) {
                    compact_names = try parseSymbolList(a, tree, kv.value);
                } else if (std.mem.eql(u8, kv.key, "min-children") or std.mem.eql(u8, kv.key, "max-children")) {
                    const is_min = kv.key[1] == 'i';
                    const n = numericValue(tree, kv.value);
                    if (boundedInt(u16, n)) |v| {
                        if (is_min) min_children = v else max_children = v;
                    } else {
                        try emitNumericOutOfRange(
                            a,
                            diags,
                            tree.spanOf(kv.value),
                            try pathConcat(a, &.{ kind_name, "heads" }, &.{kv.key}),
                            kv.key,
                            std.math.maxInt(u16),
                            n,
                        );
                    }
                }
            },
            .form => rich_count += 1,
            else => {},
        }
    }

    if (compact_names != null and rich_count > 0) {
        try emitDiag(a, diags, .invalid_manifest, hdr.head_span, &.{ kind_name, "heads" }, "value-kind `{s}` `:heads` mixes `:names` and `(head …)` children — pick one shape", .{kind_name});
    }

    if (max_children) |mx| {
        if (min_children > mx) {
            try emitDiag(a, diags, .invalid_manifest, hdr.head_span, &.{ kind_name, "heads" }, "value-kind `{s}` `:heads` declares an empty child range (`:min-children {d}` > `:max-children {d}`)", .{ kind_name, min_children, mx });
        }
    }

    if (compact_names) |names| {
        const out = try a.alloc(Plugin.ValueKind.HeadSet.Head, names.len);
        for (names, 0..) |n, i| out[i] = .{ .name = n };
        // No per-head bound can exist on this spelling, so the two
        // cross-level sums are `0` and infinity — both vacuous. Skipping
        // `checkAggregateBounds` here says that, rather than relying on
        // it to work it out.
        return .{ .heads = out, .min_children = min_children, .max_children = max_children };
    }

    if (rich_count > 0) {
        const out = try a.alloc(Plugin.ValueKind.HeadSet.Head, rich_count);
        var wi: usize = 0;
        for (hdr.children) |ci| {
            if (tree.tagOf(ci) != .form) continue;
            out[wi] = try parseHeadDecl(a, tree, ci, kind_name, diags);
            for (out[0..wi]) |prior| {
                if (std.mem.eql(u8, prior.name, out[wi].name)) {
                    try emitDiag(a, diags, .invalid_manifest, tree.spanOf(ci), &.{ kind_name, "heads" }, "value-kind `{s}` `:heads` declares duplicate head `{s}`", .{ kind_name, out[wi].name });
                    break;
                }
            }
            if (out[wi].max) |mx| {
                if (out[wi].min > mx) {
                    try emitDiag(a, diags, .invalid_manifest, tree.spanOf(ci), &.{ kind_name, "heads", out[wi].name }, "value-kind `{s}` head `{s}` declares an empty range (`:min {d}` > `:max {d}`)", .{ kind_name, out[wi].name, out[wi].min, mx });
                }
            }
            wi += 1;
        }
        const hs: Plugin.ValueKind.HeadSet = .{ .heads = out, .min_children = min_children, .max_children = max_children };
        try checkAggregateBounds(a, hs, kind_name, hdr.head_span, diags);
        return hs;
    }

    try emitDiag(a, diags, .invalid_manifest, hdr.head_span, &.{ kind_name, "heads" }, "value-kind `{s}` `:heads` declares no heads (need `:names …` or `(head …)` children)", .{kind_name});
    return .{ .heads = &.{}, .min_children = min_children, .max_children = max_children };
}

/// The two cross-level checks, and the only place this loader compares a
/// per-head bound against the set's. Both are **sums**, not per-head
/// comparisons, and that is the whole point:
///
///   * `Σ head.min > set.max` — heads `a :min 1` and `b :min 1` under a
///     set `:max-children 1` is unsatisfiable, yet neither head's `:min`
///     is above the set's `:max`. The weaker per-head spelling of this
///     check lets it through.
///   * `set.min > Σ head.max` — the mirror. Only meaningful when *every*
///     head is bounded: one unbounded head makes the sum infinite and
///     the set always fillable, so the check is vacuous and must not
///     fire (a schema saying "at least 9, and `sampler` is unbounded" is
///     perfectly satisfiable).
///
/// Accumulated in `u32`: `u16` heads summing over `u16` bounds overflows
/// in the type the fields are declared in.
///
/// Both are `invalid_manifest`, like the four spelling refusals — the
/// manifest declares something no document can satisfy, which is the
/// same class of author error as an empty range.
fn checkAggregateBounds(
    a: Allocator,
    hs: Plugin.ValueKind.HeadSet,
    kind_name: []const u8,
    head_span: Ast.Span,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!void {
    if (hs.max_children) |set_max| {
        var floor_sum: u32 = 0;
        for (hs.heads) |h| floor_sum += h.min;
        if (floor_sum > set_max) {
            try emitDiag(a, diags, .invalid_manifest, head_span, &.{ kind_name, "heads" }, "value-kind `{s}` `:heads` is unsatisfiable: its heads require at least {d} child(ren) together, above `:max-children {d}`", .{ kind_name, floor_sum, set_max });
        }
    }
    if (hs.min_children == 0) return;
    var ceil_sum: u32 = 0;
    for (hs.heads) |h| ceil_sum += h.max orelse return; // one unbounded head ⇒ vacuous
    if (hs.min_children > ceil_sum) {
        try emitDiag(a, diags, .invalid_manifest, head_span, &.{ kind_name, "heads" }, "value-kind `{s}` `:heads` is unsatisfiable: `:min-children {d}` is above the {d} child(ren) its heads allow together", .{ kind_name, hs.min_children, ceil_sum });
    }
}

/// Parse one `(head :name X :min 1 :max 1 :description "…")` form into a
/// `Head`. The meta-schema enforces `:name` is required and symbol-typed
/// and that the counts are numbers; the `u16` / non-negative / integral
/// narrowing is this loader's own, as it is for `(fixed N)`.
fn parseHeadDecl(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.ValueKind.HeadSet.Head {
    const hdr = tree.formHeader(idx);
    var h: Plugin.ValueKind.HeadSet.Head = .{ .name = "" };
    // Two passes' worth of information in one: the counts are reported
    // against the head's own name, which may be spelled after them.
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "name")) {
            h.name = try a.dupe(u8, tree.symbolText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "description")) {
            h.description = try a.dupe(u8, tree.stringText(kv.value));
        }
    }
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        const is_min = std.mem.eql(u8, kv.key, "min");
        if (!is_min and !std.mem.eql(u8, kv.key, "max")) continue;
        const n = numericValue(tree, kv.value);
        if (boundedInt(u16, n)) |v| {
            if (is_min) h.min = v else h.max = v;
        } else {
            try emitNumericOutOfRange(
                a,
                diags,
                tree.spanOf(kv.value),
                try pathConcat(a, &.{ kind_name, "heads", h.name }, &.{kv.key}),
                kv.key,
                std.math.maxInt(u16),
                n,
            );
        }
    }
    return h;
}

/// Parse `(cross-ref :target <symbol|[symbol…]> :name-key <symbol>?)` into
/// a `Plugin.ValueKind.CrossRef`. Per-plugin shape check: the owning kind
/// must have `:underlying symbol`. Cross-plugin resolution of `:target`
/// and `:name-key` typing happens later in the schema-aggregate phase
/// (`Schema.validateCrossRefs`) — at this layer we only have one plugin
/// at a time.
///
/// Both `:target` spellings normalise to a list here, so nothing
/// downstream has to know which one the author wrote. What *is* decided
/// here is everything a group cannot carry — see the exclusions below.
fn buildCrossRef(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind: Plugin.ValueKind,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.ValueKind.CrossRef {
    const hdr = tree.formHeader(idx);
    var cr: Plugin.ValueKind.CrossRef = .{ .targets = &.{} };
    // Track *written* keys, not values: `:name-key name` and `:source-key
    // src` are indistinguishable from their defaults once landed, and the
    // exclusions below are about what the author spelled.
    var saw_name_key = false;
    var saw_source_key = false;
    var wrote_target_vector = false;
    var span_target: Ast.Span = .{ .start = 0, .end = 0 };
    var span_name_key: Ast.Span = .{ .start = 0, .end = 0 };
    var span_source_key: Ast.Span = .{ .start = 0, .end = 0 };
    var span_acyclic: Ast.Span = .{ .start = 0, .end = 0 };
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "target")) {
            span_target = tree.spanOf(kv.value);
            // The meta-schema types `:target` as `form-target`, a union of
            // `symbol` and `symbol-list`, so both shapes arrive here and a
            // third one already reported `union_no_branch_matched`.
            cr.targets = switch (tree.tagOf(kv.value)) {
                .vector => try parseSymbolList(a, tree, kv.value),
                .symbol => try Plugin.ValueKind.CrossRef.dupeOne(a, tree.symbolText(kv.value)),
                else => &.{},
            };
            wrote_target_vector = tree.tagOf(kv.value) == .vector;
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

    // Target-group exclusions. Same `invalid_manifest` class as the route
    // exclusions above — an internally incoherent shape — and, like them,
    // every offending key is *dropped* rather than half-honoured, so
    // downstream only ever sees a spec that took one coherent reading.
    if (wrote_target_vector) {
        if (cr.targets.len == 0) {
            try emitDiag(a, diags, .invalid_manifest, span_target, &.{ kind.name, "cross-ref", "target" }, "value-kind `{s}` `:cross-ref` has an empty `:target []` — a cross-ref with no target accepts nothing and rejects everything", .{kind.name});
        }
        // O(n²) over a hand-written list of form heads.
        for (cr.targets, 0..) |t, i| {
            for (cr.targets[i + 1 ..]) |u| {
                if (!std.mem.eql(u8, t, u)) continue;
                try emitDiag(a, diags, .invalid_manifest, span_target, &.{ kind.name, "cross-ref", "target" }, "value-kind `{s}` `:cross-ref` lists target `{s}` twice; the group is one namespace, so the repeat adds nothing and hides a likely typo", .{ kind.name, t });
                break;
            }
        }
        if (cr.targets.len > 1) {
            // `:acyclic` — cycle edges are defined over a target form's
            // *self*-referential keys, and "self" is not well defined
            // across a group. Mirrors the `:provider` + `:acyclic`
            // rejection above, for the same reason: the check could not be
            // computed honestly, so `acyclic_without_self_edge` could not
            // be either.
            if (cr.acyclic) {
                try emitDiag(a, diags, .invalid_manifest, span_acyclic, &.{ kind.name, "cross-ref", "acyclic" }, "value-kind `{s}` `:cross-ref` sets `:acyclic true` with {d} targets — cycle edges are defined over one target form's self-referential keys, and `self` is not well defined across a group", .{ kind.name, cr.targets.len });
                cr.acyclic = false;
            }
            // `:provider` — the *registration* would still be coherent
            // (each instance's source extracted into the group's one
            // namespace), but a form could then owe extractions to several
            // buckets at once, which the binary walk's single-pass form
            // frame carries one of. Supporting it means either a per-form
            // width ceiling on schema data or a tree/binary divergence,
            // and neither is worth a shape nobody has asked for. Rejected
            // rather than silently half-honoured.
            if (cr.provider) |pv| {
                try emitDiag(a, diags, .invalid_manifest, span_target, &.{ kind.name, "cross-ref", "provider" }, "value-kind `{s}` `:cross-ref` sets `:provider {s}` with {d} targets — an extracted member set is collected per target form, so declare one cross-ref per target instead", .{ kind.name, pv, cr.targets.len });
                cr.provider = null;
                cr.source_key = "src";
            }
        }
    }
    // `:target` is `:optional false`, so a missing one is already a
    // `missing_required_key` from meta-validation — but this function must
    // stay total, and `CrossRef.targets` is documented `.len >= 1`. One
    // unnameable target keeps the invariant and reproduces the behaviour
    // the pre-slice code had for the same input: `canonicalFormName("")`
    // resolves to nothing, so the kind rejects every reference.
    if (cr.targets.len == 0) cr.targets = try Plugin.ValueKind.CrossRef.dupeOne(a, "");
    std.debug.assert(cr.targets.len >= 1);
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

/// Read one member spelling — the shared reader behind a `:values`
/// element and `(member :name …)`.
///
/// Two shapes reach here, because `member-name` is a union of `symbol`
/// and `number`:
///
///   * a bare symbol (`loop`, `cube-array`) — an ordinary member;
///   * a unit-bearing number (`1d`, `2d`, `50%`) — a *digit-leading*
///     spelling, which the lexer cannot hand over as a symbol. `name`
///     becomes its canonical spelling (so `02d` declares `2d`) and
///     `numeric_spelling` carries the `(value, unit)` identity the
///     validator matches on.
///
/// Two `invalid_manifest` rejections, both of them loader-side on
/// purpose: the meta-schema can only say "symbol or number", and *which*
/// numbers are spellings is a semantic question. This is the `(fixed N)`
/// precedent (`manifests/meta.sjon`).
///
///   * a number with **no unit** (`2`) — a bare magnitude is not a name;
///   * a unit-bearing number whose magnitude is negative, fractional, or
///     above `MAX_SPELLING_VALUE` — the range where the canonical
///     spelling has one text form in every host.
///
/// Always returns a member, rejected or not: diagnostics are the
/// contract, not an abort, and a rejected spelling lands as a plain
/// symbol member that no document value can match (a bare `2` is never a
/// symbol lexeme), so the set keeps its shape without gaining a member
/// that silently works.
fn parseMemberName(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error!Plugin.ValueKind.MemberSet.Member {
    const Spelling = Plugin.ValueKind.MemberSet.NumericSpelling;
    switch (tree.tagOf(idx)) {
        .symbol => return .{ .name = try a.dupe(u8, tree.symbolText(idx)) },
        .number_with_unit => {
            const nv = tree.numberWithUnitOf(idx);
            const key = Spelling.keyOf(nv.value) orelse {
                try emitDiag(a, diags, .invalid_manifest, tree.spanOf(idx), &.{ kind_name, "members" }, "value-kind `{s}` member spelling `{d}{s}` needs a whole non-negative magnitude at or below {d}", .{ kind_name, nv.value, nv.unit, Spelling.MAX_SPELLING_VALUE });
                return .{ .name = try std.fmt.allocPrint(a, "{d}{s}", .{ nv.value, nv.unit }) };
            };
            return .{
                .name = try Spelling.canonical(a, key, nv.unit),
                .numeric_spelling = .{ .value = key, .unit = try a.dupe(u8, nv.unit) },
            };
        },
        // Unitless number — `.number`, `.number_i64`, `.number_u64`.
        .number, .number_i64, .number_u64 => {
            const text = try renderUnitlessNumber(a, tree, idx);
            try emitDiag(a, diags, .invalid_manifest, tree.spanOf(idx), &.{ kind_name, "members" }, "value-kind `{s}` member spelling `{s}` carries no unit; a digit-leading member needs a letter tail, e.g. `1d`", .{ kind_name, text });
            return .{ .name = text };
        },
        // The meta-schema admits only symbol / number here, so anything
        // else already reported `wrong_underlying`. Keep the walk total.
        else => return .{ .name = "" },
    }
}

/// Render a unitless numeric node for a diagnostic message. Tag-true so
/// an exact-integer literal reads as the author wrote it rather than
/// through f64.
fn renderUnitlessNumber(a: Allocator, tree: *const Ast.Tree, idx: Ast.NodeIndex) Error![]const u8 {
    return switch (tree.tagOf(idx)) {
        .number_i64 => try std.fmt.allocPrint(a, "{d}", .{tree.numberI64Of(idx)}),
        .number_u64 => try std.fmt.allocPrint(a, "{d}", .{tree.numberU64Of(idx)}),
        .number => try std.fmt.allocPrint(a, "{d}", .{tree.numberOf(idx)}),
        else => unreachable, // caller gated on the unitless numeric tags
    };
}

/// Read a `:values [loop 1d 2d]` vector into members. Replaces
/// `parseSymbolList` at this one call site — since format 1.3 an element
/// may be a digit-leading spelling, which is not a symbol node.
fn parseMemberNameList(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
) Error![]const Plugin.ValueKind.MemberSet.Member {
    const elements = tree.vectorElements(idx);
    const out = try a.alloc(Plugin.ValueKind.MemberSet.Member, elements.len);
    for (elements, 0..) |ei, i| {
        out[i] = try parseMemberName(a, tree, ei, kind_name, diags);
        // The same scan `buildMemberSet` runs over `(member …)` children,
        // on the spelling that gets it wrong more easily. `:values` is the
        // common shape, and since a digit-leading member canonicalises,
        // `[2d 2.0d]` reads as two members and is one — a set silently
        // smaller than it looks, where the rich path said so. Byte-equal
        // duplicates report here too: they always should have.
        for (out[0..i]) |prior| {
            if (sameMemberIdentity(prior, out[i])) {
                try emitDiag(a, diags, .invalid_manifest, tree.spanOf(ei), &.{ kind_name, "members" }, "value-kind `{s}` `:members` declares duplicate member `{s}`", .{ kind_name, out[i].name });
                break;
            }
        }
    }
    return out;
}

/// A one-element symbol list owned by `a` — the shape a scalar `:when`
/// normalises to (`Plugin.Variant.when` is always a list).
fn oneSymbol(a: Allocator, text: []const u8) Error![]const []const u8 {
    const list = try a.alloc([]const u8, 1);
    list[0] = try a.dupe(u8, text);
    return list;
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
// ManifestLoader's tests live in the sibling `ManifestLoader_tests.zig`,
// which reaches the loader through its public surface. (Sha256-pin
// well-formedness lives in the `Sha256Pin` leaf and is tested there.)

test {
    _ = @import("ManifestLoader_tests.zig");
}
