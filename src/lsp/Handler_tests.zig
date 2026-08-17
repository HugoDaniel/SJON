//! Internal tests for `Handler.zig` (SJON-aware LSP core).
//!
//! Extracted from `Handler.zig` to keep the production file at a
//! reviewable size. Test discovery: `Handler.zig` ends with
//! `test { _ = @import("Handler_tests.zig"); }`, so these run
//! transparently under the existing `zig build test` `lsp-handler`
//! step (which targets `Handler.zig`).
//!
//! Tests access `Handler` only through its public surface — every
//! symbol reached here is `pub` in `Handler.zig`. Local `const`
//! aliases at the top re-spell those symbols unqualified to keep
//! test bodies readable.

const std = @import("std");
const build_options = @import("build_options");
const sjon = @import("sjon");
const Handler = @import("Handler.zig");

const CompletionItem = Handler.CompletionItem;

/// Find the completion item with `label`. Asserts presence — tests fail
/// loudly when the schema setup didn't surface the expected form.
fn findCompletion(items: []const CompletionItem, label: []const u8) CompletionItem {
    for (items) |it| {
        if (std.mem.eql(u8, it.label, label)) return it;
    }
    std.debug.panic("no completion item labelled '{s}' in {d} items", .{ label, items.len });
}

/// Find the workspace report for `uri`. Asserts presence — the reports
/// are unordered with respect to the test's expectations, and a missing
/// URI is a failure worth naming rather than an index out of bounds.
fn reportFor(reports: []const Handler.WorkspaceReport, uri: []const u8) Handler.WorkspaceReport {
    for (reports) |r| {
        if (std.mem.eql(u8, r.uri, uri)) return r;
    }
    std.debug.panic("no workspace report for '{s}' in {d} reports", .{ uri, reports.len });
}

/// Build a phrase/track schema for cross-ref tests. Same shape as the
/// `cross-doc:` test below but extracted so multiple tests can reuse it.
fn audioSchemaPlugin() sjon.Plugin.Plugin {
    const phrase_name_kind: sjon.Plugin.ValueKind = .{
        .name = "phrase-name",
        .underlying = .symbol,
        .cross_ref = .{ .targets = &.{"phrase"} },
    };
    const phrase_seq_kind: sjon.Plugin.ValueKind = .{
        .name = "phrase-sequence",
        .underlying = .vector,
        .vector = .{ .element = .{ .name = "phrase-name" } },
    };
    return .{
        .name = "audio",
        .value_kinds = &.{ phrase_name_kind, phrase_seq_kind },
        .forms = &.{
            .{
                .name = "phrase",
                .keys = &.{
                    .{ .name = "name", .value_type = .symbol, .optional = false },
                },
            },
            .{
                .name = "track",
                .keys = &.{
                    .{ .name = "sequence", .value_type = .{ .named = .{ .name = "phrase-sequence" } }, .optional = false },
                },
            },
        },
    };
}

/// Schema where a kvpair value directly resolves to a cross-ref kind
/// (no intervening vector). Lets completion tests exercise the
/// `kvpair_value → kind.cross_ref` path without the vector-element
/// indirection used in the conformance fixtures.
fn crossRefDirectPlugin() sjon.Plugin.Plugin {
    const phrase_name_kind: sjon.Plugin.ValueKind = .{
        .name = "phrase-name",
        .underlying = .symbol,
        .cross_ref = .{ .targets = &.{"phrase"} },
    };
    return .{
        .name = "audio",
        .value_kinds = &.{phrase_name_kind},
        .forms = &.{
            .{
                .name = "phrase",
                .keys = &.{
                    .{ .name = "name", .value_type = .symbol, .optional = false },
                    .{ .name = "related", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = true },
                },
            },
            .{
                .name = "jump",
                .keys = &.{
                    .{ .name = "target", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = false },
                },
            },
        },
    };
}

/// A handler paired with a per-call result arena — the lifecycle preamble
/// the ~140 arena-using Handler tests share. Bundles both `defer`s into one
/// `fx.deinit()` (arena first, then handler — the same LIFO order the
/// hand-written pair produced). Bind `var fx = handlerFixture(a);`, then
/// `const h = &fx.h;` / `const arena = fx.arena();` so test bodies keep
/// reading against `h` / `arena` unchanged. `openDocument` stays in the test
/// body — its position (and the doc's uri/version/src) vary per test.
const Fixture = struct {
    h: Handler,
    arena_state: std.heap.ArenaAllocator,

    /// The per-call result allocator. Valid for the fixture's lifetime;
    /// callers pass it to `getHover` / `getDiagnostics` / … .
    fn arena(self: *Fixture) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn deinit(self: *Fixture) void {
        self.arena_state.deinit();
        self.h.deinit();
    }
};

/// Build a `Fixture` — a fresh `Handler` plus an unused-until-`arena()`
/// result arena, both owned by the returned value. Infallible: mirrors the
/// tests' `Handler.init(a)` + `ArenaAllocator.init(a)`, neither of which can
/// fail. The arena hands out no interface until `fx.arena()`, so returning
/// the struct by value is move-safe.
fn handlerFixture(a: std.mem.Allocator) Fixture {
    return .{ .h = Handler.init(a), .arena_state = .init(a) };
}

test "open / diagnostics / close round-trip on a clean document" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();

    try h.openDocument("file:///a.sjon", 1, "(+ 1 2)");
    var arena_state: std.heap.ArenaAllocator = .init(a);
    defer arena_state.deinit();
    const diags = (try h.getDiagnostics(arena_state.allocator(), "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 0), diags.len);

    h.closeDocument("file:///a.sjon");
    try std.testing.expect(h.getDocument("file:///a.sjon") == null);
}

test "closeDocument: a failed forest rebuild leaves no stale cross-ref keys" {
    const a = std.testing.allocator;

    // `tree_uris` is allocated inside `cross_ref_arena`, and
    // `uri_to_tree_idx`'s keys borrow from `tree_uris` — one lifetime unit.
    // `closeDocument` frees the arena and then *attempts* a rebuild whose
    // failure it deliberately swallows, so anything still in the map at that
    // point is a key into freed memory, and the next `get` probe compares
    // against those freed bytes.
    //
    // Sweep the fail index across the whole open+close sequence; every
    // iteration that lands inside the rebuild must leave the registry wholly
    // dropped, never half.
    var saw_failed_rebuild = false;
    var fail_index: usize = 0;
    while (fail_index < 512) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(a, .{ .fail_index = fail_index });
        var h = Handler.init(failing.allocator());
        defer h.deinit();

        h.openDocument("file:///a.sjon", 1, "(+ 1 2)") catch continue;
        h.openDocument("file:///b.sjon", 1, "(+ 3 4)") catch continue;
        if (h.cross_ref_index == null) continue; // the trip landed in setup

        h.closeDocument("file:///a.sjon");

        if (h.cross_ref_index == null) {
            saw_failed_rebuild = true;
            try std.testing.expectEqual(@as(u32, 0), h.uri_to_tree_idx.count());
            try std.testing.expectEqual(@as(usize, 0), h.tree_uris.len);
        }
    }
    // The sweep is only meaningful if it actually reached the swallowed path.
    try std.testing.expect(saw_failed_rebuild);
}

test "hover on data-form head shows FormSpec" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `let` is registered by `core` as an expr func, but we need a data
    // form to test FormSpec. Use the schema's known data-form by checking
    // any plugin form. The core plugin only has expr_funcs, so this test
    // verifies the expr-func path on `+`.
    const src = "(+ 1 2)";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    // Cursor on the `+` (byte 1).
    const hov = (try h.getHover(arena, "file:///a.sjon", 1)).?;
    try std.testing.expect(std.mem.indexOf(u8, hov.contents, "expression") != null);
    try std.testing.expect(std.mem.indexOf(u8, hov.contents, "core") != null);
    try std.testing.expectEqual(@as(u32, 1), hov.span_start);
    try std.testing.expectEqual(@as(u32, 2), hov.span_end);
}

test "hover on unknown head returns null" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try h.openDocument("file:///a.sjon", 1, "(wibble)");

    const arena = fx.arena();

    const hov = try h.getHover(arena, "file:///a.sjon", 1);
    try std.testing.expect(hov == null);
}

test "hover outside any node returns null" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try h.openDocument("file:///a.sjon", 1, "(+ 1 2)\n");

    const arena = fx.arena();

    // Byte 8 is the trailing newline — past every node's span.
    const hov = try h.getHover(arena, "file:///a.sjon", 8);
    try std.testing.expect(hov == null);
}

test "hover on form-internal whitespace falls back to enclosing form" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // Bytes:  0:`(`  1:`+`  2:` `  3:`1`  4:` `  5:`2`  6:`)`.
    try h.openDocument("file:///a.sjon", 1, "(+ 1 2)");

    const arena = fx.arena();

    // Byte 2 is the whitespace after the head — inside the form but
    // outside any child. Should still show the form's hover.
    const hov = (try h.getHover(arena, "file:///a.sjon", 2)).?;
    try std.testing.expect(std.mem.indexOf(u8, hov.contents, "core") != null);
}

test "completion after `(` lists core expression heads" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try h.openDocument("file:///a.sjon", 1, "(");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 1)).?;
    try std.testing.expect(items.len > 0);

    var saw_plus = false;
    for (items) |item| {
        if (std.mem.eql(u8, item.label, "+")) saw_plus = true;
    }
    try std.testing.expect(saw_plus);
}

/// Schema with both a data form (`widget`) and an expr-func (`emit`) in
/// the same plugin so vocabulary-narrowing tests can verify which kind
/// is filtered. Pairs with `sjon.plugins.core.plugin` for `+` etc.
fn mixedVocabPlugin() sjon.Plugin.Plugin {
    return .{
        .name = "mix",
        .forms = &.{
            .{ .name = "widget", .keys = &.{} },
            .{ .name = "panel", .keys = &.{} },
        },
        .expr_funcs = &.{
            .{ .name = "emit", .arity = .{ .at_least = 0 } },
        },
    };
}

test "form-head narrowing: expr-func parent emits only expr-funcs" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = mixedVocabPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // (emit (here|)). Cursor at byte 7 — right after the inner `(`.
    //  0     6 7
    try h.openDocument("file:///a.sjon", 1, "(emit ()");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 7)).?;
    for (items) |it| {
        try std.testing.expect(!std.mem.eql(u8, it.label, "widget"));
        try std.testing.expect(!std.mem.eql(u8, it.label, "panel"));
    }
    // Both `emit` (mix) and `+` (core) should be present.
    var saw_emit = false;
    var saw_plus = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "emit")) saw_emit = true;
        if (std.mem.eql(u8, it.label, "+")) saw_plus = true;
    }
    try std.testing.expect(saw_emit);
    try std.testing.expect(saw_plus);
}

test "form-head narrowing: kvpair value_type .expr narrows to expr-funcs" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    // `rule` has `:cond` declared as `.expr`, `:body` as `.form`, `:val` as `.any`.
    const rule_form: sjon.Plugin.FormSpec = .{
        .name = "rule",
        .keys = &.{
            .{ .name = "cond", .value_type = .expr },
            .{ .name = "body", .value_type = .form },
            .{ .name = "val", .value_type = .any },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{
        .name = "host",
        .forms = &.{ rule_form, .{ .name = "widget", .keys = &.{} } },
    };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // (rule :cond ())
    //  0    56    11 14
    try h.openDocument("file:///a.sjon", 1, "(rule :cond ())");
    const arena = fx.arena();
    const items = (try h.getCompletion(arena, "file:///a.sjon", 13)).?;
    for (items) |it| {
        try std.testing.expect(!std.mem.eql(u8, it.label, "widget"));
        try std.testing.expect(!std.mem.eql(u8, it.label, "rule"));
    }
    var saw_plus = false;
    for (items) |it| if (std.mem.eql(u8, it.label, "+")) {
        saw_plus = true;
    };
    try std.testing.expect(saw_plus);
}

test "form-head narrowing: kvpair value_type .form narrows to data forms" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const rule_form: sjon.Plugin.FormSpec = .{
        .name = "rule",
        .keys = &.{.{ .name = "body", .value_type = .form }},
    };
    const plugin: sjon.Plugin.Plugin = .{
        .name = "host",
        .forms = &.{ rule_form, .{ .name = "widget", .keys = &.{} } },
    };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // (rule :body ())
    //  0    56    11 14
    // Close the inner paren so the parser materialises the inner form
    // node — without it, parent_form_idx is null and narrowing falls
    // through to .any.
    try h.openDocument("file:///a.sjon", 1, "(rule :body ())");
    const arena = fx.arena();
    const items = (try h.getCompletion(arena, "file:///a.sjon", 13)).?;
    var saw_widget = false;
    for (items) |it| {
        // No expr-funcs (core's `+`, host's none) should appear.
        try std.testing.expect(!std.mem.eql(u8, it.label, "+"));
        if (std.mem.eql(u8, it.label, "widget")) saw_widget = true;
    }
    try std.testing.expect(saw_widget);
}

test "form-head narrowing: kvpair value_type .any keeps both vocabularies" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const rule_form: sjon.Plugin.FormSpec = .{
        .name = "rule",
        .keys = &.{.{ .name = "val", .value_type = .any }},
    };
    const plugin: sjon.Plugin.Plugin = .{
        .name = "host",
        .forms = &.{ rule_form, .{ .name = "widget", .keys = &.{} } },
    };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // (rule :val ())
    try h.openDocument("file:///a.sjon", 1, "(rule :val ())");
    const arena = fx.arena();
    const items = (try h.getCompletion(arena, "file:///a.sjon", 12)).?;
    var saw_widget = false;
    var saw_plus = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "widget")) saw_widget = true;
        if (std.mem.eql(u8, it.label, "+")) saw_plus = true;
    }
    try std.testing.expect(saw_widget);
    try std.testing.expect(saw_plus);
}

test "form-head narrowing: kvpair precedence beats outer expr-func parent" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    // Outer `if` is an expr-func; inner `rule :cond …` slot is `.expr` —
    // both paths say `.expr` here, but the kvpair path wins and we
    // confirm narrowing remains correct under nesting.
    const rule_form: sjon.Plugin.FormSpec = .{
        .name = "rule",
        .keys = &.{.{ .name = "cond", .value_type = .expr }},
    };
    const plugin: sjon.Plugin.Plugin = .{
        .name = "host",
        .forms = &.{ rule_form, .{ .name = "widget", .keys = &.{} } },
        .expr_funcs = &.{
            .{ .name = "if", .arity = .{ .at_least = 0 } },
        },
    };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // (if (rule :cond ()))
    //  0   4    10    16 19
    try h.openDocument("file:///a.sjon", 1, "(if (rule :cond ()))");
    const arena = fx.arena();
    const items = (try h.getCompletion(arena, "file:///a.sjon", 17)).?;
    for (items) |it| {
        try std.testing.expect(!std.mem.eql(u8, it.label, "widget"));
        try std.testing.expect(!std.mem.eql(u8, it.label, "rule"));
    }
}

test "form-head narrowing: unknown parent head falls through to .any" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = mixedVocabPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // (unknown-head ())
    //  0            13 16
    try h.openDocument("file:///a.sjon", 1, "(unknown-head ())");
    const arena = fx.arena();
    const items = (try h.getCompletion(arena, "file:///a.sjon", 15)).?;
    var saw_widget = false;
    var saw_emit = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "widget")) saw_widget = true;
        if (std.mem.eql(u8, it.label, "emit")) saw_emit = true;
    }
    try std.testing.expect(saw_widget);
    try std.testing.expect(saw_emit);
}

test "form-head narrowing: ambiguous parent head falls through to .any" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    // Two plugins both declare `widget`. Bare `(widget …)` lookup → ambiguous.
    const a_plugin: sjon.Plugin.Plugin = .{
        .name = "a",
        .forms = &.{.{ .name = "widget", .keys = &.{} }},
    };
    const b_plugin: sjon.Plugin.Plugin = .{
        .name = "b",
        .forms = &.{.{ .name = "widget", .keys = &.{} }},
    };
    h.schema = .init(&.{ a_plugin, b_plugin, sjon.plugins.core.plugin });

    // (widget ())
    try h.openDocument("file:///a.sjon", 1, "(widget ())");
    const arena = fx.arena();
    const items = (try h.getCompletion(arena, "file:///a.sjon", 9)).?;
    // Both vocabularies should remain (data `widget` AND expr `+`).
    var saw_widget = false;
    var saw_plus = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "widget")) saw_widget = true;
        if (std.mem.eql(u8, it.label, "+")) saw_plus = true;
    }
    try std.testing.expect(saw_widget);
    try std.testing.expect(saw_plus);
}

test "form-head narrowing: empty schema produces no candidates without crashing" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{});
    try h.openDocument("file:///a.sjon", 1, "(");
    const arena = fx.arena();
    const items = (try h.getCompletion(arena, "file:///a.sjon", 1)).?;
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

/// Schema with a typed expr-func `add2` (params=.number,.number,
/// result=.number) and a handful of candidates with various result
/// types — exercises result-type narrowing of form-head completions
/// inside an expr-func arg.
fn typedExprFuncPlugin() sjon.Plugin.Plugin {
    return .{
        .name = "math",
        .expr_funcs = &.{
            .{
                .name = "add2",
                .arity = .{ .fixed = 2 },
                .params = &.{ .number, .number },
                .result = .number,
            },
            .{
                .name = "addn",
                .arity = .{ .at_least = 1 },
                .params = &.{.number},
                .rest = .number,
                .result = .number,
            },
            .{ .name = "n-cand", .arity = .{ .at_least = 0 }, .result = .number },
            .{ .name = "b-cand", .arity = .{ .at_least = 0 }, .result = .boolean },
            .{ .name = "opaque-cand", .arity = .{ .at_least = 0 } },
        },
    };
}

test "form-head narrowing: result-type filters by mono params" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{typedExprFuncPlugin()});

    // (add2 ())
    //  0    6 8
    try h.openDocument("file:///a.sjon", 1, "(add2 ())");
    const arena = fx.arena();
    const items = (try h.getCompletion(arena, "file:///a.sjon", 7)).?;
    var saw_n = false;
    var saw_b = false;
    var saw_opaque = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "n-cand")) saw_n = true;
        if (std.mem.eql(u8, it.label, "b-cand")) saw_b = true;
        if (std.mem.eql(u8, it.label, "opaque-cand")) saw_opaque = true;
    }
    try std.testing.expect(saw_n);
    try std.testing.expect(saw_opaque);
    try std.testing.expect(!saw_b);
}

test "form-head narrowing: result-type uses rest type past fixed params" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{typedExprFuncPlugin()});

    // (addn 1 2 ()) — cursor inside the third positional, past the one
    // fixed `params` slot, so the `rest = .number` type applies.
    //  0    6 8 10 13
    try h.openDocument("file:///a.sjon", 1, "(addn 1 2 ())");
    const arena = fx.arena();
    const items = (try h.getCompletion(arena, "file:///a.sjon", 11)).?;
    var saw_n = false;
    var saw_b = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "n-cand")) saw_n = true;
        if (std.mem.eql(u8, it.label, "b-cand")) saw_b = true;
    }
    try std.testing.expect(saw_n);
    try std.testing.expect(!saw_b);
}

test "form-head narrowing: opaque parent applies no result-type filter" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    // Parent `opaque-parent` has no `params`/`signatures` → opaque.
    // Candidates of all result types should appear.
    const plugin: sjon.Plugin.Plugin = .{
        .name = "math",
        .expr_funcs = &.{
            .{ .name = "opaque-parent", .arity = .{ .at_least = 0 } },
            .{ .name = "n-cand", .arity = .{ .at_least = 0 }, .result = .number },
            .{ .name = "b-cand", .arity = .{ .at_least = 0 }, .result = .boolean },
        },
    };
    h.schema = .init(&.{plugin});

    // (opaque-parent ())
    try h.openDocument("file:///a.sjon", 1, "(opaque-parent ())");
    const arena = fx.arena();
    const items = (try h.getCompletion(arena, "file:///a.sjon", 16)).?;
    var saw_n = false;
    var saw_b = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "n-cand")) saw_n = true;
        if (std.mem.eql(u8, it.label, "b-cand")) saw_b = true;
    }
    try std.testing.expect(saw_n);
    try std.testing.expect(saw_b);
}

test "form-head narrowing: overloaded candidate with matching sig is included" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    // Parent expects .number at arg 0. Candidate `poly` has two sigs:
    // one returns .number, one returns .string. Should be included.
    const plugin: sjon.Plugin.Plugin = .{
        .name = "math",
        .expr_funcs = &.{
            .{
                .name = "p",
                .arity = .{ .fixed = 1 },
                .params = &.{.number},
                .result = .number,
            },
            .{
                .name = "poly",
                .signatures = &.{
                    .{ .arity = .{ .at_least = 0 }, .result = .number },
                    .{ .arity = .{ .at_least = 0 }, .result = .string },
                },
            },
            .{
                .name = "poly-no-num",
                .signatures = &.{
                    .{ .arity = .{ .at_least = 0 }, .result = .string },
                    .{ .arity = .{ .at_least = 0 }, .result = .boolean },
                },
            },
            .{
                .name = "poly-opaque",
                .signatures = &.{
                    .{ .arity = .{ .at_least = 0 } },
                    .{ .arity = .{ .at_least = 0 }, .result = .boolean },
                },
            },
        },
    };
    h.schema = .init(&.{plugin});

    // (p ())
    try h.openDocument("file:///a.sjon", 1, "(p ())");
    const arena = fx.arena();
    const items = (try h.getCompletion(arena, "file:///a.sjon", 4)).?;
    var saw_poly = false;
    var saw_poly_no_num = false;
    var saw_poly_opaque = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "poly")) saw_poly = true;
        if (std.mem.eql(u8, it.label, "poly-no-num")) saw_poly_no_num = true;
        if (std.mem.eql(u8, it.label, "poly-opaque")) saw_poly_opaque = true;
    }
    try std.testing.expect(saw_poly);
    try std.testing.expect(saw_poly_opaque);
    try std.testing.expect(!saw_poly_no_num);
}

// ---------------------------------------------------------------------------
// .expr_arg position — argument slot completions
// ---------------------------------------------------------------------------

test "resolveContextAt: (+ 1 |) classifies cursor as .expr_arg" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    // (+ 1 )
    //  0 23 5
    try h.openDocument("file:///a.sjon", 1, "(+ 1 )");
    const doc = h.getDocument("file:///a.sjon").?;
    const ctx = Handler.resolveContextAt(&doc.tree, doc.source, 5);
    try std.testing.expectEqual(Handler.ResolvedContext.Position.expr_arg, ctx.position);
    try std.testing.expect(ctx.enclosing_form_idx != null);
}

test "resolveContextAt: (+ |) classifies cursor as .expr_arg" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    // (+ )
    //  0 3
    try h.openDocument("file:///a.sjon", 1, "(+ )");
    const doc = h.getDocument("file:///a.sjon").?;
    const ctx = Handler.resolveContextAt(&doc.tree, doc.source, 3);
    try std.testing.expectEqual(Handler.ResolvedContext.Position.expr_arg, ctx.position);
}

test "resolveContextAt: cursor on head identifier does NOT classify as .expr_arg" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    // (foo 1) — cursor at byte 2, inside the `foo` head identifier.
    try h.openDocument("file:///a.sjon", 1, "(foo 1)");
    const doc = h.getDocument("file:///a.sjon").?;
    const ctx = Handler.resolveContextAt(&doc.tree, doc.source, 2);
    // Should NOT be .expr_arg — cursor sits inside the head span.
    try std.testing.expect(ctx.position != Handler.ResolvedContext.Position.expr_arg);
}

test "expr-arg completion: typed expr-func surfaces number literal + matching candidates" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{typedExprFuncPlugin()});

    // (add2 )
    //  0    6
    try h.openDocument("file:///a.sjon", 1, "(add2 )");
    const arena = fx.arena();
    const items = (try h.getCompletion(arena, "file:///a.sjon", 6)).?;
    var saw_zero = false;
    var saw_true = false;
    var saw_false = false;
    var saw_n = false;
    var saw_b = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "0")) saw_zero = true;
        if (std.mem.eql(u8, it.label, "true")) saw_true = true;
        if (std.mem.eql(u8, it.label, "false")) saw_false = true;
        if (std.mem.eql(u8, it.label, "n-cand")) saw_n = true;
        if (std.mem.eql(u8, it.label, "b-cand")) saw_b = true;
    }
    try std.testing.expect(saw_zero);
    try std.testing.expect(saw_n);
    try std.testing.expect(!saw_true);
    try std.testing.expect(!saw_false);
    try std.testing.expect(!saw_b);
}

test "expr-arg completion: opaque expr-func includes all candidates, no literals" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    // `opaque-parent` has no `params`/`signatures` — expected is null,
    // so no literal placeholders are emitted and every expr-func passes.
    const plugin: sjon.Plugin.Plugin = .{
        .name = "math",
        .expr_funcs = &.{
            .{ .name = "opaque-parent", .arity = .{ .at_least = 0 } },
            .{ .name = "n-cand", .arity = .{ .at_least = 0 }, .result = .number },
            .{ .name = "b-cand", .arity = .{ .at_least = 0 }, .result = .boolean },
        },
    };
    h.schema = .init(&.{plugin});

    // (opaque-parent )
    //  0             14
    try h.openDocument("file:///a.sjon", 1, "(opaque-parent )");
    const arena = fx.arena();
    const items = (try h.getCompletion(arena, "file:///a.sjon", 15)).?;
    var saw_zero = false;
    var saw_n = false;
    var saw_b = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "0")) saw_zero = true;
        if (std.mem.eql(u8, it.label, "n-cand")) saw_n = true;
        if (std.mem.eql(u8, it.label, "b-cand")) saw_b = true;
    }
    try std.testing.expect(!saw_zero);
    try std.testing.expect(saw_n);
    try std.testing.expect(saw_b);
}

test "expr-arg completion: data-form parent returns null (no positional-arg list)" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin: sjon.Plugin.Plugin = .{
        .name = "host",
        .forms = &.{.{ .name = "rule", .keys = &.{} }},
        .expr_funcs = &.{},
    };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // (rule )
    //  0    5
    try h.openDocument("file:///a.sjon", 1, "(rule )");
    const arena = fx.arena();
    const items = try h.getCompletion(arena, "file:///a.sjon", 6);
    try std.testing.expect(items == null);
}

test "expr-arg snippet shape: opaque candidate is (name $1)" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin: sjon.Plugin.Plugin = .{
        .name = "math",
        .expr_funcs = &.{
            .{ .name = "opaque-parent", .arity = .{ .at_least = 0 } },
            .{ .name = "opaque-cand", .arity = .{ .at_least = 0 } },
        },
    };
    h.schema = .init(&.{plugin});

    try h.openDocument("file:///a.sjon", 1, "(opaque-parent )");
    const arena = fx.arena();
    const items = (try h.getCompletion(arena, "file:///a.sjon", 15)).?;
    const cand = findCompletion(items, "opaque-cand");
    try std.testing.expectEqualStrings("(opaque-cand $1)", cand.insert_text.?);
    try std.testing.expectEqual(Handler.CompletionItem.InsertTextFormat.snippet, cand.insert_text_format);
}

test "expr-arg snippet shape: typed candidate has one tab stop per param" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{typedExprFuncPlugin()});

    // (add2 )
    try h.openDocument("file:///a.sjon", 1, "(add2 )");
    const arena = fx.arena();
    const items = (try h.getCompletion(arena, "file:///a.sjon", 6)).?;
    const cand = findCompletion(items, "add2");
    try std.testing.expectEqualStrings("(add2 ${1:0} ${2:0})", cand.insert_text.?);
}

// ---------------------------------------------------------------------------
// EOF dead zone — parser recovery extends unclosed frames to source.len, so
// a cursor at EOF sits exactly on span.end and the exclusive-end containment
// used to report "no enclosing node" (no completions while typing at the end
// of the document, the most common live-edit position).
// ---------------------------------------------------------------------------

test "resolveContextAt: unclosed form at EOF classifies as .expr_arg" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    // `(+ 1 ` — no closing paren; cursor at EOF (byte 5 == source.len).
    try h.openDocument("file:///a.sjon", 1, "(+ 1 ");
    const doc = h.getDocument("file:///a.sjon").?;
    const ctx = Handler.resolveContextAt(&doc.tree, doc.source, 5);
    try std.testing.expectEqual(Handler.ResolvedContext.Position.expr_arg, ctx.position);
    try std.testing.expect(ctx.enclosing_form_idx != null);
}

test "resolveContextAt: EOF after a fully closed form stays .none" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    // `(+ 1 2)` — cursor at EOF sits after the `)`, outside the form.
    try h.openDocument("file:///a.sjon", 1, "(+ 1 2)");
    const doc = h.getDocument("file:///a.sjon").?;
    const ctx = Handler.resolveContextAt(&doc.tree, doc.source, 7);
    try std.testing.expectEqual(Handler.ResolvedContext.Position.none, ctx.position);
    try std.testing.expect(ctx.enclosing_form_idx == null);
}

test "resolveContextAt: closed inner form at EOF resolves to the unclosed outer" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    // `(add2 (n-cand)` — the final `)` closes the *inner* form only; the
    // cursor at EOF is outside `(n-cand)` but inside the unclosed `add2`.
    try h.openDocument("file:///a.sjon", 1, "(add2 (n-cand)");
    const doc = h.getDocument("file:///a.sjon").?;
    const ctx = Handler.resolveContextAt(&doc.tree, doc.source, 14);
    try std.testing.expectEqual(Handler.ResolvedContext.Position.expr_arg, ctx.position);
    const enc = ctx.enclosing_form_idx.?;
    try std.testing.expectEqual(@as(u32, 0), doc.tree.spanOf(enc).start);
}

test "resolveContextAt: unclosed vector at EOF classifies as .vector_elem" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    try h.openDocument("file:///a.sjon", 1, "[1 2");
    const doc = h.getDocument("file:///a.sjon").?;
    const ctx = Handler.resolveContextAt(&doc.tree, doc.source, 4);
    try std.testing.expectEqual(Handler.ResolvedContext.Position.vector_elem, ctx.position);
}

test "resolveContextAt: EOF after a closed top-level vector stays .none" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    try h.openDocument("file:///a.sjon", 1, "[1 2]");
    const doc = h.getDocument("file:///a.sjon").?;
    const ctx = Handler.resolveContextAt(&doc.tree, doc.source, 5);
    try std.testing.expectEqual(Handler.ResolvedContext.Position.none, ctx.position);
}

test "expr-arg completion: fires at EOF inside an unclosed form" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{typedExprFuncPlugin()});

    // `(add2 ` — same expectations as the closed-form arg-slot test:
    // number literal placeholder plus number-result candidates only.
    try h.openDocument("file:///a.sjon", 1, "(add2 ");
    const arena = fx.arena();
    const items = (try h.getCompletion(arena, "file:///a.sjon", 6)).?;
    var saw_zero = false;
    var saw_n = false;
    var saw_b = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "0")) saw_zero = true;
        if (std.mem.eql(u8, it.label, "n-cand")) saw_n = true;
        if (std.mem.eql(u8, it.label, "b-cand")) saw_b = true;
    }
    try std.testing.expect(saw_zero);
    try std.testing.expect(saw_n);
    try std.testing.expect(!saw_b);
}

test "completion at EOF after a fully closed form returns null" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{typedExprFuncPlugin()});

    try h.openDocument("file:///a.sjon", 1, "(add2 1 2)");
    const arena = fx.arena();
    const items = try h.getCompletion(arena, "file:///a.sjon", 10);
    try std.testing.expect(items == null);
}

test "signature help: fires at EOF inside an unclosed expr call" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{typedExprFuncPlugin()});

    // `(add2 1 ` — cursor at EOF (byte 8), second arg slot.
    try h.openDocument("file:///a.sjon", 1, "(add2 1 ");
    const arena = fx.arena();
    const help = (try h.getSignatureHelp(arena, "file:///a.sjon", 8)).?;
    try std.testing.expectEqual(@as(?u32, 1), help.active_parameter);
}

test "completion after `:` returns no keys when form is unknown" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `wibble` isn't a known form. Cursor right after `:` produces an
    // empty list (we don't know what keys to suggest).
    try h.openDocument("file:///a.sjon", 1, "(wibble :");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 9)).?;
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "completion outside any context returns null" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try h.openDocument("file:///a.sjon", 1, "(+ 1 2)\n");

    const arena = fx.arena();

    // Cursor at byte 8 — past the trailing newline, outside any form.
    const items = try h.getCompletion(arena, "file:///a.sjon", 8);
    try std.testing.expect(items == null);
}

test "completion in member-value position lists members with deprecated tag" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const kind: sjon.Plugin.ValueKind = .{
        .name = "status",
        .underlying = .symbol,
        .members = .{ .members = &.{
            .{ .name = "draft", .label = "Draft", .description = "Work in progress." },
            .{ .name = "published", .label = "Published" },
            .{ .name = "archived", .deprecated = true, .deprecation_message = "Use hidden." },
        } },
    };
    const form: sjon.Plugin.FormSpec = .{
        .name = "post",
        .keys = &.{.{ .name = "status", .value_type = .{ .named = .{ .name = "status" } }, .optional = false }},
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "blog", .forms = &.{form}, .value_kinds = &.{kind} };
    h.schema = .init(&.{plugin});

    // `(post :status )` — cursor right after the trailing space (offset 14)
    // and before the closing `)` so the form span unambiguously includes
    // the cursor.
    try h.openDocument("file:///a.sjon", 1, "(post :status )");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 14)).?;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("draft", items[0].label);
    try std.testing.expectEqualStrings("Draft", items[0].detail);
    try std.testing.expectEqualStrings("Work in progress.", items[0].documentation);
    try std.testing.expectEqual(@as(usize, 0), items[0].tags.len);
    try std.testing.expectEqualStrings("archived", items[2].label);
    try std.testing.expectEqual(@as(usize, 1), items[2].tags.len);
    try std.testing.expectEqual(CompletionItem.Tag.deprecated, items[2].tags[0]);
    try std.testing.expectEqual(CompletionItem.Kind.enum_member, items[0].kind);
}

test "hover on a string-bounded key shows the Constraints summary" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const kind: sjon.Plugin.ValueKind = .{
        .name = "slug",
        .underlying = .string,
        .string_bounds = .{ .min_len = 1, .max_len = 64, .format = .path },
    };
    const form: sjon.Plugin.FormSpec = .{
        .name = "post",
        .keys = &.{.{ .name = "id", .value_type = .{ .named = .{ .name = "slug" } }, .optional = false }},
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "blog", .forms = &.{form}, .value_kinds = &.{kind} };
    h.schema = .init(&.{plugin});

    // `(post :id "x")` — cursor on the `:id` key.
    //  0         1
    //  012345678901234
    try h.openDocument("file:///a.sjon", 1, "(post :id \"x\")");

    const arena = fx.arena();

    const hover = (try h.getHover(arena, "file:///a.sjon", 8)).?;
    try std.testing.expect(std.mem.indexOf(u8, hover.contents, "Constraints:") != null);
    try std.testing.expect(std.mem.indexOf(u8, hover.contents, "length 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, hover.contents, "64") != null);
    try std.testing.expect(std.mem.indexOf(u8, hover.contents, "`path`") != null);
}

/// Hover on the key of `(<form> :<key> …)` for a one-key form whose value
/// type is the named `kind`. The constraint-summary tests below differ only
/// in the refinement they hang on the kind, so everything else — form, key
/// name, document, cursor arithmetic — is shared here.
///
/// The plugin slice is built and consumed inside this call: `Schema.init`
/// borrows it, so the schema is installed on `h` before anything can go out
/// of scope. Returns the hover contents, which the arena owns.
fn constraintHover(
    h: *Handler,
    arena: std.mem.Allocator,
    kind: sjon.Plugin.ValueKind,
) ![]const u8 {
    const form: sjon.Plugin.FormSpec = .{
        .name = "widget",
        .keys = &.{.{ .name = "prop", .value_type = .{ .named = .{ .name = kind.name } } }},
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "ui", .forms = &.{form}, .value_kinds = &.{kind} };
    h.schema = .init(&.{plugin});

    // `(widget :prop 1)` — byte 9 is inside the `:prop` key span.
    //  0         1
    //  0123456789012345
    try h.openDocument("file:///a.sjon", 1, "(widget :prop 1)");
    const hover = (try h.getHover(arena, "file:///a.sjon", 9)).?;
    return hover.contents;
}

/// Assert every needle appears in `haystack`, reporting the whole hover on
/// failure — a bare `expect(indexOf(…) != null)` says only "false".
fn expectContainsAll(haystack: []const u8, needles: []const []const u8) !void {
    for (needles) |n| {
        if (std.mem.indexOf(u8, haystack, n) == null) {
            std.debug.print("missing '{s}' in hover:\n{s}\n", .{ n, haystack });
            return error.MissingSubstring;
        }
    }
}

test "key hover renders numeric bounds" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();

    const contents = try constraintHover(&fx.h, fx.arena(), .{
        .name = "gain",
        .underlying = .number,
        .numeric = .{
            .min = .{ .value = 0 },
            .max = .{ .value = 10, .unit = "db" },
            .exclusive_max = true,
            .integer = true,
        },
    });

    try expectContainsAll(contents, &.{ "Constraints:", "min 0", "max 10db", "exclusive", "integer" });
}

test "key hover renders vector shape" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();

    const exact = try constraintHover(&fx.h, fx.arena(), .{
        .name = "point3",
        .underlying = .vector,
        .vector = .{ .len = 3, .element = .{ .name = "number" } },
    });
    try expectContainsAll(exact, &.{ "Constraints:", "length 3", "number" });

    // A second handler: `constraintHover` installs one schema per call.
    var fx2 = handlerFixture(a);
    defer fx2.deinit();
    const ranged = try constraintHover(&fx2.h, fx2.arena(), .{
        .name = "path",
        .underlying = .vector,
        .vector = .{ .min_len = 2, .max_len = 4, .element = .{ .name = "point3" } },
    });
    try expectContainsAll(ranged, &.{ "length 2..4", "point3" });
}

test "key hover renders allowed units" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();

    const required = try constraintHover(&fx.h, fx.arena(), .{
        .name = "length",
        .underlying = .number,
        .unit = .{ .required = true, .allowed = &.{ "px", "em" } },
    });
    try expectContainsAll(required, &.{ "units: `px`, `em`", "unit required" });

    var fx2 = handlerFixture(a);
    defer fx2.deinit();
    const rejected = try constraintHover(&fx2.h, fx2.arena(), .{
        .name = "count",
        .underlying = .number,
        .unit = .{ .reject = true },
    });
    try expectContainsAll(rejected, &.{"unit rejected"});
}

test "key hover renders repr" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();

    const contents = try constraintHover(&fx.h, fx.arena(), .{
        .name = "coord",
        .underlying = .number,
        .repr = .f32,
    });

    try expectContainsAll(contents, &.{ "repr", "f32" });
}

test "key hover renders member set summary" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();

    const contents = try constraintHover(&fx.h, fx.arena(), .{
        .name = "projection",
        .underlying = .symbol,
        .members = .{ .members = &.{
            .{ .name = "ortho", .label = "Orthographic" },
            .{ .name = "perspective" },
        } },
    });

    try expectContainsAll(contents, &.{ "ortho", "Orthographic", "perspective" });
}

test "key hover still renders string bounds via the shared renderer" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();

    // The `pattern` branch the pre-existing string-bounds hover test
    // doesn't reach, plus members co-existing with bounds — the two
    // families the fold-in is most likely to drop.
    const contents = try constraintHover(&fx.h, fx.arena(), .{
        .name = "tag",
        .underlying = .string,
        .string_bounds = .{ .min_len = 2, .pattern = "^[a-z]+$" },
        .members = .{ .members = &.{.{ .name = "alpha" }} },
    });

    try expectContainsAll(contents, &.{ "length 2", "^[a-z]+$", "informational", "alpha" });
}

test "key hover renders union alternatives by name" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();

    const contents = try constraintHover(&fx.h, fx.arena(), .{
        .name = "fill",
        .underlying = .union_of,
        .union_of = .{ .alternatives = &.{
            .{ .name = "color" },
            .{ .name = "gradient", .namespace = "paint" },
        } },
    });

    try expectContainsAll(contents, &.{ "color", "paint/gradient" });
}

/// Hover on the key of `(widget :prop 1)` for a one-key form built from
/// `key` verbatim — the defaults tests vary the KeySpec (default,
/// optional) rather than the value-kind, so they can't share
/// `constraintHover`'s fixed key.
fn keySpecHover(
    h: *Handler,
    arena: std.mem.Allocator,
    key: sjon.Plugin.KeySpec,
) ![]const u8 {
    const form: sjon.Plugin.FormSpec = .{ .name = "widget", .keys = &.{key} };
    const plugin: sjon.Plugin.Plugin = .{ .name = "ui", .forms = &.{form} };
    h.schema = .init(&.{plugin});

    try h.openDocument("file:///a.sjon", 1, "(widget :prop 1)");
    const hover = (try h.getHover(arena, "file:///a.sjon", 9)).?;
    return hover.contents;
}

test "key hover shows literal default" {
    const a = std.testing.allocator;

    // One arm per literal `Default` variant, each with the SJON source
    // text it should render as. `number` collapses unit-bearing manifest
    // defaults to a bare value (ManifestLoader.parseDefault), so there is
    // no `4px` arm to test.
    const cases = [_]struct { d: sjon.Plugin.KeySpec.Default, want: []const u8 }{
        .{ .d = .{ .number = 4 }, .want = "4" },
        .{ .d = .{ .string = "hi" }, .want = "\"hi\"" },
        .{ .d = .{ .symbol = "ortho" }, .want = "ortho" },
        .{ .d = .{ .boolean = true }, .want = "true" },
        .{ .d = .nil, .want = "nil" },
        .{ .d = .{ .vector = &.{ .{ .number = 1 }, .{ .number = 2 } } }, .want = "[1 2]" },
    };

    for (cases) |c| {
        var fx = handlerFixture(a);
        defer fx.deinit();
        const contents = try keySpecHover(&fx.h, fx.arena(), .{
            .name = "prop",
            .default = c.d,
        });
        try expectContainsAll(contents, &.{ "default", c.want });
    }
}

test "key hover shows expression default as (head …)" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();

    const contents = try keySpecHover(&fx.h, fx.arena(), .{
        .name = "prop",
        .default = .{ .expression = .{
            .head = "scale",
            .namespace = "math",
            .arg_count = 2,
            .program = &.{},
        } },
    });
    try expectContainsAll(contents, &.{"(math/scale …)"});

    // A niladic expression has no arguments to elide.
    var fx2 = handlerFixture(a);
    defer fx2.deinit();
    const nilad = try keySpecHover(&fx2.h, fx2.arena(), .{
        .name = "prop",
        .default = .{ .expression = .{
            .head = "pi",
            .namespace = null,
            .arg_count = 0,
            .program = &.{},
        } },
    });
    try expectContainsAll(nilad, &.{"(pi)"});
}

test "key hover marks optional-via-default distinctly from optional" {
    const a = std.testing.allocator;

    var fx_plain = handlerFixture(a);
    defer fx_plain.deinit();
    const plain = try keySpecHover(&fx_plain.h, fx_plain.arena(), .{
        .name = "prop",
        .optional = true,
    });

    var fx_def = handlerFixture(a);
    defer fx_def.deinit();
    const defaulted = try keySpecHover(&fx_def.h, fx_def.arena(), .{
        .name = "prop",
        .optional = true,
        .default = .{ .number = 4 },
    });

    var fx_req = handlerFixture(a);
    defer fx_req.deinit();
    const required = try keySpecHover(&fx_req.h, fx_req.arena(), .{
        .name = "prop",
        .optional = false,
    });

    // Three distinguishable states: silent (plain optional), defaulted,
    // required. A defaulted key is never also marked required — that is
    // `effectiveOptional`'s whole point.
    try std.testing.expect(std.mem.indexOf(u8, plain, "default") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "required") == null);
    try expectContainsAll(defaulted, &.{"default"});
    try std.testing.expect(std.mem.indexOf(u8, defaulted, "required") == null);
    try expectContainsAll(required, &.{"required"});
}

/// Hover the `widget` head of `(widget :prop 1)` — byte 1 is inside the
/// head span. Used by the Keys-list parity tests below.
fn formHeadHover(
    h: *Handler,
    arena: std.mem.Allocator,
    plugin: sjon.Plugin.Plugin,
) ![]const u8 {
    h.schema = .init(&.{plugin});
    try h.openDocument("file:///a.sjon", 1, "(widget :prop 1)");
    const hover = (try h.getHover(arena, "file:///a.sjon", 1)).?;
    return hover.contents;
}

test "form-head hover Keys list carries the same constraint summaries" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();

    const kind: sjon.Plugin.ValueKind = .{
        .name = "gain",
        .underlying = .number,
        .numeric = .{ .min = .{ .value = 0 }, .max = .{ .value = 10 }, .integer = true },
    };
    const form: sjon.Plugin.FormSpec = .{
        .name = "widget",
        .keys = &.{.{ .name = "prop", .value_type = .{ .named = .{ .name = "gain" } } }},
    };
    const contents = try formHeadHover(&fx.h, fx.arena(), .{
        .name = "ui",
        .forms = &.{form},
        .value_kinds = &.{kind},
    });

    // Same facts the key hover renders — one renderer, no drift.
    try expectContainsAll(contents, &.{ "Keys:", ":prop", "min 0", "max 10", "integer" });
    // The bullet stays one line: no block header, no embedded newline
    // between the key name and its description.
    const bullet_start = std.mem.indexOf(u8, contents, "- `:prop`").?;
    const bullet_end = std.mem.indexOfScalarPos(u8, contents, bullet_start, '\n').?;
    const bullet = contents[bullet_start..bullet_end];
    try expectContainsAll(bullet, &.{ "min 0", "integer" });
}

test "form-head hover Keys list shows defaults" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();

    const form: sjon.Plugin.FormSpec = .{
        .name = "widget",
        .keys = &.{
            .{ .name = "prop", .default = .{ .number = 4 } },
            .{ .name = "other", .optional = false },
        },
    };
    const contents = try formHeadHover(&fx.h, fx.arena(), .{ .name = "ui", .forms = &.{form} });

    try expectContainsAll(contents, &.{ ":prop", "default", "4", ":other", "required" });
}

/// Install a one-expr-func schema, open `(f 1 2)`, and hover the head.
fn exprHover(
    h: *Handler,
    arena: std.mem.Allocator,
    func: sjon.Plugin.ExprFunc,
) ![]const u8 {
    const plugin: sjon.Plugin.Plugin = .{ .name = "m", .expr_funcs = &.{func} };
    h.schema = .init(&.{plugin});
    try h.openDocument("file:///a.sjon", 1, "(f 1 2)");
    const hover = (try h.getHover(arena, "file:///a.sjon", 1)).?;
    return hover.contents;
}

test "expr-func hover shows declared result type" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();

    const contents = try exprHover(&fx.h, fx.arena(), .{
        .name = "f",
        .arity = .{ .fixed = 2 },
        .params = &.{ .number, .number },
        .result = .number,
    });

    try expectContainsAll(contents, &.{"→ `number`"});
}

test "expr-func hover omits arrow when no result is declared" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();

    const contents = try exprHover(&fx.h, fx.arena(), .{
        .name = "f",
        .arity = .{ .fixed = 2 },
        .params = &.{ .number, .number },
    });

    if (std.mem.indexOf(u8, contents, "→") != null) {
        std.debug.print("unexpected arrow in hover:\n{s}\n", .{contents});
        return error.UnexpectedArrow;
    }
}

/// An overload set whose two signatures differ in both arity and result,
/// so a cursor's argument count alone picks one.
fn arityOverloadedFunc() sjon.Plugin.ExprFunc {
    return .{
        .name = "f",
        .signatures = &.{
            .{ .arity = .{ .fixed = 1 }, .params = &.{.number}, .result = .number },
            .{ .arity = .{ .fixed = 2 }, .params = &.{ .number, .number }, .result = .string },
        },
    };
}

test "signature help renders per-overload result types" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const plugin: sjon.Plugin.Plugin = .{ .name = "m", .expr_funcs = &.{arityOverloadedFunc()} };
    h.schema = .init(&.{plugin});

    // `(f 1 2)` — two args, so the arity-2 overload is active.
    //  0123456
    try h.openDocument("file:///a.sjon", 1, "(f 1 2)");
    const help = (try h.getSignatureHelp(fx.arena(), "file:///a.sjon", 5)).?;

    try std.testing.expectEqual(@as(usize, 2), help.signatures.len);
    try expectContainsAll(help.signatures[0].label, &.{"→ `number`"});
    try expectContainsAll(help.signatures[1].label, &.{"→ `string`"});
    try std.testing.expectEqual(@as(u32, 1), help.active_signature);
}

test "signature help picks the overload matching the cursor's arity" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const plugin: sjon.Plugin.Plugin = .{ .name = "m", .expr_funcs = &.{arityOverloadedFunc()} };
    h.schema = .init(&.{plugin});

    // One arg — the arity-1 overload wins. Asserting the set size too:
    // `active_signature == 0` is also what a single-signature result
    // reports, so without this the test would pass on a handler that
    // never learned about overloads at all.
    try h.openDocument("file:///a.sjon", 1, "(f 1)");
    const help = (try h.getSignatureHelp(fx.arena(), "file:///a.sjon", 3)).?;
    try std.testing.expectEqual(@as(usize, 2), help.signatures.len);
    try std.testing.expectEqual(@as(u32, 0), help.active_signature);
}

test "signature help renders labeled-call result when labels narrow the overload" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // Both overloads take two arguments, so only the labels can tell
    // them apart — the case arity-narrowing alone cannot resolve.
    const func: sjon.Plugin.ExprFunc = .{
        .name = "f",
        .signatures = &.{
            .{
                .arity = .{ .fixed = 2 },
                .params = &.{ .number, .number },
                .param_names = &.{ "a", "b" },
                .result = .number,
            },
            .{
                .arity = .{ .fixed = 2 },
                .params = &.{ .number, .number },
                .param_names = &.{ "x", "y" },
                .result = .string,
            },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "m", .expr_funcs = &.{func} };
    h.schema = .init(&.{plugin});

    // `(f :x 1 :y 2)` — the `:x`/`:y` labels belong to the second
    // overload only.
    //  0         1
    //  0123456789012
    try h.openDocument("file:///a.sjon", 1, "(f :x 1 :y 2)");
    const help = (try h.getSignatureHelp(fx.arena(), "file:///a.sjon", 6)).?;

    try std.testing.expectEqual(@as(u32, 1), help.active_signature);
    try expectContainsAll(help.signatures[1].label, &.{"→ `string`"});
}

test "hover on a deprecated member value surfaces the deprecation message" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const kind: sjon.Plugin.ValueKind = .{
        .name = "status",
        .underlying = .symbol,
        .members = .{ .members = &.{
            .{ .name = "draft" },
            .{ .name = "archived", .label = "Archived", .deprecated = true, .deprecation_message = "Use hidden." },
        } },
    };
    const form: sjon.Plugin.FormSpec = .{
        .name = "post",
        .keys = &.{.{ .name = "status", .value_type = .{ .named = .{ .name = "status" } }, .optional = false }},
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "blog", .forms = &.{form}, .value_kinds = &.{kind} };
    h.schema = .init(&.{plugin});

    // `(post :status archived)` — cursor in the middle of `archived` (offset 16).
    //  0         1
    //  0123456789012345
    try h.openDocument("file:///a.sjon", 1, "(post :status archived)");

    const arena = fx.arena();

    const hover = (try h.getHover(arena, "file:///a.sjon", 16)).?;
    try std.testing.expect(std.mem.indexOf(u8, hover.contents, "archived") != null);
    try std.testing.expect(std.mem.indexOf(u8, hover.contents, "Archived") != null);
    try std.testing.expect(std.mem.indexOf(u8, hover.contents, "Deprecated") != null);
    try std.testing.expect(std.mem.indexOf(u8, hover.contents, "Use hidden.") != null);
}

test "signature help for a form lists every key with active = current kvpair" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const widget: sjon.Plugin.FormSpec = .{
        .name = "widget",
        .description = "make a widget",
        .keys = &.{
            .{ .name = "size", .value_type = .number, .optional = false },
            .{ .name = "color", .value_type = .string, .optional = true },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "test", .forms = &.{widget} };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `(widget :size 10 :color "red")` — cursor inside the `:color "red"` kvpair.
    //  0123456789012345678901234567890
    //            1111111111222222222233
    try h.openDocument("file:///a.sjon", 1, "(widget :size 10 :color \"red\")");

    const arena = fx.arena();

    const help = (try h.getSignatureHelp(arena, "file:///a.sjon", 20)).?;
    try std.testing.expectEqual(@as(usize, 1), help.signatures.len);
    const sig = help.signatures[0];
    try std.testing.expectEqualStrings("widget :size number :color? string", sig.label);
    try std.testing.expectEqualStrings("make a widget", sig.documentation);
    try std.testing.expectEqual(@as(usize, 2), sig.parameters.len);
    // Param ranges point at the `:k type` substrings within the label.
    try std.testing.expectEqualStrings(
        ":size number",
        sig.label[sig.parameters[0].label_start..sig.parameters[0].label_end],
    );
    try std.testing.expectEqualStrings(
        ":color? string",
        sig.label[sig.parameters[1].label_start..sig.parameters[1].label_end],
    );
    try std.testing.expectEqual(@as(?u32, 1), help.active_parameter);
}

test "signature help on form with cursor between kvpairs has no active param" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const widget: sjon.Plugin.FormSpec = .{
        .name = "widget",
        .keys = &.{
            .{ .name = "size", .value_type = .number, .optional = false },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "test", .forms = &.{widget} };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // Cursor right after the head, before any kvpair: byte 7 (between `t` and ` `).
    try h.openDocument("file:///a.sjon", 1, "(widget )");

    const arena = fx.arena();

    const help = (try h.getSignatureHelp(arena, "file:///a.sjon", 8)).?;
    try std.testing.expectEqual(@as(?u32, null), help.active_parameter);
}

test "signature help for typed expr-func picks the active arg by cursor position" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // Custom name that doesn't collide with `core` (which already defines
    // lerp/vec3/etc.) — we want a clean `.found`, not `.ambiguous`.
    const f: sjon.Plugin.ExprFunc = .{
        .name = "mix3",
        .arity = .{ .fixed = 3 },
        .params = &.{ .number, .number, .number },
        .description = "mix three numbers",
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "test", .expr_funcs = &.{f} };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    //  0 12345 67 89..
    // "(mix3 1 2 3)"
    try h.openDocument("file:///a.sjon", 1, "(mix3 1 2 3)");

    const arena = fx.arena();

    // Cursor inside the third arg (`3`, byte 10).
    const help = (try h.getSignatureHelp(arena, "file:///a.sjon", 10)).?;
    try std.testing.expectEqualStrings("mix3 number number number", help.signatures[0].label);
    try std.testing.expectEqual(@as(usize, 3), help.signatures[0].parameters.len);
    try std.testing.expectEqual(@as(?u32, 2), help.active_parameter);
}

test "signature help for variadic expr-func clamps overflow to the rest slot" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const f: sjon.Plugin.ExprFunc = .{
        .name = "stretch",
        .arity = .{ .at_least = 1 },
        .params = &.{.number},
        .rest = .number,
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "test", .expr_funcs = &.{f} };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    //  0 1234567 89..
    // "(stretch 1 2 3 4)"
    try h.openDocument("file:///a.sjon", 1, "(stretch 1 2 3 4)");

    const arena = fx.arena();

    // Cursor at byte 15 — inside the fourth positional arg `4`. Past the
    // single fixed param, so active should be the rest slot (index 1).
    const help = (try h.getSignatureHelp(arena, "file:///a.sjon", 15)).?;
    try std.testing.expectEqualStrings("stretch number ...number", help.signatures[0].label);
    try std.testing.expectEqual(@as(usize, 2), help.signatures[0].parameters.len);
    try std.testing.expectEqual(@as(?u32, 1), help.active_parameter);
}

test "signature help renders rest type even when params is null (`+` from core)" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `+` from core: variadic, no `params` annotation but rest = .number.
    // We surface the rest as the single parameter so the user still sees
    // the type the func expects. Core declares `+`'s result, so the label
    // also carries the `→` arrow.
    try h.openDocument("file:///a.sjon", 1, "(+ 1 2 3)");

    const arena = fx.arena();

    const help = (try h.getSignatureHelp(arena, "file:///a.sjon", 5)).?;
    try std.testing.expectEqualStrings("+ ...number → `number`", help.signatures[0].label);
    try std.testing.expectEqual(@as(usize, 1), help.signatures[0].parameters.len);
    try std.testing.expectEqual(@as(?u32, 0), help.active_parameter);
}

test "signature help on fully-opaque expr-func shows a `…` placeholder" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // Custom func with neither params nor rest — the truly-opaque case.
    const f: sjon.Plugin.ExprFunc = .{
        .name = "magic",
        .arity = .{ .at_least = 0 },
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "test", .expr_funcs = &.{f} };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(magic 1 2)");

    const arena = fx.arena();

    const help = (try h.getSignatureHelp(arena, "file:///a.sjon", 8)).?;
    try std.testing.expectEqualStrings("magic …", help.signatures[0].label);
    try std.testing.expectEqual(@as(usize, 0), help.signatures[0].parameters.len);
    try std.testing.expectEqual(@as(?u32, null), help.active_parameter);
}

test "signature help returns null on the head, outside any form, and for unknown heads" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try h.openDocument("file:///a.sjon", 1, "(+ 1 2)\n");

    const arena = fx.arena();

    // Cursor on the head `+` itself — completion territory.
    try std.testing.expect((try h.getSignatureHelp(arena, "file:///a.sjon", 1)) == null);
    // Cursor past the closing `)` (outside any form span).
    try std.testing.expect((try h.getSignatureHelp(arena, "file:///a.sjon", 7)) == null);
    // Unknown head — neither form nor expr-func resolves.
    try h.changeDocumentFull("file:///a.sjon", 2, "(wibble 1 2)");
    try std.testing.expect((try h.getSignatureHelp(arena, "file:///a.sjon", 8)) == null);
}

test "format yields one whole-document edit for clean source" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try h.openDocument("file:///a.sjon", 1, "(+   1   2)");

    const arena = fx.arena();

    const edits = (try h.getFormatEdits(arena, "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 1), edits.len);
    try std.testing.expectEqual(@as(u32, 0), edits[0].span_start);
    try std.testing.expect(edits[0].new_text.len > 0);
    // Canonical form collapses runs of whitespace to single spaces.
    try std.testing.expect(std.mem.indexOf(u8, edits[0].new_text, "(+ 1 2)") != null);
}

test "format declines on parse-error documents" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // Unclosed form — parser emits an error diagnostic; we refuse to
    // reformat to avoid amplifying the breakage.
    try h.openDocument("file:///a.sjon", 1, "(+ 1 2");

    const arena = fx.arena();

    const edits = try h.getFormatEdits(arena, "file:///a.sjon");
    try std.testing.expect(edits == null);
}

test "range formatting reformats only the covering top-level root" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // Two roots, both messy. Request a range strictly inside root[0].
    //  root[0] = "(alpha    1)" [0..12)   root[1] = "(beta    2)"
    const src = "(alpha    1)\n(beta    2)";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    const edits = (try h.getRangeFormatEdits(arena, "file:///a.sjon", 0, 5)).?;
    try std.testing.expectEqual(@as(usize, 1), edits.len);
    try std.testing.expectEqual(@as(u32, 0), edits[0].span_start);
    try std.testing.expectEqual(@as(u32, 12), edits[0].span_end);
    // The replaced region is exactly root[0]'s original bytes …
    try std.testing.expectEqualStrings("(alpha    1)", src[edits[0].span_start..edits[0].span_end]);
    // … and the reformatting collapses the whitespace run.
    try std.testing.expectEqualStrings("(alpha 1)", edits[0].new_text);
}

test "range formatting spanning two roots reformats both" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const src = "(alpha    1)\n(beta    2)";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    // Range covers both roots.
    const edits = (try h.getRangeFormatEdits(arena, "file:///a.sjon", 0, @intCast(src.len))).?;
    try std.testing.expectEqual(@as(usize, 2), edits.len);
    try std.testing.expectEqualStrings("(alpha 1)", edits[0].new_text);
    try std.testing.expectEqualStrings("(beta 2)", edits[1].new_text);
}

test "range formatting preserves comments inside the root" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // A single root with an inner (before-child) comment. The reformatting
    // must keep the comment in the new text — the CP3 go/no-go.
    const src =
        \\(scene
        \\  ; keep me
        \\  1)
    ;
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    const edits = (try h.getRangeFormatEdits(arena, "file:///a.sjon", 0, @intCast(src.len))).?;
    try std.testing.expectEqual(@as(usize, 1), edits.len);
    try std.testing.expect(std.mem.indexOf(u8, edits[0].new_text, "; keep me") != null);
}

test "range formatting declines on parse errors" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // Unclosed form — parity with whole-doc formatting: refuse.
    try h.openDocument("file:///a.sjon", 1, "(+ 1 2");

    const arena = fx.arena();

    const edits = try h.getRangeFormatEdits(arena, "file:///a.sjon", 0, 6);
    try std.testing.expect(edits == null);
}

test "range formatting does not duplicate a root's leading comment" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // root[1]'s span does NOT cover its leading comment (the comment sits
    // in the inter-root gap). Printing the comment and replacing only the
    // node span would leave the original AND insert a copy. The new text
    // must therefore omit the leading comment, and the replaced span must
    // be exactly the node — leaving the comment untouched in place.
    const src =
        \\(alpha 1)
        \\; lead on beta
        \\(beta    2)
    ;
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    // Request a range inside root[1] only.
    const beta_start: u32 = @intCast(std.mem.indexOf(u8, src, "(beta").?);
    const edits = (try h.getRangeFormatEdits(arena, "file:///a.sjon", beta_start + 1, beta_start + 2)).?;
    try std.testing.expectEqual(@as(usize, 1), edits.len);
    try std.testing.expectEqualStrings("(beta 2)", edits[0].new_text);
    try std.testing.expect(std.mem.indexOf(u8, edits[0].new_text, "lead on beta") == null);
    // Replaced span is the node alone, so the comment is left in place.
    try std.testing.expectEqualStrings("(beta    2)", src[edits[0].span_start..edits[0].span_end]);
}

test "range wholly in inter-root whitespace yields no edits" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // A blank line separates the two roots. "(alpha 1)" is [0..9), the
    // gap is [9..11) ("\n\n"), "(beta 2)" starts at 11.
    const src = "(alpha 1)\n\n(beta 2)";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    // A zero-width range at byte 10 (the blank line) covers no root.
    const edits = (try h.getRangeFormatEdits(arena, "file:///a.sjon", 10, 10)).?;
    try std.testing.expectEqual(@as(usize, 0), edits.len);
}

test "document symbols flatten vectors and skip non-form nodes" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `+` is an expr (form). Inner `1` and `2` are numbers (skipped).
    // The kvpair `:x (vec3 1 2 3)` puts the inner form under the
    // outer symbol's children.
    try h.openDocument("file:///a.sjon", 1, "(+ 1 :x (vec3 1 2 3) 2)");

    const arena = fx.arena();

    const syms = (try h.getDocumentSymbols(arena, "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 1), syms.len);
    try std.testing.expectEqualStrings("+", syms[0].name);
    try std.testing.expectEqual(@as(usize, 1), syms[0].children.len);
    try std.testing.expectEqualStrings("vec3", syms[0].children[0].name);
}

test "folding ranges enumerate every form and vector in source order" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // Outer form, nested vector, nested form. Single-line; the transport
    // is what filters by line — Handler emits every form/vector span.
    try h.openDocument("file:///a.sjon", 1, "(+ 1 [(vec3 1 2 3)] 2)");

    const arena = fx.arena();

    const folds = (try h.getFoldingRanges(arena, "file:///a.sjon")).?;
    // Three folds: outer `(+ ...)`, the vector `[...]`, inner `(vec3 ...)`.
    try std.testing.expectEqual(@as(usize, 3), folds.len);
    // Outer form spans the whole input.
    try std.testing.expectEqual(@as(u32, 0), folds[0].span_start);
    try std.testing.expectEqual(@as(u32, 22), folds[0].span_end);
    // Vector `[...]` at bytes 5..19.
    try std.testing.expectEqual(@as(u32, 5), folds[1].span_start);
    try std.testing.expectEqual(@as(u32, 19), folds[1].span_end);
    // Inner form `(vec3 1 2 3)` at bytes 6..18.
    try std.testing.expectEqual(@as(u32, 6), folds[2].span_start);
    try std.testing.expectEqual(@as(u32, 18), folds[2].span_end);
}

test "folding ranges return empty list for documents with no forms" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try h.openDocument("file:///a.sjon", 1, "42");

    const arena = fx.arena();

    const folds = (try h.getFoldingRanges(arena, "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 0), folds.len);
}

test "folding ranges span a form across newlines" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `(+\n 1\n 2)` — a single form whose body straddles three lines. The
    // span is byte-based, so it covers the whole form regardless of newlines.
    try h.openDocument("file:///a.sjon", 1, "(+\n 1\n 2)");

    const arena = fx.arena();

    const folds = (try h.getFoldingRanges(arena, "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 1), folds.len);
    try std.testing.expectEqual(@as(u32, 0), folds[0].span_start);
    // `)` is the last byte at index 8; span_end is one past it.
    try std.testing.expectEqual(@as(u32, 9), folds[0].span_end);
}

test "folding ranges list nested forms in pre-order" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `(a (b 1) (c 2))` — outer form with two sibling inner forms.
    try h.openDocument("file:///a.sjon", 1, "(a (b 1) (c 2))");

    const arena = fx.arena();

    const folds = (try h.getFoldingRanges(arena, "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 3), folds.len);
    // Outer form first (pre-order), then each inner form in source order.
    try std.testing.expectEqual(@as(u32, 0), folds[0].span_start);
    try std.testing.expectEqual(@as(u32, 15), folds[0].span_end);
    try std.testing.expectEqual(@as(u32, 3), folds[1].span_start);
    try std.testing.expectEqual(@as(u32, 8), folds[1].span_end);
    try std.testing.expectEqual(@as(u32, 9), folds[2].span_start);
    try std.testing.expectEqual(@as(u32, 14), folds[2].span_end);
}

test "folding ranges walk a deeply nested document via the frame stack (C.13)" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `(a (a (a … x …)))` nested `depth` forms deep — comfortably under
    // Parser.MAX_PARSE_DEPTH (1024). The frame-stack NodeWalker must yield
    // exactly one fold per form no matter how deep the nesting, without
    // recursing on the host stack.
    const depth: usize = 800;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    for (0..depth) |_| try src.appendSlice(a, "(a ");
    try src.append(a, 'x');
    for (0..depth) |_| try src.append(a, ')');

    try h.openDocument("file:///deep.sjon", 1, src.items);

    const arena = fx.arena();

    const folds = (try h.getFoldingRanges(arena, "file:///deep.sjon")).?;
    try std.testing.expectEqual(depth, folds.len);
    // Pre-order: the outermost form spans the whole document.
    try std.testing.expectEqual(@as(u32, 0), folds[0].span_start);
    try std.testing.expectEqual(@as(u32, @intCast(src.items.len)), folds[0].span_end);
}

test "folding ranges fold a kvpair value, not the pair node" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `(form :key [1 2 3])` — the kvpair `:key [..]` itself is not a foldable
    // node; only its value vector is. So we expect the form + the vector, and
    // crucially no third span synthesized for the pair.
    try h.openDocument("file:///a.sjon", 1, "(form :key [1 2 3])");

    const arena = fx.arena();

    const folds = (try h.getFoldingRanges(arena, "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 2), folds.len);
    // The enclosing form.
    try std.testing.expectEqual(@as(u32, 0), folds[0].span_start);
    try std.testing.expectEqual(@as(u32, 19), folds[0].span_end);
    // The value vector `[1 2 3]` at bytes 11..18 — not the pair.
    try std.testing.expectEqual(@as(u32, 11), folds[1].span_start);
    try std.testing.expectEqual(@as(u32, 18), folds[1].span_end);
}

test "folding ranges cover multiple top-level forms" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // Two sibling top-level forms — each is its own foldable region.
    try h.openDocument("file:///a.sjon", 1, "(a 1)\n(b 2)");

    const arena = fx.arena();

    const folds = (try h.getFoldingRanges(arena, "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 2), folds.len);
    try std.testing.expectEqual(@as(u32, 0), folds[0].span_start);
    try std.testing.expectEqual(@as(u32, 5), folds[0].span_end);
    try std.testing.expectEqual(@as(u32, 6), folds[1].span_start);
    try std.testing.expectEqual(@as(u32, 11), folds[1].span_end);
}

test "folding ranges descend through form, vector, form" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `(a [(b 1)])` — form ⊃ vector ⊃ form, three nesting levels.
    try h.openDocument("file:///a.sjon", 1, "(a [(b 1)])");

    const arena = fx.arena();

    const folds = (try h.getFoldingRanges(arena, "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 3), folds.len);
    // Outer form, then the vector, then the innermost form — pre-order.
    try std.testing.expectEqual(@as(u32, 0), folds[0].span_start);
    try std.testing.expectEqual(@as(u32, 11), folds[0].span_end);
    try std.testing.expectEqual(@as(u32, 3), folds[1].span_start);
    try std.testing.expectEqual(@as(u32, 10), folds[1].span_end);
    try std.testing.expectEqual(@as(u32, 4), folds[2].span_start);
    try std.testing.expectEqual(@as(u32, 9), folds[2].span_end);
}

test "inlay hints label bare form heads with their plugin name" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const widget: sjon.Plugin.FormSpec = .{ .name = "widget" };
    const ui_plugin: sjon.Plugin.Plugin = .{ .name = "ui", .forms = &.{widget} };
    h.schema = .init(&.{ ui_plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(widget)");

    const arena = fx.arena();

    const hints = (try h.getInlayHints(arena, "file:///a.sjon", 0, 8)).?;
    try std.testing.expectEqual(@as(usize, 1), hints.len);
    try std.testing.expectEqualStrings("ui", hints[0].label);
    // `widget` occupies bytes 1..7, so the hint sits at offset 7 (right
    // after the head, before whatever follows).
    try std.testing.expectEqual(@as(u32, 7), hints[0].offset);
    try std.testing.expect(hints[0].padding_left);
    try std.testing.expect(!hints[0].padding_right);
}

test "inlay hints skip qualified heads — namespace already says it" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const widget: sjon.Plugin.FormSpec = .{ .name = "widget" };
    const ui_plugin: sjon.Plugin.Plugin = .{ .name = "ui", .forms = &.{widget} };
    h.schema = .init(&.{ ui_plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(ui/widget)");

    const arena = fx.arena();

    const hints = (try h.getInlayHints(arena, "file:///a.sjon", 0, 11)).?;
    try std.testing.expectEqual(@as(usize, 0), hints.len);
}

test "inlay hints skip core heads — implicit baseline, would be noise" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try h.openDocument("file:///a.sjon", 1, "(+ 1 (vec3 1 2 3))");

    const arena = fx.arena();

    const hints = (try h.getInlayHints(arena, "file:///a.sjon", 0, 18)).?;
    try std.testing.expectEqual(@as(usize, 0), hints.len);
}

test "inlay hints skip ambiguous heads — diagnostic + quickfix already cover them" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const widget: sjon.Plugin.FormSpec = .{ .name = "widget" };
    const a_plugin: sjon.Plugin.Plugin = .{ .name = "a", .forms = &.{widget} };
    const b_plugin: sjon.Plugin.Plugin = .{ .name = "b", .forms = &.{widget} };
    h.schema = .init(&.{ a_plugin, b_plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(widget)");

    const arena = fx.arena();

    const hints = (try h.getInlayHints(arena, "file:///a.sjon", 0, 8)).?;
    try std.testing.expectEqual(@as(usize, 0), hints.len);
}

test "inlay hints recurse into nested forms and vectors" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const widget: sjon.Plugin.FormSpec = .{ .name = "widget" };
    const ui_plugin: sjon.Plugin.Plugin = .{ .name = "ui", .forms = &.{widget} };
    h.schema = .init(&.{ ui_plugin, sjon.plugins.core.plugin });

    // Outer `(+ …)` is core — no hint. Inner `(widget)` is plugin-owned
    // and lives inside a vector inside the core form, so the walker has
    // to descend through both `vector` and form-children to find it.
    try h.openDocument("file:///a.sjon", 1, "(+ 1 [(widget)] 2)");

    const arena = fx.arena();

    const hints = (try h.getInlayHints(arena, "file:///a.sjon", 0, 18)).?;
    try std.testing.expectEqual(@as(usize, 1), hints.len);
    try std.testing.expectEqualStrings("ui", hints[0].label);
    // `widget` inside `(+ 1 [(widget)] 2)` is at bytes 7..13.
    try std.testing.expectEqual(@as(u32, 13), hints[0].offset);
}

test "inlay hints clip to the requested byte range" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const widget: sjon.Plugin.FormSpec = .{ .name = "widget" };
    const ui_plugin: sjon.Plugin.Plugin = .{ .name = "ui", .forms = &.{widget} };
    h.schema = .init(&.{ ui_plugin, sjon.plugins.core.plugin });

    // Two top-level widget forms, one early and one late.
    try h.openDocument("file:///a.sjon", 1, "(widget) (widget)");

    const arena = fx.arena();

    // Range covers only the second form (bytes 9..17). First form's
    // head_span ends at 7 — outside the range.
    const hints = (try h.getInlayHints(arena, "file:///a.sjon", 9, 17)).?;
    try std.testing.expectEqual(@as(usize, 1), hints.len);
    try std.testing.expectEqual(@as(u32, 16), hints[0].offset);
}

test "inlay hints label expr-funcs from non-core plugins" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // Custom expr-func name (no collision with core `vec3`/`+`/etc.).
    const blend: sjon.Plugin.ExprFunc = .{ .name = "blend", .arity = .{ .at_least = 0 } };
    const fx_plugin: sjon.Plugin.Plugin = .{ .name = "fx", .expr_funcs = &.{blend} };
    h.schema = .init(&.{ fx_plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(blend 1 2)");

    const arena = fx.arena();

    const hints = (try h.getInlayHints(arena, "file:///a.sjon", 0, 11)).?;
    try std.testing.expectEqual(@as(usize, 1), hints.len);
    try std.testing.expectEqualStrings("fx", hints[0].label);
    try std.testing.expectEqual(@as(u32, 6), hints[0].offset);
}

test "inlay hints return null for unknown documents" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const arena = fx.arena();

    try std.testing.expect((try h.getInlayHints(arena, "file:///missing.sjon", 0, 0)) == null);
}

test "code action suggests typo fix for unknown_form" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `clmp` is a misspelling of `clamp` (Levenshtein distance 1).
    try h.openDocument("file:///a.sjon", 1, "(clmp 1 0 2)");

    const arena = fx.arena();

    // Range covers the head identifier `clmp` (bytes 1..5).
    const actions = (try h.getCodeActions(arena, "file:///a.sjon", 1, 5)).?;
    try std.testing.expect(actions.len > 0);

    var saw_clamp = false;
    for (actions) |act| {
        if (std.mem.indexOf(u8, act.title, "clamp") != null) saw_clamp = true;
        for (act.diagnostics) |d| {
            try std.testing.expectEqualStrings("unknown_form", d.code);
        }
    }
    try std.testing.expect(saw_clamp);
}

test "code action typo fix uses Damerau distance and alphabetical tie-break (C.12)" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `circel` is:
    //   - one adjacent transposition from `circle` (Damerau 1, plain-Lev 2)
    //   - two substitutions      from `circus` (both 2)
    // `circus` is declared first, so a plain-Levenshtein engine with a
    // strict-`<` "first candidate wins" tie-break suggests `circus` today.
    // The shared Damerau engine makes `circle` strictly closer (1 < 2), so
    // it must win — and even on a true distance tie, `suggest`'s
    // alphabetical secondary sort prefers `circle`.
    const circus: sjon.Plugin.FormSpec = .{ .name = "circus" };
    const circle: sjon.Plugin.FormSpec = .{ .name = "circle" };
    const plugin: sjon.Plugin.Plugin = .{ .name = "shapes", .forms = &.{ circus, circle } };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(circel)");

    const arena = fx.arena();

    // Range covers the head identifier `circel` (bytes 1..7).
    const actions = (try h.getCodeActions(arena, "file:///a.sjon", 1, 7)).?;

    var saw_circle = false;
    var saw_circus = false;
    for (actions) |act| {
        if (std.mem.indexOf(u8, act.title, "circle") != null) saw_circle = true;
        if (std.mem.indexOf(u8, act.title, "circus") != null) saw_circus = true;
    }
    try std.testing.expect(saw_circle);
    try std.testing.expect(!saw_circus);
}

test "code action returns no fix when target is too distant" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // 7 letters of nonsense — too far from any core head.
    try h.openDocument("file:///a.sjon", 1, "(zzzzzzz)");

    const arena = fx.arena();

    const actions = (try h.getCodeActions(arena, "file:///a.sjon", 1, 8)).?;
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "code action emits one qualify per claimant for ambiguous_form" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const widget: sjon.Plugin.FormSpec = .{ .name = "widget" };
    const a_plugin: sjon.Plugin.Plugin = .{ .name = "a", .forms = &.{widget} };
    const b_plugin: sjon.Plugin.Plugin = .{ .name = "b", .forms = &.{widget} };
    h.schema = .init(&.{ a_plugin, b_plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(widget)");

    const arena = fx.arena();

    // Range covers `widget` (bytes 1..7).
    const actions = (try h.getCodeActions(arena, "file:///a.sjon", 1, 7)).?;
    try std.testing.expectEqual(@as(usize, 2), actions.len);

    var saw_a = false;
    var saw_b = false;
    for (actions) |act| {
        for (act.diagnostics) |d| {
            try std.testing.expectEqualStrings("ambiguous_form", d.code);
        }
        try std.testing.expectEqual(@as(usize, 1), act.edits.len);
        try std.testing.expectEqual(@as(u32, 1), act.edits[0].span_start);
        try std.testing.expectEqual(@as(u32, 7), act.edits[0].span_end);
        if (std.mem.eql(u8, act.edits[0].new_text, "a/widget")) saw_a = true;
        if (std.mem.eql(u8, act.edits[0].new_text, "b/widget")) saw_b = true;
    }
    try std.testing.expect(saw_a and saw_b);
}

test "code action inserts each missing required key with a typed stub" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // Two required keys (different types) plus one optional. The
    // resulting actions cover only the required ones, in spec-key order.
    const widget: sjon.Plugin.FormSpec = .{
        .name = "widget",
        .keys = &.{
            .{ .name = "size", .value_type = .number, .optional = false },
            .{ .name = "label", .value_type = .string, .optional = false },
            .{ .name = "color", .value_type = .string, .optional = true },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "test", .forms = &.{widget} };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(widget)");

    const arena = fx.arena();

    const actions = (try h.getCodeActions(arena, "file:///a.sjon", 1, 7)).?;
    try std.testing.expectEqual(@as(usize, 2), actions.len);

    // Both edits insert at the closing paren (byte 7).
    for (actions) |act| {
        for (act.diagnostics) |d| {
            try std.testing.expectEqualStrings("missing_required_key", d.code);
        }
        try std.testing.expectEqual(@as(usize, 1), act.edits.len);
        try std.testing.expectEqual(@as(u32, 7), act.edits[0].span_start);
        try std.testing.expectEqual(@as(u32, 7), act.edits[0].span_end);
    }
    try std.testing.expectEqualStrings(" :size 0", actions[0].edits[0].new_text);
    try std.testing.expectEqualStrings(" :label \"\"", actions[1].edits[0].new_text);
}

test "code action skips required keys already present" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const widget: sjon.Plugin.FormSpec = .{
        .name = "widget",
        .keys = &.{
            .{ .name = "size", .value_type = .number, .optional = false },
            .{ .name = "label", .value_type = .string, .optional = false },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "test", .forms = &.{widget} };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `:size` is already present; only `:label` should surface as a fix.
    const src = "(widget :size 1)";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    const actions = (try h.getCodeActions(arena, "file:///a.sjon", 1, 7)).?;
    try std.testing.expectEqual(@as(usize, 1), actions.len);
    try std.testing.expectEqualStrings(" :label \"\"", actions[0].edits[0].new_text);
    // Inserts at the closing `)`, byte 15.
    try std.testing.expectEqual(@as(u32, 15), actions[0].edits[0].span_start);
}

test "code action drops `:k` and keeps the value for expr_kvpair_not_allowed" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `+` is a core expression — kvpairs are rejected. The fix elides
    // `:foo ` and leaves `1` as a positional argument.
    try h.openDocument("file:///a.sjon", 1, "(+ :foo 1)");

    const arena = fx.arena();

    // `:foo` spans bytes 3..7; `1` lives at byte 8.
    const actions = (try h.getCodeActions(arena, "file:///a.sjon", 3, 7)).?;
    try std.testing.expectEqual(@as(usize, 1), actions.len);

    const act = actions[0];
    for (act.diagnostics) |d| {
        try std.testing.expectEqualStrings("expr_kvpair_not_allowed", d.code);
    }
    try std.testing.expectEqualStrings("Drop `:foo` (keep value)", act.title);
    try std.testing.expectEqual(@as(usize, 1), act.edits.len);
    try std.testing.expectEqual(@as(u32, 3), act.edits[0].span_start);
    try std.testing.expectEqual(@as(u32, 8), act.edits[0].span_end);
    try std.testing.expectEqualStrings("", act.edits[0].new_text);
}

/// Test schema for the duplicate-key fixture: a `scene` form with an
/// optional `:title` string key. Optional so the test doesn't need to
/// supply other required keys to reach the duplicate-check phase.
fn sceneTitleSchema() sjon.Schema.Schema {
    const scene: sjon.Plugin.FormSpec = .{
        .name = "scene",
        .keys = &.{
            .{ .name = "title", .value_type = .string, .optional = true },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "test", .forms = &.{scene} };
    return .init(&.{ plugin, sjon.plugins.core.plugin });
}

test "code action removes duplicate_key (single-line, keeps first)" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = sceneTitleSchema();

    const src = "(scene :title \"a\" :title \"b\")";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    // The duplicate `:title` token is at bytes 18..24.
    const actions = (try h.getCodeActions(arena, "file:///a.sjon", 18, 24)).?;
    try std.testing.expectEqual(@as(usize, 1), actions.len);

    const act = actions[0];
    try std.testing.expectEqualStrings("Remove duplicate `:title`", act.title);
    try std.testing.expectEqual(@as(usize, 1), act.diagnostics.len);
    try std.testing.expectEqualStrings("duplicate_key", act.diagnostics[0].code);
    try std.testing.expectEqual(@as(usize, 1), act.edits.len);
    // Sweep includes the leading space (byte 17) and runs to the end
    // of `"b"` (byte 28).
    try std.testing.expectEqual(@as(u32, 17), act.edits[0].span_start);
    try std.testing.expectEqual(@as(u32, 28), act.edits[0].span_end);
    try std.testing.expectEqualStrings("", act.edits[0].new_text);
}

test "code action suppresses duplicate_key removal when a comment precedes the duplicate" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = sceneTitleSchema();

    // The line above the duplicate ends in a `;` comment. Deleting the
    // intervening whitespace would re-glue the closing `)` (or the
    // surviving sibling) into that comment.
    const src = "(scene :title \"a\" ; first\n       :title \"b\")";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    // Range covers the duplicate `:title` on line 2.
    const dup_start: u32 = @intCast(std.mem.indexOf(u8, src, ":title \"b\"").?);
    const actions = (try h.getCodeActions(arena, "file:///a.sjon", dup_start, dup_start + 6)).?;
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "code action emits one removal per duplicate occurrence" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = sceneTitleSchema();

    // Three occurrences of `:title` — validator emits a diagnostic for
    // the second and third, each fix removes its own kvpair.
    const src = "(scene :title \"a\" :title \"b\" :title \"c\")";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    const actions = (try h.getCodeActions(arena, "file:///a.sjon", 0, @intCast(src.len))).?;
    try std.testing.expectEqual(@as(usize, 2), actions.len);

    var saw_b = false;
    var saw_c = false;
    for (actions) |act| {
        try std.testing.expectEqualStrings("Remove duplicate `:title`", act.title);
        try std.testing.expectEqual(@as(usize, 1), act.edits.len);
        const edit = act.edits[0];
        const deleted = src[edit.span_start..edit.span_end];
        if (std.mem.indexOf(u8, deleted, "\"b\"") != null) saw_b = true;
        if (std.mem.indexOf(u8, deleted, "\"c\"") != null) saw_c = true;
    }
    try std.testing.expect(saw_b);
    try std.testing.expect(saw_c);
}

test "code action removes duplicate_key on its own line, stopping at the prior line" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = sceneTitleSchema();

    const src = "(scene\n  :title \"a\"\n  :title \"b\"\n)";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    const actions = (try h.getCodeActions(arena, "file:///a.sjon", 0, @intCast(src.len))).?;
    try std.testing.expectEqual(@as(usize, 1), actions.len);

    const act = actions[0];
    try std.testing.expectEqual(@as(usize, 1), act.edits.len);
    // Sweep consumes the leading newline + indent. Result: prior `"a"`
    // line is preserved verbatim, duplicate line and its newline gone.
    const edit = act.edits[0];
    try std.testing.expectEqualStrings("", edit.new_text);
    const deleted = src[edit.span_start..edit.span_end];
    try std.testing.expectEqualStrings("\n  :title \"b\"", deleted);
}

test "code action suggests closest registered name for not_cross_ref" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // Two `phrase` definitions register `p0` and `p1`. The typo `pX` in
    // the track sequence is Levenshtein 1 from `p0` — should suggest it.
    const src = "(phrase :name p0) (phrase :name p1) (track :sequence [pX])";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    const bad_start: u32 = @intCast(std.mem.indexOf(u8, src, "pX").?);
    const actions = (try h.getCodeActions(arena, "file:///a.sjon", bad_start, bad_start + 2)).?;
    try std.testing.expectEqual(@as(usize, 1), actions.len);

    const act = actions[0];
    try std.testing.expectEqual(@as(usize, 1), act.diagnostics.len);
    try std.testing.expectEqualStrings("not_cross_ref", act.diagnostics[0].code);
    try std.testing.expectEqual(@as(usize, 1), act.edits.len);
    try std.testing.expectEqual(bad_start, act.edits[0].span_start);
    try std.testing.expectEqual(bad_start + 2, act.edits[0].span_end);
    // p0 and p1 are both distance 1; first registered wins (hashmap
    // iteration order is stable for the same input). Accept either —
    // the test only cares that one of the two valid names lands.
    const new_text = act.edits[0].new_text;
    try std.testing.expect(std.mem.eql(u8, new_text, "p0") or std.mem.eql(u8, new_text, "p1"));
    const expected_title = try std.fmt.allocPrint(arena, "Replace with `{s}`", .{new_text});
    try std.testing.expectEqualStrings(expected_title, act.title);
}

test "code action returns no fix when cross-ref typo is too distant" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `xyzzy` shares no characters with `p0` — distance 5, beyond cap.
    const src = "(phrase :name p0) (track :sequence [xyzzy])";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    const bad_start: u32 = @intCast(std.mem.indexOf(u8, src, "xyzzy").?);
    const actions = (try h.getCodeActions(arena, "file:///a.sjon", bad_start, bad_start + 5)).?;
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "code action surfaces only in-scope names for a scoped not_cross_ref" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefScopedPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // Two pieces, each registers a distinct `phrase` name. The `jump`
    // in piece B references `p0` (defined in piece A). The current
    // scope IS found (piece B), the name just isn't registered there —
    // so the validator emits `not_cross_ref` and we should suggest the
    // in-scope name `p1`, not the cross-scope `p0`.
    const src = "(piece (phrase :name p0)) (piece (phrase :name p1) (jump :target p0))";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    // The bad `p0` is the second `:target p0` (inside piece B).
    const target_kvpair: u32 = @intCast(std.mem.lastIndexOf(u8, src, ":target p0").?);
    const bad_start: u32 = target_kvpair + @as(u32, @intCast(":target ".len));
    const actions = (try h.getCodeActions(arena, "file:///a.sjon", bad_start, bad_start + 2)).?;
    try std.testing.expectEqual(@as(usize, 1), actions.len);

    const act = actions[0];
    try std.testing.expectEqual(@as(usize, 1), act.diagnostics.len);
    try std.testing.expectEqualStrings("not_cross_ref", act.diagnostics[0].code);
    try std.testing.expectEqualStrings("p1", act.edits[0].new_text);
    try std.testing.expectEqualStrings("Replace with `p1`", act.title);
}

/// Schema with a `shape` key whose value resolves to a member set of
/// `{point, rect, circle}`. Used by the `not_member` quickfix tests.
fn shapeMemberSchema() sjon.Schema.Schema {
    const shape_kind: sjon.Plugin.ValueKind = .{
        .name = "shape-kind",
        .underlying = .symbol,
        .members = .{ .members = &.{
            .{ .name = "point" },
            .{ .name = "rect" },
            .{ .name = "circle" },
        } },
    };
    const draw: sjon.Plugin.FormSpec = .{
        .name = "draw",
        .keys = &.{
            .{ .name = "shape", .value_type = .{ .named = .{ .name = "shape-kind" } }, .optional = false },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{
        .name = "test",
        .value_kinds = &.{shape_kind},
        .forms = &.{draw},
    };
    return .init(&.{ plugin, sjon.plugins.core.plugin });
}

test "code action suggests closest member for not_member typo" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = shapeMemberSchema();

    // `recta` → `rect` (delete one char, Levenshtein 1; closer than the
    // other members `point` and `circle`).
    const src = "(draw :shape recta)";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    const bad_start: u32 = @intCast(std.mem.indexOf(u8, src, "recta").?);
    const actions = (try h.getCodeActions(arena, "file:///a.sjon", bad_start, bad_start + 5)).?;
    try std.testing.expectEqual(@as(usize, 1), actions.len);

    const act = actions[0];
    try std.testing.expectEqual(@as(usize, 1), act.diagnostics.len);
    try std.testing.expectEqualStrings("not_member", act.diagnostics[0].code);
    try std.testing.expectEqualStrings("Replace with `rect`", act.title);
    try std.testing.expectEqual(@as(usize, 1), act.edits.len);
    try std.testing.expectEqual(bad_start, act.edits[0].span_start);
    try std.testing.expectEqual(bad_start + 5, act.edits[0].span_end);
    try std.testing.expectEqualStrings("rect", act.edits[0].new_text);
}

test "code action skips deprecated members when picking the closest" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `oval` is deprecated and would be the Levenshtein-closest to
    // `ovel`. With deprecated members excluded, the fix should fall
    // through to the next closest live member (`rect`, distance 4 —
    // beyond cap) and suppress rather than recommend a deprecated name.
    const shape_kind: sjon.Plugin.ValueKind = .{
        .name = "shape-kind",
        .underlying = .symbol,
        .members = .{ .members = &.{
            .{ .name = "oval", .deprecated = true },
            .{ .name = "rect" },
            .{ .name = "circle" },
        } },
    };
    const draw: sjon.Plugin.FormSpec = .{
        .name = "draw",
        .keys = &.{
            .{ .name = "shape", .value_type = .{ .named = .{ .name = "shape-kind" } }, .optional = false },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{
        .name = "test",
        .value_kinds = &.{shape_kind},
        .forms = &.{draw},
    };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    const src = "(draw :shape ovel)";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    const bad_start: u32 = @intCast(std.mem.indexOf(u8, src, "ovel").?);
    const actions = (try h.getCodeActions(arena, "file:///a.sjon", bad_start, bad_start + 4)).?;
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "code action skips not_member fix when the enclosing form went unknown" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    // No schema registered for `draw` — the form is unknown, so the
    // member-set lookup misses and the fix suppresses. The validator
    // won't emit `not_member` for an unknown form either, so this
    // primarily verifies that the dispatch arm doesn't crash when the
    // resolver bails (defensive against future emitters).
    h.schema = .init(&.{sjon.plugins.core.plugin});

    const src = "(draw :shape recangle)";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    const actions = (try h.getCodeActions(arena, "file:///a.sjon", 0, @intCast(src.len))).?;
    for (actions) |act| {
        for (act.diagnostics) |d| {
            try std.testing.expect(!std.mem.eql(u8, d.code, "not_member"));
        }
    }
}

test "code action gracefully suppresses when cross_ref_outside_scope has no in-scope candidates" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefScopedPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `jump` lives at the top level — outside any enclosing `(piece …)`,
    // so the validator emits `cross_ref_outside_scope` (no scope to
    // search in). With no in-scope alternatives, the fix should suppress
    // rather than suggest a cross-scope name that wouldn't compile.
    const src = "(piece (phrase :name p0)) (jump :target p0)";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    var saw_outside_scope = false;
    const diags = (try h.getDiagnostics(arena, "file:///a.sjon")).?;
    for (diags) |d| {
        if (std.mem.eql(u8, d.code, "cross_ref_outside_scope")) saw_outside_scope = true;
    }
    try std.testing.expect(saw_outside_scope);

    const actions = (try h.getCodeActions(arena, "file:///a.sjon", 0, @intCast(src.len))).?;
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "code action does not suggest the defining form's own name" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefDirectPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // The `:related` slot is itself a cross-ref to `phrase`. Inside
    // `(phrase :name p0 :related pX)`, the only registered name is
    // `p0` — but suggesting `p0` would point the phrase at itself.
    // With no other candidates, the fix should be suppressed.
    const src = "(phrase :name p0 :related pX)";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();

    const bad_start: u32 = @intCast(std.mem.indexOf(u8, src, "pX").?);
    const actions = (try h.getCodeActions(arena, "file:///a.sjon", bad_start, bad_start + 2)).?;
    try std.testing.expectEqual(@as(usize, 0), actions.len);
}

test "diagnostic for unknown form lands with stable code string" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();

    // `wibble` isn't declared by `core`, so this should produce
    // `unknown_form` from the validator.
    try h.openDocument("file:///b.sjon", 1, "(wibble)");
    var arena_state: std.heap.ArenaAllocator = .init(a);
    defer arena_state.deinit();
    const diags = (try h.getDiagnostics(arena_state.allocator(), "file:///b.sjon")).?;
    try std.testing.expect(diags.len > 0);

    var saw_unknown = false;
    for (diags) |d| {
        if (std.mem.eql(u8, d.code, "unknown_form")) saw_unknown = true;
    }
    try std.testing.expect(saw_unknown);
}

test "form-head completion emits a snippet for required keys" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // Inject a synthetic plugin so we can test required-key behaviour.
    // `widget` has one optional key (`color`, string) and one required
    // key (`size`, number) — only `size` should appear in the snippet.
    const widget: sjon.Plugin.FormSpec = .{
        .name = "widget",
        .keys = &.{
            .{ .name = "color", .value_type = .string, .optional = true },
            .{ .name = "size", .value_type = .number, .optional = false },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "test", .forms = &.{widget} };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 1)).?;
    const item = findCompletion(items, "widget");
    try std.testing.expectEqual(CompletionItem.InsertTextFormat.snippet, item.insert_text_format);
    try std.testing.expectEqualStrings("widget :size ${1:0}$0", item.insert_text.?);
}

test "form-head completion omits snippet when no keys are required" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const widget: sjon.Plugin.FormSpec = .{
        .name = "widget",
        .keys = &.{
            .{ .name = "color", .value_type = .string, .optional = true },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "test", .forms = &.{widget} };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 1)).?;
    const item = findCompletion(items, "widget");
    try std.testing.expect(item.insert_text == null);
    try std.testing.expectEqual(CompletionItem.InsertTextFormat.plain_text, item.insert_text_format);
}

test "form-head snippet covers each ValueType placeholder" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // One required key per ValueType variant — placeholders use successive
    // tab stops and the per-type default literal.
    const f: sjon.Plugin.FormSpec = .{
        .name = "kitchen",
        .keys = &.{
            .{ .name = "s", .value_type = .string, .optional = false },
            .{ .name = "n", .value_type = .number, .optional = false },
            .{ .name = "b", .value_type = .boolean, .optional = false },
            .{ .name = "y", .value_type = .symbol, .optional = false },
            .{ .name = "z", .value_type = .nil, .optional = false },
            .{ .name = "v", .value_type = .vector, .optional = false },
            .{ .name = "f", .value_type = .form, .optional = false },
            .{ .name = "e", .value_type = .expr, .optional = false },
            .{ .name = "a", .value_type = .any, .optional = false },
            .{ .name = "k", .value_type = .{ .named = .{ .name = "color" } }, .optional = false },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "test", .forms = &.{f} };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 1)).?;
    const item = findCompletion(items, "kitchen");
    try std.testing.expectEqualStrings(
        "kitchen :s \"$1\" :n ${2:0} :b ${3|true,false|} :y ${4:symbol}" ++
            " :z ${5:nil} :v [$6] :f ($7) :e ($8) :a $9 :k ${10:color}$0",
        item.insert_text.?,
    );
}

test "form-head snippet escapes `$` and `}` in identifiers" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // SJON symbols allow `$`; defensively make sure the snippet engine
    // sees a literal, not an undefined `${0` placeholder.
    const f: sjon.Plugin.FormSpec = .{
        .name = "do$it",
        .keys = &.{
            .{ .name = "$arg", .value_type = .number, .optional = false },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "test", .forms = &.{f} };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 1)).?;
    const item = findCompletion(items, "do$it");
    try std.testing.expectEqualStrings("do\\$it :\\$arg ${1:0}$0", item.insert_text.?);
}

test "revalidateOpenDocuments flips diagnostics after a schema swap" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // Open against core-only — `widget` is unknown.
    try h.openDocument("file:///a.sjon", 1, "(widget :size 1)");

    const arena = fx.arena();

    {
        const diags = (try h.getDiagnostics(arena, "file:///a.sjon")).?;
        var saw_unknown = false;
        for (diags) |d| {
            if (std.mem.eql(u8, d.code, "unknown_form")) saw_unknown = true;
        }
        try std.testing.expect(saw_unknown);
    }

    // Swap the schema to include a plugin that defines `widget`. Mirrors
    // what `loadProject` does internally — replacing the slice is fine
    // because `Schema.Schema` borrows it.
    const widget: sjon.Plugin.FormSpec = .{
        .name = "widget",
        .keys = &.{
            .{ .name = "size", .value_type = .number, .optional = false },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "test", .forms = &.{widget} };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // Without revalidation, the cached diagnostics are stale.
    {
        const diags = (try h.getDiagnostics(arena, "file:///a.sjon")).?;
        var saw_unknown = false;
        for (diags) |d| {
            if (std.mem.eql(u8, d.code, "unknown_form")) saw_unknown = true;
        }
        try std.testing.expect(saw_unknown);
    }

    try h.revalidateOpenDocuments();

    // After revalidation, the diagnostic is gone.
    {
        const diags = (try h.getDiagnostics(arena, "file:///a.sjon")).?;
        for (diags) |d| {
            try std.testing.expect(!std.mem.eql(u8, d.code, "unknown_form"));
        }
    }
}

test "expression-function completion stays plain text" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try h.openDocument("file:///a.sjon", 1, "(");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 1)).?;
    const item = findCompletion(items, "+");
    try std.testing.expect(item.insert_text == null);
    try std.testing.expectEqual(CompletionItem.InsertTextFormat.plain_text, item.insert_text_format);
}

test "cross-doc: per-tree default isolates references; same-doc edit updates own diagnostics" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();

    // Schema with phrase + track + cross-ref. Mirrors the conformance
    // case `cross-ref-resolved` so the same shape exercises end-to-end.
    const phrase_name_kind: sjon.Plugin.ValueKind = .{
        .name = "phrase-name",
        .underlying = .symbol,
        .cross_ref = .{ .targets = &.{"phrase"} },
    };
    const phrase_seq_kind: sjon.Plugin.ValueKind = .{
        .name = "phrase-sequence",
        .underlying = .vector,
        .vector = .{ .element = .{ .name = "phrase-name" } },
    };
    const plugin: sjon.Plugin.Plugin = .{
        .name = "audio",
        .value_kinds = &.{ phrase_name_kind, phrase_seq_kind },
        .forms = &.{
            .{
                .name = "phrase",
                .keys = &.{
                    .{ .name = "name", .value_type = .symbol, .optional = false },
                },
            },
            .{
                .name = "track",
                .keys = &.{
                    .{ .name = "sequence", .value_type = .{ .named = .{ .name = "phrase-sequence" } }, .optional = false },
                },
            },
        },
    };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    var arena_state: std.heap.ArenaAllocator = .init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Open both docs separately. Per-tree default: each doc is its own
    // scope, so the track's references to phrases in the other doc do
    // NOT resolve.
    try h.openDocument("file:///phrases.sjon", 1, "(phrase :name p0)\n(phrase :name p1)");
    try h.openDocument("file:///track.sjon", 1, "(track :sequence [p0 p1])");

    {
        const ph_diags = (try h.getDiagnostics(arena, "file:///phrases.sjon")).?;
        try std.testing.expectEqual(@as(usize, 0), ph_diags.len);
        const tr_diags = (try h.getDiagnostics(arena, "file:///track.sjon")).?;
        var saw_not_cross_ref = false;
        for (tr_diags) |d| {
            if (std.mem.eql(u8, d.code, "not_cross_ref")) saw_not_cross_ref = true;
        }
        try std.testing.expect(saw_not_cross_ref);
    }

    // Bundle the references into one document — same scope, resolves.
    try h.changeDocumentFull(
        "file:///track.sjon",
        2,
        "(phrase :name p0)\n(phrase :name p1)\n(track :sequence [p0 p1])",
    );

    {
        _ = arena_state.reset(.retain_capacity);
        const arena2 = arena_state.allocator();
        const tr_diags = (try h.getDiagnostics(arena2, "file:///track.sjon")).?;
        var saw_not_cross_ref = false;
        for (tr_diags) |d| {
            if (std.mem.eql(u8, d.code, "not_cross_ref")) saw_not_cross_ref = true;
        }
        try std.testing.expect(!saw_not_cross_ref);
    }

    // Introduce a typo: the same-doc reference now fails, even though
    // a phrase with that name exists in the other doc (per-tree
    // isolation prevents leaking).
    try h.changeDocumentFull(
        "file:///track.sjon",
        3,
        "(phrase :name p0)\n(phrase :name p1)\n(track :sequence [p0 typoed])",
    );

    {
        _ = arena_state.reset(.retain_capacity);
        const arena3 = arena_state.allocator();
        const tr_diags = (try h.getDiagnostics(arena3, "file:///track.sjon")).?;
        var saw_not_cross_ref = false;
        for (tr_diags) |d| {
            if (std.mem.eql(u8, d.code, "not_cross_ref")) saw_not_cross_ref = true;
        }
        try std.testing.expect(saw_not_cross_ref);
    }

    // Closing one doc removes its phrases from the registry — the
    // track's reference becomes invalid again.
    h.closeDocument("file:///phrases.sjon");
    {
        _ = arena_state.reset(.retain_capacity);
        const arena4 = arena_state.allocator();

        const tr_diags = (try h.getDiagnostics(arena4, "file:///track.sjon")).?;
        var not_cross_ref_count: usize = 0;
        for (tr_diags) |d| {
            if (std.mem.eql(u8, d.code, "not_cross_ref")) not_cross_ref_count += 1;
        }
        try std.testing.expect(not_cross_ref_count >= 1);
    }
}

// ---------------------------------------------------------------------------
// findReferences tests
// ---------------------------------------------------------------------------

test "findReferences: cursor on definition returns def + all references" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // (phrase :name p0)\n(track :sequence [p0 p0])
    //  012345678901234567 8901234567890123456789012
    //            1111111   222222222233333333334
    // `:name p0` is at byte 14; `p0` symbol value at bytes 14-16.
    // First ref `p0` at bytes 36-38; second ref `p0` at bytes 39-41.
    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)\n(track :sequence [p0 p0])");

    const arena = fx.arena();

    // Cursor on definition (byte 15, mid-`p0`).
    const refs = (try h.findReferences(arena, "file:///a.sjon", 15, true)).?;
    try std.testing.expectEqual(@as(usize, 3), refs.len); // def + 2 refs
    for (refs) |r| {
        try std.testing.expectEqualStrings("file:///a.sjon", r.uri);
    }
}

test "findReferences: cursor on a reference returns the same set as cursor on definition" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)\n(track :sequence [p0 p0])");

    var arena_state: std.heap.ArenaAllocator = .init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Cursor on a reference (the first `p0` in [p0 p0], byte 37).
    const refs_from_ref = (try h.findReferences(arena, "file:///a.sjon", 37, true)).?;
    // Cursor on the definition (byte 15).
    _ = arena_state.reset(.retain_capacity);
    const arena2 = arena_state.allocator();
    const refs_from_def = (try h.findReferences(arena2, "file:///a.sjon", 15, true)).?;

    try std.testing.expectEqual(refs_from_def.len, refs_from_ref.len);
}

test "findReferences: include_declaration=false omits the definition" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)\n(track :sequence [p0 p0])");

    const arena = fx.arena();

    const refs = (try h.findReferences(arena, "file:///a.sjon", 15, false)).?;
    try std.testing.expectEqual(@as(usize, 2), refs.len); // refs only
}

test "findReferences: cursor off any symbol returns null" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)\n(track :sequence [p0])");

    const arena = fx.arena();

    // Cursor on whitespace between forms (byte 17 = '\n').
    try std.testing.expect(try h.findReferences(arena, "file:///a.sjon", 17, true) == null);
}

test "findReferences: cursor on unrelated symbol returns null" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `:name` is a kvpair key (not a value), so the symbol value `p0` is
    // the only cross-ref-bearing symbol. The form head `phrase` is also
    // a symbol-shaped node but isn't a cross-ref site.
    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)");

    const arena = fx.arena();

    // Cursor on the form's head identifier (`phrase`, byte 3).
    const refs = try h.findReferences(arena, "file:///a.sjon", 3, true);
    try std.testing.expect(refs == null);
}

// ---------------------------------------------------------------------------
// getDefinition (goto-definition) tests
//
// Byte map shared by the same-document cases:
//   (phrase :name p0)\n(jump :target p0)
//    0123456789...        18...
//   definition name `p0` at 14..16; reference `p0` at 32..34.
// ---------------------------------------------------------------------------

test "getDefinition: cross-ref value jumps to the definition name span" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    const plugin = crossRefDirectPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)\n(jump :target p0)");

    // Cursor mid-reference (byte 33, inside `p0` at 32..34).
    const loc = h.getDefinition("file:///a.sjon", 33).?;
    try std.testing.expectEqualStrings("file:///a.sjon", loc.uri);
    try std.testing.expectEqual(@as(u32, 14), loc.span_start);
    try std.testing.expectEqual(@as(u32, 16), loc.span_end);
}

test "getDefinition: on the definition name returns its own site" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    const plugin = crossRefDirectPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)\n(jump :target p0)");

    // Cursor mid-definition (byte 15). Standard LSP behavior: goto-def on
    // the declaration resolves to itself rather than returning nothing.
    const loc = h.getDefinition("file:///a.sjon", 15).?;
    try std.testing.expectEqualStrings("file:///a.sjon", loc.uri);
    try std.testing.expectEqual(@as(u32, 14), loc.span_start);
    try std.testing.expectEqual(@as(u32, 16), loc.span_end);
}

test "getDefinition: does not cross document scopes (per-tree isolation)" {
    // Cross-ref scopes are per-tree unless a validator overlay shares them
    // (`Validator.Options.share_scope`, which the LSP deliberately does not
    // set — its diagnostics must match CLI behavior byte for byte). A
    // reference in one document therefore never resolves to a definition in
    // another, and goto-definition agrees with the `not_cross_ref`
    // diagnostic the same document already gets.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefDirectPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)");
    try h.openDocument("file:///b.sjon", 1, "(jump :target p0)");

    const arena = fx.arena();

    // Cursor mid-`p0` in b.sjon (bytes 14..16).
    try std.testing.expect(h.getDefinition("file:///b.sjon", 15) == null);

    // …and the reference is diagnosed as unresolved, which is the same
    // story told twice — navigation and diagnostics never disagree.
    var saw_not_cross_ref = false;
    for ((try h.getDiagnostics(arena, "file:///b.sjon")).?) |d| {
        if (std.mem.eql(u8, d.code, "not_cross_ref")) saw_not_cross_ref = true;
    }
    try std.testing.expect(saw_not_cross_ref);
}

test "getDefinition: non-reference position returns null" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    const plugin = crossRefDirectPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)\n(jump :target p0)");

    // Cursor on the form head `phrase` (byte 3) — a symbol, but not a
    // cross-ref site.
    try std.testing.expect(h.getDefinition("file:///a.sjon", 3) == null);
    // Cursor on the newline between the two forms (byte 17) — no symbol.
    try std.testing.expect(h.getDefinition("file:///a.sjon", 17) == null);
}

test "getDefinition: unresolved (typo) reference returns null" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    const plugin = crossRefDirectPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `xyz` names no phrase — the reference is registered but has no
    // definition to jump to.
    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)\n(jump :target xyz)");

    // Cursor mid-`xyz` (bytes 32..35).
    try std.testing.expect(h.getDefinition("file:///a.sjon", 33) == null);
}

// ---------------------------------------------------------------------------
// getDocumentHighlights tests
// ---------------------------------------------------------------------------

test "document highlight lists the cross-ref's occurrences in this document only" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefDirectPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // Both documents define and reference a `p0`. The cross-ref index is
    // forest-wide, so b.sjon's sites are in it too — only the URI filter
    // keeps them out of a.sjon's highlight set.
    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)\n(jump :target p0)");
    try h.openDocument("file:///b.sjon", 1, "(phrase :name p0)\n(jump :target p0)");

    const arena = fx.arena();

    const hls = (try h.getDocumentHighlights(arena, "file:///a.sjon", 33)).?;
    try std.testing.expectEqual(@as(usize, 2), hls.len);
    for (hls) |hl| {
        try std.testing.expect(hl.span_start == 14 or hl.span_start == 32);
    }
}

test "document highlight marks the definition Write and references Read" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefDirectPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)\n(jump :target p0)");

    const arena = fx.arena();

    const hls = (try h.getDocumentHighlights(arena, "file:///a.sjon", 33)).?;
    try std.testing.expectEqual(@as(usize, 2), hls.len);

    var saw_write = false;
    var saw_read = false;
    for (hls) |hl| {
        switch (hl.kind) {
            .write => {
                try std.testing.expectEqual(@as(u32, 14), hl.span_start);
                try std.testing.expectEqual(@as(u32, 16), hl.span_end);
                saw_write = true;
            },
            .read => {
                try std.testing.expectEqual(@as(u32, 32), hl.span_start);
                try std.testing.expectEqual(@as(u32, 34), hl.span_end);
                saw_read = true;
            },
        }
    }
    try std.testing.expect(saw_write);
    try std.testing.expect(saw_read);
}

test "document highlight away from any cross-ref site returns null" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefDirectPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)\n(jump :target p0)");

    const arena = fx.arena();

    // The form head `phrase` (byte 3) and the inter-form newline (17).
    try std.testing.expect(try h.getDocumentHighlights(arena, "file:///a.sjon", 3) == null);
    try std.testing.expect(try h.getDocumentHighlights(arena, "file:///a.sjon", 17) == null);
}

test "document highlight on an unresolved reference still highlights it" {
    // A typo'd reference has no definition, but the symbol under the
    // cursor is still a registered site — highlighting it (alone) is more
    // useful than nothing, and matches what rename/references do.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefDirectPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)\n(jump :target xyz)");

    const arena = fx.arena();

    const hls = (try h.getDocumentHighlights(arena, "file:///a.sjon", 33)).?;
    try std.testing.expectEqual(@as(usize, 1), hls.len);
    try std.testing.expectEqual(@as(u32, 32), hls[0].span_start);
    try std.testing.expectEqual(Handler.Highlight.Kind.read, hls[0].kind);
}

test "prepareRename: returns the symbol's span when on a cross-ref site" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)\n(track :sequence [p0])");

    // Cursor inside `p0` definition (byte 14-16; pick 15).
    const rng = h.prepareRename("file:///a.sjon", 15).?;
    try std.testing.expectEqual(@as(u32, 14), rng.span_start);
    try std.testing.expectEqual(@as(u32, 16), rng.span_end);
}

test "prepareRename: returns null off any cross-ref site" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)");

    // Cursor on the head `phrase` (byte 3) — not a cross-ref site.
    try std.testing.expect(h.prepareRename("file:///a.sjon", 3) == null);
}

test "rename: cursor on definition rewrites def + all references" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)\n(track :sequence [p0 p0])");

    const arena = fx.arena();

    const result = (try h.rename(arena, "file:///a.sjon", 15, "p1")).?;
    switch (result) {
        .err => return error.UnexpectedError,
        .edits => |we| {
            try std.testing.expectEqual(@as(usize, 1), we.changes.len);
            try std.testing.expectEqualStrings("file:///a.sjon", we.changes[0].uri);
            // 1 def + 2 refs.
            try std.testing.expectEqual(@as(usize, 3), we.changes[0].edits.len);
            for (we.changes[0].edits) |e| {
                try std.testing.expectEqualStrings("p1", e.new_text);
            }
        },
    }
}

test "rename: cursor on a reference produces the same edit set" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)\n(track :sequence [p0 p0])");

    const arena = fx.arena();

    // Cursor on the first `p0` reference inside `[p0 p0]` (byte 37).
    const result = (try h.rename(arena, "file:///a.sjon", 37, "p1")).?;
    switch (result) {
        .err => return error.UnexpectedError,
        .edits => |we| try std.testing.expectEqual(@as(usize, 3), we.changes[0].edits.len),
    }
}

test "rename: collision in same scope returns RenameError" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)\n(phrase :name p1)");

    const arena = fx.arena();

    const result = (try h.rename(arena, "file:///a.sjon", 15, "p1")).?;
    switch (result) {
        .err => |e| try std.testing.expect(std.mem.indexOf(u8, e.message, "p1") != null),
        .edits => return error.UnexpectedSuccess,
    }
}

test "rename: same-name rename is a no-op edit set, not an error" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)\n(track :sequence [p0])");

    const arena = fx.arena();

    // Renaming `p0` to `p0` — collision check skipped, edit set is the
    // def + all refs (each replaced with the same text). The net effect
    // is a no-op, but we don't special-case it.
    const result = (try h.rename(arena, "file:///a.sjon", 15, "p0")).?;
    switch (result) {
        .err => return error.UnexpectedError,
        .edits => |we| {
            try std.testing.expectEqual(@as(usize, 1), we.changes.len);
            // 1 def + 1 ref = 2 edits, all "p0".
            try std.testing.expectEqual(@as(usize, 2), we.changes[0].edits.len);
        },
    }
}

// ---------------------------------------------------------------------------
// Cross-ref value completions
// ---------------------------------------------------------------------------

test "cross-ref completion: lists registered names in scope" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefDirectPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // Two phrases registered; `(jump :target )` opens a cross-ref value
    // slot. Cursor sits right before the closing paren (byte index
    // chosen so it's unambiguously inside the form span).
    //
    // (phrase :name p0)
    // (phrase :name p1)
    // (jump :target )
    //  0         1
    //  012345678901234
    try h.openDocument(
        "file:///a.sjon",
        1,
        "(phrase :name p0)\n(phrase :name p1)\n(jump :target )",
    );

    const arena = fx.arena();

    // Cursor at the space between `:target` and `)`.
    const items = (try h.getCompletion(arena, "file:///a.sjon", 50)).?;
    try std.testing.expectEqual(@as(usize, 2), items.len);

    var saw_p0 = false;
    var saw_p1 = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "p0")) saw_p0 = true;
        if (std.mem.eql(u8, it.label, "p1")) saw_p1 = true;
        try std.testing.expectEqual(CompletionItem.Kind.enum_member, it.kind);
        try std.testing.expect(std.mem.indexOf(u8, it.detail, "audio/phrase") != null);
    }
    try std.testing.expect(saw_p0 and saw_p1);
}

test "cross-ref completion: typed prefix still returns the full list" {
    // Client-side filtering: the server returns every candidate and the
    // editor narrows by prefix. Mid-edit on a typo should still see the
    // valid names so the user can accept one.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefDirectPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // (phrase :name alpha)
    // (phrase :name beta)
    // (jump :target xyz)
    try h.openDocument(
        "file:///a.sjon",
        1,
        "(phrase :name alpha)\n(phrase :name beta)\n(jump :target xyz)",
    );

    const arena = fx.arena();

    // Cursor sits inside `xyz` (byte 56, mid-symbol). Server returns the
    // full set; editor filters by `xyz` prefix client-side.
    const items = (try h.getCompletion(arena, "file:///a.sjon", 56)).?;
    try std.testing.expectEqual(@as(usize, 2), items.len);
}

test "cross-ref completion: empty when cross_ref_index has no entries" {
    // No phrase forms registered → the index has no names under
    // `audio/phrase` for the tree scope. Completion returns empty
    // (not null — the cursor IS in a kvpair-value context).
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefDirectPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(jump :target )");

    const arena = fx.arena();

    // Cursor between `:target ` and `)` (byte 14).
    const items = (try h.getCompletion(arena, "file:///a.sjon", 14)).?;
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "cross-ref completion: defining form's own name is filtered out" {
    // The form being edited IS a `phrase` (target form). Its `:name`
    // value is the symbol the user is defining — suggesting it as a
    // `:related` value would be self-referential noise.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefDirectPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // (phrase :name p0)\n(phrase :name p1 :related )
    //  Second form bytes: `(` at 18, `:related` at 35..42, ` ` at 43,
    //  `)` at 44 (length 45). Cursor 44 = just before `)`.
    try h.openDocument(
        "file:///a.sjon",
        1,
        "(phrase :name p0)\n(phrase :name p1 :related )",
    );

    const arena = fx.arena();

    // Only `p0` should appear — `p1` is the form's own name and gets
    // filtered to avoid self-referential suggestions.
    const items = (try h.getCompletion(arena, "file:///a.sjon", 44)).?;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("p0", items[0].label);
}

test "cross-ref completion: empty when target form doesn't resolve" {
    // `target_form` points at `unknown-form` which no plugin defines.
    // The canonicalisation step fails → completion returns empty.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const ghost_kind: sjon.Plugin.ValueKind = .{
        .name = "ghost-name",
        .underlying = .symbol,
        .cross_ref = .{ .targets = &.{"unknown-form"} },
    };
    const plugin: sjon.Plugin.Plugin = .{
        .name = "ghost",
        .value_kinds = &.{ghost_kind},
        .forms = &.{
            .{
                .name = "summon",
                .keys = &.{
                    .{ .name = "who", .value_type = .{ .named = .{ .name = "ghost-name" } }, .optional = false },
                },
            },
        },
    };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(summon :who )");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 13)).?;
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

// ---------------------------------------------------------------------------
// Provider-backed cross-refs through the Handler.
//
// The names these tests navigate exist nowhere in the document's own
// syntax — they are inside an opaque string, and only the extraction
// pre-pass `revalidateForest` runs can see them. So each of these is a
// statement about the pre-pass having run, phrased through whichever read
// feature would go quiet without it.
//
// Native `:impl` on purpose. The route under test is the Handler's
// pre-pass, not wasmtime, and `ProviderExtraction` prefers a native impl
// over any invoker — so these drive the seam on every build, including
// `-Dplugin-exec=false`, with no runtime and no sidecar.
// ---------------------------------------------------------------------------

/// Provider-route twin of `crossRefDirectPlugin`. A `(shader …)` carries
/// an opaque `:src` blob; the member set comes out of it one non-empty
/// line at a time, rather than off a `:name` key.
fn providerCrossRefPlugin() sjon.Plugin.Plugin {
    const Lines = struct {
        fn extract(
            a: std.mem.Allocator,
            source: []const u8,
        ) sjon.Plugin.CrossRefProvider.ExtractError![]const []const u8 {
            var out: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, source, '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                try out.append(a, line);
            }
            return out.items;
        }
    };
    return .{
        .name = "glsl",
        .cross_ref_providers = &.{.{ .name = "lines", .impl = Lines.extract }},
        .value_kinds = &.{.{
            .name = "uniform-name",
            .underlying = .symbol,
            .cross_ref = .{ .targets = &.{"shader"}, .provider = "lines" },
        }},
        .forms = &.{
            .{
                .name = "shader",
                .keys = &.{
                    .{ .name = "name", .value_type = .symbol, .optional = false },
                    .{ .name = "src", .value_type = .string, .optional = false },
                },
            },
            .{
                .name = "bind",
                .keys = &.{
                    .{ .name = "uniform", .value_type = .{ .named = .{ .name = "uniform-name" } }, .optional = false },
                },
            },
        },
    };
}

/// Same schema with the extractor removed — a provider that is declared
/// and cannot run, which is what every host without executable-plugin
/// support looks like from the validator's side.
fn providerCrossRefPluginUnrunnable() sjon.Plugin.Plugin {
    var p = providerCrossRefPlugin();
    p.cross_ref_providers = &.{.{ .name = "lines" }};
    return p;
}

test "provider cross-ref: completion offers names the pre-pass extracted" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ providerCrossRefPlugin(), sjon.plugins.core.plugin });

    // Neither `u_time` nor `u_res` appears as a symbol anywhere: they are
    // two lines inside the `:src` string. Without the pre-pass the bucket
    // poisons and this list is empty.
    const src = "(shader :name main :src \"u_time\\nu_res\")\n(bind :uniform )";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();
    const cursor: u32 = @intCast(std.mem.lastIndexOfScalar(u8, src, ')').?);
    const items = (try h.getCompletion(arena, "file:///a.sjon", cursor)).?;

    try std.testing.expectEqual(@as(usize, 2), items.len);
    var saw_time = false;
    var saw_res = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "u_time")) saw_time = true;
        if (std.mem.eql(u8, it.label, "u_res")) saw_res = true;
        try std.testing.expectEqual(CompletionItem.Kind.enum_member, it.kind);
        try std.testing.expect(std.mem.indexOf(u8, it.detail, "glsl/shader") != null);
    }
    try std.testing.expect(saw_time and saw_res);
}

test "provider cross-ref: goto-def lands on the whole source string" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ providerCrossRefPlugin(), sjon.plugins.core.plugin });

    const src =
        "(shader :name main :src \"u_time\\nu_res\")\n" ++
        "(bind :uniform u_time)\n" ++
        "(bind :uniform u_res)";
    try h.openDocument("file:///a.sjon", 1, src);

    const time_ref: u32 = @intCast(std.mem.indexOf(u8, src, "u_time)").?);
    const res_ref: u32 = @intCast(std.mem.indexOf(u8, src, "u_res)").?);

    const to_time = h.getDefinition("file:///a.sjon", time_ref).?;
    const to_res = h.getDefinition("file:///a.sjon", res_ref).?;

    // The v1 definition semantic, stated as sharply as it can be: both
    // names land on the *same* span, because a provider returns names and
    // not offsets, so the finest anchor available is the string it read.
    // Per-name sub-spans would need an additive extension to the
    // extraction result shape — a deliberate non-goal, not an oversight.
    try std.testing.expectEqualStrings("file:///a.sjon", to_time.uri);
    try std.testing.expectEqual(to_time.span_start, to_res.span_start);
    try std.testing.expectEqual(to_time.span_end, to_res.span_end);

    const anchored = src[to_time.span_start..to_time.span_end];
    try std.testing.expect(std.mem.indexOf(u8, anchored, "u_time") != null);
    try std.testing.expect(std.mem.indexOf(u8, anchored, "u_res") != null);
}

test "provider cross-ref: a typo's quick fix ranks extracted candidates" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ providerCrossRefPlugin(), sjon.plugins.core.plugin });

    // `u_tim` is Levenshtein 1 from `u_time` — a name that only exists
    // because the provider found it, reached through the same DidYouMean
    // path a syntactically-visible target would use.
    const src = "(shader :name main :src \"u_time\\nu_res\")\n(bind :uniform u_tim)";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();
    const bad_start: u32 = @intCast(std.mem.indexOf(u8, src, "u_tim)").?);
    const actions = (try h.getCodeActions(arena, "file:///a.sjon", bad_start, bad_start + 5)).?;

    try std.testing.expectEqual(@as(usize, 1), actions.len);
    const act = actions[0];
    try std.testing.expectEqualStrings("not_cross_ref", act.diagnostics[0].code);
    try std.testing.expectEqual(@as(usize, 1), act.edits.len);
    try std.testing.expectEqualStrings("u_time", act.edits[0].new_text);
    try std.testing.expectEqual(bad_start, act.edits[0].span_start);
    try std.testing.expectEqual(bad_start + 5, act.edits[0].span_end);
}

test "provider cross-ref: every open document is extracted, and scope still isolates" {
    // The pre-pass walks the whole forest, not the document being asked
    // about — so the second file's shader is extracted too, and a
    // registry that only ever saw tree 0 would poison it.
    //
    // Scope is the other half: extracted names are ordinary members of an
    // ordinary bucket, so the LSP's per-tree default isolates them exactly
    // as it isolates a name read off a `:name` key. Both facts have to
    // hold at once, which is why they are one test.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ providerCrossRefPlugin(), sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(shader :name a :src \"u_a\")\n(bind :uniform u_a)");
    try h.openDocument(
        "file:///b.sjon",
        1,
        "(shader :name b :src \"u_b\")\n(bind :uniform u_b)\n(bind :uniform u_a)",
    );

    const arena = fx.arena();
    const a_diags = (try h.getDiagnostics(arena, "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 0), a_diags.len);

    const b_diags = (try h.getDiagnostics(arena, "file:///b.sjon")).?;
    try std.testing.expectEqual(@as(usize, 1), b_diags.len);
    try std.testing.expectEqualStrings("not_cross_ref", b_diags[0].code);
    try std.testing.expect(std.mem.indexOf(u8, b_diags[0].message, "u_a") != null);
}

test "provider cross-ref: a provider that cannot run is loud, not silent" {
    // The degradation every host without executable-plugin support gets,
    // pinned on a build that has it: the bucket poisons, the source site
    // says why once, and the references stay quiet rather than each
    // reporting an unresolvable name.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ providerCrossRefPluginUnrunnable(), sjon.plugins.core.plugin });

    const src = "(shader :name main :src \"u_time\\nu_res\")\n(bind :uniform u_time)";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();
    const diags = (try h.getDiagnostics(arena, "file:///a.sjon")).?;

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("cross_ref_provider_unavailable", diags[0].code);
}

/// The declaration-only half of the corpus's provider pair: a manifest
/// whose `(cross-ref-provider …)` ships no `:impl` and no sidecar, so no
/// host can extract from it whatever its runtime support.
///
/// Inlined rather than read off disk because the two tests below install
/// it *alongside* a project that resolved a different plugin's wasm —
/// the point is a session that can run providers meeting one it cannot,
/// which no single fixture directory expresses.
const ghost_provider_schema =
    \\(plugin :name ghost :version "1.0.0" :sjon "1.2"
    \\  (cross-ref-provider :name lines)
    \\  (form :name shader
    \\    (key :name name :type symbol :optional false)
    \\    (key :name src :type string :optional false))
    \\  (value-kind :name uniform-name
    \\    :underlying symbol
    \\    :cross-ref (cross-ref :target shader :provider lines))
    \\  (form :name bind
    \\    (key :name uniform :type uniform-name :optional false)))
;

test "provider cross-ref: a session that cannot run providers hints instead of erroring" {
    // The playground's permanent condition, driven through a project that
    // reaches it the same way the artifact does — `lines.sjon` declares a
    // provider and ships no `lines.wasm`, so no runtime is built and the
    // names in `:src` are unchecked rather than wrong.
    //
    // Red squiggles on correct source, forever, on every file that uses a
    // provider-backed vocabulary, is how an editor teaches people to stop
    // reading its diagnostics. So the *rendering* drops to a hint while
    // the diagnostic itself — code, span, message, docs link — stays whole.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try h.loadProject(std.testing.io, "conformance/cases/cross-ref-provider-unavailable");
    // The premise, asserted rather than assumed: this session holds no
    // runtime, which is what the downgrade is keyed on.
    try std.testing.expect(h.getProjectInfo().?.runtimeContext() == null);

    // No `(use-plugin "lines")` header: the LSP composes its vocabulary
    // from the project and the open schema panes, and validates the
    // document's forest directly rather than through `Host.partition`,
    // which is what strips plugin references on the document path.
    const src =
        \\(shader :name main :src "u_time")
        \\(bind :uniform u_time)
    ;
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();
    const diags = (try h.getDiagnostics(arena, "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("cross_ref_provider_unavailable", diags[0].code);
    try std.testing.expectEqual(Handler.Severity.hint, diags[0].severity);
    // Presentational and nothing more: the validator's own grading is
    // untouched, so the corpus expectation and every non-editor consumer
    // still see the error the wire format promises.
    const cached = h.getDocument("file:///a.sjon").?.validate_result.diagnostics;
    try std.testing.expectEqual(@as(usize, 1), cached.len);
    try std.testing.expectEqual(sjon.Ast.Diagnostic.Severity.err, cached[0].severity);

    // The project report is served by a path that never calls `translate`
    // (`main.zig`'s project-file branch renders `Host.HostDiagnostic`
    // directly), so a code that reached it would render as an error no
    // matter what this layer decided. It does not: the code is emitted by
    // the cross-ref index pass over *documents*, and manifest loading has
    // no occasion for it.
    for (h.getProjectInfo().?.diagnostics) |d| {
        try std.testing.expect(d.code != .cross_ref_provider_unavailable);
    }
}

test "provider cross-ref: a session that can run providers keeps the error" {
    // The other side of the same key. `-Dplugin-exec` only decides whether
    // the *fixture* can put a runtime on the session; the Handler still
    // reads capability, not target, so this skips rather than asserting
    // something the build cannot produce.
    if (!build_options.plugin_exec) return;
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const arena = fx.arena();

    // Capability from the project (its `lines.wasm` registers), vocabulary
    // from an editor pane. `setUserSchemas` recomposes the schema as core
    // + the panes and leaves the project — hence the runtime — in place,
    // which is the one arrangement where a session that demonstrably *can*
    // run providers meets one it has no module for.
    try h.loadProject(std.testing.io, "conformance/cases/cross-ref-provider-resolved");
    try std.testing.expect(h.getProjectInfo().?.runtimeContext() != null);
    _ = try h.setUserSchemas(arena, &[_]Handler.SchemaSource{
        .{ .uri = "inmemory://schema/1.sjon", .text = ghost_provider_schema },
    });

    const src =
        \\(shader :name main :src "u_time")
        \\(bind :uniform u_time)
    ;
    try h.openDocument("file:///a.sjon", 1, src);

    const diags = (try h.getDiagnostics(arena, "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("cross_ref_provider_unavailable", diags[0].code);
    // Not downgraded: this host could have run the provider, so a provider
    // it could not find is a fact about the workspace and stays an error.
    try std.testing.expectEqual(Handler.Severity.err, diags[0].severity);
}

// ---------------------------------------------------------------------------
// Provider-route navigation and write features. The tests above prove
// the extracted names are *reachable*; these pin what each feature does
// with a name whose defining occurrence is bytes inside an opaque
// string. Read features (references, highlight, symbols, tokens) treat
// the source literal as the declaration, mirroring goto-definition.
// Write features (rename) refuse: the identity-route edit set would
// replace the whole source string with the new name.
// ---------------------------------------------------------------------------

test "provider cross-ref: rename refuses — the definition lives in opaque content" {
    // The def Site a provider registers spans the *entire source
    // literal* (a provider returns names, not offsets). Rename's edit
    // set is def + references, so going ahead here would emit an edit
    // replacing `"u_time\nu_res"` with `u_delta` — destroying the
    // shader. The only correct answer is a refusal that says why.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ providerCrossRefPlugin(), sjon.plugins.core.plugin });

    const src = "(shader :name main :src \"u_time\\nu_res\")\n(bind :uniform u_time)";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();
    const ref_at: u32 = @intCast(std.mem.indexOf(u8, src, "u_time)").?);

    const result = (try h.rename(arena, "file:///a.sjon", ref_at, "u_delta")).?;
    switch (result) {
        .err => |e| {
            try std.testing.expect(std.mem.indexOf(u8, e.message, "u_time") != null);
            try std.testing.expect(std.mem.indexOf(u8, e.message, "lines") != null);
        },
        .edits => return error.UnexpectedSuccess,
    }
}

test "provider cross-ref: prepareRename declines the site" {
    // The polite half of the refusal: a client that honours prepareRename
    // never opens a rename prompt the request above would have to reject.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ providerCrossRefPlugin(), sjon.plugins.core.plugin });

    const src = "(shader :name main :src \"u_time\\nu_res\")\n(bind :uniform u_time)";
    try h.openDocument("file:///a.sjon", 1, src);

    const ref_at: u32 = @intCast(std.mem.indexOf(u8, src, "u_time)").?);
    try std.testing.expect(h.prepareRename("file:///a.sjon", ref_at) == null);
}

test "provider cross-ref: references list the source string as the declaration" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ providerCrossRefPlugin(), sjon.plugins.core.plugin });

    const src =
        "(shader :name main :src \"u_time\\nu_res\")\n" ++
        "(bind :uniform u_time)\n" ++
        "(bind :uniform u_time)";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();
    const ref_at: u32 = @intCast(std.mem.indexOf(u8, src, "u_time)").?);
    const locs = (try h.findReferences(arena, "file:///a.sjon", ref_at, true)).?;

    // Declaration first (the source literal), then both uses in order.
    try std.testing.expectEqual(@as(usize, 3), locs.len);
    const decl = src[locs[0].span_start..locs[0].span_end];
    try std.testing.expect(std.mem.indexOf(u8, decl, "u_time") != null);
    try std.testing.expect(std.mem.indexOf(u8, decl, "u_res") != null);
    for (locs[1..]) |loc| {
        try std.testing.expectEqualStrings("u_time", src[loc.span_start..loc.span_end]);
    }
}

test "provider cross-ref: document highlight marks the source string as the write site" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ providerCrossRefPlugin(), sjon.plugins.core.plugin });

    const src =
        "(shader :name main :src \"u_time\\nu_res\")\n" ++
        "(bind :uniform u_time)\n" ++
        "(bind :uniform u_time)";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();
    const ref_at: u32 = @intCast(std.mem.indexOf(u8, src, "u_time)").?);
    const hls = (try h.getDocumentHighlights(arena, "file:///a.sjon", ref_at)).?;

    try std.testing.expectEqual(@as(usize, 3), hls.len);
    try std.testing.expectEqual(Handler.Highlight.Kind.write, hls[0].kind);
    const decl = src[hls[0].span_start..hls[0].span_end];
    try std.testing.expect(std.mem.indexOf(u8, decl, "u_res") != null);
    for (hls[1..]) |hl| {
        try std.testing.expectEqual(Handler.Highlight.Kind.read, hl.kind);
        try std.testing.expectEqualStrings("u_time", src[hl.span_start..hl.span_end]);
    }
}

test "provider cross-ref: workspace symbols surface extracted names" {
    // A name only a provider ever saw is still a definition someone will
    // want to jump to from the symbol picker. Both extracted names list,
    // anchored at the source literal, containered by the target form.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ providerCrossRefPlugin(), sjon.plugins.core.plugin });

    const src = "(shader :name main :src \"u_time\\nu_res\")";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();
    const syms = try h.getWorkspaceSymbols(arena, "u_");

    try std.testing.expectEqual(@as(usize, 2), syms.len);
    // Sorted by name: `u_res` before `u_time`.
    try std.testing.expectEqualStrings("u_res", syms[0].name);
    try std.testing.expectEqualStrings("u_time", syms[1].name);
    for (syms) |s| {
        try std.testing.expectEqualStrings("glsl/shader", s.container_name);
        const at = src[s.location.span_start..s.location.span_end];
        try std.testing.expect(std.mem.indexOf(u8, at, "u_res") != null);
    }
}

test "provider cross-ref: semantic tokens colour the reference, not the source string" {
    // One `u_time` token: the reference symbol, coloured like any
    // cross-ref use and *not* marked declaration — the declaration mod
    // belongs to a defining symbol, and this route has none. The string
    // keeps whatever colour strings get; no token lands mid-literal.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ providerCrossRefPlugin(), sjon.plugins.core.plugin });

    const src = "(shader :name main :src \"u_time\\nu_res\")\n(bind :uniform u_time)";
    try h.openDocument("file:///a.sjon", 1, src);

    const toks = (try h.getSemanticTokens(fx.arena(), "file:///a.sjon")).?;
    var seen: usize = 0;
    for (toks) |t| {
        if (!std.mem.eql(u8, tokText(src, t), "u_time")) continue;
        seen += 1;
        try std.testing.expectEqual(Handler.SemanticToken.Type.variable, t.type);
        try std.testing.expect(!t.mods.declaration);
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
}

// ---------------------------------------------------------------------------
// Cross-ref hover, both routes. A cross-ref kind used to render no
// hover at all — the member-value renderer required `kind.members`, and
// the constraint summary had no cross-ref arm — so hovering a reference
// taught nothing about what it references.
// ---------------------------------------------------------------------------

test "hover on an identity cross-ref value names its target" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ crossRefDirectPlugin(), sjon.plugins.core.plugin });

    const src = "(phrase :name p0)\n(jump :target p0)";
    try h.openDocument("file:///a.sjon", 1, src);

    const at: u32 = @intCast(std.mem.lastIndexOf(u8, src, "p0").?);
    const hv = (try h.getHover(fx.arena(), "file:///a.sjon", at)).?;

    try std.testing.expect(std.mem.indexOf(u8, hv.contents, "p0") != null);
    try std.testing.expect(std.mem.indexOf(u8, hv.contents, "phrase-name") != null);
    try std.testing.expect(std.mem.indexOf(u8, hv.contents, "(phrase") != null);
    // Names the key the member set is drawn from — the same rule the
    // `not_cross_ref` message follows.
    try std.testing.expect(std.mem.indexOf(u8, hv.contents, ":name") != null);
}

test "provider cross-ref: hover on a reference names the extraction" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ providerCrossRefPlugin(), sjon.plugins.core.plugin });

    const src = "(shader :name main :src \"u_time\\nu_res\")\n(bind :uniform u_time)";
    try h.openDocument("file:///a.sjon", 1, src);

    const at: u32 = @intCast(std.mem.indexOf(u8, src, "u_time)").?);
    const hv = (try h.getHover(fx.arena(), "file:///a.sjon", at)).?;

    try std.testing.expect(std.mem.indexOf(u8, hv.contents, "uniform-name") != null);
    try std.testing.expect(std.mem.indexOf(u8, hv.contents, "(shader") != null);
    try std.testing.expect(std.mem.indexOf(u8, hv.contents, ":src") != null);
    try std.testing.expect(std.mem.indexOf(u8, hv.contents, "lines") != null);
}

test "key hover renders cross-ref facts, scope included" {
    // The scoped plugin pins all three identity-route facts at once:
    // target form, the key names are drawn from, and the scope rule.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ crossRefScopedPlugin(), sjon.plugins.core.plugin });

    const src = "(piece (phrase :name p0) (jump :target p0))";
    try h.openDocument("file:///a.sjon", 1, src);

    const at: u32 = @intCast(std.mem.indexOf(u8, src, ":target").?);
    const hv = (try h.getHover(fx.arena(), "file:///a.sjon", at)).?;

    try std.testing.expect(std.mem.indexOf(u8, hv.contents, "cross-ref to") != null);
    try std.testing.expect(std.mem.indexOf(u8, hv.contents, "(phrase") != null);
    try std.testing.expect(std.mem.indexOf(u8, hv.contents, ":name") != null);
    try std.testing.expect(std.mem.indexOf(u8, hv.contents, "(piece") != null);
}

test "key hover renders provider cross-ref facts" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ providerCrossRefPlugin(), sjon.plugins.core.plugin });

    const src = "(shader :name main :src \"u_time\")\n(bind :uniform u_time)";
    try h.openDocument("file:///a.sjon", 1, src);

    const at: u32 = @intCast(std.mem.indexOf(u8, src, ":uniform").?);
    const hv = (try h.getHover(fx.arena(), "file:///a.sjon", at)).?;

    try std.testing.expect(std.mem.indexOf(u8, hv.contents, "cross-ref to") != null);
    try std.testing.expect(std.mem.indexOf(u8, hv.contents, "(shader") != null);
    try std.testing.expect(std.mem.indexOf(u8, hv.contents, "lines") != null);
    try std.testing.expect(std.mem.indexOf(u8, hv.contents, ":src") != null);
}

// ---------------------------------------------------------------------------
// Lexical-scope-aware cross-ref completions: `scope_form` constrains
// candidates to the nearest enclosing scope-opening form instance.
// Mirrors the validator's `findNearestScope` rule so the LSP can't
// suggest a name the validator would then reject.
// ---------------------------------------------------------------------------

/// Schema with `scope_form = piece`: phrase definitions register under
/// the enclosing piece, references resolve only within that piece.
/// `piece` allows positional children (so phrases and tracks nest) and
/// a `:extras` kvpair so the "scope IS the enclosing form itself" case
/// has a vector slot to land in.
fn crossRefScopedPlugin() sjon.Plugin.Plugin {
    const phrase_name_kind: sjon.Plugin.ValueKind = .{
        .name = "phrase-name",
        .underlying = .symbol,
        .cross_ref = .{ .targets = &.{"phrase"}, .scope_form = "piece" },
    };
    const phrase_seq_kind: sjon.Plugin.ValueKind = .{
        .name = "phrase-sequence",
        .underlying = .vector,
        .vector = .{ .element = .{ .name = "phrase-name" } },
    };
    return .{
        .name = "audio",
        .value_kinds = &.{ phrase_name_kind, phrase_seq_kind },
        .forms = &.{
            .{
                .name = "phrase",
                .keys = &.{
                    .{ .name = "name", .value_type = .symbol, .optional = false },
                    .{ .name = "related", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = true },
                },
            },
            .{
                .name = "jump",
                .keys = &.{
                    .{ .name = "target", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = false },
                },
            },
            .{
                .name = "track",
                .keys = &.{
                    .{ .name = "sequence", .value_type = .{ .named = .{ .name = "phrase-sequence" } }, .optional = false },
                },
            },
            .{
                .name = "piece",
                .positional = .any,
                .keys = &.{
                    .{ .name = "extras", .value_type = .{ .named = .{ .name = "phrase-sequence" } }, .optional = true },
                },
            },
        },
    };
}

test "scoped cross-ref completion: only names from the enclosing piece" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefScopedPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // (piece (phrase :name p0) (phrase :name p1) (jump :target ))
    //  byte 0 ......................................... byte 57 = `)` of jump.
    try h.openDocument(
        "file:///a.sjon",
        1,
        "(piece (phrase :name p0) (phrase :name p1) (jump :target ))",
    );

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 57)).?;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    var saw_p0 = false;
    var saw_p1 = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "p0")) saw_p0 = true;
        if (std.mem.eql(u8, it.label, "p1")) saw_p1 = true;
    }
    try std.testing.expect(saw_p0 and saw_p1);
}

test "scoped cross-ref completion: sibling pieces don't bleed" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefScopedPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // (piece (phrase :name p0)) (piece (phrase :name q0) (jump :target ))
    //  first piece bytes 0..24, second piece bytes 26..66, `)` of jump at 65.
    try h.openDocument(
        "file:///a.sjon",
        1,
        "(piece (phrase :name p0)) (piece (phrase :name q0) (jump :target ))",
    );

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 65)).?;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("q0", items[0].label);
}

test "scoped cross-ref completion: nested pieces — innermost wins" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefScopedPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // (piece (phrase :name outer) (piece (phrase :name inner) (jump :target )))
    //  outer phrase at bytes 7..26; inner piece at bytes 28..71; jump `)` at 70.
    try h.openDocument(
        "file:///a.sjon",
        1,
        "(piece (phrase :name outer) (piece (phrase :name inner) (jump :target )))",
    );

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 70)).?;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("inner", items[0].label);
}

test "scoped cross-ref completion: outside any scope returns empty" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefScopedPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // Top-level jump, no enclosing piece. Even if phrases existed
    // elsewhere they wouldn't bleed in — but here there are none, so
    // the test isolates the "no matching ancestor" branch.
    try h.openDocument("file:///a.sjon", 1, "(jump :target )");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 14)).?;
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "scoped cross-ref completion: enclosing form IS the scope-opener" {
    // `:extras` is a kvpair on `piece` itself whose value is a
    // `phrase-sequence` vector (element kind is the scoped phrase-name).
    // Cursor in the vector → enclosing_form_idx is piece → walker
    // matches at step 0 (the inclusive walk) and queries piece's scope.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefScopedPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // (piece (phrase :name p0) :extras [])
    //  phrase at 7..23; `:extras [` at 25..33; cursor 34 = `]`, inside vector.
    try h.openDocument(
        "file:///a.sjon",
        1,
        "(piece (phrase :name p0) :extras [])",
    );

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 34)).?;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("p0", items[0].label);
}

test "scoped cross-ref completion: defining form's own name is still filtered" {
    // Scoped completion must keep the self-name filter from the
    // unscoped path: a phrase under construction shouldn't suggest
    // itself as a `:related` target.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefScopedPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // (piece (phrase :name p0) (phrase :name p1 :related ))
    //  second phrase at bytes 25..51; cursor 51 = `)`, sits in `:related` slot.
    try h.openDocument(
        "file:///a.sjon",
        1,
        "(piece (phrase :name p0) (phrase :name p1 :related ))",
    );

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 51)).?;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("p0", items[0].label);
}

test "scoped cross-ref completion: vector element honours the scope rule" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefScopedPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // (piece (phrase :name p0) (phrase :name p1) (track :sequence [])) (piece (phrase :name q0))
    //  first piece bytes 0..63; inside its track vector at byte 60 = `[`.
    try h.openDocument(
        "file:///a.sjon",
        1,
        "(piece (phrase :name p0) (phrase :name p1) (track :sequence [])) (piece (phrase :name q0))",
    );

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 60)).?;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    var saw_p0 = false;
    var saw_p1 = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "p0")) saw_p0 = true;
        if (std.mem.eql(u8, it.label, "p1")) saw_p1 = true;
        try std.testing.expect(!std.mem.eql(u8, it.label, "q0"));
    }
    try std.testing.expect(saw_p0 and saw_p1);
}

test "scoped cross-ref completion: scope_form that doesn't resolve returns empty" {
    // Plugin declares `scope_form = "phantom"` but no plugin defines a
    // `phantom` form. Canonicalisation fails → empty list (matches the
    // validator path which also can't key off an unresolvable scope).
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const phantom_name_kind: sjon.Plugin.ValueKind = .{
        .name = "phrase-name",
        .underlying = .symbol,
        .cross_ref = .{ .targets = &.{"phrase"}, .scope_form = "phantom" },
    };
    const plugin: sjon.Plugin.Plugin = .{
        .name = "audio",
        .value_kinds = &.{phantom_name_kind},
        .forms = &.{
            .{
                .name = "phrase",
                .keys = &.{
                    .{ .name = "name", .value_type = .symbol, .optional = false },
                },
            },
            .{
                .name = "jump",
                .keys = &.{
                    .{ .name = "target", .value_type = .{ .named = .{ .name = "phrase-name" } }, .optional = false },
                },
            },
        },
    };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument(
        "file:///a.sjon",
        1,
        "(phrase :name p0)\n(jump :target )",
    );

    const arena = fx.arena();

    // Cursor inside jump's `:target ` slot. Byte 32 = `)` of jump.
    const items = (try h.getCompletion(arena, "file:///a.sjon", 32)).?;
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

// ---------------------------------------------------------------------------
// Number-with-unit suffix completion: when a kvpair's value-kind has
// `.number` underlying + `unit.allowed` declared, cursor at the end of a
// bare numeric literal gets one item per allowed suffix.
// ---------------------------------------------------------------------------

/// Schema where `:duration` accepts `120ms / 90s / 5min` and `:durations`
/// is a vector of the same kind. `:name` is plain string so the wrong-
/// kvpair regression has a non-numeric slot to land on.
fn numberWithUnitPlugin() sjon.Plugin.Plugin {
    const duration_kind: sjon.Plugin.ValueKind = .{
        .name = "duration",
        .underlying = .number,
        .unit = .{ .allowed = &.{ "ms", "s", "min" } },
    };
    const duration_vec_kind: sjon.Plugin.ValueKind = .{
        .name = "duration-vector",
        .underlying = .vector,
        .vector = .{ .element = .{ .name = "duration" } },
    };
    return .{
        .name = "metro",
        .value_kinds = &.{ duration_kind, duration_vec_kind },
        .forms = &.{
            .{
                .name = "timer",
                .keys = &.{
                    .{ .name = "duration", .value_type = .{ .named = .{ .name = "duration" } }, .optional = true },
                    .{ .name = "durations", .value_type = .{ .named = .{ .name = "duration-vector" } }, .optional = true },
                    .{ .name = "name", .value_type = .string, .optional = true },
                },
            },
        },
    };
}

test "unit completion: happy path — bare number at end of value" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = numberWithUnitPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `(timer :duration 120)` — len 21, cursor 20 = right after `0`.
    try h.openDocument("file:///a.sjon", 1, "(timer :duration 120)");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 20)).?;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    const ms = findCompletion(items, "ms");
    try std.testing.expectEqual(CompletionItem.Kind.enum_member, ms.kind);
    try std.testing.expectEqualSlices(u8, "unit suffix", ms.detail);
    try std.testing.expectEqualSlices(u8, "ms", ms.insert_text.?);
    _ = findCompletion(items, "s");
    _ = findCompletion(items, "min");
}

test "unit completion: fires at EOF inside an unclosed form" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = numberWithUnitPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `(timer :duration 120` — no closing paren, cursor at EOF (byte 20).
    // The unit-suffix path requires the cursor exactly at the end of the
    // bare number, which while typing is almost always also EOF.
    try h.openDocument("file:///a.sjon", 1, "(timer :duration 120");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 20)).?;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    _ = findCompletion(items, "ms");
    _ = findCompletion(items, "s");
    _ = findCompletion(items, "min");
}

test "unit completion: allowed list of one yields a single item" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const duration_kind: sjon.Plugin.ValueKind = .{
        .name = "duration",
        .underlying = .number,
        .unit = .{ .allowed = &.{"ms"} },
    };
    const plugin: sjon.Plugin.Plugin = .{
        .name = "metro",
        .value_kinds = &.{duration_kind},
        .forms = &.{
            .{
                .name = "timer",
                .keys = &.{
                    .{ .name = "duration", .value_type = .{ .named = .{ .name = "duration" } }, .optional = true },
                },
            },
        },
    };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `(timer :duration 5)` — len 19, cursor 18.
    try h.openDocument("file:///a.sjon", 1, "(timer :duration 5)");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 18)).?;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualSlices(u8, "ms", items[0].label);
}

test "unit completion: negative number still triggers" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = numberWithUnitPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `(timer :duration -120)` — len 22, cursor 21.
    try h.openDocument("file:///a.sjon", 1, "(timer :duration -120)");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 21)).?;
    try std.testing.expectEqual(@as(usize, 3), items.len);
}

test "unit completion: decimal number still triggers" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = numberWithUnitPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `(timer :duration 1.5)` — len 21, cursor 20.
    try h.openDocument("file:///a.sjon", 1, "(timer :duration 1.5)");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 20)).?;
    try std.testing.expectEqual(@as(usize, 3), items.len);
}

test "unit completion: cursor mid-digits emits nothing" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = numberWithUnitPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `(timer :duration 120)` — cursor 18, between `1` and `2`.
    // value_span.end == 20, so `cursor != end` → skip.
    try h.openDocument("file:///a.sjon", 1, "(timer :duration 120)");

    const arena = fx.arena();

    const result = try h.getCompletion(arena, "file:///a.sjon", 18);
    const items = if (result) |xs| xs else &[_]CompletionItem{};
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "unit completion: cursor after trailing whitespace emits nothing" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = numberWithUnitPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `(timer :duration 120 )` — cursor 21, past the space.
    // value_span.end == 20; `cursor != end` → skip.
    try h.openDocument("file:///a.sjon", 1, "(timer :duration 120 )");

    const arena = fx.arena();

    const result = try h.getCompletion(arena, "file:///a.sjon", 21);
    const items = if (result) |xs| xs else &[_]CompletionItem{};
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "unit completion: empty value slot emits nothing from unit path" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = numberWithUnitPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `(timer :duration )` — cursor 17. No bare-number node to attach to.
    try h.openDocument("file:///a.sjon", 1, "(timer :duration )");

    const arena = fx.arena();

    const result = try h.getCompletion(arena, "file:///a.sjon", 17);
    const items = if (result) |xs| xs else &[_]CompletionItem{};
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "unit completion: value already carries a suffix emits nothing (deferred)" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = numberWithUnitPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `(timer :duration 120ms)` — value AST tag is `.number_with_unit`,
    // not `.number`. Partial / complete suffix needs text_edit support;
    // MVP returns 0 items.
    try h.openDocument("file:///a.sjon", 1, "(timer :duration 120ms)");

    const arena = fx.arena();

    const result = try h.getCompletion(arena, "file:///a.sjon", 22);
    const items = if (result) |xs| xs else &[_]CompletionItem{};
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "unit completion: kind without unit declared emits nothing" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plain_number_kind: sjon.Plugin.ValueKind = .{
        .name = "duration",
        .underlying = .number,
    };
    const plugin: sjon.Plugin.Plugin = .{
        .name = "metro",
        .value_kinds = &.{plain_number_kind},
        .forms = &.{
            .{
                .name = "timer",
                .keys = &.{
                    .{ .name = "duration", .value_type = .{ .named = .{ .name = "duration" } }, .optional = true },
                },
            },
        },
    };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(timer :duration 120)");

    const arena = fx.arena();

    const result = try h.getCompletion(arena, "file:///a.sjon", 20);
    const items = if (result) |xs| xs else &[_]CompletionItem{};
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "unit completion: empty allowed list (any unit accepted) emits nothing" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const permissive_kind: sjon.Plugin.ValueKind = .{
        .name = "duration",
        .underlying = .number,
        .unit = .{ .required = true, .allowed = &.{} },
    };
    const plugin: sjon.Plugin.Plugin = .{
        .name = "metro",
        .value_kinds = &.{permissive_kind},
        .forms = &.{
            .{
                .name = "timer",
                .keys = &.{
                    .{ .name = "duration", .value_type = .{ .named = .{ .name = "duration" } }, .optional = true },
                },
            },
        },
    };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(timer :duration 120)");

    const arena = fx.arena();

    const result = try h.getCompletion(arena, "file:///a.sjon", 20);
    const items = if (result) |xs| xs else &[_]CompletionItem{};
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "unit completion: non-numeric value in number-kind slot emits nothing" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = numberWithUnitPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `(timer :duration "abc")` — value AST tag is `.string`. Our helper's
    // tag check skips non-bare-number values cleanly.
    try h.openDocument("file:///a.sjon", 1, "(timer :duration \"abc\")");

    const arena = fx.arena();

    const result = try h.getCompletion(arena, "file:///a.sjon", 22);
    const items = if (result) |xs| xs else &[_]CompletionItem{};
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "unit completion: string-typed kvpair never reaches the number arm" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = numberWithUnitPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `(timer :name foo)` — kvpair value-kind is `.string`, the number+unit
    // dispatch arm isn't reached. Existing string path produces nothing
    // either (no `:format` declared), so total = 0.
    try h.openDocument("file:///a.sjon", 1, "(timer :name foo)");

    const arena = fx.arena();

    const result = try h.getCompletion(arena, "file:///a.sjon", 16);
    const items = if (result) |xs| xs else &[_]CompletionItem{};
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "unit completion: vector element happy path" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = numberWithUnitPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `(timer :durations [120])` — cursor 22, end of `120`, before `]`.
    try h.openDocument("file:///a.sjon", 1, "(timer :durations [120])");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 22)).?;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    _ = findCompletion(items, "ms");
    _ = findCompletion(items, "s");
    _ = findCompletion(items, "min");
}

test "unit completion: multi-element vector targets the second element" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = numberWithUnitPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `(timer :durations [60 120])` — cursor 25, end of `120`.
    try h.openDocument("file:///a.sjon", 1, "(timer :durations [60 120])");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 25)).?;
    try std.testing.expectEqual(@as(usize, 3), items.len);
}

test "unit completion: vector cursor between elements targets the first" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = numberWithUnitPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `(timer :durations [60 120])` — cursor 21, end of `60` (before the space).
    try h.openDocument("file:///a.sjon", 1, "(timer :durations [60 120])");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 21)).?;
    try std.testing.expectEqual(@as(usize, 3), items.len);
}

test "unit completion: vector cursor in whitespace gap emits nothing" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = numberWithUnitPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `(timer :durations [60 120])` — cursor 22, on `1` of `120`. Neither
    // element's span.end matches: element 1 ends at 21, element 2 at 25.
    try h.openDocument("file:///a.sjon", 1, "(timer :durations [60 120])");

    const arena = fx.arena();

    const result = try h.getCompletion(arena, "file:///a.sjon", 22);
    const items = if (result) |xs| xs else &[_]CompletionItem{};
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

// ---------------------------------------------------------------------------
// Keyword-key completion polish: present-key filter-out, exclusive
// groups, required-first sortText, filterText.
// ---------------------------------------------------------------------------

test "keyword-key completion: filters out keys already present in the form" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const widget: sjon.Plugin.FormSpec = .{
        .name = "widget",
        .keys = &.{
            .{ .name = "size", .value_type = .number, .optional = false },
            .{ .name = "label", .value_type = .string, .optional = false },
            .{ .name = "color", .value_type = .string, .optional = true },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "test", .forms = &.{widget} };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `:size` is already typed. Cursor right after the second `:`
    // (byte 18 in `(widget :size 10 :)`) → keyword-key context.
    //  0         1
    //  0123456789012345678
    try h.openDocument("file:///a.sjon", 1, "(widget :size 10 :)");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 18)).?;
    // `size` is filtered; `label` and `color` remain.
    try std.testing.expectEqual(@as(usize, 2), items.len);
    for (items) |it| try std.testing.expect(!std.mem.eql(u8, it.label, "size"));
}

test "keyword-key completion: required keys sort before optional via sortText" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const widget: sjon.Plugin.FormSpec = .{
        .name = "widget",
        .keys = &.{
            .{ .name = "color", .value_type = .string, .optional = true },
            .{ .name = "size", .value_type = .number, .optional = false },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "test", .forms = &.{widget} };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(widget :)");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 9)).?;
    try std.testing.expectEqual(@as(usize, 2), items.len);

    // The schema declares `color` (optional) before `size` (required);
    // the sortText flip means clients render `size` first.
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "size")) {
            try std.testing.expectEqualStrings("0_size", it.sort_text.?);
        }
        if (std.mem.eql(u8, it.label, "color")) {
            try std.testing.expectEqualStrings("1_color", it.sort_text.?);
        }
        try std.testing.expectEqualStrings(it.label, it.filter_text.?);
    }
}

test "keyword-key completion: exclusive-group siblings drop when one is present" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `:label` and `:icon` are alternatives; typing one drops the
    // other from suggestions (the validator would reject both).
    const widget: sjon.Plugin.FormSpec = .{
        .name = "widget",
        .keys = &.{
            .{ .name = "label", .value_type = .string, .optional = true },
            .{ .name = "icon", .value_type = .string, .optional = true },
            .{ .name = "size", .value_type = .number, .optional = true },
        },
        .exclusive_groups = &.{
            .{
                .alternatives = &.{
                    .{ .keys = &.{"label"} },
                    .{ .keys = &.{"icon"} },
                },
                .cardinality = .at_most_one,
            },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "test", .forms = &.{widget} };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `:label "x"` typed → only `size` should appear.
    //  0         1         2
    //  012345678901234567890
    try h.openDocument("file:///a.sjon", 1, "(widget :label \"x\" :)");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 20)).?;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("size", items[0].label);
}

// ---------------------------------------------------------------------------
// Form-head snippet polish
// ---------------------------------------------------------------------------

test "form-head snippet uses two tab stops for unit-allowed number kinds" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `length-px` is a number with allowed units `px` and `em` — the
    // first is the snippet default, occupying its own tab stop after
    // the magnitude.
    const length_kind: sjon.Plugin.ValueKind = .{
        .name = "length",
        .underlying = .number,
        .unit = .{ .allowed = &.{ "px", "em" } },
    };
    const box: sjon.Plugin.FormSpec = .{
        .name = "box",
        .keys = &.{
            .{ .name = "width", .value_type = .{ .named = .{ .name = "length" } }, .optional = false },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{
        .name = "ui",
        .value_kinds = &.{length_kind},
        .forms = &.{box},
    };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 1)).?;
    const item = findCompletion(items, "box");
    try std.testing.expectEqualStrings("box :width ${1:0}${2:px}$0", item.insert_text.?);
}

// ---------------------------------------------------------------------------
// AST resolveContextAt
// ---------------------------------------------------------------------------

test "resolveContextAt: cursor inside form returns enclosing form idx" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    try h.openDocument("file:///a.sjon", 1, "(+ 1 2)");
    const doc = h.getDocument("file:///a.sjon").?;
    // Cursor at byte 4 — between `1 ` and `2`, inside the form.
    const ctx = Handler.resolveContextAt(&doc.tree, doc.source, 4);
    try std.testing.expect(ctx.enclosing_form_idx != null);
}

test "resolveContextAt: cursor in gap between tokens falls back to source-text" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    try h.openDocument("file:///a.sjon", 1, "(widget :size )");
    const doc = h.getDocument("file:///a.sjon").?;
    // Cursor at byte 14 — between `:size ` and `)`, no kvpair-value
    // node exists yet because the parser saw an empty value slot.
    const ctx = Handler.resolveContextAt(&doc.tree, doc.source, 14);
    try std.testing.expectEqual(Handler.ResolvedContext.Position.kvpair_value, ctx.position);
    try std.testing.expect(ctx.enclosing_form_idx != null);
}

test "resolveContextAt: prefix captures the in-progress symbol before cursor" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    try h.openDocument("file:///a.sjon", 1, "(widget :size abc");
    const doc = h.getDocument("file:///a.sjon").?;
    // Cursor at byte 17 — end of `abc`. Prefix is `abc`.
    const ctx = Handler.resolveContextAt(&doc.tree, doc.source, 17);
    try std.testing.expectEqualStrings("abc", ctx.prefix);
}

test "resolveContextAt: cursor inside an existing kvpair value populates kvpair idx" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    try h.openDocument("file:///a.sjon", 1, "(widget :size 42)");
    const doc = h.getDocument("file:///a.sjon").?;
    // Cursor at byte 15 — inside the `42` value's span.
    const ctx = Handler.resolveContextAt(&doc.tree, doc.source, 15);
    try std.testing.expect(ctx.enclosing_kvpair_idx != null);
}

test "resolveContextAt: nested form sets parent_form_idx to outer" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    // (outer (inner))
    //  0     6
    try h.openDocument("file:///a.sjon", 1, "(outer (inner))");
    const doc = h.getDocument("file:///a.sjon").?;
    // Cursor at byte 13 — inside the inner form's span.
    const ctx = Handler.resolveContextAt(&doc.tree, doc.source, 13);
    const enc = ctx.enclosing_form_idx.?;
    const par = ctx.parent_form_idx.?;
    try std.testing.expect(@intFromEnum(enc) != @intFromEnum(par));
    const par_hdr = doc.tree.formHeader(par);
    try std.testing.expectEqualStrings("outer", par_hdr.head);
}

test "resolveContextAt: top-level form has null parent_form_idx" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    try h.openDocument("file:///a.sjon", 1, "(here)");
    const doc = h.getDocument("file:///a.sjon").?;
    const ctx = Handler.resolveContextAt(&doc.tree, doc.source, 3);
    try std.testing.expect(ctx.enclosing_form_idx != null);
    try std.testing.expect(ctx.parent_form_idx == null);
}

test "resolveContextAt: siblings do not become parents" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    // (a) (b)
    //  012345 6
    try h.openDocument("file:///a.sjon", 1, "(a) (b)");
    const doc = h.getDocument("file:///a.sjon").?;
    // Cursor inside (b) — its enclosing form is itself; (a) is a sibling.
    const ctx = Handler.resolveContextAt(&doc.tree, doc.source, 5);
    try std.testing.expect(ctx.enclosing_form_idx != null);
    try std.testing.expect(ctx.parent_form_idx == null);
}

test "resolveContextAt: triple nesting picks the immediate parent" {
    const a = std.testing.allocator;
    var h = Handler.init(a);
    defer h.deinit();
    // (a (b (c)))
    //  0  3  6
    try h.openDocument("file:///a.sjon", 1, "(a (b (c)))");
    const doc = h.getDocument("file:///a.sjon").?;
    // Cursor at byte 8 — inside (c). Parent should be (b), not (a).
    const ctx = Handler.resolveContextAt(&doc.tree, doc.source, 8);
    const par = ctx.parent_form_idx.?;
    const par_hdr = doc.tree.formHeader(par);
    try std.testing.expectEqualStrings("b", par_hdr.head);
}

// ---------------------------------------------------------------------------
// Vector-element completions
// ---------------------------------------------------------------------------

test "vector-element completion: cross-ref names surface inside the vector" {
    // Mirrors the conformance `cross-ref-resolved` shape: the
    // `:sequence` slot is a vector whose element is `phrase-name`
    // (cross-ref to `phrase`). Cursor inside the vector should list
    // the registered phrase names.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // (phrase :name p0)\n(phrase :name p1)\n(track :sequence [])
    //  0         1         2         3         4         5
    //  012345678901234567 8901234567890123456 7890123456789012345
    try h.openDocument(
        "file:///a.sjon",
        1,
        "(phrase :name p0)\n(phrase :name p1)\n(track :sequence [])",
    );

    const arena = fx.arena();

    // Cursor at byte 53 — between `[` and `]` of the sequence vector.
    const items = (try h.getCompletion(arena, "file:///a.sjon", 53)).?;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    var saw_p0 = false;
    var saw_p1 = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "p0")) saw_p0 = true;
        if (std.mem.eql(u8, it.label, "p1")) saw_p1 = true;
    }
    try std.testing.expect(saw_p0 and saw_p1);
}

test "vector-element completion: member values populate when element is an enum" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const status_kind: sjon.Plugin.ValueKind = .{
        .name = "status",
        .underlying = .symbol,
        .members = .{ .members = &.{
            .{ .name = "draft" },
            .{ .name = "published" },
        } },
    };
    const status_vec: sjon.Plugin.ValueKind = .{
        .name = "status-list",
        .underlying = .vector,
        .vector = .{ .element = .{ .name = "status" } },
    };
    const plugin: sjon.Plugin.Plugin = .{
        .name = "blog",
        .value_kinds = &.{ status_kind, status_vec },
        .forms = &.{
            .{
                .name = "post",
                .keys = &.{
                    .{ .name = "states", .value_type = .{ .named = .{ .name = "status-list" } }, .optional = false },
                },
            },
        },
    };
    h.schema = .init(&.{plugin});

    try h.openDocument("file:///a.sjon", 1, "(post :states [])");

    const arena = fx.arena();

    // Cursor at byte 15 — between `[` and `]`.
    const items = (try h.getCompletion(arena, "file:///a.sjon", 15)).?;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("draft", items[0].label);
    try std.testing.expectEqualStrings("published", items[1].label);
}

// ---------------------------------------------------------------------------
// Form-valued slot head completions
// ---------------------------------------------------------------------------

test "form-valued slot completion: emits a snippet per allowed head" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `:render` is `.form`-underlying with `heads = [rect, circle]`.
    // Both are concrete forms in the same plugin; each gets its own
    // `(name :req … $0)` snippet.
    const shape_kind: sjon.Plugin.ValueKind = .{
        .name = "shape",
        .underlying = .form,
        .heads = .{ .heads = &.{ .{ .name = "rect" }, .{ .name = "circle" } } },
    };
    const plugin: sjon.Plugin.Plugin = .{
        .name = "draw",
        .value_kinds = &.{shape_kind},
        .forms = &.{
            .{
                .name = "rect",
                .keys = &.{
                    .{ .name = "w", .value_type = .number, .optional = false },
                    .{ .name = "h", .value_type = .number, .optional = false },
                },
            },
            .{
                .name = "circle",
                .keys = &.{
                    .{ .name = "r", .value_type = .number, .optional = false },
                },
            },
            .{
                .name = "canvas",
                .keys = &.{
                    .{ .name = "render", .value_type = .{ .named = .{ .name = "shape" } }, .optional = false },
                },
            },
        },
    };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(canvas :render )");

    const arena = fx.arena();

    // Cursor at byte 16 — between `:render ` and `)`.
    const items = (try h.getCompletion(arena, "file:///a.sjon", 16)).?;
    try std.testing.expectEqual(@as(usize, 2), items.len);

    const rect_item = findCompletion(items, "rect");
    try std.testing.expectEqualStrings("(rect :w ${1:0} :h ${2:0}$0)", rect_item.insert_text.?);
    try std.testing.expectEqual(CompletionItem.InsertTextFormat.snippet, rect_item.insert_text_format);

    const circle_item = findCompletion(items, "circle");
    try std.testing.expectEqualStrings("(circle :r ${1:0}$0)", circle_item.insert_text.?);
}

test "form-valued slot completion: unknown head still emits a bare snippet" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `heads` names a form not declared anywhere — schema lookup
    // misses but completion should still surface the head as a bare
    // `(name $0)` placeholder rather than silently dropping it.
    const shape_kind: sjon.Plugin.ValueKind = .{
        .name = "shape",
        .underlying = .form,
        .heads = .{ .heads = &.{.{ .name = "ghost" }} },
    };
    const plugin: sjon.Plugin.Plugin = .{
        .name = "draw",
        .value_kinds = &.{shape_kind},
        .forms = &.{
            .{
                .name = "canvas",
                .keys = &.{
                    .{ .name = "render", .value_type = .{ .named = .{ .name = "shape" } }, .optional = false },
                },
            },
        },
    };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(canvas :render )");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 16)).?;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("(ghost $0)", items[0].insert_text.?);
}

// ---------------------------------------------------------------------------
// Discriminant-driven key narrowing
// ---------------------------------------------------------------------------

fn discriminatedDrumPlugin() sjon.Plugin.Plugin {
    const kind_kind: sjon.Plugin.ValueKind = .{
        .name = "drum-kind",
        .underlying = .symbol,
        .members = .{ .members = &.{
            .{ .name = "kick" },
            .{ .name = "snare" },
        } },
    };
    return .{
        .name = "drum",
        .value_kinds = &.{kind_kind},
        .forms = &.{
            .{
                .name = "hit",
                .discriminant_name = "kind",
                .discriminant_idx = 0,
                .keys = &.{
                    .{ .name = "kind", .value_type = .{ .named = .{ .name = "drum-kind" } }, .optional = false },
                    .{ .name = "velocity", .value_type = .number, .optional = true },
                },
                .variants = &.{
                    .{
                        .when = "kick",
                        .keys = &.{
                            .{ .name = "punch", .value_type = .number, .optional = true },
                        },
                    },
                    .{
                        .when = "snare",
                        .keys = &.{
                            .{ .name = "rattle", .value_type = .number, .optional = true },
                        },
                    },
                },
            },
        },
    };
}

test "discriminant narrowing: matching variant's keys join the base keys" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = discriminatedDrumPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `:kind kick` is typed → `kick` variant's `:punch` joins the
    // shared `:velocity` (but NOT the `snare` variant's `:rattle`).
    //  0         1         2
    //  012345678901234567890
    try h.openDocument("file:///a.sjon", 1, "(hit :kind kick :)");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 17)).?;
    var saw_velocity = false;
    var saw_punch = false;
    for (items) |it| {
        if (std.mem.eql(u8, it.label, "velocity")) saw_velocity = true;
        if (std.mem.eql(u8, it.label, "punch")) saw_punch = true;
        try std.testing.expect(!std.mem.eql(u8, it.label, "rattle"));
    }
    try std.testing.expect(saw_velocity);
    try std.testing.expect(saw_punch);
}

test "discriminant narrowing: unset discriminant only shows base keys" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = discriminatedDrumPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(hit :)");

    const arena = fx.arena();

    // Cursor at byte 6 — between `:` and `)`. No variant keys yet.
    const items = (try h.getCompletion(arena, "file:///a.sjon", 6)).?;
    for (items) |it| {
        try std.testing.expect(!std.mem.eql(u8, it.label, "punch"));
        try std.testing.expect(!std.mem.eql(u8, it.label, "rattle"));
    }
}

test "discriminant narrowing: unrecognised discriminant value falls back to base" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = discriminatedDrumPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `:kind cymbal` — not a declared variant, so no extras get
    // unlocked. (The validator would emit its own diagnostic.)
    try h.openDocument("file:///a.sjon", 1, "(hit :kind cymbal :)");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 19)).?;
    for (items) |it| {
        try std.testing.expect(!std.mem.eql(u8, it.label, "punch"));
        try std.testing.expect(!std.mem.eql(u8, it.label, "rattle"));
    }
}

// ---------------------------------------------------------------------------
// Primitive-literal & string-format completions
// ---------------------------------------------------------------------------

test "primitive completion: boolean slot lists true and false" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const widget: sjon.Plugin.FormSpec = .{
        .name = "widget",
        .keys = &.{
            .{ .name = "enabled", .value_type = .boolean, .optional = false },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "ui", .forms = &.{widget} };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(widget :enabled )");

    const arena = fx.arena();

    // Cursor at byte 17 — between `:enabled ` and `)`.
    const items = (try h.getCompletion(arena, "file:///a.sjon", 17)).?;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("true", items[0].label);
    try std.testing.expectEqualStrings("false", items[1].label);
}

test "primitive completion: nil slot lists nil" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const widget: sjon.Plugin.FormSpec = .{
        .name = "widget",
        .keys = &.{
            .{ .name = "marker", .value_type = .nil, .optional = false },
        },
    };
    const plugin: sjon.Plugin.Plugin = .{ .name = "ui", .forms = &.{widget} };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(widget :marker )");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 16)).?;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("nil", items[0].label);
}

test "string-format completion: email format emits a quoted snippet template" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const email_kind: sjon.Plugin.ValueKind = .{
        .name = "email",
        .underlying = .string,
        .string_bounds = .{ .format = .email },
    };
    const plugin: sjon.Plugin.Plugin = .{
        .name = "contact",
        .value_kinds = &.{email_kind},
        .forms = &.{
            .{
                .name = "person",
                .keys = &.{
                    .{ .name = "email", .value_type = .{ .named = .{ .name = "email" } }, .optional = false },
                },
            },
        },
    };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(person :email )");

    const arena = fx.arena();

    const items = (try h.getCompletion(arena, "file:///a.sjon", 15)).?;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("email", items[0].label);
    try std.testing.expectEqualStrings("\"${1:user@example.com}\"", items[0].insert_text.?);
    try std.testing.expectEqual(CompletionItem.InsertTextFormat.snippet, items[0].insert_text_format);
}

// ---------------------------------------------------------------------------
// setUserSchemas — user-authored schema composition (playground "+ schema").
// ---------------------------------------------------------------------------

/// True when any diagnostic in `diags` carries `code`.
fn hasCode(diags: []const Handler.Diagnostic, code: []const u8) bool {
    for (diags) |d| if (std.mem.eql(u8, d.code, code)) return true;
    return false;
}

/// Minimal valid manifest declaring a single `task` form with one
/// required `title` key. Mirrors the playground's SCHEMA_TEMPLATE shape.
const task_schema =
    \\(plugin :name task-schema :version "1.0.0"
    \\  (form :name task
    \\    (key :name title :type string :optional false)))
;

test "setUserSchemas: a valid manifest makes its form known and re-validates open docs" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const arena = fx.arena();

    // Against core only, `task` is an unknown form.
    try h.openDocument("file:///a.sjon", 1, "(task :title \"x\")");
    const before = (try h.getDiagnostics(arena, "file:///a.sjon")).?;
    try std.testing.expect(hasCode(before, "unknown_form"));

    // Install the schema. The report echoes the parsed `:name` and is clean.
    const sources = [_]Handler.SchemaSource{
        .{ .uri = "inmemory://schema/1.sjon", .text = task_schema },
    };
    const reports = try h.setUserSchemas(arena, &sources);
    try std.testing.expectEqual(@as(usize, 1), reports.len);
    try std.testing.expectEqualStrings("task-schema", reports[0].name);
    try std.testing.expectEqualStrings("inmemory://schema/1.sjon", reports[0].uri);
    try std.testing.expect(!hasCode(reports[0].diagnostics, "unknown_form"));
    for (reports[0].diagnostics) |d| try std.testing.expect(d.severity != .err);

    // setUserSchemas re-validated the open doc against the new schema —
    // no manual didChange needed. `task` is now known and the doc is clean.
    const after = (try h.getDiagnostics(arena, "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 0), after.len);
}

test "setUserSchemas: closed schema form flags unknown and missing keys" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const arena = fx.arena();

    // `:nope` isn't declared; required `:title` is absent.
    try h.openDocument("file:///a.sjon", 1, "(task :nope 1)");
    const sources = [_]Handler.SchemaSource{
        .{ .uri = "inmemory://schema/1.sjon", .text = task_schema },
    };
    _ = try h.setUserSchemas(arena, &sources);

    const diags = (try h.getDiagnostics(arena, "file:///a.sjon")).?;
    try std.testing.expect(hasCode(diags, "unknown_key"));
    try std.testing.expect(hasCode(diags, "missing_required_key"));
}

test "setUserSchemas: malformed manifest reports errors, contributes no forms, never panics" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const arena = fx.arena();

    try h.openDocument("file:///a.sjon", 1, "(task :title \"x\")");

    // Two sources: a valid schema and a non-`(plugin …)` root. The bad
    // one reports an error and contributes nothing; the good one applies.
    const sources = [_]Handler.SchemaSource{
        .{ .uri = "inmemory://schema/1.sjon", .text = task_schema },
        .{ .uri = "inmemory://schema/2.sjon", .text = "(form :name oops)" },
    };
    const reports = try h.setUserSchemas(arena, &sources);
    try std.testing.expectEqual(@as(usize, 2), reports.len);

    // Report 0: valid, named, no errors.
    try std.testing.expectEqualStrings("task-schema", reports[0].name);
    for (reports[0].diagnostics) |d| try std.testing.expect(d.severity != .err);

    // Report 1: invalid → empty name, at least one error diagnostic.
    try std.testing.expectEqualStrings("", reports[1].name);
    var saw_err = false;
    for (reports[1].diagnostics) |d| {
        if (d.severity == .err) saw_err = true;
    }
    try std.testing.expect(saw_err);

    // The valid schema still took effect; the broken one leaked no forms.
    const diags = (try h.getDiagnostics(arena, "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "setUserSchemas: empty set composes core only and bumps generation" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const arena = fx.arena();

    const gen0 = h.schema_generation;
    const reports = try h.setUserSchemas(arena, &.{});
    try std.testing.expectEqual(@as(usize, 0), reports.len);
    try std.testing.expectEqual(gen0 +% 1, h.schema_generation);

    // Core vocabulary survives; user forms do not exist.
    try h.openDocument("file:///a.sjon", 1, "(+ 1 2)");
    const ok = (try h.getDiagnostics(arena, "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 0), ok.len);

    try h.openDocument("file:///b.sjon", 1, "(task)");
    const bad = (try h.getDiagnostics(arena, "file:///b.sjon")).?;
    try std.testing.expect(hasCode(bad, "unknown_form"));
}

test "setUserSchemas: re-setting replaces and frees the previous set" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const arena = fx.arena();

    const widget_schema =
        \\(plugin :name widget-schema :version "1.0.0"
        \\  (form :name widget))
    ;

    // First set defines `task`.
    _ = try h.setUserSchemas(arena, &[_]Handler.SchemaSource{
        .{ .uri = "inmemory://schema/1.sjon", .text = task_schema },
    });

    // Second set defines `widget` only — replaces (not appends). The
    // testing allocator would flag a leak or double-free in the swap.
    _ = try h.setUserSchemas(arena, &[_]Handler.SchemaSource{
        .{ .uri = "inmemory://schema/2.sjon", .text = widget_schema },
    });

    try h.openDocument("file:///a.sjon", 1, "(widget)");
    const w = (try h.getDiagnostics(arena, "file:///a.sjon")).?;
    try std.testing.expect(!hasCode(w, "unknown_form"));

    try h.openDocument("file:///b.sjon", 1, "(task :title \"x\")");
    const t = (try h.getDiagnostics(arena, "file:///b.sjon")).?;
    try std.testing.expect(hasCode(t, "unknown_form"));
}

test "setUserSchemas: aggregate cross-ref errors attribute to the authoring schema" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const arena = fx.arena();

    // `phrase-name` cross-refs a `phrase` form the manifest never declares.
    // It loads clean (structurally valid); the dangling target only
    // surfaces once the schema is composed and the aggregate pass runs.
    const dangling =
        \\(plugin :name dangler :version "1.0.0"
        \\  (value-kind :name phrase-name
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :target phrase :name-key name)))
    ;
    const reports = try h.setUserSchemas(arena, &[_]Handler.SchemaSource{
        .{ .uri = "inmemory://schema/1.sjon", .text = dangling },
    });
    try std.testing.expectEqual(@as(usize, 1), reports.len);
    try std.testing.expectEqualStrings("dangler", reports[0].name);
    try std.testing.expect(hasCode(reports[0].diagnostics, "unknown_cross_ref_target"));
}

// ---------------------------------------------------------------------------
// getSelectionRanges — structural expand-selection (plan 01 / CP3).
// ---------------------------------------------------------------------------

/// Assert `chain[i]` is exactly `start..end`, with the index in the
/// failure message's line number.
fn expectRange(chain: []const Handler.SelectionRange, i: usize, start: u32, end: u32) !void {
    try std.testing.expect(i < chain.len);
    try std.testing.expectEqual(start, chain[i].span_start);
    try std.testing.expectEqual(end, chain[i].span_end);
}

test "selection ranges grow atom -> kvpair -> form -> parent form" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `(scene (widget :name "hi"))` — string 21..25, kvpair 15..25,
    // inner form 7..26, outer form 0..27.
    try h.openDocument("file:///a.sjon", 1, "(scene (widget :name \"hi\"))");

    const arena = fx.arena();

    // Cursor inside the string body.
    const chains = (try h.getSelectionRanges(arena, "file:///a.sjon", &.{22})).?;
    try std.testing.expectEqual(@as(usize, 1), chains.len);
    const chain = chains[0];
    try std.testing.expectEqual(@as(usize, 4), chain.len);
    try expectRange(chain, 0, 21, 25);
    try expectRange(chain, 1, 15, 25);
    try expectRange(chain, 2, 7, 26);
    try expectRange(chain, 3, 0, 27);
}

test "selection ranges from a vector element include the vector" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `(a [1 2])` — element 4..5, vector 3..8, form 0..9.
    try h.openDocument("file:///a.sjon", 1, "(a [1 2])");

    const arena = fx.arena();

    const chains = (try h.getSelectionRanges(arena, "file:///a.sjon", &.{4})).?;
    const chain = chains[0];
    try std.testing.expectEqual(@as(usize, 3), chain.len);
    try expectRange(chain, 0, 4, 5);
    try expectRange(chain, 1, 3, 8);
    try expectRange(chain, 2, 0, 9);
}

test "selection ranges on a form head start at the head symbol" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // Head `widget` occupies 8..14; the head is not a tree node, so the
    // chain has to synthesise it from the form header.
    try h.openDocument("file:///a.sjon", 1, "(scene (widget :name \"hi\"))");

    const arena = fx.arena();

    const chains = (try h.getSelectionRanges(arena, "file:///a.sjon", &.{9})).?;
    const chain = chains[0];
    try std.testing.expectEqual(@as(usize, 3), chain.len);
    try expectRange(chain, 0, 8, 14);
    try expectRange(chain, 1, 7, 26);
    try expectRange(chain, 2, 0, 27);
}

test "selection ranges on a kvpair key start at the key" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `:name` occupies 15..20 — like the form head, a header span rather
    // than a node of its own.
    try h.openDocument("file:///a.sjon", 1, "(scene (widget :name \"hi\"))");

    const arena = fx.arena();

    const chains = (try h.getSelectionRanges(arena, "file:///a.sjon", &.{17})).?;
    const chain = chains[0];
    try std.testing.expectEqual(@as(usize, 4), chain.len);
    try expectRange(chain, 0, 15, 20);
    try expectRange(chain, 1, 15, 25);
    try expectRange(chain, 2, 7, 26);
    try expectRange(chain, 3, 0, 27);
}

test "selection ranges in whitespace between roots yield an empty chain" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `(a 1)\n\n(b 2)` — roots at 0..5 and 7..12. Byte 6 is the blank
    // line between them: inside no root, so there is nothing to expand
    // to. Pinned as an empty chain (not the whole document) — the
    // transport turns that into a degenerate zero-width range.
    try h.openDocument("file:///a.sjon", 1, "(a 1)\n\n(b 2)");

    const arena = fx.arena();

    const chains = (try h.getSelectionRanges(arena, "file:///a.sjon", &.{6})).?;
    try std.testing.expectEqual(@as(usize, 1), chains.len);
    try std.testing.expectEqual(@as(usize, 0), chains[0].len);
}

test "selection ranges accept multiple positions in one call" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // One offset per root; each chain is resolved independently.
    try h.openDocument("file:///a.sjon", 1, "(a 1)\n\n(b 2)");

    const arena = fx.arena();

    const chains = (try h.getSelectionRanges(arena, "file:///a.sjon", &.{ 3, 10 })).?;
    try std.testing.expectEqual(@as(usize, 2), chains.len);
    try expectRange(chains[0], 0, 3, 4);
    try expectRange(chains[0], 1, 0, 5);
    try expectRange(chains[1], 0, 10, 11);
    try expectRange(chains[1], 1, 7, 12);
}

test "selection ranges return null for an unknown document" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const arena = fx.arena();

    try std.testing.expect(try h.getSelectionRanges(arena, "file:///nope.sjon", &.{0}) == null);
}

// ---------------------------------------------------------------------------
// getWorkspaceSymbols — cross-ref definitions as a workspace symbol index
// (plan 01 / CP4).
//
// Two documents:
//   a: `(phrase :name p0)\n(phrase :name Alpha)`
//       0123456789...          18...
//      `p0` at 14..16, `Alpha` at 32..37.
//   b: `(phrase :name beta)` — `beta` at 14..18.
// ---------------------------------------------------------------------------

/// Open the two-document workspace the symbol tests share. The schema
/// stays in the test body: `Schema.init` borrows the plugin slice, so it
/// has to outlive the call — a helper-local plugin would dangle.
fn openSymbolDocs(h: *Handler) !void {
    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)\n(phrase :name Alpha)");
    try h.openDocument("file:///b.sjon", 1, "(phrase :name beta)");
}

test "workspace symbols list every cross-ref definition across open documents" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefDirectPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });
    try openSymbolDocs(h);

    const arena = fx.arena();

    // Sorted by name bytes: `Alpha` (0x41) < `beta` (0x62) < `p0` (0x70).
    const syms = try h.getWorkspaceSymbols(arena, "");
    try std.testing.expectEqual(@as(usize, 3), syms.len);
    try std.testing.expectEqualStrings("Alpha", syms[0].name);
    try std.testing.expectEqualStrings("file:///a.sjon", syms[0].location.uri);
    try std.testing.expectEqualStrings("beta", syms[1].name);
    try std.testing.expectEqualStrings("file:///b.sjon", syms[1].location.uri);
    try std.testing.expectEqualStrings("p0", syms[2].name);
    try std.testing.expectEqualStrings("file:///a.sjon", syms[2].location.uri);
}

test "workspace symbols filter by case-insensitive substring query" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefDirectPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });
    try openSymbolDocs(h);

    const arena = fx.arena();

    // Uppercase query against a mixed-case name: both sides fold.
    const syms = try h.getWorkspaceSymbols(arena, "AL");
    try std.testing.expectEqual(@as(usize, 1), syms.len);
    try std.testing.expectEqualStrings("Alpha", syms[0].name);

    // Substring, not prefix — `et` sits mid-name in `beta`.
    const mid = try h.getWorkspaceSymbols(arena, "et");
    try std.testing.expectEqual(@as(usize, 1), mid.len);
    try std.testing.expectEqualStrings("beta", mid[0].name);

    // No match is an empty list, not an error.
    const none = try h.getWorkspaceSymbols(arena, "zzz");
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "workspace symbol entries carry the defining form head as container" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefDirectPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });
    try openSymbolDocs(h);

    const arena = fx.arena();

    const syms = try h.getWorkspaceSymbols(arena, "p0");
    try std.testing.expectEqual(@as(usize, 1), syms.len);
    // The container is the cross-ref target's *canonical* name — the
    // `plugin/form` key the index is built on, not the bare head as
    // written in source. Two plugins may both declare a `phrase`, and a
    // symbol picker showing `phrase` twice cannot tell them apart.
    try std.testing.expectEqualStrings("audio/phrase", syms[0].container_name);
    // Location is the name span (14..16), matching where getDefinition jumps.
    try std.testing.expectEqual(@as(u32, 14), syms[0].location.span_start);
    try std.testing.expectEqual(@as(u32, 16), syms[0].location.span_end);
}

test "workspace symbols return an empty list when no documents are open" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const arena = fx.arena();

    // No revalidation has run, so there is no cross-ref index at all.
    const syms = try h.getWorkspaceSymbols(arena, "");
    try std.testing.expectEqual(@as(usize, 0), syms.len);
}

test "workspace symbols drop definitions whose document has closed" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = crossRefDirectPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });
    try openSymbolDocs(h);

    h.closeDocument("file:///b.sjon");

    const arena = fx.arena();

    const syms = try h.getWorkspaceSymbols(arena, "");
    try std.testing.expectEqual(@as(usize, 2), syms.len);
    try std.testing.expectEqualStrings("Alpha", syms[0].name);
    try std.testing.expectEqualStrings("p0", syms[1].name);
}

/// Schema with a member set carrying one deprecated member — the shape
/// that makes the validator emit `deprecated_member`. Mirrors the
/// `deprecated-member-used` corpus case so the LSP tag and the corpus
/// warning describe the same situation.
fn deprecatedMemberPlugin() sjon.Plugin.Plugin {
    const status_kind: sjon.Plugin.ValueKind = .{
        .name = "status",
        .underlying = .symbol,
        .members = .{ .members = &.{
            .{ .name = "draft" },
            .{ .name = "archived", .deprecated = true },
        } },
    };
    return .{
        .name = "blog",
        .value_kinds = &.{status_kind},
        .forms = &.{
            .{
                .name = "post",
                .keys = &.{
                    .{ .name = "status", .value_type = .{ .named = .{ .name = "status" } }, .optional = false },
                },
            },
        },
    };
}

test "deprecated_member diagnostic carries the deprecated tag" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ deprecatedMemberPlugin(), sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(post :status archived)");
    const diags = (try h.getDiagnostics(fx.arena(), "file:///a.sjon")).?;

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("deprecated_member", diags[0].code);
    try std.testing.expectEqual(@as(usize, 1), diags[0].tags.len);
    try std.testing.expectEqual(Handler.Diagnostic.Tag.deprecated, diags[0].tags[0]);
}

test "diagnostics other than deprecated_member carry no tags" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ deprecatedMemberPlugin(), sjon.plugins.core.plugin });

    // `retired` is no member at all — a plain `not_member` error, which
    // shares the member-set machinery but is not a deprecation.
    try h.openDocument("file:///a.sjon", 1, "(post :status retired)");
    const diags = (try h.getDiagnostics(fx.arena(), "file:///a.sjon")).?;

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("not_member", diags[0].code);
    try std.testing.expectEqual(@as(usize, 0), diags[0].tags.len);
}

/// Schema with a two-alternative exclusive group — the shape that makes
/// the validator emit `mutually_exclusive_keys_present` when an author
/// writes both.
fn exclusiveGroupPlugin() sjon.Plugin.Plugin {
    return .{
        .name = "layout",
        .forms = &.{
            .{
                .name = "box",
                .keys = &.{
                    .{ .name = "width", .value_type = .number, .optional = true },
                    .{ .name = "height", .value_type = .number, .optional = true },
                },
                .exclusive_groups = &.{
                    .{
                        .alternatives = &.{
                            .{ .keys = &.{"width"} },
                            .{ .keys = &.{"height"} },
                        },
                        .cardinality = .at_most_one,
                    },
                },
            },
        },
    };
}

/// The one diagnostic in `uri` whose code is `code`. Panics otherwise —
/// a related-info test that silently matched the wrong diagnostic would
/// assert against the wrong spans.
fn diagnosticWithCode(
    h: *Handler,
    arena: std.mem.Allocator,
    uri: []const u8,
    code: []const u8,
) !Handler.Diagnostic {
    const diags = (try h.getDiagnostics(arena, uri)).?;
    for (diags) |d| {
        if (std.mem.eql(u8, d.code, code)) return d;
    }
    std.debug.panic("no '{s}' diagnostic in {d} diagnostics for {s}", .{ code, diags.len, uri });
}

test "duplicate_key related points at first occurrence" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ deprecatedMemberPlugin(), sjon.plugins.core.plugin });

    //                       0         1         2         3
    //                       0123456789012345678901234567890123
    const src = "(post :status draft :status draft)";
    try h.openDocument("file:///a.sjon", 1, src);

    const d = try diagnosticWithCode(h, fx.arena(), "file:///a.sjon", "duplicate_key");
    // The diagnostic itself sits on the *second* `:status`.
    try std.testing.expectEqual(@as(u32, 20), d.span_start);
    try std.testing.expectEqual(@as(u32, 27), d.span_end);

    try std.testing.expectEqual(@as(usize, 1), d.related.len);
    const r = d.related[0];
    try std.testing.expectEqualStrings("file:///a.sjon", r.uri);
    // …and the related location on the first.
    try std.testing.expectEqual(@as(u32, 6), r.span_start);
    try std.testing.expectEqual(@as(u32, 13), r.span_end);
    try std.testing.expect(std.mem.indexOf(u8, r.message, "first defined here") != null);
}

test "exclusive violation relates the conflicting keys" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ exclusiveGroupPlugin(), sjon.plugins.core.plugin });

    //                   0         1         2
    //                   012345678901234567890123
    const src = "(box :width 1 :height 2)";
    try h.openDocument("file:///a.sjon", 1, src);

    const d = try diagnosticWithCode(h, fx.arena(), "file:///a.sjon", "mutually_exclusive_keys_present");

    // Both present alternatives are named, each on its own key span.
    try std.testing.expectEqual(@as(usize, 2), d.related.len);
    try std.testing.expectEqual(@as(u32, 5), d.related[0].span_start);
    try std.testing.expectEqual(@as(u32, 11), d.related[0].span_end);
    try std.testing.expectEqual(@as(u32, 14), d.related[1].span_start);
    try std.testing.expectEqual(@as(u32, 21), d.related[1].span_end);
    try std.testing.expect(std.mem.indexOf(u8, d.related[0].message, ":width") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.related[1].message, ":height") != null);
}

test "cross-ref diagnostics relate candidate definitions" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ crossRefDirectPlugin(), sjon.plugins.core.plugin });

    // `p1` is a typo for the defined `p0` — one near-name candidate.
    //                   0         1
    //                   01234567890123456
    const src = "(phrase :name p0)\n(jump :target p1)";
    try h.openDocument("file:///a.sjon", 1, src);

    const d = try diagnosticWithCode(h, fx.arena(), "file:///a.sjon", "not_cross_ref");

    try std.testing.expectEqual(@as(usize, 1), d.related.len);
    const r = d.related[0];
    try std.testing.expectEqualStrings("file:///a.sjon", r.uri);
    // Points at `p0`'s definition name token on line 0 (bytes 14..16).
    try std.testing.expectEqual(@as(u32, 14), r.span_start);
    try std.testing.expectEqual(@as(u32, 16), r.span_end);
    try std.testing.expect(std.mem.indexOf(u8, r.message, "p0") != null);
}

test "cross-ref candidates stop at the scope boundary" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ crossRefDirectPlugin(), sjon.plugins.core.plugin });

    // `p0` is defined in a *different* document. Scope is per-tree (the
    // LSP never sets `Validator.Options.share_scope`), so a reference
    // never resolves across documents — offering `p0` here would be a
    // "did you mean" the user cannot act on, since accepting it leaves
    // the same `not_cross_ref` error in place.
    try h.openDocument("file:///a.sjon", 1, "(phrase :name p0)");
    try h.openDocument("file:///b.sjon", 1, "(jump :target p1)");

    const d = try diagnosticWithCode(h, fx.arena(), "file:///b.sjon", "not_cross_ref");
    try std.testing.expectEqual(@as(usize, 0), d.related.len);
}

test "diagnostics with no derivable relation carry none" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ deprecatedMemberPlugin(), sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(post :status retired)");
    const d = try diagnosticWithCode(h, fx.arena(), "file:///a.sjon", "not_member");
    try std.testing.expectEqual(@as(usize, 0), d.related.len);
}

test "hover over a diagnostic span appends the code's short explanation" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ deprecatedMemberPlugin(), sjon.plugins.core.plugin });

    // `:status` is required and absent → `missing_required_key` on the form.
    try h.openDocument("file:///a.sjon", 1, "(post)");

    // Cursor on the `post` head (byte 1), inside the diagnostic's span.
    const hov = (try h.getHover(fx.arena(), "file:///a.sjon", 1)).?;

    try std.testing.expect(std.mem.indexOf(u8, hov.contents, "missing_required_key") != null);
    const entry = sjon.Explanations.lookup("missing_required_key").?;
    try std.testing.expect(std.mem.indexOf(u8, hov.contents, entry.short) != null);
    // The schema-driven content is still there — the explanation appends.
    try std.testing.expect(std.mem.indexOf(u8, hov.contents, "post") != null);
}

test "hover over a clean span has no explanation section" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ deprecatedMemberPlugin(), sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(post :status draft)");
    const hov = (try h.getHover(fx.arena(), "file:///a.sjon", 1)).?;

    // A valid document has nothing to explain.
    try std.testing.expect(std.mem.indexOf(u8, hov.contents, "missing_required_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, hov.contents, "**Explanation") == null);
}

test "explanations reach hover contexts other than the form head" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ deprecatedMemberPlugin(), sjon.plugins.core.plugin });

    // `archived` is a deprecated member — the diagnostic sits on the
    // *value*, which resolves through `renderMemberValueHover` rather
    // than the head path the test above covers.
    try h.openDocument("file:///a.sjon", 1, "(post :status archived)");
    const hov = (try h.getHover(fx.arena(), "file:///a.sjon", 15)).?;

    try std.testing.expect(std.mem.indexOf(u8, hov.contents, "deprecated_member") != null);
    const entry = sjon.Explanations.lookup("deprecated_member").?;
    try std.testing.expect(std.mem.indexOf(u8, hov.contents, entry.short) != null);
}

test "diagnostics link to their code's documentation page" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ deprecatedMemberPlugin(), sjon.plugins.core.plugin });

    try h.openDocument("file:///a.sjon", 1, "(post :status retired)");
    const diags = (try h.getDiagnostics(fx.arena(), "file:///a.sjon")).?;

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("not_member", diags[0].code);
    try std.testing.expectEqualStrings(
        "https://hugodaniel.com/pages/sjon/errors/not_member",
        diags[0].code_href,
    );
}

test "parse diagnostics link to their page too" {
    // Parse errors never reach the schema, so they take a different path
    // to `translate` than the validator's do. The href is derived from
    // the code alone, so both should carry one.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try h.openDocument("file:///a.sjon", 1, "(unclosed :key 1");
    const diags = (try h.getDiagnostics(fx.arena(), "file:///a.sjon")).?;

    try std.testing.expect(diags.len > 0);
    for (diags) |d| {
        try std.testing.expect(std.mem.startsWith(
            u8,
            d.code_href,
            "https://hugodaniel.com/pages/sjon/errors/",
        ));
        try std.testing.expect(std.mem.endsWith(u8, d.code_href, d.code));
    }
}

test "every diagnostic code has a documentation page" {
    // The href is only useful if the page exists. `zig build
    // gen-explanations` emits one page per code from `Explanations`, so
    // this pins the other half of that contract: every code the enum can
    // produce resolves to a slug the generator emitted.
    inline for (@typeInfo(sjon.Ast.Diagnostic.Code).@"enum".fields) |f| {
        const href = Handler.codeHref(@field(sjon.Ast.Diagnostic.Code, f.name));
        try std.testing.expectEqualStrings(
            "https://hugodaniel.com/pages/sjon/errors/" ++ f.name,
            href,
        );
        try std.testing.expect(sjon.Explanations.lookup(f.name) != null);
    }
}

test "code actions carry the diagnostic they fix" {
    // Two misspellings of the same form on one line: the diagnostics
    // share a code and differ only in span. A "fix all in selection"
    // request covering both yields two actions whose titles are
    // byte-identical ("Replace with `clamp`"), so the code alone cannot
    // tell an editor which squiggle each belongs to — the action has to
    // name the diagnostic it fixes, span included.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const src = "[(clmp 1 0 2) (clmp 3 0 4)]";
    try h.openDocument("file:///a.sjon", 1, src);

    const actions = (try h.getCodeActions(fx.arena(), "file:///a.sjon", 0, @intCast(src.len))).?;
    try std.testing.expectEqual(@as(usize, 2), actions.len);

    for (actions) |act| {
        try std.testing.expectEqual(@as(usize, 1), act.diagnostics.len);
        const d = act.diagnostics[0];
        try std.testing.expectEqualStrings("unknown_form", d.code);
        // The association that matters: the diagnostic's span is the one
        // this action's edit rewrites, not the other occurrence's.
        try std.testing.expectEqual(act.edits[0].span_start, d.span_start);
        try std.testing.expectEqual(act.edits[0].span_end, d.span_end);
    }
    // And the two actions address distinct diagnostics.
    try std.testing.expect(actions[0].diagnostics[0].span_start !=
        actions[1].diagnostics[0].span_start);
}

test "code action diagnostics are fully formed, not code-only stubs" {
    // The action's diagnostic is what the transport serializes into LSP
    // `CodeAction.diagnostics`, which is `Diagnostic[]` — clients match
    // it against their published set. A stub carrying only the code
    // would serialize to something no client can match.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try h.openDocument("file:///a.sjon", 1, "(clmp 1 0 2)");

    const actions = (try h.getCodeActions(fx.arena(), "file:///a.sjon", 1, 5)).?;
    try std.testing.expect(actions.len > 0);

    const d = actions[0].diagnostics[0];
    try std.testing.expect(d.message.len > 0);
    try std.testing.expectEqual(Handler.Severity.err, d.severity);
    try std.testing.expectEqualStrings(
        "https://hugodaniel.com/pages/sjon/errors/unknown_form",
        d.code_href,
    );
}

// ---------------------------------------------------------------------------
// Plugin directives — `(plugin …)` and `(use-plugin …)` at the top level.
//
// The Handler validates the document forest directly rather than through
// `Host.validateDocument`, so it has to lift the same two heads out of the
// walk that the host does. It did not, and every `(use-plugin …)` header —
// the ordinary way a document names its vocabulary, and a form `sjon check`
// accepts — drew `unknown_form` in the editor.
//
// `Handler.dataRoots` is the one place that decides, read by the validation
// walk and the defaults overlay both, which is what keeps the overlay
// describing the same document as the diagnostics beside it.
// ---------------------------------------------------------------------------

/// The first top-level form whose head is `head`. Documents here open with
/// a directive, so "the first form" is not the one under test.
fn formIdxWithHead(doc: *const Handler.Document, head: []const u8) ?sjon.Ast.NodeIndex {
    for (doc.tree.root) |idx| {
        if (doc.tree.tagOf(idx) != .form) continue;
        if (std.mem.eql(u8, doc.tree.formHeader(idx).head, head)) return idx;
    }
    return null;
}

test "plugin directives: a (use-plugin …) header is not an unknown form" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try installSchema(&fx, task_schema);
    try h.openDocument("file:///a.sjon", 1, "(use-plugin \"task-schema\")\n(task :title \"x\")");

    const diags = (try h.getDiagnostics(fx.arena(), "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "plugin directives: an inline (plugin …) manifest is not validated as data" {
    // A manifest opened as an ordinary document. The LSP takes its schema
    // from the project file or the panes, so it has nothing to say about
    // this file — but "nothing" is the answer, not "unknown form `plugin`"
    // on a manifest that loads perfectly well.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try h.openDocument("file:///schema.sjon", 1, task_schema);

    const diags = (try h.getDiagnostics(fx.arena(), "file:///schema.sjon")).?;
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "plugin directives: the data after a header still validates" {
    // The other direction, and the one a lazy filter would break: lifting
    // the header must not lift what follows it.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try installSchema(&fx, task_schema);
    try h.openDocument("file:///a.sjon", 1, "(use-plugin \"task-schema\")\n(task :nope 1)");

    const diags = (try h.getDiagnostics(fx.arena(), "file:///a.sjon")).?;
    try std.testing.expect(hasCode(diags, "unknown_key"));
    try std.testing.expect(hasCode(diags, "missing_required_key"));
}

test "plugin directives: the defaults overlay stays aligned with the walk" {
    // The overlay is keyed by node index, so lifting a root neither
    // shifts nor drops what the walk finds — this pins that, which is
    // the claim `dataRoots` is relied on for by two callers rather than
    // one. A filter that dropped a root too many would show up here as a
    // missing effective value rather than as a missing diagnostic.
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try installSchema(&fx, fps_schema);
    try h.openDocument("file:///a.sjon", 1, "(use-plugin \"p\")\n(scene)");

    const doc = h.getDocument("file:///a.sjon").?;
    const scene = formIdxWithHead(doc, "scene") orelse return error.TestNoDataForm;
    const entry = doc.materialized.defaultFor(scene, "fps") orelse
        return error.TestMissingDefaultEntry;
    try std.testing.expectEqual(@as(f64, 60), entry.value.toF64().?);
}

// ---------------------------------------------------------------------------
// Materialized defaults — the per-document overlay of effective values for
// omitted-but-defaulted keys (plan 04 CP1). Display-only: it feeds inlay
// hints, the materialize action, and the effective-document view, and never
// reaches the validator.
// ---------------------------------------------------------------------------

/// Schema declaring one `scene` form with a literal-defaulted `fps`.
const fps_schema =
    \\(plugin :name p :version "1.0.0"
    \\  (form :name scene
    \\    (key :name fps :type number :default 60)))
;

/// Index of the first top-level form in `doc`'s tree. The overlay is keyed
/// by `NodeIndex`, and `findEnclosingFormIdx` is private to `Handler`.
fn firstFormIdx(doc: *const Handler.Document) ?sjon.Ast.NodeIndex {
    for (doc.tree.root) |idx| {
        if (doc.tree.tagOf(idx) == .form) return idx;
    }
    return null;
}

/// Install `manifest` as the sole user schema. Discards the reports —
/// callers here assert on document state, not on schema diagnostics.
fn installSchema(fx: *Fixture, manifest: []const u8) !void {
    const sources = [_]Handler.SchemaSource{
        .{ .uri = "inmemory://schema/1.sjon", .text = manifest },
    };
    _ = try fx.h.setUserSchemas(fx.arena(), &sources);
}

test "document exposes materialized defaults after open" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try installSchema(&fx, fps_schema);
    try h.openDocument("file:///a.sjon", 1, "(scene)");

    const doc = h.getDocument("file:///a.sjon").?;
    const form = firstFormIdx(doc) orelse return error.TestNoDataForm;
    const entry = doc.materialized.defaultFor(form, "fps") orelse
        return error.TestMissingDefaultEntry;
    try std.testing.expectEqual(@as(f64, 60), entry.value.toF64().?);
    try std.testing.expectEqual(
        sjon.MaterializedDefaults.Origin.literal_default,
        entry.origin,
    );
}

test "materialized defaults refresh on didChange" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try installSchema(&fx, fps_schema);
    try h.openDocument("file:///a.sjon", 1, "(scene)");
    {
        const doc = h.getDocument("file:///a.sjon").?;
        const form = firstFormIdx(doc) orelse return error.TestNoDataForm;
        try std.testing.expect(doc.materialized.defaultFor(form, "fps") != null);
    }

    // The author writes the key: the ghost entry must disappear, or the
    // inlay hint would duplicate a value the source now shows.
    try h.changeDocumentFull("file:///a.sjon", 2, "(scene :fps 30)");
    {
        const doc = h.getDocument("file:///a.sjon").?;
        const form = firstFormIdx(doc) orelse return error.TestNoDataForm;
        try std.testing.expect(doc.materialized.defaultFor(form, "fps") == null);
    }
}

test "materialized defaults refresh on schema swap" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // Opened against core only — `scene` is unknown, so nothing to materialize.
    try h.openDocument("file:///a.sjon", 1, "(scene)");
    {
        const doc = h.getDocument("file:///a.sjon").?;
        const form = firstFormIdx(doc) orelse return error.TestNoDataForm;
        try std.testing.expect(doc.materialized.defaultFor(form, "fps") == null);
    }

    // `setUserSchemas` re-validates open documents; the overlay must ride
    // along, since the defaults it holds are a property of the schema.
    try installSchema(&fx, fps_schema);
    {
        const doc = h.getDocument("file:///a.sjon").?;
        const form = firstFormIdx(doc) orelse return error.TestNoDataForm;
        const entry = doc.materialized.defaultFor(form, "fps") orelse
            return error.TestMissingDefaultEntry;
        try std.testing.expectEqual(@as(f64, 60), entry.value.toF64().?);
    }
}

test "failing expression default does not add a diagnostic in LSP" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `nope` is declared with no `:impl`: the manifest loads and the
    // aggregate phase is happy, but evaluating `(nope)` fails at
    // materialization time. Under `Host.validateDocument` that surfaces a
    // `default_eval_failed` diagnostic (`Host_tests.zig`). The LSP
    // materializes for display only, so its diagnostics must be exactly
    // what the validator produced — no more.
    // `depth` rides along as a working literal default on the same form:
    // without it, "no `fps` entry" would also hold for a Handler that
    // never materializes anything, and the test would pass for the wrong
    // reason. With it, the assertions below say the walk *did* run over
    // this form and the failure stayed local to the one bad key.
    const manifest =
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name nope :arity (fixed 0) :result number)
        \\  (form :name scene
        \\    (key :name fps :type number :default (nope))
        \\    (key :name depth :type number :default 3)))
    ;
    try installSchema(&fx, manifest);
    try h.openDocument("file:///a.sjon", 1, "(scene)");

    const diags = (try h.getDiagnostics(fx.arena(), "file:///a.sjon")).?;
    try std.testing.expect(!hasCode(diags, "default_eval_failed"));

    const doc = h.getDocument("file:///a.sjon").?;
    const form = firstFormIdx(doc) orelse return error.TestNoDataForm;
    try std.testing.expect(doc.materialized.defaultFor(form, "fps") == null);
    const ok = doc.materialized.defaultFor(form, "depth") orelse
        return error.TestMissingDefaultEntry;
    try std.testing.expectEqual(@as(f64, 3), ok.value.toF64().?);
}

// ---------------------------------------------------------------------------
// Ghost default inlay hints (plan 04 CP2) — the overlay rendered as `:key
// value` ghost text before a form's closing paren.
// ---------------------------------------------------------------------------

/// `scene` with a written `title` and a literal-defaulted `fps`, so the
/// default hint lands somewhere other than right after the head.
const scene_schema =
    \\(plugin :name p :version "1.0.0"
    \\  (form :name scene
    \\    (key :name title :type string)
    \\    (key :name fps :type number :default 60)))
;

/// The hint whose label is exactly `label`, or null. Tests match by label
/// because a bare head also draws a plugin-name hint.
fn findHint(hints: []const Handler.InlayHint, label: []const u8) ?Handler.InlayHint {
    for (hints) |hint| {
        if (std.mem.eql(u8, hint.label, label)) return hint;
    }
    return null;
}

/// The first hint whose label starts with `prefix`, or null. For the
/// truncation case, where the point is that the label is *not* known.
fn findHintPrefixed(hints: []const Handler.InlayHint, prefix: []const u8) ?Handler.InlayHint {
    for (hints) |hint| {
        if (std.mem.startsWith(u8, hint.label, prefix)) return hint;
    }
    return null;
}

test "inlay hints show omitted literal default as :key value" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try installSchema(&fx, scene_schema);
    //                       1111111
    //             01234567890123456
    const src = "(scene :title \"x\")";
    try h.openDocument("file:///a.sjon", 1, src);

    const hints = (try h.getInlayHints(fx.arena(), "file:///a.sjon", 0, @intCast(src.len))).?;
    const hint = findHint(hints, ":fps 60") orelse return error.TestMissingDefaultHint;
    // Before the closing paren — the position the key would occupy if the
    // author wrote it, which is also where CP3's action inserts it.
    try std.testing.expectEqual(@as(u32, 17), hint.offset);
    try std.testing.expectEqual(src[17], ')');
    try std.testing.expect(hint.padding_left);
    try std.testing.expectEqual(Handler.InlayHint.Kind.parameter, hint.kind.?);
}

test "inlay hints show evaluated expression default value" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // The hint shows what the default *evaluates to* (32), not its source
    // text `(* 2 16)` — hover already shows the source, and the point of
    // materialization is the value the document effectively carries.
    const manifest =
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name fps :type number :default (* 2 16))))
    ;
    try installSchema(&fx, manifest);
    try h.openDocument("file:///a.sjon", 1, "(scene)");

    const hints = (try h.getInlayHints(fx.arena(), "file:///a.sjon", 0, 7)).?;
    try std.testing.expect(findHint(hints, ":fps 32") != null);
    try std.testing.expect(findHintPrefixed(hints, ":fps (") == null);
}

test "no default hint when the key is written" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try installSchema(&fx, scene_schema);
    const src = "(scene :title \"x\" :fps 30)";
    try h.openDocument("file:///a.sjon", 1, src);

    const hints = (try h.getInlayHints(fx.arena(), "file:///a.sjon", 0, @intCast(src.len))).?;
    try std.testing.expect(findHintPrefixed(hints, ":fps") == null);
}

test "default hints clip to the requested range" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try installSchema(&fx, scene_schema);
    // `(scene)` twice: closing parens at 6 and 14.
    const src = "(scene)\n(scene)";
    try h.openDocument("file:///a.sjon", 1, src);

    // Range covering the first line only.
    const hints = (try h.getInlayHints(fx.arena(), "file:///a.sjon", 0, 8)).?;
    var count: usize = 0;
    for (hints) |hint| {
        if (std.mem.startsWith(u8, hint.label, ":fps")) {
            count += 1;
            try std.testing.expectEqual(@as(u32, 6), hint.offset);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), count);

    // Counter-check: the whole document really does have two.
    const all = (try h.getInlayHints(fx.arena(), "file:///a.sjon", 0, @intCast(src.len))).?;
    var all_count: usize = 0;
    for (all) |hint| {
        if (std.mem.startsWith(u8, hint.label, ":fps")) all_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), all_count);
}

test "default hints coexist with plugin-name hints" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try installSchema(&fx, scene_schema);
    try h.openDocument("file:///a.sjon", 1, "(scene)");

    const hints = (try h.getInlayHints(fx.arena(), "file:///a.sjon", 0, 7)).?;
    // The plugin-name hint stays unkinded — it predates this feature and
    // adding a kind would change how shipping clients render it.
    const plugin_hint = findHint(hints, "p") orelse return error.TestMissingPluginHint;
    try std.testing.expect(plugin_hint.kind == null);
    try std.testing.expect(findHint(hints, ":fps 60") != null);
}

test "long default values truncate in the hint label" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const manifest =
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name note :type string
        \\      :default "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")))
    ;
    try installSchema(&fx, manifest);
    try h.openDocument("file:///a.sjon", 1, "(scene)");

    const hints = (try h.getInlayHints(fx.arena(), "file:///a.sjon", 0, 7)).?;
    const hint = findHintPrefixed(hints, ":note ") orelse return error.TestMissingDefaultHint;
    try std.testing.expect(std.mem.endsWith(u8, hint.label, "…"));
    try std.testing.expect(hint.label.len <= ":note ".len + Handler.MAX_HINT_VALUE_BYTES + "…".len);
}

// ---------------------------------------------------------------------------
// Materialize-defaults code action (plan 04 CP3) — writes the overlay into
// the document. Unlike every other action here it is not bound to a
// diagnostic: nothing is wrong with a form that relies on its defaults.
// ---------------------------------------------------------------------------

/// Two defaulted keys on `scene` (to pin schema order) and one on a
/// `layer` that nests inside it (to pin cursor scoping).
const nested_defaults_schema =
    \\(plugin :name p :version "1.0.0"
    \\  (form :name scene
    \\    (key :name fps :type number :default 60)
    \\    (key :name depth :type number :default 3))
    \\  (form :name layer
    \\    (key :name alpha :type number :default 1)))
;

fn findAction(actions: []const Handler.CodeAction, title: []const u8) ?Handler.CodeAction {
    for (actions) |act| {
        if (std.mem.eql(u8, act.title, title)) return act;
    }
    return null;
}

const materialize_title = "Materialize omitted defaults";

test "materialize-defaults action inserts all omitted defaulted keys" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try installSchema(&fx, nested_defaults_schema);
    const src = "(scene)";
    try h.openDocument("file:///a.sjon", 1, src);

    const actions = (try h.getCodeActions(fx.arena(), "file:///a.sjon", 1, 1)).?;
    const act = findAction(actions, materialize_title) orelse
        return error.TestMissingMaterializeAction;

    // One atomic edit, not one per key: a half-applied materialization is
    // never something the user asked for.
    try std.testing.expectEqual(@as(usize, 1), act.edits.len);
    const edit = act.edits[0];
    // Pure insertion immediately before the closing paren at index 6.
    try std.testing.expectEqual(@as(u32, 6), edit.span_start);
    try std.testing.expectEqual(@as(u32, 6), edit.span_end);
    // Schema order, not overlay-happenstance order.
    try std.testing.expectEqualStrings(" :fps 60 :depth 3", edit.new_text);

    // The edit applied by hand reproduces a document that parses and no
    // longer needs materializing — the round-trip the client performs.
    const applied = try std.fmt.allocPrint(fx.arena(), "{s}{s}{s}", .{
        src[0..edit.span_start], edit.new_text, src[edit.span_end..],
    });
    try std.testing.expectEqualStrings("(scene :fps 60 :depth 3)", applied);
}

test "materialize-defaults action scopes to the form under the cursor" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try installSchema(&fx, nested_defaults_schema);
    //             0123456789...
    const src = "(scene (layer))";
    try h.openDocument("file:///a.sjon", 1, src);

    // Cursor inside `(layer)` — byte 8 is its head.
    const inner = (try h.getCodeActions(fx.arena(), "file:///a.sjon", 8, 8)).?;
    const inner_act = findAction(inner, materialize_title) orelse
        return error.TestMissingMaterializeAction;
    try std.testing.expectEqualStrings(" :alpha 1", inner_act.edits[0].new_text);
    // `layer`'s closing paren, not `scene`'s.
    try std.testing.expectEqual(@as(u32, 13), inner_act.edits[0].span_start);

    // Cursor on `scene`'s head offers scene's keys instead.
    const outer = (try h.getCodeActions(fx.arena(), "file:///a.sjon", 2, 2)).?;
    const outer_act = findAction(outer, materialize_title) orelse
        return error.TestMissingMaterializeAction;
    try std.testing.expectEqualStrings(" :fps 60 :depth 3", outer_act.edits[0].new_text);
}

test "no materialize action on a form with nothing omitted" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try installSchema(&fx, nested_defaults_schema);
    try h.openDocument("file:///a.sjon", 1, "(scene :fps 30 :depth 9)");

    const actions = (try h.getCodeActions(fx.arena(), "file:///a.sjon", 2, 2)).?;
    try std.testing.expect(findAction(actions, materialize_title) == null);
}

test "materialize-defaults action kind is refactor, not quickfix" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try installSchema(&fx, nested_defaults_schema);
    try h.openDocument("file:///a.sjon", 1, "(scene)");

    const actions = (try h.getCodeActions(fx.arena(), "file:///a.sjon", 1, 1)).?;
    const act = findAction(actions, materialize_title) orelse
        return error.TestMissingMaterializeAction;
    // Nothing is wrong with the document, so it must not appear in the
    // lightbulb's quickfix section next to real errors.
    try std.testing.expectEqual(Handler.CodeAction.Kind.refactor_rewrite, act.kind);
    try std.testing.expectEqual(@as(usize, 0), act.diagnostics.len);

    // Counter-check: a genuine fix in the same document keeps `quickfix`.
    try h.openDocument("file:///b.sjon", 1, "(clmp 1 0 2)");
    const fixes = (try h.getCodeActions(fx.arena(), "file:///b.sjon", 1, 5)).?;
    try std.testing.expect(fixes.len > 0);
    try std.testing.expectEqual(Handler.CodeAction.Kind.quickfix, fixes[0].kind);
}

// ---------------------------------------------------------------------------
// Effective document (plan 04 CP4) — the source with every form's defaults
// spliced in. CP3's action applied to the whole document at once.
// ---------------------------------------------------------------------------

test "effective document splices all defaults into the source" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try installSchema(&fx, nested_defaults_schema);
    try h.openDocument("file:///a.sjon", 1, "(scene (layer))");

    const text = (try h.getEffectiveDocument(fx.arena(), "file:///a.sjon")).?;
    // Both forms materialized, each before its own closing paren. The
    // inner insertion must not disturb the outer one's offset — hence
    // back-to-front application.
    try std.testing.expectEqualStrings("(scene (layer :alpha 1) :fps 60 :depth 3)", text);
}

test "effective document of a doc with no defaults is byte-identical" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try installSchema(&fx, nested_defaults_schema);
    // Every defaulted key written out: nothing left to materialize.
    const src = "(scene :fps 1 :depth 2)";
    try h.openDocument("file:///a.sjon", 1, src);

    const text = (try h.getEffectiveDocument(fx.arena(), "file:///a.sjon")).?;
    try std.testing.expectEqualStrings(src, text);
}

test "effective document round-trips through the parser" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try installSchema(&fx, nested_defaults_schema);
    try h.openDocument("file:///a.sjon", 1, "(scene (layer))");

    // The point of the view is to be readable *as SJON*. If splicing ever
    // produced text the parser rejects, a virtual document showing it
    // would be worse than none.
    const text = (try h.getEffectiveDocument(fx.arena(), "file:///a.sjon")).?;
    const owned = try fx.arena().dupeZ(u8, text);
    var tree = try sjon.Parser.parse(a, owned);
    defer tree.deinit();
    try std.testing.expect(!tree.hasErrors());
}

test "effective document round-trips a default carrying escape-needing bytes" {
    // The sibling round-trip test above uses defaults with nothing to
    // escape, so it stayed green while the splicer emitted raw bytes.
    // Manifest defaults arrive escape-decoded, so this `:title` default is
    // the four-byte string `a"b\` by the time it is spliced — verbatim, it
    // closes the string early and writes a syntax error into the document
    // the client is about to show (and, via the materialize action, into
    // the user's actual file).
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try installSchema(&fx,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name title :type string :default "a\"b\\")))
    );
    try h.openDocument("file:///a.sjon", 1, "(scene)");

    const text = (try h.getEffectiveDocument(fx.arena(), "file:///a.sjon")).?;
    const owned = try fx.arena().dupeZ(u8, text);
    var tree = try sjon.Parser.parse(a, owned);
    defer tree.deinit();
    try std.testing.expect(!tree.hasErrors());

    // …and it round-trips to the same value, not merely to *something*
    // parseable.
    const form = tree.formHeader(tree.root[0]);
    var found: ?[]const u8 = null;
    for (form.children) |child| {
        if (tree.tagOf(child) != .kvpair) continue;
        const kv = tree.kvpairHeader(child);
        if (std.mem.eql(u8, kv.key, "title")) found = tree.stringText(kv.value);
    }
    try std.testing.expectEqualStrings("a\"b\\", found orelse return error.TestMissingSplicedKey);
}

test "effective document is null for an unopened uri" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    try std.testing.expect((try fx.h.getEffectiveDocument(fx.arena(), "file:///nope.sjon")) == null);
}

// ---------------------------------------------------------------------------
// Evaluated values (`evalExpressionAt`)
// ---------------------------------------------------------------------------

/// A plugin declaring an expr func with no `impl` — the "validator
/// recognises it, the evaluator cannot run it" shape (`Expr.zig:28-33`).
///
/// Deliberately distinct from `core`'s `let` / `if` / `map`, which also
/// carry `impl == null` but *are* evaluable: the frame machinery handles
/// them by name. `impl == null` is therefore not a test for "can't be
/// evaluated" — only attempting the evaluation is.
fn declarationOnlyExprPlugin() sjon.Plugin.Plugin {
    return .{
        .name = "gfx",
        .expr_funcs = &.{
            .{
                .name = "noise",
                .arity = .{ .fixed = 1 },
                .params = &.{.number},
                .result = .number,
                .description = "Declared for validation; no native implementation.",
            },
        },
    };
}

/// A data form with a numeric key — the shape a real document has, where
/// every expression worth evaluating is nested inside something that is
/// not one.
fn nestedExprSchemaPlugin() sjon.Plugin.Plugin {
    return .{
        .name = "test",
        .forms = &.{
            .{
                .name = "scene",
                .keys = &.{
                    .{ .name = "fps", .value_type = .number, .optional = true },
                },
            },
        },
    };
}

test "eval at cursor computes arithmetic" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try h.openDocument("file:///a.sjon", 1, "(+ 1 2)");

    const v = (try h.evalExpressionAt(fx.arena(), "file:///a.sjon", 1, Handler.LSP_EVAL_BYTES)).?;
    try std.testing.expectEqualStrings("3", v);
}

test "eval computes vector constructors" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try h.openDocument("file:///a.sjon", 1, "(vec3 1 2 3)");

    const v = (try h.evalExpressionAt(fx.arena(), "file:///a.sjon", 1, Handler.LSP_EVAL_BYTES)).?;
    try std.testing.expectEqualStrings("[1 2 3]", v);
}

test "eval resolves let bindings" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    //           0         1
    //           0123456789012345678
    const src = "(let [x 2] (* x 3))";
    try h.openDocument("file:///a.sjon", 1, src);

    // Byte 14 is the `x` in `(* x 3)`. The smallest enclosing form is
    // `(* x 3)`, which alone raises `UnknownBinding` — only the outermost
    // enclosing expression carries the binding that makes it evaluable.
    const v = (try h.evalExpressionAt(fx.arena(), "file:///a.sjon", 14, Handler.LSP_EVAL_BYTES)).?;
    try std.testing.expectEqualStrings("6", v);
}

test "eval returns null on budget trip" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // Bounded steps, unbounded-without-the-cap memory — the shape
    // `Expr_tests` uses to drive `MemoryBudgetExceeded` deterministically.
    const src = "(map [x] [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63] (vec4 x x x x))";
    try h.openDocument("file:///a.sjon", 1, src);

    try std.testing.expect((try h.evalExpressionAt(fx.arena(), "file:///a.sjon", 1, 1024)) == null);

    // Control: the same expression under the production budget evaluates,
    // so the null above is the budget and not the expression.
    try std.testing.expect((try h.evalExpressionAt(fx.arena(), "file:///a.sjon", 1, Handler.LSP_EVAL_BYTES)) != null);
}

test "eval returns null for declaration-only plugin funcs" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    h.schema = .init(&.{ declarationOnlyExprPlugin(), sjon.plugins.core.plugin });
    try h.openDocument("file:///a.sjon", 1, "(+ 1 (noise 2))");

    // Pin the reason: the document is diagnostic-clean, so a null result
    // is the evaluator declining to run `noise` and not the
    // has-diagnostics gate tripping first.
    const diags = (try h.getDiagnostics(fx.arena(), "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 0), diags.len);

    try std.testing.expect((try h.evalExpressionAt(fx.arena(), "file:///a.sjon", 1, Handler.LSP_EVAL_BYTES)) == null);
}

test "eval returns null outside any expression" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    h.schema = .init(&.{ audioSchemaPlugin(), sjon.plugins.core.plugin });

    // A bare literal: no enclosing form at all.
    try h.openDocument("file:///lit.sjon", 1, "42");
    try std.testing.expect((try h.evalExpressionAt(fx.arena(), "file:///lit.sjon", 0, Handler.LSP_EVAL_BYTES)) == null);

    // Inside a data form: `phrase` is a `FormSpec`, not an expr func, and
    // a data form has no value to compute.
    try h.openDocument("file:///d.sjon", 1, "(phrase :name intro)");
    try std.testing.expect((try h.evalExpressionAt(fx.arena(), "file:///d.sjon", 14, Handler.LSP_EVAL_BYTES)) == null);
}

test "eval returns null when the expression has diagnostics" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // Unclosed. Parser recovery still yields a complete `(+ 1 2)` form, so
    // evaluation would happily report `3` for text the author has not
    // finished writing — the gate is the only thing that stops it.
    try h.openDocument("file:///a.sjon", 1, "(+ 1 2");

    const diags = (try h.getDiagnostics(fx.arena(), "file:///a.sjon")).?;
    try std.testing.expect(diags.len > 0);

    try std.testing.expect((try h.evalExpressionAt(fx.arena(), "file:///a.sjon", 1, Handler.LSP_EVAL_BYTES)) == null);
}

test "hover on an expression appends = value" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try h.openDocument("file:///a.sjon", 1, "(scene :fps (+ 1 2))");

    // Byte 13 is the `+`. The hover keeps its schema section and gains
    // the computed value beneath it.
    const hov = (try h.getHover(fx.arena(), "file:///a.sjon", 13)).?;
    try std.testing.expect(std.mem.indexOf(u8, hov.contents, "core") != null);
    try std.testing.expect(std.mem.indexOf(u8, hov.contents, "**=** `3`") != null);
}

test "hover truncates long values with an ellipsis" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    const src = "(map [x] [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63] (vec4 x x x x))";
    try h.openDocument("file:///a.sjon", 1, src);

    const arena = fx.arena();
    const full = (try h.evalExpressionAt(arena, "file:///a.sjon", 1, Handler.LSP_EVAL_BYTES)).?;
    try std.testing.expect(full.len > Handler.MAX_HOVER_VALUE_BYTES);

    const hov = (try h.getHover(arena, "file:///a.sjon", 1)).?;
    // A prefix exactly `MAX_HOVER_VALUE_BYTES` long survives (the value is
    // pure ASCII, so the codepoint-boundary backoff is a no-op here), the
    // whole value does not, and the elision is visible.
    try std.testing.expect(std.mem.indexOf(u8, hov.contents, full[0..Handler.MAX_HOVER_VALUE_BYTES]) != null);
    try std.testing.expect(std.mem.indexOf(u8, hov.contents, full) == null);
    try std.testing.expect(std.mem.indexOf(u8, hov.contents, "…") != null);
}

test "hover on a data form has no value section" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    h.schema = .init(&.{ audioSchemaPlugin(), sjon.plugins.core.plugin });
    try h.openDocument("file:///a.sjon", 1, "(phrase :name intro)");

    const hov = (try h.getHover(fx.arena(), "file:///a.sjon", 1)).?;
    try std.testing.expect(std.mem.indexOf(u8, hov.contents, "phrase") != null);
    try std.testing.expect(std.mem.indexOf(u8, hov.contents, "**=**") == null);
}

test "hover on a broken expression has no value section" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try h.openDocument("file:///a.sjon", 1, "(+ 1 2");

    // The schema section still renders — hover on an unfinished expression
    // is exactly when its signature is most useful — but nothing claims to
    // know what it evaluates to.
    const hov = (try h.getHover(fx.arena(), "file:///a.sjon", 1)).?;
    try std.testing.expect(std.mem.indexOf(u8, hov.contents, "core") != null);
    try std.testing.expect(std.mem.indexOf(u8, hov.contents, "**=**") == null);
}

test "hover renders a value containing backticks as inert text" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // The hover is markdown and this section is built from document
    // content, so a value carrying backticks must widen its own fence
    // rather than close the code span early and let the rest render as
    // markup.
    try h.openDocument("file:///a.sjon", 1, "(if true \"a`b\" 1)");

    const hov = (try h.getHover(fx.arena(), "file:///a.sjon", 1)).?;
    try std.testing.expect(std.mem.indexOf(u8, hov.contents, "**=** ``\"a`b\"``") != null);
}

test "evalDocument returns one entry per top-level expression root" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    h.schema = .init(&.{ audioSchemaPlugin(), sjon.plugins.core.plugin });

    //           0         1         2         3
    //           0123456789012345678901234567890123456
    const src = "(+ 1 2)\n(phrase :name intro)\n(* 2 3)";
    try h.openDocument("file:///a.sjon", 1, src);

    const entries = (try h.evalDocument(fx.arena(), "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 2), entries.len);

    // Document order, and the data form between them contributes nothing.
    try std.testing.expectEqual(@as(u32, 0), entries[0].span_start);
    try std.testing.expectEqualStrings("3", entries[0].outcome.value);
    try std.testing.expectEqual(@as(u32, 29), entries[1].span_start);
    try std.testing.expectEqualStrings("6", entries[1].outcome.value);
}

test "evalDocument descends into data forms for nested expressions" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    h.schema = .init(&.{ nestedExprSchemaPlugin(), sjon.plugins.core.plugin });

    // An expression inside a data form is still a root — it is the
    // outermost *expression* around itself, which is the unit that has a
    // value. Documents in the wild are data forms with expressions in
    // them; entries only for document-level expressions would leave the
    // panel empty for almost every real file.
    //           0         1
    //           012345678901234567890
    const src = "(scene :fps (+ 1 2))";
    try h.openDocument("file:///a.sjon", 1, src);

    const entries = (try h.evalDocument(fx.arena(), "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(u32, 12), entries[0].span_start);
    try std.testing.expectEqual(@as(u32, 19), entries[0].span_end);
    try std.testing.expectEqualStrings("3", entries[0].outcome.value);
}

test "evalDocument marks failed roots with an error kind, not a value" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    h.schema = .init(&.{ declarationOnlyExprPlugin(), sjon.plugins.core.plugin });
    try h.openDocument("file:///a.sjon", 1, "(noise 2)\n(/ 1 0)");

    const entries = (try h.evalDocument(fx.arena(), "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 2), entries.len);

    // Declared but not implemented here — a different answer from "this
    // expression is wrong", because the fix is a different one.
    try std.testing.expectEqual(Handler.EvalEntry.Failure.unsupported, entries[0].outcome.failure);
    try std.testing.expectEqual(Handler.EvalEntry.Failure.failed, entries[1].outcome.failure);
}

test "evalDocument marks a root the parser had to repair as invalid" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    try h.openDocument("file:///a.sjon", 1, "(+ 1 2");

    const entries = (try h.evalDocument(fx.arena(), "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(Handler.EvalEntry.Failure.invalid, entries[0].outcome.failure);
}

test "evalDocument shares one budget across the whole document" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // Two roots, each individually affordable. A per-root budget would
    // let a document of N of these cost N × the cap; the whole-document
    // budget stops at the ceiling and marks the rest.
    const heavy = "(map [x] [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31] (vec4 x x x x))";
    const src = try std.fmt.allocPrint(a, "{s}\n{s}", .{ heavy, heavy });
    defer a.free(src);
    try h.openDocument("file:///a.sjon", 1, src);

    // One root costs ~44 KiB of result arena, so a 50 KiB pool affords
    // the first and leaves the second short. Both assertions matter: the
    // value pins that the pool was actually spent rather than never
    // opened, and the failure pins that spending it was not free.
    const entries = (try h.evalDocumentWithBudget(fx.arena(), "file:///a.sjon", 50_000)).?;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expect(entries[0].outcome == .value);
    try std.testing.expectEqual(Handler.EvalEntry.Failure.limit, entries[1].outcome.failure);
}

test "evalDocument is null for an unopened uri" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    try std.testing.expect((try fx.h.evalDocument(fx.arena(), "file:///nope.sjon")) == null);
}

// ---------------------------------------------------------------------------
// Semantic tokens — schema-aware classification over the whole tree.
// ---------------------------------------------------------------------------

/// Plugin exercising the key and member axes: one form with declared
/// keys, one of them typed by a member-set value-kind that carries a
/// deprecated entry.
fn tokenVocabPlugin() sjon.Plugin.Plugin {
    const space_kind: sjon.Plugin.ValueKind = .{
        .name = "space",
        .underlying = .symbol,
        .members = .{ .members = &.{
            .{ .name = "rgb" },
            .{ .name = "yuv", .deprecated = true },
        } },
    };
    return .{
        .name = "paint",
        .value_kinds = &.{space_kind},
        .forms = &.{
            .{
                .name = "swatch",
                .keys = &.{
                    .{ .name = "space", .value_type = .{ .named = .{ .name = "space" } }, .optional = true },
                    .{ .name = "hex", .value_type = .string, .optional = true },
                },
            },
        },
    };
}

/// The source text a token covers — tests read against the document
/// rather than against byte arithmetic.
fn tokText(src: []const u8, t: Handler.SemanticToken) []const u8 {
    return src[t.span_start..t.span_end];
}

/// The first token covering exactly `text`. Panics when absent: a token
/// that never got classified is a failure worth naming at the point it
/// happened, not an optional unwrapped three lines later.
fn findToken(
    src: []const u8,
    toks: []const Handler.SemanticToken,
    text: []const u8,
) Handler.SemanticToken {
    for (toks) |t| {
        if (std.mem.eql(u8, tokText(src, t), text)) return t;
    }
    std.debug.panic("no semantic token covering '{s}' among {d} tokens", .{ text, toks.len });
}

/// True when nothing covers `text` — the assertion for "this stays
/// uncoloured", where the diagnostic squiggle carries the story instead.
fn noToken(src: []const u8, toks: []const Handler.SemanticToken, text: []const u8) bool {
    for (toks) |t| {
        if (std.mem.eql(u8, tokText(src, t), text)) return false;
    }
    return true;
}

test "semantic tokens classify data-form and expr-func heads" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ mixedVocabPlugin(), sjon.plugins.core.plugin });

    const src = "(widget)\n(emit 1)";
    try h.openDocument("file:///a.sjon", 1, src);

    const toks = (try h.getSemanticTokens(fx.arena(), "file:///a.sjon")).?;
    try std.testing.expectEqual(
        Handler.SemanticToken.Type.macro,
        findToken(src, toks, "widget").type,
    );
    try std.testing.expectEqual(
        Handler.SemanticToken.Type.function,
        findToken(src, toks, "emit").type,
    );
}

test "semantic tokens mark core expr-funcs as defaultLibrary" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ mixedVocabPlugin(), sjon.plugins.core.plugin });

    const src = "(emit 1)\n(+ 1 2)";
    try h.openDocument("file:///a.sjon", 1, src);

    const toks = (try h.getSemanticTokens(fx.arena(), "file:///a.sjon")).?;
    // Same token type, different provenance: `defaultLibrary` is what
    // lets a theme dim the always-available core vocabulary against the
    // functions this document's own plugins brought.
    const user = findToken(src, toks, "emit");
    const core = findToken(src, toks, "+");
    try std.testing.expectEqual(Handler.SemanticToken.Type.function, core.type);
    try std.testing.expect(!user.mods.default_library);
    try std.testing.expect(core.mods.default_library);
}

test "semantic tokens split qualified heads into namespace + head" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ mixedVocabPlugin(), sjon.plugins.core.plugin });

    //           0123456789...
    const src = "(mix/widget)";
    try h.openDocument("file:///a.sjon", 1, src);

    const toks = (try h.getSemanticTokens(fx.arena(), "file:///a.sjon")).?;
    const ns = findToken(src, toks, "mix");
    const head = findToken(src, toks, "widget");
    try std.testing.expectEqual(Handler.SemanticToken.Type.namespace, ns.type);
    try std.testing.expectEqual(Handler.SemanticToken.Type.macro, head.type);
    // The `/` belongs to neither token — spans are disjoint, which the
    // transport's relative encoding requires.
    try std.testing.expectEqual(@as(u32, 1), ns.span_start);
    try std.testing.expectEqual(@as(u32, 4), ns.span_end);
    try std.testing.expectEqual(@as(u32, 5), head.span_start);
    try std.testing.expectEqual(@as(u32, 11), head.span_end);
}

test "semantic tokens classify known keys, skip unknown keys" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ tokenVocabPlugin(), sjon.plugins.core.plugin });

    const src = "(swatch :hex \"#fff\" :nope 1)";
    try h.openDocument("file:///a.sjon", 1, src);

    const toks = (try h.getSemanticTokens(fx.arena(), "file:///a.sjon")).?;
    // The colon is part of the token: `:hex` reads as one thing.
    try std.testing.expectEqual(
        Handler.SemanticToken.Type.property,
        findToken(src, toks, ":hex").type,
    );
    try std.testing.expect(noToken(src, toks, ":nope"));
}

test "semantic tokens classify member symbols and deprecated members" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ tokenVocabPlugin(), sjon.plugins.core.plugin });

    const src = "(swatch :space rgb)\n(swatch :space yuv)";
    try h.openDocument("file:///a.sjon", 1, src);

    const toks = (try h.getSemanticTokens(fx.arena(), "file:///a.sjon")).?;
    const live = findToken(src, toks, "rgb");
    const gone = findToken(src, toks, "yuv");
    try std.testing.expectEqual(Handler.SemanticToken.Type.enum_member, live.type);
    try std.testing.expectEqual(Handler.SemanticToken.Type.enum_member, gone.type);
    try std.testing.expect(!live.mods.deprecated);
    try std.testing.expect(gone.mods.deprecated);
}

test "semantic tokens mark cross-ref definitions with declaration, references without" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ audioSchemaPlugin(), sjon.plugins.core.plugin });

    const src = "(phrase :name p0)\n(track :sequence [p0])";
    try h.openDocument("file:///a.sjon", 1, src);

    const toks = (try h.getSemanticTokens(fx.arena(), "file:///a.sjon")).?;
    var seen: usize = 0;
    for (toks) |t| {
        if (!std.mem.eql(u8, tokText(src, t), "p0")) continue;
        try std.testing.expectEqual(Handler.SemanticToken.Type.variable, t.type);
        // Document order, so the definition in `(phrase …)` comes first
        // and the use in `(track …)` second.
        try std.testing.expectEqual(seen == 0, t.mods.declaration);
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
}

test "semantic tokens skip unknown heads" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ mixedVocabPlugin(), sjon.plugins.core.plugin });

    const src = "(widget)\n(wibble)";
    try h.openDocument("file:///a.sjon", 1, src);

    const toks = (try h.getSemanticTokens(fx.arena(), "file:///a.sjon")).?;
    // No colour where the squiggle already speaks — but the walk did run,
    // so the absence is a classification decision and not an empty result.
    try std.testing.expect(noToken(src, toks, "wibble"));
    try std.testing.expect(!noToken(src, toks, "widget"));
}

test "semantic tokens are sorted by span start" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{ tokenVocabPlugin(), sjon.plugins.core.plugin });

    // Every family in one document, so the ordering has something to do:
    // heads, a qualified head, keys, a member, and a core expr-func.
    const src =
        \\(swatch :space rgb :hex "#fff")
        \\(+ 1 2)
        \\(paint/swatch :hex "#000")
    ;
    try h.openDocument("file:///a.sjon", 1, src);

    const toks = (try h.getSemanticTokens(fx.arena(), "file:///a.sjon")).?;
    try std.testing.expect(toks.len >= 8);
    // The transport encodes each token as a delta from the previous one,
    // so both properties are load-bearing there: ascending, and disjoint.
    for (toks[1..], toks[0 .. toks.len - 1]) |cur, prev| {
        try std.testing.expect(prev.span_start < cur.span_start);
        try std.testing.expect(prev.span_end <= cur.span_start);
    }
}
test "semantic tokens are empty when nothing resolves" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    h.schema = .init(&.{});

    // Not in the plan's red list, but the sortedness post-condition walks
    // pairs and an empty result has none — the first version indexed
    // `toks[1..]` unguarded and panicked here rather than returning the
    // colourless document that an all-unknown source legitimately is.
    try h.openDocument("file:///a.sjon", 1, "(wibble)");
    const toks = (try h.getSemanticTokens(fx.arena(), "file:///a.sjon")).?;
    try std.testing.expectEqual(@as(usize, 0), toks.len);
}

test "semantic tokens are null for an unopened uri" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    try std.testing.expect((try fx.h.getSemanticTokens(fx.arena(), "file:///nope.sjon")) == null);
}

test "semantic tokens colour a member that is also a cross-ref once" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;

    // `members` and `cross_ref` are both "meaningful when underlying ==
    // .symbol", so one kind may carry both and a single span is then a
    // member *and* a reference. Two tokens over one span is not a shape
    // the relative wire encoding has — and the sortedness post-condition
    // asserts disjointness, so emitting both would panic rather than
    // merely mis-colour.
    const kind: sjon.Plugin.ValueKind = .{
        .name = "tag",
        .underlying = .symbol,
        .members = .{ .members = &.{.{ .name = "p0" }} },
        .cross_ref = .{ .targets = &.{"phrase"} },
    };
    const plugin: sjon.Plugin.Plugin = .{
        .name = "both",
        .value_kinds = &.{kind},
        .forms = &.{
            .{ .name = "phrase", .keys = &.{.{ .name = "name", .value_type = .symbol }} },
            .{ .name = "use", .keys = &.{.{ .name = "tag", .value_type = .{ .named = .{ .name = "tag" } } }} },
        },
    };
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    const src = "(phrase :name p0)\n(use :tag p0)";
    try h.openDocument("file:///a.sjon", 1, src);

    const toks = (try h.getSemanticTokens(fx.arena(), "file:///a.sjon")).?;
    var seen: usize = 0;
    for (toks) |t| {
        if (!std.mem.eql(u8, tokText(src, t), "p0")) continue;
        // The cross-ref reading wins: it is the one that says something
        // the member reading doesn't, since membership follows from it.
        try std.testing.expectEqual(Handler.SemanticToken.Type.variable, t.type);
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
}

test "semantic token legends are the wire order clients were told" {
    // Literal, not derived from the enum. A reorder that moved a variant
    // and its legend entry together would keep every derived check green
    // while every already-connected client silently recoloured — these
    // indices and bits are published, so changing one is a wire break
    // rather than a refactor.
    const want_types = [_][]const u8{
        "namespace", "macro", "function", "property", "enumMember", "variable",
    };
    try std.testing.expectEqual(want_types.len, Handler.SemanticToken.Type.legend.len);
    for (want_types, Handler.SemanticToken.Type.legend) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }

    const want_mods = [_][]const u8{ "declaration", "defaultLibrary", "deprecated" };
    try std.testing.expectEqual(want_mods.len, Handler.SemanticToken.Mods.legend.len);
    for (want_mods, Handler.SemanticToken.Mods.legend) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }

    // The indices and bits themselves, since the legend only names them.
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(Handler.SemanticToken.Type.macro));
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(Handler.SemanticToken.Type.variable));
    const mods: Handler.SemanticToken.Mods = .{ .default_library = true };
    try std.testing.expectEqual(@as(u32, 0b010), mods.bits());
}

// ---------------------------------------------------------------------------
// Workspace diagnostics (plan 06 CP1)
// ---------------------------------------------------------------------------

test "workspace diagnostics cover injected unopened files" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // Nothing is open. The only file the handler knows about arrived
    // through the provider seam.
    _ = try h.ingestWorkspaceFiles(&.{
        .{ .uri = "file:///disk.sjon", .source = "(nope)" },
    });

    const reports = try h.getWorkspaceDiagnostics(fx.arena());
    try std.testing.expectEqual(@as(usize, 1), reports.len);
    try std.testing.expectEqualStrings("file:///disk.sjon", reports[0].uri);
    // Never opened, so there is no client-supplied version to report.
    try std.testing.expectEqual(@as(?i64, null), reports[0].version);
    try std.testing.expectEqual(@as(usize, 1), reports[0].diagnostics.len);
    try std.testing.expectEqualStrings("unknown_form", reports[0].diagnostics[0].code);
}

test "open-document text shadows its on-disk version" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // The editor holds a clean buffer; disk still has the broken form the
    // user just fixed. The buffer is the truth.
    try h.openDocument("file:///a.sjon", 7, "(phrase :name p0)");
    _ = try h.ingestWorkspaceFiles(&.{
        .{ .uri = "file:///a.sjon", .source = "(nope)" },
    });

    const reports = try h.getWorkspaceDiagnostics(fx.arena());
    try std.testing.expectEqual(@as(usize, 1), reports.len);
    try std.testing.expectEqual(@as(?i64, 7), reports[0].version);
    try std.testing.expectEqual(@as(usize, 0), reports[0].diagnostics.len);
}

test "workspace diagnostics carry per-file resultIds keyed on version + schema generation" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });
    const arena = fx.arena();

    try h.openDocument("file:///open.sjon", 3, "(phrase :name p0)");
    _ = try h.ingestWorkspaceFiles(&.{
        .{ .uri = "file:///disk.sjon", .source = "(phrase :name p1)" },
    });

    const first = try h.getWorkspaceDiagnostics(arena);
    try std.testing.expectEqual(@as(usize, 2), first.len);

    // An open document's id must be byte-identical to the one
    // `textDocument/diagnostic` publishes for it, or the two requests'
    // caches disagree about the same file.
    const open_id = reportFor(first, "file:///open.sjon").result_id;
    const want_open = try std.fmt.allocPrint(arena, "{d}:{d}", .{ @as(i64, 3), h.schema_generation });
    try std.testing.expectEqualStrings(want_open, open_id);

    // An unopened file has no version, so its id must key on content:
    // a disk edit the client didn't drive still has to invalidate.
    const disk_id = try arena.dupe(u8, reportFor(first, "file:///disk.sjon").result_id);
    _ = try h.ingestWorkspaceFiles(&.{
        .{ .uri = "file:///disk.sjon", .source = "(phrase :name p2)" },
    });
    const second = try h.getWorkspaceDiagnostics(arena);
    try std.testing.expect(!std.mem.eql(u8, disk_id, reportFor(second, "file:///disk.sjon").result_id));

    // A schema swap changes every id, open and on-disk alike.
    const disk_id2 = try arena.dupe(u8, reportFor(second, "file:///disk.sjon").result_id);
    const open_id2 = try arena.dupe(u8, reportFor(second, "file:///open.sjon").result_id);
    h.schema_generation +%= 1;
    const third = try h.getWorkspaceDiagnostics(arena);
    try std.testing.expect(!std.mem.eql(u8, disk_id2, reportFor(third, "file:///disk.sjon").result_id));
    try std.testing.expect(!std.mem.eql(u8, open_id2, reportFor(third, "file:///open.sjon").result_id));
}

// ---------------------------------------------------------------------------
// URI spelling
//
// The workspace scanner and the client each build a URI for the same file
// and do not agree on which bytes to percent-encode: `pathToFileUri` encodes
// everything outside RFC 3986's unreserved set, vscode-uri leaves
// `( ) ! ' * + @ = , ;` literal. Under byte-exact keys the file exists twice.
// ---------------------------------------------------------------------------

test "one file, two URI spellings, one document" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // The scan's spelling of `/w/notes (draft).sjon`…
    _ = try h.ingestWorkspaceFiles(&.{
        .{ .uri = "file:///w/notes%20%28draft%29.sjon", .source = "(nope)" },
    });
    try std.testing.expectEqual(@as(usize, 1), h.documents.count());

    // …and the editor's, when the user opens that same file.
    try h.openDocument("file:///w/notes%20(draft).sjon", 4, "(phrase :name p0)");
    try std.testing.expectEqual(@as(usize, 1), h.documents.count());

    // The open buffer won, which is the rule that silently stopped firing
    // when the two spellings were different keys.
    const reports = try h.getWorkspaceDiagnostics(fx.arena());
    try std.testing.expectEqual(@as(usize, 1), reports.len);
    try std.testing.expectEqual(@as(?i64, 4), reports[0].version);
    try std.testing.expectEqual(@as(usize, 0), reports[0].diagnostics.len);
}

test "a request in the client's spelling reaches the scan's document" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    _ = try h.ingestWorkspaceFiles(&.{
        .{ .uri = "file:///w/a%2Bb%21.sjon", .source = "(nope)" },
    });

    // `getDocument` is the funnel every read-side feature goes through.
    try std.testing.expect(h.getDocument("file:///w/a+b!.sjon") != null);
    const diags = (try h.getDiagnostics(fx.arena(), "file:///w/a+b!.sjon")).?;
    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("unknown_form", diags[0].code);
}

test "cross-ref navigation crosses a spelling difference" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // `uri_to_tree_idx` is the second URI-keyed map, and `findReferences`
    // reads both: `documents` for the tree, then this one for the
    // `Site.tree_idx` the index is keyed on. A spelling only the first
    // map forgives returns null here, so navigation dies silently while
    // diagnostics keep working.
    try h.openDocument("file:///w/lib%20(1).sjon", 1, "(phrase :name p0)\n(track :sequence [p0 p0])");

    // Byte 15 is mid-`p0`, the definition's name.
    const refs = (try h.findReferences(fx.arena(), "file:///w/lib (1).sjon", 15, true)).?;
    try std.testing.expectEqual(@as(usize, 3), refs.len); // def + 2 refs
    // Responses echo the stored spelling, which is the one that arrived first.
    for (refs) |r| try std.testing.expectEqualStrings("file:///w/lib%20(1).sjon", r.uri);
}

test "distinct files whose names differ only by an escape stay distinct" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    _ = try h.ingestWorkspaceFiles(&.{
        .{ .uri = "file:///w/a.sjon", .source = "(phrase :name p0)" },
        .{ .uri = "file:///w/a%20.sjon", .source = "(phrase :name p1)" },
    });
    try std.testing.expectEqual(@as(usize, 2), h.documents.count());
}

test "file cap clips deterministically" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // Deliberately unsorted input: the clip has to be a property of the
    // file set, not of the order the walker happened to yield.
    const ingest = try h.ingestWorkspaceFilesWithCap(&.{
        .{ .uri = "file:///c.sjon", .source = "(phrase :name p2)" },
        .{ .uri = "file:///a.sjon", .source = "(phrase :name p0)" },
        .{ .uri = "file:///b.sjon", .source = "(phrase :name p1)" },
    }, 2);
    try std.testing.expectEqual(@as(usize, 2), ingest.ingested);
    try std.testing.expectEqual(@as(usize, 1), ingest.clipped);

    const reports = try h.getWorkspaceDiagnostics(fx.arena());
    try std.testing.expectEqual(@as(usize, 2), reports.len);
    _ = reportFor(reports, "file:///a.sjon");
    _ = reportFor(reports, "file:///b.sjon");
    for (reports) |r| try std.testing.expect(!std.mem.eql(u8, r.uri, "file:///c.sjon"));
}

test "an injected workspace file does not widen another document's cross-ref scope" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // Cross-ref scope is per-tree — the LSP deliberately does not set
    // `Validator.Options.share_scope` (see `getDefinition`). Joining the
    // document set must not smuggle in the forest-wide scoping that
    // decision rules out: an unopened file defining `p0` leaves the
    // track's reference exactly as unresolved as it was.
    try h.openDocument("file:///track.sjon", 1, "(track :sequence [p0])");
    const before = (try h.getDiagnostics(fx.arena(), "file:///track.sjon")).?;
    try std.testing.expectEqual(@as(usize, 1), before.len);
    try std.testing.expectEqualStrings("not_cross_ref", before[0].code);

    _ = try h.ingestWorkspaceFiles(&.{
        .{ .uri = "file:///phrases.sjon", .source = "(phrase :name p0)" },
    });

    const after = (try h.getDiagnostics(fx.arena(), "file:///track.sjon")).?;
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings("not_cross_ref", after[0].code);
}

test "workspace symbols reach definitions in injected files" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    // The coverage change this checkpoint actually causes. Symbols read
    // the forest index, so a definition in a file nobody opened becomes
    // reachable from the symbol picker — which is what a user means when
    // they ask for a *workspace* symbol.
    _ = try h.ingestWorkspaceFiles(&.{
        .{ .uri = "file:///phrases.sjon", .source = "(phrase :name p0)" },
    });

    const syms = try h.getWorkspaceSymbols(fx.arena(), "p0");
    try std.testing.expectEqual(@as(usize, 1), syms.len);
    try std.testing.expectEqualStrings("p0", syms[0].name);
    try std.testing.expectEqualStrings("file:///phrases.sjon", syms[0].location.uri);
}

test "workspace and per-document diagnostics agree for the same open document" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });
    const arena = fx.arena();

    try h.openDocument("file:///track.sjon", 1, "(track :sequence [pX])");
    _ = try h.ingestWorkspaceFiles(&.{
        .{ .uri = "file:///phrases.sjon", .source = "(phrase :name p0)" },
    });

    const per_doc = (try h.getDiagnostics(arena, "file:///track.sjon")).?;
    const report = reportFor(try h.getWorkspaceDiagnostics(arena), "file:///track.sjon");
    try std.testing.expectEqual(per_doc.len, report.diagnostics.len);
    for (per_doc, report.diagnostics) |x, y| {
        try std.testing.expectEqualStrings(x.code, y.code);
        try std.testing.expectEqual(x.span_start, y.span_start);
    }
}

test "re-ingesting a workspace file refreshes its diagnostics" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    _ = try h.ingestWorkspaceFiles(&.{
        .{ .uri = "file:///disk.sjon", .source = "(nope)" },
    });
    try std.testing.expectEqual(
        @as(usize, 1),
        reportFor(try h.getWorkspaceDiagnostics(fx.arena()), "file:///disk.sjon").diagnostics.len,
    );

    // Someone fixed it outside the editor; the next pull must not serve
    // the old parse.
    _ = try h.ingestWorkspaceFiles(&.{
        .{ .uri = "file:///disk.sjon", .source = "(phrase :name p0)" },
    });
    try std.testing.expectEqual(
        @as(usize, 0),
        reportFor(try h.getWorkspaceDiagnostics(fx.arena()), "file:///disk.sjon").diagnostics.len,
    );
}

test "opening an injected file promotes it instead of duplicating it" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const plugin = audioSchemaPlugin();
    h.schema = .init(&.{ plugin, sjon.plugins.core.plugin });

    _ = try h.ingestWorkspaceFiles(&.{
        .{ .uri = "file:///a.sjon", .source = "(nope)" },
    });
    try h.openDocument("file:///a.sjon", 4, "(phrase :name p0)");

    const reports = try h.getWorkspaceDiagnostics(fx.arena());
    try std.testing.expectEqual(@as(usize, 1), reports.len);
    try std.testing.expectEqual(@as(?i64, 4), reports[0].version);
    try std.testing.expectEqual(@as(usize, 0), reports[0].diagnostics.len);
}

// ---------------------------------------------------------------------------
// Refactor actions — extract-site resolution (plan 11, CP1).
// ---------------------------------------------------------------------------

/// Schema for the extract/inline refactor helpers. Two `union{form,
/// cross_ref}` slots, where an inline form and a name reference are
/// interchangeable spellings:
///   * **unscoped** — `track :lead` (`phrase-or-ref`), targeting `phrase`.
///   * **scoped** — `bar :lead` and `piece :lead` (`motif-or-ref-scoped`),
///     targeting `motif` within the nearest `piece`.
/// The two use *distinct* target forms deliberately: the index builder keys
/// definition scope by canonical target name (one spec per target), so a form
/// that was both an unscoped and a scoped target would register its
/// definitions under a single, wrong scope. `bar` (a child of `piece`) carries
/// the scoped slot used for the validating tests, because a form's own kvpair
/// values are validated with its *parent* scope chain — a scoped reference in
/// `piece`'s own kvpair could never see `piece`. `piece :lead` is also scoped
/// purely for the CP1 placement resolver test, which checks structure, not
/// validity. `holder :slot` is a plain form kind (no cross-ref) — the
/// negative-space slot for the eligibility-rejection test, with a valid form
/// head so the rejection is about the *slot*, not an unknown head.
///
/// `phrase` and `motif` each carry an optional `:bars` number key so an inline
/// (CP3) body reads `(phrase :bars 4)` — content beyond the stripped `:name`,
/// which is what makes "strips the name kvpair" a distinguishing assertion.
fn extractSchemaPlugin() sjon.Plugin.Plugin {
    const phrase_inline: sjon.Plugin.ValueKind = .{
        .name = "phrase-inline",
        .underlying = .form,
        .heads = .{ .heads = &.{.{ .name = "phrase" }} },
    };
    const phrase_ref: sjon.Plugin.ValueKind = .{
        .name = "phrase-ref",
        .underlying = .symbol,
        .cross_ref = .{ .targets = &.{"phrase"} },
    };
    const phrase_or_ref: sjon.Plugin.ValueKind = .{
        .name = "phrase-or-ref",
        .underlying = .union_of,
        .union_of = .{ .alternatives = &.{ .{ .name = "phrase-inline" }, .{ .name = "phrase-ref" } } },
    };
    const motif_inline: sjon.Plugin.ValueKind = .{
        .name = "motif-inline",
        .underlying = .form,
        .heads = .{ .heads = &.{.{ .name = "motif" }} },
    };
    const motif_ref_scoped: sjon.Plugin.ValueKind = .{
        .name = "motif-ref-scoped",
        .underlying = .symbol,
        .cross_ref = .{ .targets = &.{"motif"}, .scope_form = "piece" },
    };
    const motif_or_ref_scoped: sjon.Plugin.ValueKind = .{
        .name = "motif-or-ref-scoped",
        .underlying = .union_of,
        .union_of = .{ .alternatives = &.{ .{ .name = "motif-inline" }, .{ .name = "motif-ref-scoped" } } },
    };
    const plain_form: sjon.Plugin.ValueKind = .{
        .name = "plain-form",
        .underlying = .form,
    };
    // `set :leads` is the vector-shaped union slot: the branch of
    // `unionSlotOf` that looks through a `.vector` to its element kind, and
    // the one shape besides a direct value that `kvpairHolds` accepts.
    const phrase_or_ref_list: sjon.Plugin.ValueKind = .{
        .name = "phrase-or-ref-list",
        .underlying = .vector,
        .vector = .{ .element = .{ .name = "phrase-or-ref" } },
    };
    return .{
        .name = "audio",
        .value_kinds = &.{ phrase_inline, phrase_ref, phrase_or_ref, motif_inline, motif_ref_scoped, motif_or_ref_scoped, plain_form, phrase_or_ref_list },
        .forms = &.{
            .{
                .name = "phrase",
                .keys = &.{
                    .{ .name = "name", .value_type = .symbol, .optional = true },
                    .{ .name = "bars", .value_type = .number, .optional = true },
                    // A string slot, so a test can put multi-byte text
                    // inside a form the refactors move around.
                    .{ .name = "title", .value_type = .string, .optional = true },
                },
            },
            .{
                .name = "motif",
                .keys = &.{
                    .{ .name = "name", .value_type = .symbol, .optional = true },
                    .{ .name = "bars", .value_type = .number, .optional = true },
                },
            },
            .{
                .name = "track",
                .keys = &.{
                    .{ .name = "lead", .value_type = .{ .named = .{ .name = "phrase-or-ref" } }, .optional = false },
                },
            },
            .{
                .name = "piece",
                .positional = .any,
                .keys = &.{
                    .{ .name = "lead", .value_type = .{ .named = .{ .name = "motif-or-ref-scoped" } }, .optional = true },
                },
            },
            .{
                .name = "bar",
                .keys = &.{
                    .{ .name = "lead", .value_type = .{ .named = .{ .name = "motif-or-ref-scoped" } }, .optional = false },
                },
            },
            .{
                .name = "holder",
                .keys = &.{
                    .{ .name = "slot", .value_type = .{ .named = .{ .name = "plain-form" } }, .optional = false },
                },
            },
            .{
                .name = "set",
                .keys = &.{
                    .{ .name = "leads", .value_type = .{ .named = .{ .name = "phrase-or-ref-list" } }, .optional = false },
                },
            },
            // `rack` takes positional *references* and also declares a
            // `:lead` union — the same key name `track` uses. That
            // coincidence is what makes a lexically-enclosing kvpair
            // dangerous rather than merely useless: both slots resolve, so
            // nothing downstream notices they belong to different forms.
            .{
                .name = "rack",
                .positional = .{ .kind = .{ .name = "phrase-ref" } },
                .keys = &.{
                    .{ .name = "lead", .value_type = .{ .named = .{ .name = "phrase-or-ref" } }, .optional = true },
                },
            },
        },
    };
}

/// Static so `Schema.init` — which borrows the plugins slice — can outlive
/// `openExtractDoc`'s return. A stack `&.{…}` would dangle once the helper
/// returned (the other tests' in-body `.init(&.{…})` survives only because
/// they use the schema within the same scope).
const extract_plugins = [_]sjon.Plugin.Plugin{ extractSchemaPlugin(), sjon.plugins.core.plugin };

/// Open `src` under `file:///a.sjon` on a fresh handler carrying
/// `extractSchemaPlugin`, and return the cursor byte offset just inside the
/// inline form the test targets. That form is always the one opened by the
/// *last* `(` in `src`: forms nest, so the final open-paren can only belong to
/// the innermost — and the tests place the extract candidate there. Keying on
/// the paren rather than a head keeps the helper head-agnostic across the
/// `phrase` (unscoped) and `motif` (scoped) slots.
fn openExtractDoc(h: *Handler, src: []const u8) !u32 {
    h.schema = .init(&extract_plugins);
    try h.openDocument("file:///a.sjon", 1, src);
    const at = std.mem.lastIndexOfScalar(u8, src, '(') orelse return error.NoInlineForm;
    return @intCast(at + 1);
}

test "extract eligibility: form in a cross-ref slot with matching target_form" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    const cursor = try openExtractDoc(h, "(track :lead (phrase))");
    const site = (try h.findExtractSite(arena, "file:///a.sjon", cursor, cursor)) orelse
        return error.ExpectedSite;

    try std.testing.expectEqualStrings("phrase", site.head);
    const enc = h.getDocument("file:///a.sjon").?.tree.formHeader(site.enclosing_form_idx);
    try std.testing.expectEqualStrings("track", enc.head);
}

test "extract eligibility: rejected when slot is not a cross-ref kind" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    // `:slot` is a plain form kind, not a union with a cross-ref alternative —
    // the inline phrase has nowhere to be extracted to.
    const cursor = try openExtractDoc(h, "(holder :slot (phrase))");
    const site = try h.findExtractSite(arena, "file:///a.sjon", cursor, cursor);
    try std.testing.expect(site == null);
}

test "extract eligibility: a vector-element union slot is a site" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    // `set :leads` is `[phrase-or-ref]`. The kvpair's value is the vector,
    // not the form, so this is the one shape besides a direct value that
    // has to resolve — `unionSlotOf` looks through the vector to its
    // element kind, and the containment guard must let it.
    const cursor = try openExtractDoc(h, "(set :leads [(phrase)])");
    const site = (try h.findExtractSite(arena, "file:///a.sjon", cursor, cursor)) orelse
        return error.ExpectedSite;

    try std.testing.expectEqualStrings("phrase", site.head);
    const enc = h.getDocument("file:///a.sjon").?.tree.formHeader(site.enclosing_form_idx);
    try std.testing.expectEqualStrings("set", enc.head);
}

test "extract eligibility: a positional form is not the enclosing kvpair's value" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    // The motif is a *positional* child of `piece`. It is not the value of
    // any kvpair — but it is lexically inside `bar :lead`, and `piece`
    // separately declares a `:lead` union whose cross-ref alternative
    // targets `motif`. Every check downstream therefore passes while
    // describing a slot this form does not occupy: extracting would replace
    // a positional child with a bare name that is not a reference site at
    // all, silently changing what the document says.
    //
    // v1 scope: a positional inline form is not extractable. Suppressing
    // here is the correct answer for now, not a placeholder — making it
    // extractable means resolving the slot from the *positional* spec,
    // which is a separate feature.
    const cursor = try openExtractDoc(h, "(bar :lead (piece (motif :bars 4)))");
    const site = try h.findExtractSite(arena, "file:///a.sjon", cursor, cursor);
    try std.testing.expect(site == null);
}

test "extract placement: unscoped kind places at top level after the current root" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    const cursor = try openExtractDoc(h, "(track :lead (phrase))");
    const doc = h.getDocument("file:///a.sjon").?;
    const site = (try h.findExtractSite(arena, "file:///a.sjon", cursor, cursor)) orelse
        return error.ExpectedSite;

    const placement = (try h.resolvePlacement(arena, &doc.tree, site)) orelse
        return error.ExpectedPlacement;
    try std.testing.expect(placement == .top_level_after);
    // The unscoped definition hoists to the top-level root — here `track`
    // itself, the outermost ancestor of the inline phrase.
    try std.testing.expectEqual(site.enclosing_form_idx, placement.top_level_after);
}

test "extract placement: scope_form kind places inside the nearest matching ancestor" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    const cursor = try openExtractDoc(h, "(piece :lead (motif))");
    const doc = h.getDocument("file:///a.sjon").?;
    const site = (try h.findExtractSite(arena, "file:///a.sjon", cursor, cursor)) orelse
        return error.ExpectedSite;

    const placement = (try h.resolvePlacement(arena, &doc.tree, site)) orelse
        return error.ExpectedPlacement;
    try std.testing.expect(placement == .inside_scope);
    // The scope is `piece`; the nearest enclosing `piece` is the root itself.
    try std.testing.expectEqual(site.enclosing_form_idx, placement.inside_scope);
    const scope = doc.tree.formHeader(placement.inside_scope);
    try std.testing.expectEqualStrings("piece", scope.head);
}

test "extract fresh names avoid existing definitions" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    // `phrase-1` is already defined, so the synthesized name bumps to
    // `phrase-2`.
    const cursor = try openExtractDoc(h, "(phrase :name phrase-1)\n(track :lead (phrase))");
    const site = (try h.findExtractSite(arena, "file:///a.sjon", cursor, cursor)) orelse
        return error.ExpectedSite;

    const name = (try h.freshName(arena, "file:///a.sjon", site)) orelse
        return error.ExpectedName;
    try std.testing.expectEqualStrings("phrase-2", name);
}

/// Apply non-overlapping `edits` to `source`, returning the resulting text.
/// The extract action's two edits never overlap (the hoist insertion lands
/// past the inline form's close paren), so a single ascending walk suffices.
fn applyEdits(arena: std.mem.Allocator, source: []const u8, edits: []const Handler.TextEdit) ![]u8 {
    const sorted = try arena.dupe(Handler.TextEdit, edits);
    std.mem.sort(Handler.TextEdit, sorted, {}, struct {
        fn lt(_: void, x: Handler.TextEdit, y: Handler.TextEdit) bool {
            return x.span_start < y.span_start;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    for (sorted) |e| {
        try out.appendSlice(arena, source[pos..e.span_start]);
        try out.appendSlice(arena, e.new_text);
        pos = e.span_end;
    }
    try out.appendSlice(arena, source[pos..]);
    return out.toOwnedSlice(arena);
}

/// The `refactor.extract` code action offered at `cursor`, or null when the
/// cursor is not on an eligible extract site.
fn extractAction(h: *Handler, arena: std.mem.Allocator, uri: []const u8, cursor: u32) !?Handler.CodeAction {
    const actions = (try h.getCodeActions(arena, uri, cursor, cursor)) orelse return null;
    for (actions) |act| {
        if (act.kind == .refactor_extract) return act;
    }
    return null;
}

test "extract replaces the form with the fresh name and inserts the definition" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    const cursor = try openExtractDoc(h, "(track :lead (phrase))");
    const act = (try extractAction(h, arena, "file:///a.sjon", cursor)) orelse
        return error.ExpectedAction;
    const edited = try applyEdits(arena, h.getDocument("file:///a.sjon").?.source, act.edits);

    // The inline form becomes a reference; its body hoists to a top-level
    // sibling carrying the synthesized `:name`.
    try std.testing.expectEqualStrings(
        "(track :lead phrase-1)\n(phrase :name phrase-1)",
        edited,
    );
}

test "extract places the definition inside the scope form when scoped" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    const cursor = try openExtractDoc(h, "(piece (bar :lead (motif)))");
    const act = (try extractAction(h, arena, "file:///a.sjon", cursor)) orelse
        return error.ExpectedAction;
    const edited = try applyEdits(arena, h.getDocument("file:///a.sjon").?.source, act.edits);

    // A `scope_form` cross-ref hoists inside the enclosing `piece`, not to
    // the top level — otherwise the reference (in `bar`, a child of `piece`)
    // would fall outside its scope.
    try std.testing.expectEqualStrings(
        "(piece (bar :lead motif-1) (motif :name motif-1))",
        edited,
    );
}

// ---------------------------------------------------------------------------
// Text shapes the suite never had: multi-byte content and `\r`
//
// Every refactor edit is a byte range plus replacement text, so nothing here
// counts characters — but nothing here had ever *seen* a non-ASCII byte or a
// `\r` either, and "we don't count characters" is exactly the claim a test
// should be making rather than assuming. The transports do count characters,
// on both sides of these offsets.
// ---------------------------------------------------------------------------

test "extract carries multi-byte content through byte-anchored edits" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    // 2-, 3- and 4-byte sequences inside the form being hoisted, so a
    // helper that stepped by character anywhere would cut one in half.
    const cursor = try openExtractDoc(h, "(track :lead (phrase :title \"h\xC3\xA9llo \xE2\x82\xAC \xF0\x9F\x98\x80\"))");
    const act = (try extractAction(h, arena, "file:///a.sjon", cursor)) orelse
        return error.ExpectedAction;
    const edited = try applyEdits(arena, h.getDocument("file:///a.sjon").?.source, act.edits);

    try std.testing.expectEqualStrings(
        "(track :lead phrase-1)\n(phrase :name phrase-1 :title \"h\xC3\xA9llo \xE2\x82\xAC \xF0\x9F\x98\x80\")",
        edited,
    );
    // The result is still well-formed UTF-8 — the assertion above would
    // also pass if two edits had each cut a sequence in complementary ways.
    try std.testing.expect(std.unicode.utf8ValidateSlice(edited));
}

test "inline carries multi-byte content through byte-anchored edits" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    const src = "(phrase :name p0 :title \"caf\xC3\xA9 \xF0\x9F\x8E\xB5\")\n(track :lead p0)";
    try openInlineDoc(h, src);
    const cursor: u32 = @intCast(std.mem.lastIndexOf(u8, src, "p0").?);
    const act = (try inlineAction(h, arena, "file:///a.sjon", cursor)) orelse
        return error.ExpectedAction;
    const edited = try applyEdits(arena, h.getDocument("file:///a.sjon").?.source, act.edits);

    try std.testing.expectEqualStrings(
        "(track :lead (phrase :title \"caf\xC3\xA9 \xF0\x9F\x8E\xB5\"))",
        edited,
    );
    try std.testing.expect(std.unicode.utf8ValidateSlice(edited));
}

test "extract on a CRLF document leaves every existing terminator intact" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    // Two roots separated by CRLF; the extract targets the second, so the
    // hoist splices after it and the untouched `\r\n` sits before it.
    const cursor = try openExtractDoc(h, "(track :lead (phrase :bars 1))\r\n(track :lead (phrase :bars 2))");
    const act = (try extractAction(h, arena, "file:///a.sjon", cursor)) orelse
        return error.ExpectedAction;
    const edited = try applyEdits(arena, h.getDocument("file:///a.sjon").?.source, act.edits);

    // The `\r` is not swallowed and not duplicated. The inserted separator
    // is a bare `\n`: this server does not detect a document's dominant
    // terminator, and a client that normalises on save fixes it. Written
    // down because the alternative — matching the file — is a real feature,
    // not an oversight to be quietly "fixed" by a later reader.
    try std.testing.expectEqualStrings(
        "(track :lead (phrase :bars 1))\r\n(track :lead phrase-1)\n(phrase :name phrase-1 :bars 2)",
        edited,
    );
}

test "inline on a CRLF document does not strip half a terminator" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    // Inline deletes the definition *and one adjacent whitespace run*, so a
    // CRLF is exactly where a naive "drop one byte" would leave a stray
    // `\r` at the head of the file.
    const src = "(phrase :name p0 :bars 4)\r\n(track :lead p0)";
    try openInlineDoc(h, src);
    const cursor: u32 = @intCast(std.mem.lastIndexOf(u8, src, "p0").?);
    const act = (try inlineAction(h, arena, "file:///a.sjon", cursor)) orelse
        return error.ExpectedAction;
    const edited = try applyEdits(arena, h.getDocument("file:///a.sjon").?.source, act.edits);

    try std.testing.expectEqualStrings("(track :lead (phrase :bars 4))", edited);
}

test "extract on a lone-\\r document behaves as it does on \\n" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    // Classic-Mac terminators. The lexer treats `\r` as whitespace like any
    // other, so this must be the `\n` case byte-for-byte apart from the
    // separators the document already had.
    const cursor = try openExtractDoc(h, "(track :lead (phrase :bars 1))\r(track :lead (phrase :bars 2))");
    const act = (try extractAction(h, arena, "file:///a.sjon", cursor)) orelse
        return error.ExpectedAction;
    const edited = try applyEdits(arena, h.getDocument("file:///a.sjon").?.source, act.edits);

    try std.testing.expectEqualStrings(
        "(track :lead (phrase :bars 1))\r(track :lead phrase-1)\n(phrase :name phrase-1 :bars 2)",
        edited,
    );
}

test "extract is not offered for a form that already carries the name key" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    // v1 scope: splicing a second `:name` over an existing one would
    // duplicate the key and invalidate the document, and a named inline
    // form is already effectively a definition. The *site* still resolves —
    // this is the action-level skip, so asserting on `findExtractSite`
    // would not reach it.
    const cursor = try openExtractDoc(h, "(track :lead (phrase :name p0))");
    try std.testing.expect((try h.findExtractSite(arena, "file:///a.sjon", cursor, cursor)) != null);
    try std.testing.expect((try extractAction(h, arena, "file:///a.sjon", cursor)) == null);
}

test "extract is not offered on a document the parser had to recover" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    // Mid-keystroke. Recovery finalises the unclosed frames at `source.len`,
    // so the form has a span, the site resolves, and the pre-existing
    // span-range guard passes — this used to offer an extract that hoisted
    // a copy of the unclosed tail, producing
    // `(track :lead phrase-1\n(phrase :name phrase-1 :bars`: two unclosed
    // forms where there had been one.
    const cursor = try openExtractDoc(h, "(track :lead (phrase :bars");
    try std.testing.expect(h.getDocument("file:///a.sjon").?.tree.diagnostics.len > 0);
    try std.testing.expect((try extractAction(h, arena, "file:///a.sjon", cursor)) == null);
}

test "inline is not offered on a document the parser had to recover" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    // Same precondition on the inverse action: it splices the definition's
    // source text over the reference, so a guessed span is a guessed body.
    //
    // The break is deliberately in a *third* root, well after the reference:
    // the definition and its use both parse cleanly, so every other check
    // passes and only the document-wide rule refuses. A source whose break
    // swallowed the reference would pass this test for the wrong reason.
    const src = "(phrase :name p0 :bars 4)\n(track :lead p0)\n(track :lead (phrase";
    try openInlineDoc(h, src);
    try std.testing.expect(h.getDocument("file:///a.sjon").?.tree.diagnostics.len > 0);
    const cursor: u32 = @intCast(std.mem.indexOf(u8, src, ":lead p0").? + ":lead ".len);
    try std.testing.expect((try inlineAction(h, arena, "file:///a.sjon", cursor)) == null);
}

test "extracted document validates clean" {
    const a = std.testing.allocator;

    // Both spellings — unscoped and scoped — must round-trip to a document
    // the validator accepts: the rewritten reference resolves to the hoisted
    // definition, and the definition is legal where it lands.
    const cases = [_][]const u8{
        "(track :lead (phrase))",
        "(piece (bar :lead (motif)))",
    };
    for (cases) |src| {
        var fx = handlerFixture(a);
        defer fx.deinit();
        const h = &fx.h;
        const arena = fx.arena();

        const cursor = try openExtractDoc(h, src);
        const act = (try extractAction(h, arena, "file:///a.sjon", cursor)) orelse
            return error.ExpectedAction;
        const edited = try applyEdits(arena, h.getDocument("file:///a.sjon").?.source, act.edits);

        try h.openDocument("file:///out.sjon", 1, edited);
        const out = h.getDocument("file:///out.sjon").?;
        try std.testing.expectEqual(@as(usize, 0), out.tree.diagnostics.len);
        try std.testing.expectEqual(@as(usize, 0), out.validate_result.diagnostics.len);
    }
}

test "extract is offered only at eligible sites" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    // `:slot` is a plain form kind — no cross-ref alternative, so there is no
    // name a reference could use in the inline form's place. No extract.
    const cursor = try openExtractDoc(h, "(holder :slot (phrase))");
    const act = try extractAction(h, arena, "file:///a.sjon", cursor);
    try std.testing.expect(act == null);
}

test "extract result is rename-ready" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    const cursor = try openExtractDoc(h, "(track :lead (phrase))");
    const act = (try extractAction(h, arena, "file:///a.sjon", cursor)) orelse
        return error.ExpectedAction;
    const edited = try applyEdits(arena, h.getDocument("file:///a.sjon").?.source, act.edits);

    // The hoisted definition + rewritten reference form a live cross-ref
    // pair: renaming the fresh name touches both sites, so extract and rename
    // compose.
    try h.openDocument("file:///out.sjon", 1, edited);
    const ref_at: u32 = @intCast(std.mem.indexOf(u8, edited, "phrase-1").? + 1);
    const res = (try h.rename(arena, "file:///out.sjon", ref_at, "intro")) orelse
        return error.ExpectedRename;
    switch (res) {
        .edits => |we| {
            try std.testing.expectEqual(@as(usize, 1), we.changes.len);
            try std.testing.expectEqual(@as(usize, 2), we.changes[0].edits.len);
        },
        .err => return error.UnexpectedRenameError,
    }
}

// ---------------------------------------------------------------------------
// Refactor actions — inline (plan 11, CP3). Inline is extract's inverse: on a
// cross-ref *reference* in a `union{form, cross_ref}` slot, splice the
// definition's body (minus its `:name` kvpair) over the reference. Sole
// reference → delete the definition; multiple → keep it. Reuses
// `extractSchemaPlugin` (its `:bars` key gives bodies content beyond `:name`).
// ---------------------------------------------------------------------------

/// Open `src` under `file:///a.sjon` on the extract/inline schema. Cursor
/// offsets are computed per-test from `src` (a reference symbol's byte), since
/// inline anchors on a *use*, not the trailing `(` that `openExtractDoc` keys on.
fn openInlineDoc(h: *Handler, src: []const u8) !void {
    h.schema = .init(&extract_plugins);
    try h.openDocument("file:///a.sjon", 1, src);
}

/// The `refactor.inline` code action offered at `cursor`, or null when the
/// cursor is not on an eligible inline site.
fn inlineAction(h: *Handler, arena: std.mem.Allocator, uri: []const u8, cursor: u32) !?Handler.CodeAction {
    const actions = (try h.getCodeActions(arena, uri, cursor, cursor)) orelse return null;
    for (actions) |act| {
        if (act.kind == .refactor_inline) return act;
    }
    return null;
}

test "inline splices the definition body over a single reference and removes the definition" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    const src = "(phrase :name p0 :bars 4)\n(track :lead p0)";
    try openInlineDoc(h, src);
    // The reference is the *last* `p0` (the first is the definition's `:name`).
    const cursor: u32 = @intCast(std.mem.lastIndexOf(u8, src, "p0").?);
    const act = (try inlineAction(h, arena, "file:///a.sjon", cursor)) orelse
        return error.ExpectedAction;
    const edited = try applyEdits(arena, h.getDocument("file:///a.sjon").?.source, act.edits);

    // The definition (and its trailing newline) is gone; its body — minus the
    // `:name` pair — stands where the reference did.
    try std.testing.expectEqualStrings("(track :lead (phrase :bars 4))", edited);
}

test "inline strips the name kvpair from the spliced body" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    const src = "(phrase :name p0 :bars 4)\n(track :lead p0)";
    try openInlineDoc(h, src);
    const cursor: u32 = @intCast(std.mem.lastIndexOf(u8, src, "p0").?);
    const act = (try inlineAction(h, arena, "file:///a.sjon", cursor)) orelse
        return error.ExpectedAction;
    const edited = try applyEdits(arena, h.getDocument("file:///a.sjon").?.source, act.edits);

    // The `:name` binding is dissolved entirely; the rest of the body survives.
    try std.testing.expect(std.mem.indexOf(u8, edited, ":name") == null);
    try std.testing.expect(std.mem.indexOf(u8, edited, ":bars 4") != null);
}

test "inline on a multi-reference definition inlines locally and keeps the definition" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    const src = "(phrase :name p0 :bars 4)\n(track :lead p0)\n(track :lead p0)";
    try openInlineDoc(h, src);
    // Cursor on the *first* reference: `:lead p0` in the first track.
    const cursor: u32 = @intCast(std.mem.indexOf(u8, src, ":lead p0").? + ":lead ".len);
    const act = (try inlineAction(h, arena, "file:///a.sjon", cursor)) orelse
        return error.ExpectedAction;

    // Only the cursor's reference is rewritten — one edit, definition untouched.
    try std.testing.expectEqual(@as(usize, 1), act.edits.len);
    const edited = try applyEdits(arena, h.getDocument("file:///a.sjon").?.source, act.edits);
    try std.testing.expectEqualStrings(
        "(phrase :name p0 :bars 4)\n(track :lead (phrase :bars 4))\n(track :lead p0)",
        edited,
    );
}

test "inlined document validates clean" {
    const a = std.testing.allocator;

    // Unscoped and scoped both round-trip to a document the validator accepts:
    // the spliced form is legal in the union slot the reference sat in.
    const Case = struct { src: []const u8, ref: []const u8 };
    const cases = [_]Case{
        .{ .src = "(phrase :name p0 :bars 4)\n(track :lead p0)", .ref = ":lead p0" },
        .{ .src = "(piece (motif :name m0 :bars 4) (bar :lead m0))", .ref = ":lead m0" },
    };
    for (cases) |c| {
        var fx = handlerFixture(a);
        defer fx.deinit();
        const h = &fx.h;
        const arena = fx.arena();

        try openInlineDoc(h, c.src);
        const cursor: u32 = @intCast(std.mem.indexOf(u8, c.src, c.ref).? + ":lead ".len);
        const act = (try inlineAction(h, arena, "file:///a.sjon", cursor)) orelse
            return error.ExpectedAction;
        const edited = try applyEdits(arena, h.getDocument("file:///a.sjon").?.source, act.edits);

        try h.openDocument("file:///out.sjon", 1, edited);
        const out = h.getDocument("file:///out.sjon").?;
        try std.testing.expectEqual(@as(usize, 0), out.tree.diagnostics.len);
        try std.testing.expectEqual(@as(usize, 0), out.validate_result.diagnostics.len);
    }
}

test "inline is not offered for a positional reference under an ancestor's kvpair" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    // The mirror of the extract case. `p0` is a *positional* child of
    // `rack`, whose positional kind is a cross-ref — so it is a genuine
    // reference site and the index resolves it. But it is not the value of
    // any kvpair: the pair that lexically encloses it is `track :lead`,
    // belonging to `rack`'s parent, and `rack` separately declares its own
    // `:lead` union. Both resolve, so without the containment guard an
    // inline is offered that would splice a form into a slot typed for a
    // symbol.
    const src = "(phrase :name p0 :bars 4)\n(track :lead (rack p0))";
    try openInlineDoc(h, src);
    const cursor: u32 = @intCast(std.mem.lastIndexOf(u8, src, "p0").?);
    try std.testing.expect((try inlineAction(h, arena, "file:///a.sjon", cursor)) == null);
}

test "inline is not offered on the definition itself" {
    const a = std.testing.allocator;
    var fx = handlerFixture(a);
    defer fx.deinit();
    const h = &fx.h;
    const arena = fx.arena();

    const src = "(phrase :name p0 :bars 4)\n(track :lead p0)";
    try openInlineDoc(h, src);
    // Cursor on the *definition* name (`:name p0`, the first `p0`) — inline
    // dissolves a use, not a declaration.
    const cursor: u32 = @intCast(std.mem.indexOf(u8, src, "p0").?);
    const act = try inlineAction(h, arena, "file:///a.sjon", cursor);
    try std.testing.expect(act == null);
}

// ---------------------------------------------------------------------------
// OOM convergence — the Handler under `FailingAllocator`.
//
// `oom_tests.zig` sweeps every entrypoint in `root.zig`; the Handler is not
// one of them, and it is the layer that holds the most gpa-owned state
// across a call: the document map, each `Document`'s tree + validate result
// + lowering output, and the installed schema set. `setUserSchemas` in
// particular builds a whole replacement schema list and only swaps it into
// `self` once every fallible step has succeeded — an errdefer contract that
// nothing had ever exercised.
//
// One request chain per iteration, torn down completely: an induced failure
// anywhere in it must surface as `OutOfMemory` with `deinit` still able to
// release whatever was built (`testing.allocator` catches the leak
// otherwise), and the handler must never be left holding a half-installed
// schema set.
// ---------------------------------------------------------------------------

/// Bounded so a path that allocates without converging fails loudly rather
/// than hanging the suite. Same guard `oom_tests.zig` uses.
const MAX_HANDLER_FAIL_INDEX: usize = 4096;

const handler_oom_schema =
    \\(plugin :name oom :version "1.0.0"
    \\  (form :name scene
    \\    (key :name title :type string :optional false)
    \\    (key :name fps :type number :default 60)))
;

/// The whole chain, so `defer` unwinds it on whichever step the allocator
/// fails. Returns the diagnostic count so the success arm can assert the
/// request actually did something.
fn driveHandlerOnce(a: std.mem.Allocator) !usize {
    var h = Handler.init(a);
    defer h.deinit();

    var arena_inst = std.heap.ArenaAllocator.init(a);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const sources = [_]Handler.SchemaSource{
        .{ .uri = "inmemory://schema/0.sjon", .text = handler_oom_schema },
    };
    _ = try h.setUserSchemas(arena, &sources);

    // Omits the required `:title` and the defaulted `:fps`, so the document
    // pass produces a diagnostic AND a materialized default — both
    // gpa-owned, both on the failure path.
    try h.openDocument("file:///a.sjon", 1, "(scene)");
    const diags = (try h.getDiagnostics(arena, "file:///a.sjon")) orelse
        return error.NoDocument;
    return diags.len;
}

test "OOM: a Handler schema-install + open + diagnostics chain converges" {
    var fail_index: usize = 0;
    while (fail_index < MAX_HANDLER_FAIL_INDEX) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );

        const result = driveHandlerOnce(failing.allocator());
        if (failing.has_induced_failure) {
            try std.testing.expectError(error.OutOfMemory, result);
        } else {
            // Non-vacuous: the schema installed and the missing required
            // key was reported against it.
            try std.testing.expect(try result >= 1);
            return;
        }
    }
    return error.OomLoopDidNotConverge;
}
