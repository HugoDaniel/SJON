//! Host-owned form-lowering runtime.
//!
//! Manifests can declare `:lowering` on a `FormSpec` to mark the form as
//! surface sugar that a host-owned contract turns into one or more normal
//! forms before final validation. `Schema.validateLowering` checks that
//! `:produces` resolves; this module is the runtime that actually invokes
//! the contract and routes the emitted forms through validation.
//!
//! Pieces:
//!   * `LoweringRegistry` — id → hook map plumbed through `Host.Options`.
//!   * `LoweringInput` — read-side view over the source form (via
//!     `EffectiveView`) plus the schema and the form/lowering specs.
//!   * `LayerRefs` — one staging layer's cross-reference index, built at
//!     most once and only when a hook asks (`LoweringInput.resolveRef`).
//!   * `LoweringOutput` — append-only emitted-form sink, bounded by
//!     `Plugin.MAX_LOWERED_*` constants.
//!   * `runLoweringPass` — one staging *layer*: a worklist walk (no host-
//!     stack recursion) that runs each lowerable form's hook and validates
//!     its output against the contract.
//!   * `buildLoweredTree` — turns a layer's invocations into an `Ast.Tree`
//!     whose nodes inherit the source span (so diagnostics point home).
//!
//! Staging: the host drives `runLoweringPass` once per layer — the
//! emitted forms of one layer become the next layer's forest — up to
//! `MAX_LOWERING_STAGES`, bounded further by the cumulative
//! `MAX_LOWERING_STEPS` emitted-form budget. An emitted form that is
//! itself lowerable is normal; it lowers in the next layer. Termination
//! is guaranteed statically by the produces-graph cycle check
//! (`Schema.validateLowering` → `lowering_cycle`); the runtime caps are
//! backstops.
//!
//! Lifetime: hooks receive a caller-owned `arena` allocator. Strings,
//! vectors, positional children, and nested `EmittedForm`s emitted by
//! the hook must be allocated from that arena. The arena outlives the
//! lowering pass, which itself outlives downstream consumers via
//! `HostResult.arena`.
//!
//! What a hook may read: its own form, always, and the form a
//! cross-reference key on that form names, through `resolveRef`. The
//! second is bounded by the layer: resolution searches this pass's input
//! forest, so a name a later layer will emit answers null and the
//! whole-document forest pass resolves it there. Everything the resolution
//! knows (lexical scope, a shared multi-target bucket, provider-backed
//! names, slot-local `:name`s) comes from the validator's own index, which
//! is why a hand-rolled scan over `input.view.tree.root` is not a supported
//! substitute: it answers the flat single-target case correctly and the
//! other four silently wrong. `docs/plugin-model-v1.md`, "Reading a form
//! the hook does not own", is the long version.
//!
//! Naming: hook ids by convention follow `<vendor>/<surface>-v<n>`
//! (e.g. `pngine/pass-v1`). The v1 substrate does not parse the id —
//! it is an opaque key into the registry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Ast = @import("Ast.zig");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const EffectiveViewMod = @import("EffectiveView.zig");
const EffectiveView = EffectiveViewMod.EffectiveView;
const MaterializedDefaults = @import("MaterializedDefaults.zig");
const Validator = @import("Validator.zig");
const Parser = @import("Parser.zig");
const Expr = @import("Expr.zig");

/// Hook failure surface. `HookFailed` is the catch-all signal from a
/// hook that decided not to produce a result (input was unusable, an
/// internal invariant broke, etc.); the pass driver converts it into a
/// `lowering_hook_failed` diagnostic without inspecting the cause.
/// `OutOfMemory` propagates from the hook's arena allocator.
pub const LoweringError = error{
    HookFailed,
    OutOfMemory,
};

/// Hook signature. The hook receives an arena allocator scoped to the
/// invocation, a read-only input view, and a write-only output sink.
/// Hooks return `void`; outputs flow through `out`. The contract id is
/// the registry key, not parameterized through the call.
pub const HookFn = *const fn (
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
) LoweringError!void;

/// One registered hook. `id` matches `LoweringSpec.hook`; the registry
/// indexes by this id.
pub const LoweringHook = struct {
    id: []const u8,
    lower: HookFn,
    /// Host state the hook reads back through `LoweringInput.ctx`. The
    /// same shape as `Resolver.ctx` and `ProviderExtraction.Invoker.ctx`:
    /// opaque on purpose, the pass copies the pointer and never reads
    /// through it. A stateless hook leaves it null.
    ///
    /// Borrowed, so it must outlive every pass the registry is handed to
    /// (for a host, the `validateDocument` call). A registry built per
    /// call over stack-allocated state is the intended shape: it keeps a
    /// hook's state off a module-level global, where a second concurrent
    /// pass would share it.
    ctx: ?*anyopaque = null,
};

/// Errors surfaced by `LoweringRegistry.register`. `DuplicateHook`
/// signals that two hooks share an id — by convention hosts catch this
/// at startup so a typo doesn't silently mask a hook.
pub const RegisterError = error{
    DuplicateHook,
    OutOfMemory,
};

/// The module's conventional aggregate error — the union of its hook-invocation
/// (`LoweringError`) and registry (`RegisterError`) surfaces.
pub const Error = LoweringError || RegisterError;

/// Host-owned id → hook map. Borrowed by `Host.Options.lowering_registry`;
/// `null` there means "no lowering pass runs at all" — the byte-for-byte
/// no-op default that keeps existing conformance fixtures unaffected.
///
/// Memory: the registry stores each `LoweringHook` as given and copies
/// none of `id`, `lower`, or `ctx`. Hosts construct hooks with
/// string-literal ids (or arena-owned ids whose lifetime exceeds the
/// registry's) and a `ctx` that outlives every pass.
pub const LoweringRegistry = struct {
    hooks: std.StringHashMapUnmanaged(LoweringHook) = .empty,

    pub fn register(
        self: *LoweringRegistry,
        gpa: Allocator,
        hook: LoweringHook,
    ) RegisterError!void {
        const gop = try self.hooks.getOrPut(gpa, hook.id);
        if (gop.found_existing) return RegisterError.DuplicateHook;
        gop.value_ptr.* = hook;
    }

    /// Look up by contract id. Returned pointer aliases the map's
    /// internal storage; valid until the next `register` or `deinit`.
    pub fn lookup(self: *const LoweringRegistry, id: []const u8) ?*const LoweringHook {
        return self.hooks.getPtr(id);
    }

    pub fn deinit(self: *LoweringRegistry, gpa: Allocator) void {
        self.hooks.deinit(gpa);
    }
};

/// One staging layer's cross-reference index, built at most once and only
/// when a hook asks for it.
///
/// `runLoweringPassBudgeted` constructs one per layer and hands every
/// `LoweringInput` the same pointer, so the hooks in a layer share one
/// index and a document's build count is bounded by its layer count.
///
/// Nothing is built until the first ask. The build is a full forest DFS,
/// and every lowering host that exists today resolves nothing, so a pass
/// whose hooks never ask must cost nothing — a claim that is invisible
/// from outside and therefore gets a seam: `builds` counts the builds and
/// surfaces on `PassResult.ref_index_builds`, where a test can read it.
///
/// **Bound.** The index covers this layer's *input* forest and nothing
/// else. At layer 0 that is the author's data forest; at layer N > 0 it is
/// the forms layer N-1 emitted. A name that a later layer will define is
/// not in here, and that is not an error — the final-document forest pass
/// owns cross-reference reporting and resolves it there.
pub const LayerRefs = struct {
    /// The layer's input forest as a tree view: the same nodes, rooted at
    /// the roots this pass was given. Deliberately not the whole
    /// `tree.root` — a layer resolves against what it was asked to lower,
    /// which at layer 0 excludes the manifest partition.
    forest: Ast.Tree,
    schema: Schema.Schema,
    /// Overlay + axes, so a defaulted `:name` indexes exactly as it does
    /// in the document pass (axis A).
    options: Validator.Options,
    built: ?Validator.LookupIndex = null,
    builds: usize = 0,

    /// The layer's index, building it on the first call. `arena` is the
    /// pass arena, which outlives the layer; the caller is
    /// `LoweringInput.layerIndex`, which passes the same `arena` every
    /// hook already receives.
    ///
    /// The build's transient state lands on the pass arena too, not on a
    /// GPA freed at the build's end: `buildCrossRefIndexForLookup`
    /// allocates a throw-away `Result` arena and diagnostic list per tree
    /// on its second allocator, and those bytes are now held until the
    /// pass ends. Bounded, because a layer builds at most once
    /// (`PassResult.ref_index_builds` pins it) and a document has at most
    /// `MAX_LOWERING_STAGES` layers. The alternative — threading a GPA
    /// down to here — has nowhere to come from: a hook receives only
    /// `arena`, so the GPA would have to be stored on `LoweringInput`
    /// instead, which moves the stored allocator rather than removing it.
    fn ensure(self: *LayerRefs, arena: Allocator) Allocator.Error!*const Validator.LookupIndex {
        if (self.built == null) {
            self.built = try Validator.buildCrossRefIndexForLookup(
                arena,
                arena,
                self.schema,
                (&self.forest)[0..1],
                self.options,
            );
            self.builds += 1;
        }
        return &self.built.?;
    }
};

/// Read-side view passed to a hook. The hook reads author + default
/// values via `view.getEffectiveValue(form_idx, "key")` and consults
/// `schema` / `form_spec` for type metadata.
///
/// `form_idx` is the source form being lowered. `source_span` covers
/// the same form's source bytes; downstream consumers use it to
/// trace lowered output back to the author position.
///
/// `arena` mirrors the allocator passed to the hook's `HookFn` — it is
/// stored on the input so the typed-read helpers (`symbol`, `string`,
/// `number`, `numberEval`, `boolean`) can dup their results without
/// forcing each call site to thread the allocator through explicitly.
pub const LoweringInput = struct {
    arena: Allocator,
    form_idx: Ast.NodeIndex,
    head: []const u8,
    source_span: Ast.Span,
    view: EffectiveView,
    schema: *const Schema.Schema,
    form_spec: *const Plugin.FormSpec,
    lowering_spec: *const Plugin.LoweringSpec,
    /// The registered hook's own `LoweringHook.ctx`, verbatim: null when
    /// the host set none. A hook unwraps it the way every opaque context
    /// here is unwrapped, `@ptrCast(@alignCast(input.ctx.?))`. No default,
    /// so a second constructor cannot forget to hand it over.
    ctx: ?*anyopaque,
    /// Host-supplied evaluation environment. `numberEval` resolves any
    /// free variable in an author expression against it (e.g. a
    /// `workgroup-size` constant the embedder injects). Defaults empty for
    /// every caller that doesn't opt in (`runLoweringPass`), so an
    /// expression with a free variable then fails the hook rather than
    /// resolving — the env is the only thing that makes it load-bearing.
    env: *const Expr.Env,
    /// This layer's shared, lazily built reference index. Held as a
    /// mutable pointer through a `*const LoweringInput` on purpose: the
    /// build is a side effect of asking, and the hook that asks first
    /// pays for the hooks that ask after it.
    refs: *LayerRefs,

    /// This layer's cross-reference index, built on demand.
    ///
    /// Private: a hook resolves through `resolveRef`, which cannot look in
    /// the wrong bucket. Handing out the raw index would hand out the four
    /// rules that reader exists to apply.
    fn layerIndex(self: *const LoweringInput) Allocator.Error!*const Validator.LookupIndex {
        return self.refs.ensure(self.arena);
    }

    /// Resolve a cross-reference key on THIS form to the form it names, and
    /// return that form's node index — the same index
    /// `view.getEffectiveValue` takes, so a hook reads its neighbour
    /// exactly as it reads itself:
    ///
    /// ```zig
    /// const producer = (try input.resolveRef("from")) orelse
    ///     return out.fail(arena, "`:from` names nothing", .{});
    /// const count = input.view.getEffectiveValue(producer, "count");
    /// ```
    ///
    /// Scoped like the five readers above: `key` is a key on
    /// `self.form_idx`, not a free name. The key's declared value kind
    /// supplies the cross-ref target set, so a hook cannot look in the
    /// wrong bucket, and a multi-target `(cross-ref :target [a b])` works
    /// without the hook knowing there is more than one. The four rules a
    /// hand-rolled scan over `self.view.tree.root` gets wrong — scope, the
    /// shared multi-target bucket, provider-backed names that are not in
    /// the tree at all, and slot-local `:name`s that are scoped to their
    /// slot — are the validator's here, because this is the validator's
    /// index.
    ///
    /// **Bound.** Resolution searches this staging layer's input forest and
    /// nothing else. At layer 0 that is the author's whole data forest,
    /// which is what a flat sibling vocabulary needs. At layer N > 0 it is
    /// the forms layer N-1 emitted. A name that a *later* layer will define
    /// returns null here, and that is not an error — the final-document
    /// forest pass owns cross-reference reporting and will resolve it
    /// there. A hook that wants to fail on a miss has `out.fail` /
    /// `out.failAt`; the lowering pass must not decide that an unresolved
    /// name is wrong, because it does not have the document.
    ///
    /// Returns null when the key is absent, when its value is not
    /// symbol-shaped, or when the name resolves nowhere in this layer. The
    /// middle one is why this does not go through `symbol`: a
    /// `(union-shape …)` slot spelled "a number or a name" legitimately
    /// holds a number, and a hook must not have to pre-check the tag
    /// before it may ask. `error.HookFailed` is reserved for the one thing
    /// no document decides — the key's *declared* type carries no
    /// cross-reference at all, including a key an `:open` form accepted
    /// that nothing declares. That is the same class of hook bug as
    /// calling `symbol` on a number key.
    ///
    /// Cost: the first call in a layer builds the index (a forest DFS);
    /// every later call in that layer is two hash lookups. A key that is
    /// absent, or typed without a cross-ref, is answered from the schema
    /// and builds nothing.
    pub fn resolveRef(self: *const LoweringInput, key: []const u8) LoweringError!?Ast.NodeIndex {
        // Declared shape first, and from the spec rather than the value:
        // this is the half that decides *which* bucket, and getting it
        // from what the author happened to write is the guess the reader
        // exists to remove.
        const cr = self.crossRefOfKey(key) orelse return error.HookFailed;

        // Then the name. An absent key is a miss, not a failure — a hook
        // may resolve an optional reference — and so is a value that is
        // not symbol-shaped.
        const name = self.refNameOf(key) orelse return null;

        const refs = try self.layerIndex();

        // The bucket a multi-target cross-ref shares, or the sole target's
        // canonical `<plugin>/<form>`. Null when a target does not resolve;
        // the schema-aggregate phase already reported that, so this is a
        // miss rather than a second complaint.
        const bucket = (try self.schema.crossRefBucketKey(self.arena, cr)) orelse return null;
        defer self.arena.free(bucket);

        const scope: Validator.ScopeId = if (cr.scope_form) |sf| sub: {
            const scope_canonical = (try self.schema.canonicalFormName(self.arena, sf)) orelse return null;
            defer self.arena.free(scope_canonical);
            // The chain the index recorded for this form while walking to
            // it. A reference outside its scope resolves nowhere, which is
            // what the validator says about it too.
            const chain = refs.scopeChainAt(0, self.form_idx);
            break :sub Validator.findNearestScope(chain, scope_canonical) orelse return null;
        } else .tree(0);

        const site = refs.index.lookup(scope, bucket, name) orelse return null;
        // `Site.node_idx` is the *form* index at registration, not the
        // `:name` value, so this needs no second lookup to be usable.
        return site.node_idx;
    }

    /// The symbol text in `key`'s slot, or null when the key is absent or
    /// its value is not symbol-shaped. Borrowed from the tree or the
    /// overlay — it is only ever a lookup key, so nothing is duped.
    ///
    /// The author arm accepts `symbol` and `keyword` for the reason
    /// `symbol` does (`Expr.Value` has no `.symbol`, so symbol defaults
    /// land as keywords); the default arm accepts `keyword` and `string`,
    /// which is the pair axis B indexes a defaulted `:name` from.
    fn refNameOf(self: *const LoweringInput, key: []const u8) ?[]const u8 {
        const ev = self.view.getEffectiveValue(self.form_idx, key) orelse return null;
        return switch (ev) {
            .author => |idx| switch (self.view.tree.tagOf(idx)) {
                .symbol => self.view.tree.symbolText(idx),
                .keyword => self.view.tree.keywordText(idx),
                else => null,
            },
            .default => |entry| switch (entry.value) {
                .keyword => |k| k,
                .string => |str| str,
                else => null,
            },
        };
    }

    /// The cross-reference declared by `key`'s type, or null when the key
    /// is undeclared or its type carries none.
    ///
    /// One union hop, and only one: a `(union-shape …)` alternative may be
    /// the cross-ref kind — which is what `(scalar-or-ref-shape :ref …)`
    /// desugars to — so a slot spelled "a number or a name" resolves the
    /// name. Two alternatives carrying cross-refs is null rather than a
    /// pick: choosing between them from a symbol alone is the guess this
    /// reader replaces.
    fn crossRefOfKey(self: *const LoweringInput, key: []const u8) ?Plugin.ValueKind.CrossRef {
        const spec = self.keySpecFor(key) orelse return null;
        const kind = self.kindOfType(spec.value_type) orelse return null;
        if (kind.cross_ref) |cr| return cr;

        const u = kind.union_of orelse return null;
        var found: ?Plugin.ValueKind.CrossRef = null;
        for (u.alternatives) |alt| {
            const alt_kind = self.kindOfType(.{ .named = alt }) orelse continue;
            const alt_cr = alt_kind.cross_ref orelse continue;
            if (found != null) return null;
            found = alt_cr;
        }
        return found;
    }

    /// The value kind a declared type names, or null for a primitive /
    /// structural type or an unresolvable name.
    fn kindOfType(self: *const LoweringInput, vt: Plugin.ValueType) ?*const Plugin.ValueKind {
        const named = switch (vt) {
            .named => |n| n,
            else => return null,
        };
        return switch (self.schema.lookupValueKind(named.name, named.namespace)) {
            .found => |v| v,
            else => null,
        };
    }

    /// The `KeySpec` declaring `key` on this form: a base key, or a key of
    /// any variant. Variant *activity* is not consulted — a key is
    /// declared in exactly one variant of a form (the loader rejects a
    /// name in two), so the type this finds is the type that key has
    /// wherever it is legal, and a hook reading a key from an inactive
    /// variant has already been told so by the validator.
    fn keySpecFor(self: *const LoweringInput, key: []const u8) ?*const Plugin.KeySpec {
        for (self.form_spec.keys) |*k| {
            if (std.mem.eql(u8, k.name, key)) return k;
        }
        if (self.form_spec.variants) |vs| for (vs) |*v| {
            for (v.keys) |*k| {
                if (std.mem.eql(u8, k.name, key)) return k;
            }
        };
        return null;
    }

    /// Read a symbol-typed key. Accepts author `Tag.symbol`, author
    /// `Tag.keyword`, and defaulted `Expr.Value.keyword` (the
    /// `MaterializedDefaults.literalToValue` normalization of
    /// `:default <symbol>` declarations — `Expr.Value` has no
    /// `.symbol` variant, so symbol defaults land as `.keyword`). All
    /// three arms coerce to the same `[]const u8` symbol text, papering
    /// over the symbol/keyword duality at the read layer so cross-ref
    /// slots receive a uniform value regardless of provenance.
    ///
    /// Other source types → `error.HookFailed`. Returns `null` when the
    /// key is absent (no author kvpair and no schema default). Returned
    /// text is duped onto `self.arena`, so it is safe to embed directly
    /// in an `EmittedValue.symbol` without re-coercing.
    pub fn symbol(self: *const LoweringInput, key: []const u8) LoweringError!?[]const u8 {
        const ev = self.view.getEffectiveValue(self.form_idx, key) orelse return null;
        return switch (ev) {
            .author => |idx| switch (self.view.tree.tagOf(idx)) {
                .symbol => try self.arena.dupe(u8, self.view.tree.symbolText(idx)),
                .keyword => try self.arena.dupe(u8, self.view.tree.keywordText(idx)),
                else => error.HookFailed,
            },
            .default => |entry| switch (entry.value) {
                .keyword => |k| try self.arena.dupe(u8, k),
                else => error.HookFailed,
            },
        };
    }

    /// Read a string-typed key. Accepts author `Tag.string` and
    /// defaulted `Expr.Value.string`. Other types → `error.HookFailed`.
    /// Returns `null` when the key is absent. Returned text is duped
    /// onto `self.arena`.
    pub fn string(self: *const LoweringInput, key: []const u8) LoweringError!?[]const u8 {
        const ev = self.view.getEffectiveValue(self.form_idx, key) orelse return null;
        return switch (ev) {
            .author => |idx| switch (self.view.tree.tagOf(idx)) {
                .string => try self.arena.dupe(u8, self.view.tree.stringText(idx)),
                else => error.HookFailed,
            },
            .default => |entry| switch (entry.value) {
                .string => |s| try self.arena.dupe(u8, s),
                else => error.HookFailed,
            },
        };
    }

    /// Read a number-typed key. Accepts author `Tag.number` and
    /// defaulted `Expr.Value.number`. Other types (including
    /// `Tag.number_with_unit`) → `error.HookFailed`. Returns `null`
    /// when the key is absent.
    pub fn number(self: *const LoweringInput, key: []const u8) LoweringError!?f64 {
        const ev = self.view.getEffectiveValue(self.form_idx, key) orelse return null;
        return switch (ev) {
            .author => |idx| switch (self.view.tree.tagOf(idx)) {
                .number, .number_i64, .number_u64 => self.view.tree.numberOf(idx),
                else => error.HookFailed,
            },
            .default => |entry| switch (entry.value) {
                .number => |n| n,
                else => error.HookFailed,
            },
        };
    }

    /// Read a number-typed key, *evaluating* an author expression in value
    /// position against `self.env` rather than rejecting it the way
    /// `number` does. A plain author number tag takes a literal fast-path
    /// (no evaluator); anything else (`(* workgroup-size 2)`, a `:ref`, …)
    /// is fed to `Expr.eval` with the host-supplied env, so a hook can
    /// consume a computed value or a host constant. A defaulted value
    /// arrives already as an `Expr.Value` and is collapsed directly.
    ///
    /// Returns `null` when the key is absent. A non-numeric result, or any
    /// eval failure (an unbound free variable raises `UnknownBinding`
    /// against the default empty env), → `error.HookFailed`; `OutOfMemory`
    /// propagates. The owning plugin's functions must be in `self.schema`
    /// (core supplies `*`).
    pub fn numberEval(self: *const LoweringInput, key: []const u8) LoweringError!?f64 {
        const ev = self.view.getEffectiveValue(self.form_idx, key) orelse return null;
        return switch (ev) {
            .author => |idx| switch (self.view.tree.tagOf(idx)) {
                .number, .number_i64, .number_u64 => self.view.tree.numberOf(idx),
                else => blk: {
                    var r = Expr.eval(self.arena, self.view.tree, idx, self.env, self.schema.*) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.HookFailed,
                    };
                    defer r.deinit();
                    break :blk valueToF64(r.value) orelse error.HookFailed;
                },
            },
            .default => |entry| valueToF64(entry.value) orelse error.HookFailed,
        };
    }

    /// Read a boolean-typed key. Accepts author `Tag.boolean_true` /
    /// `Tag.boolean_false` and defaulted `Expr.Value.boolean`. Other
    /// types → `error.HookFailed`. Returns `null` when the key is
    /// absent.
    pub fn boolean(self: *const LoweringInput, key: []const u8) LoweringError!?bool {
        const ev = self.view.getEffectiveValue(self.form_idx, key) orelse return null;
        return switch (ev) {
            .author => |idx| switch (self.view.tree.tagOf(idx)) {
                .boolean_true => true,
                .boolean_false => false,
                else => error.HookFailed,
            },
            .default => |entry| switch (entry.value) {
                .boolean => |b| b,
                else => error.HookFailed,
            },
        };
    }
};

/// Collapse the numeric `Expr.Value` variants to `f64` for `numberEval`.
/// Non-numeric values (the hook evaluated a non-number slot) return
/// `null`, which the caller turns into `error.HookFailed`.
fn valueToF64(v: Expr.Value) ?f64 {
    return switch (v) {
        .number => |n| n,
        .integer_i64 => |i| @floatFromInt(i),
        .integer_u64 => |u| @floatFromInt(u),
        else => null,
    };
}

/// Write-only sink for hook output. `forms` lives on the hook's
/// arena; the pass driver consumes the slice and translates each
/// emitted form into an `Ast.Tree` node via `buildLoweredTree`.
pub const LoweringOutput = struct {
    forms: std.ArrayList(EmittedForm) = .empty,

    /// Why this hook is about to return `HookFailed`, set through
    /// `fail`/`failAt`. `null` — the default, and what a hook that simply
    /// `return error.HookFailed`s leaves behind — reproduces the original
    /// behaviour byte for byte: the driver reports its own generic
    /// "returned HookFailed" message at the source form's head span.
    ///
    /// It lives on the OUTPUT rather than in a new `HookFn` parameter
    /// because this struct is already the hook's only write channel and the
    /// hook already holds the arena the message must live on. That makes the
    /// extension additive: every existing hook and host compiles unchanged,
    /// and only a hook that opts in changes what an author reads.
    cause: ?Cause = null,

    /// A hook's own account of a failure. `span` overrides the diagnostic's
    /// default location (the lowered form's head) and is load-bearing for a
    /// *container* hook — one whose form wraps children it lowers together
    /// — because such a hook's failures belong to one child, and pointing
    /// at the container underlines the whole construct instead.
    pub const Cause = struct {
        message: []const u8,
        span: ?Ast.Span = null,
    };

    /// Convenience: append a fully constructed `EmittedForm`. Equivalent
    /// to calling `forms.append(arena, ef)` directly — exposed so hooks
    /// don't depend on the ArrayList API shape.
    pub fn append(
        self: *LoweringOutput,
        arena: Allocator,
        ef: EmittedForm,
    ) Allocator.Error!void {
        try self.forms.append(arena, ef);
    }

    /// Record why this hook is failing and hand back the error to propagate,
    /// so a call site reads as one statement:
    ///
    /// ```zig
    /// if (scan.count == 0) return out.fail(arena, "`{s}` declares no entry point", .{name});
    /// ```
    ///
    /// The message is formatted onto the hook's `arena`; the driver copies it
    /// onto the diagnostic's gpa, so it need not outlive the invocation.
    pub fn fail(
        self: *LoweringOutput,
        arena: Allocator,
        comptime fmt: []const u8,
        args: anytype,
    ) LoweringError {
        return self.failWith(arena, null, fmt, args);
    }

    /// `fail` with an explicit source span — the arm a container hook uses to
    /// point at the child that broke rather than at itself. `span` must come
    /// from the document being lowered (`input.view.tree`), the same tree the
    /// default head span is read from.
    pub fn failAt(
        self: *LoweringOutput,
        arena: Allocator,
        span: Ast.Span,
        comptime fmt: []const u8,
        args: anytype,
    ) LoweringError {
        std.debug.assert(span.end >= span.start); // pre: a well-formed span
        return self.failWith(arena, span, fmt, args);
    }

    fn failWith(
        self: *LoweringOutput,
        arena: Allocator,
        span: ?Ast.Span,
        comptime fmt: []const u8,
        args: anytype,
    ) LoweringError {
        comptime std.debug.assert(fmt.len > 0); // pre: a cause says something

        // A formatting failure leaves `cause` as it was and still returns
        // HookFailed, rather than escalating to OutOfMemory. The hook was
        // already failing on the author's document; turning that into a host
        // memory error would misreport whose problem it is, and the
        // cause-free diagnostic — the exact one this API replaces — is the
        // honest fallback.
        const message = std.fmt.allocPrint(arena, fmt, args) catch
            return LoweringError.HookFailed;
        self.cause = .{ .message = message, .span = span };
        std.debug.assert(self.cause.?.message.len > 0); // post: a cause says something
        return LoweringError.HookFailed;
    }
};

/// One form emitted by a hook. Field shapes intentionally mirror the
/// author tree without committing to AST tags (the pass driver
/// translates).
pub const EmittedForm = struct {
    head: []const u8,
    kvpairs: []const EmittedKvpair = &.{},
    /// Ordered positional list, materialized after `kvpairs`. A `.form`
    /// arm is a nested-form positional — it carries a head, is checked
    /// against `:produces`, and preserves provenance (diagnostics on a
    /// deeply-nested emitted form still trace back to the source form via
    /// `source_form_idx`). A scalar arm
    /// (`symbol`/`number`/`string`/`keyword`/`boolean`/`nil`) is a *bare
    /// positional atom*: it has no head and is not `:produces`-checked, so a
    /// hook can synthesize `(module shader)` — a head plus a lone positional
    /// symbol — the same shape an author could write. A `.vector` arm has no
    /// head of its own, but any `.form` nested inside it (at any depth) is
    /// `:produces`-checked like any other emitted form: the contract applies
    /// to every emitted form regardless of how it is attached — positional
    /// child, kvpair value, or vector element (see `validateEmittedForm`).
    /// The slice and any nested payloads must be arena-owned, like every
    /// other emitted field.
    children: []const EmittedValue = &.{},
    /// Provenance: the source form that owned the kvpairs the hook
    /// read. Always equal to `LoweringInput.form_idx` at the top
    /// level; preserved on nested children so the lowered-tree
    /// builder can stamp every emitted node with the same source span.
    source_form_idx: Ast.NodeIndex,
    /// Span to stamp on this form and its subtree, overriding the source
    /// form's. Null (the default) keeps the source form's span, which is
    /// right for genuine sugar: the container authored those bytes and is
    /// the honest place to point at.
    ///
    /// A *container* hook that lifts a child out of its own subtree wants
    /// the other answer. `(space :name poster (text :name letters …))`
    /// lowers to a flat `text` the author wrote on its own line, and
    /// without this every diagnostic on it points at the whole enclosing
    /// block — strictly worse than the flat spelling the nesting replaces.
    /// Set it to the lifted child's span and the diagnostics land on the
    /// bytes the author typed.
    ///
    /// Orthogonal to provenance: `source_form_idx` still names the
    /// container, because the container's hook did author the form. The two
    /// questions — "who emitted this" and "which bytes should a reader be
    /// shown" — get one field each.
    ///
    /// A nested emitted form may narrow further: the override an
    /// `EmittedForm` sets applies to its whole subtree until a descendant
    /// sets its own.
    source_span: ?Ast.Span = null,
};

pub const EmittedKvpair = struct {
    key: []const u8,
    value: EmittedValue,
};

/// Value shapes a hook may emit. Mirrors the kvpair-value shapes that
/// appear in a source tree — no number-with-unit (use `number`; the
/// lowered tree models `Tag.number`) and no expression form (lowering
/// produces data, never recursive computation).
pub const EmittedValue = union(enum) {
    number: f64,
    string: []const u8,
    symbol: []const u8,
    keyword: []const u8,
    boolean: bool,
    nil,
    vector: []const EmittedValue,
    /// A nested form. Wherever an `EmittedValue.form` appears — a positional
    /// child, a kvpair value, or a vector element — its head is checked
    /// against the hook's `:produces` and its nesting counts toward
    /// `MAX_LOWERED_DEPTH`, exactly like a top-level emitted form.
    form: EmittedForm,
};

/// Per-form provenance side-table populated by `buildLoweredTree`.
/// Form-level granularity is sufficient for v1: every
/// node inside a lowered form inherits the source span anyway, so
/// downstream consumers can answer "what authored this?" with one
/// lookup per lowered form.
///
/// **One table is one layer, and one layer is one hop.** A table
/// describes exactly the pass that produced it: `lowered_form_idx`
/// indexes the tree this table came back with, `source_form_idx` indexes
/// the tree that pass ran *over*. Staging runs one pass per lowerable
/// generation (`Host.runLoweringStages`), so a document that lowers `n`
/// times produces `n` tables and no single one of them reaches past its
/// own hop. Chaining them is the caller's, not the table's, and
/// `Host.HostResult.provenanceChain` is the caller that does it.
pub const LoweringProvenance = struct {
    entries: []const Entry = &.{},

    pub const Entry = struct {
        /// The emitted root form, indexing the tree this table came back
        /// with.
        lowered_form_idx: Ast.NodeIndex,
        /// The form the hook lowered, indexing the tree the pass ran
        /// over — the source tree at layer 0, the previous layer's tree
        /// at every layer after it. This is an `Ast.NodeIndex`, a `u32`
        /// and not a pointer, so reading it against some *other* tree
        /// does not fail: it lands on an unrelated node of that tree, or
        /// on nothing at all, with no error either way. Pair it with the
        /// tree its own layer ran over and nothing else.
        source_form_idx: Ast.NodeIndex,
        /// Id of the hook that ran, e.g. `"test/identity-v1"`. Arena-owned
        /// alongside the table.
        hook_id: []const u8,
    };

    /// Lookup by lowered form index. Linear scan — the provenance
    /// table is short by construction (one entry per emitted top-
    /// level form), so a hash would cost more than it saves.
    pub fn lookup(self: *const LoweringProvenance, lowered: Ast.NodeIndex) ?Entry {
        for (self.entries) |entry| {
            if (entry.lowered_form_idx == lowered) return entry;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Pass driver — walk the data forest, find forms with :lowering, gate
// the hook on surface validation, invoke it, validate the emitted
// forest against the contract. The lowered-tree builder is separate
// (`buildLoweredTree`); this driver returns invocations so callers
// (Host + tests) can inspect what would be lowered before tree construction.
// ---------------------------------------------------------------------------

/// One executed lowering invocation. `forms` is the slice the hook
/// appended to its `LoweringOutput`. Arena-owned alongside the
/// embedded strings.
pub const Invocation = struct {
    source_form_idx: Ast.NodeIndex,
    hook_id: []const u8,
    forms: []const EmittedForm,
};

/// Outcome of `runLoweringPass`. Mirrors the aggregate-validator
/// pattern: invocations are arena-owned; diagnostics are gpa-owned
/// and released via `deinit`.
pub const PassResult = struct {
    invocations: []const Invocation,
    diagnostics: []const Ast.Diagnostic,
    /// How many times this layer built its cross-reference index — see
    /// `LayerRefs`. Zero for every pass whose hooks resolved nothing,
    /// one for every pass where at least one did, and never more: the
    /// index is shared across the layer's hooks. It is here because that
    /// sentence is otherwise unobservable, and an unobservable promise is
    /// one a refactor can break in silence.
    ref_index_builds: usize = 0,

    pub fn deinit(self: *PassResult, gpa: Allocator) void {
        Ast.Diagnostic.freeOwnedSlice(gpa, self.diagnostics);
    }
};

/// Maximum number of staging layers a document may pass through. Each
/// layer lowers the previous layer's emitted forms; the produces-graph
/// cycle check (`Schema.validateLowering` → `lowering_cycle`) already
/// proves staging terminates, so this is a backstop for a deep-but-
/// acyclic chain. Exceeding it → `lowering_output_too_large`. Distinct
/// from `Plugin.MAX_LOWERED_DEPTH`, which bounds per-form *nesting*
/// within a single emitted output, not the number of layers.
pub const MAX_LOWERING_STAGES: usize = 16;

/// Cumulative emitted-form budget across all staging layers — the
/// fan-out backstop. A hook whose output is itself heavily lowerable
/// could otherwise blow up form count / memory layer over layer; this
/// caps the total. Mirrors the `1 << 20` step ceilings the other frame-
/// stack walkers use (`Validator.MAX_VALIDATE_STEPS`, `Expr.MAX_STEPS`).
/// Exceeding it → `lowering_output_too_large`. Threaded as a parameter
/// through `runLoweringPassBudgeted` so the host accumulates one counter
/// across layers and tests can trip it with a small cap.
pub const MAX_LOWERING_STEPS: usize = 1 << 20;

/// Run one staging *layer*: walk `data_forest` over `tree` and run any
/// lowering contract declared on the matching `FormSpec`. Returns an
/// `Invocation` per executed hook and a diagnostic stream of contract
/// violations (missing hook, hook failure, invalid produced head,
/// output-too-large). Surface-validation failures are silent here — the
/// source-tree validation pass in the host surfaces them, and re-
/// emitting would double the entry.
///
/// The host re-invokes this per layer — the emitted forms of one layer
/// become the next layer's forest — up to `MAX_LOWERING_STAGES`. An
/// emitted form whose own `FormSpec` is lowerable is no longer rejected;
/// staging lowers it in the next layer.
///
/// `arena` owns the invocations and their emitted forms (so they outlive
/// this call and feed into the lowered-tree builder). Diagnostics use
/// `gpa`; the host copies them via `wrapDiagnostic` before `deinit`.
pub fn runLoweringPass(
    gpa: Allocator,
    arena: Allocator,
    tree: *const Ast.Tree,
    data_forest: []const Ast.NodeIndex,
    schema: Schema.Schema,
    materialized: *const MaterializedDefaults.MaterializedDefaults,
    registry: *const LoweringRegistry,
    axes: Validator.EffectiveAxes,
) Allocator.Error!PassResult {
    const empty_env: Expr.Env = .{};
    return runLoweringPassWithEnv(gpa, arena, tree, data_forest, schema, materialized, registry, axes, &empty_env);
}

/// Env-aware `runLoweringPass`: the same single-layer pass, but threads a
/// host-supplied `Expr.Env` so a hook's `numberEval` resolves free
/// variables (host-injected constants) in author expressions.
/// `runLoweringPass` is exactly this with an empty env. Direct API
/// consumers that have constants to inject use this; the production driver
/// goes through `runLoweringPassBudgeted` (the host threads one cumulative
/// emitted-form budget across staging layers).
pub fn runLoweringPassWithEnv(
    gpa: Allocator,
    arena: Allocator,
    tree: *const Ast.Tree,
    data_forest: []const Ast.NodeIndex,
    schema: Schema.Schema,
    materialized: *const MaterializedDefaults.MaterializedDefaults,
    registry: *const LoweringRegistry,
    axes: Validator.EffectiveAxes,
    env: *const Expr.Env,
) Allocator.Error!PassResult {
    var emitted: usize = 0;
    return runLoweringPassBudgeted(gpa, arena, tree, data_forest, schema, materialized, registry, axes, env, &emitted, MAX_LOWERING_STEPS);
}

/// Budget-parameterized `runLoweringPass`. `emitted` accumulates the
/// total emitted-form count — the host threads one counter across every
/// staging layer so the cumulative `budget` (normally `MAX_LOWERING_STEPS`)
/// bounds the whole pipeline, not just one layer. `env` is the
/// host-supplied evaluation environment placed on every `LoweringInput`
/// (`numberEval` resolves author-expression free variables against it).
/// Exposed so tests can drive the fan-out backstop with a small cap
/// (mirrors `Expr.evalWithRuntimeBudget`).
pub fn runLoweringPassBudgeted(
    gpa: Allocator,
    arena: Allocator,
    tree: *const Ast.Tree,
    data_forest: []const Ast.NodeIndex,
    schema: Schema.Schema,
    materialized: *const MaterializedDefaults.MaterializedDefaults,
    registry: *const LoweringRegistry,
    axes: Validator.EffectiveAxes,
    env: *const Expr.Env,
    emitted: *usize,
    budget: usize,
) Allocator.Error!PassResult {
    var invocations: std.ArrayList(Invocation) = .empty;
    errdefer invocations.deinit(arena);
    var diags: std.ArrayList(Ast.Diagnostic) = .empty;
    // On the error path, free each recorded diagnostic's contents (message +
    // path parts), not just the list backing — mirrors PassResult.deinit. A
    // mid-pass OOM after a diagnostic was appended must not leak it.
    errdefer {
        Ast.Diagnostic.freeOwnedContents(gpa, diags.items);
        diags.deinit(gpa);
    }

    // Held-unaware on purpose. `Host.HostOptions.held_symbol` reaches the
    // overlay and the validator; it stops here, so a hook reads a held
    // kvpair as the author's `_` rather than as the key's declared default.
    // Lowering runs Zig function pointers and no host executes a hook (see
    // CLAUDE.md), so the editing host that asked for held positions cannot
    // reach this pass — threading it through `runLoweringPass*` would be
    // three more parameters for a caller that does not exist. Thread it when
    // one does.
    const view = EffectiveView.init(tree, materialized);

    // The layer's reference index. Constructed unconditionally (a plain
    // stack value that allocates nothing) and *built* only if a hook asks
    // — see `LayerRefs`. Its forest view is the roots this pass was
    // given, not the whole tree.
    var forest_view: Ast.Tree = tree.*;
    forest_view.root = data_forest;
    var refs: LayerRefs = .{
        .forest = forest_view,
        .schema = schema,
        .options = .{ .overlay = materialized, .axes = axes },
    };

    // Iterative pre-order walk over the forest — replaces host recursion
    // with an explicit worklist (frame-stack discipline, matching the
    // other walkers). Children are pushed in reverse so siblings pop
    // left-to-right, preserving the document order the recursive walk
    // produced. Each frame carries the slot-local registry its enclosing
    // slot puts in scope, so a head resolves **local-first** exactly as
    // the validator resolves it (`Validator.validateFormHead` step 0): a
    // local body is never a hook, so a local head that shadows a global
    // *lowerable* form must not fire the global's hook — the runtime half
    // of the S7 rule ("a local shadows a same-named global").
    var work: std.ArrayList(WorkFrame) = .empty;
    defer work.deinit(gpa);
    // Per-form scratch, reused across the walk: the `KeySpec` each kvpair
    // child is accepted under (`matchKvpairKeys`), which is what decides
    // the registry a kvpair-value form child takes.
    var matched: std.ArrayList(?*const Plugin.KeySpec) = .empty;
    defer matched.deinit(gpa);
    var seed = data_forest.len;
    while (seed > 0) {
        seed -= 1;
        try work.append(gpa, .{ .idx = data_forest[seed] });
    }

    while (work.pop()) |fr| {
        const idx = fr.idx;
        if (tree.tagOf(idx) != .form) continue;
        const hdr = tree.formHeader(idx);
        // Parser-recovery synthetic form — skip, mirroring materializeDefaults.
        if (hdr.head.len == 0) continue;

        // Local-first: a bare head in a slot with a registry resolves to the
        // local body when one matches; a qualified head bypasses locals. A
        // local never lowers (`FormSpec.lowering` is null on every local —
        // loader-rejected, `Schema.init`-asserted), so only a global hit can
        // fire a hook.
        const local_hit = matchLocalHead(fr.local_registry, hdr);
        var spec: ?*const Plugin.FormSpec = local_hit;
        var parent_lowerable = false;
        if (local_hit == null) {
            const hit = schema.lookupForm(hdr.head, hdr.namespace);
            if (hit == .found) {
                const form_spec = hit.found.form;
                spec = form_spec;
                if (form_spec.lowering) |*low| {
                    parent_lowerable = true;
                    try lowerOneForm(gpa, arena, tree, idx, hdr, form_spec, low, schema, view, registry, axes, env, &refs, &invocations, &diags, emitted, budget);
                }
            }
        }

        // Which key each kvpair child is accepted under — the same rule the
        // validator's key-typing pass applies, so a variant key's locals are
        // in scope only while its variant is active.
        matched.clearRetainingCapacity();
        try matched.appendNTimes(gpa, null, hdr.children.len);
        if (spec) |sp| matchKvpairKeys(sp, tree, idx, hdr, materialized, axes, matched.items);

        // A lowerable child of a lowerable parent is the one self-
        // contradictory container setup (`:lowering` on both): the
        // container consumes its children as data, but a child that
        // *also* declares `:lowering` fires its own hook in the same
        // layer, so both emit overlapping output. Flag it at the child
        // instead of letting the overlap cascade into a confusing
        // `duplicate_cross_ref_target` downstream. Emit-only — the
        // by-design descent (a *plain-data* parent holding lowerable
        // sugar, where `parent_lowerable` is false) is untouched, and
        // collection-over-abort keeps lowering both forms.
        //
        // Forward sweep for the lint so sibling diagnostics surface in
        // *document* order — the order an author reads them. Kept distinct
        // from the reverse push below: folding the check into that loop
        // would emit siblings last-to-first.
        if (parent_lowerable) {
            for (hdr.children, 0..) |child, ci| {
                if (slotIsOpaque(tree, child, matched.items[ci])) continue;
                if (tree.childForm(child)) |cf| try checkNestedLowerable(gpa, tree, cf, childLocalRegistry(spec, tree, child, matched.items[ci]), schema, &diags);
            }
        }

        // Descend into form-shaped children so nested sugar forms also
        // lower. Push in reverse so the worklist pops them in document
        // order (matches the prior recursive descent). Each child frame
        // takes the registry this form's spec puts in scope for it.
        var c = hdr.children.len;
        while (c > 0) {
            c -= 1;
            const child = hdr.children[c];
            if (slotIsOpaque(tree, child, matched.items[c])) continue;
            if (tree.childForm(child)) |cf| {
                try work.append(gpa, .{ .idx = cf, .local_registry = childLocalRegistry(spec, tree, child, matched.items[c]) });
            }
        }
    }

    return .{
        .invocations = try invocations.toOwnedSlice(arena),
        .diagnostics = try diags.toOwnedSlice(gpa),
        .ref_index_builds = refs.builds,
    };
}

/// One worklist frame of `runLoweringPassBudgeted`: a form node plus the
/// slot-local registry its enclosing slot puts in scope for its head — the
/// parent's `FormSpec.local_forms` for a positional form child, the matched
/// key's `KeySpec.local_forms` for a kvpair-value form, null otherwise
/// (`childLocalRegistry`). Mirrors the validator's frame fields so the two
/// walkers resolve a head the same way.
const WorkFrame = struct {
    idx: Ast.NodeIndex,
    local_registry: ?[]const Plugin.FormSpec = null,
};

/// True when the key this kvpair was accepted under declared the slot
/// `walk_opaque`. The validator does not descend there, so neither does
/// this pass: a hook rewriting a subtree the surrounding schema declined
/// to read would turn the validator's deliberate blind spot into an edit,
/// and the lowered forms it emitted would then be validated against the
/// very schema that said it was not looking.
///
/// A positional child carries no `KeySpec`, so it carries no opt-in
/// either; an unaccepted key says nothing, the same as everywhere else.
fn slotIsOpaque(
    tree: *const Ast.Tree,
    child: Ast.NodeIndex,
    matched_key: ?*const Plugin.KeySpec,
) bool {
    if (tree.tagOf(child) != .kvpair) return false;
    const key = matched_key orelse return false;
    return key.walk_opaque;
}

/// The local body a form head resolves to under `registry`, or null: a bare
/// head with a matching local, and nothing else. A qualified head bypasses
/// locals; no registry means no locals in scope. The gate is the same one
/// `Validator.validateFormHead` step 0 applies before consulting the
/// global catalog.
fn matchLocalHead(registry: ?[]const Plugin.FormSpec, hdr: Ast.FormHeader) ?*const Plugin.FormSpec {
    if (hdr.namespace != null) return null;
    const reg = registry orelse return null;
    return Validator.matchLocalForm(reg, hdr.head);
}

/// The slot-local registry a form whose resolved spec is `parent_spec` puts
/// in scope for its child node `child` (a positional child or a kvpair, as
/// listed in `FormHeader.children`): the parent's own `local_forms` for a
/// form-shaped positional child; for a kvpair whose value is a form, the
/// `local_forms` of `matched_key` — the key the validator accepts the kvpair
/// under (`matchKvpairKeys`), so an unaccepted key puts nothing in scope;
/// null when the parent is unresolved, the child is neither, or the carrier
/// is empty.
fn childLocalRegistry(
    parent_spec: ?*const Plugin.FormSpec,
    tree: *const Ast.Tree,
    child: Ast.NodeIndex,
    matched_key: ?*const Plugin.KeySpec,
) ?[]const Plugin.FormSpec {
    const spec = parent_spec orelse return null;
    switch (tree.tagOf(child)) {
        .form => return if (spec.local_forms.len > 0) spec.local_forms else null,
        .kvpair => {
            const kvh = tree.kvpairHeader(child);
            if (tree.tagOf(kvh.value) != .form) return null;
            const key = matched_key orelse return null;
            return if (key.local_forms.len > 0) key.local_forms else null;
        },
        else => return null,
    }
}

/// Fill `out[i]` with the `KeySpec` the validator's key-typing pass accepts
/// kvpair child `i` of the form under (positional children and unaccepted
/// keys stay null): a common key by name; a variant key by name only while
/// its variant is **active** — selected by the discriminant kvpair seen
/// *earlier* among the children (the position rule of
/// `Validator.matchAndTypecheckDeclaredKey` / `matchAndTypecheckVariantKey`:
/// discriminant first) or, when the author omitted the discriminant, by its
/// overlay default under axis D (`Validator.preresolveDiscriminantViaOverlay`).
/// A discriminant value no variant selects leaves the active variant as it
/// was, as there. The tree walker hands its frames the typing pass's own
/// matches, so this is the one restatement of the rule; the lowering
/// worklist needs it because it resolves heads on the authored tree before
/// validation runs.
fn matchKvpairKeys(
    spec: *const Plugin.FormSpec,
    tree: *const Ast.Tree,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    materialized: *const MaterializedDefaults.MaterializedDefaults,
    axes: Validator.EffectiveAxes,
    out: []?*const Plugin.KeySpec,
) void {
    std.debug.assert(out.len == hdr.children.len);
    const variants = spec.variants orelse &.{};
    var active: ?usize = null;
    // Axis D: an omitted discriminant with an overlay default pre-selects.
    if (axes.variant) {
        if (spec.discriminant_idx) |didx| {
            const dkey = spec.keys[didx];
            if (!Validator.authorWroteKvpair(tree, hdr, dkey.name)) {
                if (materialized.defaultFor(form_idx, dkey.name)) |entry| {
                    // Symbol defaults reach the overlay as `.keyword`;
                    // strings are accepted too, as the validator does.
                    const stext: ?[]const u8 = switch (entry.value) {
                        .keyword => |k| k,
                        .string => |t| t,
                        else => null,
                    };
                    if (stext) |t| {
                        for (variants, 0..) |v, vi| {
                            if (v.selects(t)) {
                                active = vi;
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
    for (hdr.children, 0..) |ch, ci| {
        if (tree.tagOf(ch) != .kvpair) continue;
        const kvh = tree.kvpairHeader(ch);
        if (spec.keyByName(kvh.key)) |k| {
            out[ci] = k;
            if (spec.discriminant_idx) |didx| {
                if (k == &spec.keys[didx] and tree.tagOf(kvh.value) == .symbol) {
                    const sym = tree.symbolText(kvh.value);
                    for (variants, 0..) |v, vi| {
                        if (v.selects(sym)) {
                            active = vi;
                            break;
                        }
                    }
                }
            }
            continue;
        }
        const vi = active orelse continue;
        for (variants[vi].keys) |*vk| {
            if (std.mem.eql(u8, vk.name, kvh.key)) {
                out[ci] = vk;
                break;
            }
        }
    }
}

/// Emit `lowering_nested_lowerable` when `child` resolves to a form whose own
/// `FormSpec` declares `:lowering`. The worklist calls this only when the
/// *parent* is itself lowerable, so a plain-data parent holding lowerable sugar
/// (the supported nested-sugar shape) never trips it. Resolution is
/// local-first under `local_registry` (the parent's slot registry for this
/// child): a local body never lowers, so a local head that shadows a global
/// lowerable form is not a nested-lowerable. The diagnostic points at the
/// child's head with path `[<child-head>, lowering]`. Emit-only: the caller
/// still descends into `child`, so both hooks run and the contradictory
/// output still forms — the clear diagnostic is the headline, not a veto.
fn checkNestedLowerable(
    gpa: Allocator,
    tree: *const Ast.Tree,
    child: Ast.NodeIndex,
    local_registry: ?[]const Plugin.FormSpec,
    schema: Schema.Schema,
    diags: *std.ArrayList(Ast.Diagnostic),
) Allocator.Error!void {
    const chdr = tree.formHeader(child);
    // Parser-recovery synthetic form — no head to resolve or report.
    if (chdr.head.len == 0) return;
    if (matchLocalHead(local_registry, chdr) != null) return;
    const chit = schema.lookupForm(chdr.head, chdr.namespace);
    if (chit != .found) return;
    if (chit.found.form.lowering == null) return;
    try emitDiag(gpa, diags, .lowering_nested_lowerable, chdr.head_span, &.{ chdr.head, "lowering" }, "form `({s} …)` declares :lowering but is a positional child of another :lowering form; both hooks fire in the same layer — put :lowering on the container or the child, not both", .{chdr.head});
}

fn lowerOneForm(
    gpa: Allocator,
    arena: Allocator,
    tree: *const Ast.Tree,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    form_spec: *const Plugin.FormSpec,
    lowering_spec: *const Plugin.LoweringSpec,
    schema: Schema.Schema,
    view: EffectiveView,
    registry: *const LoweringRegistry,
    axes: Validator.EffectiveAxes,
    env: *const Expr.Env,
    refs: *LayerRefs,
    invocations: *std.ArrayList(Invocation),
    diags: *std.ArrayList(Ast.Diagnostic),
    emitted: *usize,
    budget: usize,
) Allocator.Error!void {
    // Caller-contract guards. The worklist walk in `runLoweringPassBudgeted`
    // is the only caller; it filters synthetic recovery forms
    // (`head.len == 0`) and only enters this branch when
    // `form_spec.lowering` is non-null. Asserting both means a future
    // caller that skips the filters trips the gate during testing instead
    // of producing a confusing diagnostic.
    std.debug.assert(hdr.head.len > 0);
    std.debug.assert(form_spec.lowering != null);

    // Step 1 — surface-validate the single-form sub-tree. A tree-copy
    // substitution lets us reuse `Validator.validateWithOptions` over
    // just this form: same nodes, narrowed root. Anything error-level
    // suppresses the hook so a malformed sugar form doesn't reach a
    // contract that assumes well-formed input.
    //
    // `defer_cross_refs` is what makes that gate honest. This is the one
    // caller that validates a form out of its document, and the *only*
    // input that differs from the whole-document pass is which names are
    // registered: the sub-tree's cross-ref index sees this form alone, so
    // a reference to a sibling elsewhere misses here and resolves in the
    // final forest. Everything else — the schema, the overlay (which is
    // the whole document's, not a fragment of one), the axes — is the same
    // object in both passes and decides identically.
    //
    // The flag replaces a hand-maintained list of cross-ref diagnostic
    // codes. The list said the same thing by enumerating the ways that one
    // difference surfaces, and it fell behind: a reference reached through
    // a `(union-shape …)` fails as `union_no_branch_matched`, which is not
    // a cross-ref code, so the gate closed and the hook was skipped with
    // no diagnostic anywhere (`docs/plans/asks/19-*.md`). A vector
    // alternative or a nested union would have been the next spelling.
    // Saying "this tree is a fragment" has no next spelling.
    //
    // Surface diagnostics are still discarded — they never reach the host
    // stream from this pass. The final-forest pass surfaces what survives:
    // an unlowered form validates as authored, and a lowered one is judged
    // through what its hook emitted.
    var sub: Ast.Tree = tree.*;
    var sub_root = [_]Ast.NodeIndex{form_idx};
    sub.root = sub_root[0..];
    var surface = try Validator.validateWithOptions(gpa, sub, schema, .{
        .overlay = view.materialized,
        .axes = axes,
        .defer_cross_refs = true,
    });
    defer surface.deinit();
    if (hasError(surface.diagnostics)) return;

    // Step 2 — find the hook.
    const hook = registry.lookup(lowering_spec.hook) orelse {
        try emitDiag(gpa, diags, .lowering_hook_missing, hdr.head_span, &.{ hdr.head, "lowering" }, "form `({s} …)` declares :lowering :hook \"{s}\" but no hook is registered with that id", .{ hdr.head, lowering_spec.hook });
        return;
    };

    // Step 3 — invoke the hook. The hook arena outlives the call
    // (entries land on the caller's arena directly); a hook that
    // returns HookFailed surfaces as `lowering_hook_failed` and
    // contributes no invocation entry.
    var output: LoweringOutput = .{};
    const input: LoweringInput = .{
        .arena = arena,
        .form_idx = form_idx,
        .head = hdr.head,
        .source_span = hdr.head_span,
        .view = view,
        .schema = &schema,
        .form_spec = form_spec,
        .lowering_spec = lowering_spec,
        .ctx = hook.ctx,
        .env = env,
        .refs = refs,
    };
    hook.lower(arena, &input, &output) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.HookFailed => {
            // A hook that explained itself (`out.fail`/`failAt`) owns the
            // message verbatim and may own the span: it knows which child of
            // a container broke, and it is writing for the document's author,
            // who does not care which hook id is registered where. Provenance
            // is not lost — the code, the `path`, and the span all still say
            // this came from lowering `(head …)`.
            if (output.cause) |c| {
                try emitDiag(gpa, diags, .lowering_hook_failed, c.span orelse hdr.head_span, &.{ hdr.head, "lowering" }, "{s}", .{c.message});
            } else {
                try emitDiag(gpa, diags, .lowering_hook_failed, hdr.head_span, &.{ hdr.head, "lowering" }, "lowering hook `{s}` on `({s} …)` returned HookFailed", .{ lowering_spec.hook, hdr.head });
            }
            return;
        },
    };

    // Step 4 — validate the emitted forest against the contract.
    var seen_violation = false;
    var totals: Totals = .{};
    for (output.forms.items) |*ef| {
        try validateEmittedForm(gpa, ef, lowering_spec, hdr.head_span, &totals, diags, &seen_violation);
    }

    // Step 5 — per-invocation bounds. Per-form nesting depth is checked
    // inside `validateEmittedForm`; total form count and byte estimate
    // land here so a single emitted root tree blowing the budget surfaces
    // once at the source.
    if (totals.form_count > Plugin.MAX_LOWERED_FORMS or totals.byte_estimate > Plugin.MAX_LOWERED_BYTES) {
        try emitDiag(gpa, diags, .lowering_output_too_large, hdr.head_span, &.{ hdr.head, "lowering" }, "lowering hook `{s}` on `({s} …)` produced {d} form(s) / ~{d} byte(s); limits are {d} / {d}", .{ lowering_spec.hook, hdr.head, totals.form_count, totals.byte_estimate, Plugin.MAX_LOWERED_FORMS, Plugin.MAX_LOWERED_BYTES });
        seen_violation = true;
    }

    // Step 6 — cumulative staging budget (the fan-out backstop). `emitted`
    // carries the running total across every staging layer; crossing
    // `budget` (normally `MAX_LOWERING_STEPS`) drops the invocation. The
    // over-count on an already-violating invocation is harmless — it only
    // trips the backstop marginally sooner.
    emitted.* += totals.form_count;
    if (emitted.* > budget) {
        try emitDiag(gpa, diags, .lowering_output_too_large, hdr.head_span, &.{ hdr.head, "lowering" }, "lowering exceeded the cumulative staging budget of {d} emitted form(s)", .{budget});
        seen_violation = true;
    }

    if (seen_violation) return;

    try invocations.append(arena, .{
        .source_form_idx = form_idx,
        .hook_id = try arena.dupe(u8, lowering_spec.hook),
        .forms = output.forms.items,
    });
}

const Totals = struct {
    form_count: usize = 0,
    byte_estimate: usize = 0,
};

/// True iff `diags` holds any err-severity diagnostic. The whole gate,
/// now that `defer_cross_refs` keeps identity questions out of the
/// fragment pass: what is left in `diags` are shape errors (missing
/// required key, wrong underlying, a head outside its set, …), and every
/// one of them means the same thing in the document as it does here.
///
/// This used to be `hasNonCrossRefError`, which excused three cross-ref
/// codes by name. See `lowerOneForm`'s step 1 for why the exclusion moved
/// into the validator and became one flag.
fn hasError(diags: []const Ast.Diagnostic) bool {
    for (diags) |d| if (d.severity == .err) return true;
    return false;
}

/// Validate one emitted form tree against the hook's contract: every
/// emitted form's head must be in `:produces` and its per-form *nesting*
/// must not exceed `Plugin.MAX_LOWERED_DEPTH` (distinct from the
/// staging-layer depth) — *wherever* the form is attached (positional
/// child, kvpair value, or vector element; kvpairs and vectors are
/// transparent to the depth count). The running form/byte totals feed
/// the per-invocation bounds check. Iterative (one explicit stack over
/// forms and their nested values) — no host-stack recursion.
///
/// An emitted form whose own `FormSpec` is lowerable is NOT a violation:
/// staging lowers it in the next layer. (The retired
/// `lowering_produced_lowerable_head` check lived here in single-pass v1.)
fn validateEmittedForm(
    gpa: Allocator,
    ef_root: *const EmittedForm,
    lowering_spec: *const Plugin.LoweringSpec,
    source_span: Ast.Span,
    totals: *Totals,
    diags: *std.ArrayList(Ast.Diagnostic),
    seen_violation: *bool,
) Allocator.Error!void {
    // One explicit stack over both forms and the values nested inside them.
    // Every `.form` — wherever it sits (positional child, kvpair value, or
    // vector element, at any nesting) — is framed and gets the identical
    // head-in-produces + depth contract check exactly once. `depth` counts
    // *form* nesting; kvpairs and vectors are transparent to it (a form one
    // level down is `depth + 1` regardless of how it is attached). Byte
    // totals accrue on whichever frame owns each byte — form heads + kvpair
    // keys on the form frame, scalar payloads on the value frame — so the
    // running totals match the earlier form-only stack plus recursive
    // byte-walker exactly, minus that walker's unbounded host-stack recursion.
    //
    // `vec_depth` is the second, independent axis: vectors are transparent to
    // *form* depth, and nested vectors add nothing to `byte_estimate` (only
    // strings count), so a hook emitting `[[[[…]]]]` passes every other
    // contract check — then `emitValueIntoTree` descends it one host-stack
    // frame per level. Bounding it here kills hostile shapes at the contract
    // check, which is what lets the emit walk stay recursive.
    const Frame = union(enum) {
        form: struct { ef: *const EmittedForm, depth: usize },
        value: struct { v: *const EmittedValue, depth: usize, vec_depth: usize = 0 },
    };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{ .form = .{ .ef = ef_root, .depth = 1 } });

    while (stack.pop()) |fr| switch (fr) {
        .form => |ff| {
            const ef = ff.ef;
            totals.form_count += 1;
            totals.byte_estimate += ef.head.len;

            // Over-depth: count the node, surface the violation, but don't
            // descend (matches the early-return the recursive walk did).
            if (ff.depth > Plugin.MAX_LOWERED_DEPTH) {
                try emitDiag(gpa, diags, .lowering_output_too_large, source_span, &.{ ef.head, "lowering" }, "lowering output exceeds depth limit {d}", .{Plugin.MAX_LOWERED_DEPTH});
                seen_violation.* = true;
                continue;
            }

            if (!headInProduces(ef.head, lowering_spec.produces)) {
                try emitDiag(gpa, diags, .lowering_produced_invalid_head, source_span, &.{ ef.head, "lowering", "produces" }, "lowering produced form head `{s}` which is not in :produces", .{ef.head});
                seen_violation.* = true;
            }
            // Shape of the head itself, independent of `:produces`: a
            // head that *is* listed can still be `""`, `x/` or `/x` — the
            // lexer accepts `/` anywhere in a symbol and a Zig-built
            // Plugin lists whatever it likes. `emitFormIntoTree` asserts
            // both halves are non-empty, so this is where hook output
            // becomes a diagnostic instead of an abort.
            if (!Plugin.headHalvesNonEmpty(ef.head)) {
                try emitDiag(gpa, diags, .lowering_produced_invalid_head, source_span, &.{ ef.head, "lowering", "produces" }, "lowering produced form head `{s}` with an empty name or namespace half", .{ef.head});
                seen_violation.* = true;
            }

            // Positional children first, then kvpair values on top, each
            // pushed in reverse so the pop order is kvpair values then
            // positional children, both in document order — the pre-order the
            // recursive walk produced. Nested forms are framed at `depth + 1`.
            // Index the arena-stable slices so the framed pointers stay valid.
            var c = ef.children.len;
            while (c > 0) {
                c -= 1;
                try stack.append(gpa, .{ .value = .{ .v = &ef.children[c], .depth = ff.depth + 1 } });
            }
            var k = ef.kvpairs.len;
            while (k > 0) {
                k -= 1;
                totals.byte_estimate += ef.kvpairs[k].key.len;
                try stack.append(gpa, .{ .value = .{ .v = &ef.kvpairs[k].value, .depth = ff.depth + 1 } });
            }
        },
        .value => |vf| switch (vf.v.*) {
            .number, .boolean, .nil => {},
            .string, .symbol, .keyword => |s| totals.byte_estimate += s.len,
            // Vectors are transparent to form depth: elements inherit the
            // vector value's depth. They are NOT transparent to `vec_depth` —
            // that is the axis bounding the emit walk's recursion. Push in
            // reverse for document order.
            .vector => |xs| {
                if (vf.vec_depth + 1 > Plugin.MAX_LOWERED_VECTOR_DEPTH) {
                    try emitDiag(gpa, diags, .lowering_output_too_large, source_span, &.{ ef_root.head, "lowering" }, "lowering output exceeds vector depth limit {d}", .{Plugin.MAX_LOWERED_VECTOR_DEPTH});
                    seen_violation.* = true;
                    continue;
                }
                var i = xs.len;
                while (i > 0) {
                    i -= 1;
                    try stack.append(gpa, .{ .value = .{ .v = &xs[i], .depth = vf.depth, .vec_depth = vf.vec_depth + 1 } });
                }
            },
            // A form reached through a kvpair value or vector element is
            // checked exactly like a positional-child form — the whole point
            // of the unified stack.
            .form => |*child_form| try stack.append(gpa, .{ .form = .{ .ef = child_form, .depth = vf.depth } }),
        },
    };
}

fn headInProduces(head: []const u8, produces: []const []const u8) bool {
    for (produces) |p| if (std.mem.eql(u8, p, head)) return true;
    return false;
}

fn emitDiag(
    gpa: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    code: Ast.Diagnostic.Code,
    span: Ast.Span,
    path_parts: []const []const u8,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    // Positional adapter over `Ast.Diagnostic.appendOwned` — nine call
    // sites in this module pass the same five things in the same order,
    // and reading them as prose is worth one forwarding function. The
    // leak-safe allocation sequence lives there, once.
    return Ast.Diagnostic.appendOwned(
        gpa,
        diags,
        .{ .code = code, .span = span, .path_parts = path_parts },
        fmt,
        args,
    );
}

// ---------------------------------------------------------------------------
// Lowered tree construction + re-validation.
//
// `buildLoweredTree` converts the Invocation list from `runLoweringPass`
// into a real `Ast.Tree` whose roots are the emitted forms. Every
// synthesized node carries the source form's span, so diagnostics on
// the lowered tree point back at author bytes — a property serialize+
// reparse can't preserve. The form-level `LoweringProvenance` side-
// table records (lowered_form, source_form, hook_id) per emitted root.
// ---------------------------------------------------------------------------

/// Owned bundle produced by `buildLoweredTree`. The provenance entries
/// live in the same arena as the tree; `deinit` releases both.
pub const LoweredTree = struct {
    tree: Ast.Tree,
    provenance: LoweringProvenance,

    pub fn deinit(self: *LoweredTree) void {
        self.tree.deinit();
    }
};

/// Build an `Ast.Tree` whose roots are every form emitted by every
/// invocation. The tree owns its own arena; provenance entries live
/// on that arena.
///
/// Empty input (no invocations) returns a tree with `root.len == 0` —
/// downstream code that revalidates with a zero-root tree gets back
/// an empty diagnostic stream, matching "nothing to revalidate".
pub fn buildLoweredTree(
    gpa: Allocator,
    invocations: []const Invocation,
    source_tree: *const Ast.Tree,
) Allocator.Error!LoweredTree {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var b: Ast.TreeBuilder = .{ .a = arena.allocator() };

    var roots: std.ArrayList(Ast.NodeIndex) = .empty;
    var prov_entries: std.ArrayList(LoweringProvenance.Entry) = .empty;

    for (invocations) |inv| {
        const src_span = source_tree.spanOf(inv.source_form_idx);
        const hook_id_dup = try arena.allocator().dupe(u8, inv.hook_id);

        for (inv.forms) |*ef| {
            const idx = try emitFormIntoTree(&b, ef, src_span);
            try roots.append(arena.allocator(), idx);
            try prov_entries.append(arena.allocator(), .{
                .lowered_form_idx = idx,
                .source_form_idx = inv.source_form_idx,
                .hook_id = hook_id_dup,
            });
        }
    }

    const roots_slice = try roots.toOwnedSlice(arena.allocator());
    const prov_slice = try prov_entries.toOwnedSlice(arena.allocator());

    const tree = try b.finalize(&arena, "", roots_slice);

    return .{
        .tree = tree,
        .provenance = .{ .entries = prov_slice },
    };
}

/// Materialize one emitted form into the lowered tree.
///
/// Mutually recursive with `emitValueIntoTree` on the host stack. Bounded
/// recursion (the `docs/zig-discipline.md` carve-out), not a frame-stack
/// walk: both axes are capped before this runs. `validateEmittedForm` is
/// the gate — `seen_violation` short-circuits the invocation before it can
/// reach `invocations`, so anything materialized here has already passed
/// `Plugin.MAX_LOWERED_DEPTH` on the form axis and
/// `Plugin.MAX_LOWERED_VECTOR_DEPTH` on the vector axis. Worst-case depth is
/// their product.
fn emitFormIntoTree(
    b: *Ast.TreeBuilder,
    ef: *const EmittedForm,
    src_span: Ast.Span,
) Allocator.Error!Ast.NodeIndex {
    // Hook contract: every emitted form carries a non-empty head.
    // `validateEmittedForm` ran first and dropped the whole invocation
    // on an empty head or half (`Plugin.headHalvesNonEmpty`), so these asserts
    // are on an invariant it established, not on hook output.
    std.debug.assert(ef.head.len > 0);

    // A hook may name the bytes this form came from; the invocation's source
    // span is the default and covers the subtree from here down.
    const span = ef.source_span orelse src_span;
    std.debug.assert(span.end >= span.start); // pre: a well-formed span

    // Resolve namespace splitting on the head ("pngine/shader" → ("pngine", "shader")).
    var head_ns: ?[]const u8 = null;
    var head_name: []const u8 = ef.head;
    if (std.mem.indexOfScalar(u8, ef.head, '/')) |slash| {
        head_ns = ef.head[0..slash];
        head_name = ef.head[slash + 1 ..];
    }
    // Both halves non-empty — established by `validateEmittedForm`.
    std.debug.assert(head_name.len > 0);
    if (head_ns) |ns| std.debug.assert(ns.len > 0);

    var children: std.ArrayList(Ast.NodeIndex) = .empty;

    for (ef.kvpairs) |kv| {
        const value_idx = try emitValueIntoTree(b, kv.value, span, ef);
        const kv_idx = try b.appendKvpair(kv.key, value_idx, span, span);
        try children.append(b.a, kv_idx);
    }

    // Positional children follow the kvpairs verbatim — a `.form` arm
    // recurses into a nested form, every scalar arm becomes a bare atom.
    // `emitValueIntoTree` already materializes every `EmittedValue` shape
    // (including `.form`), so positionals and kvpair values share one path.
    for (ef.children) |child| {
        const cidx = try emitValueIntoTree(b, child, span, ef);
        try children.append(b.a, cidx);
    }

    return b.appendForm(head_name, head_ns, span, children.items, span);
}

/// Materialize one emitted value. See `emitFormIntoTree` for the recursion
/// bound the two share: the `.vector` arm below descends the axis capped by
/// `Plugin.MAX_LOWERED_VECTOR_DEPTH`, the `.form` arm the one capped by
/// `Plugin.MAX_LOWERED_DEPTH`.
fn emitValueIntoTree(
    b: *Ast.TreeBuilder,
    v: EmittedValue,
    src_span: Ast.Span,
    parent: *const EmittedForm,
) Allocator.Error!Ast.NodeIndex {
    return switch (v) {
        .number => |n| try b.appendNumber(n, src_span),
        .string => |s| try b.appendString(s, src_span),
        .symbol => |s| try b.appendSymbol(s, src_span),
        .keyword => |s| try b.appendKeyword(s, src_span),
        .boolean => |x| try b.appendBoolean(x, src_span),
        .nil => try b.appendNil(src_span),
        .vector => |xs| blk: {
            var elems: std.ArrayList(Ast.NodeIndex) = .empty;
            for (xs) |x| {
                const ei = try emitValueIntoTree(b, x, src_span, parent);
                try elems.append(b.a, ei);
            }
            break :blk try b.appendVector(elems.items, src_span);
        },
        .form => |ef| try emitFormIntoTree(b, &ef, src_span),
    };
}

/// Re-run the validator over a lowered tree using the same schema +
/// overlay as the source-tree pass. Diagnostics surface standard
/// codes (`wrong_underlying`, `unknown_form`, etc.) — the
/// `phase = .validation` stamp is applied by the caller via
/// `wrapDiagnostic`. This is just `Validator.validateWithOptions`
/// over the lowered tree, exposed as a public helper so the host
/// pipeline reads as a linear sequence of passes.
pub fn revalidateLowered(
    gpa: Allocator,
    lowered_tree: Ast.Tree,
    schema: Schema.Schema,
    materialized: *const MaterializedDefaults.MaterializedDefaults,
    axes: Validator.EffectiveAxes,
) Allocator.Error!Validator.Result {
    return Validator.validateWithOptions(gpa, lowered_tree, schema, .{
        .overlay = materialized,
        .axes = axes,
    });
}

// ---------------------------------------------------------------------------
// Tests — registry surface only. The pass driver and tree builder land
// in commits 3 and 4.
// ---------------------------------------------------------------------------

fn dummyLowerOk(
    _: Allocator,
    _: *const LoweringInput,
    _: *LoweringOutput,
) LoweringError!void {}

fn dummyLowerFail(
    _: Allocator,
    _: *const LoweringInput,
    _: *LoweringOutput,
) LoweringError!void {
    return LoweringError.HookFailed;
}

test "LoweringRegistry: register then lookup returns the hook" {
    var registry: LoweringRegistry = .{};
    defer registry.deinit(testing.allocator);

    try registry.register(testing.allocator, .{ .id = "test/identity-v1", .lower = dummyLowerOk });

    const got = registry.lookup("test/identity-v1") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("test/identity-v1", got.id);
    try testing.expect(got.lower == dummyLowerOk);
}

test "LoweringRegistry: lookup of unknown id returns null" {
    var registry: LoweringRegistry = .{};
    defer registry.deinit(testing.allocator);
    try testing.expect(registry.lookup("missing/v1") == null);
}

test "LoweringRegistry: duplicate registration returns DuplicateHook" {
    var registry: LoweringRegistry = .{};
    defer registry.deinit(testing.allocator);

    try registry.register(testing.allocator, .{ .id = "h/v1", .lower = dummyLowerOk });
    try testing.expectError(
        RegisterError.DuplicateHook,
        registry.register(testing.allocator, .{ .id = "h/v1", .lower = dummyLowerFail }),
    );

    // The first registration must still resolve.
    const got = registry.lookup("h/v1") orelse return error.TestUnexpectedNull;
    try testing.expect(got.lower == dummyLowerOk);
}

test "LoweringRegistry: multiple distinct hooks coexist" {
    var registry: LoweringRegistry = .{};
    defer registry.deinit(testing.allocator);

    try registry.register(testing.allocator, .{ .id = "a/v1", .lower = dummyLowerOk });
    try registry.register(testing.allocator, .{ .id = "b/v1", .lower = dummyLowerFail });

    const a = registry.lookup("a/v1") orelse return error.TestUnexpectedNull;
    const b = registry.lookup("b/v1") orelse return error.TestUnexpectedNull;
    try testing.expect(a.lower == dummyLowerOk);
    try testing.expect(b.lower == dummyLowerFail);
}

test "LoweringRegistry: a hook's ctx is stored verbatim and defaults to null" {
    var registry: LoweringRegistry = .{};
    defer registry.deinit(testing.allocator);

    var state: u32 = 0;
    try registry.register(testing.allocator, .{ .id = "with/v1", .lower = dummyLowerOk, .ctx = &state });
    try registry.register(testing.allocator, .{ .id = "without/v1", .lower = dummyLowerOk });

    const with = registry.lookup("with/v1") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&state)), with.ctx);
    const without = registry.lookup("without/v1") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(?*anyopaque, null), without.ctx);
}

test "LoweringRegistry: deinit on empty registry is safe" {
    var registry: LoweringRegistry = .{};
    registry.deinit(testing.allocator);
}

test "LoweringProvenance: lookup returns entry by lowered idx" {
    const entries = [_]LoweringProvenance.Entry{
        .{
            .lowered_form_idx = Ast.NodeIndex.from(0),
            .source_form_idx = Ast.NodeIndex.from(7),
            .hook_id = "test/identity-v1",
        },
        .{
            .lowered_form_idx = Ast.NodeIndex.from(3),
            .source_form_idx = Ast.NodeIndex.from(9),
            .hook_id = "test/identity-v1",
        },
    };
    const prov: LoweringProvenance = .{ .entries = entries[0..] };

    const hit = prov.lookup(Ast.NodeIndex.from(3)) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(Ast.NodeIndex.from(9), hit.source_form_idx);
    try testing.expectEqualStrings("test/identity-v1", hit.hook_id);

    try testing.expect(prov.lookup(Ast.NodeIndex.from(42)) == null);
}

// ---------------------------------------------------------------------------
// Pass driver tests — exercise each branch of `runLoweringPass` via a
// hand-rolled inline schema (built directly from Plugin descriptors,
// not via ManifestLoader, so the tests don't depend on parser output
// for the schema half).
// ---------------------------------------------------------------------------

/// Test hook: emit one form named `<input_head>-normal` carrying any
/// kvpairs the author wrote on the input form (copied verbatim).
fn identityRenameHook(
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
) LoweringError!void {
    const new_head = try std.fmt.allocPrint(arena, "{s}-normal", .{input.head});

    // Copy author kvpairs by reading them through the EffectiveView.
    var kvpairs: std.ArrayList(EmittedKvpair) = .empty;
    for (input.form_spec.keys) |key| {
        const ev = input.view.getEffectiveValue(input.form_idx, key.name) orelse continue;
        const value = effectiveValueToEmitted(arena, input.view.tree, ev) catch return LoweringError.HookFailed;
        try kvpairs.append(arena, .{ .key = try arena.dupe(u8, key.name), .value = value });
    }

    try out.append(arena, .{
        .head = new_head,
        .kvpairs = try kvpairs.toOwnedSlice(arena),
        .children = &.{},
        .source_form_idx = input.form_idx,
    });
}

fn effectiveValueToEmitted(
    arena: Allocator,
    tree: *const Ast.Tree,
    ev: EffectiveViewMod.EffectiveValue,
) !EmittedValue {
    return switch (ev) {
        .author => |idx| astNodeToEmitted(arena, tree, idx),
        .default => |entry| exprValueToEmitted(arena, entry.value),
    };
}

fn astNodeToEmitted(arena: Allocator, tree: *const Ast.Tree, idx: Ast.NodeIndex) !EmittedValue {
    return switch (tree.tagOf(idx)) {
        .number, .number_i64, .number_u64 => .{ .number = tree.numberOf(idx) },
        .boolean_true => .{ .boolean = true },
        .boolean_false => .{ .boolean = false },
        .nil => .nil,
        .string => .{ .string = try arena.dupe(u8, tree.stringText(idx)) },
        .symbol => .{ .symbol = try arena.dupe(u8, tree.symbolText(idx)) },
        else => error.HookFailed,
    };
}

fn exprValueToEmitted(arena: Allocator, v: anytype) !EmittedValue {
    return switch (v) {
        .number => .{ .number = v.number },
        // EmittedValue.number is f64; lossy-collapse integer variants
        // at the lowering boundary. Lowering authors that need exact
        // bits can emit `.symbol` / `.string` instead.
        .integer_i64 => .{ .number = @as(f64, @floatFromInt(v.integer_i64)) },
        .integer_u64 => .{ .number = @as(f64, @floatFromInt(v.integer_u64)) },
        .boolean => .{ .boolean = v.boolean },
        .nil => .nil,
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        .keyword => |k| .{ .keyword = try arena.dupe(u8, k) },
        else => error.HookFailed,
    };
}

fn failingHook(
    _: Allocator,
    _: *const LoweringInput,
    _: *LoweringOutput,
) LoweringError!void {
    return LoweringError.HookFailed;
}

/// Asks the layer for its reference index twice and does nothing with it.
/// The ask is the point: one index serves every hook in a layer, however
/// many of them call and however often each one does.
fn indexAskingHook(
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
) LoweringError!void {
    _ = try input.layerIndex();
    _ = try input.layerIndex();
    try out.append(arena, .{ .head = "sugar-normal", .source_form_idx = input.form_idx });
}

/// Fails the way a hook should once it has something to say: one call, the
/// message formatted from what the hook actually knows.
fn explainingHook(
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
) LoweringError!void {
    return out.fail(arena, "`{s}` needs {d} of them, not {d}", .{ input.head, 3, 1 });
}

/// Blames the exact node it read rather than the form it was called on — the
/// `failAt` arm, and what a container hook needs to point at one child.
fn childBlamingHook(
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
) LoweringError!void {
    const tree = input.view.tree;
    for (tree.formHeader(input.form_idx).children) |child| {
        if (tree.tagOf(child) != .kvpair) continue;
        const kv = tree.kvpairHeader(child);
        return out.failAt(arena, tree.spanOf(kv.value), "`:{s}` is not usable here", .{kv.key});
    }
    return out.fail(arena, "`{s}` has nothing to read", .{input.head});
}

/// Hook that emits a deeply-nested vector to exceed depth or byte limits
/// depending on caller wiring.
fn explosionHook(
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
) LoweringError!void {
    // 17-deep nested children — over MAX_LOWERED_DEPTH = 16.
    var current: EmittedForm = .{
        .head = "sugar-normal",
        .kvpairs = &.{},
        .children = &.{},
        .source_form_idx = input.form_idx,
    };
    var i: usize = 0;
    while (i < 17) : (i += 1) {
        const wrapper = try arena.alloc(EmittedValue, 1);
        wrapper[0] = .{ .form = current };
        current = .{
            .head = "sugar-normal",
            .kvpairs = &.{},
            .children = wrapper,
            .source_form_idx = input.form_idx,
        };
    }
    try out.append(arena, current);
}

/// Hook that emits a form whose single child is a vector nested past
/// `MAX_LOWERED_VECTOR_DEPTH`, with nothing else wrong: one form (depth 1),
/// no strings, no disallowed head. Vectors are transparent to *form* depth
/// and contribute nothing to `byte_estimate`, so before the vector axis was
/// bounded this passed every contract check and then drove
/// `emitValueIntoTree` one host-stack frame per level.
fn deepVectorHook(
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
) LoweringError!void {
    var current: EmittedValue = .{ .number = 1 };
    var i: usize = 0;
    while (i < Plugin.MAX_LOWERED_VECTOR_DEPTH + 1) : (i += 1) {
        const wrapper = try arena.alloc(EmittedValue, 1);
        wrapper[0] = current;
        current = .{ .vector = wrapper };
    }
    const children = try arena.alloc(EmittedValue, 1);
    children[0] = current;
    try out.append(arena, .{
        .head = "sugar-normal",
        .kvpairs = &.{},
        .children = children,
        .source_form_idx = input.form_idx,
    });
}

/// Emits a well-declared `sugar-normal` form carrying, as the *value* of a
/// `:slot` kvpair, a nested form whose head `smuggled` is NOT in `:produces`.
/// The positional-child path is covered by `identityRenameHook`; a form
/// reached only through a kvpair value must be `:produces`-checked identically.
fn kvpairFormHook(
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
) LoweringError!void {
    const kvpairs = try arena.alloc(EmittedKvpair, 1);
    kvpairs[0] = .{
        .key = "slot",
        .value = .{ .form = .{
            .head = "smuggled",
            .source_form_idx = input.form_idx,
        } },
    };
    try out.append(arena, .{
        .head = "sugar-normal",
        .kvpairs = kvpairs,
        .source_form_idx = input.form_idx,
    });
}

/// Emits a well-declared `sugar-normal` form with a positional *vector* child
/// whose sole element is a nested form with the undeclared head `smuggled`.
/// Same bypass class as `kvpairFormHook`, reached through a vector element.
fn vectorFormHook(
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
) LoweringError!void {
    const elems = try arena.alloc(EmittedValue, 1);
    elems[0] = .{ .form = .{
        .head = "smuggled",
        .source_form_idx = input.form_idx,
    } };
    const children = try arena.alloc(EmittedValue, 1);
    children[0] = .{ .vector = elems };
    try out.append(arena, .{
        .head = "sugar-normal",
        .children = children,
        .source_form_idx = input.form_idx,
    });
}

/// Emits five flat `sugar-normal` forms — enough to overshoot a small
/// cumulative budget passed to `runLoweringPassBudgeted` without tripping
/// the per-invocation form (1024) or nesting-depth (16) caps. Used to
/// exercise the fan-out backstop directly.
fn manyFlatFormsHook(
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
) LoweringError!void {
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try out.append(arena, .{
            .head = "sugar-normal",
            .source_form_idx = input.form_idx,
        });
    }
}

const TestSchemaSetup = struct {
    plugin: Plugin.Plugin,
    schema: Schema.Schema,
};

/// Build a tiny schema: one sugar form with :lowering, one normal form
/// (the produces target). No defaults, no validation rules beyond the
/// declared key set. Every slice lives on the caller's `plugin_arena`.
fn buildSchema(
    plugin_arena: *std.heap.ArenaAllocator,
    sugar_keys: []const Plugin.KeySpec,
    normal_keys: []const Plugin.KeySpec,
    hook_id: []const u8,
    produces: []const []const u8,
    sugar_open: bool,
    normal_open: bool,
) !TestSchemaSetup {
    const a = plugin_arena.allocator();

    const sugar_keys_dup = try a.dupe(Plugin.KeySpec, sugar_keys);
    const normal_keys_dup = try a.dupe(Plugin.KeySpec, normal_keys);
    const produces_dup = try a.alloc([]const u8, produces.len);
    for (produces, 0..) |p, i| produces_dup[i] = try a.dupe(u8, p);

    const forms = try a.alloc(Plugin.FormSpec, 2);
    forms[0] = .{
        .name = try a.dupe(u8, "sugar"),
        .keys = sugar_keys_dup,
        .open = sugar_open,
        .lowering = .{
            .hook = try a.dupe(u8, hook_id),
            .produces = produces_dup,
        },
    };
    forms[1] = .{
        .name = try a.dupe(u8, "sugar-normal"),
        .keys = normal_keys_dup,
        .open = normal_open,
    };

    const plugin: Plugin.Plugin = .{
        .name = try a.dupe(u8, "tp"),
        .forms = forms,
    };
    const plugins_slice = try a.alloc(Plugin.Plugin, 1);
    plugins_slice[0] = plugin;

    return .{ .plugin = plugin, .schema = .{ .plugins = plugins_slice } };
}

test "runLoweringPass: missing hook emits lowering_hook_missing" {
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    const setup = try buildSchema(
        &plugin_arena,
        &.{},
        &.{},
        "missing/v1",
        &.{"sugar-normal"},
        true,
        true,
    );

    var tree = try Parser.parse(gpa, "(sugar :a 1)");
    defer tree.deinit();
    const data_forest = tree.root;

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, data_forest, setup.schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), pr.invocations.len);
    try testing.expectEqual(@as(usize, 1), pr.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.lowering_hook_missing, pr.diagnostics[0].code);
    try testing.expectEqual(@as(usize, 2), pr.diagnostics[0].path.len);
    try testing.expectEqualStrings("sugar", pr.diagnostics[0].path[0]);
    try testing.expectEqualStrings("lowering", pr.diagnostics[0].path[1]);
}

test "runLoweringPass: hook failure emits lowering_hook_failed" {
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    const setup = try buildSchema(
        &plugin_arena,
        &.{},
        &.{},
        "fail/v1",
        &.{"sugar-normal"},
        true,
        true,
    );

    var tree = try Parser.parse(gpa, "(sugar :a 1)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "fail/v1", .lower = failingHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), pr.invocations.len);
    try testing.expectEqual(@as(usize, 1), pr.diagnostics.len);
    try testing.expectEqual(Ast.Diagnostic.Code.lowering_hook_failed, pr.diagnostics[0].code);
    // A hook that says nothing still gets the generic message at the head
    // span — pinned so the `cause` arm below cannot quietly become the only
    // behaviour, and so a host that never opts in sees no change at all.
    try testing.expectEqualStrings(
        "lowering hook `fail/v1` on `(sugar …)` returned HookFailed",
        pr.diagnostics[0].message,
    );
    try testing.expectEqual(tree.formHeader(tree.root[0]).head_span.start, pr.diagnostics[0].span.start);
}

/// Host state for the ctx test: the hook counts its invocations on it.
const CtxState = struct { calls: usize = 0 };

/// Reads its registered ctx, records the call, then lowers exactly as
/// `identityRenameHook` does.
fn ctxCountingHook(
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
) LoweringError!void {
    const state: *CtxState = @ptrCast(@alignCast(input.ctx.?));
    state.calls += 1;
    return identityRenameHook(arena, input, out);
}

test "runLoweringPass: the hook receives its registered ctx on LoweringInput" {
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    const setup = try buildSchema(&plugin_arena, &.{}, &.{}, "ctx/v1", &.{"sugar-normal"}, true, true);

    var tree = try Parser.parse(gpa, "(sugar :a 1) (sugar :a 2)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var state: CtxState = .{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "ctx/v1", .lower = ctxCountingHook, .ctx = &state });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), pr.invocations.len);
    try testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    // Two forms, one hook, one state: the pointer reached the hook both
    // times, and it is the host's own, not a per-invocation copy.
    try testing.expectEqual(@as(usize, 2), state.calls);
}

test "runLoweringPass: a hook's cause replaces the generic message" {
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    const setup = try buildSchema(&plugin_arena, &.{}, &.{}, "fail/v1", &.{"sugar-normal"}, true, true);

    var tree = try Parser.parse(gpa, "(sugar :a 1)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "fail/v1", .lower = explainingHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), pr.invocations.len);
    try testing.expectEqual(@as(usize, 1), pr.diagnostics.len);
    // Same code and same path — only the human-facing text changes, so a
    // conformance consumer keying on `lowering_hook_failed` is unaffected.
    try testing.expectEqual(Ast.Diagnostic.Code.lowering_hook_failed, pr.diagnostics[0].code);
    try testing.expectEqualStrings("sugar", pr.diagnostics[0].path[0]);
    try testing.expectEqualStrings("lowering", pr.diagnostics[0].path[1]);
    try testing.expectEqualStrings("`sugar` needs 3 of them, not 1", pr.diagnostics[0].message);
    // No span supplied → still the form head.
    try testing.expectEqual(tree.formHeader(tree.root[0]).head_span.start, pr.diagnostics[0].span.start);
}

test "runLoweringPass: failAt moves the diagnostic off the form's head" {
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    const setup = try buildSchema(&plugin_arena, &.{}, &.{}, "fail/v1", &.{"sugar-normal"}, true, true);

    // What broke is inside the form, not the form itself — the case a
    // container hook faces on every one of its children.
    var tree = try Parser.parse(gpa, "(sugar :a 1)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "fail/v1", .lower = childBlamingHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), pr.diagnostics.len);
    try testing.expectEqualStrings("`:a` is not usable here", pr.diagnostics[0].message);

    // The span is the node the hook read, strictly past the head it would
    // otherwise have been pinned to — the difference this arm exists for.
    const form = tree.root[0];
    const kv = tree.kvpairHeader(tree.formHeader(form).children[0]);
    try testing.expectEqual(tree.spanOf(kv.value).start, pr.diagnostics[0].span.start);
    try testing.expect(pr.diagnostics[0].span.start > tree.formHeader(form).head_span.start);
}

fn emptyHalfHeadHook(
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
) LoweringError!void {
    // Emits the first `:produces` entry verbatim — the test lists `x/`,
    // a head the lexer and a Zig-built Plugin both admit.
    try out.append(arena, .{
        .head = input.lowering_spec.produces[0],
        .kvpairs = &.{},
        .children = &.{},
        .source_form_idx = input.form_idx,
    });
}

test "runLoweringPass: a produced head with an empty half is a diagnostic, not an assert" {
    // `x/` is in :produces, so `headInProduces` passes; before the halves
    // check `emitFormIntoTree` asserted `head_name.len > 0` on hook
    // output and aborted the host.
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    for ([_][]const u8{ "x/", "/x", "" }) |bad| {
        const setup = try buildSchema(&plugin_arena, &.{}, &.{}, "test/empty-half-v1", &.{bad}, true, true);
        var tree = try Parser.parse(gpa, "(sugar :a 1)");
        defer tree.deinit();
        const overlay = MaterializedDefaults.MaterializedDefaults{};
        var registry: LoweringRegistry = .{};
        defer registry.deinit(gpa);
        try registry.register(gpa, .{ .id = "test/empty-half-v1", .lower = emptyHalfHeadHook });
        var pass_arena = std.heap.ArenaAllocator.init(gpa);
        defer pass_arena.deinit();

        var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{});
        defer pr.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), pr.invocations.len);
        var saw = false;
        for (pr.diagnostics) |d| {
            if (d.code == .lowering_produced_invalid_head) saw = true;
        }
        try testing.expect(saw);
    }
}

test "runLoweringPass: invalid produced head emits lowering_produced_invalid_head" {
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    // Hook will emit `sugar-normal` but :produces lists only `something-else`.
    const setup = try buildSchema(
        &plugin_arena,
        &.{},
        &.{},
        "test/identity-v1",
        &.{"something-else"},
        true,
        true,
    );

    var tree = try Parser.parse(gpa, "(sugar :a 1)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), pr.invocations.len);
    try testing.expect(pr.diagnostics.len >= 1);
    try testing.expectEqual(Ast.Diagnostic.Code.lowering_produced_invalid_head, pr.diagnostics[0].code);
    try testing.expectEqual(@as(usize, 3), pr.diagnostics[0].path.len);
    try testing.expectEqualStrings("sugar-normal", pr.diagnostics[0].path[0]);
    try testing.expectEqualStrings("lowering", pr.diagnostics[0].path[1]);
    try testing.expectEqualStrings("produces", pr.diagnostics[0].path[2]);
}

test "runLoweringPass: kvpair-value form head is checked against :produces" {
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    // :produces lists `sugar-normal` (the outer head) but NOT `smuggled`
    // (the head the hook hides inside a `:slot` kvpair value). A form reached
    // through a kvpair value must be flagged exactly like a positional child.
    const setup = try buildSchema(
        &plugin_arena,
        &.{},
        &.{},
        "kvform/v1",
        &.{"sugar-normal"},
        true,
        true,
    );

    var tree = try Parser.parse(gpa, "(sugar)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "kvform/v1", .lower = kvpairFormHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    // The contract violation drops the invocation and flags `smuggled` with
    // the same code + path a positional child would get.
    try testing.expectEqual(@as(usize, 0), pr.invocations.len);
    var saw: ?Ast.Diagnostic = null;
    for (pr.diagnostics) |d| {
        if (d.code == .lowering_produced_invalid_head) saw = d;
    }
    try testing.expect(saw != null);
    try testing.expectEqual(@as(usize, 3), saw.?.path.len);
    try testing.expectEqualStrings("smuggled", saw.?.path[0]);
    try testing.expectEqualStrings("lowering", saw.?.path[1]);
    try testing.expectEqualStrings("produces", saw.?.path[2]);
}

test "runLoweringPass: vector-element form head is checked against :produces" {
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    // Same undeclared `smuggled` head, this time inside a positional vector.
    const setup = try buildSchema(
        &plugin_arena,
        &.{},
        &.{},
        "vecform/v1",
        &.{"sugar-normal"},
        true,
        true,
    );

    var tree = try Parser.parse(gpa, "(sugar)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "vecform/v1", .lower = vectorFormHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), pr.invocations.len);
    var saw: ?Ast.Diagnostic = null;
    for (pr.diagnostics) |d| {
        if (d.code == .lowering_produced_invalid_head) saw = d;
    }
    try testing.expect(saw != null);
    try testing.expectEqual(@as(usize, 3), saw.?.path.len);
    try testing.expectEqualStrings("smuggled", saw.?.path[0]);
    try testing.expectEqualStrings("lowering", saw.?.path[1]);
    try testing.expectEqualStrings("produces", saw.?.path[2]);
}

test "runLoweringPass: depth limit triggers lowering_output_too_large" {
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    const setup = try buildSchema(
        &plugin_arena,
        &.{},
        &.{},
        "explode/v1",
        &.{"sugar-normal"},
        true,
        true,
    );

    var tree = try Parser.parse(gpa, "(sugar)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "explode/v1", .lower = explosionHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), pr.invocations.len);
    var saw_too_large = false;
    for (pr.diagnostics) |d| {
        if (d.code == .lowering_output_too_large) saw_too_large = true;
    }
    try testing.expect(saw_too_large);
}

test "lowering: vector nesting past MAX_LOWERED_VECTOR_DEPTH trips lowering_output_too_large" {
    // The form axis was bounded; the vector axis was not. A hook emitting
    // one shallow form whose child is a 17-deep vector cleared every check —
    // vectors are transparent to form depth and add nothing to the byte
    // estimate — and then `emitValueIntoTree` recursed once per level on the
    // host stack. This is the sibling of the depth-17 `explosionHook` test on
    // the other axis.
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    const setup = try buildSchema(
        &plugin_arena,
        &.{},
        &.{},
        "deepvec/v1",
        &.{"sugar-normal"},
        true,
        true,
    );

    var tree = try Parser.parse(gpa, "(sugar)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "deepvec/v1", .lower = deepVectorHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    // Dropped at the contract check, so nothing reaches the emit walk.
    try testing.expectEqual(@as(usize, 0), pr.invocations.len);
    var saw_too_large = false;
    for (pr.diagnostics) |d| {
        if (d.code == .lowering_output_too_large) saw_too_large = true;
    }
    try testing.expect(saw_too_large);
}

test "runLoweringPassBudgeted: cumulative emitted-form budget trips lowering_output_too_large" {
    // The fan-out backstop: a hook emitting 5 flat forms overshoots a
    // budget of 2, so the invocation is dropped with lowering_output_too_large.
    // Neither the per-invocation form cap (1024) nor the nesting-depth cap
    // (16) fires — only the cumulative staging budget. The host threads one
    // such counter across all layers; here a single pass suffices to trip it.
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    const setup = try buildSchema(
        &plugin_arena,
        &.{},
        &.{},
        "many/v1",
        &.{"sugar-normal"},
        true,
        true,
    );

    var tree = try Parser.parse(gpa, "(sugar)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "many/v1", .lower = manyFlatFormsHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    const empty_env: Expr.Env = .{};
    var emitted: usize = 0;
    var pr = try runLoweringPassBudgeted(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{}, &empty_env, &emitted, 2);
    defer pr.deinit(gpa);

    // Invocation dropped (budget exceeded); diagnostic surfaced.
    try testing.expectEqual(@as(usize, 0), pr.invocations.len);
    var saw_too_large = false;
    for (pr.diagnostics) |d| {
        if (d.code == .lowering_output_too_large) saw_too_large = true;
    }
    try testing.expect(saw_too_large);

    // A budget at/above the emitted count admits the invocation.
    var emitted_ok: usize = 0;
    var pr_ok = try runLoweringPassBudgeted(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{}, &empty_env, &emitted_ok, 1000);
    defer pr_ok.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), pr_ok.invocations.len);
    try testing.expectEqual(@as(usize, 0), pr_ok.diagnostics.len);
}

test "runLoweringPass: empty registry — no invocations, no diagnostics" {
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    // No form has :lowering — explicit shape via raw FormSpec.
    const a = plugin_arena.allocator();
    const forms = try a.alloc(Plugin.FormSpec, 1);
    forms[0] = .{ .name = "sugar", .open = true };
    const plugins_slice = try a.alloc(Plugin.Plugin, 1);
    plugins_slice[0] = .{ .name = "tp", .forms = forms };
    const schema: Schema.Schema = .{ .plugins = plugins_slice };

    var tree = try Parser.parse(gpa, "(sugar :a 1)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), pr.invocations.len);
    try testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
}

// ---------------------------------------------------------------------------
// `resolveRef` — a hook resolving a cross-reference key to the form it names
// (`docs/plans/asks/18-*.md`). The fixture is the ask's own four-form
// manifest, built as descriptors so these tests do not depend on the loader.
// ---------------------------------------------------------------------------

/// Resolve `:from` and emit `(sugar-normal :count N)`, where N is the
/// *neighbour's* `:count` read through the same view the hook reads itself
/// with. `-1` is "resolved nowhere in this layer", which is a miss and not a
/// failure — the distinction the whole bound rests on.
fn resolveCountHook(
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
) LoweringError!void {
    try emitNeighbourCount(arena, input, out, try input.resolveRef("from"));
}

/// The same, through a `(union-shape …)` slot — the shape
/// `(scalar-or-ref-shape :ref …)` desugars to.
fn resolveUnionCountHook(
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
) LoweringError!void {
    try emitNeighbourCount(arena, input, out, try input.resolveRef("either"));
}

/// Asks a number key for a cross-reference. The hook-bug arm: nothing about
/// the document decides this, so it is a failure rather than a miss.
fn resolveWrongKeyHook(
    _: Allocator,
    input: *const LoweringInput,
    _: *LoweringOutput,
) LoweringError!void {
    _ = try input.resolveRef("size");
}

fn emitNeighbourCount(
    arena: Allocator,
    input: *const LoweringInput,
    out: *LoweringOutput,
    target: ?Ast.NodeIndex,
) LoweringError!void {
    var count: f64 = -1;
    if (target) |idx| {
        count = switch (input.view.getEffectiveValue(idx, "count") orelse return error.HookFailed) {
            .author => |n| input.view.tree.numberOf(n),
            .default => |entry| valueToF64(entry.value) orelse return error.HookFailed,
        };
    }
    const kvpairs = try arena.alloc(EmittedKvpair, 1);
    kvpairs[0] = .{ .key = "count", .value = .{ .number = count } };
    try out.append(arena, .{
        .head = "sugar-normal",
        .kvpairs = kvpairs,
        .source_form_idx = input.form_idx,
    });
}

const RefFixture = struct {
    const producer: Plugin.FormSpec = .{ .name = "producer", .keys = &.{
        .{ .name = "name", .value_type = .symbol },
        .{ .name = "count", .value_type = .number },
    } };
    /// Same form with `:count` declared rather than written — the row where
    /// the neighbour's value comes off the overlay.
    const defaulted_producer: Plugin.FormSpec = .{ .name = "producer", .keys = &.{
        .{ .name = "name", .value_type = .symbol },
        .{ .name = "count", .value_type = .number, .default = .{ .number = 24000 } },
    } };
    const other: Plugin.FormSpec = .{ .name = "other", .keys = &.{
        .{ .name = "name", .value_type = .symbol },
        .{ .name = "count", .value_type = .number },
    } };
    /// Scope opener for the `:scope` row; open so it takes the vocabulary as
    /// positional children.
    const piece: Plugin.FormSpec = .{ .name = "piece", .open = true };
    const consumer: Plugin.FormSpec = .{
        .name = "consumer",
        .keys = &.{
            .{ .name = "from", .value_type = .{ .named = .{ .name = "producer-ref" } } },
            .{ .name = "either", .value_type = .{ .named = .{ .name = "count-or-ref" } } },
            .{ .name = "size", .value_type = .number },
        },
        .lowering = .{ .hook = "test/resolve-v1", .produces = &.{"sugar-normal"} },
    };
    const sugar_normal: Plugin.FormSpec = .{ .name = "sugar-normal", .open = true };

    fn schema(comptime cr: Plugin.ValueKind.CrossRef, comptime prod: Plugin.FormSpec) Schema.Schema {
        return Schema.Schema.init(&.{.{
            .name = "t",
            .value_kinds = &.{
                .{ .name = "producer-ref", .underlying = .symbol, .cross_ref = cr },
                .{ .name = "plain-count", .underlying = .number },
                .{ .name = "count-or-ref", .underlying = .union_of, .union_of = .{
                    .alternatives = &.{ .{ .name = "plain-count" }, .{ .name = "producer-ref" } },
                } },
            },
            .forms = &.{ prod, other, piece, consumer, sugar_normal },
        }});
    }

    const flat: Plugin.ValueKind.CrossRef = .{ .targets = &.{"producer"} };
    const grouped: Plugin.ValueKind.CrossRef = .{ .targets = &.{ "producer", "other" } };
    const scoped: Plugin.ValueKind.CrossRef = .{ .targets = &.{"producer"}, .scope_form = "piece" };
};

/// Run one lowering layer over `src` with `hook` registered as
/// `test/resolve-v1`, appending the `:count` every invocation emitted — the
/// hook's report of what `resolveRef` handed it, in document order. Returns
/// whether any `lowering_hook_failed` fired.
fn runRefLayer(
    gpa: Allocator,
    schema: Schema.Schema,
    src: [:0]const u8,
    hook: HookFn,
    counts: *std.ArrayList(f64),
) !bool {
    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();
    const a = pass_arena.allocator();

    var mat = try MaterializedDefaults.materializeDefaults(gpa, a, &tree, tree.root, schema);
    defer mat.deinit(gpa);

    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/resolve-v1", .lower = hook });

    var pr = try runLoweringPass(gpa, a, &tree, tree.root, schema, &mat.materialized, &registry, .{});
    defer pr.deinit(gpa);

    for (pr.invocations) |inv| {
        for (inv.forms) |f| {
            for (f.kvpairs) |kv| {
                if (std.mem.eql(u8, kv.key, "count")) try counts.append(gpa, kv.value.number);
            }
        }
    }
    for (pr.diagnostics) |d| {
        if (d.code == .lowering_hook_failed) return true;
    }
    return false;
}

test "resolveRef: a hook reads a sibling two references away" {
    const gpa = testing.allocator;
    var counts: std.ArrayList(f64) = .empty;
    defer counts.deinit(gpa);

    const failed = try runRefLayer(
        gpa,
        RefFixture.schema(RefFixture.flat, RefFixture.producer),
        "(producer :name a :count 7)\n(consumer :from a)",
        resolveCountHook,
        &counts,
    );
    try testing.expect(!failed);
    try testing.expectEqualSlices(f64, &.{7}, counts.items);
}

test "resolveRef: the neighbour's defaulted value arrives through the overlay" {
    const gpa = testing.allocator;
    var counts: std.ArrayList(f64) = .empty;
    defer counts.deinit(gpa);

    // The hook does nothing special: `getEffectiveValue` on the resolved
    // index is the same read it makes on its own form.
    const failed = try runRefLayer(
        gpa,
        RefFixture.schema(RefFixture.flat, RefFixture.defaulted_producer),
        "(producer :name a)\n(consumer :from a)",
        resolveCountHook,
        &counts,
    );
    try testing.expect(!failed);
    try testing.expectEqualSlices(f64, &.{24000}, counts.items);
}

test "resolveRef: a name nothing defines, and an absent key, are both misses" {
    const gpa = testing.allocator;
    const schema = RefFixture.schema(RefFixture.flat, RefFixture.producer);

    var miss: std.ArrayList(f64) = .empty;
    defer miss.deinit(gpa);
    try testing.expect(!try runRefLayer(gpa, schema, "(producer :name a :count 7)\n(consumer :from nowhere)", resolveCountHook, &miss));
    try testing.expectEqualSlices(f64, &.{-1}, miss.items);

    var absent: std.ArrayList(f64) = .empty;
    defer absent.deinit(gpa);
    try testing.expect(!try runRefLayer(gpa, schema, "(producer :name a :count 7)\n(consumer)", resolveCountHook, &absent));
    try testing.expectEqualSlices(f64, &.{-1}, absent.items);
}

test "resolveRef: a key whose type carries no cross-reference is a hook bug" {
    const gpa = testing.allocator;
    var counts: std.ArrayList(f64) = .empty;
    defer counts.deinit(gpa);

    // `:size` is a number. Nothing about the document decides this, so it
    // fails the hook rather than reading as "resolved nowhere".
    const failed = try runRefLayer(
        gpa,
        RefFixture.schema(RefFixture.flat, RefFixture.producer),
        "(consumer :size 3)",
        resolveWrongKeyHook,
        &counts,
    );
    try testing.expect(failed);
    try testing.expectEqual(@as(usize, 0), counts.items.len);
}

test "resolveRef: a multi-target cross-ref resolves in its shared bucket" {
    const gpa = testing.allocator;
    var counts: std.ArrayList(f64) = .empty;
    defer counts.deinit(gpa);

    // The hook names one key and gets either head — it never spells the
    // target set, which is what keeps S4b's grouping out of hook code.
    const failed = try runRefLayer(
        gpa,
        RefFixture.schema(RefFixture.grouped, RefFixture.producer),
        "(producer :name a :count 7)\n(other :name b :count 9)\n(consumer :from b)",
        resolveCountHook,
        &counts,
    );
    try testing.expect(!failed);
    try testing.expectEqualSlices(f64, &.{9}, counts.items);
}

test "resolveRef: a scoped cross-ref resolves inside its scope and nowhere else" {
    const gpa = testing.allocator;
    var counts: std.ArrayList(f64) = .empty;
    defer counts.deinit(gpa);

    // Same name, same schema, two positions: inside the `(piece …)` that
    // defines it, and outside every piece. A scan over the roots would
    // answer 7 to both.
    const failed = try runRefLayer(
        gpa,
        RefFixture.schema(RefFixture.scoped, RefFixture.producer),
        "(piece (producer :name a :count 7) (consumer :from a))\n(consumer :from a)",
        resolveCountHook,
        &counts,
    );
    try testing.expect(!failed);
    try testing.expectEqualSlices(f64, &.{ 7, -1 }, counts.items);
}

test "resolveRef: a cross-reference reached through a union resolves" {
    const gpa = testing.allocator;
    const schema = RefFixture.schema(RefFixture.flat, RefFixture.producer);

    // `:either` is "a number or a name". The name arm resolves; the number
    // arm is not a symbol, so it is a miss and not a failure.
    var named: std.ArrayList(f64) = .empty;
    defer named.deinit(gpa);
    try testing.expect(!try runRefLayer(gpa, schema, "(producer :name a :count 7)\n(consumer :either a)", resolveUnionCountHook, &named));
    try testing.expectEqualSlices(f64, &.{7}, named.items);

    var numeric: std.ArrayList(f64) = .empty;
    defer numeric.deinit(gpa);
    try testing.expect(!try runRefLayer(gpa, schema, "(producer :name a :count 7)\n(consumer :either 5)", resolveUnionCountHook, &numeric));
    try testing.expectEqualSlices(f64, &.{-1}, numeric.items);
}

test "runLoweringPass: the layer builds one reference index for every hook that asks" {
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    const setup = try buildSchema(&plugin_arena, &.{}, &.{}, "test/asking-v1", &.{"sugar-normal"}, true, true);

    // Two lowerable forms, each hook asking twice: four asks, one build.
    var tree = try Parser.parse(gpa, "(sugar :a 1)\n(sugar :a 2)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/asking-v1", .lower = indexAskingHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), pr.invocations.len);
    try testing.expectEqual(@as(usize, 1), pr.ref_index_builds);
}

test "runLoweringPass: a layer whose hooks never ask builds no reference index" {
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    const setup = try buildSchema(&plugin_arena, &.{}, &.{}, "test/identity-v1", &.{"sugar-normal"}, true, true);

    var tree = try Parser.parse(gpa, "(sugar :a 1)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    // The hook ran — this is a pass that did work and still built nothing.
    try testing.expectEqual(@as(usize, 1), pr.invocations.len);
    try testing.expectEqual(@as(usize, 0), pr.ref_index_builds);
}

test "runLoweringPass: happy path produces one invocation" {
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    const a = plugin_arena.allocator();
    const sugar_keys = try a.alloc(Plugin.KeySpec, 1);
    sugar_keys[0] = .{ .name = "a", .value_type = .number };
    const normal_keys = try a.alloc(Plugin.KeySpec, 1);
    normal_keys[0] = .{ .name = "a", .value_type = .number };

    const setup = try buildSchema(
        &plugin_arena,
        sugar_keys,
        normal_keys,
        "test/identity-v1",
        &.{"sugar-normal"},
        false,
        false,
    );

    var tree = try Parser.parse(gpa, "(sugar :a 1)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try testing.expectEqual(@as(usize, 1), pr.invocations.len);

    const inv = pr.invocations[0];
    try testing.expectEqualStrings("test/identity-v1", inv.hook_id);
    try testing.expectEqual(@as(usize, 1), inv.forms.len);
    try testing.expectEqualStrings("sugar-normal", inv.forms[0].head);
    try testing.expectEqual(@as(usize, 1), inv.forms[0].kvpairs.len);
    try testing.expectEqualStrings("a", inv.forms[0].kvpairs[0].key);
    try testing.expectEqual(@as(f64, 1), inv.forms[0].kvpairs[0].value.number);
}

test "buildLoweredTree: emits a tree with kvpairs and inherited spans" {
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    const a = plugin_arena.allocator();
    const sugar_keys = try a.alloc(Plugin.KeySpec, 1);
    sugar_keys[0] = .{ .name = "a", .value_type = .number };
    const normal_keys = try a.alloc(Plugin.KeySpec, 1);
    normal_keys[0] = .{ .name = "a", .value_type = .number };

    const setup = try buildSchema(
        &plugin_arena,
        sugar_keys,
        normal_keys,
        "test/identity-v1",
        &.{"sugar-normal"},
        false,
        false,
    );

    var tree = try Parser.parse(gpa, "(sugar :a 1)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    var lowered = try buildLoweredTree(gpa, pr.invocations, &tree);
    defer lowered.deinit();

    try testing.expectEqual(@as(usize, 1), lowered.tree.root.len);
    const root_idx = lowered.tree.root[0];
    try testing.expectEqual(Ast.Tag.form, lowered.tree.tagOf(root_idx));

    const hdr = lowered.tree.formHeader(root_idx);
    try testing.expectEqualStrings("sugar-normal", hdr.head);
    try testing.expect(hdr.namespace == null);
    try testing.expectEqual(@as(usize, 1), hdr.children.len);

    const kv_idx = hdr.children[0];
    try testing.expectEqual(Ast.Tag.kvpair, lowered.tree.tagOf(kv_idx));
    const kvh = lowered.tree.kvpairHeader(kv_idx);
    try testing.expectEqualStrings("a", kvh.key);
    try testing.expectEqual(@as(f64, 1), lowered.tree.numberOf(kvh.value));

    // Span inherits from the source form's span.
    const source_span = tree.spanOf(tree.root[0]);
    try testing.expectEqual(source_span.start, hdr.head_span.start);
    try testing.expectEqual(source_span.end, hdr.head_span.end);
}

test "buildLoweredTree: positional atom materializes as a bare symbol child" {
    const gpa = testing.allocator;

    // The source tree only supplies a span to inherit; its shape is irrelevant
    // to the positional-atom materialization under test.
    var src = try Parser.parse(gpa, "(shader-decl)");
    defer src.deinit();

    // `(module shader)` — a head plus one bare positional symbol, the shape a
    // hook previously could not emit (children were forms-only).
    const emitted = [_]EmittedForm{.{
        .head = "module",
        .children = &.{.{ .symbol = "shader" }},
        .source_form_idx = src.root[0],
    }};
    const invocations = [_]Invocation{.{
        .source_form_idx = src.root[0],
        .hook_id = "test/synth-positional-v1",
        .forms = &emitted,
    }};

    var lowered = try buildLoweredTree(gpa, &invocations, &src);
    defer lowered.deinit();

    try testing.expectEqual(@as(usize, 1), lowered.tree.root.len);
    const root_idx = lowered.tree.root[0];
    try testing.expectEqual(Ast.Tag.form, lowered.tree.tagOf(root_idx));

    const hdr = lowered.tree.formHeader(root_idx);
    try testing.expectEqualStrings("module", hdr.head);
    try testing.expectEqual(@as(usize, 1), hdr.children.len);

    // The lone child is a bare positional symbol — not a kvpair, not a form.
    const child_idx = hdr.children[0];
    try testing.expectEqual(Ast.Tag.symbol, lowered.tree.tagOf(child_idx));
    try testing.expectEqualStrings("shader", lowered.tree.symbolText(child_idx));
}

test "buildLoweredTree: provenance maps lowered → source" {
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    const setup = try buildSchema(
        &plugin_arena,
        &.{},
        &.{},
        "test/identity-v1",
        &.{"sugar-normal"},
        true,
        true,
    );

    var tree = try Parser.parse(gpa, "(sugar)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    var lowered = try buildLoweredTree(gpa, pr.invocations, &tree);
    defer lowered.deinit();

    try testing.expectEqual(@as(usize, 1), lowered.provenance.entries.len);
    const e = lowered.provenance.entries[0];
    try testing.expectEqualStrings("test/identity-v1", e.hook_id);
    try testing.expectEqual(tree.root[0], e.source_form_idx);
    try testing.expectEqual(lowered.tree.root[0], e.lowered_form_idx);

    const hit = lowered.provenance.lookup(lowered.tree.root[0]) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(tree.root[0], hit.source_form_idx);
}

test "revalidateLowered: standard diagnostics surface on a broken hook" {
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    const a = plugin_arena.allocator();
    // sugar declares `:a :type number`; sugar-normal declares `:a :type
    // string`. The identity hook copies the author number into the
    // normal form, where the type clash surfaces as wrong_underlying.
    const sugar_keys = try a.alloc(Plugin.KeySpec, 1);
    sugar_keys[0] = .{ .name = "a", .value_type = .number };
    const normal_keys = try a.alloc(Plugin.KeySpec, 1);
    normal_keys[0] = .{ .name = "a", .value_type = .string };

    const setup = try buildSchema(
        &plugin_arena,
        sugar_keys,
        normal_keys,
        "test/identity-v1",
        &.{"sugar-normal"},
        false,
        false,
    );

    var tree = try Parser.parse(gpa, "(sugar :a 1)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    var lowered = try buildLoweredTree(gpa, pr.invocations, &tree);
    defer lowered.deinit();

    var rv = try revalidateLowered(gpa, lowered.tree, setup.schema, &overlay, .{});
    defer rv.deinit();

    var saw_wrong_underlying = false;
    for (rv.diagnostics) |d| {
        if (d.code == .wrong_underlying) saw_wrong_underlying = true;
    }
    try testing.expect(saw_wrong_underlying);
}

// --- EmittedForm.source_span: a lifted child names its own bytes ------------
//
// `buildLoweredTree` reads one span per invocation and stamps it on every form
// that invocation emits, which is right for sugar: the container authored the
// bytes. A *container* hook that lifts a child out of its own subtree wants
// the other answer, or the nested spelling's diagnostics collapse onto the
// enclosing block and read worse than the flat spelling it replaces.

/// `(space :name poster (text :name letters))` — the shape a container hook
/// flattens. Returns the parsed tree; `root[0]` is the container and its last
/// positional child is the `text` the author wrote on its own.
fn parseContainerDoc(gpa: Allocator) !Ast.Tree {
    return Parser.parse(gpa, "(space :name poster (text :name letters))");
}

fn lastChildOf(tree: *const Ast.Tree, form: Ast.NodeIndex) Ast.NodeIndex {
    const hdr = tree.formHeader(form);
    return hdr.children[hdr.children.len - 1];
}

test "buildLoweredTree: a null source_span keeps the container's span" {
    // The default, and the byte-identical baseline every existing hook is on:
    // the lifted `text` reports against the whole `(space …)` block.
    const gpa = testing.allocator;
    var src = try parseContainerDoc(gpa);
    defer src.deinit();

    const emitted = [_]EmittedForm{.{
        .head = "text",
        .kvpairs = &.{.{ .key = "name", .value = .{ .symbol = "letters" } }},
        .source_form_idx = src.root[0],
    }};
    const invocations = [_]Invocation{.{
        .source_form_idx = src.root[0],
        .hook_id = "test/space-v1",
        .forms = &emitted,
    }};

    var lowered = try buildLoweredTree(gpa, &invocations, &src);
    defer lowered.deinit();

    const container = src.spanOf(src.root[0]);
    const hdr = lowered.tree.formHeader(lowered.tree.root[0]);
    try testing.expectEqual(container.start, hdr.head_span.start);
    try testing.expectEqual(container.end, hdr.head_span.end);
}

test "buildLoweredTree: an emitted form may name its own source span" {
    // The same emission with the child's span set: the form and its kvpairs
    // now point at `(text :name letters)`, the bytes the author typed.
    const gpa = testing.allocator;
    var src = try parseContainerDoc(gpa);
    defer src.deinit();

    const child = lastChildOf(&src, src.root[0]);
    const child_span = src.spanOf(child);

    const emitted = [_]EmittedForm{.{
        .head = "text",
        .kvpairs = &.{.{ .key = "name", .value = .{ .symbol = "letters" } }},
        .source_form_idx = src.root[0],
        .source_span = child_span,
    }};
    const invocations = [_]Invocation{.{
        .source_form_idx = src.root[0],
        .hook_id = "test/space-v1",
        .forms = &emitted,
    }};

    var lowered = try buildLoweredTree(gpa, &invocations, &src);
    defer lowered.deinit();

    const root_idx = lowered.tree.root[0];
    const hdr = lowered.tree.formHeader(root_idx);
    try testing.expectEqual(child_span.start, hdr.head_span.start);
    try testing.expectEqual(child_span.end, hdr.head_span.end);

    // The subtree follows, not just the head: a diagnostic on the kvpair
    // lands on the child too.
    const kv_span = lowered.tree.spanOf(hdr.children[0]);
    try testing.expectEqual(child_span.start, kv_span.start);

    // The override is strictly narrower than the container's span — which is
    // the whole point, and a guard against the two accidentally being equal.
    const container = src.spanOf(src.root[0]);
    try testing.expect(child_span.start > container.start);

    // Provenance is untouched: the container's hook did author this form.
    const prov = lowered.provenance.lookup(root_idx) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(src.root[0], prov.source_form_idx);
    try testing.expectEqualStrings("test/space-v1", prov.hook_id);
}

test "buildLoweredTree: a nested emitted form narrows the override further" {
    // The override covers the subtree until a descendant sets its own. Here
    // the outer emission claims the child's span and the nested one claims the
    // `:name` kvpair's, so the two do not have to agree.
    const gpa = testing.allocator;
    var src = try parseContainerDoc(gpa);
    defer src.deinit();

    const child = lastChildOf(&src, src.root[0]);
    const child_span = src.spanOf(child);
    const inner_span = src.spanOf(src.formHeader(child).children[0]);

    const nested: EmittedForm = .{
        .head = "glyph",
        .source_form_idx = src.root[0],
        .source_span = inner_span,
    };
    const emitted = [_]EmittedForm{.{
        .head = "text",
        .children = &.{.{ .form = nested }},
        .source_form_idx = src.root[0],
        .source_span = child_span,
    }};
    const invocations = [_]Invocation{.{
        .source_form_idx = src.root[0],
        .hook_id = "test/space-v1",
        .forms = &emitted,
    }};

    var lowered = try buildLoweredTree(gpa, &invocations, &src);
    defer lowered.deinit();

    const hdr = lowered.tree.formHeader(lowered.tree.root[0]);
    try testing.expectEqual(child_span.start, hdr.head_span.start);

    const inner_hdr = lowered.tree.formHeader(hdr.children[0]);
    try testing.expectEqualStrings("glyph", inner_hdr.head);
    try testing.expectEqual(inner_span.start, inner_hdr.head_span.start);
    try testing.expect(inner_span.start > child_span.start);
}

test "revalidateLowered: a set source_span reaches the diagnostic" {
    // The end of the chain, and the reason the field exists: a diagnostic
    // raised on the lowered tree points at the author's own bytes. `ghost` is
    // in no schema, so the revalidation pass reports `unknown_form` at the
    // emitted form's head span.
    const gpa = testing.allocator;
    var src = try parseContainerDoc(gpa);
    defer src.deinit();

    const child_span = src.spanOf(lastChildOf(&src, src.root[0]));

    const emitted = [_]EmittedForm{.{
        .head = "ghost",
        .source_form_idx = src.root[0],
        .source_span = child_span,
    }};
    const invocations = [_]Invocation{.{
        .source_form_idx = src.root[0],
        .hook_id = "test/space-v1",
        .forms = &emitted,
    }};

    var lowered = try buildLoweredTree(gpa, &invocations, &src);
    defer lowered.deinit();

    const plugins = [_]Plugin.Plugin{.{ .name = "p", .forms = &.{.{ .name = "text" }} }};
    const schema = Schema.Schema.init(&plugins);
    const overlay = MaterializedDefaults.MaterializedDefaults{};

    var rv = try revalidateLowered(gpa, lowered.tree, schema, &overlay, .{});
    defer rv.deinit();

    var found = false;
    for (rv.diagnostics) |d| {
        if (d.code != .unknown_form) continue;
        found = true;
        try testing.expectEqual(child_span.start, d.span.start);
        try testing.expectEqual(child_span.end, d.span.end);
    }
    try testing.expect(found);
}

test "buildLoweredTree: empty invocations yields a zero-root tree" {
    const gpa = testing.allocator;

    var source = try Parser.parse(gpa, "(form)");
    defer source.deinit();

    var lowered = try buildLoweredTree(gpa, &.{}, &source);
    defer lowered.deinit();

    try testing.expectEqual(@as(usize, 0), lowered.tree.root.len);
    try testing.expectEqual(@as(usize, 0), lowered.provenance.entries.len);
}

test "buildLoweredTree + materializeDefaults: literal default on emitted form lands in lowered overlay" {
    // Materializing defaults over the *lowered* tree yields entries keyed
    // by lowered `NodeIndex`. A literal default
    // declared on the emitted form's schema must show up in
    // `lowered.materialized.defaultFor(emitted_idx, key_name)` — the
    // source-tree overlay has no such entry because the source has no
    // instance of the emitted form.
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    const a = plugin_arena.allocator();
    const normal_keys = try a.alloc(Plugin.KeySpec, 1);
    normal_keys[0] = .{
        .name = "x",
        .value_type = .number,
        .default = .{ .number = 5 },
        .optional = true,
    };

    const setup = try buildSchema(
        &plugin_arena,
        &.{},
        normal_keys,
        "test/identity-v1",
        &.{"sugar-normal"},
        true,
        false,
    );

    var tree = try Parser.parse(gpa, "(sugar)");
    defer tree.deinit();

    const empty_overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &empty_overlay, &registry, .{});
    defer pr.deinit(gpa);

    var lowered = try buildLoweredTree(gpa, pr.invocations, &tree);
    defer lowered.deinit();

    var overlay_arena = std.heap.ArenaAllocator.init(gpa);
    defer overlay_arena.deinit();

    var lowered_mat = try MaterializedDefaults.materializeDefaults(
        gpa,
        overlay_arena.allocator(),
        &lowered.tree,
        lowered.tree.root,
        setup.schema,
    );
    defer lowered_mat.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), lowered.tree.root.len);
    const emitted_idx = lowered.tree.root[0];

    const entry = lowered_mat.materialized.defaultFor(emitted_idx, "x") orelse return error.TestUnexpectedNull;
    try testing.expect(entry.value == .number);
    try testing.expectEqual(@as(f64, 5), entry.value.number);
    try testing.expectEqual(MaterializedDefaults.Origin.literal_default, entry.origin);
}

test "runLoweringPass: emitting a lowerable head is normal under staging (lowering_produced_lowerable_head retired)" {
    // TOMBSTONE for `lowering_produced_lowerable_head`. Single-pass v1
    // rejected an emitted form whose own `FormSpec` was lowerable. Staging
    // makes that normal — the emitted form lowers in the *next* layer
    // (the host drives layers; one `runLoweringPass` is one layer). The
    // wire-stable code variant is kept (never renumbered) but no longer
    // emitted; this test references it so `audit-diagnostics` stays green
    // and documents the retirement.
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    //   - `sugar` has `:lowering` and produces `sugar-normal`.
    //   - `sugar-normal` ALSO has `:lowering` (the previously-forbidden
    //     transitive shape — now lowered in a later layer).
    const a = plugin_arena.allocator();
    const sugar_keys = try a.alloc(Plugin.KeySpec, 0);
    const normal_keys = try a.alloc(Plugin.KeySpec, 0);
    const sugar_produces = try a.alloc([]const u8, 1);
    sugar_produces[0] = "sugar-normal";
    const normal_produces = try a.alloc([]const u8, 1);
    normal_produces[0] = "sugar-final";

    const forms = try a.alloc(Plugin.FormSpec, 3);
    forms[0] = .{
        .name = "sugar",
        .keys = sugar_keys,
        .open = true,
        .lowering = .{ .hook = "test/identity-v1", .produces = sugar_produces },
    };
    forms[1] = .{
        .name = "sugar-normal",
        .keys = normal_keys,
        .open = true,
        .lowering = .{ .hook = "another/v1", .produces = normal_produces },
    };
    forms[2] = .{ .name = "sugar-final", .open = true };

    const plugins_slice = try a.alloc(Plugin.Plugin, 1);
    plugins_slice[0] = .{ .name = "tp", .forms = forms };
    const schema: Schema.Schema = .{ .plugins = plugins_slice };

    var tree = try Parser.parse(gpa, "(sugar)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    // The retired code is never emitted; the emitted `sugar-normal` is a
    // normal invocation (the host lowers it again in the next layer).
    for (pr.diagnostics) |d| {
        try testing.expect(d.code != .lowering_produced_lowerable_head);
    }
    try testing.expectEqual(@as(usize, 1), pr.invocations.len);
    try testing.expectEqualStrings("sugar-normal", pr.invocations[0].forms[0].head);
}

test "runLoweringPass: surface-validation failure skips hook silently" {
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    const a = plugin_arena.allocator();
    // sugar requires `:a` — author omits it.
    const sugar_keys = try a.alloc(Plugin.KeySpec, 1);
    sugar_keys[0] = .{ .name = "a", .value_type = .number, .optional = false };
    const normal_keys = try a.alloc(Plugin.KeySpec, 0);

    const setup = try buildSchema(
        &plugin_arena,
        sugar_keys,
        normal_keys,
        "test/identity-v1",
        &.{"sugar-normal"},
        false,
        true,
    );

    var tree = try Parser.parse(gpa, "(sugar)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, setup.schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    // Surface validation fails (missing_required_key on `:a`) — hook
    // is not invoked, and no lowering-phase diagnostic is emitted.
    // The source-tree validation pass in the host will surface the
    // underlying missing_required_key.
    try testing.expectEqual(@as(usize, 0), pr.invocations.len);
    try testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
}

// Surface validation gates on shape errors. Identity questions never
// reach it any more — the fragment pass runs with
// `Validator.Options.defer_cross_refs`, so a reference to a sibling the
// sub-tree cannot see is not a failure to begin with. What is left is
// severity, and that is all this predicate now decides.
//
// The code-filtering test that stood here retired with
// `hasNonCrossRefError`; the two below outlive it because the severity
// rule is not the thing that changed. A gate that tripped on a warning
// would skip hooks for advisories.

test "hasError: shape errors trip the gate" {
    const diags = [_]Ast.Diagnostic{.{
        .span = .{ .start = 0, .end = 0 },
        .message = "",
        .severity = .err,
        .code = .missing_required_key,
        .path = &.{},
    }};
    try testing.expect(hasError(diags[0..]));
}

test "hasError: warnings are ignored regardless of code" {
    const diags = [_]Ast.Diagnostic{.{
        .span = .{ .start = 0, .end = 0 },
        .message = "",
        .severity = .warning,
        .code = .missing_required_key,
        .path = &.{},
    }};
    try testing.expect(!hasError(diags[0..]));
}

test "lowerOneForm: cross-ref miss on sugar form does NOT suppress the hook" {
    // Schema: sugar carries a `:ref` whose value-kind is a cross-ref
    // into `target`. The single-form sub-tree surface validation
    // builds its cross-ref index over [sugar_idx] only — it never
    // sees the `(target …)` defined elsewhere in the document.
    // Without the cross-ref filter, the surface pass emits
    // `cross_ref_not_found`, `surface.hasErrors()` fires, and the
    // hook is silently skipped. With the cross-ref filter, the hook
    // still runs.
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();

    const a = plugin_arena.allocator();

    const value_kinds = try a.alloc(Plugin.ValueKind, 1);
    value_kinds[0] = .{
        .name = try a.dupe(u8, "target-ref"),
        .underlying = .symbol,
        .cross_ref = .{
            .targets = try Plugin.ValueKind.CrossRef.dupeOne(a, "target"),
            .name_key = try a.dupe(u8, "name"),
        },
    };

    const sugar_keys = try a.alloc(Plugin.KeySpec, 1);
    sugar_keys[0] = .{
        .name = try a.dupe(u8, "ref"),
        .value_type = .{ .named = .{ .name = try a.dupe(u8, "target-ref") } },
        .optional = false,
    };

    const target_keys = try a.alloc(Plugin.KeySpec, 1);
    target_keys[0] = .{
        .name = try a.dupe(u8, "name"),
        .value_type = .symbol,
        .optional = false,
    };

    const normal_keys = try a.alloc(Plugin.KeySpec, 0);

    const forms = try a.alloc(Plugin.FormSpec, 3);
    forms[0] = .{
        .name = try a.dupe(u8, "sugar"),
        .keys = sugar_keys,
        .lowering = .{
            .hook = try a.dupe(u8, "test/identity-v1"),
            .produces = blk: {
                const ps = try a.alloc([]const u8, 1);
                ps[0] = try a.dupe(u8, "sugar-normal");
                break :blk ps;
            },
        },
    };
    forms[1] = .{
        .name = try a.dupe(u8, "sugar-normal"),
        .keys = normal_keys,
        .open = true,
    };
    forms[2] = .{
        .name = try a.dupe(u8, "target"),
        .keys = target_keys,
    };

    const plugin: Plugin.Plugin = .{
        .name = try a.dupe(u8, "tp"),
        .value_kinds = value_kinds,
        .forms = forms,
    };
    const plugins_slice = try a.alloc(Plugin.Plugin, 1);
    plugins_slice[0] = plugin;
    const schema: Schema.Schema = .{ .plugins = plugins_slice };

    var tree = try Parser.parse(gpa, "(target :name t0) (sugar :ref t0)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    // Despite the surface pass emitting cross_ref_not_found on the
    // single-form sub-tree, the gate filters it out and the hook runs.
    try testing.expectEqual(@as(usize, 1), pr.invocations.len);
}

test "lowerOneForm: a union reaching a cross-ref does NOT suppress the hook" {
    // The ask (`docs/plans/asks/19-*.md`), at the layer it was reported
    // from. `box` is a container whose positional children are ordinary
    // forms, and `child`'s `:unioned` slot is `union{member-set, ref-kind}`
    // — the shape a colour attachment has when it may be either the canvas
    // or a texture. The fragment cannot resolve `t0`, both alternatives
    // fail, and the union reports `union_no_branch_matched`: a *shape* code,
    // which the retired filter list did not excuse and could not have.
    //
    // Two things this pins that the plain-`:ref` twin above does not: the
    // failure arrives through a union rather than directly, and it arrives
    // from a node one positional level below the form being lowered.
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const a = plugin_arena.allocator();

    const value_kinds = try a.alloc(Plugin.ValueKind, 4);
    value_kinds[0] = .{
        .name = try a.dupe(u8, "target-ref"),
        .underlying = .symbol,
        .cross_ref = .{
            .targets = try Plugin.ValueKind.CrossRef.dupeOne(a, "target"),
            .name_key = try a.dupe(u8, "name"),
        },
    };
    value_kinds[1] = .{
        .name = try a.dupe(u8, "spot"),
        .underlying = .symbol,
        .members = .{ .members = blk: {
            const ms = try a.alloc(Plugin.ValueKind.MemberSet.Member, 1);
            ms[0] = .{ .name = try a.dupe(u8, "here") };
            break :blk ms;
        } },
    };
    value_kinds[2] = .{
        .name = try a.dupe(u8, "spot-or-target"),
        .underlying = .union_of,
        .union_of = .{ .alternatives = blk: {
            const alts = try a.alloc(Plugin.QualifiedRef, 2);
            alts[0] = .{ .name = try a.dupe(u8, "spot") };
            alts[1] = .{ .name = try a.dupe(u8, "target-ref") };
            break :blk alts;
        } },
    };
    value_kinds[3] = .{
        .name = try a.dupe(u8, "child-item"),
        .underlying = .form,
        .heads = .{ .heads = blk: {
            const hs = try a.alloc(Plugin.ValueKind.HeadSet.Head, 1);
            hs[0] = .{ .name = try a.dupe(u8, "child") };
            break :blk hs;
        } },
    };

    const child_keys = try a.alloc(Plugin.KeySpec, 1);
    child_keys[0] = .{
        .name = try a.dupe(u8, "unioned"),
        .value_type = .{ .named = .{ .name = try a.dupe(u8, "spot-or-target") } },
        .optional = false,
    };
    const target_keys = try a.alloc(Plugin.KeySpec, 1);
    target_keys[0] = .{
        .name = try a.dupe(u8, "name"),
        .value_type = .symbol,
        .optional = false,
    };

    const forms = try a.alloc(Plugin.FormSpec, 4);
    forms[0] = .{
        .name = try a.dupe(u8, "box"),
        .keys = &.{},
        .positional = .{ .kind = .{ .name = try a.dupe(u8, "child-item") } },
        .lowering = .{
            .hook = try a.dupe(u8, "test/identity-v1"),
            .produces = blk: {
                const ps = try a.alloc([]const u8, 1);
                ps[0] = try a.dupe(u8, "box-normal");
                break :blk ps;
            },
        },
    };
    forms[1] = .{ .name = try a.dupe(u8, "box-normal"), .keys = &.{}, .open = true };
    forms[2] = .{ .name = try a.dupe(u8, "child"), .keys = child_keys };
    forms[3] = .{ .name = try a.dupe(u8, "target"), .keys = target_keys };

    const plugins_slice = try a.alloc(Plugin.Plugin, 1);
    plugins_slice[0] = .{
        .name = try a.dupe(u8, "tp"),
        .value_kinds = value_kinds,
        .forms = forms,
    };
    const schema: Schema.Schema = .{ .plugins = plugins_slice };

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    // The ref arm: `t0` is defined in a sibling the fragment cannot see.
    {
        var tree = try Parser.parse(gpa, "(target :name t0) (box (child :unioned t0))");
        defer tree.deinit();
        var pass_arena = std.heap.ArenaAllocator.init(gpa);
        defer pass_arena.deinit();
        var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &overlay, &registry, .{});
        defer pr.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), pr.invocations.len);
    }

    // The member arm, one alternative over: this always worked, because
    // the member set needs no index. Pinned so the fix cannot be read as
    // "the union now matches everything".
    {
        var tree = try Parser.parse(gpa, "(target :name t0) (box (child :unioned here))");
        defer tree.deinit();
        var pass_arena = std.heap.ArenaAllocator.init(gpa);
        defer pass_arena.deinit();
        var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &overlay, &registry, .{});
        defer pr.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), pr.invocations.len);
    }

    // And the gate still closes on a shape the fragment *can* judge: a
    // number reaches neither alternative, in the document or out of it.
    {
        var tree = try Parser.parse(gpa, "(target :name t0) (box (child :unioned 42))");
        defer tree.deinit();
        var pass_arena = std.heap.ArenaAllocator.init(gpa);
        defer pass_arena.deinit();
        var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &overlay, &registry, .{});
        defer pr.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), pr.invocations.len);
    }
}

test "runLoweringPass: lowerable child of a lowerable parent emits lowering_nested_lowerable" {
    // The one self-contradictory container setup — `:lowering` on BOTH a
    // container and a positional child. Container lowering treats children as
    // data, but a child that also declares `:lowering` fires its own hook in
    // the same layer, so both emit. The lint flags it at the child. Emit-only:
    // both hooks still run (2 invocations) and the diagnostic is additive.
    const gpa = testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const a = plugin_arena.allocator();

    const outer_produces = try a.alloc([]const u8, 1);
    outer_produces[0] = "outer-normal";
    const inner_produces = try a.alloc([]const u8, 1);
    inner_produces[0] = "inner-normal";

    // Both `outer` and `inner` are `:open true` (so `(outer (inner))` surface-
    // validates) and both declare `:lowering` — the contradiction the lint
    // exists to catch. The `-normal` terminals are the identity hook's output.
    const forms = try a.alloc(Plugin.FormSpec, 4);
    forms[0] = .{ .name = "outer", .open = true, .lowering = .{ .hook = "test/identity-v1", .produces = outer_produces } };
    forms[1] = .{ .name = "inner", .open = true, .lowering = .{ .hook = "test/identity-v1", .produces = inner_produces } };
    forms[2] = .{ .name = "outer-normal", .open = true };
    forms[3] = .{ .name = "inner-normal", .open = true };

    const plugins_slice = try a.alloc(Plugin.Plugin, 1);
    plugins_slice[0] = .{ .name = "tp", .forms = forms };
    const schema: Schema.Schema = .{ .plugins = plugins_slice };

    var tree = try Parser.parse(gpa, "(outer (inner))");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    // Exactly one nested-lowerable diagnostic, pointed at the child.
    var nested_count: usize = 0;
    var nested_idx: ?usize = null;
    for (pr.diagnostics, 0..) |d, i| {
        if (d.code == .lowering_nested_lowerable) {
            nested_count += 1;
            nested_idx = i;
        }
    }
    try testing.expectEqual(@as(usize, 1), nested_count);
    const d = pr.diagnostics[nested_idx.?];
    try testing.expectEqual(@as(usize, 2), d.path.len);
    try testing.expectEqualStrings("inner", d.path[0]);
    try testing.expectEqualStrings("lowering", d.path[1]);

    // Emit-only: the lint does not veto lowering — both hooks fired.
    try testing.expectEqual(@as(usize, 2), pr.invocations.len);
}

// ---------------------------------------------------------------------------
// Nested-lowerable lint — decision-table + ordering coverage.
//
// `checkNestedLowerable` has a wide surface: parent-lowerable × child-
// lowerable × attachment-kind (positional / kvpair-value) × multiplicity ×
// depth × namespacing, plus three guard returns (empty head, unknown head,
// non-lowerable child). The helpers below let each case read as a one-liner —
// a source string, the forms it needs, the heads expected to trip the lint in
// document order, and (optionally) how many hooks should have fired.
// ---------------------------------------------------------------------------

/// One form for `buildSchema`. `lower` makes it a `test/identity-v1` lowerer
/// (emitting `<name>-normal`); `open` is `:open true` so a sugar parent
/// surface-validates whatever children a test hangs under it.
const LowerSpec = struct { name: []const u8, lower: bool = true, open: bool = true };

/// Build a single-plugin schema from `specs`. Each lowerable spec also gets a
/// matching `<name>-normal :open true` terminal (the identity hook's output),
/// so the lowered forest validates clean and the nested-lowerable diagnostic
/// is the only thing the assertion has to account for. Allocates into `a`.
fn buildNestedSchema(a: Allocator, specs: []const LowerSpec) Allocator.Error!Schema.Schema {
    var forms: std.ArrayList(Plugin.FormSpec) = .empty;
    for (specs) |s| {
        if (s.lower) {
            const produces = try a.alloc([]const u8, 1);
            produces[0] = try std.fmt.allocPrint(a, "{s}-normal", .{s.name});
            try forms.append(a, .{ .name = s.name, .open = s.open, .lowering = .{ .hook = "test/identity-v1", .produces = produces } });
            try forms.append(a, .{ .name = produces[0], .open = true });
        } else {
            try forms.append(a, .{ .name = s.name, .open = s.open });
        }
    }
    const plugins = try a.alloc(Plugin.Plugin, 1);
    plugins[0] = .{ .name = "tp", .forms = try forms.toOwnedSlice(a) };
    return .{ .plugins = plugins };
}

/// Assert the `lowering_nested_lowerable` diagnostics in `diags` carry
/// `path[0]` equal to `expected_heads`, in emission order, and that exactly
/// that many fire (each with the canonical `[<head>, lowering]` two-part
/// path). Filtering by code keeps the order pin independent of any incidental
/// lowering diagnostics sharing the list.
fn expectNestedHeadsInOrder(diags: []const Ast.Diagnostic, expected_heads: []const []const u8) !void {
    var i: usize = 0;
    for (diags) |d| {
        if (d.code != .lowering_nested_lowerable) continue;
        if (i >= expected_heads.len) return error.TooManyNestedDiagnostics;
        try testing.expectEqual(@as(usize, 2), d.path.len);
        try testing.expectEqualStrings(expected_heads[i], d.path[0]);
        try testing.expectEqualStrings("lowering", d.path[1]);
        i += 1;
    }
    try testing.expectEqual(expected_heads.len, i);
}

/// Parse `src`, build a schema from `specs`, run the lowering pass under
/// `test/identity-v1`, and assert the nested-lowerable diagnostics match
/// `expected_heads` (document order) — and, when non-null, that
/// `expected_invocations` hooks fired (the emit-only proof). Self-contained:
/// owns every allocation it makes.
fn expectNested(
    gpa: Allocator,
    src: [:0]const u8,
    specs: []const LowerSpec,
    expected_heads: []const []const u8,
    expected_invocations: ?usize,
) !void {
    var schema_arena = std.heap.ArenaAllocator.init(gpa);
    defer schema_arena.deinit();
    const schema = try buildNestedSchema(schema_arena.allocator(), specs);

    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();
    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    try expectNestedHeadsInOrder(pr.diagnostics, expected_heads);
    if (expected_invocations) |n| try testing.expectEqual(n, pr.invocations.len);
}

test "runLoweringPass: sibling nested-lowerable diagnostics emit in document order" {
    // Three lowerable children under one lowerable parent. The forward lint
    // sweep must surface them left-to-right — `inner`, `inner2`, `inner3` —
    // the order the author wrote them, not the reverse order the worklist
    // pushes them in. Emit-only: all four hooks (parent + three children) fire.
    try expectNested(
        testing.allocator,
        "(outer (inner) (inner2) (inner3))",
        &.{ .{ .name = "outer" }, .{ .name = "inner" }, .{ .name = "inner2" }, .{ .name = "inner3" } },
        &.{ "inner", "inner2", "inner3" },
        4,
    );
}

test "runLoweringPass: deep nested-lowerable chain emits one diagnostic per level in document order" {
    // A single-child chain four deep, every form lowerable. Each level is the
    // sole child in its own descent, so document and discovery order already
    // coincide here — the pin is on the *count* (one per nested level: `b`,
    // `c`, `d`) and that depth drops none of them.
    try expectNested(
        testing.allocator,
        "(a (b (c (d))))",
        &.{ .{ .name = "a" }, .{ .name = "b" }, .{ .name = "c" }, .{ .name = "d" } },
        &.{ "b", "c", "d" },
        4,
    );
}

test "runLoweringPass: nested-lowerable across positional and kvpair-value attachment stays in document order" {
    // `outer` holds a positional lowerable `(a)` then a kvpair-value lowerable
    // `:slot (b)`. The forward sweep visits children in document order
    // regardless of attachment kind, so the diagnostics are `a` then `b` —
    // proving the kvpair-value branch of `childForm` participates in ordering.
    try expectNested(
        testing.allocator,
        "(outer (a) :slot (b))",
        &.{ .{ .name = "outer" }, .{ .name = "a" }, .{ .name = "b" } },
        &.{ "a", "b" },
        3,
    );
}

// --- Decision-table: positive paths -----------------------------------------

test "runLoweringPass: nested-lowerable via kvpair value points the span at the child head" {
    // `:slot (inner)` — the kvpair-value attachment. Beyond exercising that
    // branch (Commit 1's mixed test already does), this pins span *precision*:
    // the diagnostic must point at `inner`'s head span, not the kvpair's or the
    // parent's. emitDiag stamps `chdr.head_span`; verify it survives the trip.
    const gpa = testing.allocator;
    var schema_arena = std.heap.ArenaAllocator.init(gpa);
    defer schema_arena.deinit();
    const schema = try buildNestedSchema(schema_arena.allocator(), &.{ .{ .name = "outer" }, .{ .name = "inner" } });

    var tree = try Parser.parse(gpa, "(outer :slot (inner))");
    defer tree.deinit();

    // Find `inner`'s head span directly: outer → `:slot` kvpair → value form.
    const outer_hdr = tree.formHeader(tree.root[0]);
    var inner_head_span: ?Ast.Span = null;
    for (outer_hdr.children) |child| {
        if (tree.childForm(child)) |cf| inner_head_span = tree.formHeader(cf).head_span;
    }
    const want = inner_head_span orelse return error.TestNoInnerForm;

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();
    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    try expectNestedHeadsInOrder(pr.diagnostics, &.{"inner"});

    var checked = false;
    for (pr.diagnostics) |d| {
        if (d.code != .lowering_nested_lowerable) continue;
        try testing.expectEqual(want.start, d.span.start);
        try testing.expectEqual(want.end, d.span.end);
        checked = true;
    }
    try testing.expect(checked);
    // Emit-only: both `outer` and `inner` lowered.
    try testing.expectEqual(@as(usize, 2), pr.invocations.len);
}

test "runLoweringPass: namespaced nested-lowerable child reports a bare head path" {
    // `(outer (ns/inner))` — the child is namespace-qualified. lookupForm
    // resolves it qualified (`inner` in plugin `ns`), but the diagnostic path
    // is the *bare* head `[inner, lowering]`, never `[ns/inner, …]`. Pins the
    // path shape so a fixture author isn't caught out by the qualified source.
    const gpa = testing.allocator;
    var schema_arena = std.heap.ArenaAllocator.init(gpa);
    defer schema_arena.deinit();
    const a = schema_arena.allocator();

    // Two plugins: `outer` lives in `tp`; `inner` lives in namespace `ns`.
    const outer_produces = try a.alloc([]const u8, 1);
    outer_produces[0] = "outer-normal";
    const inner_produces = try a.alloc([]const u8, 1);
    inner_produces[0] = "inner-normal";

    const tp_forms = try a.alloc(Plugin.FormSpec, 2);
    tp_forms[0] = .{ .name = "outer", .open = true, .lowering = .{ .hook = "test/identity-v1", .produces = outer_produces } };
    tp_forms[1] = .{ .name = "outer-normal", .open = true };

    const ns_forms = try a.alloc(Plugin.FormSpec, 2);
    ns_forms[0] = .{ .name = "inner", .open = true, .lowering = .{ .hook = "test/identity-v1", .produces = inner_produces } };
    ns_forms[1] = .{ .name = "inner-normal", .open = true };

    const plugins = try a.alloc(Plugin.Plugin, 2);
    plugins[0] = .{ .name = "tp", .forms = tp_forms };
    plugins[1] = .{ .name = "ns", .forms = ns_forms };
    const schema: Schema.Schema = .{ .plugins = plugins };

    var tree = try Parser.parse(gpa, "(outer (ns/inner))");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();
    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    // Bare head path — `inner`, not `ns/inner`.
    try expectNestedHeadsInOrder(pr.diagnostics, &.{"inner"});
}

test "runLoweringPass: self-recursive lowerable head flags its own nested instance" {
    // `(node (node))` — the same lowerable head nested in itself. The lint is
    // structural (parent lowerable, child resolves to a lowering form), so a
    // self-reference trips it exactly once, at the inner `node`.
    try expectNested(testing.allocator, "(node (node))", &.{.{ .name = "node" }}, &.{"node"}, 2);
}

// --- Decision-table: negative space -----------------------------------------

test "runLoweringPass: plain parent holding a lowerable child does not trip the lint" {
    // The by-design nested-sugar shape: a *plain-data* parent (`plain`, no
    // :lowering) holding a lowerable `(inner)`. `parent_lowerable` is false, so
    // the forward sweep is skipped — no diagnostic — and the child still lowers
    // (1 invocation). This soundness guarantee is why the lint keys on the
    // parent, not just the child.
    try expectNested(testing.allocator, "(plain (inner))", &.{ .{ .name = "plain", .lower = false }, .{ .name = "inner" } }, &.{}, 1);
}

test "runLoweringPass: nested-lowerable lint is direct-parent-child, not transitive" {
    // `(a (b (c)))` with a & c lowerable but b plain in the middle. The lint
    // never fires: a's child b is not lowering (guard 3), and b — being plain —
    // is not `parent_lowerable`, so c is never checked against it. Proves the
    // lint looks one level down, not an ancestor chain. Both a and c still lower.
    try expectNested(testing.allocator, "(a (b (c)))", &.{ .{ .name = "a" }, .{ .name = "b", .lower = false }, .{ .name = "c" } }, &.{}, 2);
}

test "runLoweringPass: kvpair value that is not a form is not a nested child" {
    // `:slot "x"` — a kvpair whose value is a string, not a form. `childForm`
    // returns null, so neither the lint nor the descent treats it as a child.
    try expectNested(testing.allocator, "(outer :slot \"x\")", &.{.{ .name = "outer" }}, &.{}, 1);
}

test "runLoweringPass: unknown child head does not trip the nested-lowerable lint" {
    // `(outer (bogus))` — `bogus` resolves to no form (guard 2 in
    // checkNestedLowerable), so the lint stays silent even though the parent is
    // lowerable. Invocations are left unasserted: surface validation may gate
    // outer's hook on the unknown child, which is orthogonal to the guard.
    try expectNested(testing.allocator, "(outer (bogus))", &.{.{ .name = "outer" }}, &.{}, null);
}

// --- Slot-local resolution: the worklist mirrors the validator ---------------
//
// A form head resolves local-first at validation (S7): a bare head in a slot
// that declares locals takes the local body, shadowing a same-named global.
// The worklist must resolve the same way, or a local `entry` under
// `bind-group` fires the hook of a global lowerable `entry` it never meant.
// Both carriers, the qualified bypass, and the nested-lowerable lint.

/// Schema for the shadowing tests: a global lowerable `entry` (identity hook →
/// `entry-normal`), a `bind-group` whose positional local `entry` and keyed
/// local (`:layout`) `entry` shadow it, and a lowerable `outer` carrying the
/// same positional local. Everything `:open` so surface validation never
/// gates a hook.
fn shadowSchema(a: Allocator) !Schema.Schema {
    const entry_produces = try a.alloc([]const u8, 1);
    entry_produces[0] = "entry-normal";
    const outer_produces = try a.alloc([]const u8, 1);
    outer_produces[0] = "outer-normal";

    const local_entry = try a.alloc(Plugin.FormSpec, 1);
    local_entry[0] = .{ .name = "entry", .open = true };
    const layout_key = try a.alloc(Plugin.KeySpec, 1);
    layout_key[0] = .{ .name = "layout", .value_type = .form, .local_forms = local_entry };

    const forms = try a.alloc(Plugin.FormSpec, 5);
    forms[0] = .{ .name = "entry", .open = true, .lowering = .{ .hook = "test/identity-v1", .produces = entry_produces } };
    forms[1] = .{ .name = "entry-normal", .open = true };
    forms[2] = .{ .name = "bind-group", .open = true, .positional = .any, .local_forms = local_entry, .keys = layout_key };
    forms[3] = .{ .name = "outer", .open = true, .positional = .any, .local_forms = local_entry, .lowering = .{ .hook = "test/identity-v1", .produces = outer_produces } };
    forms[4] = .{ .name = "outer-normal", .open = true };

    const plugins = try a.alloc(Plugin.Plugin, 1);
    plugins[0] = .{ .name = "p", .forms = forms };
    return .{ .plugins = plugins };
}

fn runShadow(gpa: Allocator, src: [:0]const u8, expected_invocations: usize, expected_nested: []const []const u8) !void {
    var schema_arena = std.heap.ArenaAllocator.init(gpa);
    defer schema_arena.deinit();
    const schema = try shadowSchema(schema_arena.allocator());

    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();
    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    try testing.expectEqual(expected_invocations, pr.invocations.len);
    try expectNestedHeadsInOrder(pr.diagnostics, expected_nested);
}

test "runLoweringPass: a global lowerable head lowers at the root (control)" {
    // `(entry)` at the root has no registry in scope: the global lowerable
    // `entry` resolves and its hook fires once.
    try runShadow(testing.allocator, "(entry)", 1, &.{});
}

test "runLoweringPass: an authored positional local that shadows a global lowerable head does not lower" {
    // `(bind-group (entry))` — `entry` is `bind-group`'s positional local, so
    // it resolves to the local body (never a hook). Before the worklist
    // resolved local-first this fired the global `entry`'s hook on it.
    try runShadow(testing.allocator, "(bind-group (entry))", 0, &.{});
}

test "runLoweringPass: an authored keyed local that shadows a global lowerable head does not lower" {
    // The keyed carrier: `(bind-group :layout (entry))` — `:layout` declares
    // the local `entry`, so the kvpair-value form resolves to it.
    try runShadow(testing.allocator, "(bind-group :layout (entry))", 0, &.{});
}

test "runLoweringPass: a qualified head bypasses the slot's locals and lowers the global" {
    // `(bind-group (p/entry))` — the qualified spelling bypasses locals, as
    // it does at the site, so the global lowerable `entry` fires.
    try runShadow(testing.allocator, "(bind-group (p/entry))", 1, &.{});
}

test "runLoweringPass: a local under a slot with no matching local falls back to the global" {
    // `(bind-group (other))` where `other` is nobody's local: the registry is
    // in scope but does not match, so resolution falls through to the global
    // catalog (which has no `other` either) — nothing lowers, nothing lints.
    try runShadow(testing.allocator, "(bind-group (other))", 0, &.{});
}

test "runLoweringPass: nested-lowerable lint ignores a local that shadows a global lowerable head" {
    // `(outer (entry))` — `outer` is lowerable AND declares the positional
    // local `entry`. The child resolves to the local, which never lowers, so
    // it is not a nested-lowerable: one invocation (`outer`), no lint.
    try runShadow(testing.allocator, "(outer (entry))", 1, &.{});
}

test "runLoweringPass: nested-lowerable lint still fires for a qualified child that names the global" {
    // The lint's control: `(outer (p/entry))` bypasses the local, resolves
    // the global lowerable `entry`, and both fire — flagged at `entry`.
    try runShadow(testing.allocator, "(outer (p/entry))", 2, &.{"entry"});
}

// --- A container whose children share its head (ask 22) ---------------------
//
// The shadow family above pins a lowerable container over a local that
// shadows a *different* global lowerable head (`(outer (entry))`). The case a
// host actually asks for is the container shadowing **its own** head: a
// `space` that may hold spaces, lowered by one invocation that walks the whole
// subtree itself. That needs no `:consumes` declaration — the head is a
// slot-local of the form that declares it, so `checkNestedLowerable` returns
// on the local hit and the worklist resolves the child to a body that can
// never lower.

/// A lowerable `space` (identity hook → `space-normal`) that declares the
/// positional slot-local `space`, plus the plain `text` a nested space holds.
/// The local is its own `FormSpec`: same name, no `:lowering`, and it may
/// legitimately differ from the global — which is the point of the spelling.
fn containerSchema(a: Allocator) !Schema.Schema {
    const space_produces = try a.alloc([]const u8, 1);
    space_produces[0] = "space-normal";

    // Two levels of local `space`, so `(space (space (space …)))` resolves
    // local-first all the way down instead of falling back to the global at
    // the third level.
    const inner_local = try a.alloc(Plugin.FormSpec, 1);
    inner_local[0] = .{ .name = "space", .open = true, .positional = .any };
    const local_space = try a.alloc(Plugin.FormSpec, 1);
    local_space[0] = .{ .name = "space", .open = true, .positional = .any, .local_forms = inner_local };

    const forms = try a.alloc(Plugin.FormSpec, 3);
    forms[0] = .{ .name = "space", .open = true, .positional = .any, .local_forms = local_space, .lowering = .{ .hook = "test/identity-v1", .produces = space_produces } };
    forms[1] = .{ .name = "space-normal", .open = true };
    forms[2] = .{ .name = "text", .open = true, .positional = .any };

    const plugins = try a.alloc(Plugin.Plugin, 1);
    plugins[0] = .{ .name = "p", .forms = forms };
    return .{ .plugins = plugins };
}

fn runContainer(gpa: Allocator, src: [:0]const u8, expected_invocations: usize, expected_nested: []const []const u8) !void {
    var schema_arena = std.heap.ArenaAllocator.init(gpa);
    defer schema_arena.deinit();
    const schema = try containerSchema(schema_arena.allocator());

    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();
    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    try testing.expectEqual(expected_invocations, pr.invocations.len);
    try expectNestedHeadsInOrder(pr.diagnostics, expected_nested);
}

test "runLoweringPass: a container consumes children of its own head" {
    // The ask's shape. `(space (space (text)))`: the outer `space` resolves
    // globally and lowers; the inner one resolves to the container's own
    // positional local, which never lowers, so it is data the container's hook
    // walks. One invocation, no `lowering_nested_lowerable`. This is what
    // `:consumes [space]` was asked for and it needs no manifest grammar.
    try runContainer(testing.allocator, "(space (space (text)))", 1, &.{});
}

test "runLoweringPass: a container's own-head local shadows at every nesting level" {
    // Three levels. The local `space` declares a local `space` of its own, so
    // `childLocalRegistry` hands each level exactly its parent's locals and the
    // shadow holds all the way down — which is why the ask's "transitive
    // :consumes" question is moot: the hook walks its own subtree.
    try runContainer(testing.allocator, "(space (space (space (text))))", 1, &.{});
}

test "runLoweringPass: a qualified child bypasses the container's own-head local" {
    // The control for the two above. `(space (p/space))` spells the head
    // qualified, which bypasses locals at the site and here too: the global
    // lowerable `space` resolves, both hooks fire, and the child is flagged.
    try runContainer(testing.allocator, "(space (p/space))", 2, &.{"space"});
}

// --- Variant-key locals: in scope only while the variant is active ----------
//
// A key declared on a `(variant …)` is accepted by the validator only under
// the active variant, discriminant first (or with the discriminant omitted
// and defaulted, under axis D). Its `local_forms` are in scope exactly then
// (`Validator.zig`'s "variant-key locals (dual)" tests); the worklist decides
// the same way through `matchKvpairKeys`, so a local that shadows a global
// lowerable head shadows it only where the validator would resolve the local.

/// A global lowerable `entry` and a discriminated `thing` (`:kind` ∈ {a, b},
/// defaulting to `a`) whose variant `a` declares `:extra` (form, local
/// `entry`); variant `b` declares nothing. Everything `:open`.
fn variantShadowSchema(a: Allocator) !Schema.Schema {
    const entry_produces = try a.alloc([]const u8, 1);
    entry_produces[0] = "entry-normal";
    const local_entry = try a.alloc(Plugin.FormSpec, 1);
    local_entry[0] = .{ .name = "entry", .open = true };
    const a_keys = try a.alloc(Plugin.KeySpec, 1);
    a_keys[0] = .{ .name = "extra", .value_type = .form, .optional = true, .local_forms = local_entry };
    const variants = try a.alloc(Plugin.Variant, 2);
    variants[0] = .{ .when = &.{"a"}, .keys = a_keys };
    variants[1] = .{ .when = &.{"b"} };
    const thing_keys = try a.alloc(Plugin.KeySpec, 2);
    thing_keys[0] = .{ .name = "kind", .value_type = .{ .named = .{ .name = "k" } }, .optional = false, .default = .{ .symbol = "a" } };
    // A slot the schema declines to interpret. Nothing about it is
    // variant-scoped: opacity is the key's, not the variant's.
    thing_keys[1] = .{ .name = "sealed", .value_type = .any, .optional = true, .walk_opaque = true };

    const forms = try a.alloc(Plugin.FormSpec, 3);
    forms[0] = .{ .name = "entry", .open = true, .lowering = .{ .hook = "test/identity-v1", .produces = entry_produces } };
    forms[1] = .{ .name = "entry-normal", .open = true };
    forms[2] = .{ .name = "thing", .open = true, .keys = thing_keys, .discriminant_name = "kind", .discriminant_idx = 0, .variants = variants };
    const kinds = try a.alloc(Plugin.ValueKind, 1);
    kinds[0] = .{ .name = "k", .underlying = .symbol, .members = .{ .members = &.{ .{ .name = "a" }, .{ .name = "b" } } } };
    const plugins = try a.alloc(Plugin.Plugin, 1);
    plugins[0] = .{ .name = "p", .forms = forms, .value_kinds = kinds };
    return .{ .plugins = plugins };
}

/// Run `src` through the pass with the schema's *materialized* overlay (so
/// an omitted `:kind` carries its default) under `axes`, and count hook
/// invocations: 0 = the local `entry` shadowed the global; 1 = it fired.
fn runVariantShadow(gpa: Allocator, src: [:0]const u8, axes: Validator.EffectiveAxes, expected_invocations: usize) !void {
    var schema_arena = std.heap.ArenaAllocator.init(gpa);
    defer schema_arena.deinit();
    const schema = try variantShadowSchema(schema_arena.allocator());

    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();
    var mat = try MaterializedDefaults.materializeDefaults(gpa, pass_arena.allocator(), &tree, tree.root, schema);
    defer mat.deinit(gpa);

    var registry: LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, .{ .id = "test/identity-v1", .lower = identityRenameHook });

    var pr = try runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &mat.materialized, &registry, axes);
    defer pr.deinit(gpa);
    try testing.expectEqual(expected_invocations, pr.invocations.len);
}

test "runLoweringPass: a local on the active variant's key shadows the global lowerable" {
    try runVariantShadow(testing.allocator, "(thing :kind a :extra (entry))", .{}, 0);
}

test "runLoweringPass: a local on an inactive variant's key is not in scope — the global fires" {
    // `:extra` belongs to variant `a`; with `b` active the validator rejects
    // the key and resolves `(entry)` globally, so the worklist does too.
    try runVariantShadow(testing.allocator, "(thing :kind b :extra (entry))", .{}, 1);
}

test "runLoweringPass: a variant key ahead of the discriminant is not in scope — the global fires" {
    // The position rule: discriminant first. `:extra` here precedes `:kind a`.
    try runVariantShadow(testing.allocator, "(thing :extra (entry) :kind a)", .{}, 1);
}

test "runLoweringPass: an omitted discriminant with an overlay default selects the variant (axis D)" {
    // `:kind` defaults to `a`; with axis D on the validator pre-resolves
    // variant `a`, accepts `:extra`, and resolves `(entry)` locally.
    try runVariantShadow(testing.allocator, "(thing :extra (entry))", .{}, 0);
    // With axis D off the omitted discriminant selects nothing.
    try runVariantShadow(testing.allocator, "(thing :extra (entry))", .{ .variant = false }, 1);
}

test "runLoweringPass: a walk_opaque slot's contents are not lowered" {
    // `(entry)` is a lowerable form, and in any ordinary slot its hook
    // fires. In `:sealed` it does not: the validator will not descend
    // there, so rewriting it would edit a subtree nothing then checks.
    try runVariantShadow(testing.allocator, "(thing :sealed (entry))", .{}, 0);
    // Control, one key over: the same value in a slot the schema reads.
    try runVariantShadow(testing.allocator, "(thing :kind b :extra (entry))", .{}, 1);
}
