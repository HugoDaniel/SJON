//! Host unit tests.
//!
//! D0 fixed the contract types and four diagnostic codes; D1 wires
//! `Host.validateDocument` against an inline-manifest source. The D0
//! constructibility tests stay so the audit script keeps registering
//! coverage on the manifest-load / resolution codes whose first real
//! emission paths are still gated on D2/D3.

const std = @import("std");
const build_options = @import("build_options");
const sjon = @import("root.zig");
const Ast = sjon.Ast;
const Host = sjon.Host;
const Lowering = sjon.Lowering;
const Lowering_test_hooks = sjon.Lowering_test_hooks;
const Expr = sjon.Expr;
const Resolver = sjon.Resolver;

fn diagWith(code: Ast.Diagnostic.Code) Ast.Diagnostic {
    return .{
        .code = code,
        .span = .{ .start = 0, .end = 0 },
        .severity = .err,
        .message = "stub",
        .path = &.{},
    };
}

test "D0: invalid_manifest code is constructible" {
    const d = diagWith(.invalid_manifest);
    try std.testing.expectEqual(Ast.Diagnostic.Code.invalid_manifest, d.code);
}

test "D0: unresolved_plugin code is constructible" {
    const d = diagWith(.unresolved_plugin);
    try std.testing.expectEqual(Ast.Diagnostic.Code.unresolved_plugin, d.code);
}

test "D0: plugin_version_mismatch code is constructible" {
    const d = diagWith(.plugin_version_mismatch);
    try std.testing.expectEqual(Ast.Diagnostic.Code.plugin_version_mismatch, d.code);
}

test "D0: plugin_hash_mismatch code is constructible" {
    const d = diagWith(.plugin_hash_mismatch);
    try std.testing.expectEqual(Ast.Diagnostic.Code.plugin_hash_mismatch, d.code);
}

test "D0: HostOptions defaults are sane" {
    const opts: Host.HostOptions = .{};
    try std.testing.expectEqual(Host.FailurePolicy.lenient, opts.failure_policy);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.project_root);
    try std.testing.expectEqual(@as(usize, 0), opts.plugin_search_roots.len);
    try std.testing.expect(opts.resolver == null);
}

test "D0: Resolver.Resolution variants are constructible" {
    const decl_only: Resolver.Resolution = .{ .manifest = .{ .source = "stub" } };
    const with_wasm: Resolver.Resolution = .{ .manifest = .{ .source = "stub", .wasm = &.{} } };
    const failure: Resolver.Resolution = .{
        .failure = .{ .code = .unresolved_plugin, .detail = "stub" },
    };
    try std.testing.expect(decl_only == .manifest);
    try std.testing.expect(decl_only.manifest.wasm == null);
    try std.testing.expect(with_wasm == .manifest);
    try std.testing.expect(with_wasm.manifest.wasm != null);
    try std.testing.expect(failure == .failure);
}

// ---------------------------------------------------------------------------
// D1: Host.validateDocument coverage.
// ---------------------------------------------------------------------------

const SRC_CLEAN_INLINE =
    \\(plugin :name probe :version "1.0.0"
    \\  (form :name widget
    \\    (key :name name :type symbol :optional false)
    \\    (key :name size :type number :optional true)))
    \\
    \\(widget :name w0 :size 4)
    \\
;

test "D1: clean inline document yields zero diagnostics" {
    const a = std.testing.allocator;
    var r = try Host.validateDocument(a, SRC_CLEAN_INLINE, .{});
    defer r.deinit();

    try std.testing.expect(!r.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), r.declarations.len);
    try std.testing.expectEqual(@as(usize, 1), r.data_forest.len);
    try std.testing.expectEqual(@as(usize, 0), r.references.len);
    try std.testing.expectEqual(@as(usize, 1), r.plugins.len);
    try std.testing.expectEqualStrings("probe", r.plugins[0].name);
    try std.testing.expectEqual(@as(usize, 1), r.schema.plugins.len);
    try std.testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}

test "D1: data only without declarations emits unknown_form per data form" {
    const a = std.testing.allocator;
    const src: [:0]const u8 = "(widget :name w0)\n";
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 0), r.declarations.len);
    try std.testing.expectEqual(@as(usize, 1), r.data_forest.len);
    try std.testing.expectEqual(@as(usize, 0), r.plugins.len);
    try std.testing.expect(r.hasErrors());

    var unknown_form_count: usize = 0;
    for (r.diagnostics) |d| {
        try std.testing.expectEqual(Host.Phase.validation, d.phase);
        if (d.code == .unknown_form) unknown_form_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), unknown_form_count);
}

test "D1: declaration only with no data forest yields zero diagnostics" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\(plugin :name solo :version "1.0.0"
        \\  (form :name w (key :name name :type symbol :optional false)))
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.declarations.len);
    try std.testing.expectEqual(@as(usize, 0), r.data_forest.len);
    try std.testing.expectEqual(@as(usize, 1), r.plugins.len);
    try std.testing.expectEqual(@as(usize, 0), r.diagnostics.len);
    try std.testing.expect(!r.hasErrors());
}

test "D1: invalid declaration emits manifest-phase diagnostics with declaration_span" {
    const a = std.testing.allocator;
    // Missing required `:name` on the plugin form — meta-validator
    // emits `missing_required_key` against the plugin declaration.
    const src: [:0]const u8 =
        \\(plugin :version "1.0.0"
        \\  (form :name w (key :name name :type symbol :optional false)))
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.declarations.len);
    // Broken declaration must NOT contribute to plugins/schema.
    try std.testing.expectEqual(@as(usize, 0), r.plugins.len);
    try std.testing.expect(r.hasErrors());

    var manifest_errs: usize = 0;
    for (r.diagnostics) |d| {
        if (d.severity != .err) continue;
        if (d.phase != .manifest) continue;
        try std.testing.expect(d.declaration_span != null);
        try std.testing.expectEqual(d.code, .missing_required_key);
        manifest_errs += 1;
    }
    try std.testing.expect(manifest_errs >= 1);
}

test "D1: declaration plus data error yields a single validation-phase diagnostic" {
    const a = std.testing.allocator;
    // `widget` requires `:name`; data form omits it.
    const src: [:0]const u8 =
        \\(plugin :name probe :version "1.0.0"
        \\  (form :name widget
        \\    (key :name name :type symbol :optional false)))
        \\
        \\(widget)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.plugins.len);
    var validation_errs: usize = 0;
    for (r.diagnostics) |d| {
        if (d.severity != .err) continue;
        try std.testing.expectEqual(Host.Phase.validation, d.phase);
        try std.testing.expectEqual(Ast.Diagnostic.Code.missing_required_key, d.code);
        validation_errs += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), validation_errs);
}

test "D1: two declarations — one good, one bad" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\(plugin :name good :version "1.0.0"
        \\  (form :name widget
        \\    (key :name name :type symbol :optional false)))
        \\
        \\(plugin :version "1.0.0"
        \\  (form :name other (key :name name :type symbol :optional false)))
        \\
        \\(widget :name w0)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    // Good plugin loads; bad plugin's diagnostics arrive in manifest phase.
    try std.testing.expectEqual(@as(usize, 2), r.declarations.len);
    try std.testing.expectEqual(@as(usize, 1), r.plugins.len);
    try std.testing.expectEqualStrings("good", r.plugins[0].name);

    var has_manifest_err = false;
    var validation_err_count: usize = 0;
    for (r.diagnostics) |d| {
        if (d.severity != .err) continue;
        switch (d.phase) {
            .manifest => has_manifest_err = true,
            .validation => validation_err_count += 1,
            else => {},
        }
    }
    try std.testing.expect(has_manifest_err);
    // Data form `(widget :name w0)` validates cleanly against `good`.
    try std.testing.expectEqual(@as(usize, 0), validation_err_count);
}

test "D1: two declarations colliding on form name surface ambiguous_form at data" {
    const a = std.testing.allocator;
    // Both plugins declare `(form :name widget …)`. A bare `(widget …)`
    // at validation time sees two claimants — `ambiguous_form`.
    const src: [:0]const u8 =
        \\(plugin :name pa :version "1.0.0"
        \\  (form :name widget
        \\    (key :name name :type symbol :optional false)))
        \\
        \\(plugin :name pb :version "1.0.0"
        \\  (form :name widget
        \\    (key :name name :type symbol :optional false)))
        \\
        \\(widget :name w0)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 2), r.plugins.len);

    var saw_ambiguous_form = false;
    for (r.diagnostics) |d| {
        if (d.code == .ambiguous_form) {
            try std.testing.expectEqual(Host.Phase.validation, d.phase);
            saw_ambiguous_form = true;
        }
    }
    try std.testing.expect(saw_ambiguous_form);
}

test "D1: data form following a declaration anchors path at the form head" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\(plugin :name probe :version "1.0.0"
        \\  (form :name widget
        \\    (key :name name :type symbol :optional false)))
        \\
        \\(widget)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    var saw = false;
    for (r.diagnostics) |d| {
        if (d.phase != .validation) continue;
        if (d.code != .missing_required_key) continue;
        try std.testing.expect(d.path.len >= 1);
        try std.testing.expectEqualStrings("widget", d.path[0]);
        saw = true;
    }
    try std.testing.expect(saw);
}

test "D1: HostResult.deinit releases every arena under testing.allocator" {
    const a = std.testing.allocator;
    // Run a few times to make a leak across the per-plugin / tree / host
    // arena release sequence reliably trip testing.allocator's checker.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var r = try Host.validateDocument(a, SRC_CLEAN_INLINE, .{});
        r.deinit();
    }
}

test "D1: hasErrors fires for manifest, aggregate, and validation phases" {
    const a = std.testing.allocator;

    // Manifest phase — invalid plugin declaration.
    {
        const src: [:0]const u8 =
            \\(plugin :version "1.0.0"
            \\  (form :name w (key :name name :type symbol :optional false)))
            \\
        ;
        var r = try Host.validateDocument(a, src, .{});
        defer r.deinit();
        try std.testing.expect(r.hasErrors());
        var saw_manifest = false;
        for (r.diagnostics) |d| if (d.severity == .err and d.phase == .manifest) {
            saw_manifest = true;
        };
        try std.testing.expect(saw_manifest);
    }

    // Aggregate phase — `:cross-ref :target` names a form that the
    // schema does not declare (`unknown_cross_ref_target`).
    {
        const src: [:0]const u8 =
            \\(plugin :name agg :version "1.0.0"
            \\  (value-kind :name phrase-name
            \\    :underlying symbol
            \\    :description "ref"
            \\    :cross-ref (cross-ref :target nonexistent))
            \\  (form :name track
            \\    (key :name target :type phrase-name :optional false)))
            \\
        ;
        var r = try Host.validateDocument(a, src, .{});
        defer r.deinit();
        try std.testing.expect(r.hasErrors());
        var saw_aggregate = false;
        for (r.diagnostics) |d| if (d.severity == .err and d.phase == .aggregate) {
            saw_aggregate = true;
        };
        try std.testing.expect(saw_aggregate);
    }

    // Validation phase — clean plugin, broken data.
    {
        const src: [:0]const u8 =
            \\(plugin :name probe :version "1.0.0"
            \\  (form :name w (key :name name :type symbol :optional false)))
            \\
            \\(w)
            \\
        ;
        var r = try Host.validateDocument(a, src, .{});
        defer r.deinit();
        try std.testing.expect(r.hasErrors());
        var saw_validation = false;
        for (r.diagnostics) |d| if (d.severity == .err and d.phase == .validation) {
            saw_validation = true;
        };
        try std.testing.expect(saw_validation);
    }
}

// ---------------------------------------------------------------------------
// D3: `(use-plugin …)` resolver loop coverage.
// ---------------------------------------------------------------------------

const SHAPES_MANIFEST =
    \\(plugin :name shapes :version "1.0.0"
    \\  (form :name circle
    \\    (key :name r :type number :optional false)))
    \\
;

/// Mock resolver that returns whichever Resolution it was constructed
/// with, ignoring the reference. `served` counts calls so tests can
/// assert "resolver was / wasn't invoked."
const MockResolver = struct {
    response: Resolver.Resolution,
    served: u32 = 0,

    fn resolve(
        ctx: *anyopaque,
        ref: Resolver.Reference,
        arena: std.mem.Allocator,
    ) std.mem.Allocator.Error!Resolver.Resolution {
        _ = ref;
        const self: *MockResolver = @ptrCast(@alignCast(ctx));
        self.served += 1;
        // Re-allocate any byte-carrying variant into the caller arena so
        // the host's lifetime expectations hold (the contract says the
        // arena owns the returned bytes).
        return switch (self.response) {
            .manifest => |m| .{ .manifest = .{
                .source = try arena.dupe(u8, m.source),
                .wasm = if (m.wasm) |w| try arena.dupe(u8, w) else null,
            } },
            .failure => |f| .{ .failure = .{
                .code = f.code,
                .detail = try arena.dupe(u8, f.detail),
            } },
        };
    }

    fn handle(self: *MockResolver) Resolver.Resolver {
        return .{ .ctx = self, .resolve = resolve };
    }
};

test "D3: (use-plugin …) with no resolver emits unresolved_plugin" {
    const a = std.testing.allocator;
    const src: [:0]const u8 = "(use-plugin \"shapes\")\n";
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 0), r.declarations.len);
    try std.testing.expectEqual(@as(usize, 1), r.references.len);
    try std.testing.expectEqual(@as(usize, 0), r.plugins.len);
    try std.testing.expect(r.hasErrors());

    var saw = false;
    for (r.diagnostics) |d| if (d.code == .unresolved_plugin) {
        try std.testing.expectEqual(Host.Phase.manifest, d.phase);
        try std.testing.expect(d.declaration_span != null);
        saw = true;
    };
    try std.testing.expect(saw);
}

test "D3: resolver returning a declarative manifest envelope contributes a plugin" {
    const a = std.testing.allocator;
    var mock = MockResolver{ .response = .{ .manifest = .{ .source = SHAPES_MANIFEST } } };

    const src: [:0]const u8 =
        \\(use-plugin "shapes")
        \\(circle :r 4)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{ .resolver = mock.handle() });
    defer r.deinit();

    try std.testing.expectEqual(@as(u32, 1), mock.served);
    try std.testing.expectEqual(@as(usize, 1), r.references.len);
    try std.testing.expectEqual(@as(usize, 1), r.plugins.len);
    try std.testing.expectEqualStrings("shapes", r.plugins[0].name);
    try std.testing.expect(!r.hasErrors());
}

test "D3: resolver manifest with wrong :name surfaces plugin_name_mismatch" {
    const a = std.testing.allocator;
    // Manifest's :name is `shapes`, but the reference asked for `circles`.
    var mock = MockResolver{ .response = .{ .manifest = .{ .source = SHAPES_MANIFEST } } };

    const src: [:0]const u8 = "(use-plugin \"circles\")\n";
    var r = try Host.validateDocument(a, src, .{ .resolver = mock.handle() });
    defer r.deinit();

    try std.testing.expectEqual(@as(u32, 1), mock.served);
    try std.testing.expectEqual(@as(usize, 0), r.plugins.len);
    try std.testing.expect(r.hasErrors());

    var saw = false;
    for (r.diagnostics) |d| if (d.code == .plugin_name_mismatch) {
        try std.testing.expectEqual(Host.Phase.manifest, d.phase);
        saw = true;
    };
    try std.testing.expect(saw);
}

test "D3: matching (use-plugin … :version) pin resolves cleanly" {
    const a = std.testing.allocator;
    var mock = MockResolver{ .response = .{ .manifest = .{ .source = SHAPES_MANIFEST } } };

    const src: [:0]const u8 =
        \\(use-plugin "shapes" :version "1.0.0")
        \\(circle :r 4)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{ .resolver = mock.handle() });
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.plugins.len);
    try std.testing.expect(!r.hasErrors());
}

test "D3: mismatched (use-plugin … :version) pin surfaces plugin_version_mismatch" {
    const a = std.testing.allocator;
    var mock = MockResolver{ .response = .{ .manifest = .{ .source = SHAPES_MANIFEST } } };

    const src: [:0]const u8 = "(use-plugin \"shapes\" :version \"9.9.9\")\n";
    var r = try Host.validateDocument(a, src, .{ .resolver = mock.handle() });
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), mock.served);
    try std.testing.expectEqual(@as(usize, 0), r.plugins.len);
    try std.testing.expect(r.hasErrors());

    var saw = false;
    for (r.diagnostics) |d| if (d.code == .plugin_version_mismatch) {
        try std.testing.expectEqual(Host.Phase.manifest, d.phase);
        try std.testing.expect(std.mem.indexOf(u8, d.message, "9.9.9") != null);
        try std.testing.expect(std.mem.indexOf(u8, d.message, "1.0.0") != null);
        saw = true;
    };
    try std.testing.expect(saw);
}

test "D3: a (use-plugin … :version) pin against an unversioned manifest is plugin_version_mismatch" {
    // `:version` is optional on the manifest. A pin is a claim about a
    // version the manifest declares, so pinning an unversioned plugin
    // fails the same way a wrong pin does — and the message says the
    // manifest declares none rather than quoting an empty string.
    const a = std.testing.allocator;
    const unversioned =
        \\(plugin :name shapes
        \\  (form :name circle
        \\    (key :name r :type number :optional false)))
        \\
    ;
    var mock = MockResolver{ .response = .{ .manifest = .{ .source = unversioned } } };

    const src: [:0]const u8 = "(use-plugin \"shapes\" :version \"1.0.0\")\n";
    var r = try Host.validateDocument(a, src, .{ .resolver = mock.handle() });
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 0), r.plugins.len);
    try std.testing.expect(r.hasErrors());

    var saw = false;
    for (r.diagnostics) |d| if (d.code == .plugin_version_mismatch) {
        try std.testing.expectEqual(Host.Phase.manifest, d.phase);
        try std.testing.expect(std.mem.indexOf(u8, d.message, "declares no :version") != null);
        saw = true;
    };
    try std.testing.expect(saw);
}

test "D3: an unversioned manifest resolves cleanly when nothing pins it" {
    const a = std.testing.allocator;
    const unversioned =
        \\(plugin :name shapes
        \\  (form :name circle
        \\    (key :name r :type number :optional false)))
        \\
    ;
    var mock = MockResolver{ .response = .{ .manifest = .{ .source = unversioned } } };

    const src: [:0]const u8 =
        \\(use-plugin "shapes")
        \\(circle :r 4)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{ .resolver = mock.handle() });
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.plugins.len);
    try std.testing.expect(!r.hasErrors());
    try std.testing.expectEqualStrings("", r.plugins[0].version);
}

test "D3: matching (use-plugin … :hash) pin resolves cleanly" {
    // Test premise: the hash-pin path verifies bytes BEFORE any
    // runtime instantiation. Under `-Dplugin-exec=true` the same path
    // continues into pre-flight, which (correctly) rejects the
    // arbitrary `fake-wasm` payload. To keep this test scoped to the
    // hash-pin semantics, skip it on plugin-exec builds; the conformance
    // corpus's `use-plugin-hash-mismatch` case exercises the full
    // hash + pre-flight chain against real wasm bytes.
    if (build_options.plugin_exec) return;

    const a = std.testing.allocator;
    const wasm_bytes = "fake-wasm";
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(wasm_bytes, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);

    var mock = MockResolver{ .response = .{ .manifest = .{
        .source = SHAPES_MANIFEST,
        .wasm = wasm_bytes,
    } } };

    const src = try std.fmt.allocPrintSentinel(
        a,
        "(use-plugin \"shapes\" :hash \"sha256-{s}\")\n(circle :r 4)\n",
        .{hex},
        0,
    );
    defer a.free(src);

    var r = try Host.validateDocument(a, src, .{ .resolver = mock.handle() });
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.plugins.len);
    try std.testing.expect(!r.hasErrors());
}

test "D3: mismatched (use-plugin … :hash) pin surfaces plugin_hash_mismatch" {
    const a = std.testing.allocator;
    var mock = MockResolver{ .response = .{ .manifest = .{
        .source = SHAPES_MANIFEST,
        .wasm = "fake-wasm",
    } } };

    const src: [:0]const u8 =
        "(use-plugin \"shapes\" :hash \"sha256-0000000000000000000000000000000000000000000000000000000000000000\")\n";
    var r = try Host.validateDocument(a, src, .{ .resolver = mock.handle() });
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 0), r.plugins.len);
    var saw = false;
    for (r.diagnostics) |d| if (d.code == .plugin_hash_mismatch) {
        try std.testing.expectEqual(Host.Phase.manifest, d.phase);
        try std.testing.expect(std.mem.indexOf(u8, d.message, "does not match") != null);
        saw = true;
    };
    try std.testing.expect(saw);
}

test "D3: malformed :hash pin surfaces plugin_hash_mismatch" {
    const a = std.testing.allocator;
    var mock = MockResolver{ .response = .{ .manifest = .{
        .source = SHAPES_MANIFEST,
        .wasm = "fake-wasm",
    } } };

    // `md5-…` is not a recognised algorithm; resolver should reject.
    const src: [:0]const u8 = "(use-plugin \"shapes\" :hash \"md5-deadbeef\")\n";
    var r = try Host.validateDocument(a, src, .{ .resolver = mock.handle() });
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 0), r.plugins.len);
    var saw = false;
    for (r.diagnostics) |d| if (d.code == .plugin_hash_mismatch) {
        try std.testing.expect(std.mem.indexOf(u8, d.message, "malformed") != null);
        saw = true;
    };
    try std.testing.expect(saw);
}

test "D3: :hash pin with no wasm surfaces plugin_hash_mismatch" {
    const a = std.testing.allocator;
    // Manifest only — no sidecar wasm. Pinning a hash on a declarative
    // manifest is meaningless and fails fast with a discriminating
    // detail.
    var mock = MockResolver{ .response = .{ .manifest = .{
        .source = SHAPES_MANIFEST,
    } } };

    const src: [:0]const u8 =
        "(use-plugin \"shapes\" :hash \"sha256-0000000000000000000000000000000000000000000000000000000000000000\")\n";
    var r = try Host.validateDocument(a, src, .{ .resolver = mock.handle() });
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 0), r.plugins.len);
    var saw = false;
    for (r.diagnostics) |d| if (d.code == .plugin_hash_mismatch) {
        try std.testing.expect(std.mem.indexOf(u8, d.message, "no wasm") != null);
        saw = true;
    };
    try std.testing.expect(saw);
}

test "D3: resolver returning structured failure preserves the failure code" {
    const a = std.testing.allocator;
    var mock = MockResolver{ .response = .{ .failure = .{
        .code = .plugin_version_mismatch,
        .detail = "needed 2.x, got 1.0",
    } } };

    const src: [:0]const u8 = "(use-plugin \"shapes\" :version \"2.x\")\n";
    var r = try Host.validateDocument(a, src, .{ .resolver = mock.handle() });
    defer r.deinit();

    try std.testing.expectEqual(@as(u32, 1), mock.served);
    try std.testing.expectEqual(@as(usize, 0), r.plugins.len);

    var saw = false;
    for (r.diagnostics) |d| if (d.code == .plugin_version_mismatch) {
        try std.testing.expectEqual(Host.Phase.manifest, d.phase);
        try std.testing.expect(std.mem.indexOf(u8, d.message, "needed 2.x") != null);
        saw = true;
    };
    try std.testing.expect(saw);
}

test "D3: resolver returning manifest+wasm bytes loads declaratively in Zig native" {
    // Test premise documented in the old `docs/executable-plugin-abi.md`
    // §15.1 wording (now superseded): "Zig native loads manifest
    // declarations but does not instantiate the sidecar". With the
    // native runtime adapter shipped (`-Dplugin-exec=true` default),
    // arbitrary `fake-wasm` bytes get pre-flighted and rejected as
    // `plugin_abi_mismatch`. The declarative-only stance survives as a
    // build-option fallback; this test only verifies it in that mode.
    // Cross-host pre-flight coverage moved to the conformance corpus
    // (`plugin-exec-*` cases) which uses real fixture wasm.
    if (build_options.plugin_exec) return;

    const a = std.testing.allocator;
    var mock = MockResolver{ .response = .{ .manifest = .{
        .source = SHAPES_MANIFEST,
        .wasm = "fake-wasm",
    } } };

    const src: [:0]const u8 = "(use-plugin \"shapes\")\n";
    var r = try Host.validateDocument(a, src, .{ .resolver = mock.handle() });
    defer r.deinit();

    try std.testing.expectEqual(@as(u32, 1), mock.served);
    try std.testing.expectEqual(@as(usize, 1), r.plugins.len);
    try std.testing.expectEqualStrings("shapes", r.plugins[0].name);
    try std.testing.expect(!r.hasErrors());
}

test "D7-exec: resolver returning pre-flight failure code lands at .manifest phase" {
    const a = std.testing.allocator;
    // Mirror of the cross-host pre-flight path: a host whose resolver
    // bridge instantiated the plugin and found ABI 99 returns a
    // Resolution.failure with `plugin_abi_mismatch`. Host.validateDocument
    // surfaces it at the (use-plugin …) reference span under
    // `phase: .manifest`.
    var mock = MockResolver{ .response = .{ .failure = .{
        .code = .plugin_abi_mismatch,
        .detail = "shapes.wasm reports ABI 99; host implements 1",
    } } };

    const src: [:0]const u8 = "(use-plugin \"shapes\")\n";
    var r = try Host.validateDocument(a, src, .{ .resolver = mock.handle() });
    defer r.deinit();

    try std.testing.expectEqual(@as(u32, 1), mock.served);
    try std.testing.expectEqual(@as(usize, 0), r.plugins.len);

    var saw = false;
    for (r.diagnostics) |d| if (d.code == .plugin_abi_mismatch) {
        try std.testing.expectEqual(Host.Phase.manifest, d.phase);
        try std.testing.expect(std.mem.indexOf(u8, d.message, "ABI 99") != null);
        try std.testing.expect(d.declaration_span != null);
        saw = true;
    };
    try std.testing.expect(saw);
}

test "D7: manifest declares wasm:* impl but resolver returned no wasm → plugin_wasm_required" {
    const a = std.testing.allocator;
    // Manifest declares one `:impl "wasm:double"` expr-func, resolver
    // returns the manifest only (no paired wasm). Without the loud
    // diagnostic the plugin would load as declaration-only and the
    // failure would surface as a generic `PluginFuncNotImplemented` at
    // eval time.
    const WASM_REFERENCING_MANIFEST =
        \\(plugin :name math2 :version "1.0.0"
        \\  (expr-func :name double
        \\    :params [number]
        \\    :result number
        \\    :impl "wasm:double"))
        \\
    ;
    var mock = MockResolver{ .response = .{ .manifest = .{ .source = WASM_REFERENCING_MANIFEST } } };

    const src: [:0]const u8 = "(use-plugin \"math2\")\n";
    var r = try Host.validateDocument(a, src, .{ .resolver = mock.handle() });
    defer r.deinit();

    try std.testing.expectEqual(@as(u32, 1), mock.served);
    // Manifest still loads (declaration-only); the diagnostic is the
    // load-time signal that the executable side is missing.
    try std.testing.expectEqual(@as(usize, 1), r.plugins.len);
    try std.testing.expectEqualStrings("math2", r.plugins[0].name);

    var saw_wasm_required = false;
    var saw_unresolved = false;
    for (r.diagnostics) |d| switch (d.code) {
        .plugin_wasm_required => {
            try std.testing.expectEqual(Host.Phase.manifest, d.phase);
            try std.testing.expect(std.mem.indexOf(u8, d.message, "wasm:") != null);
            saw_wasm_required = true;
        },
        .unresolved_plugin => saw_unresolved = true,
        else => {},
    };
    try std.testing.expect(saw_wasm_required);
    // The deferral diagnostic only fires when wasm bytes ARE present;
    // the missing-wasm path is plugin_wasm_required's job.
    try std.testing.expect(!saw_unresolved);
}

test "D3: malformed (use-plugin) skips the resolver entirely" {
    const a = std.testing.allocator;
    var mock = MockResolver{ .response = .{ .manifest = .{ .source = SHAPES_MANIFEST } } };

    const src: [:0]const u8 = "(use-plugin)\n";
    var r = try Host.validateDocument(a, src, .{ .resolver = mock.handle() });
    defer r.deinit();

    try std.testing.expectEqual(@as(u32, 0), mock.served);
    var saw_invalid = false;
    for (r.diagnostics) |d| if (d.code == .invalid_manifest) {
        saw_invalid = true;
    };
    try std.testing.expect(saw_invalid);
}

test "D3: two references for the same name dedupe via duplicate_plugin_name" {
    const a = std.testing.allocator;
    // Two `(use-plugin "shapes")` references resolve to the same plugin
    // name. Without dedupe, `Schema.lookupForm` would see two claimants
    // for every form name and return `ambiguous_form` for any bare
    // invocation. Dedupe is loud (duplicate_plugin_name) rather than
    // silent so resolvers returning inconsistent content for the same
    // name aren't masked.
    var mock = MockResolver{ .response = .{ .manifest = .{ .source = SHAPES_MANIFEST } } };

    const src: [:0]const u8 =
        \\(use-plugin "shapes")
        \\(use-plugin "shapes")
        \\(circle :r 4)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{ .resolver = mock.handle() });
    defer r.deinit();

    // Resolver still gets called for both references (parsing + lookup
    // happens before the dedupe check); only the schema-level duplicate
    // is suppressed.
    try std.testing.expectEqual(@as(u32, 2), mock.served);
    try std.testing.expectEqual(@as(usize, 1), r.plugins.len);
    try std.testing.expectEqualStrings("shapes", r.plugins[0].name);

    var saw_dup = false;
    var saw_ambiguous = false;
    for (r.diagnostics) |d| switch (d.code) {
        .duplicate_plugin_name => {
            try std.testing.expectEqual(Host.Phase.manifest, d.phase);
            try std.testing.expect(std.mem.indexOf(u8, d.message, "shapes") != null);
            saw_dup = true;
        },
        .ambiguous_form => saw_ambiguous = true,
        else => {},
    };
    try std.testing.expect(saw_dup);
    // The bare `(circle :r 4)` data form must resolve cleanly — the
    // dedupe leaves only one claimant in the schema.
    try std.testing.expect(!saw_ambiguous);
}

test "D3: inline (plugin …) and (use-plugin …) compose into one schema" {
    const a = std.testing.allocator;
    var mock = MockResolver{ .response = .{ .manifest = .{ .source = SHAPES_MANIFEST } } };

    const src: [:0]const u8 =
        \\(plugin :name local :version "1.0.0"
        \\  (form :name probe (key :name name :type symbol :optional false)))
        \\(use-plugin "shapes")
        \\
        \\(probe :name p)
        \\(circle :r 1)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{ .resolver = mock.handle() });
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.declarations.len);
    try std.testing.expectEqual(@as(usize, 1), r.references.len);
    try std.testing.expectEqual(@as(usize, 2), r.plugins.len);
    try std.testing.expect(!r.hasErrors());
}

test "D3: D0 constructibility — three new project-resolution codes" {
    try std.testing.expectEqual(
        Ast.Diagnostic.Code.duplicate_plugin_name,
        diagWith(.duplicate_plugin_name).code,
    );
    try std.testing.expectEqual(
        Ast.Diagnostic.Code.plugin_name_mismatch,
        diagWith(.plugin_name_mismatch).code,
    );
    try std.testing.expectEqual(
        Ast.Diagnostic.Code.project_file_not_found,
        diagWith(.project_file_not_found).code,
    );
}

// ---------------------------------------------------------------------------
// D8-lower: validateLowering runs as part of the aggregate phase.
// ---------------------------------------------------------------------------

test "D8-lower: unknown :produces head emits aggregate unknown_form" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\(plugin :name low :version "1.0.0"
        \\  (form :name pass-foo
        \\    :lowering (lowering :hook pass :produces [no-such-form])))
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();
    try std.testing.expect(r.hasErrors());
    var saw: bool = false;
    for (r.diagnostics) |d| {
        if (d.severity == .err and d.phase == .aggregate and
            d.code == .unknown_form)
        {
            saw = true;
        }
    }
    try std.testing.expect(saw);
}

test "D8-lower: every :produces head resolves cleanly → no aggregate diagnostics" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\(plugin :name low :version "1.0.0"
        \\  (form :name circle
        \\    (key :name r :type number :optional false))
        \\  (form :name pass-circle
        \\    :lowering (lowering :hook pass :produces [circle])))
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();
    var aggregate_errors: usize = 0;
    for (r.diagnostics) |d| {
        if (d.severity == .err and d.phase == .aggregate) aggregate_errors += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), aggregate_errors);
}

// ---------------------------------------------------------------------------
// D8-defaults: validateDefaults runs as part of the aggregate phase.
// Expression-shaped defaults retain both cheap head metadata and a
// one-root Binary IR program. The aggregate phase resolves the metadata
// via the same Validator helpers D8-types built and emits
// `wrong_underlying` on a `.no` verdict.
// ---------------------------------------------------------------------------

test "D8-defaults: expression default with mismatched result emits aggregate wrong_underlying" {
    const a = std.testing.allocator;
    // Declare a 0-arity expression head returning `string`, then bind it
    // as the default for a `number`-typed key — mismatch, must emit.
    const src: [:0]const u8 =
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name lbl :arity (fixed 0) :result string)
        \\  (form :name scene
        \\    (key :name fps :type number :default (lbl))))
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();
    try std.testing.expect(r.hasErrors());
    var saw: bool = false;
    for (r.diagnostics) |d| {
        if (d.severity == .err and d.phase == .aggregate and
            d.code == .wrong_underlying and d.path.len == 4 and
            std.mem.eql(u8, d.path[3], "default"))
        {
            saw = true;
        }
    }
    try std.testing.expect(saw);
}

test "D8-defaults: expression default with matching result yields zero aggregate errors" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name nx :arity (fixed 0) :result number)
        \\  (form :name scene
        \\    (key :name fps :type number :default (nx))))
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();
    var aggregate_errors: usize = 0;
    for (r.diagnostics) |d| {
        if (d.severity == .err and d.phase == .aggregate) aggregate_errors += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), aggregate_errors);
}

// ---------------------------------------------------------------------------
// Default materialization — `Host.validateDocument` populates
// `HostResult.materialized_defaults` for omitted defaulted keys on every
// known data form, and surfaces `default_eval_failed` at .validation
// phase when an expression default fails to evaluate.
// ---------------------------------------------------------------------------

fn firstDataForm(r: *const Host.HostResult) ?Ast.NodeIndex {
    for (r.data_forest) |idx| {
        if (r.tree.tagOf(idx) == .form) return idx;
    }
    return null;
}

test "default materialization: literal default lands on the overlay for an omitted key" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name fps :type number :default 60)))
        \\(scene)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    try std.testing.expect(!r.hasErrors());

    const form_idx = firstDataForm(&r) orelse return error.TestNoDataForm;
    const entry = r.materialized_defaults.defaultFor(form_idx, "fps") orelse
        return error.TestMissingDefaultEntry;
    try std.testing.expectEqual(@as(f64, 60), entry.value.toF64().?);
    try std.testing.expectEqual(sjon.MaterializedDefaults.Origin.literal_default, entry.origin);
}

test "default materialization: explicit author kvpair suppresses the overlay entry" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name fps :type number :default 60)))
        \\(scene :fps 30)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    try std.testing.expect(!r.hasErrors());

    const form_idx = firstDataForm(&r) orelse return error.TestNoDataForm;
    try std.testing.expect(r.materialized_defaults.defaultFor(form_idx, "fps") == null);
}

test "default materialization: expression default whose func has no impl emits default_eval_failed at .validation" {
    const a = std.testing.allocator;
    // `nope` is a declared expr-func with no `:impl` — aggregate phase
    // is happy (the result type matches the key type) but runtime
    // evaluation of `(nope)` fails, which is exactly the
    // `default_eval_failed` path.
    const src: [:0]const u8 =
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name nope :arity (fixed 0) :result number)
        \\  (form :name scene
        \\    (key :name fps :type number :default (nope))))
        \\(scene)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    var saw: bool = false;
    for (r.diagnostics) |d| {
        if (d.severity == .err and d.phase == .validation and
            d.code == .default_eval_failed)
        {
            saw = true;
        }
    }
    try std.testing.expect(saw);

    const form_idx = firstDataForm(&r) orelse return error.TestNoDataForm;
    // Failed evaluation contributes no overlay entry — the negative
    // cache suppresses both the entry and any duplicate diagnostic
    // emission on repeated instances.
    try std.testing.expect(r.materialized_defaults.defaultFor(form_idx, "fps") == null);
}

test "default materialization: failed expression default fires once across many form instances" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name nope :arity (fixed 0) :result number)
        \\  (form :name scene
        \\    (key :name fps :type number :default (nope))))
        \\(scene)
        \\(scene)
        \\(scene)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    var fail_count: usize = 0;
    for (r.diagnostics) |d| {
        if (d.code == .default_eval_failed) fail_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), fail_count);
}

test "phase-reorder regression guard: validator diags precede materializer diags within .validation phase" {
    const a = std.testing.allocator;
    // Two .validation-phase emissions on the same document: the validator
    // sees `:radius "huh"` and emits `wrong_underlying`; the materializer
    // sees the omitted `:fps (nope)` default and emits `default_eval_failed`.
    // Validator diagnostic must come first — that's the pre-reorder order
    // the conformance corpus is pinned to.
    const src: [:0]const u8 =
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name nope :arity (fixed 0) :result number)
        \\  (form :name scene
        \\    (key :name fps :type number :default (nope))
        \\    (key :name radius :type number)))
        \\(scene :radius "huh")
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    var validator_pos: ?usize = null;
    var materializer_pos: ?usize = null;
    for (r.diagnostics, 0..) |d, i| {
        if (d.phase != .validation) continue;
        if (d.code == .wrong_underlying and validator_pos == null) validator_pos = i;
        if (d.code == .default_eval_failed and materializer_pos == null) materializer_pos = i;
    }
    try std.testing.expect(validator_pos != null);
    try std.testing.expect(materializer_pos != null);
    try std.testing.expect(validator_pos.? < materializer_pos.?);
}

// ---------------------------------------------------------------------------
// JSON exposure — `wasm_host_json.writeHostResult` emits a
// `materializedDefaults` array so cross-host consumers (Web, Rust) can
// read effective values without re-running materialization.
// ---------------------------------------------------------------------------

const wasm_host_json = @import("wasm_host_json.zig");

fn parseMaterializedField(a: std.mem.Allocator, json_text: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, a, json_text, .{});
}

// JSON numbers come back as `.integer` for whole-valued inputs (e.g. `60`)
// and `.float` for fractional inputs. Pull either arm uniformly.
fn jsonNumber(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => unreachable,
    };
}

test "writeHostResult JSON: literal default emits one entry with origin=literal_default" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name fps :type number :default 60)))
        \\(scene)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    const json_text = try wasm_host_json.writeHostResult(a, r);
    defer a.free(json_text);

    var parsed = try parseMaterializedField(a, json_text);
    defer parsed.deinit();

    const obj = parsed.value.object;
    const arr = obj.get("materializedDefaults").?.array;
    try std.testing.expectEqual(@as(usize, 1), arr.items.len);

    const entry = arr.items[0].object;
    const path = entry.get("path").?.array;
    try std.testing.expectEqual(@as(usize, 2), path.items.len);
    try std.testing.expectEqualStrings("scene", path.items[0].string);
    try std.testing.expectEqualStrings("fps", path.items[1].string);
    try std.testing.expectEqualStrings("fps", entry.get("key").?.string);
    try std.testing.expectEqualStrings("literal_default", entry.get("origin").?.string);
    try std.testing.expectEqual(@as(f64, 60), jsonNumber(entry.get("value").?));
}

test "writeHostResult JSON: expression default emits origin=expression_default" {
    const a = std.testing.allocator;
    // `(if ...)` is a special form dispatched by the evaluator before
    // any schema lookup, so it materializes without needing `core` to
    // be loaded into the document's schema.
    const src: [:0]const u8 =
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name fps :type number :default (if true 60 0))))
        \\(scene)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    const json_text = try wasm_host_json.writeHostResult(a, r);
    defer a.free(json_text);

    var parsed = try parseMaterializedField(a, json_text);
    defer parsed.deinit();

    const arr = parsed.value.object.get("materializedDefaults").?.array;
    try std.testing.expectEqual(@as(usize, 1), arr.items.len);
    const entry = arr.items[0].object;
    try std.testing.expectEqualStrings("expression_default", entry.get("origin").?.string);
    try std.testing.expectEqual(@as(f64, 60), jsonNumber(entry.get("value").?));
}

test "writeHostResult JSON: explicit author kvpair suppresses overlay entry" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name fps :type number :default 60)))
        \\(scene :fps 30)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    const json_text = try wasm_host_json.writeHostResult(a, r);
    defer a.free(json_text);

    var parsed = try parseMaterializedField(a, json_text);
    defer parsed.deinit();

    const arr = parsed.value.object.get("materializedDefaults").?.array;
    try std.testing.expectEqual(@as(usize, 0), arr.items.len);
}

test "writeHostResult JSON: failed expression default yields no entry" {
    const a = std.testing.allocator;
    // `(nope)` has no `:impl` — runtime materialization fails and the
    // negative-cache path emits one `default_eval_failed` diagnostic
    // and zero overlay entries.
    const src: [:0]const u8 =
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name nope :arity (fixed 0) :result number)
        \\  (form :name scene
        \\    (key :name fps :type number :default (nope))))
        \\(scene)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    const json_text = try wasm_host_json.writeHostResult(a, r);
    defer a.free(json_text);

    var parsed = try parseMaterializedField(a, json_text);
    defer parsed.deinit();

    const arr = parsed.value.object.get("materializedDefaults").?.array;
    try std.testing.expectEqual(@as(usize, 0), arr.items.len);
}

test "writeHostResult JSON: evaluatedResults field is always present" {
    const a = std.testing.allocator;
    // No expr-funcs evaluated → field is present but empty. Web + Rust
    // decoders can therefore unconditionally read the array.
    var r = try Host.validateDocument(a, SRC_CLEAN_INLINE, .{});
    defer r.deinit();

    const json_text = try wasm_host_json.writeHostResult(a, r);
    defer a.free(json_text);

    var parsed = try parseMaterializedField(a, json_text);
    defer parsed.deinit();

    const arr = parsed.value.object.get("evaluatedResults").?.array;
    try std.testing.expectEqual(@as(usize, 0), arr.items.len);
}

// ---------------------------------------------------------------------------
// D8-lowering-runtime — end-to-end through Host.validateDocument.
// ---------------------------------------------------------------------------

test "D8-lowering: registry=null leaves the pipeline byte-identical" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\(plugin :name probe :version "1.0.0"
        \\  (form :name sugar :open true
        \\    :lowering (lowering :hook test/identity-v1 :produces [sugar-normal]))
        \\  (form :name sugar-normal :open true))
        \\(sugar :a 1)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    try std.testing.expect(r.lowered_tree == null);
    try std.testing.expectEqual(@as(usize, 0), r.lowering_provenance.entries.len);

    var saw_any_lowering_diag = false;
    for (r.diagnostics) |d| {
        if (d.phase == .lowering) saw_any_lowering_diag = true;
    }
    try std.testing.expect(!saw_any_lowering_diag);
}

test "D8-lowering: registry with test/identity-v1 builds a lowered tree" {
    const a = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    try registry.register(a, Lowering_test_hooks.test_identity_v1);

    const src: [:0]const u8 =
        \\(plugin :name probe :version "1.0.0"
        \\  (form :name sugar :open true
        \\    :lowering (lowering :hook test/identity-v1 :produces [sugar-normal]))
        \\  (form :name sugar-normal :open true))
        \\(sugar :a 1)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{ .lowering_registry = &registry });
    defer r.deinit();

    for (r.diagnostics) |d| {
        if (d.severity != .err) continue;
        std.debug.print("\nunexpected err: phase={s} code={s}\n", .{ @tagName(d.phase), @tagName(d.code) });
    }
    try std.testing.expect(!r.hasErrors());

    const lt = r.lowered_tree orelse return error.TestNoLoweredTree;
    try std.testing.expectEqual(@as(usize, 1), lt.root.len);
    const hdr = lt.formHeader(lt.root[0]);
    try std.testing.expectEqualStrings("sugar-normal", hdr.head);

    try std.testing.expectEqual(@as(usize, 1), r.lowering_provenance.entries.len);
    const prov = r.lowering_provenance.entries[0];
    try std.testing.expectEqualStrings("test/identity-v1", prov.hook_id);
    // Source form is the first data-form root (after the plugin decl).
    try std.testing.expect(prov.source_form_idx.isValid());
}

// v2 lowered-tree overlay: a hook emits a form that omits a key whose
// KeySpec carries a `:default`, so the default materializes on the
// *lowered* tree's overlay — keyed on the lowered NodeIndex, which the
// source overlay (source-index space) can never match. Pins the
// before/after contract a downstream host (PNGine) depends on: pairing
// `lowered_tree` with the new overlay resolves the default; pairing it
// with an empty overlay (the prior behavior) returns null.
test "D8-lowering: lowered_materialized_defaults resolves a default on a hook-emitted form" {
    const a = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    try registry.register(a, Lowering_test_hooks.test_identity_v1);

    // `sugar` declares no keys, so identity-v1 emits a bare `(sugar-normal)`.
    // `sugar-normal`'s `:kind` is defaulted + optional, so the lowered-tree
    // overlay materializes `kind = normal` on the emitted form.
    const src: [:0]const u8 =
        \\(plugin :name probe :version "1.0.0"
        \\  (form :name sugar :open true
        \\    :lowering (lowering :hook test/identity-v1 :produces [sugar-normal]))
        \\  (form :name sugar-normal :open true
        \\    (key :name kind :type symbol :default normal :optional true)))
        \\(sugar)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{ .lowering_registry = &registry });
    defer r.deinit();
    try std.testing.expect(!r.hasErrors());

    const lt = r.lowered_tree orelse return error.TestNoLoweredTree;
    try std.testing.expectEqual(@as(usize, 1), lt.root.len);
    const lform = lt.root[0];

    // (a) The overlay carries the entry, keyed on the lowered form node.
    const entry = r.lowered_materialized_defaults.defaultFor(lform, "kind") orelse
        return error.TestMissingLoweredDefault;
    // `:default normal` is a symbol literal → `Expr.Value.keyword`.
    try std.testing.expectEqualStrings("normal", entry.value.keyword);

    // (b) EffectiveView over (lowered_tree, NEW overlay) resolves the default…
    const ev_new = sjon.EffectiveView.EffectiveView.init(&lt, &r.lowered_materialized_defaults);
    try std.testing.expect(ev_new.getEffectiveValue(lform, "kind") != null);

    // …while the prior empty-overlay pairing returns null (the dead-default bug).
    const empty: sjon.MaterializedDefaults.MaterializedDefaults = .{};
    const ev_old = sjon.EffectiveView.EffectiveView.init(&lt, &empty);
    try std.testing.expect(ev_old.getEffectiveValue(lform, "kind") == null);
}

// Negative space: no lowering registry → nothing lowers, so `lowered_tree`
// stays null and the lowered overlay is empty/default (`.{}`). The *source*
// overlay still materializes the `:default`; the lowered one does not exist.
test "D8-lowering: no lowering yields an empty lowered_materialized_defaults" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene
        \\    (key :name fps :type number :default 60 :optional true)))
        \\(scene)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    try std.testing.expect(r.lowered_tree == null);
    try std.testing.expectEqual(@as(usize, 0), r.lowered_materialized_defaults.entries.len);
}

// Multi-stage: the returned overlay must reflect the *terminal* layer and
// survive the freeing of intermediate layer trees. `a` → `a-normal` →
// `a-normal-normal` chains because identity-v1 emits `<head>-normal`. Only
// the terminal `a-normal-normal` declares the defaulted `:tag`; neither `a`
// nor `a-normal` does, so a materialized `tag = leaf` can come *only* from
// the last layer's overlay — proving `stage_mats.items[last]` is selected
// (not an intermediate) and that its host-arena entries outlive the
// `for (stage_trees.items[0..last]) lt.deinit()` sweep.
test "D8-lowering: lowered_materialized_defaults reflects the terminal layer across stages" {
    const a = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    try registry.register(a, Lowering_test_hooks.test_identity_v1);

    const src: [:0]const u8 =
        \\(plugin :name stage :version "1.0.0"
        \\  (form :name a :open true
        \\    :lowering (lowering :hook test/identity-v1 :produces [a-normal]))
        \\  (form :name a-normal :open true
        \\    :lowering (lowering :hook test/identity-v1 :produces [a-normal-normal]))
        \\  (form :name a-normal-normal :open true
        \\    (key :name tag :type symbol :default leaf :optional true)))
        \\(a)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{ .lowering_registry = &registry });
    defer r.deinit();
    try std.testing.expect(!r.hasErrors());

    // Terminal layer is `a-normal-normal`, not the intermediate `a-normal`.
    const lt = r.lowered_tree orelse return error.TestNoLoweredTree;
    try std.testing.expectEqual(@as(usize, 1), lt.root.len);
    const lform = lt.root[0];
    try std.testing.expectEqualStrings("a-normal-normal", lt.formHeader(lform).head);

    // Exactly the terminal default — intermediate layers contribute none.
    try std.testing.expectEqual(@as(usize, 1), r.lowered_materialized_defaults.entries.len);
    const entry = r.lowered_materialized_defaults.defaultFor(lform, "tag") orelse
        return error.TestMissingLoweredDefault;
    try std.testing.expectEqualStrings("leaf", entry.value.keyword);

    const ev = sjon.EffectiveView.EffectiveView.init(&lt, &r.lowered_materialized_defaults);
    const eff = ev.getEffectiveValue(lform, "tag") orelse return error.TestNoEffectiveValue;
    try std.testing.expect(std.meta.activeTag(eff) == .default);
}

// Overlay semantics carry over to lowered trees: it holds only *omitted*
// defaults, spans every terminal root, and author-written keys win. One
// `(bundle …)` fans out via test/bundle-v1 to two roots — `(asset :name
// <n>-asset)` + `(link …)`. On `asset` the hook writes `:name`, so it
// resolves `.author` (beating the `:name` default and contributing no
// overlay entry); the omitted `:format` materializes `png` as `.default`.
test "D8-lowering: lowered overlay holds only omitted defaults; author keys win" {
    const a = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    try registry.register(a, Lowering_test_hooks.test_bundle_v1);

    const src: [:0]const u8 =
        \\(plugin :name bun :version "1.0.0"
        \\  (form :name bundle :open true
        \\    (key :name name :type symbol :optional false)
        \\    (key :name target :type symbol :optional false)
        \\    :lowering (lowering :hook test/bundle-v1 :produces [asset link]))
        \\  (form :name asset :open true
        \\    (key :name name :type symbol :default anon :optional true)
        \\    (key :name format :type symbol :default png :optional true))
        \\  (form :name link :open true
        \\    (key :name from :type symbol :optional true)
        \\    (key :name to :type symbol :optional true)))
        \\(bundle :name thing :target dest)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{ .lowering_registry = &registry });
    defer r.deinit();
    try std.testing.expect(!r.hasErrors());

    const lt = r.lowered_tree orelse return error.TestNoLoweredTree;
    try std.testing.expectEqual(@as(usize, 2), lt.root.len);

    // Locate the emitted `asset` root among the two terminals.
    var asset: ?Ast.NodeIndex = null;
    for (lt.root) |idx| {
        if (std.mem.eql(u8, lt.formHeader(idx).head, "asset")) asset = idx;
    }
    const aform = asset orelse return error.TestNoAssetForm;

    const ev = sjon.EffectiveView.EffectiveView.init(&lt, &r.lowered_materialized_defaults);

    // `:name` was written by the hook → no overlay entry, resolves `.author`.
    try std.testing.expect(r.lowered_materialized_defaults.defaultFor(aform, "name") == null);
    const name_eff = ev.getEffectiveValue(aform, "name") orelse return error.TestNoName;
    try std.testing.expect(std.meta.activeTag(name_eff) == .author);

    // `:format` was omitted → overlay materializes the `png` default.
    const fmt = r.lowered_materialized_defaults.defaultFor(aform, "format") orelse
        return error.TestMissingFormatDefault;
    try std.testing.expectEqualStrings("png", fmt.value.keyword);
    const fmt_eff = ev.getEffectiveValue(aform, "format") orelse return error.TestNoFormat;
    try std.testing.expect(std.meta.activeTag(fmt_eff) == .default);
}

// The lowering pass validates each sugar form against `eval_schema` (core
// prepended), so an author *expression* in a value slot resolves its core
// operators instead of failing the surface gate with `unknown_form`. Before
// this, the lowering pass used the user-only `schema`, so `(* 2 2)` in a
// `:type number` slot was rejected and the hook never ran. `test/eval-env-v1`
// reads `:count` via `numberEval`, which evaluates the expression → 4.
test "D8-lowering: an expression in a lowering form's value slot resolves core operators" {
    const a = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    try registry.register(a, Lowering_test_hooks.test_eval_env_v1);

    const src: [:0]const u8 =
        \\(plugin :name probe :version "1.0.0"
        \\  (form :name thing
        \\    (key :name count :type number :optional true)
        \\    :lowering (lowering :hook test/eval-env-v1 :produces [descriptor]))
        \\  (form :name descriptor :open true))
        \\(thing :count (* 2 2))
        \\
    ;
    var r = try Host.validateDocument(a, src, .{ .lowering_registry = &registry });
    defer r.deinit();

    for (r.diagnostics) |d| {
        if (d.severity != .err) continue;
        std.debug.print("\nunexpected err: phase={s} code={s}\n", .{ @tagName(d.phase), @tagName(d.code) });
    }
    try std.testing.expect(!r.hasErrors());

    const lt = r.lowered_tree orelse return error.TestNoLoweredTree;
    try std.testing.expectEqual(@as(usize, 1), lt.root.len);
    const hdr = lt.formHeader(lt.root[0]);
    try std.testing.expectEqualStrings("descriptor", hdr.head);

    // The lowered `(descriptor :count <n>)` carries the evaluated `(* 2 2)` → 4.
    var count: ?f64 = null;
    for (hdr.children) |child| {
        if (lt.tagOf(child) != .kvpair) continue;
        const kvh = lt.kvpairHeader(child);
        if (!std.mem.eql(u8, kvh.key, "count")) continue;
        count = lt.numberOf(kvh.value);
    }
    try std.testing.expectEqual(@as(f64, 4), count orelse return error.TestNoCount);
}

// End-to-end proof of the `HostOptions.lowering_env` knob — the PNGine-facing
// path. The same document and registry lower cleanly *with* a populated env and
// fail *without* one, so this pins the embedder's plumbing, not just the
// `Lowering`-level API the inline tests in `Lowering_test_hooks.zig` cover. The
// `:count` slot holds an expression with a *free* variable (`workgroup-size`),
// which only the host env can bind — a bare `:count workgroup-size` would be a
// static `wrong_underlying` in the `:type number` slot.
const EVAL_ENV_SRC: [:0]const u8 =
    \\(plugin :name probe :version "1.0.0"
    \\  (form :name thing
    \\    (key :name count :type number :optional true)
    \\    :lowering (lowering :hook test/eval-env-v1 :produces [descriptor]))
    \\  (form :name descriptor :open true))
    \\(thing :count (* workgroup-size 1))
    \\
;

test "D8-lowering: HostOptions.lowering_env resolves a host constant in an author expression" {
    const a = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    try registry.register(a, Lowering_test_hooks.test_eval_env_v1);

    // Embedder injects `workgroup-size = 16`; `numberEval` resolves the free
    // variable in `(* workgroup-size 1)`, so the lowered descriptor carries 16.
    const bindings = [_]Expr.Env.Binding{.{ .name = "workgroup-size", .value = .{ .number = 16 } }};
    const env: Expr.Env = .{ .bindings = &bindings };

    var r = try Host.validateDocument(a, EVAL_ENV_SRC, .{ .lowering_registry = &registry, .lowering_env = &env });
    defer r.deinit();

    for (r.diagnostics) |d| {
        if (d.severity != .err) continue;
        std.debug.print("\nunexpected err: phase={s} code={s}\n", .{ @tagName(d.phase), @tagName(d.code) });
    }
    try std.testing.expect(!r.hasErrors());

    const lt = r.lowered_tree orelse return error.TestNoLoweredTree;
    try std.testing.expectEqual(@as(usize, 1), lt.root.len);
    const hdr = lt.formHeader(lt.root[0]);
    try std.testing.expectEqualStrings("descriptor", hdr.head);

    // The lowered `(descriptor :count <n>)` carries the evaluated 16.
    var count: ?f64 = null;
    for (hdr.children) |child| {
        if (lt.tagOf(child) != .kvpair) continue;
        const kvh = lt.kvpairHeader(child);
        if (!std.mem.eql(u8, kvh.key, "count")) continue;
        count = lt.numberOf(kvh.value);
    }
    try std.testing.expectEqual(@as(f64, 16), count orelse return error.TestNoCount);
}

test "D8-lowering: default empty lowering_env leaves a free variable unbound → lowering_hook_failed" {
    const a = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    try registry.register(a, Lowering_test_hooks.test_eval_env_v1);

    // No `lowering_env` → the default empty env → `workgroup-size` is unbound,
    // `numberEval` raises UnknownBinding → HookFailed → one `lowering_hook_failed`
    // stamped at phase `.lowering`. The env is the only difference from the test
    // above, so this isolates it as the cause.
    var r = try Host.validateDocument(a, EVAL_ENV_SRC, .{ .lowering_registry = &registry });
    defer r.deinit();

    var saw_hook_failed = false;
    for (r.diagnostics) |d| {
        if (d.code == .lowering_hook_failed and d.phase == .lowering) saw_hook_failed = true;
    }
    try std.testing.expect(saw_hook_failed);
}

test "D8-lowering: nested-lowerable lint fires on a hook's emitted output one staging layer down" {
    // The nested-lowerable lint observes *emitted* structure, not just author
    // source. `seed` lowers via test/nest-emit-v1 to `(wrap (leaf))` — both
    // declared lowerable — so the contradiction is constructed by the hook and
    // only materializes when the Host feeds that lowered tree back into the
    // pass (layer 1). The source `(seed)` is childless and clean; the diagnostic
    // surfaces against `leaf` a layer down. Emergent but correct: a hook author
    // emitting a contradictory nested structure earns the same warning a source
    // author would. This is a characterization — pin it, don't "fix" it.
    const a = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    try registry.register(a, Lowering_test_hooks.test_nest_emit_v1);
    try registry.register(a, Lowering_test_hooks.test_identity_v1);

    const src: [:0]const u8 =
        \\(plugin :name nest :version "1.0.0"
        \\  (form :name seed :open true
        \\    :lowering (lowering :hook test/nest-emit-v1 :produces [wrap leaf]))
        \\  (form :name wrap :open true
        \\    :lowering (lowering :hook test/identity-v1 :produces [wrap-normal]))
        \\  (form :name leaf :open true
        \\    :lowering (lowering :hook test/identity-v1 :produces [leaf-normal]))
        \\  (form :name wrap-normal :open true)
        \\  (form :name leaf-normal :open true))
        \\(seed)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{ .lowering_registry = &registry });
    defer r.deinit();

    // Exactly one nested-lowerable diagnostic, against the emitted `leaf`.
    var nested_count: usize = 0;
    for (r.diagnostics) |d| {
        if (d.code != .lowering_nested_lowerable) continue;
        nested_count += 1;
        try std.testing.expectEqual(@as(usize, 2), d.path.len);
        try std.testing.expectEqualStrings("leaf", d.path[0]);
        try std.testing.expectEqualStrings("lowering", d.path[1]);
    }
    try std.testing.expectEqual(@as(usize, 1), nested_count);

    // Staging ran to completion and produced a terminal tree.
    try std.testing.expect(r.lowered_tree != null);
}

test "D8-lowering: provenance lets re-validation diagnostic trace back to source span" {
    const a = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    try registry.register(a, Lowering_test_hooks.test_identity_v1);

    // sugar.a is number; sugar-normal.a is string. The hook copies the
    // number into the lowered form, where the type clash trips
    // wrong_underlying. The diagnostic's span must point back into the
    // source `(sugar :a 1)` — the lowered tree was built with spans
    // inherited from the source form.
    const src: [:0]const u8 =
        \\(plugin :name probe :version "1.0.0"
        \\  (form :name sugar
        \\    (key :name a :type number)
        \\    :lowering (lowering :hook test/identity-v1 :produces [sugar-normal]))
        \\  (form :name sugar-normal
        \\    (key :name a :type string)))
        \\(sugar :a 1)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{ .lowering_registry = &registry });
    defer r.deinit();

    // Find the wrong_underlying diagnostic on the lowered tree.
    var saw_wu = false;
    var wu_span: Ast.Span = .{ .start = 0, .end = 0 };
    for (r.diagnostics) |d| {
        if (d.code == .wrong_underlying) {
            saw_wu = true;
            wu_span = d.span;
        }
    }
    try std.testing.expect(saw_wu);

    // The diagnostic span must be contained within the source `(sugar
    // :a 1)` form's span — that's the inherited-span guarantee.
    var source_form_idx: ?Ast.NodeIndex = null;
    for (r.data_forest) |idx| {
        if (r.tree.tagOf(idx) == .form) {
            const hdr = r.tree.formHeader(idx);
            if (std.mem.eql(u8, hdr.head, "sugar")) source_form_idx = idx;
        }
    }
    const sf = source_form_idx orelse return error.TestNoSugarForm;
    const source_span = r.tree.spanOf(sf);
    try std.testing.expect(wu_span.start >= source_span.start);
    try std.testing.expect(wu_span.end <= source_span.end);
}

test "D8-v2: cross-tree ref resolves clean; missing target's span points at source `(origin …)`" {
    // The forest pass spans source ↔ lowered trees. A source-tree
    // `(origin :ref X)` resolves against a lowered `(sugar-normal
    // :name X)` produced by the hook. With v2 this is clean. Swap
    // the ref to a non-existent name and the validator emits
    // `not_cross_ref` whose span points at the source `(origin …)`
    // — NOT at the lowered tree — because the diagnostic is emitted
    // against the source-tree node that authored the bad reference.
    const a = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    try registry.register(a, Lowering_test_hooks.test_identity_v1);

    // Negative: ref points at a name no form declares.
    const src_bad: [:0]const u8 =
        \\(plugin :name probe :version "1.0.0"
        \\  (value-kind :name target-ref :underlying symbol
        \\    :cross-ref (cross-ref :target sugar-normal))
        \\  (form :name sugar
        \\    (key :name name :type symbol :optional false)
        \\    :lowering (lowering :hook test/identity-v1 :produces [sugar-normal]))
        \\  (form :name sugar-normal
        \\    (key :name name :type symbol :optional false))
        \\  (form :name origin
        \\    (key :name ref :type target-ref :optional false)))
        \\(sugar :name lowered-one)
        \\(origin :ref nowhere)
        \\
    ;
    var r_bad = try Host.validateDocument(a, src_bad, .{ .lowering_registry = &registry });
    defer r_bad.deinit();

    var saw_not_cross_ref = false;
    var ncr_span: Ast.Span = .{ .start = 0, .end = 0 };
    for (r_bad.diagnostics) |d| {
        if (d.code == .not_cross_ref) {
            saw_not_cross_ref = true;
            ncr_span = d.span;
        }
    }
    try std.testing.expect(saw_not_cross_ref);

    // Find the `(origin …)` form's span in the source tree and
    // confirm the diagnostic anchors within it.
    var origin_idx: ?Ast.NodeIndex = null;
    for (r_bad.data_forest) |idx| {
        if (r_bad.tree.tagOf(idx) == .form) {
            const hdr = r_bad.tree.formHeader(idx);
            if (std.mem.eql(u8, hdr.head, "origin")) origin_idx = idx;
        }
    }
    const oi = origin_idx orelse return error.TestNoOriginForm;
    const origin_span = r_bad.tree.spanOf(oi);
    try std.testing.expect(ncr_span.start >= origin_span.start);
    try std.testing.expect(ncr_span.end <= origin_span.end);

    // Positive: same shape, ref points at the lowered name → clean.
    const src_good: [:0]const u8 =
        \\(plugin :name probe :version "1.0.0"
        \\  (value-kind :name target-ref :underlying symbol
        \\    :cross-ref (cross-ref :target sugar-normal))
        \\  (form :name sugar
        \\    (key :name name :type symbol :optional false)
        \\    :lowering (lowering :hook test/identity-v1 :produces [sugar-normal]))
        \\  (form :name sugar-normal
        \\    (key :name name :type symbol :optional false))
        \\  (form :name origin
        \\    (key :name ref :type target-ref :optional false)))
        \\(sugar :name lowered-one)
        \\(origin :ref lowered-one)
        \\
    ;
    var r_good = try Host.validateDocument(a, src_good, .{ .lowering_registry = &registry });
    defer r_good.deinit();
    try std.testing.expect(!r_good.hasErrors());
}

test "D8-bundle: provenance traces lowered link diagnostic back to source bundle" {
    const a = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    try registry.register(a, Lowering_test_hooks.test_bundle_v1);

    // bundle emits two forms (asset + link). The link's `:to nowhere`
    // fails forest-wide cross-ref → `not_cross_ref`. Provenance must
    // map that lowered link back to the source `(bundle …)` form.
    const src: [:0]const u8 =
        \\(plugin :name probe :version "1.0.0"
        \\  (value-kind :name target-ref :underlying symbol
        \\    :cross-ref (cross-ref :target target))
        \\  (form :name bundle
        \\    (key :name name :type symbol :optional false)
        \\    (key :name target :type symbol :optional false)
        \\    :lowering (lowering :hook test/bundle-v1 :produces [asset link]))
        \\  (form :name asset
        \\    (key :name name :type symbol :optional false))
        \\  (form :name link
        \\    (key :name from :type symbol :optional false)
        \\    (key :name to :type target-ref :optional false))
        \\  (form :name target
        \\    (key :name name :type symbol :optional false)))
        \\(target :name hero)
        \\(bundle :name main :target nowhere)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{ .lowering_registry = &registry });
    defer r.deinit();

    // Two emitted forms → two provenance entries; both pin the
    // same source bundle. Asset is emitted first, so entries[1] is
    // the link.
    try std.testing.expectEqual(@as(usize, 2), r.lowering_provenance.entries.len);
    try std.testing.expectEqualStrings(
        "test/bundle-v1",
        r.lowering_provenance.entries[1].hook_id,
    );
    const bundle_idx = r.lowering_provenance.entries[1].source_form_idx;
    try std.testing.expectEqual(
        bundle_idx,
        r.lowering_provenance.entries[0].source_form_idx,
    );

    const lt = r.lowered_tree orelse return error.TestNoLoweredTree;
    var saw = false;
    for (r.diagnostics) |d| {
        if (d.code != .not_cross_ref) continue;
        for (lt.root) |lidx| {
            const hdr = lt.formHeader(lidx);
            if (!std.mem.eql(u8, hdr.head, "link")) continue;
            const entry = r.lowering_provenance.lookup(lidx) orelse continue;
            try std.testing.expectEqual(bundle_idx, entry.source_form_idx);
            try std.testing.expectEqualStrings("test/bundle-v1", entry.hook_id);
            saw = true;
        }
    }
    try std.testing.expect(saw);
}

test "D8-lowering: missing hook surfaces lowering_hook_missing under .lowering phase" {
    const a = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    // Deliberately do not register any hook.

    const src: [:0]const u8 =
        \\(plugin :name probe :version "1.0.0"
        \\  (form :name sugar :open true
        \\    :lowering (lowering :hook missing/v1 :produces [normal]))
        \\  (form :name normal :open true))
        \\(sugar :a 1)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{ .lowering_registry = &registry });
    defer r.deinit();

    var saw_missing = false;
    for (r.diagnostics) |d| {
        if (d.code == .lowering_hook_missing) {
            try std.testing.expectEqual(Host.Phase.lowering, d.phase);
            saw_missing = true;
        }
    }
    try std.testing.expect(saw_missing);
    try std.testing.expect(r.lowered_tree == null);
}

// ---------------------------------------------------------------------------
// D8-typed-reads — exercise `input.symbol` / `string` / `number` /
// `boolean` on `LoweringInput`. Tests assert helper return shape
// indirectly via the probe hook's `(echo …)` emission.
// ---------------------------------------------------------------------------

fn findEchoKv(
    lt: Ast.Tree,
    key: []const u8,
) ?Ast.NodeIndex {
    if (lt.root.len == 0) return null;
    const hdr = lt.formHeader(lt.root[0]);
    if (!std.mem.eql(u8, hdr.head, "echo")) return null;
    for (hdr.children) |ch| {
        if (lt.tagOf(ch) != .kvpair) continue;
        const kv = lt.kvpairHeader(ch);
        if (std.mem.eql(u8, kv.key, key)) return kv.value;
    }
    return null;
}

test "D8-typed-reads: author symbol returns text" {
    const a = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    try registry.register(a, Lowering_test_hooks.test_probe_v1);

    const src: [:0]const u8 =
        \\(plugin :name probe :version "1.0.0"
        \\  (form :name probe
        \\    (key :name name :type symbol :optional false)
        \\    :lowering (lowering :hook test/probe-v1 :produces [echo]))
        \\  (form :name echo :open true))
        \\(probe :name hello)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{ .lowering_registry = &registry });
    defer r.deinit();
    try std.testing.expect(!r.hasErrors());

    const lt = r.lowered_tree orelse return error.TestNoLoweredTree;
    const value_idx = findEchoKv(lt, "name") orelse return error.TestMissingNameKv;
    try std.testing.expectEqual(Ast.Tag.symbol, lt.tagOf(value_idx));
    try std.testing.expectEqualStrings("hello", lt.symbolText(value_idx));
}

test "D8-typed-reads: defaulted symbol coerces keyword to symbol" {
    const a = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    try registry.register(a, Lowering_test_hooks.test_probe_v1);

    // Author omits `:name`; schema default fills it with the symbol
    // `hero`. Without the helper's keyword→symbol normalization the
    // probe would either fail or emit a `.keyword` — both observable
    // here via the lowered kvpair's tag check.
    const src: [:0]const u8 =
        \\(plugin :name probe :version "1.0.0"
        \\  (form :name probe
        \\    (key :name name :type symbol :default hero :optional true)
        \\    :lowering (lowering :hook test/probe-v1 :produces [echo]))
        \\  (form :name echo :open true))
        \\(probe)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{ .lowering_registry = &registry });
    defer r.deinit();
    try std.testing.expect(!r.hasErrors());

    const lt = r.lowered_tree orelse return error.TestNoLoweredTree;
    const value_idx = findEchoKv(lt, "name") orelse return error.TestMissingNameKv;
    try std.testing.expectEqual(Ast.Tag.symbol, lt.tagOf(value_idx));
    try std.testing.expectEqualStrings("hero", lt.symbolText(value_idx));
}

test "D8-typed-reads: wrong type returns HookFailed" {
    const a = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    try registry.register(a, Lowering_test_hooks.test_probe_wrong_call_v1);

    // `n` is declared `:type number`; the probe-wrong-call hook reads
    // it via `input.symbol("n")`, which must surface HookFailed.
    const src: [:0]const u8 =
        \\(plugin :name probe :version "1.0.0"
        \\  (form :name probe
        \\    (key :name n :type number :optional false)
        \\    :lowering (lowering :hook test/probe-wrong-call-v1 :produces [echo]))
        \\  (form :name echo :open true))
        \\(probe :n 42)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{ .lowering_registry = &registry });
    defer r.deinit();

    var saw_failed = false;
    for (r.diagnostics) |d| {
        if (d.code == .lowering_hook_failed) saw_failed = true;
    }
    try std.testing.expect(saw_failed);
    try std.testing.expect(r.lowered_tree == null);
}

test "D8-typed-reads: missing optional key returns null" {
    const a = std.testing.allocator;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    try registry.register(a, Lowering_test_hooks.test_probe_v1);

    // Author omits `:extra`; no default. The probe hook's
    // `input.symbol("extra")` returns null, so the emitted `(echo)`
    // has no `:extra` kvpair.
    const src: [:0]const u8 =
        \\(plugin :name probe :version "1.0.0"
        \\  (form :name probe
        \\    (key :name extra :type symbol :optional true)
        \\    :lowering (lowering :hook test/probe-v1 :produces [echo]))
        \\  (form :name echo :open true))
        \\(probe)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{ .lowering_registry = &registry });
    defer r.deinit();
    try std.testing.expect(!r.hasErrors());

    const lt = r.lowered_tree orelse return error.TestNoLoweredTree;
    try std.testing.expect(findEchoKv(lt, "extra") == null);
}

// ---------------------------------------------------------------------------
// Host.evalExpr coverage
// ---------------------------------------------------------------------------

test "evalExpr: core arithmetic returns a number value" {
    const a = std.testing.allocator;
    const src: [:0]const u8 = "(+ 1 2 3)\n";
    var r = try Host.evalExpr(a, src, .{});
    defer r.deinit();

    try std.testing.expect(!r.hasErrors());
    const v = r.value orelse return error.TestNoValue;
    try std.testing.expectEqual(@as(f64, 6.0), v.toF64().?);
}

test "evalExpr: NoExpression on document with no data forest form" {
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\(plugin :name solo :version "1.0.0"
        \\  (form :name w (key :name name :type symbol :optional false)))
        \\
    ;
    try std.testing.expectError(error.NoExpression, Host.evalExpr(a, src, .{}));
}

test "evalExpr: MultipleExpressions on more than one data form" {
    const a = std.testing.allocator;
    const src: [:0]const u8 = "(+ 1 2) (* 3 4)\n";
    try std.testing.expectError(error.MultipleExpressions, Host.evalExpr(a, src, .{}));
}

test "evalExpr: unknown function evaluates as Value.form (v2 form-as-data)" {
    // v2 semantic flip: unknown form heads no longer error — they pass
    // through as Value.form so plugin expr-funcs can receive form
    // literals as arguments. The host surfaces the form on `.value`
    // and emits no validation diagnostic.
    const a = std.testing.allocator;
    const src: [:0]const u8 = "(no-such-func 1 2)\n";
    var r = try Host.evalExpr(a, src, .{});
    defer r.deinit();

    try std.testing.expect(!r.hasErrors());
    const v = r.value orelse return error.TestNoValue;
    try std.testing.expect(v == .form);
    try std.testing.expectEqualStrings("no-such-func", v.form.head);
    try std.testing.expectEqual(@as(usize, 2), v.form.children.len);
    try std.testing.expectEqual(@as(f64, 1.0), v.form.children[0].toF64().?);
    try std.testing.expectEqual(@as(f64, 2.0), v.form.children[1].toF64().?);
}

test "evalExpr: inline plugin manifest aggregates schema before eval" {
    // Inline-declared plugin contributes a (form …) but no expr-func;
    // the trailing data-form is a core expression that still evaluates
    // — confirms the prep pipeline runs the manifest-load phase even
    // when the expression doesn't need the plugin's funcs.
    const a = std.testing.allocator;
    const src: [:0]const u8 =
        \\(plugin :name probe :version "1.0.0"
        \\  (form :name w (key :name name :type symbol :optional false)))
        \\
        \\(/ 10 4)
        \\
    ;
    var r = try Host.evalExpr(a, src, .{});
    defer r.deinit();
    try std.testing.expect(!r.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), r.plugins.len);
    const v = r.value orelse return error.TestNoValue;
    try std.testing.expectEqual(@as(f64, 2.5), v.toF64().?);
}

// ----------------------------------------------------------------------
// loadProject — workspace-scoped eager plugin loading.
// ----------------------------------------------------------------------

fn tmpRootPath(a: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{sub_path});
}

test "loadProject: no project root → core-only schema, no diagnostics" {
    const a = std.testing.allocator;
    var r = try Host.loadProject(a, .{});
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 0), r.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), r.plugins.len); // core
    try std.testing.expectEqual(@as(usize, 0), r.plugin_results.len);
    try std.testing.expectEqual(@as(?[:0]const u8, null), r.project_source);
    try std.testing.expectEqual(@as(?[]const u8, null), r.project_uri);
}

test "loadProject: project file with one valid manifest → core + plugin" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(a, &tmp.sub_path);
    defer a.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "shapes.sjon",
        .data = "(plugin :name shapes :version \"1.0.0\")",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(project :plugins [\"shapes.sjon\"])",
    });

    var r = try Host.loadProject(a, .{
        .project_root = root,
        .io = std.testing.io,
    });
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 0), r.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 2), r.plugins.len); // core + shapes
    try std.testing.expectEqual(@as(usize, 1), r.plugin_results.len);
    try std.testing.expectEqualStrings("shapes", r.plugins[1].name);
    try std.testing.expect(r.project_source != null);
    try std.testing.expect(r.project_uri != null);
    try std.testing.expect(std.mem.startsWith(u8, r.project_uri.?, "file://"));
}

test "loadProject: missing project file → no project_source, no fatal diagnostic" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(a, &tmp.sub_path);
    defer a.free(root);
    // Deliberately do NOT write sjon-project.sjon.

    var r = try Host.loadProject(a, .{
        .project_root = root,
        .io = std.testing.io,
    });
    defer r.deinit();

    // FilesystemResolver currently swallows a missing project file as a
    // diagnostic (`invalid_manifest`, "could not read project file …").
    // The resolver still works for explicit `:path` references but
    // loadProject's eager path indexes nothing.
    try std.testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try std.testing.expectEqual(Ast.Diagnostic.Code.invalid_manifest, r.diagnostics[0].code);
    try std.testing.expectEqual(@as(usize, 1), r.plugins.len); // core only
    try std.testing.expectEqual(@as(?[:0]const u8, null), r.project_source);
}

test "loadProject: malformed project file (non-project root) → invalid_manifest" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(a, &tmp.sub_path);
    defer a.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(not-project :plugins [])",
    });

    var r = try Host.loadProject(a, .{
        .project_root = root,
        .io = std.testing.io,
    });
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try std.testing.expectEqual(Ast.Diagnostic.Code.invalid_manifest, r.diagnostics[0].code);
    try std.testing.expectEqual(@as(usize, 1), r.plugins.len); // core only
    // The project file *did* exist and was read, even though its root
    // form was rejected — so project_source is populated.
    try std.testing.expect(r.project_source != null);
}

test "loadProject: manifest path that does not exist → invalid_manifest, partial load" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(a, &tmp.sub_path);
    defer a.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "ok.sjon",
        .data = "(plugin :name ok :version \"1.0.0\")",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(project :plugins [\"missing.sjon\" \"ok.sjon\"])",
    });

    var r = try Host.loadProject(a, .{
        .project_root = root,
        .io = std.testing.io,
    });
    defer r.deinit();

    // The good manifest still loads; the bad one becomes a diagnostic.
    try std.testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try std.testing.expectEqual(Ast.Diagnostic.Code.invalid_manifest, r.diagnostics[0].code);
    try std.testing.expectEqual(@as(usize, 2), r.plugins.len); // core + ok
    try std.testing.expectEqualStrings("ok", r.plugins[1].name);
}

test "loadProject: hasErrors fires when any diagnostic carries err severity" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(a, &tmp.sub_path);
    defer a.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(not-project :plugins [])",
    });

    var r = try Host.loadProject(a, .{
        .project_root = root,
        .io = std.testing.io,
    });
    defer r.deinit();

    try std.testing.expect(r.hasErrors());
}

test "loadProject: a project plugin's sidecar registers into a project-owned runtime" {
    if (!build_options.plugin_exec) return;
    const a = std.testing.allocator;

    // The corpus fixture rather than a synthetic tmp dir: `lines.wasm` is
    // committed next to its manifest, so this drives exactly the bytes the
    // conformance runner drives. A project load that quietly stopped
    // fetching sidecars would go red here, one layer below the host
    // boundary where the corpus would eventually catch it.
    var r = try Host.loadProject(a, .{
        .project_root = "conformance/cases/cross-ref-provider-resolved",
        .io = std.testing.io,
    });
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 0), r.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 2), r.plugins.len); // core + lines
    try std.testing.expectEqualStrings("lines", r.plugins[1].name);
    try std.testing.expect(r.runtime != null);
    try std.testing.expect(r.runtimeContext() != null);
}

test "loadProject: a declarative-only project builds no runtime at all" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(a, &tmp.sub_path);
    defer a.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "shapes.sjon",
        .data = "(plugin :name shapes :version \"1.0.0\")",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(project :plugins [\"shapes.sjon\"])",
    });

    var r = try Host.loadProject(a, .{
        .project_root = root,
        .io = std.testing.io,
    });
    defer r.deinit();

    // No sidecar next to the manifest, so nothing to register — and a
    // wasmtime engine that is never constructed is the point: every
    // project that predates executable plugins pays nothing.
    try std.testing.expectEqual(@as(usize, 2), r.plugins.len);
    try std.testing.expect(r.runtime == null);
    try std.testing.expectEqual(@as(?*anyopaque, null), r.runtimeContext());
}

test "loadProject: a rejected sidecar diagnoses but keeps the plugin" {
    if (!build_options.plugin_exec) return;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(a, &tmp.sub_path);
    defer a.free(root);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "shapes.sjon",
        .data = "(plugin :name shapes :version \"1.0.0\")",
    });
    // Flat-vendor pairing: `<stem>.sjon` next to `<stem>.wasm`. The bytes
    // are not a wasm module at all, so pre-flight refuses them.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "shapes.wasm",
        .data = "fake-wasm",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(project :plugins [\"shapes.sjon\"])",
    });

    var r = try Host.loadProject(a, .{
        .project_root = root,
        .io = std.testing.io,
    });
    defer r.deinit();

    // The divergence from the document path, pinned: `validateDocument`
    // pops a plugin whose sidecar pre-flight rejects, because it is about
    // to evaluate against it. Project load keeps it — an editor that lost
    // every form in the workspace over a half-written sidecar would be
    // useless exactly when it is needed.
    try std.testing.expect(r.hasErrors());
    try std.testing.expectEqual(@as(usize, 2), r.plugins.len);
    try std.testing.expectEqualStrings("shapes", r.plugins[1].name);

    var saw = false;
    for (r.diagnostics) |d| if (d.severity == .err) {
        try std.testing.expectEqual(Host.Phase.manifest, d.phase);
        // The manifest path is the anchor: there is no `(use-plugin …)`
        // reference at project-load time to point a span at.
        try std.testing.expect(std.mem.indexOf(u8, d.message, "shapes.sjon") != null);
        saw = true;
    };
    try std.testing.expect(saw);
}

// ---------------------------------------------------------------------------
// preloaded schema (F9) — HostOptions.preloaded threads a PreloadedSchema
// into the shared prepareDocument spine. Preloaded plugins are additive with
// inline (plugin …) / (use-plugin …); the document-time diagnostics stay
// document-local (no prefix rebasing), and plugin_results stays document-only
// so deinit never touches a borrowed preloaded arena.
// ---------------------------------------------------------------------------

/// Every diagnostic span on a HostResult must index within the document
/// source — the property that makes preloaded-schema diagnostics need no
/// prefix rebasing. Preload-phase (manifest / aggregate) diagnostics never
/// reach a HostResult (they live on PreloadedSchema), so all of these are
/// document-local by construction.
fn assertSpansWithin(r: *const Host.HostResult, len: usize) !void {
    for (r.diagnostics) |d| {
        try std.testing.expect(d.span.start <= len);
        try std.testing.expect(d.span.end <= len);
    }
}

test "preloaded: one schema validates many documents with document-local spans" {
    const a = std.testing.allocator;
    const schema_sources = [_][:0]const u8{
        \\(plugin :name shapes :version "1.0.0"
        \\  (form :name circle
        \\    (key :name r :type number :optional false)))
        ,
    };
    var pre = try Host.preloadSchema(a, &schema_sources);
    defer pre.deinit();
    try std.testing.expect(!pre.hasErrors());

    // Doc 1 — valid use of the preloaded form → no diagnostics.
    {
        const doc: [:0]const u8 = "(circle :r 5)\n";
        var r = try Host.validateDocument(a, doc, .{ .preloaded = &pre });
        defer r.deinit();
        try std.testing.expect(!r.hasErrors());
        try assertSpansWithin(&r, doc.len);
    }
    // Doc 2 — missing required key → a validation error, span in THIS doc.
    {
        const doc: [:0]const u8 = "(circle)\n";
        var r = try Host.validateDocument(a, doc, .{ .preloaded = &pre });
        defer r.deinit();
        try std.testing.expect(r.hasErrors());
        try assertSpansWithin(&r, doc.len);
    }
    // Doc 3 — unknown key → a validation error, span in THIS doc.
    {
        const doc: [:0]const u8 = "(circle :r 5 :bogus 1)\n";
        var r = try Host.validateDocument(a, doc, .{ .preloaded = &pre });
        defer r.deinit();
        try std.testing.expect(r.hasErrors());
        try assertSpansWithin(&r, doc.len);
    }
}

test "preloaded: inline (plugin …) composes additively with the preloaded set" {
    const a = std.testing.allocator;
    const schema_sources = [_][:0]const u8{
        \\(plugin :name shapes :version "1.0.0"
        \\  (form :name circle (key :name r :type number :optional false)))
        ,
    };
    var pre = try Host.preloadSchema(a, &schema_sources);
    defer pre.deinit();

    // The document declares its own plugin AND uses a preloaded form.
    const doc: [:0]const u8 =
        \\(plugin :name extras :version "1.0.0"
        \\  (form :name square (key :name side :type number :optional false)))
        \\(circle :r 5)
        \\(square :side 4)
        \\
    ;
    var r = try Host.validateDocument(a, doc, .{ .preloaded = &pre });
    defer r.deinit();

    try std.testing.expect(!r.hasErrors());
    // Public schema = preloaded (shapes) ++ document-loaded (extras).
    try std.testing.expectEqual(@as(usize, 2), r.plugins.len);
    try std.testing.expectEqualStrings("shapes", r.plugins[0].name);
    try std.testing.expectEqualStrings("extras", r.plugins[1].name);
    // plugin_results is DOCUMENT-ONLY (preloaded arenas are borrowed) — the
    // suffix-only alias invariant.
    try std.testing.expectEqual(@as(usize, 1), r.plugin_results.len);
    try std.testing.expectEqualStrings("extras", r.plugin_results[0].plugin.name);
}

test "preloaded: (use-plugin …) resolves alongside a preloaded schema" {
    const a = std.testing.allocator;
    const schema_sources = [_][:0]const u8{
        \\(plugin :name shapes :version "1.0.0"
        \\  (form :name circle (key :name r :type number :optional false)))
        ,
    };
    var pre = try Host.preloadSchema(a, &schema_sources);
    defer pre.deinit();

    var mock = MockResolver{ .response = .{ .manifest = .{
        .source =
        \\(plugin :name extras :version "1.0.0"
        \\  (form :name square (key :name side :type number :optional false)))
        ,
        .wasm = null,
    } } };

    const doc: [:0]const u8 =
        \\(use-plugin "extras")
        \\(circle :r 5)
        \\(square :side 4)
        \\
    ;
    var r = try Host.validateDocument(a, doc, .{ .preloaded = &pre, .resolver = mock.handle() });
    defer r.deinit();

    try std.testing.expect(!r.hasErrors());
    try std.testing.expectEqual(@as(u32, 1), mock.served);
    // shapes (preloaded) ++ extras (resolved via use-plugin).
    try std.testing.expectEqual(@as(usize, 2), r.plugins.len);
    try std.testing.expectEqualStrings("shapes", r.plugins[0].name);
    try std.testing.expectEqualStrings("extras", r.plugins[1].name);
    try std.testing.expectEqual(@as(usize, 1), r.plugin_results.len); // document-only
}

test "preloaded: defaults materialize from a preloaded :default" {
    const a = std.testing.allocator;
    const schema_sources = [_][:0]const u8{
        \\(plugin :name p :version "1.0.0"
        \\  (form :name scene (key :name fps :type number :default 60)))
        ,
    };
    var pre = try Host.preloadSchema(a, &schema_sources);
    defer pre.deinit();

    const doc: [:0]const u8 = "(scene)\n";
    var r = try Host.validateDocument(a, doc, .{ .preloaded = &pre });
    defer r.deinit();

    try std.testing.expect(!r.hasErrors());
    const form_idx = firstDataForm(&r) orelse return error.TestNoDataForm;
    const entry = r.materialized_defaults.defaultFor(form_idx, "fps") orelse
        return error.TestMissingDefaultEntry;
    try std.testing.expectEqual(@as(f64, 60), entry.value.toF64().?);
}

test "preloaded: evalExpr resolves a preloaded expr-func (shared prepareDocument)" {
    const a = std.testing.allocator;
    const schema_sources = [_][:0]const u8{
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name nope :arity (fixed 0) :result number))
        ,
    };
    var pre = try Host.preloadSchema(a, &schema_sources);
    defer pre.deinit();

    // `(nope)` is a preloaded expr-func with no impl. On native it RESOLVES
    // (proving preloaded threads through evalExpr's shared prepareDocument),
    // then fails to execute — surfacing plugin_func_failed, never unknown_form.
    const doc: [:0]const u8 = "(nope)\n";
    var r = try Host.evalExpr(a, doc, .{ .preloaded = &pre });
    defer r.deinit();

    // The preloaded plugin is in evalExpr's result view (load-bearing proof).
    try std.testing.expectEqual(@as(usize, 1), r.plugins.len);
    try std.testing.expectEqualStrings("p", r.plugins[0].name);
    // Resolution succeeded — the failure is exec-time, not an unknown head.
    for (r.diagnostics) |d| {
        try std.testing.expect(d.code != .unknown_form);
    }
}

test "preloaded: a document error surfaces only validation-phase diagnostics" {
    const a = std.testing.allocator;
    const schema_sources = [_][:0]const u8{
        \\(plugin :name shapes :version "1.0.0"
        \\  (form :name circle (key :name r :type number :optional false)))
        ,
    };
    var pre = try Host.preloadSchema(a, &schema_sources);
    defer pre.deinit();

    // Missing required key → a validation error. No inline plugin and no
    // document-added plugin, so no manifest/aggregate diagnostics reach the
    // HostResult — the preload-phase diagnostics stay on PreloadedSchema.
    const doc: [:0]const u8 = "(circle)\n";
    var r = try Host.validateDocument(a, doc, .{ .preloaded = &pre });
    defer r.deinit();

    try std.testing.expect(r.hasErrors());
    var saw_validation = false;
    for (r.diagnostics) |d| {
        try std.testing.expectEqual(Host.Phase.validation, d.phase);
        saw_validation = true;
    }
    try std.testing.expect(saw_validation);
}

// ---------------------------------------------------------------------------
// Evaluated-results surfacing: `runEvalPass` records each top-level
// expr-func evaluation onto `HostResult.evaluated_results`, deep-copying
// the value into the host arena so it outlives the per-eval arena.
//
// `Host.validateDocument` keeps `core` out of its *public* schema
// (`HostResult.schema` / `.plugins` are user-only) but does prepend it to
// the `eval_schema` this pass dispatches through, so top-level `(+ …)` /
// `(clamp …)` do evaluate here — `sjon eval` is exactly this path.
// ---------------------------------------------------------------------------

test "evaluated_results: non-expr-func data forms record nothing" {
    const a = std.testing.allocator;
    var r = try Host.validateDocument(a, SRC_CLEAN_INLINE, .{});
    defer r.deinit();

    try std.testing.expect(!r.hasErrors());
    try std.testing.expectEqual(@as(usize, 0), r.evaluated_results.len);
}

test "evaluated_results: declared wasm-impl on Zig native records no value" {
    const a = std.testing.allocator;
    // Declared but-unimplemented expr-func on Zig native (no wasm
    // runtime) — `Expr.eval` returns `PluginFuncNotImplemented`, which
    // `runEvalPass` swallows without emitting a fresh diagnostic and
    // without appending to `evaluated_results`. The same fixture
    // (plugin-exec-double-eval) hits the success path on Web/Rust hosts.
    const src: [:0]const u8 =
        \\(plugin :name p :version "1.0.0"
        \\  (expr-func :name unwired :arity (fixed 0) :result number :impl "wasm:unwired"))
        \\(unwired)
        \\
    ;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 0), r.evaluated_results.len);
    // …and no diagnostic either: this is the documented "declarative-only
    // on Zig native" deferral, one of the two classes `runEvalPass` still
    // swallows unconditionally.
    try std.testing.expect(!r.hasErrors());
}

// ---------------------------------------------------------------------------
// Runtime domain errors. `runEvalPass` used to drop every non-plugin
// `Expr.Error` on the claim that the validator had already emitted a
// matching diagnostic. That holds for `UnknownFunction` / `ArityMismatch`
// and fails for exactly the class the validator cannot see: a failure
// that depends on the *computed values*, not the declared types. So an
// inverted `clamp` range, an out-of-range `nth`, a zero-length
// `normalize` and a division by zero all evaluated to silence and exit 0.
//
// The rule is now checked rather than asserted — report unless an error
// is already anchored inside the same top-level form — which is what
// makes the original comment's claim true instead of hopeful.
// ---------------------------------------------------------------------------

fn expectOneEvalDiagnostic(src: [:0]const u8, code: Ast.Diagnostic.Code) !void {
    const a = std.testing.allocator;
    var r = try Host.validateDocument(a, src, .{});
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try std.testing.expectEqual(code, r.diagnostics[0].code);
    try std.testing.expectEqual(Ast.Diagnostic.Severity.err, r.diagnostics[0].severity);
    // The failing form yields no value — the diagnostic replaces it
    // rather than accompanying it.
    try std.testing.expectEqual(@as(usize, 0), r.evaluated_results.len);
}

test "runEvalPass: value-domain failures report instead of vanishing" {
    // Each of these type-checks statically: the validator sees numbers and
    // vectors where numbers and vectors are declared, and has no way to
    // know that lo > hi, that the index is past the end, or that the
    // vector's length is zero.
    try expectOneEvalDiagnostic("(clamp 5.0 10.0 0.0)\n", .expr_type_mismatch);
    try expectOneEvalDiagnostic("(nth [1 2 3] 9)\n", .expr_type_mismatch);
    try expectOneEvalDiagnostic("(normalize [0.0 0.0])\n", .expr_type_mismatch);
    try expectOneEvalDiagnostic("(rand-range 1.0 2.0 5.0 0.0)\n", .expr_type_mismatch);
    try expectOneEvalDiagnostic("(reflect [1.0 2.0] [1.0 2.0 3.0])\n", .expr_type_mismatch);
    try expectOneEvalDiagnostic("(/ 1.0 0.0)\n", .expr_type_mismatch);
    try expectOneEvalDiagnostic("(mod 1.0 0.0)\n", .expr_type_mismatch);
}

test "runEvalPass: a statically-caught mismatch is not reported twice" {
    const a = std.testing.allocator;
    // `(sqrt "x")` fails in *both* phases — the validator on the declared
    // argument type, then the evaluator on the same argument. Without the
    // already-reported check every statically-typed mismatch would
    // double-report; with it, the validator's entry stands alone because
    // it is anchored inside the form's extent.
    var r = try Host.validateDocument(a, "(sqrt \"x\")\n", .{});
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try std.testing.expectEqual(Ast.Diagnostic.Code.expr_type_mismatch, r.diagnostics[0].code);
    // The surviving entry is the validator's, not the eval pass's: it
    // carries the argument path the eval pass has no way to build.
    try std.testing.expectEqual(@as(usize, 2), r.diagnostics[0].path.len);
}

test "runEvalPass: a reported failure costs one result, not the run" {
    const a = std.testing.allocator;
    var r = try Host.validateDocument(a, "(clamp 5.0 10.0 0.0)\n(clamp 5.0 0.0 10.0)\n", .{});
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), r.evaluated_results.len);
    // The survivor is form 1, and it evaluated correctly.
    try std.testing.expectEqual(@as(usize, 1), r.evaluated_results[0].forest_index);
    try std.testing.expectEqual(@as(f64, 5.0), r.evaluated_results[0].value.toF64().?);
}

test "runEvalPass: the deepest parseable expression still evaluates" {
    const a = std.testing.allocator;
    // The other half of the (c) arm's justification: it is not merely a
    // policy, it is unreachable from here. `Expr.MAX_FRAMES` equals
    // `Parser.MAX_PARSE_DEPTH`, so a document deep enough to exhaust the
    // evaluator's frame stack is rejected by the parser first — one short
    // of that ceiling evaluates cleanly. This pins the equality: if
    // `MAX_FRAMES` is ever lowered, the (c) arm becomes live and this
    // goes red rather than the arm silently starting to swallow real
    // failures.
    try std.testing.expectEqual(@as(u32, 1024), Expr.MAX_FRAMES);

    const depth = Expr.MAX_FRAMES - 1;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    for (0..depth) |_| try src.appendSlice(a, "(* 2 ");
    try src.append(a, '1');
    for (0..depth) |_| try src.append(a, ')');
    try src.append(a, '\n');
    const z = try src.toOwnedSliceSentinel(a, 0);
    defer a.free(z);

    var r = try Host.validateDocument(a, z, .{});
    defer r.deinit();
    try std.testing.expect(!r.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), r.evaluated_results.len);
}

// ---------------------------------------------------------------------------
// Staged lowering — backstops + span chaining (D8-staging). These drive
// `Host.validateDocument` with a real lowering registry, exercising the
// multi-layer loop the conformance corpus also covers.
// ---------------------------------------------------------------------------

fn appendChainName(a: std.mem.Allocator, buf: *std.ArrayList(u8), i: usize) !void {
    // The identity hook emits `<head>-normal`, so the form chained `i`
    // layers deep is `s` followed by `i` copies of `-normal`.
    try buf.appendSlice(a, "s");
    var k: usize = 0;
    while (k < i) : (k += 1) try buf.appendSlice(a, "-normal");
}

test "lowering staging: a chain deeper than MAX_LOWERING_STAGES trips lowering_output_too_large" {
    const a = std.testing.allocator;
    const stages = Lowering.MAX_LOWERING_STAGES;

    // Build a manifest whose forms chain `s -> s-normal -> ...` via the
    // identity hook. Forms 0..stages-1 are lowerable (each produces the
    // next); form `stages` is terminal. Every head is distinct, so the
    // chain is acyclic — the static cycle check passes and the runtime
    // stage cap is the backstop that stops it.
    var src_buf: std.ArrayList(u8) = .empty;
    defer src_buf.deinit(a);
    try src_buf.appendSlice(a, "(plugin :name chain :version \"1.0.0\"\n");
    var i: usize = 0;
    while (i <= stages) : (i += 1) {
        try src_buf.appendSlice(a, "  (form :name ");
        try appendChainName(a, &src_buf, i);
        if (i < stages) {
            try src_buf.appendSlice(a, " :open true :lowering (lowering :hook test/identity-v1 :produces [");
            try appendChainName(a, &src_buf, i + 1);
            try src_buf.appendSlice(a, "]))\n");
        } else {
            try src_buf.appendSlice(a, " :open true)\n");
        }
    }
    try src_buf.appendSlice(a, ")\n(s)\n");
    try src_buf.append(a, 0);
    const src: [:0]const u8 = src_buf.items[0 .. src_buf.items.len - 1 :0];

    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    try registry.register(a, Lowering_test_hooks.test_identity_v1);

    var r = try Host.validateDocument(a, src, .{ .lowering_registry = &registry });
    defer r.deinit();

    var saw_too_large = false;
    var saw_cycle = false;
    for (r.diagnostics) |d| {
        if (d.code == .lowering_output_too_large) saw_too_large = true;
        if (d.code == .lowering_cycle) saw_cycle = true;
    }
    try std.testing.expect(saw_too_large);
    try std.testing.expect(!saw_cycle); // acyclic chain — only the runtime cap fires
}

test "lowering staging: a terminal-form diagnostic's span points at the original surface bytes" {
    const a = std.testing.allocator;
    // a -> a-normal -> a-normal-normal (terminal). a-normal-normal requires
    // `:y`, which the identity hook never carries, so the terminal form
    // surfaces missing_required_key after TWO layers. Its span must chain
    // back through both layers to the source `(a :x 1)` bytes.
    const src: [:0]const u8 =
        \\(plugin :name stage :version "1.0.0"
        \\  (form :name a (key :name x :type number :optional false)
        \\    :lowering (lowering :hook test/identity-v1 :produces [a-normal]))
        \\  (form :name a-normal (key :name x :type number :optional false)
        \\    :lowering (lowering :hook test/identity-v1 :produces [a-normal-normal]))
        \\  (form :name a-normal-normal
        \\    (key :name x :type number :optional false)
        \\    (key :name y :type number :optional false)))
        \\(a :x 1)
        \\
    ;
    var registry: Lowering.LoweringRegistry = .{};
    defer registry.deinit(a);
    try registry.register(a, Lowering_test_hooks.test_identity_v1);

    var r = try Host.validateDocument(a, src, .{ .lowering_registry = &registry });
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.data_forest.len);
    const source_span = r.tree.spanOf(r.data_forest[0]);

    var found = false;
    for (r.diagnostics) |d| {
        if (d.code == .missing_required_key) {
            found = true;
            // Span chained home: identical to the source form's span, not
            // the manifest, not {0,0}.
            try std.testing.expectEqual(source_span.start, d.span.start);
            try std.testing.expectEqual(source_span.end, d.span.end);
        }
    }
    try std.testing.expect(found);
}

// ---------------------------------------------------------------------
// Provider extraction reaches the validator
//
// `validateDocument` runs the extraction pre-pass and then validates; the
// join between the two is one options field, and a missing one is
// invisible from either side — the pre-pass still ran, the validator
// still validated, and the only trace is that every provider-route source
// looks like an *absent* table entry rather than the answer the pre-pass
// actually recorded.
//
// The two are distinguishable by the message, which is why these assert
// on it: `Extraction.unavailable` carries a reason, an absent entry has
// none. Both paths emit `cross_ref_provider_unavailable`, so a code-only
// assertion here would pass with the table thrown away.
// ---------------------------------------------------------------------

/// A declaration-only provider: legal, and unrunnable on every host, so
/// this needs neither a wasm sidecar nor a plugin runtime.
const provider_doc: [:0]const u8 =
    \\(plugin :name probe :version "1.0.0"
    \\  (cross-ref-provider :name lines :description "One name per line.")
    \\  (form :name shader
    \\    (key :name name :type symbol :optional false)
    \\    (key :name src :type string :optional false))
    \\  (value-kind :name uniform-name
    \\    :underlying symbol
    \\    :cross-ref (cross-ref :target shader :provider lines))
    \\  (form :name bind
    \\    (key :name uniform :type uniform-name :optional false)))
    \\(shader :name main :src "u_time")
    \\(bind :uniform u_time)
    \\
;

test "provider extraction: the pre-pass's answer reaches the validator" {
    const a = std.testing.allocator;

    var r = try Host.validateDocument(a, provider_doc, .{});
    defer r.deinit();

    var found = false;
    for (r.diagnostics) |d| {
        if (d.code != .cross_ref_provider_unavailable) continue;
        found = true;
        // The table said *why*. An absent entry would have produced the
        // same code with the message stopping at `unchecked`.
        try std.testing.expect(std.mem.indexOf(u8, d.message, "nothing to run") != null);
    }
    try std.testing.expect(found);
}

test "provider extraction: an unknown member set is silent, not a miss" {
    // The poisoned-bucket rule, at the host boundary: the reference is
    // neither accepted nor reported. `cross-ref-provider-unavailable`
    // pins the same thing across the four hosts; this is the Zig-side
    // guard that keeps it from regressing between corpus runs.
    const a = std.testing.allocator;

    var r = try Host.validateDocument(a, provider_doc, .{});
    defer r.deinit();

    for (r.diagnostics) |d| try std.testing.expect(d.code != .not_cross_ref);
}
