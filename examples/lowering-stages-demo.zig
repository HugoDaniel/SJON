//! Lowering demo: a hook reads a neighbour by reference, a form lowers
//! through two layers and every layer survives, and a container's child
//! keeps its union-typed reference.
//!
//! Run with: zig build lowering-demo
//!
//! Lowering is host-owned. A manifest names a hook contract, as in
//! `:lowering (lowering :hook demo/step-v1 :produces [pass])`, and the
//! host registers Zig code under that id. No `sjon` CLI verb runs a
//! hook, which is why this is a Zig program and not a `.sjon` fixture:
//! it registers two hooks, drives three documents through
//! `Host.validateDocument`, and prints what came out of each layer.
//!
//! Act 1: `LoweringInput.resolveRef`. A hook resolves a cross-reference
//!        key on its own form to the form it names, then reads that form
//!        through the same effective view it reads itself with, so a
//!        neighbour's defaulted value arrives like an authored one.
//! Act 2: `HostResult.lowering_stages` and `provenanceChain`. A form
//!        that lowers into a form that lowers again runs two layers, the
//!        result keeps both, and a chain walks the terminal form back to
//!        the authored one hop by hop. Eject (replace a verb's span with
//!        the text of what the verb wrote) reads layer 0, and the demo
//!        prints what reading the terminal layer would have said instead.
//! Act 3: a container whose child carries a cross-reference through a
//!        `(union-shape …)` still lowers. The fragment pass that checks
//!        the container before its hook runs declines to judge
//!        cross-reference identity (`Validator.Options.defer_cross_refs`),
//!        so the hook fires and the whole-document pass resolves the name.
//!
//! The pieces this touches are documented in `docs/plugin-model-v1.md`
//! ("Reading a form the hook does not own", "The layers are part of the
//! result", "What the container's children may use").

const std = @import("std");
const sjon = @import("sjon");
const Allocator = std.mem.Allocator;
const Ast = sjon.Ast;
const Host = sjon.Host;
const Lowering = sjon.Lowering;

// ---------------------------------------------------------------------------
// The hooks. A hook is a function `(arena, *const LoweringInput,
// *LoweringOutput) LoweringError!void` registered under a string id.
// ---------------------------------------------------------------------------

/// `demo/step-v1`: emit the one head `:produces` lists, carrying every
/// declared key the source form has an effective value for. It is the
/// identity rewrite with a rename, which is all Acts 2 and 3 need: a
/// form that steps to the next form in a chain, or a container that
/// steps to its normalized twin.
const step_v1: Lowering.LoweringHook = .{ .id = "demo/step-v1", .lower = lowerStep };

fn lowerStep(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    const produces = input.lowering_spec.produces;
    if (produces.len != 1) {
        return out.fail(arena, "demo/step-v1 emits one head, and `:produces` lists {d}", .{produces.len});
    }
    try out.append(arena, .{
        .head = try arena.dupe(u8, produces[0]),
        .kvpairs = try copyDeclaredKeys(arena, input),
        .source_form_idx = input.form_idx,
    });
}

/// `demo/bind-v1`: `(bind :buffer X)` becomes `(binding :bytes N)` where
/// `N` is the `:size` of the `(buffer :name X …)` the reference names.
///
/// `resolveRef("buffer")` is keyed on the hook's own form: the key's
/// declared value kind says which forms it may name, so the hook never
/// picks a bucket, and the answer is a node index the effective view
/// already takes. A buffer that omitted `:size` answers through its
/// default, with nothing special in the hook.
const bind_v1: Lowering.LoweringHook = .{ .id = "demo/bind-v1", .lower = lowerBind };

fn lowerBind(
    arena: Allocator,
    input: *const Lowering.LoweringInput,
    out: *Lowering.LoweringOutput,
) Lowering.LoweringError!void {
    // Null is a miss (absent key, non-symbol value, or a name this layer
    // does not define), never an error: the whole-document pass owns
    // cross-reference reporting. A hook that wants to insist says so.
    const buffer = (try input.resolveRef("buffer")) orelse
        return out.fail(arena, "`:buffer` names no buffer this layer defines", .{});
    const bytes = numberAt(input, buffer, "size") orelse
        return out.fail(arena, "the named buffer carries no `:size`", .{});

    var kvs: std.ArrayList(Lowering.EmittedKvpair) = .empty;
    try kvs.append(arena, .{ .key = try arena.dupe(u8, "bytes"), .value = .{ .number = bytes } });
    try out.append(arena, .{
        .head = try arena.dupe(u8, "binding"),
        .kvpairs = try kvs.toOwnedSlice(arena),
        .source_form_idx = input.form_idx,
    });
}

/// The effective number in `key` on `form`, whether the author wrote it
/// or the schema defaulted it. Null when absent or not a number.
fn numberAt(input: *const Lowering.LoweringInput, form: Ast.NodeIndex, key: []const u8) ?f64 {
    const ev = input.view.getEffectiveValue(form, key) orelse return null;
    return switch (ev) {
        .author => |idx| switch (input.view.tree.tagOf(idx)) {
            .number, .number_i64, .number_u64 => input.view.tree.numberOf(idx),
            else => null,
        },
        .default => |entry| switch (entry.value) {
            .number => |n| n,
            .integer_i64 => |i| @as(f64, @floatFromInt(i)),
            .integer_u64 => |u| @as(f64, @floatFromInt(u)),
            else => null,
        },
    };
}

/// Every declared key with a symbol or number effective value, as
/// emitted kvpairs. Anything else is skipped: this is a demo hook, and
/// the two acts that use it only carry names and counts.
fn copyDeclaredKeys(arena: Allocator, input: *const Lowering.LoweringInput) Allocator.Error![]const Lowering.EmittedKvpair {
    var kvs: std.ArrayList(Lowering.EmittedKvpair) = .empty;
    for (input.form_spec.keys) |key| {
        const ev = input.view.getEffectiveValue(input.form_idx, key.name) orelse continue;
        const value: Lowering.EmittedValue = switch (ev) {
            .author => |idx| switch (input.view.tree.tagOf(idx)) {
                .symbol => .{ .symbol = try arena.dupe(u8, input.view.tree.symbolText(idx)) },
                .number, .number_i64, .number_u64 => .{ .number = input.view.tree.numberOf(idx) },
                else => continue,
            },
            // A symbol default lands as a keyword: `Expr.Value` has no
            // symbol variant. Emit it back as the symbol it was.
            .default => |entry| switch (entry.value) {
                .number => |n| .{ .number = n },
                .keyword => |k| .{ .symbol = try arena.dupe(u8, k) },
                else => continue,
            },
        };
        try kvs.append(arena, .{ .key = try arena.dupe(u8, key.name), .value = value });
    }
    return kvs.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// The three documents. Each carries its schema inline.
// ---------------------------------------------------------------------------

/// Act 1. A flat vocabulary: buffers and binds sit side by side at the
/// top level and name each other, so a `bind` hook has no subtree to
/// find its buffer in. `params` omits `:size` and gets it from the
/// schema's default.
const act1_source: [:0]const u8 =
    \\(plugin :name gpu :version "1.0.0"
    \\  (value-kind :name buffer-name :underlying symbol
    \\    :cross-ref (cross-ref :target buffer))
    \\  (form :name buffer
    \\    (key :name name :type symbol :optional false)
    \\    (key :name size :type number :optional true :default 256))
    \\  (form :name bind
    \\    :lowering (lowering :hook demo/bind-v1 :produces [binding])
    \\    (key :name buffer :type buffer-name :optional false))
    \\  (form :name binding
    \\    (key :name bytes :type number :optional false)))
    \\
    \\(buffer :name verts :size 1024)
    \\(buffer :name params)
    \\(bind :buffer verts)
    \\(bind :buffer params)
    \\
;

/// Act 2. `paint` is sugar for `pass`, and `pass` is sugar for `draw`:
/// two layers, each one hook invocation.
const act2_source: [:0]const u8 =
    \\(plugin :name brush :version "1.0.0"
    \\  (form :name paint
    \\    (key :name source :type symbol :optional false)
    \\    :lowering (lowering :hook demo/step-v1 :produces [pass]))
    \\  (form :name pass
    \\    (key :name source :type symbol :optional false)
    \\    :lowering (lowering :hook demo/step-v1 :produces [draw]))
    \\  (form :name draw
    \\    (key :name source :type symbol :optional false)))
    \\
    \\(paint :source dust)
    \\
;

/// Act 3. A `pass` container whose `(attach …)` child renders either to
/// the canvas (a member) or to a named texture (a cross-reference), the
/// two behind one union. `(present :pass main)` names the *lowered*
/// `pass-core`, so it resolves only if the container's hook ran.
const act3_source: [:0]const u8 =
    \\(plugin :name render :version "1.0.0"
    \\  (value-kind :name texture-name :underlying symbol
    \\    :cross-ref (cross-ref :target texture))
    \\  (value-kind :name surface :underlying symbol
    \\    :members (member-set :values [canvas]))
    \\  (value-kind :name surface-or-texture :underlying union
    \\    :union (union-shape :alternatives [surface texture-name]))
    \\  (value-kind :name attachment :underlying form
    \\    :heads (head-set :names [attach]))
    \\  (value-kind :name pass-name :underlying symbol
    \\    :cross-ref (cross-ref :target pass-core))
    \\
    \\  (form :name texture
    \\    (key :name name :type symbol :optional false))
    \\  (form :name attach
    \\    (key :name to :type surface-or-texture :optional false))
    \\  (form :name pass
    \\    (key :name name :type symbol :optional false)
    \\    :positional attachment
    \\    :lowering (lowering :hook demo/step-v1 :produces [pass-core]))
    \\  (form :name pass-core
    \\    (key :name name :type symbol :optional false))
    \\  (form :name present
    \\    (key :name pass :type pass-name :optional false)))
    \\
    \\(texture :name offscreen)
    \\(pass :name main (attach :to offscreen))
    \\(present :pass main)
    \\
;

// ---------------------------------------------------------------------------
// Printing helpers.
// ---------------------------------------------------------------------------

fn printTree(gpa: Allocator, label: []const u8, tree: Ast.Tree) !void {
    const text = try sjon.Printer.print(gpa, tree, .{});
    defer text.deinit();
    std.debug.print("  {s}:\n", .{label});
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text.data, "\n"), '\n');
    while (lines.next()) |line| std.debug.print("    {s}\n", .{line});
}

fn printDiagnostics(r: *const Host.HostResult) void {
    std.debug.print("  diagnostics: {d}\n", .{r.diagnostics.len});
    for (r.diagnostics) |d| std.debug.print("    [{s}] {s}\n", .{ @tagName(d.code), d.message });
}

/// Eject, as a host would write it: the forms `stage` recorded as
/// emitted from `source_form_idx`, printed. A tree copy with a
/// substituted root list is the same view-narrowing the host uses to
/// validate one layer's terminals, so nothing but the roots slice is
/// allocated.
fn ejectedText(gpa: Allocator, stage: Host.LoweringStage, source_form_idx: Ast.NodeIndex) !Ast.Bytes {
    var roots: std.ArrayList(Ast.NodeIndex) = .empty;
    defer roots.deinit(gpa);
    for (stage.provenance.entries) |entry| {
        if (entry.source_form_idx == source_form_idx) try roots.append(gpa, entry.lowered_form_idx);
    }
    var view = stage.tree;
    view.root = roots.items;
    return sjon.Printer.print(gpa, view, .{});
}

pub fn main() !void {
    // An arena for the whole run: every result below owns its own arena
    // and is freed on `deinit`, and the demo's own scratch goes here.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(gpa);
    try registry.register(gpa, step_v1);
    try registry.register(gpa, bind_v1);
    const opts: Host.HostOptions = .{ .lowering_registry = &registry };

    // ----------------------------------------------------------------- Act 1
    std.debug.print("=== Act 1. resolveRef: a hook reads the form its key names ===\n\n", .{});
    {
        var r = try Host.validateDocument(gpa, act1_source, opts);
        defer r.deinit();
        printDiagnostics(&r);
        const lowered = r.lowered_tree orelse return error.NothingLowered;
        // `verts` wrote `:size 1024`; `params` did not, and 256 arrives
        // through the overlay. The hook read both the same way.
        try printTree(gpa, "lowered", lowered);
        std.debug.print("\n", .{});
    }

    // ----------------------------------------------------------------- Act 2
    std.debug.print("=== Act 2. Two layers, kept; a chain back to the author; eject ===\n\n", .{});
    {
        var r = try Host.validateDocument(gpa, act2_source, opts);
        defer r.deinit();
        printDiagnostics(&r);
        std.debug.print("  layers: {d}\n", .{r.lowering_stages.len});
        for (r.lowering_stages, 0..) |stage, i| {
            const label = try std.fmt.allocPrint(gpa, "layer {d}", .{i});
            try printTree(gpa, label, stage.tree);
        }

        // The chain, source-first: hop 0 is the authored form and the
        // hook that first rewrote it. Each hop carries both trees, so an
        // index is never read against the wrong one.
        const lowered = r.lowered_tree orelse return error.NothingLowered;
        var buf: [Lowering.MAX_LOWERING_STAGES]Host.Hop = undefined;
        const chain = r.provenanceChain(lowered.root[0], &buf);
        std.debug.print("  chain for the terminal `{s}`:\n", .{lowered.formHeader(lowered.root[0]).head});
        for (chain, 0..) |hop, i| {
            std.debug.print("    hop {d}: ({s} …) --[{s}]--> ({s} …)\n", .{
                i,
                hop.source_tree.formHeader(hop.source_form_idx).head,
                hop.hook_id,
                hop.lowered_tree.formHeader(hop.lowered_form_idx).head,
            });
        }

        // Eject. The verb is the authored `(paint …)`; what it wrote is
        // in layer 0. Reading the terminal layer instead prints the core
        // the sugar eventually becomes, which the verb never wrote.
        const verb = r.data_forest[0];
        const span = r.tree.spanOf(verb);
        const layer0 = try ejectedText(gpa, r.lowering_stages[0], verb);
        defer layer0.deinit();
        const terminal = try ejectedText(gpa, r.lowering_stages[1], r.lowering_stages[0].tree.root[0]);
        defer terminal.deinit();
        std.debug.print("  eject `{s}`\n", .{act2_source[span.start..span.end]});
        std.debug.print("    from layer 0 (right):     {s}", .{layer0.data});
        std.debug.print("    from the terminal (wrong): {s}\n", .{terminal.data});
    }

    // ----------------------------------------------------------------- Act 3
    std.debug.print("=== Act 3. A union-typed reference in a container's child ===\n\n", .{});
    {
        var r = try Host.validateDocument(gpa, act3_source, opts);
        defer r.deinit();
        // Clean, and `(present :pass main)` resolved against a form that
        // exists only because the hook ran. Before the fragment pass
        // deferred cross-reference identity, `offscreen` failed to match
        // inside the fragment, the union reported no branch matched, the
        // gate closed, the hook never ran, and this document reported
        // `not_cross_ref` at `[present pass]` with nothing naming the
        // real cause.
        printDiagnostics(&r);
        const lowered = r.lowered_tree orelse return error.NothingLowered;
        try printTree(gpa, "lowered", lowered);
    }
}
