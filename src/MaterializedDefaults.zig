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
pub fn literalToValue(
    a: Allocator,
    default: Plugin.KeySpec.Default,
) ConvertError!Expr.Value {
    return switch (default) {
        .number => |n| .{ .number = n },
        .boolean => |b| .{ .boolean = b },
        .nil => .nil,
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .symbol => |s| .{ .keyword = try a.dupe(u8, s) },
        .vector => |xs| blk: {
            const dup = try a.alloc(Expr.Value, xs.len);
            for (xs, 0..) |x, i| dup[i] = try literalToValue(a, x);
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
    var work: std.ArrayList(Ast.NodeIndex) = .empty;
    defer work.deinit(gpa);
    {
        var i = data_forest.len;
        while (i > 0) {
            i -= 1;
            try work.append(gpa, data_forest[i]);
        }
    }

    while (work.pop()) |idx| {
        if (tree.tagOf(idx) != .form) continue;
        const hdr = tree.formHeader(idx);
        // Parser-recovery synthetic form — mirror the validator's skip.
        if (hdr.head.len == 0) continue;

        // Only materialize for *data* forms. Expression-function invocations
        // in data positions produce a runtime value, not a kvpair-bearing
        // instance; unknown heads are already diagnosed by the validator.
        const form_hit = schema.lookupForm(hdr.head, hdr.namespace);
        if (form_hit == .found) {
            try materializeForForm(gpa, arena, tree, idx, hdr, form_hit.found.form, schema, &entries, &diags, &cache);
        }

        // Descend into form-shaped children regardless of whether this node
        // resolved as a data form — a child may be a data form even when the
        // parent didn't resolve (the validator already emitted at the
        // unresolved parent). Push in reverse so the worklist pops them in
        // document order (matches the prior recursive pre-order descent).
        var c = hdr.children.len;
        while (c > 0) {
            c -= 1;
            if (tree.childForm(hdr.children[c])) |cf| try work.append(gpa, cf);
        }
    }

    return .{
        .materialized = .{ .entries = try entries.toOwnedSlice(arena) },
        .diagnostics = try diags.toOwnedSlice(gpa),
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
) Allocator.Error!void {
    // KNOWN LIMITATION: only the form's *common* keys are materialized, never
    // `form_spec.variants[i].keys`. A `:default` on a variant key is honoured by
    // the Validator (`effectiveOptional()` treats a defaulted key as satisfied, so
    // `emitVariantSweeps` skips the missing-required check) but never lands in this
    // overlay, so a consumer reading its effective value gets `null`. Materializing
    // it correctly would require resolving the *active* variant here — including the
    // axis-D case where the discriminant is itself a default — which duplicates the
    // Validator's stateful discriminant resolution. Latent today (no in-repo schema
    // declares a variant-key default); deferred and pinned by the
    // "variant-key default is NOT materialized" characterization test below.
    for (form_spec.keys) |*key| {
        if (key.default == null) continue;
        if (authorWroteKey(tree, hdr, key.name)) continue;

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
        });
    }
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

fn authorWroteKey(tree: *const Ast.Tree, hdr: Ast.FormHeader, key_name: []const u8) bool {
    return authorValueOnForm(tree, hdr, key_name) != null;
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
            // Vector defaults with `.expression` elements are rejected
            // at manifest-load time, so a literal `Default` reaching
            // here can never carry an inner `.expression` arm.
            error.NotALiteral => unreachable,
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
    err: anyerror,
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

// Characterization / tripwire for the variant-key-default gap (see the KNOWN
// LIMITATION comment on `materializeForForm`'s key loop). A `:default` declared
// on a *variant* key is silently not materialized — the Validator accepts the
// omission (`effectiveOptional`) on the assumption the default applies, but the
// overlay never carries it, so a consumer reading the effective value gets
// nothing. This is a documented gap, not desired behaviour: the assertion below
// will flip red the moment a future change starts materializing variant defaults,
// forcing a deliberate decision (materialize the active variant's keys vs. reject
// variant-key defaults at manifest load) and a rewrite of this test.
test "materializeDefaults: a variant-key default is NOT materialized (known limitation)" {
    const Parser = @import("Parser.zig");
    const a = testing.allocator;
    // `:kind special` activates the `special` variant and omits both the common
    // `:color` default and the variant-only `:size` default.
    var doc = try Parser.parse(a, "(widget :kind special)");
    defer doc.deinit();

    const plugin: Plugin.Plugin = .{
        .name = "ui",
        .forms = &.{.{
            .name = "widget",
            .keys = &.{
                .{ .name = "kind", .value_type = .symbol },
                .{ .name = "color", .value_type = .symbol, .default = .{ .symbol = "red" } },
            },
            .discriminant_name = "kind",
            .discriminant_idx = 0,
            .variants = &.{.{
                .when = "special",
                .keys = &.{.{ .name = "size", .value_type = .number, .default = .{ .number = 10 } }},
            }},
        }},
    };
    const schema = Schema.Schema.init(&.{plugin});

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    var result = try materializeDefaults(a, arena.allocator(), &doc, doc.root, schema);
    defer result.deinit(a);

    const widget = doc.root[0];
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    // Control: the *common* `:color` default materializes end-to-end.
    try testing.expect(result.materialized.defaultFor(widget, "color") != null);
    // The gap: the *variant* `:size` default does not (current behaviour).
    try testing.expectEqual(@as(?*const Entry, null), result.materialized.defaultFor(widget, "size"));
    // Exactly one entry (color), never two.
    try testing.expectEqual(@as(usize, 1), result.materialized.entries.len);
}
