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
    try testing.expectEqualStrings("phrase", cr.target_form);
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
    try testing.expectEqualStrings("shader", cr.target_form);
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

test "ManifestLoader: accepts :license, :homepage, :repository, :keywords, :sjon" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name x :version "1.0.0"
        \\  :license "CC0-1.0"
        \\  :homepage "https://example.com"
        \\  :repository "https://github.com/x/y"
        \\  :keywords [graphics two-d shapes]
        \\  :sjon "1.0")
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(!r.hasErrors());
    try testing.expectEqualStrings("CC0-1.0", r.plugin.license);
    try testing.expectEqualStrings("1.0", r.plugin.sjon_format);
    try testing.expectEqual(@as(usize, 3), r.plugin.keywords.len);
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

test "ManifestLoader: sjon_format_unsupported when declared version > supported" {
    const a = testing.allocator;
    var tree = try parseSource(a,
        \\(plugin :name x :version "1.0.0" :sjon "99.0")
    );
    defer tree.deinit();
    var r = try load(a, tree);
    defer r.deinit();
    try testing.expect(r.hasErrors());
    var saw = false;
    for (r.diagnostics) |d| {
        if (d.code == .sjon_format_unsupported) saw = true;
    }
    try testing.expect(saw);
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
    try testing.expectEqualStrings("tri", variants[0].when);
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
