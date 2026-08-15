//! Validator — walks an `Ast.Tree` (or, via `validateBinary`, a
//! `BinaryCursor`) against a `Schema`, emitting diagnostics with source
//! spans suitable for editor LSP rendering.
//!
//! Iterative descent over a stack of `Ast.NodeIndex` — no recursion.
//! Atoms are skipped; forms and vectors push their children for further
//! visitation.
//!
//! Lookup precedence per form:
//!   1. Qualified head (`<ns>/<name>`): lookup in that plugin's `forms`,
//!      then in its `expr_funcs`.
//!   2. Bare head: bare lookup as a data form first; if not found, bare
//!      lookup as an expression function. If neither matches, the head
//!      is "unknown".
//!
//! Lookup outcomes mapped to diagnostics:
//!   * `.not_found`  → `error: unknown form …`
//!   * `.ambiguous`  → `error: form … is ambiguous; defined by [a, b, …]`
//!
//! Lookup decision flowchart. Qualified and bare heads run the same
//! two-step precedence — `namespace` is null for a bare head, non-null for
//! a qualified one; a qualified head can only ever hit its one plugin, so
//! `.ambiguous` is reachable for bare heads only:
//!
//!     schema.lookupForm(name, namespace)
//!       │
//!       ├── exactly one      ──► validate keyword names ──► OK
//!       ├── two or more      ──► .ambiguous ──► diagnostic (bare only)
//!       └── zero
//!             │
//!             ▼
//!     schema.lookupExprFunc(name, namespace)
//!       │
//!       ├── exactly one      ──► validate arity, no kwargs ──► OK
//!       ├── two or more      ──► .ambiguous ──► diagnostic (bare only)
//!       └── zero             ──► .not_found ──► diagnostic
//!
//! A form-spec hit additionally checks declared keyword names. An
//! expression-func hit additionally checks arity and rejects keyword
//! children (expressions take only positional arguments in v0.1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const BinaryCursor = @import("BinaryCursor.zig");
const MaterializedDefaults = @import("MaterializedDefaults.zig");
const StringFormats = @import("StringFormats.zig");

/// Per-axis effective-validation switches. The field defaults encode
/// the production policy: A+B+C+D on. Each axis:
///   * `name_index`: cross-ref name indexing consults the overlay when
///     the form's `:name-key` kvpair is omitted.
///   * `ref_lookup`: cross-ref symbol-slot lookup runs against the
///     overlay value when the kvpair is omitted.
///   * `exclusive_group`: presence checks for `required_one_of_missing`
///     and `mutually_exclusive_keys_present` consult overlay defaults
///     under a group-aware rule — a defaulted alternative participates
///     only when no sibling alternative is fully author-present;
///     schemas with multiple default-only alts in one group surface
///     `multiple_defaulted_alternatives_in_group`.
///   * `variant`: variant discriminant selection consults the overlay
///     when the discriminant kvpair is omitted.
///
/// Threaded through `validateWithOptions`/`validateForestWithOptions`;
/// `Host.validateDocument` exposes the bits via `HostOptions.effective_axes`.
/// All four axes graduated to production-on as of 2026-05-12 — flags
/// remain so the effective-axes harness can flip individual bits and
/// measure diagnostic-stream deltas against the production reference.
/// Axis C runs under the group-aware default rule.
pub const EffectiveAxes = struct {
    name_index: bool = true, // A — graduated
    ref_lookup: bool = true, // B — graduated
    exclusive_group: bool = true, // C — graduated (group-aware rule)
    variant: bool = true, // D — graduated
};

/// Per-call validator options. Bundles the overlay pointer with the
/// per-axis switches so the four entry points share one parameter shape.
pub const Options = struct {
    /// Read-only side-table built by `MaterializedDefaults.materializeDefaults`.
    /// When non-null and any `axes.*` bit is true, the validator consults
    /// the overlay at the matching call sites. `null` means "author-only
    /// behaviour"; `axes` bits are ignored in that case.
    ///
    /// In forest mode (`validateForestWithOptions`), this single overlay
    /// is shared across every tree. If `overlays` is also set, it takes
    /// precedence and `overlay` is ignored.
    overlay: ?*const MaterializedDefaults.MaterializedDefaults = null,
    /// Per-tree overlays. Forest mode only — when non-null, must have one
    /// entry per input tree and the i-th entry is the overlay used for
    /// the i-th tree at every call site (cross-ref index pass + per-tree
    /// validation walk). Used by the host's final-document forest pass,
    /// where the source-tree overlay (keyed by source `NodeIndex`) and
    /// the lowered-tree overlay (keyed by lowered `NodeIndex`) live in
    /// disjoint index spaces and cannot share one side-table.
    overlays: ?[]const ?*const MaterializedDefaults.MaterializedDefaults = null,
    /// Forest mode: when `true`, every tree in the forest registers and
    /// looks up cross-refs against a single shared `tree_scope`
    /// (`ScopeId.tree(0)`), as if the trees were one logical document.
    /// Default `false` preserves per-tree isolation — what the LSP /
    /// multi-file workflows depend on.
    ///
    /// The host's final-document forest pass sets this to `true` so a
    /// source form referencing a target that only exists in the lowered
    /// tree (or vice versa) resolves cleanly. Lexical scopes built from
    /// `:scope <form>` heads still carry their owning `tree_idx` and
    /// remain tree-local in v2 — only the default tree-level scope is
    /// fused.
    share_scope: bool = false,
    axes: EffectiveAxes = .{},
    /// Results of the host's provider-extraction pre-pass, keyed by
    /// `(canonical provider, source bytes)` — see `ExtractionMap`. The
    /// cross-ref index pass reads it to fill provider-route buckets; a
    /// request it cannot answer poisons the bucket rather than leaving
    /// it empty.
    ///
    /// `null` means no host ran the pre-pass, which is the ordinary case
    /// for every schema without a provider route (and for hosts that
    /// cannot execute plugins at all). Borrowed for the duration of the
    /// call: the index dupes any bytes it keeps, because the map outlives
    /// neither the index nor the LSP's retention of it.
    extractions: ?*const ExtractionMap = null,
};

/// Effective overlay for a given tree index. `overlays[i]` wins when the
/// per-tree slice is supplied; otherwise the single shared `overlay`
/// applies to every tree. Helper used by both the cross-ref index pass
/// and the per-tree validation walk so the routing rule lives in one
/// place.
fn effectiveOverlay(options: Options, tree_idx: usize) ?*const MaterializedDefaults.MaterializedDefaults {
    if (options.overlays) |ovs| {
        std.debug.assert(tree_idx < ovs.len);
        return ovs[tree_idx];
    }
    return options.overlay;
}

/// Per-tree Options view: same axes, overlay swapped to the per-tree
/// effective pointer, `overlays` cleared. Lets internal walkers
/// (`validateOneTree`, `registerCrossRefInstance`) keep reading
/// `options.overlay` without per-call-site routing logic.
///
/// This rebuilds a fresh `Options` field by field rather than copying and
/// patching, so a field added to `Options` and *not* listed here is
/// silently dropped on the way to every internal walker — and drops
/// quietly, because every test without that field set still passes.
/// `extractions` is forest-wide (content-addressed, not tree-keyed), so
/// it passes through unchanged. `share_scope`'s absence is the opposite
/// case and deliberate: the callers resolve the scope before they call
/// in, so a per-tree view has no use for it. Anything added later has to
/// be sorted into one of those two buckets here.
fn perTreeOptions(options: Options, tree_idx: usize) Options {
    return .{
        .overlay = effectiveOverlay(options, tree_idx),
        .overlays = null,
        .axes = options.axes,
        .extractions = options.extractions,
    };
}

/// Severity of a validator diagnostic. `err` blocks downstream consumers;
/// `warning` is informational. Aliased to `Ast.Diagnostic.Severity` so
/// parse and validate diagnostics share one canonical declaration.
pub const Severity = Ast.Diagnostic.Severity;

// ---------------------------------------------------------------------------
// Overload resolution.
//
// For multi-signature `ExprFunc`s the validator dispatches by arity-then-
// type at validate-time. The resolution state is a 32-bit candidate
// bitmask: bit `i` set ↔ signature `i` (in `func.signatureIter()` order)
// is still in the running. Initial mask = signatures whose arity accepts
// the call's argc. Each positional arg narrows the mask via tag-level
// type matching; if narrowing empties the mask the arg gets an
// `expr_type_mismatch` listing the candidate types tried.
//
// Tag-level (vs the mono path's refinement-aware match) is a deliberate
// scoping choice: signatures' param types are typically primitives or
// `.named` value-kinds whose tag-level shape is enough to distinguish
// overloads. Refinement-aware narrowing of overloads (length-pinning a
// vector kind, narrowing a member-set-bearing symbol, …) is left for
// later — `.named` types accept any tag at this layer to avoid false
// negatives. Both walkers (Tree + Binary) consult the same helpers below
// so their behavior stays in lock-step.
// ---------------------------------------------------------------------------

/// Cap on overload count. 32 bits in a u32 mask; signatures past this
/// are silently ignored, which is fine for any realistic vocabulary
/// (`lerp`/`clamp`/`min`/`max` use ≤ 4 each).
const MAX_OVERLOADS: u8 = 32;

/// True if any signature of `func` opts into labeled-call form. Both
/// validator paths ask this, so it lives with the rest of the label
/// rules in `Schema` rather than being restated here.
const anyLabeledSignature = Schema.anyLabeledSignature;

/// Initial candidate mask for an overloaded call: bit `i` set iff
/// signature `i`'s arity accepts `argc`. For mono ExprFuncs this still
/// works (one signature, single bit) but the mono path uses the existing
/// refinement-aware machinery and never consults this mask.
fn overloadInitialMask(func: Plugin.ExprFunc, argc: usize) u32 {
    var mask: u32 = 0;
    var it = func.signatureIter();
    var i: u5 = 0;
    while (it.next()) |sig| : (i += 1) {
        if (i >= MAX_OVERLOADS) break;
        if (sig.checkArity(argc)) mask |= @as(u32, 1) << i;
    }
    return mask;
}

/// Per-arg narrowing: returns the bitmask of signatures whose declared
/// type at `pos_idx` accepts a value of tag `kind`. Opaque positions
/// (signature has no `params`/`rest` covering this index) accept any
/// tag — the corresponding bit stays set so opaque overloads survive
/// to the next arg.
fn overloadAcceptMask(
    func: Plugin.ExprFunc,
    pos_idx: usize,
    kind: Ast.ValueKind,
) u32 {
    var accept: u32 = 0;
    var it = func.signatureIter();
    var i: u5 = 0;
    while (it.next()) |sig| : (i += 1) {
        if (i >= MAX_OVERLOADS) break;
        const bit = @as(u32, 1) << i;
        if (sig.paramType(pos_idx)) |t| {
            if (kindAcceptsType(kind, t)) accept |= bit;
        } else {
            accept |= bit;
        }
    }
    return accept;
}

/// Tag-level acceptance check. Mirrors the primitive cases of
/// `matchValueAgainstType` but stays at the tag layer — never recurses
/// into `.named` kinds. `.named` and `.any` accept any tag so the
/// overload narrowing doesn't false-eliminate candidates whose param
/// types reference a refined kind. Symbol/form values defer to runtime
/// at the call site (caller gates) so they never reach this fn.
fn kindAcceptsType(kind: Ast.ValueKind, expected: Plugin.ValueType) bool {
    return switch (expected) {
        .any, .named => true,
        .number => kind == .number or kind == .number_with_unit,
        .string => kind == .string,
        .symbol => kind == .symbol,
        .boolean => kind == .boolean,
        .nil => kind == .nil,
        .vector => kind == .vector,
        .form, .expr => kind == .form,
    };
}

/// English label for a `ValueKind` — used in overload-mismatch messages
/// where the actual node's kind needs to be named without a Tree handle.
fn kindLabel(kind: Ast.ValueKind) []const u8 {
    return switch (kind) {
        .nil => "nil",
        .boolean => "boolean",
        .number => "number",
        .number_with_unit => "number with unit",
        .date => "date",
        .time => "time",
        .string => "string",
        .keyword => "keyword",
        .symbol => "symbol",
        .vector => "vector",
        .form => "form",
    };
}

/// Emit the "tried these types, none matched" diagnostic for a failed
/// overload narrowing. `cand_mask` is the mask BEFORE this arg's
/// narrowing — i.e. the candidates that were still alive when the arg
/// hit. The message lists each unique declared type at `pos_idx` across
/// those candidates (deduped), separated by " or ".
fn emitOverloadMismatch(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    span: Ast.Span,
    path: []const []const u8,
    func: Plugin.ExprFunc,
    pos_idx: usize,
    cand_mask: u32,
    actual_kind: Ast.ValueKind,
) Allocator.Error!void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "expression `");
    try buf.appendSlice(a, func.name);
    try buf.appendSlice(a, "` argument ");
    const piece = try std.fmt.allocPrint(a, "{d}", .{pos_idx});
    try buf.appendSlice(a, piece);
    try buf.appendSlice(a, " expects ");
    try describeOverloadTypes(a, &buf, func, pos_idx, cand_mask);
    try buf.appendSlice(a, ", got ");
    try buf.appendSlice(a, kindLabel(actual_kind));
    try emit(a, diags, span, path, .err, .expr_type_mismatch, try buf.toOwnedSlice(a));
}

/// Append a `" or "`-joined list of expected types at `pos_idx` across
/// the active candidates in `cand_mask`. Deduplicates structurally so a
/// vocabulary like `(number,number,number)` and `(number,number,number)`
/// across two overloads collapses to a single "number" in the message.
fn describeOverloadTypes(
    a: Allocator,
    buf: *std.ArrayList(u8),
    func: Plugin.ExprFunc,
    pos_idx: usize,
    cand_mask: u32,
) Allocator.Error!void {
    var seen: [MAX_OVERLOADS]Plugin.ValueType = undefined;
    var n_seen: usize = 0;
    var it = func.signatureIter();
    var i: u5 = 0;
    while (it.next()) |sig| : (i += 1) {
        if (i >= MAX_OVERLOADS) break;
        if ((cand_mask & (@as(u32, 1) << i)) == 0) continue;
        const t = sig.paramType(pos_idx) orelse continue;
        var dup = false;
        for (seen[0..n_seen]) |s| if (valueTypesEqual(s, t)) {
            dup = true;
            break;
        };
        if (!dup and n_seen < seen.len) {
            seen[n_seen] = t;
            n_seen += 1;
        }
    }
    if (n_seen == 0) {
        try buf.appendSlice(a, "any value");
        return;
    }
    for (seen[0..n_seen], 0..) |t, idx| {
        if (idx > 0) try buf.appendSlice(a, " or ");
        try describeType(a, buf, t);
    }
}

fn valueTypesEqual(a: Plugin.ValueType, b: Plugin.ValueType) bool {
    if (@as(std.meta.Tag(Plugin.ValueType), a) != @as(std.meta.Tag(Plugin.ValueType), b)) return false;
    return switch (a) {
        .named => |n| qualifiedRefsEqual(n, b.named),
        else => true,
    };
}

fn qualifiedRefsEqual(a: Plugin.QualifiedRef, b: Plugin.QualifiedRef) bool {
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if (a.namespace == null and b.namespace == null) return true;
    if (a.namespace == null or b.namespace == null) return false;
    return std.mem.eql(u8, a.namespace.?, b.namespace.?);
}

// ---------------------------------------------------------------------------
// Form-expression result resolution.
//
// Used by typed-slot matching and expression-argument checking to peek at
// a form-valued node's declared result type without evaluating it. The
// resolver mirrors `validateFormHead`'s precedence (data form first,
// expression second) so result classification stays consistent with head
// diagnostics. For overloaded calls the result is the shared declared
// result across signatures that survive arity narrowing — if those
// signatures disagree on result, or any active candidate is opaque, the
// result is `null` and the caller falls back to "defer".
// ---------------------------------------------------------------------------

/// Classification of a form-valued node by its head:
///   * `data_form` — head resolves to a `FormSpec` (not an expression).
///   * `expr` — head resolves to an `ExprFunc`; `result` is the declared
///     return type when statically determinable, else `null` (opaque /
///     overload ambiguity).
///   * `unresolved` — head is unknown or ambiguous; the head validator
///     emits `unknown_form` / `ambiguous_form` separately and the slot
///     should not pile on a second diagnostic.
pub const FormExprResolution = union(enum) {
    data_form,
    expr: struct {
        func: *const Plugin.ExprFunc,
        result: ?Plugin.ValueType,
    },
    unresolved,
};

/// Classify a form-valued node's head; if expression, surface its
/// declared result type (or `null` for opaque / ambiguous cases). Pure —
/// never evaluates, never reads host bindings.
fn resolveFormExpression(
    a: Allocator,
    schema: Schema.Schema,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) Allocator.Error!FormExprResolution {
    if (tree.tagOf(idx) != .form) return .unresolved;
    const hdr = tree.formHeader(idx);
    if (hdr.head.len == 0) return .unresolved;

    // Mirror validateFormHead: data form lookup first.
    switch (schema.lookupForm(hdr.head, hdr.namespace)) {
        .found => return .data_form,
        .ambiguous => return .unresolved,
        .not_found => {},
    }

    switch (schema.lookupExprFunc(hdr.head, hdr.namespace)) {
        .not_found, .ambiguous => return .unresolved,
        .found => |hit| {
            // Mono — `.signatures == null` → top-level result is the
            // single declared result.
            if (hit.func.signatures == null) {
                return .{ .expr = .{ .func = hit.func, .result = hit.func.result } };
            }
            // Multi-sig — labeled call resolves to one signature.
            const resolved = try Schema.resolveExprArgs(a, hit.func.*, tree, hdr);
            switch (resolved) {
                .err => return .{ .expr = .{ .func = hit.func, .result = null } },
                .ok => |r| {
                    if (r.signature) |sig| {
                        return .{ .expr = .{ .func = hit.func, .result = sig.result } };
                    }
                    // Positional — derive shared result across surviving
                    // candidates by arity. Statically narrowing further on
                    // literal args is an optimization left for a later
                    // slice; today an opaque positional overload defers.
                    return .{ .expr = .{ .func = hit.func, .result = sharedResultByArity(hit.func.*, r.positional.len) } };
                },
            }
        },
    }
}

/// Binary-side resolver: same classification as `resolveFormExpression`,
/// but driven by a form's head + namespace + child count instead of a
/// `Tree` handle. The binary path can't cheaply run labeled-call
/// resolution (no random-access children), so multi-sig functions
/// narrow on arity alone — labeled-only multi-sigs collapse to the
/// `sharedResultByArity` outcome, which is `null` (opaque) for
/// signatures with differing results. Mono functions still surface
/// `func.result` exactly.
pub fn resolveFormExpressionBinary(
    schema: Schema.Schema,
    head: []const u8,
    namespace: ?[]const u8,
    argc: u32,
) FormExprResolution {
    if (head.len == 0) return .unresolved;
    switch (schema.lookupForm(head, namespace)) {
        .found => return .data_form,
        .ambiguous => return .unresolved,
        .not_found => {},
    }
    switch (schema.lookupExprFunc(head, namespace)) {
        .not_found, .ambiguous => return .unresolved,
        .found => |hit| {
            if (hit.func.signatures == null) {
                return .{ .expr = .{ .func = hit.func, .result = hit.func.result } };
            }
            return .{ .expr = .{ .func = hit.func, .result = sharedResultByArity(hit.func.*, argc) } };
        },
    }
}

/// Of the signatures that accept `argc` positionals, return the shared
/// declared result type if every survivor declares the same result.
/// Returns `null` when survivors disagree, when any survivor has no
/// declared result, or when no survivor exists (arity miss — that
/// surfaces as an arity diagnostic separately).
fn sharedResultByArity(func: Plugin.ExprFunc, argc: usize) ?Plugin.ValueType {
    var shared: ?Plugin.ValueType = null;
    var have_one = false;
    var it = func.signatureIter();
    while (it.next()) |sig| {
        if (!sig.checkArity(argc)) continue;
        const r = sig.result orelse return null;
        if (!have_one) {
            shared = r;
            have_one = true;
            continue;
        }
        if (!valueTypesEqual(shared.?, r)) return null;
    }
    return shared;
}

/// Three-valued compatibility between a *declared* expression result
/// type and a slot's expected type. `.yes` and `.no` are firm verdicts;
/// `.unknown` says "can't prove from declarations alone" and tells the
/// caller to defer (today's behavior).
///
/// Rules:
///
/// - `expected == .any` → `.yes`.
/// - `actual == .any` → `.unknown`.
/// - Primitive vs primitive: equal underlyings = `.yes`, different = `.no`.
/// - `.named` actual + primitive expected: resolve the named kind's
///   underlying; same primitive = `.yes`, different = `.no`, lookup
///   miss / ambiguity / recursion = `.unknown`.
/// - Primitive actual + refined `.named` expected: `.unknown` — a coarse
///   "vector" result cannot prove a fixed-length `vec3`, etc.
/// - `.named` actual + `.named` expected with matching names = `.yes`;
///   different names compare resolved underlyings as above, with
///   refinements on expected forcing `.unknown` unless actual is
///   exactly that kind.
/// - `.form` / `.expr` are not handled here — typed-slot matching dispatches
///   on those before reaching this helper.
pub const DeclaredTypeMatch = enum { yes, no, unknown };

/// Three-way check on whether an expression's declared `:result` type
/// satisfies an expected typed slot. `.yes` accepts (including the
/// `any`-collapses-to-anything rule); `.no` rejects with a typed-slot
/// diagnostic; `.unknown` defers — the validator should fall back to a
/// runtime-shape check rather than emit a static error. See
/// `DeclaredTypeMatch` for the per-arm contract.
pub fn declaredResultMatchesExpected(
    schema: Schema.Schema,
    actual: Plugin.ValueType,
    expected: Plugin.ValueType,
) DeclaredTypeMatch {
    if (isAnyType(expected)) return .yes;
    if (isAnyType(actual)) return .unknown;

    // Quick win: name-level exact match (after primitive-shortcut
    // normalization) is .yes regardless of refinements.
    const a_norm = normalizeTypeName(actual);
    const e_norm = normalizeTypeName(expected);
    if (valueTypesEqual(a_norm, e_norm)) return .yes;

    const a_prim = primitiveOf(schema, a_norm) orelse return .unknown;
    const e_prim = primitiveOf(schema, e_norm) orelse return .unknown;
    if (a_prim != e_prim) return .no;

    // Same primitive underlying. Refined `.named` expected can't be
    // proven from a coarser actual; defer.
    if (e_norm == .named) {
        const k = switch (schema.lookupValueKind(e_norm.named.name, e_norm.named.namespace)) {
            .found => |kk| kk,
            else => return .unknown,
        };
        if (kindHasRefinements(k)) return .unknown;
    }
    return .yes;
}

fn isAnyType(vt: Plugin.ValueType) bool {
    return switch (vt) {
        .any => true,
        .named => |n| std.mem.eql(u8, n.name, "any"),
        else => false,
    };
}

fn normalizeTypeName(vt: Plugin.ValueType) Plugin.ValueType {
    return switch (vt) {
        .named => |n| resolvePrimitiveShortcut(n.name) orelse vt,
        else => vt,
    };
}

/// One-hop resolution from a `ValueType` to its primitive underlying.
/// Returns null for `.form`, `.expr`, `.any`, lookup miss, ambiguity, or
/// when a `.named` chain doesn't terminate in a primitive at depth 1.
/// Suitable for compatibility checks that only care about the tag-level
/// category (number / string / symbol / boolean / nil / vector); refined
/// dimensions live on the kind, not the underlying.
const PrimitiveUnderlying = enum { number, string, symbol, boolean, nil, vector };

fn primitiveOf(schema: Schema.Schema, vt: Plugin.ValueType) ?PrimitiveUnderlying {
    return switch (vt) {
        .number => .number,
        .string => .string,
        .symbol => .symbol,
        .boolean => .boolean,
        .nil => .nil,
        .vector => .vector,
        .any, .form, .expr => null,
        .named => |n| switch (schema.lookupValueKind(n.name, n.namespace)) {
            .found => |k| switch (k.underlying) {
                .number => .number,
                .string => .string,
                .symbol => .symbol,
                .vector => .vector,
                .form => null,
                .union_of => null,
            },
            else => null,
        },
    };
}

/// True if the kind narrows its underlying with refinements that need
/// per-value inspection: vector length, unit requirement, member set,
/// head set, cross-ref, union dispatch. A coarse primitive result type
/// can't prove these — caller treats actual≠expected as `.unknown`.
fn kindHasRefinements(k: *const Plugin.ValueKind) bool {
    if (k.vector) |_| return true;
    if (k.unit) |_| return true;
    if (k.members) |_| return true;
    if (k.heads) |_| return true;
    if (k.cross_ref) |_| return true;
    if (k.union_of) |_| return true;
    return false;
}

/// True if `expected` is a `.named` reference to a value-kind whose
/// underlying is `.union_of`. Forms hit this gate to fall through to
/// the union-dispatch path in `matchValueAgainstKind`, so a sibling
/// alternative (e.g. a `.form`-underlying kind) can accept the form.
fn resolvesToUnion(schema: Schema.Schema, expected: Plugin.ValueType) bool {
    switch (expected) {
        .named => |n| switch (schema.lookupValueKind(n.name, n.namespace)) {
            .found => |k| return k.underlying == .union_of,
            else => return false,
        },
        else => return false,
    }
}

/// English label for an expected type, used in `wrong_underlying`
/// messages when a form's resolved expression result is incompatible
/// with the slot. Stable across Tree / Binary paths so conformance
/// stays diagnostic-equal.
pub fn typeLabel(expected: Plugin.ValueType) []const u8 {
    return switch (expected) {
        .any => "any value",
        .number => "number",
        .string => "string",
        .symbol => "symbol",
        .boolean => "boolean",
        .nil => "nil",
        .vector => "vector",
        .form => "form",
        .expr => "expression",
        .named => |n| n.name,
    };
}

/// One validator finding tied to a source span. Every field's lifetime is
/// the enclosing `Result`'s arena. Aliased to `Ast.Diagnostic` so a
/// downstream consumer rendering both parse and validate diagnostics in
/// one UI sees a single type.
pub const Diagnostic = Ast.Diagnostic;

/// Validation outcome. Owns an arena for diagnostic strings; call
/// `result.deinit()` to release them.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    diagnostics: []const Diagnostic,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const Result) bool {
        for (self.diagnostics) |d| if (d.severity == .err) return true;
        return false;
    }
};

/// Errors `validateBinary` can return. Same set as `BinaryCursor.Error`
/// (== `Binary.Error`): the streaming validator forwards every wire-format
/// error from the cursor, plus its own `DepthExceeded` for the step / frame
/// budget. Schema violations remain diagnostics inside the returned `Result`.
///
/// `validate` (the Tree path) only allocates and therefore returns
/// `Allocator.Error!Result`; it does not need this set.
///
/// `DepthExceeded` is shared with `Binary.Error` and `Expr.Error` — the
/// shared name is a deliberate spine across the depth-bounded walkers; see
/// each module's `Error` doc-comment for the per-site meaning. Here it
/// means the `MAX_VALIDATE_STEPS` or `MAX_VALIDATE_FRAMES` budget was
/// exceeded.
pub const Error = BinaryCursor.Error;

/// One stack frame in the iterative descent. Pairs a node index with
/// the semantic path that leads to it from the document root, used as
/// the `path` field on every diagnostic emitted from this node.
///
/// `scope_chain` is the chain of currently-open lexical scopes from
/// outermost to innermost — each entry recording its scope-opening form's
/// canonical name plus the `ScopeId` instances it represents. The chain
/// is recomputed (and arena-allocated) only when crossing a scope-opener;
/// non-opening descendants share their parent's chain by reference.
const Frame = struct {
    idx: Ast.NodeIndex,
    /// Owned by `arena`. Each step is a borrowed slice (form head /
    /// kvpair key / decimal index string).
    path: []const []const u8,
    scope_chain: []const ScopeFrame = &.{},
    /// Spec of the form this frame's node lives inside (the immediate
    /// parent form when this frame is a kvpair / form / vector / atom
    /// child of a form). Null at roots and inside vector elements.
    /// Used by the kvpair handler to honour `KeySpec.walk_opaque`.
    parent_form_spec: ?*const Plugin.FormSpec = null,
    /// Slot-local form registry in scope for this frame. Set on a form
    /// value frame by the kvpair handler when the matching `KeySpec` has
    /// `local_forms`: the form's head then resolves local-first against
    /// this slice before the additive global fallback. Null otherwise.
    local_form_registry: ?[]const Plugin.FormSpec = null,
    /// Path of the enclosing slot (the kvpair), used to emit
    /// `unknown_local_form` at the slot (e.g. `[canvas shape]`) rather than
    /// at the value's unknown head. Meaningful only when
    /// `local_form_registry != null`.
    local_form_slot_path: []const []const u8 = &.{},
};

/// One link in the lexical scope chain. `canonical` is borrowed from
/// the long-lived `scope_heads` set; `scope_id` is the per-instance
/// `ScopeId.lexical(tree_idx, lexical_id)` value the index registered
/// names under.
pub const ScopeFrame = struct {
    canonical: []const u8,
    scope_id: ScopeId,
};

/// Resolve the nearest enclosing scope whose canonical form matches
/// `scope_form`, walking innermost-first. Returns null when no chain
/// entry matches — at the reference site the caller emits
/// `cross_ref_outside_scope`.
fn findNearestScope(chain: []const ScopeFrame, scope_form: []const u8) ?ScopeId {
    var i: usize = chain.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, chain[i].canonical, scope_form)) return chain[i].scope_id;
    }
    return null;
}

/// Encoded scope identity. References resolve only against names
/// registered under the same scope, so two pieces with phrases `p0`
/// in each don't collide.
///
/// Encoding (u64-tagged so a single `AutoHashMap(ScopeId, …)`
/// monomorphisation serves both tree-only and lexical-scope worlds):
///   bit 63    : 0 = tree-scope, 1 = lexical-scope
///   bits 32-62: lexical_id (the scope-opening form's AST node index
///               on the tree path, or its payload byte offset on the
///               binary path; ignored for tree-scope)
///   bits 0-31 : tree_idx
///
/// In v1 (this PR) only tree-scope is constructed; lexical-scope is
/// reserved for the `:scope <form>` follow-up.
pub const ScopeId = enum(u64) {
    _,

    pub inline fn tree(tree_idx: u32) ScopeId {
        return @enumFromInt(@as(u64, tree_idx));
    }

    pub inline fn lexical(tree_idx: u32, lexical_id: u32) ScopeId {
        const v: u64 = (@as(u64, 1) << 63) | (@as(u64, lexical_id) << 32) | tree_idx;
        return @enumFromInt(v);
    }

    pub inline fn treeIdx(self: ScopeId) u32 {
        return @truncate(@intFromEnum(self));
    }

    pub inline fn isLexical(self: ScopeId) bool {
        return (@intFromEnum(self) >> 63) != 0;
    }
};

/// Document-discovered name table. Built once per `validateForest` call
/// from a full DFS over every tree's forms; consumed by
/// `matchValueAgainstKind`'s `.symbol` branch on slots whose kind has
/// `cross_ref` set.
///
/// Three-level keying:
///   1. Outer `by_scope` map: `ScopeId` → `TargetMap`. References
///      resolve only against names registered under the same scope —
///      v1 enforces per-tree isolation by default (every tree gets
///      its own `ScopeId.tree(idx)`).
///   2. `TargetMap`: canonical `<plugin>/<form>` target name →
///      `NameMap`. Two plugins each declaring a form named `phrase`
///      register under distinct keys (`audio/phrase` vs.
///      `music/phrase`).
///   3. `NameMap`: the form's `:name-key` value text → `Site`
///      locating the defining occurrence (first-by-input-order
///      within its scope).
///
/// `Site` is the public surface LSP follow-on features (goto-definition,
/// find-references, rename, completion-from-registry) consume. The
/// validator's hot path uses only `contains`; `Site`'s span and scope
/// fields are dead from the validator's perspective and there for the LSP.
///
/// Empty when the schema declares no cross-refs — the index pass exits
/// early in that case.
pub const CrossRefIndex = struct {
    by_scope: std.AutoHashMapUnmanaged(ScopeId, TargetMap) = .empty,
    /// Parallel to `by_scope`, but each leaf is a list of reference Sites
    /// (where a name was *used*) rather than the single defining Site.
    /// Populated incrementally during `matchValueAgainstKind` /
    /// `matchKindBinary`'s `.symbol` branch — the same query that emits
    /// `not_cross_ref` also captures the site, regardless of hit/miss
    /// (typo'd references are still reference sites for find-refs/rename).
    references_by_scope: std.AutoHashMapUnmanaged(ScopeId, RefTargetMap) = .empty,
    /// Targets whose member set could not be computed, per scope. A
    /// provider-route registration whose extraction failed or never ran
    /// records `(scope, canonical target)` here instead of registering
    /// names; the membership sites then accept every reference into that
    /// bucket rather than reporting misses against a set nobody could
    /// compute. One root-cause diagnostic, zero cascade.
    ///
    /// Parallel to `by_scope` rather than a flag inside `TargetMap`,
    /// deliberately: `TargetMap`'s value *is* the `NameMap`, which
    /// `contains` / `lookup` / `iterateNames` / `registerSite` and three
    /// LSP sites consume directly. Being parallel also means poison
    /// survives the union probe's shallow index copy for free.
    poisoned_by_scope: std.AutoHashMapUnmanaged(ScopeId, PoisonSet) = .empty,
    /// Buckets whose member set comes (or was meant to come) from a
    /// provider extraction, keyed like `poisoned_by_scope`; the value is
    /// the provider's possibly-qualified name, duped onto the index
    /// arena. Marked whether the extraction succeeded, failed, or never
    /// ran — the fact recorded is the *route*, not the outcome. LSP
    /// write features consult this: a name whose defining occurrence is
    /// bytes inside an opaque string can be navigated to but not
    /// renamed, since the finest def span available is the whole source
    /// literal and an edit over it would replace the source with the
    /// new name.
    provider_backed_by_scope: std.AutoHashMapUnmanaged(ScopeId, ProviderMap) = .empty,
    /// Allocator backing every map/list above. Set to the index arena's
    /// allocator at construction (`buildCrossRefIndex*`); appending a
    /// reference reuses this so `appendReference` doesn't have to thread
    /// an allocator through every validation layer.
    arena: ?Allocator = null,

    pub const TargetMap = std.StringHashMapUnmanaged(NameMap);
    pub const NameMap = std.StringHashMapUnmanaged(Site);

    pub const RefTargetMap = std.StringHashMapUnmanaged(RefNameMap);
    pub const RefNameMap = std.StringHashMapUnmanaged(std.ArrayList(Site));

    /// Canonical target names whose member set is unknowable in one scope.
    pub const PoisonSet = std.StringHashMapUnmanaged(void);

    /// Canonical target name → provider name, for provider-route buckets.
    pub const ProviderMap = std.StringHashMapUnmanaged([]const u8);

    /// Where a registered name was defined or referenced. `tree_idx`
    /// indexes into the `trees` slice passed to `validateForest`; spans
    /// are byte offsets into that tree's source. `scope` records which
    /// scope owns this site — LSP rename / find-refs use it to bound
    /// their search.
    ///
    /// For definitions, `form_span` is the whole `(phrase :name p0 …)`
    /// form and `name_span` is the `:name-key` value token. For
    /// references, both fields are the symbol-value span — the validator
    /// hot path doesn't carry the enclosing form's idx down to the leaf
    /// match, and the LSP only needs `name_span` anyway.
    pub const Site = struct {
        tree_idx: u32,
        node_idx: Ast.NodeIndex,
        form_span: Ast.Span,
        name_span: Ast.Span,
        scope: ScopeId,
    };

    pub fn isEmpty(self: *const CrossRefIndex) bool {
        return self.by_scope.count() == 0;
    }

    pub fn contains(
        self: *const CrossRefIndex,
        scope: ScopeId,
        target: []const u8,
        name: []const u8,
    ) bool {
        const tm = self.by_scope.getPtr(scope) orelse return false;
        const set = tm.getPtr(target) orelse return false;
        return set.contains(name);
    }

    /// Look up the defining `Site` of a registered name, or null when
    /// the scope/target isn't tracked or the name wasn't registered
    /// in that scope.
    pub fn lookup(
        self: *const CrossRefIndex,
        scope: ScopeId,
        target: []const u8,
        name: []const u8,
    ) ?Site {
        const tm = self.by_scope.getPtr(scope) orelse return null;
        const set = tm.getPtr(target) orelse return null;
        return set.get(name);
    }

    /// All reference Sites recorded for a `(scope, target, name)` triple,
    /// or empty slice when none are registered. Order is the validator's
    /// traversal order (depth-first pre-order, tree-by-tree on the tree
    /// path; iterative descent on the binary path) — both stable for the
    /// same input.
    pub fn lookupReferences(
        self: *const CrossRefIndex,
        scope: ScopeId,
        target: []const u8,
        name: []const u8,
    ) []const Site {
        const tm = self.references_by_scope.getPtr(scope) orelse return &.{};
        const set = tm.getPtr(target) orelse return &.{};
        const list = set.getPtr(name) orelse return &.{};
        return list.items;
    }

    /// Iterate every registered name under `(scope, target)`. Order is
    /// hashmap-iteration order — stable for the same input but not
    /// otherwise specified. Empty when the scope/target isn't tracked.
    /// LSP completions use this to surface valid cross-ref symbols
    /// without exposing the underlying `StringHashMapUnmanaged`.
    pub fn iterateNames(
        self: *const CrossRefIndex,
        scope: ScopeId,
        target: []const u8,
    ) NameMap.Iterator {
        const tm = self.by_scope.getPtr(scope) orelse return (NameMap{}).iterator();
        const set = tm.getPtr(target) orelse return (NameMap{}).iterator();
        return set.iterator();
    }

    /// True when `(scope, target)`'s member set could not be computed —
    /// see `poisoned_by_scope`. O(1) and only ever reached on a
    /// membership *miss*, so a healthy document pays nothing: the
    /// `contains` hit returns first.
    pub fn isPoisoned(
        self: *const CrossRefIndex,
        scope: ScopeId,
        target: []const u8,
    ) bool {
        const set = self.poisoned_by_scope.getPtr(scope) orelse return false;
        return set.contains(target);
    }

    /// Mark `(scope, target)`'s member set unknowable. Idempotent — two
    /// broken source instances under one target poison it once, and each
    /// still emits its own root-cause diagnostic. `target` must already
    /// live on the index arena (it is a `collectCrossRefTargets` key, as
    /// everywhere else in this index).
    fn poison(
        self: *CrossRefIndex,
        a: Allocator,
        scope: ScopeId,
        target: []const u8,
    ) Allocator.Error!void {
        const scope_gop = try self.poisoned_by_scope.getOrPut(a, scope);
        if (!scope_gop.found_existing) scope_gop.value_ptr.* = .empty;
        try scope_gop.value_ptr.put(a, target, {});
    }

    /// The provider name behind a provider-route bucket, or null for an
    /// identity-route one — see `provider_backed_by_scope`.
    pub fn providerBacked(
        self: *const CrossRefIndex,
        scope: ScopeId,
        target: []const u8,
    ) ?[]const u8 {
        const pm = self.provider_backed_by_scope.getPtr(scope) orelse return null;
        return pm.get(target);
    }

    /// Mark `(scope, target)` provider-backed. Idempotent, and the first
    /// marking wins — one bucket has one provider (a target form's spec
    /// names exactly one). Same `target` lifetime contract as `poison`;
    /// `provider` is duped because it borrows from the schema, which the
    /// LSP can swap while the index is still held.
    fn markProviderBacked(
        self: *CrossRefIndex,
        a: Allocator,
        scope: ScopeId,
        target: []const u8,
        provider: []const u8,
    ) Allocator.Error!void {
        const scope_gop = try self.provider_backed_by_scope.getOrPut(a, scope);
        if (!scope_gop.found_existing) scope_gop.value_ptr.* = .empty;
        const gop = try scope_gop.value_ptr.getOrPut(a, target);
        if (!gop.found_existing) gop.value_ptr.* = try a.dupe(u8, provider);
    }

    /// Record a reference Site under `(scope, target, name)`. No-op when
    /// `arena` isn't set (manually-constructed indices, e.g. in tests
    /// that don't exercise reference capture).
    pub fn appendReference(
        self: *CrossRefIndex,
        scope: ScopeId,
        target: []const u8,
        name: []const u8,
        site: Site,
    ) Allocator.Error!void {
        const a = self.arena orelse return;
        const scope_gop = try self.references_by_scope.getOrPut(a, scope);
        if (!scope_gop.found_existing) scope_gop.value_ptr.* = .empty;
        const target_gop = try scope_gop.value_ptr.getOrPut(a, target);
        if (!target_gop.found_existing) target_gop.value_ptr.* = .empty;
        const name_gop = try target_gop.value_ptr.getOrPut(a, name);
        if (!name_gop.found_existing) name_gop.value_ptr.* = .empty;
        try name_gop.value_ptr.append(a, site);
    }
};

/// Bundle returned by `validateForest`: one `Result` per input tree, plus
/// a forest-wide `CrossRefIndex` owned by its own arena. Caller must
/// either call `deinit` (frees everything) or `intoSingle` (peels the
/// one Result off and drops the index).
pub const ForestResult = struct {
    /// One Result per input tree, in input order. Each Result keeps its
    /// own arena so callers like the LSP can hold one per-document Result
    /// and free them independently as documents close.
    results: []Result,
    /// Forest-wide cross-ref registry. Borrowed strings reference the
    /// trees passed in; lifetime is bounded by `index_arena`.
    cross_ref_index: CrossRefIndex,
    /// Backs `cross_ref_index`. Separate from any `Result` arena so the
    /// LSP can replace the index across revalidations without disturbing
    /// per-document Result lifecycles.
    index_arena: std.heap.ArenaAllocator,

    /// Free every Result and the index arena. The `gpa` must be the same
    /// allocator that produced this ForestResult.
    pub fn deinit(self: *ForestResult, gpa: Allocator) void {
        for (self.results) |*r| r.deinit();
        gpa.free(self.results);
        self.index_arena.deinit();
        self.* = undefined;
    }

    /// Single-tree shortcut: take ownership of the one Result, drop the
    /// index. Asserts `results.len == 1`.
    pub fn intoSingle(self: *ForestResult, gpa: Allocator) Result {
        std.debug.assert(self.results.len == 1);
        const r = self.results[0];
        gpa.free(self.results);
        self.index_arena.deinit();
        self.* = undefined;
        return r;
    }
};

/// `Schema.canonicalFormName`'s hot-path twin, for a form head
/// discovered during DFS: resolve `(head …)` (with optional
/// `namespace`) to the same canonical `<plugin>/<form>` spelling, but
/// write it into a caller-owned `buf` instead of allocating. Returns a
/// slice into `buf`, valid until the next call; null when the form
/// doesn't resolve. Both must mint the same string — the registry keys
/// come from one and the DFS lookups from the other.
fn canonicalFormNameBuf(
    a: Allocator,
    buf: *std.ArrayList(u8),
    schema: Schema.Schema,
    head: []const u8,
    namespace: ?[]const u8,
) Allocator.Error!?[]const u8 {
    const hit = switch (schema.lookupForm(head, namespace)) {
        .found => |h| h,
        else => return null,
    };
    buf.clearRetainingCapacity();
    try buf.appendSlice(a, hit.plugin.name);
    try buf.append(a, '/');
    try buf.appendSlice(a, hit.form.name);
    return buf.items;
}

/// Per-spec, per-scope captured graph for `:acyclic true` cross-refs.
/// Built during the same forest DFS that populates `CrossRefIndex`;
/// consumed by `runAcyclicCheck` immediately after to emit
/// `cyclic_cross_ref`.
///
/// `specs` is gpa-owned (`init` allocates, `deinit` frees). Each
/// `nodes_by_scope[spec_idx]` is a per-scope map from `ScopeId` to the
/// nodes registered under that scope — cycles are detected only within
/// a single scope, so piece-A's phrases never link to piece-B's.
/// Storage for the maps and node lists rides the index arena.
const CycleCtx = struct {
    specs: []Schema.AcyclicSpec,
    nodes_by_scope: []std.AutoHashMapUnmanaged(ScopeId, std.ArrayList(Node)),

    const Node = struct {
        name: []const u8,
        tree_idx: u32,
        name_span: Ast.Span,
        edges: []const []const u8,
    };

    fn init(
        gpa: Allocator,
        index_a: Allocator,
        schema: Schema.Schema,
    ) Allocator.Error!CycleCtx {
        const specs = try Schema.collectAcyclicSpecs(schema, gpa);
        errdefer Schema.freeAcyclicSpecs(gpa, specs);
        const maps = try index_a.alloc(std.AutoHashMapUnmanaged(ScopeId, std.ArrayList(Node)), specs.len);
        for (maps) |*m| m.* = .empty;
        return .{ .specs = specs, .nodes_by_scope = maps };
    }

    fn deinit(self: *CycleCtx, gpa: Allocator) void {
        Schema.freeAcyclicSpecs(gpa, self.specs);
    }

    fn isEmpty(self: *const CycleCtx) bool {
        return self.specs.len == 0;
    }

    /// First spec whose canonical `target_form` matches `canonical`, or
    /// null. Linear scan; spec lists are tiny (typically 1).
    fn specForCanonical(self: *const CycleCtx, canonical: []const u8) ?u32 {
        for (self.specs, 0..) |s, i| {
            if (std.mem.eql(u8, s.target_form, canonical)) return @intCast(i);
        }
        return null;
    }

    fn edgeShape(self: *const CycleCtx, spec_idx: u32, key: []const u8) ?Schema.EdgeShape {
        for (self.specs[spec_idx].edges) |e| {
            if (std.mem.eql(u8, e.name, key)) return e.shape;
        }
        return null;
    }

    fn appendNode(
        self: *CycleCtx,
        index_a: Allocator,
        spec_idx: u32,
        scope: ScopeId,
        name: []const u8,
        tree_idx: u32,
        name_span: Ast.Span,
        edges: []const []const u8,
    ) Allocator.Error!void {
        const gop = try self.nodes_by_scope[spec_idx].getOrPut(index_a, scope);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(index_a, .{
            .name = name,
            .tree_idx = tree_idx,
            .name_span = name_span,
            .edges = edges,
        });
    }
};

/// Per-target spec collected once per validator entry from the schema.
/// `name_key` is the form key carrying the registered name; `scope_form`
/// (when set) is the canonical `<plugin>/<form>` whose instances bound
/// the cross-ref's scope. Null `scope_form` means tree-scoped.
pub const CrossRefSpec = struct {
    name_key: []const u8,
    scope_form: ?[]const u8,
    /// Provider route: canonical `<plugin>/<provider>` name whose
    /// extractor supplies this target's member names. Null is the
    /// identity route, where `name_key` reads the name off the instance
    /// itself. The two routes are exclusive by construction — the
    /// manifest loader drops whichever key contradicts the other, so a
    /// spec that reaches here took exactly one of them.
    provider: ?[]const u8 = null,
    /// Provider route: key on the target form whose *string* value is
    /// handed to the extractor. Meaningless when `provider` is null.
    source_key: []const u8 = "src",
};

/// Walk every plugin's value-kinds and collect `canonical_target → CrossRefSpec`,
/// where `canonical_target` is the schema-resolved `<plugin>/<form>` name
/// produced by `Schema.canonicalFormName`. Shared by both Tree and Binary
/// forest paths so the schema iteration is not duplicated. First-wins if
/// multiple cross-refs share a target.
///
/// Keys live on `index_a` and ride the index arena's lifetime — they're
/// the same strings used to register and look up `CrossRefIndex` entries,
/// so canonicalising once here means the hot path can compare slices
/// directly against the registry. `scope_form` (when set) is also
/// canonicalised so scope-chain lookups compare canonical-to-canonical.
fn collectCrossRefTargets(
    index_a: Allocator,
    schema: Schema.Schema,
) Allocator.Error!std.StringHashMapUnmanaged(CrossRefSpec) {
    var targets: std.StringHashMapUnmanaged(CrossRefSpec) = .empty;
    errdefer targets.deinit(index_a);
    for (schema.plugins) |*plugin| {
        for (plugin.value_kinds) |*kind| {
            const cr = kind.cross_ref orelse continue;
            const canonical = (try schema.canonicalFormName(index_a, cr.target_form)) orelse continue;
            const scope_canonical: ?[]const u8 = if (cr.scope_form) |sf|
                try schema.canonicalFormName(index_a, sf)
            else
                null;
            // An unresolvable `:provider` drops the whole cross-ref rather
            // than falling back to the identity route: reading `:name` off
            // a form the author never meant to name that way would invent
            // a member set out of a schema error. First-wins then lets a
            // sound cross-ref on the same target take the slot.
            const provider_canonical: ?[]const u8 = if (cr.provider) |pv|
                (try schema.canonicalProviderName(index_a, pv)) orelse continue
            else
                null;
            const gop = try targets.getOrPut(index_a, canonical);
            if (!gop.found_existing) gop.value_ptr.* = .{
                .name_key = cr.name_key,
                .scope_form = scope_canonical,
                .provider = provider_canonical,
                .source_key = cr.source_key,
            };
        }
    }
    return targets;
}

/// Set of canonical form names whose instances open a lexical scope.
/// Built alongside `collectCrossRefTargets`; used during DFS to recognise
/// scope boundaries in O(1).
fn collectScopeHeads(
    index_a: Allocator,
    targets: *const std.StringHashMapUnmanaged(CrossRefSpec),
) Allocator.Error!std.StringHashMapUnmanaged(void) {
    var heads: std.StringHashMapUnmanaged(void) = .empty;
    errdefer heads.deinit(index_a);
    var it = targets.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.scope_form) |sf| {
            try heads.put(index_a, sf, {});
        }
    }
    return heads;
}

/// Same shape as `collectScopeHeads` but built directly from the schema —
/// used by the per-tree validation walks (which don't carry a `targets`
/// map). Keys are allocated on `a`; pair with `freeSchemaScopeHeads` to
/// clean up.
fn schemaScopeHeads(
    a: Allocator,
    schema: Schema.Schema,
) Allocator.Error!std.StringHashMapUnmanaged(void) {
    var heads: std.StringHashMapUnmanaged(void) = .empty;
    errdefer freeSchemaScopeHeads(a, &heads);
    for (schema.plugins) |*plugin| {
        for (plugin.value_kinds) |*kind| {
            const cr = kind.cross_ref orelse continue;
            const scope = cr.scope_form orelse continue;
            const canonical = (try schema.canonicalFormName(a, scope)) orelse continue;
            const gop = try heads.getOrPut(a, canonical);
            if (gop.found_existing) a.free(canonical);
        }
    }
    return heads;
}

/// Free the canonical name strings owned by a `schemaScopeHeads` result,
/// then deinit the map itself.
fn freeSchemaScopeHeads(a: Allocator, heads: *std.StringHashMapUnmanaged(void)) void {
    var it = heads.keyIterator();
    while (it.next()) |k| a.free(k.*);
    heads.deinit(a);
}

/// One provider run's outcome, as the validator consumes it.
///
/// The types live here — with the consumer — rather than with the module
/// that *builds* them (`ProviderExtraction`): fulfillment needs the plugin
/// invoker, which is host territory, and an `Options` field naming a type
/// from there would close an import cycle. `ProviderExtraction` imports
/// `Validator`; `Validator` never imports it back.
pub const Extraction = union(enum) {
    /// The extracted member names, in provider order, deduplicated within
    /// this one source. Duplicates *inside* one blob are the provider's
    /// business — a name is a name, and a source's internal redundancy is
    /// not a document error. Duplicates across two sources in one scope
    /// stay the document's business and keep firing
    /// `duplicate_cross_ref_target`.
    names: []const []const u8,
    /// The provider ran and said no: malformed source, a result that
    /// violated the value contract, or a cap trip. Reported as
    /// `cross_ref_extraction_failed` at each site that asked for it.
    failure: Failure,
    /// The provider could not be run at all — no bytes and no native
    /// impl, a host built without executable-plugin support, no runtime,
    /// or a name no loaded plugin declares. Carries the reason and is
    /// reported as `cross_ref_provider_unavailable`.
    ///
    /// An entry rather than an absence, so the table is *total* over the
    /// pairs that were requested. A lookup that comes back null then
    /// means exactly one thing — the discovery walk and the index walk
    /// disagreed about which pairs exist — instead of being ambiguous
    /// with "the host could not run it".
    unavailable: []const u8,

    pub const Failure = struct {
        message: []const u8,
        /// Byte offset into the source, when the provider knows one. It is
        /// folded into the message rather than into the diagnostic's span:
        /// the source is an opaque blob in some other language, so the
        /// span that means something to SJON is the whole string value.
        offset: ?u32 = null,
    };
};

/// Extraction-table key: a canonical `<plugin>/<provider>` name plus the
/// source bytes it was handed.
pub const ExtractionKey = struct {
    provider: []const u8,
    source: []const u8,
};

/// Content hashing on both halves — the point of content addressing is
/// that the same source in two documents is one extraction, so the key
/// cannot be identity-based. Both halves are length-prefixed so
/// `("ab", "c")` and `("a", "bc")` hash apart.
const ExtractionKeyContext = struct {
    pub fn hash(_: ExtractionKeyContext, k: ExtractionKey) u64 {
        var h: std.hash.Wyhash = .init(0);
        h.update(std.mem.asBytes(&@as(u64, k.provider.len)));
        h.update(k.provider);
        h.update(k.source);
        return h.final();
    }
    pub fn eql(_: ExtractionKeyContext, a: ExtractionKey, b: ExtractionKey) bool {
        return std.mem.eql(u8, a.provider, b.provider) and
            std.mem.eql(u8, a.source, b.source);
    }
};

/// `(provider, source) → Extraction`, content-addressed on purpose:
/// identical sources extract once, table order is irrelevant, and
/// discovery does not have to agree with the index pass about *which
/// instances* exist — only that every pair the index looks up is present.
pub const ExtractionMap = std.HashMapUnmanaged(
    ExtractionKey,
    Extraction,
    ExtractionKeyContext,
    std.hash_map.default_max_load_percentage,
);

const ExtractionKeySet = std.HashMapUnmanaged(
    ExtractionKey,
    void,
    ExtractionKeyContext,
    std.hash_map.default_max_load_percentage,
);

/// A pair some document asked for. Deliberately just the key: the
/// diagnostics that a failed extraction produces are emitted by the index
/// pass, at each site that asked, so a request carries no span of its own
/// and there is no "first site" to privilege.
pub const ExtractionRequest = ExtractionKey;

/// Owned result of `collectExtractionRequests`. `provider` strings live on
/// `arena`; `source` slices are *borrowed* from the input trees (or binary
/// buffers), which must outlive this struct — the same borrow the
/// cross-ref index already takes.
pub const ExtractionRequests = struct {
    arena: std.heap.ArenaAllocator,
    items: []const ExtractionRequest,

    pub fn deinit(self: *ExtractionRequests) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Walk `trees` and collect every distinct `(provider, source)` pair a
/// provider-backed cross-ref target instance asks for. Pre-order DFS with
/// the same descent as `buildCrossRefIndexForest` — every `(form …)`, not
/// just roots — and the same target set (`collectCrossRefTargets`), so the
/// request walk and the index walk cannot drift apart on what a "target"
/// is.
///
/// Lexical tolerance matches `registerCrossRefInstance`: a missing,
/// duplicated, or non-string `:source-key` value is skipped silently. Each
/// of those surfaces elsewhere (missing-required-key / `duplicate_key` /
/// the value-type mismatch), and the index pass skips the same instances,
/// so nothing is looked up that was not requested.
///
/// Only *written* source values are read — a `:source-key` supplied by a
/// materialized default is not extracted. The index pass declines the same
/// ones, which is what keeps the two walks in agreement.
///
/// O(nodes) over the forest; the DFS stack is heap-held on `gpa`, never
/// the host stack.
pub fn collectExtractionRequests(
    gpa: Allocator,
    schema: Schema.Schema,
    trees: []const Ast.Tree,
) Allocator.Error!ExtractionRequests {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var items: std.ArrayList(ExtractionRequest) = .empty;

    // Two guards, and they ask different questions. This one is free —
    // no allocation, no canonicalisation — so every schema written before
    // providers existed pays one scan and stops. `anyProviderRoute` below
    // asks the *resolved* question, which needs the targets map built.
    if (declaresProviderRoute(schema)) {
        // Arena-owned: the canonical provider names handed out below ride it.
        var targets = try collectCrossRefTargets(a, schema);
        if (!anyProviderRoute(&targets)) return .{ .arena = arena, .items = &.{} };

        var seen: ExtractionKeySet = .empty;

        var stack: std.ArrayList(Ast.NodeIndex) = .empty;
        defer stack.deinit(gpa);
        var canon_buf: std.ArrayList(u8) = .empty;
        defer canon_buf.deinit(gpa);

        for (trees) |*tree| {
            stack.clearRetainingCapacity();
            var ri: usize = tree.root.len;
            while (ri > 0) : (ri -= 1) try stack.append(gpa, tree.root[ri - 1]);

            while (stack.pop()) |idx| {
                switch (tree.tagOf(idx)) {
                    .form => {
                        const hdr = tree.formHeader(idx);
                        if (try canonicalFormNameBuf(gpa, &canon_buf, schema, hdr.head, hdr.namespace)) |canon| {
                            if (targets.get(canon)) |spec| request: {
                                const provider = spec.provider orelse break :request;
                                const source = sourceTextOf(tree, hdr, spec.source_key) orelse break :request;
                                const key: ExtractionKey = .{ .provider = provider, .source = source.text };
                                const gop = try seen.getOrPut(a, key);
                                if (gop.found_existing) break :request;
                                gop.value_ptr.* = {};
                                try items.append(a, key);
                            }
                        }
                        var ci: usize = hdr.children.len;
                        while (ci > 0) : (ci -= 1) try stack.append(gpa, hdr.children[ci - 1]);
                    },
                    .vector => {
                        const elements = tree.vectorElements(idx);
                        var ci: usize = elements.len;
                        while (ci > 0) : (ci -= 1) try stack.append(gpa, elements[ci - 1]);
                    },
                    .kvpair => try stack.append(gpa, tree.kvpairHeader(idx).value),
                    else => {},
                }
            }
        }
    }

    return .{ .arena = arena, .items = items.items };
}

/// True when some value-kind's cross-ref names a provider at all. The
/// allocation-free pre-check: a schema that fails it cannot produce a
/// request, so neither discovery walk builds anything.
fn declaresProviderRoute(schema: Schema.Schema) bool {
    for (schema.plugins) |*plugin| {
        for (plugin.value_kinds) |*kind| {
            const cr = kind.cross_ref orelse continue;
            if (cr.provider != null) return true;
        }
    }
    return false;
}

/// True when at least one *collected* target takes the provider route —
/// i.e. its `:provider` also resolved. Distinct from
/// `declaresProviderRoute`, which cannot know that yet.
fn anyProviderRoute(targets: *const std.StringHashMapUnmanaged(CrossRefSpec)) bool {
    var it = targets.valueIterator();
    while (it.next()) |spec| if (spec.provider != null) return true;
    return false;
}

/// The first `source_key` kvpair whose value is a string. `text` is
/// borrowed from the tree; `span` is the string value's own span, which is
/// where every provider-route diagnostic anchors — the source is opaque
/// content in some other language, so the whole literal is the only span
/// that means anything in SJON terms.
const SourceValue = struct {
    text: []const u8,
    span: Ast.Span,
};

/// The form's usable source value, or null when it carries none.
/// First-wins on duplicates, mirroring the `:name-key` read, and null on a
/// non-string first match for the same reason that read skips a non-symbol:
/// the slot's own type error is the visible diagnostic and cross-ref does
/// not cascade on top of it.
fn sourceTextOf(tree: *const Ast.Tree, hdr: Ast.FormHeader, source_key: []const u8) ?SourceValue {
    for (hdr.children) |ch| {
        if (tree.tagOf(ch) != .kvpair) continue;
        const kv = tree.kvpairHeader(ch);
        if (!std.mem.eql(u8, kv.key, source_key)) continue;
        if (tree.tagOf(kv.value) != .string) return null;
        return .{ .text = tree.stringText(kv.value), .span = tree.spanOf(kv.value) };
    }
    return null;
}

/// Frame for the binary discovery walk. Deliberately not `IndexFrame`:
/// that one carries scopes, cycle edges, and captured spans because the
/// index registers *sites*, and discovery registers nothing — it only has
/// to reach every form and read one string off some of them.
const ExtractionFrame = union(enum) {
    form: struct {
        iter: BinaryCursor.ChildIter,
        /// Canonical provider name when this form is a provider-backed
        /// target; null frames descend without requesting.
        provider: ?[]const u8,
        /// Meaningful only when `provider` is non-null.
        source_key: []const u8,
        /// True once the first `source_key`-matching kvpair is consumed;
        /// later matches are ignored, mirroring the tree walk's first-wins.
        saw_source_kvpair: bool = false,
    },
    vector: BinaryCursor.VectorIter,
};

/// Binary twin of `collectExtractionRequests`: same target set, same
/// first-wins lexical tolerance, same content-addressed dedupe, read
/// through `BinaryCursor` instead of an `Ast.Tree`. The native binary
/// paths (conformance replay, `validateForestBinary`'s callers) meet user
/// schemas, so they need the same pairs their tree counterparts discover.
///
/// Takes a `Budget` where the tree twin takes none: a tree was bounded by
/// the parser on the way in, whereas binary bytes arrive unbounded, so the
/// walkers over them carry this module's step and frame ceilings
/// (`MAX_VALIDATE_STEPS` / `MAX_VALIDATE_FRAMES`).
pub fn collectExtractionRequestsBinary(
    gpa: Allocator,
    schema: Schema.Schema,
    binaries: []const []const u8,
    budget: Budget,
) Error!ExtractionRequests {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var items: std.ArrayList(ExtractionRequest) = .empty;

    // Same two guards, same reasons, as the tree twin.
    if (declaresProviderRoute(schema)) {
        var targets = try collectCrossRefTargets(a, schema);
        if (!anyProviderRoute(&targets)) return .{ .arena = arena, .items = &.{} };

        var seen: ExtractionKeySet = .empty;

        var frames: std.ArrayList(ExtractionFrame) = .empty;
        defer frames.deinit(gpa);
        var canon_buf: std.ArrayList(u8) = .empty;
        defer canon_buf.deinit(gpa);

        for (binaries) |bytes| {
            var cursor = try BinaryCursor.Cursor.init(bytes);
            var root_iter = try cursor.rootIter();

            while (try root_iter.next()) |root_view| {
                try dispatchExtractionValue(gpa, &canon_buf, schema, &cursor, root_view, &targets, &frames);

                var step: u32 = 0;
                while (frames.items.len > 0) {
                    if (step >= budget.steps) return error.DepthExceeded;
                    if (frames.items.len > budget.frames) return error.DepthExceeded;
                    step += 1;

                    const top = frames.items.len - 1;
                    switch (frames.items[top]) {
                        .form => {
                            const fi = &frames.items[top].form;
                            if (fi.iter.remaining == 0) {
                                // Drain trailing comments before popping, or
                                // the cursor desyncs on the next sibling.
                                _ = try fi.iter.next();
                                _ = frames.pop();
                                continue;
                            }
                            const entry = (try fi.iter.next()) orelse unreachable;

                            if (fi.provider) |prov| {
                                if (!fi.saw_source_kvpair and entry.kind == .keyword and
                                    std.mem.eql(u8, entry.key.?, fi.source_key))
                                {
                                    fi.saw_source_kvpair = true;
                                    if (entry.value.kind == .string) {
                                        const key: ExtractionKey = .{
                                            .provider = prov,
                                            .source = try BinaryCursor.readString(&cursor, entry.value),
                                        };
                                        const gop = try seen.getOrPut(a, key);
                                        if (!gop.found_existing) {
                                            gop.value_ptr.* = {};
                                            try items.append(a, key);
                                        }
                                        continue;
                                    }
                                    // Non-string first match: nothing to
                                    // request, but the value still has to be
                                    // consumed — and descended into, since a
                                    // form there may hold targets of its own.
                                }
                            }

                            // `dispatchExtractionValue` may push and realloc
                            // `frames.items`, invalidating `fi`; every write
                            // to it is above this line.
                            try dispatchExtractionValue(gpa, &canon_buf, schema, &cursor, entry.value, &targets, &frames);
                        },
                        .vector => {
                            const vi = &frames.items[top].vector;
                            if (vi.remaining == 0) {
                                _ = try vi.next();
                                _ = frames.pop();
                                continue;
                            }
                            const ev = (try vi.next()) orelse unreachable;
                            try dispatchExtractionValue(gpa, &canon_buf, schema, &cursor, ev, &targets, &frames);
                        },
                    }
                }
            }
        }
    }

    return .{ .arena = arena, .items = items.items };
}

/// Push a frame for a form or vector, skip anything else. The form's
/// route is resolved once, at push time, so the iteration loop compares
/// keys against a slice instead of re-canonicalising per child.
fn dispatchExtractionValue(
    gpa: Allocator,
    canon_buf: *std.ArrayList(u8),
    schema: Schema.Schema,
    cursor: *BinaryCursor.Cursor,
    view: BinaryCursor.NodeView,
    targets: *const std.StringHashMapUnmanaged(CrossRefSpec),
    frames: *std.ArrayList(ExtractionFrame),
) Error!void {
    switch (view.kind) {
        .form => {
            const fv = try BinaryCursor.readForm(cursor, view);
            var provider: ?[]const u8 = null;
            var source_key: []const u8 = "";
            if (try canonicalFormNameBuf(gpa, canon_buf, schema, fv.head, fv.namespace)) |canon| {
                if (targets.get(canon)) |spec| {
                    provider = spec.provider;
                    source_key = spec.source_key;
                }
            }
            try frames.append(gpa, .{ .form = .{
                .iter = fv.children,
                .provider = provider,
                .source_key = source_key,
            } });
        },
        .vector => try frames.append(gpa, .{ .vector = try BinaryCursor.readVector(cursor, view) }),
        else => try BinaryCursor.skipBody(cursor, view),
    }
}

/// Shared fixture for the discovery tests below: two forms (`shader`, the
/// cross-ref target carrying an opaque `:src`; `group`, a plain container
/// used to nest one) and a value-kind whose cross-ref takes whichever
/// route the caller asks for. Same forms on both routes, so a test that
/// swaps only the route is comparing descent, not schemas.
const DiscoveryFixture = struct {
    const forms: []const Plugin.FormSpec = &.{
        .{ .name = "shader", .keys = &.{
            .{ .name = "name", .value_type = .symbol },
            .{ .name = "src", .value_type = .string },
        } },
        .{ .name = "group", .keys = &.{.{ .name = "items", .value_type = .any }} },
    };

    /// `cr` is `comptime` and the returned plugin is a constant: an
    /// `&.{…}` literal built from a *runtime* parameter would point at a
    /// dead stack temporary the moment this returns.
    fn plugin(comptime cr: Plugin.ValueKind.CrossRef) Plugin.Plugin {
        const kinds: []const Plugin.ValueKind = &.{
            .{ .name = "uniform-name", .underlying = .symbol, .cross_ref = cr },
        };
        return .{
            .name = "glsl",
            .cross_ref_providers = &.{.{ .name = "lines", .description = "one name per line" }},
            .value_kinds = kinds,
            .forms = forms,
        };
    }

    const provider_route: Plugin.ValueKind.CrossRef = .{ .target_form = "shader", .provider = "lines" };
    const identity_route: Plugin.ValueKind.CrossRef = .{ .target_form = "shader" };
};

test "extraction discovery: one request per distinct (provider, source) pair" {
    const testing = std.testing;
    const Parser = @import("Parser.zig");
    const gpa = testing.allocator;

    const p = DiscoveryFixture.plugin(DiscoveryFixture.provider_route);
    const schema = Schema.Schema.init(&.{p});

    // Two instances share a source verbatim; the third differs. Content
    // addressing means the shared one is extracted once, and the two
    // sites that asked for it both read that single answer later.
    var tree = try Parser.parse(gpa,
        \\(shader :name a :src "u_one u_two")
        \\(group :items [(shader :name b :src "u_one u_two")])
        \\(shader :name c :src "u_three")
    );
    defer tree.deinit();
    const trees = [_]Ast.Tree{tree};

    var reqs = try collectExtractionRequests(gpa, schema, &trees);
    defer reqs.deinit();

    try testing.expectEqual(@as(usize, 2), reqs.items.len);
    for (reqs.items) |r| try testing.expectEqualStrings("glsl/lines", r.provider);
    try testing.expectEqualStrings("u_one u_two", reqs.items[0].source);
    try testing.expectEqualStrings("u_three", reqs.items[1].source);
}

test "extraction discovery: the identity route requests nothing" {
    const testing = std.testing;
    const Parser = @import("Parser.zig");
    const gpa = testing.allocator;

    const p = DiscoveryFixture.plugin(DiscoveryFixture.identity_route);
    const schema = Schema.Schema.init(&.{p});

    var tree = try Parser.parse(gpa, "(shader :name a :src \"u_one\")");
    defer tree.deinit();
    const trees = [_]Ast.Tree{tree};

    var reqs = try collectExtractionRequests(gpa, schema, &trees);
    defer reqs.deinit();
    try testing.expectEqual(@as(usize, 0), reqs.items.len);
}

test "extraction discovery: an unusable :source-key is skipped, not requested" {
    const testing = std.testing;
    const Parser = @import("Parser.zig");
    const gpa = testing.allocator;

    const p = DiscoveryFixture.plugin(DiscoveryFixture.provider_route);
    const schema = Schema.Schema.init(&.{p});

    // Absent, non-string, and belonging to a head the schema doesn't know.
    // The index pass skips the same instances, so nothing downstream looks
    // up a pair discovery never requested.
    var tree = try Parser.parse(gpa,
        \\(shader :name a)
        \\(shader :name b :src 42)
        \\(unknown-head :name c :src "u_one")
    );
    defer tree.deinit();
    const trees = [_]Ast.Tree{tree};

    var reqs = try collectExtractionRequests(gpa, schema, &trees);
    defer reqs.deinit();
    try testing.expectEqual(@as(usize, 0), reqs.items.len);
}

test "extraction discovery: an unresolvable :provider requests nothing" {
    const testing = std.testing;
    const Parser = @import("Parser.zig");
    const gpa = testing.allocator;

    // `validateCrossRefs` has already said `unknown_cross_ref_provider`
    // here. Discovery declining is what stops the index pass falling back
    // to `:name` and inventing a member set out of a schema error.
    const p = DiscoveryFixture.plugin(.{ .target_form = "shader", .provider = "nope" });
    const schema = Schema.Schema.init(&.{p});

    var tree = try Parser.parse(gpa, "(shader :name a :src \"u_one\")");
    defer tree.deinit();
    const trees = [_]Ast.Tree{tree};

    var reqs = try collectExtractionRequests(gpa, schema, &trees);
    defer reqs.deinit();
    try testing.expectEqual(@as(usize, 0), reqs.items.len);
}

test "extraction discovery: the binary twin discovers what the tree walk does" {
    const testing = std.testing;
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;

    const schema = Schema.Schema.init(&.{DiscoveryFixture.plugin(DiscoveryFixture.provider_route)});

    // Every shape the two walks handle differently on the way down: a
    // nested target, a repeat source (deduped), an absent `:src`, and a
    // non-string one (consumed but not requested).
    var tree = try Parser.parse(gpa,
        \\(shader :name a :src "s1")
        \\(group :items [(shader :name b :src "s2")])
        \\(group :items (shader :name c :src "s1"))
        \\(shader :name d)
        \\(shader :name e :src 42)
    );
    defer tree.deinit();
    const trees = [_]Ast.Tree{tree};

    const bin = try Binary.toBinary(gpa, tree, .{});
    defer bin.deinit();
    const binaries = [_][]const u8{bin.data};

    var from_tree = try collectExtractionRequests(gpa, schema, &trees);
    defer from_tree.deinit();
    var from_binary = try collectExtractionRequestsBinary(gpa, schema, &binaries, .{});
    defer from_binary.deinit();

    try testing.expectEqual(@as(usize, 2), from_tree.items.len);
    try testing.expectEqual(from_tree.items.len, from_binary.items.len);
    for (from_tree.items, from_binary.items) |t, b| {
        try testing.expectEqualStrings(t.provider, b.provider);
        try testing.expectEqualStrings(t.source, b.source);
    }
}

test "budget: the extraction-request walk trips its own step and frame ceilings" {
    // Direct, for the same reason the cross-index budget test is direct:
    // any budget small enough to trip this pre-pass also trips every walk
    // downstream, so only calling it here says which loop answered.
    const testing = std.testing;
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;

    const schema = Schema.Schema.init(&.{DiscoveryFixture.plugin(DiscoveryFixture.provider_route)});

    // Nested on purpose: the frame guard is `len > budget.frames`, so a
    // flat form peaks at one live frame and a cap of 1 would never trip.
    var tree = try Parser.parse(gpa, "(group :items [(shader :name a :src \"s1\")])");
    defer tree.deinit();
    const bin = try Binary.toBinary(gpa, tree, .{});
    defer bin.deinit();
    const binaries = [_][]const u8{bin.data};

    const Case = struct {
        fn run(g: Allocator, sc: Schema.Schema, bins: []const []const u8, budget: Budget) Error!void {
            var reqs = try collectExtractionRequestsBinary(g, sc, bins, budget);
            reqs.deinit();
        }
    };

    try testing.expectError(error.DepthExceeded, Case.run(gpa, schema, &binaries, .{ .steps = 1 }));
    try testing.expectError(error.DepthExceeded, Case.run(gpa, schema, &binaries, .{ .frames = 1 }));

    // Control: the same buffer at the production ceilings, so the trips
    // above are the budget and not the document.
    try Case.run(gpa, schema, &binaries, .{});
}

test "extraction discovery descends exactly where the index pass descends" {
    const testing = std.testing;
    const Parser = @import("Parser.zig");
    const gpa = testing.allocator;

    // Root, inside a vector, and as a kvpair value directly — the three
    // shapes `buildCrossRefIndexForest`'s DFS handles. Same document
    // through both walks with only the cross-ref's route swapped: if one
    // walk ever stops descending somewhere the other still does, these two
    // counts diverge.
    const src =
        \\(shader :name a :src "s1")
        \\(group :items [(shader :name b :src "s2")])
        \\(group :items (shader :name c :src "s3"))
    ;
    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();
    const trees = [_]Ast.Tree{tree};

    const provider_schema = Schema.Schema.init(&.{DiscoveryFixture.plugin(DiscoveryFixture.provider_route)});
    var reqs = try collectExtractionRequests(gpa, provider_schema, &trees);
    defer reqs.deinit();

    const identity_schema = Schema.Schema.init(&.{DiscoveryFixture.plugin(DiscoveryFixture.identity_route)});
    var results = [_]Result{.{ .arena = std.heap.ArenaAllocator.init(gpa), .diagnostics = &.{} }};
    defer results[0].deinit();
    var diags_lists = [_]std.ArrayList(Diagnostic){.empty};
    var index_arena = std.heap.ArenaAllocator.init(gpa);
    defer index_arena.deinit();
    var index = try buildCrossRefIndexForest(
        index_arena.allocator(),
        gpa,
        identity_schema,
        &trees,
        &results,
        &diags_lists,
        .{},
    );

    var registered: usize = 0;
    var it = index.iterateNames(.tree(0), "glsl/shader");
    while (it.next()) |_| registered += 1;

    try testing.expectEqual(@as(usize, 3), registered);
    try testing.expectEqual(registered, reqs.items.len);
}

/// Build the forest-wide cross-ref registry from `schema`'s declared
/// cross-refs and the document content of every input tree. Walks
/// descendants (every `(form …)` node, not just roots) because libraries
/// are commonly nested under containers like `(piece …)`.
///
/// Forest iteration order matches the input slice; within each tree the
/// walk is depth-first pre-order. The first-by-`(tree_idx,
/// document-order)` occurrence wins; later occurrences emit
/// `duplicate_cross_ref_target` on the duplicate's `:name`-value span.
/// The diagnostic is appended to the duplicate's tree's diag list so it
/// surfaces against the correct document.
/// Sentinel `NodeIndex` value used in `buildCrossRefIndexForest`'s DFS
/// stack to mark "pop the lexical scope chain" on unwind. `NodeIndex.invalid`
/// is the natural choice — it never appears as a real document node.
const SCOPE_POP_SENTINEL: Ast.NodeIndex = .invalid;

fn buildCrossRefIndexForest(
    index_a: Allocator,
    gpa: Allocator,
    schema: Schema.Schema,
    trees: []const Ast.Tree,
    results: []Result,
    diags_lists: []std.ArrayList(Diagnostic),
    options: Options,
) Allocator.Error!CrossRefIndex {
    // 1. Collect canonical target → spec. The schema-aggregate phase has
    //    already vetted each cross-ref's `:target` resolves; here we
    //    canonicalise to `<plugin>/<form>` so document forms (also
    //    canonicalised below) can match by string equality.
    var targets = try collectCrossRefTargets(index_a, schema);
    defer targets.deinit(index_a);
    var scope_heads = try collectScopeHeads(index_a, &targets);
    defer scope_heads.deinit(index_a);

    var cycle_ctx = try CycleCtx.init(gpa, index_a, schema);
    defer cycle_ctx.deinit(gpa);

    var index: CrossRefIndex = .{ .arena = index_a };
    if (targets.count() == 0 and cycle_ctx.isEmpty()) return index;

    // 2. Pre-order DFS, tree by tree. Stack memory is transient on `gpa`.
    //    `canon_buf` is reused for canonicalising every encountered form
    //    head; the slice it returns is valid only until the next call.
    //    `scope_stack` parallels the DFS — push on entering a scope-
    //    opening form, pop when its `SCOPE_POP_SENTINEL` is consumed.
    var stack: std.ArrayList(Ast.NodeIndex) = .empty;
    defer stack.deinit(gpa);
    var canon_buf: std.ArrayList(u8) = .empty;
    defer canon_buf.deinit(gpa);
    var scope_stack: std.ArrayList(ScopeFrame) = .empty;
    defer scope_stack.deinit(gpa);

    for (trees, 0..) |*tree, t| {
        stack.clearRetainingCapacity();
        scope_stack.clearRetainingCapacity();
        const t_idx: u32 = @intCast(t);
        const tree_scope: ScopeId = if (options.share_scope) .tree(0) else .tree(t_idx);
        const tree_a = results[t].arena.allocator();
        const tree_options = perTreeOptions(options, t);

        var ri: usize = tree.root.len;
        while (ri > 0) : (ri -= 1) try stack.append(gpa, tree.root[ri - 1]);

        while (stack.pop()) |idx| {
            if (idx == SCOPE_POP_SENTINEL) {
                _ = scope_stack.pop();
                continue;
            }
            switch (tree.tagOf(idx)) {
                .form => {
                    const hdr = tree.formHeader(idx);
                    const canonical = try canonicalFormNameBuf(gpa, &canon_buf, schema, hdr.head, hdr.namespace);
                    if (canonical) |canon| {
                        // Register this form (if a cross-ref target).
                        if (targets.getEntry(canon)) |entry| {
                            const spec = entry.value_ptr.*;
                            const reg_scope = if (spec.scope_form) |sf|
                                findNearestScope(scope_stack.items, sf) orelse tree_scope
                            else
                                tree_scope;
                            try registerCrossRefInstance(
                                index_a,
                                tree_a,
                                &index,
                                &cycle_ctx,
                                tree,
                                t_idx,
                                reg_scope,
                                idx,
                                hdr,
                                entry.key_ptr.*,
                                spec,
                                &diags_lists[t],
                                tree_options,
                            );
                        }
                        // Open a new lexical scope when this form's canonical
                        // name is a `:scope` head somewhere in the schema.
                        if (scope_heads.getEntry(canon)) |sh_entry| {
                            const lexical_id: u32 = @intFromEnum(idx);
                            try scope_stack.append(gpa, .{
                                .canonical = sh_entry.key_ptr.*,
                                .scope_id = .lexical(t_idx, lexical_id),
                            });
                            // Sentinel pops AFTER all children are processed.
                            try stack.append(gpa, SCOPE_POP_SENTINEL);
                        }
                    }
                    var ci: usize = hdr.children.len;
                    while (ci > 0) : (ci -= 1) try stack.append(gpa, hdr.children[ci - 1]);
                },
                .vector => {
                    const elements = tree.vectorElements(idx);
                    var ci: usize = elements.len;
                    while (ci > 0) : (ci -= 1) try stack.append(gpa, elements[ci - 1]);
                },
                .kvpair => {
                    const kvh = tree.kvpairHeader(idx);
                    try stack.append(gpa, kvh.value);
                },
                else => {},
            }
        }
    }

    if (!cycle_ctx.isEmpty()) {
        try runAcyclicCheck(gpa, &cycle_ctx, results, diags_lists);
    }

    return index;
}

fn registerCrossRefInstance(
    index_a: Allocator,
    tree_a: Allocator,
    index: *CrossRefIndex,
    cycle_ctx: *CycleCtx,
    tree: *const Ast.Tree,
    tree_idx: u32,
    scope: ScopeId,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    canonical_target: []const u8,
    spec: CrossRefSpec,
    diags: *std.ArrayList(Diagnostic),
    options: Options,
) Allocator.Error!void {
    if (spec.provider) |provider| return registerFromProvider(
        index_a,
        tree_a,
        index,
        tree,
        tree_idx,
        scope,
        form_idx,
        hdr,
        canonical_target,
        provider,
        spec.source_key,
        diags,
        options,
    );
    const name_key = spec.name_key;

    // Find the form's :name-key kvpair. Lexical tolerance: silently
    // skip when the kvpair is missing, non-symbol, or duplicated. Each
    // of those conditions surfaces elsewhere (missing-required-key /
    // wrong_underlying / duplicate_key) and we don't want to cascade.
    for (hdr.children) |ch| {
        if (tree.tagOf(ch) != .kvpair) continue;
        const kv = tree.kvpairHeader(ch);
        if (!std.mem.eql(u8, kv.key, name_key)) continue;
        if (tree.tagOf(kv.value) != .symbol) return;

        const name_text = tree.symbolText(kv.value);
        try registerName(
            index_a,
            tree_a,
            index,
            cycle_ctx,
            tree,
            tree_idx,
            scope,
            form_idx,
            hdr,
            canonical_target,
            name_text,
            tree.spanOf(kv.value),
            diags,
        );
        return;
    }

    // Axis A — effective name indexing. The author omitted the
    // `:name-key` kvpair; consult the overlay for the same key. A
    // keyword/string default's text becomes the indexed name on the
    // synthetic span `[<form-head>, <name-key>, "default"]`. (Source-
    // level symbol defaults map to `Expr.Value.keyword` via
    // `MaterializedDefaults.literalToValue` — there's no `.symbol`
    // arm at runtime.)
    if (options.axes.name_index) if (options.overlay) |overlay| {
        const entry = overlay.defaultFor(form_idx, name_key) orelse return;
        const text = switch (entry.value) {
            .keyword => |k| k,
            .string => |s| s,
            else => return,
        };
        try registerName(
            index_a,
            tree_a,
            index,
            cycle_ctx,
            tree,
            tree_idx,
            scope,
            form_idx,
            hdr,
            canonical_target,
            text,
            hdr.head_span,
            diags,
        );
    };
}

/// Provider-route registration for one target instance: read the source
/// string, look its extraction up, and either register every extracted
/// name or poison the bucket.
///
/// Axis A is deliberately not consulted here. A *defaulted* source — one
/// supplied by the materialized-defaults overlay rather than written in
/// the document — never reached `collectExtractionRequests`, so its
/// extraction would always be missing and every such instance would read
/// as unavailable. Skipping the overlay makes that a documented v1 limit
/// instead of a stream of misleading diagnostics; lifting it means
/// feeding overlay values into discovery, not patching this arm.
///
/// No `CycleCtx` either, and that is not an omission: the loader rejects
/// `:provider` together with `:acyclic true` (`ManifestLoader.zig`), so a
/// provider-route target never participates in cycle detection.
///
/// Shared by both index builders: the binary path reads its source string
/// during form iteration and calls in with the captured bytes.
fn registerFromProvider(
    index_a: Allocator,
    tree_a: Allocator,
    index: *CrossRefIndex,
    tree: *const Ast.Tree,
    tree_idx: u32,
    scope: ScopeId,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    canonical_target: []const u8,
    provider: []const u8,
    source_key: []const u8,
    diags: *std.ArrayList(Diagnostic),
    options: Options,
) Allocator.Error!void {
    const source = sourceTextOf(tree, hdr, source_key) orelse return;
    try registerExtractedNames(
        index_a,
        tree_a,
        index,
        tree_idx,
        scope,
        form_idx,
        tree.spanOf(form_idx),
        canonical_target,
        provider,
        source.text,
        source.span,
        diags,
        options.extractions,
    );
}

/// The half of the provider route that has no tree in it: given a
/// `(provider, source)` pair and where it was found, fill or poison the
/// bucket. Both index builders funnel here, so the outcome-to-diagnostic
/// mapping and the poisoning rule exist once.
fn registerExtractedNames(
    index_a: Allocator,
    tree_a: Allocator,
    index: *CrossRefIndex,
    tree_idx: u32,
    scope: ScopeId,
    form_idx: Ast.NodeIndex,
    form_span: Ast.Span,
    canonical_target: []const u8,
    provider: []const u8,
    source: []const u8,
    source_span: Ast.Span,
    diags: *std.ArrayList(Diagnostic),
    extractions: ?*const ExtractionMap,
) Allocator.Error!void {
    // Route first, outcome second: the bucket is provider-backed whether
    // the extraction below succeeds, fails, or never ran, and the LSP's
    // rename guard needs the route even for a poisoned bucket (typo'd
    // references into it are still sites a rename request can land on).
    try index.markProviderBacked(index_a, scope, canonical_target, provider);

    // A table that was never built and a table missing this pair are the
    // same situation from here: nobody can say what belongs in this
    // bucket. The distinction (host ran no pre-pass vs. the two walks
    // disagree) matters upstream, not to the document's author.
    const found: ?Extraction = if (extractions) |map|
        map.get(.{ .provider = provider, .source = source })
    else
        null;
    const outcome = found orelse {
        try emitProviderUnavailable(tree_a, diags, source_span, canonical_target, provider, null);
        return index.poison(index_a, scope, canonical_target);
    };

    switch (outcome) {
        .names => |names| for (names) |name| {
            // The extraction table is the host's and outlives neither the
            // index nor the LSP's retention of it, whereas every other
            // registered name borrows from a tree the index outlives
            // (ForestResult's contract). Dupe onto the index arena so the
            // registry's lifetime story stays uniform.
            const owned = try index_a.dupe(u8, name);
            const site = try registerSite(
                index_a,
                tree_a,
                index,
                scope,
                canonical_target,
                owned,
                source_span,
                diags,
            ) orelse continue;
            site.* = .{
                .tree_idx = tree_idx,
                .node_idx = form_idx,
                .form_span = form_span,
                // Every name from one source shares the source literal's
                // span: the name exists inside opaque content SJON cannot
                // address. Goto-definition lands on the blob that declares
                // it, which is the best answer available.
                .name_span = source_span,
                .scope = scope,
            };
        },
        .failure => |f| {
            const message = if (f.offset) |off| try std.fmt.allocPrint(
                tree_a,
                "provider `{s}` could not extract `{s}` names from this source (at byte {d}): {s}",
                .{ provider, canonical_target, off, f.message },
            ) else try std.fmt.allocPrint(
                tree_a,
                "provider `{s}` could not extract `{s}` names from this source: {s}",
                .{ provider, canonical_target, f.message },
            );
            // Empty path, the index pass's convention — its two existing
            // diagnostics (`duplicate_cross_ref_target`, `cyclic_cross_ref`)
            // both anchor on span alone, and the corpus pins that.
            try emit(tree_a, diags, source_span, &.{}, .err, .cross_ref_extraction_failed, message);
            try index.poison(index_a, scope, canonical_target);
        },
        .unavailable => |why| {
            try emitProviderUnavailable(tree_a, diags, source_span, canonical_target, provider, why);
            try index.poison(index_a, scope, canonical_target);
        },
    }
}

/// `cross_ref_provider_unavailable`, from either the table's own
/// `.unavailable` arm (which carries a reason) or an absent entry (which
/// does not). One helper so the two paths cannot drift in wording.
fn emitProviderUnavailable(
    tree_a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    span: Ast.Span,
    canonical_target: []const u8,
    provider: []const u8,
    why: ?[]const u8,
) Allocator.Error!void {
    const message = if (why) |w| try std.fmt.allocPrint(
        tree_a,
        "provider `{s}` was not run, so `{s}` names from this source are unchecked: {s}",
        .{ provider, canonical_target, w },
    ) else try std.fmt.allocPrint(
        tree_a,
        "provider `{s}` was not run, so `{s}` names from this source are unchecked",
        .{ provider, canonical_target },
    );
    try emit(tree_a, diags, span, &.{}, .err, .cross_ref_provider_unavailable, message);
}

/// Insert a cross-ref name into the 3-level `by_scope → target → name`
/// index, seeding empty sub-maps as needed. Returns the freshly-inserted
/// `Site` slot for the caller to fill, or null if the name is already
/// registered in this scope — in which case a `duplicate_cross_ref`
/// diagnostic has been emitted and the caller must stop. Shared by the tree
/// (`registerName`) and binary (`registerCrossRefBinary`) index builders.
fn registerSite(
    index_a: Allocator,
    tree_a: Allocator,
    index: *CrossRefIndex,
    scope: ScopeId,
    canonical_target: []const u8,
    name_text: []const u8,
    name_span: Ast.Span,
    diags: *std.ArrayList(Diagnostic),
) Allocator.Error!?*CrossRefIndex.Site {
    const scope_gop = try index.by_scope.getOrPut(index_a, scope);
    if (!scope_gop.found_existing) scope_gop.value_ptr.* = .empty;
    const target_gop = try scope_gop.value_ptr.getOrPut(index_a, canonical_target);
    if (!target_gop.found_existing) target_gop.value_ptr.* = .empty;
    const gop = try target_gop.value_ptr.getOrPut(index_a, name_text);
    if (gop.found_existing) {
        try emitDuplicateCrossRef(tree_a, diags, name_span, canonical_target, name_text);
        return null;
    }
    return gop.value_ptr;
}

fn registerName(
    index_a: Allocator,
    tree_a: Allocator,
    index: *CrossRefIndex,
    cycle_ctx: *CycleCtx,
    tree: *const Ast.Tree,
    tree_idx: u32,
    scope: ScopeId,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    canonical_target: []const u8,
    name_text: []const u8,
    name_span: Ast.Span,
    diags: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    const site = try registerSite(index_a, tree_a, index, scope, canonical_target, name_text, name_span, diags) orelse return;
    site.* = .{
        .tree_idx = tree_idx,
        .node_idx = form_idx,
        .form_span = tree.spanOf(form_idx),
        .name_span = name_span,
        .scope = scope,
    };

    if (cycle_ctx.specForCanonical(canonical_target)) |spec_idx| {
        try captureTreeEdges(
            index_a,
            cycle_ctx,
            spec_idx,
            scope,
            tree,
            tree_idx,
            hdr,
            name_text,
            name_span,
        );
    }
}

/// Walk a freshly-registered form's kvpairs, harvest outgoing
/// cross-ref edges declared by the spec, and append the resulting
/// node to `cycle_ctx.nodes_by_scope[spec_idx][scope]`. Symbol-typed
/// scalar edges and vectors-of-symbol edges are captured; mistyped
/// slots are silently skipped (the validator reports those as type
/// mismatches).
fn captureTreeEdges(
    index_a: Allocator,
    ctx: *CycleCtx,
    spec_idx: u32,
    scope: ScopeId,
    tree: *const Ast.Tree,
    tree_idx: u32,
    hdr: Ast.FormHeader,
    name_text: []const u8,
    name_span: Ast.Span,
) Allocator.Error!void {
    var edges: std.ArrayList([]const u8) = .empty;
    errdefer edges.deinit(index_a);

    for (hdr.children) |ch| {
        if (tree.tagOf(ch) != .kvpair) continue;
        const kv = tree.kvpairHeader(ch);
        const shape = ctx.edgeShape(spec_idx, kv.key) orelse continue;
        switch (shape) {
            .scalar => {
                if (tree.tagOf(kv.value) == .symbol) {
                    try edges.append(index_a, tree.symbolText(kv.value));
                }
            },
            .vector => {
                if (tree.tagOf(kv.value) == .vector) {
                    for (tree.vectorElements(kv.value)) |elem| {
                        if (tree.tagOf(elem) == .symbol) {
                            try edges.append(index_a, tree.symbolText(elem));
                        }
                    }
                }
            },
        }
    }

    try ctx.appendNode(
        index_a,
        spec_idx,
        scope,
        name_text,
        tree_idx,
        name_span,
        try edges.toOwnedSlice(index_a),
    );
}

/// Path-agnostic cycle detector. For each spec, run iterative DFS with
/// white/gray/black coloring on the captured graph; on every back-edge
/// to a gray ancestor, emit `cyclic_cross_ref` diagnostics on each
/// member of the discovered cycle. Edges into nodes outside the
/// registry are dropped (`not_cross_ref` already covers those at a
/// different layer).
fn runAcyclicCheck(
    gpa: Allocator,
    ctx: *CycleCtx,
    results: []Result,
    diags_lists: []std.ArrayList(Diagnostic),
) Allocator.Error!void {
    for (ctx.specs, 0..) |spec, spec_idx| {
        var it = ctx.nodes_by_scope[spec_idx].iterator();
        while (it.next()) |entry| {
            const nodes = entry.value_ptr.items;
            if (nodes.len == 0) continue;
            try runAcyclicSpec(gpa, spec, nodes, results, diags_lists);
        }
    }
}

fn runAcyclicSpec(
    gpa: Allocator,
    spec: Schema.AcyclicSpec,
    nodes: []const CycleCtx.Node,
    results: []Result,
    diags_lists: []std.ArrayList(Diagnostic),
) Allocator.Error!void {
    // The cycle walk itself is the shared `detectGraphCycles` core
    // (also fed by the lowering `:produces` graph). The only cross-ref-
    // specific work — rendering the cycle path and attaching one
    // diagnostic per cycle member to its originating tree — lives in the
    // `onCycle` callback below.
    const Emit = struct {
        gpa: Allocator,
        kind_name: []const u8,
        results: []Result,
        diags_lists: []std.ArrayList(Diagnostic),

        fn onCycle(
            self: @This(),
            ns: []const CycleCtx.Node,
            cycle: []const DfsFrame,
        ) Allocator.Error!void {
            try emitCyclicCrossRef(
                self.gpa,
                self.results,
                self.diags_lists,
                self.kind_name,
                ns,
                cycle,
            );
        }
    };

    try detectGraphCycles(CycleCtx.Node, gpa, nodes, Emit{
        .gpa = gpa,
        .kind_name = spec.kind_name,
        .results = results,
        .diags_lists = diags_lists,
    }, Emit.onCycle);
}

const COLOR_WHITE: u8 = 0;
const COLOR_GRAY: u8 = 1;
const COLOR_BLACK: u8 = 2;
pub const DfsFrame = struct { node_idx: u32, edge_idx: u32 };

/// Iterative 3-colour DFS cycle detector over a name→edges graph, shared
/// by the `:acyclic` cross-ref check and the lowering `:produces` graph.
/// `Node` must expose `name: []const u8` and `edges: []const []const u8`
/// (edge targets are matched against node names by string equality). On
/// every back edge to a gray ancestor, `onCycle(ctx, nodes, cycle)` is
/// invoked; `cycle` is the gray-ancestor frame slice and is transient —
/// it aliases the live DFS stack, so copy it if you need it past the
/// call. No host-stack recursion: descent rides the explicit `DfsFrame`
/// stack, matching the other frame-stack walkers in this module.
///
/// Public so `Schema.validateLowering` can reuse it for the `:produces`
/// lowering graph — same detector, different `Node`/`onCycle`.
pub fn detectGraphCycles(
    comptime Node: type,
    gpa: Allocator,
    nodes: []const Node,
    ctx: anytype,
    comptime onCycle: anytype,
) Allocator.Error!void {
    // Callers append nodes in a stable, document-derived order, so no
    // sort is needed. Linear name lookup (rather than a hashmap) keeps
    // the detector's binary footprint small — these graphs are a handful
    // of nodes in practice, below the size where a hashmap's constant
    // factor pays off.
    var color = try gpa.alloc(u8, nodes.len);
    defer gpa.free(color);
    @memset(color, COLOR_WHITE);

    var stack: std.ArrayList(DfsFrame) = .empty;
    defer stack.deinit(gpa);

    for (0..nodes.len) |start| {
        if (color[start] != COLOR_WHITE) continue;
        color[start] = COLOR_GRAY;
        try stack.append(gpa, .{ .node_idx = @intCast(start), .edge_idx = 0 });

        while (stack.items.len > 0) {
            const top = stack.items.len - 1;
            const frame = &stack.items[top];
            const node = nodes[frame.node_idx];

            if (frame.edge_idx >= node.edges.len) {
                color[frame.node_idx] = COLOR_BLACK;
                _ = stack.pop();
                continue;
            }

            const edge_target = node.edges[frame.edge_idx];
            frame.edge_idx += 1;

            const target_idx = lookupGraphNodeIdx(Node, nodes, edge_target) orelse continue;
            const tc = color[target_idx];
            if (tc == COLOR_BLACK) continue;
            if (tc == COLOR_GRAY) {
                var start_idx: usize = stack.items.len;
                for (stack.items, 0..) |sf, i| {
                    if (sf.node_idx == target_idx) {
                        start_idx = i;
                        break;
                    }
                }
                if (start_idx < stack.items.len) {
                    try onCycle(ctx, nodes, stack.items[start_idx..]);
                }
                continue;
            }
            color[target_idx] = COLOR_GRAY;
            try stack.append(gpa, .{ .node_idx = target_idx, .edge_idx = 0 });
        }
    }
}

fn lookupGraphNodeIdx(comptime Node: type, nodes: []const Node, name: []const u8) ?u32 {
    for (nodes, 0..) |n, i| {
        if (std.mem.eql(u8, n.name, name)) return @intCast(i);
    }
    return null;
}

/// Emit one diagnostic per cycle member, attached to the right tree's
/// diag list. The cycle path is rendered once on `gpa` (transient) and
/// duplicated into each tree's arena via `allocPrint`.
///
/// Cannot funnel through `emit()`: that helper takes a single `(a, diags)`
/// pair, but a cross-tree cycle fans each member out to its OWN tree's
/// arena and diagnostics list (`diags_lists[node.tree_idx]`), so the append
/// is inlined per member here.
fn emitCyclicCrossRef(
    gpa: Allocator,
    results: []Result,
    diags_lists: []std.ArrayList(Diagnostic),
    kind_name: []const u8,
    nodes: []const CycleCtx.Node,
    cycle: []const DfsFrame,
) Allocator.Error!void {
    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);
    for (cycle, 0..) |sf, i| {
        if (i > 0) try path_buf.appendSlice(gpa, " -> ");
        try path_buf.appendSlice(gpa, nodes[sf.node_idx].name);
    }
    try path_buf.appendSlice(gpa, " -> ");
    try path_buf.appendSlice(gpa, nodes[cycle[0].node_idx].name);

    for (cycle) |sf| {
        const node = nodes[sf.node_idx];
        const tree_a = results[node.tree_idx].arena.allocator();
        const message = try std.fmt.allocPrint(
            tree_a,
            "cyclic reference through `{s}` cross-ref: `{s}`",
            .{ kind_name, path_buf.items },
        );
        try diags_lists[node.tree_idx].append(tree_a, .{
            .span = node.name_span,
            .message = message,
            .severity = .err,
            .code = .cyclic_cross_ref,
            .path = &.{},
        });
    }
}

fn emitDuplicateCrossRef(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    span: Ast.Span,
    target: []const u8,
    name: []const u8,
) Allocator.Error!void {
    const message = try std.fmt.allocPrint(
        a,
        "duplicate cross-ref name `{s}` on form `{s}`",
        .{ name, target },
    );
    // Path stays empty — the index pass walks outside the path-tracking
    // machinery, so editors land on the span instead. Funnel through the
    // shared `emit()` (single diags/arena); `clonePath` short-circuits the
    // empty path, so the appended diagnostic is byte-for-byte the same.
    try emit(a, diags, span, &.{}, .err, .duplicate_cross_ref_target, message);
}

/// Iterative descent frame for the binary index pass. Mirrors the tree
/// path's stack-of-NodeIndex but holds live cursor iterators (cursor is
/// monotonic — we cannot revisit, so each frame must remember where it
/// is mid-iteration).
const IndexFrame = union(enum) {
    form_iter: FormIndexFrame,
    vector_iter: VectorIndexFrame,
};

const FormIndexFrame = struct {
    head: []const u8,
    /// Canonical `<plugin>/<form>` name for this form, resolved via
    /// `Schema.lookupForm` when the frame was pushed. Non-null only when
    /// the head resolves cleanly (single matching plugin) AND that
    /// canonical name is a cross-ref target. Used as the registry outer
    /// key when registering at iter exhaustion. Null frames descend
    /// without registering.
    canonical_target: ?[]const u8,
    /// `name_key` non-null when this form is an *identity-route*
    /// registration target. Exactly one of `name_key` / `provider` is
    /// non-null whenever `canonical_target` is — the routes are exclusive
    /// and the loader enforces it.
    name_key: ?[]const u8,
    /// Provider route: canonical `<plugin>/<provider>` whose extractor
    /// supplies this form's names.
    provider: ?[]const u8 = null,
    /// Provider route: the key whose *string* value is handed to the
    /// extractor. Non-null exactly when `provider` is.
    source_key: ?[]const u8 = null,
    form_span: Ast.Span,
    iter: BinaryCursor.ChildIter,
    /// Captured during iteration when the matching `:name-key` kvpair is
    /// found and its value is symbol-typed. Registered at iter exhaustion.
    captured_name: ?[]const u8 = null,
    captured_span: Ast.Span = ZERO_SPAN,
    /// True after the first `name_key`-matching kvpair is consumed —
    /// subsequent matches are ignored (mirrors Tree path's first-wins on
    /// duplicate `:name` kvpairs).
    saw_name_kvpair: bool = false,
    /// Provider route's counterpart to `captured_name`: the source string
    /// handed to the extractor, captured mid-iteration because the cursor
    /// is monotonic — by the time the frame is exhausted the bytes are
    /// already behind us. Same first-wins tolerance via
    /// `saw_source_kvpair`.
    captured_source: ?[]const u8 = null,
    captured_source_span: Ast.Span = ZERO_SPAN,
    saw_source_kvpair: bool = false,
    /// Non-null when this form's canonical name matches a `CycleCtx` spec
    /// (i.e., is a target of an `:acyclic true` cross-ref). Symbol values
    /// on declared edge keys are appended to `captured_edges`.
    acyclic_spec_idx: ?u32 = null,
    /// Scope this form's registration lives under. Set at frame push,
    /// resolved against the cross-ref spec's `:scope` (if any) using
    /// the active scope stack — for tree-scoped specs (the default)
    /// this is just the buffer's `tree_scope`.
    scope: ScopeId,
    /// True when this form opened a new lexical scope (its canonical
    /// name is in `scope_heads`); the binary-path index-build loop pops
    /// the parallel `scope_stack` when the frame is exhausted.
    opened_scope: bool = false,
    /// Outgoing edges harvested during iteration. Backing storage on
    /// `index_a` — handed to `cycle_ctx` on register.
    captured_edges: std.ArrayList([]const u8) = .empty,
};

/// Vector-iter wrapper. `edge_capture` is set when the vector lives
/// inside an edge-key kvpair on an enclosing acyclic-target form;
/// symbol elements are forwarded to that parent's `captured_edges`.
const VectorIndexFrame = struct {
    iter: BinaryCursor.VectorIter,
    edge_capture: ?EdgeCapture = null,

    const EdgeCapture = struct {
        /// Stable index of the parent `form_iter` frame. The frames
        /// stack only mutates at the top, so once a child is pushed
        /// above its parent, the parent's index is fixed for the
        /// child's lifetime.
        parent_form_idx: u32,
    };
};

/// Build the forest-wide cross-ref registry from binary buffers. Mirrors
/// `buildCrossRefIndexForest`'s semantics — descendant DFS, first-by-
/// `(buffer_idx, document-order)` wins, lexical tolerance on missing or
/// non-symbol `:name-key` values — but reads bytes through `BinaryCursor`
/// instead of an `Ast.Tree`. Cursor positions are monotonic, so iterators
/// live on the frame stack.
///
/// Spans are derived from the binary's `with_spans` flag when set; absent
/// when the binary was encoded without spans (`name_span` and `form_span`
/// fall back to zero, which is fine — editors consuming the binary path
/// are expected to keep the source `Tree` for goto-def landing anyway).
fn buildCrossRefIndexBinary(
    index_a: Allocator,
    gpa: Allocator,
    schema: Schema.Schema,
    binaries: []const []const u8,
    results: []Result,
    diags_lists: []std.ArrayList(Diagnostic),
    budget: Budget,
    extractions: ?*const ExtractionMap,
) Error!CrossRefIndex {
    var targets = try collectCrossRefTargets(index_a, schema);
    defer targets.deinit(index_a);
    var scope_heads = try collectScopeHeads(index_a, &targets);
    defer scope_heads.deinit(index_a);

    var cycle_ctx = try CycleCtx.init(gpa, index_a, schema);
    defer cycle_ctx.deinit(gpa);

    var index: CrossRefIndex = .{ .arena = index_a };
    if (targets.count() == 0 and cycle_ctx.isEmpty()) return index;

    var frames: std.ArrayList(IndexFrame) = .empty;
    defer frames.deinit(gpa);
    var canon_buf: std.ArrayList(u8) = .empty;
    defer canon_buf.deinit(gpa);
    var scope_stack: std.ArrayList(ScopeFrame) = .empty;
    defer scope_stack.deinit(gpa);

    for (binaries, 0..) |bytes, b| {
        const t_idx: u32 = @intCast(b);
        const tree_scope: ScopeId = .tree(t_idx);
        const tree_a = results[b].arena.allocator();
        var cursor = try BinaryCursor.Cursor.init(bytes);
        var root_iter = try cursor.rootIter();
        scope_stack.clearRetainingCapacity();

        while (try root_iter.next()) |root_view| {
            try dispatchIndexValue(gpa, &canon_buf, schema, &cursor, root_view, &targets, &scope_heads, &cycle_ctx, &frames, &scope_stack, t_idx, tree_scope);

            var step: u32 = 0;
            while (frames.items.len > 0) {
                if (step >= budget.steps) return error.DepthExceeded;
                if (frames.items.len > budget.frames) return error.DepthExceeded;
                step += 1;

                const top = frames.items.len - 1;
                switch (frames.items[top]) {
                    .form_iter => {
                        const fi = &frames.items[top].form_iter;
                        if (fi.iter.remaining == 0) {
                            // Drain trailing comments. Then register the
                            // captured name (if any) on the way out.
                            _ = try fi.iter.next();
                            if (fi.canonical_target) |canon| {
                                if (fi.provider) |pv| {
                                    // Provider route. A frame with no
                                    // captured source is an instance
                                    // discovery never requested either, so
                                    // it stays silent — same tolerance the
                                    // identity route gives a missing
                                    // `:name-key`.
                                    if (fi.captured_source) |src| try registerExtractedNames(
                                        index_a,
                                        tree_a,
                                        &index,
                                        t_idx,
                                        fi.scope,
                                        .invalid,
                                        fi.form_span,
                                        canon,
                                        pv,
                                        src,
                                        fi.captured_source_span,
                                        &diags_lists[b],
                                        extractions,
                                    );
                                } else if (fi.captured_name) |nt| {
                                    try registerCrossRefBinary(
                                        index_a,
                                        tree_a,
                                        &index,
                                        &cycle_ctx,
                                        fi.acyclic_spec_idx,
                                        canon,
                                        nt,
                                        fi.captured_span,
                                        fi.form_span,
                                        t_idx,
                                        fi.scope,
                                        fi.captured_edges.items,
                                        &diags_lists[b],
                                    );
                                }
                            }
                            if (fi.opened_scope) _ = scope_stack.pop();
                            _ = frames.pop();
                            continue;
                        }

                        const entry = (try fi.iter.next()) orelse unreachable;
                        const matches_name = fi.name_key != null and
                            !fi.saw_name_kvpair and
                            entry.kind == .keyword and
                            std.mem.eql(u8, entry.key.?, fi.name_key.?);
                        const matches_source = fi.source_key != null and
                            !fi.saw_source_kvpair and
                            entry.kind == .keyword and
                            std.mem.eql(u8, entry.key.?, fi.source_key.?);

                        if (matches_source) {
                            fi.saw_source_kvpair = true;
                            if (entry.value.kind == .string) {
                                fi.captured_source = try BinaryCursor.readString(&cursor, entry.value);
                                fi.captured_source_span = entry.value.span orelse ZERO_SPAN;
                                continue;
                            }
                            // Non-string `:source-key` value: silent skip,
                            // but fall through so the cursor is consumed and
                            // any forms nested inside it still get indexed.
                        }

                        if (matches_name) {
                            fi.saw_name_kvpair = true;
                            if (entry.value.kind == .symbol) {
                                fi.captured_name = try BinaryCursor.readSymbol(&cursor, entry.value);
                                fi.captured_span = entry.value.span orelse ZERO_SPAN;
                                continue;
                            }
                            // Non-symbol :name-key value: silent skip but
                            // still consume the cursor (and recurse — a
                            // form value contains forms we should index).
                        }

                        if (fi.acyclic_spec_idx) |spec_idx| {
                            if (entry.kind == .keyword) {
                                if (cycle_ctx.edgeShape(spec_idx, entry.key.?)) |shape| {
                                    if (try captureBinaryEdge(
                                        index_a,
                                        gpa,
                                        &cursor,
                                        shape,
                                        entry.value,
                                        fi,
                                        @intCast(top),
                                        &frames,
                                    )) continue;
                                }
                            }
                        }

                        // `dispatchIndexValue` may push a new frame and
                        // realloc `frames.items`, invalidating `fi`. We've
                        // already finished mutating fi above.
                        try dispatchIndexValue(gpa, &canon_buf, schema, &cursor, entry.value, &targets, &scope_heads, &cycle_ctx, &frames, &scope_stack, t_idx, tree_scope);
                    },
                    .vector_iter => {
                        const vi = &frames.items[top].vector_iter;
                        if (vi.iter.remaining == 0) {
                            // Drain the vector's trailing comments (wire v5+)
                            // before popping, or the cursor desyncs on the
                            // next indexed sibling under a comment preset.
                            _ = try vi.iter.next();
                            _ = frames.pop();
                            continue;
                        }
                        const ev = (try vi.iter.next()) orelse unreachable;
                        if (vi.edge_capture) |ec| {
                            if (ev.kind == .symbol) {
                                const sym = try BinaryCursor.readSymbol(&cursor, ev);
                                const fp = &frames.items[ec.parent_form_idx].form_iter;
                                try fp.captured_edges.append(index_a, sym);
                                continue;
                            }
                            // Non-symbol element in an edge vector: dispatch
                            // normally so nested forms still get indexed;
                            // the validator emits the type error elsewhere.
                        }
                        try dispatchIndexValue(gpa, &canon_buf, schema, &cursor, ev, &targets, &scope_heads, &cycle_ctx, &frames, &scope_stack, t_idx, tree_scope);
                    },
                }
            }
        }
    }

    if (!cycle_ctx.isEmpty()) {
        try runAcyclicCheck(gpa, &cycle_ctx, results, diags_lists);
    }

    return index;
}

test "budget: the cross-index walk trips its own step and frame ceilings" {
    // Driven here rather than from `Validator_tests.zig` because the trip
    // has to be *attributable*. This pass runs ahead of the per-buffer walk,
    // so any budget small enough to trip it also trips the walk downstream —
    // a test through `validateBinaryWithBudget` still sees `DepthExceeded`
    // with these guards reverted to the constants, which is what makes that
    // version of the test worthless. Calling the pass directly is the only
    // way to know which loop answered.
    const testing = std.testing;
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    const gpa = testing.allocator;

    // The pass short-circuits unless the schema declares a cross-ref target,
    // so a core-only schema would never enter the loop at all.
    const plugin: Plugin.Plugin = .{
        .name = "demo",
        .value_kinds = &.{.{ .name = "phrase-name", .underlying = .symbol, .cross_ref = .{ .target_form = "phrase" } }},
        .forms = &.{
            .{ .name = "phrase", .keys = &.{.{ .name = "name", .value_type = .symbol }} },
            .{ .name = "ref", .keys = &.{.{ .name = "k", .value_type = .{ .named = .{ .name = "phrase-name" } } }} },
        },
    };
    const schema = Schema.Schema.init(&.{plugin});

    // Nested on purpose: the frame guard is `len > budget.frames`, so a flat
    // `(ref :k p0)` peaks at one live frame and a cap of 1 would never trip.
    // The inner form pushes a second iterator.
    var tree = try Parser.parse(gpa, "(phrase :name p0)\n(group (ref :k p0))");
    defer tree.deinit();
    const bin = try Binary.toBinary(gpa, tree, .{});
    defer bin.deinit();
    var binaries = [_][]const u8{bin.data};

    // `results` / `diags_lists` are the shapes `validateForestBinary` hands
    // in: diagnostics are appended through each Result's own arena, so the
    // Result owns them and the list header itself needs no separate free.
    const Case = struct {
        fn run(g: Allocator, sc: Schema.Schema, bins: [][]const u8, budget: Budget) Error!void {
            var results = [_]Result{.{ .arena = std.heap.ArenaAllocator.init(g), .diagnostics = &.{} }};
            defer results[0].deinit();
            var diags_lists = [_]std.ArrayList(Diagnostic){.empty};
            var index_arena = std.heap.ArenaAllocator.init(g);
            defer index_arena.deinit();
            _ = try buildCrossRefIndexBinary(index_arena.allocator(), g, sc, bins, &results, &diags_lists, budget, null);
        }
    };

    try testing.expectError(error.DepthExceeded, Case.run(gpa, schema, &binaries, .{ .steps = 1 }));
    try testing.expectError(error.DepthExceeded, Case.run(gpa, schema, &binaries, .{ .frames = 1 }));

    // Control: the same buffer through the same pass at the production
    // ceilings, so the trips above are the budget and not the document.
    try Case.run(gpa, schema, &binaries, .{});
}

/// Try to capture an outgoing edge for the form at `parent_form_idx`.
/// Returns true when the entry was consumed by the capture path (the
/// caller skips its own dispatch); false when the kvpair value's shape
/// didn't match — the caller falls through to `dispatchIndexValue` so
/// nested forms still descend and the validator emits any type errors.
fn captureBinaryEdge(
    index_a: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    shape: Schema.EdgeShape,
    value: BinaryCursor.NodeView,
    parent_fi: *FormIndexFrame,
    parent_form_idx: u32,
    frames: *std.ArrayList(IndexFrame),
) Error!bool {
    switch (shape) {
        .scalar => {
            if (value.kind == .symbol) {
                const sym = try BinaryCursor.readSymbol(cursor, value);
                try parent_fi.captured_edges.append(index_a, sym);
                return true;
            }
            return false;
        },
        .vector => {
            if (value.kind == .vector) {
                const it = try BinaryCursor.readVector(cursor, value);
                try frames.append(gpa, .{ .vector_iter = .{
                    .iter = it,
                    .edge_capture = .{ .parent_form_idx = parent_form_idx },
                } });
                return true;
            }
            return false;
        },
    }
}

/// Dispatch on a freshly-read `NodeView`: forms and vectors get a frame
/// pushed (caller continues the iterative loop), leaves consume their
/// payload via `skipBody` and advance the cursor.
///
/// For form views, the head is canonicalised via `Schema.lookupForm` and
/// matched against the registry's canonical targets. The form frame
/// stores the canonical name (borrowed from `targets`'s index-arena
/// key, which outlives the frame) so registration can use it without
/// recomputing.
fn dispatchIndexValue(
    gpa: Allocator,
    canon_buf: *std.ArrayList(u8),
    schema: Schema.Schema,
    cursor: *BinaryCursor.Cursor,
    view: BinaryCursor.NodeView,
    targets: *const std.StringHashMapUnmanaged(CrossRefSpec),
    scope_heads: *const std.StringHashMapUnmanaged(void),
    cycle_ctx: *const CycleCtx,
    frames: *std.ArrayList(IndexFrame),
    scope_stack: *std.ArrayList(ScopeFrame),
    tree_idx: u32,
    tree_scope: ScopeId,
) Error!void {
    switch (view.kind) {
        .form => {
            const fv = try BinaryCursor.readForm(cursor, view);
            const form_pos: u32 = @intCast(cursor.pos);
            const canon_slice = try canonicalFormNameBuf(gpa, canon_buf, schema, fv.head, fv.namespace);
            var canonical_target: ?[]const u8 = null;
            var name_key: ?[]const u8 = null;
            var provider: ?[]const u8 = null;
            var source_key: ?[]const u8 = null;
            var spec_idx: ?u32 = null;
            var reg_scope: ScopeId = tree_scope;
            var opened_scope: bool = false;
            if (canon_slice) |c| {
                if (targets.getEntry(c)) |entry| {
                    // `entry.key_ptr.*` is the index-arena-owned canonical
                    // key, valid for the lifetime of this index pass.
                    canonical_target = entry.key_ptr.*;
                    const spec = entry.value_ptr.*;
                    // The routes are exclusive, and `name_key` keeps its
                    // default spelling on a provider-route spec — so
                    // leaving it set here would have this frame register
                    // an identity name *and* an extracted set.
                    if (spec.provider) |pv| {
                        provider = pv;
                        source_key = spec.source_key;
                    } else {
                        name_key = spec.name_key;
                    }
                    reg_scope = if (spec.scope_form) |sf|
                        findNearestScope(scope_stack.items, sf) orelse tree_scope
                    else
                        tree_scope;
                }
                spec_idx = cycle_ctx.specForCanonical(c);
                if (scope_heads.getEntry(c)) |sh_entry| {
                    try scope_stack.append(gpa, .{
                        .canonical = sh_entry.key_ptr.*,
                        .scope_id = .lexical(tree_idx, form_pos),
                    });
                    opened_scope = true;
                }
            }
            try frames.append(gpa, .{ .form_iter = .{
                .head = fv.head,
                .canonical_target = canonical_target,
                .name_key = name_key,
                .provider = provider,
                .source_key = source_key,
                .form_span = view.span orelse ZERO_SPAN,
                .iter = fv.children,
                .acyclic_spec_idx = spec_idx,
                .scope = reg_scope,
                .opened_scope = opened_scope,
            } });
        },
        .vector => {
            const it = try BinaryCursor.readVector(cursor, view);
            try frames.append(gpa, .{ .vector_iter = .{ .iter = it } });
        },
        else => try BinaryCursor.skipBody(cursor, view),
    }
}

fn registerCrossRefBinary(
    index_a: Allocator,
    tree_a: Allocator,
    index: *CrossRefIndex,
    cycle_ctx: *CycleCtx,
    spec_idx: ?u32,
    canonical_target: []const u8,
    name_text: []const u8,
    name_span: Ast.Span,
    form_span: Ast.Span,
    tree_idx: u32,
    scope: ScopeId,
    captured_edges: []const []const u8,
    diags: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    const site = try registerSite(index_a, tree_a, index, scope, canonical_target, name_text, name_span, diags) orelse return;
    site.* = .{
        .tree_idx = tree_idx,
        // Binary path has no `Ast.NodeIndex` analog. The validator's
        // hot path uses only `contains`; node_idx is for LSP follow-on
        // features that already keep the source Tree alongside.
        .node_idx = .invalid,
        .form_span = form_span,
        .name_span = name_span,
        .scope = scope,
    };
    if (spec_idx) |idx| {
        try cycle_ctx.appendNode(
            index_a,
            idx,
            scope,
            name_text,
            tree_idx,
            name_span,
            captured_edges,
        );
    }
}

/// Walk a `Tree`, validate every form / expression head, and collect
/// diagnostics. Always succeeds unless allocation fails.
///
/// Single-tree wrapper over `validateForest`: bundles the tree into a
/// one-element forest, runs the forest pass, peels off the single
/// `Result` and drops the (empty) cross-ref index.
pub fn validate(
    gpa: Allocator,
    tree: Ast.Tree,
    schema: Schema.Schema,
) Allocator.Error!Result {
    return validateWithOptions(gpa, tree, schema, .{});
}

/// `validate` with caller-supplied effective-axes options. `Options{}`
/// is byte-equivalent to `validate`.
pub fn validateWithOptions(
    gpa: Allocator,
    tree: Ast.Tree,
    schema: Schema.Schema,
    options: Options,
) Allocator.Error!Result {
    var trees: [1]Ast.Tree = .{tree};
    var fr = try validateForestWithOptions(gpa, &trees, schema, options);
    return fr.intoSingle(gpa);
}

/// Validate a forest of trees against `schema`. Builds one cross-ref
/// registry spanning all trees and runs the per-tree validation walk
/// threading the shared registry, so document-spanning references (e.g.
/// a `(track …)` in one file referencing `(phrase :name p0 …)` in
/// another) resolve cleanly.
///
/// Each input tree gets its own `Result` (own arena, own diagnostics)
/// in input order. The forest-wide `CrossRefIndex` is owned by its own
/// arena on `ForestResult` so callers like the LSP can hold per-document
/// `Result`s and replace the index across revalidations independently.
pub fn validateForest(
    gpa: Allocator,
    trees: []const Ast.Tree,
    schema: Schema.Schema,
) Allocator.Error!ForestResult {
    return validateForestWithOptions(gpa, trees, schema, .{});
}

/// `validateForest` with caller-supplied effective-axes options.
pub fn validateForestWithOptions(
    gpa: Allocator,
    trees: []const Ast.Tree,
    schema: Schema.Schema,
    options: Options,
) Allocator.Error!ForestResult {
    if (options.overlays) |ovs| std.debug.assert(ovs.len == trees.len);

    var index_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer index_arena.deinit();

    // Per-tree Results, with arenas initialized eagerly so the index
    // pass can allocate duplicate-diagnostic strings on the right tree's
    // arena even before its walk runs.
    var results = try gpa.alloc(Result, trees.len);
    errdefer gpa.free(results);

    var inited: usize = 0;
    errdefer for (results[0..inited]) |*r| r.arena.deinit();
    for (0..trees.len) |i| {
        results[i] = .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .diagnostics = &.{},
        };
        inited = i + 1;
    }

    // Per-tree growable diag lists. The list metadata lives on `gpa`
    // (transient); the diagnostic strings allocate on each tree's arena.
    var diags_lists = try gpa.alloc(std.ArrayList(Diagnostic), trees.len);
    defer gpa.free(diags_lists);
    for (0..trees.len) |i| diags_lists[i] = .empty;

    // 1. Build the cross-ref index across the whole forest. Duplicate
    //    diagnostics emitted here attach to the duplicate's tree.
    var index = try buildCrossRefIndexForest(
        index_arena.allocator(),
        gpa,
        schema,
        trees,
        results,
        diags_lists,
        options,
    );

    // Precompute the set of canonical scope-opening form names so the
    // per-tree validation loop can skip a per-form schema scan.
    var scope_heads_validation = try schemaScopeHeads(gpa, schema);
    defer freeSchemaScopeHeads(gpa, &scope_heads_validation);

    // 2. Run the per-tree validation walk threading the shared index.
    for (trees, 0..) |*tree, i| {
        const tree_scope: ScopeId = if (options.share_scope) .tree(0) else .tree(@intCast(i));
        try validateOneTree(
            results[i].arena.allocator(),
            gpa,
            schema,
            &index,
            tree,
            tree_scope,
            &scope_heads_validation,
            &diags_lists[i],
            perTreeOptions(options, i),
        );
    }

    // 3. Hand each tree's diagnostic list off to its Result. The list's
    //    backing buffer lives on the tree arena; trimming via toOwnedSlice
    //    is unnecessary because arena.deinit frees both used+unused at once.
    for (0..trees.len) |i| {
        results[i].diagnostics = diags_lists[i].items;
    }

    return .{
        .results = results,
        .cross_ref_index = index,
        .index_arena = index_arena,
    };
}

/// Single-tree walk extracted from the M1 `validate` body. Caller
/// supplies the tree's arena allocator (where paths and diagnostic
/// strings land) and the forest's shared `CrossRefIndex`. `tree_scope`
/// is the default scope that bounds cross-ref resolution for this tree
/// (`.tree(tree_idx)`); a parallel scope chain is built per-frame for
/// `:scope <form>` cross-refs, and `cross_ref_outside_scope` fires when
/// a reference appears outside any matching enclosing form.
fn validateOneTree(
    a: Allocator,
    gpa: Allocator,
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree: *const Ast.Tree,
    tree_scope: ScopeId,
    scope_heads: *const std.StringHashMapUnmanaged(void),
    diags: *std.ArrayList(Diagnostic),
    options: Options,
) Allocator.Error!void {
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    var canon_buf: std.ArrayList(u8) = .empty;
    defer canon_buf.deinit(gpa);

    // Push roots in reverse order so traversal proceeds left-to-right.
    // Each root's path begins with its head (or empty for non-form roots,
    // which the validator skips anyway).
    var i: usize = tree.root.len;
    while (i > 0) : (i -= 1) {
        const idx = tree.root[i - 1];
        const path = try initialPath(a, tree, idx);
        try stack.append(gpa, .{ .idx = idx, .path = path, .scope_chain = &.{} });
    }

    outer: while (stack.pop()) |frame| {
        switch (tree.tagOf(frame.idx)) {
            .form => {
                const hdr = tree.formHeader(frame.idx);
                // Slot-local resolution: when this form value sits in a slot
                // that declares local forms, its head resolves local-first
                // (bare heads only — a qualified `ns/foo` bypasses locals).
                // Computed once and reused for both head validation and the
                // children's `parent_form_spec`.
                const local_hit: ?*const Plugin.FormSpec = blk: {
                    const reg = frame.local_form_registry orelse break :blk null;
                    if (hdr.namespace != null) break :blk null;
                    break :blk matchLocalForm(reg, hdr.head);
                };
                try validateFormHead(a, diags, schema, cross_index, tree_scope, frame.scope_chain, tree, frame.idx, frame.path, options, frame.local_form_registry, frame.local_form_slot_path, local_hit);
                // If this form is a scope-opener, build an extended chain
                // for its descendants. Non-openers reuse the parent's chain.
                var child_chain = frame.scope_chain;
                if (scope_heads.count() > 0) {
                    if (try canonicalFormNameBuf(gpa, &canon_buf, schema, hdr.head, hdr.namespace)) |canon| {
                        if (scope_heads.getEntry(canon)) |sh_entry| {
                            const tree_idx = tree_scope.treeIdx();
                            const new_chain = try a.alloc(ScopeFrame, frame.scope_chain.len + 1);
                            @memcpy(new_chain[0..frame.scope_chain.len], frame.scope_chain);
                            new_chain[frame.scope_chain.len] = .{
                                .canonical = sh_entry.key_ptr.*,
                                .scope_id = .lexical(tree_idx, @intFromEnum(frame.idx)),
                            };
                            child_chain = new_chain;
                        }
                    }
                }
                // Resolve the form's own spec so kvpair children can consult
                // `walk_opaque` / `local_forms` on their matching KeySpec. A
                // slot-local hit shadows the global catalog (additive
                // layering); otherwise fall back to the global lookup.
                const child_spec: ?*const Plugin.FormSpec = if (local_hit) |lf|
                    lf
                else switch (schema.lookupForm(hdr.head, hdr.namespace)) {
                    .found => |hit| hit.form,
                    else => null,
                };
                // Push children in reverse order with extended paths.
                var j: usize = hdr.children.len;
                while (j > 0) : (j -= 1) {
                    const ch = hdr.children[j - 1];
                    const step = try childStep(a, tree, ch, hdr.children, j - 1);
                    const child_path = try extendPath(a, frame.path, step);
                    // Positional slot-local resolution: a form-shaped POSITIONAL
                    // child resolves its head local-first against this form's
                    // `FormSpec.local_forms` — the positional mirror of the keyed
                    // carrier handled in the `.kvpair` arm below. Only a form
                    // child carries a head to resolve; a kvpair child is `.kvpair`
                    // (its own arm attaches any key-local registry to the value),
                    // so gating on the `.form` tag is what keeps the two carriers
                    // from colliding. The registry + slot path (this form's own
                    // path) ride onto the child frame; all downstream resolution
                    // (local-first hit, `validateFormHead` step 0, shadowing,
                    // additive fallback, qualified bypass) already keys off the
                    // frame fields.
                    const pos_local: ?[]const Plugin.FormSpec = if (tree.tagOf(ch) == .form) blk: {
                        const spec = child_spec orelse break :blk null;
                        if (spec.local_forms.len == 0) break :blk null;
                        break :blk spec.local_forms;
                    } else null;
                    try stack.append(gpa, .{
                        .idx = ch,
                        .path = child_path,
                        .scope_chain = child_chain,
                        .parent_form_spec = child_spec,
                        .local_form_registry = pos_local,
                        .local_form_slot_path = if (pos_local != null) frame.path else &.{},
                    });
                }
            },
            .vector => {
                const elements = tree.vectorElements(frame.idx);
                var j: usize = elements.len;
                while (j > 0) : (j -= 1) {
                    const elem = elements[j - 1];
                    const step = try indexStep(a, j - 1);
                    const child_path = try extendPath(a, frame.path, step);
                    try stack.append(gpa, .{ .idx = elem, .path = child_path, .scope_chain = frame.scope_chain });
                }
            },
            .kvpair => {
                // The kvpair's value generally inherits the kvpair's path —
                // they're "at the same key". The exception is form values:
                // descending into them adds the form's head as a step, so
                // diagnostics emitted from inside the form report a path
                // that matches the structural descent (e.g.
                // `[canvas, shape, triangle]` rather than `[canvas, shape]`
                // for a triangle nested under :shape).
                const kvh = tree.kvpairHeader(frame.idx);
                // Resolve the parent form's matching KeySpec (common keys
                // first, then any variant's keys) to honour two slot-level
                // opt-ins:
                //   * `walk_opaque` — skip descent entirely. The slot-level
                //     type-check via `matchValueAgainstType` still runs
                //     through `validateFormKeys`; this only suppresses the
                //     per-node walk that would otherwise emit `unknown_form`
                //     for expression-shaped contents the surrounding schema
                //     does not need to know about.
                //   * `local_forms` — the value form resolves its head
                //     local-first. The registry + slot path ride onto the
                //     pushed value frame (see `validateFormHead`). Mutually
                //     exclusive with `walk_opaque` (opaque = not descended).
                var local_registry: ?[]const Plugin.FormSpec = null;
                if (frame.parent_form_spec) |spec| {
                    const matched: ?Plugin.KeySpec = blk: {
                        for (spec.keys) |k| {
                            if (std.mem.eql(u8, k.name, kvh.key)) break :blk k;
                        }
                        if (spec.variants) |variants| {
                            for (variants) |v| {
                                for (v.keys) |k| {
                                    if (std.mem.eql(u8, k.name, kvh.key)) break :blk k;
                                }
                            }
                        }
                        break :blk null;
                    };
                    if (matched) |k| {
                        if (k.walk_opaque) continue :outer;
                        if (k.local_forms.len > 0 and tree.tagOf(kvh.value) == .form) {
                            local_registry = k.local_forms;
                        }
                    }
                }
                var child_path = frame.path;
                if (tree.tagOf(kvh.value) == .form) {
                    const v_hdr = tree.formHeader(kvh.value);
                    if (v_hdr.head.len > 0) {
                        const step = try a.dupe(u8, v_hdr.head);
                        child_path = try extendPath(a, frame.path, step);
                    }
                }
                try stack.append(gpa, .{
                    .idx = kvh.value,
                    .path = child_path,
                    .scope_chain = frame.scope_chain,
                    // The slot path is the kvpair's own path (`[canvas shape]`),
                    // before the value's head was appended above — that's where
                    // `unknown_local_form` should point.
                    .local_form_registry = local_registry,
                    .local_form_slot_path = if (local_registry != null) frame.path else &.{},
                });
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------

/// Path for a top-level node: a one-step path naming the node, or
/// empty for non-form roots (the validator never emits on them).
fn initialPath(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) Allocator.Error![]const []const u8 {
    if (tree.tagOf(idx) != .form) return &.{};
    const hdr = tree.formHeader(idx);
    if (hdr.head.len == 0) return &.{};
    const head_dup = try a.dupe(u8, hdr.head);
    const out = try a.alloc([]const u8, 1);
    out[0] = head_dup;
    return out;
}

/// Step contributed by a child of a form: the kvpair key, the form
/// head, or the positional index when no head is available (e.g. the
/// child is an atom rather than a form).
fn childStep(
    a: Allocator,
    tree: *const Ast.Tree,
    child: Ast.NodeIndex,
    siblings: []const Ast.NodeIndex,
    sibling_idx: usize,
) Allocator.Error![]const u8 {
    return switch (tree.tagOf(child)) {
        .kvpair => try a.dupe(u8, tree.kvpairHeader(child).key),
        .form => sub: {
            const ch_hdr = tree.formHeader(child);
            if (ch_hdr.head.len > 0) break :sub try a.dupe(u8, ch_hdr.head);
            break :sub try indexStep(a, positionalIndex(tree, siblings, sibling_idx));
        },
        else => try indexStep(a, positionalIndex(tree, siblings, sibling_idx)),
    };
}

/// Number of preceding positional (non-kvpair) siblings. The path
/// step for a positional child is its positional ordinal, not its
/// raw child index — kvpairs are skipped because they're represented
/// by their key.
fn positionalIndex(
    tree: *const Ast.Tree,
    siblings: []const Ast.NodeIndex,
    sibling_idx: usize,
) usize {
    var n: usize = 0;
    for (siblings[0..sibling_idx]) |s| {
        if (tree.tagOf(s) != .kvpair) n += 1;
    }
    return n;
}

fn indexStep(a: Allocator, n: usize) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{d}", .{n});
}

/// Allocate `parent ++ [step]` into `a`. Each call produces a fresh
/// slice — paths shared between parent/child are not aliased.
fn extendPath(
    a: Allocator,
    parent: []const []const u8,
    step: []const u8,
) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, parent.len + 1);
    @memcpy(out[0..parent.len], parent);
    out[parent.len] = step;
    return out;
}

/// Allocate `path ++ [step]` for use by an emit site that needs a
/// child path without descending the walker (e.g. validateFormKeys
/// emitting on a kvpair).
fn appendStep(
    a: Allocator,
    path: []const []const u8,
    step: []const u8,
) Allocator.Error![]const []const u8 {
    const dup = try a.dupe(u8, step);
    return extendPath(a, path, dup);
}

/// Resolve `(base_path, step, view_kind, head)` to the pair of paths the
/// Binary walker emits diagnostics at. See `PathPair` and `StepKind`
/// docstrings for the convention. `head` is ignored when `view_kind`
/// isn't `.form`; an empty head also disables head extension (parser-
/// recovery synthetic forms).
fn computeBinaryPathPair(
    a: Allocator,
    base: []const []const u8,
    step: StepKind,
    view_kind: BinaryCursor.NodeKind,
    head: []const u8,
) Allocator.Error!PathPair {
    const has_head = view_kind == .form and head.len > 0;
    return switch (step) {
        .root => sub: {
            if (has_head) {
                const p = try extendPath(a, base, try a.dupe(u8, head));
                break :sub .{ .diag = p, .form = p };
            }
            break :sub .{ .diag = base, .form = base };
        },
        .kvpair_value => sub: {
            if (has_head) {
                const fp = try extendPath(a, base, try a.dupe(u8, head));
                break :sub .{ .diag = base, .form = fp };
            }
            break :sub .{ .diag = base, .form = base };
        },
        .positional => |idx| sub: {
            const step_str: []const u8 = if (has_head)
                try a.dupe(u8, head)
            else
                try indexStep(a, idx);
            const p = try extendPath(a, base, step_str);
            break :sub .{ .diag = p, .form = p };
        },
        .vector_element => .{ .diag = base, .form = base },
    };
}

// ---------------------------------------------------------------------------
// Per-form validation
// ---------------------------------------------------------------------------

/// Resolve a bare form head against a slot-local `local_forms` registry:
/// return the first `FormSpec` whose name matches, or null. Callers gate on
/// `namespace == null` and a non-null registry before calling — a qualified
/// head bypasses locals. Shared verbatim by the tree (`validateOneTree`) and
/// binary (`scheduleFormWalkValidate`) head-resolution steps so the two can't
/// drift on how a local head is matched.
fn matchLocalForm(reg: []const Plugin.FormSpec, head: []const u8) ?*const Plugin.FormSpec {
    for (reg) |*lf| {
        if (std.mem.eql(u8, lf.name, head)) return lf;
    }
    return null;
}

fn validateFormHead(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    path: []const []const u8,
    options: Options,
    /// Slot-local form registry in scope (from the enclosing slot's
    /// `KeySpec.local_forms`), or null when this form is not in a
    /// local-forms slot.
    local_registry: ?[]const Plugin.FormSpec,
    /// Path of the enclosing slot, used to point `unknown_local_form` at the
    /// slot rather than at the value's head. Meaningful only with a registry.
    local_slot_path: []const []const u8,
    /// The matched local form (computed by the caller), or null when no
    /// local form's bare name matched this head.
    local_hit: ?*const Plugin.FormSpec,
) Allocator.Error!void {
    const hdr = tree.formHeader(idx);
    // Empty head signals a parser-recovery synthetic form — skip.
    if (hdr.head.len == 0) return;

    // 0. Slot-local resolution (additive, local-first). Runs only for a
    // *bare* head in a slot that declared local forms — a qualified head
    // (`ns/foo`) deliberately bypasses locals and falls through to the
    // global-only path below (so its terminal miss is `unknown_form`, not
    // `unknown_local_form`). A local hit shadows the global catalog; a bare
    // miss falls back to the global lookup; a miss against both is
    // `unknown_local_form` at the slot path (the generic `unknown_form` is
    // suppressed for this node).
    if (hdr.namespace == null) {
        if (local_registry) |reg| {
            if (local_hit) |lf| {
                try validateFormKeys(a, diags, schema, cross_index, tree_scope, scope_chain, lf.*, tree, idx, hdr, path, options);
                return;
            }
            switch (schema.lookupForm(hdr.head, null)) {
                .found => |hit| {
                    try validateFormKeys(a, diags, schema, cross_index, tree_scope, scope_chain, hit.form.*, tree, idx, hdr, path, options);
                    return;
                },
                .ambiguous => |amb| {
                    try emitAmbiguous(a, diags, hdr.head_span, path, "form", hdr.head, amb.slice());
                    return;
                },
                .not_found => {
                    try emitUnknownLocalForm(a, diags, hdr.head_span, local_slot_path, hdr.head, reg);
                    return;
                },
            }
        }
    }

    // 1. Try data form lookup.
    const form_hit = schema.lookupForm(hdr.head, hdr.namespace);
    switch (form_hit) {
        .found => |hit| {
            try validateFormKeys(a, diags, schema, cross_index, tree_scope, scope_chain, hit.form.*, tree, idx, hdr, path, options);
            return;
        },
        .ambiguous => |amb| {
            try emitAmbiguous(a, diags, hdr.head_span, path, "form", hdr.head, amb.slice());
            return;
        },
        .not_found => {},
    }

    // 2. Try expression-function lookup.
    const expr_hit = schema.lookupExprFunc(hdr.head, hdr.namespace);
    switch (expr_hit) {
        .found => |hit| {
            // Resolve labels (or pass through positional). Errors on
            // the labeled path emit and stop further checks; on the
            // positional path the type loop below runs unchanged.
            const resolved = try Schema.resolveExprArgs(a, hit.func.*, tree, hdr);
            switch (resolved) {
                .err => |re| {
                    try emitResolveError(a, diags, path, hit.func.*, hdr.head_span, re);
                    return;
                },
                .ok => |r| {
                    if (!hit.func.checkArity(r.positional.len)) {
                        try emitArity(a, diags, hdr.head_span, path, hit.func.*, r.positional.len);
                    }
                    if (r.signature) |sig| {
                        // Labeled call — the signature is pinned by the
                        // matched name set, so no overload narrowing is
                        // needed. Type-check positionals directly.
                        // Forms are checked too: `matchValueAgainstType`
                        // now classifies a form's declared expression
                        // result against the expected type (or defers
                        // for opaque expressions).
                        for (r.positional, 0..) |ch, i| {
                            const ctag = tree.tagOf(ch);
                            if (ctag == .symbol) continue;
                            if (sig.paramType(i)) |t| {
                                if (try matchValueAgainstType(a, schema, cross_index, tree_scope, scope_chain, tree, ch, t, 0)) |fail| {
                                    const arg_step = try indexStep(a, i);
                                    const arg_path = try extendPath(a, path, arg_step);
                                    try emitTypeMismatch(
                                        a,
                                        diags,
                                        tree,
                                        ch,
                                        arg_path,
                                        hit.func.name,
                                        .{ .expr_arg = @intCast(i) },
                                        t,
                                        fail,
                                    );
                                } else {
                                    // Uniform with every other slot — and
                                    // now required for parity, since the
                                    // binary walker types mono labeled
                                    // args and so emits these too.
                                    try emitDeprecatedMemberTree(a, diags, schema, tree, ch, t, path);
                                    try emitStringPatternUnsupportedTree(a, diags, schema, tree, ch, t, path);
                                }
                            }
                        }
                        return;
                    }
                    // Positional call — overload-aware narrowing on the
                    // raw children (mono funcs use the typed-signature
                    // path; overloaded funcs narrow a candidate mask).
                    const overloaded = hit.func.signatures != null;
                    var cand_mask: u32 = if (overloaded)
                        overloadInitialMask(hit.func.*, hdr.children.len)
                    else
                        0;
                    for (hdr.children, 0..) |ch, positional_idx| {
                        // Symbols may be `let`-bound references whose
                        // type the validator can't predict statically;
                        // skip them. Forms get full result-type matching
                        // through `matchValueAgainstType` in the mono
                        // path; in the overloaded path the existing
                        // tag-level mask narrowing is kept (forms still
                        // tag-match against `.form`/`.expr`/`.named`/
                        // `.any` param types). Narrowing overloads by
                        // declared form-result is a later slice.
                        const ctag = tree.tagOf(ch);
                        const checkable_overload = ctag != .symbol and ctag != .form;
                        const checkable_mono = ctag != .symbol;
                        if (checkable_overload and overloaded) {
                            const ckind = ctag.toValueKind();
                            const accept = overloadAcceptMask(hit.func.*, positional_idx, ckind);
                            const new_mask = cand_mask & accept;
                            if (cand_mask != 0 and new_mask == 0) {
                                const arg_step = try indexStep(a, positional_idx);
                                const arg_path = try extendPath(a, path, arg_step);
                                try emitOverloadMismatch(
                                    a,
                                    diags,
                                    tree.spanOf(ch),
                                    arg_path,
                                    hit.func.*,
                                    positional_idx,
                                    cand_mask,
                                    ckind,
                                );
                            }
                            cand_mask = new_mask;
                        } else if (checkable_mono and !overloaded) {
                            if (hit.func.paramType(positional_idx)) |t| {
                                if (try matchValueAgainstType(a, schema, cross_index, tree_scope, scope_chain, tree, ch, t, 0)) |fail| {
                                    const arg_step = try indexStep(a, positional_idx);
                                    const arg_path = try extendPath(a, path, arg_step);
                                    try emitTypeMismatch(
                                        a,
                                        diags,
                                        tree,
                                        ch,
                                        arg_path,
                                        hit.func.name,
                                        .{ .expr_arg = @intCast(positional_idx) },
                                        t,
                                        fail,
                                    );
                                } else {
                                    // Same uniform-warning rule as every
                                    // other slot; the binary walker
                                    // already applies it to mono expr
                                    // args.
                                    try emitDeprecatedMemberTree(a, diags, schema, tree, ch, t, path);
                                    try emitStringPatternUnsupportedTree(a, diags, schema, tree, ch, t, path);
                                }
                            }
                        }
                    }
                    return;
                },
            }
        },
        .ambiguous => |amb| {
            try emitAmbiguous(a, diags, hdr.head_span, path, "expression", hdr.head, amb.slice());
            return;
        },
        .not_found => {},
    }

    // 3. Neither — unknown head.
    try emitUnknown(a, diags, hdr.head_span, path, hdr.head, hdr.namespace);
}

/// Bundle of per-form state threaded through `validateFormKeys`'s
/// sub-passes. The immutable fields mirror `validateFormKeys`'s
/// parameter list; the mutable ones (`seen`, `seen_variant`,
/// `resolved_*`, `discriminant_via_overlay`, `overlay_present*`,
/// `any_required`) accumulate findings from one pass for use by
/// later passes. State lifetime is the call to `validateFormKeys`
/// only — helpers borrow `*FormKeysState` and have no separate
/// lifecycle.
const FormKeysState = struct {
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    spec: Plugin.FormSpec,
    tree: *const Ast.Tree,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    path: []const []const u8,
    options: Options,

    /// True iff at least one declared key has `effectiveOptional() == false`.
    /// Lets the required-key sweep short-circuit when nothing is required.
    any_required: bool,
    /// Top-level declared keys the author wrote (by index into `spec.keys`).
    seen: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
    /// Variant-only declared keys the author wrote (by index into the
    /// resolved variant's `keys`). Empty until the discriminant resolves.
    seen_variant: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
    /// `:when …` value of the resolved variant, or null when the
    /// discriminant kvpair is absent and no overlay default applies.
    resolved_when: ?[]const u8 = null,
    /// Index into `spec.variants` of the resolved variant; mirrors
    /// `resolved_when` (both set together).
    resolved_variant_idx: ?usize = null,
    /// True when axis D pre-resolved the discriminant from an overlay
    /// default. Suppresses the `missing_discriminant_key` emit while
    /// leaving `seen` untouched for the discriminant slot.
    discriminant_via_overlay: bool = false,
    /// Top-level keys whose author kvpair is omitted but whose overlay
    /// default resolves. Filled by `computeOverlayPresenceBitsets`;
    /// `null` when axis C is off or there's no overlay.
    overlay_present: ?std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS) = null,
    /// Variant-key analogue of `overlay_present`.
    overlay_present_variant: ?std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS) = null,
};

/// Validate a single form-header's kvpair children + positional
/// children against `spec`, walking through six phases:
///
///   1. `emitDuplicateKvpairKeys`           — schema-independent dedup
///   2. `preresolveDiscriminantViaOverlay`  — axis D: variant from default
///   3. `validateChildKvpairsAndPositionals`— main type-check pass
///   4. `emitMissingDiscriminant`           — closed-form discriminant gate
///   5. `computeOverlayPresenceBitsets`     — axis C overlay bookkeeping
///   6. `emitMissingRequiredTopLevel`       — closed-form required sweep
///   7. (inline) top-level exclusive groups
///   8. `emitVariantSweeps`                 — variant required + exclusive
///   9. `runEffectiveRefLookups`            — axis B: cross-ref on defaults
///
/// `spec.open` short-circuits after phase 3 — phases 4-9 enforce
/// closed-form shape rules. Type checks always run regardless of
/// `open` so declared keys still get typed values.
fn validateFormKeys(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    spec: Plugin.FormSpec,
    tree: *const Ast.Tree,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    path: []const []const u8,
    options: Options,
) Allocator.Error!void {
    std.debug.assert(spec.keys.len <= Plugin.MAX_FORM_KEYS);

    var any_required = false;
    for (spec.keys) |k| {
        if (!k.effectiveOptional()) {
            any_required = true;
            break;
        }
    }

    var st: FormKeysState = .{
        .a = a,
        .diags = diags,
        .schema = schema,
        .cross_index = cross_index,
        .tree_scope = tree_scope,
        .scope_chain = scope_chain,
        .spec = spec,
        .tree = tree,
        .form_idx = form_idx,
        .hdr = hdr,
        .path = path,
        .options = options,
        .any_required = any_required,
        .seen = .initEmpty(),
        .seen_variant = .initEmpty(),
    };

    try emitDuplicateKvpairKeys(&st);
    try preresolveDiscriminantViaOverlay(&st);
    try validateChildKvpairsAndPositionals(&st);

    if (spec.open) return;

    try emitMissingDiscriminant(&st);
    computeOverlayPresenceBitsets(&st);
    try emitMissingRequiredTopLevel(&st);
    try emitExclusiveGroupDiagnostics(
        st.a,
        st.diags,
        st.spec.exclusive_groups,
        st.spec.keys,
        st.seen,
        st.overlay_present,
        st.spec.name,
        null,
        st.hdr.head_span,
        st.path,
    );
    try emitVariantSweeps(&st);
    try runEffectiveRefLookups(&st);
}

/// Phase 1 — duplicate-key detection is schema-independent: kvpair
/// lists carry map semantics, so `:k` may appear at most once even
/// on open forms (which only relax unknown-key and required-key
/// checks). Emits one `duplicate_key` per offending kvpair against
/// the *first* prior occurrence so the user sees the conflict pair.
fn emitDuplicateKvpairKeys(st: *FormKeysState) Allocator.Error!void {
    for (st.hdr.children, 0..) |ch, idx| {
        if (st.tree.tagOf(ch) != .kvpair) continue;
        const kvh = st.tree.kvpairHeader(ch);
        for (st.hdr.children[0..idx]) |prior| {
            if (st.tree.tagOf(prior) != .kvpair) continue;
            if (std.mem.eql(u8, st.tree.kvpairHeader(prior).key, kvh.key)) {
                const dup_path = try appendStep(st.a, st.path, kvh.key);
                try emit(st.a, st.diags, kvh.key_span, dup_path, .err, .duplicate_key, try duplicateKeyMsg(st.a, st.spec.name, kvh.key));
                break;
            }
        }
    }
}

/// Phase 2 — axis D. When the author omitted the discriminant
/// kvpair and the overlay carries a symbol/keyword default that
/// resolves to a known variant, pre-set `resolved_when`/
/// `resolved_variant_idx` so the children loop accepts variant-only
/// keys without the "discriminant must come first" complaint and
/// the `missing_discriminant_key` emit below suppresses. The
/// `seen` bit for the discriminant slot stays clear — this is
/// overlay-derived, not author-written.
fn preresolveDiscriminantViaOverlay(st: *FormKeysState) Allocator.Error!void {
    if (!st.options.axes.variant) return;
    const overlay = st.options.overlay orelse return;
    const didx = st.spec.discriminant_idx orelse return;
    const dkey = st.spec.keys[didx];
    if (authorWroteKvpair(st.tree, st.hdr, dkey.name)) return;
    const entry = overlay.defaultFor(st.form_idx, dkey.name) orelse return;
    // Source-level symbol defaults reach the overlay as `.keyword`
    // (see `MaterializedDefaults.literalToValue`); string defaults are
    // accepted too for symmetry with discriminant kvpair handling.
    const stext: []const u8 = switch (entry.value) {
        .keyword => |k| k,
        .string => |s| s,
        else => return,
    };
    const vs = st.spec.variants orelse &.{};
    for (vs, 0..) |v, vi| {
        if (std.mem.eql(u8, v.when, stext)) {
            st.resolved_when = v.when;
            st.resolved_variant_idx = vi;
            st.discriminant_via_overlay = true;
            return;
        }
    }
}

/// Phase 3 — main pass. Walk every child of `hdr`. Kvpairs match
/// declared keys first; if not found and the discriminant has been
/// resolved, match variant-only keys; otherwise emit unknown-key
/// (closed forms only). Positionals enforce `spec.positional`.
/// Updates `st.seen` / `st.seen_variant` and may update
/// `resolved_*` if the discriminant kvpair appears in-line.
fn validateChildKvpairsAndPositionals(st: *FormKeysState) Allocator.Error!void {
    var positional_n: usize = 0;
    for (st.hdr.children) |ch| {
        if (st.tree.tagOf(ch) == .kvpair) {
            const kvh = st.tree.kvpairHeader(ch);
            const found_declared = try matchAndTypecheckDeclaredKey(st, kvh);
            const found_variant = if (!found_declared)
                try matchAndTypecheckVariantKey(st, kvh)
            else
                false;
            if (!found_declared and !found_variant and !st.spec.open) {
                try emitUnknownKeywordKvpair(st, kvh);
            }
        } else {
            try validatePositionalChild(st, ch, positional_n);
            positional_n += 1;
        }
    }
}

/// Attempt to match `kvh` against a declared top-level key in
/// `spec.keys`. On hit: set the `seen` bit, type-check the value,
/// and (if the matched key is the discriminant slot and the value
/// is a symbol) resolve the variant for downstream lookups.
fn matchAndTypecheckDeclaredKey(
    st: *FormKeysState,
    kvh: Ast.KvPairHeader,
) Allocator.Error!bool {
    for (st.spec.keys, 0..) |k, ki| {
        if (!std.mem.eql(u8, k.name, kvh.key)) continue;
        if (ki < Plugin.MAX_FORM_KEYS) st.seen.set(ki);
        if (try matchValueAgainstType(st.a, st.schema, st.cross_index, st.tree_scope, st.scope_chain, st.tree, kvh.value, k.value_type, 0)) |fail| {
            const value_path = try appendStep(st.a, st.path, kvh.key);
            try emitTypeMismatch(
                st.a,
                st.diags,
                st.tree,
                kvh.value,
                value_path,
                st.spec.name,
                .{ .key = k.name },
                k.value_type,
                fail,
            );
        } else {
            const value_path = try appendStep(st.a, st.path, kvh.key);
            try emitDeprecatedMemberTree(st.a, st.diags, st.schema, st.tree, kvh.value, k.value_type, value_path);
            try emitStringPatternUnsupportedTree(st.a, st.diags, st.schema, st.tree, kvh.value, k.value_type, value_path);
        }
        // Discriminant slot: capture the author-written variant.
        // Type-check above already emitted any not_member diagnostic,
        // so a value outside the MemberSet leaves the variant
        // unresolved.
        if (st.spec.discriminant_idx) |didx| {
            if (ki == didx and st.tree.tagOf(kvh.value) == .symbol) {
                const sym = st.tree.symbolText(kvh.value);
                const vs = st.spec.variants orelse &.{};
                for (vs, 0..) |v, vi| {
                    if (std.mem.eql(u8, v.when, sym)) {
                        st.resolved_when = v.when;
                        st.resolved_variant_idx = vi;
                        break;
                    }
                }
            }
        }
        return true;
    }
    return false;
}

/// Variant-key fallthrough — only fires when the discriminant has
/// already been resolved (either author-written earlier in the
/// children sequence, or axis-D pre-resolved). Enforces the
/// position rule "discriminant precedes variant-only keys": keys
/// appearing earlier than the discriminant fall through to
/// `emitUnknownKeywordKvpair` instead.
fn matchAndTypecheckVariantKey(
    st: *FormKeysState,
    kvh: Ast.KvPairHeader,
) Allocator.Error!bool {
    const vi = st.resolved_variant_idx orelse return false;
    const vs = st.spec.variants.?;
    const v = vs[vi];
    for (v.keys, 0..) |vk, vki| {
        if (!std.mem.eql(u8, vk.name, kvh.key)) continue;
        if (vki < Plugin.MAX_FORM_KEYS) st.seen_variant.set(vki);
        if (try matchValueAgainstType(st.a, st.schema, st.cross_index, st.tree_scope, st.scope_chain, st.tree, kvh.value, vk.value_type, 0)) |fail| {
            const value_path = try appendStep(st.a, st.path, kvh.key);
            try emitTypeMismatch(
                st.a,
                st.diags,
                st.tree,
                kvh.value,
                value_path,
                st.spec.name,
                .{ .key = vk.name },
                vk.value_type,
                fail,
            );
        } else {
            const value_path = try appendStep(st.a, st.path, kvh.key);
            try emitDeprecatedMemberTree(st.a, st.diags, st.schema, st.tree, kvh.value, vk.value_type, value_path);
            try emitStringPatternUnsupportedTree(st.a, st.diags, st.schema, st.tree, kvh.value, vk.value_type, value_path);
        }
        return true;
    }
    return false;
}

/// Closed-form unknown-key emit. The message picks one of two
/// shapes:
///   * If the spec has a discriminant and it hasn't been resolved
///     yet, hint the producer that the discriminant must come
///     before variant-only keys.
///   * Otherwise, plain "unknown keyword", optionally annotated
///     with the active variant in parentheses when the discriminant
///     *has* resolved.
fn emitUnknownKeywordKvpair(
    st: *FormKeysState,
    kvh: Ast.KvPairHeader,
) Allocator.Error!void {
    const unk_path = try appendStep(st.a, st.path, kvh.key);
    const ctx: UnknownKeyContext = if (st.spec.discriminant_idx != null and st.resolved_when == null)
        .{ .needs_discriminant = st.spec.discriminant_name orelse "kind" }
    else
        .{ .resolved = st.resolved_when };
    try emit(st.a, st.diags, kvh.key_span, unk_path, .err, .unknown_key, try unknownKeywordMsg(st.a, st.spec.name, kvh.key, ctx));
}

/// Enforce the form's positional policy on a non-kvpair child:
///   * `.none` — emit `positional_not_allowed` (closed forms only)
///   * `.any`  — accept anything
///   * `.kind` — type-check against the named kind
fn validatePositionalChild(
    st: *FormKeysState,
    ch: Ast.NodeIndex,
    positional_n: usize,
) Allocator.Error!void {
    const pos_step = try positionalStep(st.a, st.tree, ch, positional_n);
    const pos_path = try extendPath(st.a, st.path, pos_step);
    switch (st.spec.positional) {
        .none => if (!st.spec.open) try emit(st.a, st.diags, st.tree.spanOf(ch), pos_path, .err, .positional_not_allowed, try positionalNotAllowedMsg(st.a, st.spec.name)),
        .any => {},
        .kind => |kind_ref| {
            const expected: Plugin.ValueType = .{ .named = kind_ref };
            if (try matchValueAgainstType(st.a, st.schema, st.cross_index, st.tree_scope, st.scope_chain, st.tree, ch, expected, 0)) |fail| {
                try emitTypeMismatch(
                    st.a,
                    st.diags,
                    st.tree,
                    ch,
                    pos_path,
                    st.spec.name,
                    .positional,
                    expected,
                    fail,
                );
            } else {
                // Both warnings, as at every declared-key and variant-key
                // site. The binary walker emits them uniformly for every
                // slot-contexted node (`processEvalValidate`); the tree
                // side had grown them per-site and this one only ever got
                // the string-pattern half — the `walk_opaque` bug class in
                // warning form, invisible to the corpus replay only
                // because no case covers a deprecated member in a
                // positional slot.
                try emitDeprecatedMemberTree(st.a, st.diags, st.schema, st.tree, ch, expected, pos_path);
                try emitStringPatternUnsupportedTree(st.a, st.diags, st.schema, st.tree, ch, expected, pos_path);
            }
        },
        .flag_set => |fs| {
            const is_kw = st.tree.tagOf(ch) == .keyword;
            const got: []const u8 = if (is_kw) st.tree.keywordText(ch) else "";
            switch (classifyFlag(is_kw, got, fs.flags)) {
                .ok => if (priorFlagText(st.tree, st.hdr.children, ch, got))
                    try emit(st.a, st.diags, st.tree.spanOf(ch), pos_path, .err, .duplicate_positional_flag, try flagDuplicateMsg(st.a, st.spec.name, got)),
                .wrong_shape => try emit(st.a, st.diags, st.tree.spanOf(ch), pos_path, .err, .wrong_underlying, try flagWrongShapeMsg(st.a, st.spec.name)),
                .not_member => try emit(st.a, st.diags, st.tree.spanOf(ch), pos_path, .err, .not_flag_member, try flagNotMemberMsg(st.a, st.spec.name, got, fs.flags)),
            }
        },
    }
}

/// Classification of a positional child against a `(flag-set …)` slot.
/// Shared by the tree and binary positional walkers so both paths agree
/// on `wrong_underlying` vs `not_flag_member`.
const FlagClass = enum { ok, wrong_shape, not_member };

/// `got` is the colon-stripped keyword text (meaningful only when
/// `is_keyword`). A non-keyword positional is `.wrong_shape`
/// (→ `wrong_underlying`); a keyword whose text matches no flag `name`
/// is `.not_member` (→ `not_flag_member`). Matches on `name` alone —
/// `description`/`link` metadata is ignored here.
fn classifyFlag(is_keyword: bool, got: []const u8, flags: []const Plugin.PositionalSpec.FlagSet.Flag) FlagClass {
    if (!is_keyword) return .wrong_shape;
    for (flags) |f| {
        if (std.mem.eql(u8, f.name, got)) return .ok;
    }
    return .not_member;
}

/// Prose for `wrong_underlying` when a non-keyword value sits in a flag slot.
fn flagWrongShapeMsg(a: Allocator, form_name: []const u8) Allocator.Error![]const u8 {
    return try std.fmt.allocPrint(
        a,
        "form `{s}` accepts only positional keyword flags here, not a value",
        .{form_name},
    );
}

/// Prose for `not_flag_member`: the offending flag plus the declared set.
fn flagNotMemberMsg(
    a: Allocator,
    form_name: []const u8,
    got: []const u8,
    flags: []const Plugin.PositionalSpec.FlagSet.Flag,
) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "positional flag `:");
    try buf.appendSlice(a, got);
    try buf.appendSlice(a, "` is not declared on form `");
    try buf.appendSlice(a, form_name);
    try buf.appendSlice(a, "` (declared flags: ");
    for (flags, 0..) |f, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, ":");
        try buf.appendSlice(a, f.name);
    }
    try buf.appendSlice(a, ")");
    return try buf.toOwnedSlice(a);
}

/// True when a positional keyword child whose colon-stripped text equals
/// `got` appears among `children` *before* `cur`. Drives the tree
/// walker's `duplicate_positional_flag` (the binary walker can't rewind,
/// so it accumulates seen flags instead). The scan stops at `cur`.
fn priorFlagText(tree: *const Ast.Tree, children: []const Ast.NodeIndex, cur: Ast.NodeIndex, got: []const u8) bool {
    for (children) |ci| {
        if (ci == cur) return false;
        if (tree.tagOf(ci) != .keyword) continue;
        if (std.mem.eql(u8, tree.keywordText(ci), got)) return true;
    }
    return false;
}

/// Prose for `duplicate_positional_flag`: the repeated flag plus its form.
/// Shared by the tree and binary walkers.
fn flagDuplicateMsg(a: Allocator, form_name: []const u8, got: []const u8) Allocator.Error![]const u8 {
    return try std.fmt.allocPrint(
        a,
        "positional flag `:{s}` is repeated on form `{s}`",
        .{ got, form_name },
    );
}

// -- Shared form-key walk messages -----------------------------------------
//
// These six builders are the single source of prose for the conformance-
// sensitive form-key diagnostics emitted by BOTH the tree
// (`FormKeysState`-driven) and binary (`FrameBinary`-driven) walkers. The
// corpus compares only (code, path, severity), so a wording drift between
// paths would slip every gate — sharing the builder makes drift structurally
// impossible, and the message-parity pins in `Validator_tests.zig` lock the
// exact text.

/// Prose for `duplicate_key`: the repeated keyword and its form.
fn duplicateKeyMsg(a: Allocator, form_name: []const u8, key: []const u8) Allocator.Error![]const u8 {
    return try std.fmt.allocPrint(a, "duplicate keyword `:{s}` in form `{s}`", .{ key, form_name });
}

/// Discriminant context for an `unknown_key` message. `.needs_discriminant`
/// carries the discriminant name for the "must be set before variant-only
/// keys" hint (a form with a discriminant that has not resolved yet);
/// `.resolved` carries the active variant's `:when` value — or null when no
/// variant is in play — for the optional parenthetical annotation.
const UnknownKeyContext = union(enum) {
    needs_discriminant: []const u8,
    resolved: ?[]const u8,
};

/// Prose for `unknown_key`, both shapes (pre-discriminant hint vs. plain,
/// optionally annotated with the resolved variant).
fn unknownKeywordMsg(
    a: Allocator,
    form_name: []const u8,
    key: []const u8,
    ctx: UnknownKeyContext,
) Allocator.Error![]const u8 {
    switch (ctx) {
        .needs_discriminant => |dname| return try std.fmt.allocPrint(
            a,
            "unknown keyword `:{s}` in form `{s}` — `:{s}` must be set before variant-only keys",
            .{ key, form_name, dname },
        ),
        .resolved => |maybe_when| {
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendSlice(a, "unknown keyword `:");
            try buf.appendSlice(a, key);
            try buf.appendSlice(a, "` in form `");
            try buf.appendSlice(a, form_name);
            try buf.appendSlice(a, "`");
            if (maybe_when) |w| {
                try buf.appendSlice(a, " (variant `:when ");
                try buf.appendSlice(a, w);
                try buf.appendSlice(a, "`)");
            }
            return try buf.toOwnedSlice(a);
        },
    }
}

/// Prose for `positional_not_allowed`.
fn positionalNotAllowedMsg(a: Allocator, form_name: []const u8) Allocator.Error![]const u8 {
    return try std.fmt.allocPrint(a, "form `{s}` does not accept positional children", .{form_name});
}

/// Prose for `missing_discriminant_key`.
fn missingDiscriminantMsg(a: Allocator, form_name: []const u8, dname: []const u8) Allocator.Error![]const u8 {
    return try std.fmt.allocPrint(a, "form `{s}` is missing required discriminant `:{s}`", .{ form_name, dname });
}

/// Prose for the top-level `missing_required_key`.
fn missingRequiredKeyMsg(a: Allocator, form_name: []const u8, key: []const u8) Allocator.Error![]const u8 {
    return try std.fmt.allocPrint(a, "form `{s}` is missing required keyword `:{s}`", .{ form_name, key });
}

/// Prose for the variant `missing_required_key` (names the active `:when`).
fn missingRequiredVariantKeyMsg(a: Allocator, form_name: []const u8, when: []const u8, key: []const u8) Allocator.Error![]const u8 {
    return try std.fmt.allocPrint(
        a,
        "form `{s}` (variant `:when {s}`) is missing required keyword `:{s}`",
        .{ form_name, when, key },
    );
}

/// Phase 4 — when the discriminant kvpair is absent and axis D
/// didn't pre-resolve it via the overlay, emit one
/// `missing_discriminant_key`. The single emit (vs. piling on
/// missing-variant-key diagnostics) keeps the root cause obvious.
fn emitMissingDiscriminant(st: *FormKeysState) Allocator.Error!void {
    const didx = st.spec.discriminant_idx orelse return;
    if (didx >= Plugin.MAX_FORM_KEYS) return;
    if (st.seen.isSet(didx)) return;
    if (st.discriminant_via_overlay) return;
    const dname = st.spec.discriminant_name orelse st.spec.keys[didx].name;
    try emit(st.a, st.diags, st.hdr.head_span, st.path, .err, .missing_discriminant_key, try missingDiscriminantMsg(st.a, st.spec.name, dname));
}

/// Phase 5 — axis C. Build per-key "overlay-defaulted, author-
/// absent" bitsets for the exclusive-group walker. The walker
/// applies a group-aware rule: a defaulted alternative
/// participates only when no sibling is fully author-present;
/// schemas with multiple default-only alts in the same group emit
/// `multiple_defaulted_alternatives_in_group`. When axis C is off
/// (or no overlay), both bitsets stay `null` and the walker degrades
/// to author-only counting.
fn computeOverlayPresenceBitsets(st: *FormKeysState) void {
    if (!st.options.axes.exclusive_group) return;
    const overlay = st.options.overlay orelse return;
    var op = std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS).initEmpty();
    for (st.spec.keys, 0..) |k, ki| {
        if (ki >= Plugin.MAX_FORM_KEYS) break;
        if (st.seen.isSet(ki)) continue;
        if (overlay.defaultFor(st.form_idx, k.name) != null) {
            op.set(ki);
        }
    }
    st.overlay_present = op;
    if (st.resolved_variant_idx) |vi| {
        const vs = st.spec.variants.?;
        var opv = std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS).initEmpty();
        for (vs[vi].keys, 0..) |vk, vki| {
            if (vki >= Plugin.MAX_FORM_KEYS) break;
            if (st.seen_variant.isSet(vki)) continue;
            if (overlay.defaultFor(st.form_idx, vk.name) != null) {
                opv.set(vki);
            }
        }
        st.overlay_present_variant = opv;
    }
}

/// Phase 6 — for each declared required key the author did not
/// write: emit `missing_required_key`. Skips the discriminant slot
/// (already covered by `emitMissingDiscriminant`) and any key
/// inside an exclusive group (covered by the group sweep that
/// fires right after).
fn emitMissingRequiredTopLevel(st: *FormKeysState) Allocator.Error!void {
    if (!st.any_required) return;
    for (st.spec.keys, 0..) |k, ki| {
        if (k.effectiveOptional()) continue;
        if (ki < Plugin.MAX_FORM_KEYS and st.seen.isSet(ki)) continue;
        if (st.spec.discriminant_idx) |didx| {
            if (ki == didx) continue;
        }
        if (keyInExclusiveGroup(st.spec.exclusive_groups, k.name)) continue;
        try emit(st.a, st.diags, st.hdr.head_span, st.path, .err, .missing_required_key, try missingRequiredKeyMsg(st.a, st.spec.name, k.name));
    }
}

/// Phase 8 — variant-only required-key sweep + variant exclusive
/// groups. Skips keys the author *did* write but that landed as
/// `unknown_key` because they appeared before the discriminant
/// (the user wrote them, just in the wrong order).
fn emitVariantSweeps(st: *FormKeysState) Allocator.Error!void {
    const vi = st.resolved_variant_idx orelse return;
    const v = st.spec.variants.?[vi];
    for (v.keys, 0..) |vk, vki| {
        if (vk.effectiveOptional()) continue;
        if (vki < Plugin.MAX_FORM_KEYS and st.seen_variant.isSet(vki)) continue;
        var present = false;
        for (st.hdr.children) |ch2| {
            if (st.tree.tagOf(ch2) != .kvpair) continue;
            if (std.mem.eql(u8, st.tree.kvpairHeader(ch2).key, vk.name)) {
                present = true;
                break;
            }
        }
        if (present) continue;
        if (keyInExclusiveGroup(v.exclusive_groups, vk.name)) continue;
        try emit(st.a, st.diags, st.hdr.head_span, st.path, .err, .missing_required_key, try missingRequiredVariantKeyMsg(st.a, st.spec.name, v.when, vk.name));
    }
    try emitExclusiveGroupDiagnostics(
        st.a,
        st.diags,
        v.exclusive_groups,
        v.keys,
        st.seen_variant,
        st.overlay_present_variant,
        st.spec.name,
        v.when,
        st.hdr.head_span,
        st.path,
    );
}

/// Phase 9 — axis B. For each declared key whose kvpair is
/// omitted, whose value type's underlying kind has a `cross_ref`
/// annotation, and whose overlay-default is a symbol / keyword:
/// run the registry lookup against the defaulted text. An
/// unresolved hit emits `not_cross_ref` at synthetic path
/// `[<form-head>, <key>, "default"]`. Active only when axis B is
/// on and an overlay is available.
fn runEffectiveRefLookups(st: *FormKeysState) Allocator.Error!void {
    if (!st.options.axes.ref_lookup) return;
    const overlay = st.options.overlay orelse return;
    try checkEffectiveRefLookups(
        st.a,
        st.diags,
        st.schema,
        st.cross_index,
        st.tree_scope,
        st.scope_chain,
        st.spec,
        st.form_idx,
        st.hdr,
        st.path,
        overlay,
        st.seen,
        st.resolved_variant_idx,
        st.seen_variant,
    );
}

/// `authorWroteKvpair` — does this form header carry an explicit kvpair
/// for `key_name` in author input? Sibling to `MaterializedDefaults
/// .authorValueOnForm` but answers "kvpair exists?" rather than "what's
/// the value?", because the axis-D pre-resolution code only needs the
/// presence bit.
fn authorWroteKvpair(tree: *const Ast.Tree, hdr: Ast.FormHeader, key_name: []const u8) bool {
    for (hdr.children) |ch| {
        if (tree.tagOf(ch) != .kvpair) continue;
        if (std.mem.eql(u8, tree.kvpairHeader(ch).key, key_name)) return true;
    }
    return false;
}

/// Axis B implementation. For every form-level + active-variant
/// declared key that was omitted by the author and whose value type
/// resolves to a kind carrying a `cross_ref`, look up the overlay
/// default's text against the cross-ref index. Misses emit a
/// `not_cross_ref` diagnostic; type-mismatch (overlay value is not a
/// symbol / keyword) is silently skipped — the materializer already
/// honored the declared type, so a mismatch here would indicate a
/// schema bug rather than a doc bug.
fn checkEffectiveRefLookups(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    spec: Plugin.FormSpec,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    path: []const []const u8,
    overlay: *const MaterializedDefaults.MaterializedDefaults,
    seen: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
    resolved_variant_idx: ?usize,
    seen_variant: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
) Allocator.Error!void {
    for (spec.keys, 0..) |k, ki| {
        if (ki < Plugin.MAX_FORM_KEYS and seen.isSet(ki)) continue;
        try maybeEmitEffectiveRefMiss(
            a,
            diags,
            schema,
            cross_index,
            tree_scope,
            scope_chain,
            spec.name,
            form_idx,
            hdr,
            path,
            overlay,
            k,
        );
    }
    if (resolved_variant_idx) |vi| {
        const v = spec.variants.?[vi];
        for (v.keys, 0..) |vk, vki| {
            if (vki < Plugin.MAX_FORM_KEYS and seen_variant.isSet(vki)) continue;
            try maybeEmitEffectiveRefMiss(
                a,
                diags,
                schema,
                cross_index,
                tree_scope,
                scope_chain,
                spec.name,
                form_idx,
                hdr,
                path,
                overlay,
                vk,
            );
        }
    }
}

fn maybeEmitEffectiveRefMiss(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    form_name: []const u8,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    path: []const []const u8,
    overlay: *const MaterializedDefaults.MaterializedDefaults,
    key: Plugin.KeySpec,
) Allocator.Error!void {
    const named = switch (key.value_type) {
        .named => |n| n,
        else => return,
    };
    const lookup = schema.lookupValueKind(named.name, named.namespace);
    const kind_ptr = switch (lookup) {
        .found => |v| v,
        else => return,
    };
    const cr = kind_ptr.cross_ref orelse return;

    const entry = overlay.defaultFor(form_idx, key.name) orelse return;
    const got = switch (entry.value) {
        .keyword => |k| k,
        .string => |s| s,
        else => return,
    };

    const canonical = (try schema.canonicalFormName(a, cr.target_form)) orelse return;
    const lookup_scope: ScopeId = if (cr.scope_form) |sf| sub: {
        const scope_canonical = (try schema.canonicalFormName(a, sf)) orelse return;
        break :sub findNearestScope(scope_chain, scope_canonical) orelse return;
    } else tree_scope;

    if (cross_index.contains(lookup_scope, canonical, got)) return;
    // Same poison rule as `matchScalar`'s cross-ref arm — this is the
    // other place `not_cross_ref` is emitted, and an uncomputable member
    // set must silence both or the cascade comes back through Axis B.
    if (cross_index.isPoisoned(lookup_scope, canonical)) return;

    var step_path: std.ArrayList([]const u8) = .empty;
    try step_path.appendSlice(a, path);
    try step_path.append(a, try a.dupe(u8, key.name));
    try step_path.append(a, try a.dupe(u8, "default"));
    const default_path = try step_path.toOwnedSlice(a);

    const msg = try std.fmt.allocPrint(
        a,
        "form `{s}` keyword `:{s}` default `{s}` does not name a `({s} …)` instance",
        .{ form_name, key.name, got, canonical },
    );
    try emit(a, diags, hdr.head_span, default_path, .err, .not_cross_ref, msg);
}

/// Returns true when `name` appears in any alternative of any group.
/// Used by both the form and variant required-key sweeps to skip
/// double-emission: the exclusive-group sweep is responsible for
/// presence diagnostics on grouped keys.
fn keyInExclusiveGroup(groups: []const Plugin.ExclusiveGroup, name: []const u8) bool {
    for (groups) |g| {
        for (g.alternatives) |alt| {
            for (alt.keys) |k| {
                if (std.mem.eql(u8, k, name)) return true;
            }
        }
    }
    return false;
}

/// Returns true when every key listed by `alt.keys` is set in `seen`.
/// `seen` is indexed by position in `keys`; an alt key whose name has
/// no slot in `keys` (caller-side bug — manifest loader rejects this,
/// but static plugin literals could) is treated as absent.
fn alternativePresentTree(
    alt: Plugin.Alternative,
    keys: []const Plugin.KeySpec,
    seen: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
) bool {
    if (alt.keys.len == 0) return false;
    for (alt.keys) |alt_key| {
        const idx = indexOfKey(keys, alt_key) orelse return false;
        if (idx >= Plugin.MAX_FORM_KEYS) return false;
        if (!seen.isSet(idx)) return false;
    }
    return true;
}

/// Returns true when a multi-key alt bundle is partially present:
/// at least one key in `seen`, at least one key absent. Single-key
/// alts (`alt.keys.len <= 1`) never report partial — partial-bundle
/// is a multi-key-only failure mode.
fn alternativePartiallyPresentTree(
    alt: Plugin.Alternative,
    keys: []const Plugin.KeySpec,
    seen: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
) bool {
    if (alt.keys.len <= 1) return false;
    var any_set = false;
    var any_absent = false;
    for (alt.keys) |alt_key| {
        const idx = indexOfKey(keys, alt_key) orelse {
            any_absent = true;
            continue;
        };
        if (idx >= Plugin.MAX_FORM_KEYS) {
            any_absent = true;
            continue;
        }
        if (seen.isSet(idx)) any_set = true else any_absent = true;
    }
    return any_set and any_absent;
}

/// Returns true when an alt is resolvable via author keys + overlay
/// defaults but is **not** fully author-present — i.e. all alt keys
/// are in `seen OR overlay_present`, and at least one is supplied by
/// overlay alone. v1 single-key alts: equivalent to "the key is
/// overlay-defaulted, not author-set." Used by the group walker to
/// apply the group-aware default rule.
fn alternativeDefaultResolved(
    alt: Plugin.Alternative,
    keys: []const Plugin.KeySpec,
    seen: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
    overlay_present: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
) bool {
    if (alt.keys.len == 0) return false;
    var saw_default = false;
    for (alt.keys) |alt_key| {
        const idx = indexOfKey(keys, alt_key) orelse return false;
        if (idx >= Plugin.MAX_FORM_KEYS) return false;
        const in_seen = seen.isSet(idx);
        const in_overlay = overlay_present.isSet(idx);
        if (!in_seen and !in_overlay) return false;
        if (!in_seen and in_overlay) saw_default = true;
    }
    return saw_default;
}

fn indexOfKey(keys: []const Plugin.KeySpec, name: []const u8) ?usize {
    for (keys, 0..) |k, i| {
        if (std.mem.eql(u8, k.name, name)) return i;
    }
    return null;
}

fn emitExclusiveGroupDiagnostics(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    groups: []const Plugin.ExclusiveGroup,
    keys: []const Plugin.KeySpec,
    seen: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
    overlay_present: ?std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
    form_name: []const u8,
    variant_when: ?[]const u8,
    span: Ast.Span,
    path: []const []const u8,
) Allocator.Error!void {
    for (groups) |group| {
        var author_count: usize = 0;
        for (group.alternatives) |alt| {
            if (alternativePresentTree(alt, keys, seen)) author_count += 1;
        }
        // Author trumps default: defaulted alts only contribute to the
        // presence count when no sibling is fully author-present.
        var default_count: usize = 0;
        if (author_count == 0) {
            if (overlay_present) |op| {
                for (group.alternatives) |alt| {
                    if (alternativeDefaultResolved(alt, keys, seen, op)) default_count += 1;
                }
            }
        }

        if (author_count >= 2) {
            try emit(a, diags, span, path, .err, .mutually_exclusive_keys_present, try formatExclusiveMessage(
                a,
                form_name,
                variant_when,
                group,
                .mutually_exclusive_keys_present,
            ));
            continue;
        }

        // Partial multi-key bundles fire only when no sibling alt is
        // fully author-present. A full sibling wins the group via the
        // mutually-exclusive check above; a partial paired with a
        // satisfied sibling is just one author overspecifying — covered
        // by the existing presence count below, not a bundle bug.
        if (author_count == 0) {
            for (group.alternatives) |alt| {
                if (alternativePartiallyPresentTree(alt, keys, seen)) {
                    try emit(a, diags, span, path, .err, .exclusive_bundle_partial, try formatExclusiveBundleMessage(
                        a,
                        form_name,
                        variant_when,
                        alt,
                        keys,
                        seen,
                    ));
                }
            }
        }

        if (author_count == 0 and default_count > 1) {
            // Schema ambiguity — multiple default-only paths with no
            // author resolution. Skip the cardinality check; the
            // diagnostic points the schema author at the conflicting
            // defaults, not the document author at a phantom overpresence.
            try emit(a, diags, span, path, .err, .multiple_defaulted_alternatives_in_group, try formatExclusiveMessage(
                a,
                form_name,
                variant_when,
                group,
                .multiple_defaulted_alternatives_in_group,
            ));
            continue;
        }

        const present_count = author_count + default_count;
        if (present_count == 0 and group.cardinality == .exactly_one) {
            // Skip required_one_of_missing when a partial-bundle was
            // already emitted: the author tried to set the bundle,
            // pointing them at the missing siblings is the better
            // diagnostic than telling them no alt was chosen.
            var partial_seen = false;
            for (group.alternatives) |alt| {
                if (alternativePartiallyPresentTree(alt, keys, seen)) {
                    partial_seen = true;
                    break;
                }
            }
            if (!partial_seen) {
                try emit(a, diags, span, path, .err, .required_one_of_missing, try formatExclusiveMessage(
                    a,
                    form_name,
                    variant_when,
                    group,
                    .required_one_of_missing,
                ));
            }
        }
    }
}

/// Formats the exclusive-group diagnostic message in the shape used by
/// both the tree and binary paths. The alternatives list is rendered as
/// `:k1` / `:k1+:k2`-joined entries separated by " | " — readable for
/// the v1 single-key shape and for the v2 multi-key bundles.
fn formatExclusiveMessage(
    a: Allocator,
    form_name: []const u8,
    variant_when: ?[]const u8,
    group: Plugin.ExclusiveGroup,
    code: Diagnostic.Code,
) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "form `");
    try buf.appendSlice(a, form_name);
    try buf.appendSlice(a, "`");
    if (variant_when) |w| {
        try buf.appendSlice(a, " (variant `:when ");
        try buf.appendSlice(a, w);
        try buf.appendSlice(a, "`)");
    }
    switch (code) {
        .mutually_exclusive_keys_present => try buf.appendSlice(a, ": at most one of "),
        .required_one_of_missing => try buf.appendSlice(a, ": exactly one of "),
        .multiple_defaulted_alternatives_in_group => try buf.appendSlice(a, ": schema admits more than one default-only path through "),
        else => try buf.appendSlice(a, ": "),
    }
    for (group.alternatives, 0..) |alt, ai| {
        if (ai > 0) try buf.appendSlice(a, " | ");
        for (alt.keys, 0..) |kn, ki| {
            if (ki > 0) try buf.appendSlice(a, "+");
            try buf.appendSlice(a, ":");
            try buf.appendSlice(a, kn);
        }
    }
    switch (code) {
        .mutually_exclusive_keys_present => try buf.appendSlice(a, " may be present"),
        .required_one_of_missing => try buf.appendSlice(a, " must be present"),
        .multiple_defaulted_alternatives_in_group => try buf.appendSlice(a, " — author has no kvpair to disambiguate"),
        else => {},
    }
    return try buf.toOwnedSlice(a);
}

/// Formats `exclusive_bundle_partial`. Names every key in the bundle,
/// tags each as set/missing, so the author can see which sibling to
/// add. Mirrors the `:k1+:k2` rendering of `formatExclusiveMessage`.
fn formatExclusiveBundleMessage(
    a: Allocator,
    form_name: []const u8,
    variant_when: ?[]const u8,
    alt: Plugin.Alternative,
    keys: []const Plugin.KeySpec,
    seen: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "form `");
    try buf.appendSlice(a, form_name);
    try buf.appendSlice(a, "`");
    if (variant_when) |w| {
        try buf.appendSlice(a, " (variant `:when ");
        try buf.appendSlice(a, w);
        try buf.appendSlice(a, "`)");
    }
    try buf.appendSlice(a, ": exclusive-group alt `");
    for (alt.keys, 0..) |kn, ki| {
        if (ki > 0) try buf.appendSlice(a, "+");
        try buf.appendSlice(a, ":");
        try buf.appendSlice(a, kn);
    }
    try buf.appendSlice(a, "` is partially present (");
    var first = true;
    for (alt.keys) |kn| {
        if (!first) try buf.appendSlice(a, ", ");
        first = false;
        try buf.appendSlice(a, ":");
        try buf.appendSlice(a, kn);
        const idx = indexOfKey(keys, kn);
        const is_set = if (idx) |i| (i < Plugin.MAX_FORM_KEYS and seen.isSet(i)) else false;
        try buf.appendSlice(a, if (is_set) " set" else " missing");
    }
    try buf.appendSlice(a, "); bundles are all-or-nothing");
    return try buf.toOwnedSlice(a);
}

/// Step name for a positional child of a form: the form's head when
/// the child is itself a form (and has one), otherwise the positional
/// ordinal as a decimal string. Mirrors `childStep` but operates on
/// a single child instead of a sibling list.
fn positionalStep(
    a: Allocator,
    tree: *const Ast.Tree,
    child: Ast.NodeIndex,
    n: usize,
) Allocator.Error![]const u8 {
    if (tree.tagOf(child) == .form) {
        const ch_hdr = tree.formHeader(child);
        if (ch_hdr.head.len > 0) return try a.dupe(u8, ch_hdr.head);
    }
    return indexStep(a, n);
}

// Bitset coupling: required-key tracking uses a `u64`-backed bitset, so
// the language-level `Plugin.MAX_FORM_KEYS` cap must fit. Both construction
// paths reject over-cap forms before the bitset is indexed: ManifestLoader
// emits `too_many_keys` at load time, and `Schema.assertFormKeyCaps`
// (invoked from `Schema.init`) panics on directly-constructed plugins.
// The runtime `if (ki < Plugin.MAX_FORM_KEYS)` guards downstream are
// defense-in-depth.
comptime {
    std.debug.assert(Plugin.MAX_FORM_KEYS <= @bitSizeOf(u64));
}

// ---------------------------------------------------------------------------
// Diagnostic builders
// ---------------------------------------------------------------------------

fn emit(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    span: Ast.Span,
    path: []const []const u8,
    severity: Severity,
    code: Diagnostic.Code,
    message: []const u8,
) Allocator.Error!void {
    try diags.append(a, .{
        .span = span,
        .severity = severity,
        .code = code,
        .message = message,
        .path = try clonePath(a, path),
    });
}

/// Defensive-copy a path slice into the diagnostics arena. The walker
/// reuses path slices across siblings (parent path is shared); cloning
/// at emit time decouples the diagnostic from any later mutation.
fn clonePath(a: Allocator, path: []const []const u8) Allocator.Error![]const []const u8 {
    if (path.len == 0) return &.{};
    const out = try a.alloc([]const u8, path.len);
    for (path, 0..) |s, i| out[i] = s;
    return out;
}

fn emitUnknown(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    span: Ast.Span,
    path: []const []const u8,
    head: []const u8,
    namespace: ?[]const u8,
) Allocator.Error!void {
    const msg = if (namespace) |ns|
        try std.fmt.allocPrint(a, "unknown form `{s}/{s}`", .{ ns, head })
    else
        try std.fmt.allocPrint(a, "unknown form `{s}`", .{head});
    try emit(a, diags, span, path, .err, .unknown_form, msg);
}

/// Emit `unknown_local_form` for a form value whose head matched neither a
/// slot-local form nor — after the additive fallback — any global form. The
/// diagnostic is reported at `slot_path` (the enclosing slot, e.g.
/// `[canvas shape]`) and lists the allowed local heads, mirroring
/// `emitAmbiguous`'s list formatting. The caller suppresses the generic
/// `unknown_form` for this node.
fn emitUnknownLocalForm(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    span: Ast.Span,
    slot_path: []const []const u8,
    head: []const u8,
    registry: []const Plugin.FormSpec,
) Allocator.Error!void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "unknown form `");
    try buf.appendSlice(a, head);
    try buf.appendSlice(a, "` in this slot — expected one of [");
    for (registry, 0..) |lf, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, lf.name);
    }
    try buf.appendSlice(a, "] or a known form");
    try emit(a, diags, span, slot_path, .err, .unknown_local_form, try buf.toOwnedSlice(a));
}

/// `kind` is the user-facing English label ("form", "expression",
/// "value-kind") and selects the stable `code` variant.
fn emitAmbiguous(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    span: Ast.Span,
    path: []const []const u8,
    kind: []const u8,
    head: []const u8,
    claimants: []const *const Plugin.Plugin,
) Allocator.Error!void {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, kind);
    try buf.appendSlice(a, " `");
    try buf.appendSlice(a, head);
    try buf.appendSlice(a, "` is ambiguous — defined by [");
    for (claimants, 0..) |p, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, p.name);
    }
    try buf.appendSlice(a, "]; qualify with `<ns>/");
    try buf.appendSlice(a, head);
    try buf.appendSlice(a, "`");
    const code: Diagnostic.Code =
        if (std.mem.eql(u8, kind, "expression")) .ambiguous_expr else if (std.mem.eql(u8, kind, "value-kind")) .ambiguous_element_kind else .ambiguous_form;
    try emit(a, diags, span, path, .err, code, try buf.toOwnedSlice(a));
}

/// Translate a `Schema.ResolveError` into the corresponding diagnostic.
/// Each variant maps 1:1 to a `Diagnostic.Code`; this routes message
/// strings + spans into the standard `emit` pipeline.
///
/// Takes `head_span` rather than the whole `Ast.FormHeader` because the
/// binary walker has no header to hand — only `missing_label`, which has
/// no span of its own, needs it. Sharing this emitter is what keeps the
/// two paths' *messages* identical, not just their codes.
fn emitResolveError(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    path: []const []const u8,
    func: Plugin.ExprFunc,
    head_span: Ast.Span,
    err: Schema.ResolveError,
) Allocator.Error!void {
    switch (err) {
        .mixed => |m| {
            const msg = try std.fmt.allocPrint(
                a,
                "expression `{s}` mixes positional and labeled arguments — pick one calling style",
                .{func.name},
            );
            try emit(a, diags, m.span, path, .err, .expr_mixed_args, msg);
        },
        .labels_not_supported => |ls| {
            const child_path = try appendStep(a, path, ls.key);
            const msg = try std.fmt.allocPrint(
                a,
                "expression `{s}` does not accept keyword argument `:{s}`",
                .{ func.name, ls.key },
            );
            try emit(a, diags, ls.span, child_path, .err, .expr_kvpair_not_allowed, msg);
        },
        .unknown_label => |ul| {
            const child_path = try appendStep(a, path, ul.key);
            const msg = try std.fmt.allocPrint(
                a,
                "expression `{s}` has no parameter named `{s}`",
                .{ func.name, ul.key },
            );
            try emit(a, diags, ul.span, child_path, .err, .expr_unknown_label, msg);
        },
        .duplicate_label => |dl| {
            const child_path = try appendStep(a, path, dl.key);
            const msg = try std.fmt.allocPrint(
                a,
                "duplicate label `:{s}` in call to `{s}`",
                .{ dl.key, func.name },
            );
            try emit(a, diags, dl.span, child_path, .err, .expr_duplicate_label, msg);
        },
        .missing_label => |ml| {
            const msg = try std.fmt.allocPrint(
                a,
                "expression `{s}` requires labeled argument `:{s}`",
                .{ func.name, ml.name },
            );
            try emit(a, diags, head_span, path, .err, .expr_missing_label, msg);
        },
    }
}

fn emitArity(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    span: Ast.Span,
    path: []const []const u8,
    func: Plugin.ExprFunc,
    actual: usize,
) Allocator.Error!void {
    const expected = switch (func.arity) {
        .fixed => |k| try std.fmt.allocPrint(a, "exactly {d}", .{k}),
        .at_least => |k| try std.fmt.allocPrint(a, "at least {d}", .{k}),
        .range => |r| try std.fmt.allocPrint(a, "{d}..{d}", .{ r.min, r.max }),
    };
    const msg = try std.fmt.allocPrint(
        a,
        "expression `{s}` expects {s} argument(s), got {d}",
        .{ func.name, expected, actual },
    );
    try emit(a, diags, span, path, .err, .arity_mismatch, msg);
}

/// Map an internal `MatchFail` variant onto the stable diagnostic code.
/// Pure switch — used by both Tree and Binary type-mismatch emitters.
///
/// `element_at` recurses to the leaf failure: a typed-vector element
/// that fails its kind check carries the leaf code (e.g. `wrong_underlying`
/// when a number-typed element gets a string). The Binary path emits
/// per-element directly with the leaf code, so this recursion keeps
/// Tree + Binary code-parity. The vector's *length* mismatch stays at
/// `vector_length_mismatch` (a container-level failure, not nested).
fn matchFailToCode(fail: MatchFail) Diagnostic.Code {
    return switch (fail) {
        .wrong_underlying => .wrong_underlying,
        .wrong_vector_len => .vector_length_mismatch,
        .vector_too_short => .vector_too_short,
        .vector_too_long => .vector_too_long,
        .element_at => |e| matchFailToCode(e.fail.*),
        .unit_missing => .unit_required,
        .unit_wrong => .unit_not_allowed,
        .unit_forbidden => .unit_forbidden,
        .not_member => .not_member,
        .not_head_member => .not_head_member,
        .unknown_element_kind => .unknown_element_kind,
        .ambiguous_element_kind => .ambiguous_element_kind,
        .recursion_depth => .recursion_depth,
        .not_cross_ref => .not_cross_ref,
        .cross_ref_outside_scope => .cross_ref_outside_scope,
        .union_no_branch_matched => .union_no_branch_matched,
        .number_below_min => .number_below_min,
        .number_above_max => .number_above_max,
        .number_at_or_below_exclusive_min => .number_at_or_below_exclusive_min,
        .number_at_or_above_exclusive_max => .number_at_or_above_exclusive_max,
        .number_not_integer => .number_not_integer,
        .numeric_bound_unit_mismatch => .numeric_bound_unit_mismatch,
        .repr_out_of_range => .repr_out_of_range,
        .string_too_short => .string_too_short,
        .string_too_long => .string_too_long,
        .string_format_mismatch => .string_format_mismatch,
        .string_pattern_mismatch => .string_pattern_mismatch,
    };
}

// ---------------------------------------------------------------------------
// Slot-type matching
//
// Activates the dormant `KeySpec.value_type` and `PositionalSpec.kind`
// declarations. Pure walk on `Ast.Tree` — no allocation on the success
// path. Allocates only nested `MatchFail` records when a typed-vector
// element fails (rare error path; uses the diagnostic arena).
//
// `Tag.form` defers to runtime everywhere except when the slot expects a
// form/expression directly. Reason: a form value in a slot is almost
// always an expression that will be evaluated to the slot's type at
// expr-eval time. The validator can't statically resolve that, so it
// stays out of the way.
// ---------------------------------------------------------------------------

/// Identifies which slot of a form a diagnostic is about. Carried into
/// `emitTypeMismatch` so the message can name the slot.
///
/// `expr_arg` carries the 0-based positional index for an expression
/// argument; the surrounding `SlotCtx.form_name` carries the expr name.
/// The diagnostic prefix flips from "form" to "expression" in this case
/// so prose reads as `expression `+` argument 2 expects number, …`.
const Slot = union(enum) {
    positional,
    key: []const u8,
    expr_arg: u8,
};

/// Reason a typed-slot match failed. Returned from `matchValueAgainstType`
/// and consumed by `emitTypeMismatch`. Recursive via `element_at` (inner
/// pointer is allocated on the diagnostics arena — cheap because match
/// failure is rare).
const MatchFail = union(enum) {
    /// Tag-level mismatch. Payload is an English category label
    /// (`"number"`, `"vector"`, …) — the actual node's tag is read at
    /// format time via `tree.tagOf`.
    wrong_underlying: []const u8,
    /// Vector arity mismatch under a `VectorShape` with a fixed `len`.
    wrong_vector_len: struct { want: u16, got: u32 },
    /// Vector shorter than `VectorShape.min_len` (variable-arity floor).
    vector_too_short: struct { got: u32, min_len: u16 },
    /// Vector longer than `VectorShape.max_len` (variable-arity ceiling).
    vector_too_long: struct { got: u32, max_len: u16 },
    /// A typed-vector element failed to match. `leaf` points at the
    /// element node so the diagnostic can name what tag it actually has.
    element_at: struct {
        index: usize,
        fail: *const MatchFail,
        leaf: Ast.NodeIndex,
    },
    /// Bare `Tag.number` where the slot's `UnitShape.required` is true.
    unit_missing: []const []const u8,
    /// `Tag.number_with_unit` whose suffix is not in `UnitShape.allowed`.
    unit_wrong: struct { got: []const u8, allowed: []const []const u8 },
    /// `Tag.number_with_unit` in a slot whose `UnitShape.reject` is true
    /// (bare numbers only). Payload is the offending unit suffix text.
    unit_forbidden: []const u8,
    /// `Tag.symbol` or `Tag.string` whose text is not in `MemberSet.members`.
    /// `allowed` carries the kind's full Member slice so diagnostic
    /// prose can list names and forward-looking hooks (e.g. LSP "did
    /// you mean?") can read labels / deprecation flags too.
    not_member: struct { got: []const u8, allowed: []const Plugin.ValueKind.MemberSet.Member },
    /// `Tag.form` whose head name is not in `HeadSet.names`. Distinct
    /// from `not_member` so the diagnostic prose can name the
    /// discriminator role explicitly (`form head … not in set …`).
    not_head_member: struct { got: []const u8, allowed: []const []const u8 },
    /// The slot referenced an undeclared `ValueKind` — a plugin-setup bug.
    /// `namespace` is non-null when the slot was qualified (`paint/color`)
    /// so the rendered diagnostic preserves the user's surface text.
    unknown_element_kind: struct {
        name: []const u8,
        namespace: ?[]const u8 = null,
    },
    /// Cross-plugin name collision on a bare `.named` value-kind reference.
    /// `claimants` are arena-owned; rendered at format time. When this fail
    /// fires the slot was bare — qualifying with `<plugin>/<name>` would
    /// pick one of the claimants. The renderer surfaces that hint.
    ambiguous_element_kind: struct {
        name: []const u8,
        claimants: []const *const Plugin.Plugin,
    },
    /// `Schema.MAX_KIND_DEPTH` exceeded resolving a chain of named kinds.
    recursion_depth,
    /// `Tag.symbol` value didn't match any registered name in the
    /// cross-ref's target table. `got` is the symbol's text; `target`
    /// names the form whose instances populate the registry.
    ///
    /// `key` and `route` are what the message needs to point the reader
    /// at the *declarations*: on the identity route the member set is
    /// the `:name-key` symbol of each target instance, on the provider
    /// route it is whatever a provider extracted from each instance's
    /// `:source-key` string. Both are carried rather than assumed
    /// because a message naming the wrong key sends the reader to add a
    /// declaration in a place that would not register one.
    not_cross_ref: struct {
        got: []const u8,
        target: []const u8,
        key: []const u8,
        route: enum { identity, provider },
    },
    /// A `:scope <form>`-bound cross-ref reference appeared outside any
    /// enclosing instance of `<form>`. `got` is the symbol's text;
    /// `scope_form` names the missing enclosing form (canonical).
    cross_ref_outside_scope: struct { got: []const u8, scope_form: []const u8 },
    /// A `union_of` value-kind's alternatives all rejected the value.
    /// `got_label` is the actual node's tag category (e.g. "number",
    /// "form"); `alternatives` is the kind's alternative-name list.
    /// Both slices are kind-lifetime — diagnostics borrow, never own.
    union_no_branch_matched: struct {
        got_label: []const u8,
        alternatives: []const Plugin.QualifiedRef,
    },
    /// Value below an inclusive `:min`.
    number_below_min: NumericFail,
    /// Value above an inclusive `:max`.
    number_above_max: NumericFail,
    /// Value ≤ `:min` when `:exclusive-min true`.
    number_at_or_below_exclusive_min: NumericFail,
    /// Value ≥ `:max` when `:exclusive-max true`.
    number_at_or_above_exclusive_max: NumericFail,
    /// `:integer true` set; value is fractional or non-finite. Payload is
    /// the value's f64 magnitude for the diagnostic message.
    number_not_integer: f64,
    /// Bound carries a unit but the validated value either has none or
    /// carries a different unit. Either side may be null.
    numeric_bound_unit_mismatch: struct {
        value_unit: ?[]const u8,
        bound_unit: ?[]const u8,
    },
    /// Value doesn't fit its value-kind's `:repr` GPU type. `reason`
    /// disambiguates the rendered message between an out-of-range
    /// magnitude and a non-integral value under an integer type; `repr`
    /// names the GPU type. `value` is the f64 view (lossy only for u64 >
    /// 2^53, which is already far out of every integer repr's range).
    repr_out_of_range: struct {
        value: f64,
        repr: Plugin.ValueKind.Repr,
        reason: enum { out_of_range, not_integer },
    },

    /// String length below inclusive `:min-len` (UTF-8 codepoint count).
    string_too_short: struct { got: u32, min_len: u32 },
    /// String length above inclusive `:max-len` (UTF-8 codepoint count).
    string_too_long: struct { got: u32, max_len: u32 },
    /// String doesn't satisfy declared `:format`. `got` is the literal
    /// text; `format` is the format's symbolic name (kept as a string
    /// here so diagnostic rendering doesn't need to import the enum).
    string_format_mismatch: struct { got: []const u8, format: []const u8 },
    /// Reserved: string value doesn't match the declared `:pattern`. v1
    /// builds never produce this — the regex engine lands in a follow-up
    /// milestone. `string_pattern_unsupported` is what fires instead.
    string_pattern_mismatch: struct { got: []const u8, pattern: []const u8 },

    /// Shared payload for the four out-of-range MatchFail variants.
    /// `value` is the validated number's f64 view (lossy for u64 > 2^53);
    /// `bound` is the bound's f64 view; `unit` is the bound's unit if
    /// any (only present when the bound was declared with a suffix).
    pub const NumericFail = struct {
        value: f64,
        bound: f64,
        unit: ?[]const u8 = null,
    };
};

/// A numeric value's exact representation, kept tag-true so the validator
/// can pick integer-space comparison when both the value and a `:min`/
/// `:max` bound came from integer literals. Mirrored on the binary path
/// via `MatchExtras.numeric`.
const NumericValue = union(enum) {
    f: f64,
    i: i64,
    u: u64,

    fn toF64(self: NumericValue) f64 {
        return switch (self) {
            .f => |v| v,
            .i => |v| @floatFromInt(v),
            .u => |v| @floatFromInt(v),
        };
    }

    /// True when the value is integral in the IEEE-754 sense. `Tag.number_i64`
    /// and `Tag.number_u64` are trivially integer; `Tag.number` /
    /// `Tag.number_with_unit` reject NaN, ±inf, and fractional magnitudes.
    fn isInteger(self: NumericValue) bool {
        return switch (self) {
            .i, .u => true,
            .f => |v| std.math.isFinite(v) and @floor(v) == v,
        };
    }
};

fn readNumericValueTree(
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    tag: Ast.Tag,
) NumericValue {
    return switch (tag) {
        .number => .{ .f = tree.numberOf(idx) },
        .number_i64 => .{ .i = tree.numberI64Of(idx) },
        .number_u64 => .{ .u = tree.numberU64Of(idx) },
        .number_with_unit => .{ .f = tree.numberWithUnitOf(idx).value },
        else => unreachable, // caller already gated on numeric tags
    };
}

fn boundFitsI64(f: f64) bool {
    return std.math.isFinite(f) and
        @floor(f) == f and
        f >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
        f <= @as(f64, @floatFromInt(std.math.maxInt(i64)));
}

fn boundFitsU64(f: f64) bool {
    return std.math.isFinite(f) and
        @floor(f) == f and
        f >= 0.0 and
        // f64's max representable u64-fitting value is 2^64 (exclusive). The
        // strict `<` is deliberate: 18446744073709551616.0 rounds to a number
        // that overflows on `@intFromFloat(u64)`.
        f < 18446744073709551616.0;
}

/// Comparison of a numeric value against a `Bound`, preserving exact-int
/// precision where possible. The value's tag-true representation
/// (`NumericValue`) combined with the bound's `exact_int` flag picks the
/// integer-space path when both came from integer literals; otherwise the
/// comparison falls back to f64 (documented as lossy when |value| > 2^53).
///
/// NaN-safe: `std.math.order` panics on NaN (both `<` and `>` are false).
/// When either operand is NaN we report `.eq` — the bounds-check arms
/// treat that as "not strictly less / not strictly greater", which means
/// inclusive bounds let NaN through and exclusive bounds reject it.
/// Users who want a hard NaN gate should set `:integer true` (it rejects
/// all non-finite values upstream of this function).
fn compareToBound(value: NumericValue, bound: Plugin.ValueKind.NumericBounds.Bound) std.math.Order {
    return switch (value) {
        .f => |v| sub: {
            if (std.math.isNan(v) or std.math.isNan(bound.value)) break :sub .eq;
            break :sub std.math.order(v, bound.value);
        },
        .i => |v| sub: {
            if (bound.exact_int and boundFitsI64(bound.value)) {
                const b: i64 = @intFromFloat(bound.value);
                break :sub std.math.order(v, b);
            }
            if (std.math.isNan(bound.value)) break :sub .eq;
            break :sub std.math.order(@as(f64, @floatFromInt(v)), bound.value);
        },
        .u => |v| sub: {
            if (bound.exact_int and boundFitsU64(bound.value)) {
                const b: u64 = @intFromFloat(bound.value);
                break :sub std.math.order(v, b);
            }
            if (std.math.isNan(bound.value)) break :sub .eq;
            break :sub std.math.order(@as(f64, @floatFromInt(v)), bound.value);
        },
    };
}

/// True when the bound's `:unit` requirement and the value's actual unit
/// disagree by byte-equality (no canonicalisation — units are opaque per
/// LANGUAGE.md §2.6). `null` on either side counts as "no unit".
fn boundUnitMismatch(bound: Plugin.ValueKind.NumericBounds.Bound, value_unit: ?[]const u8) bool {
    if (bound.unit == null) return false;
    if (value_unit == null) return true;
    return !std.mem.eql(u8, bound.unit.?, value_unit.?);
}

/// Run integer + min + max checks; return the first failure in priority
/// order. The validator emits at most one diagnostic per slot (matches
/// the existing one-fail-per-call discipline for unit checks etc.); the
/// priority puts the structural unit-mismatch ahead of value comparisons
/// so a wrong-unit value isn't also flagged out-of-range.
fn checkNumericBoundsValue(
    value: NumericValue,
    value_unit: ?[]const u8,
    nb: Plugin.ValueKind.NumericBounds,
) ?MatchFail {
    if (nb.integer and !value.isInteger()) {
        return MatchFail{ .number_not_integer = value.toF64() };
    }
    if (nb.min) |mn| {
        if (boundUnitMismatch(mn, value_unit)) return MatchFail{
            .numeric_bound_unit_mismatch = .{ .value_unit = value_unit, .bound_unit = mn.unit },
        };
        const ord = compareToBound(value, mn);
        if (nb.exclusive_min) {
            if (ord != .gt) return MatchFail{
                .number_at_or_below_exclusive_min = .{ .value = value.toF64(), .bound = mn.value, .unit = mn.unit },
            };
        } else if (ord == .lt) return MatchFail{
            .number_below_min = .{ .value = value.toF64(), .bound = mn.value, .unit = mn.unit },
        };
    }
    if (nb.max) |mx| {
        if (boundUnitMismatch(mx, value_unit)) return MatchFail{
            .numeric_bound_unit_mismatch = .{ .value_unit = value_unit, .bound_unit = mx.unit },
        };
        const ord = compareToBound(value, mx);
        if (nb.exclusive_max) {
            if (ord != .lt) return MatchFail{
                .number_at_or_above_exclusive_max = .{ .value = value.toF64(), .bound = mx.value, .unit = mx.unit },
            };
        } else if (ord == .gt) return MatchFail{
            .number_above_max = .{ .value = value.toF64(), .bound = mx.value, .unit = mx.unit },
        };
    }
    return null;
}

/// GPU-representation range / integrality check. Derives a closed
/// (min, max, integer) triple from the `Repr` enum and applies it like a
/// numeric bound, but reports a single `repr_out_of_range` whose `reason`
/// disambiguates non-integer from out-of-range. Integrality is checked
/// first so `70000.5` under `:repr u16` reads as "not an integer" rather
/// than "out of range". Range-only — precision narrowing is the emitter's
/// accepted lossy step. Used by both validator paths (`extras.numeric`
/// feeds the binary one), so the comparison stays in `NumericValue` space
/// to share the exact-int integrality test.
fn checkReprValue(value: NumericValue, repr: Plugin.ValueKind.Repr) ?MatchFail {
    const s = repr.spec();
    if (s.integer and !value.isInteger()) {
        return MatchFail{ .repr_out_of_range = .{ .value = value.toF64(), .repr = repr, .reason = .not_integer } };
    }
    const v = value.toF64();
    if (v < s.min or v > s.max) {
        return MatchFail{ .repr_out_of_range = .{ .value = value.toF64(), .repr = repr, .reason = .out_of_range } };
    }
    return null;
}

/// Run the value-side string-bounds checks: length first (cheapest,
/// deterministic), then `:format` (O(n) hand-written checker). Pattern
/// is the caller's concern — v1 builds emit `string_pattern_unsupported`
/// as a separate warning rather than running a regex, so this helper
/// never produces `string_pattern_mismatch`.
///
/// Returns the first failure in priority order, or null on match.
fn checkStringBoundsValue(
    text: []const u8,
    sb: Plugin.ValueKind.StringBounds,
) ?MatchFail {
    if (sb.min_len != null or sb.max_len != null) {
        const cp: u32 = blk: {
            const counted = std.unicode.utf8CountCodepoints(text) catch break :blk @intCast(text.len);
            break :blk @intCast(counted);
        };
        if (sb.min_len) |mn| if (cp < mn) return MatchFail{
            .string_too_short = .{ .got = cp, .min_len = mn },
        };
        if (sb.max_len) |mx| if (cp > mx) return MatchFail{
            .string_too_long = .{ .got = cp, .max_len = mx },
        };
    }
    if (sb.format) |fmt| {
        if (!StringFormats.check(fmt, text)) return MatchFail{
            .string_format_mismatch = .{ .got = text, .format = @tagName(fmt) },
        };
    }
    return null;
}

/// Returns null on match. On failure, returns a `MatchFail`. The caller
/// (validateFormKeys) emits at most one diagnostic per failed slot.
///
/// `tree_scope` is the default registration scope (the buffer's
/// `.tree(idx)`); `scope_chain` is the open lexical-scope chain. They
/// only matter at the cross-ref check inside `matchValueAgainstKind`.
fn matchValueAgainstType(
    a: Allocator,
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    expected: Plugin.ValueType,
    depth: u8,
) Allocator.Error!?MatchFail {
    const tag = tree.tagOf(idx);

    // Forms in typed slots: dispatch by what `expected` says.
    //
    // (a) `.form`-underlying ValueKind with a HeadSet: structural head
    //     narrowing (§7.4). Without a HeadSet the kind is "any form".
    // (b) `.form`, `.any`: accept any form.
    // (c) `.expr`: require the head to resolve to an expression.
    // (d) `.union_of` named: fall through so `matchValueAgainstKind`
    //     can try each alternative — alternatives may include a
    //     `.form`-underlying kind that accepts this form.
    // (e) Any other typed slot: resolve the form's declared expression
    //     result type and compare. Data forms in non-form slots are now
    //     a mismatch; opaque/unresolved expressions defer.
    if (tag == .form) {
        if (resolveFormHeadKind(schema, expected)) |kind| {
            if (kind.heads) |hs| {
                const head = tree.formHeader(idx).head;
                for (hs.names) |n| if (std.mem.eql(u8, n, head)) return null;
                return MatchFail{ .not_head_member = .{ .got = head, .allowed = hs.names } };
            }
            return null;
        }
        if (isAnyType(expected)) return null;
        const form_or_expr_handled: ?(?MatchFail) = blk: {
            switch (expected) {
                .form => break :blk @as(?MatchFail, null),
                .expr => {
                    const res = try resolveFormExpression(a, schema, tree, idx);
                    break :blk switch (res) {
                        .expr => @as(?MatchFail, null),
                        .data_form => @as(?MatchFail, MatchFail{ .wrong_underlying = typeLabel(expected) }),
                        .unresolved => @as(?MatchFail, null),
                    };
                },
                else => break :blk null,
            }
        };
        if (form_or_expr_handled) |v| return v;
        // For `.named` expected, defer to the union dispatch in
        // `matchValueAgainstKind` when the kind is `.union_of` — the
        // alternative loop may accept the form via a sibling kind.
        if (resolvesToUnion(schema, expected)) {
            // fall through to the switch below
        } else {
            const res = try resolveFormExpression(a, schema, tree, idx);
            return switch (res) {
                .unresolved => null,
                .data_form => MatchFail{ .wrong_underlying = typeLabel(expected) },
                .expr => |e| sub: {
                    const declared = e.result orelse break :sub null;
                    break :sub switch (declaredResultMatchesExpected(schema, declared, expected)) {
                        .yes, .unknown => null,
                        .no => MatchFail{ .wrong_underlying = typeLabel(expected) },
                    };
                },
            };
        }
    }

    return switch (expected) {
        .any => null,
        .number => switch (tag) {
            .number, .number_with_unit, .number_i64, .number_u64 => null,
            else => MatchFail{ .wrong_underlying = "number" },
        },
        .string => if (tag == .string) null else MatchFail{ .wrong_underlying = "string" },
        .symbol => if (tag == .symbol) null else MatchFail{ .wrong_underlying = "symbol" },
        .boolean => switch (tag) {
            .boolean_true, .boolean_false => null,
            else => MatchFail{ .wrong_underlying = "boolean" },
        },
        .nil => if (tag == .nil) null else MatchFail{ .wrong_underlying = "nil" },
        .vector => if (tag == .vector) null else MatchFail{ .wrong_underlying = "vector" },
        // Already returned null above for .form tag; reaching here means
        // the tag is something else — mismatch.
        .form, .expr => MatchFail{ .wrong_underlying = "form" },
        .named => |kind_ref| blk: {
            // Primitive shortcuts let `VectorShape.element` spell
            // `"number"`/`"string"`/… without needing a wrapper kind.
            if (resolvePrimitiveShortcut(kind_ref.name)) |vt| {
                break :blk try matchValueAgainstType(a, schema, cross_index, tree_scope, scope_chain, tree, idx, vt, depth);
            }
            const kind = switch (schema.lookupValueKind(kind_ref.name, kind_ref.namespace)) {
                .found => |k| k,
                .not_found => break :blk MatchFail{ .unknown_element_kind = .{
                    .name = kind_ref.name,
                    .namespace = kind_ref.namespace,
                } },
                .ambiguous => |amb| break :blk MatchFail{ .ambiguous_element_kind = .{
                    .name = kind_ref.name,
                    .claimants = try a.dupe(*const Plugin.Plugin, amb.slice()),
                } },
            };
            const next_depth = depth + 1;
            if (next_depth >= Schema.MAX_KIND_DEPTH) break :blk .recursion_depth;
            break :blk try matchValueAgainstKind(a, schema, cross_index, tree_scope, scope_chain, tree, idx, kind, next_depth);
        },
    };
}

fn resolvePrimitiveShortcut(name: []const u8) ?Plugin.ValueType {
    // `Plugin.primitive_type_names` is doubly-optional: the outer optional is
    // "is a catalog member", the inner is "resolves to a ValueType". `expr`
    // is a member with a null inner (see the catalog's doc), so both a miss
    // and `expr` flatten to null here — the `orelse null` is load-bearing.
    return Plugin.primitive_type_names.get(name) orelse null;
}

test "resolvePrimitiveShortcut: 8 names resolve; expr and unknowns are null" {
    // The name→ValueType shortcut. `expr` is a member of the primitive
    // type-name catalog (see Schema.isPrimitiveTypeName) but is deliberately
    // NOT resolved here — a `.named{"expr"}` reference must stay named rather
    // than collapse to the `.expr` primitive. Load-bearing asymmetry.
    try std.testing.expect(resolvePrimitiveShortcut("any").? == .any);
    try std.testing.expect(resolvePrimitiveShortcut("number").? == .number);
    try std.testing.expect(resolvePrimitiveShortcut("string").? == .string);
    try std.testing.expect(resolvePrimitiveShortcut("symbol").? == .symbol);
    try std.testing.expect(resolvePrimitiveShortcut("boolean").? == .boolean);
    try std.testing.expect(resolvePrimitiveShortcut("nil").? == .nil);
    try std.testing.expect(resolvePrimitiveShortcut("vector").? == .vector);
    try std.testing.expect(resolvePrimitiveShortcut("form").? == .form);
    try std.testing.expect(resolvePrimitiveShortcut("expr") == null);
    try std.testing.expect(resolvePrimitiveShortcut("color") == null);
    try std.testing.expect(resolvePrimitiveShortcut("") == null);
}

/// Resolve `expected` to a `.form`-underlying `ValueKind` if it is one;
/// returns null otherwise. Used by both the Tree and Binary paths to
/// gate the HeadSet narrowing on form values — the only structural
/// check applied to forms (which otherwise defer to runtime per §7.4).
/// Returns null on lookup miss / ambiguity / non-form underlying;
/// those concerns are handled elsewhere or left to runtime evaluation.
fn resolveFormHeadKind(
    schema: Schema.Schema,
    expected: Plugin.ValueType,
) ?*const Plugin.ValueKind {
    var current = expected;
    while (true) {
        switch (current) {
            .named => |ref| {
                if (resolvePrimitiveShortcut(ref.name)) |p| {
                    current = p;
                    continue;
                }
                switch (schema.lookupValueKind(ref.name, ref.namespace)) {
                    .found => |k| return if (k.underlying == .form) k else null,
                    else => return null,
                }
            },
            else => return null,
        }
    }
}

/// The scalar projection consumed by `matchScalar`. Both walkers build one
/// — the tree per typed slot (`fromTree`), the binary off the eval frame's
/// already-populated `MatchExtras` (`fromBinary`) — so the number / string /
/// symbol refinement logic (unit narrowing, numeric/repr bounds, string
/// members/bounds, symbol cross-ref/members) lives in exactly one place. The
/// `.form`, `.vector`, and `.union_of` underlyings stay per-path: they drive
/// walk bookkeeping (random-access recursion vs single-pass streaming) that
/// is deliberately NOT unified.
const ScalarView = struct {
    /// Coarse value kind. The tree projects its finer `Ast.Tag` via
    /// `toValueKind`; the binary's `view.kind` is already this vocabulary.
    kind: Ast.ValueKind,
    /// `.number_with_unit` unit suffix; null otherwise.
    unit: ?[]const u8 = null,
    /// String / symbol body. Read only after the tag gate confirms the
    /// matching underlying, so a null here on a wrong-tag value is never
    /// dereferenced.
    text: ?[]const u8 = null,
    /// Tag-true numeric value for `.number` / `.number_with_unit`.
    numeric: ?NumericValue = null,
    /// Reference-site span + node for cross-ref capture. The binary falls
    /// back to `ZERO_SPAN` / `.invalid` (spanless encodings; editors that
    /// need precise spans hold the source Tree alongside).
    ref_span: Ast.Span,
    ref_node_idx: Ast.NodeIndex,

    fn fromTree(tree: *const Ast.Tree, idx: Ast.NodeIndex) ScalarView {
        const tag = tree.tagOf(idx);
        var sv: ScalarView = .{
            .kind = tag.toValueKind(),
            .ref_span = tree.spanOf(idx),
            .ref_node_idx = idx,
        };
        switch (tag) {
            .number, .number_i64, .number_u64 => sv.numeric = readNumericValueTree(tree, idx, tag),
            .number_with_unit => {
                sv.unit = tree.numberWithUnitOf(idx).unit;
                sv.numeric = readNumericValueTree(tree, idx, tag);
            },
            .string => sv.text = tree.stringText(idx),
            .symbol => sv.text = tree.symbolText(idx),
            else => {},
        }
        return sv;
    }

    fn fromBinary(view: BinaryCursor.NodeView, extras: MatchExtras) ScalarView {
        return .{
            .kind = view.kind,
            .unit = extras.unit,
            .text = extras.text,
            .numeric = extras.numeric,
            .ref_span = view.span orelse ZERO_SPAN,
            .ref_node_idx = .invalid,
        };
    }
};

/// Shared refinement matcher for the number / string / symbol axes (plus the
/// symbol cross-ref block). `kind.underlying` MUST be one of those three —
/// the callers (`matchValueAgainstKind` on the tree, `matchKindBinary` on the
/// binary) dispatch the structural `.form` / `.vector` / `.union_of`
/// underlyings themselves, since those recurse and the two walkers recurse
/// differently. Returns null on match, else the first `MatchFail`. Scalars
/// never spawn an element walk, so the caller wraps the result in a bare
/// `MatchResult` (binary) or returns it directly (tree).
fn matchScalar(
    a: Allocator,
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    kind: *const Plugin.ValueKind,
    sv: ScalarView,
) Allocator.Error!?MatchFail {
    const tag = sv.kind;
    switch (kind.underlying) {
        .number => {
            std.debug.assert(kind.members == null);
            // Step 1: unit-shape narrowing. A wrong tag (string in a number
            // slot) short-circuits with wrong_underlying; a unit mismatch
            // fires unit_required / unit_not_allowed and skips the bound
            // check below — wrong units are upstream of wrong magnitudes.
            const unit_fail: ?MatchFail = switch (tag) {
                .number => sub: {
                    if (kind.unit) |u| if (u.required) break :sub @as(?MatchFail, .{ .unit_missing = u.allowed });
                    break :sub @as(?MatchFail, null);
                },
                .number_with_unit => sub: {
                    if (kind.unit) |u| {
                        const got = sv.unit.?;
                        // `:reject` forbids *any* unit — bare numbers only.
                        // Checked before the allowed-list narrowing (the two
                        // are mutually exclusive at load time, but reject wins
                        // if both slip through) so the message names no set.
                        if (u.reject) break :sub @as(?MatchFail, .{ .unit_forbidden = got });
                        if (u.allowed.len != 0) {
                            var ok: bool = false;
                            for (u.allowed) |w| if (std.mem.eql(u8, w, got)) {
                                ok = true;
                                break;
                            };
                            if (!ok) break :sub @as(?MatchFail, .{ .unit_wrong = .{ .got = got, .allowed = u.allowed } });
                        }
                    }
                    break :sub @as(?MatchFail, null);
                },
                else => return MatchFail{ .wrong_underlying = "number" },
            };
            if (unit_fail) |f| return f;
            // Step 2: numeric-bounds narrowing. Runs only when the kind
            // opted in and the view carries a tag-true numeric value (the
            // eval frame / tree reader populates it exact for i64 / u64).
            if (kind.numeric) |nb| if (sv.numeric) |v| {
                if (checkNumericBoundsValue(v, sv.unit, nb)) |f| return f;
            };
            // Step 3: repr narrowing (GPU representation range/integrality).
            // Orthogonal to :numeric — both may be set; each checked
            // independently. The unit suffix (if any) is irrelevant to the
            // magnitude, so the bare numeric view is enough.
            if (kind.repr) |r| if (sv.numeric) |v| {
                if (checkReprValue(v, r)) |f| return f;
            };
            return null;
        },
        .string => {
            if (tag != .string) return MatchFail{ .wrong_underlying = "string" };
            if (kind.members) |m| {
                if (m.members.len != 0) {
                    const got = sv.text.?;
                    var matched: bool = false;
                    for (m.members) |v| if (std.mem.eql(u8, v.name, got)) {
                        matched = true;
                        break;
                    };
                    if (!matched) return MatchFail{ .not_member = .{ .got = got, .allowed = m.members } };
                }
            }
            if (kind.string_bounds) |sb| {
                if (checkStringBoundsValue(sv.text.?, sb)) |f| return f;
            }
            return null;
        },
        .symbol => {
            if (tag != .symbol) return MatchFail{ .wrong_underlying = "symbol" };
            if (kind.cross_ref) |cr| {
                const got = sv.text.?;
                // Which key the reader should be looking at, decided once
                // from the spec so all three exits below agree.
                const route: @FieldType(@FieldType(MatchFail, "not_cross_ref"), "route") =
                    if (cr.provider != null) .provider else .identity;
                const decl_key = if (cr.provider != null) cr.source_key else cr.name_key;
                const canonical = (try schema.canonicalFormName(a, cr.target_form)) orelse {
                    // Schema-aggregate phase already emitted unknown/ambiguous
                    // diagnostics for this; treat as unresolved so the symbol
                    // doesn't masquerade as a valid reference.
                    return MatchFail{ .not_cross_ref = .{ .got = got, .target = cr.target_form, .key = decl_key, .route = route } };
                };
                // Resolve which scope to search: nearest enclosing instance
                // of `:scope <form>` if specified; otherwise tree scope.
                const lookup_scope: ScopeId = if (cr.scope_form) |sf| sub: {
                    const scope_canonical = (try schema.canonicalFormName(a, sf)) orelse {
                        return MatchFail{ .not_cross_ref = .{ .got = got, .target = canonical, .key = decl_key, .route = route } };
                    };
                    break :sub findNearestScope(scope_chain, scope_canonical) orelse {
                        return MatchFail{ .cross_ref_outside_scope = .{ .got = got, .scope_form = scope_canonical } };
                    };
                } else tree_scope;
                // Capture the reference site (LSP find-refs/rename consumes
                // this). Done before the contains check so typo'd references
                // are still recorded — the editor wants to surface them too.
                // The binary view supplies ZERO_SPAN / `.invalid` when the
                // buffer was encoded without spans.
                try cross_index.appendReference(lookup_scope, canonical, got, .{
                    .tree_idx = tree_scope.treeIdx(),
                    .node_idx = sv.ref_node_idx,
                    .form_span = sv.ref_span,
                    .name_span = sv.ref_span,
                    .scope = lookup_scope,
                });
                if (cross_index.contains(lookup_scope, canonical, got)) return null;
                // A poisoned bucket is one whose member set could not be
                // computed — the provider failed or never ran, and that
                // already produced its own root-cause diagnostic at the
                // source. Accept, after the capture above: the reference
                // is still a site for the LSP, it just isn't checkable.
                if (cross_index.isPoisoned(lookup_scope, canonical)) return null;
                return MatchFail{ .not_cross_ref = .{ .got = got, .target = canonical, .key = decl_key, .route = route } };
            }
            if (kind.members) |m| {
                if (m.members.len == 0) return null;
                const got = sv.text.?;
                for (m.members) |v| if (std.mem.eql(u8, v.name, got)) return null;
                return MatchFail{ .not_member = .{ .got = got, .allowed = m.members } };
            }
            return null;
        },
        // Structural underlyings are dispatched by the callers (they recurse
        // path-specifically); matchScalar is only ever reached for scalars.
        .form, .vector, .union_of => unreachable,
    }
}

fn matchValueAgainstKind(
    a: Allocator,
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    kind: *const Plugin.ValueKind,
    depth: u8,
) Allocator.Error!?MatchFail {
    const tag = tree.tagOf(idx);
    return switch (kind.underlying) {
        .number, .string, .symbol => try matchScalar(a, schema, cross_index, tree_scope, scope_chain, kind, ScalarView.fromTree(tree, idx)),
        .form => blk: {
            std.debug.assert(kind.members == null);
            if (tag != .form) break :blk MatchFail{ .wrong_underlying = "form" };
            if (kind.heads) |hs| {
                const head = tree.formHeader(idx).head;
                for (hs.names) |n| if (std.mem.eql(u8, n, head)) break :blk null;
                break :blk MatchFail{ .not_head_member = .{ .got = head, .allowed = hs.names } };
            }
            break :blk null;
        },
        .vector => blk: {
            std.debug.assert(kind.members == null);
            if (tag != .vector) break :blk MatchFail{ .wrong_underlying = "vector" };
            if (kind.vector) |vs| {
                const elements = tree.vectorElements(idx);
                if (vs.len) |want| {
                    if (elements.len != want) break :blk MatchFail{
                        .wrong_vector_len = .{ .want = want, .got = @intCast(elements.len) },
                    };
                }
                if (vs.min_len) |mn| {
                    if (elements.len < mn) break :blk MatchFail{
                        .vector_too_short = .{ .got = @intCast(elements.len), .min_len = mn },
                    };
                }
                if (vs.max_len) |mx| {
                    if (elements.len > mx) break :blk MatchFail{
                        .vector_too_long = .{ .got = @intCast(elements.len), .max_len = mx },
                    };
                }
                const elem_type: Plugin.ValueType = .{ .named = vs.element };
                for (elements, 0..) |el_idx, i| {
                    const inner = try matchValueAgainstType(a, schema, cross_index, tree_scope, scope_chain, tree, el_idx, elem_type, depth);
                    if (inner) |f| {
                        const owned = try a.create(MatchFail);
                        owned.* = f;
                        break :blk MatchFail{ .element_at = .{ .index = i, .fail = owned, .leaf = el_idx } };
                    }
                }
            }
            break :blk null;
        },
        .union_of => blk: {
            const us = kind.union_of orelse break :blk MatchFail{ .wrong_underlying = "union" };
            // Try alternatives in declaration order; first match wins.
            // Depth is unchanged — the union itself is a one-step
            // indirection, alternatives consume their own budget when
            // they recurse via `matchValueAgainstType`.
            //
            // Probing runs against a capture-suppressed view of the index:
            // a cross-ref alternative records a reference site *before*
            // checking `contains` (deliberate, so typo'd references still
            // reach find-refs), and in a union that means every rejected
            // alternative left its capture behind. A symbol matching the
            // `members` half of `union{members, ref-kind}` was registered
            // as a reference to the ref-kind anyway, polluting rename and
            // find-refs with sites that are not references at all. Only
            // the accepted alternative's captures should land, so the
            // winner is re-run with capture enabled.
            //
            // The suppressed view is a shallow copy with `arena` nulled:
            // `appendReference` returns early on that, while `contains`
            // and every lookup still read the real maps.
            var probe = cross_index.*;
            probe.arena = null;
            for (us.alternatives) |alt_name| {
                const alt_type: Plugin.ValueType = .{ .named = alt_name };
                const inner = try matchValueAgainstType(a, schema, &probe, tree_scope, scope_chain, tree, idx, alt_type, depth);
                if (inner == null) {
                    _ = try matchValueAgainstType(a, schema, cross_index, tree_scope, scope_chain, tree, idx, alt_type, depth);
                    break :blk null;
                }
            }
            // Nothing accepted: there is no winner to pollute, and the
            // symbol really might be a typo'd reference — which find-refs
            // and rename want to see. Re-run with capture on so that
            // behaviour is unchanged for the case it was written for.
            for (us.alternatives) |alt_name| {
                _ = try matchValueAgainstType(a, schema, cross_index, tree_scope, scope_chain, tree, idx, .{ .named = alt_name }, depth);
            }
            break :blk MatchFail{ .union_no_branch_matched = .{
                .got_label = nodeTagLabel(tag),
                .alternatives = us.alternatives,
            } };
        },
    };
}

/// Short user-facing label for a node tag, used in the
/// `union_no_branch_matched` diagnostic. Mirrors `describeNode`'s
/// vocabulary but returns a static string (no allocation needed for
/// the simple cases — `number_with_unit` and `vector` lose their
/// payload here, since the union diagnostic just names the category).
fn nodeTagLabel(tag: Ast.Tag) []const u8 {
    return switch (tag) {
        .number, .number_with_unit, .number_i64, .number_u64 => "number",
        .string => "string",
        .keyword => "keyword",
        .symbol => "symbol",
        .boolean_true, .boolean_false => "boolean",
        .nil => "nil",
        .date => "date",
        .time => "time",
        .vector => "vector",
        .form => "form",
        .kvpair => "keyword pair",
    };
}

// ---------------------------------------------------------------------------
// Slot-type diagnostics
// ---------------------------------------------------------------------------

/// Shared prefix for a type-mismatch message: `<noun> `<form>` <slot> expects
/// <type>, ` — identical on the tree and binary walkers. The caller appends
/// the per-path failure description and emits.
fn writeSlotPrefix(
    a: Allocator,
    buf: *std.ArrayList(u8),
    form_name: []const u8,
    slot: Slot,
    expected: Plugin.ValueType,
) Allocator.Error!void {
    const noun: []const u8 = switch (slot) {
        .positional, .key => "form",
        .expr_arg => "expression",
    };
    try buf.appendSlice(a, noun);
    try buf.appendSlice(a, " `");
    try buf.appendSlice(a, form_name);
    try buf.appendSlice(a, "` ");
    switch (slot) {
        .positional => try buf.appendSlice(a, "positional argument"),
        .key => |k| {
            try buf.appendSlice(a, "keyword `:");
            try buf.appendSlice(a, k);
            try buf.appendSlice(a, "`");
        },
        .expr_arg => |i| {
            try buf.appendSlice(a, "argument ");
            const piece = try std.fmt.allocPrint(a, "{d}", .{i});
            try buf.appendSlice(a, piece);
        },
    }
    try buf.appendSlice(a, " expects ");
    try describeType(a, buf, expected);
    try buf.appendSlice(a, ", ");
}

/// Slot role determines the code: expression positional args take the
/// dedicated `expr_type_mismatch` code (so consumers can split typed-
/// signature failures from kvpair-value failures); kvpair / positional
/// slots derive their code from the underlying `MatchFail` variant. Shared
/// by both type-mismatch emitters.
fn slotMismatchCode(slot: Slot, fail: MatchFail) Diagnostic.Code {
    return switch (slot) {
        .expr_arg => .expr_type_mismatch,
        .positional, .key => matchFailToCode(fail),
    };
}

fn emitTypeMismatch(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    tree: *const Ast.Tree,
    value_idx: Ast.NodeIndex,
    path: []const []const u8,
    form_name: []const u8,
    slot: Slot,
    expected: Plugin.ValueType,
    fail: MatchFail,
) Allocator.Error!void {
    var buf: std.ArrayList(u8) = .empty;
    try writeSlotPrefix(a, &buf, form_name, slot, expected);
    try describeFail(a, &buf, tree, value_idx, fail);
    try emit(a, diags, tree.spanOf(value_idx), path, .err, slotMismatchCode(slot, fail), try buf.toOwnedSlice(a));
}

/// Render a `ValueType` as a short user-facing label. `noinline` because
/// every call lives on the diagnostic path — keeping it out of line lets
/// the validator's hot loop stay tight.
noinline fn describeType(
    a: Allocator,
    buf: *std.ArrayList(u8),
    expected: Plugin.ValueType,
) Allocator.Error!void {
    switch (expected) {
        .any => try buf.appendSlice(a, "any value"),
        .number => try buf.appendSlice(a, "number"),
        .string => try buf.appendSlice(a, "string"),
        .symbol => try buf.appendSlice(a, "symbol"),
        .boolean => try buf.appendSlice(a, "boolean"),
        .nil => try buf.appendSlice(a, "nil"),
        .vector => try buf.appendSlice(a, "vector"),
        .form => try buf.appendSlice(a, "form"),
        .expr => try buf.appendSlice(a, "expression"),
        .named => |n| {
            try buf.appendSlice(a, "`");
            if (n.namespace) |ns| {
                try buf.appendSlice(a, ns);
                try buf.appendSlice(a, "/");
            }
            try buf.appendSlice(a, n.name);
            try buf.appendSlice(a, "`");
        },
    }
}

/// Render the actual node's tag/payload as a short label. Used by
/// `describeFail` to say e.g. "got vector of length 2".
fn describeNode(
    a: Allocator,
    buf: *std.ArrayList(u8),
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) Allocator.Error!void {
    switch (tree.tagOf(idx)) {
        .number, .number_i64, .number_u64 => try buf.appendSlice(a, "number"),
        .number_with_unit => {
            const nu = tree.numberWithUnitOf(idx);
            try buf.appendSlice(a, "number with unit `");
            try buf.appendSlice(a, nu.unit);
            try buf.appendSlice(a, "`");
        },
        .string => try buf.appendSlice(a, "string"),
        .keyword => try buf.appendSlice(a, "keyword"),
        .symbol => try buf.appendSlice(a, "symbol"),
        .boolean_true, .boolean_false => try buf.appendSlice(a, "boolean"),
        .nil => try buf.appendSlice(a, "nil"),
        .date => try buf.appendSlice(a, "date"),
        .time => try buf.appendSlice(a, "time"),
        .vector => {
            const elems = tree.vectorElements(idx);
            const piece = try std.fmt.allocPrint(a, "vector of length {d}", .{elems.len});
            try buf.appendSlice(a, piece);
        },
        .form => try buf.appendSlice(a, "form"),
        .kvpair => try buf.appendSlice(a, "keyword pair"),
    }
}

fn describeFail(
    a: Allocator,
    buf: *std.ArrayList(u8),
    tree: *const Ast.Tree,
    leaf: Ast.NodeIndex,
    fail: MatchFail,
) Allocator.Error!void {
    switch (fail) {
        // Per-path: render the offending node from the tree.
        .wrong_underlying => {
            try buf.appendSlice(a, "got ");
            try describeNode(a, buf, tree, leaf);
        },
        // Per-path: recurse into the nested element failure (the binary path
        // emits per-element instead and never wraps).
        .element_at => |e| {
            const piece = try std.fmt.allocPrint(a, "element [{d}]: ", .{e.index});
            try buf.appendSlice(a, piece);
            try describeFail(a, buf, tree, e.leaf, e.fail.*);
        },
        else => try describeFailCommon(a, buf, fail),
    }
}

/// The type-mismatch failure arms that depend only on the `MatchFail`
/// payload — byte-identical between the tree and binary walkers. The two
/// per-path arms (`.wrong_underlying`, which renders the offending node, and
/// `.element_at`, which the tree recurses and the binary path never reaches)
/// are handled by the callers before delegating here.
fn describeFailCommon(
    a: Allocator,
    buf: *std.ArrayList(u8),
    fail: MatchFail,
) Allocator.Error!void {
    switch (fail) {
        .wrong_underlying, .element_at => unreachable, // caller-handled (per-path)
        .wrong_vector_len => |w| {
            const piece = try std.fmt.allocPrint(a, "got vector of length {d}", .{w.got});
            try buf.appendSlice(a, piece);
        },
        .vector_too_short => |v| {
            const piece = try std.fmt.allocPrint(a, "got vector of length {d}, below :min-len {d}", .{ v.got, v.min_len });
            try buf.appendSlice(a, piece);
        },
        .vector_too_long => |v| {
            const piece = try std.fmt.allocPrint(a, "got vector of length {d}, above :max-len {d}", .{ v.got, v.max_len });
            try buf.appendSlice(a, piece);
        },
        .unit_missing => |allowed| {
            try buf.appendSlice(a, "got number without unit");
            try writeAllowedList(a, buf, allowed);
        },
        .unit_wrong => |w| {
            try buf.appendSlice(a, "got number with unit `");
            try buf.appendSlice(a, w.got);
            try buf.appendSlice(a, "`");
            try writeAllowedList(a, buf, w.allowed);
        },
        .unit_forbidden => |got| {
            try buf.appendSlice(a, "got number with unit `");
            try buf.appendSlice(a, got);
            try buf.appendSlice(a, "` (slot rejects units — bare number required)");
        },
        .not_member => |w| {
            try buf.appendSlice(a, "got `");
            try buf.appendSlice(a, w.got);
            try buf.appendSlice(a, "`");
            try writeAllowedMembers(a, buf, w.allowed);
        },
        .not_head_member => |w| {
            try buf.appendSlice(a, "got form head `");
            try buf.appendSlice(a, w.got);
            try buf.appendSlice(a, "`");
            try writeAllowedHeads(a, buf, w.allowed);
        },
        .unknown_element_kind => |w| try writeUnknownElementKind(a, buf, w.name, w.namespace),
        .ambiguous_element_kind => |k| try writeAmbiguousElementKind(a, buf, k.name, k.claimants),
        .recursion_depth => {
            try buf.appendSlice(a, "value kind chain too deep");
        },
        .not_cross_ref => |w| {
            // Name the key the member set is actually drawn from, and say
            // which way it is drawn. The two routes send the reader to
            // different places: add a declaration with that `:key`, or
            // edit the string under it until the provider finds the name
            // inside. A message that always said `:name` would send the
            // provider route's reader to write a declaration that
            // registers nothing.
            try buf.appendSlice(a, "got `");
            try buf.appendSlice(a, w.got);
            try buf.appendSlice(a, "` (no `(");
            try buf.appendSlice(a, w.target);
            try buf.appendSlice(a, " :");
            try buf.appendSlice(a, w.key);
            try buf.appendSlice(a, " …)` ");
            try buf.appendSlice(a, switch (w.route) {
                .identity => "form declares this name",
                .provider => "source provides this name",
            });
            try buf.appendSlice(a, ")");
        },
        .cross_ref_outside_scope => |w| {
            try buf.appendSlice(a, "got `");
            try buf.appendSlice(a, w.got);
            try buf.appendSlice(a, "` outside any enclosing `(");
            try buf.appendSlice(a, w.scope_form);
            try buf.appendSlice(a, " …)` — this cross-ref is `:scope`-bound");
        },
        .union_no_branch_matched => |u| {
            try buf.appendSlice(a, "got ");
            try buf.appendSlice(a, u.got_label);
            try buf.appendSlice(a, " (no alternative matched: ");
            for (u.alternatives, 0..) |alt, i| {
                if (i > 0) try buf.appendSlice(a, " | ");
                try buf.appendSlice(a, "`");
                if (alt.namespace) |ns| {
                    try buf.appendSlice(a, ns);
                    try buf.appendSlice(a, "/");
                }
                try buf.appendSlice(a, alt.name);
                try buf.appendSlice(a, "`");
            }
            try buf.appendSlice(a, ")");
        },
        .number_below_min => |nf| try writeNumericFail(a, buf, "below minimum", nf),
        .number_above_max => |nf| try writeNumericFail(a, buf, "above maximum", nf),
        .number_at_or_below_exclusive_min => |nf| try writeNumericFail(a, buf, "must be strictly greater than", nf),
        .number_at_or_above_exclusive_max => |nf| try writeNumericFail(a, buf, "must be strictly less than", nf),
        .number_not_integer => |v| {
            const piece = try std.fmt.allocPrint(a, "value {d} is not an integer", .{v});
            try buf.appendSlice(a, piece);
        },
        .numeric_bound_unit_mismatch => |m| {
            try buf.appendSlice(a, "value unit ");
            try writeUnitOrNone(a, buf, m.value_unit);
            try buf.appendSlice(a, " does not match bound unit ");
            try writeUnitOrNone(a, buf, m.bound_unit);
        },
        .repr_out_of_range => |r| try writeReprFail(a, buf, r),
        .string_too_short => |s| {
            const piece = try std.fmt.allocPrint(
                a,
                "string length {d} is below :min-len {d}",
                .{ s.got, s.min_len },
            );
            try buf.appendSlice(a, piece);
        },
        .string_too_long => |s| {
            const piece = try std.fmt.allocPrint(
                a,
                "string length {d} is above :max-len {d}",
                .{ s.got, s.max_len },
            );
            try buf.appendSlice(a, piece);
        },
        .string_format_mismatch => |s| {
            const piece = try std.fmt.allocPrint(
                a,
                "string \"{s}\" does not satisfy :format `{s}`",
                .{ s.got, s.format },
            );
            try buf.appendSlice(a, piece);
        },
        .string_pattern_mismatch => |s| {
            const piece = try std.fmt.allocPrint(
                a,
                "string \"{s}\" does not match :pattern `{s}`",
                .{ s.got, s.pattern },
            );
            try buf.appendSlice(a, piece);
        },
    }
}

fn writeNumericFail(
    a: Allocator,
    buf: *std.ArrayList(u8),
    relation: []const u8,
    nf: MatchFail.NumericFail,
) Allocator.Error!void {
    const piece = try std.fmt.allocPrint(a, "value {d} {s} {d}", .{ nf.value, relation, nf.bound });
    try buf.appendSlice(a, piece);
    if (nf.unit) |u| {
        try buf.appendSlice(a, u);
    }
}

/// Render a `repr_out_of_range` payload. `reason` disambiguates the two
/// failure modes; `@tagName(rf.repr)` yields the bare GPU type name
/// (`"f32"` … `"f16"`). Shared by both `describeFail` renderers.
fn writeReprFail(
    a: Allocator,
    buf: *std.ArrayList(u8),
    rf: anytype,
) Allocator.Error!void {
    const piece = switch (rf.reason) {
        .not_integer => try std.fmt.allocPrint(
            a,
            "value {d} is not an integer — :repr `{s}` requires a whole number",
            .{ rf.value, @tagName(rf.repr) },
        ),
        .out_of_range => try std.fmt.allocPrint(
            a,
            "value {d} is out of range for :repr `{s}`",
            .{ rf.value, @tagName(rf.repr) },
        ),
    };
    try buf.appendSlice(a, piece);
}

fn writeUnitOrNone(
    a: Allocator,
    buf: *std.ArrayList(u8),
    unit: ?[]const u8,
) Allocator.Error!void {
    if (unit) |u| {
        try buf.appendSlice(a, "`");
        try buf.appendSlice(a, u);
        try buf.appendSlice(a, "`");
    } else {
        try buf.appendSlice(a, "(none)");
    }
}

/// After a successful symbol/string match against a typed slot, check
/// whether the matched member carries `deprecated = true` and, if so,
/// emit a `deprecated_member` warning at the value's span.
///
/// `expected` is the slot's declared `ValueType`; only `.named` types
/// resolving to a member-set kind can fire the warning. Other shapes
/// return without work. `text` is the byte-equal name the validator
/// just matched (caller already extracted it from the tree / cursor).
///
/// Severity is `.warning` so validation as a whole still succeeds; the
/// caller does not need to alter its control flow.
fn emitDeprecatedMemberCore(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    schema: Schema.Schema,
    text: []const u8,
    expected: Plugin.ValueType,
    span: Ast.Span,
    path: []const []const u8,
) Allocator.Error!void {
    const ref = switch (expected) {
        .named => |n| n,
        else => return,
    };
    const kind = switch (schema.lookupValueKind(ref.name, ref.namespace)) {
        .found => |k| k,
        else => return,
    };
    const m = kind.members orelse return;
    if (m.members.len == 0) return;
    for (m.members) |mem| {
        if (!std.mem.eql(u8, mem.name, text)) continue;
        if (!mem.deprecated) return;
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(a, "member `");
        try buf.appendSlice(a, mem.name);
        try buf.appendSlice(a, "` is deprecated");
        if (mem.deprecation_message.len > 0) {
            try buf.appendSlice(a, ": ");
            try buf.appendSlice(a, mem.deprecation_message);
        }
        try emit(a, diags, span, path, .warning, .deprecated_member, try buf.toOwnedSlice(a));
        return;
    }
}

/// Tree-path wrapper: extracts the symbol/string text from `idx` and
/// delegates to `emitDeprecatedMemberCore`. No-op when the node isn't
/// a symbol or string.
fn emitDeprecatedMemberTree(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    schema: Schema.Schema,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    expected: Plugin.ValueType,
    path: []const []const u8,
) Allocator.Error!void {
    const text: []const u8 = switch (tree.tagOf(idx)) {
        .symbol => tree.symbolText(idx),
        .string => tree.stringText(idx),
        else => return,
    };
    try emitDeprecatedMemberCore(a, diags, schema, text, expected, tree.spanOf(idx), path);
}

/// After a successful string-typed match against a typed slot whose
/// kind declares `:string-bounds :pattern …`, emit a
/// `string_pattern_unsupported` warning. v1 builds carry no regex
/// engine; the pattern is stored but not enforced, and authors should
/// know their constraint is informational only.
///
/// Emission happens at the value's span, with the same path used for
/// any deprecated-member warning at the same site. Severity is
/// `.warning` so validation as a whole still succeeds. v1 emits once
/// per value site (no per-pass dedup); the engine milestone will
/// either start enforcing `:pattern` or add dedup, depending on the
/// chosen engine's cost profile.
fn emitStringPatternUnsupportedCore(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    schema: Schema.Schema,
    expected: Plugin.ValueType,
    span: Ast.Span,
    path: []const []const u8,
) Allocator.Error!void {
    const ref = switch (expected) {
        .named => |n| n,
        else => return,
    };
    const kind = switch (schema.lookupValueKind(ref.name, ref.namespace)) {
        .found => |k| k,
        else => return,
    };
    if (kind.underlying != .string) return;
    const sb = kind.string_bounds orelse return;
    const pat = sb.pattern orelse return;
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "value-kind `");
    try buf.appendSlice(a, kind.name);
    try buf.appendSlice(a, "` declares `:pattern \"");
    try buf.appendSlice(a, pat);
    try buf.appendSlice(a, "\"` but this build has no regex engine — constraint is informational only");
    try emit(a, diags, span, path, .warning, .string_pattern_unsupported, try buf.toOwnedSlice(a));
}

fn emitStringPatternUnsupportedTree(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    schema: Schema.Schema,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    expected: Plugin.ValueType,
    path: []const []const u8,
) Allocator.Error!void {
    if (tree.tagOf(idx) != .string) return;
    try emitStringPatternUnsupportedCore(a, diags, schema, expected, tree.spanOf(idx), path);
}

fn writeAllowedList(
    a: Allocator,
    buf: *std.ArrayList(u8),
    allowed: []const []const u8,
) Allocator.Error!void {
    if (allowed.len == 0) return;
    try buf.appendSlice(a, " (allowed: ");
    for (allowed, 0..) |u, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, "`");
        try buf.appendSlice(a, u);
        try buf.appendSlice(a, "`");
    }
    try buf.appendSlice(a, ")");
}

/// Render a `MemberSet`'s entries as the "(allowed: a, b, c)" suffix.
/// Mirrors `writeAllowedList` but reads `.name` off each `Member` so the
/// `not_member` diagnostic doesn't need to pre-project the kind's
/// member slice into a flat `[]const []const u8`.
fn writeAllowedMembers(
    a: Allocator,
    buf: *std.ArrayList(u8),
    allowed: []const Plugin.ValueKind.MemberSet.Member,
) Allocator.Error!void {
    if (allowed.len == 0) return;
    try buf.appendSlice(a, " (allowed: ");
    for (allowed, 0..) |m, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, "`");
        try buf.appendSlice(a, m.name);
        try buf.appendSlice(a, "`");
    }
    try buf.appendSlice(a, ")");
}

/// Render a `HeadSet`-style allowed list using the OpenAPI alternation
/// pattern (`[a | b | c]`), distinguishing it visually from the
/// member-set list (`(allowed: a, b, c)`). Heads name forms, not
/// scalar values, and the alternation reads more naturally as
/// "one of these heads."
fn writeAllowedHeads(
    a: Allocator,
    buf: *std.ArrayList(u8),
    allowed: []const []const u8,
) Allocator.Error!void {
    if (allowed.len == 0) return;
    try buf.appendSlice(a, " not in set [");
    for (allowed, 0..) |u, i| {
        if (i > 0) try buf.appendSlice(a, " | ");
        try buf.appendSlice(a, u);
    }
    try buf.appendSlice(a, "]");
}

/// Render `unknown value kind \`<ns>/<name>\`` (or bare when namespace
/// is null). Shared between the tree- and binary-path renderers so the
/// surface text stays diagnostic-equal across both validators.
fn writeUnknownElementKind(
    a: Allocator,
    buf: *std.ArrayList(u8),
    name: []const u8,
    namespace: ?[]const u8,
) Allocator.Error!void {
    try buf.appendSlice(a, "unknown value kind `");
    if (namespace) |ns| {
        try buf.appendSlice(a, ns);
        try buf.appendSlice(a, "/");
    }
    try buf.appendSlice(a, name);
    try buf.appendSlice(a, "`");
}

/// Render `value kind \`<name>\` is ambiguous — defined by [a, b]; qualify
/// with \`<plugin>/<name>\``. The hint mirrors the schema-build-time
/// emitter for forms/expr-funcs so the user sees the same recovery
/// instruction regardless of which phase raised the diagnostic.
fn writeAmbiguousElementKind(
    a: Allocator,
    buf: *std.ArrayList(u8),
    name: []const u8,
    claimants: []const *const Plugin.Plugin,
) Allocator.Error!void {
    try buf.appendSlice(a, "value kind `");
    try buf.appendSlice(a, name);
    try buf.appendSlice(a, "` is ambiguous — defined by [");
    for (claimants, 0..) |p, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, p.name);
    }
    try buf.appendSlice(a, "]");
    if (claimants.len > 0) {
        try buf.appendSlice(a, "; qualify with `");
        try buf.appendSlice(a, claimants[0].name);
        try buf.appendSlice(a, "/");
        try buf.appendSlice(a, name);
        try buf.appendSlice(a, "`");
    }
}

// ---------------------------------------------------------------------------
// Streaming validator over Binary IR (via BinaryCursor)
//
// Mirrors validate's per-form / per-key checks but reads bytes through a
// single-pass cursor — no intermediate `Tree` is built. Eliminating
// `Binary.fromBinary` from the validator's call graph lets DCE strip the
// tree-builder code path from `sjon-binary.wasm`.
//
// Type-check and recursion are FUSED. The cursor is monotonic, so we
// cannot do tree-validator's two passes (slot-check via random access,
// then re-walk for recursion). Instead, each `eval` frame carries an
// `expected: ValueType`, an optional `slot_ctx`, and a kind-resolution
// `depth`; the type check happens inline as we descend, and the resolved
// element type propagates into nested `vector_walk` frames.
//
// Because the check is per-element, a typed-vector failure is DETECTED at
// the element rather than at the outer slot. To keep the diagnostic
// identical to `validate`, the outer slot's framing (span, path, expected-
// type label, form/slot identity) is threaded down through the
// `vector_walk` frames as an `OuterVecCtx`; when an element fails, the emit
// reconstructs the tree walker's "form X expects mat4, element [3]: got
// vector of length 3" at the outer slot's span — same message, span, path,
// and code on both walkers (see B.9). The one intentional exception is a
// `.union_of` slot that accepts a vector alternative: there the tree arm
// collapses to `union_no_branch_matched` at the slot and the binary path
// keeps its per-element divergence (union-div #2 in the tests).
// ---------------------------------------------------------------------------

const MAX_VALIDATE_FRAMES: u32 = 1024;
const MAX_VALIDATE_STEPS: u32 = 1024 * 1024;

/// The two ceilings the binary-side walkers enforce, carried together so a
/// test can lower one without building a document large enough to reach the
/// production value. Same shape as `Expr.Budget` and `PatternQuery.Budget`,
/// for the same reason: without a seam neither `error.DepthExceeded` arm has
/// ever executed, and deleting a guard passes every gate.
///
/// Note which walkers these bound. Both `validateOneBinary` and the
/// cross-index pass are *streaming* — a form's children arrive through a
/// cursor iterator, so live frames track nesting depth, not width. The tree
/// walker in `validateOneTree` is deliberately not bounded by either: it
/// pushes a frame per child up-front, so `MAX_VALIDATE_FRAMES` would reject
/// a merely *wide* document that the binary path accepts, and it needs no
/// ceiling anyway — every node is pushed exactly once by its parent, so the
/// walk is bounded by the tree the parser already bounded.
pub const Budget = struct {
    steps: u32 = MAX_VALIDATE_STEPS,
    frames: u32 = MAX_VALIDATE_FRAMES,
};

const ZERO_SPAN: Ast.Span = .{ .start = 0, .end = 0 };

/// Form / slot identifier used to format type-mismatch diagnostics.
/// Carried alongside `expected` through nested `vector_walk` frames so a
/// failure at any nesting level can still name the originating slot.
const SlotCtx = struct {
    form_name: []const u8,
    slot: Slot,
};

/// Framing of the outermost enclosing typed-`.vector` slot, threaded down
/// through nested `vector_walk` frames so a type failure at any element
/// depth reports against that slot — same span, path, expected-type label,
/// and diagnostic code the Tree walker produces via its `element_at` wrap.
///
/// Set only when the outer slot's `expected` resolves to a direct `.vector`
/// kind (the case the Tree arm wraps). A `.union_of` slot that happens to
/// accept a vector alternative deliberately leaves this null — the Tree arm
/// collapses union failures to `union_no_branch_matched` at the slot, and
/// the binary path keeps its documented per-element divergence there.
const OuterVecCtx = struct {
    /// The outermost slot's declared type (e.g. `mat4`), so the message
    /// names the container, not the element kind.
    expected: Plugin.ValueType,
    /// The outermost vector's span — where the diagnostic points.
    span: Ast.Span,
    /// The outermost slot's diag path (no element-index steps).
    path: []const []const u8,
    /// Form/slot identity for the message prefix.
    ctx: SlotCtx,
    /// Accumulated `element [i]: element [j]: …` wrap, one segment per
    /// vector-nesting level between the outer slot and the failing node.
    index_prefix: []const u8,
};

/// Per-form spec discriminator. Picked once at form-walk start; controls
/// how each child iteration validates its entry.
const SpecState = union(enum) {
    /// Form spec hit — validate keyword names + types and positional types.
    data_form: *const Plugin.FormSpec,
    /// Expression-function hit — arity check at end, reject keyword children.
    expr_func: *const Plugin.ExprFunc,
    /// Empty / recovery / unknown / ambiguous head — recurse only.
    walk_only,
};

/// Auxiliary data captured while consuming a node's payload — needed both
/// for the inline type check and for diagnostic formatting.
const MatchExtras = struct {
    /// Set by `readNumberWithUnit` for `.number_with_unit`; null otherwise.
    unit: ?[]const u8 = null,
    /// Set by `readVector` for `.vector`; zero otherwise.
    vec_len: u32 = 0,
    /// Set by `readString` / `readSymbol`; null otherwise. Used by member
    /// narrowing on `.string`/`.symbol` ValueKinds.
    text: ?[]const u8 = null,
    /// Set by the eval-frame numeric reader (tag-dispatched on wire tag
    /// byte) for `.number` and `.number_with_unit`; null otherwise. The
    /// validator's `:numeric` bound check uses the tag-true value to
    /// preserve exact-int precision against integer-literal bounds.
    numeric: ?NumericValue = null,
};

/// Result of `matchAgainstExpected` for one node level.
const MatchResult = struct {
    /// Diagnostic to emit (caller decides), or null on success.
    fail: ?MatchFail = null,
    /// Element type to propagate into a `vector_walk`. `.any` when the
    /// outer expected didn't pin a per-element type or the outer match
    /// already failed.
    element_type: Plugin.ValueType = .any,
    /// Kind-resolution depth to propagate into element evaluation.
    element_depth: u8 = 0,
    /// True when `element_type` came from a direct `.vector` kind, meaning
    /// the Tree arm would wrap an element failure in `element_at` and report
    /// it against this slot. Cleared when the type resolved via a union
    /// alternative — there the Tree arm emits `union_no_branch_matched` at
    /// the slot instead, so the binary path stays per-element (a separate,
    /// documented divergence). Drives whether a `vector_walk` establishes an
    /// `OuterVecCtx`.
    wrap_element_failures: bool = false,
};

/// Path-extension policy for an eval frame. Unlike the Tree path (where
/// the parent knows the child's head and pre-computes the step), the
/// Binary cursor only exposes a form's head AFTER `readForm`. So the
/// child step is computed inside `processEvalValidate` once the head
/// is known, using `base_path` plus the rule encoded by this enum.
///
/// Convention parity with Tree path (see `childStep` / `kvpair` walker
/// branch in the Tree validator):
///
///   * `root`           — root push: append [head] iff form-with-head.
///   * `kvpair_value`   — kvpair value: append [head] iff form-with-head;
///                        otherwise the diagnostic stays at the slot.
///   * `positional`     — form positional: append [head] iff form-with-
///                        head, else [str(pos_idx)] (Tree's head-or-idx).
///   * `vector_element` — vector element: never extends; the
///                        [str(idx)] step was pre-applied at vector_walk
///                        push time (vector elements always step by
///                        index, even when they are forms).
const StepKind = union(enum) {
    root,
    kvpair_value,
    positional: u32,
    vector_element,
};

/// Two paths derived from one `(base_path, step, view_kind, head)` tuple.
/// `diag` is the path used by emits FIRED AT THIS NODE (type-mismatch /
/// HeadSet failure). `form` is the path of the form's own scope, used
/// when scheduling `form_walk` and emitting form-head diagnostics.
/// They differ only for `kvpair_value` of a form-with-head: the
/// HeadSet failure on `(canvas :shape (triangle …))` emits at
/// `[canvas, shape]` (the slot), but the descent into `(triangle …)`
/// uses `[canvas, shape, triangle]` for any diagnostic emitted from
/// inside that form.
const PathPair = struct {
    diag: []const []const u8,
    form: []const []const u8,
};

const FrameValidate = union(enum) {
    /// Process one node. Cursor must be at `view`'s payload when this
    /// frame runs. Type-checks against `expected` (if `slot_ctx != null`),
    /// then pushes child walks for vectors and forms.
    eval: struct {
        view: BinaryCursor.NodeView,
        expected: Plugin.ValueType,
        slot_ctx: ?SlotCtx,
        depth: u8,
        /// Parent's path; the eval-time path-pair derives from this and
        /// the StepKind below.
        base_path: []const []const u8,
        step: StepKind,
        /// Set when this value sits in a `KeySpec.walk_opaque` slot. The
        /// slot type-check still runs, but the value's body is drained
        /// from the cursor rather than walked — so an expression-shaped
        /// value raises no `unknown_form`. Mirrors the tree path's
        /// `continue :outer` suppression (validateOneTree, ~line 2293).
        walk_opaque: bool = false,
        /// Slot-local form registry in scope for this value (from the
        /// enclosing slot's `KeySpec.local_forms`). When set and this value
        /// is a form, `scheduleFormWalkValidate` resolves the head
        /// local-first before the additive global fallback. Mirrors the tree
        /// path's `Frame.local_form_registry`.
        local_form_registry: ?[]const Plugin.FormSpec = null,
        /// Path of the enclosing slot, used to point `unknown_local_form` at
        /// the slot (e.g. `[canvas shape]`) rather than at the value's head.
        /// Meaningful only when `local_form_registry != null`.
        local_form_slot_path: []const []const u8 = &.{},
        /// Set when this value is an element of a typed `.vector` slot. A
        /// type failure here reports against the outer slot (span/path/type)
        /// with an `element [i]: …` wrap instead of at this element — the
        /// convergence that matches the Tree walker's `element_at` framing.
        outer_vec: ?OuterVecCtx = null,
    },

    /// Iterate one form's children. Each iteration: read next entry,
    /// slot-validate, push self+1 then eval(child). On exhaustion: emit
    /// missing-required diagnostics and (for expr-func) verify arity.
    ///
    /// `seen_keys` indexes into `spec.keys` for closed-form required-key
    /// tracking. `dup_keys` accumulates every kvpair key encountered (as
    /// arena-owned slices) for duplicate detection — applies to all
    /// `data_form` specs, including open ones, since kvpair lists carry
    /// map semantics regardless of openness.
    form_walk: struct {
        head: []const u8,
        head_span: ?Ast.Span,
        iter: BinaryCursor.ChildIter,
        spec_state: SpecState,
        seen_keys: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS),
        dup_keys: std.ArrayList([]const u8),
        /// Positional keyword-flag texts seen so far on this form (arena-
        /// owned). Mirrors `dup_keys` for `flag_set` slots: drives
        /// `duplicate_positional_flag`, since the single-pass cursor can't
        /// rewind to re-scan prior positionals the way the tree walker does.
        seen_flags: std.ArrayList([]const u8),
        argc: u32,
        /// Running positional-argument index for `expr_func` slots —
        /// used to look up the param type via `ExprFunc.paramType(i)`.
        /// Incremented per positional entry; ignored for keyword entries.
        pos_idx: u8 = 0,
        /// Overload candidate mask for `spec_state == .expr_func` when
        /// the func is multi-signature. Bit `i` = signature `i` is still
        /// in the running. Initialised at form_walk schedule time from
        /// the call's argc + sig arities. Tag-narrowed each positional
        /// arg. Unused for mono ExprFuncs and for `data_form`/`walk_only`.
        cand_mask: u32 = 0,
        /// Form's own full path: parent's path extended with the form's
        /// own contribution (head, kvpair key + head, vector index, …).
        /// Used directly for form-level emits (missing-required, arity)
        /// and as the base for child-eval paths.
        path: []const []const u8,
        /// True when the schedule pushed an entry onto the per-buffer
        /// scope stack because this form is a lexical-scope opener; the
        /// pop on frame exhaustion matches one push.
        opened_scope: bool = false,
        /// Discriminant tracking for `data_form` specs that declare
        /// `discriminant_idx`. Set when the discriminant kvpair has
        /// been seen and its symbol value matched a variant. Subsequent
        /// kvpair lookups consult `seen_variant_keys` for variant-only
        /// keys; the form-end sweep uses these to emit variant required-
        /// key diagnostics.
        seen_variant_keys: std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS) = .initEmpty(),
        discriminant_resolved_when: ?[]const u8 = null,
        discriminant_variant_idx: ?u8 = null,
        /// Labeled-call tracking for `spec_state == .expr_func`. The tree
        /// walker resolves a labeled call in one shot against
        /// `hdr.children`; a single-pass cursor cannot, so the labels are
        /// accumulated here and judged at frame close by the same
        /// `Schema` rules (`Schema.diagnoseLabels` and friends).
        ///
        /// Only populated for `expr_func` frames — a data form's kvpairs
        /// go through `dup_keys`, which answers a different question
        /// (`duplicate_key`, per-key rather than per-call).
        expr_labels: std.ArrayList(Schema.LabelRef),
        /// True once a positional argument has been seen. A call carrying
        /// both kinds is `expr_mixed_args`, which outranks every label
        /// fault.
        expr_saw_positional: bool = false,
    },

    /// Iterate one vector's elements. Each iteration: read next view,
    /// push self+1, push eval(elem) carrying `element_type`.
    vector_walk: struct {
        iter: BinaryCursor.VectorIter,
        element_type: Plugin.ValueType,
        slot_ctx: ?SlotCtx,
        element_depth: u8,
        /// Path leading to the vector's slot (no element step). Element
        /// frames are pushed with `base_path = path ++ [str(idx)]` and
        /// `step = .vector_element` so they don't gain a head step.
        path: []const []const u8,
        /// Index of the next element to be popped from `iter`. Used to
        /// build the [str(idx)] step at element push time.
        next_index: u32,
        /// Outer-slot framing for element failures, or null for an untyped
        /// vector / a union-resolved slot (see `OuterVecCtx`). Inherited by
        /// each element's eval frame with this level's index appended.
        outer_vec: ?OuterVecCtx = null,
    },
};

/// Streaming validator entry point. Walks `bytes` via `BinaryCursor` and
/// returns the same `Result` shape as `validate`. The typed `Error` set is
/// `BinaryCursor.Error` (== `Binary.Error`): wire-format failures bubble up
/// from the cursor and `DepthExceeded` from the step / frame budget. Schema
/// violations remain diagnostics inside the returned `Result`.
///
/// Single-binary wrapper over `validateForestBinary`: bundles the buffer
/// into a one-element forest, runs the forest pass, peels off the single
/// `Result` and drops the cross-ref index. Cross-refs *within* one binary
/// are enforced because the index pass walks descendants of the single
/// buffer.
///
/// Defaults both explicit knobs: production `Budget`, and no extraction
/// table — so a provider-route target validated through here reports
/// `cross_ref_provider_unavailable` rather than resolving. Callers that
/// have run the extraction pre-pass want `validateForestBinary`.
pub fn validateBinary(
    gpa: Allocator,
    bytes: []const u8,
    schema: Schema.Schema,
) Error!Result {
    return validateBinaryWithBudget(gpa, bytes, schema, .{}, null);
}

/// `validateBinary` with both explicit knobs. Exposed so tests can drive
/// the two `error.DepthExceeded` arms with a small cap and a small document
/// instead of a document large enough to reach the production ceilings (see
/// `Budget`), and so a caller that ran the provider-extraction pre-pass can
/// hand the table in.
pub fn validateBinaryWithBudget(
    gpa: Allocator,
    bytes: []const u8,
    schema: Schema.Schema,
    budget: Budget,
    extractions: ?*const ExtractionMap,
) Error!Result {
    var bins: [1][]const u8 = .{bytes};
    var fr = try validateForestBinaryWithBudget(gpa, &bins, schema, budget, extractions);
    return fr.intoSingle(gpa);
}

/// Forest-mode binary validator. Mirrors `validateForest`'s shape for
/// `[]const []const u8` byte buffers: builds one cross-ref registry
/// spanning all buffers, then runs the per-buffer streaming validator
/// threading the shared registry. Returns one `Result` per buffer in
/// input order plus the forest-wide `CrossRefIndex`.
///
/// `extractions` is the host's provider-extraction table (null when no
/// pre-pass ran) and is the *only* configuration this path takes. It is a
/// plain parameter rather than a field on a binary `Options`, deliberately:
/// this walker supports no overlays, no effective axes, and no
/// `share_scope`, and a struct named `Options` would promise all three.
/// The graduation criterion recorded in `conformance_tests.zig` — widen the
/// walker-parity replay when the binary path grows an `Options` — is
/// therefore still unmet, which is correct: one field for one feature is
/// not that evolution.
pub fn validateForestBinary(
    gpa: Allocator,
    binaries: []const []const u8,
    schema: Schema.Schema,
    extractions: ?*const ExtractionMap,
) Error!ForestResult {
    return validateForestBinaryWithBudget(gpa, binaries, schema, .{}, extractions);
}

/// Budget-parameterized `validateForestBinary`. See `Budget`.
pub fn validateForestBinaryWithBudget(
    gpa: Allocator,
    binaries: []const []const u8,
    schema: Schema.Schema,
    budget: Budget,
    extractions: ?*const ExtractionMap,
) Error!ForestResult {
    var index_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer index_arena.deinit();

    var results = try gpa.alloc(Result, binaries.len);
    errdefer gpa.free(results);

    var inited: usize = 0;
    errdefer for (results[0..inited]) |*r| r.deinit();
    for (0..binaries.len) |i| {
        results[i] = .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .diagnostics = &.{},
        };
        inited = i + 1;
    }

    var diags_lists = try gpa.alloc(std.ArrayList(Diagnostic), binaries.len);
    defer gpa.free(diags_lists);
    for (0..binaries.len) |i| diags_lists[i] = .empty;

    // 1. Build the cross-ref index across the whole forest. Duplicate
    //    diagnostics emitted here attach to the duplicate's buffer.
    var index = try buildCrossRefIndexBinary(
        index_arena.allocator(),
        gpa,
        schema,
        binaries,
        results,
        diags_lists,
        budget,
        extractions,
    );

    // Precompute canonical scope-opening form names for the per-buffer
    // validation walk's scope-chain construction.
    var scope_heads_validation = try schemaScopeHeads(gpa, schema);
    defer freeSchemaScopeHeads(gpa, &scope_heads_validation);

    // 2. Run the per-buffer streaming validator threading the shared index.
    for (binaries, 0..) |bytes, i| {
        try validateOneBinary(
            results[i].arena.allocator(),
            gpa,
            bytes,
            schema,
            &index,
            .tree(@intCast(i)),
            &scope_heads_validation,
            &diags_lists[i],
            budget,
        );
    }

    for (0..binaries.len) |i| {
        results[i].diagnostics = diags_lists[i].items;
    }

    return .{
        .results = results,
        .cross_ref_index = index,
        .index_arena = index_arena,
    };
}

/// Per-buffer streaming validator body. Caller supplies the result arena
/// (where diagnostic strings land), the forest's shared `CrossRefIndex`,
/// the buffer's `tree_scope`, and the schema-derived `scope_heads` set
/// used to track lexical-scope chains.
fn validateOneBinary(
    a: Allocator,
    gpa: Allocator,
    bytes: []const u8,
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_heads: *const std.StringHashMapUnmanaged(void),
    diags: *std.ArrayList(Diagnostic),
    budget: Budget,
) Error!void {
    var cursor = try BinaryCursor.Cursor.init(bytes);
    var root_iter = try cursor.rootIter();

    var frames: std.ArrayList(FrameValidate) = .empty;
    defer frames.deinit(gpa);
    var scope_stack: std.ArrayList(ScopeFrame) = .empty;
    defer scope_stack.deinit(gpa);
    var canon_buf: std.ArrayList(u8) = .empty;
    defer canon_buf.deinit(gpa);

    while (try root_iter.next()) |root_view| {
        try frames.append(gpa, .{ .eval = .{
            .view = root_view,
            .expected = .any,
            .slot_ctx = null,
            .depth = 0,
            .base_path = &.{},
            .step = .root,
        } });

        var step: u32 = 0;
        while (frames.items.len > 0) {
            if (step >= budget.steps) return error.DepthExceeded;
            if (frames.items.len > budget.frames) return error.DepthExceeded;
            step += 1;

            const f = frames.pop().?;
            switch (f) {
                .eval => |e| try processEvalValidate(a, gpa, &cursor, schema, cross_index, tree_scope, scope_heads, &scope_stack, &canon_buf, e, &frames, diags),
                .form_walk => |fw| try processFormWalkValidate(a, gpa, fw, &frames, &scope_stack, diags),
                .vector_walk => |vw| try processVectorWalkValidate(a, gpa, vw, &frames),
            }
        }
    }
}

fn processEvalValidate(
    a: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_heads: *const std.StringHashMapUnmanaged(void),
    scope_stack: *std.ArrayList(ScopeFrame),
    canon_buf: *std.ArrayList(u8),
    e: anytype,
    frames: *std.ArrayList(FrameValidate),
    diags: *std.ArrayList(Diagnostic),
) Error!void {
    const view = e.view;

    // 1. Consume the cursor for this node and capture data needed for
    //    type checks AND diagnostic formatting.
    var extras: MatchExtras = .{};
    var maybe_iter: ?BinaryCursor.VectorIter = null;
    var maybe_form: ?BinaryCursor.FormView = null;

    switch (view.kind) {
        .nil => try BinaryCursor.readNil(cursor, view),
        .boolean => _ = try BinaryCursor.readBoolean(cursor, view),
        .number => extras.numeric = switch (view.tag) {
            .number => NumericValue{ .f = try BinaryCursor.readNumber(cursor, view) },
            .number_i64 => NumericValue{ .i = try BinaryCursor.readNumberI64(cursor, view) },
            .number_u64 => NumericValue{ .u = try BinaryCursor.readNumberU64(cursor, view) },
            else => unreachable, // view.kind == .number gates the three tags above
        },
        .number_with_unit => {
            const nu = try BinaryCursor.readNumberWithUnit(cursor, view);
            extras.unit = nu.unit;
            extras.numeric = NumericValue{ .f = nu.value };
        },
        .date => _ = try BinaryCursor.readDate(cursor, view),
        .time => _ = try BinaryCursor.readTime(cursor, view),
        .string => extras.text = try BinaryCursor.readString(cursor, view),
        .keyword => _ = try BinaryCursor.readKeyword(cursor, view),
        .symbol => extras.text = try BinaryCursor.readSymbol(cursor, view),
        .vector => {
            const it = try BinaryCursor.readVector(cursor, view);
            extras.vec_len = it.remaining;
            maybe_iter = it;
        },
        .form => {
            maybe_form = try BinaryCursor.readForm(cursor, view);
        },
    }

    // 2. Resolve this node's two paths from base + step + view + head.
    //    `diag` is the path used for emits AT THIS NODE (type-mismatch /
    //    HeadSet failure); `form` is the path of the form's own scope.
    const head_for_path: []const u8 = if (maybe_form) |fv| fv.head else "";
    const paths = try computeBinaryPathPair(a, e.base_path, e.step, view.kind, head_for_path);

    // 3. Inline type check against `expected`. Only runs when slot_ctx is
    //    set — root frames and recursion-only descents pass slot_ctx=null
    //    and skip the check entirely. Forms in non-form slots defer to
    //    runtime (matches `matchValueAgainstType` line 435).
    var element_type: Plugin.ValueType = .any;
    var element_depth: u8 = 0;
    var element_wrap = false;

    if (e.slot_ctx) |ctx| {
        if (view.kind != .form) {
            const result = try matchAgainstExpected(a, schema, cross_index, tree_scope, scope_stack.items, view, e.expected, e.depth, extras);
            if (result.fail) |f| {
                if (e.outer_vec) |ov| {
                    try emitTypeMismatchBinaryOuter(a, diags, view, ov, f, extras);
                } else {
                    try emitTypeMismatchBinary(a, diags, view, paths.diag, ctx, e.expected, f, extras);
                }
            } else if (extras.text) |t| {
                try emitDeprecatedMemberCore(a, diags, schema, t, e.expected, view.span orelse ZERO_SPAN, paths.diag);
                if (view.kind == .string) {
                    try emitStringPatternUnsupportedCore(a, diags, schema, e.expected, view.span orelse ZERO_SPAN, paths.diag);
                }
            }
            element_type = result.element_type;
            element_depth = result.element_depth;
            element_wrap = result.wrap_element_failures;
        } else if (resolveFormHeadKind(schema, e.expected)) |kind| {
            // Form value in a form-pinned slot: the only structural
            // check applied to forms is the HeadSet narrowing — every
            // other form-typed slot defers to runtime (§7.4).
            if (kind.heads) |hs| {
                const head = maybe_form.?.head;
                var matched = false;
                for (hs.names) |n| if (std.mem.eql(u8, n, head)) {
                    matched = true;
                    break;
                };
                if (!matched) {
                    var head_extras = extras;
                    head_extras.text = head;
                    const head_fail: MatchFail = .{ .not_head_member = .{ .got = head, .allowed = hs.names } };
                    if (e.outer_vec) |ov| {
                        try emitTypeMismatchBinaryOuter(a, diags, view, ov, head_fail, head_extras);
                    } else {
                        try emitTypeMismatchBinary(a, diags, view, paths.diag, ctx, e.expected, head_fail, head_extras);
                    }
                }
            }
        } else if (!isAnyType(e.expected) and e.expected != .form) {
            // Form value in a typed non-form/any slot (form-pinned HeadSet
            // slots are handled by the branch above). Delegate to the binary
            // form matcher: union-alternative dispatch plus declared-
            // expression-result comparison, parity with the tree path's
            // `matchValueAgainstType` form branch. The old inlined block
            // guarded union slots out with `!resolvesToUnion`, so a
            // rejectable form in a union slot silently passed — the helper's
            // step 4 closes that gap.
            const fv = maybe_form.?;
            if (matchFormAgainstTypeBinary(schema, fv.head, fv.namespace, fv.children.remaining, e.expected, e.depth)) |f| {
                if (e.outer_vec) |ov| {
                    try emitTypeMismatchBinaryOuter(a, diags, view, ov, f, extras);
                } else {
                    try emitTypeMismatchBinary(a, diags, view, paths.diag, ctx, e.expected, f, extras);
                }
            }
        }
    }

    // 4. Push child walks. Vectors get a vector_walk regardless of any
    //    type-check outcome (recursion still reaches nested forms). Forms
    //    get a form_walk so their head is validated and their children
    //    are walked.
    //
    //    `walk_opaque` slots are the exception: the slot type-check above
    //    ran, but the value's contents are opaque to the schema, so we
    //    drain the body from the cursor instead of walking it. Draining
    //    keeps the single-pass cursor in sync (every node still consumed)
    //    while suppressing the per-node diagnostics descent would emit —
    //    chiefly `unknown_form` for an expression-shaped value like
    //    `(pi)`. This mirrors the tree path's `continue :outer`
    //    (validateOneTree, ~line 2293), where the separate
    //    `validateFormKeys` type-check likewise still runs.
    if (e.walk_opaque) {
        if (maybe_iter) |it| {
            var vit = it;
            while (try vit.next()) |elem| try BinaryCursor.skipBody(cursor, elem);
        } else if (maybe_form) |fv| {
            var cit = fv.children;
            while (try cit.next()) |ce| try BinaryCursor.skipBody(cursor, ce.value);
        }
    } else if (maybe_iter) |it| {
        // Establish (or inherit) the outer-slot framing for element failures.
        // An untyped vector (`element_type == .any`) type-checks no elements,
        // so it needs none. Otherwise: inherit the enclosing typed vector's
        // context if we're already inside one; else, for a direct `.vector`
        // slot (`element_wrap`), open a fresh context anchored at this node.
        // A union-resolved vector leaves it null (see `OuterVecCtx`).
        const child_outer: ?OuterVecCtx = if (element_type == .any)
            null
        else if (e.outer_vec) |ov|
            ov
        else if (element_wrap)
            .{
                .expected = e.expected,
                .span = view.span orelse ZERO_SPAN,
                .path = paths.diag,
                .ctx = e.slot_ctx.?,
                .index_prefix = "",
            }
        else
            null;
        try frames.append(gpa, .{ .vector_walk = .{
            .iter = it,
            .element_type = element_type,
            .slot_ctx = if (element_type == .any) null else e.slot_ctx,
            .element_depth = element_depth,
            .path = paths.diag,
            .next_index = 0,
            .outer_vec = child_outer,
        } });
    } else if (maybe_form) |fv| {
        try scheduleFormWalkValidate(a, gpa, schema, fv, paths.form, frames, diags, scope_heads, scope_stack, canon_buf, tree_scope, e.local_form_registry, e.local_form_slot_path);
    }
}

fn scheduleFormWalkValidate(
    a: Allocator,
    gpa: Allocator,
    schema: Schema.Schema,
    fv: BinaryCursor.FormView,
    form_path: []const []const u8,
    frames: *std.ArrayList(FrameValidate),
    diags: *std.ArrayList(Diagnostic),
    scope_heads: *const std.StringHashMapUnmanaged(void),
    scope_stack: *std.ArrayList(ScopeFrame),
    canon_buf: *std.ArrayList(u8),
    tree_scope: ScopeId,
    /// Slot-local form registry in scope (from the enclosing slot's
    /// `KeySpec.local_forms`), or null when this form is not in a
    /// local-forms slot. Mirrors the tree path's `validateFormHead`.
    local_registry: ?[]const Plugin.FormSpec,
    /// Path of the enclosing slot, used to point `unknown_local_form` at the
    /// slot rather than at the value's head. Meaningful only with a registry.
    local_slot_path: []const []const u8,
) Error!void {
    const head = fv.head;
    const head_span = fv.head_span orelse ZERO_SPAN;
    const argc = fv.children.remaining;

    var spec_state: SpecState = .walk_only;

    // Empty head signals a parser-recovery synthetic form — skip head
    // lookup but still walk children.
    if (head.len > 0) {
        // 0. Slot-local resolution (additive, local-first), mirroring the
        // tree path's `validateFormHead` step 0. Runs only for a *bare* head
        // in a slot that declared local forms — a qualified head bypasses
        // locals and falls through to the global path below (so its terminal
        // miss is `unknown_form`, not `unknown_local_form`). A local hit
        // shadows the global catalog; a bare miss falls back to the global
        // form lookup (not expr-funcs — the slot is `:type form`); a miss
        // against both is `unknown_local_form` at the slot path.
        if (fv.namespace == null and local_registry != null) {
            const reg = local_registry.?;
            const local_hit = matchLocalForm(reg, head);
            if (local_hit) |lf| {
                spec_state = .{ .data_form = lf };
            } else switch (schema.lookupForm(head, null)) {
                .found => |hit| spec_state = .{ .data_form = hit.form },
                .ambiguous => |amb| try emitAmbiguous(a, diags, head_span, form_path, "form", head, amb.slice()),
                .not_found => try emitUnknownLocalForm(a, diags, head_span, local_slot_path, head, reg),
            }
        } else {
            const form_hit = schema.lookupForm(head, fv.namespace);
            switch (form_hit) {
                .found => |hit| spec_state = .{ .data_form = hit.form },
                .ambiguous => |amb| try emitAmbiguous(a, diags, head_span, form_path, "form", head, amb.slice()),
                .not_found => {
                    const expr_hit = schema.lookupExprFunc(head, fv.namespace);
                    switch (expr_hit) {
                        .found => |hit| spec_state = .{ .expr_func = hit.func },
                        .ambiguous => |amb| try emitAmbiguous(a, diags, head_span, form_path, "expression", head, amb.slice()),
                        .not_found => try emitUnknown(a, diags, head_span, form_path, head, fv.namespace),
                    }
                },
            }
        }
    }

    const cand_mask: u32 = switch (spec_state) {
        .expr_func => |func| if (func.signatures != null)
            overloadInitialMask(func.*, argc)
        else
            0,
        else => 0,
    };

    // Push a scope frame if this form's canonical name is a scope-opener
    // somewhere in the schema. `form_pos` is the cursor position right
    // after `readForm`, matching what the index-build pass captured for
    // the same form instance. The matching pop happens when the form_walk
    // is fully consumed in the buffer-validator loop.
    var opened_scope = false;
    const form_pos: u32 = @intCast(fv.children.cursor.pos);
    if (scope_heads.count() > 0) {
        if (canonicalFormNameBuf(gpa, canon_buf, schema, head, fv.namespace) catch null) |canon| {
            if (scope_heads.getEntry(canon)) |sh_entry| {
                try scope_stack.append(gpa, .{
                    .canonical = sh_entry.key_ptr.*,
                    .scope_id = .lexical(tree_scope.treeIdx(), form_pos),
                });
                opened_scope = true;
            }
        }
    }

    try frames.append(gpa, .{ .form_walk = .{
        .head = head,
        .head_span = fv.head_span,
        .iter = fv.children,
        .spec_state = spec_state,
        .seen_keys = std.bit_set.IntegerBitSet(Plugin.MAX_FORM_KEYS).initEmpty(),
        .dup_keys = .empty,
        .seen_flags = .empty,
        .argc = argc,
        .cand_mask = cand_mask,
        .path = form_path,
        .opened_scope = opened_scope,
        .expr_labels = .empty,
    } });
}

fn processFormWalkValidate(
    a: Allocator,
    gpa: Allocator,
    fw: anytype,
    frames: *std.ArrayList(FrameValidate),
    scope_stack: *std.ArrayList(ScopeFrame),
    diags: *std.ArrayList(Diagnostic),
) Error!void {
    var iter = fw.iter;

    if (iter.remaining == 0) {
        // Drain trailing comments via the final next() call (returns null).
        _ = try iter.next();
        try emitEndOfFormBinary(a, diags, fw);
        // Only the terminal call pops the scope frame this form opened —
        // the per-iteration re-pushes inherit `.opened_scope = true` so
        // any descendant references see the open scope, but only one of
        // them owns the pop.
        if (fw.opened_scope and scope_stack.items.len > 0) {
            _ = scope_stack.pop();
        }
        return;
    }

    const entry = (try iter.next()) orelse unreachable;

    // Per-child slot validation. Sets `expected` + `slot_ctx` for the
    // child eval frame; emits any per-child structural diagnostics.
    var expected: Plugin.ValueType = .any;
    var slot_ctx: ?SlotCtx = null;
    var seen_keys = fw.seen_keys;
    var seen_variant_keys = fw.seen_variant_keys;
    var dup_keys = fw.dup_keys;
    var seen_flags = fw.seen_flags;
    var expr_labels = fw.expr_labels;
    var expr_saw_positional = fw.expr_saw_positional;
    // Discriminant tracking carried across iterations of the same form.
    var discriminant_resolved_when = fw.discriminant_resolved_when;
    var discriminant_variant_idx = fw.discriminant_variant_idx;
    // Default-carry: keeps the overload candidate mask unchanged unless
    // an overloaded expr-func arg narrows it (see .expr_func branch).
    var next_cand_mask = fw.cand_mask;
    // Set when the matched declared/variant key opts out of recursive
    // descent (`KeySpec.walk_opaque`). Carried onto the child eval frame.
    var suppress_descent = false;
    // Set when the matched declared/variant key carries `KeySpec.local_forms`
    // and the value is a form: the registry + slot path ride onto the child
    // eval frame so `scheduleFormWalkValidate` resolves the head local-first.
    // Mirrors the tree path's kvpair handler (validateOneTree, ~line 2340).
    var local_registry: ?[]const Plugin.FormSpec = null;
    var local_slot_path: []const []const u8 = &.{};

    // Step pre-decided for the child eval. For kvpair entries this is
    // `kvpair_value` (eval may further extend with [head] iff form-with-
    // head). For positional entries it's `positional(pos_idx)` (eval
    // resolves to [head] or [str(pos_idx)]).
    const child_step: StepKind = switch (entry.kind) {
        .keyword => .kvpair_value,
        .positional => .{ .positional = fw.pos_idx },
        _ => .{ .positional = fw.pos_idx },
    };

    // For kvpair child eval frames, eval's base path already includes
    // the [key] step; the eval's StepKind only needs to handle the
    // optional head extension. For positional, eval's base path stays
    // at `fw.path` and eval applies the head-or-idx step itself.
    const child_base: []const []const u8 = switch (entry.kind) {
        .keyword => try appendStep(a, fw.path, entry.key.?),
        .positional => fw.path,
        _ => fw.path,
    };

    switch (fw.spec_state) {
        .walk_only => {},
        .data_form => |spec| switch (entry.kind) {
            .keyword => {
                const key = entry.key.?;
                // Duplicate detection: schema-independent, applies to
                // both open and closed data_form specs.
                var is_dup = false;
                for (dup_keys.items) |prior| {
                    if (std.mem.eql(u8, prior, key)) {
                        is_dup = true;
                        break;
                    }
                }
                if (is_dup) {
                    try emit(a, diags, entry.key_span orelse ZERO_SPAN, child_base, .err, .duplicate_key, try duplicateKeyMsg(a, spec.name, key));
                } else {
                    try dup_keys.append(a, key);
                }

                // Type-check declared keys regardless of `open` — the
                // `open` relaxation is for *undeclared* shape, not for
                // skipping types on shape that *was* declared. See
                // LANGUAGE.md §7.3.
                var found = false;
                for (spec.keys, 0..) |k, ki| {
                    if (std.mem.eql(u8, k.name, key)) {
                        found = true;
                        if (ki < Plugin.MAX_FORM_KEYS) seen_keys.set(ki);
                        expected = k.value_type;
                        slot_ctx = .{ .form_name = spec.name, .slot = .{ .key = k.name } };
                        suppress_descent = k.walk_opaque;
                        if (k.local_forms.len > 0 and entry.value.kind == .form) {
                            local_registry = k.local_forms;
                            local_slot_path = child_base;
                        }
                        // Discriminant resolution: peek the symbol value
                        // *before* the eval frame consumes it. The peek
                        // is non-destructive; eval still type-checks the
                        // value normally (so a not_member diagnostic
                        // fires for out-of-set values). Only matches in
                        // the declared MemberSet resolve a variant.
                        if (spec.discriminant_idx) |didx| {
                            if (ki == didx and entry.value.kind == .symbol) {
                                if (BinaryCursor.peekSymbol(iter.cursor, entry.value)) |sym| {
                                    const vs = spec.variants orelse &.{};
                                    for (vs, 0..) |v, vi| {
                                        if (std.mem.eql(u8, v.when, sym)) {
                                            discriminant_resolved_when = v.when;
                                            discriminant_variant_idx = @intCast(vi);
                                            break;
                                        }
                                    }
                                } else |_| {}
                            }
                        }
                        break;
                    }
                }
                // Variant-key fallthrough: only when the discriminant
                // has already been seen and resolved on this form.
                // Producers must emit the discriminant first.
                if (!found) {
                    if (discriminant_variant_idx) |vi| {
                        const v = spec.variants.?[vi];
                        for (v.keys, 0..) |vk, vki| {
                            if (std.mem.eql(u8, vk.name, key)) {
                                found = true;
                                if (vki < Plugin.MAX_FORM_KEYS) seen_variant_keys.set(vki);
                                expected = vk.value_type;
                                slot_ctx = .{ .form_name = spec.name, .slot = .{ .key = vk.name } };
                                suppress_descent = vk.walk_opaque;
                                if (vk.local_forms.len > 0 and entry.value.kind == .form) {
                                    local_registry = vk.local_forms;
                                    local_slot_path = child_base;
                                }
                                break;
                            }
                        }
                    }
                }
                if (!found and !spec.open) {
                    const ctx: UnknownKeyContext = if (spec.discriminant_idx != null and discriminant_resolved_when == null)
                        .{ .needs_discriminant = spec.discriminant_name orelse "kind" }
                    else
                        .{ .resolved = discriminant_resolved_when };
                    try emit(a, diags, entry.key_span orelse ZERO_SPAN, child_base, .err, .unknown_key, try unknownKeywordMsg(a, spec.name, key, ctx));
                }
            },
            .positional => {
                // Positional slot-local resolution: a form-shaped positional
                // child resolves its head local-first against this form's
                // `FormSpec.local_forms`, independent of the positional variant
                // (`.any` / `.kind` head-set / …). Mirror of the keyword carrier
                // above and of the tree path's `.form` child-push (validateOneTree,
                // ~line 2270). `child_base` is `fw.path` for a positional entry, so
                // the slot path is this form's own path; the registry + slot path
                // ride onto the child eval frame, where `scheduleFormWalkValidate`
                // resolves the head local-first.
                if (spec.local_forms.len > 0 and entry.value.kind == .form) {
                    local_registry = spec.local_forms;
                    local_slot_path = child_base;
                }
                switch (spec.positional) {
                    .none => if (!spec.open) {
                        // Mirrors Tree's `positionalStep`: head when the
                        // positional is a non-synthetic form, index
                        // otherwise. `peekFormHead` rewinds c.pos so the
                        // child eval frame's `readForm` is unaffected.
                        const step: []const u8 = if (entry.value.kind == .form) blk: {
                            const h = try BinaryCursor.peekFormHead(iter.cursor, entry.value);
                            if (h.len > 0) break :blk try a.dupe(u8, h);
                            break :blk try indexStep(a, fw.pos_idx);
                        } else try indexStep(a, fw.pos_idx);
                        const pos_path = try extendPath(a, fw.path, step);
                        try emit(a, diags, entry.value.span orelse ZERO_SPAN, pos_path, .err, .positional_not_allowed, try positionalNotAllowedMsg(a, spec.name));
                    },
                    .any => {},
                    .kind => |kind_ref| {
                        expected = .{ .named = kind_ref };
                        slot_ctx = .{ .form_name = spec.name, .slot = .positional };
                    },
                    .flag_set => |fs| {
                        // Emit directly (like `.none`) and leave
                        // `expected`/`slot_ctx` default so the value frame
                        // still consumes the keyword leaf. `peekKeyword`
                        // rewinds c.pos so that read is unaffected.
                        const step: []const u8 = if (entry.value.kind == .form) blk: {
                            const h = try BinaryCursor.peekFormHead(iter.cursor, entry.value);
                            if (h.len > 0) break :blk try a.dupe(u8, h);
                            break :blk try indexStep(a, fw.pos_idx);
                        } else try indexStep(a, fw.pos_idx);
                        const pos_path = try extendPath(a, fw.path, step);
                        const is_kw = entry.value.kind == .keyword;
                        const got: []const u8 = if (is_kw) try BinaryCursor.peekKeyword(iter.cursor, entry.value) else "";
                        switch (classifyFlag(is_kw, got, fs.flags)) {
                            .ok => {
                                // A valid flag repeated on this form is
                                // `duplicate_positional_flag`. `got` borrows
                                // the cursor buffer, so dupe before retaining.
                                var dup = false;
                                for (seen_flags.items) |prior| {
                                    if (std.mem.eql(u8, prior, got)) {
                                        dup = true;
                                        break;
                                    }
                                }
                                if (dup) {
                                    try emit(a, diags, entry.value.span orelse ZERO_SPAN, pos_path, .err, .duplicate_positional_flag, try flagDuplicateMsg(a, spec.name, got));
                                } else {
                                    try seen_flags.append(a, try a.dupe(u8, got));
                                }
                            },
                            .wrong_shape => try emit(a, diags, entry.value.span orelse ZERO_SPAN, pos_path, .err, .wrong_underlying, try flagWrongShapeMsg(a, spec.name)),
                            .not_member => try emit(a, diags, entry.value.span orelse ZERO_SPAN, pos_path, .err, .not_flag_member, try flagNotMemberMsg(a, spec.name, got, fs.flags)),
                        }
                    },
                }
            },
            _ => unreachable,
        },
        .expr_func => |func| {
            if (entry.kind == .keyword) {
                // If any signature opts into labels, this is a labeled
                // call: record the label for the frame-close judgement
                // and type the argument. Otherwise — no labels declared
                // — the `expr_kvpair_not_allowed` path fires unchanged.
                if (anyLabeledSignature(func.*)) {
                    // The structural verdict (mixed / duplicate /
                    // unknown / missing) needs the whole label set, so
                    // it waits for frame close; accumulate here.
                    // Arena-backed, like `dup_keys` / `seen_flags`: these
                    // live exactly as long as the diagnostics they may
                    // produce, so there is no per-frame free.
                    try expr_labels.append(a, .{
                        .key = entry.key.?,
                        .span = entry.key_span orelse ZERO_SPAN,
                    });
                    // Typing the argument needs no random access when
                    // the function is mono: the label names the slot
                    // outright. Skipping it once meant a read-side host
                    // validating pre-encoded IR missed an error-severity
                    // `expr_type_mismatch` the reference emits.
                    //
                    // Multi-signature selection stays deferred — picking
                    // among same-arity labeled overloads needs the whole
                    // label set, which a single-pass cursor does not have
                    // at this point. That remainder is union-div 3.
                    if (func.signatures == null) {
                        var mono_it = func.signatureIter();
                        const sig = mono_it.next().?;
                        // Symbols may be `let`-bound; defer them exactly
                        // as the positional mono path does.
                        if (entry.value.kind != .symbol) {
                            if (sig.indexOfLabel(entry.key.?)) |slot| {
                                if (sig.paramType(slot)) |t| {
                                    expected = t;
                                    slot_ctx = .{ .form_name = func.name, .slot = .{ .expr_arg = slot } };
                                }
                            }
                        }
                    }
                } else {
                    try emit(a, diags, entry.key_span orelse ZERO_SPAN, child_base, .err, .expr_kvpair_not_allowed, try std.fmt.allocPrint(
                        a,
                        "expression `{s}` does not accept keyword argument `:{s}`",
                        .{ func.name, entry.key.? },
                    ));
                }
            } else if (func.signatures != null) {
                expr_saw_positional = true;
                // Overloaded — narrow the candidate mask tag-wise.
                // Symbols / forms defer to runtime; keep mask intact.
                if (entry.value.kind != .symbol and entry.value.kind != .form) {
                    const accept = overloadAcceptMask(func.*, fw.pos_idx, entry.value.kind);
                    const new_mask = fw.cand_mask & accept;
                    if (fw.cand_mask != 0 and new_mask == 0) {
                        // Mirror the mono path's [str(pos_idx)] path
                        // step. The mono path routes through eval's
                        // typing (which builds the path from
                        // `step = .positional`); here we're emitting
                        // directly so build the step inline.
                        const step = try indexStep(a, fw.pos_idx);
                        const arg_path = try extendPath(a, fw.path, step);
                        try emitOverloadMismatch(
                            a,
                            diags,
                            entry.value.span orelse ZERO_SPAN,
                            arg_path,
                            func.*,
                            fw.pos_idx,
                            fw.cand_mask,
                            entry.value.kind,
                        );
                    }
                    next_cand_mask = new_mask;
                }
                // expected stays .any, slot_ctx stays null — eval skips
                // its own typing for overloaded args.
            } else {
                expr_saw_positional = true;
                if (func.paramType(fw.pos_idx)) |t| {
                    // Mono — refinement-aware via eval's slot typing.
                    // Symbols may be `let`-bound references — defer to
                    // runtime by leaving slot_ctx unset so the eval frame
                    // skips the type check. Forms are deferred by the
                    // existing `view.kind != .form` gate in the eval loop.
                    if (entry.value.kind != .symbol) {
                        expected = t;
                        slot_ctx = .{ .form_name = func.name, .slot = .{ .expr_arg = fw.pos_idx } };
                    }
                }
            }
        },
    }

    // Advance the per-form positional index for the next iteration.
    var next_pos_idx = fw.pos_idx;
    if (entry.kind == .positional and next_pos_idx != std.math.maxInt(u8)) {
        next_pos_idx += 1;
    }

    // Push self+1 (deeper in stack), then child eval (top of stack).
    try frames.append(gpa, .{
        .form_walk = .{
            .head = fw.head,
            .head_span = fw.head_span,
            .iter = iter,
            .spec_state = fw.spec_state,
            .seen_keys = seen_keys,
            .seen_variant_keys = seen_variant_keys,
            .dup_keys = dup_keys,
            .seen_flags = seen_flags,
            .argc = fw.argc,
            .pos_idx = next_pos_idx,
            .cand_mask = next_cand_mask,
            .path = fw.path,
            // Carry the scope-opener flag so the eventual exhausted-frame
            // pop knows to drop the matching scope_stack entry.
            .opened_scope = fw.opened_scope,
            .discriminant_resolved_when = discriminant_resolved_when,
            .discriminant_variant_idx = discriminant_variant_idx,
            .expr_labels = expr_labels,
            .expr_saw_positional = expr_saw_positional,
        },
    });
    try frames.append(gpa, .{ .eval = .{
        .view = entry.value,
        .expected = expected,
        .slot_ctx = slot_ctx,
        .depth = 0,
        .base_path = child_base,
        .step = child_step,
        .walk_opaque = suppress_descent,
        .local_form_registry = local_registry,
        .local_form_slot_path = local_slot_path,
    } });
}

fn emitEndOfFormBinary(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    fw: anytype,
) Allocator.Error!void {
    const head_span = fw.head_span orelse ZERO_SPAN;
    switch (fw.spec_state) {
        .walk_only => {},
        .data_form => |spec| {
            if (spec.open) return;
            // Discriminant absent: emit one diagnostic and skip variant
            // required-key sweep so we don't pile up missing-key noise.
            if (spec.discriminant_idx) |didx| {
                if (didx < Plugin.MAX_FORM_KEYS and !fw.seen_keys.isSet(didx)) {
                    const dname = spec.discriminant_name orelse spec.keys[didx].name;
                    try emit(a, diags, head_span, fw.path, .err, .missing_discriminant_key, try missingDiscriminantMsg(a, spec.name, dname));
                }
            }
            for (spec.keys, 0..) |k, ki| {
                if (k.effectiveOptional()) continue;
                if (ki < Plugin.MAX_FORM_KEYS and fw.seen_keys.isSet(ki)) continue;
                if (spec.discriminant_idx) |didx| {
                    if (ki == didx) continue;
                }
                if (keyInExclusiveGroup(spec.exclusive_groups, k.name)) continue;
                try emit(a, diags, head_span, fw.path, .err, .missing_required_key, try missingRequiredKeyMsg(a, spec.name, k.name));
            }
            try emitExclusiveGroupDiagnostics(
                a,
                diags,
                spec.exclusive_groups,
                spec.keys,
                fw.seen_keys,
                null,
                spec.name,
                null,
                head_span,
                fw.path,
            );
            if (fw.discriminant_variant_idx) |vi| {
                const v = spec.variants.?[vi];
                for (v.keys, 0..) |vk, vki| {
                    if (vk.effectiveOptional()) continue;
                    if (vki < Plugin.MAX_FORM_KEYS and fw.seen_variant_keys.isSet(vki)) continue;
                    // Don't double-report a variant key that appears in
                    // the form but was rejected mid-stream (e.g.
                    // before the discriminant). `dup_keys` accumulates
                    // every kvpair name encountered, regardless of
                    // resolution outcome.
                    var present = false;
                    for (fw.dup_keys.items) |k| {
                        if (std.mem.eql(u8, k, vk.name)) {
                            present = true;
                            break;
                        }
                    }
                    if (present) continue;
                    if (keyInExclusiveGroup(v.exclusive_groups, vk.name)) continue;
                    try emit(a, diags, head_span, fw.path, .err, .missing_required_key, try missingRequiredVariantKeyMsg(a, spec.name, v.when, vk.name));
                }
                try emitExclusiveGroupDiagnostics(
                    a,
                    diags,
                    v.exclusive_groups,
                    v.keys,
                    fw.seen_variant_keys,
                    null,
                    spec.name,
                    v.when,
                    head_span,
                    fw.path,
                );
            }
        },
        .expr_func => |func| {
            // A labeled call is judged as a whole, so the verdict lands
            // here rather than per-child: the tree walker resolves the
            // call in one shot (`Schema.resolveExprArgs`), and this is
            // the first point at which the streaming walker holds the
            // same information — every label, and whether a positional
            // also appeared.
            //
            // Until this arm existed the binary path judged labeled
            // calls on arity alone, which silently accepted an unknown,
            // duplicate or mixed-in label and reported a missing one as
            // `arity_mismatch`. A read-side host validating pre-encoded
            // IR therefore accepted calls the reference rejects.
            if (fw.expr_labels.items.len > 0 and anyLabeledSignature(func.*)) {
                if (fw.expr_saw_positional) {
                    // Mixed outranks every label fault, and is blamed on
                    // the first label — matching `resolveExprArgs`,
                    // which decides this before looking at signatures.
                    try emitResolveError(a, diags, fw.path, func.*, head_span, .{
                        .mixed = .{ .span = fw.expr_labels.items[0].span },
                    });
                    return;
                }
                if (!Schema.labelsMatchAnySignature(func.*, fw.expr_labels.items)) {
                    try emitResolveError(a, diags, fw.path, func.*, head_span, Schema.diagnoseLabels(func.*, fw.expr_labels.items));
                    return;
                }
                // Matched: `labelsMatchSignature` required one label per
                // slot and every slot filled, so the arity check below
                // could only ever pass. The tree path likewise returns
                // without re-checking it.
                return;
            }
            if (!func.checkArity(fw.argc)) {
                try emitArity(a, diags, head_span, fw.path, func.*, fw.argc);
            }
        },
    }
}

fn processVectorWalkValidate(
    a: Allocator,
    gpa: Allocator,
    vw: anytype,
    frames: *std.ArrayList(FrameValidate),
) Error!void {
    var iter = vw.iter;
    if (iter.remaining == 0) {
        // Drain the vector's trailing comments via the final next() (wire
        // v5+), mirroring the form walk; without it the cursor desyncs on
        // the next sibling under a comment-carrying preset.
        _ = try iter.next();
        return;
    }

    const elem_view = (try iter.next()) orelse unreachable;

    // Vector elements always get the index step (even when the element
    // is a form-with-head, matching the Tree-path convention). The eval
    // frame's `step = .vector_element` keeps the path stable: no further
    // head extension at the element node.
    const idx_step = try indexStep(a, vw.next_index);
    const elem_base = try extendPath(a, vw.path, idx_step);

    // Extend the outer-slot wrap with this element's index, so a failure here
    // (or deeper) reads `… element [next_index]: <inner>` against the outer
    // slot — one `element [i]:` segment per nesting level, outer index first.
    const elem_outer: ?OuterVecCtx = if (vw.outer_vec) |ov| .{
        .expected = ov.expected,
        .span = ov.span,
        .path = ov.path,
        .ctx = ov.ctx,
        .index_prefix = try appendElementPrefix(a, ov.index_prefix, vw.next_index),
    } else null;

    try frames.append(gpa, .{ .vector_walk = .{
        .iter = iter,
        .element_type = vw.element_type,
        .slot_ctx = vw.slot_ctx,
        .element_depth = vw.element_depth,
        .path = vw.path,
        .next_index = vw.next_index + 1,
        .outer_vec = vw.outer_vec,
    } });
    try frames.append(gpa, .{ .eval = .{
        .view = elem_view,
        .expected = vw.element_type,
        .slot_ctx = vw.slot_ctx,
        .depth = vw.element_depth,
        .base_path = elem_base,
        .step = .vector_element,
        .outer_vec = elem_outer,
    } });
}

/// Append one `element [idx]: ` segment to an accumulated wrap prefix, using
/// the exact shape the Tree walker's `describeFail` `.element_at` arm emits.
fn appendElementPrefix(a: Allocator, prev: []const u8, idx: u32) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{s}element [{d}]: ", .{ prev, idx });
}

// ---------------------------------------------------------------------------
// Type matching (binary path). Mirrors matchValueAgainstType / matchValueAgainstKind
// but operates on the cursor's NodeView + extras instead of a Tree node.
// ---------------------------------------------------------------------------

/// Resolution outcome for an `expected` type. Strips off `.named` chains
/// down to either a primitive `ValueType` or a concrete `*ValueKind`.
const Resolved = union(enum) {
    primitive: Plugin.ValueType,
    kind: struct { ptr: *const Plugin.ValueKind, depth: u8 },
    fail: MatchFail,
};

fn resolveExpected(
    a: Allocator,
    schema: Schema.Schema,
    expected: Plugin.ValueType,
    depth: u8,
) Allocator.Error!Resolved {
    var current = expected;
    while (true) {
        switch (current) {
            .named => |ref| {
                if (resolvePrimitiveShortcut(ref.name)) |p| {
                    current = p;
                    continue;
                }
                switch (schema.lookupValueKind(ref.name, ref.namespace)) {
                    .found => |k| {
                        const next_d = depth + 1;
                        if (next_d >= Schema.MAX_KIND_DEPTH) return .{ .fail = .recursion_depth };
                        return .{ .kind = .{ .ptr = k, .depth = next_d } };
                    },
                    .not_found => return .{ .fail = .{ .unknown_element_kind = .{
                        .name = ref.name,
                        .namespace = ref.namespace,
                    } } },
                    .ambiguous => |amb| return .{ .fail = .{ .ambiguous_element_kind = .{
                        .name = ref.name,
                        .claimants = try a.dupe(*const Plugin.Plugin, amb.slice()),
                    } } },
                }
            },
            else => return .{ .primitive = current },
        }
    }
}

fn matchAgainstExpected(
    a: Allocator,
    schema: Schema.Schema,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    view: BinaryCursor.NodeView,
    expected: Plugin.ValueType,
    depth: u8,
    extras: MatchExtras,
) Allocator.Error!MatchResult {
    return switch (try resolveExpected(a, schema, expected, depth)) {
        .fail => |f| .{ .fail = f },
        .primitive => |p| matchPrimitiveBinary(view, p),
        .kind => |kr| try matchKindBinary(a, schema, view, kr.ptr, kr.depth, cross_index, tree_scope, scope_chain, extras),
    };
}

fn matchPrimitiveBinary(view: BinaryCursor.NodeView, p: Plugin.ValueType) MatchResult {
    const tag = view.kind;
    return switch (p) {
        .any => .{},
        .number => switch (tag) {
            .number, .number_with_unit => .{},
            else => .{ .fail = .{ .wrong_underlying = "number" } },
        },
        .string => if (tag == .string) .{} else .{ .fail = .{ .wrong_underlying = "string" } },
        .symbol => if (tag == .symbol) .{} else .{ .fail = .{ .wrong_underlying = "symbol" } },
        .boolean => if (tag == .boolean) .{} else .{ .fail = .{ .wrong_underlying = "boolean" } },
        .nil => if (tag == .nil) .{} else .{ .fail = .{ .wrong_underlying = "nil" } },
        .vector => if (tag == .vector) .{} else .{ .fail = .{ .wrong_underlying = "vector" } },
        // Forms in non-form slots are deferred BEFORE this fn runs (caller
        // gates on `view.kind != .form`). Reaching here means we expect a
        // form but got something non-form: reuse "form" label.
        .form, .expr => .{ .fail = .{ .wrong_underlying = "form" } },
        .named => unreachable, // resolveExpected unwraps .named
    };
}

fn matchKindBinary(
    a: Allocator,
    schema: Schema.Schema,
    view: BinaryCursor.NodeView,
    kind: *const Plugin.ValueKind,
    depth: u8,
    cross_index: *CrossRefIndex,
    tree_scope: ScopeId,
    scope_chain: []const ScopeFrame,
    extras: MatchExtras,
) Allocator.Error!MatchResult {
    const tag = view.kind;
    return switch (kind.underlying) {
        .number, .string, .symbol => .{
            // Scalars never spawn an element walk; the shared matcher's
            // `?MatchFail` is the whole result (element_type/depth stay
            // at their `.any`/0 defaults, as the inlined arms returned).
            .fail = try matchScalar(a, schema, cross_index, tree_scope, scope_chain, kind, ScalarView.fromBinary(view, extras)),
        },
        .form => blk: {
            std.debug.assert(kind.members == null);
            break :blk if (tag == .form) .{} else .{ .fail = .{ .wrong_underlying = "form" } };
        },
        .vector => blk: {
            std.debug.assert(kind.members == null);
            if (tag != .vector) break :blk .{ .fail = .{ .wrong_underlying = "vector" } };
            if (kind.vector) |vs| {
                if (vs.len) |want| {
                    if (extras.vec_len != want) break :blk .{
                        .fail = .{ .wrong_vector_len = .{ .want = want, .got = extras.vec_len } },
                    };
                }
                if (vs.min_len) |mn| {
                    if (extras.vec_len < mn) break :blk .{
                        .fail = .{ .vector_too_short = .{ .got = extras.vec_len, .min_len = mn } },
                    };
                }
                if (vs.max_len) |mx| {
                    if (extras.vec_len > mx) break :blk .{
                        .fail = .{ .vector_too_long = .{ .got = extras.vec_len, .max_len = mx } },
                    };
                }
                break :blk .{
                    .element_type = .{ .named = vs.element },
                    .element_depth = depth,
                    .wrap_element_failures = true,
                };
            }
            break :blk .{};
        },
        .union_of => blk: {
            const us = kind.union_of orelse break :blk .{ .fail = .{ .wrong_underlying = "union" } };
            // Try alternatives in declaration order via the same dispatch
            // entry point a non-union slot uses; first match wins. Depth
            // is unchanged — the union itself doesn't burn budget; the
            // alternative's `resolveExpected` will increment as needed.
            //
            // Capture-suppressed while probing, then the winner re-run with
            // capture enabled — see the Tree arm for why (rejected
            // alternatives were registering reference sites). Kept in step
            // here because cross-ref capture is shared by both walkers.
            var probe = cross_index.*;
            probe.arena = null;
            for (us.alternatives) |alt_name| {
                const result = try matchAgainstExpected(
                    a,
                    schema,
                    &probe,
                    tree_scope,
                    scope_chain,
                    view,
                    .{ .named = alt_name },
                    depth,
                    extras,
                );
                if (result.fail == null) {
                    _ = try matchAgainstExpected(
                        a,
                        schema,
                        cross_index,
                        tree_scope,
                        scope_chain,
                        view,
                        .{ .named = alt_name },
                        depth,
                        extras,
                    );
                    // The alternative may be a `.vector` (its match set
                    // `wrap_element_failures`), but a failing element of a
                    // union-accepted vector is NOT wrapped by the Tree arm —
                    // it collapses the whole union to `union_no_branch_matched`
                    // at the slot. Clear the flag so the binary path keeps its
                    // documented per-element divergence here (union-div #2).
                    var r = result;
                    r.wrap_element_failures = false;
                    break :blk r;
                }
            }
            // Nothing accepted — no winner to pollute, so let the typo'd
            // reference be captured, matching the Tree arm.
            for (us.alternatives) |alt_name| {
                _ = try matchAgainstExpected(a, schema, cross_index, tree_scope, scope_chain, view, .{ .named = alt_name }, depth, extras);
            }
            break :blk .{ .fail = .{ .union_no_branch_matched = .{
                .got_label = nodeKindLabelBinary(tag),
                .alternatives = us.alternatives,
            } } };
        },
    };
}

/// Binary-path form-vs-type matcher. A pure mirror of the tree path's form
/// handling (`matchValueAgainstType`'s form branch + `matchValueAgainstKind`'s
/// `.form` / `.union_of` arms), driven off a `FormView`'s (head, namespace,
/// argc) instead of a `Tree` handle. The single-pass cursor can't recurse
/// into the form's children, so the only structural checks a form gets are:
/// HeadSet narrowing, the any/form/expr shortcuts, union-alternative dispatch
/// (first match wins), and declared-expression-result comparison. Returns the
/// first `MatchFail`, or null on accept.
///
/// This is the funnel that closes the union-over-forms binary gap: forms in a
/// union-resolving slot used to fall out of `processEvalValidate`'s check
/// chain entirely (the `!resolvesToUnion` guard), so the binary path silently
/// passed a form that the tree rejected with `union_no_branch_matched`.
///
/// Nested unions are rejected at schema-aggregate time, so a union alternative
/// is never itself a union — the recursion terminates in one hop; `depth`
/// still threads the `Schema.MAX_KIND_DEPTH` bound for parity with
/// `resolveExpected`.
fn matchFormAgainstTypeBinary(
    schema: Schema.Schema,
    head: []const u8,
    namespace: ?[]const u8,
    argc: u32,
    expected: Plugin.ValueType,
    depth: u8,
) ?MatchFail {
    // 1. Form-pinned kind with a HeadSet: narrow by head (tree
    //    `matchValueAgainstType` 4342-4349 + `matchValueAgainstKind` `.form`).
    if (resolveFormHeadKind(schema, expected)) |kind| {
        if (kind.heads) |hs| {
            for (hs.names) |n| if (std.mem.eql(u8, n, head)) return null;
            return MatchFail{ .not_head_member = .{ .got = head, .allowed = hs.names } };
        }
        return null;
    }
    // 2. any / form shortcuts accept any form (tree 4350, 4353).
    if (isAnyType(expected)) return null;
    if (expected == .form) return null;
    // 3. expr slot: an expr-func head matches, a data form fails, an
    //    unresolved head defers (tree 4354-4361).
    if (expected == .expr) {
        return switch (resolveFormExpressionBinary(schema, head, namespace, argc)) {
            .expr => null,
            .data_form => MatchFail{ .wrong_underlying = typeLabel(expected) },
            .unresolved => null,
        };
    }
    // 4. Union slot: try alternatives in declaration order, first match wins;
    //    none match -> `union_no_branch_matched` (tree 4369 fall-through into
    //    `matchValueAgainstKind`'s `.union_of` arm 4638-4653).
    if (resolvesToUnion(schema, expected)) {
        const ref = expected.named; // resolvesToUnion implies `.named`
        const next_d = depth + 1;
        if (next_d >= Schema.MAX_KIND_DEPTH) return MatchFail{ .recursion_depth = {} };
        const k = switch (schema.lookupValueKind(ref.name, ref.namespace)) {
            .found => |kk| kk,
            else => return null, // unreachable given resolvesToUnion; defer
        };
        const us = k.union_of orelse return null;
        for (us.alternatives) |alt_name| {
            if (matchFormAgainstTypeBinary(schema, head, namespace, argc, .{ .named = alt_name }, next_d) == null)
                return null;
        }
        return MatchFail{ .union_no_branch_matched = .{
            .got_label = "form",
            .alternatives = us.alternatives,
        } };
    }
    // 5. Typed non-form/any/union/expr slot: compare the form's declared
    //    expression result to the expected type (tree 4372-4383).
    return switch (resolveFormExpressionBinary(schema, head, namespace, argc)) {
        .unresolved => null,
        .data_form => MatchFail{ .wrong_underlying = typeLabel(expected) },
        .expr => |x| blk: {
            const declared = x.result orelse break :blk null;
            break :blk switch (declaredResultMatchesExpected(schema, declared, expected)) {
                .yes, .unknown => null,
                .no => MatchFail{ .wrong_underlying = typeLabel(expected) },
            };
        },
    };
}

/// Short user-facing label for a binary view's kind, used in the
/// `union_no_branch_matched` diagnostic. Mirrors `nodeTagLabel` (tree
/// path) but operates on the binary's coarser `Ast.ValueKind` enum
/// (no `boolean_true`/`boolean_false` split, no `kvpair`).
fn nodeKindLabelBinary(kind: Ast.ValueKind) []const u8 {
    return switch (kind) {
        .number, .number_with_unit => "number",
        .string => "string",
        .keyword => "keyword",
        .symbol => "symbol",
        .boolean => "boolean",
        .nil => "nil",
        .date => "date",
        .time => "time",
        .vector => "vector",
        .form => "form",
    };
}

// ---------------------------------------------------------------------------
// Diagnostic formatting (binary path). Parallel to emitTypeMismatch /
// describeNode / describeFail; reads kind + extras directly off the view.
// ---------------------------------------------------------------------------

fn emitTypeMismatchBinary(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    view: BinaryCursor.NodeView,
    path: []const []const u8,
    ctx: SlotCtx,
    expected: Plugin.ValueType,
    fail: MatchFail,
    extras: MatchExtras,
) Allocator.Error!void {
    var buf: std.ArrayList(u8) = .empty;
    try writeSlotPrefix(a, &buf, ctx.form_name, ctx.slot, expected);
    try describeFailBinary(a, &buf, view, fail, extras);
    try emit(a, diags, view.span orelse ZERO_SPAN, path, .err, slotMismatchCode(ctx.slot, fail), try buf.toOwnedSlice(a));
}

/// Emit a typed-vector element failure against its OUTER slot — the Tree
/// walker's framing. `ov` carries the outer slot's span, path, expected-type
/// label, and identity; `view`/`extras` describe the offending element (still
/// the current cursor node). The message is
/// `<slot prefix for ov.expected>` + `element [i]: …` + `<offending node>`,
/// byte-identical to the Tree arm's `describeFail` `.element_at` output, and
/// the code matches because `element_at` recurses to the same leaf code.
fn emitTypeMismatchBinaryOuter(
    a: Allocator,
    diags: *std.ArrayList(Diagnostic),
    view: BinaryCursor.NodeView,
    ov: OuterVecCtx,
    fail: MatchFail,
    extras: MatchExtras,
) Allocator.Error!void {
    var buf: std.ArrayList(u8) = .empty;
    try writeSlotPrefix(a, &buf, ov.ctx.form_name, ov.ctx.slot, ov.expected);
    try buf.appendSlice(a, ov.index_prefix);
    try describeFailBinary(a, &buf, view, fail, extras);
    try emit(a, diags, ov.span, ov.path, .err, slotMismatchCode(ov.ctx.slot, fail), try buf.toOwnedSlice(a));
}

fn describeFailBinary(
    a: Allocator,
    buf: *std.ArrayList(u8),
    view: BinaryCursor.NodeView,
    fail: MatchFail,
    extras: MatchExtras,
) Allocator.Error!void {
    switch (fail) {
        // Per-path: render the offending node from the binary view + extras.
        .wrong_underlying => {
            try buf.appendSlice(a, "got ");
            try describeNodeBinary(a, buf, view, extras);
        },
        // The binary path emits per-element and never wraps, so a top-level
        // `.element_at` is impossible here.
        .element_at => unreachable,
        else => try describeFailCommon(a, buf, fail),
    }
}

fn describeNodeBinary(
    a: Allocator,
    buf: *std.ArrayList(u8),
    view: BinaryCursor.NodeView,
    extras: MatchExtras,
) Allocator.Error!void {
    switch (view.kind) {
        .number => try buf.appendSlice(a, "number"),
        .number_with_unit => {
            try buf.appendSlice(a, "number with unit `");
            try buf.appendSlice(a, extras.unit.?);
            try buf.appendSlice(a, "`");
        },
        .string => try buf.appendSlice(a, "string"),
        .keyword => try buf.appendSlice(a, "keyword"),
        .symbol => try buf.appendSlice(a, "symbol"),
        .boolean => try buf.appendSlice(a, "boolean"),
        .nil => try buf.appendSlice(a, "nil"),
        .date => try buf.appendSlice(a, "date"),
        .time => try buf.appendSlice(a, "time"),
        .vector => {
            const piece = try std.fmt.allocPrint(a, "vector of length {d}", .{extras.vec_len});
            try buf.appendSlice(a, piece);
        },
        .form => try buf.appendSlice(a, "form"),
    }
}

test {
    _ = @import("Validator_tests.zig");
}
