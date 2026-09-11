//! Safe-expression evaluator.
//!
//! Closed v1 vocabulary — arithmetic, comparison, logical, vec2/3/4,
//! lerp/clamp/min/max/dot/cross/length, `let`, `if`, `cond`. No lambdas,
//! no recursion at the language level, no I/O, no mutation.
//!
//! Implementation: the evaluator is iterative. `evaluate` drives an
//! explicit `frames` stack of `Frame` records (eval, apply_form,
//! form_collect, let_commit, if_select, cond_select, and_check, or_check,
//! vec_collect) against a `values` stack. Each step pops one frame and
//! either pushes a result onto `values` or schedules further frames.
//! Depth is bounded by `MAX_FRAMES` and total work by `MAX_STEPS`; the
//! evaluator never recurses on the host stack. The binary path mirrors
//! every tree frame; `form_collect` ↔ `form_collect_walk` carry the
//! form-as-data pass-through for forms whose head doesn't resolve to a
//! `Plugin.ExprFunc`.
//!
//! The evaluator loop is stackless, but a few `Value` consumers still
//! recurse on the host stack (`deepCopyValue`, `equalsBounded`, the plugin
//! codec). `MAX_VALUE_DEPTH` caps `Value` nesting so those recursions are
//! bounded too — see its doc for the carve-out from the no-host-recursion
//! rule.
//!
//! Memory: every allocated `Value` (vectors, strings) lives in an arena
//! supplied by the caller through `Result`. `result.deinit()` releases
//! everything. The implementation never allocates from `gpa` directly.
//!
//! Plugin extension: every `Plugin.ExprFunc` carries an `impl` pointer.
//! `applyFunction` resolves the func via `Schema.lookupExprFunc` and
//! dispatches through `impl`. A declared func with `impl == null`
//! evaluates to `error.PluginFuncNotImplemented` — declaration-only is a
//! supported state for plugins that want validator recognition without
//! committing to runtime semantics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Date = @import("Date.zig");
const Time = @import("Time.zig");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const BinaryCursor = @import("BinaryCursor.zig");
const wasm_plugin_invoker = @import("wasm_plugin_invoker.zig");
const trig = @import("trig.zig");

/// Conceptual depth ceiling for SJON expressions. Iterative driver bounds
/// the explicit `frames` stack at `MAX_FRAMES` and the per-call step count
/// at `MAX_STEPS`; both ceilings are far above any realistic program.
pub const MAX_EVAL_DEPTH: u32 = 256;

/// Hard ceiling on the live frame-stack depth. Each AST nesting level
/// contributes at most a small constant number of frames (eval + one
/// continuation). Sized 4× `MAX_EVAL_DEPTH` so well-formed programs never trip
/// it; pathological inputs surface as `error.DepthExceeded`.
///
/// This bounds *nesting* only. Width — a vector's element count, a call's
/// argument count — costs a constant, because both paths stream their
/// children (`Frame.child_walk` on the tree, `vec_walk` / `form_walk` on
/// the binary). `pub` so tests can straddle the ceiling.
pub const MAX_FRAMES: u32 = MAX_EVAL_DEPTH * 4;

/// Hard ceiling on total interpreter steps per call. Bounded by AST size
/// in normal programs; the cap exists so a buggy frame transition cannot
/// loop forever.
const MAX_STEPS: u32 = 1 << 20;

/// The two work-shaped ceilings a caller may lower, carried together so the
/// `*WithRuntimeBudget` entries take one parameter rather than a growing row
/// of bare scalars. Defaults are the production values; a test lowers the
/// axis it means to trip and leaves the other alone.
///
/// `MAX_FRAMES` is deliberately not here: frame depth is a property of the
/// *input's* nesting, reachable by writing a deep enough expression, and it
/// already has ±1 tests on both paths. Steps and bytes are not reachable
/// that way inside a test of sane size, which is exactly why they need a
/// seam — without one the `error.DepthExceeded` arm at the end of both eval
/// loops has never executed, and rewriting `for (0..MAX_STEPS)` to
/// `while (true)` would pass every gate in the repo.
pub const Budget = struct {
    bytes: usize = MAX_EVAL_BYTES,
    steps: u32 = MAX_STEPS,
};

/// Hard ceiling on total result-arena bytes per eval call. Bounds the
/// memory an expression can allocate (vectors, strings, forms, plugin
/// return values, and the final deep-copy) so a *bounded-step* expression
/// cannot still drive the host to OS OOM — it surfaces
/// `error.MemoryBudgetExceeded` gracefully, the way step exhaustion
/// surfaces `error.DepthExceeded`. Sized far above any realistic program.
///
/// This is the third resource axis (steps, frame depth, bytes); the frame
/// and value scratch stacks are separately bounded by `MAX_FRAMES` /
/// `MAX_STEPS`. The cap is enforced by polling `ArenaAllocator.queryCapacity`
/// once per interpreter step plus once after the final deep-copy — no
/// allocator wrapper, so the returned `Result` keeps a plain `gpa`-backed
/// arena and stays movable.
pub const MAX_EVAL_BYTES: usize = 1 << 26; // 64 MiB

/// Hard ceiling on the *nesting depth* of a `Value`. Distinct from the
/// three eval-loop axes above: those bound how much work / memory an
/// evaluation may do, this bounds how deeply the resulting data may nest.
/// It exists because a handful of `Value` consumers recurse on the host
/// stack — `deepCopyValue` (the mandatory final result copy), the
/// `equalsBounded` used by `=` / `!=`, and the plugin-arg codec. An
/// expression can still *build* a deeply-nested value mid-eval (it burns
/// steps and bytes under the ceilings above), but the moment anything
/// tries to recurse over one past this depth it gets `error.DepthExceeded`
/// instead of a stack overflow. Set equal to `MAX_EVAL_DEPTH`: a value can
/// nest no deeper than the frame depth that produced it plus the small
/// constant slack the binder forms add.
pub const MAX_VALUE_DEPTH: u32 = MAX_EVAL_DEPTH;

comptime {
    // `Value` is the unit of the value stack and gets pushed/popped on
    // every frame transition; pin its size so the stack's growth stays
    // predictable across stdlib changes. The largest variant is now
    // `form` — a 4-slice struct (4 × 16B = 64B) — plus the union tag.
    std.debug.assert(@sizeOf(Value) <= 72);
}

/// Runtime value produced by the expression evaluator. String / keyword
/// slices, the `vector` element array, and the `form` head / namespace /
/// children / kvpair arrays are arena-owned by the enclosing `Result`;
/// do not retain them past `result.deinit()`.
///
/// Three integer-shaped variants — `number` (f64), `integer_i64`,
/// `integer_u64` — mirror the AST's three number tags. Identity ops
/// (binding, vector/form construction, plugin pass-through) preserve
/// the variant; arithmetic and comparisons collapse to `f64` via
/// `toF64` (lossy beyond 2^53, deliberate — matches the pre-exact-int
/// semantics of `+`/`-`/`*`/`/`/`mod`/cmp).
pub const Value = union(enum) {
    number: f64,
    /// Exact signed 64-bit integer. Produced by `processEval` for
    /// `Tag.number_i64` nodes and propagated through identity ops.
    /// Arithmetic / comparison route via `toF64` and collapse this
    /// to `number`.
    integer_i64: i64,
    /// Exact unsigned 64-bit integer above `i64.max`. Produced by
    /// `processEval` for `Tag.number_u64` nodes. Same arithmetic/
    /// comparison collapse as `integer_i64`.
    integer_u64: u64,
    boolean: bool,
    nil,
    string: []const u8,
    keyword: []const u8,
    /// Calendar date (proleptic Gregorian, no time, no zone). Produced
    /// by `processEval` for `Tag.date` nodes; identity-preserving
    /// through let bindings, vector / form construction, and plugin
    /// pass-through. Equality and ordering are calendar-exact via
    /// `Date.eql` / `Date.order` — no cross-variant numeric collapse,
    /// even though the wire byte sits next to the integer tags.
    date: Date,
    /// Clock time (no date, no zone, no leap seconds). Produced by
    /// `processEval` for `Tag.time` nodes; identity-preserving through
    /// let bindings, vector / form construction, and plugin pass-
    /// through. Equality and ordering are component-exact via
    /// `Time.eql` / `Time.order` — no cross-variant numeric collapse,
    /// even though `45296` is the second-of-day for `12:34:56`.
    time: Time,
    vector: []const Value,
    /// Form value (head + namespace + children + kvpairs). Lets a
    /// plugin expr-func accept or return a form — e.g. `(count-done
    /// [(todo …) …])` consumes a vector-of-form arg. `namespace` is
    /// the empty string when the form is bare. See
    /// `docs/executable-plugin-abi.md` §9.1 form payload.
    form: FormValue,

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            .nil => false,
            else => true,
        };
    }

    /// Coerce a numeric variant to f64. Returns null for non-numeric
    /// variants. Integer variants lose precision above 2^53 — call this
    /// only at arithmetic / comparison sites where the lossy collapse
    /// is the documented contract. Identity-shaped ops should preserve
    /// the original variant instead.
    pub fn toF64(self: Value) ?f64 {
        return switch (self) {
            .number => |x| x,
            .integer_i64 => |x| @floatFromInt(x),
            .integer_u64 => |x| @floatFromInt(x),
            else => null,
        };
    }

    /// Structural value equality returning a plain `bool`. Recurses on the
    /// host stack over vectors and forms, so it is **safe only for values
    /// already bounded to `MAX_VALUE_DEPTH`** — every `Result` value is
    /// (eval's final `deepCopyValue` caps depth), and every in-repo caller
    /// compares Result or literal values. To compare a possibly-deep
    /// *mid-eval* value, use `equalsBounded`, which returns
    /// `error.DepthExceeded` rather than risking a host-stack overflow.
    pub fn equals(a: Value, b: Value) bool {
        // SAFETY: inputs are contract-bounded to MAX_VALUE_DEPTH (every
        // `Value` a caller can hold came out of eval's final deepCopyValue
        // or `MaterializedDefaults.literalToValue`, both capped there), so
        // the depth cap is never reached; a violation is a caller bug,
        // surfaced loudly rather than as a silent stack smash.
        return equalsDepth(a, b, 0) catch unreachable;
    }

    /// Depth-guarded structural equality for values whose nesting is
    /// bounded only by the step / byte ceilings — i.e. mid-evaluation
    /// values seen before the final `deepCopyValue`. `=` / `!=` route
    /// through this so a deep computed value fails gracefully.
    pub fn equalsBounded(a: Value, b: Value) error{DepthExceeded}!bool {
        return equalsDepth(a, b, 0);
    }

    /// Exact `i64 == u64`, without a lossy widening on either side.
    fn exactIntEql(signed: i64, unsigned: u64) bool {
        if (signed < 0) return false;
        return @as(u64, @intCast(signed)) == unsigned;
    }

    fn equalsDepth(a: Value, b: Value, depth: u32) error{DepthExceeded}!bool {
        if (depth >= MAX_VALUE_DEPTH) return error.DepthExceeded;
        // Two *exact* integer variants compare exactly, even across
        // variants: nothing is gained by collapsing them, and the collapse
        // is wrong — `(= 9223372036854775807 9223372036854775808)` is
        // true through f64 (both round to 2^63) though the values differ
        // and both are exactly representable. Signs make this total: a
        // negative i64 is never equal to any u64.
        if (a == .integer_i64 and b == .integer_u64) return exactIntEql(a.integer_i64, b.integer_u64);
        if (a == .integer_u64 and b == .integer_i64) return exactIntEql(b.integer_i64, a.integer_u64);

        // Remaining cross-variant numeric comparisons (anything involving
        // `.number`) collapse to f64 — lossy beyond 2^53 but matching
        // arithmetic semantics, which is deliberate.
        const a_num = a.toF64();
        const b_num = b.toF64();
        if (a_num != null and b_num != null) {
            if (@as(std.meta.Tag(Value), a) != @as(std.meta.Tag(Value), b)) {
                return a_num.? == b_num.?;
            }
        }
        if (@as(std.meta.Tag(Value), a) != @as(std.meta.Tag(Value), b)) return false;
        return switch (a) {
            .number => |x| x == b.number,
            .integer_i64 => |x| x == b.integer_i64,
            .integer_u64 => |x| x == b.integer_u64,
            .boolean => |x| x == b.boolean,
            .nil => true,
            .string => |x| std.mem.eql(u8, x, b.string),
            .keyword => |x| std.mem.eql(u8, x, b.keyword),
            .date => |x| x.eql(b.date),
            .time => |x| x.eql(b.time),
            .vector => |xs| blk: {
                if (xs.len != b.vector.len) break :blk false;
                for (xs, b.vector) |xv, yv| if (!try equalsDepth(xv, yv, depth + 1)) break :blk false;
                break :blk true;
            },
            .form => |fa| blk: {
                const fb = b.form;
                if (!std.mem.eql(u8, fa.head, fb.head)) break :blk false;
                if (!std.mem.eql(u8, fa.namespace, fb.namespace)) break :blk false;
                if (fa.children.len != fb.children.len) break :blk false;
                for (fa.children, fb.children) |xv, yv| if (!try equalsDepth(xv, yv, depth + 1)) break :blk false;
                if (fa.kvpairs.len != fb.kvpairs.len) break :blk false;
                for (fa.kvpairs, fb.kvpairs) |xp, yp| {
                    if (!std.mem.eql(u8, xp.key, yp.key)) break :blk false;
                    if (!try equalsDepth(xp.value, yp.value, depth + 1)) break :blk false;
                }
                break :blk true;
            },
        };
    }
};

/// Form-value payload. Mirrors `Ast.FormHeader`'s shape so a plugin
/// receiving a form sees the same head / namespace / positional /
/// keyword decomposition the validator does. `namespace` is the empty
/// byte slice for bare forms.
pub const FormValue = struct {
    head: []const u8,
    namespace: []const u8,
    children: []const Value,
    kvpairs: []const KvPair,
};

/// One keyword argument in a form value. `key` is the bare keyword name
/// without the leading `:`.
pub const KvPair = struct {
    key: []const u8,
    value: Value,
};

/// Lexically-scoped environment. `bindings` is small (let only adds a
/// handful of names); a sequential search is faster than hashing for the
/// expected size and avoids allocator pressure.
pub const Env = struct {
    parent: ?*const Env = null,
    /// Stack-allocated by the caller; lookups search from the end backwards
    /// so later bindings shadow earlier ones.
    bindings: []const Binding = &.{},

    pub const Binding = struct {
        name: []const u8,
        value: Value,
    };

    pub fn lookup(self: *const Env, name: []const u8) ?Value {
        var i: usize = self.bindings.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.bindings[i].name, name)) return self.bindings[i].value;
        }
        if (self.parent) |p| return p.lookup(name);
        return null;
    }
};

/// Errors `eval` can return. `OutOfMemory` is the only allocator failure;
/// everything else is a deterministic evaluation outcome the consumer can
/// turn into a diagnostic with the enclosing node's `span`.
///
/// `DepthExceeded` is shared with `Binary.Error` and `Validator.Error` —
/// the shared name is a deliberate spine across the depth-bounded
/// walkers; see those modules' `Error` doc-comments for the per-site
/// meaning. Here it means the evaluator frame stack exceeded
/// `MAX_FRAMES`.
pub const Error = error{
    OutOfMemory,
    TypeMismatch,
    DivisionByZero,
    UnknownFunction,
    AmbiguousFunction,
    ArityMismatch,
    UnknownBinding,
    InvalidLetBinding,
    InvalidCondClause,
    /// `map`/`filter`/`any`/`all`/`fold`'s first child is not a literal
    /// vector of the required number of symbols. Specifically: the
    /// binder must be a vector node (not a kvpair, not a form), its
    /// length must match the form's expected binder arity (1 for
    /// `map`/`filter`/`any`/`all`, 2 for `fold`), and every element
    /// must be a symbol node.
    InvalidBinderShape,
    KeywordInExpressionArgs,
    DepthExceeded,
    /// Result-arena allocation exceeded `MAX_EVAL_BYTES`. Distinct from
    /// `DepthExceeded` (frame/step ceilings) and from `OutOfMemory` (the
    /// host allocator genuinely failed): this is the evaluator refusing to
    /// keep allocating once a single call's arena passes the byte budget,
    /// so a memory-heavy / step-light expression fails gracefully instead
    /// of OOM-ing the process. Like `DepthExceeded`, it is a deterministic
    /// resource-limit outcome, not a host failure.
    MemoryBudgetExceeded,
    PluginFuncNotImplemented,
    /// A `:impl "wasm:<export>"` plugin func was invoked but the
    /// returned value's runtime type does not satisfy the declared
    /// `:result` type. Structured detail (expected vs. actual) lives in
    /// `wasm_plugin_invoker.lastFailure()`.
    PluginFuncResultType,
    /// A `:impl "wasm:<export>"` plugin func returned an `ok=0` frame
    /// with a structured `(code, detail)` pair. Plugin-emitted codes
    /// MUST NOT begin with `_`; that prefix is reserved for host-
    /// synthesized failures (see `PluginFuncTrapped` /
    /// `PluginFuncAllocFailed`). Detail in
    /// `wasm_plugin_invoker.lastFailure()`.
    PluginFuncFailed,
    /// The host adapter caught a WASM trap during plugin export
    /// execution (typically a reachable `unreachable` or out-of-bounds
    /// memory access) and synthesized an `ok=0` frame with code
    /// `_internal_trap`. Detail in `wasm_plugin_invoker.lastFailure()`.
    PluginFuncTrapped,
    /// Either the host adapter's call to the plugin's
    /// `sjon_plugin_alloc` failed, or the host failed to allocate the
    /// outbound frame. Surfaced via the synthetic `_alloc` code on the
    /// host side. Detail in `wasm_plugin_invoker.lastFailure()`.
    PluginFuncAllocFailed,
};

/// Error set for the binary-IR evaluation path. Composes the
/// expression-level errors (`Error`) with the binary-cursor errors
/// (`BinaryCursor.Error`, an alias for `Binary.Error`) plus
/// `MultipleRoots`, raised by `evalBinary` when the input buffer
/// contains more than one root node.
pub const BinaryError = Error || BinaryCursor.Error || error{MultipleRoots};

/// Evaluation result. Owns an arena from which result vectors / strings
/// were allocated. `result.deinit()` frees everything.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    value: Value,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }
};

// ---------------------------------------------------------------------------
// Iterative evaluator
//
// Frames are pushed in LIFO order onto `frames`. Values produced by frames
// land on `values`. The driver loop pops a frame, processes it, and may
// push more frames or values. When `frames` is empty, `values` holds
// exactly one entry — the final result.
//
// Each Frame variant documents what it pops from `values` and what it
// pushes (frames/values).
// ---------------------------------------------------------------------------

/// Native Tree evaluator — walks `(tree, idx)` via an explicit frame stack
/// keyed by `NodeIndex`. No legacy bridge. String / keyword values are
/// duped into the result arena, so callers do not need to keep `tree`
/// alive past `result.deinit()`.
///
/// Declarative entry point: callers that don't construct a
/// `PluginRuntime` (everyone except `Host.runEvalPass` and the few
/// runtime-aware test paths) use this convenience wrapper. It forwards
/// to `evalWithRuntime` with a null runtime — calling a `:impl
/// "wasm:<name>"` function under this entry point raises
/// `PluginFuncNotImplemented` exactly as before the native runtime
/// adapter landed.
pub fn eval(
    gpa: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    env: *const Env,
    schema: Schema.Schema,
) Error!Result {
    return evalWithRuntime(gpa, tree, idx, env, schema, null);
}

/// Runtime-aware Tree evaluator. `runtime` is an opaque pointer to a
/// `PluginRuntime` instance (only non-null when the build was compiled
/// with `-Dplugin-exec=true` on a native target AND the host wired up
/// an executable-plugin runtime). The type is `?*anyopaque` rather than
/// `?*PluginRuntime` so this module doesn't transitively pull in
/// libwasmtime on the WASM build or on minimal native builds —
/// `wasm_plugin_invoker.invoke` casts back to the real type behind a
/// `comptime` gate.
pub fn evalWithRuntime(
    gpa: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    env: *const Env,
    schema: Schema.Schema,
    runtime: ?*anyopaque,
) Error!Result {
    return evalWithRuntimeBudget(gpa, tree, idx, env, schema, runtime, .{});
}

/// Budget-parameterized variant of `evalWithRuntime`. `budget` lowers the
/// result-arena byte cap and/or the per-call step cap (see `Budget`); the
/// public entry points take the defaults. Exposed so tests can drive
/// `MemoryBudgetExceeded` and step exhaustion deterministically with small
/// caps and a small expression, independent of whether the closed vocabulary
/// has an allocation or step amplifier.
pub fn evalWithRuntimeBudget(
    gpa: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    env: *const Env,
    schema: Schema.Schema,
    runtime: ?*anyopaque,
    budget: Budget,
) Error!Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(gpa);
    var values: std.ArrayList(Value) = .empty;
    defer values.deinit(gpa);

    try frames.append(gpa, .{ .eval = .{ .idx = idx, .env = env } });

    for (0..budget.steps) |_| {
        if (frames.items.len == 0) break;
        if (frames.items.len > MAX_FRAMES) return error.DepthExceeded;
        if (arena.queryCapacity() > budget.bytes) return error.MemoryBudgetExceeded;

        const f = frames.pop().?;
        switch (f) {
            .eval => |e| try processEval(a, gpa, tree, e, &frames, &values, schema),
            .vec_collect => |vc| try processVecCollect(a, gpa, vc, &values),
            .child_walk => |cw| try processChildWalk(gpa, cw, &frames),
            .apply_form => |af| try processApplyForm(a, gpa, af, &values, schema, runtime),
            .form_collect => |fc| try processFormCollect(a, gpa, fc, &values),
            .let_commit => |lc| processLetCommit(lc, &values),
            .if_select => |s| try processIfSelect(s, gpa, &frames, &values),
            .cond_select => |s| try processCondSelect(s, gpa, tree, &frames, &values),
            .and_check => |s| try processAndCheck(s, gpa, tree, &frames, &values),
            .or_check => |s| try processOrCheck(s, gpa, tree, &frames, &values),
            .binder_setup => |s| try processBinderSetup(a, gpa, s, &frames, &values),
            .binder_iter => |s| try processBinderIter(gpa, s, &frames, &values),
        }
    } else {
        return error.DepthExceeded;
    }

    std.debug.assert(values.items.len == 1);
    // Strings / keywords on the value stack point into tree.strings
    // (arena-owned by the source tree). Dupe before returning so the
    // result outlives `tree`.
    const final = try deepCopyValue(a, values.items[0]);
    // The final deep-copy can roughly double transient arena usage; check
    // once more so an over-budget result fails gracefully here too.
    if (arena.queryCapacity() > budget.bytes) return error.MemoryBudgetExceeded;
    return .{ .arena = arena, .value = final };
}

/// Deep-copy a `Value` into `a`. Numbers / bools / nil are copied by value;
/// string / keyword slices are duped; vectors / forms recurse
/// element-by-element on the host stack. Recursion is bounded by
/// `MAX_VALUE_DEPTH`: a value nested deeper than that yields
/// `error.DepthExceeded` instead of overflowing the stack. Because eval
/// runs this on its result exactly once, it is also what caps the depth of
/// every `Result` value (and thus every downstream consumer).
pub fn deepCopyValue(a: Allocator, v: Value) error{ OutOfMemory, DepthExceeded }!Value {
    return deepCopyValueDepth(a, v, 0);
}

/// Deep-copy a `Value` already known to be within `MAX_VALUE_DEPTH` — i.e. an
/// eval `Result` value, which eval depth-capped when it produced it. Same copy
/// as `deepCopyValue`, but the cap provably can't trip, so the error set
/// narrows to `Allocator.Error`. The single home for the eval-Result copy the
/// EffectiveView + MaterializedDefaults overlays both perform (each otherwise
/// spelled the `DepthExceeded => unreachable` narrowing at its own call site).
pub fn deepCopyValueAssumeBounded(a: Allocator, v: Value) Allocator.Error!Value {
    return deepCopyValue(a, v) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.DepthExceeded => unreachable,
    };
}

fn deepCopyValueDepth(a: Allocator, v: Value, depth: u32) error{ OutOfMemory, DepthExceeded }!Value {
    if (depth >= MAX_VALUE_DEPTH) return error.DepthExceeded;
    return switch (v) {
        .number, .integer_i64, .integer_u64, .boolean, .nil, .date, .time => v,
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .keyword => |k| .{ .keyword = try a.dupe(u8, k) },
        .vector => |xs| blk: {
            const dup = try a.alloc(Value, xs.len);
            for (xs, 0..) |x, i| dup[i] = try deepCopyValueDepth(a, x, depth + 1);
            break :blk .{ .vector = dup };
        },
        .form => |f| blk: {
            const head = try a.dupe(u8, f.head);
            const ns = try a.dupe(u8, f.namespace);
            const children = try a.alloc(Value, f.children.len);
            for (f.children, 0..) |c, i| children[i] = try deepCopyValueDepth(a, c, depth + 1);
            const kvs = try a.alloc(KvPair, f.kvpairs.len);
            for (f.kvpairs, 0..) |p, i| kvs[i] = .{
                .key = try a.dupe(u8, p.key),
                .value = try deepCopyValueDepth(a, p.value, depth + 1),
            };
            break :blk .{ .form = .{
                .head = head,
                .namespace = ns,
                .children = children,
                .kvpairs = kvs,
            } };
        },
    };
}

test "deepCopyValueAssumeBounded copies a bounded value into fresh storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const original: Value = .{ .vector = &.{
        .{ .integer_i64 = 7 },
        .{ .string = "hi" },
    } };
    const copy = try deepCopyValueAssumeBounded(a, original);

    try std.testing.expect(original.equals(copy)); // structurally equal
    try std.testing.expect(copy.vector.ptr != original.vector.ptr); // not aliased
}

// ---------------------------------------------------------------------------
// Frame stack — drives evaluation by walking `(tree, NodeIndex)` pairs
// via `tree.formHeader` / `tree.vectorElements` / `tree.kvpairHeader`.
// ---------------------------------------------------------------------------

/// Higher-order binder forms: which iteration discipline does the
/// frame's `process` arm run? `map` accumulates body values, `filter`
/// accumulates original elements on truthy body, `any`/`all` produce
/// booleans with short-circuit on truthy/falsy respectively.
pub const BinderKind = enum(u8) { map, filter, any, all, fold };

/// The ten core special forms, keyed by head. `let`/`if`/`cond`/`and`/`or`
/// each schedule a bespoke frame shape; the five higher-order binders fold
/// into one `BinderKind`-tagged arm. `scheduleForm`, `scheduleFormBinary`,
/// and `isCoreSpecialForm` all resolve heads through `special_forms`, so the
/// catalog cannot drift between the tree dispatch, the binary dispatch, and
/// the membership test — the single source of truth is this map.
const SpecialForm = union(enum) {
    let,
    @"if",
    cond,
    @"and",
    @"or",
    binder: BinderKind,
};

const special_forms = std.StaticStringMap(SpecialForm).initComptime(.{
    .{ "let", .let },
    .{ "if", .@"if" },
    .{ "cond", .cond },
    .{ "and", .@"and" },
    .{ "or", .@"or" },
    .{ "map", SpecialForm{ .binder = .map } },
    .{ "filter", SpecialForm{ .binder = .filter } },
    .{ "any", SpecialForm{ .binder = .any } },
    .{ "all", SpecialForm{ .binder = .all } },
    .{ "fold", SpecialForm{ .binder = .fold } },
});

/// Frame payloads shared verbatim by the tree `Frame` and binary
/// `FrameBinary` unions. Naming them lets the three process* functions
/// both drivers call (`processVecCollect`/`processApplyForm`/
/// `processLetCommit`) take a concrete parameter type instead of an
/// `anytype` bridge — the two unions used to carry two distinct anonymous
/// structs with identical fields, forcing `anytype`.
const VecCollect = struct { count: u32 };
const ApplyForm = struct {
    head: []const u8,
    namespace: []const u8,
    argc: u32,
    slots: ?[]const u8 = null,
};
const LetCommit = struct {
    name: []const u8,
    env: *Env,
    env_buf: []Env.Binding,
    idx: u32,
};
const FormCollect = struct {
    head: []const u8,
    namespace: []const u8,
    keys: []const ?[]const u8,
};

/// What a `child_walk` pushes once it has evaluated every child.
///
/// A separate union rather than a `Frame` field because `Frame` cannot
/// contain itself. These are exactly the three frames that consume a run
/// of sibling values off the value stack.
const ChildWalkThen = union(enum) {
    vec_collect: VecCollect,
    apply_form: ApplyForm,
    form_collect: FormCollect,
};

const Frame = union(enum) {
    eval: struct { idx: Ast.NodeIndex, env: *const Env },
    vec_collect: VecCollect,
    /// `slots` permutes a labeled call's source-order args into the
    /// function's declared positional order; null for positional calls
    /// (and for the tree path, which reorders before scheduling evals).
    apply_form: ApplyForm,
    /// Form-as-data pass-through. Fires when a form's head doesn't
    /// resolve to a `Plugin.ExprFunc` — we're not invoking a function,
    /// we're constructing a runtime `Value.form` from the evaluated
    /// children + kvpairs. `keys[i]` follows source order:
    ///   * `null` → values[i] is a positional child
    ///   * non-null → values[i] is the value of a kvpair with that key
    /// Matches the binary path's `form_collect_walk`.
    form_collect: FormCollect,
    /// Streaming walk over a run of sibling nodes to evaluate, pushing one
    /// `eval` at a time and then `then`.
    ///
    /// Scheduling all `n` children up front made *width* cost frames like
    /// *depth*: a 1500-element vector literal (or a 1500-argument call)
    /// blew `MAX_FRAMES` at nesting depth 1 and returned
    /// `error.DepthExceeded`, while the binary path — which already
    /// streams, via `vec_walk` / `form_walk` — evaluated it fine. Same
    /// input, same schema, different answer depending on whether the host
    /// held a tree or IR. Now both stream, and `MAX_FRAMES` bounds only
    /// nesting on both.
    ///
    /// `items` are visited left to right, so values land on the value
    /// stack in source order exactly as the reverse-push scheduling did.
    child_walk: struct {
        items: []const Ast.NodeIndex,
        consumed: u32,
        env: *const Env,
        then: ChildWalkThen,
    },
    let_commit: LetCommit,
    if_select: struct {
        then_idx: Ast.NodeIndex,
        else_idx: Ast.NodeIndex,
        has_else: bool,
        env: *const Env,
    },
    cond_select: struct {
        value_idx: Ast.NodeIndex,
        remaining: []const Ast.NodeIndex,
        env: *const Env,
    },
    and_check: struct {
        remaining: []const Ast.NodeIndex,
        env: *const Env,
    },
    or_check: struct {
        remaining: []const Ast.NodeIndex,
        env: *const Env,
    },
    /// First phase of a binder form. Runs once after `xs` evaluates
    /// (and, for fold, after `init` evaluates too), pops the
    /// resulting value(s) off `values`, validates that `xs` is a
    /// vector, allocates the per-iteration binding slot(s) and (for
    /// map/filter) the accumulator, then schedules the first body
    /// iteration via `binder_iter`. Empty `xs` skips straight to the
    /// kind's empty-result value (or `init` for fold).
    binder_setup: struct {
        kind: BinderKind,
        /// Loop-variable symbol name. For fold this is the `x` half
        /// of `[acc x]`; for map/filter/any/all it is the sole symbol.
        binder_name: []const u8,
        /// Accumulator symbol name; non-null only for fold (the
        /// `acc` half of `[acc x]`).
        binder_acc_name: ?[]const u8,
        body_idx: Ast.NodeIndex,
        env_outer: *const Env,
    },
    /// Per-iteration phase of a binder form. Runs after each body
    /// evaluation; pops the body's value, updates the accumulator or
    /// short-circuits depending on `kind`, then either pushes the next
    /// iteration's eval frames or pushes the final result. `env_buf`
    /// is a single-slot binding buffer; `inner_env.bindings` points at
    /// `env_buf[0..1]`. Updating `env_buf[0].value` per iteration is
    /// what makes the loop variable visible to the next body eval.
    binder_iter: struct {
        kind: BinderKind,
        body_idx: Ast.NodeIndex,
        inner_env: *Env,
        env_buf: []Env.Binding,
        xs_vec: []const Value,
        /// Pre-allocated for `map`/`filter` to `xs_vec.len`. Empty
        /// slice for `any`/`all` (they don't accumulate).
        accumulator: []Value,
        /// Number of slots in `accumulator` filled so far. Equals `i`
        /// for `map`; can lag for `filter` (truthy-only); unused for
        /// `any`/`all`.
        accumulator_count: u32,
        /// Index of the element we just finished evaluating the body
        /// against. The first invocation runs after `xs_vec[0]`'s body
        /// has evaluated, so `i == 0` on first entry.
        i: u32,
        /// Cached `xs_vec.len` so the iteration loop doesn't re-read
        /// the slice header on every step.
        n: u32,
    },
};

fn processEval(
    a: Allocator,
    gpa: Allocator,
    tree: *const Ast.Tree,
    e: anytype,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
    schema: Schema.Schema,
) Error!void {
    const idx = e.idx;
    const env = e.env;
    switch (tree.tagOf(idx)) {
        .number => try values.append(gpa, .{ .number = tree.numberOf(idx) }),
        .number_i64 => try values.append(gpa, .{ .integer_i64 = tree.numberI64Of(idx) }),
        .number_u64 => try values.append(gpa, .{ .integer_u64 = tree.numberU64Of(idx) }),
        .number_with_unit => {
            // Safe-expression evaluation drops the unit; the unit is opaque
            // metadata at the AST layer and the closed expr vocabulary
            // operates on numeric values.
            const nu = tree.numberWithUnitOf(idx);
            try values.append(gpa, .{ .number = nu.value });
        },
        .boolean_true => try values.append(gpa, .{ .boolean = true }),
        .boolean_false => try values.append(gpa, .{ .boolean = false }),
        .nil => try values.append(gpa, .nil),
        .date => try values.append(gpa, .{ .date = tree.dateOf(idx) }),
        .time => try values.append(gpa, .{ .time = tree.timeOf(idx) }),
        .string => {
            const si: Ast.StringIndex = @enumFromInt(tree.dataOf(idx).single);
            try values.append(gpa, .{ .string = tree.stringSlice(si) });
        },
        .keyword => {
            const si: Ast.StringIndex = @enumFromInt(tree.dataOf(idx).single);
            try values.append(gpa, .{ .keyword = tree.stringSlice(si) });
        },
        .symbol => {
            const si: Ast.StringIndex = @enumFromInt(tree.dataOf(idx).single);
            const v = env.lookup(tree.stringSlice(si)) orelse return error.UnknownBinding;
            try values.append(gpa, v);
        },
        .vector => {
            const elements = tree.vectorElements(idx);
            try frames.append(gpa, .{ .child_walk = .{
                .items = elements,
                .consumed = 0,
                .env = env,
                .then = .{ .vec_collect = .{ .count = @intCast(elements.len) } },
            } });
        },
        .form => try scheduleForm(a, gpa, tree, idx, env, frames, values, schema),
        .kvpair => return error.KeywordInExpressionArgs,
    }
}

fn scheduleForm(
    a: Allocator,
    gpa: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    env: *const Env,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
    schema: Schema.Schema,
) Error!void {
    const hdr = tree.formHeader(idx);

    if (hdr.namespace == null) {
        if (special_forms.get(hdr.head)) |sf| switch (sf) {
            .let => return scheduleLet(a, gpa, tree, hdr, env, frames),
            .@"if" => return scheduleIf(gpa, tree, hdr, env, frames),
            .cond => return scheduleCond(gpa, tree, hdr, env, frames, values),
            .@"and" => return scheduleAnd(gpa, tree, hdr, env, frames, values),
            .@"or" => return scheduleOr(gpa, tree, hdr, env, frames, values),
            .binder => |kind| return scheduleBinder(kind, gpa, tree, hdr, env, frames),
        };
    }

    // Resolve labeled args via the schema's shared resolver. When the
    // head doesn't resolve to an expr-func, fall through to the
    // form-as-data pass-through path — building a `Value.form` lets
    // plugin expr-funcs receive `(todo …)` literals as arguments. The
    // `ambiguous` lookup still feeds the dispatch path so it surfaces
    // the existing `AmbiguousFunction` error.
    const lookup = schema.lookupExprFunc(hdr.head, hdr.namespace);
    if (lookup == .not_found) return scheduleFormCollect(a, gpa, tree, hdr, env, frames);

    const positional: []const Ast.NodeIndex = positional: {
        switch (lookup) {
            .found => |hit| {
                const r = try Schema.resolveExprArgs(a, hit.func.*, tree, hdr);
                switch (r) {
                    .ok => |ok| break :positional ok.positional,
                    .err => return error.KeywordInExpressionArgs,
                }
            },
            else => break :positional hdr.children,
        }
    };

    // Even on the fallback path, a stray kvpair is a runtime error —
    // matches pre-resolver behaviour for unknown heads.
    for (positional) |c| {
        if (tree.tagOf(c) == .kvpair) return error.KeywordInExpressionArgs;
    }

    const argc: u32 = @intCast(positional.len);
    try frames.append(gpa, .{ .child_walk = .{
        .items = positional,
        .consumed = 0,
        .env = env,
        .then = .{ .apply_form = .{ .head = hdr.head, .namespace = hdr.namespace orelse "", .argc = argc } },
    } });
}

/// Advance one `child_walk`: evaluate the next child, or, once they are
/// all done, hand off to the terminal frame that consumes their values.
///
/// Two frames live at a time (this walk plus the child being evaluated),
/// regardless of how many children there are — see `Frame.child_walk`.
fn processChildWalk(
    gpa: Allocator,
    cw: anytype,
    frames: *std.ArrayList(Frame),
) Error!void {
    std.debug.assert(cw.consumed <= cw.items.len);
    if (cw.consumed == cw.items.len) {
        switch (cw.then) {
            .vec_collect => |t| try frames.append(gpa, .{ .vec_collect = t }),
            .apply_form => |t| try frames.append(gpa, .{ .apply_form = t }),
            .form_collect => |t| try frames.append(gpa, .{ .form_collect = t }),
        }
        return;
    }
    const next = cw.items[cw.consumed];
    try frames.append(gpa, .{ .child_walk = .{
        .items = cw.items,
        .consumed = cw.consumed + 1,
        .env = cw.env,
        .then = cw.then,
    } });
    // Pushed last, so it is popped first and its value lands before the
    // walk resumes — source order, preserved.
    try frames.append(gpa, .{ .eval = .{ .idx = next, .env = cw.env } });
}

/// Form-as-data pass-through. Walks `hdr.children`, separating
/// positionals from kvpairs in source order, schedules eval frames
/// for every value, and a trailing `form_collect` frame that
/// assembles the resulting `Value.form`. Used when the head doesn't
/// resolve to an expr-func — i.e. when a `(todo …)` literal appears
/// in expression position.
fn scheduleFormCollect(
    a: Allocator,
    gpa: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    env: *const Env,
    frames: *std.ArrayList(Frame),
) Error!void {
    // `keys[i] == null` ⇒ children[i] is positional; non-null ⇒ kvpair
    // with that key (stored as a tree-string slice; deepCopyValue
    // dupes it at the end of eval). `items[i]` is the node whose value
    // occupies that slot — a kvpair contributes its value, not itself.
    const keys = try a.alloc(?[]const u8, hdr.children.len);
    const items = try a.alloc(Ast.NodeIndex, hdr.children.len);
    for (hdr.children, 0..) |c, i| {
        if (tree.tagOf(c) == .kvpair) {
            const kv = tree.kvpairHeader(c);
            keys[i] = kv.key;
            items[i] = kv.value;
        } else {
            keys[i] = null;
            items[i] = c;
        }
    }

    try frames.append(gpa, .{ .child_walk = .{
        .items = items,
        .consumed = 0,
        .env = env,
        .then = .{ .form_collect = .{
            .head = hdr.head,
            .namespace = hdr.namespace orelse "",
            .keys = keys,
        } },
    } });
}

/// Pop the trailing `keys.len` values off `values` and assemble them into
/// a `Value.form`, splitting positionals (`keys[i] == null`) from kvpairs
/// (`keys[i]` = key) in source order. Shared by the tree path's
/// `processFormCollect` and the binary path's `processFormCollectWalk`:
/// the two frame shapes differ (cursor iter vs. none) but the final
/// stack → `Value.form` assembly is identical.
///
/// The `values.items.len >= total` assert precedes the `base` subtraction
/// so the invariant is checked before the usize arithmetic that would
/// otherwise wrap on underflow. It is an internal stack-discipline
/// invariant — the scheduler pushed exactly `total` eval frames ahead of
/// the collect frame — never user input.
fn assembleFormValue(
    a: Allocator,
    gpa: Allocator,
    head: []const u8,
    namespace: []const u8,
    keys: []const ?[]const u8,
    values: *std.ArrayList(Value),
) Error!void {
    const total = keys.len;
    std.debug.assert(values.items.len >= total);
    const base = values.items.len - total;

    var positional_count: usize = 0;
    for (keys) |k| {
        if (k == null) positional_count += 1;
    }
    const kv_count = total - positional_count;

    const children = try a.alloc(Value, positional_count);
    const kvs = try a.alloc(KvPair, kv_count);
    var ci: usize = 0;
    var ki: usize = 0;
    for (keys, 0..) |k, i| {
        const v = values.items[base + i];
        if (k) |key| {
            kvs[ki] = .{ .key = key, .value = v };
            ki += 1;
        } else {
            children[ci] = v;
            ci += 1;
        }
    }
    // Pair the entry-side `values.items.len >= total` with a positive-
    // space post-condition: every allocated slot got filled exactly
    // once. Mismatch would mean the source-order/key bookkeeping above
    // disagrees with the count loop's tally.
    std.debug.assert(ci == positional_count);
    std.debug.assert(ki == kv_count);
    values.items.len = base;
    try values.append(gpa, .{ .form = .{
        .head = head,
        .namespace = namespace,
        .children = children,
        .kvpairs = kvs,
    } });
}

fn processFormCollect(
    a: Allocator,
    gpa: Allocator,
    fc: anytype,
    values: *std.ArrayList(Value),
) Error!void {
    try assembleFormValue(a, gpa, fc.head, fc.namespace, fc.keys, values);
}

fn scheduleLet(
    a: Allocator,
    gpa: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    env: *const Env,
    frames: *std.ArrayList(Frame),
) Error!void {
    if (hdr.children.len != 2) return error.ArityMismatch;
    const binds_idx = hdr.children[0];
    if (tree.tagOf(binds_idx) == .kvpair) return error.InvalidLetBinding;
    if (tree.tagOf(binds_idx) != .vector) return error.InvalidLetBinding;
    const binds = tree.vectorElements(binds_idx);
    if (binds.len % 2 != 0) return error.InvalidLetBinding;

    const pair_count: u32 = @intCast(binds.len / 2);

    const env_buf = try a.alloc(Env.Binding, pair_count);
    const inner_env = try a.create(Env);
    inner_env.* = .{ .parent = env, .bindings = env_buf[0..0] };

    const body_idx = hdr.children[1];
    if (tree.tagOf(body_idx) == .kvpair) return error.InvalidLetBinding;

    try frames.append(gpa, .{ .eval = .{ .idx = body_idx, .env = inner_env } });
    var i: usize = pair_count;
    while (i > 0) {
        i -= 1;
        const name_idx = binds[2 * i];
        const value_idx = binds[2 * i + 1];
        if (tree.tagOf(name_idx) != .symbol) return error.InvalidLetBinding;
        const name_si: Ast.StringIndex = @enumFromInt(tree.dataOf(name_idx).single);
        const name = tree.stringSlice(name_si);
        try frames.append(gpa, .{ .let_commit = .{
            .name = name,
            .env = inner_env,
            .env_buf = env_buf,
            .idx = @intCast(i),
        } });
        try frames.append(gpa, .{ .eval = .{ .idx = value_idx, .env = inner_env } });
    }
}

fn scheduleIf(
    gpa: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    env: *const Env,
    frames: *std.ArrayList(Frame),
) Error!void {
    if (hdr.children.len < 2 or hdr.children.len > 3) return error.ArityMismatch;
    const test_idx = hdr.children[0];
    const then_idx = hdr.children[1];
    if (tree.tagOf(test_idx) == .kvpair) return error.KeywordInExpressionArgs;
    if (tree.tagOf(then_idx) == .kvpair) return error.KeywordInExpressionArgs;
    var has_else = false;
    var else_idx: Ast.NodeIndex = then_idx; // placeholder
    if (hdr.children.len == 3) {
        else_idx = hdr.children[2];
        if (tree.tagOf(else_idx) == .kvpair) return error.KeywordInExpressionArgs;
        has_else = true;
    }

    try frames.append(gpa, .{ .if_select = .{
        .then_idx = then_idx,
        .else_idx = else_idx,
        .has_else = has_else,
        .env = env,
    } });
    try frames.append(gpa, .{ .eval = .{ .idx = test_idx, .env = env } });
}

fn scheduleCond(
    gpa: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    env: *const Env,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
) Error!void {
    if (hdr.children.len % 2 != 0) return error.InvalidCondClause;
    if (hdr.children.len == 0) {
        try values.append(gpa, .nil);
        return;
    }
    const t_idx = hdr.children[0];
    const v_idx = hdr.children[1];
    if (tree.tagOf(t_idx) == .kvpair) return error.KeywordInExpressionArgs;
    if (tree.tagOf(v_idx) == .kvpair) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .cond_select = .{
        .value_idx = v_idx,
        .remaining = hdr.children[2..],
        .env = env,
    } });
    try frames.append(gpa, .{ .eval = .{ .idx = t_idx, .env = env } });
}

fn scheduleAnd(
    gpa: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    env: *const Env,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
) Error!void {
    if (hdr.children.len == 0) {
        // Zero-arg `(and)` ≡ true. Push the literal directly — there is
        // no synthetic node in this tree to schedule an eval against.
        try values.append(gpa, .{ .boolean = true });
        return;
    }
    const first = hdr.children[0];
    if (tree.tagOf(first) == .kvpair) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .and_check = .{ .remaining = hdr.children[1..], .env = env } });
    try frames.append(gpa, .{ .eval = .{ .idx = first, .env = env } });
}

fn scheduleOr(
    gpa: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    env: *const Env,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
) Error!void {
    if (hdr.children.len == 0) {
        // Zero-arg `(or)` ≡ false.
        try values.append(gpa, .{ .boolean = false });
        return;
    }
    const first = hdr.children[0];
    if (tree.tagOf(first) == .kvpair) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .or_check = .{ .remaining = hdr.children[1..], .env = env } });
    try frames.append(gpa, .{ .eval = .{ .idx = first, .env = env } });
}

/// Schedule a higher-order binder form. The 1-symbol kinds
/// (`map`/`filter`/`any`/`all`) have arity 3: child 0 is `[name]`,
/// child 1 is `xs`, child 2 is the body. `fold` is arity 4: child 0
/// is `[acc x]` (two distinct symbols), child 1 is `init`, child 2
/// is `xs`, child 3 is the body. Setup pops the evaluated input(s)
/// off the value stack and schedules the iteration loop.
fn scheduleBinder(
    kind: BinderKind,
    gpa: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    env: *const Env,
    frames: *std.ArrayList(Frame),
) Error!void {
    if (kind == .fold) {
        if (hdr.children.len != 4) return error.ArityMismatch;
        const binder_idx = hdr.children[0];
        const init_idx = hdr.children[1];
        const xs_idx = hdr.children[2];
        const body_idx = hdr.children[3];

        // [acc x] — literal two-symbol vector, distinct names. Same
        // strictness as the 1-symbol binders: non-vector binder,
        // wrong length, or non-symbol element is a shape error, not
        // a type error.
        if (tree.tagOf(binder_idx) != .vector) return error.InvalidBinderShape;
        const binder_elems = tree.vectorElements(binder_idx);
        if (binder_elems.len != 2) return error.InvalidBinderShape;
        if (tree.tagOf(binder_elems[0]) != .symbol) return error.InvalidBinderShape;
        if (tree.tagOf(binder_elems[1]) != .symbol) return error.InvalidBinderShape;
        const acc_si: Ast.StringIndex = @enumFromInt(tree.dataOf(binder_elems[0]).single);
        const x_si: Ast.StringIndex = @enumFromInt(tree.dataOf(binder_elems[1]).single);
        const acc_name = tree.stringSlice(acc_si);
        const x_name = tree.stringSlice(x_si);
        // Distinct names: `[acc acc]` would make symbol lookup
        // ambiguous (env_buf[0] is shadowed by env_buf[1]), so we
        // reject up front.
        if (std.mem.eql(u8, acc_name, x_name)) return error.InvalidBinderShape;

        if (tree.tagOf(init_idx) == .kvpair) return error.KeywordInExpressionArgs;
        if (tree.tagOf(xs_idx) == .kvpair) return error.KeywordInExpressionArgs;
        if (tree.tagOf(body_idx) == .kvpair) return error.KeywordInExpressionArgs;

        // LIFO push: eval(init) runs first (top), then eval(xs),
        // then binder_setup. After both evals, the value stack is
        // (top → bottom) [xs_val, init_val]; setup pops xs first,
        // then init.
        try frames.append(gpa, .{ .binder_setup = .{
            .kind = .fold,
            .binder_name = x_name,
            .binder_acc_name = acc_name,
            .body_idx = body_idx,
            .env_outer = env,
        } });
        try frames.append(gpa, .{ .eval = .{ .idx = xs_idx, .env = env } });
        try frames.append(gpa, .{ .eval = .{ .idx = init_idx, .env = env } });
        return;
    }

    if (hdr.children.len != 3) return error.ArityMismatch;
    const binder_idx = hdr.children[0];
    const xs_idx = hdr.children[1];
    const body_idx = hdr.children[2];

    // The binder vector is a syntactic, never-evaluated subnode: a
    // literal vector containing exactly one symbol. `(map foo xs body)`
    // and `(map [1] xs body)` are rejected up front.
    if (tree.tagOf(binder_idx) != .vector) return error.InvalidBinderShape;
    const binder_elems = tree.vectorElements(binder_idx);
    if (binder_elems.len != 1) return error.InvalidBinderShape;
    if (tree.tagOf(binder_elems[0]) != .symbol) return error.InvalidBinderShape;
    const name_si: Ast.StringIndex = @enumFromInt(tree.dataOf(binder_elems[0]).single);
    const binder_name = tree.stringSlice(name_si);

    // xs and body each reject paired keyword children — same posture
    // as `if`/`cond` for expression-position kvpairs.
    if (tree.tagOf(xs_idx) == .kvpair) return error.KeywordInExpressionArgs;
    if (tree.tagOf(body_idx) == .kvpair) return error.KeywordInExpressionArgs;

    // Order: setup deferred until xs evaluates. LIFO push means
    // eval(xs) runs first, then binder_setup pops the resulting vector.
    try frames.append(gpa, .{ .binder_setup = .{
        .kind = kind,
        .binder_name = binder_name,
        .binder_acc_name = null,
        .body_idx = body_idx,
        .env_outer = env,
    } });
    try frames.append(gpa, .{ .eval = .{ .idx = xs_idx, .env = env } });
}

/// Per-loop heap state shared by both binder setup paths: the inner Env
/// (whose `bindings` alias `env_buf`), the binding slot(s), and the
/// map/filter accumulator. Built by `initBinderLoopState`.
const BinderLoopState = struct {
    inner_env: *Env,
    env_buf: []Env.Binding,
    accumulator: []Value,
};

/// Allocate a binder loop's per-iteration state. Fold gets two slots
/// [acc, x] in source order so backward symbol lookup finds the loop
/// variable before the accumulator; map/filter/any/all get one slot [x].
/// map/filter pre-size the accumulator to `n` (map fills all, filter the
/// truthy prefix); any/all/fold don't accumulate. Precondition: `n > 0`
/// — empty input is answered by `binderEmptyResult` before any alloc.
/// Identical on both eval paths.
fn initBinderLoopState(
    a: Allocator,
    kind: BinderKind,
    binder_name: []const u8,
    binder_acc_name: ?[]const u8,
    env_outer: *const Env,
    xs_vec: []const Value,
    init_val: ?Value,
    n: u32,
) Error!BinderLoopState {
    std.debug.assert(n > 0);
    const env_buf: []Env.Binding = switch (kind) {
        .fold => blk: {
            const buf = try a.alloc(Env.Binding, 2);
            buf[0] = .{ .name = binder_acc_name.?, .value = init_val.? };
            buf[1] = .{ .name = binder_name, .value = xs_vec[0] };
            break :blk buf;
        },
        else => blk: {
            const buf = try a.alloc(Env.Binding, 1);
            buf[0] = .{ .name = binder_name, .value = xs_vec[0] };
            break :blk buf;
        },
    };
    const inner_env = try a.create(Env);
    inner_env.* = .{ .parent = env_outer, .bindings = env_buf };
    const accumulator: []Value = switch (kind) {
        .map, .filter => try a.alloc(Value, n),
        .any, .all, .fold => &.{},
    };
    return .{ .inner_env = inner_env, .env_buf = env_buf, .accumulator = accumulator };
}

/// The binder's result for empty input — no iterations scheduled.
/// `(map [x] [] b)`/`(filter …)` → `[]`; `(any …)` → false (no truthy
/// seen); `(all …)` → true (vacuously satisfied); `(fold [acc x] init []
/// b)` → init (the left-fold identity). Identical on both eval paths.
fn binderEmptyResult(kind: BinderKind, init_val: ?Value) Value {
    return switch (kind) {
        .map, .filter => .{ .vector = &.{} },
        .any => .{ .boolean = false },
        .all => .{ .boolean = true },
        .fold => init_val.?,
    };
}

/// Outcome of folding one evaluated body value into a binder loop.
const BinderStep = union(enum) {
    /// Keep looping; the accumulator's filled-count is now this value.
    advance: u32,
    /// any/all short-circuited: the loop's result is this value.
    short_circuit: Value,
};

/// Fold one body value into the loop. map writes `accumulator[i]`;
/// filter appends the source element on a truthy body; any/all
/// short-circuit on the first truthy/falsy; fold no-ops here (its
/// accumulator lives in the env binding, advanced by
/// `advanceBinderBindings`). Identical on both eval paths.
fn binderAccumulate(
    kind: BinderKind,
    accumulator: []Value,
    xs_vec: []const Value,
    i: u32,
    accumulator_count: u32,
    body_val: Value,
) BinderStep {
    switch (kind) {
        .map => {
            accumulator[i] = body_val;
            return .{ .advance = i + 1 };
        },
        .filter => {
            if (body_val.isTruthy()) {
                accumulator[accumulator_count] = xs_vec[i];
                return .{ .advance = accumulator_count + 1 };
            }
            return .{ .advance = accumulator_count };
        },
        .any => {
            if (body_val.isTruthy()) return .{ .short_circuit = .{ .boolean = true } };
            return .{ .advance = accumulator_count };
        },
        .all => {
            if (!body_val.isTruthy()) return .{ .short_circuit = .{ .boolean = false } };
            return .{ .advance = accumulator_count };
        },
        .fold => return .{ .advance = accumulator_count },
    }
}

/// The binder's result once the final iteration completes without a
/// short-circuit. map/filter return their accumulator (filter trimmed to
/// the truthy `count`); any/all return their no-match default; fold
/// returns the last body value. Identical on both eval paths.
fn binderFinalResult(kind: BinderKind, accumulator: []const Value, count: u32, body_val: Value) Value {
    return switch (kind) {
        .map => .{ .vector = accumulator },
        .filter => .{ .vector = accumulator[0..count] },
        .any => .{ .boolean = false },
        .all => .{ .boolean = true },
        .fold => body_val,
    };
}

/// Install the next iteration's binding(s) by mutating `env_buf` in
/// place — inner_env.bindings aliases env_buf, so the next body eval
/// sees the new value(s) via symbol lookup. Fold additionally installs
/// the body's value as the next accumulator. Identical on both eval
/// paths.
fn advanceBinderBindings(kind: BinderKind, env_buf: []Env.Binding, xs_vec: []const Value, next_i: u32, body_val: Value) void {
    if (kind == .fold) {
        env_buf[0].value = body_val;
        env_buf[1].value = xs_vec[next_i];
    } else {
        env_buf[0].value = xs_vec[next_i];
    }
}

fn processBinderSetup(
    a: Allocator,
    gpa: Allocator,
    s: anytype,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
) Error!void {
    // After eval(xs) (and, for fold, eval(init) too) the value stack
    // is (top → bottom) [xs_val, init_val?]. Pop xs first and require
    // it to be a vector. Non-vector `xs` (e.g. `(map [x] 5 body)`) is
    // a `TypeMismatch`, not a binder-shape error — the binder shape
    // was fine syntactically, the runtime type is wrong.
    const fold_extra: usize = if (s.kind == .fold) 1 else 0;
    std.debug.assert(values.items.len >= 1 + fold_extra);
    const xs_val = values.pop().?;
    const xs_vec = try expectVector(xs_val);
    const init_val: ?Value = if (s.kind == .fold) values.pop().? else null;
    const n: u32 = @intCast(xs_vec.len);

    if (n == 0) {
        try values.append(gpa, binderEmptyResult(s.kind, init_val));
        return;
    }

    const loop = try initBinderLoopState(a, s.kind, s.binder_name, s.binder_acc_name, s.env_outer, xs_vec, init_val, n);

    try frames.append(gpa, .{ .binder_iter = .{
        .kind = s.kind,
        .body_idx = s.body_idx,
        .inner_env = loop.inner_env,
        .env_buf = loop.env_buf,
        .xs_vec = xs_vec,
        .accumulator = loop.accumulator,
        .accumulator_count = 0,
        .i = 0,
        .n = n,
    } });
    try frames.append(gpa, .{ .eval = .{ .idx = s.body_idx, .env = loop.inner_env } });
}

fn processBinderIter(
    gpa: Allocator,
    s: anytype,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
) Error!void {
    // Each binder_iter execution sits after exactly one body eval — by
    // construction (we push body's eval immediately after pushing
    // ourselves). Pop the body value; the shared helpers decide whether
    // to accumulate, short-circuit, or finish.
    std.debug.assert(values.items.len >= 1);
    const body_val = values.pop().?;

    const next_i: u32 = s.i + 1;
    var next_count: u32 = s.accumulator_count;
    switch (binderAccumulate(s.kind, s.accumulator, s.xs_vec, s.i, s.accumulator_count, body_val)) {
        .short_circuit => |v| {
            try values.append(gpa, v);
            return;
        },
        .advance => |c| next_count = c,
    }

    if (next_i == s.n) {
        try values.append(gpa, binderFinalResult(s.kind, s.accumulator, next_count, body_val));
        return;
    }

    advanceBinderBindings(s.kind, s.env_buf, s.xs_vec, next_i, body_val);

    // Re-push self with advanced state, then the next body eval.
    // Touching `s` directly would mutate a value-typed local; build a
    // fresh frame value instead.
    try frames.append(gpa, .{ .binder_iter = .{
        .kind = s.kind,
        .body_idx = s.body_idx,
        .inner_env = s.inner_env,
        .env_buf = s.env_buf,
        .xs_vec = s.xs_vec,
        .accumulator = s.accumulator,
        .accumulator_count = next_count,
        .i = next_i,
        .n = s.n,
    } });
    try frames.append(gpa, .{ .eval = .{ .idx = s.body_idx, .env = s.inner_env } });
}

fn processVecCollect(
    a: Allocator,
    gpa: Allocator,
    vc: VecCollect,
    values: *std.ArrayList(Value),
) Error!void {
    const count: usize = vc.count;
    // The scheduler pushes `count` eval frames before the matching
    // `vec_collect` — by the time we run, every element must be on
    // the value stack. Underflow would `values.pop().?` panic below
    // with an unrelated location; assert here so the wiring bug
    // surfaces at the source.
    std.debug.assert(values.items.len >= count);
    const elems = try a.alloc(Value, count);
    var i: usize = count;
    while (i > 0) {
        i -= 1;
        elems[i] = values.pop().?;
    }
    try values.append(gpa, .{ .vector = elems });
}

fn processApplyForm(
    a: Allocator,
    gpa: Allocator,
    af: ApplyForm,
    values: *std.ArrayList(Value),
    schema: Schema.Schema,
    runtime: ?*anyopaque,
) Error!void {
    const argc: usize = af.argc;
    // Scheduler pushes `argc` eval frames before the matching
    // apply_form. Labeled-call slot table is allocated to `argc`
    // entries — a mismatch would index out of bounds in the
    // permutation loop below.
    std.debug.assert(values.items.len >= argc);
    if (af.slots) |slots| std.debug.assert(slots.len == argc);

    const args = try a.alloc(Value, argc);
    var i: usize = argc;
    while (i > 0) {
        i -= 1;
        args[i] = values.pop().?;
    }
    // Labeled call: rearrange source-order args into slot order so the
    // function impl sees its declared positional contract.
    if (af.slots) |slots| {
        const final = try a.alloc(Value, argc);
        // Slots are a permutation of [0, argc): processFormWalk opens
        // labeled mode only at consumed==0 and rejects duplicate labels,
        // so by pigeonhole this loop writes every `final` entry exactly
        // once and none is read uninitialized. Assert it at the source so
        // a future regression in slot construction trips here, not as a
        // wrong result deep inside applyFunction.
        if (std.debug.runtime_safety) {
            for (slots, 0..) |s, k| {
                std.debug.assert(s < argc);
                for (slots[0..k]) |prev| std.debug.assert(prev != s);
            }
        }
        for (0..argc) |k| final[slots[k]] = args[k];
        const result = try applyFunction(a, af.head, af.namespace, final, schema, runtime);
        try values.append(gpa, result);
        return;
    }
    const result = try applyFunction(a, af.head, af.namespace, args, schema, runtime);
    try values.append(gpa, result);
}

fn processLetCommit(
    lc: LetCommit,
    values: *std.ArrayList(Value),
) void {
    // Scheduler always pairs `let_commit{idx=i}` with one eval(value)
    // that leaves a value on the stack, and `idx` is one of
    // 0..pair_count-1 by construction (binding loop in `scheduleLet`
    // / `scheduleLetBinary`). Without these the next two lines would
    // trap with an unrelated location on a wiring bug.
    std.debug.assert(values.items.len >= 1);
    std.debug.assert(lc.idx < lc.env_buf.len);

    const v = values.pop().?;
    lc.env_buf[lc.idx] = .{ .name = lc.name, .value = v };
    lc.env.bindings = lc.env_buf[0 .. lc.idx + 1];
}

fn processIfSelect(
    s: anytype,
    gpa: Allocator,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
) Error!void {
    const test_v = values.pop().?;
    if (test_v.isTruthy()) {
        try frames.append(gpa, .{ .eval = .{ .idx = s.then_idx, .env = s.env } });
    } else if (s.has_else) {
        try frames.append(gpa, .{ .eval = .{ .idx = s.else_idx, .env = s.env } });
    } else {
        try values.append(gpa, .nil);
    }
}

fn processCondSelect(
    s: anytype,
    gpa: Allocator,
    tree: *const Ast.Tree,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
) Error!void {
    const test_v = values.pop().?;
    if (test_v.isTruthy()) {
        try frames.append(gpa, .{ .eval = .{ .idx = s.value_idx, .env = s.env } });
        return;
    }
    if (s.remaining.len == 0) {
        try values.append(gpa, .nil);
        return;
    }
    const t_idx = s.remaining[0];
    const v_idx = s.remaining[1];
    if (tree.tagOf(t_idx) == .kvpair) return error.KeywordInExpressionArgs;
    if (tree.tagOf(v_idx) == .kvpair) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .cond_select = .{
        .value_idx = v_idx,
        .remaining = s.remaining[2..],
        .env = s.env,
    } });
    try frames.append(gpa, .{ .eval = .{ .idx = t_idx, .env = s.env } });
}

fn processAndCheck(
    s: anytype,
    gpa: Allocator,
    tree: *const Ast.Tree,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
) Error!void {
    const v = values.pop().?;
    if (!v.isTruthy()) {
        try values.append(gpa, v);
        return;
    }
    if (s.remaining.len == 0) {
        try values.append(gpa, v);
        return;
    }
    const next = s.remaining[0];
    if (tree.tagOf(next) == .kvpair) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .and_check = .{ .remaining = s.remaining[1..], .env = s.env } });
    try frames.append(gpa, .{ .eval = .{ .idx = next, .env = s.env } });
}

fn processOrCheck(
    s: anytype,
    gpa: Allocator,
    tree: *const Ast.Tree,
    frames: *std.ArrayList(Frame),
    values: *std.ArrayList(Value),
) Error!void {
    const v = values.pop().?;
    if (v.isTruthy()) {
        try values.append(gpa, v);
        return;
    }
    if (s.remaining.len == 0) {
        try values.append(gpa, .{ .boolean = false });
        return;
    }
    const next = s.remaining[0];
    if (tree.tagOf(next) == .kvpair) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .or_check = .{ .remaining = s.remaining[1..], .env = s.env } });
    try frames.append(gpa, .{ .eval = .{ .idx = next, .env = s.env } });
}

// ---------------------------------------------------------------------------
// Streaming evaluator (over Binary IR via BinaryCursor)
//
// Mirrors eval's iterative frame-stack architecture but walks the binary
// buffer directly via BinaryCursor — no intermediate Tree. Shares Value,
// Env, Result, Error, applyFunction with the tree path.
//
// The cursor is monotonic: each frame fully consumes its node's bytes, so
// when a parent walk-frame yields control to a child eval, the child
// consumes the child's bytes and the parent resumes with the cursor at
// exactly the byte its iter expects for next(). Walk frames carry the
// iter (a *Cursor + remaining counter) directly — no position
// save/restore is required.
// ---------------------------------------------------------------------------

const FrameBinary = union(enum) {
    /// Begin evaluation of one node. Cursor must be at view's payload when
    /// this frame runs.
    eval: struct {
        view: BinaryCursor.NodeView,
        env: *const Env,
    },

    /// Pop count values (in stack order; reverses to source order),
    /// allocate a vector, push that vector value.
    vec_collect: VecCollect,

    /// Pop argc values, dispatch via applyFunction, push the result.
    /// `namespace` is empty-slice when bare; convert at the lookup site.
    /// `slots` permutes a labeled call's source-order args into the
    /// function's declared positional order — `slots[i]` is the slot
    /// for source arg `i`. Null for positional calls.
    apply_form: ApplyForm,

    /// Pop one value, write to env_buf[idx], advance env.bindings.
    let_commit: LetCommit,

    /// Walk a vector's elements sequentially. Each iteration: read next
    /// elem via iter, push self+1, push eval. Final iteration: drain the
    /// vector's trailing comments (wire v5+) and push vec_collect.
    vec_walk: struct {
        iter: BinaryCursor.VectorIter,
        env: *const Env,
        consumed: u32,
        count: u32,
    },

    /// Walk a generic form's children sequentially. Each iteration: read
    /// next child via iter, push self+1, push eval. Final iteration:
    /// drain trailing comments and push apply_form.
    ///
    /// Mode is decided by the first child and then fixed: all positional,
    /// or all keyword (labeled). `labeled_sig` is non-null once a labeled
    /// call is recognised — labeled mode may only open on the first
    /// child, every child must then be a kvpair carrying a distinct
    /// label, and `slots[i]` holds the resolved target slot for
    /// source-arg `i`. The slots array is allocated when labeled mode
    /// opens. These invariants keep `slots` a permutation of [0, argc) so
    /// the reorder in processApplyForm never reads an uninitialized
    /// Value — enforced here because the binary bytes may be unvalidated.
    form_walk: struct {
        head: []const u8,
        namespace: []const u8,
        iter: BinaryCursor.ChildIter,
        env: *const Env,
        consumed: u32,
        argc: u32,
        labeled_sig: ?Plugin.ExprFunc.Signature = null,
        slots: ?[]u8 = null,
        /// Label keys seen so far, in call order. Kept because signature
        /// selection streams: a label that misses the signature chosen on
        /// the first child has to re-select against the whole prefix, and
        /// `slots` holds indices into the *old* signature by then. Keys
        /// borrow from the binary buffer, which outlives the walk.
        labels: ?[][]const u8 = null,
    },

    /// Form-as-data pass-through (binary path). Fires when a form's
    /// head doesn't resolve to a `Plugin.ExprFunc` — we walk children
    /// one at a time, evaluate each, and at the end build a
    /// `Value.form`. `keys[i]` is `null` for positional children and a
    /// kvpair key slice otherwise (in source order). Mirrors the tree
    /// path's `form_collect`.
    form_collect_walk: struct {
        head: []const u8,
        namespace: []const u8,
        iter: BinaryCursor.ChildIter,
        env: *const Env,
        consumed: u32,
        argc: u32,
        keys: []?[]const u8,
    },

    /// Walk let bindings vector pair-by-pair, then schedule body eval.
    /// Each iteration with idx<pair_count: read name + value_view, push
    /// self+1, let_commit, eval(value). When idx==pair_count: read body
    /// from form_iter and schedule eval(body) + form_drain.
    let_walk: struct {
        form_iter: BinaryCursor.ChildIter,
        inner_env: *Env,
        env_buf: []Env.Binding,
        binds_iter: BinaryCursor.VectorIter,
        idx: u32,
        pair_count: u32,
    },

    /// After if's test eval: pop value, choose branch.
    if_after_test: struct {
        iter: BinaryCursor.ChildIter,
        env: *const Env,
        has_else: bool,
    },

    /// After cond's predicate eval: pop value, dispatch.
    cond_after_pred: struct {
        iter: BinaryCursor.ChildIter,
        env: *const Env,
    },

    /// After and's child eval: short-circuit on falsy or recurse.
    and_after_child: struct {
        iter: BinaryCursor.ChildIter,
        env: *const Env,
    },

    /// First phase of a binder form on the binary path. Runs after
    /// `xs` evaluates. Pops the xs vector, reads the body's
    /// `NodeView` from `form_iter` (capturing `body_payload_pos`
    /// before consuming the body's bytes), `skipBody`s the body,
    /// drains the form to `post_form_pos`, then schedules the first
    /// iteration via `binder_iter_binary`. Empty `xs` produces the
    /// kind's identity result without scheduling.
    binder_setup_binary: struct {
        kind: BinderKind,
        /// Loop-variable symbol name. For fold this is the `x` half
        /// of `[acc x]`; for map/filter/any/all it is the sole symbol.
        binder_name: []const u8,
        /// Accumulator symbol name; non-null only for fold.
        binder_acc_name: ?[]const u8,
        form_iter: BinaryCursor.ChildIter,
        env_outer: *const Env,
        /// Fold-only: the already-evaluated `init` value, captured
        /// upstream by `fold_capture_init` before this frame ran.
        /// `null` for non-fold kinds (their setup pops only xs).
        init_val_captured: ?Value,
    },
    /// Fold-only intermediate frame on the binary path: bridges
    /// `eval(init)` and `eval(xs)` because each `form_iter.next()`
    /// requires the previous child's body to be consumed first. Pops
    /// init_val, advances form_iter to xs, then schedules
    /// `binder_setup_binary` with init_val captured.
    fold_capture_init: struct {
        binder_name: []const u8,
        binder_acc_name: []const u8,
        form_iter: BinaryCursor.ChildIter,
        env_outer: *const Env,
    },
    /// Per-iteration phase of a binder form on the binary path. The
    /// surrounding form has already been drained to `post_form_pos`,
    /// so this frame owns cursor position exclusively during the
    /// loop. Per iteration: pop body value, update accumulator /
    /// short-circuit, then either reset `cursor.pos = body_payload_pos`
    /// and push the next eval, or restore `cursor.pos = post_form_pos`
    /// and push the final result.
    binder_iter_binary: struct {
        kind: BinderKind,
        body_view: BinaryCursor.NodeView,
        /// Byte position of the body's variant payload. Saved at
        /// setup time before `skipBody` advances the cursor past
        /// body. Each iteration resets `cursor.pos` here so the
        /// next `eval{view: body_view}` re-reads body's bytes.
        body_payload_pos: u32,
        /// Cursor position after the surrounding form has been
        /// fully drained (skipBody on body + terminal iter.next()
        /// consumes trailing comments). Restored on exit so the
        /// caller sees the cursor where a normal walk would have
        /// left it.
        post_form_pos: u32,
        inner_env: *Env,
        env_buf: []Env.Binding,
        xs_vec: []const Value,
        accumulator: []Value,
        accumulator_count: u32,
        i: u32,
        n: u32,
    },
    /// After or's child eval: short-circuit on truthy or recurse.
    or_after_child: struct {
        iter: BinaryCursor.ChildIter,
        env: *const Env,
    },

    /// Drain a form's child iter: skipBody every remaining child, then
    /// consume trailing comments (a final iter.next() that returns null).
    /// Used to clean up after every special-form walk regardless of
    /// branch taken.
    form_drain: struct { iter: BinaryCursor.ChildIter },
};

/// Evaluate a single-root binary IR buffer as a safe expression. Returns
/// `error.MultipleRoots` if the binary does not have exactly one root — the
/// name is a slight misnomer: a zero-root buffer (all-comments or empty) also
/// yields `MultipleRoots`, not a distinct empty-input error. The
/// returned `Value` is fully owned by `result.arena` — string / keyword
/// / vector contents are deep-copied out of `bytes`, so callers do NOT
/// need to keep `bytes` alive past this call.
///
/// The error set is `BinaryError` (composes `Error`, `BinaryCursor.Error`,
/// and `MultipleRoots`); see the type definition above.
pub fn evalBinary(
    gpa: Allocator,
    bytes: []const u8,
    env: *const Env,
    schema: Schema.Schema,
) BinaryError!Result {
    return evalBinaryWithRuntime(gpa, bytes, env, schema, null);
}

/// Runtime-aware binary-IR evaluator. See `evalWithRuntime` for the
/// `runtime` parameter's contract.
pub fn evalBinaryWithRuntime(
    gpa: Allocator,
    bytes: []const u8,
    env: *const Env,
    schema: Schema.Schema,
    runtime: ?*anyopaque,
) BinaryError!Result {
    return evalBinaryWithRuntimeBudget(gpa, bytes, env, schema, runtime, .{});
}

/// Budget-parameterized variant of `evalBinaryWithRuntime`. See
/// `evalWithRuntimeBudget` for the `budget` contract.
pub fn evalBinaryWithRuntimeBudget(
    gpa: Allocator,
    bytes: []const u8,
    env: *const Env,
    schema: Schema.Schema,
    runtime: ?*anyopaque,
    budget: Budget,
) BinaryError!Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var cursor = try BinaryCursor.Cursor.init(bytes);
    // Pool index for the eval walk, on the result arena: every symbol and
    // form head below resolves through the cursor, which is O(pool
    // entries) per lookup without one. The arena owns it, so there is no
    // free to pair — it dies with the `Result`. It is charged to
    // `budget.bytes` like everything else on this arena, which is the
    // honest accounting: 4 bytes per pool entry against a 64 MiB ceiling.
    const pool_index = try a.alloc(u32, cursor.poolIndexLen());
    cursor.indexPools(pool_index);
    var root_iter = try cursor.rootIter();
    if (root_iter.remaining != 1) return error.MultipleRoots; // != 1 also catches zero roots (name is a slight misnomer for the empty case)
    const root_view = (try root_iter.next()) orelse unreachable;

    var frames: std.ArrayList(FrameBinary) = .empty;
    defer frames.deinit(gpa);
    var values: std.ArrayList(Value) = .empty;
    defer values.deinit(gpa);

    try frames.append(gpa, .{ .eval = .{ .view = root_view, .env = env } });

    for (0..budget.steps) |_| {
        if (frames.items.len == 0) break;
        if (frames.items.len > MAX_FRAMES) return error.DepthExceeded;
        if (arena.queryCapacity() > budget.bytes) return error.MemoryBudgetExceeded;

        const f = frames.pop().?;
        switch (f) {
            .eval => |e| try processEvalBinary(a, gpa, &cursor, e, &frames, &values, schema),
            .vec_collect => |vc| try processVecCollect(a, gpa, vc, &values),
            .apply_form => |af| try processApplyForm(a, gpa, af, &values, schema, runtime),
            .let_commit => |lc| processLetCommit(lc, &values),
            .vec_walk => |vw| try processVecWalk(gpa, vw, &frames),
            .form_walk => |fw| try processFormWalk(a, gpa, fw, &frames, schema),
            .form_collect_walk => |fc| try processFormCollectWalk(a, gpa, fc, &frames, &values),
            .let_walk => |lw| try processLetWalk(gpa, &cursor, lw, &frames),
            .if_after_test => |s| try processIfAfterTest(gpa, &cursor, s, &frames, &values),
            .cond_after_pred => |s| try processCondAfterPred(gpa, &cursor, s, &frames, &values),
            .and_after_child => |s| try processAndAfterChild(gpa, s, &frames, &values),
            .or_after_child => |s| try processOrAfterChild(gpa, s, &frames, &values),
            .form_drain => |s| try processFormDrain(s.iter),
            .binder_setup_binary => |s| try processBinderSetupBinary(a, gpa, &cursor, s, &frames, &values),
            .binder_iter_binary => |s| try processBinderIterBinary(gpa, &cursor, s, &frames, &values),
            .fold_capture_init => |s| try processFoldCaptureInit(gpa, s, &frames, &values),
        }
    } else {
        return error.DepthExceeded;
    }

    std.debug.assert(values.items.len == 1);
    // Strings / keywords on the value stack point into `bytes`. Dupe before
    // returning so the caller can free `bytes`.
    const final = try deepCopyValue(a, values.items[0]);
    // Mirror the tree path: catch an over-budget result after the copy.
    if (arena.queryCapacity() > budget.bytes) return error.MemoryBudgetExceeded;
    return .{ .arena = arena, .value = final };
}

fn processEvalBinary(
    a: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    e: anytype,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
    schema: Schema.Schema,
) BinaryError!void {
    const view = e.view;
    const env = e.env;
    switch (view.kind) {
        .nil => {
            try BinaryCursor.readNil(cursor, view);
            try values.append(gpa, .nil);
        },
        .boolean => {
            const b = try BinaryCursor.readBoolean(cursor, view);
            try values.append(gpa, .{ .boolean = b });
        },
        .number => switch (view.tag) {
            .number => {
                const x = try BinaryCursor.readNumber(cursor, view);
                try values.append(gpa, .{ .number = x });
            },
            .number_i64 => {
                const x = try BinaryCursor.readNumberI64(cursor, view);
                try values.append(gpa, .{ .integer_i64 = x });
            },
            .number_u64 => {
                const x = try BinaryCursor.readNumberU64(cursor, view);
                try values.append(gpa, .{ .integer_u64 = x });
            },
            else => unreachable, // view.kind == .number gates the three tags above
        },
        .number_with_unit => {
            // Safe-expression evaluation drops the unit; matches
            // processEval behaviour for `Tag.number_with_unit`.
            const nu = try BinaryCursor.readNumberWithUnit(cursor, view);
            try values.append(gpa, .{ .number = nu.value });
        },
        .date => {
            const d = try BinaryCursor.readDate(cursor, view);
            try values.append(gpa, .{ .date = d });
        },
        .time => {
            const t = try BinaryCursor.readTime(cursor, view);
            try values.append(gpa, .{ .time = t });
        },
        .string => {
            const s = try BinaryCursor.readString(cursor, view);
            try values.append(gpa, .{ .string = s });
        },
        .keyword => {
            const k = try BinaryCursor.readKeyword(cursor, view);
            try values.append(gpa, .{ .keyword = k });
        },
        .symbol => {
            const sym = try BinaryCursor.readSymbol(cursor, view);
            const v = env.lookup(sym) orelse return error.UnknownBinding;
            try values.append(gpa, v);
        },
        .vector => {
            const iter = try BinaryCursor.readVector(cursor, view);
            const n = iter.remaining;
            try frames.append(gpa, .{ .vec_walk = .{
                .iter = iter,
                .env = env,
                .consumed = 0,
                .count = n,
            } });
        },
        .form => try scheduleFormBinary(a, gpa, cursor, view, env, frames, values, schema),
    }
}

fn scheduleFormBinary(
    a: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    view: BinaryCursor.NodeView,
    env: *const Env,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
    schema: Schema.Schema,
) BinaryError!void {
    const fv = try BinaryCursor.readForm(cursor, view);
    const head = fv.head;

    if (fv.namespace == null) {
        if (special_forms.get(head)) |sf| switch (sf) {
            .let => return scheduleLetBinary(a, gpa, cursor, fv, env, frames),
            .@"if" => return scheduleIfBinary(gpa, fv, env, frames),
            .cond => return scheduleCondBinary(gpa, fv, env, frames, values),
            .@"and" => return scheduleAndBinary(gpa, fv, env, frames, values),
            .@"or" => return scheduleOrBinary(gpa, fv, env, frames, values),
            .binder => |kind| return scheduleBinderBinary(kind, gpa, cursor, fv, env, frames),
        };
    }

    const argc = fv.children.remaining;

    // Form-as-data pass-through: when the head doesn't resolve to a
    // Plugin.ExprFunc, the binary path collects evaluated children +
    // kvpairs into a Value.form (mirrors the tree path's
    // `scheduleFormCollect`). The `.ambiguous` arm continues down the
    // dispatch path so it surfaces the existing AmbiguousFunction
    // error.
    if (schema.lookupExprFunc(head, fv.namespace) == .not_found) {
        const keys = try a.alloc(?[]const u8, argc);
        for (keys) |*k| k.* = null;
        try frames.append(gpa, .{ .form_collect_walk = .{
            .head = head,
            .namespace = fv.namespace orelse "",
            .iter = fv.children,
            .env = env,
            .consumed = 0,
            .argc = argc,
            .keys = keys,
        } });
        return;
    }

    // Generic form: form_walk reads children one-by-one and finally pushes
    // apply_form. Initial argc = current iter.remaining (before any next()).
    // Labeled-call detection happens lazily in `processFormWalk` once we
    // see whether the first child is a kvpair.
    try frames.append(gpa, .{ .form_walk = .{
        .head = head,
        .namespace = fv.namespace orelse "",
        .iter = fv.children,
        .env = env,
        .consumed = 0,
        .argc = argc,
    } });
}

fn processFormCollectWalk(
    a: Allocator,
    gpa: Allocator,
    fc: anytype,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    var iter = fc.iter;
    if (fc.consumed == fc.argc) {
        // Final: drain trailing comments, then build the Value.form by
        // popping `keys.len` (== argc) values off the value stack. Source
        // order is bottom-up (first eval landed first), so the popped
        // values are already in source order. `assembleFormValue` is
        // shared with the tree path.
        _ = try iter.next();
        try assembleFormValue(a, gpa, fc.head, fc.namespace, fc.keys, values);
        return;
    }

    const entry = (try iter.next()) orelse unreachable;
    var keys = fc.keys;
    if (entry.kind == .keyword) {
        keys[fc.consumed] = try a.dupe(u8, entry.key.?);
    }
    try frames.append(gpa, .{ .form_collect_walk = .{
        .head = fc.head,
        .namespace = fc.namespace,
        .iter = iter,
        .env = fc.env,
        .consumed = fc.consumed + 1,
        .argc = fc.argc,
        .keys = keys,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = entry.value, .env = fc.env } });
}

fn processFormWalk(
    a: Allocator,
    gpa: Allocator,
    fw: anytype,
    frames: *std.ArrayList(FrameBinary),
    schema: Schema.Schema,
) BinaryError!void {
    var iter = fw.iter;
    if (fw.consumed == fw.argc) {
        // Drain trailing comments via final iter.next() (returns null).
        _ = try iter.next();
        try frames.append(gpa, .{ .apply_form = .{
            .head = fw.head,
            .namespace = fw.namespace,
            .argc = fw.argc,
            .slots = fw.slots,
        } });
        return;
    }
    const entry = (try iter.next()) orelse unreachable;

    // Decide labeled vs positional mode on the first child. This
    // evaluator runs on binary bytes that may never have been validated
    // (the read-only wasm artifact walks the IR directly), so it enforces
    // the labeled-call contract itself rather than trusting an upstream
    // validator: a keyword may only open labeled mode as the very first
    // child, and no label may repeat. Both rules keep `slots` a total
    // permutation of [0, argc) so processApplyForm writes every entry of
    // `final` exactly once.
    var labeled_sig = fw.labeled_sig;
    var slots = fw.slots;
    var labels = fw.labels;
    if (entry.kind == .keyword) {
        // A keyword after one or more positionals is a mixed call:
        // opening labeled mode here would leave `slots[0..consumed]`
        // uninitialized, and processApplyForm would index `final`
        // with those garbage slot values. Reject before opening it.
        if (labeled_sig == null and fw.consumed != 0) return error.KeywordInExpressionArgs;
        const key = entry.key orelse return error.KeywordInExpressionArgs;

        if (labels == null) labels = try a.alloc([]const u8, fw.argc);
        labels.?[fw.consumed] = key;

        // Select — or re-select — the signature against every label seen so
        // far, not just this one. Overload resolution has to consider all
        // labeled signatures the way the tree path does (`Schema.resolveExprArgs`
        // matches the label set exactly); committing to the first
        // arity-matching signature and hard-erroring on the first label it
        // lacks made `(poly :y 1)` evaluate on a tree and fail on the IR —
        // and `sjon-binary.wasm` evaluates exclusively here. Selection is
        // deferred rather than eager because labels stream: the full set is
        // only known once the children have passed.
        if (labeled_sig == null or labeled_sig.?.indexOfLabel(key) == null) {
            const ns: ?[]const u8 = if (fw.namespace.len == 0) null else fw.namespace;
            labeled_sig = selectLabeledSignature(schema, fw.head, ns, fw.argc, labels.?[0 .. fw.consumed + 1]) orelse
                return error.KeywordInExpressionArgs;
            if (slots == null) slots = try a.alloc(u8, fw.argc);
            // The prefix's slot indices belong to the signature we just
            // left; re-resolve them against the new one. Every lookup is
            // total — selection accepted this signature precisely because
            // it names all of these labels.
            for (labels.?[0 .. fw.consumed + 1], 0..) |l, i| {
                slots.?[i] = labeled_sig.?.indexOfLabel(l).?;
            }
        } else {
            slots.?[fw.consumed] = labeled_sig.?.indexOfLabel(key).?;
        }

        // Reject duplicate labels. The slots resolved so far are the
        // seen-set — each holds a distinct target index by this very
        // check — so a repeat would leave one declared slot unwritten and
        // processApplyForm would read an uninitialized Value. O(argc²)
        // with argc ≤ 255 is negligible and needs no extra allocation.
        for (slots.?[0..fw.consumed]) |prev| {
            if (prev == slots.?[fw.consumed]) return error.KeywordInExpressionArgs;
        }
    } else if (labeled_sig != null) {
        // Already in labeled mode but received a positional — strict
        // mixing rule. Tree validator emits expr_mixed_args; the
        // evaluator's runtime equivalent is the kvpair-arg error.
        return error.KeywordInExpressionArgs;
    }

    try frames.append(gpa, .{ .form_walk = .{
        .head = fw.head,
        .namespace = fw.namespace,
        .iter = iter,
        .env = fw.env,
        .consumed = fw.consumed + 1,
        .argc = fw.argc,
        .labeled_sig = labeled_sig,
        .slots = slots,
        .labels = labels,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = entry.value, .env = fw.env } });
}

/// The first labeled signature of `head` that accepts `argc` arguments and
/// names every label in `wanted`.
///
/// The binary analogue of `Schema.resolveExprArgs`' phase 2. With arity
/// fixed and the labels distinct (the caller's duplicate check guarantees
/// that), "names every wanted label" becomes an exact set match once the
/// call is complete — which is the tree path's rule.
fn selectLabeledSignature(
    schema: Schema.Schema,
    head: []const u8,
    ns: ?[]const u8,
    argc: u32,
    wanted: []const []const u8,
) ?Plugin.ExprFunc.Signature {
    const hit = switch (schema.lookupExprFunc(head, ns)) {
        .found => |h| h,
        else => return null,
    };
    var it = hit.func.signatureIter();
    while (it.next()) |sig| {
        if (!sig.labeledEnabled() or !sig.checkArity(argc)) continue;
        const names_all = for (wanted) |w| {
            if (sig.indexOfLabel(w) == null) break false;
        } else true;
        if (names_all) return sig;
    }
    return null;
}

/// Drive an exhausted `VectorIter` to its null result so it consumes the
/// vector's trailing comments (wire v5+). The structural binary readers —
/// generic `vec_walk`, `let` bindings, and `map`/`filter`/`fold` binders —
/// read a fixed element count and stop *before* the terminating `next()`
/// that `VectorIter` relies on to drain end-of-body comments; this closes
/// that gap so the cursor lands at the next sibling. Asserts no elements
/// remain (callers reach here only after consuming every element).
fn drainVectorTrailing(iter: *BinaryCursor.VectorIter) BinaryError!void {
    std.debug.assert(iter.remaining == 0);
    const end = try iter.next();
    std.debug.assert(end == null);
}

fn processVecWalk(
    gpa: Allocator,
    vw: anytype,
    frames: *std.ArrayList(FrameBinary),
) BinaryError!void {
    var iter = vw.iter;
    if (vw.consumed == vw.count) {
        try drainVectorTrailing(&iter);
        try frames.append(gpa, .{ .vec_collect = .{ .count = vw.count } });
        return;
    }
    const elem_view = (try iter.next()) orelse unreachable;
    try frames.append(gpa, .{ .vec_walk = .{
        .iter = iter,
        .env = vw.env,
        .consumed = vw.consumed + 1,
        .count = vw.count,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = elem_view, .env = vw.env } });
}

fn scheduleLetBinary(
    a: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    fv: BinaryCursor.FormView,
    env: *const Env,
    frames: *std.ArrayList(FrameBinary),
) BinaryError!void {
    var form_iter = fv.children;
    if (form_iter.remaining != 2) return error.ArityMismatch;

    const binds_entry = (try form_iter.next()) orelse unreachable;
    if (binds_entry.kind == .keyword) return error.InvalidLetBinding;
    if (binds_entry.value.kind != .vector) return error.InvalidLetBinding;
    const binds_iter = try BinaryCursor.readVector(cursor, binds_entry.value);
    if (binds_iter.remaining % 2 != 0) return error.InvalidLetBinding;

    const pair_count: u32 = binds_iter.remaining / 2;

    const env_buf = try a.alloc(Env.Binding, pair_count);
    const inner_env = try a.create(Env);
    inner_env.* = .{ .parent = env, .bindings = env_buf[0..0] };

    try frames.append(gpa, .{ .let_walk = .{
        .form_iter = form_iter,
        .inner_env = inner_env,
        .env_buf = env_buf,
        .binds_iter = binds_iter,
        .idx = 0,
        .pair_count = pair_count,
    } });
}

fn processLetWalk(
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    lw: anytype,
    frames: *std.ArrayList(FrameBinary),
) BinaryError!void {
    var binds_iter = lw.binds_iter;
    var form_iter = lw.form_iter;

    if (lw.idx == lw.pair_count) {
        // All bindings done. Drain the binder vector's trailing comments
        // (wire v5+) before reading the body. After the body's eval,
        // form_drain takes care of the form's trailing comments.
        try drainVectorTrailing(&binds_iter);
        const body_entry = (try form_iter.next()) orelse unreachable;
        if (body_entry.kind == .keyword) return error.InvalidLetBinding;
        try frames.append(gpa, .{ .form_drain = .{ .iter = form_iter } });
        try frames.append(gpa, .{ .eval = .{ .view = body_entry.value, .env = lw.inner_env } });
        return;
    }

    // Walk one binding pair.
    const name_view = (try binds_iter.next()) orelse return error.InvalidLetBinding;
    if (name_view.kind != .symbol) return error.InvalidLetBinding;
    const name = try BinaryCursor.readSymbol(cursor, name_view);

    const value_view = (try binds_iter.next()) orelse return error.InvalidLetBinding;

    try frames.append(gpa, .{ .let_walk = .{
        .form_iter = form_iter,
        .inner_env = lw.inner_env,
        .env_buf = lw.env_buf,
        .binds_iter = binds_iter,
        .idx = lw.idx + 1,
        .pair_count = lw.pair_count,
    } });
    try frames.append(gpa, .{ .let_commit = .{
        .name = name,
        .env = lw.inner_env,
        .env_buf = lw.env_buf,
        .idx = lw.idx,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = value_view, .env = lw.inner_env } });
}

fn scheduleIfBinary(
    gpa: Allocator,
    fv: BinaryCursor.FormView,
    env: *const Env,
    frames: *std.ArrayList(FrameBinary),
) BinaryError!void {
    var iter = fv.children;
    if (iter.remaining < 2 or iter.remaining > 3) return error.ArityMismatch;
    const has_else = iter.remaining == 3;

    const test_entry = (try iter.next()) orelse unreachable;
    if (test_entry.kind == .keyword) return error.KeywordInExpressionArgs;

    try frames.append(gpa, .{ .if_after_test = .{
        .iter = iter,
        .env = env,
        .has_else = has_else,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = test_entry.value, .env = env } });
}

fn processIfAfterTest(
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    s: anytype,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    const test_v = values.pop().?;
    var iter = s.iter;
    const truthy = test_v.isTruthy();

    const then_entry = (try iter.next()) orelse unreachable;
    if (then_entry.kind == .keyword) return error.KeywordInExpressionArgs;

    if (truthy) {
        // Eval then-branch; form_drain skips else (if any) + trailing.
        try frames.append(gpa, .{ .form_drain = .{ .iter = iter } });
        try frames.append(gpa, .{ .eval = .{ .view = then_entry.value, .env = s.env } });
    } else {
        try BinaryCursor.skipBody(cursor, then_entry.value);
        if (s.has_else) {
            const else_entry = (try iter.next()) orelse unreachable;
            if (else_entry.kind == .keyword) return error.KeywordInExpressionArgs;
            try frames.append(gpa, .{ .form_drain = .{ .iter = iter } });
            try frames.append(gpa, .{ .eval = .{ .view = else_entry.value, .env = s.env } });
        } else {
            // No else; result is nil. Drain trailing inline.
            _ = try iter.next();
            try values.append(gpa, .nil);
        }
    }
}

fn scheduleCondBinary(
    gpa: Allocator,
    fv: BinaryCursor.FormView,
    env: *const Env,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    var iter = fv.children;
    if (iter.remaining % 2 != 0) return error.InvalidCondClause;
    if (iter.remaining == 0) {
        _ = try iter.next();
        try values.append(gpa, .nil);
        return;
    }
    const pred_entry = (try iter.next()) orelse unreachable;
    if (pred_entry.kind == .keyword) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .cond_after_pred = .{
        .iter = iter,
        .env = env,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = pred_entry.value, .env = env } });
}

fn processCondAfterPred(
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    s: anytype,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    const test_v = values.pop().?;
    var iter = s.iter;
    const truthy = test_v.isTruthy();

    const value_entry = (try iter.next()) orelse unreachable;
    if (value_entry.kind == .keyword) return error.KeywordInExpressionArgs;

    if (truthy) {
        // Eval value clause; drain remaining + trailing afterward.
        try frames.append(gpa, .{ .form_drain = .{ .iter = iter } });
        try frames.append(gpa, .{ .eval = .{ .view = value_entry.value, .env = s.env } });
        return;
    }
    // Falsy: skip value clause, recurse on next predicate (if any).
    try BinaryCursor.skipBody(cursor, value_entry.value);
    if (iter.remaining == 0) {
        _ = try iter.next();
        try values.append(gpa, .nil);
        return;
    }
    const next_pred = (try iter.next()) orelse unreachable;
    if (next_pred.kind == .keyword) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .cond_after_pred = .{
        .iter = iter,
        .env = s.env,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = next_pred.value, .env = s.env } });
}

fn scheduleAndBinary(
    gpa: Allocator,
    fv: BinaryCursor.FormView,
    env: *const Env,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    var iter = fv.children;
    if (iter.remaining == 0) {
        _ = try iter.next();
        try values.append(gpa, .{ .boolean = true });
        return;
    }
    const first = (try iter.next()) orelse unreachable;
    if (first.kind == .keyword) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .and_after_child = .{
        .iter = iter,
        .env = env,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = first.value, .env = env } });
}

fn processAndAfterChild(
    gpa: Allocator,
    s: anytype,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    const v = values.pop().?;
    var iter = s.iter;
    if (!v.isTruthy()) {
        // Short-circuit: push v, drain rest.
        try values.append(gpa, v);
        try frames.append(gpa, .{ .form_drain = .{ .iter = iter } });
        return;
    }
    if (iter.remaining == 0) {
        // All truthy; result is the last value.
        _ = try iter.next();
        try values.append(gpa, v);
        return;
    }
    const next = (try iter.next()) orelse unreachable;
    if (next.kind == .keyword) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .and_after_child = .{
        .iter = iter,
        .env = s.env,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = next.value, .env = s.env } });
}

fn scheduleOrBinary(
    gpa: Allocator,
    fv: BinaryCursor.FormView,
    env: *const Env,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    var iter = fv.children;
    if (iter.remaining == 0) {
        _ = try iter.next();
        try values.append(gpa, .{ .boolean = false });
        return;
    }
    const first = (try iter.next()) orelse unreachable;
    if (first.kind == .keyword) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .or_after_child = .{
        .iter = iter,
        .env = env,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = first.value, .env = env } });
}

fn processOrAfterChild(
    gpa: Allocator,
    s: anytype,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    const v = values.pop().?;
    var iter = s.iter;
    if (v.isTruthy()) {
        try values.append(gpa, v);
        try frames.append(gpa, .{ .form_drain = .{ .iter = iter } });
        return;
    }
    if (iter.remaining == 0) {
        _ = try iter.next();
        try values.append(gpa, .{ .boolean = false });
        return;
    }
    const next = (try iter.next()) orelse unreachable;
    if (next.kind == .keyword) return error.KeywordInExpressionArgs;
    try frames.append(gpa, .{ .or_after_child = .{
        .iter = iter,
        .env = s.env,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = next.value, .env = s.env } });
}

/// Fold-only intermediate frame: pops `init`'s value off the value
/// stack (just-evaluated by the preceding `eval(init_view)`),
/// advances `form_iter` to `xs`, then schedules `binder_setup_binary`
/// with `init_val` captured into the frame's `init_val_captured`
/// field. This decoupling is required because the binary cursor is
/// stateful — `form_iter.next()` only reads the next child's tag and
/// header; the previous child's body must be consumed before the
/// next tag byte can be read. We can't read both init and xs in
/// `scheduleBinderBinary` without interleaving their evals.
fn processFoldCaptureInit(
    gpa: Allocator,
    s: anytype,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    std.debug.assert(values.items.len >= 1);
    const init_val = values.pop().?;

    var form_iter = s.form_iter;
    const xs_entry = (try form_iter.next()) orelse unreachable;
    if (xs_entry.kind == .keyword) return error.KeywordInExpressionArgs;

    try frames.append(gpa, .{ .binder_setup_binary = .{
        .kind = .fold,
        .binder_name = s.binder_name,
        .binder_acc_name = s.binder_acc_name,
        .form_iter = form_iter,
        .env_outer = s.env_outer,
        .init_val_captured = init_val,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = xs_entry.value, .env = s.env_outer } });
}

/// Schedule a higher-order binder form on the binary path. Reads
/// the binder vector eagerly (validates 1 symbol — or 2 distinct
/// symbols for fold), consumes the `xs` (or `init`, for fold) child
/// header, and pushes a continuation (`binder_setup_binary`, or for
/// fold the `fold_capture_init` bridge) that fires once `eval(xs)`
/// (or `eval(init)`) lands its value on the value stack.
///
/// The deferred work — capturing `body_payload_pos`, draining the
/// form to `post_form_pos`, and launching the iteration loop —
/// lives in `processBinderSetupBinary` because the body's
/// `NodeView` can only be read AFTER `xs` has been consumed by the
/// cursor.
fn scheduleBinderBinary(
    kind: BinderKind,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    fv: BinaryCursor.FormView,
    env: *const Env,
    frames: *std.ArrayList(FrameBinary),
) BinaryError!void {
    var form_iter = fv.children;
    const expected_arity: u32 = if (kind == .fold) 4 else 3;
    if (form_iter.remaining != expected_arity) return error.ArityMismatch;

    const binder_entry = (try form_iter.next()) orelse unreachable;
    if (binder_entry.kind == .keyword) return error.InvalidBinderShape;
    if (binder_entry.value.kind != .vector) return error.InvalidBinderShape;
    var binder_iter = try BinaryCursor.readVector(cursor, binder_entry.value);

    if (kind == .fold) {
        if (binder_iter.remaining != 2) return error.InvalidBinderShape;
        const acc_view = (try binder_iter.next()) orelse unreachable;
        if (acc_view.kind != .symbol) return error.InvalidBinderShape;
        const acc_name = try BinaryCursor.readSymbol(cursor, acc_view);
        const x_view = (try binder_iter.next()) orelse unreachable;
        if (x_view.kind != .symbol) return error.InvalidBinderShape;
        const x_name = try BinaryCursor.readSymbol(cursor, x_view);
        // Distinct binder names — same reason as the tree path.
        if (std.mem.eql(u8, acc_name, x_name)) return error.InvalidBinderShape;
        try drainVectorTrailing(&binder_iter);

        // Binary-cursor sequencing: each `form_iter.next()` only reads
        // the next child's header, leaving the cursor at the child's
        // payload. The body must be consumed (eval'd) before the next
        // child's tag byte can be read. So we can't read both init
        // and xs eagerly here — fold_capture_init bridges between
        // eval(init) and the setup flow.
        const init_entry = (try form_iter.next()) orelse unreachable;
        if (init_entry.kind == .keyword) return error.KeywordInExpressionArgs;

        try frames.append(gpa, .{ .fold_capture_init = .{
            .binder_name = x_name,
            .binder_acc_name = acc_name,
            .form_iter = form_iter,
            .env_outer = env,
        } });
        try frames.append(gpa, .{ .eval = .{ .view = init_entry.value, .env = env } });
        return;
    }

    if (binder_iter.remaining != 1) return error.InvalidBinderShape;
    const sym_view = (try binder_iter.next()) orelse unreachable;
    if (sym_view.kind != .symbol) return error.InvalidBinderShape;
    const binder_name = try BinaryCursor.readSymbol(cursor, sym_view);
    try drainVectorTrailing(&binder_iter);

    const xs_entry = (try form_iter.next()) orelse unreachable;
    if (xs_entry.kind == .keyword) return error.KeywordInExpressionArgs;

    try frames.append(gpa, .{ .binder_setup_binary = .{
        .kind = kind,
        .binder_name = binder_name,
        .binder_acc_name = null,
        .form_iter = form_iter,
        .env_outer = env,
        .init_val_captured = null,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = xs_entry.value, .env = env } });
}

fn processBinderSetupBinary(
    a: Allocator,
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    s: anytype,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    // Pop xs (just-evaluated). For fold, the init value was captured
    // earlier by `fold_capture_init` into `s.init_val_captured` —
    // popping it here would be wrong because the binary path can't
    // queue both `eval(init)` and `eval(xs)` before the setup runs.
    std.debug.assert(values.items.len >= 1);
    const xs_val = values.pop().?;
    const xs_vec = try expectVector(xs_val);
    const init_val: ?Value = s.init_val_captured;
    const n: u32 = @intCast(xs_vec.len);

    // Read the body's NodeView. The iter contract puts the cursor at
    // body's variant payload after this returns, so `cursor.pos` is
    // exactly `body_payload_pos` — the position we must restore
    // before each per-element eval.
    var form_iter = s.form_iter;
    const body_entry = (try form_iter.next()) orelse unreachable;
    if (body_entry.kind == .keyword) return error.KeywordInExpressionArgs;
    const body_view = body_entry.value;
    const body_payload_pos: u32 = cursor.pos;

    // Drain the surrounding form to a stable post-form position so
    // the binder loop owns the cursor exclusively. `skipBody`
    // advances past body's bytes; the terminal `iter.next()`
    // returning null consumes any trailing comments.
    try BinaryCursor.skipBody(cursor, body_view);
    _ = try form_iter.next();
    const post_form_pos: u32 = cursor.pos;

    if (n == 0) {
        // Empty input — cursor is already at post_form_pos, no replay
        // needed. Same identity values as the tree path.
        try values.append(gpa, binderEmptyResult(s.kind, init_val));
        return;
    }

    const loop = try initBinderLoopState(a, s.kind, s.binder_name, s.binder_acc_name, s.env_outer, xs_vec, init_val, n);

    // Reset the cursor to body's payload so the about-to-be-pushed
    // eval frame consumes body's bytes correctly.
    BinaryCursor.setPos(cursor, body_payload_pos);

    try frames.append(gpa, .{ .binder_iter_binary = .{
        .kind = s.kind,
        .body_view = body_view,
        .body_payload_pos = body_payload_pos,
        .post_form_pos = post_form_pos,
        .inner_env = loop.inner_env,
        .env_buf = loop.env_buf,
        .xs_vec = xs_vec,
        .accumulator = loop.accumulator,
        .accumulator_count = 0,
        .i = 0,
        .n = n,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = body_view, .env = loop.inner_env } });
}

fn processBinderIterBinary(
    gpa: Allocator,
    cursor: *BinaryCursor.Cursor,
    s: anytype,
    frames: *std.ArrayList(FrameBinary),
    values: *std.ArrayList(Value),
) BinaryError!void {
    std.debug.assert(values.items.len >= 1);
    const body_val = values.pop().?;

    const next_i: u32 = s.i + 1;
    var next_count: u32 = s.accumulator_count;
    var done: ?Value = null;
    switch (binderAccumulate(s.kind, s.accumulator, s.xs_vec, s.i, s.accumulator_count, body_val)) {
        .short_circuit => |v| done = v,
        .advance => |c| next_count = c,
    }

    if (done == null and next_i == s.n) {
        done = binderFinalResult(s.kind, s.accumulator, next_count, body_val);
    }

    if (done) |final_v| {
        // Restore cursor so a parent walk-frame's next read picks up
        // where a normal walk would have left it. `eval(body_view)`
        // advanced cursor.pos to `body_payload_pos + body_size`,
        // which may sit short of `post_form_pos` if the form has
        // trailing comments.
        BinaryCursor.setPos(cursor, s.post_form_pos);
        try values.append(gpa, final_v);
        return;
    }

    advanceBinderBindings(s.kind, s.env_buf, s.xs_vec, next_i, body_val);

    // Reset cursor to body's payload before pushing the next eval.
    BinaryCursor.setPos(cursor, s.body_payload_pos);

    try frames.append(gpa, .{ .binder_iter_binary = .{
        .kind = s.kind,
        .body_view = s.body_view,
        .body_payload_pos = s.body_payload_pos,
        .post_form_pos = s.post_form_pos,
        .inner_env = s.inner_env,
        .env_buf = s.env_buf,
        .xs_vec = s.xs_vec,
        .accumulator = s.accumulator,
        .accumulator_count = next_count,
        .i = next_i,
        .n = s.n,
    } });
    try frames.append(gpa, .{ .eval = .{ .view = s.body_view, .env = s.inner_env } });
}

fn processFormDrain(iter_in: BinaryCursor.ChildIter) BinaryError!void {
    var iter = iter_in;
    while (iter.remaining > 0) {
        const entry = (try iter.next()) orelse unreachable;
        try BinaryCursor.skipBody(iter.cursor, entry.value);
    }
    // Final next() returns null and consumes form-trailing comments.
    _ = try iter.next();
}

// ---------------------------------------------------------------------------
// Function dispatch
// ---------------------------------------------------------------------------

/// Resolve `(name, namespace)` via the schema and dispatch through the
/// function's `impl` pointer or `wasm_export_name` import. A `not_found`
/// lookup is `error.UnknownFunction`; an `ambiguous` lookup (only
/// reachable on bare dispatch with two plugins claiming the same name)
/// is `error.AmbiguousFunction`. A `found` hit dispatches in this order:
///   * `impl != null` — native Zig function pointer, called directly.
///   * `wasm_export_name != null` — `:impl "wasm:<export>"`; delegated
///     to `wasm_plugin_invoker.invoke`. On native builds the invoker is
///     a stub returning `PluginFuncNotImplemented`; on wasm32 it calls
///     the host's `sjon_host_invoke_plugin` import.
///   * both null — `error.PluginFuncNotImplemented` (declaration-only is
///     a supported state per `Plugin.ExprFunc`).
///
/// Bare special forms (`let` / `if` / `cond` / `and` / `or`) never reach
/// here; they're handled by dedicated frames in the evaluator. Qualified
/// `(core/let …)` does reach here and surfaces the impl-null marker as
/// `PluginFuncNotImplemented`.
fn applyFunction(
    a: Allocator,
    name: []const u8,
    namespace: []const u8,
    args: []const Value,
    schema: Schema.Schema,
    runtime: ?*anyopaque,
) Error!Value {
    const ns: ?[]const u8 = if (namespace.len == 0) null else namespace;
    return switch (schema.lookupExprFunc(name, ns)) {
        .found => |hit| blk: {
            // Wasm-impl funcs gate on declared arity here so a call the
            // validator already flagged as `arity_mismatch` doesn't
            // dispatch into the plugin with a malformed args payload
            // (which would surface as a spurious
            // `plugin_func_alloc_failed`). Native `impl` bodies do their
            // own arity check inside the impl, matching the calling
            // convention of `applyDiff` / `applyQuotient` / etc.
            if (hit.func.wasm_export_name != null and !hit.func.checkArity(args.len)) {
                break :blk error.ArityMismatch;
            }
            break :blk if (hit.func.impl) |impl|
                impl(a, args)
            else if (hit.func.wasm_export_name) |export_name|
                wasm_plugin_invoker.invoke(a, runtime, hit.plugin.name, export_name, hit.func.result, args)
            else
                error.PluginFuncNotImplemented;
        },
        .ambiguous => error.AmbiguousFunction,
        .not_found => error.UnknownFunction,
    };
}

// ---------------------------------------------------------------------------
// Arithmetic
// ---------------------------------------------------------------------------

// All `applyXxx` impls below match `Plugin.ExprFunc.Impl` so `core.zig`
// can plug them directly into `ExprFunc.impl`. Funcs that don't need the
// allocator discard it.

pub fn applySum(_: Allocator, args: []const Value) Error!Value {
    var total: f64 = 0;
    for (args) |v| total += try expectNumber(v);
    return .{ .number = total };
}

pub fn applyDiff(_: Allocator, args: []const Value) Error!Value {
    if (args.len == 0) return error.ArityMismatch;
    if (args.len == 1) return .{ .number = -try expectNumber(args[0]) };
    var total = try expectNumber(args[0]);
    for (args[1..]) |v| total -= try expectNumber(v);
    return .{ .number = total };
}

pub fn applyProduct(_: Allocator, args: []const Value) Error!Value {
    var total: f64 = 1;
    for (args) |v| total *= try expectNumber(v);
    return .{ .number = total };
}

pub fn applyQuotient(_: Allocator, args: []const Value) Error!Value {
    if (args.len < 2) return error.ArityMismatch;
    var total = try expectNumber(args[0]);
    for (args[1..]) |v| {
        const d = try expectNumber(v);
        if (d == 0) return error.DivisionByZero;
        total /= d;
    }
    return .{ .number = total };
}

pub fn applyMod(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const x = try expectNumber(args[0]);
    const y = try expectNumber(args[1]);
    if (y == 0) return error.DivisionByZero;
    // Floored for every divisor: the result carries the *divisor's* sign,
    // matching GLSL `mod()` and Python `%`. `@mod` alone does not give
    // that — it is floored for a positive divisor but degrades to `@rem`
    // (the numerator's sign) for a negative one, so `(mod 7 -3)` used to
    // be 1 where floored is -2. That split is what this corrects.
    //
    // Written as a correction *on top of* `@mod` rather than as
    // `x - y * @floor(x / y)` for two reasons, both load-bearing:
    //
    //   * The positive-divisor path is then literally untouched, so every
    //     value SJON has ever produced for a positive divisor is
    //     bit-identical. That is the region documents actually use.
    //   * The closed form loses precision when `x / y` is inexact —
    //     it gives 0 for `(mod 1e16 3)` where the true answer is 1, and
    //     the naive `@rem`-plus-correction form returns 1e16 for
    //     `(mod -1 1e16)`, a result equal to the divisor. `@mod` already
    //     handles both; correcting it inherits that.
    //
    // The guard is `m != 0` so an exact multiple keeps `@mod`'s zero
    // (and its sign) instead of being pushed to `y`, and the sign
    // comparison is written out rather than `m > 0` so it stays correct
    // if the branch is ever reached with a positive divisor.
    const m = @mod(x, y);
    if (y < 0 and m != 0 and (m < 0) != (y < 0)) return .{ .number = m + y };
    return .{ .number = m };
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

const CmpOp = enum { lt, gt, le, ge };

fn cmp(args: []const Value, op: CmpOp) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const a = try expectNumber(args[0]);
    const b = try expectNumber(args[1]);
    const r = switch (op) {
        .lt => a < b,
        .gt => a > b,
        .le => a <= b,
        .ge => a >= b,
    };
    return .{ .boolean = r };
}

pub fn applyLt(_: Allocator, args: []const Value) Error!Value {
    return cmp(args, .lt);
}
pub fn applyGt(_: Allocator, args: []const Value) Error!Value {
    return cmp(args, .gt);
}
pub fn applyLe(_: Allocator, args: []const Value) Error!Value {
    return cmp(args, .le);
}
pub fn applyGe(_: Allocator, args: []const Value) Error!Value {
    return cmp(args, .ge);
}

pub fn applyEq(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    // Operands are mid-eval values (not yet capped by the final
    // deepCopyValue), so use the depth-guarded comparison.
    return .{ .boolean = try Value.equalsBounded(args[0], args[1]) };
}

pub fn applyNeq(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    return .{ .boolean = !try Value.equalsBounded(args[0], args[1]) };
}

pub fn applyNot(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return .{ .boolean = !args[0].isTruthy() };
}

// ---------------------------------------------------------------------------
// Vectors and math
// ---------------------------------------------------------------------------

fn applyVecN(a: Allocator, args: []const Value, n: usize) Error!Value {
    if (args.len != n) return error.ArityMismatch;
    const elems = try a.alloc(Value, n);
    for (args, 0..) |v, i| elems[i] = .{ .number = try expectNumber(v) };
    return .{ .vector = elems };
}

pub fn applyVec2(a: Allocator, args: []const Value) Error!Value {
    return applyVecN(a, args, 2);
}
pub fn applyVec3(a: Allocator, args: []const Value) Error!Value {
    return applyVecN(a, args, 3);
}
pub fn applyVec4(a: Allocator, args: []const Value) Error!Value {
    return applyVecN(a, args, 4);
}

pub fn applyLerp(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 3) return error.ArityMismatch;
    const x = try expectNumber(args[0]);
    const y = try expectNumber(args[1]);
    const t = try expectNumber(args[2]);
    return .{ .number = x + (y - x) * t };
}

pub fn applyClamp(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 3) return error.ArityMismatch;
    const x = try expectNumber(args[0]);
    const lo = try expectNumber(args[1]);
    const hi = try expectNumber(args[2]);
    // `std.math.clamp` asserts `lower <= upper`, and both bounds here are
    // author input evaluated at runtime — a `let`-bound pair, a plugin
    // result, anything. Reaching that assert is a panic in a safe build and
    // illegal behavior in a fast one, from a document the validator cannot
    // reject (it does not know the values). So the inverted range is a
    // diagnostic, exactly as `applyRandRange` / `applyRandInt` already
    // treat theirs. Written `!(lo <= hi)` rather than `lo > hi` so a NaN
    // bound — which makes every comparison false — is rejected too instead
    // of falling through to the same assert.
    if (!(lo <= hi)) return error.TypeMismatch;
    return .{ .number = std.math.clamp(x, lo, hi) };
}

fn applyMinMax(args: []const Value, op: enum { min, max }) Error!Value {
    if (args.len == 0) return error.ArityMismatch;
    var best = try expectNumber(args[0]);
    for (args[1..]) |v| {
        const x = try expectNumber(v);
        best = switch (op) {
            .min => @min(best, x),
            .max => @max(best, x),
        };
    }
    return .{ .number = best };
}

pub fn applyMin(_: Allocator, args: []const Value) Error!Value {
    return applyMinMax(args, .min);
}
pub fn applyMax(_: Allocator, args: []const Value) Error!Value {
    return applyMinMax(args, .max);
}

/// Dot product Σ aᵢ·bᵢ over two equal-length numeric vectors, accumulated
/// left-to-right. The accumulation order is bit-significant for cross-host
/// reproducibility (see the extended-math note below). `TypeMismatch` if
/// the lengths differ or any element isn't a number; empty vectors dot to
/// 0. Backs dot/length/normalize/reflect; distance sums squared
/// differences instead, so it doesn't route through here.
fn dotOf(a: []const Value, b: []const Value) Error!f64 {
    if (a.len != b.len) return error.TypeMismatch;
    var total: f64 = 0;
    for (a, b) |x, y| {
        total += (try expectNumber(x)) * (try expectNumber(y));
    }
    return total;
}

pub fn applyDot(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const a = try expectVector(args[0]);
    const b = try expectVector(args[1]);
    return .{ .number = try dotOf(a, b) };
}

pub fn applyCross(a_alloc: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const a = try expectVector(args[0]);
    const b = try expectVector(args[1]);
    if (a.len != 3 or b.len != 3) return error.TypeMismatch;
    const ax = try expectNumber(a[0]);
    const ay = try expectNumber(a[1]);
    const az = try expectNumber(a[2]);
    const bx = try expectNumber(b[0]);
    const by = try expectNumber(b[1]);
    const bz = try expectNumber(b[2]);
    const out = try a_alloc.alloc(Value, 3);
    out[0] = .{ .number = ay * bz - az * by };
    out[1] = .{ .number = az * bx - ax * bz };
    out[2] = .{ .number = ax * by - ay * bx };
    return .{ .vector = out };
}

pub fn applyLength(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    const v = try expectVector(args[0]);
    return .{ .number = @sqrt(try dotOf(v, v)) };
}

// ---------------------------------------------------------------------------
// Math (extended) — scalar f64 → f64. Domain errors propagate IEEE 754
// NaN by design (e.g. `(sqrt -1)` → NaN, `(asin 2)` → NaN). See
// docs/LANGUAGE.md §8.6. No `MathDomain` error code.
//
// Cross-platform reproducibility: the correctly-rounded ops (`+ - * /`,
// `sqrt`) are bit-identical across hosts by IEEE 754 alone (Zig defaults
// to `FloatMode.strict`, so no FMA contraction). The transcendentals
// `sin`/`cos`/`tan` are NOT mandated correctly-rounded by IEEE 754 and the
// `@sin`/`@cos`/`@tan` builtins lower to the platform libm — so they would
// differ in the last ULP between the native build and the freestanding
// WASM artifacts. They route through `trig.zig` (vendored musl/compiler_rt
// software impl) instead, which makes them bit-identical by construction.
// `pow` has the same hazard — `std.math.pow`'s fractional-exponent path calls
// the `@exp`/`@log` builtins — so it routes through `trig.zig`'s `pow64` too.
// `asin`/`acos`/`atan`/`atan2` are the exception: their `std.math.*` impls are
// genuinely pure-Zig software (no builtins), so they are reproducible as-is.
// ---------------------------------------------------------------------------

/// Comptime factory: wrap a plain `f64 → f64` math op as an
/// `Impl`-compatible ExprFunc. Every generated builtin shares the one
/// arity check + `expectNumber` + `Value.number` wrapping, so each clone
/// builtin declares only its operation. Pinned by the per-builtin eval
/// battery (arity + type-mismatch cases hit the shared prologue).
fn unaryMath(comptime op: fn (f64) f64) fn (Allocator, []const Value) Error!Value {
    return struct {
        fn apply(_: Allocator, args: []const Value) Error!Value {
            if (args.len != 1) return error.ArityMismatch;
            return .{ .number = op(try expectNumber(args[0])) };
        }
    }.apply;
}

/// Comptime factory for a two-argument `f64 × f64 → f64` op. `op`
/// receives `(args[0], args[1])` in source order.
fn binaryMath(comptime op: fn (f64, f64) f64) fn (Allocator, []const Value) Error!Value {
    return struct {
        fn apply(_: Allocator, args: []const Value) Error!Value {
            if (args.len != 2) return error.ArityMismatch;
            const x = try expectNumber(args[0]);
            const y = try expectNumber(args[1]);
            return .{ .number = op(x, y) };
        }
    }.apply;
}

/// f64 wrappers for math ops that aren't already `fn (f64) f64` values —
/// Zig builtins (`@abs`/`@floor`/…) and the generic `std.math` functions
/// — so they can feed `unaryMath`/`binaryMath`. `trig.sin64`/`cos64`/
/// `tan64`/`pow64` are already concrete f64 signatures and pass directly.
const mathf = struct {
    fn abs(x: f64) f64 {
        return @abs(x);
    }
    fn floor(x: f64) f64 {
        return @floor(x);
    }
    fn ceil(x: f64) f64 {
        return @ceil(x);
    }
    fn round(x: f64) f64 {
        return @round(x);
    }
    fn sqrt(x: f64) f64 {
        return @sqrt(x);
    }
    fn fract(x: f64) f64 {
        // WGSL: result may be exactly 1.0 for some near-integer negatives
        // (floating-point rounding). Don't clamp.
        return x - @floor(x);
    }
    fn asin(x: f64) f64 {
        return std.math.asin(x);
    }
    fn acos(x: f64) f64 {
        return std.math.acos(x);
    }
    fn atan(x: f64) f64 {
        return std.math.atan(x);
    }
    fn atan2(y: f64, x: f64) f64 {
        return std.math.atan2(y, x);
    }
    fn radians(x: f64) f64 {
        return x * (std.math.pi / 180.0);
    }
    fn degrees(x: f64) f64 {
        return x * (180.0 / std.math.pi);
    }
};

pub const applyAbs = unaryMath(mathf.abs);

// Not a clone: NaN passes through, and the sign of ±0 is preserved.
pub fn applySign(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    const x = try expectNumber(args[0]);
    if (std.math.isNan(x)) return .{ .number = x };
    return .{ .number = if (x > 0) 1.0 else if (x < 0) -1.0 else x };
}

pub const applyFloor = unaryMath(mathf.floor);
pub const applyCeil = unaryMath(mathf.ceil);
pub const applyRound = unaryMath(mathf.round);
pub const applyFract = unaryMath(mathf.fract);
pub const applySqrt = unaryMath(mathf.sqrt);
pub const applyPow = binaryMath(trig.pow64);
pub const applySin = unaryMath(trig.sin64);
pub const applyCos = unaryMath(trig.cos64);
pub const applyTan = unaryMath(trig.tan64);
pub const applyAsin = unaryMath(mathf.asin);
pub const applyAcos = unaryMath(mathf.acos);
pub const applyAtan = unaryMath(mathf.atan);
pub const applyAtan2 = binaryMath(mathf.atan2);
pub const applyRadians = unaryMath(mathf.radians);
pub const applyDegrees = unaryMath(mathf.degrees);

pub fn applyPi(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 0) return error.ArityMismatch;
    return .{ .number = std.math.pi };
}

pub fn applyTau(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 0) return error.ArityMismatch;
    return .{ .number = 2.0 * std.math.pi };
}

// ---------------------------------------------------------------------------
// Smoothing — WGSL conventions.
// ---------------------------------------------------------------------------

pub fn applySaturate(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    return .{ .number = std.math.clamp(try expectNumber(args[0]), 0.0, 1.0) };
}

pub fn applyStep(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const edge = try expectNumber(args[0]);
    const x = try expectNumber(args[1]);
    return .{ .number = if (x < edge) 0.0 else 1.0 };
}

pub fn applySmoothstep(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 3) return error.ArityMismatch;
    const edge0 = try expectNumber(args[0]);
    const edge1 = try expectNumber(args[1]);
    const x = try expectNumber(args[2]);
    // WGSL: edge0 == edge1 is invalid/indeterminate. Don't special-case;
    // let the divide go non-finite and lean on the clamp. What comes out
    // is a step function whose rising edge sits at edge0: below it the
    // quotient is -inf and clamps to 0, above it +inf and clamps to 1,
    // and *at* it the 0/0 NaN clamps to 1 — because the clamp is
    // @max(lo, @min(hi, v)) and IEEE min/max return the non-NaN operand.
    // (An earlier version of this comment said the NaN "coerces to lo
    // (0.0)"; it does not, and `conformance/cases/expr-value-smoothing`
    // now pins all three.) Well-defined and reproducible on every host,
    // but still an input authors should avoid.
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return .{ .number = t * t * (3.0 - 2.0 * t) };
}

// ---------------------------------------------------------------------------
// Vector ops (extended). normalize/distance/reflect operate on vectors of
// any matching length; empty vectors are rejected because the operations
// are undefined there.
// ---------------------------------------------------------------------------

pub fn applyNormalize(a: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    const v = try expectVector(args[0]);
    if (v.len == 0) return error.TypeMismatch;
    const sum_sq = try dotOf(v, v);
    if (sum_sq == 0) return error.TypeMismatch;
    const inv = 1.0 / @sqrt(sum_sq);
    const out = try a.alloc(Value, v.len);
    for (v, 0..) |x, i| {
        const n = try expectNumber(x);
        out[i] = .{ .number = n * inv };
    }
    return .{ .vector = out };
}

pub fn applyDistance(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const a = try expectVector(args[0]);
    const b = try expectVector(args[1]);
    if (a.len != b.len) return error.TypeMismatch;
    if (a.len == 0) return error.TypeMismatch;
    var sum_sq: f64 = 0;
    for (a, b) |x, y| {
        const d = (try expectNumber(x)) - (try expectNumber(y));
        sum_sq += d * d;
    }
    return .{ .number = @sqrt(sum_sq) };
}

pub fn applyReflect(a_alloc: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const i = try expectVector(args[0]);
    const n = try expectVector(args[1]);
    if (i.len != n.len) return error.TypeMismatch;
    if (i.len == 0) return error.TypeMismatch;
    // WGSL: caller must supply unit-length N. We do not auto-normalize.
    const dot = try dotOf(i, n);
    const out = try a_alloc.alloc(Value, i.len);
    for (i, n, 0..) |ix, nx, k| {
        const ixv = try expectNumber(ix);
        const nxv = try expectNumber(nx);
        out[k] = .{ .number = ixv - 2.0 * dot * nxv };
    }
    return .{ .vector = out };
}

// ---------------------------------------------------------------------------
// List ops — vector-only for v1. nth uses 0-based indexing; non-integer
// or out-of-bounds indices yield TypeMismatch (no separate IndexOutOfRange
// code; deliberate to keep the Error surface narrow).
// ---------------------------------------------------------------------------

pub fn applyNth(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const v = try expectVector(args[0]);
    const i_f = try expectNumber(args[1]);
    if (!std.math.isFinite(i_f)) return error.TypeMismatch;
    if (@floor(i_f) != i_f) return error.TypeMismatch;
    if (i_f < 0) return error.TypeMismatch;
    if (i_f >= @as(f64, @floatFromInt(v.len))) return error.TypeMismatch;
    const idx: usize = @intFromFloat(i_f);
    return v[idx];
}

pub fn applyCount(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 1) return error.ArityMismatch;
    const v = try expectVector(args[0]);
    return .{ .number = @as(f64, @floatFromInt(v.len)) };
}

// ---------------------------------------------------------------------------
// Seeded random — counter-based, pure functions of (seed, key, …). Pick:
// SplitMix64 mixer. Tiny, well-tested, trivially portable to TS/BigInt
// (and any future host). All randoms are deterministic across platforms.
//
// Seed/key conversion (toU64): integer-valued f64 → i64 → u64, so
// `(rand01 1 0)` and `(rand01 1.0 0.0)` produce identical sequences.
// Non-integer seeds bit-cast verbatim (still deterministic, just
// drift-sensitive — document accordingly).
// ---------------------------------------------------------------------------

// 2^53 — exact integer ceiling for f64, used here for hash → [0,1)
// normalization + integer detection. The canonical printers
// (`Printer`/`Json`) and `SchemaExport` (`Model.F64_PRECISE_INT_CEILING`)
// keep their own copies for different jobs; deliberately unshared, each
// corpus-pinned.
const TWO_53: f64 = 9007199254740992.0;

fn splitMix64(z0: u64) u64 {
    var z = z0;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn coreHash(seed: u64, key: u64) u64 {
    return splitMix64(seed +% splitMix64(key));
}

fn toU64(x: f64) u64 {
    if (std.math.isFinite(x) and @floor(x) == x and @abs(x) < TWO_53) {
        return @bitCast(@as(i64, @intFromFloat(x)));
    }
    return @bitCast(x);
}

inline fn unitFloatFromHash(h: u64) f64 {
    // 53-bit mantissa fits exactly in f64; result is in [0, 1).
    return @as(f64, @floatFromInt(h >> 11)) / TWO_53;
}

pub fn applyHash(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const seed = toU64(try expectNumber(args[0]));
    const key = toU64(try expectNumber(args[1]));
    const h = coreHash(seed, key) >> 11; // 53-bit, exact in f64.
    return .{ .number = @as(f64, @floatFromInt(h)) };
}

pub fn applyRand01(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return error.ArityMismatch;
    const seed = toU64(try expectNumber(args[0]));
    const key = toU64(try expectNumber(args[1]));
    return .{ .number = unitFloatFromHash(coreHash(seed, key)) };
}

pub fn applyRandRange(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 4) return error.ArityMismatch;
    const seed = toU64(try expectNumber(args[0]));
    const key = toU64(try expectNumber(args[1]));
    const lo = try expectNumber(args[2]);
    const hi = try expectNumber(args[3]);
    if (lo > hi) return error.TypeMismatch;
    const r = unitFloatFromHash(coreHash(seed, key));
    return .{ .number = lo + (hi - lo) * r };
}

pub fn applyRandInt(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 4) return error.ArityMismatch;
    const seed = toU64(try expectNumber(args[0]));
    const key = toU64(try expectNumber(args[1]));
    const lo = try expectNumber(args[2]);
    const hi = try expectNumber(args[3]);
    if (!std.math.isFinite(lo) or !std.math.isFinite(hi)) return error.TypeMismatch;
    if (@floor(lo) != lo or @floor(hi) != hi) return error.TypeMismatch;
    if (lo > hi) return error.TypeMismatch;
    const r = unitFloatFromHash(coreHash(seed, key));
    const span = hi - lo + 1.0;
    return .{ .number = lo + @floor(r * span) };
}

pub fn applyRandBool(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 3) return error.ArityMismatch;
    const seed = toU64(try expectNumber(args[0]));
    const key = toU64(try expectNumber(args[1]));
    const p = try expectNumber(args[2]);
    const p_clamped = std.math.clamp(p, 0.0, 1.0);
    const r = unitFloatFromHash(coreHash(seed, key));
    return .{ .boolean = r < p_clamped };
}

pub fn applyRandChoice(_: Allocator, args: []const Value) Error!Value {
    if (args.len != 3) return error.ArityMismatch;
    const seed = toU64(try expectNumber(args[0]));
    const key = toU64(try expectNumber(args[1]));
    const v = try expectVector(args[2]);
    if (v.len == 0) return error.TypeMismatch;
    const r = unitFloatFromHash(coreHash(seed, key));
    const idx_f = @floor(r * @as(f64, @floatFromInt(v.len)));
    const idx: usize = @intFromFloat(idx_f);
    return v[idx];
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

inline fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// True when `(head, namespace)` names a core special form — one that
/// `scheduleForm`/`scheduleFormBinary` dispatch through a dedicated
/// frame rather than `applyFunction`. Resolves through the shared
/// `special_forms` map, so it cannot drift from the two dispatchers.
///
/// Callers (notably `Host.runEvalPass`) use this to decide whether a
/// top-level form should be evaluated even though its head is not
/// registered as a plugin `ExprFunc` in the active schema — `core` is
/// deliberately not seeded into `validateDocument`'s schema, so
/// special-form heads never resolve via `lookupExprFunc`.
pub fn isCoreSpecialForm(head: []const u8, namespace: ?[]const u8) bool {
    if (namespace != null) return false;
    return special_forms.has(head);
}

test "isCoreSpecialForm: the ten core heads match only with a null namespace" {
    // Membership pin for the special-form set. Locks the catalog that
    // `scheduleForm`/`scheduleFormBinary` dispatch and `Host.runEvalPass`
    // consults — the three must agree on exactly these ten heads.
    const heads = [_][]const u8{ "let", "if", "cond", "and", "or", "map", "filter", "any", "all", "fold" };
    for (heads) |h| {
        try std.testing.expect(isCoreSpecialForm(h, null));
        try std.testing.expect(!isCoreSpecialForm(h, "ns")); // any namespace disqualifies
    }
    try std.testing.expect(!isCoreSpecialForm("nope", null)); // not a special form
    try std.testing.expect(!isCoreSpecialForm("fold", "core")); // qualified head is data, not a form
}

fn expectNumber(v: Value) Error!f64 {
    return v.toF64() orelse error.TypeMismatch;
}

fn expectVector(v: Value) Error![]const Value {
    return switch (v) {
        .vector => |xs| xs,
        else => error.TypeMismatch,
    };
}

test {
    _ = @import("Expr_tests.zig");
    _ = @import("trig.zig"); // run trig.zig's inline tests under the suite
}
