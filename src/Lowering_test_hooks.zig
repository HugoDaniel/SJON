//! Test-only lowering hooks — the fixtures the conformance corpus and the
//! host test harnesses register. Kept out of `src/Lowering.zig` so the
//! production lowering API stays minimal, but re-exported from `root.zig`
//! (`pub const Lowering_test_hooks`) as shipped test scaffolding: a host's
//! own test suite drives the same hooks the corpus does. None is a
//! production lowerer — no host wires these into a real pipeline. The
//! conformance runner registers `test_identity_v1` against any case whose
//! name begins with `lowering-`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Lowering = @import("Lowering.zig");
const Ast = @import("Ast.zig");
const EffectiveView = @import("EffectiveView.zig");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
// `Expr` is referenced by the `test/eval-env-v1` tests below, which build an
// `Expr.Env` of host constants to drive `numberEval`'s evaluation path.
const Expr = @import("Expr.zig");
// Test-only imports: the hand-built-schema tests below drive `runLoweringPass`
// directly. Top-level `const` imports unused outside `test` blocks are not an
// error in Zig, so these stay out of non-test builds.
const Parser = @import("Parser.zig");
const MaterializedDefaults = @import("MaterializedDefaults.zig");
const core = @import("plugins/core.zig");

/// `test/identity-v1`: emit one form named `<input_head>-normal`
/// carrying every kvpair the author wrote on the input form. Walks
/// `form_spec.keys` to discover declared keys; reads each value via
/// `EffectiveView`, so a defaulted key also flows into the emitted
/// form. Values that don't round-trip cleanly through the limited
/// `EmittedValue` shape (nested forms, units, expressions) fall
/// through silently — this is a test hook, not a production lowerer.
pub const test_identity_v1: Lowering.LoweringHook = .{
    .id = "test/identity-v1",
    .lower = lowerIdentity,
};

fn lowerIdentity(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const new_head = try std.fmt.allocPrint(arena, "{s}-normal", .{input.head});

    var kvpairs: std.ArrayList(Lowering.EmittedKvpair) = .empty;

    for (input.form_spec.keys) |key| {
        const ev = input.view.getEffectiveValue(input.form_idx, key.name) orelse continue;
        const value = effectiveValueToEmitted(arena, input.view.tree, ev) catch continue;
        try kvpairs.append(arena, .{
            .key = try arena.dupe(u8, key.name),
            .value = value,
        });
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
    ev: EffectiveView.EffectiveValue,
) !Lowering.EmittedValue {
    return switch (ev) {
        .author => |idx| astNodeToEmitted(arena, tree, idx),
        .default => |entry| exprValueToEmitted(arena, entry.value),
    };
}

fn astNodeToEmitted(
    arena: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) !Lowering.EmittedValue {
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

fn exprValueToEmitted(arena: Allocator, v: anytype) !Lowering.EmittedValue {
    return switch (v) {
        .number => .{ .number = v.number },
        .integer_i64 => .{ .number = @as(f64, @floatFromInt(v.integer_i64)) },
        .integer_u64 => .{ .number = @as(f64, @floatFromInt(v.integer_u64)) },
        .boolean => .{ .boolean = v.boolean },
        .nil => .nil,
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        .keyword => |k| .{ .keyword = try arena.dupe(u8, k) },
        else => error.HookFailed,
    };
}

/// `test/bundle-v1`: a non-identity consumer-example hook. Reads
/// `:name`, `:target`, and optional `:kind` from a source
/// `(bundle …)` form via the typed-read helpers on `LoweringInput`
/// (so a defaulted `:target` flows through as a normalized symbol
/// too) and emits two forms:
///   1. `(asset :name <N>-asset [:kind <K>])`
///   2. `(link :from <N> :to <T>)`
/// Emission order is asset → link, so the provenance index for the
/// link is deterministically `entries[1]`. The link's `:to` slot is
/// typed `target-ref`; `input.symbol` papers over the keyword/symbol
/// duality at the read layer so the emitted value is always a plain
/// `Tag.symbol` regardless of whether the author wrote `:target` or
/// the materializer filled it from the schema default.
pub const test_bundle_v1: Lowering.LoweringHook = .{
    .id = "test/bundle-v1",
    .lower = lowerBundle,
};

fn lowerBundle(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const name = (try input.symbol("name")) orelse return error.HookFailed;
    const target = (try input.symbol("target")) orelse return error.HookFailed;
    const kind_opt = try input.symbol("kind");

    var asset_kvs: std.ArrayList(Lowering.EmittedKvpair) = .empty;
    try asset_kvs.append(arena, .{
        .key = try arena.dupe(u8, "name"),
        .value = .{ .symbol = try std.fmt.allocPrint(arena, "{s}-asset", .{name}) },
    });
    if (kind_opt) |kind| {
        try asset_kvs.append(arena, .{
            .key = try arena.dupe(u8, "kind"),
            .value = .{ .symbol = kind },
        });
    }
    try out.append(arena, .{
        .head = try arena.dupe(u8, "asset"),
        .kvpairs = try asset_kvs.toOwnedSlice(arena),
        .children = &.{},
        .source_form_idx = input.form_idx,
    });

    var link_kvs: std.ArrayList(Lowering.EmittedKvpair) = .empty;
    try link_kvs.append(arena, .{ .key = try arena.dupe(u8, "from"), .value = .{ .symbol = name } });
    try link_kvs.append(arena, .{ .key = try arena.dupe(u8, "to"), .value = .{ .symbol = target } });
    try out.append(arena, .{
        .head = try arena.dupe(u8, "link"),
        .kvpairs = try link_kvs.toOwnedSlice(arena),
        .children = &.{},
        .source_form_idx = input.form_idx,
    });
}

/// `test/probe-v1`: generic echo hook exercising the typed-read
/// helpers (`input.symbol` / `input.string` / `input.number` /
/// `input.boolean`). Iterates declared keys on the form spec, dispatches
/// to the helper that matches each key's `value_type`, and emits a
/// single `(echo …)` form carrying every key that resolved to a value.
/// `:type any`, named, vector, form, expr, and nil types are skipped —
/// the typed helpers cover scalars only. Used by `D8-typed-reads` tests
/// to assert helper return shape via the emission.
pub const test_probe_v1: Lowering.LoweringHook = .{
    .id = "test/probe-v1",
    .lower = lowerProbe,
};

fn lowerProbe(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    var kvpairs: std.ArrayList(Lowering.EmittedKvpair) = .empty;

    for (input.form_spec.keys) |key| {
        const maybe_value: ?Lowering.EmittedValue = switch (key.value_type) {
            .symbol => if (try input.symbol(key.name)) |s| .{ .symbol = s } else null,
            .string => if (try input.string(key.name)) |s| .{ .string = s } else null,
            .number => if (try input.number(key.name)) |n| .{ .number = n } else null,
            .boolean => if (try input.boolean(key.name)) |b| .{ .boolean = b } else null,
            else => null,
        };
        if (maybe_value) |v| {
            try kvpairs.append(arena, .{
                .key = try arena.dupe(u8, key.name),
                .value = v,
            });
        }
    }

    try out.append(arena, .{
        .head = try arena.dupe(u8, "echo"),
        .kvpairs = try kvpairs.toOwnedSlice(arena),
        .children = &.{},
        .source_form_idx = input.form_idx,
    });
}

/// `test/probe-wrong-call-v1`: deliberately calls `input.symbol` on a
/// key whose declared `value_type` is `.number`. Used by the D8-typed-
/// reads "wrong type" test to verify that a type-mismatched helper
/// call surfaces as `error.HookFailed`, which the pass driver turns
/// into a `lowering_hook_failed` diagnostic.
pub const test_probe_wrong_call_v1: Lowering.LoweringHook = .{
    .id = "test/probe-wrong-call-v1",
    .lower = lowerProbeWrongCall,
};

fn lowerProbeWrongCall(
    _: Allocator,
    input: *const Lowering.LoweringInput,
    _: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    // Caller wires a key named `n` typed `:type number`. Reading it as
    // a symbol must fail with `error.HookFailed`, which the pass driver
    // surfaces as a `lowering_hook_failed` diagnostic.
    _ = try input.symbol("n");
}

/// `test/fanout-v1`: a staging fan-out. Emits TWO forms with fixed heads
/// `left` and `right` (no kvpairs), so one source form branches into two
/// independently-lowerable forms. Paired with `test/to-row-v1` (both
/// branches lower to `row`) it exercises diamond multiplicity: one source
/// instance yields TWO `row` instances, never merged.
pub const test_fanout_v1: Lowering.LoweringHook = .{
    .id = "test/fanout-v1",
    .lower = lowerFanout,
};

fn lowerFanout(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    try out.append(arena, .{
        .head = try arena.dupe(u8, "left"),
        .source_form_idx = input.form_idx,
    });
    try out.append(arena, .{
        .head = try arena.dupe(u8, "right"),
        .source_form_idx = input.form_idx,
    });
}

/// `test/to-row-v1`: emits one form with the fixed head `row` (no
/// kvpairs). The convergence target for `test/fanout-v1`'s two branches —
/// each branch lowers to its own `row`, so two branches yield two rows
/// (one emitted instance per source instance × `:produces` edge; no
/// implicit merge).
pub const test_to_row_v1: Lowering.LoweringHook = .{
    .id = "test/to-row-v1",
    .lower = lowerToRow,
};

fn lowerToRow(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    try out.append(arena, .{
        .head = try arena.dupe(u8, "row"),
        .source_form_idx = input.form_idx,
    });
}

/// `test/nest-emit-v1`: emits a single `(wrap (leaf))` — one form holding one
/// nested positional child. When the consuming schema declares *both* `wrap`
/// and `leaf` lowerable, the emitted output is itself the self-contradictory
/// nested-lowerable shape, one staging layer down from the source. The only
/// hook that emits a form-shaped child, so it is the sole way to characterize
/// `lowering_nested_lowerable` firing on a hook's *emitted* structure (rather
/// than on author source) as the Host feeds the lowered tree back into the pass.
pub const test_nest_emit_v1: Lowering.LoweringHook = .{
    .id = "test/nest-emit-v1",
    .lower = lowerNestEmit,
};

fn lowerNestEmit(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const child = try arena.alloc(Lowering.EmittedValue, 1);
    child[0] = .{ .form = .{
        .head = try arena.dupe(u8, "leaf"),
        .source_form_idx = input.form_idx,
    } };
    try out.append(arena, .{
        .head = try arena.dupe(u8, "wrap"),
        .children = child,
        .source_form_idx = input.form_idx,
    });
}

// ---------------------------------------------------------------------------
// Container / group lowering — `webgpu/render-graph-v1`.
//
// A *container* form (`render-graph`) holds N `(pass …)` children. One hook
// invocation receives the container as `input.form_idx`; the `EffectiveView`
// it carries wraps the WHOLE document (`EffectiveView.tree` is the document
// tree, not a per-form slice), so the hook walks every child pass via
// `input.view.getEffectiveValue(child_idx, key)` and sequences texture ids
// across all of them in document order. That global view is exactly what a
// per-form hook lacks: lowering each `pass` in isolation, no invocation could
// see its siblings, so it could never assign a coherent cross-pass id.
//
// The passes are plain data forms with NO `:lowering`; the container consumes
// them, so this single invocation does everything — there is no second pass
// and nothing to reconcile. When the container lowers, its `pass` children
// (never forest roots) vanish with it; only the emitted terminals validate.
// ---------------------------------------------------------------------------

/// `webgpu/render-graph-v1`: container lowering. Reads every `(pass …)` child
/// of the `(render-graph …)` container, assigns each a texture id by document
/// position, and emits — per pass — a `gpu-texture` named by that id, a
/// `gpu-render-pass` whose `:reads` points at the *previous* pass's texture
/// (the cross-pass dependency only a whole-graph view can wire), and, only
/// when the pass is `:multisample true`, a synthesized `gpu-auto-blit`. Every
/// emitted head is listed in the container's `:produces` and declared as a
/// terminal form; none is authored by hand — they are resources the hook
/// materializes from the graph shape.
pub const webgpu_render_graph_v1: Lowering.LoweringHook = .{
    .id = "webgpu/render-graph-v1",
    .lower = lowerRenderGraph,
};

fn lowerRenderGraph(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const view = input.view;
    const hdr = view.tree.formHeader(input.form_idx);

    // Document-order index over the `pass` children: this IS the texture id.
    // A per-pass hook would restart the counter at 0 for every pass, so the
    // ids would collide; the container sees the whole set and numbers them
    // once, coherently.
    var id: usize = 0;
    for (hdr.children) |child| {
        if (view.tree.tagOf(child) != .form) continue;
        if (!std.mem.eql(u8, view.tree.formHeader(child).head, "pass")) continue;

        const pass_name = (try passSymbol(arena, view, child, "name")) orelse return error.HookFailed;
        const multisample = try passBoolean(view, child, "multisample");

        // One texture per pass, named by its global sequence id.
        {
            const kvs = try arena.alloc(Lowering.EmittedKvpair, 1);
            kvs[0] = .{
                .key = try arena.dupe(u8, "name"),
                .value = .{ .symbol = try std.fmt.allocPrint(arena, "tex-{d}", .{id}) },
            };
            try out.append(arena, .{
                .head = try arena.dupe(u8, "gpu-texture"),
                .kvpairs = kvs,
                .source_form_idx = input.form_idx,
            });
        }

        // The render pass. Pass 0 has no upstream; every later pass reads the
        // texture written by its predecessor — wiring that needs the whole
        // graph in view at once.
        {
            var kvs: std.ArrayList(Lowering.EmittedKvpair) = .empty;
            try kvs.append(arena, .{ .key = try arena.dupe(u8, "name"), .value = .{ .symbol = pass_name } });
            if (id > 0) {
                try kvs.append(arena, .{
                    .key = try arena.dupe(u8, "reads"),
                    .value = .{ .symbol = try std.fmt.allocPrint(arena, "tex-{d}", .{id - 1}) },
                });
            }
            try out.append(arena, .{
                .head = try arena.dupe(u8, "gpu-render-pass"),
                .kvpairs = try kvs.toOwnedSlice(arena),
                .source_form_idx = input.form_idx,
            });
        }

        // A multisampled pass needs a resolve step the author never wrote —
        // emitted only when the condition holds (conditional, emergent output).
        if (multisample) {
            const kvs = try arena.alloc(Lowering.EmittedKvpair, 1);
            kvs[0] = .{ .key = try arena.dupe(u8, "pass"), .value = .{ .symbol = pass_name } };
            try out.append(arena, .{
                .head = try arena.dupe(u8, "gpu-auto-blit"),
                .kvpairs = kvs,
                .source_form_idx = input.form_idx,
            });
        }

        id += 1;
    }

    // A render-graph with no passes is malformed; guard so the hook never
    // emits an empty invocation. (Surface validation also rejects an empty
    // container when the schema constrains its positionals.)
    if (id == 0) return error.HookFailed;
}

/// Read a symbol-typed key off an *arbitrary* form index (a child pass), not
/// the lowered container. `LoweringInput.symbol` hardcodes the container's
/// own `form_idx`, so container lowering reads its children through the view
/// directly. Mirrors `LoweringInput.symbol`'s author-symbol / author-keyword
/// / materialized-default coercion so a defaulted pass key flows through too.
fn passSymbol(
    arena: Allocator,
    view: EffectiveView.EffectiveView,
    form_idx: Ast.NodeIndex,
    key: []const u8,
) Lowering.LoweringError!?[]const u8 {
    const ev = view.getEffectiveValue(form_idx, key) orelse return null;
    return switch (ev) {
        .author => |node| switch (view.tree.tagOf(node)) {
            .symbol => try arena.dupe(u8, view.tree.symbolText(node)),
            .keyword => try arena.dupe(u8, view.tree.keywordText(node)),
            else => error.HookFailed,
        },
        .default => |entry| switch (entry.value) {
            .keyword => |k| try arena.dupe(u8, k),
            else => error.HookFailed,
        },
    };
}

/// Read a boolean-typed key off a child pass, defaulting to `false` when the
/// key is absent (the author omitted an optional flag). Sibling of
/// `passSymbol`; mirrors `LoweringInput.boolean`.
fn passBoolean(
    view: EffectiveView.EffectiveView,
    form_idx: Ast.NodeIndex,
    key: []const u8,
) Lowering.LoweringError!bool {
    const ev = view.getEffectiveValue(form_idx, key) orelse return false;
    return switch (ev) {
        .author => |node| switch (view.tree.tagOf(node)) {
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

/// `test/synth-terminal-v1`: minimal proof that a hook may emit a *declared
/// terminal* form the author never wrote. From a contentless `(needs-sampler)`
/// sugar form it synthesizes `(gpu-sampler :name default-sampler)` — a
/// resource that appears nowhere in the source. The terminal is declared
/// (`:open true`) and listed in `:produces`; no authored instance is required,
/// which is the whole point. Isolates the "emit an undeclared-by-the-author
/// resource" capability that `webgpu/render-graph-v1` also exercises, minus
/// the render-graph schema.
pub const test_synth_terminal_v1: Lowering.LoweringHook = .{
    .id = "test/synth-terminal-v1",
    .lower = lowerSynthTerminal,
};

fn lowerSynthTerminal(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const kvs = try arena.alloc(Lowering.EmittedKvpair, 1);
    kvs[0] = .{
        .key = try arena.dupe(u8, "name"),
        .value = .{ .symbol = try arena.dupe(u8, "default-sampler") },
    };
    try out.append(arena, .{
        .head = try arena.dupe(u8, "gpu-sampler"),
        .kvpairs = kvs,
        .source_form_idx = input.form_idx,
    });
}

/// `test/synth-positional-v1`: minimal proof that a hook may emit a *bare
/// positional atom*. From a contentless `(shader-decl)` sugar form it
/// synthesizes `(module shader)` — head `module`, a single positional
/// `.symbol` child, no kvpairs — the same shape an author writes by hand.
/// This is the capability `EmittedForm.children` gained when it became
/// `[]EmittedValue`; `test/synth-terminal-v1` next door emits the
/// kvpair-only counterpart. Paired with the `lowering-positional-atom`
/// conformance case, which drives the hook through the Host pipeline and
/// asserts the synthesized form revalidates clean under `:positional any`.
pub const test_synth_positional_v1: Lowering.LoweringHook = .{
    .id = "test/synth-positional-v1",
    .lower = lowerSynthPositional,
};

fn lowerSynthPositional(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const children = try arena.alloc(Lowering.EmittedValue, 1);
    children[0] = .{ .symbol = try arena.dupe(u8, "shader") };
    try out.append(arena, .{
        .head = try arena.dupe(u8, "module"),
        .children = children,
        .source_form_idx = input.form_idx,
    });
}

// ---------------------------------------------------------------------------
// Per-form lowering — `webgpu/render-pipeline-v1`.
//
// The executable companion to `examples/webgpu-render-pipeline.sjon`. Unlike
// `webgpu/render-graph-v1` (a *container* hook that consumes its children),
// this is a *per-form* hook: it receives one `(render-pipeline …)` and emits
// one `(gpu-render-pipeline-descriptor …)` — the minimal-but-representative
// terminal a WebGPU host would feed to `device.createRenderPipeline(...)`.
//
// It exercises the three read paths a real hook needs, one per emitted field:
//   * `:label`        — an author *string* literal, read via `input.string`.
//   * `:sample-count` — an author *expression* `(* 2 2)`. `input.number`
//     rejects an expr node (it accepts only literal number tags), so the hook
//     *evaluates* it (→ 4), proving lowering can consume computed values.
//   * `:depth-format` — pulled off the nested, author-empty `(depth-stencil)`
//     child, whose `:format` is a *materialized default* (`depth24plus`).
//     Reaching it through `getEffectiveValue(child_idx, …)` proves effective
//     defaults on a child form flow into lowering — the same whole-document
//     view the container hook relies on.
//
// The `(gpu-render-pipeline-descriptor …)` terminal is `:open true`, so it
// accepts whatever shape the hook emits; declaring the head is the whole cost.
// ---------------------------------------------------------------------------

/// `webgpu/render-pipeline-v1`: per-form lowering. See the section comment.
pub const webgpu_render_pipeline_v1: Lowering.LoweringHook = .{
    .id = "webgpu/render-pipeline-v1",
    .lower = lowerRenderPipeline,
};

fn lowerRenderPipeline(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const view = input.view;
    var kvs: std.ArrayList(Lowering.EmittedKvpair) = .empty;

    // `:label` — optional author string. Emitted only when present.
    if (try input.string("label")) |label| {
        try kvs.append(arena, .{ .key = try arena.dupe(u8, "label"), .value = .{ .string = label } });
    }

    // `:sample-count` — author expression `(* 2 2)`; `numberEval` evaluates it
    // (against the pass env, empty here) so the descriptor carries the computed
    // `4`, not the raw expr node.
    const sample_count = (try input.numberEval("sample-count")) orelse return error.HookFailed;
    try kvs.append(arena, .{ .key = try arena.dupe(u8, "sample-count"), .value = .{ .number = sample_count } });

    // `:depth-format` — the nested `(depth-stencil)`'s `:format`, which the
    // author left to its `depth24plus` default. Walks the pipeline's children
    // for the section form and reads its effective value, exactly as the
    // container hook reaches each `(pass …)`.
    const hdr = view.tree.formHeader(input.form_idx);
    for (hdr.children) |child| {
        if (view.tree.tagOf(child) != .form) continue;
        if (!std.mem.eql(u8, view.tree.formHeader(child).head, "depth-stencil")) continue;
        if (try passSymbol(arena, view, child, "format")) |fmt| {
            try kvs.append(arena, .{ .key = try arena.dupe(u8, "depth-format"), .value = .{ .symbol = fmt } });
        }
        break;
    }

    try out.append(arena, .{
        .head = try arena.dupe(u8, "gpu-render-pipeline-descriptor"),
        .kvpairs = try kvs.toOwnedSlice(arena),
        .source_form_idx = input.form_idx,
    });
}

// ---------------------------------------------------------------------------
// Host-supplied env — `test/eval-env-v1`.
//
// The synthetic exerciser for `LoweringInput.numberEval` + the threaded
// `Expr.Env`. Reads `:count` via `numberEval` and emits `(descriptor :count
// <n>)`. With a populated env, `(thing :count (* workgroup-size 1))` lowers to
// `:count 16` (the env binds `workgroup-size = 16`); with the default empty env
// the free variable is unbound, `numberEval` returns `HookFailed`, and the pass
// surfaces `lowering_hook_failed` — proving the env is load-bearing, not
// decorative. A literal `:count 7` takes `numberEval`'s fast path (no env
// needed). No in-repo production consumer yet (PNGine adopts it post-cutover);
// this hook stands in for one.
// ---------------------------------------------------------------------------

/// `test/eval-env-v1`: per-form lowering reading `:count` through the
/// eval-capable `numberEval`. See the section comment.
pub const test_eval_env_v1: Lowering.LoweringHook = .{
    .id = "test/eval-env-v1",
    .lower = lowerEvalEnv,
};

fn lowerEvalEnv(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    // `:count` — an author expression evaluated against the host env (a free
    // variable resolves to an injected constant), a computed literal, or a
    // plain number via the fast path. A non-numeric result, or a free variable
    // the env can't bind, → HookFailed.
    const count = (try input.numberEval("count")) orelse return error.HookFailed;
    var kvs: std.ArrayList(Lowering.EmittedKvpair) = .empty;
    try kvs.append(arena, .{ .key = try arena.dupe(u8, "count"), .value = .{ .number = count } });
    try out.append(arena, .{
        .head = try arena.dupe(u8, "descriptor"),
        .kvpairs = try kvs.toOwnedSlice(arena),
        .source_form_idx = input.form_idx,
    });
}

test "test_identity_v1: registers under its id" {
    const gpa = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, test_identity_v1);
    const hit = registry.lookup("test/identity-v1") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("test/identity-v1", hit.id);
}

test "test_bundle_v1: registers under its id" {
    const gpa = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, test_bundle_v1);
    const hit = registry.lookup("test/bundle-v1") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("test/bundle-v1", hit.id);
}

test "test_probe_v1: registers under its id" {
    const gpa = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, test_probe_v1);
    const hit = registry.lookup("test/probe-v1") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("test/probe-v1", hit.id);
}

test "test_probe_wrong_call_v1: registers under its id" {
    const gpa = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, test_probe_wrong_call_v1);
    const hit = registry.lookup("test/probe-wrong-call-v1") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("test/probe-wrong-call-v1", hit.id);
}

test "test_fanout_v1: registers under its id" {
    const gpa = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, test_fanout_v1);
    const hit = registry.lookup("test/fanout-v1") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("test/fanout-v1", hit.id);
}

test "test_to_row_v1: registers under its id" {
    const gpa = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, test_to_row_v1);
    const hit = registry.lookup("test/to-row-v1") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("test/to-row-v1", hit.id);
}

test "test_nest_emit_v1: registers under its id" {
    const gpa = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, test_nest_emit_v1);
    const hit = registry.lookup("test/nest-emit-v1") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("test/nest-emit-v1", hit.id);
}

test "webgpu_render_graph_v1: registers under its id" {
    const gpa = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, webgpu_render_graph_v1);
    const hit = registry.lookup("webgpu/render-graph-v1") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("webgpu/render-graph-v1", hit.id);
}

test "test_synth_terminal_v1: registers under its id" {
    const gpa = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, test_synth_terminal_v1);
    const hit = registry.lookup("test/synth-terminal-v1") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("test/synth-terminal-v1", hit.id);
}

test "test_synth_positional_v1: registers under its id" {
    const gpa = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, test_synth_positional_v1);
    const hit = registry.lookup("test/synth-positional-v1") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("test/synth-positional-v1", hit.id);
}

test "webgpu_render_pipeline_v1: registers under its id" {
    const gpa = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, webgpu_render_pipeline_v1);
    const hit = registry.lookup("webgpu/render-pipeline-v1") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("webgpu/render-pipeline-v1", hit.id);
}

test "test_eval_env_v1: registers under its id" {
    const gpa = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, test_eval_env_v1);
    const hit = registry.lookup("test/eval-env-v1") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("test/eval-env-v1", hit.id);
}

// Primary coherence proof. The conformance corpus only observes diagnostics;
// this asserts the texture-id *sequence* precisely by inspecting the emitted
// forms before tree construction. Three sibling passes must yield textures
// `tex-0 / tex-1 / tex-2` in document order, and each non-first pass must read
// its predecessor's texture — the cross-pass property a per-form hook (which
// sees one pass at a time) could never produce.
test "webgpu_render_graph_v1: sequences texture ids across sibling passes in document order" {
    const gpa = std.testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const a = plugin_arena.allocator();

    // `pass`: `:name` (required symbol) + `:multisample` (optional boolean).
    const pass_keys = try a.alloc(Plugin.KeySpec, 2);
    pass_keys[0] = .{ .name = "name", .value_type = .symbol, .optional = false };
    pass_keys[1] = .{ .name = "multisample", .value_type = .boolean, .optional = true };

    const produces = try a.alloc([]const u8, 3);
    produces[0] = "gpu-render-pass";
    produces[1] = "gpu-texture";
    produces[2] = "gpu-auto-blit";

    // `render-graph` is `:open true`, so it accepts positional `(pass …)`
    // children at surface validation (Validator: `.none` positional policy is
    // only an error on closed forms). The emitted terminals are `:open true`.
    const forms = try a.alloc(Plugin.FormSpec, 5);
    forms[0] = .{
        .name = "render-graph",
        .open = true,
        .lowering = .{ .hook = "webgpu/render-graph-v1", .produces = produces },
    };
    forms[1] = .{ .name = "pass", .keys = pass_keys };
    forms[2] = .{ .name = "gpu-texture", .open = true };
    forms[3] = .{ .name = "gpu-render-pass", .open = true };
    forms[4] = .{ .name = "gpu-auto-blit", .open = true };

    const plugins_slice = try a.alloc(Plugin.Plugin, 1);
    plugins_slice[0] = .{ .name = "webgpu", .forms = forms };
    const schema: Schema.Schema = .{ .plugins = plugins_slice };

    var tree = try Parser.parse(gpa, "(render-graph (pass :name a) (pass :name b) (pass :name c))");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, webgpu_render_graph_v1);

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try Lowering.runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    // One invocation (the container), clean — every emitted head is in
    // `:produces`, within bounds.
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), pr.invocations.len);

    // 3 passes, none multisampled → 2 forms each: gpu-texture + gpu-render-pass,
    // interleaved in document order.
    const out = pr.invocations[0].forms;
    try std.testing.expectEqual(@as(usize, 6), out.len);

    // Textures sequenced 0,1,2 by document position.
    try std.testing.expectEqualStrings("gpu-texture", out[0].head);
    try std.testing.expectEqualStrings("tex-0", out[0].kvpairs[0].value.symbol);
    try std.testing.expectEqualStrings("gpu-texture", out[2].head);
    try std.testing.expectEqualStrings("tex-1", out[2].kvpairs[0].value.symbol);
    try std.testing.expectEqualStrings("gpu-texture", out[4].head);
    try std.testing.expectEqualStrings("tex-2", out[4].kvpairs[0].value.symbol);

    // Cross-pass wiring: the first pass reads nothing; `b` reads `a`'s texture
    // (tex-0), `c` reads `b`'s (tex-1).
    try std.testing.expectEqualStrings("gpu-render-pass", out[1].head);
    try std.testing.expectEqual(@as(usize, 1), out[1].kvpairs.len);
    try std.testing.expectEqualStrings("gpu-render-pass", out[3].head);
    try std.testing.expectEqualStrings("reads", out[3].kvpairs[1].key);
    try std.testing.expectEqualStrings("tex-0", out[3].kvpairs[1].value.symbol);
    try std.testing.expectEqualStrings("reads", out[5].kvpairs[1].key);
    try std.testing.expectEqualStrings("tex-1", out[5].kvpairs[1].value.symbol);
}

// Emission proof for the per-form pipeline hook. Asserts each of the three
// read paths lands the right value in the descriptor: an author string
// (`:label`), an *evaluated* author expression (`:sample-count (* 2 2)` → 4),
// and a *materialized default* read off a nested child (`(depth-stencil)`'s
// `:format` → depth24plus). The schema seeds core[0] so the hook can evaluate
// `(* 2 2)`; webgpu[1] carries the forms.
test "webgpu_render_pipeline_v1: emits descriptor with computed sample-count and defaulted depth-format" {
    const gpa = std.testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const a = plugin_arena.allocator();

    // `render-pipeline`: `:open true` accepts the positional `(depth-stencil)`
    // child at surface validation; `:label` + `:sample-count` are its keys.
    const rp_keys = try a.alloc(Plugin.KeySpec, 2);
    rp_keys[0] = .{ .name = "label", .value_type = .string, .optional = true };
    rp_keys[1] = .{ .name = "sample-count", .value_type = .number, .default = .{ .number = 1 }, .optional = true };

    const produces = try a.alloc([]const u8, 1);
    produces[0] = "gpu-render-pipeline-descriptor";

    // `depth-stencil`: one symbol key with a default — the author-empty
    // `(depth-stencil)` materializes `:format depth24plus`, what the hook reads.
    const ds_keys = try a.alloc(Plugin.KeySpec, 1);
    ds_keys[0] = .{ .name = "format", .value_type = .symbol, .default = .{ .symbol = "depth24plus" }, .optional = true };

    const forms = try a.alloc(Plugin.FormSpec, 3);
    forms[0] = .{
        .name = "render-pipeline",
        .open = true,
        .keys = rp_keys,
        .lowering = .{ .hook = "webgpu/render-pipeline-v1", .produces = produces },
    };
    forms[1] = .{ .name = "depth-stencil", .keys = ds_keys };
    forms[2] = .{ .name = "gpu-render-pipeline-descriptor", .open = true };

    const plugins_slice = try a.alloc(Plugin.Plugin, 2);
    plugins_slice[0] = core.plugin;
    plugins_slice[1] = .{ .name = "webgpu", .forms = forms };
    const schema: Schema.Schema = .{ .plugins = plugins_slice };

    var tree = try Parser.parse(gpa, "(render-pipeline :label \"hello-triangle\" :sample-count (* 2 2) (depth-stencil))");
    defer tree.deinit();

    var overlay_arena = std.heap.ArenaAllocator.init(gpa);
    defer overlay_arena.deinit();
    var mat = try MaterializedDefaults.materializeDefaults(gpa, overlay_arena.allocator(), &tree, tree.root, schema);
    defer mat.deinit(gpa);

    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, webgpu_render_pipeline_v1);

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try Lowering.runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &mat.materialized, &registry, .{});
    defer pr.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), pr.invocations.len);

    const out = pr.invocations[0].forms;
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("gpu-render-pipeline-descriptor", out[0].head);

    // Three emitted fields, one per read path, in append order.
    const kvs = out[0].kvpairs;
    try std.testing.expectEqual(@as(usize, 3), kvs.len);
    try std.testing.expectEqualStrings("label", kvs[0].key);
    try std.testing.expectEqualStrings("hello-triangle", kvs[0].value.string);
    try std.testing.expectEqualStrings("sample-count", kvs[1].key);
    try std.testing.expectEqual(@as(f64, 4), kvs[1].value.number);
    try std.testing.expectEqualStrings("depth-format", kvs[2].key);
    try std.testing.expectEqualStrings("depth24plus", kvs[2].value.symbol);
}

// Shared schema for the `test/eval-env-v1` tests: a `(thing :count <number>)`
// sugar form that lowers via the hook to `(descriptor :count <n>)`. `:count` is
// `:type number`, so the validator *defers* an expression in that slot (the
// shape `numberEval` evaluates) while still rejecting a bare symbol as
// `wrong_underlying` — which is precisely why a host constant is referenced
// *inside* an expression (`(* workgroup-size 1)`), never as a bare
// `:count workgroup-size`. `core` supplies `*` for the expression.
fn evalEnvSchema(a: Allocator) Allocator.Error!Schema.Schema {
    const thing_keys = try a.alloc(Plugin.KeySpec, 1);
    thing_keys[0] = .{ .name = "count", .value_type = .number, .optional = true };
    const produces = try a.alloc([]const u8, 1);
    produces[0] = "descriptor";
    const forms = try a.alloc(Plugin.FormSpec, 2);
    forms[0] = .{
        .name = "thing",
        .keys = thing_keys,
        .lowering = .{ .hook = "test/eval-env-v1", .produces = produces },
    };
    forms[1] = .{ .name = "descriptor", .open = true };
    const plugins_slice = try a.alloc(Plugin.Plugin, 2);
    plugins_slice[0] = core.plugin;
    plugins_slice[1] = .{ .name = "test", .forms = forms };
    return .{ .plugins = plugins_slice };
}

// The headline proof for host-supplied env: the embedder injects
// `workgroup-size = 16`, and the hook's `numberEval` resolves the free variable
// inside the author expression `(* workgroup-size 1)` → 16. Without the env this
// document does not lower (the next test); the env is what makes it resolve.
test "test_eval_env_v1: populated env resolves a free variable in an author expression" {
    const gpa = std.testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const a = plugin_arena.allocator();

    const schema = try evalEnvSchema(a);

    var tree = try Parser.parse(gpa, "(thing :count (* workgroup-size 1))");
    defer tree.deinit();

    var overlay_arena = std.heap.ArenaAllocator.init(gpa);
    defer overlay_arena.deinit();
    var mat = try MaterializedDefaults.materializeDefaults(gpa, overlay_arena.allocator(), &tree, tree.root, schema);
    defer mat.deinit(gpa);

    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, test_eval_env_v1);

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    const bindings = [_]Expr.Env.Binding{.{ .name = "workgroup-size", .value = .{ .number = 16 } }};
    const env: Expr.Env = .{ .bindings = &bindings };

    var pr = try Lowering.runLoweringPassWithEnv(gpa, pass_arena.allocator(), &tree, tree.root, schema, &mat.materialized, &registry, .{}, &env);
    defer pr.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), pr.invocations.len);
    const kvs = pr.invocations[0].forms[0].kvpairs;
    try std.testing.expectEqual(@as(usize, 1), kvs.len);
    try std.testing.expectEqualStrings("count", kvs[0].key);
    try std.testing.expectEqual(@as(f64, 16), kvs[0].value.number);
}

// Negative space for the same document: `runLoweringPass` supplies the default
// empty env, so `workgroup-size` is unbound, `numberEval` raises
// `UnknownBinding` → HookFailed, and the pass surfaces one
// `lowering_hook_failed` with no invocation. Proves the env is load-bearing.
test "test_eval_env_v1: empty env leaves the free variable unbound → lowering_hook_failed" {
    const gpa = std.testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const a = plugin_arena.allocator();

    const schema = try evalEnvSchema(a);

    var tree = try Parser.parse(gpa, "(thing :count (* workgroup-size 1))");
    defer tree.deinit();

    var overlay_arena = std.heap.ArenaAllocator.init(gpa);
    defer overlay_arena.deinit();
    var mat = try MaterializedDefaults.materializeDefaults(gpa, overlay_arena.allocator(), &tree, tree.root, schema);
    defer mat.deinit(gpa);

    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, test_eval_env_v1);

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try Lowering.runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &mat.materialized, &registry, .{});
    defer pr.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), pr.invocations.len);
    try std.testing.expectEqual(@as(usize, 1), pr.diagnostics.len);
    try std.testing.expectEqual(Ast.Diagnostic.Code.lowering_hook_failed, pr.diagnostics[0].code);
}

// A plain author number takes `numberEval`'s literal fast path — no evaluator,
// so the empty env is irrelevant. `:count 7` → 7.
test "test_eval_env_v1: a literal number takes the fast path (no env needed)" {
    const gpa = std.testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const a = plugin_arena.allocator();

    const schema = try evalEnvSchema(a);

    var tree = try Parser.parse(gpa, "(thing :count 7)");
    defer tree.deinit();

    var overlay_arena = std.heap.ArenaAllocator.init(gpa);
    defer overlay_arena.deinit();
    var mat = try MaterializedDefaults.materializeDefaults(gpa, overlay_arena.allocator(), &tree, tree.root, schema);
    defer mat.deinit(gpa);

    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, test_eval_env_v1);

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try Lowering.runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &mat.materialized, &registry, .{});
    defer pr.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), pr.invocations.len);
    const kvs = pr.invocations[0].forms[0].kvpairs;
    try std.testing.expectEqual(@as(f64, 7), kvs[0].value.number);
}

// `numberEval` rejects a non-numeric *result*. `(if true "x" "y")` is a form
// (so the validator defers it in the number slot) that evaluates to a string;
// `valueToF64` returns null → HookFailed → `lowering_hook_failed`. Uses a
// populated env to prove the failure is the string result, not an unbound name.
test "test_eval_env_v1: a non-number expression result → lowering_hook_failed" {
    const gpa = std.testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const a = plugin_arena.allocator();

    const schema = try evalEnvSchema(a);

    var tree = try Parser.parse(gpa, "(thing :count (if true \"x\" \"y\"))");
    defer tree.deinit();

    var overlay_arena = std.heap.ArenaAllocator.init(gpa);
    defer overlay_arena.deinit();
    var mat = try MaterializedDefaults.materializeDefaults(gpa, overlay_arena.allocator(), &tree, tree.root, schema);
    defer mat.deinit(gpa);

    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, test_eval_env_v1);

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    const bindings = [_]Expr.Env.Binding{.{ .name = "workgroup-size", .value = .{ .number = 16 } }};
    const env: Expr.Env = .{ .bindings = &bindings };

    var pr = try Lowering.runLoweringPassWithEnv(gpa, pass_arena.allocator(), &tree, tree.root, schema, &mat.materialized, &registry, .{}, &env);
    defer pr.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), pr.invocations.len);
    try std.testing.expectEqual(@as(usize, 1), pr.diagnostics.len);
    try std.testing.expectEqual(Ast.Diagnostic.Code.lowering_hook_failed, pr.diagnostics[0].code);
}

// ---------------------------------------------------------------------------
// Long-tail coverage for `numberEval` + the host-supplied env. The four tests
// above pin the headline paths (populated env, empty env, literal fast-path,
// non-number author expression); the tests below reach the arms they leave
// uncovered:
//   * `valueToF64`'s integer variants — only an *identity* op (`if`/`let`/a
//     bound symbol) carries an integer `Value` to the hook; arithmetic
//     collapses to f64, so `(* …)` could never exercise them.
//   * `numberEval`'s `.default` arm (numeric default read; non-numeric default
//     → HookFailed) — every test above drives the `.author` arm.
//   * env mechanics the flat single-binding tests skip: parent-chain traversal,
//     child-shadows-parent, multiple free variables.
//   * fractional-result fidelity, unit-dropping inside an expression, and a
//     non-UnknownBinding eval failure (DivisionByZero) folding to HookFailed.
// ---------------------------------------------------------------------------

/// What a long-tail assertion needs after driving `test/eval-env-v1` over one
/// document + env: the single emitted `:count` (when the hook ran) and the
/// first diagnostic code (when it didn't), plus the invocation/diagnostic
/// counts. Both escaping fields are value types, so `runEvalEnv` frees every
/// arena before returning and the caller manages nothing.
const EvalEnvOutcome = struct {
    count: ?f64 = null,
    first_diag: ?Ast.Diagnostic.Code = null,
    invocations: usize = 0,
    diagnostics: usize = 0,
};

/// Drive the eval-env hook once and collapse the result to an `EvalEnvOutcome`.
/// `schema` is borrowed — its slices live in the caller's arena, which must
/// outlive this call (it does: callers `defer` the arena at test scope).
fn runEvalEnv(
    gpa: Allocator,
    schema: Schema.Schema,
    src: [:0]const u8,
    env: *const Expr.Env,
) !EvalEnvOutcome {
    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();

    var overlay_arena = std.heap.ArenaAllocator.init(gpa);
    defer overlay_arena.deinit();
    var mat = try MaterializedDefaults.materializeDefaults(gpa, overlay_arena.allocator(), &tree, tree.root, schema);
    defer mat.deinit(gpa);

    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, test_eval_env_v1);

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try Lowering.runLoweringPassWithEnv(gpa, pass_arena.allocator(), &tree, tree.root, schema, &mat.materialized, &registry, .{}, env);
    defer pr.deinit(gpa);

    var out: EvalEnvOutcome = .{ .invocations = pr.invocations.len, .diagnostics = pr.diagnostics.len };
    if (pr.invocations.len > 0 and pr.invocations[0].forms.len > 0) {
        const kvs = pr.invocations[0].forms[0].kvpairs;
        if (kvs.len > 0) out.count = kvs[0].value.number;
    }
    if (pr.diagnostics.len > 0) out.first_diag = pr.diagnostics[0].code;
    return out;
}

// An `integer_i64` env binding reaches `valueToF64`'s `.integer_i64` arm only
// because `if` is an identity op: `(* …)` would collapse it to f64 first. The
// chosen branch returns the bound Value untouched, so a 16 stored as an exact
// i64 lands in the descriptor as 16.0.
test "test_eval_env_v1: an integer_i64 env binding survives an identity op (if)" {
    const gpa = std.testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const schema = try evalEnvSchema(plugin_arena.allocator());

    const bindings = [_]Expr.Env.Binding{.{ .name = "workgroup-size", .value = .{ .integer_i64 = 16 } }};
    const env: Expr.Env = .{ .bindings = &bindings };

    const out = try runEvalEnv(gpa, schema, "(thing :count (if true workgroup-size 0))", &env);
    try std.testing.expectEqual(@as(usize, 0), out.diagnostics);
    try std.testing.expectEqual(@as(usize, 1), out.invocations);
    try std.testing.expectEqual(@as(f64, 16), out.count orelse return error.TestNoCount);
}

// The `.integer_u64` arm is the one numeric arm neither arithmetic nor an i64
// binding can reach: a value above `i64.max` kept as an exact u64, carried
// through `if`, and collapsed to f64 only at `valueToF64`.
test "test_eval_env_v1: an integer_u64 env binding survives an identity op (if)" {
    const gpa = std.testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const schema = try evalEnvSchema(plugin_arena.allocator());

    const big: u64 = std.math.maxInt(u64);
    const bindings = [_]Expr.Env.Binding{.{ .name = "huge", .value = .{ .integer_u64 = big } }};
    const env: Expr.Env = .{ .bindings = &bindings };

    const out = try runEvalEnv(gpa, schema, "(thing :count (if true huge 0))", &env);
    try std.testing.expectEqual(@as(usize, 0), out.diagnostics);
    try std.testing.expectEqual(@as(usize, 1), out.invocations);
    try std.testing.expectEqual(@as(f64, @floatFromInt(big)), out.count orelse return error.TestNoCount);
}

// numberEval returns the true f64, not a truncated int: 16 / 3 = 5.333….
test "test_eval_env_v1: a fractional quotient keeps f64 precision" {
    const gpa = std.testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const schema = try evalEnvSchema(plugin_arena.allocator());

    const bindings = [_]Expr.Env.Binding{.{ .name = "workgroup-size", .value = .{ .number = 16 } }};
    const env: Expr.Env = .{ .bindings = &bindings };

    const out = try runEvalEnv(gpa, schema, "(thing :count (/ workgroup-size 3))", &env);
    try std.testing.expectEqual(@as(usize, 0), out.diagnostics);
    try std.testing.expectEqual(@as(usize, 1), out.invocations);
    try std.testing.expectApproxEqAbs(@as(f64, 16.0 / 3.0), out.count orelse return error.TestNoCount, 1e-9);
}

// One expression, two distinct free variables — both resolve from the same env.
test "test_eval_env_v1: an expression resolves two distinct free variables" {
    const gpa = std.testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const schema = try evalEnvSchema(plugin_arena.allocator());

    const bindings = [_]Expr.Env.Binding{
        .{ .name = "workgroup-size", .value = .{ .number = 16 } },
        .{ .name = "tiles", .value = .{ .number = 4 } },
    };
    const env: Expr.Env = .{ .bindings = &bindings };

    const out = try runEvalEnv(gpa, schema, "(thing :count (* workgroup-size tiles))", &env);
    try std.testing.expectEqual(@as(usize, 0), out.diagnostics);
    try std.testing.expectEqual(@as(usize, 1), out.invocations);
    try std.testing.expectEqual(@as(f64, 64), out.count orelse return error.TestNoCount);
}

// `wg` lives only in the parent env, `mul` only in the child. Resolving both
// proves the lowering path threads a real `*const Env` with its parent pointer
// intact — not a flattened copy of one frame. (`Env.lookup` walks `parent`.)
test "test_eval_env_v1: numberEval resolves a free variable through the env parent chain" {
    const gpa = std.testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const schema = try evalEnvSchema(plugin_arena.allocator());

    const outer_b = [_]Expr.Env.Binding{.{ .name = "wg", .value = .{ .number = 4 } }};
    const outer: Expr.Env = .{ .bindings = &outer_b };
    const inner_b = [_]Expr.Env.Binding{.{ .name = "mul", .value = .{ .number = 3 } }};
    const inner: Expr.Env = .{ .parent = &outer, .bindings = &inner_b };

    const out = try runEvalEnv(gpa, schema, "(thing :count (* wg mul))", &inner);
    try std.testing.expectEqual(@as(usize, 0), out.diagnostics);
    try std.testing.expectEqual(@as(usize, 1), out.invocations);
    try std.testing.expectEqual(@as(f64, 12), out.count orelse return error.TestNoCount);
}

// Same name bound in both frames; the child's value wins (lookup searches the
// child's bindings before recursing to the parent).
test "test_eval_env_v1: a child env binding shadows the parent" {
    const gpa = std.testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const schema = try evalEnvSchema(plugin_arena.allocator());

    const outer_b = [_]Expr.Env.Binding{.{ .name = "wg", .value = .{ .number = 4 } }};
    const outer: Expr.Env = .{ .bindings = &outer_b };
    const inner_b = [_]Expr.Env.Binding{.{ .name = "wg", .value = .{ .number = 100 } }};
    const inner: Expr.Env = .{ .parent = &outer, .bindings = &inner_b };

    const out = try runEvalEnv(gpa, schema, "(thing :count (* wg 1))", &inner);
    try std.testing.expectEqual(@as(usize, 0), out.diagnostics);
    try std.testing.expectEqual(@as(usize, 1), out.invocations);
    try std.testing.expectEqual(@as(f64, 100), out.count orelse return error.TestNoCount);
}

// A non-UnknownBinding eval failure still folds to HookFailed: with no free
// variables the only outcome is DivisionByZero, proving numberEval's catch-all
// maps *every* non-OOM `Expr.Error`, not just the unbound-name case.
test "test_eval_env_v1: a DivisionByZero eval failure folds to lowering_hook_failed" {
    const gpa = std.testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const schema = try evalEnvSchema(plugin_arena.allocator());

    const empty: Expr.Env = .{};
    const out = try runEvalEnv(gpa, schema, "(thing :count (/ 1 0))", &empty);
    try std.testing.expectEqual(@as(usize, 0), out.invocations);
    try std.testing.expectEqual(Ast.Diagnostic.Code.lowering_hook_failed, out.first_diag orelse return error.TestNoDiag);
}

// `5px` evaluates to the bare f64 5 (the unit is opaque to the closed expr
// vocabulary), so `(* 5px 4)` → 20. The literal-only `number` helper rejects a
// top-level number-with-unit; inside an expression numberEval evaluates it and
// the unit drops — the documented expr semantic, reached through lowering.
test "test_eval_env_v1: numberEval drops a unit on a number-with-unit operand" {
    const gpa = std.testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const schema = try evalEnvSchema(plugin_arena.allocator());

    const empty: Expr.Env = .{};
    const out = try runEvalEnv(gpa, schema, "(thing :count (* 5px 4))", &empty);
    try std.testing.expectEqual(@as(usize, 0), out.diagnostics);
    try std.testing.expectEqual(@as(usize, 1), out.invocations);
    try std.testing.expectEqual(@as(f64, 20), out.count orelse return error.TestNoCount);
}

/// Schema whose `:count` carries a default and a chosen value-type, so a
/// `(thing)` with no author `:count` materializes one — letting the tests
/// exercise numberEval's `.default` arm (read off the overlay, no evaluator)
/// for both a numeric default and a non-numeric one.
fn evalEnvSchemaWithDefault(
    a: Allocator,
    value_type: Plugin.ValueType,
    default: Plugin.KeySpec.Default,
) Allocator.Error!Schema.Schema {
    const thing_keys = try a.alloc(Plugin.KeySpec, 1);
    thing_keys[0] = .{ .name = "count", .value_type = value_type, .default = default, .optional = true };
    const produces = try a.alloc([]const u8, 1);
    produces[0] = "descriptor";
    const forms = try a.alloc(Plugin.FormSpec, 2);
    forms[0] = .{
        .name = "thing",
        .keys = thing_keys,
        .lowering = .{ .hook = "test/eval-env-v1", .produces = produces },
    };
    forms[1] = .{ .name = "descriptor", .open = true };
    const plugins_slice = try a.alloc(Plugin.Plugin, 2);
    plugins_slice[0] = core.plugin;
    plugins_slice[1] = .{ .name = "test", .forms = forms };
    return .{ .plugins = plugins_slice };
}

// `.default` arm: `(thing)` omits `:count`, so the effective value is the
// materialized default — numberEval `valueToF64`s it directly (no eval). The
// four headline tests all drive the `.author` arm; this is the other one.
test "test_eval_env_v1: numberEval reads a numeric schema default (the .default arm)" {
    const gpa = std.testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const schema = try evalEnvSchemaWithDefault(plugin_arena.allocator(), .number, .{ .number = 9 });

    const empty: Expr.Env = .{};
    const out = try runEvalEnv(gpa, schema, "(thing)", &empty);
    try std.testing.expectEqual(@as(usize, 0), out.diagnostics);
    try std.testing.expectEqual(@as(usize, 1), out.invocations);
    try std.testing.expectEqual(@as(f64, 9), out.count orelse return error.TestNoCount);
}

// `.default` arm, negative space: a symbol default materializes as `.keyword`,
// which `valueToF64` rejects (null → HookFailed) — the default-path mirror of
// the `.author` non-number test above.
test "test_eval_env_v1: a non-numeric schema default fails the .default arm" {
    const gpa = std.testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const schema = try evalEnvSchemaWithDefault(plugin_arena.allocator(), .symbol, .{ .symbol = "foo" });

    const empty: Expr.Env = .{};
    const out = try runEvalEnv(gpa, schema, "(thing)", &empty);
    try std.testing.expectEqual(@as(usize, 0), out.invocations);
    try std.testing.expectEqual(Ast.Diagnostic.Code.lowering_hook_failed, out.first_diag orelse return error.TestNoDiag);
}

// Emission proof for the bare-positional-atom hook. `(shader-decl)` lowers to a
// single `(module shader)`: head `module`, one positional `.symbol` child and no
// kvpairs — the shape only expressible since `EmittedForm.children` became
// `[]EmittedValue`. The pass is clean (`module` is in `:produces`, within
// bounds); the `lowering-positional-atom` conformance case then drives the same
// hook through the Host pipeline and asserts the synthesized form revalidates
// clean under `:positional any`.
test "test_synth_positional_v1: emits (module shader) as a bare positional symbol" {
    const gpa = std.testing.allocator;
    var plugin_arena = std.heap.ArenaAllocator.init(gpa);
    defer plugin_arena.deinit();
    const a = plugin_arena.allocator();

    const produces = try a.alloc([]const u8, 1);
    produces[0] = "module";

    // `shader-decl` is the sugar form; `module` is the produced terminal,
    // `:positional any` so the synthesized symbol child validates clean.
    const forms = try a.alloc(Plugin.FormSpec, 2);
    forms[0] = .{
        .name = "shader-decl",
        .open = true,
        .lowering = .{ .hook = "test/synth-positional-v1", .produces = produces },
    };
    forms[1] = .{ .name = "module", .open = true, .positional = .any };

    const plugins_slice = try a.alloc(Plugin.Plugin, 1);
    plugins_slice[0] = .{ .name = "gfx", .forms = forms };
    const schema: Schema.Schema = .{ .plugins = plugins_slice };

    var tree = try Parser.parse(gpa, "(shader-decl)");
    defer tree.deinit();

    const overlay = MaterializedDefaults.MaterializedDefaults{};
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, test_synth_positional_v1);

    var pass_arena = std.heap.ArenaAllocator.init(gpa);
    defer pass_arena.deinit();

    var pr = try Lowering.runLoweringPass(gpa, pass_arena.allocator(), &tree, tree.root, schema, &overlay, &registry, .{});
    defer pr.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), pr.invocations.len);

    const out = pr.invocations[0].forms;
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("module", out[0].head);
    try std.testing.expectEqual(@as(usize, 0), out[0].kvpairs.len);

    // The lone positional child is a bare symbol atom — the new capability.
    try std.testing.expectEqual(@as(usize, 1), out[0].children.len);
    try std.testing.expectEqualStrings("shader", out[0].children[0].symbol);
}
