//! Side-table overlay of materialized default values for omitted keys.
//!
//! The author `Ast.Tree` stays pristine — effective values for omitted
//! keys live in this
//! overlay, keyed by `(form NodeIndex, key name)`. A consumer that
//! wants author input walks the tree; one that wants the effective
//! value asks the overlay first, then falls back to the tree.
//!
//! Scope: this module owns the full data-forest walk. It populates
//! `entries` for every omitted defaulted key — literal defaults via
//! `literalToValue`, expression defaults via the evaluator — and emits a
//! `default_eval_failed` diagnostic per failing expression default.
//!
//! Heads resolve the way the validator resolves them: local-first
//! against the slot the form arrived in, then additively against the
//! global catalog (`resolveHead`). An overlay that resolved globally
//! would describe a different form than the diagnostics printed beside
//! it — and did, splicing a shadowed global's `:radius` into a
//! slot-local `circle` that declares `:r`.
//!
//! Ownership: `entries` and every owned slice inside an `Entry` are
//! allocated from a caller-chosen allocator (the host wiring will
//! pass the `HostResult` arena). This module deliberately exposes no
//! `deinit` — the overlay's lifetime is tied to whatever arena owns
//! the entries.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Expr = @import("Expr.zig");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
// Head resolution only (`matchLocalForm`). `Validator` imports this module
// back for its overlay `Options`, so the pair is a cycle at file scope —
// legal, and preferable to a second copy of local-first matching, which is
// the drift the shared helper exists to prevent.
const Validator = @import("Validator.zig");
const testing = std.testing;

/// Provenance for a materialized entry. Hosts may surface this so a
/// consumer can tell a copied literal apart from an evaluated
/// expression result.
pub const Origin = enum {
    literal_default,
    expression_default,
};

/// One materialized default tied to a specific omitted key on a
/// specific form instance.
pub const Entry = struct {
    /// The form node whose declared `key` was omitted by the author.
    form: Ast.NodeIndex,
    /// Schema key name (e.g. `"radius"`). Owned by the entry's arena.
    key: []const u8,
    /// Effective value. Strings / keywords / vectors are owned by the
    /// entry's arena (see `literalToValue`).
    value: Expr.Value,
    origin: Origin,
    /// The manifest's literal `:default` spelling, or null for an
    /// expression default (whose only rendering is the computed
    /// `value`).
    ///
    /// Recorded by the walk rather than re-derived by the reader. The
    /// key belongs to whichever `FormSpec` the head resolved to *in its
    /// slot*, so a consumer holding only the head would have to redo
    /// that resolution — and the two consumers that did resolved
    /// globally, which is how the effective document came to splice a
    /// shadowed global's default into a slot-local form.
    ///
    /// Borrows the manifest's storage (unlike `key` and `value`, which
    /// are arena-duped). No new lifetime obligation: reading it is
    /// exactly where the reader used to pass a live `Schema` in to do
    /// the same lookup.
    literal: ?Plugin.KeySpec.Default = null,
    /// Schema-side path of the default, useful for diagnostics. Shape
    /// matches the aggregate path: `[plugin, form, key, "default"]`.
    /// Owned by the entry's arena. May be empty until the populating
    /// walk fills it.
    schema_path: []const []const u8 = &.{},
};

/// Read-only overlay. The struct itself is value-typed; pass a
/// pointer when calling lookup helpers so the returned `*const Entry`
/// stays anchored to the slice the caller owns.
pub const MaterializedDefaults = struct {
    entries: []const Entry = &.{},

    /// Find the materialized default for `(form, key)`, or `null` if
    /// the author wrote the key explicitly or the schema has no
    /// default. Linear scan: documents typically have only a handful
    /// of omitted defaulted keys per form, so hashing would cost more
    /// than it saves; revisit if profiling shows the scan dominating.
    pub fn defaultFor(
        self: *const MaterializedDefaults,
        form: Ast.NodeIndex,
        key: []const u8,
    ) ?*const Entry {
        for (self.entries) |*entry| {
            if (entry.form == form and std.mem.eql(u8, entry.key, key)) {
                return entry;
            }
        }
        return null;
    }
};

/// Failure modes for `literalToValue`. `NotALiteral` is the signal
/// that the caller must route through the expression-evaluation path
/// (slice 3) instead.
pub const ConvertError = error{
    OutOfMemory,
    /// Default is `.expression` — caller must evaluate the
    /// `program` payload with `Expr.evalBinary`, not convert here.
    NotALiteral,
    /// A literal vector default nests past `Expr.MAX_VALUE_DEPTH`. The
    /// manifest parser bounds a default at `Parser.MAX_PARSE_DEPTH`
    /// (1024), four times what every `Expr.Value` consumer assumes, so
    /// the cap has to be enforced here or an overlay entry could carry a
    /// value `deepCopyValueAssumeBounded` cannot copy.
    DepthExceeded,
};

/// The module's conventional aggregate error — its sole surface is conversion.
pub const Error = ConvertError;

/// Convert a literal `Plugin.KeySpec.Default` arm into `Expr.Value`,
/// duping owned strings / vectors into `a`. The caller picks the
/// allocator — host wiring passes the `HostResult` arena so the
/// resulting value outlives the manifest's plugin arena.
///
/// `Default.symbol` maps to `Expr.Value.keyword`: `Expr.Value` has no
/// symbol variant because expression-context symbols are always
/// bound names, never values. The keyword spelling preserves the
/// identifier; consumers needing the source-level symbol-vs-keyword
/// distinction can read the author tree directly.
///
/// `Default.expression` returns `error.NotALiteral` — the evaluable
/// `program` is the materialization input, not literal data.
///
/// Bounded recursion over `.vector`: returns `error.DepthExceeded` at
/// `Expr.MAX_VALUE_DEPTH`, with the same entry-check shape as
/// `Expr.deepCopyValueDepth`, so every value this produces is one that
/// `deepCopyValueAssumeBounded` provably accepts.
pub fn literalToValue(
    a: Allocator,
    default: Plugin.KeySpec.Default,
) ConvertError!Expr.Value {
    return literalToValueDepth(a, default, 0);
}

fn literalToValueDepth(
    a: Allocator,
    default: Plugin.KeySpec.Default,
    depth: u32,
) ConvertError!Expr.Value {
    if (depth >= Expr.MAX_VALUE_DEPTH) return error.DepthExceeded;
    return switch (default) {
        .number => |n| .{ .number = n },
        .boolean => |b| .{ .boolean = b },
        .nil => .nil,
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .symbol => |s| .{ .keyword = try a.dupe(u8, s) },
        .vector => |xs| blk: {
            const dup = try a.alloc(Expr.Value, xs.len);
            for (xs, 0..) |x, i| dup[i] = try literalToValueDepth(a, x, depth + 1);
            break :blk .{ .vector = dup };
        },
        .expression => ConvertError.NotALiteral,
    };
}

// ---------------------------------------------------------------------------
// materializeDefaults — data-forest walk
// ---------------------------------------------------------------------------

/// Outcome of one `materializeDefaults` call. Mirrors the aggregate-
/// validator pattern: entries are arena-owned (caller chose the arena);
/// diagnostics are gpa-owned and must be released via `deinit`.
pub const Result = struct {
    materialized: MaterializedDefaults,
    diagnostics: []const Ast.Diagnostic,

    pub fn deinit(self: *Result, gpa: Allocator) void {
        Ast.Diagnostic.freeOwnedSlice(gpa, self.diagnostics);
    }
};

/// One node still to visit, plus the slot-local registry its head
/// resolves against before the global catalog. The walk has to carry
/// that registry because a bare head matches the slot's own forms
/// first — the same thing `validateOneTree`'s frame carries, for the
/// same reason.
const Pending = struct {
    idx: Ast.NodeIndex,
    /// Empty for every node that sits in no local-forms slot, which is
    /// the overwhelming majority.
    registry: []const Plugin.FormSpec = &.{},
};

/// Walk every known data form reachable from `data_forest`, materialize
/// each omitted declared key whose `KeySpec.default` is non-null, and
/// emit a `default_eval_failed` diagnostic for every expression default
/// whose evaluation fails. `entries` live in `arena`; `diagnostics`
/// are gpa-owned (the host wrapper copies them into its result arena).
///
/// Schema-key caching: each `Plugin.KeySpec`'s default is evaluated at
/// most once. N omitted instances of the same schema key share the same
/// `Expr.Value`, whose string/vector contents alias `arena` and remain
/// valid until the arena releases.
pub fn materializeDefaults(
    gpa: Allocator,
    arena: Allocator,
    tree: *const Ast.Tree,
    data_forest: []const Ast.NodeIndex,
    schema: Schema.Schema,
) Allocator.Error!Result {
    return materializeDefaultsWithOptions(gpa, arena, tree, data_forest, schema, .{});
}

/// Knobs on the materialization pass. One field today; a struct rather than
/// a parameter because `materializeDefaults` is called from eleven places
/// and only the host's two care.
pub const Options = struct {
    /// `Validator.Options.held_symbol` — the spelling of a position the
    /// author has deliberately not filled in yet. When non-null, a key whose
    /// author value is that symbol does **not** suppress the key's default:
    /// held reads as absent here, so `(warp :by _)` on a key declaring a
    /// `:default` materializes that default rather than handing the consumer
    /// back `_`.
    ///
    /// That is the whole point of the field. A held value *is* an author
    /// value structurally, so without it the author-wins rule would suppress
    /// the very default a hole is supposed to resolve to, and every consumer
    /// would have to special-case the held symbol instead of one site doing
    /// it here.
    held_symbol: ?[]const u8 = null,
};

/// `materializeDefaults` with the pass's knobs. See `Options`.
pub fn materializeDefaultsWithOptions(
    gpa: Allocator,
    arena: Allocator,
    tree: *const Ast.Tree,
    data_forest: []const Ast.NodeIndex,
    schema: Schema.Schema,
    options: Options,
) Allocator.Error!Result {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(arena);
    var diags: std.ArrayList(Ast.Diagnostic) = .empty;
    // On the error path, free each recorded diagnostic's contents (message +
    // path parts), not just the list backing — mirrors `Result.deinit`. A
    // mid-walk OOM after a diagnostic was appended must not leak it. Same
    // shape as `Lowering.runLoweringPassBudgeted`.
    errdefer {
        Ast.Diagnostic.freeOwnedContents(gpa, diags.items);
        diags.deinit(gpa);
    }

    // Cache: `*const Plugin.KeySpec` → arena-owned `Expr.Value`. Negative
    // hits (eval failed for this schema key) are recorded with a
    // sentinel `null` so retries on the next instance don't re-emit the
    // diagnostic or re-run the failing program.
    const CacheValue = ?Expr.Value;
    var cache: std.AutoHashMapUnmanaged(*const Plugin.KeySpec, CacheValue) = .empty;
    defer cache.deinit(gpa);

    // Worklist over form-shaped nodes — no host-stack recursion. A deeply
    // nested tree would otherwise recurse up to `Parser.MAX_PARSE_DEPTH`
    // frames, unsafe on the wasm shadow stack (this module runs inside the
    // kitchen-sink artifact via `Host`). Seed the forest in reverse so the
    // worklist pops it in document order; the reverse child push below keeps
    // that pre-order as the walk descends.
    var work: std.ArrayList(Pending) = .empty;
    defer work.deinit(gpa);
    {
        var i = data_forest.len;
        while (i > 0) {
            i -= 1;
            try work.append(gpa, .{ .idx = data_forest[i] });
        }
    }

    while (work.pop()) |pending| {
        const idx = pending.idx;
        if (tree.tagOf(idx) != .form) continue;
        const hdr = tree.formHeader(idx);
        // Parser-recovery synthetic form — mirror the validator's skip.
        if (hdr.head.len == 0) continue;

        // Only materialize for *data* forms. Expression-function invocations
        // in data positions produce a runtime value, not a kvpair-bearing
        // instance; unknown heads are already diagnosed by the validator.
        const form_spec = resolveHead(schema, hdr, pending.registry);
        if (form_spec) |spec| {
            try materializeForForm(gpa, arena, tree, idx, hdr, spec, schema, &entries, &diags, &cache, options.held_symbol);
        }

        // Descend into form-shaped children regardless of whether this node
        // resolved as a data form — a child may be a data form even when the
        // parent didn't resolve (the validator already emitted at the
        // unresolved parent). Push in reverse so the worklist pops them in
        // document order (matches the prior recursive pre-order descent).
        var c = hdr.children.len;
        while (c > 0) {
            c -= 1;
            const child = hdr.children[c];
            const cf = tree.childForm(child) orelse continue;
            // The overlay as it stands: every default this form declares is
            // already in it, so the shared resolver can take the axis-D leg.
            const so_far: MaterializedDefaults = .{ .entries = entries.items };
            const registry = Validator.childSlot(tree, form_spec, idx, hdr, &so_far, child) orelse continue;
            try work.append(gpa, .{ .idx = cf, .registry = registry });
        }
    }

    return .{
        .materialized = .{ .entries = try entries.toOwnedSlice(arena) },
        .diagnostics = try diags.toOwnedSlice(gpa),
    };
}

/// Resolve `hdr`'s head the way `Validator.validateFormHead` step 0
/// does: local-first against the slot's registry, then additively
/// against the global catalog. A qualified head (`ns/foo`) bypasses
/// locals, and an empty registry means there was no local slot to
/// consult.
///
/// Resolving globally here materialized the *shadowed* global's
/// defaults onto a slot-local form instance — keys the validator then
/// reports as `unknown_key` on the very document the effective view
/// spliced them into.
fn resolveHead(
    schema: Schema.Schema,
    hdr: Ast.FormHeader,
    registry: []const Plugin.FormSpec,
) ?*const Plugin.FormSpec {
    if (hdr.namespace == null and registry.len > 0) {
        if (Validator.matchLocalForm(registry, hdr.head)) |local| return local;
    }
    return switch (schema.lookupForm(hdr.head, hdr.namespace)) {
        .found => |hit| hit.form,
        else => null,
    };
}

fn materializeForForm(
    gpa: Allocator,
    arena: Allocator,
    tree: *const Ast.Tree,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    form_spec: *const Plugin.FormSpec,
    schema: Schema.Schema,
    entries: *std.ArrayList(Entry),
    diags: *std.ArrayList(Ast.Diagnostic),
    cache: *std.AutoHashMapUnmanaged(*const Plugin.KeySpec, ?Expr.Value),
    held_symbol: ?[]const u8,
) Allocator.Error!void {
    try materializeKeys(gpa, arena, tree, form_idx, hdr, form_spec.keys, &.{}, schema, entries, diags, cache, held_symbol);

    // The active variant's keys, second and for a reason: the discriminant
    // is a *common* key, so a discriminant supplied by its own `:default`
    // is already an entry by the time `activeVariant` reads for it. That is
    // the order `validateFormKeys` runs in too — pre-resolve, then walk,
    // then sweep.
    const v = activeVariant(tree, form_idx, hdr, form_spec, entries.items) orelse return;
    try materializeKeys(gpa, arena, tree, form_idx, hdr, v.keys, form_spec.keys, schema, entries, diags, cache, held_symbol);
}

/// Materialize every defaulted key of `keys` the author left out of this
/// form instance. Shared by the common-key and variant-key passes, which
/// differ only in which list they walk — a defaulted variant key is
/// omitted, satisfied and effective on exactly the same terms as a
/// defaulted common one (`KeySpec.effectiveOptional`).
fn materializeKeys(
    gpa: Allocator,
    arena: Allocator,
    tree: *const Ast.Tree,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    keys: []const Plugin.KeySpec,
    /// Names an earlier pass on this instance already covered. Empty for
    /// the common pass; the form's common keys for the variant one, and
    /// only because `variant_key_collision` is a *diagnostic* rather than
    /// a rejection — `Schema.validateForms` reports the redeclaration and
    /// the spec keeps both keys, so without this the overlay would carry
    /// two entries for one slot and `EffectiveDocument.formInsertion`
    /// would splice a duplicate kvpair into the effective document.
    shadowed: []const Plugin.KeySpec,
    schema: Schema.Schema,
    entries: *std.ArrayList(Entry),
    diags: *std.ArrayList(Ast.Diagnostic),
    cache: *std.AutoHashMapUnmanaged(*const Plugin.KeySpec, ?Expr.Value),
    held_symbol: ?[]const u8,
) Allocator.Error!void {
    for (keys) |*key| {
        if (key.default == null) continue;
        // Position-independent on purpose. A variant key written *ahead* of
        // its discriminant is `unknown_key`, but the author still wrote it —
        // `emitVariantSweeps` scans the children the same way rather than
        // trusting `seen_variant`, so neither surface offers a default for a
        // slot that already has text in it.
        if (authorWroteKey(tree, hdr, key.name, held_symbol)) continue;
        if (nameIn(shadowed, key.name)) continue;

        const value = materializeOne(gpa, arena, schema, key, hdr.head, hdr.head_span, diags, cache) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        } orelse continue;

        try entries.append(arena, .{
            .form = form_idx,
            .key = try arena.dupe(u8, key.name),
            .value = value,
            .origin = switch (key.default.?) {
                .expression => .expression_default,
                else => .literal_default,
            },
            .literal = switch (key.default.?) {
                .expression => null,
                else => key.default.?,
            },
        });
    }
}

/// The variant in force on this form *instance*, by the two routes the
/// validator resolves one: a discriminant the author wrote anywhere among
/// the children, else one supplied by its own `:default` (axis D).
///
/// The anchor is the form's own end, and that is the difference from
/// `slotKey`'s. This asks a question about the *form* — which extra keys
/// does this instance have, and which of them did the author omit — which
/// is what `emitVariantSweeps` asks after the whole child walk. `slotKey`
/// asks about one kvpair *at a position*, where the discriminant must
/// precede it. Two questions, two anchors; collapsing them would either
/// accept a mis-ordered key or lose a default the validator counts on.
fn nameIn(keys: []const Plugin.KeySpec, name: []const u8) bool {
    for (keys) |*k| {
        if (std.mem.eql(u8, k.name, name)) return true;
    }
    return false;
}

fn activeVariant(
    tree: *const Ast.Tree,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    spec: *const Plugin.FormSpec,
    entries: []const Entry,
) ?*const Plugin.Variant {
    if (Validator.activeVariantAt(tree, hdr, spec, tree.spanOf(form_idx).end)) |v| return v;
    const so_far: MaterializedDefaults = .{ .entries = entries };
    return Validator.overlayVariant(spec, form_idx, &so_far);
}

/// Return the value `NodeIndex` of the explicit `:key` kvpair on
/// the form whose header is `hdr`, or `null` if no kvpair child
/// matches `key`. Public so `EffectiveView.getAuthorValue` can share
/// the same lookup without re-implementing the children walk.
pub fn authorValueOnForm(
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    key: []const u8,
) ?Ast.NodeIndex {
    for (hdr.children) |child| {
        if (tree.tagOf(child) != .kvpair) continue;
        const kvh = tree.kvpairHeader(child);
        if (std.mem.eql(u8, kvh.key, key)) return kvh.value;
    }
    return null;
}

/// True when this node is `held_symbol`. Null (every caller that has not
/// opted in) answers false for every node. Shared with `EffectiveView`,
/// which asks the same question of the same lookup.
pub fn isHeldValue(tree: *const Ast.Tree, idx: Ast.NodeIndex, held_symbol: ?[]const u8) bool {
    const held = held_symbol orelse return false;
    if (tree.tagOf(idx) != .symbol) return false;
    return std.mem.eql(u8, tree.symbolText(idx), held);
}

/// "Did the author fill this slot?" — which is not quite "is there a kvpair
/// for this key", because a held value is a kvpair the author wrote to say
/// they have *not* decided. Held answers false, so the default still
/// materializes; see `Options.held_symbol`.
fn authorWroteKey(
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    key_name: []const u8,
    held_symbol: ?[]const u8,
) bool {
    const idx = authorValueOnForm(tree, hdr, key_name) orelse return false;
    return !isHeldValue(tree, idx, held_symbol);
}

/// Return the cached `Expr.Value` for this schema key, evaluating it on
/// first hit. `null` means "evaluation failed for this key" — the
/// diagnostic was already emitted on the failing instance, and callers
/// should skip adding an Entry. Returns an `Allocator.Error` only on
/// arena/gpa OOM; runtime evaluation failures fall onto the diagnostic
/// stream and resolve to `null`.
fn materializeOne(
    gpa: Allocator,
    arena: Allocator,
    schema: Schema.Schema,
    key: *const Plugin.KeySpec,
    form_head: []const u8,
    head_span: Ast.Span,
    diags: *std.ArrayList(Ast.Diagnostic),
    cache: *std.AutoHashMapUnmanaged(*const Plugin.KeySpec, ?Expr.Value),
) Allocator.Error!?Expr.Value {
    if (cache.get(key)) |cached| return cached;

    const default = key.default.?;
    if (default != .expression) {
        const value = literalToValue(arena, default) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // SAFETY: vector defaults with `.expression` elements are
            // rejected at manifest-load time (`ManifestLoader.parseDefault`
            // returns null for a form element), so a literal `Default`
            // reaching here can never carry an inner `.expression` arm. A
            // Zig-built `Plugin` that nests one is a caller bug.
            error.NotALiteral => unreachable,
            // A literal nested past `Expr.MAX_VALUE_DEPTH` is reported the
            // way a failing expression default is: the key stays
            // unmaterialized and the author sees why.
            error.DepthExceeded => {
                try emitFailure(gpa, diags, form_head, key.name, head_span, error.DepthExceeded);
                try cache.put(gpa, key, null);
                return null;
            },
        };
        try cache.put(gpa, key, value);
        return value;
    }

    const program = default.expression.program;
    var eval_result = Expr.evalBinary(gpa, program, &.{}, schema) catch |err| {
        try emitFailure(gpa, diags, form_head, key.name, head_span, err);
        try cache.put(gpa, key, null);
        return null;
    };
    defer eval_result.deinit();

    const owned = try Expr.deepCopyValueAssumeBounded(arena, eval_result.value);
    try cache.put(gpa, key, owned);
    return owned;
}

fn emitFailure(
    gpa: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    form_head: []const u8,
    key_name: []const u8,
    span: Ast.Span,
    err: Expr.BinaryError,
) Allocator.Error!void {
    // The leak-safe allocation sequence used to be written out here as
    // well, with a comment pointing at `Lowering.emitDiag` and saying
    // "mirrors". It lives in `Ast.Diagnostic.appendOwned` now, so the
    // mirror is a call rather than a claim.
    return Ast.Diagnostic.appendOwned(
        gpa,
        diags,
        .{
            .code = .default_eval_failed,
            .span = span,
            .path_parts = &.{ form_head, key_name, "default" },
        },
        "default for `:{s}` on `({s} …)` failed to evaluate: {s}",
        .{ key_name, form_head, @errorName(err) },
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "literalToValue: number" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try literalToValue(arena.allocator(), .{ .number = 3.5 });
    try testing.expect(v == .number);
    try testing.expectEqual(@as(f64, 3.5), v.number);
}

test "literalToValue: boolean" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try literalToValue(arena.allocator(), .{ .boolean = true });
    const f = try literalToValue(arena.allocator(), .{ .boolean = false });
    try testing.expect(t == .boolean and t.boolean == true);
    try testing.expect(f == .boolean and f.boolean == false);
}

test "literalToValue: nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try literalToValue(arena.allocator(), .nil);
    try testing.expect(v == .nil);
}

test "literalToValue: string dupes into allocator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var src = [_]u8{ 'h', 'i' };
    const v = try literalToValue(arena.allocator(), .{ .string = src[0..] });
    try testing.expect(v == .string);
    try testing.expectEqualStrings("hi", v.string);
    // Mutate the source — dup should be independent.
    src[0] = 'X';
    try testing.expectEqualStrings("hi", v.string);
}

test "literalToValue: symbol maps to keyword and dupes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var src = [_]u8{ 'l', 'o', 'o', 'p' };
    const v = try literalToValue(arena.allocator(), .{ .symbol = src[0..] });
    try testing.expect(v == .keyword);
    try testing.expectEqualStrings("loop", v.keyword);
    src[0] = 'X';
    try testing.expectEqualStrings("loop", v.keyword);
}

test "literalToValue: vector of literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const xs = [_]Plugin.KeySpec.Default{
        .{ .number = 1 },
        .{ .number = 2 },
        .{ .number = 3 },
    };
    const v = try literalToValue(arena.allocator(), .{ .vector = xs[0..] });
    try testing.expect(v == .vector);
    try testing.expectEqual(@as(usize, 3), v.vector.len);
    try testing.expectEqual(@as(f64, 1), v.vector[0].number);
    try testing.expectEqual(@as(f64, 2), v.vector[1].number);
    try testing.expectEqual(@as(f64, 3), v.vector[2].number);
}

test "literalToValue: nested vector and string copy chain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inner = [_]Plugin.KeySpec.Default{
        .{ .string = "a" },
        .{ .string = "b" },
    };
    const outer = [_]Plugin.KeySpec.Default{
        .{ .vector = inner[0..] },
        .{ .number = 7 },
    };
    const v = try literalToValue(arena.allocator(), .{ .vector = outer[0..] });
    try testing.expect(v == .vector);
    try testing.expectEqual(@as(usize, 2), v.vector.len);
    try testing.expect(v.vector[0] == .vector);
    try testing.expectEqualStrings("a", v.vector[0].vector[0].string);
    try testing.expectEqualStrings("b", v.vector[0].vector[1].string);
    try testing.expectEqual(@as(f64, 7), v.vector[1].number);
}

test "literalToValue: expression arm returns NotALiteral" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const d = Plugin.KeySpec.Default{ .expression = .{
        .head = "*",
        .namespace = null,
        .arg_count = 2,
        .program = &.{},
    } };
    try testing.expectError(ConvertError.NotALiteral, literalToValue(arena.allocator(), d));
}

test "MaterializedDefaults.defaultFor: finds entry by form+key" {
    const entries = [_]Entry{
        .{
            .form = Ast.NodeIndex.from(7),
            .key = "radius",
            .value = .{ .number = 32 },
            .origin = .expression_default,
        },
        .{
            .form = Ast.NodeIndex.from(11),
            .key = "bg",
            .value = .{ .string = "black" },
            .origin = .literal_default,
        },
    };
    const overlay = MaterializedDefaults{ .entries = entries[0..] };

    const hit = overlay.defaultFor(Ast.NodeIndex.from(7), "radius");
    try testing.expect(hit != null);
    try testing.expectEqual(@as(f64, 32), hit.?.value.number);
    try testing.expectEqual(Origin.expression_default, hit.?.origin);

    const hit2 = overlay.defaultFor(Ast.NodeIndex.from(11), "bg");
    try testing.expect(hit2 != null);
    try testing.expectEqualStrings("black", hit2.?.value.string);
    try testing.expectEqual(Origin.literal_default, hit2.?.origin);
}

test "MaterializedDefaults.defaultFor: returns null on miss" {
    const entries = [_]Entry{
        .{
            .form = Ast.NodeIndex.from(7),
            .key = "radius",
            .value = .{ .number = 32 },
            .origin = .expression_default,
        },
    };
    const overlay = MaterializedDefaults{ .entries = entries[0..] };

    // Wrong form, right key.
    try testing.expect(overlay.defaultFor(Ast.NodeIndex.from(8), "radius") == null);
    // Right form, wrong key.
    try testing.expect(overlay.defaultFor(Ast.NodeIndex.from(7), "fps") == null);
    // Empty overlay.
    const empty = MaterializedDefaults{};
    try testing.expect(empty.defaultFor(Ast.NodeIndex.from(7), "radius") == null);
}

test "MaterializedDefaults.defaultFor: same key, different forms" {
    const entries = [_]Entry{
        .{
            .form = Ast.NodeIndex.from(1),
            .key = "size",
            .value = .{ .number = 16 },
            .origin = .literal_default,
        },
        .{
            .form = Ast.NodeIndex.from(2),
            .key = "size",
            .value = .{ .number = 32 },
            .origin = .literal_default,
        },
    };
    const overlay = MaterializedDefaults{ .entries = entries[0..] };

    try testing.expectEqual(@as(f64, 16), overlay.defaultFor(Ast.NodeIndex.from(1), "size").?.value.number);
    try testing.expectEqual(@as(f64, 32), overlay.defaultFor(Ast.NodeIndex.from(2), "size").?.value.number);
}

// ---------------------------------------------------------------------------
// materializeDefaults tests
// ---------------------------------------------------------------------------

/// Encode `src` (one root) into one-root Binary IR usable as an
/// `Expression.program`. Caller owns the returned `Ast.Bytes`.
fn encodeProgram(a: Allocator, src: [:0]const u8) !Ast.Bytes {
    const Parser = @import("Parser.zig");
    const Binary = @import("Binary.zig");
    var prog_tree = try Parser.parse(a, src);
    defer prog_tree.deinit();
    return Binary.toBinary(a, prog_tree, Binary.ToBinaryOptions.forMode(.compact));
}

test "materializeDefaults: literal default on omitted key" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(circle)");
    defer doc.deinit();

    const plugin: Plugin.Plugin = .{
        .name = "shapes",
        .forms = &.{.{
            .name = "circle",
            .keys = &.{.{
                .name = "radius",
                .default = .{ .number = 32 },
            }},
        }},
    };
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
    const e = result.materialized.entries[0];
    try testing.expectEqualStrings("radius", e.key);
    try testing.expect(e.value == .number);
    try testing.expectEqual(@as(f64, 32), e.value.number);
    try testing.expectEqual(Origin.literal_default, e.origin);
}

test "materializeDefaults: expression default evaluates against empty env" {
    const Parser = @import("Parser.zig");
    const core = @import("plugins/core.zig");
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(circle)");
    defer doc.deinit();

    const bytes = try encodeProgram(a, "(* 2 16)");
    defer bytes.deinit();

    const plugin: Plugin.Plugin = .{
        .name = "shapes",
        .forms = &.{.{
            .name = "circle",
            .keys = &.{.{
                .name = "radius",
                .default = .{ .expression = .{
                    .head = "*",
                    .namespace = null,
                    .arg_count = 2,
                    .program = bytes.data,
                } },
            }},
        }},
    };
    const schema = Schema.Schema.init(&.{ core.plugin, plugin });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
    const e = result.materialized.entries[0];
    try testing.expectEqualStrings("radius", e.key);
    try testing.expectEqual(@as(f64, 32), e.value.number);
    try testing.expectEqual(Origin.expression_default, e.origin);
}

test "materializeDefaults: explicit author value suppresses materialization" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(circle :radius 7)");
    defer doc.deinit();

    const plugin: Plugin.Plugin = .{
        .name = "shapes",
        .forms = &.{.{
            .name = "circle",
            .keys = &.{.{
                .name = "radius",
                .default = .{ .number = 32 },
            }},
        }},
    };
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try testing.expectEqual(@as(usize, 0), result.materialized.entries.len);
}

test "literalToValue: a vector literal nested past MAX_VALUE_DEPTH is DepthExceeded" {
    // The manifest parser admits 1024 levels; every Value consumer assumes
    // 256. Without this cap an overlay entry 300 deep reached
    // `deepCopyValueAssumeBounded`, whose DepthExceeded arm is unreachable.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var inner: Plugin.KeySpec.Default = .nil;
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        const xs = try a.alloc(Plugin.KeySpec.Default, 1);
        xs[0] = inner;
        inner = .{ .vector = xs };
    }
    try testing.expectError(error.DepthExceeded, literalToValue(a, inner));

    // Exactly at the cap: 255 vectors around a scalar is depth 256 — the
    // last level the copy accepts — so the boundary agrees with
    // `Expr.deepCopyValue` (a scalar at depth 256 is one too many).
    var at_cap: Plugin.KeySpec.Default = .nil;
    i = 0;
    while (i < Expr.MAX_VALUE_DEPTH - 1) : (i += 1) {
        const xs = try a.alloc(Plugin.KeySpec.Default, 1);
        xs[0] = at_cap;
        at_cap = .{ .vector = xs };
    }
    const v = try literalToValue(a, at_cap);
    _ = try Expr.deepCopyValueAssumeBounded(a, v);
}

test "materializeDefaults: a literal default nested past MAX_VALUE_DEPTH emits default_eval_failed" {
    const Parser = @import("Parser.zig");
    const core = @import("plugins/core.zig");
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(circle)");
    defer doc.deinit();

    var plugin_arena = std.heap.ArenaAllocator.init(a);
    defer plugin_arena.deinit();
    const pa = plugin_arena.allocator();
    var deep: Plugin.KeySpec.Default = .nil;
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        const xs = try pa.alloc(Plugin.KeySpec.Default, 1);
        xs[0] = deep;
        deep = .{ .vector = xs };
    }
    const plugin: Plugin.Plugin = .{
        .name = "shapes",
        .forms = &.{.{
            .name = "circle",
            .keys = &.{.{ .name = "radius", .default = deep }},
        }},
    };
    const schema = Schema.Schema.init(&.{ core.plugin, plugin });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    // Reported, not materialized — and never handed to a consumer that
    // assumes the 256-level cap.
    try testing.expectEqual(@as(usize, 0), result.materialized.entries.len);
    try testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.default_eval_failed, result.diagnostics[0].code);
}

test "materializeDefaults: expression failure emits default_eval_failed" {
    const Parser = @import("Parser.zig");
    const core = @import("plugins/core.zig");
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(circle)");
    defer doc.deinit();

    // Division by zero — the simplest core-arithmetic failure that
    // can't be reframed as form-as-data. (Unknown heads now build a
    // Value.form per the v2 form-as-data pass-through, so the prior
    // `(undefined-fn 1)` style no longer triggers eval failure.)
    const bytes = try encodeProgram(a, "(/ 1 0)");
    defer bytes.deinit();

    const plugin: Plugin.Plugin = .{
        .name = "shapes",
        .forms = &.{.{
            .name = "circle",
            .keys = &.{.{
                .name = "radius",
                .default = .{ .expression = .{
                    .head = "/",
                    .namespace = null,
                    .arg_count = 2,
                    .program = bytes.data,
                } },
            }},
        }},
    };
    const schema = Schema.Schema.init(&.{ core.plugin, plugin });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 0), result.materialized.entries.len);
    try testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    const d = result.diagnostics[0];
    try testing.expectEqual(Ast.Diagnostic.Code.default_eval_failed, d.code);
    try testing.expectEqual(Ast.Diagnostic.Severity.err, d.severity);
    try testing.expectEqual(@as(usize, 3), d.path.len);
    try testing.expectEqualStrings("circle", d.path[0]);
    try testing.expectEqualStrings("radius", d.path[1]);
    try testing.expectEqualStrings("default", d.path[2]);
}

test "materializeDefaults: two omitted instances share cached expression value" {
    const Parser = @import("Parser.zig");
    const core = @import("plugins/core.zig");
    const a = testing.allocator;
    // `scene` isn't declared as a form — the walk still recurses into
    // its positional children, materializing each `(circle)` instance.
    var doc = try Parser.parse(a, "(scene (circle) (circle))");
    defer doc.deinit();

    const bytes = try encodeProgram(a, "(* 2 16)");
    defer bytes.deinit();

    const plugin: Plugin.Plugin = .{
        .name = "shapes",
        .forms = &.{.{
            .name = "circle",
            .keys = &.{.{
                .name = "radius",
                .default = .{ .expression = .{
                    .head = "*",
                    .namespace = null,
                    .arg_count = 2,
                    .program = bytes.data,
                } },
            }},
        }},
    };
    const schema = Schema.Schema.init(&.{ core.plugin, plugin });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try testing.expectEqual(@as(usize, 2), result.materialized.entries.len);
    // Both entries point at distinct (form, key) tuples but share the
    // evaluated `32`.
    try testing.expect(result.materialized.entries[0].form != result.materialized.entries[1].form);
    try testing.expectEqual(@as(f64, 32), result.materialized.entries[0].value.number);
    try testing.expectEqual(@as(f64, 32), result.materialized.entries[1].value.number);
    try testing.expectEqual(Origin.expression_default, result.materialized.entries[0].origin);
    try testing.expectEqual(Origin.expression_default, result.materialized.entries[1].origin);
}

test "materializeDefaults: string-default cache aliases value across instances" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(scene (circle) (circle))");
    defer doc.deinit();

    const plugin: Plugin.Plugin = .{
        .name = "shapes",
        .forms = &.{.{
            .name = "circle",
            .keys = &.{.{
                .name = "fill",
                .default = .{ .string = "red" },
            }},
        }},
    };
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 2), result.materialized.entries.len);
    const s0 = result.materialized.entries[0].value.string;
    const s1 = result.materialized.entries[1].value.string;
    try testing.expectEqualStrings("red", s0);
    try testing.expectEqualStrings("red", s1);
    // Cache reuse: both entries point at the same arena bytes.
    try testing.expectEqual(@intFromPtr(s0.ptr), @intFromPtr(s1.ptr));
}

test "materializeDefaults: nested form recurses through unknown parent" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(scene (circle))");
    defer doc.deinit();

    const plugin: Plugin.Plugin = .{
        .name = "shapes",
        .forms = &.{.{
            .name = "circle",
            .keys = &.{.{
                .name = "radius",
                .default = .{ .number = 16 },
            }},
        }},
    };
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
    try testing.expectEqualStrings("radius", result.materialized.entries[0].key);
    try testing.expectEqual(@as(f64, 16), result.materialized.entries[0].value.number);
}

test "materializeDefaults: nested form inside kvpair value materializes" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    // The badge form carries a `:shape` kvpair whose value is a circle
    // form. The walker must descend into the kvpair value.
    var doc = try Parser.parse(a, "(badge :shape (circle))");
    defer doc.deinit();

    const plugin: Plugin.Plugin = .{
        .name = "shapes",
        .forms = &.{ .{
            .name = "badge",
        }, .{
            .name = "circle",
            .keys = &.{.{
                .name = "radius",
                .default = .{ .number = 8 },
            }},
        } },
    };
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
    try testing.expectEqualStrings("radius", result.materialized.entries[0].key);
    try testing.expectEqual(@as(f64, 8), result.materialized.entries[0].value.number);
}

/// `canvas.:shape` declares a local `circle` (`:r`, defaulted) beside a
/// global `circle` (`:radius`, defaulted) built to be shadowed, a
/// local-only `rect`, and a global `line` reachable by the additive
/// fallback. The shape of `examples/plugins/local-forms/plugin.sjon`,
/// with defaults added — this module only ever sees defaulted keys.
fn shadowingLocalsPlugin() Plugin.Plugin {
    return .{
        .name = "shapes",
        .forms = &.{
            .{
                .name = "canvas",
                .keys = &.{.{
                    .name = "shape",
                    .value_type = .form,
                    .local_forms = &.{
                        .{
                            .name = "circle",
                            .keys = &.{.{ .name = "r", .default = .{ .number = 1 } }},
                        },
                        .{
                            .name = "rect",
                            .keys = &.{.{ .name = "w", .default = .{ .number = 2 } }},
                        },
                    },
                }},
            },
            .{
                .name = "circle",
                .keys = &.{.{ .name = "radius", .default = .{ .number = 9 } }},
            },
            .{
                .name = "line",
                .keys = &.{.{ .name = "width", .default = .{ .number = 7 } }},
            },
        },
    };
}

test "materializeDefaults: a slot-local form shadows the global it hides" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(canvas :shape (circle))");
    defer doc.deinit();

    const plugin = shadowingLocalsPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    // The local `circle` declares `:r`; the global one declares
    // `:radius`. Materializing `:radius` here would splice a key the
    // validator reports as `unknown_key` into this very form.
    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
    try testing.expectEqualStrings("r", result.materialized.entries[0].key);
    try testing.expectEqual(@as(f64, 1), result.materialized.entries[0].value.number);
}

test "materializeDefaults: a local-only head materializes with no global to fall back to" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(canvas :shape (rect))");
    defer doc.deinit();

    const plugin = shadowingLocalsPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
    try testing.expectEqualStrings("w", result.materialized.entries[0].key);
    try testing.expectEqual(@as(f64, 2), result.materialized.entries[0].value.number);
}

test "materializeDefaults: the additive global fallback still materializes" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    // `line` is global-only; a local-forms slot falls back to the
    // catalog rather than closing over its own registry.
    var doc = try Parser.parse(a, "(canvas :shape (line))");
    defer doc.deinit();

    const plugin = shadowingLocalsPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
    try testing.expectEqualStrings("width", result.materialized.entries[0].key);
}

test "materializeDefaults: a qualified head bypasses the slot's locals" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    // `shapes/circle` names the global explicitly — the same bypass
    // `Validator.validateFormHead` step 0 applies.
    var doc = try Parser.parse(a, "(canvas :shape (shapes/circle))");
    defer doc.deinit();

    const plugin = shadowingLocalsPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
    try testing.expectEqualStrings("radius", result.materialized.entries[0].key);
}

test "materializeDefaults: a positional slot-local form resolves local-first" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    // The positional carrier: `frame`'s own `local_forms` scope its
    // form-shaped positional children (`FormSpec.local_forms`), not a
    // key's.
    var doc = try Parser.parse(a, "(frame (circle))");
    defer doc.deinit();

    const plugin: Plugin.Plugin = .{
        .name = "shapes",
        .forms = &.{
            .{
                .name = "frame",
                .local_forms = &.{.{
                    .name = "circle",
                    .keys = &.{.{ .name = "r", .default = .{ .number = 1 } }},
                }},
            },
            .{
                .name = "circle",
                .keys = &.{.{ .name = "radius", .default = .{ .number = 9 } }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
    try testing.expectEqualStrings("r", result.materialized.entries[0].key);
}

test "materializeDefaults: an unresolved parent still hands its child the global catalog" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    // `mystery` resolves to nothing, so it puts no locals in scope and
    // the child falls back to the catalog — the validator's rule, which
    // pushes a null registry rather than writing the subtree off.
    var doc = try Parser.parse(a, "(mystery (circle))");
    defer doc.deinit();

    const plugin = shadowingLocalsPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
    try testing.expectEqualStrings("radius", result.materialized.entries[0].key);
}

/// `widget`'s `special` variant declares `:shape`, whose slot declares a
/// local `circle` (`:r`) shadowing the global `circle` (`:radius`). The
/// discriminant `:kind` carries a default of its own, so the axis-D case —
/// a variant unlocked by a default rather than by written text — is
/// reachable from the same fixture.
fn variantLocalsPlugin() Plugin.Plugin {
    return .{
        .name = "ui",
        .forms = &.{
            .{
                .name = "widget",
                .keys = &.{.{
                    .name = "kind",
                    .value_type = .symbol,
                    .default = .{ .symbol = "special" },
                }},
                .discriminant_name = "kind",
                .discriminant_idx = 0,
                .variants = &.{.{
                    .when = &.{"special"},
                    .keys = &.{.{
                        .name = "shape",
                        .value_type = .form,
                        .local_forms = &.{.{
                            .name = "circle",
                            .keys = &.{.{ .name = "r", .default = .{ .number = 1 } }},
                        }},
                    }},
                }},
            },
            .{
                .name = "circle",
                .keys = &.{.{ .name = "radius", .default = .{ .number = 9 } }},
            },
        },
    };
}

test "materializeDefaults: a variant key's local forms scope its value's head" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    // `:kind special` precedes `:shape`, so the validator accepts `:shape`
    // and scopes its locals — and so must the overlay, or it splices the
    // shadowed global's `:radius` into a form that declares `:r`.
    var doc = try Parser.parse(a, "(widget :kind special :shape (circle))");
    defer doc.deinit();

    const plugin = variantLocalsPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
    try testing.expectEqualStrings("r", result.materialized.entries[0].key);
    try testing.expectEqual(@as(f64, 1), result.materialized.entries[0].value.number);
}

test "materializeDefaults: a variant key ahead of its discriminant puts no locals in scope" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    // Same keys, written the other way round. The validator reports
    // `:shape` as `unknown_key` here (a variant key needs its discriminant
    // to precede it), and an unknown key puts nothing in scope — so the
    // head resolves against the global catalog.
    var doc = try Parser.parse(a, "(widget :shape (circle) :kind special)");
    defer doc.deinit();

    const plugin = variantLocalsPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
    try testing.expectEqualStrings("radius", result.materialized.entries[0].key);
}

test "materializeDefaults: a discriminant supplied by its own default still scopes the variant's locals" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    // Axis D: `:kind` is omitted, so the variant is selected by the value
    // this very walk materialized one step earlier. A validator handed this
    // overlay accepts `:shape` for exactly that reason
    // (`Validator.preresolveDiscriminantViaOverlay`), so the overlay has to
    // scope the slot the same way.
    var doc = try Parser.parse(a, "(widget :shape (circle))");
    defer doc.deinit();

    const plugin = variantLocalsPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    const widget = doc.root[0];
    // The discriminant's own default materialized — that is the value the
    // variant was selected by.
    const kind = result.materialized.defaultFor(widget, "kind").?;
    try testing.expectEqualStrings("special", kind.value.keyword);
    // And the local `circle` won its slot: `:r`, not the global `:radius`.
    const shape_kv = doc.formHeader(widget).children[0];
    const circle = doc.kvpairHeader(shape_kv).value;
    try testing.expectEqual(@as(usize, 2), result.materialized.entries.len);
    try testing.expectEqual(@as(f64, 1), result.materialized.defaultFor(circle, "r").?.value.number);
    try testing.expect(result.materialized.defaultFor(circle, "radius") == null);
}

test "materializeDefaults: a literal default records its manifest spelling" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(circle)");
    defer doc.deinit();

    const plugin: Plugin.Plugin = .{
        .name = "shapes",
        .forms = &.{.{
            .name = "circle",
            // A symbol default is the arm `Expr.Value` cannot carry: it
            // lands in the overlay as `.keyword`, so the entry's own
            // `literal` is the only faithful record of what the manifest
            // said.
            .keys = &.{.{ .name = "mode", .default = .{ .symbol = "fast" } }},
        }},
    };
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
    const e = result.materialized.entries[0];
    try testing.expect(e.literal != null);
    try testing.expectEqualStrings("fast", e.literal.?.symbol);
    try testing.expect(e.value == .keyword);
}

test "materializeDefaults: unknown form produces no entries and no diagnostics" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(mystery)");
    defer doc.deinit();

    // Empty schema: every form is unknown.
    const schema = Schema.Schema.init(&.{});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 0), result.materialized.entries.len);
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "materializeDefaults: key without default is left untouched" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(circle)");
    defer doc.deinit();

    const plugin: Plugin.Plugin = .{
        .name = "shapes",
        .forms = &.{.{
            .name = "circle",
            .keys = &.{
                .{ .name = "radius", .default = .{ .number = 32 } },
                .{ .name = "color" }, // no default
            },
        }},
    };
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
    try testing.expectEqualStrings("radius", result.materialized.entries[0].key);
}

/// `widget` is discriminated on `:kind`, which carries a default of its
/// own so the axis-D route is reachable. One defaulted common key
/// (`:color`) and two variants, each with one defaulted key — enough to
/// tell "the active variant's" apart from "every variant's".
fn variantDefaultsPlugin() Plugin.Plugin {
    return .{
        .name = "ui",
        .forms = &.{.{
            .name = "widget",
            .keys = &.{
                .{ .name = "kind", .value_type = .symbol, .default = .{ .symbol = "special" } },
                .{ .name = "color", .value_type = .symbol, .default = .{ .symbol = "red" } },
            },
            .discriminant_name = "kind",
            .discriminant_idx = 0,
            .variants = &.{
                .{
                    .when = &.{"special"},
                    .keys = &.{.{ .name = "size", .value_type = .number, .default = .{ .number = 10 } }},
                },
                .{
                    .when = &.{"plain"},
                    .keys = &.{.{ .name = "weight", .value_type = .number, .default = .{ .number = 1 } }},
                },
            },
        }},
    };
}

/// Run `src` against `variantDefaultsPlugin` and hand the caller the
/// overlay plus the `widget` node every assertion below keys on.
fn materializeWidget(
    a: Allocator,
    arena: Allocator,
    doc: *const Ast.Tree,
) Allocator.Error!Result {
    const plugin = variantDefaultsPlugin();
    const schema = Schema.Schema.init(&.{plugin});
    return materializeDefaults(a, arena, doc, doc.root, schema);
}

test "materializeDefaults: the active variant's defaults materialize beside the common ones" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    // `:kind special` selects the `special` variant and omits both the
    // common `:color` default and the variant-only `:size` default. The
    // Validator already treats the second as satisfied
    // (`effectiveOptional`), and `computeOverlayPresenceBitsets` /
    // `checkEffectiveRefLookups` already look for it in this overlay.
    var doc = try Parser.parse(a, "(widget :kind special)");
    defer doc.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeWidget(a, arena.allocator(), &doc);
    defer result.deinit(a);

    const widget = doc.root[0];
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try testing.expectEqual(@as(usize, 2), result.materialized.entries.len);
    try testing.expectEqualStrings("red", result.materialized.defaultFor(widget, "color").?.value.keyword);
    try testing.expectEqual(@as(f64, 10), result.materialized.defaultFor(widget, "size").?.value.number);
}

test "materializeDefaults: a discriminant supplied by its own default carries its variant's keys" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    // Axis D end to end: `:kind` is omitted, materialized as `special` by
    // the common-key pass, and read back one step later to pick the variant
    // whose `:size` is then materialized too. The ordering inside
    // `materializeForForm` is what makes this work.
    var doc = try Parser.parse(a, "(widget)");
    defer doc.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeWidget(a, arena.allocator(), &doc);
    defer result.deinit(a);

    const widget = doc.root[0];
    try testing.expectEqual(@as(usize, 3), result.materialized.entries.len);
    try testing.expectEqualStrings("special", result.materialized.defaultFor(widget, "kind").?.value.keyword);
    try testing.expectEqual(@as(f64, 10), result.materialized.defaultFor(widget, "size").?.value.number);
    try testing.expect(result.materialized.defaultFor(widget, "weight") == null);
}

test "materializeDefaults: only the active variant's keys materialize" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    var doc = try Parser.parse(a, "(widget :kind plain)");
    defer doc.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeWidget(a, arena.allocator(), &doc);
    defer result.deinit(a);

    const widget = doc.root[0];
    try testing.expectEqual(@as(usize, 2), result.materialized.entries.len);
    try testing.expectEqual(@as(f64, 1), result.materialized.defaultFor(widget, "weight").?.value.number);
    // `:size` belongs to the variant this instance is not in — writing it
    // would be `unknown_key`, so defaulting it would be worse.
    try testing.expect(result.materialized.defaultFor(widget, "size") == null);
}

test "materializeDefaults: a discriminant selecting no variant materializes no variant keys" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    // The author wrote the discriminant, so the default does not apply and
    // there is nothing to fall back to — `other` selects neither variant.
    var doc = try Parser.parse(a, "(widget :kind other)");
    defer doc.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeWidget(a, arena.allocator(), &doc);
    defer result.deinit(a);

    const widget = doc.root[0];
    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
    try testing.expect(result.materialized.defaultFor(widget, "color") != null);
    try testing.expect(result.materialized.defaultFor(widget, "size") == null);
    try testing.expect(result.materialized.defaultFor(widget, "weight") == null);
}

test "materializeDefaults: a variant key written ahead of its discriminant still suppresses its default" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    // `:size` here is `unknown_key` — a variant key needs its discriminant
    // to precede it — but the author did write it. Materializing over that
    // would put two values in one slot, so the presence scan is
    // position-independent, exactly as `emitVariantSweeps`' is.
    var doc = try Parser.parse(a, "(widget :size 4 :kind special)");
    defer doc.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeWidget(a, arena.allocator(), &doc);
    defer result.deinit(a);

    const widget = doc.root[0];
    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
    try testing.expect(result.materialized.defaultFor(widget, "color") != null);
    try testing.expect(result.materialized.defaultFor(widget, "size") == null);
}

test "materializeDefaults: a variant key colliding with a common key yields one entry" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    // `variant_key_collision` is a schema-aggregate *diagnostic*
    // (`Schema.validateForms`), not a rejection, and `Host.validateDocument`
    // walks on past the aggregate phase — so this spec reaches the overlay
    // with `:step` declared twice. Two entries for one slot would reach
    // `EffectiveDocument.formInsertion` as a duplicate kvpair, turning a bad
    // schema into an effective document the validator rejects for
    // `duplicate_key`. The common key wins.
    var doc = try Parser.parse(a, "(track :kind kick)");
    defer doc.deinit();

    const plugin: Plugin.Plugin = .{
        .name = "probe",
        .forms = &.{.{
            .name = "track",
            .keys = &.{
                .{ .name = "kind", .value_type = .symbol },
                .{ .name = "step", .value_type = .number, .default = .{ .number = 1 } },
            },
            .discriminant_name = "kind",
            .discriminant_idx = 0,
            .variants = &.{.{
                .when = &.{"kick"},
                .keys = &.{.{ .name = "step", .value_type = .number, .default = .{ .number = 99 } }},
            }},
        }},
    };
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
    try testing.expectEqual(@as(f64, 1), result.materialized.entries[0].value.number);
}

/// `host` holds a form in each of two `:type any` slots: `:body` is
/// `walk_opaque`, `:panel` is not. The global `circle` carries a
/// defaulted `:radius`, so a descent into either slot shows up as an
/// entry and a stopped one shows up as its absence.
fn opaqueSlotPlugin() Plugin.Plugin {
    return .{
        .name = "shapes",
        .forms = &.{
            .{
                .name = "host",
                .keys = &.{
                    .{ .name = "body", .value_type = .any, .walk_opaque = true },
                    .{ .name = "panel", .value_type = .any },
                },
            },
            .{
                .name = "circle",
                .keys = &.{.{ .name = "radius", .default = .{ .number = 32 } }},
            },
        },
    };
}

test "materializeDefaults: a walk_opaque slot stops the descent" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    const plugin = opaqueSlotPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    {
        // `validateOneTree` abandons the whole kvpair frame here, so it
        // never sees this `circle`. An overlay that materialized `:radius`
        // anyway would have `sjon effective` write a schema-supplied key
        // into the region the schema was told not to interpret.
        var doc = try Parser.parse(a, "(host :body (circle))");
        defer doc.deinit();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
        defer result.deinit(a);
        try testing.expectEqual(@as(usize, 0), result.materialized.entries.len);
    }
    {
        // Control: the same value in the sibling slot, which is not opaque.
        var doc = try Parser.parse(a, "(host :panel (circle))");
        defer doc.deinit();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
        defer result.deinit(a);
        try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
        try testing.expectEqualStrings("radius", result.materialized.entries[0].key);
    }
}

test "materializeDefaults: an unknown key is not opaque" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    // Opaque is something a *matched* key says. `:mystery` matches
    // nothing — it is `unknown_key` — and an unknown key says nothing, so
    // the validator pushes its value with a null registry and this walk
    // descends the same way.
    var doc = try Parser.parse(a, "(host :mystery (circle))");
    defer doc.deinit();

    const plugin = opaqueSlotPlugin();
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
    try testing.expectEqualStrings("radius", result.materialized.entries[0].key);
}

test "materializeDefaults: a variant key's walk_opaque is honoured too" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    // The slot resolution behind this is `slotKey`, so an opaque *variant*
    // key stops the descent exactly as a common one does — once its
    // discriminant has selected the variant it sits in.
    var doc = try Parser.parse(a, "(host :kind rich :body (circle))");
    defer doc.deinit();

    const plugin: Plugin.Plugin = .{
        .name = "shapes",
        .forms = &.{
            .{
                .name = "host",
                .keys = &.{.{ .name = "kind", .value_type = .symbol }},
                .discriminant_name = "kind",
                .discriminant_idx = 0,
                .variants = &.{.{
                    .when = &.{"rich"},
                    .keys = &.{.{ .name = "body", .value_type = .any, .walk_opaque = true }},
                }},
            },
            .{
                .name = "circle",
                .keys = &.{.{ .name = "radius", .default = .{ .number = 32 } }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    try testing.expectEqual(@as(usize, 0), result.materialized.entries.len);
}

test "materializeDefaults: an opaque slot's failing expression default is not reported" {
    const Parser = @import("Parser.zig");
    const core = @import("plugins/core.zig");
    const a = testing.allocator;

    const bytes = try encodeProgram(a, "(/ 1 0)");
    defer bytes.deinit();

    const plugin: Plugin.Plugin = .{
        .name = "shapes",
        .forms = &.{
            .{
                .name = "host",
                .keys = &.{
                    .{ .name = "body", .value_type = .any, .walk_opaque = true },
                    .{ .name = "panel", .value_type = .any },
                },
            },
            .{
                .name = "circle",
                .keys = &.{.{
                    .name = "radius",
                    .default = .{ .expression = .{
                        .head = "/",
                        .namespace = null,
                        .arg_count = 2,
                        .program = bytes.data,
                    } },
                }},
            },
        },
    };
    const schema = Schema.Schema.init(&.{ core.plugin, plugin });

    {
        // Nothing is materialized in there, so nothing can fail in there —
        // the `default_eval_failed` this schema key earns elsewhere is not
        // earned here.
        var doc = try Parser.parse(a, "(host :body (circle))");
        defer doc.deinit();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
        defer result.deinit(a);
        try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    }
    {
        var doc = try Parser.parse(a, "(host :panel (circle))");
        defer doc.deinit();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
        defer result.deinit(a);
        try testing.expectEqual(@as(usize, 1), result.diagnostics.len);
        try testing.expectEqual(Ast.Diagnostic.Code.default_eval_failed, result.diagnostics[0].code);
    }
}
