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
/// Memory: the registry copies neither the `id` slice nor the function
/// pointer. Hosts construct hooks with string-literal ids (or arena-
/// owned ids whose lifetime exceeds the registry's).
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
    /// Host-supplied evaluation environment. `numberEval` resolves any
    /// free variable in an author expression against it (e.g. a
    /// `workgroup-size` constant the embedder injects). Defaults empty for
    /// every caller that doesn't opt in (`runLoweringPass`), so an
    /// expression with a free variable then fails the hook rather than
    /// resolving — the env is the only thing that makes it load-bearing.
    env: *const Expr.Env,

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
pub const LoweringProvenance = struct {
    entries: []const Entry = &.{},

    pub const Entry = struct {
        lowered_form_idx: Ast.NodeIndex,
        source_form_idx: Ast.NodeIndex,
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

    const view = EffectiveView.init(tree, materialized);

    // Iterative pre-order walk over the forest — replaces host recursion
    // with an explicit worklist (frame-stack discipline, matching the
    // other walkers). Children are pushed in reverse so siblings pop
    // left-to-right, preserving the document order the recursive walk
    // produced.
    var work: std.ArrayList(Ast.NodeIndex) = .empty;
    defer work.deinit(gpa);
    var seed = data_forest.len;
    while (seed > 0) {
        seed -= 1;
        try work.append(gpa, data_forest[seed]);
    }

    while (work.pop()) |idx| {
        if (tree.tagOf(idx) != .form) continue;
        const hdr = tree.formHeader(idx);
        // Parser-recovery synthetic form — skip, mirroring materializeDefaults.
        if (hdr.head.len == 0) continue;

        const hit = schema.lookupForm(hdr.head, hdr.namespace);
        var parent_lowerable = false;
        if (hit == .found) {
            const form_spec = hit.found.form;
            if (form_spec.lowering) |*low| {
                parent_lowerable = true;
                try lowerOneForm(gpa, arena, tree, idx, hdr, form_spec, low, schema, view, registry, axes, env, &invocations, &diags, emitted, budget);
            }
        }

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
            for (hdr.children) |child| {
                if (tree.childForm(child)) |cf| try checkNestedLowerable(gpa, tree, cf, schema, &diags);
            }
        }

        // Descend into form-shaped children so nested sugar forms also
        // lower. Push in reverse so the worklist pops them in document
        // order (matches the prior recursive descent).
        var c = hdr.children.len;
        while (c > 0) {
            c -= 1;
            if (tree.childForm(hdr.children[c])) |cf| try work.append(gpa, cf);
        }
    }

    return .{
        .invocations = try invocations.toOwnedSlice(arena),
        .diagnostics = try diags.toOwnedSlice(gpa),
    };
}

/// Emit `lowering_nested_lowerable` when `child` resolves to a form whose own
/// `FormSpec` declares `:lowering`. The worklist calls this only when the
/// *parent* is itself lowerable, so a plain-data parent holding lowerable sugar
/// (the supported nested-sugar shape) never trips it. The diagnostic points at
/// the child's head with path `[<child-head>, lowering]`. Emit-only: the
/// caller still descends into `child`, so both hooks run and the contradictory
/// output still forms — the clear diagnostic is the headline, not a veto.
fn checkNestedLowerable(
    gpa: Allocator,
    tree: *const Ast.Tree,
    child: Ast.NodeIndex,
    schema: Schema.Schema,
    diags: *std.ArrayList(Ast.Diagnostic),
) Allocator.Error!void {
    const chdr = tree.formHeader(child);
    // Parser-recovery synthetic form — no head to resolve or report.
    if (chdr.head.len == 0) return;
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
    // Cross-ref diagnostics are filtered out of the gate decision —
    // the single-form sub-tree's cross-ref index sees only this form,
    // so a `:ref` to a sibling target elsewhere in the document
    // misses here even though it resolves cleanly in the final-document
    // forest pass. Treating that miss as a gate failure would silently
    // skip the hook for any sugar form that points outward. Filtered
    // diagnostics are still discarded — surface diagnostics never reach
    // the host stream from this pass (the final-forest pass surfaces
    // them when the sugar form lands in `unlowered_roots`).
    var sub: Ast.Tree = tree.*;
    var sub_root = [_]Ast.NodeIndex{form_idx};
    sub.root = sub_root[0..];
    var surface = try Validator.validateWithOptions(gpa, sub, schema, .{
        .overlay = view.materialized,
        .axes = axes,
    });
    defer surface.deinit();
    if (hasNonCrossRefError(surface.diagnostics)) return;

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
        .env = env,
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

/// True iff `diags` contains an err-severity diagnostic whose code is
/// NOT a cross-ref miss. Used by `lowerOneForm` to gate hook execution
/// on *shape* errors (missing required key, wrong underlying, …) only —
/// cross-ref diagnostics on the single-form sub-tree are expected
/// whenever the sugar form references a target elsewhere in the
/// document, and would silently skip the hook if treated as a failure.
/// The final-document forest pass owns cross-ref reporting; this
/// filter just prevents the gate from over-rejecting.
///
/// Filtered set tracks the runtime emissions of `Validator`'s
/// cross-ref index walk: `not_cross_ref` (unresolved lookup),
/// `cross_ref_outside_scope` (resolved but outside scope), and
/// `duplicate_cross_ref_target` (name collision on registration).
/// Schema-aggregate cross-ref codes (`unknown_cross_ref_target`,
/// `ambiguous_cross_ref_target`, …) are emitted before this gate runs
/// and never appear here.
fn hasNonCrossRefError(diags: []const Ast.Diagnostic) bool {
    for (diags) |d| {
        if (d.severity != .err) continue;
        switch (d.code) {
            .not_cross_ref,
            .cross_ref_outside_scope,
            .duplicate_cross_ref_target,
            => continue,
            else => return true,
        }
    }
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
    // An empty head would produce a tree node the validator's
    // `headInProduces` check can't ever match — failing here
    // surfaces the hook bug instead of a confusing "head `` not
    // in :produces" diagnostic later in the pipeline.
    std.debug.assert(ef.head.len > 0);

    // Resolve namespace splitting on the head ("pngine/shader" → ("pngine", "shader")).
    var head_ns: ?[]const u8 = null;
    var head_name: []const u8 = ef.head;
    if (std.mem.indexOfScalar(u8, ef.head, '/')) |slash| {
        head_ns = ef.head[0..slash];
        head_name = ef.head[slash + 1 ..];
    }
    // Namespace separator must not produce an empty name half ("foo/"
    // or "/" would). The validator would emit a confusing
    // `lookupForm` miss; assert so hook tests catch it directly.
    std.debug.assert(head_name.len > 0);

    var children: std.ArrayList(Ast.NodeIndex) = .empty;

    for (ef.kvpairs) |kv| {
        const value_idx = try emitValueIntoTree(b, kv.value, src_span, ef);
        const kv_idx = try b.appendKvpair(kv.key, value_idx, src_span, src_span);
        try children.append(b.a, kv_idx);
    }

    // Positional children follow the kvpairs verbatim — a `.form` arm
    // recurses into a nested form, every scalar arm becomes a bare atom.
    // `emitValueIntoTree` already materializes every `EmittedValue` shape
    // (including `.form`), so positionals and kvpair values share one path.
    for (ef.children) |child| {
        const cidx = try emitValueIntoTree(b, child, src_span, ef);
        try children.append(b.a, cidx);
    }

    return b.appendForm(head_name, head_ns, src_span, children.items, src_span);
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

// Surface validation gates on shape errors only,
// not on cross-ref misses. The single-form sub-tree the surface pass
// sees can never resolve a sibling-form cross-ref; treating that miss
// as a gate failure would silently skip the hook for any sugar form
// that points outward.

test "hasNonCrossRefError: cross-ref codes are filtered out" {
    const codes = [_]Ast.Diagnostic.Code{
        .not_cross_ref,
        .cross_ref_outside_scope,
        .duplicate_cross_ref_target,
    };
    for (codes) |c| {
        const diags = [_]Ast.Diagnostic{.{
            .span = .{ .start = 0, .end = 0 },
            .message = "",
            .severity = .err,
            .code = c,
            .path = &.{},
        }};
        try testing.expect(!hasNonCrossRefError(diags[0..]));
    }
}

test "hasNonCrossRefError: shape errors trip the gate" {
    const diags = [_]Ast.Diagnostic{.{
        .span = .{ .start = 0, .end = 0 },
        .message = "",
        .severity = .err,
        .code = .missing_required_key,
        .path = &.{},
    }};
    try testing.expect(hasNonCrossRefError(diags[0..]));
}

test "hasNonCrossRefError: warnings are ignored regardless of code" {
    const diags = [_]Ast.Diagnostic{.{
        .span = .{ .start = 0, .end = 0 },
        .message = "",
        .severity = .warning,
        .code = .missing_required_key,
        .path = &.{},
    }};
    try testing.expect(!hasNonCrossRefError(diags[0..]));
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
            .target_form = try a.dupe(u8, "target"),
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
