//! Internal tests for ManifestLoader.zig (SJON project-manifest parser).
//!
//! Pulled out of `ManifestLoader.zig` to keep the growing production file
//! free of its ~135 interleaved manifest-loading tests. Test discovery:
//! `ManifestLoader.zig` ends with `test { _ = @import("ManifestLoader_tests.zig"); }`,
//! so these run transparently once `refAllDecls(@This())` in `root.zig`'s test
//! block references `ManifestLoader`.
//!
//! Tests reach `ManifestLoader` through its public surface (`load`,
//! `loadUnchecked`). The one private-helper test (`compareSjonFormat`) stays
//! inline in `ManifestLoader.zig`, since that function is intentionally not
//! `pub`. (Sha256-pin well-formedness moved to the `Sha256Pin` leaf, tested
//! there.)

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const Parser = @import("Parser.zig");
const Expr = @import("Expr.zig");
const core = @import("plugins/core.zig");
const ManifestLoader = @import("ManifestLoader.zig");

// Local aliases — keep test bodies readable without churning every callsite.
const load = ManifestLoader.load;
const loadUnchecked = ManifestLoader.loadUnchecked;

fn parseSource(a: Allocator, src: [:0]const u8) !Ast.Tree {
    return Parser.parse(a, src);
}

test "ManifestLoader: parses (cross-ref :target …) on a symbol value-kind" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name phrase-name
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :target phrase :name-key name)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 1), r.plugin.value_kinds.len);
    const k = r.plugin.value_kinds[0];
    const cr = k.cross_ref orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), cr.targets.len);
    try testing.expectEqualStrings("phrase", cr.targets[0]);
    try testing.expectEqualStrings("name", cr.name_key);
}

test "ManifestLoader: :name-key defaults to `name` when omitted" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name phrase-name
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :target phrase)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const cr = r.plugin.value_kinds[0].cross_ref orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("name", cr.name_key);
}

test "ManifestLoader: :acyclic true round-trips into CrossRef.acyclic" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name phrase-name
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :target phrase :acyclic true)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const cr = r.plugin.value_kinds[0].cross_ref orelse return error.TestUnexpectedResult;
    try testing.expect(cr.acyclic);
}

test "ManifestLoader: :acyclic defaults to false when omitted" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name phrase-name
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :target phrase)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const cr = r.plugin.value_kinds[0].cross_ref orelse return error.TestUnexpectedResult;
    try testing.expect(!cr.acyclic);
}

test "ManifestLoader: :cross-ref on non-symbol underlying emits wrong_underlying" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bogus
        \\    :underlying string
        \\    :cross-ref (cross-ref :target phrase)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found = false;
    for (r.diagnostics) |d| {
        if (d.code == .wrong_underlying and
            std.mem.indexOf(u8, d.message, "cross-ref") != null and
            std.mem.indexOf(u8, d.message, "string") != null)
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

// ── provider-route cross-refs ────────────────────────────────────────────
//
// The second route to a cross-ref's member set: `:provider` names a
// `(cross-ref-provider …)` and `:source-key` names the string it reads.
// Nothing extracts at this layer — these pin the *declaration* surface:
// what lands on the spec, and the three exclusions that keep a spec from
// claiming both routes at once.

/// Find the first diagnostic with `code` whose message mentions `needle`.
fn findDiag(r: anytype, code: Ast.Diagnostic.Code, needle: []const u8) ?Ast.Diagnostic {
    for (r.diagnostics) |d| {
        if (d.code == code and std.mem.indexOf(u8, d.message, needle) != null) return d;
    }
    return null;
}

test "ManifestLoader: parses (cross-ref-provider …) into the fourth catalog" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (cross-ref-provider :name uniforms
        \\    :description "Uniform names in a GLSL source string."
        \\    :impl "wasm:extract_uniforms"))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 1), r.plugin.cross_ref_providers.len);
    const cp = r.plugin.cross_ref_providers[0];
    try testing.expectEqualStrings("uniforms", cp.name);
    try testing.expectEqualStrings("Uniform names in a GLSL source string.", cp.description);
    try testing.expectEqualStrings("extract_uniforms", cp.wasm_export_name.?);
    // Native `impl` is a static-plugin field; a manifest can never set it.
    try testing.expect(cp.impl == null);
}

test "ManifestLoader: (cross-ref-provider …) without :impl is declaration-only, not an error" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (cross-ref-provider :name uniforms))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const cp = r.plugin.cross_ref_providers[0];
    try testing.expect(cp.wasm_export_name == null);
    try testing.expectEqualStrings("", cp.description);
}

test "ManifestLoader: (cross-ref-provider …) ignores non-wasm :impl schemes" {
    // Same rule as expr-func `:impl`: v1 binds `wasm:` and leaves every
    // other scheme declaration-only rather than guessing at it.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (cross-ref-provider :name uniforms :impl "host:extract_uniforms"))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expect(r.plugin.cross_ref_providers[0].wasm_export_name == null);
}

test "ManifestLoader: cross-ref provider route lands :provider and :source-key" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (cross-ref-provider :name uniforms)
        \\  (value-kind :name uniform-name
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :provider uniforms :target shader :source-key body)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const cr = r.plugin.value_kinds[0].cross_ref orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), cr.targets.len);
    try testing.expectEqualStrings("shader", cr.targets[0]);
    try testing.expectEqualStrings("uniforms", cr.provider.?);
    try testing.expectEqualStrings("body", cr.source_key);
    // The identity field keeps its default; nothing consults it on this route.
    try testing.expectEqualStrings("name", cr.name_key);
}

test "ManifestLoader: :source-key defaults to `src` on the provider route" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (cross-ref-provider :name uniforms)
        \\  (value-kind :name uniform-name
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :provider uniforms :target shader)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const cr = r.plugin.value_kinds[0].cross_ref orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("src", cr.source_key);
}

test "ManifestLoader: :provider with :name-key is invalid_manifest and drops :name-key" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (cross-ref-provider :name uniforms)
        \\  (value-kind :name uniform-name
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :provider uniforms :target shader :name-key id)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiag(r, .invalid_manifest, "extraction routes are exclusive") != null);
    // Dropped, not half-honoured: downstream only ever sees one route.
    const cr = r.plugin.value_kinds[0].cross_ref orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("name", cr.name_key);
    try testing.expectEqualStrings("uniforms", cr.provider.?);
}

test "ManifestLoader: :provider with :acyclic true is invalid_manifest and drops :acyclic" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (cross-ref-provider :name uniforms)
        \\  (value-kind :name uniform-name
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :provider uniforms :target shader :acyclic true)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiag(r, .invalid_manifest, ":acyclic true") != null);
    const cr = r.plugin.value_kinds[0].cross_ref orelse return error.TestUnexpectedResult;
    try testing.expect(!cr.acyclic);
}

test "ManifestLoader: :acyclic false alongside :provider is not an error" {
    // The exclusion is about an *active* cycle check, not the key's
    // presence — `:acyclic false` asks for nothing and contradicts nothing.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (cross-ref-provider :name uniforms)
        \\  (value-kind :name uniform-name
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :provider uniforms :target shader :acyclic false)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "ManifestLoader: :source-key without :provider is invalid_manifest and drops it" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name phrase-name
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :target phrase :source-key body)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiag(r, .invalid_manifest, "without `:provider`") != null);
    const cr = r.plugin.value_kinds[0].cross_ref orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("src", cr.source_key);
    try testing.expect(cr.provider == null);
}

test "ManifestLoader: :target accepts a vector and normalises it to a list" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name pipeline-ref
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :target [render-pipeline compute-pipeline])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const cr = r.plugin.value_kinds[0].cross_ref orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), cr.targets.len);
    try testing.expectEqualStrings("render-pipeline", cr.targets[0]);
    try testing.expectEqualStrings("compute-pipeline", cr.targets[1]);
    // Manifest order, not sorted: the order the author wrote is the order
    // diagnostics list, and `soleTarget` is null for a group either way.
    try testing.expect(cr.soleTarget() == null);
}

test "ManifestLoader: a one-element :target vector is a single-target cross-ref" {
    // The two spellings converge, so nothing downstream can tell them
    // apart — `[phrase]` must not become a *group* of one, which would key
    // its own bucket and stop aliasing a plain `:target phrase`.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name phrase-name
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :target [phrase])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const cr = r.plugin.value_kinds[0].cross_ref orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("phrase", cr.soleTarget() orelse return error.TestUnexpectedResult);
}

test "ManifestLoader: an empty :target vector is invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name nothing-ref
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :target [])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiag(r, .invalid_manifest, "empty `:target []`") != null);
}

test "ManifestLoader: a repeated :target entry is invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name pipeline-ref
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :target [render-pipeline render-pipeline])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiag(r, .invalid_manifest, "twice") != null);
}

test "ManifestLoader: :acyclic true with several targets is invalid_manifest and drops :acyclic" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name node-ref
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :target [group leaf] :acyclic true)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiag(r, .invalid_manifest, "`self` is not well defined") != null);
    const cr = r.plugin.value_kinds[0].cross_ref orelse return error.TestUnexpectedResult;
    try testing.expect(!cr.acyclic);
}

test "ManifestLoader: :acyclic true with a one-element vector is fine" {
    // The exclusion is about a *group*, not about the vector spelling.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name node-ref
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :target [node] :acyclic true)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const cr = r.plugin.value_kinds[0].cross_ref orelse return error.TestUnexpectedResult;
    try testing.expect(cr.acyclic);
}

test "ManifestLoader: :provider with several targets is invalid_manifest and drops the route" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (cross-ref-provider :name uniforms)
        \\  (value-kind :name uniform-name
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :provider uniforms :target [vertex fragment])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiag(r, .invalid_manifest, "one cross-ref per target") != null);
    const cr = r.plugin.value_kinds[0].cross_ref orelse return error.TestUnexpectedResult;
    // Dropped, not half-honoured: the spec that reaches the index took the
    // identity route cleanly rather than a provider route it cannot run.
    try testing.expect(cr.provider == null);
    try testing.expectEqualStrings("src", cr.source_key);
}

test "ManifestLoader: identity-route cross-refs are untouched by the new keys" {
    // The regression that matters most: an existing manifest must load
    // exactly as it did, with `provider` null and `source_key` inert.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name phrase-name
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :target phrase :name-key id :acyclic true :scope piece)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const cr = r.plugin.value_kinds[0].cross_ref orelse return error.TestUnexpectedResult;
    try testing.expect(cr.provider == null);
    try testing.expectEqualStrings("src", cr.source_key);
    try testing.expectEqualStrings("id", cr.name_key);
    try testing.expect(cr.acyclic);
    try testing.expectEqualStrings("piece", cr.scope_form.?);
}

test "ManifestLoader: parses (union-shape :alternatives [...]) on a union value-kind" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name note-or-event
        \\    :underlying union
        \\    :union (union-shape :alternatives [note-or-rest event])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    // The aggregate-phase check (unknown alternatives) doesn't run from
    // load; the manifest-load level only verifies shape. Two structural
    // diagnostics are possible here from meta-validation — we don't
    // assert clean, just that the union-shape parsed into the kind.
    try testing.expectEqual(@as(usize, 1), r.plugin.value_kinds.len);
    const k = r.plugin.value_kinds[0];
    try testing.expectEqual(Plugin.ValueKind.Underlying.union_of, k.underlying);
    const us = k.union_of orelse return error.TestExpectedUnionShape;
    try testing.expectEqual(@as(usize, 2), us.alternatives.len);
    try testing.expectEqualStrings("note-or-rest", us.alternatives[0].name);
    try testing.expect(us.alternatives[0].namespace == null);
    try testing.expectEqualStrings("event", us.alternatives[1].name);
    try testing.expect(us.alternatives[1].namespace == null);
}

test "ManifestLoader: parseValueType honours plugin/kind qualification" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name consumer :version "1.0.0"
        \\  (form :name swatch
        \\    (key :name hue :type paint/color :optional false)
        \\    (key :name shade :type color :optional false)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.plugin.forms.len);
    const f = r.plugin.forms[0];
    try testing.expectEqual(@as(usize, 2), f.keys.len);
    // First key: qualified `paint/color` → namespace="paint", name="color"
    switch (f.keys[0].value_type) {
        .named => |q| {
            try testing.expectEqualStrings("color", q.name);
            try testing.expect(q.namespace != null);
            try testing.expectEqualStrings("paint", q.namespace.?);
        },
        else => return error.TestExpectedNamedType,
    }
    // Second key: bare `color` → namespace=null
    switch (f.keys[1].value_type) {
        .named => |q| {
            try testing.expectEqualStrings("color", q.name);
            try testing.expect(q.namespace == null);
        },
        else => return error.TestExpectedNamedType,
    }
}

test "ManifestLoader: vector :element and union :alternatives accept qualified refs" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name palette :underlying vector :vector (vector-shape :element paint/color))
        \\  (value-kind :name swatch-ref :underlying union :union (union-shape :alternatives [paint/color event])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.plugin.value_kinds.len);

    const palette = r.plugin.value_kinds[0];
    const vs = palette.vector orelse return error.TestExpectedVectorShape;
    try testing.expectEqualStrings("color", vs.element.name);
    try testing.expectEqualStrings("paint", vs.element.namespace.?);

    const swatch = r.plugin.value_kinds[1];
    const us = swatch.union_of orelse return error.TestExpectedUnionShape;
    try testing.expectEqual(@as(usize, 2), us.alternatives.len);
    try testing.expectEqualStrings("color", us.alternatives[0].name);
    try testing.expectEqualStrings("paint", us.alternatives[0].namespace.?);
    try testing.expectEqualStrings("event", us.alternatives[1].name);
    try testing.expect(us.alternatives[1].namespace == null);
}

test "ManifestLoader: :union without :underlying union emits wrong_underlying" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bogus
        \\    :underlying symbol
        \\    :union (union-shape :alternatives [a b])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found = false;
    for (r.diagnostics) |d| {
        if (d.code == .wrong_underlying and
            std.mem.indexOf(u8, d.message, ":union") != null and
            std.mem.indexOf(u8, d.message, "symbol") != null)
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "ManifestLoader: :underlying union without :union slot emits wrong_underlying" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bogus :underlying union))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found = false;
    for (r.diagnostics) |d| {
        if (d.code == .wrong_underlying and
            std.mem.indexOf(u8, d.message, "union") != null and
            std.mem.indexOf(u8, d.message, "no `:union") != null)
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "ManifestLoader: union with single alternative emits wrong_underlying" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bogus
        \\    :underlying union
        \\    :union (union-shape :alternatives [solo])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found = false;
    for (r.diagnostics) |d| {
        if (d.code == .wrong_underlying and
            std.mem.indexOf(u8, d.message, "at least two alternatives") != null)
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "ManifestLoader: union with duplicate alternatives emits wrong_underlying" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bogus
        \\    :underlying union
        \\    :union (union-shape :alternatives [a b a])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found = false;
    for (r.diagnostics) |d| {
        if (d.code == .wrong_underlying and
            std.mem.indexOf(u8, d.message, "listed twice") != null)
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "ManifestLoader: expr-func with :impl wasm:<name> records wasm_export_name" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name math2 :version "1.0.0"
        \\  (expr-func :name double :arity (fixed 1)
        \\    :params [number] :result number
        \\    :impl "wasm:double"))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 1), r.plugin.expr_funcs.len);
    const f = r.plugin.expr_funcs[0];
    try testing.expectEqualStrings("double", f.wasm_export_name.?);
    try testing.expect(f.impl == null);
}

test "ManifestLoader: expr-func with :impl host:<name> leaves wasm_export_name null" {
    // host:* is reserved by the portable manifest spec; v1's executable
    // ABI binds only wasm:*. The loader silently leaves the field null,
    // matching pre-D7 behaviour.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name f :arity (fixed 0) :result number
        \\    :impl "host:something"))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expect(r.plugin.expr_funcs[0].wasm_export_name == null);
    try testing.expect(r.plugin.expr_funcs[0].impl == null);
}

test "ManifestLoader: expr-func with param-names round-trips" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name lerp :arity (fixed 3)
        \\    :params [number number number]
        \\    :param-names [from to t]
        \\    :result number))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 1), r.plugin.expr_funcs.len);
    const f = r.plugin.expr_funcs[0];
    const names = f.param_names orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("from", names[0]);
    try testing.expectEqualStrings("to", names[1]);
    try testing.expectEqualStrings("t", names[2]);
}

test "ManifestLoader: param-names with non-fixed arity emits diagnostic" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name f :arity (at-least 1)
        \\    :param-names [a b]))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found = false;
    for (r.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "requires fixed arity") != null) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "ManifestLoader: param-names with rest emits diagnostic" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name f :arity (fixed 2)
        \\    :params [number number] :rest number
        \\    :param-names [a b]))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found = false;
    for (r.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "incompatible with `:rest`") != null) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "ManifestLoader: param-names longer than fixed arity emits diagnostic" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name f :arity (fixed 2)
        \\    :param-names [a b c]))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found = false;
    for (r.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "more names than") != null) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "ManifestLoader: param-names with duplicate names emits diagnostic" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name f :arity (fixed 3)
        \\    :param-names [a b a]))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found = false;
    for (r.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "duplicate names") != null) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "ManifestLoader: minimal manifest with name only" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name foo :version "1.0.0")
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqualStrings("foo", r.plugin.name);
    try testing.expectEqualStrings("1.0.0", r.plugin.version);
    try testing.expectEqual(@as(usize, 0), r.plugin.forms.len);
    try testing.expectEqual(@as(usize, 0), r.plugin.value_kinds.len);
    try testing.expectEqual(@as(usize, 0), r.plugin.expr_funcs.len);
}

test "ManifestLoader: captures :version verbatim" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name bar :version "2.5.1-rc.3")
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqualStrings("2.5.1-rc.3", r.plugin.version);
}

test "ManifestLoader: a single value-kind with member-set" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name colour-space :underlying string
        \\    :members (member-set :values [rgb yuv hsl])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 1), r.plugin.value_kinds.len);
    const k = r.plugin.value_kinds[0];
    try testing.expectEqualStrings("colour-space", k.name);
    try testing.expectEqual(Plugin.ValueKind.Underlying.string, k.underlying);
    const ms = k.members orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), ms.members.len);
    try testing.expectEqualStrings("rgb", ms.members[0].name);
}

test "ManifestLoader: member-set rich shape carries label/description/deprecated" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name status :underlying symbol
        \\    :members (member-set
        \\      (member :name draft     :label "Draft" :description "Work in progress.")
        \\      (member :name published :label "Published")
        \\      (member :name archived  :deprecated true :deprecation-message "Use hidden instead."))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const k = r.plugin.value_kinds[0];
    const ms = k.members orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), ms.members.len);
    try testing.expectEqualStrings("draft", ms.members[0].name);
    try testing.expectEqualStrings("Draft", ms.members[0].label);
    try testing.expectEqualStrings("Work in progress.", ms.members[0].description);
    try testing.expect(!ms.members[0].deprecated);
    try testing.expectEqualStrings("published", ms.members[1].name);
    try testing.expectEqualStrings("archived", ms.members[2].name);
    try testing.expect(ms.members[2].deprecated);
    try testing.expectEqualStrings("Use hidden instead.", ms.members[2].deprecation_message);
}

test "ManifestLoader: mixing :values and (member …) emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name status :underlying symbol
        \\    :members (member-set
        \\      :values [draft]
        \\      (member :name published))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "mixes") != null) found = true;
    }
    try testing.expect(found);
}

test "ManifestLoader: empty (member-set) emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name status :underlying symbol
        \\    :members (member-set)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "no members") != null) found = true;
    }
    try testing.expect(found);
}

test "ManifestLoader: duplicate (member :name …) emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name status :underlying symbol
        \\    :members (member-set
        \\      (member :name draft)
        \\      (member :name draft :label "Second"))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "duplicate member") != null) found = true;
    }
    try testing.expect(found);
}

// ---------------------------------------------------------------------------
// Digit-leading member spellings (`1d`, `2d`) — format 1.3. `:values` and
// `(member :name …)` are `member-name`-typed, so an element may arrive as a
// unit-bearing number. Which numbers are *spellings* is a loader question,
// hence the four rejections below rather than a meta-schema type.
// ---------------------------------------------------------------------------

fn findMember(kind: Plugin.ValueKind, name: []const u8) ?Plugin.ValueKind.MemberSet.Member {
    const ms = kind.members orelse return null;
    for (ms.members) |m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

test "ManifestLoader: :values accepts digit-leading spellings alongside symbols" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name gpu :version "1.0.0"
        \\  (value-kind :name view-dimension :underlying symbol
        \\    :members (member-set :values [1d 2d cube 3d])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const vk = r.plugin.value_kinds[0];
    try testing.expectEqual(@as(usize, 4), vk.members.?.members.len);

    // The digit-leading ones carry the `(value, unit)` match key; `cube`
    // stays an ordinary symbol member with none.
    const two = findMember(vk, "2d").?;
    try testing.expectEqual(@as(u64, 2), two.numeric_spelling.?.value);
    try testing.expectEqualStrings("d", two.numeric_spelling.?.unit);
    try testing.expect(findMember(vk, "cube").?.numeric_spelling == null);
    try testing.expect(findMember(vk, "1d") != null);
    try testing.expect(findMember(vk, "3d") != null);
}

test "ManifestLoader: (member :name 2d …) carries its editor metadata too" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name gpu :version "1.0.0"
        \\  (value-kind :name view-dimension :underlying symbol
        \\    :members (member-set
        \\      (member :name 2d :description "The default.")
        \\      (member :name 3d :deprecated true))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const vk = r.plugin.value_kinds[0];
    const two = findMember(vk, "2d").?;
    try testing.expectEqual(@as(u64, 2), two.numeric_spelling.?.value);
    try testing.expectEqualStrings("The default.", two.description);
    try testing.expect(findMember(vk, "3d").?.deprecated);
}

test "ManifestLoader: a digit-leading spelling canonicalises its magnitude" {
    // `02d` and `2.0d` declare the same member as `2d`. The name is
    // re-rendered from the integer, so a manifest's incidental spelling
    // does not reach the exported enum or a diagnostic.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name gpu :version "1.0.0"
        \\  (value-kind :name a :underlying symbol :members (member-set :values [02d]))
        \\  (value-kind :name b :underlying symbol :members (member-set :values [2.0d])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    for (r.plugin.value_kinds) |vk| {
        try testing.expectEqualStrings("2d", vk.members.?.members[0].name);
        try testing.expectEqual(@as(u64, 2), vk.members.?.members[0].numeric_spelling.?.value);
    }
}

test "ManifestLoader: a unitless number is not a member spelling" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying symbol
        \\    :members (member-set :values [1 2 3])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var count: usize = 0;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "carries no unit") != null) count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count); // one per element
}

test "ManifestLoader: a spelling's magnitude must be whole, non-negative, and in range" {
    const a = testing.allocator;
    for ([_][:0]const u8{
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying symbol
        \\    :members (member-set (member :name -1d))))
        ,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying symbol
        \\    :members (member-set (member :name 1.5d))))
        ,
        // 2^53 + 2, the first even value above the cap.
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying symbol
        \\    :members (member-set (member :name 9007199254740994d))))
        ,
    }) |src| {
        var tree = try parseSource(a, src);
        defer tree.deinit();
        var r = try load(a, tree);
        defer r.deinit();
        var found: bool = false;
        for (r.diagnostics) |d| {
            if (d.code == .invalid_manifest and
                std.mem.indexOf(u8, d.message, "whole non-negative magnitude") != null) found = true;
        }
        try testing.expect(found);
    }
}

test "ManifestLoader: 2^53 exactly is a legal spelling magnitude" {
    // The ±1 partner of the test above — the cap is inclusive.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name big :underlying symbol
        \\    :members (member-set (member :name 9007199254740992d))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(
        @as(u64, 1) << 53,
        r.plugin.value_kinds[0].members.?.members[0].numeric_spelling.?.value,
    );
}

test "ManifestLoader: a digit-leading spelling needs a symbol underlying" {
    // On a `.string` underlying the members are string literals, so no
    // numeric value can ever reach them — dead declaration, said out loud.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying string
        \\    :members (member-set (member :name 2d))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "only reachable on `symbol`") != null) found = true;
    }
    try testing.expect(found);
}

test "ManifestLoader: duplicate detection compares the spelling's identity, not its text" {
    // `2d` and `02d` canonicalise to the same name *and* the same
    // `(value, unit)`. The check is on the pair, since that is what the
    // validator matches on.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name dim :underlying symbol
        \\    :members (member-set
        \\      (member :name 2d)
        \\      (member :name 02d :label "Second"))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "duplicate member `2d`") != null) found = true;
    }
    try testing.expect(found);
}

test "ManifestLoader: the compact :values list is scanned for duplicates too" {
    // The scan used to run on `(member …)` children only, so the *common*
    // spelling accepted a set silently smaller than it looked. Both halves
    // are asserted: the byte-equal pair that was always wrong, and the
    // canonicalising pair that only became possible with digit-leading
    // members.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name plain :underlying symbol
        \\    :members (member-set :values [a b a]))
        \\  (value-kind :name dim :underlying symbol
        \\    :members (member-set :values [2d 2.0d])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .invalid_manifest, "duplicate member `a`"));
    try testing.expect(findDiagWithCode(r.diagnostics, .invalid_manifest, "duplicate member `2d`"));
}

test "ManifestLoader: a distinct compact :values list is clean" {
    // The negative space: three spellings that canonicalise apart, one of
    // each shape, stay three members.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name dim :underlying symbol
        \\    :members (member-set :values [1d 2d cube])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 3), r.plugin.value_kinds[0].members.?.members.len);
}

test "ManifestLoader: a symbol member and a digit-leading one never collide" {
    // The negative space of the test above: a member set may hold both
    // shapes, and neither is mistaken for the other.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name dim :underlying symbol
        \\    :members (member-set
        \\      (member :name cube)
        \\      (member :name 2d)
        \\      (member :name cube-array))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 3), r.plugin.value_kinds[0].members.?.members.len);
}

test "ManifestLoader: a value-kind diagnostic names its kind whatever the key order" {
    // `:members` and `:heads` build while the kvpair loop is still running,
    // so before `:name` got its own pass a manifest spelling `:members`
    // first reported "value-kind ``" with the path `/members`. Key order
    // inside a form is not significant anywhere else in SJON; both
    // spellings below must produce the identical message and path.
    const a = testing.allocator;
    for ([_][:0]const u8{
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name status :underlying symbol :members (member-set)))
        ,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :members (member-set) :name status :underlying symbol))
        ,
    }) |src| {
        var tree = try parseSource(a, src);
        defer tree.deinit();
        var r = try load(a, tree);
        defer r.deinit();
        var found: bool = false;
        for (r.diagnostics) |d| {
            if (d.code != .invalid_manifest) continue;
            if (std.mem.indexOf(u8, d.message, "no members") == null) continue;
            try testing.expect(std.mem.indexOf(u8, d.message, "`status`") != null);
            try testing.expectEqual(@as(usize, 2), d.path.len);
            try testing.expectEqualStrings("status", d.path[0]);
            try testing.expectEqualStrings("members", d.path[1]);
            found = true;
        }
        try testing.expect(found);
    }
}

test "ManifestLoader: a head-set diagnostic names its kind whatever the key order" {
    // The `:heads` twin of the test above — same in-loop build, same fix.
    const a = testing.allocator;
    for ([_][:0]const u8{
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name slot :underlying form :heads (head-set)))
        ,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :heads (head-set) :name slot :underlying form))
        ,
    }) |src| {
        var tree = try parseSource(a, src);
        defer tree.deinit();
        var r = try load(a, tree);
        defer r.deinit();
        var found: bool = false;
        for (r.diagnostics) |d| {
            if (d.code != .invalid_manifest) continue;
            if (std.mem.indexOf(u8, d.message, "no heads") == null) continue;
            try testing.expect(std.mem.indexOf(u8, d.message, "`slot`") != null);
            try testing.expectEqual(@as(usize, 2), d.path.len);
            try testing.expectEqualStrings("slot", d.path[0]);
            try testing.expectEqualStrings("heads", d.path[1]);
            found = true;
        }
        try testing.expect(found);
    }
}

// ---------------------------------------------------------------------------
// head-set — the two spellings and their four rejections. Deliberately
// laid out as a mirror of the `member-set` block above: same shapes, same
// message vocabulary ("mixes", "no heads", "duplicate head"), so a reader
// who has learned one has learned the other.
// ---------------------------------------------------------------------------

test "ManifestLoader: head-set compact spelling lowers to unbounded heads" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name vertex)
        \\  (form :name fragment)
        \\  (value-kind :name stage :underlying form
        \\    :heads (head-set :names [vertex fragment])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const hs = r.plugin.value_kinds[0].heads orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), hs.heads.len);
    try testing.expectEqualStrings("vertex", hs.heads[0].name);
    try testing.expectEqualStrings("fragment", hs.heads[1].name);
    // The compact spelling can't express a bound, so every entry is
    // unbounded and the count sweep never runs for this kind.
    try testing.expect(hs.isUnbounded());
    for (hs.heads) |h| {
        try testing.expectEqual(@as(u16, 0), h.min);
        try testing.expectEqual(@as(?u16, null), h.max);
    }
}

test "ManifestLoader: head-set rich shape carries min/max/description" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name vertex)
        \\  (form :name fragment)
        \\  (form :name constant)
        \\  (value-kind :name stage :underlying form
        \\    :heads (head-set
        \\      (head :name vertex   :min 1 :max 1 :description "Exactly one.")
        \\      (head :name fragment :max 1)
        \\      (head :name constant))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const hs = r.plugin.value_kinds[0].heads orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), hs.heads.len);
    try testing.expect(!hs.isUnbounded());
    try testing.expectEqualStrings("vertex", hs.heads[0].name);
    try testing.expectEqual(@as(u16, 1), hs.heads[0].min);
    try testing.expectEqual(@as(?u16, 1), hs.heads[0].max);
    try testing.expectEqualStrings("Exactly one.", hs.heads[0].description);
    // `:max` alone leaves the floor at 0 — "at most one, possibly none".
    try testing.expectEqual(@as(u16, 0), hs.heads[1].min);
    try testing.expectEqual(@as(?u16, 1), hs.heads[1].max);
    // A bare `(head …)` inside a rich set is still unbounded.
    try testing.expectEqual(@as(u16, 0), hs.heads[2].min);
    try testing.expectEqual(@as(?u16, null), hs.heads[2].max);
}

test "ManifestLoader: mixing :names and (head …) emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name vertex)
        \\  (form :name fragment)
        \\  (value-kind :name stage :underlying form
        \\    :heads (head-set
        \\      :names [vertex]
        \\      (head :name fragment))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .invalid_manifest, "mixes"));
}

test "ManifestLoader: empty (head-set) emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name stage :underlying form
        \\    :heads (head-set)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .invalid_manifest, "no heads"));
}

test "ManifestLoader: duplicate (head :name …) emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name vertex)
        \\  (value-kind :name stage :underlying form
        \\    :heads (head-set
        \\      (head :name vertex :max 1)
        \\      (head :name vertex :max 2))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .invalid_manifest, "duplicate head"));
}

test "ManifestLoader: head :min > :max emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name vertex)
        \\  (value-kind :name stage :underlying form
        \\    :heads (head-set (head :name vertex :min 3 :max 1))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .invalid_manifest, "empty range"));
}

test "ManifestLoader: head :min = :max is an exact count, not an empty range" {
    // The ±1 companion to the test above: `:min 2 :max 2` is the
    // "exactly two" spelling and must load clean.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name vertex)
        \\  (value-kind :name stage :underlying form
        \\    :heads (head-set (head :name vertex :min 2 :max 2))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const hs = r.plugin.value_kinds[0].heads orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 2), hs.heads[0].min);
    try testing.expectEqual(@as(?u16, 2), hs.heads[0].max);
}

test "ManifestLoader: negative and fractional head counts report wrong_underlying" {
    // Reuses `emitNumericOutOfRange`, so the code is `wrong_underlying`
    // and the prose is the same one `(fixed N)` produces — the condition
    // is identical, and a second message shape for it would be drift.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name vertex)
        \\  (form :name fragment)
        \\  (value-kind :name stage :underlying form
        \\    :heads (head-set
        \\      (head :name vertex   :min -1)
        \\      (head :name fragment :max 1.5))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var min_reported = false;
    var max_reported = false;
    for (r.diagnostics) |d| {
        if (d.code != .wrong_underlying) continue;
        if (std.mem.indexOf(u8, d.message, "`:min` requires a non-negative integer") != null) min_reported = true;
        if (std.mem.indexOf(u8, d.message, "`:max` requires a non-negative integer") != null) max_reported = true;
    }
    try testing.expect(min_reported);
    try testing.expect(max_reported);
}

// ---------------------------------------------------------------------------
// head-set aggregate counts — `:min-children` / `:max-children`, the bound
// on the *set* rather than on any one head. Two spellings carry them (the
// aggregate needs no per-head metadata, so the compact `:names` shape is
// legal here where it can carry no `(head …)` bound), and three refusals
// fall out: the set's own empty range, and the two cross-level sums.
// ---------------------------------------------------------------------------

test "ManifestLoader: head-set :min-children / :max-children on the compact spelling" {
    // The common case — "exactly one of these four" needs no per-head
    // metadata at all, so it must not force the rich spelling. This is
    // also what invalidated `isUnbounded`'s old promise that the compact
    // shape is always unbounded.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name buffer)
        \\  (form :name sampler)
        \\  (value-kind :name resource :underlying form
        \\    :heads (head-set :names [buffer sampler] :min-children 1 :max-children 1)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const hs = r.plugin.value_kinds[0].heads orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), hs.heads.len);
    try testing.expectEqual(@as(u16, 1), hs.min_children);
    try testing.expectEqual(@as(?u16, 1), hs.max_children);
    // Every *head* is still unbounded, and the set is not: `isUnbounded`
    // now has to read both levels or the count sweep never runs.
    for (hs.heads) |h| {
        try testing.expectEqual(@as(u16, 0), h.min);
        try testing.expectEqual(@as(?u16, null), h.max);
    }
    try testing.expect(!hs.isUnbounded());
}

test "ManifestLoader: set bounds ride alongside per-head bounds" {
    // Both levels at once — "one of each, up to two" is the shape neither
    // level can express alone.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name buffer)
        \\  (form :name sampler)
        \\  (value-kind :name resource :underlying form
        \\    :heads (head-set :max-children 2
        \\      (head :name buffer  :max 1)
        \\      (head :name sampler :max 1))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const hs = r.plugin.value_kinds[0].heads orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 0), hs.min_children);
    try testing.expectEqual(@as(?u16, 2), hs.max_children);
    try testing.expectEqual(@as(?u16, 1), hs.heads[0].max);
}

test "ManifestLoader: a head-set with no set bounds leaves the pair at its default" {
    // The drift gate for every head-set written before S10: absent keys
    // must lower to `0` / `null`, which is what keeps an all-unbounded
    // compact set on the `isUnbounded` fast path.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name buffer)
        \\  (value-kind :name resource :underlying form
        \\    :heads (head-set :names [buffer])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const hs = r.plugin.value_kinds[0].heads orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 0), hs.min_children);
    try testing.expectEqual(@as(?u16, null), hs.max_children);
    try testing.expect(hs.isUnbounded());
}

test "ManifestLoader: :min-children > :max-children emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name buffer)
        \\  (value-kind :name resource :underlying form
        \\    :heads (head-set :names [buffer] :min-children 3 :max-children 1)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .invalid_manifest, "empty child range"));
}

test "ManifestLoader: :min-children = :max-children is exactly-N, not an empty range" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name buffer)
        \\  (value-kind :name resource :underlying form
        \\    :heads (head-set :names [buffer] :min-children 2 :max-children 2)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "ManifestLoader: Σ head.min above :max-children emits invalid_manifest" {
    // The check the *weaker* per-head spelling would have let through:
    // neither head's `:min 1` exceeds `:max-children 1`, yet satisfying
    // both needs two children and the set allows one. Only the sum sees
    // it, which is why the cross-check is a sum and not a comparison.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name buffer)
        \\  (form :name sampler)
        \\  (value-kind :name resource :underlying form
        \\    :heads (head-set :max-children 1
        \\      (head :name buffer  :min 1)
        \\      (head :name sampler :min 1))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .invalid_manifest, "require at least 2 child(ren) together"));
}

test "ManifestLoader: Σ head.min equal to :max-children is satisfiable" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name buffer)
        \\  (form :name sampler)
        \\  (value-kind :name resource :underlying form
        \\    :heads (head-set :max-children 2
        \\      (head :name buffer  :min 1)
        \\      (head :name sampler :min 1))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "ManifestLoader: :min-children above Σ head.max emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name buffer)
        \\  (form :name sampler)
        \\  (value-kind :name resource :underlying form
        \\    :heads (head-set :min-children 3
        \\      (head :name buffer  :max 1)
        \\      (head :name sampler :max 1))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .invalid_manifest, "2 child(ren) its heads allow together"));
}

test "ManifestLoader: one unbounded head makes the Σ head.max check vacuous" {
    // The ceiling sum is only finite when *every* head is bounded. One
    // unbounded head means the set can always be filled, so the check must
    // not fire — otherwise a perfectly satisfiable schema is refused.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name buffer)
        \\  (form :name sampler)
        \\  (value-kind :name resource :underlying form
        \\    :heads (head-set :min-children 9
        \\      (head :name buffer  :max 1)
        \\      (head :name sampler))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "ManifestLoader: negative and fractional set counts report wrong_underlying" {
    // Same reuse of `emitNumericOutOfRange` the per-head pair gets, for
    // the same reason: the condition is identical.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name buffer)
        \\  (value-kind :name resource :underlying form
        \\    :heads (head-set :names [buffer] :min-children -1 :max-children 1.5)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var min_reported = false;
    var max_reported = false;
    for (r.diagnostics) |d| {
        if (d.code != .wrong_underlying) continue;
        if (std.mem.indexOf(u8, d.message, "`:min-children` requires a non-negative integer") != null) min_reported = true;
        if (std.mem.indexOf(u8, d.message, "`:max-children` requires a non-negative integer") != null) max_reported = true;
    }
    try testing.expect(min_reported);
    try testing.expect(max_reported);
}

test "ManifestLoader: unit-shape :reject true loads with reject set" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bare :underlying number
        \\    :unit (unit-shape :reject true)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 1), r.plugin.value_kinds.len);
    const u = r.plugin.value_kinds[0].unit.?;
    try testing.expect(u.reject);
    try testing.expect(!u.required);
    try testing.expectEqual(@as(usize, 0), u.allowed.len);
}

test "ManifestLoader: unit-shape :reject + :required emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying number
        \\    :unit (unit-shape :reject true :required true)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "forbid and demand") != null) found = true;
    }
    try testing.expect(found);
}

test "ManifestLoader: unit-shape :reject + :allowed emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying number
        \\    :unit (unit-shape :reject true :allowed [ms s])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "contradict") != null) found = true;
    }
    try testing.expect(found);
}

test "ManifestLoader: vector-shape :min-len/:max-len load with the bounds set" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name list :underlying vector
        \\    :vector (vector-shape :element number :min-len 1 :max-len 4)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const vs = r.plugin.value_kinds[0].vector.?;
    try testing.expectEqual(@as(?u16, 1), vs.min_len);
    try testing.expectEqual(@as(?u16, 4), vs.max_len);
    try testing.expectEqual(@as(?u16, null), vs.len);
}

test "ManifestLoader: vector-shape :len + :min-len emits vector_bounds_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name list :underlying vector
        \\    :vector (vector-shape :element number :len 3 :min-len 1)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .vector_bounds_invalid and
            std.mem.indexOf(u8, d.message, "subsumes") != null) found = true;
    }
    try testing.expect(found);
}

test "ManifestLoader: vector-shape :min-len > :max-len emits vector_bounds_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name list :underlying vector
        \\    :vector (vector-shape :element number :min-len 5 :max-len 2)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .vector_bounds_invalid and
            std.mem.indexOf(u8, d.message, "empty range") != null) found = true;
    }
    try testing.expect(found);
}

test "ManifestLoader: a form with key + positional" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene :open false :positional any
        \\    (key :name title :type string :optional false)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 1), r.plugin.forms.len);
    const f = r.plugin.forms[0];
    try testing.expectEqualStrings("scene", f.name);
    try testing.expectEqual(false, f.open);
    try testing.expectEqual(Plugin.PositionalSpec.any, f.positional);
    try testing.expectEqual(@as(usize, 1), f.keys.len);
    try testing.expectEqualStrings("title", f.keys[0].name);
    try testing.expectEqual(Plugin.ValueType.string, f.keys[0].value_type);
    try testing.expectEqual(false, f.keys[0].optional);
}

test "ManifestLoader: flag-set carries :description/:link metadata" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name task
        \\    :positional (flag-set
        \\      (flag :name done
        \\        :description "Marks the task as complete."
        \\        :link "https://example.com/docs#done")
        \\      (flag :name archived))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 1), r.plugin.forms.len);
    const fs = switch (r.plugin.forms[0].positional) {
        .flag_set => |captured| captured,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 2), fs.flags.len);
    try testing.expectEqualStrings("done", fs.flags[0].name);
    try testing.expectEqualStrings("Marks the task as complete.", fs.flags[0].description);
    try testing.expectEqualStrings("https://example.com/docs#done", fs.flags[0].link.?);
    // The second flag omits metadata → "" / null defaults.
    try testing.expectEqualStrings("archived", fs.flags[1].name);
    try testing.expectEqualStrings("", fs.flags[1].description);
    try testing.expectEqual(@as(?[]const u8, null), fs.flags[1].link);
}

test "ManifestLoader: duplicate (flag :name …) in a flag-set emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name task
        \\    :positional (flag-set
        \\      (flag :name done)
        \\      (flag :name done))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "duplicate flag") != null) found = true;
    }
    try testing.expect(found);
}

test "ManifestLoader: empty (flag-set) emits invalid_manifest" {
    // A flag-set with no `(flag …)` children is a useless closed set —
    // `parseFlagSet` rejects it the way `buildMemberSet` rejects an empty
    // member-set. The positional still resolves to an empty `flag_set`
    // so downstream membership checks stay total.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name task :positional (flag-set)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "declares no flags") != null) found = true;
    }
    try testing.expect(found);
}

test "ManifestLoader: expr-func with typed signature" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name add :arity (fixed 2)
        \\    :params [number number] :result number))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 1), r.plugin.expr_funcs.len);
    const f = r.plugin.expr_funcs[0];
    try testing.expectEqualStrings("add", f.name);
    try testing.expectEqual(@as(u8, 2), f.arity.fixed);
    try testing.expectEqual(@as(usize, 2), f.params.?.len);
    try testing.expectEqual(Plugin.ValueType.number, f.params.?[0]);
    try testing.expectEqual(Plugin.ValueType.number, f.result.?);
}

test "ManifestLoader: rejects manifest with wrong-shaped declarations" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-knd :name typo :underlying string))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
}

// ---------------------------------------------------------------------------
// MAX_FORM_KEYS — load-time cap on `:keyword` slots per form.
// ---------------------------------------------------------------------------

fn buildKeysSource(a: Allocator, n: usize) ![:0]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "(plugin :name p :version \"1.0.0\"\n  (form :name f");
    for (0..n) |i| {
        var num_buf: [16]u8 = undefined;
        const num = try std.fmt.bufPrint(&num_buf, "{d}", .{i});
        try buf.appendSlice(a, "\n    (key :name k");
        try buf.appendSlice(a, num);
        try buf.appendSlice(a, " :type any)");
    }
    try buf.appendSlice(a, "))");
    const z = try a.allocSentinel(u8, buf.items.len, 0);
    @memcpy(z, buf.items);
    return z;
}

test "ManifestLoader: form with exactly MAX_FORM_KEYS keys loads clean" {
    const a = testing.allocator;
    const src = try buildKeysSource(a, Plugin.MAX_FORM_KEYS);
    defer a.free(src);
    var tree = try parseSource(a, src);
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 1), r.plugin.forms.len);
    try testing.expectEqual(Plugin.MAX_FORM_KEYS, r.plugin.forms[0].keys.len);
}

test "ManifestLoader: rejects form with more than MAX_FORM_KEYS keys" {
    const a = testing.allocator;
    const declared = Plugin.MAX_FORM_KEYS + 1;
    const src = try buildKeysSource(a, declared);
    defer a.free(src);
    var tree = try parseSource(a, src);
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());

    var too_many: usize = 0;
    for (r.diagnostics) |d| {
        if (d.code == .too_many_keys) too_many += 1;
    }
    try testing.expectEqual(@as(usize, 1), too_many);

    // Truncation invariant: the post-load FormSpec must satisfy the
    // validator's `spec.keys.len <= MAX_FORM_KEYS` assert regardless of
    // how many `(key …)` children were declared in source.
    try testing.expectEqual(@as(usize, 1), r.plugin.forms.len);
    try testing.expectEqual(Plugin.MAX_FORM_KEYS, r.plugin.forms[0].keys.len);
}

// ---------------------------------------------------------------------------
// :default — manifest → KeySpec.default + spec-correct optional rule.
// ---------------------------------------------------------------------------

test "ManifestLoader: :default round-trips primitive literals" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name title  :type string  :default "Untitled")
        \\    (key :name fps    :type number  :default 60)
        \\    (key :name mode   :type symbol  :default loop)
        \\    (key :name muted  :type boolean :default false)
        \\    (key :name parent :type any     :default nil)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const f = r.plugin.forms[0];
    try testing.expectEqual(@as(usize, 5), f.keys.len);

    try testing.expectEqualStrings("Untitled", f.keys[0].default.?.string);
    try testing.expectEqual(@as(f64, 60), f.keys[1].default.?.number);
    try testing.expectEqualStrings("loop", f.keys[2].default.?.symbol);
    try testing.expectEqual(false, f.keys[3].default.?.boolean);
    try testing.expectEqual(Plugin.KeySpec.Default.nil, f.keys[4].default.?);

    // Each key with a default is implicitly optional regardless of the
    // omitted `:optional` flag.
    for (f.keys) |k| try testing.expect(k.effectiveOptional());
}

test "ManifestLoader: :default vector preserves element order" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name canvas
        \\    (key :name origin :type vector :default [0 0])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const v = r.plugin.forms[0].keys[0].default.?.vector;
    try testing.expectEqual(@as(usize, 2), v.len);
    try testing.expectEqual(@as(f64, 0), v[0].number);
    try testing.expectEqual(@as(f64, 0), v[1].number);
}

test "ManifestLoader: :default with wrong tag emits wrong_underlying" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name title :type number :default "oops")))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());

    var found_code = false;
    var found_path = false;
    for (r.diagnostics) |d| {
        if (d.code != .wrong_underlying) continue;
        found_code = true;
        // path = [scene, title, default]
        if (d.path.len == 3 and
            std.mem.eql(u8, d.path[0], "scene") and
            std.mem.eql(u8, d.path[1], "title") and
            std.mem.eql(u8, d.path[2], "default"))
        {
            found_path = true;
        }
    }
    try testing.expect(found_code);
    try testing.expect(found_path);
}

test "ManifestLoader: :default accepts a mono expression form" {
    // Expression-shaped defaults snapshot the head/namespace/argc so
    // `Schema.validateDefaults` can classify them at aggregate phase.
    // Load-time stores the snapshot without verdict.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name radius :type number :default (pi))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const d = r.plugin.forms[0].keys[0].default.?;
    try testing.expect(d == .expression);
    try testing.expectEqualStrings("pi", d.expression.head);
    try testing.expect(d.expression.namespace == null);
    try testing.expectEqual(@as(u32, 0), d.expression.arg_count);
    try testing.expect(r.plugin.forms[0].keys[0].effectiveOptional());
}

test "ManifestLoader: :walk-opaque true round-trips onto the KeySpec" {
    // Wire-level `:walk-opaque true` must surface as KeySpec.walk_opaque
    // so the validator skips recursive descent into the slot's value.
    // The accompanying `:default (pi)` exercises the suppression: without
    // walk_opaque, descending into `(pi)` would be an `unknown_form`.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name fill :type any :walk-opaque true :default (pi))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expect(r.plugin.forms[0].keys[0].walk_opaque);
}

test "ManifestLoader: walk_opaque defaults to false when :walk-opaque absent" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name title :type string :optional true)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expect(!r.plugin.forms[0].keys[0].walk_opaque);
}

test "ManifestLoader: loadUnchecked builds a manifest without meta-validation" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name title :type string :optional false)))
    );
    defer tree.deinit();
    var r = try loadUnchecked(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqualStrings("p", r.plugin.name);
    try testing.expectEqualStrings("1.0.0", r.plugin.version);
    try testing.expectEqual(@as(usize, 1), r.plugin.forms.len);
}

test "ManifestLoader: loadUnchecked skips the meta-validation load enforces" {
    // A manifest with an unknown key on (plugin …) fails `load`'s
    // meta-validation pre-pass (unknown_key), but `loadUnchecked` skips
    // that pass and builds — buildPlugin simply ignores the stray key.
    // This is the property tools/gen_meta_schema.zig relies on when it
    // loads meta.sjon (the source of the very schema load would check).
    const a = testing.allocator;
    const src =
        \\(plugin :name p :version "1.0.0" :bogus 1
        \\  (form :name scene
        \\    (key :name title :type string :optional false)))
    ;

    var tree_a = try parseSource(a, src);
    defer tree_a.deinit();
    var checked = try load(a, tree_a);
    defer checked.deinit();
    try testing.expect(checked.hasErrors());

    var tree_b = try parseSource(a, src);
    defer tree_b.deinit();
    var unchecked = try loadUnchecked(a, tree_b);
    defer unchecked.deinit();
    try testing.expect(!unchecked.hasErrors());
    try testing.expectEqualStrings("p", unchecked.plugin.name);
}

test "ManifestLoader: :walk-opaque false yields walk_opaque == false" {
    // Completes the truth table alongside the `true`/absent cases:
    // an explicit `false` must not flip the bit on.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name fill :type any :walk-opaque false)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expect(!r.plugin.forms[0].keys[0].walk_opaque);
}

test "ManifestLoader: load rejects a non-boolean :walk-opaque (meta :type boolean guard)" {
    // The meta-spec change declares `(key :name walk-opaque :type boolean
    // :optional true)`. A non-boolean value must fail meta-validation,
    // proving the wire key is actually constrained — not silently coerced.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name fill :type any :walk-opaque 5)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    // Meta-validation failed, so no plugin was built.
    try testing.expectEqual(@as(usize, 0), r.plugin.forms.len);
    var saw_wrong_underlying = false;
    for (r.diagnostics) |d| {
        if (d.code == .wrong_underlying) saw_wrong_underlying = true;
    }
    try testing.expect(saw_wrong_underlying);
}

test "ManifestLoader: loadUnchecked still surfaces structural diagnostics" {
    // The doc contract: loadUnchecked skips the *meta-validation* pre-pass
    // but keeps buildPlugin's own structural checks. A malformed
    // :wasm-sha256 pin must still produce plugin_wasm_self_hash_malformed.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0" :wasm-sha256 "not-a-hash")
    );
    defer tree.deinit();
    var r = try loadUnchecked(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var saw = false;
    for (r.diagnostics) |d| {
        if (d.code == .plugin_wasm_self_hash_malformed) saw = true;
    }
    try testing.expect(saw);
}

test "ManifestLoader: loadUnchecked rejects a non-plugin root" {
    // Step-2 structural re-check (load's meta-validation guaranteed this
    // shape; loadUnchecked must re-assert it since that pass is skipped).
    const a = testing.allocator;
    var tree = try parseSource(a, "(widget :name x)");
    defer tree.deinit();
    try testing.expectError(error.NotAPluginManifest, loadUnchecked(a, tree));
}

test "ManifestLoader: loadUnchecked rejects a multi-root tree" {
    // Two roots → not a single (plugin …) manifest.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name a :version "1.0.0")
        \\(plugin :name b :version "1.0.0")
    );
    defer tree.deinit();
    try testing.expectError(error.NotAPluginManifest, loadUnchecked(a, tree));
}

test "ManifestLoader: :default accepts a multi-arg expression form" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name fps :type number :default (* 2 16))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const d = r.plugin.forms[0].keys[0].default.?;
    try testing.expect(d == .expression);
    try testing.expectEqualStrings("*", d.expression.head);
    try testing.expect(d.expression.namespace == null);
    try testing.expectEqual(@as(u32, 2), d.expression.arg_count);
}

test "ManifestLoader: :default expression retains evaluable program" {
    // The substrate guarantee: a form-shaped default carries a one-root
    // Binary IR program in the plugin arena so a future materialization
    // pass can call Expr.evalBinary against an empty env. Round-trip
    // `(* 2 16)` here as the proof that the encoded bytes survive
    // manifest-tree teardown and decode to 32.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name fps :type number :default (* 2 16))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const d = r.plugin.forms[0].keys[0].default.?;
    try testing.expect(d == .expression);
    try testing.expect(d.expression.program.len > 0);

    const schema = Schema.Schema.init(&.{core.plugin});
    const empty_env: Expr.Env = .{};
    var result = try Expr.evalBinary(a, d.expression.program, &empty_env, schema);
    defer result.deinit();
    try testing.expect(result.value == .number);
    try testing.expectEqual(@as(f64, 32), result.value.number);
}

test "ManifestLoader: :default expression preserves namespace" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name r :type number :default (math/pi))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    const d = r.plugin.forms[0].keys[0].default.?;
    try testing.expect(d == .expression);
    try testing.expectEqualStrings("pi", d.expression.head);
    try testing.expect(d.expression.namespace != null);
    try testing.expectEqualStrings("math", d.expression.namespace.?);
}

test "ManifestLoader: :default vector with form element rejected (whole vector dropped)" {
    // Vectors of expression elements are deferred — the whole vector is
    // dropped (default stays null). Authors who need a computed vector
    // should write `:default (vec3 0 0 0)` instead of `[0 0 (* 0 1)]`.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name canvas
        \\    (key :name origin :type vector :default [0 (* 0 1)])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.plugin.forms[0].keys[0].default == null);
}

test "ManifestLoader: omitted :optional defaults to false (manifest convention)" {
    // Doc spec §5.1: `:optional` defaults to false when no `:default`
    // is present. The Zig struct's default is true (ergonomic for
    // direct in-source plugin declarations); the loader fixes it up to
    // match the manifest convention.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name title :type string)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(false, r.plugin.forms[0].keys[0].optional);
}

test "ManifestLoader: omitted :optional with :default becomes true" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name title :type string :default "x")))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(true, r.plugin.forms[0].keys[0].optional);
}

test "ManifestLoader: explicit :optional wins over default-implied rule" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name title :type string :optional false :default "x")))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    // Explicit `:optional false` is preserved on the struct, but the
    // `effectiveOptional` predicate still returns true because the
    // default-presence overrides for missing-required purposes.
    try testing.expectEqual(false, r.plugin.forms[0].keys[0].optional);
    try testing.expect(r.plugin.forms[0].keys[0].effectiveOptional());
}

// ---------------------------------------------------------------------------
// Multi-signature ExprFunc encoding.
// ---------------------------------------------------------------------------

test "ManifestLoader: expr-func with (signature ...) overloads" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name lerp
        \\    (signature :arity (fixed 3) :params [number number number] :result number)
        \\    (signature :arity (fixed 3) :params [vector vector number]  :result vector)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());

    const f = r.plugin.expr_funcs[0];
    try testing.expectEqualStrings("lerp", f.name);
    const sigs = f.signatures orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), sigs.len);
    try testing.expectEqual(@as(u8, 3), sigs[0].arity.fixed);
    try testing.expectEqual(Plugin.ValueType.number, sigs[0].params.?[0]);
    try testing.expectEqual(Plugin.ValueType.number, sigs[0].result.?);
    try testing.expectEqual(Plugin.ValueType.vector, sigs[1].params.?[0]);
    try testing.expectEqual(Plugin.ValueType.vector, sigs[1].result.?);

    // Mono fields must not co-exist with the overload set; the loader
    // clears them so the iterator never mixes encodings.
    try testing.expect(f.params == null);
    try testing.expect(f.rest == null);
    try testing.expect(f.result == null);
    try testing.expectEqual(@as(usize, 2), f.signatureCount());
}

test "ManifestLoader: mixed mono + signature emits load diagnostic" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name muddle :arity (fixed 1) :params [number]
        \\    (signature :arity (fixed 1) :params [string])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());

    var found = false;
    for (r.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "mixes mono-signature fields") != null) {
            found = true;
        }
    }
    try testing.expect(found);
    // Even with the diagnostic, the loader prefers the overload
    // encoding; the in-memory ExprFunc carries `signatures` only.
    const f = r.plugin.expr_funcs[0];
    const sigs = f.signatures orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), sigs.len);
    try testing.expect(f.params == null);
}

// ---------------------------------------------------------------------------
// Numeric narrowing — meta-validation only proves "is a number", so the
// loader has to reject fractional / negative / oversized values before
// the `@intFromFloat` narrowing site would invoke illegal behavior.
// ---------------------------------------------------------------------------

fn findNumericOutOfRange(
    diags: []const Ast.Diagnostic,
    expected_field: []const u8,
    expected_path: []const []const u8,
) bool {
    for (diags) |d| {
        if (d.code != .wrong_underlying) continue;
        if (std.mem.indexOf(u8, d.message, "non-negative integer") == null) continue;
        if (std.mem.indexOf(u8, d.message, expected_field) == null) continue;
        if (d.path.len != expected_path.len) continue;
        var match = true;
        for (d.path, expected_path) |a_step, e_step| {
            if (!std.mem.eql(u8, a_step, e_step)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

test "ManifestLoader: vector-shape :len rejects negative" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name vec3 :underlying vector
        \\    :vector (vector-shape :len -1 :element number)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findNumericOutOfRange(r.diagnostics, "len", &.{ "vec3", "vector", "len" }));
    // Field stays unset on rejection.
    try testing.expect(r.plugin.value_kinds[0].vector.?.len == null);
}

test "ManifestLoader: vector-shape :len rejects fractional" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name vec3 :underlying vector
        \\    :vector (vector-shape :len 1.5 :element number)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findNumericOutOfRange(r.diagnostics, "len", &.{ "vec3", "vector", "len" }));
}

test "ManifestLoader: vector-shape :len rejects oversized (> u16)" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name vec3 :underlying vector
        \\    :vector (vector-shape :len 70000 :element number)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findNumericOutOfRange(r.diagnostics, "len", &.{ "vec3", "vector", "len" }));
}

test "ManifestLoader: arity (fixed N) rejects oversized (> u8)" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name big :arity (fixed 999)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findNumericOutOfRange(
        r.diagnostics,
        "fixed",
        &.{ "big", "arity", "fixed" },
    ));
    // Falls back to the zero default rather than a corrupted narrow.
    try testing.expectEqual(@as(u8, 0), r.plugin.expr_funcs[0].arity.fixed);
}

test "ManifestLoader: arity (at-least N) rejects negative" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name oops :arity (at-least -1)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findNumericOutOfRange(
        r.diagnostics,
        "at-least",
        &.{ "oops", "arity", "at-least" },
    ));
}

test "ManifestLoader: arity (range :min :max) rejects oversized :max" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name r :arity (range :min 0 :max 9999)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findNumericOutOfRange(
        r.diagnostics,
        "max",
        &.{ "r", "arity", "range", "max" },
    ));
}

test "ManifestLoader: signature arity narrowing diagnostics carry the signature path" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name lerp
        \\    (signature :arity (fixed 999) :params [number])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findNumericOutOfRange(
        r.diagnostics,
        "fixed",
        &.{ "lerp", "signature", "arity", "fixed" },
    ));
}

test "ManifestLoader: in-range arity values still narrow cleanly" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name f :arity (range :min 1 :max 4)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const arity = r.plugin.expr_funcs[0].arity;
    try testing.expectEqual(@as(u8, 1), arity.range.min);
    try testing.expectEqual(@as(u8, 4), arity.range.max);
}

// ----- Exclusive-group manifest-load tests --------------------------------

/// True if any diagnostic carries `code` and a message containing `needle`.
/// Shared by the exclusive-group / numeric-bounds / string-bounds finders,
/// which differ only in the code they match.
fn findDiagWithCode(
    diags: []const Ast.Diagnostic,
    code: Ast.Diagnostic.Code,
    needle: []const u8,
) bool {
    for (diags) |d| {
        if (d.code != code) continue;
        if (std.mem.indexOf(u8, d.message, needle) != null) return true;
    }
    return false;
}

test "ManifestLoader: (exclusive-group ...) round-trips into FormSpec.exclusive_groups" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name phrase
        \\    (key :name name   :type symbol :optional false)
        \\    (key :name notes  :type vector :optional true)
        \\    (key :name events :type vector :optional true)
        \\    (exclusive-group :cardinality exactly-one
        \\      (alt :keys [notes])
        \\      (alt :keys [events]))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const f = r.plugin.forms[0];
    try testing.expectEqual(@as(usize, 1), f.exclusive_groups.len);
    const g = f.exclusive_groups[0];
    try testing.expectEqual(Plugin.Cardinality.exactly_one, g.cardinality);
    try testing.expectEqual(@as(usize, 2), g.alternatives.len);
    try testing.expectEqualStrings("notes", g.alternatives[0].keys[0]);
    try testing.expectEqualStrings("events", g.alternatives[1].keys[0]);
}

test "ManifestLoader: alt names an unknown key emits exclusive_group_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name phrase
        \\    (key :name notes  :type vector :optional true)
        \\    (key :name events :type vector :optional true)
        \\    (exclusive-group :cardinality exactly-one
        \\      (alt :keys [notes])
        \\      (alt :keys [evnts]))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expectEqual(
        Ast.Diagnostic.Code.exclusive_group_invalid,
        r.diagnostics[0].code,
    );
    try testing.expect(findDiagWithCode(r.diagnostics, .exclusive_group_invalid, "evnts"));
}

test "ManifestLoader: single-alt group emits exclusive_group_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name phrase
        \\    (key :name notes :type vector :optional true)
        \\    (exclusive-group :cardinality exactly-one
        \\      (alt :keys [notes]))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .exclusive_group_invalid, "at least 2"));
}

test "ManifestLoader: same key in two groups emits exclusive_group_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name phrase
        \\    (key :name notes  :type vector :optional true)
        \\    (key :name events :type vector :optional true)
        \\    (key :name beats  :type vector :optional true)
        \\    (exclusive-group :cardinality exactly-one
        \\      (alt :keys [notes])
        \\      (alt :keys [events]))
        \\    (exclusive-group :cardinality at-most-one
        \\      (alt :keys [notes])
        \\      (alt :keys [beats]))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .exclusive_group_invalid, "more than one"));
}

test "ManifestLoader: group naming the discriminant emits exclusive_group_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name track
        \\    :discriminant kind
        \\    (key :name name   :type symbol :optional false)
        \\    (key :name kind   :type symbol :optional false)
        \\    (key :name events :type vector :optional true)
        \\    (exclusive-group :cardinality exactly-one
        \\      (alt :keys [kind])
        \\      (alt :keys [events]))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .exclusive_group_invalid, "discriminant"));
}

test "ManifestLoader: (lowering …) round-trips into FormSpec.lowering" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name pass
        \\    :lowering (lowering :hook pngine/pass-v1
        \\      :produces [shader texture pipeline])
        \\    (key :name name :type symbol :optional false)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 1), r.plugin.forms.len);
    const f = r.plugin.forms[0];
    const low = f.lowering orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("pngine/pass-v1", low.hook);
    try testing.expectEqual(@as(usize, 3), low.produces.len);
    try testing.expectEqualStrings("shader", low.produces[0]);
    try testing.expectEqualStrings("texture", low.produces[1]);
    try testing.expectEqualStrings("pipeline", low.produces[2]);
}

test "ManifestLoader: FormSpec.lowering is null when :lowering is absent" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name plain
        \\    (key :name name :type symbol :optional false)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expect(r.plugin.forms[0].lowering == null);
}

test "ManifestLoader: lowering with empty :produces emits wrong_underlying" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name pass
        \\    :lowering (lowering :hook pngine/pass-v1 :produces [])
        \\    (key :name name :type symbol :optional false)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found = false;
    for (r.diagnostics) |d| {
        if (d.code == .wrong_underlying and
            std.mem.indexOf(u8, d.message, "lowering") != null and
            std.mem.indexOf(u8, d.message, "produced head") != null)
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "ManifestLoader: lowering with duplicate :produces emits wrong_underlying" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name pass
        \\    :lowering (lowering :hook pngine/pass-v1
        \\      :produces [shader shader pipeline])
        \\    (key :name name :type symbol :optional false)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found = false;
    for (r.diagnostics) |d| {
        if (d.code == .wrong_underlying and
            std.mem.indexOf(u8, d.message, "lowering") != null and
            std.mem.indexOf(u8, d.message, "listed twice") != null)
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "ManifestLoader: a :produces head with an empty half emits wrong_underlying" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name pass
        \\    :lowering (lowering :hook pngine/pass-v1
        \\      :produces [x/ /y ok])
        \\    (key :name name :type symbol :optional false)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: usize = 0;
    for (r.diagnostics) |d| {
        if (d.code == .wrong_underlying and std.mem.indexOf(u8, d.message, "empty name or namespace half") != null) found += 1;
    }
    try testing.expectEqual(@as(usize, 2), found);
}

// ----- Numeric-bounds manifest-load tests ----------------------------------

test "ManifestLoader: (numeric-bounds …) round-trips into ValueKind.numeric" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name opacity :underlying number
        \\    :numeric (numeric-bounds :min 0 :max 1)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const vk = r.plugin.value_kinds[0];
    try testing.expectEqualStrings("opacity", vk.name);
    const nb = vk.numeric orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(f64, 0.0), nb.min.?.value);
    try testing.expectEqual(@as(f64, 1.0), nb.max.?.value);
    try testing.expect(nb.min.?.exact_int);
    try testing.expect(nb.max.?.exact_int);
    try testing.expect(!nb.exclusive_min);
    try testing.expect(!nb.exclusive_max);
    try testing.expect(!nb.integer);
}

test "ManifestLoader: (repr-shape …) round-trips into ValueKind.repr" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name channel :underlying number
        \\    :repr (repr-shape :type f32)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const vk = r.plugin.value_kinds[0];
    try testing.expectEqualStrings("channel", vk.name);
    try testing.expectEqual(Plugin.ValueKind.Repr.f32, vk.repr orelse return error.TestUnexpectedResult);
}

test "ManifestLoader: every :repr type tag parses to its enum" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name a :underlying number :repr (repr-shape :type f32))
        \\  (value-kind :name b :underlying number :repr (repr-shape :type u32))
        \\  (value-kind :name c :underlying number :repr (repr-shape :type i32))
        \\  (value-kind :name d :underlying number :repr (repr-shape :type u16))
        \\  (value-kind :name e :underlying number :repr (repr-shape :type f16)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const want = [_]Plugin.ValueKind.Repr{ .f32, .u32, .i32, .u16, .f16 };
    for (want, 0..) |w, i| {
        try testing.expectEqual(w, r.plugin.value_kinds[i].repr orelse return error.TestUnexpectedResult);
    }
}

test "ManifestLoader: :repr on non-number underlying emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying string
        \\    :repr (repr-shape :type f32)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "`:repr`") != null and
            std.mem.indexOf(u8, d.message, "not `number`") != null) found = true;
    }
    try testing.expect(found);
}

test "ManifestLoader: :underlying scalar-or-ref desugars to union [base symbol]" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name count-value :underlying number)
        \\  (value-kind :name count
        \\    :underlying scalar-or-ref
        \\    :scalar-or-ref (scalar-or-ref-shape :base count-value)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const vk = r.plugin.value_kinds[1];
    try testing.expectEqualStrings("count", vk.name);
    try testing.expectEqual(Plugin.ValueKind.Underlying.union_of, vk.underlying);
    const us = vk.union_of orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), us.alternatives.len);
    try testing.expectEqualStrings("count-value", us.alternatives[0].name);
    try testing.expectEqualStrings("symbol", us.alternatives[1].name);
}

test "ManifestLoader: scalar-or-ref :ref substitutes for the default symbol" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name count-value :underlying number)
        \\  (value-kind :name define-ref :underlying symbol
        \\    :cross-ref (cross-ref :target define))
        \\  (value-kind :name count
        \\    :underlying scalar-or-ref
        \\    :scalar-or-ref (scalar-or-ref-shape :base count-value :ref define-ref)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const us = r.plugin.value_kinds[2].union_of orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), us.alternatives.len);
    try testing.expectEqualStrings("count-value", us.alternatives[0].name);
    // The whole feature: alternative 1 is the named kind, not `symbol`.
    try testing.expectEqualStrings("define-ref", us.alternatives[1].name);
}

test "ManifestLoader: scalar-or-ref :ref accepts a qualified ref" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name count-value :underlying number)
        \\  (value-kind :name count
        \\    :underlying scalar-or-ref
        \\    :scalar-or-ref (scalar-or-ref-shape :base count-value :ref other/define-ref)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    const us = r.plugin.value_kinds[1].union_of orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("define-ref", us.alternatives[1].name);
    const ns = us.alternatives[1].namespace orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("other", ns);
}

test "ManifestLoader: scalar-or-ref :ref equal to :base emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name count-value :underlying number)
        \\  (value-kind :name count
        \\    :underlying scalar-or-ref
        \\    :scalar-or-ref (scalar-or-ref-shape :base count-value :ref count-value)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "`:ref` equal to `:base`") != null) found = true;
    }
    try testing.expect(found);
}

test "ManifestLoader: scalar-or-ref :ref differing only in namespace is not a collision" {
    // `qualifiedRefEql` is byte-equality on both halves: a bare name and a
    // qualified one are different refs even when the namespace names this
    // plugin, matching the loader's resolution rule elsewhere.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name count-value :underlying number)
        \\  (value-kind :name count
        \\    :underlying scalar-or-ref
        \\    :scalar-or-ref (scalar-or-ref-shape :base count-value :ref p/count-value)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    for (r.diagnostics) |d| {
        try testing.expect(std.mem.indexOf(u8, d.message, "`:ref` equal to `:base`") == null);
    }
}

test "ManifestLoader: :underlying scalar-or-ref without :scalar-or-ref slot emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying scalar-or-ref))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "scalar-or-ref") != null) found = true;
    }
    try testing.expect(found);
}

test "ManifestLoader: :scalar-or-ref on non-scalar-or-ref underlying emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name count-value :underlying number)
        \\  (value-kind :name bad
        \\    :underlying number
        \\    :scalar-or-ref (scalar-or-ref-shape :base count-value)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "`:scalar-or-ref`") != null and
            std.mem.indexOf(u8, d.message, "not `scalar-or-ref`") != null) found = true;
    }
    try testing.expect(found);
}

// ---------------------------------------------------------------------------
// S14 — `(variant :when [a b])`. The loader normalises both spellings to
// `Plugin.Variant.when` (a list) and decides everything a list can carry
// that a symbol cannot: empty, a repeat, a value two variants both list.
// ---------------------------------------------------------------------------

test "ManifestLoader: variant :when accepts a symbol or a vector, both normalised to a list" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name topo :underlying symbol
        \\    :members (member-set :values [tri-list tri-strip line-list line-strip]))
        \\  (form :name prim :discriminant topo-key
        \\    (key :name topo-key :type topo :optional false)
        \\    (variant :when [tri-strip line-strip]
        \\      (key :name strip-format :type symbol :optional true))
        \\    (variant :when line-list
        \\      (key :name line-width :type number :optional true))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const variants = r.plugin.forms[0].variants orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), variants.len);
    try testing.expectEqual(@as(usize, 2), variants[0].when.len);
    try testing.expectEqualStrings("tri-strip", variants[0].when[0]);
    try testing.expectEqualStrings("line-strip", variants[0].when[1]);
    try testing.expectEqual(@as(usize, 1), variants[1].when.len);
    try testing.expectEqualStrings("line-list", variants[1].when[0]);
}

test "ManifestLoader: variant :when [] is invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name topo :underlying symbol
        \\    :members (member-set :values [a b]))
        \\  (form :name f :discriminant k
        \\    (key :name k :type topo :optional false)
        \\    (variant :when []
        \\      (key :name x :type number :optional true))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiag(r, .invalid_manifest, "`:when []`") != null);
    // Total: the variant still lands, selected by nothing.
    const variants = r.plugin.forms[0].variants orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), variants[0].when.len);
    try testing.expect(!variants[0].selects("a"));
}

test "ManifestLoader: variant :when listing one value twice is invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name topo :underlying symbol
        \\    :members (member-set :values [a b]))
        \\  (form :name f :discriminant k
        \\    (key :name k :type topo :optional false)
        \\    (variant :when [a b a]
        \\      (key :name x :type number :optional true))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiag(r, .invalid_manifest, "lists `a` twice") != null);
}

test "ManifestLoader: a value listed by two variants is invalid_manifest, once per value" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name topo :underlying symbol
        \\    :members (member-set :values [a b c d]))
        \\  (form :name f :discriminant k
        \\    (key :name k :type topo :optional false)
        \\    (variant :when [a b]
        \\      (key :name x :type number :optional true))
        \\    (variant :when [b c]
        \\      (key :name y :type number :optional true))
        \\    (variant :when b
        \\      (key :name z :type number :optional true))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    // `[b c]` repeats `b` from `[a b]`; the scalar `b` repeats it again.
    // Each later listing reports once, naming the earlier variant.
    try testing.expect(findDiag(r, .invalid_manifest, "variant `:when [b c]` lists `b`, already selected by variant `:when [a b]`") != null);
    try testing.expect(findDiag(r, .invalid_manifest, "variant `:when b` lists `b`, already selected by variant `:when [a b]`") != null);
    var count: usize = 0;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and std.mem.indexOf(u8, d.message, "already selected") != null) count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
    // The key-collision check is untouched: three distinct keys, no
    // `variant_key_collision`, and the manifest is otherwise whole.
    for (r.diagnostics) |d| try testing.expect(d.code != .variant_key_collision);
}

test "ManifestLoader: two variants with the same single :when is invalid_manifest" {
    // The pre-list gap: `:when a` twice used to load clean, with the second
    // variant dead (first match won). The disjointness rule catches it now.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name topo :underlying symbol
        \\    :members (member-set :values [a b]))
        \\  (form :name f :discriminant k
        \\    (key :name k :type topo :optional false)
        \\    (variant :when a
        \\      (key :name x :type number :optional true))
        \\    (variant :when a
        \\      (key :name y :type number :optional true))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(findDiag(r, .invalid_manifest, "variant `:when a` lists `a`, already selected by variant `:when a`") != null);
}

test "ManifestLoader: integer + exclusive-min round-trip" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name positive-int :underlying number
        \\    :numeric (numeric-bounds :min 0 :exclusive-min true :integer true)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const nb = r.plugin.value_kinds[0].numeric.?;
    try testing.expect(nb.exclusive_min);
    try testing.expect(nb.integer);
    try testing.expect(nb.max == null);
}

test "ManifestLoader: unit-bearing bound captures unit string" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name duration-ms :underlying number
        \\    :unit (unit-shape :required true :allowed [ms])
        \\    :numeric (numeric-bounds :min 0ms :max 10000ms)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const nb = r.plugin.value_kinds[0].numeric.?;
    try testing.expectEqualStrings("ms", nb.min.?.unit.?);
    try testing.expectEqualStrings("ms", nb.max.?.unit.?);
    try testing.expectEqual(@as(f64, 10000.0), nb.max.?.value);
}

test "ManifestLoader: :numeric on non-number underlying emits numeric_bounds_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying string
        \\    :numeric (numeric-bounds :min 0)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .numeric_bounds_invalid, "not `number`"));
}

test "ManifestLoader: :requires parses into the key's dependency list" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name entry
        \\    (key :name binding :type number :optional false)
        \\    (key :name buffer :type symbol :optional true)
        \\    (key :name offset :type number :optional true :requires [buffer])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const offset = r.plugin.forms[0].keys[2];
    try testing.expectEqualStrings("offset", offset.name);
    try testing.expectEqual(@as(usize, 1), offset.requires.len);
    try testing.expectEqualStrings("buffer", offset.requires[0]);
    // Absent `:requires` is an empty list, not null.
    try testing.expectEqual(@as(usize, 0), r.plugin.forms[0].keys[1].requires.len);
}

test "ManifestLoader: :requires may name a key declared later" {
    // The check is deferred to the end of `buildForm` precisely so
    // declaration order does not matter.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name entry
        \\    (key :name offset :type number :optional true :requires [buffer])
        \\    (key :name buffer :type symbol :optional true)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "ManifestLoader: a self-referencing :requires emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name entry
        \\    (key :name a :type number :optional true :requires [a])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .invalid_manifest, "requires itself"));
}

test "ManifestLoader: an unresolvable :requires emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name entry
        \\    (key :name a :type number :optional true :requires [nope])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .invalid_manifest, "does not declare"));
}

test "ManifestLoader: :requires naming an already-required key emits invalid_manifest" {
    // The dependency can never fire: the key is always present, or the
    // form already failed with missing_required_key.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name entry
        \\    (key :name a :type number :optional true :requires [b])
        \\    (key :name b :type symbol :optional false)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .invalid_manifest, "can never fire"));
}

test "ManifestLoader: :requires across one exclusive group emits invalid_manifest" {
    // The group says "at most one of these"; the dependency says "both".
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name entry
        \\    (key :name a :type number :optional true :requires [b])
        \\    (key :name b :type symbol :optional true)
        \\    (exclusive-group :cardinality at-most-one
        \\      (alt :keys [a])
        \\      (alt :keys [b]))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .invalid_manifest, "one exclusive group"));
}

test "ManifestLoader: a :requires cycle emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name entry
        \\    (key :name a :type number :optional true :requires [b])
        \\    (key :name b :type symbol :optional true :requires [a])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .invalid_manifest, "cycle"));
}

test "ManifestLoader: a three-key :requires cycle is caught" {
    // a -> b -> c -> a. A two-colour visited set would miss this; the
    // grey/black distinction is what makes the back edge detectable.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name entry
        \\    (key :name a :type number :optional true :requires [b])
        \\    (key :name b :type number :optional true :requires [c])
        \\    (key :name c :type number :optional true :requires [a])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .invalid_manifest, "cycle"));
}

test "ManifestLoader: a diamond :requires graph is not a cycle" {
    // a requires b and c; both require d. Every node is reachable twice,
    // which a naive "already visited means cycle" check would misreport.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name entry
        \\    (key :name a :type number :optional true :requires [b c])
        \\    (key :name b :type number :optional true :requires [d])
        \\    (key :name c :type number :optional true :requires [d])
        \\    (key :name d :type number :optional true)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "ManifestLoader: a variant key may :requires a base key" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name topo :underlying symbol
        \\    :members (member-set :values [strip list]))
        \\  (form :name primitive :discriminant topology
        \\    (key :name topology :type topo :optional false)
        \\    (key :name cull :type symbol :optional true)
        \\    (variant :when strip
        \\      (key :name index-format :type symbol :optional true :requires [cull]))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "ManifestLoader: a base key may NOT :requires a variant key" {
    // That dependency would be conditional on the discriminant, which is
    // what (variant …) is for. It reads as unresolvable from base scope.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name topo :underlying symbol
        \\    :members (member-set :values [strip list]))
        \\  (form :name primitive :discriminant topology
        \\    (key :name topology :type topo :optional false)
        \\    (key :name cull :type symbol :optional true :requires [index-format])
        \\    (variant :when strip
        \\      (key :name index-format :type symbol :optional true))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .invalid_manifest, "does not declare"));
}

test "ManifestLoader: :multiple-of parses into a Bound, unit and exact_int included" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name aligned :underlying number
        \\    :numeric (numeric-bounds :min 0 :integer true :multiple-of 256))
        \\  (value-kind :name aligned-bytes :underlying number
        \\    :unit (unit-shape :required true :allowed [b])
        \\    :numeric (numeric-bounds :multiple-of 256b)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());

    const plain = r.plugin.value_kinds[0].numeric.?.multiple_of orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(f64, 256), plain.value);
    try testing.expectEqual(@as(?[]const u8, null), plain.unit);
    // Reusing `loadBound` is what carries `exact_int` along, which is what
    // keeps the divisibility check in integer space.
    try testing.expect(plain.exact_int);

    const united = r.plugin.value_kinds[1].numeric.?.multiple_of orelse
        return error.TestUnexpectedResult;
    try testing.expectEqualStrings("b", united.unit.?);
}

test "ManifestLoader: :multiple-of 0 emits numeric_bounds_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying number
        \\    :numeric (numeric-bounds :multiple-of 0)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .numeric_bounds_invalid, "must be positive"));
}

test "ManifestLoader: a negative :multiple-of emits numeric_bounds_invalid" {
    // `-3` divides exactly what `3` divides, so accepting it bought nothing
    // — and it exported `"multipleOf": -3`, which JSON Schema 2020-12
    // forbids and ajv refuses to compile. The one arm covers both signs.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying number
        \\    :numeric (numeric-bounds :multiple-of -3)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .numeric_bounds_invalid, "must be positive"));
    try testing.expect(findDiagWithCode(r.diagnostics, .numeric_bounds_invalid, "-3"));
}

test "ManifestLoader: a fractional :multiple-of warns rather than erroring" {
    // `:multiple-of 0.5` is meaningful, just approximate — divisibility is
    // exact only in integer space. A warning steers the author to the exact
    // path without rejecting a schema that works.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name quarter :underlying number
        \\    :numeric (numeric-bounds :multiple-of 0.25)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    var found = false;
    for (r.diagnostics) |d| {
        if (d.code == .numeric_bounds_invalid and
            std.mem.indexOf(u8, d.message, "approximate") != null)
        {
            try testing.expectEqual(Ast.Diagnostic.Severity.warning, d.severity);
            found = true;
        }
    }
    try testing.expect(found);
    // The bound is still stored — a warning does not drop the constraint.
    try testing.expect(r.plugin.value_kinds[0].numeric.?.multiple_of != null);
}

test "ManifestLoader: an integral :multiple-of warns about nothing" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name aligned :underlying number
        \\    :numeric (numeric-bounds :multiple-of 4)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    for (r.diagnostics) |d| {
        try testing.expect(d.code != .numeric_bounds_invalid);
    }
}

test "ManifestLoader: :exclusive-min true without :min emits numeric_bounds_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying number
        \\    :numeric (numeric-bounds :exclusive-min true)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .numeric_bounds_invalid, "`:min` is absent"));
}

test "ManifestLoader: :exclusive-max true without :max emits numeric_bounds_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying number
        \\    :numeric (numeric-bounds :exclusive-max true)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .numeric_bounds_invalid, "`:max` is absent"));
}

test "ManifestLoader: :min > :max with shared unit emits numeric_bounds_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying number
        \\    :numeric (numeric-bounds :min 1 :max 0)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .numeric_bounds_invalid, "empty range"));
}

test "ManifestLoader: :min > :max with differing units does NOT emit (deferred)" {
    // Mixed-unit bound comparisons are deferred to validate time, where
    // they surface as `numeric_bound_unit_mismatch`. The loader has no
    // business unifying units it cannot canonicalise.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name odd :underlying number
        \\    :numeric (numeric-bounds :min 1s :max 500ms)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "ManifestLoader: empty (numeric-bounds) form parses with all-default bounds" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name unconstrained :underlying number
        \\    :numeric (numeric-bounds)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const nb = r.plugin.value_kinds[0].numeric.?;
    try testing.expect(nb.min == null);
    try testing.expect(nb.max == null);
    try testing.expect(!nb.exclusive_min);
    try testing.expect(!nb.exclusive_max);
    try testing.expect(!nb.integer);
}

test "ManifestLoader: :exclusive-min false with no :min is valid (default-shaped)" {
    // The exclusivity flags are only "invalid without bound" when set
    // to true. Explicit `false` is the default and must not trigger
    // `numeric_bounds_invalid`.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name x :underlying number
        \\    :numeric (numeric-bounds :exclusive-min false :exclusive-max false)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const nb = r.plugin.value_kinds[0].numeric.?;
    try testing.expect(!nb.exclusive_min);
    try testing.expect(!nb.exclusive_max);
}

test "ManifestLoader: :integer false explicit default round-trips" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name x :underlying number
        \\    :numeric (numeric-bounds :integer false)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expect(!r.plugin.value_kinds[0].numeric.?.integer);
}

test "ManifestLoader: :min == :max is a valid single-point range" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name exactly-one :underlying number
        \\    :numeric (numeric-bounds :min 1 :max 1)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const nb = r.plugin.value_kinds[0].numeric.?;
    try testing.expectEqual(@as(f64, 1.0), nb.min.?.value);
    try testing.expectEqual(@as(f64, 1.0), nb.max.?.value);
}

test "ManifestLoader: i64.min literal as :min round-trips exact_int" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name signed :underlying number
        \\    :numeric (numeric-bounds :min -9223372036854775808 :max 0)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const nb = r.plugin.value_kinds[0].numeric.?;
    try testing.expect(nb.min.?.exact_int);
    // i64.min rounds to -9.223372036854776e18 in f64; the flag flags
    // exactness of the literal, not of the f64 storage.
    try testing.expectEqual(@as(f64, @floatFromInt(std.math.minInt(i64))), nb.min.?.value);
}

test "ManifestLoader: u64-range literal beyond i64.max as :max keeps exact_int" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name big :underlying number
        \\    :numeric (numeric-bounds :max 18446744073709551615)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expect(r.plugin.value_kinds[0].numeric.?.max.?.exact_int);
}

test "ManifestLoader: fractional bound literal sets exact_int = false" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name x :underlying number
        \\    :numeric (numeric-bounds :min 0.5 :max 1.5)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const nb = r.plugin.value_kinds[0].numeric.?;
    try testing.expect(!nb.min.?.exact_int);
    try testing.expect(!nb.max.?.exact_int);
}

test "ManifestLoader: scientific-notation bound literal lands as exact_int=false" {
    // `1e2` parses as Tag.number (f64-only), not Tag.number_i64 — the
    // exponent path bypasses the exact-int classifier even when the
    // mathematical value is whole.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name x :underlying number
        \\    :numeric (numeric-bounds :max 1e2)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const nb = r.plugin.value_kinds[0].numeric.?;
    try testing.expectEqual(@as(f64, 100.0), nb.max.?.value);
    try testing.expect(!nb.max.?.exact_int);
}

test "ManifestLoader: :numeric on vector-underlying emits numeric_bounds_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name v :underlying vector
        \\    :vector (vector-shape :element number)
        \\    :numeric (numeric-bounds :min 0)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .numeric_bounds_invalid, "not `number`"));
}

test "ManifestLoader: :numeric on form-underlying emits numeric_bounds_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name fk :underlying form
        \\    :numeric (numeric-bounds :max 10)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .numeric_bounds_invalid, "not `number`"));
}

test "ManifestLoader: equal bounds with shared unit are NOT flagged as empty range" {
    // Equal bounds form a closed single-point range, which is legal even
    // when both carry the same unit. The loader's empty-range check fires
    // only on a strict `min > max`.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name pin :underlying number
        \\    :unit (unit-shape :required true :allowed [ms])
        \\    :numeric (numeric-bounds :min 500ms :max 500ms)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "ManifestLoader: both exclusivity flags without bounds emit two diagnostics" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying number
        \\    :numeric (numeric-bounds :exclusive-min true :exclusive-max true)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .numeric_bounds_invalid, "`:min` is absent"));
    try testing.expect(findDiagWithCode(r.diagnostics, .numeric_bounds_invalid, "`:max` is absent"));
}

test "ManifestLoader: two value-kinds with bounds load independently" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name a :underlying number
        \\    :numeric (numeric-bounds :min 0 :max 1))
        \\  (value-kind :name b :underlying number
        \\    :numeric (numeric-bounds :integer true)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 2), r.plugin.value_kinds.len);
    try testing.expect(r.plugin.value_kinds[0].numeric.?.max != null);
    try testing.expect(r.plugin.value_kinds[1].numeric.?.integer);
    try testing.expect(r.plugin.value_kinds[1].numeric.?.min == null);
}

test "ManifestLoader: kind with both :unit and :numeric round-trips both refinements" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name dur :underlying number
        \\    :unit (unit-shape :required true :allowed [ms])
        \\    :numeric (numeric-bounds :min 0ms :max 1000ms :exclusive-max true)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const vk = r.plugin.value_kinds[0];
    try testing.expect(vk.unit != null);
    try testing.expect(vk.unit.?.required);
    const nb = vk.numeric.?;
    try testing.expect(nb.exclusive_max);
    try testing.expectEqualStrings("ms", nb.min.?.unit.?);
    try testing.expectEqualStrings("ms", nb.max.?.unit.?);
}

test "ManifestLoader: :min == :max but :exclusive-min true is NOT load-time flagged (deferred)" {
    // The loader's empty-range gate is `min.value > max.value` (strict).
    // `min == max` with `:exclusive-min true` is logically empty but the
    // loader doesn't try to interpret exclusivity at load time — the
    // validator surfaces the failure on the first value that hits it.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name impossible :underlying number
        \\    :numeric (numeric-bounds :min 5 :max 5 :exclusive-min true)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

// ----- String-bounds manifest-load tests -----------------------------------

test "ManifestLoader: (string-bounds …) round-trips into ValueKind.string_bounds" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name slug :underlying string
        \\    :string-bounds (string-bounds :min-len 1 :max-len 64)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const sb = r.plugin.value_kinds[0].string_bounds orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1), sb.min_len.?);
    try testing.expectEqual(@as(u32, 64), sb.max_len.?);
    try testing.expect(sb.pattern == null);
    try testing.expect(sb.format == null);
}

test "ManifestLoader: :pattern and :format round-trip" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name email-address :underlying string
        \\    :string-bounds (string-bounds :pattern "^[^@]+@[^@]+$" :format email)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const sb = r.plugin.value_kinds[0].string_bounds.?;
    try testing.expectEqualStrings("^[^@]+@[^@]+$", sb.pattern.?);
    try testing.expectEqual(Plugin.ValueKind.StringBounds.Format.email, sb.format.?);
}

test "ManifestLoader: :string-bounds on non-string underlying emits string_bounds_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying number
        \\    :string-bounds (string-bounds :min-len 1)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var saw: bool = false;
    for (r.diagnostics) |d| if (d.code == .string_bounds_invalid) {
        saw = true;
        break;
    };
    try testing.expect(saw);
    try testing.expect(findDiagWithCode(r.diagnostics, .string_bounds_invalid, "not `string`"));
}

test "ManifestLoader: negative :min-len emits string_bounds_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying string
        \\    :string-bounds (string-bounds :min-len -1)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .string_bounds_invalid, "negative :min-len"));
}

test "ManifestLoader: negative :max-len emits string_bounds_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying string
        \\    :string-bounds (string-bounds :max-len -3)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .string_bounds_invalid, "negative :max-len"));
}

test "ManifestLoader: :min-len > :max-len emits empty-range string_bounds_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying string
        \\    :string-bounds (string-bounds :min-len 5 :max-len 3)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .string_bounds_invalid, "empty range"));
}

test "ManifestLoader: empty :pattern emits string_bounds_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying string
        \\    :string-bounds (string-bounds :pattern "")))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .string_bounds_invalid, "empty string"));
}

test "ManifestLoader: member shorter than :min-len emits string_bounds_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying string
        \\    :members (member-set :values [ab cd])
        \\    :string-bounds (string-bounds :min-len 3)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .string_bounds_invalid, "< :min-len"));
}

test "ManifestLoader: member failing :format emits string_bounds_invalid" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name bad :underlying string
        \\    :members (member-set :values [nope])
        \\    :string-bounds (string-bounds :format email)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    try testing.expect(findDiagWithCode(r.diagnostics, .string_bounds_invalid, "does not satisfy :format"));
}

test "ManifestLoader: empty (string-bounds) form parses with all-default bounds" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name unconstrained :underlying string
        \\    :string-bounds (string-bounds)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const sb = r.plugin.value_kinds[0].string_bounds.?;
    try testing.expect(sb.min_len == null);
    try testing.expect(sb.max_len == null);
    try testing.expect(sb.pattern == null);
    try testing.expect(sb.format == null);
}

test "ManifestLoader: :min-len == :max-len is a valid single-point range" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (value-kind :name code :underlying string
        \\    :string-bounds (string-bounds :min-len 4 :max-len 4)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
}

test "ManifestLoader: multi-key bundle key reused in same group emits exclusive_bundle_collision" {
    // `:from` appears in both `(alt :keys [from to])` and
    // `(alt :keys [from at])` — same group, distinct alts. The
    // in-group bundle-collision check fires before the cross-group
    // tracker registers anything, so `exclusive_group_invalid` is
    // not emitted for the same occurrence.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name routes :version "1.0.0"
        \\  (form :name route
        \\    (key :name from :type symbol :optional true)
        \\    (key :name to :type symbol :optional true)
        \\    (key :name at :type symbol :optional true)
        \\    (exclusive-group :cardinality exactly-one
        \\      (alt :keys [from to])
        \\      (alt :keys [from at]))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var saw_collision = false;
    for (r.diagnostics) |d| {
        if (d.code == .exclusive_bundle_collision) {
            saw_collision = true;
            try testing.expect(std.mem.indexOf(u8, d.message, "from") != null);
        }
    }
    try testing.expect(saw_collision);
}

test "ManifestLoader: same key in two different groups still emits exclusive_group_invalid" {
    // Cross-group reuse keeps the old code — only in-group bundle
    // collisions get the new `exclusive_bundle_collision`.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name routes :version "1.0.0"
        \\  (form :name route
        \\    (key :name from :type symbol :optional true)
        \\    (key :name to :type symbol :optional true)
        \\    (key :name at :type symbol :optional true)
        \\    (key :name when :type symbol :optional true)
        \\    (exclusive-group :cardinality exactly-one
        \\      (alt :keys [from])
        \\      (alt :keys [to]))
        \\    (exclusive-group :cardinality at-most-one
        \\      (alt :keys [from])
        \\      (alt :keys [when]))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var saw_group_invalid = false;
    var saw_bundle_collision = false;
    for (r.diagnostics) |d| {
        if (d.code == .exclusive_group_invalid) saw_group_invalid = true;
        if (d.code == .exclusive_bundle_collision) saw_bundle_collision = true;
    }
    try testing.expect(saw_group_invalid);
    try testing.expect(!saw_bundle_collision);
}

// ---------------------------------------------------------------------------
// v1.1 packaging-metadata tests (Slice 2 of the local-packaging plan).
// ---------------------------------------------------------------------------

test "ManifestLoader: accepts :wasm-file" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name x :version "1.0.0" :wasm-file "plugin.wasm")
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqualStrings("plugin.wasm", r.plugin.wasm_file.?);
}

test "ManifestLoader: accepts :wasm-sha256 (well-formed)" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name x :version "1.0.0" :wasm-sha256 "sha256-0000000000000000000000000000000000000000000000000000000000000000")
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expect(r.plugin.wasm_sha256 != null);
}

test "ManifestLoader: accepts :authors as vector of strings" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name x :version "1.0.0" :authors ["Ada" "Babbage"])
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 2), r.plugin.authors.len);
}

test "ManifestLoader: accepts :license, :homepage, :repository, :keywords" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name x :version "1.0.0"
        \\  :license "CC0-1.0"
        \\  :homepage "https://example.com"
        \\  :repository "https://github.com/x/y"
        \\  :keywords [graphics two-d shapes])
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqualStrings("CC0-1.0", r.plugin.license);
    try testing.expectEqual(@as(usize, 3), r.plugin.keywords.len);
}

test "ManifestLoader: :version is optional — a manifest without one loads, unversioned" {
    // The key used to be required, which gave every scratch manifest a
    // fake "1.0.0". It is the pin target and the lockfile row, nothing
    // else, so a manifest that has no version to declare declares none:
    // `plugin.version` is empty and every consumer treats that as
    // unversioned (the CLI prints `?`, a `(use-plugin … :version …)` pin
    // against it is `plugin_version_mismatch` — see Host_tests).
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name x
        \\  (form :name f (key :name n :type number)))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqualStrings("x", r.plugin.name);
    try testing.expectEqualStrings("", r.plugin.version);
    try testing.expectEqual(@as(usize, 1), r.plugin.forms.len);
}

test "ManifestLoader: plugin_wasm_self_hash_malformed on bad :wasm-sha256" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name x :version "1.0.0"
        \\  :wasm-sha256 "not-a-hash")
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var saw = false;
    for (r.diagnostics) |d| {
        if (d.code == .plugin_wasm_self_hash_malformed) saw = true;
    }
    try testing.expect(saw);
}

test "ManifestLoader: license_unrecognized advisory on non-SPDX :license" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name x :version "1.0.0" :license "WTFPL")
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors()); // advisory only
    var saw = false;
    for (r.diagnostics) |d| {
        if (d.code == .license_unrecognized) saw = true;
    }
    try testing.expect(saw);
}

test "ManifestLoader: too_many_keywords advisory above MAX_KEYWORDS" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name x :version "1.0.0"
        \\  :keywords [a b c d e f g h i j k l m n o p q r])
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    var saw = false;
    for (r.diagnostics) |d| {
        if (d.code == .too_many_keywords) saw = true;
    }
    try testing.expect(saw);
}

test "ManifestLoader: a manifest has no format version of its own (sjon_format_unsupported retired)" {
    // TOMBSTONE for `sjon_format_unsupported`. Manifests once declared
    // `:sjon "<major>.<minor>"` and a host refused any declaration above
    // its `SUPPORTED_SJON_FORMAT`. The key never enabled anything on the
    // host reading it — every feature was on regardless — so it was
    // retired: the vocabulary has one version, the SJON release. A manifest
    // newer than its host still fails loudly, through the meta-schema
    // (`(plugin …)` is `:open false`): the retired key is now just an
    // unknown key. The wire-stable code variant is kept (never renumbered)
    // but no longer emitted; this test references it so `audit-diagnostics`
    // stays green and documents the retirement.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name x :version "1.0.0" :sjon "99.0")
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var saw_unknown_key = false;
    for (r.diagnostics) |d| {
        try testing.expect(d.code != .sjon_format_unsupported);
        if (d.code == .unknown_key) saw_unknown_key = true;
    }
    try testing.expect(saw_unknown_key);
}

// ---------------------------------------------------------------------------
// Slot-local forms (KeySpec.local_forms). These go through `load` (not
// `loadUnchecked`) so each also exercises the meta-schema gate: a forgotten
// `gen-meta-schema --regen` would reject the inline `(form …)` as
// `positional_not_allowed` and these would fail.
// ---------------------------------------------------------------------------

test "ManifestLoader: inline slot-local forms round-trip onto KeySpec.local_forms" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name ui :version "1.0.0"
        \\  (form :name canvas
        \\    (key :name shape :type form
        \\      (form :name circle (key :name r :type number :optional false))
        \\      (form :name rect
        \\        (key :name w :type number :optional false)
        \\        (key :name h :type number :optional false)))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 1), r.plugin.forms.len);
    const canvas = r.plugin.forms[0];
    try testing.expectEqualStrings("canvas", canvas.name);
    try testing.expectEqual(@as(usize, 1), canvas.keys.len);
    const shape = canvas.keys[0];
    try testing.expectEqualStrings("shape", shape.name);
    try testing.expectEqual(Plugin.ValueType.form, shape.value_type);
    try testing.expectEqual(@as(usize, 2), shape.local_forms.len);
    try testing.expectEqualStrings("circle", shape.local_forms[0].name);
    try testing.expectEqual(@as(usize, 1), shape.local_forms[0].keys.len);
    try testing.expectEqualStrings("r", shape.local_forms[0].keys[0].name);
    try testing.expect(!shape.local_forms[0].keys[0].optional);
    try testing.expectEqualStrings("rect", shape.local_forms[1].name);
    try testing.expectEqual(@as(usize, 2), shape.local_forms[1].keys.len);
}

test "ManifestLoader: discriminated slot-local form resolves its discriminant + variant" {
    // Exercises that buildForm fully recurses on a local form: discriminant
    // index resolution and variant key sets are wired the same as a global.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name ui :version "1.0.0"
        \\  (form :name canvas
        \\    (key :name shape :type form
        \\      (form :name poly :discriminant kind
        \\        (key :name kind :type symbol :optional false)
        \\        (variant :when tri (key :name a :type number :optional false))))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const poly = r.plugin.forms[0].keys[0].local_forms[0];
    try testing.expectEqualStrings("poly", poly.name);
    try testing.expectEqual(@as(?u8, 0), poly.discriminant_idx);
    const variants = poly.variants orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), variants.len);
    try testing.expectEqual(@as(usize, 1), variants[0].when.len);
    try testing.expectEqualStrings("tri", variants[0].when[0]);
}

test "ManifestLoader: slot-local forms on a non-form slot emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name ui :version "1.0.0"
        \\  (form :name canvas
        \\    (key :name count :type number
        \\      (form :name circle (key :name r :type number :optional false)))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "inline slot-local form") != null and
            std.mem.indexOf(u8, d.message, "not `form`") != null) found = true;
    }
    try testing.expect(found);
}

test "ManifestLoader: duplicate slot-local form name emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name ui :version "1.0.0"
        \\  (form :name canvas
        \\    (key :name shape :type form
        \\      (form :name circle (key :name r :type number :optional false))
        \\      (form :name circle (key :name r :type number :optional false)))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "duplicate slot-local form") != null) found = true;
    }
    try testing.expect(found);
}

/// Generate a manifest whose deepest slot-local form sits at form-depth `d`
/// (top-level form is depth 1; each inline local adds one). Used to drive the
/// `MAX_LOCAL_FORM_DEPTH` boundary.
fn buildNestedLocalSource(a: Allocator, d: usize) ![:0]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "(plugin :name p :version \"1.0.0\"\n  ");
    for (0..d) |i| {
        var num_buf: [16]u8 = undefined;
        const num = try std.fmt.bufPrint(&num_buf, "{d}", .{i});
        if (i < d - 1) {
            try buf.appendSlice(a, "(form :name f");
            try buf.appendSlice(a, num);
            try buf.appendSlice(a, " (key :name k :type form ");
        } else {
            try buf.appendSlice(a, "(form :name f");
            try buf.appendSlice(a, num);
            try buf.appendSlice(a, ")");
        }
    }
    // Each of the d-1 outer levels opened a `(form` and a `(key` — close both.
    for (0..d - 1) |_| try buf.appendSlice(a, "))");
    try buf.appendSlice(a, ")"); // close (plugin
    const z = try a.allocSentinel(u8, buf.items.len, 0);
    @memcpy(z, buf.items);
    return z;
}

test "ManifestLoader: slot-local forms at MAX_LOCAL_FORM_DEPTH load clean" {
    const a = testing.allocator;
    const src = try buildNestedLocalSource(a, Plugin.MAX_LOCAL_FORM_DEPTH);
    defer a.free(src);
    var tree = try parseSource(a, src);
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 1), r.plugin.forms.len);
    // Top form carries exactly one local; the chain descends from there.
    try testing.expectEqual(@as(usize, 1), r.plugin.forms[0].keys[0].local_forms.len);
}

test "ManifestLoader: slot-local form past MAX_LOCAL_FORM_DEPTH emits invalid_manifest" {
    const a = testing.allocator;
    const src = try buildNestedLocalSource(a, Plugin.MAX_LOCAL_FORM_DEPTH + 1);
    defer a.free(src);
    var tree = try parseSource(a, src);
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "MAX_LOCAL_FORM_DEPTH") != null) found = true;
    }
    try testing.expect(found);
}

// ---------------------------------------------------------------------------
// Positional slot-local forms (FormSpec.local_forms). Inline `(form …)`
// children directly under a `(form …)` — the positional mirror of the keyed
// slot-locals above. Also `load` (not `loadUnchecked`), so each exercises the
// meta-schema gate: without the `form-child-decl` grammar (commit 7) a nested
// `(form …)` would meta-reject as not_head_member and these would fail.
// ---------------------------------------------------------------------------

test "ManifestLoader: inline positional-local forms round-trip onto FormSpec.local_forms" {
    // The closed-positional-set recipe: a head-set `:positional` names the local
    // heads, and matching `(form …)` children supply the definitions.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name ui :version "1.0.0"
        \\  (value-kind :name shape-form :underlying form :heads (head-set :names [circle rect]))
        \\  (form :name canvas
        \\    :positional shape-form
        \\    (form :name circle (key :name r :type number :optional false))
        \\    (form :name rect
        \\      (key :name w :type number :optional false)
        \\      (key :name h :type number :optional false))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 1), r.plugin.forms.len);
    const canvas = r.plugin.forms[0];
    try testing.expectEqualStrings("canvas", canvas.name);
    // The declared head-set positional is preserved (not overwritten by the
    // implied-`.any` rule, which only fires when `:positional` is absent).
    switch (canvas.positional) {
        .kind => |ref| try testing.expectEqualStrings("shape-form", ref.name),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 2), canvas.local_forms.len);
    try testing.expectEqualStrings("circle", canvas.local_forms[0].name);
    try testing.expectEqual(@as(usize, 1), canvas.local_forms[0].keys.len);
    try testing.expectEqualStrings("r", canvas.local_forms[0].keys[0].name);
    try testing.expectEqualStrings("rect", canvas.local_forms[1].name);
    try testing.expectEqual(@as(usize, 2), canvas.local_forms[1].keys.len);
}

test "ManifestLoader: positional-local forms with no :positional imply .any" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name ui :version "1.0.0"
        \\  (form :name canvas
        \\    (form :name circle (key :name r :type number :optional false))
        \\    (form :name rect (key :name w :type number :optional false))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    const canvas = r.plugin.forms[0];
    // No `:positional` declared, but locals are present → implied `.any` so the
    // locals aren't dead behind positional_not_allowed.
    try testing.expectEqual(Plugin.PositionalSpec.any, canvas.positional);
    try testing.expectEqual(@as(usize, 2), canvas.local_forms.len);
    try testing.expectEqualStrings("circle", canvas.local_forms[0].name);
    try testing.expectEqualStrings("rect", canvas.local_forms[1].name);
}

test "ManifestLoader: duplicate positional-local form name emits invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name ui :version "1.0.0"
        \\  (form :name canvas
        \\    (form :name circle (key :name r :type number :optional false))
        \\    (form :name circle (key :name r :type number :optional false))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "duplicate positional-local form") != null) found = true;
    }
    try testing.expect(found);
}

test "ManifestLoader: positional-local forms alongside a (flag-set …) emit invalid_manifest" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name ui :version "1.0.0"
        \\  (form :name canvas
        \\    :positional (flag-set (flag :name done))
        \\    (form :name circle (key :name r :type number :optional false))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "flag-set") != null and
            std.mem.indexOf(u8, d.message, "positional-local") != null) found = true;
    }
    try testing.expect(found);
}

test "ManifestLoader: :lowering on a positional slot-local form emits invalid_manifest and stays null" {
    // A slot-local form cannot lower — nothing downstream would honour it
    // (`Schema.validateLowering` and the graph walk top-level forms; the
    // worklist resolves a local head to its local body). Rejected at load,
    // and the local's spec keeps `lowering == null` so the invariant holds
    // even in the partial result. The top-level sugar beside it loads.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name bind-group
        \\    (form :name entry
        \\      :lowering (lowering :hook p/entry-v1 :produces [entry-normal])))
        \\  (form :name entry-normal :open true)
        \\  (form :name init
        \\    :lowering (lowering :hook p/init-v1 :produces [bind-group entry])))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "slot-local form `entry` declares `:lowering`") != null)
        {
            found = true;
            try testing.expectEqual(@as(usize, 2), d.path.len);
            try testing.expectEqualStrings("entry", d.path[0]);
            try testing.expectEqualStrings("lowering", d.path[1]);
        }
    }
    try testing.expect(found);
    // Partial load: the local carries no lowering; the top-level sugar does.
    const bg = r.plugin.forms[0];
    try testing.expectEqualStrings("bind-group", bg.name);
    try testing.expect(bg.local_forms[0].lowering == null);
    try testing.expect(r.plugin.forms[2].lowering != null);
}

test "ManifestLoader: :lowering on a keyed slot-local form emits invalid_manifest" {
    // The keyed carrier (`KeySpec.local_forms`) takes the same rejection —
    // the depth the guard keys on is form nesting, whichever carrier nests.
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name p :version "1.0.0"
        \\  (form :name pipeline
        \\    (key :name layout :type form
        \\      (form :name layout
        \\        :lowering (lowering :hook p/layout-v1 :produces [pipeline])))))
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "slot-local form `layout` declares `:lowering`") != null) found = true;
    }
    try testing.expect(found);
    try testing.expect(r.plugin.forms[0].keys[0].local_forms[0].lowering == null);
}

/// Generate a manifest whose deepest POSITIONAL slot-local form sits at
/// form-depth `d` (top-level form is depth 1; each inline positional local
/// adds one). The positional mirror of `buildNestedLocalSource` — nests
/// `(form …)` directly under `(form …)` with no `(key …)` carrier.
fn buildNestedPositionalLocalSource(a: Allocator, d: usize) ![:0]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "(plugin :name p :version \"1.0.0\"\n  ");
    for (0..d) |i| {
        var num_buf: [16]u8 = undefined;
        const num = try std.fmt.bufPrint(&num_buf, "{d}", .{i});
        try buf.appendSlice(a, "(form :name f");
        try buf.appendSlice(a, num);
        try buf.appendSlice(a, " ");
    }
    for (0..d) |_| try buf.appendSlice(a, ")"); // close the d forms
    try buf.appendSlice(a, ")"); // close (plugin
    const z = try a.allocSentinel(u8, buf.items.len, 0);
    @memcpy(z, buf.items);
    return z;
}

test "ManifestLoader: positional-local forms at MAX_LOCAL_FORM_DEPTH load clean" {
    const a = testing.allocator;
    const src = try buildNestedPositionalLocalSource(a, Plugin.MAX_LOCAL_FORM_DEPTH);
    defer a.free(src);
    var tree = try parseSource(a, src);
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 1), r.plugin.forms.len);
    // Top form carries exactly one positional local; the chain descends.
    try testing.expectEqual(@as(usize, 1), r.plugin.forms[0].local_forms.len);
}

test "ManifestLoader: positional-local form past MAX_LOCAL_FORM_DEPTH emits invalid_manifest" {
    const a = testing.allocator;
    const src = try buildNestedPositionalLocalSource(a, Plugin.MAX_LOCAL_FORM_DEPTH + 1);
    defer a.free(src);
    var tree = try parseSource(a, src);
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "MAX_LOCAL_FORM_DEPTH") != null) found = true;
    }
    try testing.expect(found);
}

/// Generate a manifest whose single top-level form nests a positional local of
/// **its own name** `d` levels deep — the container-holds-its-own-head shape
/// (ask 22). Distinct from `buildNestedPositionalLocalSource`, which renames
/// every level: the duplicate-local check is per sibling set, so repeating one
/// name down a chain is legal and the only limit is the depth cap.
fn buildSelfNestedLocalSource(a: Allocator, d: usize) ![:0]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "(plugin :name p :version \"1.0.0\"\n  ");
    for (0..d) |_| try buf.appendSlice(a, "(form :name space ");
    for (0..d) |_| try buf.appendSlice(a, ")");
    try buf.appendSlice(a, ")"); // close (plugin
    const z = try a.allocSentinel(u8, buf.items.len, 0);
    @memcpy(z, buf.items);
    return z;
}

test "ManifestLoader: a form nesting its own head at MAX_LOCAL_FORM_DEPTH loads clean" {
    const a = testing.allocator;
    const src = try buildSelfNestedLocalSource(a, Plugin.MAX_LOCAL_FORM_DEPTH);
    defer a.free(src);
    var tree = try parseSource(a, src);
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqual(@as(usize, 1), r.plugin.forms.len);
    try testing.expectEqualStrings("space", r.plugin.forms[0].name);
    // The local shadowing the global carries the same name, one level down.
    try testing.expectEqual(@as(usize, 1), r.plugin.forms[0].local_forms.len);
    try testing.expectEqualStrings("space", r.plugin.forms[0].local_forms[0].name);
}

test "ManifestLoader: a form nesting its own head past MAX_LOCAL_FORM_DEPTH emits invalid_manifest" {
    const a = testing.allocator;
    const src = try buildSelfNestedLocalSource(a, Plugin.MAX_LOCAL_FORM_DEPTH + 1);
    defer a.free(src);
    var tree = try parseSource(a, src);
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var found: bool = false;
    for (r.diagnostics) |d| {
        if (d.code == .invalid_manifest and
            std.mem.indexOf(u8, d.message, "MAX_LOCAL_FORM_DEPTH") != null) found = true;
    }
    try testing.expect(found);
}
