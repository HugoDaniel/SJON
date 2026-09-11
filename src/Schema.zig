//! Schema — comptime aggregator over one or more `Plugin` descriptors.
//!
//! A `Schema` is the single source of truth the validator and evaluator
//! consult to resolve form heads, expression functions, and value kinds.
//! Lookup honours both bare and namespaced surface forms:
//!
//!   * Bare:        `(verb …)`        — schema searches every plugin and
//!                                       returns `.ambiguous` when more
//!                                       than one plugin claims `verb`.
//!   * Qualified:   `(masagin/verb …)` — schema looks up only inside the
//!                                       plugin whose `name == "masagin"`.
//!
//! All three lookups (`lookupForm`, `lookupExprFunc`, `lookupValueKind`)
//! return the same generic `LookupResult(Hit)` shape: `.found(Hit)` /
//! `.not_found` / `.ambiguous(Ambiguous)` and all three take a
//! `namespace: ?[]const u8` second argument. Value-kind references in
//! manifests use the same `<plugin>/<kind>` syntax as form heads and
//! expr-func heads — an `.ambiguous` bare lookup is recovered by
//! qualifying the reference with the owning plugin's name.

const std = @import("std");
const Plugin = @import("Plugin.zig");
const Ast = @import("Ast.zig");

const Allocator = std.mem.Allocator;

/// Aggregate view over a list of plugins. Built at comptime by
/// `Schema.init(&.{ plugin_a, plugin_b, … })` and consumed by the
/// validator and expression evaluator.
pub const Schema = struct {
    /// The plugins this schema aggregates, in declaration order. Bare
    /// lookups walk this list; qualified lookups select by `Plugin.name`.
    plugins: []const Plugin.Plugin,

    pub fn init(plugins: []const Plugin.Plugin) Schema {
        const self: Schema = .{ .plugins = plugins };
        self.assertFormKeyCaps();
        return self;
    }

    /// Panic if any form exceeds `Plugin.MAX_FORM_KEYS`, or if any
    /// slot-local form declares `:lowering`. The required-key bitset in the
    /// validator is u64-backed; over-cap forms would silently drop tracking
    /// past index 63. A local's `:lowering` would be silently dead:
    /// `validateLowering` and the produces graph walk top-level forms only,
    /// and the lowering worklist resolves a local head to its local body,
    /// never to a hook (`ManifestLoader` rejects it as `invalid_manifest`;
    /// this is the mirror for static plugin literals). Recurses through
    /// variant key sets and both slot-local form carriers
    /// (`KeySpec.local_forms` and `FormSpec.local_forms`) so an over-cap or
    /// lowerable nested form trips here at `Schema.init` rather than
    /// corrupting required-key tracking — or lying about lowering — at
    /// validate time. Recursion is bounded by `Plugin.MAX_LOCAL_FORM_DEPTH`
    /// (loader-enforced for manifests) and by the finite, developer-authored
    /// shape of static plugin literals — this runs at schema construction,
    /// not on the user-input walk path.
    pub fn assertFormKeyCaps(self: Schema) void {
        for (self.plugins) |*p| {
            for (p.forms) |*f| {
                assertOneFormKeyCaps(p.name, f, false);
            }
        }
    }

    fn assertOneFormKeyCaps(plugin_name: []const u8, f: *const Plugin.FormSpec, is_local: bool) void {
        if (f.keys.len > Plugin.MAX_FORM_KEYS) {
            std.debug.panic(
                "plugin '{s}' form '{s}' has {d} keys; Plugin.MAX_FORM_KEYS is {d}",
                .{ plugin_name, f.name, f.keys.len, Plugin.MAX_FORM_KEYS },
            );
        }
        if (is_local and f.lowering != null) {
            std.debug.panic(
                "plugin '{s}' slot-local form '{s}' declares lowering; a slot-local form cannot lower",
                .{ plugin_name, f.name },
            );
        }
        for (f.keys) |*k| {
            for (k.local_forms) |*lf| assertOneFormKeyCaps(plugin_name, lf, true);
        }
        // Positional slot-local forms (FormSpec.local_forms) — the positional
        // carrier, recursed the same as the keyed one above.
        for (f.local_forms) |*lf| assertOneFormKeyCaps(plugin_name, lf, true);
        if (f.variants) |variants| {
            for (variants) |*v| {
                if (v.keys.len > Plugin.MAX_FORM_KEYS) {
                    std.debug.panic(
                        "plugin '{s}' form '{s}' variant '{s}' has {d} keys; Plugin.MAX_FORM_KEYS is {d}",
                        .{ plugin_name, f.name, v.when[0], v.keys.len, Plugin.MAX_FORM_KEYS },
                    );
                }
                for (v.keys) |*k| {
                    for (k.local_forms) |*lf| assertOneFormKeyCaps(plugin_name, lf, true);
                }
            }
        }
    }

    /// True if a plugin named `ns` is present in the loaded aggregate.
    /// Lets callers distinguish "qualified head into an absent plugin"
    /// from "qualified head into a present plugin that lacks the form" —
    /// `lookupForm` collapses both to `.not_found`.
    pub fn hasPlugin(self: Schema, ns: []const u8) bool {
        for (self.plugins) |*p| {
            if (std.mem.eql(u8, p.name, ns)) return true;
        }
        return false;
    }

    /// Resolve `name` (optionally qualified by `namespace`) against a single
    /// per-plugin catalog — `forms`, `expr_funcs`, or `value_kinds`. Backs
    /// `lookupForm` / `lookupExprFunc` / `lookupValueKind`, which differ only
    /// in the catalog field walked and how a match packages into `Hit`.
    ///
    ///   * Qualified: consult only the plugin whose `name == namespace`;
    ///     first name match wins, else `.not_found`.
    ///   * Bare: walk every plugin. A single owner → `.found`; two or more →
    ///     `.ambiguous` carrying each claimant (capped at `MAX_AMBIGUOUS`).
    ///
    /// `first_plugin` is tracked alongside `first` because a value-kind `Hit`
    /// is just the kind pointer and doesn't carry its owning plugin.
    fn lookupGeneric(
        self: Schema,
        comptime Item: type,
        comptime items_field: []const u8,
        comptime Hit: type,
        comptime makeHit: fn (*const Plugin.Plugin, *const Item) Hit,
        name: []const u8,
        namespace: ?[]const u8,
    ) LookupResult(Hit) {
        if (namespace) |ns| {
            for (self.plugins) |*p| {
                if (!std.mem.eql(u8, p.name, ns)) continue;
                for (@field(p, items_field)) |*it| {
                    if (std.mem.eql(u8, it.name, name)) {
                        return .{ .found = makeHit(p, it) };
                    }
                }
                return .not_found;
            }
            return .not_found;
        }
        // Bare lookup: walk every plugin; collect collisions.
        var first: ?Hit = null;
        var first_plugin: ?*const Plugin.Plugin = null;
        var amb: Ambiguous = .{ .buf = undefined, .len = 0 };
        for (self.plugins) |*p| {
            for (@field(p, items_field)) |*it| {
                if (!std.mem.eql(u8, it.name, name)) continue;
                if (first == null) {
                    first = makeHit(p, it);
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
        if (first) |h| return .{ .found = h };
        return .not_found;
    }

    pub fn lookupForm(
        self: Schema,
        name: []const u8,
        namespace: ?[]const u8,
    ) FormLookup {
        const make = struct {
            fn f(p: *const Plugin.Plugin, form: *const Plugin.FormSpec) FormHit {
                return .{ .plugin = p, .form = form };
            }
        }.f;
        return self.lookupGeneric(Plugin.FormSpec, "forms", FormHit, make, name, namespace);
    }

    pub fn lookupExprFunc(
        self: Schema,
        name: []const u8,
        namespace: ?[]const u8,
    ) ExprLookup {
        const make = struct {
            fn f(p: *const Plugin.Plugin, func: *const Plugin.ExprFunc) ExprHit {
                return .{ .plugin = p, .func = func };
            }
        }.f;
        return self.lookupGeneric(Plugin.ExprFunc, "expr_funcs", ExprHit, make, name, namespace);
    }

    /// Run one aggregate-phase walk under a throwaway scratch arena, then copy
    /// the collected diagnostics out into `a`. The scratch arena is why a
    /// mid-walk OOM frees every partial allocation atomically — only a clean
    /// run reaches `dupeAggregateDiagnostics`, which copies out into `a`.
    /// `body` receives `(self, scratch_allocator, diags_list_to_append_into)`.
    /// Shared by all five aggregate validators (`validateCrossRefs` …
    /// `validateDefaults`), so the arena/dupe envelope lives in one place and
    /// each validator supplies only its walk.
    ///
    /// Caller owns the returned slice and every string within (allocated from
    /// `a`); free via `Host.freeAggregateDiagnostics` or an arena.
    fn runInScratch(
        self: Schema,
        a: Allocator,
        comptime body: fn (Schema, Allocator, *std.ArrayList(Ast.Diagnostic)) Allocator.Error!void,
    ) Allocator.Error![]const Ast.Diagnostic {
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();

        var diags: std.ArrayList(Ast.Diagnostic) = .empty;
        try body(self, scratch.allocator(), &diags);
        return dupeAggregateDiagnostics(a, diags.items);
    }

    /// Walk every plugin's value-kinds, resolving each `:cross-ref :target`
    /// against the aggregated form catalog. Emits diagnostics for unresolved,
    /// ambiguous, or mistyped targets. Run once at schema-build time —
    /// not on the per-keystroke validate path, so the diagnostic strings
    /// can be verbose without contributing to the validator's binary size.
    ///
    /// Caller owns the returned slice and every string within (allocated
    /// from `a`). Diagnostic `.span` is `{0, 0}` because the aggregate phase
    /// has no access to the originating manifest's source tree; the path
    /// `[<plugin>, <kind>, cross-ref]` identifies the offender.
    pub fn validateCrossRefs(
        self: Schema,
        a: Allocator,
    ) Allocator.Error![]const Ast.Diagnostic {
        return self.runInScratch(a, struct {
            fn body(s: Schema, sa: Allocator, diags: *std.ArrayList(Ast.Diagnostic)) Allocator.Error!void {
                // `winners` replays `Validator.collectCrossRefTargets`'
                // first-wins map in the same plugin × value-kind order, so
                // "the first spec" here is the spec the registry will
                // actually be built from at validate time. Both walks must
                // keep that order for the warning to name the right loser.
                var winners: std.StringHashMapUnmanaged(RegistrySpec) = .empty;
                for (s.plugins) |*plugin| {
                    for (plugin.value_kinds) |*kind| {
                        const cr = kind.cross_ref orelse continue;
                        try checkCrossRef(s, sa, diags, plugin, kind, cr);
                        try checkTargetCollapse(s, sa, diags, &winners, plugin, kind, cr);
                    }
                }
            }
        }.body);
    }

    /// Walk every plugin's value-kinds, resolving each `:union`
    /// alternative against the aggregated value-kind catalog. Emits
    /// `unknown_element_kind` for unresolved alternatives,
    /// `ambiguous_element_kind` for cross-plugin collisions, and
    /// `nested_union` when an alternative resolves to another `union_of`
    /// kind (forbidden so dispatch stays a flat loop). Run alongside
    /// `validateCrossRefs` at schema-build time; safe to ignore on the
    /// per-keystroke validate path.
    ///
    /// Caller owns the returned slice and every string within (allocated
    /// from `a`). Diagnostic `.span` is `{0, 0}`; the path
    /// `[<plugin>, <kind>, union]` identifies the offender.
    pub fn validateUnions(
        self: Schema,
        a: Allocator,
    ) Allocator.Error![]const Ast.Diagnostic {
        return self.runInScratch(a, struct {
            fn body(s: Schema, sa: Allocator, diags: *std.ArrayList(Ast.Diagnostic)) Allocator.Error!void {
                for (s.plugins) |*plugin| {
                    for (plugin.value_kinds) |*kind| {
                        const us = kind.union_of orelse continue;
                        try checkUnion(s, sa, diags, plugin, kind, us);
                    }
                }
            }
        }.body);
    }

    /// Walk every plugin's forms; for each discriminated form, verify
    /// the discriminant key resolves to a closed `MemberSet`, every
    /// variant's `:when` is a member, and no key name collides between
    /// the common-keys list and any variant (or across variants). Run
    /// alongside `validateCrossRefs` / `validateUnions` at schema-build
    /// time.
    ///
    /// Caller owns the returned slice and every string within (allocated
    /// from `a`). Diagnostic `.span` is `{0, 0}`; the path
    /// `[<plugin>, <form>, discriminant|variant]` identifies the offender.
    pub fn validateForms(
        self: Schema,
        a: Allocator,
    ) Allocator.Error![]const Ast.Diagnostic {
        return self.runInScratch(a, struct {
            fn body(s: Schema, sa: Allocator, diags: *std.ArrayList(Ast.Diagnostic)) Allocator.Error!void {
                for (s.plugins) |*plugin| {
                    for (plugin.forms) |*form| {
                        if (form.discriminant_idx == null) continue;
                        try checkForm(s, sa, diags, plugin, form);
                    }
                }
            }
        }.body);
    }

    /// Walk every plugin's forms; for each form with a `:lowering`
    /// declaration, resolve every `:produces` entry against the
    /// aggregated form catalog (qualified or bare, per the usual
    /// resolution rules). Emits `unknown_form` for unresolved heads and
    /// `ambiguous_form` for bare entries that collide across plugins.
    /// Run alongside `validateCrossRefs` / `validateUnions` /
    /// `validateForms` at schema-build time; safe to ignore on the
    /// per-keystroke validate path.
    ///
    /// Caller owns the returned slice and every string within (allocated
    /// from `a`). Diagnostic `.span` is `{0, 0}`; the path
    /// `[<plugin>, <form>, lowering]` identifies the offender.
    pub fn validateLowering(
        self: Schema,
        a: Allocator,
    ) Allocator.Error![]const Ast.Diagnostic {
        return self.runInScratch(a, struct {
            fn body(s: Schema, sa: Allocator, diags: *std.ArrayList(Ast.Diagnostic)) Allocator.Error!void {
                for (s.plugins) |*plugin| {
                    for (plugin.forms) |*form| {
                        const low = form.lowering orelse continue;
                        try checkLowering(s, sa, diags, plugin, form, low);
                    }
                }
                // Second phase (inside the same scratch): the `:produces`
                // edges form a graph whose cycles would make staged lowering
                // non-terminating. Reject them statically with
                // `lowering_cycle`, reusing the same 3-colour DFS the
                // `:acyclic` cross-ref check runs.
                try checkLoweringCycles(s, sa, diags);
            }
        }.body);
    }

    /// Walk every plugin's forms' keys; for each key whose `:default`
    /// is `.expression`-shaped, classify the head via
    /// `Validator.resolveFormExpressionBinary` and compare the declared
    /// result type to the key's `value_type` via
    /// `Validator.declaredResultMatchesExpected`. Emits
    /// `wrong_underlying` on a `.no` verdict or when the head resolves
    /// to a data form rather than an expression. Opaque (`.unknown`
    /// verdict, null declared result, unresolved head) defers — the
    /// validator's runtime-deferral policy for nested expressions.
    /// Run alongside the other aggregate-phase validators at schema-
    /// build time.
    ///
    /// Caller owns the returned slice and every string within (allocated
    /// from `a`). Diagnostic `.span` is `{0, 0}`; the path
    /// `[<plugin>, <form>, <key>, "default"]` identifies the offender.
    pub fn validateDefaults(
        self: Schema,
        a: Allocator,
    ) Allocator.Error![]const Ast.Diagnostic {
        return self.runInScratch(a, struct {
            fn body(s: Schema, sa: Allocator, diags: *std.ArrayList(Ast.Diagnostic)) Allocator.Error!void {
                for (s.plugins) |*plugin| {
                    for (plugin.forms) |*form| {
                        for (form.keys) |*key| {
                            const dflt = key.default orelse continue;
                            if (dflt != .expression) continue;
                            try checkDefaultExpression(s, sa, diags, plugin, form, key, dflt.expression);
                        }
                    }
                }
            }
        }.body);
    }

    /// Find a plugin-defined value kind by name, optionally qualified
    /// with a plugin namespace.
    ///
    /// When `namespace` is non-null, only the named plugin is consulted —
    /// cross-plugin collisions are filtered out by construction. When
    /// `namespace` is null, every plugin is walked and cross-plugin
    /// collisions surface as `.ambiguous`; within-plugin duplicates
    /// resolve first-match (only the plugin's own author can fix those,
    /// and qualifying with a namespace doesn't help — they share one).
    ///
    /// Mirrors `lookupForm` / `lookupExprFunc` so all three vocabularies
    /// follow the same bare-or-qualified rule.
    pub fn lookupValueKind(
        self: Schema,
        name: []const u8,
        namespace: ?[]const u8,
    ) ValueKindLookup {
        const make = struct {
            fn f(_: *const Plugin.Plugin, v: *const Plugin.ValueKind) *const Plugin.ValueKind {
                return v;
            }
        }.f;
        return self.lookupGeneric(Plugin.ValueKind, "value_kinds", *const Plugin.ValueKind, make, name, namespace);
    }

    /// Find a plugin-declared cross-ref provider by name, optionally
    /// qualified with a plugin namespace.
    ///
    /// The fourth vocabulary, following the same bare-or-qualified rule as
    /// `lookupForm` / `lookupExprFunc` / `lookupValueKind`. Unlike a
    /// value-kind hit, this one keeps the owning plugin: the canonical
    /// `<plugin>/<provider>` spelling is the extraction table's key half,
    /// so a bare reference still has to name its namespace once resolved.
    pub fn lookupCrossRefProvider(
        self: Schema,
        name: []const u8,
        namespace: ?[]const u8,
    ) CrossRefProviderLookup {
        const make = struct {
            fn f(p: *const Plugin.Plugin, cp: *const Plugin.CrossRefProvider) CrossRefProviderHit {
                return .{ .plugin = p, .provider = cp };
            }
        }.f;
        return self.lookupGeneric(
            Plugin.CrossRefProvider,
            "cross_ref_providers",
            CrossRefProviderHit,
            make,
            name,
            namespace,
        );
    }

    /// Resolve a possibly-qualified form spelling (`phrase`, `audio/phrase`)
    /// to its canonical `<plugin>/<form>` name. Returns null when the
    /// spelling doesn't resolve cleanly (`not_found` / `ambiguous`) — every
    /// caller is downstream of `validateCrossRefs`, which has already
    /// emitted the diagnostic for those.
    ///
    /// Canonical names are the cross-ref registry's keys, so this is the one
    /// place the `<plugin>/<name>` spelling is minted: the validator's
    /// index, its scope chain, and the aggregate collapse check all compare
    /// strings produced here. Allocates on `a`. O(catalog size).
    pub fn canonicalFormName(
        self: Schema,
        a: Allocator,
        spelling: []const u8,
    ) Allocator.Error!?[]const u8 {
        const q = Plugin.splitQualified(spelling);
        const hit = switch (self.lookupForm(q.name, q.namespace)) {
            .found => |h| h,
            else => return null,
        };
        return try std.fmt.allocPrint(a, "{s}/{s}", .{ hit.plugin.name, hit.form.name });
    }

    /// The name-registry **bucket** a cross-ref's names live in, or null
    /// when the cross-ref cannot contribute one (see below). Allocates on
    /// `a` only for a multi-target group; a single-target cross-ref pays
    /// exactly what `canonicalFormName` costs, which is what it paid
    /// before groups existed.
    ///
    /// One target → the canonical `<plugin>/<form>` name, so every
    /// pre-group schema keys its bucket exactly as it always did.
    ///
    /// Several targets → one synthetic key naming each canonical target,
    /// space-separated. That is the whole of the multi-target design: the
    /// listed targets' instances all register into *this* bucket, so
    /// duplicate detection, lookup, poisoning, did-you-mean, and the LSP
    /// consumers stay single-bucket operations and need no change. A
    /// space cannot occur in a symbol, so a group key can never collide
    /// with a canonical form name.
    ///
    /// **The key is a set, not a list: sorted and de-duplicated.** A group
    /// declares that its targets share one namespace, and a namespace has
    /// no order — so `[a b]` and `[b a]` are the same bucket, and
    /// `[a p/a]` (one form under two spellings, which the loader's
    /// spelling-keyed repeat check cannot see) is the same bucket as
    /// `:target a`. Keying on the written order instead made one namespace
    /// register twice, which reported one duplicate name as two errors,
    /// hid `cross_ref_target_collapse` between two spellings of one group,
    /// and made `union_ambiguous` warn that order picks the entity when
    /// both readings picked the same one. Sorting also means a group reads
    /// the same way in every message whichever kind's declaration produced
    /// it. Two surfaces render a group and they differ deliberately: hover
    /// and the exporters take the author's spelling and order through
    /// `CrossRef.describeTargets`, the validator's and the LSP's messages
    /// take this canonical sorted order through `describeBucket`.
    ///
    /// **All-or-nothing.** If any listed target fails to resolve, the
    /// whole cross-ref contributes nothing — the same rule an unresolvable
    /// `:provider` already follows (`Validator.collectCrossRefTargets`).
    /// Registering the resolvable subset would accept references while
    /// silently excluding names the author listed; and there is no cascade
    /// to avoid, because `checkCrossRef` has already emitted
    /// `unknown_cross_ref_target` at `.err` for the offending entry, so
    /// the document fails validation either way.
    ///
    /// This function is the single source of truth for the key, shared by
    /// the aggregate collapse check and both index-build walks. Two
    /// implementations of it would be a silent divergence: references
    /// would be looked up in a bucket nothing registered into.
    pub fn crossRefBucketKey(
        self: Schema,
        a: Allocator,
        cr: Plugin.ValueKind.CrossRef,
    ) Allocator.Error!?[]const u8 {
        std.debug.assert(cr.targets.len >= 1);
        if (cr.targets.len == 1) return try self.canonicalFormName(a, cr.targets[0]);

        // The per-target names are scaffolding for the joined key, so they
        // are freed here rather than left for the caller's arena to absorb:
        // every call site passes a different allocator (index arena,
        // aggregate scratch, an LSP request arena, a test's GPA), and only
        // one thing should come back owned.
        var parts: std.ArrayList([]const u8) = .empty;
        defer {
            for (parts.items) |part| a.free(part);
            parts.deinit(a);
        }
        for (cr.targets) |t| {
            const canonical = (try self.canonicalFormName(a, t)) orelse return null;
            errdefer a.free(canonical); // not yet in `parts`, which the errdefer above frees
            try parts.append(a, canonical);
        }
        std.debug.assert(parts.items.len == cr.targets.len);

        // Set semantics, in two steps: sort so the written order cannot
        // fork the bucket, then drop the neighbours sorting has made equal
        // so two spellings of one form cannot name it twice. The freed
        // duplicates are the `defer` above's to release, so shrink the list
        // by swapping them to the tail rather than overwriting them.
        std.mem.sort([]const u8, parts.items, {}, lessThanStr);
        var write: usize = 1;
        var read: usize = 1;
        while (read < parts.items.len) : (read += 1) {
            if (std.mem.eql(u8, parts.items[read], parts.items[write - 1])) continue;
            std.mem.swap([]const u8, &parts.items[write], &parts.items[read]);
            write += 1;
        }
        std.debug.assert(write >= 1);
        std.debug.assert(write <= cr.targets.len);
        // The separator is also the split point: `describeBucket` recovers
        // the parts by splitting on `' '`, which is only sound while no
        // part can contain one. A canonical name is `<plugin>/<form>` and
        // both halves are symbols, which the lexer ends at whitespace — so
        // this holds today. Assert it at the join rather than trusting it
        // at the split: a pre-condition here is a post-condition there.
        for (parts.items[0..write]) |part| std.debug.assert(std.mem.indexOfScalar(u8, part, ' ') == null);
        return try std.mem.join(a, " ", parts.items[0..write]);
    }

    /// A bucket key rendered for a human, plus whether it names more than
    /// one form — callers need that to pick a preposition (`on form` for
    /// one, `across forms` for a set), and re-deriving it by probing
    /// `text` for a space would restate what this already knows.
    pub const BucketDisplay = struct { text: []const u8, is_group: bool };

    /// Render `crossRefBucketKey`'s output for a message: unchanged for
    /// one target, `a | b` for a group — the separator
    /// `CrossRef.describeTargets` and the Markdown exporter already use,
    /// so the codebase has one display convention for a group and not two.
    ///
    /// The two renderers answer different questions and so read
    /// differently on purpose. `describeTargets` echoes what the author
    /// wrote (their spelling, their order); this one names the namespace
    /// that rejected a reference, which is canonical, sorted and
    /// de-duplicated because the bucket is.
    ///
    /// **Ownership depends on the count**, exactly as `describeTargets`:
    /// one target returns the caller's own slice *borrowed* and
    /// unchanged, a group returns a fresh allocation on `a`. There is no
    /// unconditional `free` for the result, so every caller passes an
    /// arena.
    pub fn describeBucket(a: Allocator, bucket: []const u8) Allocator.Error!BucketDisplay {
        std.debug.assert(bucket.len > 0);
        if (std.mem.indexOfScalar(u8, bucket, ' ') == null) {
            return .{ .text = bucket, .is_group = false };
        }
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(a);
        var it = std.mem.splitScalar(u8, bucket, ' ');
        var first = true;
        while (it.next()) |part| {
            if (!first) try buf.appendSlice(a, " | ");
            first = false;
            try buf.appendSlice(a, part);
        }
        std.debug.assert(!first);
        return .{ .text = try buf.toOwnedSlice(a), .is_group = true };
    }

    /// Byte order over the bucket key's canonical parts. Any total order
    /// would do — what the key needs is *a* fixed one.
    fn lessThanStr(_: void, x: []const u8, y: []const u8) bool {
        return std.mem.lessThan(u8, x, y);
    }

    /// Same rule, one vocabulary over: a `:provider` spelling resolves to
    /// the canonical `<plugin>/<provider>` name that keys the extraction
    /// table. Null on `not_found` / `ambiguous`, where
    /// `unknown_cross_ref_provider` / `ambiguous_cross_ref_provider` have
    /// already been emitted — so neither discovery nor the index pass ever
    /// requests an extraction it cannot name. Allocates on `a`.
    pub fn canonicalProviderName(
        self: Schema,
        a: Allocator,
        spelling: []const u8,
    ) Allocator.Error!?[]const u8 {
        const q = Plugin.splitQualified(spelling);
        const hit = switch (self.lookupCrossRefProvider(q.name, q.namespace)) {
            .found => |h| h,
            else => return null,
        };
        return try std.fmt.allocPrint(a, "{s}/{s}", .{ hit.plugin.name, hit.provider.name });
    }
};

// ---------------------------------------------------------------------------
// Expression argument resolution.
//
// Single source of truth for "given a form's children and an `ExprFunc`,
// what's the positional argument list?". Drives both the validator and
// the evaluator so labeled and positional calls go through one rule set.
// ---------------------------------------------------------------------------

pub const Resolved = struct {
    /// Source children laid out in the function's positional order.
    /// For all-positional calls this is `hdr.children` verbatim. For
    /// labeled calls it's a fresh slice owned by the caller's arena,
    /// reordered so `positional[i]` is the value for `param_names[i]`.
    positional: []const Ast.NodeIndex,
    /// Non-null only for labeled calls — the signature whose
    /// `param_names` matched. For positional calls the validator
    /// continues to drive overload narrowing through `signatureIter`.
    signature: ?Plugin.ExprFunc.Signature = null,
};

pub const ResolveError = union(enum) {
    /// Positional and labeled args appeared in the same call. Span
    /// points at the first kvpair's key.
    mixed: struct { span: Ast.Span },
    /// Function has no signature with `param_names` declared but
    /// the caller used kvpairs.
    labels_not_supported: struct { span: Ast.Span, key: []const u8 },
    /// A kvpair label is not declared by any matching signature.
    unknown_label: struct { span: Ast.Span, key: []const u8 },
    /// Same label appeared more than once in this call.
    duplicate_label: struct { span: Ast.Span, key: []const u8 },
    /// All call labels are known but a declared name was not supplied.
    /// Span is the form's head span (caller fills it in for the
    /// diagnostic — the resolver only knows the missing name).
    missing_label: struct { name: []const u8 },
};

pub const ResolveResult = union(enum) {
    ok: Resolved,
    err: ResolveError,
};

/// Classify `hdr.children` and produce a positional list per `func`'s
/// declared shape. See `Resolved` / `ResolveError` for outcomes.
///
/// Allocates `Resolved.positional` from `a` only on the labeled path.
pub fn resolveExprArgs(
    a: Allocator,
    func: Plugin.ExprFunc,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
) Allocator.Error!ResolveResult {
    // Phase 1 — classify children.
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

    // Phase 2 — labeled call. Reduce the children to the shared
    // `LabelRef` shape, then apply the same rules the binary walker
    // applies to its streamed label list.
    const labels = try a.alloc(LabelRef, n_kv);
    for (hdr.children, 0..) |c, i| {
        const kvh = tree.kvpairHeader(c);
        labels[i] = .{ .key = kvh.key, .span = kvh.key_span };
    }

    var sigs_it = func.signatureIter();
    while (sigs_it.next()) |sig| {
        if (!sig.labeledEnabled()) continue;
        if (labelsMatchSignature(sig, labels)) {
            return try buildLabeledPositional(a, sig, tree, hdr);
        }
    }

    if (!anyLabeledSignature(func)) {
        return .{ .err = .{ .labels_not_supported = .{
            .span = first_kv_span,
            .key = first_kv_key,
        } } };
    }

    // Some labeled signature exists but none accepted the call. Emit
    // the most specific diagnostic, scanning labels in source order.
    return .{ .err = diagnoseLabels(func, labels) };
}

/// One labeled argument, reduced to what the label rules below need: the
/// key, and the span to blame if that key is the fault.
///
/// The two validator paths reach a labeled call with different handles on
/// it — the tree walker has random access to `hdr.children`, the binary
/// walker has a streamed list accumulated across `form_walk` iterations —
/// so each reduces its own representation to a `LabelRef` slice and asks
/// the shared rules from there. Before that split existed the binary path
/// simply skipped label structure entirely, which is how four
/// error-severity codes came to be emitted on one path and silently
/// dropped on the other.
pub const LabelRef = struct {
    key: []const u8,
    /// The label's key span. `ZERO_SPAN`-equivalents are acceptable when a
    /// path has no span to offer; only diagnostics read it.
    span: Ast.Span,
};

/// True when `labels` maps onto `sig.param_names` one-to-one and onto: a
/// unique slot per label, every slot supplied. Order is irrelevant.
pub fn labelsMatchSignature(
    sig: Plugin.ExprFunc.Signature,
    labels: []const LabelRef,
) bool {
    const names = sig.param_names orelse return false;
    if (labels.len != names.len) return false;
    // `param_names.len` is bounded only by `Arity.fixed` (a u8), so a label
    // can index past 31 — a u32 seen-mask would panic shifting by a u5 that
    // can't hold the index. A 256-bit set spans the whole u8 index space.
    var seen = std.StaticBitSet(256).initEmpty();
    for (labels) |l| {
        const idx = sig.indexOfLabel(l.key) orelse return false;
        if (seen.isSet(idx)) return false;
        seen.set(idx);
    }
    // Every set bit is a distinct index < names.len (indexOfLabel's range)
    // and labels.len == names.len, so a full count means every slot was
    // supplied exactly once.
    return seen.count() == names.len;
}

/// True when some labeled signature of `func` accepts exactly `labels`.
pub fn labelsMatchAnySignature(func: ExprFuncRef, labels: []const LabelRef) bool {
    var it = func.signatureIter();
    while (it.next()) |sig| {
        if (!sig.labeledEnabled()) continue;
        if (labelsMatchSignature(sig, labels)) return true;
    }
    return false;
}

/// True when `func` declares any labeled signature at all. A call with
/// kvpairs against a function with none is `labels_not_supported`, not a
/// label mismatch.
pub fn anyLabeledSignature(func: ExprFuncRef) bool {
    var it = func.signatureIter();
    while (it.next()) |sig| {
        if (sig.labeledEnabled()) return true;
    }
    return false;
}

const ExprFuncRef = Plugin.ExprFunc;

/// Diagnose a labeled call that `labelsMatchAnySignature` rejected.
/// Precedence, most specific first: duplicate label, then unknown label,
/// then missing label — each scanned in the order the labels were
/// written. Callers must have established that `func` declares at least
/// one labeled signature.
pub fn diagnoseLabels(func: ExprFuncRef, labels: []const LabelRef) ResolveError {
    // Duplicates first — they're a hard error regardless of signature.
    for (labels, 0..) |l, i| {
        for (labels[i + 1 ..]) |d| {
            if (std.mem.eql(u8, l.key, d.key)) {
                return .{ .duplicate_label = .{ .span = d.span, .key = d.key } };
            }
        }
    }
    // Unknown labels next — a label that no labeled signature declares.
    for (labels) |l| {
        if (!labelKnownInAnyLabeledSig(func, l.key)) {
            return .{ .unknown_label = .{ .span = l.span, .key = l.key } };
        }
    }
    // Missing labels — pick the first labeled signature and report any of
    // its names the call didn't supply. Every label is known at this
    // point, so the mismatch is missing slots.
    var sigs_it = func.signatureIter();
    while (sigs_it.next()) |sig| {
        if (!sig.labeledEnabled()) continue;
        for (sig.param_names.?) |n| {
            if (!hasLabel(labels, n)) return .{ .missing_label = .{ .name = n } };
        }
    }
    // Unreachable: every label known and every name supplied means a
    // signature would have matched. Fall back to a safe default.
    return .{ .missing_label = .{ .name = "" } };
}

fn hasLabel(labels: []const LabelRef, name: []const u8) bool {
    for (labels) |l| {
        if (std.mem.eql(u8, l.key, name)) return true;
    }
    return false;
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

fn labelKnownInAnyLabeledSig(func: Plugin.ExprFunc, name: []const u8) bool {
    var it = func.signatureIter();
    while (it.next()) |sig| {
        if (!sig.labeledEnabled()) continue;
        if (sig.indexOfLabel(name) != null) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Cross-ref aggregate-phase resolution.
// ---------------------------------------------------------------------------

/// Render the shared "<prefix> is ambiguous — defined by [a, b, …]<suffix>"
/// diagnostic message. Every ambiguity diagnostic — cross-ref `:target` /
/// `:scope`, `:union` alternative, `:lowering` produces head — shares the
/// "is ambiguous — defined by [<claimants>]" spine; `prefix_parts` and
/// `suffix_parts` are the caller's borrowed literal/name fragments,
/// concatenated verbatim around it. Only the returned owned slice is
/// allocated from `a` (the fragments are borrowed), so the allocation shape
/// matches the hand-rolled builders this replaces.
fn ambiguityMessage(
    a: Allocator,
    prefix_parts: []const []const u8,
    claimants: []const *const Plugin.Plugin,
    suffix_parts: []const []const u8,
) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (prefix_parts) |part| try buf.appendSlice(a, part);
    try buf.appendSlice(a, " is ambiguous — defined by [");
    for (claimants, 0..) |p, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, p.name);
    }
    try buf.appendSlice(a, "]");
    for (suffix_parts) |part| try buf.appendSlice(a, part);
    return buf.toOwnedSlice(a);
}

/// Render `names` as "`a`, `b`, `c`" — each backticked, comma-joined. Owned
/// by `a`; the fragments are borrowed.
fn backtickList(a: Allocator, names: []const []const u8) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.append(a, '`');
        try buf.appendSlice(a, n);
        try buf.append(a, '`');
    }
    return buf.toOwnedSlice(a);
}

/// Deep-copy aggregate diagnostics built in a validator's scratch arena into
/// caller-owned `a` allocations — the ownership `runAggregateValidators` /
/// `freeDiagnostics` expect (`message` + each path segment + the path slice +
/// the outer slice). Atomic under OOM: a failure partway frees every `a`
/// allocation made so far, so the scratch arena remains the sole owner and the
/// caller's `defer scratch.deinit()` reclaims the originals. This is what lets
/// each aggregate validator build with 17 inline `try allocPrint` append sites
/// yet never leak a partial diagnostic when the failing allocator trips one.
fn dupeAggregateDiagnostics(
    a: Allocator,
    items: []const Ast.Diagnostic,
) Allocator.Error![]const Ast.Diagnostic {
    const out = try a.alloc(Ast.Diagnostic, items.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |d| {
            a.free(d.message);
            for (d.path) |seg| a.free(seg);
            a.free(d.path);
        }
        a.free(out);
    }
    for (items, 0..) |src, i| {
        const message = try a.dupe(u8, src.message);
        errdefer a.free(message);

        const path = try a.alloc([]const u8, src.path.len);
        var pdone: usize = 0;
        errdefer {
            for (path[0..pdone]) |seg| a.free(seg);
            a.free(path);
        }
        for (src.path, 0..) |seg, j| {
            path[j] = try a.dupe(u8, seg);
            pdone = j + 1;
        }

        // Ast.Diagnostic is exactly {span, message, severity, code, path};
        // span/severity/code are POD, message/path are the owned copies above.
        out[i] = .{
            .span = src.span,
            .message = message,
            .severity = src.severity,
            .code = src.code,
            .path = path,
        };
        done = i + 1;
    }
    return out;
}

/// Everything about a `(cross-ref …)` that decides *what ends up in the
/// registry* for its target, canonicalised. Deliberately not the whole
/// `CrossRef`: `:acyclic` is a check run over the finished registry, not
/// an input to building it, so two kinds differing only in `:acyclic`
/// agree on the member set and must not warn.
const RegistrySpec = struct {
    /// The losing kind's identity, for the message. Not compared.
    plugin: []const u8,
    kind: []const u8,
    /// Canonical `<plugin>/<provider>`, or null on the identity route.
    /// A route difference is the sharpest form of disagreement.
    provider: ?[]const u8,
    /// `:name-key` on the identity route, `:source-key` on the provider
    /// route — the one the route actually reads. Folding them into one
    /// field is what keeps a provider spec's inert default `:name-key`
    /// from registering as a difference.
    key: []const u8,
    /// Canonical `<plugin>/<form>`, or null for document-wide.
    scope: ?[]const u8,

    /// True when both specs would build the same member set. Compared
    /// field-by-field rather than by `std.meta.eql` so the identity
    /// fields above stay out of it.
    fn agreesWith(self: RegistrySpec, other: RegistrySpec) bool {
        if (!optStrEql(self.provider, other.provider)) return false;
        if (!std.mem.eql(u8, self.key, other.key)) return false;
        return optStrEql(self.scope, other.scope);
    }

    /// How this spec builds its set, phrased for the message.
    fn describe(self: RegistrySpec, a: Allocator) Allocator.Error![]const u8 {
        const route = if (self.provider) |pv|
            try std.fmt.allocPrint(a, "`:provider {s}` over `:source-key {s}`", .{ pv, self.key })
        else
            try std.fmt.allocPrint(a, "`:name-key {s}`", .{self.key});
        if (self.scope) |sc| return std.fmt.allocPrint(a, "{s} scoped to `{s}`", .{ route, sc });
        return route;
    }
};

fn optStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// One bucket, one member set: the registry is keyed by
/// `Schema.crossRefBucketKey` and built first-wins, so a second
/// `(cross-ref …)` landing in the same bucket contributes nothing. Silent
/// when the two specs agree — that is ordinary aliasing — and a
/// `.warning` naming both when they don't, because the loser's references
/// are then checked against a set its own declaration had no part in
/// building.
///
/// The bucket, not the target, is what collapses. For a single-target
/// cross-ref the two are the same thing, which is why this reads as
/// "one target form, one member set" for every schema written before
/// groups existed. Two kinds that list the *same* group of targets share
/// a bucket and so can collapse; a group and a single-target kind on one
/// of its members cannot, because their keys differ.
///
/// Mirrors `Validator.collectCrossRefTargets`' skips exactly: an
/// unresolvable target or provider never reaches the registry, so it
/// cannot win or lose a collapse either. `checkCrossRef` has already
/// reported both.
fn checkTargetCollapse(
    schema: Schema,
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    winners: *std.StringHashMapUnmanaged(RegistrySpec),
    plugin: *const Plugin.Plugin,
    kind: *const Plugin.ValueKind,
    cr: Plugin.ValueKind.CrossRef,
) Allocator.Error!void {
    const bucket = (try schema.crossRefBucketKey(a, cr)) orelse return;
    const provider: ?[]const u8 = if (cr.provider) |pv|
        (try schema.canonicalProviderName(a, pv)) orelse return
    else
        null;
    const mine: RegistrySpec = .{
        .plugin = plugin.name,
        .kind = kind.name,
        .provider = provider,
        .key = if (provider == null) cr.name_key else cr.source_key,
        .scope = if (cr.scope_form) |sf| try schema.canonicalFormName(a, sf) else null,
    };

    const gop = try winners.getOrPut(a, bucket);
    if (!gop.found_existing) {
        gop.value_ptr.* = mine;
        return;
    }
    const won = gop.value_ptr.*;
    if (won.agreesWith(mine)) return;

    // A group's bucket key is not a form name, so it cannot be introduced
    // as one; single-target messages are unchanged, byte for byte.
    const subject = if (cr.targets.len == 1)
        try std.fmt.allocPrint(a, "form `{s}`", .{bucket})
    else
        try std.fmt.allocPrint(a, "the target group `{s}`", .{bucket});

    try diags.append(a, .{
        .span = .{ .start = 0, .end = 0 },
        .message = try std.fmt.allocPrint(
            a,
            "value-kind `{s}` cross-references {s}, whose members are already " ++
                "collected by value-kind `{s}` in plugin `{s}` using {s}; this kind's {s} " ++
                "is ignored, and its references are checked against the other kind's names",
            .{
                kind.name,
                subject,
                won.kind,
                won.plugin,
                try won.describe(a),
                try mine.describe(a),
            },
        ),
        .severity = .warning,
        .code = .cross_ref_target_collapse,
        .path = try formAggregatePath(a, plugin.name, kind.name, "cross-ref"),
    });
}

fn checkCrossRef(
    schema: Schema,
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    plugin: *const Plugin.Plugin,
    kind: *const Plugin.ValueKind,
    cr: Plugin.ValueKind.CrossRef,
) Allocator.Error!void {
    // Per *entry*: a group whose second target is a typo reports that
    // entry, names it, and leaves the first entry's verdict alone. The
    // aggregate pass collects rather than aborts, so all of them land.
    for (cr.targets) |target| try checkCrossRefTarget(schema, a, diags, plugin, kind, cr, target);

    // `:scope` and `:provider` are properties of the cross-ref, not of any
    // one target, so they are checked once however many targets there are.
    // (`:source-key` is read on *every* target, but its type check belongs
    // to the target and lives in `checkCrossRefTarget`.)
    try checkCrossRefScopeAndProvider(schema, a, diags, plugin, kind, cr);
}

fn checkCrossRefTarget(
    schema: Schema,
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    plugin: *const Plugin.Plugin,
    kind: *const Plugin.ValueKind,
    cr: Plugin.ValueKind.CrossRef,
    target: []const u8,
) Allocator.Error!void {
    // A `:target` entry may be bare (`phrase`) or qualified (`audio/phrase`).
    const target_split = Plugin.splitQualified(target);
    const target_ns = target_split.namespace;
    const target_name = target_split.name;
    switch (schema.lookupForm(target_name, target_ns)) {
        .not_found => {
            try diags.append(a, .{
                .span = .{ .start = 0, .end = 0 },
                .message = try std.fmt.allocPrint(
                    a,
                    "value-kind `{s}` cross-ref `:target {s}` does not resolve to any form",
                    .{ kind.name, target },
                ),
                .severity = .err,
                .code = .unknown_cross_ref_target,
                .path = try formAggregatePath(a, plugin.name, kind.name, "cross-ref"),
            });
        },
        .ambiguous => |amb| {
            try diags.append(a, .{
                .span = .{ .start = 0, .end = 0 },
                .message = try ambiguityMessage(
                    a,
                    &.{ "value-kind `", kind.name, "` cross-ref `:target ", target, "`" },
                    amb.slice(),
                    &.{ "; qualify with `<ns>/", target_name, "`" },
                ),
                .severity = .err,
                .code = .ambiguous_cross_ref_target,
                .path = try formAggregatePath(a, plugin.name, kind.name, "cross-ref"),
            });
        },
        .found => |hit| {
            // Exactly one of the two routes' keys is checked — the loader
            // has already rejected a spec claiming both, so this is a
            // dispatch, not a precedence rule.
            if (cr.provider == null) {
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
                        .path = try formAggregatePath(a, plugin.name, kind.name, "cross-ref"),
                    });
                }
            } else {
                var found_key = false;
                var string_typed = false;
                for (hit.form.keys) |k| {
                    if (!std.mem.eql(u8, k.name, cr.source_key)) continue;
                    found_key = true;
                    string_typed = isStringValueType(schema, k.value_type);
                    break;
                }
                if (!found_key or !string_typed) {
                    try diags.append(a, .{
                        .span = .{ .start = 0, .end = 0 },
                        .message = try std.fmt.allocPrint(
                            a,
                            "value-kind `{s}` cross-ref `:source-key {s}` is not a string-typed key on form `{s}`",
                            .{ kind.name, cr.source_key, target_name },
                        ),
                        .severity = .err,
                        .code = .cross_ref_source_key_unknown,
                        .path = try formAggregatePath(a, plugin.name, kind.name, "cross-ref"),
                    });
                }
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
                        .path = try formAggregatePath(a, plugin.name, kind.name, "cross-ref"),
                    });
                }
            }
        },
    }
}

fn checkCrossRefScopeAndProvider(
    schema: Schema,
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    plugin: *const Plugin.Plugin,
    kind: *const Plugin.ValueKind,
    cr: Plugin.ValueKind.CrossRef,
) Allocator.Error!void {
    // `:scope <form>` must resolve to a form (qualified or bare). Same
    // bare/qualified split as a `:target` entry.
    if (cr.scope_form) |sf| {
        const scope_split = Plugin.splitQualified(sf);
        const scope_ns = scope_split.namespace;
        const scope_name = scope_split.name;
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
                    .path = try formAggregatePath(a, plugin.name, kind.name, "cross-ref"),
                });
            },
            .ambiguous => |amb| {
                try diags.append(a, .{
                    .span = .{ .start = 0, .end = 0 },
                    .message = try ambiguityMessage(
                        a,
                        &.{ "value-kind `", kind.name, "` cross-ref `:scope ", sf, "`" },
                        amb.slice(),
                        &.{ "; qualify with `<ns>/", scope_name, "`" },
                    ),
                    .severity = .err,
                    .code = .ambiguous_cross_ref_scope,
                    .path = try formAggregatePath(a, plugin.name, kind.name, "cross-ref"),
                });
            },
            .found => {},
        }
    }

    // `:provider <name>` must resolve to exactly one declared provider
    // (qualified or bare). Independent of whether `:target` resolved —
    // two separate authoring mistakes deserve two diagnostics, and the
    // aggregate pass collects rather than aborts.
    if (cr.provider) |pv| {
        const prov_split = Plugin.splitQualified(pv);
        const prov_ns = prov_split.namespace;
        const prov_name = prov_split.name;
        switch (schema.lookupCrossRefProvider(prov_name, prov_ns)) {
            .not_found => {
                try diags.append(a, .{
                    .span = .{ .start = 0, .end = 0 },
                    .message = try std.fmt.allocPrint(
                        a,
                        "value-kind `{s}` cross-ref `:provider {s}` does not resolve to any declared provider",
                        .{ kind.name, pv },
                    ),
                    .severity = .err,
                    .code = .unknown_cross_ref_provider,
                    .path = try formAggregatePath(a, plugin.name, kind.name, "cross-ref"),
                });
            },
            .ambiguous => |amb| {
                try diags.append(a, .{
                    .span = .{ .start = 0, .end = 0 },
                    .message = try ambiguityMessage(
                        a,
                        &.{ "value-kind `", kind.name, "` cross-ref `:provider ", pv, "`" },
                        amb.slice(),
                        &.{ "; qualify with `<ns>/", prov_name, "`" },
                    ),
                    .severity = .err,
                    .code = .ambiguous_cross_ref_provider,
                    .path = try formAggregatePath(a, plugin.name, kind.name, "cross-ref"),
                });
            },
            .found => {},
        }
    }
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
        // Primitive shortcuts always resolve to themselves, never to a
        // union — skip the catalog lookup.
        if (isPrimitiveTypeName(alt.name)) continue;
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
                    .path = try formAggregatePath(a, plugin.name, kind.name, "union"),
                });
            },
            .ambiguous => |amb| {
                const claimants = amb.slice();
                // Union alternatives name the first actual claimant in the
                // "qualify with" hint (not the `<ns>` placeholder the other
                // sites use), and drop the hint entirely when the collision
                // list is empty.
                const suffix: []const []const u8 = if (claimants.len > 0)
                    &.{ "; qualify with `", claimants[0].name, "/", alt.name, "`" }
                else
                    &.{};
                try diags.append(a, .{
                    .span = .{ .start = 0, .end = 0 },
                    .message = try ambiguityMessage(
                        a,
                        &.{ "value-kind `", kind.name, "` `:union` alternative `", alt.name, "`" },
                        claimants,
                        suffix,
                    ),
                    .severity = .err,
                    .code = .ambiguous_element_kind,
                    .path = try formAggregatePath(a, plugin.name, kind.name, "union"),
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
                        .path = try formAggregatePath(a, plugin.name, kind.name, "union"),
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

/// Resolve the discriminant key's `value_type` to a value-kind with
/// `.symbol` underlying and a non-empty `MemberSet`. Returns null if the
/// kind isn't a closed enum (the caller emits `discriminant_not_closed_enum`).
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
    if (idx >= form.keys.len) return; // defensive: loader should not produce this
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
        // Without a closed enum we cannot validate :when values; skip
        // the rest to avoid noise on top of the root-cause diagnostic.
        return;
    }
    const ms = members.?;

    const variants = form.variants orelse &.{};
    for (variants) |v| {
        // Once per listed value: `:when [tri-strip nope]` reports `nope`
        // and keeps `tri-strip`, so a set with one typo names the typo
        // rather than rejecting the whole declaration.
        for (v.when) |w| {
            var found = false;
            for (ms) |m| {
                if (std.mem.eql(u8, w, m.name)) {
                    found = true;
                    break;
                }
            }
            if (found) continue;
            const when_text = try v.whenText(a);
            try diags.append(a, .{
                .span = .{ .start = 0, .end = 0 },
                .message = if (v.when.len == 1) try std.fmt.allocPrint(
                    a,
                    "form `{s}` variant `:when {s}` is not a member of discriminant `:{s}`",
                    .{ form.name, when_text, dkey.name },
                ) else try std.fmt.allocPrint(
                    a,
                    "form `{s}` variant `:when {s}` lists `{s}`, which is not a member of discriminant `:{s}`",
                    .{ form.name, when_text, w, dkey.name },
                ),
                .severity = .err,
                .code = .unknown_discriminant_value,
                .path = try formAggregatePath(a, plugin.name, form.name, "variant"),
            });
        }
    }

    // Key-name collisions: every variant key must be distinct from every
    // common key, and from every prior variant key. One name = one slot.
    // A `:when` listing several values does not loosen this — the point of
    // one declaration reaching several values is that a key still lives in
    // exactly one variant.
    for (variants, 0..) |v, vi| {
        for (v.keys) |vk| {
            for (form.keys) |ck| {
                if (std.mem.eql(u8, vk.name, ck.name)) {
                    try diags.append(a, .{
                        .span = .{ .start = 0, .end = 0 },
                        .message = try std.fmt.allocPrint(
                            a,
                            "form `{s}` variant `:when {s}` redeclares key `:{s}` (also in common keys)",
                            .{ form.name, try v.whenText(a), vk.name },
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
                                .{ form.name, try v.whenText(a), vk.name, try prior.whenText(a) },
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

/// Per-key worker for `validateDefaults`: classify one key's `:default`
/// expression head via `Validator.resolveFormExpressionBinary` and emit
/// `wrong_underlying` when it resolves to a data form, or when its declared
/// result type doesn't match the key's `value_type`. Opaque heads (unknown
/// verdict / null declared result / unresolved head) defer to runtime.
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

/// Push every slot-local form declared *directly* on `f` — both carriers:
/// `KeySpec.local_forms` on the base keys and on every variant's keys, and
/// the positional `FormSpec.local_forms`. One level only; callers loop, so
/// nested locals are reached without host-stack recursion. Shared by the
/// `:produces` reachability closure and the declaring-form hint so the two
/// cannot disagree on what "declared inside" means.
fn pushDirectLocalForms(
    a: Allocator,
    stack: *std.ArrayList(*const Plugin.FormSpec),
    f: *const Plugin.FormSpec,
) Allocator.Error!void {
    for (f.keys) |*k| {
        for (k.local_forms) |*lf| try stack.append(a, lf);
    }
    if (f.variants) |variants| {
        for (variants) |*v| {
            for (v.keys) |*k| {
                for (k.local_forms) |*lf| try stack.append(a, lf);
            }
        }
    }
    for (f.local_forms) |*lf| try stack.append(a, lf);
}

/// The slot-local heads a `:produces` list can reach: every local form
/// declared — at any depth, through either carrier — inside a form the same
/// list resolves globally (bare or qualified). Names only; a body is chosen
/// at the site, local-first (`Validator.matchLocalForm`), and this decides
/// nothing but "declared, and reachable from here".
///
/// Why *reachable from the list* rather than "any local anywhere": an
/// emitted form is either a root of a lowered layer or nested inside another
/// emitted form, so an emitted local can only ever sit under its declaring
/// form — and the all-depths contract (`Lowering.validateEmittedForm`) puts
/// that declaring form in this very list. The reachable set is therefore
/// exactly the set of local heads a hook can legally place; a local listed
/// without its declaring form is a manifest that cannot be right, and the
/// caller says which form is missing. Entries the catalog cannot resolve
/// (unknown, ambiguous, absent plugin) contribute nothing — they are reported
/// on their own by `checkLowering`, and a local under an ambiguous root
/// resolves once its root does.
///
/// Locals never carry `:lowering` (loader-rejected, `Schema.init`-asserted),
/// so a head resolved here adds no edge to `buildLoweringGraph` — the graph
/// keeps resolving globally, and only a global lowerable form is an edge.
fn collectReachableLocalHeads(
    schema: Schema,
    a: Allocator,
    produces: []const []const u8,
) Allocator.Error!std.StringHashMapUnmanaged(void) {
    var reachable: std.StringHashMapUnmanaged(void) = .empty;
    errdefer reachable.deinit(a);
    var stack: std.ArrayList(*const Plugin.FormSpec) = .empty;
    defer stack.deinit(a);
    for (produces) |head| {
        const q = Plugin.splitQualified(head);
        switch (schema.lookupForm(q.name, q.namespace)) {
            .found => |hit| try stack.append(a, hit.form),
            else => {},
        }
    }
    // Locals are owned slices in a finite spec tree (loader-bounded by
    // `Plugin.MAX_LOCAL_FORM_DEPTH`), so the worklist terminates without a
    // visited set; a name reached twice is a no-op `put`.
    while (stack.pop()) |f| {
        const mark = stack.items.len;
        try pushDirectLocalForms(a, &stack, f);
        for (stack.items[mark..]) |lf| try reachable.put(a, lf.name, {});
    }
    return reachable;
}

/// Top-level forms (bare names, catalog order) that declare a slot-local
/// form named `head` somewhere in their local tree — the forms a `:produces`
/// list would have to name for `head` to resolve. Error-path only; feeds the
/// `unknown_form` hint. Empty when `head` is nobody's local.
fn localHeadDeclaringForms(
    schema: Schema,
    a: Allocator,
    head: []const u8,
) Allocator.Error![]const []const u8 {
    var owners: std.ArrayList([]const u8) = .empty;
    errdefer owners.deinit(a);
    var stack: std.ArrayList(*const Plugin.FormSpec) = .empty;
    defer stack.deinit(a);
    for (schema.plugins) |*p| {
        for (p.forms) |*f| {
            stack.clearRetainingCapacity();
            try stack.append(a, f);
            const owns = blk: while (stack.pop()) |cur| {
                const mark = stack.items.len;
                try pushDirectLocalForms(a, &stack, cur);
                for (stack.items[mark..]) |lf| {
                    if (std.mem.eql(u8, lf.name, head)) break :blk true;
                }
            } else false;
            if (!owns) continue;
            // Two plugins declaring the same-named owner (an ambiguous root)
            // would name it twice; the ambiguity is reported on its own.
            for (owners.items) |seen| {
                if (std.mem.eql(u8, seen, f.name)) break;
            } else try owners.append(a, f.name);
        }
    }
    return owners.toOwnedSlice(a);
}

/// Resolve every `:produces` entry on a form's `lowering` declaration.
/// A bare entry (`shader`) resolves **local-first**, mirroring the site
/// (`Validator.validateFormHead` step 0): if it names a slot-local form
/// reachable from this list (`collectReachableLocalHeads`) it resolves,
/// whatever the global catalog says; otherwise it looks up across all
/// plugins — ambiguity = collision. A qualified entry (`pngine/shader`)
/// targets one plugin and bypasses locals, exactly as a qualified head does
/// at the site. The hook id itself is opaque to the substrate (no
/// resolution), so this only checks `:produces`.
fn checkLowering(
    schema: Schema,
    a: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    plugin: *const Plugin.Plugin,
    form: *const Plugin.FormSpec,
    low: Plugin.LoweringSpec,
) Allocator.Error!void {
    var reachable_locals = try collectReachableLocalHeads(schema, a, low.produces);
    defer reachable_locals.deinit(a);
    for (low.produces) |head| {
        const head_split = Plugin.splitQualified(head);
        const head_ns = head_split.namespace;
        const head_name = head_split.name;
        // Slot-local, reachable through a form this list names: resolved.
        // Local-first — a same-named global (found or ambiguous) is shadowed
        // at the site, so it is shadowed here too.
        if (head_ns == null and reachable_locals.contains(head_name)) continue;
        switch (schema.lookupForm(head_name, head_ns)) {
            .not_found => {
                // A *qualified* head whose plugin is absent dangles on load
                // order, not on a typo — call that out with a distinct code
                // (collection over abort: the edge is reported, never fatal).
                // Bare heads and qualified heads into a present-but-formless
                // plugin keep the generic `unknown_form`; a bare head that is
                // somebody's slot-local names the declaring form(s) the list
                // would have to carry for it to resolve.
                const absent_plugin = head_ns != null and !schema.hasPlugin(head_ns.?);
                const declaring: []const []const u8 = if (head_ns == null)
                    try localHeadDeclaringForms(schema, a, head_name)
                else
                    &.{};
                try diags.append(a, .{
                    .span = .{ .start = 0, .end = 0 },
                    .message = if (absent_plugin) try std.fmt.allocPrint(
                        a,
                        "form `{s}` `:lowering` produces head `{s}` whose plugin `{s}` is not loaded",
                        .{ form.name, head, head_ns.? },
                    ) else if (declaring.len > 0) try std.fmt.allocPrint(
                        a,
                        "form `{s}` `:lowering` produces head `{s}` does not resolve to any declared form; `{s}` is slot-local to {s} and resolves only through a `:produces` entry naming that form",
                        .{ form.name, head, head, try backtickList(a, declaring) },
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
                try diags.append(a, .{
                    .span = .{ .start = 0, .end = 0 },
                    .message = try ambiguityMessage(
                        a,
                        &.{ "form `", form.name, "` `:lowering` produces head `", head, "`" },
                        amb.slice(),
                        &.{ "; qualify with `<ns>/", head_name, "`" },
                    ),
                    .severity = .err,
                    .code = .ambiguous_form,
                    .path = try formAggregatePath(a, plugin.name, form.name, "lowering"),
                });
            },
            .found => {},
        }
    }
}

/// One node in the lowering `:produces` graph: a form that declares
/// `:lowering`. `name` is the canonical `<plugin>/<form>` head used for
/// edge matching by the shared cycle detector; `edges` are the canonical
/// heads of this form's `:produces` targets (unresolved / ambiguous
/// entries are dropped — `checkLowering` already reports those, and they
/// can't anchor a cycle edge). `plugin_name` / `form_name` carry the
/// structural path for the emitted `lowering_cycle` diagnostic.
pub const LoweringGraphNode = struct {
    name: []const u8,
    plugin_name: []const u8,
    form_name: []const u8,
    edges: []const []const u8,
};

/// Build the lowering `:produces` graph: one node per form declaring
/// `:lowering`, with edges = each `:produces` head resolved to its
/// canonical `<plugin>/<form>` name (so same-plugin and cross-plugin
/// edges match uniformly). Unresolved / ambiguous / absent-plugin heads
/// are dropped — `checkLowering` reports those, and a dangling head can't
/// anchor a graph edge.
///
/// Nodes and their `name` / `edges` backing strings are allocated on
/// `arena`; `plugin_name` / `form_name` borrow from `self`, so the schema
/// must outlive the returned slice. Shared by the static cycle check
/// (`checkLoweringCycles`) and the `lowering-graph` export, so both
/// observe the exact same derived graph.
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
                const q = Plugin.splitQualified(head);
                switch (self.lookupForm(q.name, q.namespace)) {
                    .found => |hit| try edges.append(
                        arena,
                        try std.fmt.allocPrint(arena, "{s}/{s}", .{ hit.plugin.name, hit.form.name }),
                    ),
                    // Unresolved / ambiguous heads are already reported by
                    // `checkLowering`; drop them as graph edges (mirrors
                    // `collectAcyclicSpecs` dropping unanchorable specs).
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

/// Build the lowering `:produces` graph and reject cycles statically.
/// Nodes are every form declaring `:lowering`; edges are each form's
/// `:produces` heads resolved to canonical `<plugin>/<form>` names (so
/// same-plugin and cross-plugin edges match uniformly). Runs the same
/// iterative 3-colour DFS the `:acyclic` cross-ref check uses
/// (`Validator.detectGraphCycles`); each back edge emits one
/// `lowering_cycle` anchored at the cycle's entry form.
///
/// The transient graph lives on a scratch arena freed before return;
/// emitted diagnostics are allocated on `a` and survive.
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

    // The only lowering-cycle-specific work is rendering the path and
    // attaching one diagnostic per cycle; the walk itself is shared.
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

/// True if `vt` is a symbol-typed slot — either `.symbol` directly,
/// `.any` (which accepts any tag), or a `.named` reference whose
/// value-kind has `.underlying == .symbol`. Single-hop `.named`
/// resolution is enough here: refinement axes (`members`, etc.) live
/// on the kind itself, not in a chain.
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

/// String twin of `isSymbolValueType`, for the provider route's
/// `:source-key`. Same two questions — `.any` matches (an unconstrained
/// slot can hold a string), a `.named` reference resolves one hop to its
/// underlying — and one that only arises here: a `string_bounds`-refined
/// kind still counts, since a refinement narrows a string rather than
/// replacing it, and the provider is handed the bytes either way.
///
/// Deliberately one hop, not transitive, exactly like the symbol version:
/// deeper chains are `MAX_KIND_DEPTH` territory and the aggregate pass
/// stays a flat check.
fn isStringValueType(schema: Schema, vt: Plugin.ValueType) bool {
    return switch (vt) {
        .string, .any => true,
        .named => |ref| sub: {
            if (std.mem.eql(u8, ref.name, "string") or std.mem.eql(u8, ref.name, "any")) break :sub true;
            break :sub switch (schema.lookupValueKind(ref.name, ref.namespace)) {
                .found => |k| k.underlying == .string,
                else => false,
            };
        },
        else => false,
    };
}

/// Whether a key's `value_type` resolves to a given cross-ref kind, and
/// if so via what shape. `.scalar` is a direct symbol reference (e.g.
/// `:parent phrase-name`); `.vector` is one vector-hop away (e.g.
/// `:children phrase-name-list`, where `phrase-name-list` is a vector
/// of `phrase-name`). Returns `null` when no self-edge is present.
pub const EdgeShape = enum { scalar, vector };

/// Per-spec view of "this acyclic cross-ref kind targets `target_form`,
/// and its self-edges live on these keys". Built once per schema by
/// `collectAcyclicSpecs`, consumed by both forest-validator paths.
pub const AcyclicSpec = struct {
    /// The cross-ref kind name (e.g. `"phrase-name"`). Used to label the
    /// `cyclic_cross_ref` diagnostic message.
    kind_name: []const u8,
    /// Canonical `<plugin>/<form>` target name (e.g. `"audio/phrase"`),
    /// produced via `Schema.lookupForm`. Owned by the spec — freed via
    /// `freeAcyclicSpecs`. Same key shape the cross-ref index uses, so
    /// a `(spec, form)` match is a string-equality check on canonical
    /// names.
    target_form: []const u8,
    /// `:name-key` for the target form (e.g. `"name"`). Mirrors what the
    /// existing cross-ref index already knows for this target.
    name_key: []const u8,
    /// Canonical `<plugin>/<form>` for the lexical scope, when the
    /// cross-ref opts into `:scope <form>`; null = tree-scoped. Owned
    /// alongside `target_form` and freed via `freeAcyclicSpecs`. The
    /// cycle detector keys per `(spec, scope-instance)` — under lexical
    /// scoping, cycles are confined to a single instance's bindings.
    scope_form: ?[]const u8,
    /// Keys on the target form whose value type resolves back to
    /// `kind_name`. Each edge says "look in this kvpair for outgoing
    /// references to other instances of `target_form`".
    edges: []const EdgeKey,

    pub const EdgeKey = struct {
        name: []const u8,
        shape: EdgeShape,
    };
};

/// Walk every `:acyclic true` cross-ref in the schema; for each one
/// resolve its target form and harvest the keys whose `value_type`
/// resolves back to the cross-ref's kind. Returns `[]AcyclicSpec` on
/// `gpa` (caller frees via `freeAcyclicSpecs`).
///
/// Specs whose target form lookup fails (`unknown_cross_ref_target` /
/// `ambiguous_cross_ref_target` already emitted) are silently dropped —
/// the validator can't enforce a cycle check it can't anchor. Specs
/// with no self-edges are also dropped here; the `acyclic_without_self_edge`
/// diagnostic for that case fires from `validateCrossRefs` separately.
pub fn collectAcyclicSpecs(
    self: Schema,
    gpa: Allocator,
) Allocator.Error![]AcyclicSpec {
    var out: std.ArrayList(AcyclicSpec) = .empty;
    // Every appended spec already owns three gpa allocations, so a
    // failure after the first append must release them the way
    // `freeAcyclicSpecs` does — `out.deinit` alone drops only the list.
    errdefer {
        for (out.items) |s| {
            gpa.free(s.target_form);
            if (s.scope_form) |sf| gpa.free(sf);
            gpa.free(s.edges);
        }
        out.deinit(gpa);
    }
    for (self.plugins) |*plugin| {
        for (plugin.value_kinds) |*kind| {
            const cr = kind.cross_ref orelse continue;
            if (!cr.acyclic) continue;
            // Cycle edges are defined over a target's *self*-referential
            // keys, so "self" has to be one form. The loader rejects
            // `:acyclic true` on a group for exactly this reason; reading
            // through `soleTarget` states the assumption where it is
            // relied on instead of leaving a bare `targets[0]` that a
            // later widening could quietly make wrong.
            const sole = cr.soleTarget() orelse continue;
            const q = Plugin.splitQualified(sole);
            const form_hit = switch (self.lookupForm(q.name, q.namespace)) {
                .found => |h| h,
                else => continue,
            };
            var edges: std.ArrayList(AcyclicSpec.EdgeKey) = .empty;
            errdefer edges.deinit(gpa);
            for (form_hit.form.keys) |k| {
                // The cross-ref's `name_key` is the node identifier, not
                // an outgoing edge — skip it. Including it would inject
                // a self-loop on every form and produce a false-positive
                // cyclic_cross_ref on every registered name.
                if (std.mem.eql(u8, k.name, cr.name_key)) continue;
                if (selfEdgeShape(self, k.value_type, kind.name)) |shape| {
                    try edges.append(gpa, .{ .name = k.name, .shape = shape });
                }
            }
            // Variant keys participate in the schema cycle graph too — a
            // self-edge on a variant-only key is still a real edge, even
            // though the document only triggers it when the discriminant
            // matches. Cycles are a schema property, not document-state.
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

            // Canonicalise `:scope` to `<plugin>/<form>` if present, so
            // the cycle detector keys per scope-instance against the
            // same canonical strings the index uses.
            var scope_canonical: ?[]const u8 = null;
            if (cr.scope_form) |sf| {
                const sq = Plugin.splitQualified(sf);
                switch (self.lookupForm(sq.name, sq.namespace)) {
                    .found => |sh| {
                        scope_canonical = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ sh.plugin.name, sh.form.name });
                    },
                    else => {},
                }
            }
            errdefer if (scope_canonical) |sc| gpa.free(sc);

            // Take ownership before the append: `toOwnedSlice` runs
            // first, and if the append then fails nothing else holds
            // the slice.
            const owned_edges = try edges.toOwnedSlice(gpa);
            errdefer gpa.free(owned_edges);
            try out.append(gpa, .{
                .kind_name = kind.name,
                .target_form = canonical,
                .name_key = cr.name_key,
                .scope_form = scope_canonical,
                .edges = owned_edges,
            });
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Free a slice produced by `collectAcyclicSpecs`. Each spec owns its
/// `target_form`, optional `scope_form`, and `edges` on the same allocator.
pub fn freeAcyclicSpecs(gpa: Allocator, specs: []AcyclicSpec) void {
    for (specs) |s| {
        gpa.free(s.target_form);
        if (s.scope_form) |sf| gpa.free(sf);
        gpa.free(s.edges);
    }
    gpa.free(specs);
}

/// Resolve a `value_type` (typically a key's declared type on the
/// target form) and check whether it ultimately points back to
/// `target_kind`. Iterative walk along `.named` aliases up to
/// `MAX_KIND_DEPTH`; at most one vector hop is allowed (the
/// `(vector-shape :element …)` indirection). Returns the shape of the
/// self-edge, or null when absent.
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
        // Primitives never alias back to a kind.
        if (isPrimitiveTypeName(ref.name)) return null;
        const vk = switch (schema.lookupValueKind(ref.name, ref.namespace)) {
            .found => |k| k,
            else => return null,
        };
        if (vk.vector) |vs| {
            if (saw_vector) return null;
            saw_vector = true;
            if (std.mem.eql(u8, vs.element.name, target_kind)) return .vector;
            if (isPrimitiveTypeName(vs.element.name)) return null;
            current = .{ .named = vs.element };
            continue;
        }
        return null;
    }
    return null;
}

fn isPrimitiveTypeName(name: []const u8) bool {
    // Membership in the shared catalog (`Plugin.primitive_type_names`);
    // `expr` counts as a primitive type-name here.
    return Plugin.primitive_type_names.has(name);
}

test "isPrimitiveTypeName: 9-name catalog incl. expr; rejects non-primitives" {
    // Membership catalog for schema type-refs. `expr` IS a member (a valid
    // type-ref name); the asymmetry with the validator's
    // resolvePrimitiveShortcut — which excludes `expr` — is deliberate and
    // pinned there.
    const members = [_][]const u8{
        "any", "number", "string", "symbol", "boolean",
        "nil", "vector", "form",   "expr",
    };
    for (members) |m| try testing.expect(isPrimitiveTypeName(m));
    try testing.expect(!isPrimitiveTypeName("color"));
    try testing.expect(!isPrimitiveTypeName("Number"));
    try testing.expect(!isPrimitiveTypeName(""));
    // 8 chars — would have slipped past the old `name.len <= 7` prefilter.
    try testing.expect(!isPrimitiveTypeName("booleans"));
}

/// Hard cap on how many plugin pointers we report inside an `.ambiguous`
/// hit. Stored inline in the union so the value is self-contained.
pub const MAX_AMBIGUOUS: usize = 16;

/// Hard cap on `ValueKind` resolution depth. A vector-of-vector-of-… chain
/// hitting this limit fails loud rather than recursing forever (a cyclic
/// `element` reference between plugin-defined kinds would otherwise loop).
pub const MAX_KIND_DEPTH: u8 = 8;

/// Successful data-form lookup: identifies the owning plugin and the
/// specific `FormSpec` that matched.
pub const FormHit = struct {
    plugin: *const Plugin.Plugin,
    form: *const Plugin.FormSpec,
};

/// Successful expression-function lookup: identifies the owning plugin
/// and the specific `ExprFunc` that matched.
pub const ExprHit = struct {
    plugin: *const Plugin.Plugin,
    func: *const Plugin.ExprFunc,
};

/// Successful cross-ref-provider lookup: identifies the owning plugin
/// and the specific `CrossRefProvider` that matched. The plugin pointer
/// is not optional bookkeeping — the extraction table is keyed by the
/// canonical `<plugin>/<provider>` spelling, so every resolution needs
/// the namespace even when the manifest spelled the name bare.
pub const CrossRefProviderHit = struct {
    plugin: *const Plugin.Plugin,
    provider: *const Plugin.CrossRefProvider,
};

/// All plugins that claim a single bare name. The buffer is owned by the
/// hit value itself, so the slice is valid as long as the hit is.
pub const Ambiguous = struct {
    buf: [MAX_AMBIGUOUS]*const Plugin.Plugin,
    len: u8,

    pub fn slice(self: *const Ambiguous) []const *const Plugin.Plugin {
        return self.buf[0..self.len];
    }
};

/// Unified tri-state shape for every `Schema` lookup. `Hit` is the
/// successful-result type — `FormHit`, `ExprHit`, or
/// `*const Plugin.ValueKind`. `.ambiguous` carries the list of every
/// plugin that claimed the bare name so editors / diagnostics can name
/// the colliders.
pub fn LookupResult(comptime Hit: type) type {
    return union(enum) {
        found: Hit,
        not_found,
        ambiguous: Ambiguous,
    };
}

/// Tri-state result of `Schema.lookupForm`.
pub const FormLookup = LookupResult(FormHit);

/// Tri-state result of `Schema.lookupExprFunc`. Same shape as `FormLookup`.
pub const ExprLookup = LookupResult(ExprHit);

/// Tri-state result of `Schema.lookupValueKind`. Same shape as `FormLookup`.
pub const ValueKindLookup = LookupResult(*const Plugin.ValueKind);

/// Tri-state result of `Schema.lookupCrossRefProvider`. Same shape as
/// `FormLookup`.
pub const CrossRefProviderLookup = LookupResult(CrossRefProviderHit);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const core = @import("plugins/core.zig");

test "lookup core expression by bare name" {
    const schema = Schema.init(&.{core.plugin});
    const hit = schema.lookupExprFunc("vec3", null);
    try testing.expect(hit == .found);
    try testing.expectEqualStrings("vec3", hit.found.func.name);
    try testing.expectEqualStrings("core", hit.found.plugin.name);
}

test "lookup core expression by qualified name" {
    const schema = Schema.init(&.{core.plugin});
    const hit = schema.lookupExprFunc("vec3", "core");
    try testing.expect(hit == .found);
    try testing.expectEqualStrings("vec3", hit.found.func.name);
}

test "qualified lookup misses when plugin doesn't have it" {
    const schema = Schema.init(&.{core.plugin});
    const hit = schema.lookupExprFunc("vec3", "masagin");
    try testing.expect(hit == .not_found);
}

test "bare form lookup with no plugins yields not_found" {
    const schema = Schema.init(&.{});
    const hit = schema.lookupForm("scene", null);
    try testing.expect(hit == .not_found);
}

test "ambiguous form name is detected" {
    const a: Plugin.Plugin = .{
        .name = "a",
        .forms = &.{.{ .name = "verb" }},
    };
    const b: Plugin.Plugin = .{
        .name = "b",
        .forms = &.{.{ .name = "verb" }},
    };
    const schema = Schema.init(&.{ a, b });
    const hit = schema.lookupForm("verb", null);
    try testing.expect(hit == .ambiguous);
    try testing.expectEqual(@as(u8, 2), hit.ambiguous.len);
    const claimants = hit.ambiguous.slice();
    try testing.expectEqualStrings("a", claimants[0].name);
    try testing.expectEqualStrings("b", claimants[1].name);
}

test "ambiguous resolved by qualifying" {
    const a: Plugin.Plugin = .{
        .name = "a",
        .forms = &.{.{ .name = "verb" }},
    };
    const b: Plugin.Plugin = .{
        .name = "b",
        .forms = &.{.{ .name = "verb" }},
    };
    const schema = Schema.init(&.{ a, b });
    const hit = schema.lookupForm("verb", "b");
    try testing.expect(hit == .found);
    try testing.expectEqualStrings("b", hit.found.plugin.name);
}

test "lookupValueKind: bare, qualified, misses, and ambiguous" {
    // Direct pin on the value-kind lookup — the odd one out, whose `.found`
    // carries only the kind pointer (no owning plugin), so its bare-collision
    // path tracks the first plugin separately. Only indirectly exercised
    // elsewhere (validateUnions / discriminant resolution); pin it head-on.
    const a_plug: Plugin.Plugin = .{
        .name = "a",
        .value_kinds = &.{.{ .name = "color", .underlying = .symbol }},
    };
    const b_plug: Plugin.Plugin = .{
        .name = "b",
        .value_kinds = &.{
            .{ .name = "color", .underlying = .symbol },
            .{ .name = "gain", .underlying = .number },
        },
    };
    const schema = Schema.init(&.{ a_plug, b_plug });

    // Bare, unambiguous: only `b` defines `gain`.
    const gain = schema.lookupValueKind("gain", null);
    try testing.expect(gain == .found);
    try testing.expectEqualStrings("gain", gain.found.name);

    // Qualified: pick `a`'s `color` specifically.
    const a_color = schema.lookupValueKind("color", "a");
    try testing.expect(a_color == .found);
    try testing.expect(a_color.found.underlying == .symbol);

    // Miss on an absent plugin, and on a present plugin lacking the name.
    try testing.expect(schema.lookupValueKind("color", "nope") == .not_found);
    try testing.expect(schema.lookupValueKind("gain", "a") == .not_found);

    // Bare, ambiguous: both `a` and `b` define `color`, in plugin order.
    const color = schema.lookupValueKind("color", null);
    try testing.expect(color == .ambiguous);
    try testing.expectEqual(@as(u8, 2), color.ambiguous.len);
    const claimants = color.ambiguous.slice();
    try testing.expectEqualStrings("a", claimants[0].name);
    try testing.expectEqualStrings("b", claimants[1].name);
}

test "lookupCrossRefProvider: bare, qualified, misses, and ambiguous" {
    // The fourth catalog rides `lookupGeneric` like the other three; pin it
    // head-on so the wrapper can't silently point at the wrong field.
    const a_plug: Plugin.Plugin = .{
        .name = "a",
        .cross_ref_providers = &.{.{ .name = "uniforms" }},
    };
    const b_plug: Plugin.Plugin = .{
        .name = "b",
        .cross_ref_providers = &.{
            .{ .name = "uniforms" },
            .{ .name = "columns", .wasm_export_name = "extract_columns" },
        },
    };
    const schema = Schema.init(&.{ a_plug, b_plug });

    // Bare, unambiguous: only `b` declares `columns`. The hit keeps the
    // owning plugin, which is what makes the canonical key spellable.
    const columns = schema.lookupCrossRefProvider("columns", null);
    try testing.expect(columns == .found);
    try testing.expectEqualStrings("columns", columns.found.provider.name);
    try testing.expectEqualStrings("b", columns.found.plugin.name);
    try testing.expectEqualStrings("extract_columns", columns.found.provider.wasm_export_name.?);

    // Qualified: pick `a`'s `uniforms` specifically.
    const a_uniforms = schema.lookupCrossRefProvider("uniforms", "a");
    try testing.expect(a_uniforms == .found);
    try testing.expectEqualStrings("a", a_uniforms.found.plugin.name);

    // Miss on an absent plugin, and on a present plugin lacking the name.
    try testing.expect(schema.lookupCrossRefProvider("uniforms", "nope") == .not_found);
    try testing.expect(schema.lookupCrossRefProvider("columns", "a") == .not_found);

    // Bare, ambiguous: both plugins declare `uniforms`, in plugin order.
    const uniforms = schema.lookupCrossRefProvider("uniforms", null);
    try testing.expect(uniforms == .ambiguous);
    try testing.expectEqual(@as(u8, 2), uniforms.ambiguous.len);
    const claimants = uniforms.ambiguous.slice();
    try testing.expectEqualStrings("a", claimants[0].name);
    try testing.expectEqualStrings("b", claimants[1].name);
}

test "value kind lookup" {
    const p: Plugin.Plugin = .{
        .name = "domain",
        .value_kinds = &.{
            .{ .name = "duration", .underlying = .number },
            .{ .name = "angle", .underlying = .number },
        },
    };
    const schema = Schema.init(&.{p});
    const hit = schema.lookupValueKind("angle", null);
    try testing.expect(hit == .found);
    try testing.expectEqualStrings("angle", hit.found.name);
}

test "value kind lookup miss" {
    const schema = Schema.init(&.{});
    const hit = schema.lookupValueKind("angle", null);
    try testing.expect(hit == .not_found);
}

test "value kind lookup detects cross-plugin collision" {
    const a: Plugin.Plugin = .{
        .name = "a",
        .value_kinds = &.{.{ .name = "color", .underlying = .string }},
    };
    const b: Plugin.Plugin = .{
        .name = "b",
        .value_kinds = &.{.{ .name = "color", .underlying = .string }},
    };
    const schema = Schema.init(&.{ a, b });
    const hit = schema.lookupValueKind("color", null);
    try testing.expect(hit == .ambiguous);
    try testing.expectEqual(@as(u8, 2), hit.ambiguous.len);
    const claimants = hit.ambiguous.slice();
    try testing.expectEqualStrings("a", claimants[0].name);
    try testing.expectEqualStrings("b", claimants[1].name);
}

test "value kind within-plugin duplicate resolves first-match" {
    const p: Plugin.Plugin = .{
        .name = "lone",
        .value_kinds = &.{
            .{ .name = "color", .underlying = .string },
            .{ .name = "color", .underlying = .number },
        },
    };
    const schema = Schema.init(&.{p});
    const hit = schema.lookupValueKind("color", null);
    try testing.expect(hit == .found);
    try testing.expect(hit.found.underlying == .string);
}

test "value kind qualified lookup picks the named plugin" {
    const a: Plugin.Plugin = .{
        .name = "a",
        .value_kinds = &.{.{ .name = "color", .underlying = .string }},
    };
    const b: Plugin.Plugin = .{
        .name = "b",
        .value_kinds = &.{.{ .name = "color", .underlying = .number }},
    };
    const schema = Schema.init(&.{ a, b });
    const hit = schema.lookupValueKind("color", "b");
    try testing.expect(hit == .found);
    try testing.expect(hit.found.underlying == .number);
}

test "value kind qualified lookup miss when plugin lacks kind" {
    const a: Plugin.Plugin = .{
        .name = "a",
        .value_kinds = &.{.{ .name = "color", .underlying = .string }},
    };
    const schema = Schema.init(&.{a});
    try testing.expect(schema.lookupValueKind("color", "b") == .not_found);
    try testing.expect(schema.lookupValueKind("missing", "a") == .not_found);
}

test "value kind qualified lookup beats ambiguity" {
    const a: Plugin.Plugin = .{
        .name = "a",
        .value_kinds = &.{.{ .name = "color", .underlying = .string }},
    };
    const b: Plugin.Plugin = .{
        .name = "b",
        .value_kinds = &.{.{ .name = "color", .underlying = .number }},
    };
    const schema = Schema.init(&.{ a, b });
    // Bare lookup is ambiguous.
    try testing.expect(schema.lookupValueKind("color", null) == .ambiguous);
    // Qualified lookup picks the plugin out of the ambiguity.
    const hit = schema.lookupValueKind("color", "a");
    try testing.expect(hit == .found);
    try testing.expect(hit.found.underlying == .string);
}

// ---------------------------------------------------------------------------
// validateCrossRefs — schema-aggregate phase tests.
// ---------------------------------------------------------------------------

fn freeDiagnostics(a: std.mem.Allocator, diags: []const Ast.Diagnostic) void {
    for (diags) |d| {
        a.free(d.message);
        for (d.path) |s| a.free(s);
        a.free(d.path);
    }
    a.free(diags);
}

test "assertFormKeyCaps recurses into FormSpec.local_forms (positional carrier)" {
    // The cap assertion `Schema.init` runs must visit a positional slot-local
    // form (FormSpec.local_forms) — the mirror of the KeySpec.local_forms
    // recursion. Here the positional local `circle` carries a keyed local
    // `leaf`, so init walks both carriers in one descent; under-cap, so it
    // constructs cleanly (an over-cap local would panic at init rather than
    // corrupt the validator's required-key bitset).
    const inner: Plugin.FormSpec = .{
        .name = "leaf",
        .keys = &.{.{ .name = "r", .value_type = .number, .optional = false }},
    };
    const positional_local: Plugin.FormSpec = .{
        .name = "circle",
        .keys = &.{.{ .name = "shape", .value_type = .form, .local_forms = &.{inner} }},
    };
    const p: Plugin.Plugin = .{
        .name = "ui",
        .forms = &.{.{
            .name = "canvas",
            .positional = .any,
            .local_forms = &.{positional_local},
        }},
    };
    const schema = Schema.init(&.{p}); // runs assertFormKeyCaps over both carriers
    const canvas = schema.plugins[0].forms[0];
    try testing.expectEqual(@as(usize, 1), canvas.local_forms.len);
    try testing.expectEqualStrings("circle", canvas.local_forms[0].name);
    // Keyed local nested under the positional local — proves the two compose.
    try testing.expectEqualStrings("leaf", canvas.local_forms[0].keys[0].local_forms[0].name);
}

test "validateCrossRefs: resolved target with default :name-key" {
    // (phrase :name p0) declared on plugin "audio";
    // (value-kind phrase-name :cross-ref (cross-ref :target phrase)) — should resolve cleanly.
    const audio: Plugin.Plugin = .{
        .name = "audio",
        .forms = &.{
            .{ .name = "phrase", .keys = &.{
                .{ .name = "name", .value_type = .symbol, .optional = false },
            } },
        },
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"phrase"} },
            },
        },
    };
    const schema = Schema.init(&.{audio});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateCrossRefs: a group reports each unresolvable entry, naming it" {
    // Per *entry*, not per cross-ref: a group with two typos is two
    // authoring mistakes and gets two diagnostics, each naming the entry it
    // is about. The aggregate phase collects rather than aborting, so a
    // resolvable entry beside them changes nothing.
    const gpu: Plugin.Plugin = .{
        .name = "gpu",
        .forms = &.{
            .{ .name = "render-pipeline", .keys = &.{
                .{ .name = "name", .value_type = .symbol, .optional = false },
            } },
        },
        .value_kinds = &.{
            .{
                .name = "pipeline-ref",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{ "render-pipeline", "compute-pipeline", "ghost" } },
            },
        },
    };
    const schema = Schema.init(&.{gpu});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);

    var unknown: usize = 0;
    var named_compute = false;
    var named_ghost = false;
    for (diags) |d| {
        if (d.code != .unknown_cross_ref_target) continue;
        unknown += 1;
        if (std.mem.indexOf(u8, d.message, "compute-pipeline") != null) named_compute = true;
        if (std.mem.indexOf(u8, d.message, "ghost") != null) named_ghost = true;
    }
    try testing.expectEqual(@as(usize, 2), unknown);
    try testing.expect(named_compute);
    try testing.expect(named_ghost);
}

test "validateCrossRefs: a group with one bad entry contributes no bucket" {
    // All-or-nothing: `crossRefBucketKey` returns null, so the kind cannot
    // win or lose a collapse — which is what keeps `checkTargetCollapse` in
    // step with the index it is describing.
    const gpu: Plugin.Plugin = .{
        .name = "gpu",
        .forms = &.{
            .{ .name = "render-pipeline", .keys = &.{
                .{ .name = "name", .value_type = .symbol, .optional = false },
            } },
        },
        .value_kinds = &.{
            .{
                .name = "pipeline-ref",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{ "render-pipeline", "ghost" } },
            },
        },
    };
    const schema = Schema.init(&.{gpu});
    try testing.expect((try schema.crossRefBucketKey(testing.allocator, schema.plugins[0].value_kinds[0].cross_ref.?)) == null);
}

test "crossRefBucketKey: one target keys on the canonical form name" {
    // The compatibility claim the whole design rests on: nothing about a
    // pre-group schema's bucket key changes.
    const audio: Plugin.Plugin = .{
        .name = "audio",
        .forms = &.{.{ .name = "phrase" }},
        .value_kinds = &.{
            .{ .name = "phrase-name", .underlying = .symbol, .cross_ref = .{ .targets = &.{"phrase"} } },
        },
    };
    const schema = Schema.init(&.{audio});
    const key = (try schema.crossRefBucketKey(testing.allocator, schema.plugins[0].value_kinds[0].cross_ref.?)).?;
    defer testing.allocator.free(key);
    try testing.expectEqualStrings("audio/phrase", key);
}

test "crossRefBucketKey: a group keys on every canonical target, space-joined" {
    const gpu: Plugin.Plugin = .{
        .name = "gpu",
        .forms = &.{ .{ .name = "render-pipeline" }, .{ .name = "compute-pipeline" } },
        .value_kinds = &.{
            .{
                .name = "pipeline-ref",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{ "render-pipeline", "compute-pipeline" } },
            },
        },
    };
    const schema = Schema.init(&.{gpu});
    const key = (try schema.crossRefBucketKey(testing.allocator, schema.plugins[0].value_kinds[0].cross_ref.?)).?;
    defer testing.allocator.free(key);
    // Sorted, not written-order: `compute` precedes `render` here even
    // though the manifest lists them the other way round. A space cannot
    // occur in a symbol, so this can never collide with a canonical form
    // name however the forms are spelled.
    try testing.expectEqualStrings("gpu/compute-pipeline gpu/render-pipeline", key);
    try testing.expect(std.mem.indexOfScalar(u8, key, ' ') != null);
}

test "crossRefBucketKey: the written order does not fork the bucket" {
    // A group declares one namespace, and a namespace has no order. Keyed
    // on the written order, `[a b]` and `[b a]` were two buckets over the
    // same names — which double-reported one duplicate name, hid the
    // collapse warning between them, and made `union_ambiguous` fire on a
    // slot whose two readings picked the same entity.
    const gpu: Plugin.Plugin = .{
        .name = "gpu",
        .forms = &.{ .{ .name = "render-pipeline" }, .{ .name = "compute-pipeline" } },
        .value_kinds = &.{
            .{
                .name = "forwards",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{ "render-pipeline", "compute-pipeline" } },
            },
            .{
                .name = "backwards",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{ "compute-pipeline", "render-pipeline" } },
            },
        },
    };
    const schema = Schema.init(&.{gpu});
    const fwd = (try schema.crossRefBucketKey(testing.allocator, schema.plugins[0].value_kinds[0].cross_ref.?)).?;
    defer testing.allocator.free(fwd);
    const bwd = (try schema.crossRefBucketKey(testing.allocator, schema.plugins[0].value_kinds[1].cross_ref.?)).?;
    defer testing.allocator.free(bwd);
    try testing.expectEqualStrings(fwd, bwd);
}

test "crossRefBucketKey: one form under two spellings is one target" {
    // The loader's repeat check compares spellings, so `[phrase audio/phrase]`
    // reaches here as two entries naming one form. De-duplicating after
    // canonicalisation is what keeps that group's bucket the same one
    // `:target phrase` uses — and keeps the rendered target from naming the
    // same form twice.
    const audio: Plugin.Plugin = .{
        .name = "audio",
        .forms = &.{.{ .name = "phrase" }},
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{ "phrase", "audio/phrase" } },
            },
        },
    };
    const schema = Schema.init(&.{audio});
    const key = (try schema.crossRefBucketKey(testing.allocator, schema.plugins[0].value_kinds[0].cross_ref.?)).?;
    defer testing.allocator.free(key);
    try testing.expectEqualStrings("audio/phrase", key);
    try testing.expect(std.mem.indexOfScalar(u8, key, ' ') == null);
}

test "describeBucket: one target passes through borrowed and unchanged" {
    // The byte-identity rule the whole plan rests on: a bucket with no
    // space is not rendered at all, so every pre-group message and every
    // test pinning one stays exactly as it was.
    const bucket = "phrase";
    const shown = try Schema.describeBucket(testing.allocator, bucket);
    try testing.expect(!shown.is_group);
    try testing.expectEqualStrings("phrase", shown.text);
    try testing.expect(shown.text.ptr == bucket.ptr);
}

test "describeBucket: a namespaced single target keeps its `/` and is not a group" {
    // `/` is not the separator — a canonical single-target key carries one
    // and is still one form.
    const bucket = "audio/phrase";
    const shown = try Schema.describeBucket(testing.allocator, bucket);
    try testing.expect(!shown.is_group);
    try testing.expectEqualStrings("audio/phrase", shown.text);
    try testing.expect(shown.text.ptr == bucket.ptr);
}

test "describeBucket: a group renders the bucket's order with ` | `" {
    const shown = try Schema.describeBucket(testing.allocator, "gpu/compute-pipeline gpu/render-pipeline");
    defer testing.allocator.free(shown.text);
    try testing.expect(shown.is_group);
    // The bucket's order, not the author's: canonical and sorted, which is
    // what `describeTargets` deliberately does not do.
    try testing.expectEqualStrings("gpu/compute-pipeline | gpu/render-pipeline", shown.text);
}

test "describeBucket: a three-target group gets two separators" {
    // The loop, not a two-part special case.
    const shown = try Schema.describeBucket(testing.allocator, "p/a p/b p/c");
    defer testing.allocator.free(shown.text);
    try testing.expect(shown.is_group);
    try testing.expectEqualStrings("p/a | p/b | p/c", shown.text);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, shown.text, " | "));
}

test "validateCrossRefs: unknown target emits unknown_cross_ref_target" {
    const p: Plugin.Plugin = .{
        .name = "p",
        .value_kinds = &.{
            .{
                .name = "ref",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"missing"} },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.unknown_cross_ref_target, diags[0].code);
    try testing.expectEqual(@as(usize, 3), diags[0].path.len);
    try testing.expectEqualStrings("p", diags[0].path[0]);
    try testing.expectEqualStrings("ref", diags[0].path[1]);
    try testing.expectEqualStrings("cross-ref", diags[0].path[2]);
}

test "validateCrossRefs: OOM mid-walk leaves no partial diagnostic behind" {
    // A dangling `:target missing` makes checkCrossRef allocate a diagnostic
    // (message + 3-segment path) — so the build phase actually reaches into
    // the allocator, unlike a clean schema. Walking a FailingAllocator across
    // every allocation point proves the scratch-arena + atomic copy-out path
    // never leaks: an induced failure returns OutOfMemory with nothing left
    // behind (std.testing.allocator underneath flags any leak). This is the
    // path all five aggregate validators share via `dupeAggregateDiagnostics`.
    const p: Plugin.Plugin = .{
        .name = "p",
        .value_kinds = &.{
            .{ .name = "ref", .underlying = .symbol, .cross_ref = .{ .targets = &.{"missing"} } },
        },
    };
    const schema = Schema.init(&.{p});

    const MAX_FAIL_INDEX: usize = 4096;
    var fail_index: usize = 0;
    while (fail_index < MAX_FAIL_INDEX) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const a = failing.allocator();

        const result = schema.validateCrossRefs(a);
        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            const diags = try result;
            defer freeDiagnostics(a, diags);
            try testing.expectEqual(@as(usize, 1), diags.len);
            try testing.expectEqual(Ast.Diagnostic.Code.unknown_cross_ref_target, diags[0].code);
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}

test "validateCrossRefs: ambiguous target emits ambiguous_cross_ref_target" {
    const a_plug: Plugin.Plugin = .{
        .name = "a",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .symbol, .optional = false },
        } }},
    };
    const b_plug: Plugin.Plugin = .{
        .name = "b",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .symbol, .optional = false },
        } }},
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"phrase"} },
            },
        },
    };
    const schema = Schema.init(&.{ a_plug, b_plug });
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.ambiguous_cross_ref_target, diags[0].code);
    try testing.expectEqualStrings(
        "value-kind `phrase-name` cross-ref `:target phrase` is ambiguous — defined by [a, b]; qualify with `<ns>/phrase`",
        diags[0].message,
    );
}

test "validateCrossRefs: qualified target resolves to one specific plugin" {
    const a_plug: Plugin.Plugin = .{
        .name = "a",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .symbol, .optional = false },
        } }},
    };
    const b_plug: Plugin.Plugin = .{
        .name = "b",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .symbol, .optional = false },
        } }},
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"a/phrase"} },
            },
        },
    };
    const schema = Schema.init(&.{ a_plug, b_plug });
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateCrossRefs: name-key not on target emits cross_ref_name_key_unknown" {
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .symbol, .optional = false },
        } }},
        .value_kinds = &.{
            .{
                .name = "ref",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"phrase"}, .name_key = "label" },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.cross_ref_name_key_unknown, diags[0].code);
}

test "validateCrossRefs: name-key with non-symbol type emits cross_ref_name_key_unknown" {
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .number, .optional = false },
        } }},
        .value_kinds = &.{
            .{
                .name = "ref",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"phrase"} },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.cross_ref_name_key_unknown, diags[0].code);
}

test "validateCrossRefs: named symbol-underlying value-kind on name-key resolves" {
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "label", .value_type = .{ .named = .{ .name = "tag-id" } }, .optional = false },
        } }},
        .value_kinds = &.{
            .{ .name = "tag-id", .underlying = .symbol },
            .{
                .name = "ref",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"phrase"}, .name_key = "label" },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

// ── provider route ───────────────────────────────────────────────────────
//
// The aggregate pass' half of the provider story: does `:provider`
// resolve, and could the target form ever hand it a string? Extraction
// itself is a host pre-pass — nothing here runs a provider.

test "validateCrossRefs: provider route with a string source-key resolves cleanly" {
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "shader", .keys = &.{
            .{ .name = "src", .value_type = .string, .optional = false },
        } }},
        .cross_ref_providers = &.{.{ .name = "uniforms" }},
        .value_kinds = &.{
            .{
                .name = "uniform-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"}, .provider = "uniforms" },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateCrossRefs: unknown provider emits unknown_cross_ref_provider" {
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "shader", .keys = &.{
            .{ .name = "src", .value_type = .string, .optional = false },
        } }},
        .value_kinds = &.{
            .{
                .name = "uniform-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"}, .provider = "nope" },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.unknown_cross_ref_provider, diags[0].code);
    try testing.expectEqual(@as(usize, 3), diags[0].path.len);
    try testing.expectEqualStrings("p", diags[0].path[0]);
    try testing.expectEqualStrings("uniform-name", diags[0].path[1]);
    try testing.expectEqualStrings("cross-ref", diags[0].path[2]);
}

test "validateCrossRefs: bare provider claimed by two plugins emits ambiguous_cross_ref_provider" {
    const a_plug: Plugin.Plugin = .{
        .name = "a",
        .cross_ref_providers = &.{.{ .name = "uniforms" }},
    };
    const b_plug: Plugin.Plugin = .{
        .name = "b",
        .forms = &.{.{ .name = "shader", .keys = &.{
            .{ .name = "src", .value_type = .string, .optional = false },
        } }},
        .cross_ref_providers = &.{.{ .name = "uniforms" }},
        .value_kinds = &.{
            .{
                .name = "uniform-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"}, .provider = "uniforms" },
            },
        },
    };
    const schema = Schema.init(&.{ a_plug, b_plug });
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.ambiguous_cross_ref_provider, diags[0].code);
    try testing.expect(std.mem.indexOf(u8, diags[0].message, "qualify with `<ns>/uniforms`") != null);
}

test "validateCrossRefs: qualified provider picks one plugin out of a collision" {
    const a_plug: Plugin.Plugin = .{
        .name = "a",
        .cross_ref_providers = &.{.{ .name = "uniforms" }},
    };
    const b_plug: Plugin.Plugin = .{
        .name = "b",
        .forms = &.{.{ .name = "shader", .keys = &.{
            .{ .name = "src", .value_type = .string, .optional = false },
        } }},
        .cross_ref_providers = &.{.{ .name = "uniforms" }},
        .value_kinds = &.{
            .{
                .name = "uniform-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"}, .provider = "a/uniforms" },
            },
        },
    };
    const schema = Schema.init(&.{ a_plug, b_plug });
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateCrossRefs: source-key not on target emits cross_ref_source_key_unknown" {
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "shader", .keys = &.{
            .{ .name = "src", .value_type = .string, .optional = false },
        } }},
        .cross_ref_providers = &.{.{ .name = "uniforms" }},
        .value_kinds = &.{
            .{
                .name = "uniform-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"}, .provider = "uniforms", .source_key = "body" },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.cross_ref_source_key_unknown, diags[0].code);
}

test "validateCrossRefs: non-string source-key emits cross_ref_source_key_unknown" {
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "shader", .keys = &.{
            .{ .name = "src", .value_type = .number, .optional = false },
        } }},
        .cross_ref_providers = &.{.{ .name = "uniforms" }},
        .value_kinds = &.{
            .{
                .name = "uniform-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"}, .provider = "uniforms" },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.cross_ref_source_key_unknown, diags[0].code);
}

test "validateCrossRefs: a string_bounds-refined named kind satisfies :source-key" {
    // A refinement narrows a string rather than replacing it, and the
    // provider is handed the same bytes either way — so this resolves.
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "shader", .keys = &.{
            .{ .name = "src", .value_type = .{ .named = .{ .name = "glsl-source" } }, .optional = false },
        } }},
        .cross_ref_providers = &.{.{ .name = "uniforms" }},
        .value_kinds = &.{
            .{
                .name = "glsl-source",
                .underlying = .string,
                .string_bounds = .{ .min_len = 1 },
            },
            .{
                .name = "uniform-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"}, .provider = "uniforms" },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateCrossRefs: the provider route never checks :name-key" {
    // The routes dispatch, they don't stack: a provider-backed spec whose
    // (defaulted) `:name-key` names nothing on the target must stay quiet.
    // Getting this wrong would fire cross_ref_name_key_unknown on every
    // provider-backed kind whose target has no `:name`.
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "shader", .keys = &.{
            .{ .name = "src", .value_type = .string, .optional = false },
        } }},
        .cross_ref_providers = &.{.{ .name = "uniforms" }},
        .value_kinds = &.{
            .{
                .name = "uniform-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"}, .provider = "uniforms" },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

// --- Target collapse (cross_ref_target_collapse) ---------------------------
//
// One target form, one member set, built first-wins. These pin *when* the
// second declaration is inert enough to warn about — the mixed-route case
// is the one the provider route introduced, but a same-route disagreement
// about the key or the scope is just as inert.

/// A target form carrying both a symbol `:name` and a string `:src`, so an
/// identity-route and a provider-route cross-ref can each be declared
/// against it without either tripping a key-shape diagnostic. Callers
/// append their own value-kinds.
fn collapseShaderForm() Plugin.FormSpec {
    return .{ .name = "shader", .keys = &.{
        .{ .name = "name", .value_type = .symbol, .optional = false },
        .{ .name = "src", .value_type = .string, .optional = false },
    } };
}

test "validateCrossRefs: identity and provider routes on one target collapse" {
    const p: Plugin.Plugin = .{
        .name = "gl",
        .forms = &.{collapseShaderForm()},
        .cross_ref_providers = &.{.{ .name = "uniforms" }},
        .value_kinds = &.{
            .{
                .name = "shader-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"} },
            },
            .{
                .name = "uniform-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"}, .provider = "uniforms" },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.cross_ref_target_collapse, diags[0].code);
    try testing.expectEqual(Ast.Diagnostic.Severity.warning, diags[0].severity);
    // Pathed at the *loser* — the kind whose declaration is inert.
    try testing.expectEqualStrings("gl", diags[0].path[0]);
    try testing.expectEqualStrings("uniform-name", diags[0].path[1]);
    try testing.expectEqualStrings("cross-ref", diags[0].path[2]);
    // Pinned whole, not by substring: the ts-parity host pins the same
    // literal in `test/cross-ref-provider.test.ts`, so "byte-identical
    // across hosts" is gated from both ends rather than asserted in prose.
    // It names both routes (so the reader can tell which won) and names
    // the target canonically, not as the manifest spelled it.
    try testing.expectEqualStrings(
        "value-kind `uniform-name` cross-references form `gl/shader`, whose members are already " ++
            "collected by value-kind `shader-name` in plugin `gl` using `:name-key name`; this kind's " ++
            "`:provider gl/uniforms` over `:source-key src` is ignored, and its references are checked " ++
            "against the other kind's names",
        diags[0].message,
    );
}

test "validateCrossRefs: declaration order decides which route wins" {
    // Same two kinds, swapped. The warning must follow the order, not a
    // preference for either route — the registry has no preference either.
    const p: Plugin.Plugin = .{
        .name = "gl",
        .forms = &.{collapseShaderForm()},
        .cross_ref_providers = &.{.{ .name = "uniforms" }},
        .value_kinds = &.{
            .{
                .name = "uniform-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"}, .provider = "uniforms" },
            },
            .{
                .name = "shader-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"} },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.cross_ref_target_collapse, diags[0].code);
    try testing.expectEqualStrings("shader-name", diags[0].path[1]);
}

test "validateCrossRefs: two kinds aliasing one target identically stay silent" {
    // The common idiom — a `:vertex` slot and a `:fragment` slot both
    // typed as references to the same form. Both agree on the member set,
    // so first-wins costs nothing and there is nothing to report.
    const p: Plugin.Plugin = .{
        .name = "gl",
        .forms = &.{collapseShaderForm()},
        .value_kinds = &.{
            .{ .name = "vertex-ref", .underlying = .symbol, .cross_ref = .{ .targets = &.{"shader"} } },
            .{ .name = "fragment-ref", .underlying = .symbol, .cross_ref = .{ .targets = &.{"shader"} } },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateCrossRefs: two provider-route kinds agreeing stay silent" {
    // Same aliasing idiom one route over — including that a bare and a
    // qualified `:provider` spelling of the same provider agree, because
    // the comparison is canonical.
    const p: Plugin.Plugin = .{
        .name = "gl",
        .forms = &.{collapseShaderForm()},
        .cross_ref_providers = &.{.{ .name = "uniforms" }},
        .value_kinds = &.{
            .{
                .name = "uniform-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"}, .provider = "uniforms" },
            },
            .{
                .name = "uniform-ref",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"}, .provider = "gl/uniforms" },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateCrossRefs: same route, different :name-key collapses" {
    const p: Plugin.Plugin = .{
        .name = "gl",
        .forms = &.{.{ .name = "shader", .keys = &.{
            .{ .name = "name", .value_type = .symbol, .optional = false },
            .{ .name = "alias", .value_type = .symbol, .optional = false },
        } }},
        .value_kinds = &.{
            .{ .name = "by-name", .underlying = .symbol, .cross_ref = .{ .targets = &.{"shader"} } },
            .{
                .name = "by-alias",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"}, .name_key = "alias" },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.cross_ref_target_collapse, diags[0].code);
    try testing.expectEqualStrings("by-alias", diags[0].path[1]);
}

test "validateCrossRefs: one group spelled two ways still collapses" {
    // The collapse check reports the *bucket*, so it only sees these two
    // kinds as one registry if the key ignores the written order. Keyed on
    // the order, each got a bucket of its own, both honoured their own
    // `:name-key`, and this warning — the one that tells the author their
    // `:name-key alias` is ignored — went silent.
    const p: Plugin.Plugin = .{
        .name = "gl",
        .forms = &.{
            .{ .name = "shader", .keys = &.{
                .{ .name = "name", .value_type = .symbol, .optional = false },
                .{ .name = "alias", .value_type = .symbol, .optional = false },
            } },
            .{ .name = "kernel", .keys = &.{
                .{ .name = "name", .value_type = .symbol, .optional = false },
                .{ .name = "alias", .value_type = .symbol, .optional = false },
            } },
        },
        .value_kinds = &.{
            .{
                .name = "by-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{ "shader", "kernel" } },
            },
            .{
                .name = "by-alias",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{ "kernel", "shader" }, .name_key = "alias" },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.cross_ref_target_collapse, diags[0].code);
    try testing.expectEqualStrings("by-alias", diags[0].path[1]);
    try testing.expect(std.mem.indexOf(u8, diags[0].message, "the target group") != null);
}

test "validateCrossRefs: a differing :scope collapses too" {
    // Scope is part of how the set is *keyed*, not just where it is read,
    // so two kinds disagreeing about it disagree about the registry.
    const p: Plugin.Plugin = .{
        .name = "gl",
        .forms = &.{
            collapseShaderForm(),
            .{ .name = "pass", .keys = &.{} },
        },
        .value_kinds = &.{
            .{ .name = "global-ref", .underlying = .symbol, .cross_ref = .{ .targets = &.{"shader"} } },
            .{
                .name = "scoped-ref",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"}, .scope_form = "pass" },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.cross_ref_target_collapse, diags[0].code);
    try testing.expect(std.mem.indexOf(u8, diags[0].message, "scoped to `gl/pass`") != null);
}

test "validateCrossRefs: a differing :acyclic alone does not collapse" {
    // `:acyclic` is a check run *over* the finished registry, not an input
    // to building it, so it is deliberately outside RegistrySpec. Both
    // kinds get the same member set; only one of them also walks it for
    // cycles, and that is not a disagreement worth a warning.
    const p: Plugin.Plugin = .{
        .name = "gl",
        .forms = &.{.{ .name = "shader", .keys = &.{
            .{ .name = "name", .value_type = .symbol, .optional = false },
            .{ .name = "base", .value_type = .{ .named = .{ .name = "strict-ref" } }, .optional = true },
        } }},
        .value_kinds = &.{
            .{ .name = "loose-ref", .underlying = .symbol, .cross_ref = .{ .targets = &.{"shader"} } },
            .{
                .name = "strict-ref",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"}, .acyclic = true },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateCrossRefs: every loser is compared against the first winner" {
    // Not a chain: the third kind disagrees with the second but *agrees*
    // with the first, so it must not warn. Comparing pairwise against the
    // previous kind instead of the winner would report it.
    const p: Plugin.Plugin = .{
        .name = "gl",
        .forms = &.{collapseShaderForm()},
        .cross_ref_providers = &.{.{ .name = "uniforms" }},
        .value_kinds = &.{
            .{ .name = "first", .underlying = .symbol, .cross_ref = .{ .targets = &.{"shader"} } },
            .{
                .name = "second",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"}, .provider = "uniforms" },
            },
            .{ .name = "third", .underlying = .symbol, .cross_ref = .{ .targets = &.{"shader"} } },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("second", diags[0].path[1]);
}

test "validateCrossRefs: collapse spans plugins, in load order" {
    const first: Plugin.Plugin = .{
        .name = "gl",
        .forms = &.{collapseShaderForm()},
        .value_kinds = &.{
            .{ .name = "shader-name", .underlying = .symbol, .cross_ref = .{ .targets = &.{"shader"} } },
        },
    };
    const second: Plugin.Plugin = .{
        .name = "ext",
        .cross_ref_providers = &.{.{ .name = "uniforms" }},
        .value_kinds = &.{
            .{
                .name = "uniform-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"gl/shader"}, .provider = "uniforms" },
            },
        },
    };
    const schema = Schema.init(&.{ first, second });
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.cross_ref_target_collapse, diags[0].code);
    try testing.expectEqualStrings("ext", diags[0].path[0]);
    // The winner is named with its owning plugin, which is the whole point
    // when the two kinds live in different manifests.
    try testing.expect(std.mem.indexOf(u8, diags[0].message, "plugin `gl`") != null);
}

test "validateCrossRefs: a spec the registry never sees cannot collapse" {
    // An unresolvable `:provider` drops the cross-ref before it reaches
    // `collectCrossRefTargets`' map, so it neither wins nor loses a
    // collapse — one diagnostic (the unknown provider), not two. Mirroring
    // that skip is what keeps the warning from blaming a spec that was
    // already reported for a different reason.
    const p: Plugin.Plugin = .{
        .name = "gl",
        .forms = &.{collapseShaderForm()},
        .value_kinds = &.{
            .{ .name = "shader-name", .underlying = .symbol, .cross_ref = .{ .targets = &.{"shader"} } },
            .{
                .name = "uniform-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"shader"}, .provider = "nope" },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.unknown_cross_ref_provider, diags[0].code);
}

test "validateCrossRefs: distinct targets never collapse" {
    const p: Plugin.Plugin = .{
        .name = "gl",
        .forms = &.{
            collapseShaderForm(),
            .{ .name = "buffer", .keys = &.{
                .{ .name = "name", .value_type = .symbol, .optional = false },
                .{ .name = "src", .value_type = .string, .optional = false },
            } },
        },
        .cross_ref_providers = &.{.{ .name = "uniforms" }},
        .value_kinds = &.{
            .{ .name = "shader-name", .underlying = .symbol, .cross_ref = .{ .targets = &.{"shader"} } },
            .{
                .name = "buffer-field",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"buffer"}, .provider = "uniforms" },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateCrossRefs: unresolved target and unresolved provider both diagnose" {
    // Two independent authoring mistakes, two diagnostics — the aggregate
    // pass collects rather than short-circuiting on the first.
    const p: Plugin.Plugin = .{
        .name = "p",
        .value_kinds = &.{
            .{
                .name = "uniform-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"nope"}, .provider = "also-nope" },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 2), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.unknown_cross_ref_target, diags[0].code);
    try testing.expectEqual(Ast.Diagnostic.Code.unknown_cross_ref_provider, diags[1].code);
}

test "validateCrossRefs: :acyclic true without self-edge emits acyclic_without_self_edge" {
    // (phrase :name p0) — no `:parent`, no self-edge keys; flagging
    // `:acyclic true` here is meaningless and should diagnose at
    // schema-aggregate time so authoring confusion surfaces early.
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .symbol, .optional = false },
        } }},
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"phrase"}, .acyclic = true },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.acyclic_without_self_edge, diags[0].code);
    try testing.expect(std.mem.indexOf(u8, diags[0].message, "phrase-name") != null);
}

test "validateCrossRefs: :acyclic true with scalar self-edge resolves cleanly" {
    // (phrase :name :parent) — `:parent phrase-name` is the self-edge.
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = false },
            .{ .name = "parent", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = true },
        } }},
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"phrase"}, .acyclic = true },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateCrossRefs: :acyclic true with vector self-edge resolves cleanly" {
    // `:children phrase-name-list` is a vector-shape kind whose element
    // resolves to phrase-name — the one-vector-hop self-edge case.
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = false },
            .{ .name = "children", .value_type = .{ .named = .{ .name = "phrase-name-list" } }, .optional = true },
        } }},
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"phrase"}, .acyclic = true },
            },
            .{
                .name = "phrase-name-list",
                .underlying = .vector,
                .vector = .{ .element = .{ .name = "phrase-name" } },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateCrossRefs: unknown :scope emits unknown_cross_ref_scope" {
    // Cross-ref opts into `:scope nope` but no form named `nope` exists in
    // the schema — the lexical-scope opener can't bind to anything.
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .symbol, .optional = false },
        } }},
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"phrase"}, .scope_form = "nope" },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.unknown_cross_ref_scope, diags[0].code);
    try testing.expectEqual(@as(usize, 3), diags[0].path.len);
    try testing.expectEqualStrings("p", diags[0].path[0]);
    try testing.expectEqualStrings("phrase-name", diags[0].path[1]);
    try testing.expectEqualStrings("cross-ref", diags[0].path[2]);
}

test "validateCrossRefs: ambiguous bare :scope emits ambiguous_cross_ref_scope" {
    // Two plugins each define a form named `track`. A bare `:scope track`
    // can't pick one — author must qualify with `<ns>/track`.
    const a_plug: Plugin.Plugin = .{
        .name = "a",
        .forms = &.{.{ .name = "track", .keys = &.{
            .{ .name = "id", .value_type = .symbol, .optional = false },
        } }},
    };
    const b_plug: Plugin.Plugin = .{
        .name = "b",
        .forms = &.{
            .{ .name = "track", .keys = &.{
                .{ .name = "id", .value_type = .symbol, .optional = false },
            } },
            .{ .name = "phrase", .keys = &.{
                .{ .name = "name", .value_type = .symbol, .optional = false },
            } },
        },
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"b/phrase"}, .scope_form = "track" },
            },
        },
    };
    const schema = Schema.init(&.{ a_plug, b_plug });
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.ambiguous_cross_ref_scope, diags[0].code);
    try testing.expectEqualStrings(
        "value-kind `phrase-name` cross-ref `:scope track` is ambiguous — defined by [a, b]; qualify with `<ns>/track`",
        diags[0].message,
    );
}

test "validateCrossRefs: qualified :scope resolves cleanly" {
    // Sanity counter to the ambiguous case — qualifying disambiguates.
    const a_plug: Plugin.Plugin = .{
        .name = "a",
        .forms = &.{.{ .name = "track", .keys = &.{
            .{ .name = "id", .value_type = .symbol, .optional = false },
        } }},
    };
    const b_plug: Plugin.Plugin = .{
        .name = "b",
        .forms = &.{
            .{ .name = "track", .keys = &.{
                .{ .name = "id", .value_type = .symbol, .optional = false },
            } },
            .{ .name = "phrase", .keys = &.{
                .{ .name = "name", .value_type = .symbol, .optional = false },
            } },
        },
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"b/phrase"}, .scope_form = "b/track" },
            },
        },
    };
    const schema = Schema.init(&.{ a_plug, b_plug });
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

// ---------------------------------------------------------------------------
// selfEdgeShape coverage — vector path + primitive-name short-circuit.
//
// The earlier "vector self-edge resolves cleanly" test bypassed the vector
// branch because its first key was already a scalar self-edge; the walker
// returned at the `.named == target_kind` arm and never inspected the
// vector-shape kind. The cases below force selfEdgeShape into the vector
// arm and the `isPrimitiveTypeName` short-circuit.
// ---------------------------------------------------------------------------

test "validateCrossRefs: :acyclic true with vector-only self-edge resolves cleanly" {
    // `:name` is a bare `.symbol` (not a `.named` self-edge), so the only
    // self-edge has to come through `:kids` → phrase-name-list (a vector
    // whose element resolves directly to phrase-name). Forces selfEdgeShape
    // into the `vs.element == target_kind` branch.
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .symbol, .optional = false },
            .{ .name = "kids", .value_type = .{ .named = .{ .name = "phrase-name-list" } }, .optional = true },
        } }},
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"phrase"}, .acyclic = true },
            },
            .{
                .name = "phrase-name-list",
                .underlying = .vector,
                .vector = .{ .element = .{ .name = "phrase-name" } },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateCrossRefs: :acyclic true with vector-of-primitive element diagnoses no self-edge" {
    // `:tags` → tag-list, a vector whose element is the primitive `string`.
    // Forces selfEdgeShape into the `vs.element` primitive short-circuit
    // (`isPrimitiveTypeName("string")` returns true). With no self-edges
    // anywhere on the form, the kind diagnoses `acyclic_without_self_edge`.
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .symbol, .optional = false },
            .{ .name = "tags", .value_type = .{ .named = .{ .name = "tag-list" } }, .optional = true },
        } }},
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"phrase"}, .acyclic = true },
            },
            .{
                .name = "tag-list",
                .underlying = .vector,
                .vector = .{ .element = .{ .name = "string" } },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.acyclic_without_self_edge, diags[0].code);
}

test "validateCrossRefs: :acyclic true walking past vector hop into a non-looping kind diagnoses" {
    // `:tags` → tag-list (vector of tag-id) → tag-id (symbol kind, no
    // outgoing edges). selfEdgeShape takes the one allowed vector hop,
    // continues into tag-id, finds no further vector — bottoms out as
    // "no self-edge". Exercises the post-vector `.named` continuation
    // path and the trailing `return null` after the `vk.vector` branch.
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .symbol, .optional = false },
            .{ .name = "tags", .value_type = .{ .named = .{ .name = "tag-list" } }, .optional = true },
        } }},
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"phrase"}, .acyclic = true },
            },
            .{
                .name = "tag-list",
                .underlying = .vector,
                .vector = .{ .element = .{ .name = "tag-id" } },
            },
            .{ .name = "tag-id", .underlying = .symbol },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.acyclic_without_self_edge, diags[0].code);
}

test "validateCrossRefs: :acyclic true with .named primitive type short-circuits to no self-edge" {
    // `:weight :type number` is declared as a `.named "number"` value-type
    // — selfEdgeShape's first-iteration `isPrimitiveTypeName` short-circuit
    // fires on the bare-primitive name and returns null without consulting
    // the value-kind table.
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .symbol, .optional = false },
            .{ .name = "weight", .value_type = .{ .named = .{ .name = "number" } }, .optional = true },
        } }},
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"phrase"}, .acyclic = true },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateCrossRefs(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.acyclic_without_self_edge, diags[0].code);
}

// ---------------------------------------------------------------------------
// validateUnions — schema-aggregate phase tests.
// ---------------------------------------------------------------------------

test "validateUnions: every alternative resolves cleanly → no diagnostics" {
    const p: Plugin.Plugin = .{
        .name = "p",
        .value_kinds = &.{
            .{ .name = "a", .underlying = .symbol },
            .{ .name = "b", .underlying = .form },
            .{
                .name = "a-or-b",
                .underlying = .union_of,
                .union_of = .{ .alternatives = &.{ .{ .name = "a" }, .{ .name = "b" } } },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateUnions(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateUnions: primitive shortcuts as alternatives need no catalog lookup" {
    const p: Plugin.Plugin = .{
        .name = "p",
        .value_kinds = &.{
            .{
                .name = "scalar-or-color",
                .underlying = .union_of,
                .union_of = .{ .alternatives = &.{ .{ .name = "number" }, .{ .name = "vector" }, .{ .name = "form" } } },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateUnions(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateUnions: unknown alternative emits unknown_element_kind" {
    const p: Plugin.Plugin = .{
        .name = "p",
        .value_kinds = &.{
            .{ .name = "a", .underlying = .symbol },
            .{
                .name = "u",
                .underlying = .union_of,
                .union_of = .{ .alternatives = &.{ .{ .name = "a" }, .{ .name = "missing" } } },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateUnions(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.unknown_element_kind, diags[0].code);
    try testing.expectEqual(@as(usize, 3), diags[0].path.len);
    try testing.expectEqualStrings("p", diags[0].path[0]);
    try testing.expectEqualStrings("u", diags[0].path[1]);
    try testing.expectEqualStrings("union", diags[0].path[2]);
}

test "validateUnions: ambiguous alternative emits ambiguous_element_kind" {
    const a_plug: Plugin.Plugin = .{
        .name = "a",
        .value_kinds = &.{.{ .name = "shared", .underlying = .symbol }},
    };
    const b_plug: Plugin.Plugin = .{
        .name = "b",
        .value_kinds = &.{
            .{ .name = "shared", .underlying = .symbol },
            .{
                .name = "u",
                .underlying = .union_of,
                .union_of = .{ .alternatives = &.{ .{ .name = "shared" }, .{ .name = "number" } } },
            },
        },
    };
    const schema = Schema.init(&.{ a_plug, b_plug });
    const diags = try schema.validateUnions(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.ambiguous_element_kind, diags[0].code);
    try testing.expectEqualStrings(
        "value-kind `u` `:union` alternative `shared` is ambiguous — defined by [a, b]; qualify with `a/shared`",
        diags[0].message,
    );
}

test "validateUnions: nested union emits nested_union" {
    const p: Plugin.Plugin = .{
        .name = "p",
        .value_kinds = &.{
            .{ .name = "a", .underlying = .symbol },
            .{ .name = "b", .underlying = .form },
            .{
                .name = "inner",
                .underlying = .union_of,
                .union_of = .{ .alternatives = &.{ .{ .name = "a" }, .{ .name = "b" } } },
            },
            .{
                .name = "outer",
                .underlying = .union_of,
                // Pulling `inner` into `outer`'s alternatives is the
                // forbidden case — dispatch must stay flat.
                .union_of = .{ .alternatives = &.{ .{ .name = "a" }, .{ .name = "inner" } } },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateUnions(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.nested_union, diags[0].code);
    try testing.expect(std.mem.indexOf(u8, diags[0].message, "outer") != null);
    try testing.expect(std.mem.indexOf(u8, diags[0].message, "inner") != null);
}

// ---------------------------------------------------------------------------
// validateForms — schema-aggregate phase tests for discriminated forms.
// ---------------------------------------------------------------------------

test "validateForms: discriminant resolving to closed MemberSet → clean" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "thing",
                .keys = &.{
                    .{ .name = "kind", .value_type = .{ .named = .{ .name = "thing-kind" } }, .optional = false },
                },
                .discriminant_name = "kind",
                .discriminant_idx = 0,
                .variants = &.{
                    .{ .when = &.{"x"}, .keys = &.{} },
                },
            },
        },
        .value_kinds = &.{
            .{
                .name = "thing-kind",
                .underlying = .symbol,
                .members = .{ .members = &.{ .{ .name = "x" }, .{ .name = "y" } } },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateForms(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateForms: discriminant on bare .symbol emits discriminant_not_closed_enum" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "thing",
                .keys = &.{
                    .{ .name = "kind", .value_type = .symbol, .optional = false },
                },
                .discriminant_name = "kind",
                .discriminant_idx = 0,
                .variants = &.{
                    .{ .when = &.{"x"}, .keys = &.{} },
                },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateForms(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.discriminant_not_closed_enum, diags[0].code);
}

test "validateForms: variant :when not in member-set emits unknown_discriminant_value" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "thing",
                .keys = &.{
                    .{ .name = "kind", .value_type = .{ .named = .{ .name = "thing-kind" } }, .optional = false },
                },
                .discriminant_name = "kind",
                .discriminant_idx = 0,
                .variants = &.{
                    .{ .when = &.{"bogus"}, .keys = &.{} },
                },
            },
        },
        .value_kinds = &.{
            .{
                .name = "thing-kind",
                .underlying = .symbol,
                .members = .{ .members = &.{ .{ .name = "x" }, .{ .name = "y" } } },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateForms(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.unknown_discriminant_value, diags[0].code);
    try testing.expect(std.mem.indexOf(u8, diags[0].message, "bogus") != null);
}

test "validateForms: a multi-value :when is checked once per value, naming the value" {
    // `[x nope]` reports `nope` and keeps `x`; a set with one typo names
    // the typo rather than rejecting the whole declaration.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "thing",
                .keys = &.{
                    .{ .name = "kind", .value_type = .{ .named = .{ .name = "thing-kind" } }, .optional = false },
                },
                .discriminant_name = "kind",
                .discriminant_idx = 0,
                .variants = &.{
                    .{ .when = &.{ "x", "nope", "y" }, .keys = &.{} },
                },
            },
        },
        .value_kinds = &.{
            .{
                .name = "thing-kind",
                .underlying = .symbol,
                .members = .{ .members = &.{ .{ .name = "x" }, .{ .name = "y" } } },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateForms(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.unknown_discriminant_value, diags[0].code);
    try testing.expectEqualStrings(
        "form `thing` variant `:when [x nope y]` lists `nope`, which is not a member of discriminant `:kind`",
        diags[0].message,
    );
}

test "validateForms: a multi-value :when keeps the key-collision check as strict" {
    // One declaration reaching several values is what makes the collision
    // question never arise — but the check itself is unchanged, and the
    // message spells the offending variant as the author did.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "thing",
                .keys = &.{
                    .{ .name = "kind", .value_type = .{ .named = .{ .name = "thing-kind" } }, .optional = false },
                },
                .discriminant_name = "kind",
                .discriminant_idx = 0,
                .variants = &.{
                    .{ .when = &.{ "x", "y" }, .keys = &.{.{ .name = "dup", .value_type = .number, .optional = true }} },
                    .{ .when = &.{"z"}, .keys = &.{.{ .name = "dup", .value_type = .string, .optional = true }} },
                },
            },
        },
        .value_kinds = &.{
            .{
                .name = "thing-kind",
                .underlying = .symbol,
                .members = .{ .members = &.{ .{ .name = "x" }, .{ .name = "y" }, .{ .name = "z" } } },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateForms(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.variant_key_collision, diags[0].code);
    try testing.expectEqualStrings(
        "form `thing` variant `:when z` redeclares key `:dup` (also in variant `:when [x y]`)",
        diags[0].message,
    );
}

test "validateForms: variant key collides with common key emits variant_key_collision" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "thing",
                .keys = &.{
                    .{ .name = "kind", .value_type = .{ .named = .{ .name = "thing-kind" } }, .optional = false },
                    .{ .name = "shared", .value_type = .number, .optional = true },
                },
                .discriminant_name = "kind",
                .discriminant_idx = 0,
                .variants = &.{
                    .{
                        .when = &.{"x"},
                        .keys = &.{
                            .{ .name = "shared", .value_type = .string, .optional = true },
                        },
                    },
                },
            },
        },
        .value_kinds = &.{
            .{
                .name = "thing-kind",
                .underlying = .symbol,
                .members = .{ .members = &.{.{ .name = "x" }} },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateForms(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.variant_key_collision, diags[0].code);
    try testing.expect(std.mem.indexOf(u8, diags[0].message, "shared") != null);
}

test "validateForms: same key in two variants emits variant_key_collision" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "thing",
                .keys = &.{
                    .{ .name = "kind", .value_type = .{ .named = .{ .name = "thing-kind" } }, .optional = false },
                },
                .discriminant_name = "kind",
                .discriminant_idx = 0,
                .variants = &.{
                    .{ .when = &.{"x"}, .keys = &.{.{ .name = "dup", .value_type = .number, .optional = true }} },
                    .{ .when = &.{"y"}, .keys = &.{.{ .name = "dup", .value_type = .string, .optional = true }} },
                },
            },
        },
        .value_kinds = &.{
            .{
                .name = "thing-kind",
                .underlying = .symbol,
                .members = .{ .members = &.{ .{ .name = "x" }, .{ .name = "y" } } },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateForms(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.variant_key_collision, diags[0].code);
}

test "validateForms: form with no discriminant is skipped" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{
            .{
                .name = "plain",
                .keys = &.{.{ .name = "k", .value_type = .number, .optional = true }},
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateForms(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

// ---------------------------------------------------------------------------
// collectAcyclicSpecs — direct exercise of the schema-build helper.
//
// `collectAcyclicSpecs` is reachable transitively from `Validator.validateForest`,
// but the validator's existing acyclic suite happens to exercise only the
// no-slash / no-scope path. Direct tests here make the slash- and scope-
// canonicalisation branches reachable from `kcov` and pin the schema-side
// contract independently of the validator pipeline.
// ---------------------------------------------------------------------------

test "collectAcyclicSpecs: empty schema → empty result" {
    const schema = Schema.init(&.{});
    const specs = try collectAcyclicSpecs(schema, testing.allocator);
    defer freeAcyclicSpecs(testing.allocator, specs);
    try testing.expectEqual(@as(usize, 0), specs.len);
}

test "collectAcyclicSpecs: kinds without :acyclic are skipped" {
    // Kind without cross-ref + kind with `:acyclic false` both bail out at
    // the `cr.acyclic` filter; neither produces a spec.
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .symbol, .optional = false },
        } }},
        .value_kinds = &.{
            .{ .name = "raw", .underlying = .symbol },
            .{
                .name = "ref",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"phrase"}, .acyclic = false },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const specs = try collectAcyclicSpecs(schema, testing.allocator);
    defer freeAcyclicSpecs(testing.allocator, specs);
    try testing.expectEqual(@as(usize, 0), specs.len);
}

test "collectAcyclicSpecs: scalar self-edge produces a spec with canonicalised target" {
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = false },
            .{ .name = "parent", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = true },
        } }},
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"phrase"}, .acyclic = true },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const specs = try collectAcyclicSpecs(schema, testing.allocator);
    defer freeAcyclicSpecs(testing.allocator, specs);
    try testing.expectEqual(@as(usize, 1), specs.len);
    try testing.expectEqualStrings("phrase-name", specs[0].kind_name);
    try testing.expectEqualStrings("demo/phrase", specs[0].target_form);
    try testing.expectEqualStrings("name", specs[0].name_key);
    try testing.expectEqual(@as(?[]const u8, null), specs[0].scope_form);
    try testing.expectEqual(@as(usize, 1), specs[0].edges.len);
    try testing.expectEqualStrings("parent", specs[0].edges[0].name);
    try testing.expect(specs[0].edges[0].shape == .scalar);
}

test "collectAcyclicSpecs: qualified target_form parses ns/name and canonicalises" {
    // `cr.targets = &.{"demo/phrase"}` exercises the slash-handling branch
    // at the head of collectAcyclicSpecs. The canonical name matches the
    // bare-target case because lookupForm returns the same `(plugin, form)`.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = false },
            .{ .name = "parent", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = true },
        } }},
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"demo/phrase"}, .acyclic = true },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const specs = try collectAcyclicSpecs(schema, testing.allocator);
    defer freeAcyclicSpecs(testing.allocator, specs);
    try testing.expectEqual(@as(usize, 1), specs.len);
    try testing.expectEqualStrings("demo/phrase", specs[0].target_form);
}

test "collectAcyclicSpecs: target unresolved silently dropped" {
    // `validateCrossRefs` would have already reported `unknown_cross_ref_target`
    // for this schema; the spec collector skips it instead of double-reporting.
    const p: Plugin.Plugin = .{
        .name = "p",
        .value_kinds = &.{
            .{
                .name = "ref",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"missing"}, .acyclic = true },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const specs = try collectAcyclicSpecs(schema, testing.allocator);
    defer freeAcyclicSpecs(testing.allocator, specs);
    try testing.expectEqual(@as(usize, 0), specs.len);
}

test "collectAcyclicSpecs: target found but no self-edge keys → spec dropped" {
    // Target form has only the name_key, no self-edges. Spec is dropped
    // here even though `validateCrossRefs` reports `acyclic_without_self_edge`
    // on the same shape.
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .symbol, .optional = false },
        } }},
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"phrase"}, .acyclic = true },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const specs = try collectAcyclicSpecs(schema, testing.allocator);
    defer freeAcyclicSpecs(testing.allocator, specs);
    try testing.expectEqual(@as(usize, 0), specs.len);
}

test "collectAcyclicSpecs: bare scope_form canonicalises to <plugin>/<form>" {
    const p: Plugin.Plugin = .{
        .name = "lexical",
        .forms = &.{
            .{ .name = "track", .keys = &.{
                .{ .name = "id", .value_type = .symbol, .optional = false },
            } },
            .{ .name = "phrase", .keys = &.{
                .{ .name = "name", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = false },
                .{ .name = "parent", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = true },
            } },
        },
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{
                    .targets = &.{"phrase"},
                    .acyclic = true,
                    .scope_form = "track",
                },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const specs = try collectAcyclicSpecs(schema, testing.allocator);
    defer freeAcyclicSpecs(testing.allocator, specs);
    try testing.expectEqual(@as(usize, 1), specs.len);
    try testing.expect(specs[0].scope_form != null);
    try testing.expectEqualStrings("lexical/track", specs[0].scope_form.?);
}

test "collectAcyclicSpecs: qualified scope_form canonicalises identically" {
    const p: Plugin.Plugin = .{
        .name = "lexical",
        .forms = &.{
            .{ .name = "track", .keys = &.{
                .{ .name = "id", .value_type = .symbol, .optional = false },
            } },
            .{ .name = "phrase", .keys = &.{
                .{ .name = "name", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = false },
                .{ .name = "parent", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = true },
            } },
        },
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{
                    .targets = &.{"phrase"},
                    .acyclic = true,
                    .scope_form = "lexical/track",
                },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const specs = try collectAcyclicSpecs(schema, testing.allocator);
    defer freeAcyclicSpecs(testing.allocator, specs);
    try testing.expectEqual(@as(usize, 1), specs.len);
    try testing.expect(specs[0].scope_form != null);
    try testing.expectEqualStrings("lexical/track", specs[0].scope_form.?);
}

test "collectAcyclicSpecs: unresolved scope_form leaves scope_form null on the spec" {
    // `validateCrossRefs` has already reported `unknown_cross_ref_scope`;
    // the spec collector keeps the (anchored) target spec but drops the
    // un-anchorable scope.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = false },
            .{ .name = "parent", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = true },
        } }},
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{
                    .targets = &.{"phrase"},
                    .acyclic = true,
                    .scope_form = "missing",
                },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const specs = try collectAcyclicSpecs(schema, testing.allocator);
    defer freeAcyclicSpecs(testing.allocator, specs);
    try testing.expectEqual(@as(usize, 1), specs.len);
    try testing.expectEqual(@as(?[]const u8, null), specs[0].scope_form);
}

test "collectAcyclicSpecs: name_key is not treated as an outgoing edge" {
    // The cross-ref's `name_key` (`name`) is typed as phrase-name — same
    // as the self-edge keys. Including it would inject a false self-loop
    // on every node and produce spurious cyclic_cross_ref. The collector
    // skips the name_key explicitly.
    const p: Plugin.Plugin = .{
        .name = "demo",
        .forms = &.{.{ .name = "phrase", .keys = &.{
            .{ .name = "name", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = false },
            .{ .name = "parent", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = true },
        } }},
        .value_kinds = &.{
            .{
                .name = "phrase-name",
                .underlying = .symbol,
                .cross_ref = .{ .targets = &.{"phrase"}, .acyclic = true },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const specs = try collectAcyclicSpecs(schema, testing.allocator);
    defer freeAcyclicSpecs(testing.allocator, specs);
    try testing.expectEqual(@as(usize, 1), specs.len);
    for (specs[0].edges) |edge| {
        try testing.expect(!std.mem.eql(u8, edge.name, "name"));
    }
}

// ---------------------------------------------------------------------------
// validateLowering — schema-aggregate phase tests.
// ---------------------------------------------------------------------------

test "validateLowering: every produces head resolves cleanly" {
    const p: Plugin.Plugin = .{
        .name = "pngine",
        .forms = &.{
            .{
                .name = "pass",
                .lowering = .{ .hook = "pngine/pass-v1", .produces = &.{ "shader", "pipeline" } },
            },
            .{ .name = "shader" },
            .{ .name = "pipeline" },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateLowering: unknown produces head emits unknown_form" {
    const p: Plugin.Plugin = .{
        .name = "pngine",
        .forms = &.{
            .{
                .name = "pass",
                .lowering = .{ .hook = "pngine/pass-v1", .produces = &.{"missing"} },
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.unknown_form, diags[0].code);
    try testing.expectEqual(@as(usize, 3), diags[0].path.len);
    try testing.expectEqualStrings("pngine", diags[0].path[0]);
    try testing.expectEqualStrings("pass", diags[0].path[1]);
    try testing.expectEqualStrings("lowering", diags[0].path[2]);
}

test "validateLowering: ambiguous bare produces head emits ambiguous_form" {
    // Two plugins both declare a `shader` form; a third declares lowering
    // that produces bare `shader` — that's ambiguous.
    const a_plug: Plugin.Plugin = .{ .name = "a", .forms = &.{.{ .name = "shader" }} };
    const b_plug: Plugin.Plugin = .{ .name = "b", .forms = &.{.{ .name = "shader" }} };
    const pngine: Plugin.Plugin = .{
        .name = "pngine",
        .forms = &.{
            .{
                .name = "pass",
                .lowering = .{ .hook = "pngine/pass-v1", .produces = &.{"shader"} },
            },
        },
    };
    const schema = Schema.init(&.{ a_plug, b_plug, pngine });
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.ambiguous_form, diags[0].code);
    try testing.expectEqualStrings(
        "form `pass` `:lowering` produces head `shader` is ambiguous — defined by [a, b]; qualify with `<ns>/shader`",
        diags[0].message,
    );
}

test "validateLowering: qualified produces head resolves to one specific plugin" {
    const a_plug: Plugin.Plugin = .{ .name = "a", .forms = &.{.{ .name = "shader" }} };
    const b_plug: Plugin.Plugin = .{ .name = "b", .forms = &.{.{ .name = "shader" }} };
    const pngine: Plugin.Plugin = .{
        .name = "pngine",
        .forms = &.{
            .{
                .name = "pass",
                .lowering = .{ .hook = "pngine/pass-v1", .produces = &.{"a/shader"} },
            },
        },
    };
    const schema = Schema.init(&.{ a_plug, b_plug, pngine });
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateLowering: qualified produces head into an absent plugin emits lowering_target_plugin_absent" {
    // `pngine/pass` produces `storage/table-row`, but no `storage` plugin
    // is loaded — the edge dangles on load order, not on a typo, so it gets
    // the distinct code rather than the generic `unknown_form`.
    const pngine: Plugin.Plugin = .{
        .name = "pngine",
        .forms = &.{
            .{
                .name = "pass",
                .lowering = .{ .hook = "pngine/pass-v1", .produces = &.{"storage/table-row"} },
            },
        },
    };
    const schema = Schema.init(&.{pngine});
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.lowering_target_plugin_absent, diags[0].code);
    try testing.expectEqual(@as(usize, 3), diags[0].path.len);
    try testing.expectEqualStrings("pngine", diags[0].path[0]);
    try testing.expectEqualStrings("pass", diags[0].path[1]);
    try testing.expectEqualStrings("lowering", diags[0].path[2]);
}

test "validateLowering: qualified head into a present plugin missing the form stays unknown_form" {
    // `storage` IS loaded but has no `table-row` form — that's a typo-class
    // miss, not a missing-plugin one, so the code stays `unknown_form`.
    const storage: Plugin.Plugin = .{ .name = "storage", .forms = &.{.{ .name = "blob" }} };
    const pngine: Plugin.Plugin = .{
        .name = "pngine",
        .forms = &.{
            .{
                .name = "pass",
                .lowering = .{ .hook = "pngine/pass-v1", .produces = &.{"storage/table-row"} },
            },
        },
    };
    const schema = Schema.init(&.{ storage, pngine });
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.unknown_form, diags[0].code);
}

// --- `:produces` naming a slot-local head (S12) ------------------------------
//
// A hook that emits `(bind-group (entry …))`, where `entry` is slot-local to
// `bind-group`, must list `entry` (the contract checks every depth) and the
// list must resolve. A bare `:produces` head therefore resolves local-first:
// it names a slot-local form reachable through a form the same list resolves,
// or a global form as before. Qualified heads bypass locals, as at the site.

test "validateLowering: produces head resolves to a positional slot-local of a listed form" {
    const p: Plugin.Plugin = .{
        .name = "pngine",
        .forms = &.{
            .{
                .name = "init",
                .lowering = .{ .hook = "pngine/init-v1", .produces = &.{ "bind-group", "entry" } },
            },
            .{
                .name = "bind-group",
                .local_forms = &.{.{ .name = "entry", .keys = &.{.{ .name = "binding", .value_type = .number }} }},
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateLowering: produces head resolves to a keyed slot-local (KeySpec.local_forms) of a listed form" {
    const p: Plugin.Plugin = .{
        .name = "pngine",
        .forms = &.{
            .{
                .name = "init",
                .lowering = .{ .hook = "pngine/init-v1", .produces = &.{ "pipeline", "layout" } },
            },
            .{
                .name = "pipeline",
                .keys = &.{.{ .name = "layout", .value_type = .form, .local_forms = &.{.{ .name = "layout" }} }},
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateLowering: produces head resolves to a slot-local of a variant key of a listed form" {
    const p: Plugin.Plugin = .{
        .name = "pngine",
        .forms = &.{
            .{
                .name = "init",
                .lowering = .{ .hook = "pngine/init-v1", .produces = &.{ "target", "view" } },
            },
            .{
                .name = "target",
                .keys = &.{.{ .name = "kind", .value_type = .symbol }},
                .discriminant_name = "kind",
                .discriminant_idx = 0,
                .variants = &.{.{
                    .when = &.{"texture"},
                    .keys = &.{.{ .name = "view", .value_type = .form, .local_forms = &.{.{ .name = "view" }} }},
                }},
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateLowering: produces head resolves to a local of a local (two deep) of a listed form" {
    // `bind-group` → local `entry` → local `range`: only the root is global,
    // and the list names all three. Reachability is transitive through both
    // carriers, so `range` resolves through `entry` through `bind-group`.
    const p: Plugin.Plugin = .{
        .name = "pngine",
        .forms = &.{
            .{
                .name = "init",
                .lowering = .{ .hook = "pngine/init-v1", .produces = &.{ "bind-group", "entry", "range" } },
            },
            .{
                .name = "bind-group",
                .local_forms = &.{.{
                    .name = "entry",
                    .keys = &.{.{ .name = "span", .value_type = .form, .local_forms = &.{.{ .name = "range" }} }},
                }},
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateLowering: slot-local produces head reaches through a qualified root" {
    // The root is listed qualified (`gpu/bind-group`); its local `entry` is
    // listed bare, the only spelling an emitted local can have.
    const gpu: Plugin.Plugin = .{
        .name = "gpu",
        .forms = &.{.{ .name = "bind-group", .local_forms = &.{.{ .name = "entry" }} }},
    };
    const pngine: Plugin.Plugin = .{
        .name = "pngine",
        .forms = &.{
            .{
                .name = "init",
                .lowering = .{ .hook = "pngine/init-v1", .produces = &.{ "gpu/bind-group", "entry" } },
            },
        },
    };
    const schema = Schema.init(&.{ gpu, pngine });
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateLowering: slot-local produces head whose declaring form is unlisted is unknown_form naming that form" {
    // `entry` is declared inside `bind-group`, but the list names only
    // `entry`. A hook can place a local only under its declaring form, and
    // the all-depths contract would then require `bind-group` in the list —
    // so this manifest cannot be right, and the message says what is missing.
    const p: Plugin.Plugin = .{
        .name = "pngine",
        .forms = &.{
            .{
                .name = "init",
                .lowering = .{ .hook = "pngine/init-v1", .produces = &.{"entry"} },
            },
            .{ .name = "bind-group", .local_forms = &.{.{ .name = "entry" }} },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.unknown_form, diags[0].code);
    try testing.expectEqualStrings(
        "form `init` `:lowering` produces head `entry` does not resolve to any declared form; `entry` is slot-local to `bind-group` and resolves only through a `:produces` entry naming that form",
        diags[0].message,
    );
    try testing.expectEqualStrings("lowering", diags[0].path[2]);
}

test "validateLowering: the unlisted-declaring-form hint lists every declaring form, catalog order" {
    const p: Plugin.Plugin = .{
        .name = "pngine",
        .forms = &.{
            .{
                .name = "init",
                .lowering = .{ .hook = "pngine/init-v1", .produces = &.{"entry"} },
            },
            .{ .name = "bind-group", .local_forms = &.{.{ .name = "entry" }} },
            .{ .name = "layout", .keys = &.{.{ .name = "slot", .value_type = .form, .local_forms = &.{.{ .name = "entry" }} }} },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expect(std.mem.indexOf(u8, diags[0].message, "slot-local to `bind-group`, `layout`") != null);
}

test "validateLowering: a head that is nobody's local keeps the plain unknown_form message" {
    const p: Plugin.Plugin = .{
        .name = "pngine",
        .forms = &.{
            .{
                .name = "init",
                .lowering = .{ .hook = "pngine/init-v1", .produces = &.{ "bind-group", "ghost" } },
            },
            .{ .name = "bind-group", .local_forms = &.{.{ .name = "entry" }} },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings(
        "form `init` `:lowering` produces head `ghost` does not resolve to any declared form",
        diags[0].message,
    );
}

test "validateLowering: a qualified produces head never resolves through locals" {
    // `pngine/entry` targets plugin `pngine`'s global catalog only — the
    // same bypass a qualified head takes at the site. The local `entry`
    // under the listed `bind-group` does not rescue it; and because the
    // spelling is qualified, no declaring-form hint is offered either.
    const p: Plugin.Plugin = .{
        .name = "pngine",
        .forms = &.{
            .{
                .name = "init",
                .lowering = .{ .hook = "pngine/init-v1", .produces = &.{ "bind-group", "pngine/entry" } },
            },
            .{ .name = "bind-group", .local_forms = &.{.{ .name = "entry" }} },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.unknown_form, diags[0].code);
    try testing.expectEqualStrings(
        "form `init` `:lowering` produces head `pngine/entry` does not resolve to any declared form",
        diags[0].message,
    );
}

test "validateLowering: a reachable slot-local shadows an ambiguous global of the same name" {
    // Local-first, as at the site: `entry` is a global in two plugins
    // (ambiguous bare) AND a local of the listed `bind-group`. The hook's
    // emitted `entry` sits under `bind-group` and resolves to the local, so
    // the list resolves clean — the "qualify with `<ns>/entry`" hint the
    // ambiguity would offer is unfollowable here (an emitted bare `entry`
    // never equals a listed `a/entry`).
    const a_plug: Plugin.Plugin = .{ .name = "a", .forms = &.{.{ .name = "entry" }} };
    const b_plug: Plugin.Plugin = .{ .name = "b", .forms = &.{.{ .name = "entry" }} };
    const pngine: Plugin.Plugin = .{
        .name = "pngine",
        .forms = &.{
            .{
                .name = "init",
                .lowering = .{ .hook = "pngine/init-v1", .produces = &.{ "bind-group", "entry" } },
            },
            .{ .name = "bind-group", .local_forms = &.{.{ .name = "entry" }} },
        },
    };
    const schema = Schema.init(&.{ a_plug, b_plug, pngine });
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateLowering: a local under an ambiguous root is not reachable until the root resolves" {
    // `bind-group` is a global in two plugins; both carry a local `entry`.
    // The ambiguous root contributes no locals, so the list reports the
    // ambiguity (as before) AND `entry` as unresolved — with the hint naming
    // `bind-group`, which the author fixes by qualifying the root.
    const a_plug: Plugin.Plugin = .{ .name = "a", .forms = &.{.{ .name = "bind-group", .local_forms = &.{.{ .name = "entry" }} }} };
    const b_plug: Plugin.Plugin = .{ .name = "b", .forms = &.{.{ .name = "bind-group", .local_forms = &.{.{ .name = "entry" }} }} };
    const pngine: Plugin.Plugin = .{
        .name = "pngine",
        .forms = &.{
            .{
                .name = "init",
                .lowering = .{ .hook = "pngine/init-v1", .produces = &.{ "bind-group", "entry" } },
            },
        },
    };
    const schema = Schema.init(&.{ a_plug, b_plug, pngine });
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 2), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.ambiguous_form, diags[0].code);
    try testing.expectEqual(Ast.Diagnostic.Code.unknown_form, diags[1].code);
    try testing.expect(std.mem.indexOf(u8, diags[1].message, "slot-local to `bind-group` and resolves") != null);
}

test "buildLoweringGraph: a slot-local produces head adds no edge" {
    // Locals never lower (loader-rejected, `Schema.init`-asserted), so the
    // graph the cycle check and the export consume keeps only the global
    // edge: `init → pngine/bind-group`, nothing for `entry`.
    const p: Plugin.Plugin = .{
        .name = "pngine",
        .forms = &.{
            .{
                .name = "init",
                .lowering = .{ .hook = "pngine/init-v1", .produces = &.{ "bind-group", "entry" } },
            },
            .{ .name = "bind-group", .local_forms = &.{.{ .name = "entry" }} },
        },
    };
    const schema = Schema.init(&.{p});
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nodes = try buildLoweringGraph(schema, arena.allocator());
    try testing.expectEqual(@as(usize, 1), nodes.len);
    try testing.expectEqual(@as(usize, 1), nodes[0].edges.len);
    try testing.expectEqualStrings("pngine/bind-group", nodes[0].edges[0]);
}

test "validateLowering: no-op when no forms declare :lowering" {
    const p: Plugin.Plugin = .{
        .name = "plain",
        .forms = &.{ .{ .name = "scene" }, .{ .name = "shape" } },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateLowering: cyclic produces graph emits lowering_cycle" {
    // `a` lowers to `b`, `b` lowers back to `a` — a 2-cycle in the
    // produces graph. The aggregate check rejects it statically, anchored
    // at the cycle's entry form (`a`, the first lowering form walked).
    const p: Plugin.Plugin = .{
        .name = "cyc",
        .forms = &.{
            .{ .name = "a", .lowering = .{ .hook = "cyc/a-v1", .produces = &.{"b"} } },
            .{ .name = "b", .lowering = .{ .hook = "cyc/b-v1", .produces = &.{"a"} } },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.lowering_cycle, diags[0].code);
    try testing.expectEqual(@as(usize, 3), diags[0].path.len);
    try testing.expectEqualStrings("cyc", diags[0].path[0]);
    try testing.expectEqualStrings("a", diags[0].path[1]);
    try testing.expectEqualStrings("lowering", diags[0].path[2]);
}

test "validateLowering: self-producing form emits lowering_cycle" {
    // A form that produces itself is a 1-cycle (self-loop).
    const p: Plugin.Plugin = .{
        .name = "cyc",
        .forms = &.{
            .{ .name = "a", .lowering = .{ .hook = "cyc/a-v1", .produces = &.{"a"} } },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.lowering_cycle, diags[0].code);
}

test "validateLowering: cross-plugin cycle emits lowering_cycle" {
    // The cycle spans two plugins: `up/task` produces `down/row`, which
    // produces back into `up/task`. Cross-plugin edges are ordinary
    // aggregate edges — same `lookupForm` resolution, same DFS — so the
    // cycle is caught and anchored at the first lowering form walked
    // (`up/task`, since `up` is declared first).
    const up: Plugin.Plugin = .{
        .name = "up",
        .forms = &.{
            .{ .name = "task", .lowering = .{ .hook = "up/task-v1", .produces = &.{"down/row"} } },
        },
    };
    const down: Plugin.Plugin = .{
        .name = "down",
        .forms = &.{
            .{ .name = "row", .lowering = .{ .hook = "down/row-v1", .produces = &.{"up/task"} } },
        },
    };
    const schema = Schema.init(&.{ up, down });
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.lowering_cycle, diags[0].code);
    try testing.expectEqualStrings("up", diags[0].path[0]);
    try testing.expectEqualStrings("task", diags[0].path[1]);
    try testing.expectEqualStrings("lowering", diags[0].path[2]);
}

test "validateLowering: acyclic staged chain does not emit lowering_cycle" {
    // `a` -> `b` -> `c`, where `c` is terminal (no `:lowering`). A
    // legitimate multi-stage chain must NOT false-positive as a cycle.
    const p: Plugin.Plugin = .{
        .name = "stage",
        .forms = &.{
            .{ .name = "a", .lowering = .{ .hook = "stage/a-v1", .produces = &.{"b"} } },
            .{ .name = "b", .lowering = .{ .hook = "stage/b-v1", .produces = &.{"c"} } },
            .{ .name = "c" },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateLowering(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "buildLoweringGraph: one node per lowering form, edges canonicalized, unresolved dropped" {
    // `a/x` produces a bare `y` (resolves cross-plugin to `b/y`), a
    // qualified `b/y` (same target), and a dangling `b/missing` (dropped:
    // the builder keeps only resolvable edges, just like the cycle check).
    // `b/y` is terminal, so the graph the export and cycle check both
    // consume has exactly one node, with edges canonicalized to
    // `<plugin>/<form>` and no implicit dedup of the two `b/y` edges.
    const a_plug: Plugin.Plugin = .{
        .name = "a",
        .forms = &.{
            .{ .name = "x", .lowering = .{ .hook = "a/x-v1", .produces = &.{ "y", "b/y", "b/missing" } } },
        },
    };
    const b_plug: Plugin.Plugin = .{ .name = "b", .forms = &.{.{ .name = "y" }} };
    const schema = Schema.init(&.{ a_plug, b_plug });

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nodes = try buildLoweringGraph(schema, arena.allocator());

    try testing.expectEqual(@as(usize, 1), nodes.len);
    try testing.expectEqualStrings("a/x", nodes[0].name);
    try testing.expectEqualStrings("a", nodes[0].plugin_name);
    try testing.expectEqualStrings("x", nodes[0].form_name);
    try testing.expectEqual(@as(usize, 2), nodes[0].edges.len);
    try testing.expectEqualStrings("b/y", nodes[0].edges[0]);
    try testing.expectEqualStrings("b/y", nodes[0].edges[1]);
}

// ---------------------------------------------------------------------------
// validateDefaults — schema-aggregate phase tests for expression-shaped
// defaults. Re-uses `Validator.resolveFormExpressionBinary` and
// `Validator.declaredResultMatchesExpected`.
// ---------------------------------------------------------------------------

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

test "validateDefaults: mono expression result matches → clean" {
    const p: Plugin.Plugin = .{
        .name = "p",
        .expr_funcs = &.{expr_pi},
        .forms = &.{.{
            .name = "scene",
            .keys = &.{.{
                .name = "r",
                .value_type = .number,
                .default = .{ .expression = .{ .head = "pi", .namespace = null, .arg_count = 0, .program = &.{} } },
            }},
        }},
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateDefaults(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateDefaults: mono expression result mismatch → wrong_underlying" {
    const p: Plugin.Plugin = .{
        .name = "p",
        .expr_funcs = &.{expr_pi_string},
        .forms = &.{.{
            .name = "scene",
            .keys = &.{.{
                .name = "r",
                .value_type = .number,
                .default = .{ .expression = .{ .head = "pi-str", .namespace = null, .arg_count = 0, .program = &.{} } },
            }},
        }},
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateDefaults(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.wrong_underlying, diags[0].code);
    try testing.expectEqual(@as(usize, 4), diags[0].path.len);
    try testing.expectEqualStrings("p", diags[0].path[0]);
    try testing.expectEqualStrings("scene", diags[0].path[1]);
    try testing.expectEqualStrings("r", diags[0].path[2]);
    try testing.expectEqualStrings("default", diags[0].path[3]);
}

test "validateDefaults: opaque-result expression defers (no diagnostic)" {
    const p: Plugin.Plugin = .{
        .name = "p",
        .expr_funcs = &.{expr_opaque},
        .forms = &.{.{
            .name = "scene",
            .keys = &.{.{
                .name = "r",
                .value_type = .number,
                .default = .{ .expression = .{ .head = "let", .namespace = null, .arg_count = 2, .program = &.{} } },
            }},
        }},
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateDefaults(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateDefaults: unknown head defers silently" {
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{
            .name = "scene",
            .keys = &.{.{
                .name = "r",
                .value_type = .number,
                .default = .{ .expression = .{ .head = "nope", .namespace = null, .arg_count = 0, .program = &.{} } },
            }},
        }},
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateDefaults(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "validateDefaults: data-form default rejected" {
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{
            .{ .name = "circle", .keys = &.{.{ .name = "r", .value_type = .number }} },
            .{
                .name = "scene",
                .keys = &.{.{
                    .name = "shape",
                    .value_type = .any,
                    .default = .{ .expression = .{ .head = "circle", .namespace = null, .arg_count = 0, .program = &.{} } },
                }},
            },
        },
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateDefaults(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.wrong_underlying, diags[0].code);
    try testing.expectEqualStrings("default", diags[0].path[3]);
}

test "validateDefaults: no expression defaults → 0 diagnostics" {
    const p: Plugin.Plugin = .{
        .name = "p",
        .forms = &.{.{
            .name = "scene",
            .keys = &.{.{
                .name = "title",
                .value_type = .string,
                .default = .{ .string = "Untitled" },
            }},
        }},
    };
    const schema = Schema.init(&.{p});
    const diags = try schema.validateDefaults(testing.allocator);
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}
