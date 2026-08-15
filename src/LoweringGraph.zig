//! `lowering-graph` export: renders the aggregate `:lowering :produces`
//! DAG as SJON.
//!
//! The lowering pipeline is otherwise *implicit* — a reader has to chase
//! `:produces` edges across forms (and across plugins) to see how a
//! surface form fans out into terminal forms. This export makes the
//! derived graph printable, diffable, and testable: the same antidote to
//! "emergent pipeline" opacity that schema export and the binary trace
//! provide elsewhere.
//!
//! The graph is exactly the one `Schema.buildLoweringGraph` feeds the
//! static cycle check (`detectGraphCycles`), so what you export is what
//! gets validated — no second, drifting derivation. One `(node …)` per
//! form declaring `:lowering`; terminal forms that are only edge *targets*
//! (no `:lowering` of their own) appear inside `:produces` but get no node
//! of their own. Heads are canonical `<plugin>/<form>` strings, so the
//! output is unambiguous regardless of bare/qualified spelling at the
//! source. Node and edge order is the plugins-then-forms declaration
//! order `buildLoweringGraph` walks, so the rendering is deterministic.
//!
//! Heads are emitted as SJON strings rather than symbols: a canonical
//! head always carries a `/`, and a string sidesteps any question of how
//! `<ns>/<name>` parses in value position while still round-tripping.

const std = @import("std");
const Schema = @import("Schema.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{OutOfMemory};

/// Render the lowering produces-graph of `schema` as a `(lowering-graph
/// …)` SJON form. An aggregate with no lowering forms renders the empty
/// `(lowering-graph)`. Caller owns the returned bytes (allocated on
/// `gpa`).
pub fn render(gpa: Allocator, schema: Schema.Schema) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const nodes = try Schema.buildLoweringGraph(schema, arena_state.allocator());

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    if (nodes.len == 0) {
        try out.appendSlice(gpa, "(lowering-graph)\n");
        return out.toOwnedSlice(gpa);
    }

    try out.appendSlice(gpa, "(lowering-graph\n");
    for (nodes) |node| {
        try out.appendSlice(gpa, "  (node :form \"");
        try out.appendSlice(gpa, node.name);
        try out.appendSlice(gpa, "\" :produces [");
        for (node.edges, 0..) |edge, i| {
            if (i > 0) try out.append(gpa, ' ');
            try out.append(gpa, '"');
            try out.appendSlice(gpa, edge);
            try out.append(gpa, '"');
        }
        try out.appendSlice(gpa, "])\n");
    }
    try out.appendSlice(gpa, ")\n");
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;
const Plugin = @import("Plugin.zig");
const Parser = @import("Parser.zig");

test "render: an aggregate with no lowering forms renders the empty graph" {
    const p: Plugin.Plugin = .{ .name = "plain", .forms = &.{ .{ .name = "scene" }, .{ .name = "shape" } } };
    const schema = Schema.Schema.init(&.{p});
    const sjon = try render(testing.allocator, schema);
    defer testing.allocator.free(sjon);
    try testing.expectEqualStrings("(lowering-graph)\n", sjon);
}

test "render: one node per lowering form, edges canonicalized, output round-trips" {
    // `front/seed` produces a bare `row` (resolves cross-plugin to
    // `back/row`); `back/row` is terminal so it appears as an edge target
    // but gets no node of its own. The render must canonicalize the bare
    // head and parse back as valid SJON.
    const front: Plugin.Plugin = .{
        .name = "front",
        .forms = &.{
            .{ .name = "seed", .lowering = .{ .hook = "front/seed-v1", .produces = &.{"row"} } },
        },
    };
    const back: Plugin.Plugin = .{ .name = "back", .forms = &.{.{ .name = "row" }} };
    const schema = Schema.Schema.init(&.{ front, back });

    const sjon = try render(testing.allocator, schema);
    defer testing.allocator.free(sjon);

    try testing.expectEqualStrings(
        \\(lowering-graph
        \\  (node :form "front/seed" :produces ["back/row"])
        \\)
        \\
    , sjon);

    // The rendered graph is itself valid SJON.
    const src = try testing.allocator.allocSentinel(u8, sjon.len, 0);
    defer testing.allocator.free(src);
    @memcpy(src, sjon);
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
}
