//! Conformance corpus runner.
//!
//! Two case shapes share `conformance/cases/`. They are mutually
//! exclusive — a case directory may contain exactly one of:
//!
//!   * **Legacy split-file** — `schema.sjon` + `input.sjon` +
//!     `expected.sjon`. Schema is loaded standalone via
//!     `ManifestLoader`; input validates against it. Optional
//!     `extra-*.sjon` siblings each become an additional plugin in
//!     lexical order. Phases: manifest load → `validateCrossRefs` →
//!     input validation. A parallel host-pass runner
//!     (`runLegacyCaseAsHost`) drives the same legacy fixtures through the
//!     F9 two-phase API — `Host.preloadSchema` over the schema + extras,
//!     then `Host.validateDocument(input, .{ .preloaded })` — as a
//!     cross-host parity gate and a preloadSchema dogfood. It compares
//!     `pre.diagnostics ++ hr.diagnostics` (manifest → aggregate →
//!     validation), the same order the old prepend-the-schema-to-the-
//!     document approach produced, with no `prefix_len` span rebasing.
//!
//!   * **Inline-manifest** — `document.sjon` + `expected.sjon`. The
//!     single source declares its plugins inline and uses them in the
//!     same file, driven through `Host.validateDocument`. Phases:
//!     manifest load (per declaration) → all three Schema aggregate
//!     validators → data-forest validation. The runner flattens the
//!     resulting `HostResult.diagnostics` into the comparison list,
//!     ordered manifest → aggregate → validation (matching the legacy
//!     concatenation order).
//!
//! Each entry in `expected.sjon` asserts on `(code, path)`; message
//! prose is deliberately unchecked because it's host-flavoured (see
//! `docs/portable-manifest-v1.md` §10).
//!
//! A value-carrying fixture adds an optional `(values (value :index N
//! :result <lit>))` block asserting on evaluated results. This runner
//! decodes it via `ConformanceExpected.parseExpectedValues` and compares
//! natively through `Expr.Value.equals` — the independent leg. The Web and
//! Rust hosts instead read a generated `expected.values.json` sibling
//! (`tools/gen_expected_values.zig`, `zig build gen-expected-values`),
//! which re-encodes each literal through `wasm_common.appendValue` — the
//! same encoder their evaluated-result envelope uses — and is drift-gated
//! inside `zig build test`.
//!
//! Adding a case: drop a directory under `conformance/cases/` with one
//! shape's files. The runner discovers it automatically. The TypeScript
//! parity harness reads the same corpus and replays all three shapes
//! (legacy, inline-manifest via `validateDocument`, and query via the
//! native pattern walker); being declarative-only by design, it skips the
//! families needing capabilities it doesn't carry — the Expr evaluator
//! (`expr-*`, `pattern-expr-*`), the D7 executable-plugin runtime
//! (`plugin-exec-*`), and the runtime lowering / default-materialization /
//! effective-axis / exclusive-group hooks — leaving those to the Web and
//! Rust hosts, which delegate to the shared `sjon.wasm`.
//!
//! Corpus policy — the legacy split-file shape is **frozen, not
//! deprecated**. The 136 legacy cases stay (they double as F9 preload
//! coverage: `runLegacyCaseAsHost` drives each through the `preloadSchema`
//! API), but a NEW case must use `document.sjon` (inline) or `query.sjon`.
//! The count is pinned by `test "conformance: legacy corpus is frozen at
//! 136 cases"`; a deliberate legacy addition bumps that pin and says why
//! in the commit. Case *classification* data (marker filenames, dispatch
//! precedence, wasm-host skip families) is mirrored as data in
//! `conformance/classifier.json`, which the TS + Rust hosts consume; this
//! runner is the reference and classifies natively (see `discoverCases`).

const std = @import("std");
const build_options = @import("build_options");
const Ast = @import("Ast.zig");
const Parser = @import("Parser.zig");
const Binary = @import("Binary.zig");
const Validator = @import("Validator.zig");
const Schema = @import("Schema.zig");
const ManifestLoader = @import("ManifestLoader.zig");
const Plugin = @import("Plugin.zig");
const Host = @import("Host.zig");
const Lowering = @import("Lowering.zig");
const Lowering_test_hooks = @import("Lowering_test_hooks.zig");
const ConformanceExpected = @import("ConformanceExpected.zig");
const PatternQuery = @import("PatternQuery.zig");
const plugins_core = @import("plugins/core.zig");
const plugins_pattern = @import("plugins/pattern.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// One discovered case: directory name plus which shape applies. The
/// shape gates which runner branch processes the case.
///
///   * `query` — `document.sjon` (a pattern) + `query.sjon`
///     (`(query :window [b e] :seed N)`) + `expected.sjon` (`(haps …)` or
///     `(diagnostics …)`). Driven through `PatternQuery.queryTree`. Probed
///     first in `discoverCases` because a query case also carries
///     `document.sjon`.
const CaseKind = enum { legacy, inline_manifest, query };

const Case = struct {
    name: []u8,
    kind: CaseKind,
};

/// Walk `conformance/cases/` and return the directories that look like
/// cases — those containing exactly one of `schema.sjon` or
/// `document.sjon`. Containing both is a fixture-author bug and surfaces
/// as an error so the disjointness invariant cannot quietly drift.
/// Sorted by name for deterministic failure reporting. Caller owns each
/// entry's `name` and the list itself.
fn discoverCases(a: Allocator, io: Io) !std.ArrayList(Case) {
    var dir = try Io.Dir.cwd().openDir(io, "conformance/cases", .{ .iterate = true });
    defer dir.close(io);

    var cases: std.ArrayList(Case) = .empty;
    errdefer {
        for (cases.items) |c| a.free(c.name);
        cases.deinit(a);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        var probe_buf: [std.fs.max_name_bytes + 32]u8 = undefined;
        const schema_probe = std.fmt.bufPrint(&probe_buf, "{s}/schema.sjon", .{entry.name}) catch continue;
        const has_schema = blk: {
            dir.access(io, schema_probe, .{}) catch break :blk false;
            break :blk true;
        };

        var doc_probe_buf: [std.fs.max_name_bytes + 32]u8 = undefined;
        const doc_probe = std.fmt.bufPrint(&doc_probe_buf, "{s}/document.sjon", .{entry.name}) catch continue;
        const has_doc = blk: {
            dir.access(io, doc_probe, .{}) catch break :blk false;
            break :blk true;
        };

        var query_probe_buf: [std.fs.max_name_bytes + 32]u8 = undefined;
        const query_probe = std.fmt.bufPrint(&query_probe_buf, "{s}/query.sjon", .{entry.name}) catch continue;
        const has_query = blk: {
            dir.access(io, query_probe, .{}) catch break :blk false;
            break :blk true;
        };

        // A query case carries `query.sjon` + `document.sjon` (no
        // `schema.sjon`). Probe it first so its `document.sjon` isn't
        // miscategorized as inline-manifest.
        if (has_query) {
            if (has_schema) {
                std.debug.print(
                    "\nconformance case `{s}` contains both query.sjon and schema.sjon — fixtures must use exactly one shape\n",
                    .{entry.name},
                );
                return error.AmbiguousCaseShape;
            }
            if (!has_doc) {
                std.debug.print(
                    "\nconformance case `{s}` has query.sjon but no document.sjon — a query case needs both\n",
                    .{entry.name},
                );
                return error.AmbiguousCaseShape;
            }
            try cases.append(a, .{ .name = try a.dupe(u8, entry.name), .kind = .query });
            continue;
        }

        if (has_schema and has_doc) {
            std.debug.print(
                "\nconformance case `{s}` contains both schema.sjon and document.sjon — fixtures must use exactly one shape\n",
                .{entry.name},
            );
            return error.AmbiguousCaseShape;
        }

        if (has_schema) {
            try cases.append(a, .{ .name = try a.dupe(u8, entry.name), .kind = .legacy });
        } else if (has_doc) {
            try cases.append(a, .{ .name = try a.dupe(u8, entry.name), .kind = .inline_manifest });
        }
    }

    std.mem.sort(Case, cases.items, {}, struct {
        fn lt(_: void, lhs: Case, rhs: Case) bool {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lt);

    return cases;
}

/// List `extra-*.sjon` filenames inside a case directory, sorted
/// alphabetically. Each becomes an additional plugin in the schema —
/// see the module docstring for the multi-plugin convention.
fn discoverExtras(a: Allocator, case_name: []const u8) !std.ArrayList([]u8) {
    const io = std.testing.io;
    var path_buf: [256]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}", .{case_name});

    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "extra-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sjon")) continue;
        try names.append(a, try a.dupe(u8, entry.name));
    }

    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lt);

    return names;
}

/// Read a file as a 0-terminated buffer (the SJON parser requires
/// a sentinel-terminated source). Mirrors `readExampleSentinel` in
/// `root.zig` — kept private here so this module compiles standalone.
fn readSentinelFile(a: Allocator, path: []const u8) ![:0]u8 {
    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    defer a.free(bytes);
    const buf = try a.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf;
}

const ExpectedDiagnostic = ConformanceExpected.ExpectedDiagnostic;
const parseExpected = ConformanceExpected.parseExpectedDiagnostics;

fn runCase(a: Allocator, case: Case) !void {
    switch (case.kind) {
        .legacy => return runLegacyCase(a, case.name),
        .inline_manifest => return runInlineManifestCase(a, case.name),
        .query => return runQueryCase(a, case.name),
    }
}

/// A parsed `query.sjon`: the half-open tick window and the RNG seed.
const QuerySpec = struct { window: PatternQuery.Span, seed: i64 };

/// Parse `(query :window [begin end] :seed N)`. `:window` is required (two
/// integer ticks, `begin <= end`); `:seed` is optional (default 0).
fn parseQuerySpec(tree: *const Ast.Tree) !QuerySpec {
    if (tree.root.len != 1 or tree.tagOf(tree.root[0]) != .form) return error.MalformedQuery;
    const hdr = tree.formHeader(tree.root[0]);
    if (!std.mem.eql(u8, hdr.head, "query")) return error.MalformedQuery;

    var begin: ?i64 = null;
    var end: ?i64 = null;
    var seed: i64 = 0;
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "window")) {
            if (tree.tagOf(kv.value) != .vector) return error.MalformedQuery;
            const elems = tree.vectorElements(kv.value);
            if (elems.len != 2) return error.MalformedQuery;
            begin = try readQueryTick(tree, elems[0]);
            end = try readQueryTick(tree, elems[1]);
        } else if (std.mem.eql(u8, kv.key, "seed")) {
            seed = try readQueryTick(tree, kv.value);
        }
    }
    const b = begin orelse return error.MalformedQuery;
    const e = end orelse return error.MalformedQuery;
    if (b > e) return error.MalformedQuery;
    return .{ .window = PatternQuery.Span.init(b, e), .seed = seed };
}

fn readQueryTick(tree: *const Ast.Tree, idx: Ast.NodeIndex) !i64 {
    return switch (tree.tagOf(idx)) {
        .number_i64 => tree.numberI64Of(idx),
        else => error.MalformedQuery,
    };
}

/// Run a `query` case: parse the pattern + the query window, build the
/// pattern schema, validate (parity with the parse→validate→query
/// pipeline), query, then compare against `expected.sjon`. The expected
/// form's head selects the comparison: `(haps …)` checks the hap stream
/// (and asserts no diagnostics); `(diagnostics …)` checks the combined
/// validator + query `(code, path)` stream.
fn runQueryCase(a: Allocator, case_name: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    var path_buf: [256]u8 = undefined;

    const doc_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/document.sjon", .{case_name});
    const doc_src = try readSentinelFile(a, doc_path);
    defer a.free(doc_src);
    var doc_tree = try Parser.parse(a, doc_src);
    defer doc_tree.deinit();
    if (doc_tree.hasErrors()) return error.DocumentParseFailed;
    if (doc_tree.root.len != 1) return error.QueryDocumentNotSingleRoot;

    const query_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/query.sjon", .{case_name});
    const query_src = try readSentinelFile(a, query_path);
    defer a.free(query_src);
    var query_tree = try Parser.parse(a, query_src);
    defer query_tree.deinit();
    if (query_tree.hasErrors()) return error.QueryParseFailed;
    const qspec = try parseQuerySpec(&query_tree);

    const pattern_schema = Schema.Schema.init(&.{ plugins_core.plugin, plugins_pattern.plugin });

    var vr = try Validator.validate(a, doc_tree, pattern_schema);
    defer vr.deinit();

    var qr = try PatternQuery.queryTree(a, &doc_tree, doc_tree.root[0], pattern_schema, qspec.window, qspec.seed);
    defer qr.deinit();

    const expected_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/expected.sjon", .{case_name});
    const expected_src = try readSentinelFile(a, expected_path);
    defer a.free(expected_src);
    var expected_tree = try Parser.parse(a, expected_src);
    defer expected_tree.deinit();
    if (expected_tree.hasErrors()) return error.ExpectedParseFailed;
    if (expected_tree.root.len != 1 or expected_tree.tagOf(expected_tree.root[0]) != .form) return error.MalformedExpected;
    const ehead = expected_tree.formHeader(expected_tree.root[0]).head;

    if (std.mem.eql(u8, ehead, "haps")) {
        const total_diags = vr.diagnostics.len + qr.diagnostics.len;
        if (total_diags != 0) {
            std.debug.print("\n[query {s}] expected (haps …) but got {d} diagnostic(s):\n", .{ case_name, total_diags });
            for (vr.diagnostics) |d| std.debug.print("  validator [{s}] {s}\n", .{ @tagName(d.code), d.message });
            for (qr.diagnostics) |d| std.debug.print("  query     [{s}] {s}\n", .{ @tagName(d.code), d.message });
            return error.UnexpectedQueryDiagnostics;
        }
        const expected_haps = try PatternQuery.reconstructHaps(aa, &expected_tree, expected_tree.root[0]);
        try compareHaps(case_name, expected_haps, qr.haps);
    } else if (std.mem.eql(u8, ehead, "diagnostics")) {
        var actual: std.ArrayList(Ast.Diagnostic) = .empty;
        for (vr.diagnostics) |d| try actual.append(aa, d);
        for (qr.diagnostics) |d| try actual.append(aa, d);

        var expected_list = try parseExpected(aa, &expected_tree);
        defer expected_list.deinit(aa);
        try compareDiagList(case_name, expected_list.items, actual.items);
    } else return error.MalformedExpected;
}

/// Positional structural comparison of two hap streams on
/// `(part, whole?, value)`.
fn compareHaps(case_name: []const u8, expected: []const PatternQuery.Hap, actual: []const PatternQuery.Hap) !void {
    if (expected.len != actual.len) {
        std.debug.print("\n[query {s}] hap count mismatch: expected {d}, got {d}\n", .{ case_name, expected.len, actual.len });
        for (actual) |h| printHap(h);
        return error.HapCountMismatch;
    }
    for (expected, actual, 0..) |want, have, i| {
        if (!want.eql(have)) {
            std.debug.print("\n[query {s}] hap {d} mismatch:\n  expected ", .{ case_name, i });
            printHap(want);
            std.debug.print("  got      ", .{});
            printHap(have);
            return error.HapMismatch;
        }
    }
}

fn printHap(h: PatternQuery.Hap) void {
    std.debug.print("part=[{d} {d}]", .{ h.timing.part.begin, h.timing.part.end });
    if (h.timing.whole) |w| {
        std.debug.print(" whole=[{d} {d}]", .{ w.begin, w.end });
    } else {
        std.debug.print(" whole=nil", .{});
    }
    std.debug.print(" value={s}\n", .{@tagName(h.value)});
}

/// Compare an expected diagnostic list against the actual stream on
/// `(code, severity, path)`. Mirrors the inline-manifest comparison.
fn compareDiagList(case_name: []const u8, expected: []const ExpectedDiagnostic, actual: []const Ast.Diagnostic) !void {
    if (expected.len != actual.len) {
        std.debug.print("\n[query {s}] diagnostic count mismatch: expected {d}, got {d}\n", .{ case_name, expected.len, actual.len });
        for (actual) |d| {
            std.debug.print("  [{s} {s}] path=", .{ @tagName(d.severity), @tagName(d.code) });
            printPath(d.path);
            std.debug.print(" — {s}\n", .{d.message});
        }
        return error.DiagnosticCountMismatch;
    }
    for (expected, actual, 0..) |exp, got, i| {
        if (exp.code != got.code) {
            std.debug.print("\n[query {s}] diagnostic {d}: code mismatch — expected {s}, got {s}\n", .{ case_name, i, @tagName(exp.code), @tagName(got.code) });
            return error.DiagnosticCodeMismatch;
        }
        if (exp.severity != got.severity) {
            std.debug.print("\n[query {s}] diagnostic {d}: severity mismatch — expected {s}, got {s}\n", .{ case_name, i, @tagName(exp.severity), @tagName(got.severity) });
            return error.DiagnosticSeverityMismatch;
        }
        if (!pathEqual(exp.path, got.path)) {
            std.debug.print("\n[query {s}] diagnostic {d}: path mismatch\n  expected ", .{ case_name, i });
            printPath(exp.path);
            std.debug.print("\n  got      ", .{});
            printPath(got.path);
            std.debug.print("\n", .{});
            return error.DiagnosticPathMismatch;
        }
    }
}

/// D5 (4/4): Run a legacy schema+input case through the F9 preload API.
/// Each `schema.sjon` / `extra-*.sjon` is a standalone `(plugin …)` manifest —
/// the same single-source shape `runLegacyCase` feeds to `ManifestLoader` — so
/// we `Host.preloadSchema` the set once, then `Host.validateDocument` the
/// `input.sjon` against it via `HostOptions.preloaded`. This is the cross-host
/// parity gate AND the preload dogfood: preloading the schema (rather than
/// prepending it to the document and rebasing every diagnostic span by
/// `prefix_len`) exercises the two-phase host contract end-to-end over all
/// cases.
///
/// The diagnostic order matches the historic single-document host pass:
/// `pre.diagnostics` carries manifest (per source, in order) then aggregate
/// (over the loaded set); `hr.diagnostics` carries the input's validation
/// diagnostics. The input contributes no plugin, so its aggregate pass is
/// skipped and the aggregate runs exactly once — no double reporting. Spans
/// need no rebasing: preload spans are manifest-source-local and the input's
/// are document-local by construction. Any mismatch is an ordering artefact
/// of this concatenation — fix it here, never in a fixture (shared with the
/// primary runner + TS parity).
fn runLegacyCaseAsHost(a: Allocator, case_name: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    var path_buf: [256]u8 = undefined;

    // Preloaded sources: schema.sjon first, then each extra-*.sjon in
    // alphabetical order — one (plugin …) manifest per source. Read into the
    // per-case arena as separate sentinel buffers.
    var sources: std.ArrayList([:0]const u8) = .empty;

    const schema_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/schema.sjon", .{case_name});
    try sources.append(aa, try readSentinelFile(aa, schema_path));

    var extra_names = try discoverExtras(a, case_name);
    defer {
        for (extra_names.items) |n| a.free(n);
        extra_names.deinit(a);
    }
    for (extra_names.items) |xname| {
        const xpath = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/{s}", .{ case_name, xname });
        try sources.append(aa, try readSentinelFile(aa, xpath));
    }

    var pre = try Host.preloadSchema(a, sources.items);
    defer pre.deinit();

    const input_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/input.sjon", .{case_name});
    const input_bytes = try readSentinelFile(aa, input_path);

    var hr = try Host.validateDocument(a, input_bytes, .{ .preloaded = &pre });
    defer hr.deinit();

    // Concatenate preload-phase (manifest → aggregate over the preloaded set)
    // and document-phase (validation over the input) diagnostics — the same
    // order the old single-document host pass emitted, now split across the
    // two-phase API.
    var actual_diags: std.ArrayList(Ast.Diagnostic) = .empty;
    for (pre.diagnostics) |d| {
        try actual_diags.append(aa, try cloneDiagnostic(aa, .{
            .span = d.span,
            .message = d.message,
            .severity = d.severity,
            .code = d.code,
            .path = d.path,
        }));
    }
    for (hr.diagnostics) |d| {
        try actual_diags.append(aa, try cloneDiagnostic(aa, .{
            .span = d.span,
            .message = d.message,
            .severity = d.severity,
            .code = d.code,
            .path = d.path,
        }));
    }

    const expected_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/expected.sjon", .{case_name});
    const expected_src = try readSentinelFile(a, expected_path);
    defer a.free(expected_src);

    var expected_tree = try Parser.parse(a, expected_src);
    defer expected_tree.deinit();
    if (expected_tree.hasErrors()) return error.ExpectedParseFailed;

    var expected_list = try parseExpected(aa, &expected_tree);
    defer expected_list.deinit(aa);

    if (actual_diags.items.len != expected_list.items.len) {
        std.debug.print("\n[host-pass {s}] count mismatch: expected {d}, got {d}\n", .{
            case_name, expected_list.items.len, actual_diags.items.len,
        });
        std.debug.print("Actual diagnostics:\n", .{});
        for (actual_diags.items) |d| {
            std.debug.print("  [{s} {s}] path=", .{ @tagName(d.severity), @tagName(d.code) });
            printPath(d.path);
            std.debug.print(" — {s}\n", .{d.message});
        }
        return error.DiagnosticCountMismatch;
    }

    for (expected_list.items, actual_diags.items, 0..) |exp, got, i| {
        if (exp.code != got.code) {
            std.debug.print("\n[host-pass {s}] diagnostic {d}: code mismatch — expected {s}, got {s}\n", .{
                case_name, i, @tagName(exp.code), @tagName(got.code),
            });
            std.debug.print("  message: {s}\n", .{got.message});
            return error.DiagnosticCodeMismatch;
        }
        if (exp.severity != got.severity) {
            std.debug.print("\n[host-pass {s}] diagnostic {d}: severity mismatch — expected {s}, got {s}\n", .{
                case_name, i, @tagName(exp.severity), @tagName(got.severity),
            });
            return error.DiagnosticSeverityMismatch;
        }
        if (!pathEqual(exp.path, got.path)) {
            std.debug.print("\n[host-pass {s}] diagnostic {d}: path mismatch\n  expected ", .{
                case_name, i,
            });
            printPath(exp.path);
            std.debug.print("\n  got      ", .{});
            printPath(got.path);
            std.debug.print("\n", .{});
            return error.DiagnosticPathMismatch;
        }
    }
}

fn runLegacyCase(a: Allocator, case_name: []const u8) !void {
    // One arena owns every phase's per-case allocations: file buffers,
    // each phase's dupes of diagnostics, and the expected-list parse.
    // Mixing borrowed slices (into loaded.arena) with owned dupes was
    // ergonomically painful — copying everything into one arena erases
    // the boundary and lets a single deinit() handle cleanup.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    var path_buf: [256]u8 = undefined;

    // Phase 1 — manifest parse + load. A parse failure is a fixture bug;
    // a load failure (e.g. `too_many_keys`) is a legitimate schema-phase
    // diagnostic the case may be asserting against.
    const schema_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/schema.sjon", .{case_name});
    const schema_src = try readSentinelFile(a, schema_path);
    defer a.free(schema_src);

    var schema_tree = try Parser.parse(a, schema_src);
    defer schema_tree.deinit();
    if (schema_tree.hasErrors()) return error.SchemaParseFailed;

    var loaded = try ManifestLoader.load(a, schema_tree);
    defer loaded.deinit();

    var actual_diags: std.ArrayList(Ast.Diagnostic) = .empty;
    for (loaded.diagnostics) |d| {
        try actual_diags.append(aa, try cloneDiagnostic(aa, d));
    }

    // Optional sibling plugins. Each `extra-*.sjon` is loaded as an
    // additional Plugin slot, alphabetical order. Errors aggregate into
    // the same diagnostics stream as the primary plugin's load. We hold
    // sources, trees, and Result values alive for the rest of the case
    // because each Plugin's slices borrow from its Result's arena.
    var extra_sources: std.ArrayList([:0]u8) = .empty;
    var extra_trees: std.ArrayList(Ast.Tree) = .empty;
    var extra_loads: std.ArrayList(ManifestLoader.Result) = .empty;
    defer {
        // Deinit order: loads (independent), trees (borrow from sources),
        // sources (raw bytes). Trees must be released before the source
        // they index into is freed (per Ast.Tree's "Borrowed source").
        for (extra_loads.items) |*r| r.deinit();
        for (extra_trees.items) |*t| t.deinit();
        for (extra_sources.items) |s| a.free(s);
        extra_loads.deinit(a);
        extra_trees.deinit(a);
        extra_sources.deinit(a);
    }

    var extra_names = try discoverExtras(a, case_name);
    defer {
        for (extra_names.items) |n| a.free(n);
        extra_names.deinit(a);
    }

    for (extra_names.items) |xname| {
        const xpath = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/{s}", .{ case_name, xname });
        const xsrc = try readSentinelFile(a, xpath);
        try extra_sources.append(a, xsrc);

        var xtree = try Parser.parse(a, xsrc);
        if (xtree.hasErrors()) {
            xtree.deinit();
            return error.SchemaParseFailed;
        }
        try extra_trees.append(a, xtree);

        const xloaded = try ManifestLoader.load(a, xtree);
        for (xloaded.diagnostics) |d| {
            try actual_diags.append(aa, try cloneDiagnostic(aa, d));
        }
        try extra_loads.append(a, xloaded);
    }

    const plugins_buf = try aa.alloc(Plugin.Plugin, 1 + extra_loads.items.len);
    plugins_buf[0] = loaded.plugin;
    for (extra_loads.items, 0..) |xloaded, i| plugins_buf[1 + i] = xloaded.plugin;
    const schema: Schema.Schema = .{ .plugins = plugins_buf };

    // Phase 2 — schema-aggregate cross-ref resolution. Skip when any
    // plugin (primary or extra) failed to load: a partial plugin may be
    // missing the very pieces aggregate validation walks, and the load
    // diagnostic already reports the underlying issue.
    var any_load_errors = loaded.hasErrors();
    for (extra_loads.items) |*r| {
        if (r.hasErrors()) any_load_errors = true;
    }
    if (!any_load_errors) {
        // Mirror Host.validateDocument's aggregate phase: cross-refs,
        // unions, forms, lowering, defaults. Each validator owns its own
        // diagnostic slice; copy each err into the per-case arena before
        // releasing.
        const runners: [5]*const fn (Schema.Schema, std.mem.Allocator) std.mem.Allocator.Error![]const Ast.Diagnostic = .{
            &Schema.Schema.validateCrossRefs,
            &Schema.Schema.validateUnions,
            &Schema.Schema.validateForms,
            &Schema.Schema.validateLowering,
            &Schema.Schema.validateDefaults,
        };
        for (runners) |run| {
            const agg_diags = try run(schema, a);
            defer {
                for (agg_diags) |d| {
                    a.free(d.message);
                    for (d.path) |p| a.free(p);
                    a.free(d.path);
                }
                a.free(agg_diags);
            }
            for (agg_diags) |d| {
                try actual_diags.append(aa, try cloneDiagnostic(aa, d));
            }
        }
    }

    // Phase 3 — parse the input and validate.
    const input_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/input.sjon", .{case_name});
    const input_src = try readSentinelFile(a, input_path);
    defer a.free(input_src);

    var input_tree = try Parser.parse(a, input_src);
    defer input_tree.deinit();
    if (input_tree.hasErrors()) return error.InputParseFailed;

    var v = try Validator.validate(a, input_tree, schema);
    defer v.deinit();
    for (v.diagnostics) |d| {
        try actual_diags.append(aa, try cloneDiagnostic(aa, d));
    }

    // Phase 4 — load expected diagnostics.
    const expected_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/expected.sjon", .{case_name});
    const expected_src = try readSentinelFile(a, expected_path);
    defer a.free(expected_src);

    var expected_tree = try Parser.parse(a, expected_src);
    defer expected_tree.deinit();
    if (expected_tree.hasErrors()) return error.ExpectedParseFailed;

    var expected_list = try parseExpected(aa, &expected_tree);
    defer expected_list.deinit(aa);

    if (actual_diags.items.len != expected_list.items.len) {
        std.debug.print("\n[{s}] count mismatch: expected {d}, got {d}\n", .{
            case_name, expected_list.items.len, actual_diags.items.len,
        });
        std.debug.print("Actual diagnostics:\n", .{});
        for (actual_diags.items) |d| {
            std.debug.print("  [{s} {s}] path=", .{ @tagName(d.severity), @tagName(d.code) });
            printPath(d.path);
            std.debug.print(" — {s}\n", .{d.message});
        }
        return error.DiagnosticCountMismatch;
    }

    for (expected_list.items, actual_diags.items, 0..) |exp, got, i| {
        if (exp.code != got.code) {
            std.debug.print("\n[{s}] diagnostic {d}: code mismatch — expected {s}, got {s}\n", .{
                case_name, i, @tagName(exp.code), @tagName(got.code),
            });
            std.debug.print("  message: {s}\n", .{got.message});
            return error.DiagnosticCodeMismatch;
        }
        if (exp.severity != got.severity) {
            std.debug.print("\n[{s}] diagnostic {d}: severity mismatch — expected {s}, got {s}\n", .{
                case_name, i, @tagName(exp.severity), @tagName(got.severity),
            });
            return error.DiagnosticSeverityMismatch;
        }
        if (!pathEqual(exp.path, got.path)) {
            std.debug.print("\n[{s}] diagnostic {d}: path mismatch\n  expected ", .{
                case_name, i,
            });
            printPath(exp.path);
            std.debug.print("\n  got      ", .{});
            printPath(got.path);
            std.debug.print("\n", .{});
            return error.DiagnosticPathMismatch;
        }
    }
}

fn isLoweringCase(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "lowering-");
}

/// Part 2 (2.4): replay a legacy `schema+input` case through BOTH
/// validation walkers on identical input — tree `Validator.validate` vs
/// `toBinary(spans) → validateBinary` — and assert `(code, severity,
/// path)` parity via `expectBinaryValidationParity`. Only Phase-3 input
/// validation is compared; the manifest-load and schema-aggregate phases
/// stay tree-only (the binary validator has no manifest/aggregate entry
/// point), so this never consults `expected.sjon`. The invariant it pins:
/// a KeySpec / value-kind feature implemented in `validateOneTree` but not
/// `validateOneBinary` (or vice-versa) diverges here even when every
/// `expected.sjon` still matches the tree path. Schema/input parse
/// failures return early — the `corpus runs` test already covers those.
fn replayLegacyCaseBinary(a: Allocator, case_name: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    var path_buf: [256]u8 = undefined;

    const schema_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/schema.sjon", .{case_name});
    const schema_src = try readSentinelFile(a, schema_path);
    defer a.free(schema_src);

    var schema_tree = try Parser.parse(a, schema_src);
    defer schema_tree.deinit();
    if (schema_tree.hasErrors()) return;

    var loaded = try ManifestLoader.load(a, schema_tree);
    defer loaded.deinit();

    // Sibling `extra-*.sjon` plugins, held alive because each Plugin
    // borrows from its Result's arena (mirrors runLegacyCase's lifetimes).
    var extra_sources: std.ArrayList([:0]u8) = .empty;
    var extra_trees: std.ArrayList(Ast.Tree) = .empty;
    var extra_loads: std.ArrayList(ManifestLoader.Result) = .empty;
    defer {
        for (extra_loads.items) |*r| r.deinit();
        for (extra_trees.items) |*t| t.deinit();
        for (extra_sources.items) |s| a.free(s);
        extra_loads.deinit(a);
        extra_trees.deinit(a);
        extra_sources.deinit(a);
    }

    var extra_names = try discoverExtras(a, case_name);
    defer {
        for (extra_names.items) |n| a.free(n);
        extra_names.deinit(a);
    }

    for (extra_names.items) |xname| {
        const xpath = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/{s}", .{ case_name, xname });
        const xsrc = try readSentinelFile(a, xpath);
        try extra_sources.append(a, xsrc);

        var xtree = try Parser.parse(a, xsrc);
        if (xtree.hasErrors()) {
            xtree.deinit();
            return;
        }
        try extra_trees.append(a, xtree);

        const xloaded = try ManifestLoader.load(a, xtree);
        try extra_loads.append(a, xloaded);
    }

    const plugins_buf = try aa.alloc(Plugin.Plugin, 1 + extra_loads.items.len);
    plugins_buf[0] = loaded.plugin;
    for (extra_loads.items, 0..) |xloaded, i| plugins_buf[1 + i] = xloaded.plugin;
    const schema: Schema.Schema = .{ .plugins = plugins_buf };

    const input_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/input.sjon", .{case_name});
    const input_src = try readSentinelFile(a, input_path);
    defer a.free(input_src);

    var input_tree = try Parser.parse(a, input_src);
    defer input_tree.deinit();
    if (input_tree.hasErrors()) return;

    var vt = try Validator.validate(a, input_tree, schema);
    defer vt.deinit();

    const bin = try Binary.toBinary(a, input_tree, .{
        .with_spans = true,
        .with_head_spans = true,
        .with_kvpair_key_spans = true,
    });
    defer bin.deinit();
    var vb = try Validator.validateBinary(a, bin.data, schema);
    defer vb.deinit();

    try expectBinaryValidationParity(case_name, vt.diagnostics, vb.diagnostics);
}

/// Part 2 (2.5): replay an inline-manifest case's DATA-FOREST validation
/// through BOTH walkers on identical input and assert `(code, severity,
/// path)` parity — the inline-shape companion to `replayLegacyCaseBinary`.
///
/// The input here is a full document with inline `(plugin …)` declarations,
/// so we drive it through `Host.validateDocument` (same options as
/// `runInlineManifestCase`) to obtain the parsed tree, the resolved plugin
/// set, and the `data_forest` partition — then run the two walkers directly
/// over the data forest via the tree-copy view-substitution pattern
/// (`Host.zig` §"Validation — final-document forest pass"): copy `hr.tree`
/// by value and repoint `.root` at `hr.data_forest`, so only the data forms
/// are walked (the `(plugin …)` / `(use-plugin …)` declarations are
/// excluded). Node storage is shared; only `root` differs on the view.
///
/// This is an OPTION-LESS walker-parity property. Host's real validation
/// pass threads overlays / effective-axes / `share_scope` into
/// `Host.validateForestWithOptions`; the binary walker
/// (`validateForestBinary`) takes no `Options`, so those semantics can't
/// replay. We compare the two walkers under `Options{}` on the same forest
/// — narrower than Host's pass, but exactly the surface the binary path can
/// express. Graduation criterion: when `validateForestBinary` grows an
/// `Options` parameter, widen this to the full overlay/axes/`share_scope`
/// comparison.
///
/// Schema: `eval_schema = plugins_core.plugin ++ hr.plugins`.
/// `HostResult.schema` is user-only by design; forest
/// validation needs core in scope so top-level `(map …)` / `(if …)` /
/// `(* …)` resolve without `unknown_form`, so we rebuild it here.
///
/// `lowering-*` cases replay the *source* forest (`data_forest`), not the
/// lowered output — both walkers see the same source forms, so the parity
/// property holds regardless of what Host's lowering pass produced. A
/// document that fails to parse cleanly (recovered tree) is skipped: a
/// partial tree isn't a meaningful `toBinary` subject.
fn replayInlineCaseBinary(a: Allocator, case_name: []const u8) !void {
    var path_buf: [256]u8 = undefined;

    const doc_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/document.sjon", .{case_name});
    const doc_src = try readSentinelFile(a, doc_path);
    defer a.free(doc_src);

    // Mirror runInlineManifestCase's host options: the case dir is the
    // project root (so explicit `:path` refs resolve), a `sjon-project.sjon`
    // sibling attaches the name index when present, and `lowering-*` cases
    // register the test hooks so the host pass finds them.
    const project_root = try std.fmt.allocPrint(a, "conformance/cases/{s}", .{case_name});
    defer a.free(project_root);
    const project_file_path = try std.fmt.allocPrint(a, "{s}/sjon-project.sjon", .{project_root});
    defer a.free(project_file_path);
    const has_project_file = blk: {
        std.Io.Dir.cwd().access(std.testing.io, project_file_path, .{}) catch break :blk false;
        break :blk true;
    };

    var lowering_registry: Lowering.LoweringRegistry = .{};
    defer lowering_registry.deinit(a);
    if (isLoweringCase(case_name)) {
        try lowering_registry.register(a, Lowering_test_hooks.test_identity_v1);
        try lowering_registry.register(a, Lowering_test_hooks.test_bundle_v1);
        try lowering_registry.register(a, Lowering_test_hooks.test_probe_v1);
        try lowering_registry.register(a, Lowering_test_hooks.test_probe_wrong_call_v1);
        try lowering_registry.register(a, Lowering_test_hooks.test_fanout_v1);
        try lowering_registry.register(a, Lowering_test_hooks.test_to_row_v1);
        try lowering_registry.register(a, Lowering_test_hooks.webgpu_render_graph_v1);
        try lowering_registry.register(a, Lowering_test_hooks.test_synth_terminal_v1);
        try lowering_registry.register(a, Lowering_test_hooks.test_synth_positional_v1);
    }

    var hr = try Host.validateDocument(a, doc_src, .{
        .project_root = project_root,
        .project_file = if (has_project_file) project_file_path else null,
        .io = std.testing.io,
        .lowering_registry = if (isLoweringCase(case_name)) &lowering_registry else null,
    });
    defer hr.deinit();

    // A recovered (partial) parse isn't a meaningful walker-parity subject;
    // nothing to validate when the forest is empty either.
    if (hr.tree.hasErrors()) return;
    if (hr.data_forest.len == 0) return;

    // eval_schema = core ++ user plugins (HostResult.schema is user-only).
    const eval_plugins = try a.alloc(Plugin.Plugin, hr.plugins.len + 1);
    defer a.free(eval_plugins);
    eval_plugins[0] = plugins_core.plugin;
    for (hr.plugins, 0..) |p, i| eval_plugins[i + 1] = p;
    const eval_schema: Schema.Schema = .{ .plugins = eval_plugins };

    // Tree-copy view substitution: repoint `root` at the data forest so the
    // walkers skip the declarations. `hr.tree`'s node arena stays owned by
    // `hr`; the view is never deinited.
    var source_view: Ast.Tree = hr.tree;
    source_view.root = hr.data_forest;

    var vt = try Validator.validate(a, source_view, eval_schema);
    defer vt.deinit();

    const bin = try Binary.toBinary(a, source_view, .{
        .with_spans = true,
        .with_head_spans = true,
        .with_kvpair_key_spans = true,
    });
    defer bin.deinit();
    var vb = try Validator.validateBinary(a, bin.data, eval_schema);
    defer vb.deinit();

    try expectBinaryValidationParity(case_name, vt.diagnostics, vb.diagnostics);
}

fn runInlineManifestCase(a: Allocator, case_name: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    var path_buf: [256]u8 = undefined;

    const doc_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/document.sjon", .{case_name});
    const doc_src = try readSentinelFile(a, doc_path);
    defer a.free(doc_src);

    // The case directory is the project root: always hand it to Host so
    // explicit `:path` references in `(use-plugin …)` forms resolve
    // relative to the case dir. Only attach `project_file` when a sibling
    // `sjon-project.sjon` exists; cases without one still get a resolver
    // (for `:path`) but no name index.
    const project_root = try std.fmt.allocPrint(aa, "conformance/cases/{s}", .{case_name});
    const project_file_path = try std.fmt.allocPrint(aa, "{s}/sjon-project.sjon", .{project_root});
    const has_project_file = blk: {
        std.Io.Dir.cwd().access(std.testing.io, project_file_path, .{}) catch break :blk false;
        break :blk true;
    };

    // `lowering-*` cases exercise the lowering runtime — register the
    // test hook so the host pass driver finds it. Other inline-manifest
    // cases pass `lowering_registry = null` and stay byte-identical to
    // the pre-lowering baseline.
    var lowering_registry: Lowering.LoweringRegistry = .{};
    defer lowering_registry.deinit(a);
    if (isLoweringCase(case_name)) {
        try lowering_registry.register(a, Lowering_test_hooks.test_identity_v1);
        try lowering_registry.register(a, Lowering_test_hooks.test_bundle_v1);
        try lowering_registry.register(a, Lowering_test_hooks.test_probe_v1);
        try lowering_registry.register(a, Lowering_test_hooks.test_probe_wrong_call_v1);
        try lowering_registry.register(a, Lowering_test_hooks.test_fanout_v1);
        try lowering_registry.register(a, Lowering_test_hooks.test_to_row_v1);
        try lowering_registry.register(a, Lowering_test_hooks.webgpu_render_graph_v1);
        try lowering_registry.register(a, Lowering_test_hooks.test_synth_terminal_v1);
        try lowering_registry.register(a, Lowering_test_hooks.test_synth_positional_v1);
    }

    var hr = try Host.validateDocument(a, doc_src, .{
        .project_root = project_root,
        .project_file = if (has_project_file) project_file_path else null,
        .io = std.testing.io,
        .lowering_registry = if (isLoweringCase(case_name)) &lowering_registry else null,
    });
    defer hr.deinit();

    // HostResult.diagnostics already orders entries manifest → aggregate
    // → validation, so a flat sweep mirrors the legacy path's phase
    // concatenation exactly. Both err- and warning-severity entries are
    // collected; expected.sjon's `:severity` (default `err`) selects.
    var actual_diags: std.ArrayList(Ast.Diagnostic) = .empty;
    for (hr.diagnostics) |d| {
        try actual_diags.append(aa, try cloneDiagnostic(aa, .{
            .span = d.span,
            .message = d.message,
            .severity = d.severity,
            .code = d.code,
            .path = d.path,
        }));
    }

    const expected_path = try std.fmt.bufPrint(&path_buf, "conformance/cases/{s}/expected.sjon", .{case_name});
    const expected_src = try readSentinelFile(a, expected_path);
    defer a.free(expected_src);

    var expected_tree = try Parser.parse(a, expected_src);
    defer expected_tree.deinit();
    if (expected_tree.hasErrors()) return error.ExpectedParseFailed;

    var expected_list = try parseExpected(aa, &expected_tree);
    defer expected_list.deinit(aa);

    if (actual_diags.items.len != expected_list.items.len) {
        std.debug.print("\n[{s}] count mismatch: expected {d}, got {d}\n", .{
            case_name, expected_list.items.len, actual_diags.items.len,
        });
        std.debug.print("Actual diagnostics:\n", .{});
        for (actual_diags.items) |d| {
            std.debug.print("  [{s} {s}] path=", .{ @tagName(d.severity), @tagName(d.code) });
            printPath(d.path);
            std.debug.print(" — {s}\n", .{d.message});
        }
        return error.DiagnosticCountMismatch;
    }

    for (expected_list.items, actual_diags.items, 0..) |exp, got, i| {
        if (exp.code != got.code) {
            std.debug.print("\n[{s}] diagnostic {d}: code mismatch — expected {s}, got {s}\n", .{
                case_name, i, @tagName(exp.code), @tagName(got.code),
            });
            std.debug.print("  message: {s}\n", .{got.message});
            return error.DiagnosticCodeMismatch;
        }
        if (exp.severity != got.severity) {
            std.debug.print("\n[{s}] diagnostic {d}: severity mismatch — expected {s}, got {s}\n", .{
                case_name, i, @tagName(exp.severity), @tagName(got.severity),
            });
            return error.DiagnosticSeverityMismatch;
        }
        if (!pathEqual(exp.path, got.path)) {
            std.debug.print("\n[{s}] diagnostic {d}: path mismatch\n  expected ", .{
                case_name, i,
            });
            printPath(exp.path);
            std.debug.print("\n  got      ", .{});
            printPath(got.path);
            std.debug.print("\n", .{});
            return error.DiagnosticPathMismatch;
        }
    }

    // Optional `(values …)` assertion. Cases that opt in compare each
    // entry's `:result` literal against `hr.evaluated_results[…]` by
    // `forest_index`. Cases without a `(values …)` form get an empty
    // list and skip the loop.
    var expected_values = try ConformanceExpected.parseExpectedValues(aa, &expected_tree);
    defer expected_values.deinit(aa);
    for (expected_values.items) |ev| {
        const actual = blk: {
            for (hr.evaluated_results) |er| {
                if (er.forest_index == ev.forest_index) break :blk er.value;
            }
            std.debug.print("\n[{s}] expected value at index {d} but no matching evaluated_results entry\n", .{
                case_name, ev.forest_index,
            });
            return error.ExpectedValueMissing;
        };
        if (!ev.value.equals(actual)) {
            std.debug.print("\n[{s}] value mismatch at index {d}\n", .{
                case_name, ev.forest_index,
            });
            return error.ExpectedValueMismatch;
        }
    }
}

fn cloneDiagnostic(a: Allocator, d: Ast.Diagnostic) !Ast.Diagnostic {
    const path = try a.alloc([]const u8, d.path.len);
    for (d.path, 0..) |s, i| path[i] = try a.dupe(u8, s);
    return .{
        .span = d.span,
        .message = try a.dupe(u8, d.message),
        .severity = d.severity,
        .code = d.code,
        .path = path,
    };
}

const pathEqual = ConformanceExpected.pathEqual;

fn printPath(path: []const []const u8) void {
    std.debug.print("[", .{});
    for (path, 0..) |s, i| {
        if (i > 0) std.debug.print(" ", .{});
        std.debug.print("{s}", .{s});
    }
    std.debug.print("]", .{});
}

// ---------------------------------------------------------------------------
// Binary-path dual replay (Part 2, 2.4).
//
// The corpus `expected.sjon` only ever pins the TREE validation path. To
// keep `validateOneBinary` from silently drifting from `validateOneTree`,
// every legacy case's Phase-3 input validation is replayed through both
// walkers on identical input and compared `(code, severity, path)`.
// ---------------------------------------------------------------------------

/// True when `full` is `prefix` followed by ≥ 1 additional segments that
/// are *all* vector element indices (each extra segment non-empty, all
/// ASCII digits). This is the one sanctioned tree↔binary path divergence:
/// the tree validator wraps a failing typed-vector element into ONE
/// diagnostic at the slot path (`[set v]`, message "element [N]: …"),
/// while the binary validator emits at the failing element's own
/// index-extended path (`[set v 1]`, or `[set m 3]` / `[set m 3 2]` when
/// nested). A non-digit extra segment is NOT a vector descent and stays a
/// real mismatch.
fn isDigitSuffixExtension(prefix: []const []const u8, full: []const []const u8) bool {
    if (full.len <= prefix.len) return false;
    for (prefix, full[0..prefix.len]) |p, f| {
        if (!std.mem.eql(u8, p, f)) return false;
    }
    for (full[prefix.len..]) |seg| {
        if (seg.len == 0) return false;
        for (seg) |c| if (c < '0' or c > '9') return false;
    }
    return true;
}

fn diagExact(t: Ast.Diagnostic, b: Ast.Diagnostic) bool {
    return t.code == b.code and t.severity == b.severity and pathEqual(t.path, b.path);
}

fn reportBinaryParityMismatch(
    case_name: []const u8,
    tree_diags: []const Ast.Diagnostic,
    bin_diags: []const Ast.Diagnostic,
    ti: usize,
    bi: usize,
) error{BinaryValidationParityMismatch} {
    std.debug.print("\n[bin-parity {s}] divergence at tree[{d}] / binary[{d}]\n", .{ case_name, ti, bi });
    std.debug.print("  TREE ({d}):\n", .{tree_diags.len});
    for (tree_diags) |d| {
        std.debug.print("    [{s} {s}] ", .{ @tagName(d.severity), @tagName(d.code) });
        printPath(d.path);
        std.debug.print("\n", .{});
    }
    std.debug.print("  BINARY ({d}):\n", .{bin_diags.len});
    for (bin_diags) |d| {
        std.debug.print("    [{s} {s}] ", .{ @tagName(d.severity), @tagName(d.code) });
        printPath(d.path);
        std.debug.print("\n", .{});
    }
    return error.BinaryValidationParityMismatch;
}

/// First index pair `.{ti, bi}` where the tree-path and binary-path streams
/// diverge under the parity contract, or null when they agree. The contract:
/// both must emit the same `(code, severity, path)` for every diagnostic, in
/// order, EXCEPT the vector-element exemption (`isDigitSuffixExtension`) —
/// one tree diagnostic at a slot path absorbs the run of binary diagnostics
/// that fire per failing element under that slot (matching code + severity).
/// Any other divergence — count, code, severity, or a non-index path — is
/// returned as the divergence point. Pure: no printing, no allocation, so
/// unit tests can assert on it without stderr noise.
fn firstBinaryParityDivergence(
    tree_diags: []const Ast.Diagnostic,
    bin_diags: []const Ast.Diagnostic,
) ?[2]usize {
    var ti: usize = 0;
    var bi: usize = 0;
    while (ti < tree_diags.len and bi < bin_diags.len) {
        const t = tree_diags[ti];
        const b = bin_diags[bi];
        if (diagExact(t, b)) {
            ti += 1;
            bi += 1;
            continue;
        }
        // Vector-element exemption: the binary diag descends into the tree
        // diag's slot via an all-index path suffix. Consume the one tree
        // diag and absorb the whole per-element run (same code + severity,
        // same slot prefix).
        if (t.code == b.code and t.severity == b.severity and isDigitSuffixExtension(t.path, b.path)) {
            ti += 1;
            bi += 1;
            while (bi < bin_diags.len and
                bin_diags[bi].code == t.code and
                bin_diags[bi].severity == t.severity and
                isDigitSuffixExtension(t.path, bin_diags[bi].path)) : (bi += 1)
            {}
            continue;
        }
        return .{ ti, bi };
    }
    if (ti != tree_diags.len or bi != bin_diags.len) return .{ ti, bi };
    return null;
}

/// Assert tree/binary parity for one case, printing both streams for
/// localisation on divergence. Wraps `firstBinaryParityDivergence` — the
/// print fires ONLY on a real divergence (green runs stay silent), so the
/// pure-predicate unit tests below don't pollute the suite output.
fn expectBinaryValidationParity(
    case_name: []const u8,
    tree_diags: []const Ast.Diagnostic,
    bin_diags: []const Ast.Diagnostic,
) error{BinaryValidationParityMismatch}!void {
    if (firstBinaryParityDivergence(tree_diags, bin_diags)) |at| {
        return reportBinaryParityMismatch(case_name, tree_diags, bin_diags, at[0], at[1]);
    }
}

fn synthDiag(
    code: Ast.Diagnostic.Code,
    severity: Ast.Diagnostic.Severity,
    path: []const []const u8,
) Ast.Diagnostic {
    return .{ .span = .{ .start = 0, .end = 0 }, .message = "", .severity = severity, .code = code, .path = path };
}

test "isDigitSuffixExtension: precise about index tails" {
    try testing.expect(isDigitSuffixExtension(&.{ "set", "v" }, &.{ "set", "v", "0" }));
    try testing.expect(isDigitSuffixExtension(&.{ "set", "m" }, &.{ "set", "m", "3", "2" }));
    try testing.expect(!isDigitSuffixExtension(&.{ "set", "v" }, &.{ "set", "v" })); // not longer
    try testing.expect(!isDigitSuffixExtension(&.{ "set", "v" }, &.{ "set", "w", "0" })); // prefix differs
    try testing.expect(!isDigitSuffixExtension(&.{ "set", "v" }, &.{ "set", "v", "x" })); // non-digit tail
    try testing.expect(!isDigitSuffixExtension(&.{ "set", "v" }, &.{ "set", "v", "" })); // empty segment
}

test "binary parity comparator: identical streams pass" {
    const tree = [_]Ast.Diagnostic{
        synthDiag(.unknown_form, .err, &.{"scene"}),
        synthDiag(.missing_required_key, .err, &.{ "scene", "bpm" }),
    };
    try testing.expect(firstBinaryParityDivergence(&tree, &tree) == null);
}

test "binary parity comparator: vector-element single index absorbed" {
    // Tree wraps at the slot; binary fires at element [1]. Same code.
    const tree = [_]Ast.Diagnostic{synthDiag(.number_above_max, .err, &.{ "set", "v" })};
    const bin = [_]Ast.Diagnostic{synthDiag(.number_above_max, .err, &.{ "set", "v", "1" })};
    try testing.expect(firstBinaryParityDivergence(&tree, &bin) == null);
}

test "binary parity comparator: multi-element run absorbed into one wrap" {
    const tree = [_]Ast.Diagnostic{synthDiag(.number_above_max, .err, &.{ "set", "v" })};
    const bin = [_]Ast.Diagnostic{
        synthDiag(.number_above_max, .err, &.{ "set", "v", "0" }),
        synthDiag(.number_above_max, .err, &.{ "set", "v", "1" }),
    };
    try testing.expect(firstBinaryParityDivergence(&tree, &bin) == null);
}

test "binary parity comparator: nested index suffix absorbed" {
    const tree = [_]Ast.Diagnostic{synthDiag(.vector_length_mismatch, .err, &.{ "set", "m" })};
    const bin = [_]Ast.Diagnostic{synthDiag(.vector_length_mismatch, .err, &.{ "set", "m", "3" })};
    try testing.expect(firstBinaryParityDivergence(&tree, &bin) == null);
}

test "binary parity comparator: genuine code mismatch diverges" {
    const tree = [_]Ast.Diagnostic{synthDiag(.unknown_form, .err, &.{"a"})};
    const bin = [_]Ast.Diagnostic{synthDiag(.unknown_key, .err, &.{"b"})};
    try testing.expect(firstBinaryParityDivergence(&tree, &bin) != null);
}

test "binary parity comparator: non-index suffix is a real divergence" {
    const tree = [_]Ast.Diagnostic{synthDiag(.number_above_max, .err, &.{ "set", "v" })};
    const bin = [_]Ast.Diagnostic{synthDiag(.number_above_max, .err, &.{ "set", "v", "nested" })};
    try testing.expect(firstBinaryParityDivergence(&tree, &bin) != null);
}

test "binary parity comparator: severity divergence diverges" {
    const tree = [_]Ast.Diagnostic{synthDiag(.number_above_max, .err, &.{ "set", "v" })};
    const bin = [_]Ast.Diagnostic{synthDiag(.number_above_max, .warning, &.{ "set", "v", "0" })};
    try testing.expect(firstBinaryParityDivergence(&tree, &bin) != null);
}

test "conformance: corpus runs" {
    const a = testing.allocator;
    const io = std.testing.io;

    var cases = try discoverCases(a, io);
    defer {
        for (cases.items) |c| a.free(c.name);
        cases.deinit(a);
    }

    // An empty corpus would silently pass — guard against it so a
    // misplaced fixture root surfaces as a test failure.
    try testing.expect(cases.items.len > 0);

    var failures: usize = 0;
    for (cases.items) |c| {
        if (isPluginExecCase(c.name)) continue;
        runCase(a, c) catch |err| {
            std.debug.print("\nconformance case `{s}` failed: {s}\n", .{ c.name, @errorName(err) });
            failures += 1;
        };
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "conformance: legacy corpus is frozen at 136 cases" {
    const a = testing.allocator;
    const io = std.testing.io;

    var cases = try discoverCases(a, io);
    defer {
        for (cases.items) |c| a.free(c.name);
        cases.deinit(a);
    }

    // Ratchet pin (see the file header's "Corpus policy"): the legacy
    // split-file shape (`schema.sjon` + `input.sjon`) is FROZEN. The 136
    // legacy cases stay — they double as F9 preload coverage via
    // `runLegacyCaseAsHost` — but new cases must be `document.sjon`
    // (inline) or `query.sjon`. A deliberate legacy addition bumps this
    // number in the same commit and explains why. Green by design.
    var legacy: usize = 0;
    for (cases.items) |c| {
        if (c.kind == .legacy) legacy += 1;
    }
    try testing.expectEqual(@as(usize, 136), legacy);
}

/// Fixtures where the host pipeline emits a different diagnostic set
/// than the legacy pre-compose path. The divergence is not a parser /
/// validator drift — it's a deliberate host design choice that the
/// legacy path doesn't make. Skipping these in the host-pass keeps the
/// dual-pass invariant honest for everything else.
///
/// `too-many-keys` — `Host.validateDocument` drops errored plugins
///   from the schema (`Host.zig` §"can't contribute to the schema"), so
///   `(big …)` becomes `unknown_form` on top of the manifest-phase
///   `too_many_keys`. The legacy runner keeps the truncated plugin in
///   the schema, so its `(big)` validates cleanly. Both behaviours are
///   intentional; the host's stricter stance is the cross-host
///   contract.
const HOST_PASS_SKIP = [_][]const u8{
    "too-many-keys",
};

fn isHostPassSkipped(name: []const u8) bool {
    for (HOST_PASS_SKIP) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

test "conformance: classifier.json wasm-host skip families match the Zig runner mirror" {
    // `conformance/classifier.json` is the single source the TS + Rust hosts
    // read for case classification; this Zig runner is the REFERENCE and
    // mirrors it natively — `isLoweringCase` for the `lowering-` prefix family,
    // `HOST_PASS_SKIP` for the exact `too-many-keys` family. A skip family
    // added to the JSON without a Zig mirror (or the reverse) silently drifts
    // the reference from its consumers, so pin the two vocabularies together.
    const a = testing.allocator;

    const Family = struct {
        label: []const u8,
        match: struct { type: []const u8, value: []const u8 },
    };
    const ClassifierData = struct {
        wasmHostSkipFamilies: []const Family,
    };

    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "conformance/classifier.json",
        a,
        .unlimited,
    );
    defer a.free(bytes);

    const parsed = try std.json.parseFromSlice(ClassifierData, a, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const families = parsed.value.wasmHostSkipFamilies;

    // Exactly the two families the runner hard-codes — counted both ways, so a
    // one-sided addition (JSON-only or HOST_PASS_SKIP-only) trips the gate.
    try testing.expectEqual(@as(usize, 2), families.len);
    try testing.expectEqual(@as(usize, 1), HOST_PASS_SKIP.len);

    var saw_prefix = false;
    var saw_exact = false;
    for (families) |fam| {
        if (std.mem.eql(u8, fam.match.type, "prefix")) {
            // Mirrored by isLoweringCase: the declared prefix is what the runner
            // keys on, and the behaviour agrees on positive and negative space.
            try testing.expectEqualStrings("lowering-", fam.match.value);
            try testing.expect(isLoweringCase("lowering-foo"));
            try testing.expect(!isLoweringCase("too-many-keys"));
            saw_prefix = true;
        } else if (std.mem.eql(u8, fam.match.type, "exact")) {
            // Mirrored by HOST_PASS_SKIP / isHostPassSkipped.
            try testing.expectEqualStrings("too-many-keys", fam.match.value);
            try testing.expect(isHostPassSkipped(fam.match.value));
            try testing.expect(!isHostPassSkipped("lowering-foo"));
            saw_exact = true;
        } else {
            std.debug.print("classifier.json: unknown match type {s}\n", .{fam.match.type});
            return error.UnknownClassifierMatchType;
        }
    }
    try testing.expect(saw_prefix);
    try testing.expect(saw_exact);
}

/// Cases that exercise the executable-plugin runtime (D7-exec). Pre-
/// dating the native runtime adapter, these were skipped entirely on
/// Zig-native because no in-process wasm runtime existed; now they
/// run end-to-end when the build was compiled with `-Dplugin-exec=true`
/// (the default). Builds with `plugin_exec=false` still skip them so
/// contributors without libwasmtime can run `zig build test`.
///
/// The `cross-ref-provider-*` family is split rather than prefixed,
/// because only part of it needs a runtime. Its three aggregate-tier
/// cases reject the *schema* before any document is read, and
/// `-unavailable` declares a provider with no `:impl` at all — so all
/// four answer identically whether or not plugins can run, and skipping
/// them would be pure coverage loss. The rest reach a `lines.wasm`.
fn isPluginExecCase(name: []const u8) bool {
    if (comptime build_options.plugin_exec) return false;
    if (std.mem.startsWith(u8, name, "plugin-exec-")) return true;
    if (!std.mem.startsWith(u8, name, "cross-ref-provider-")) return false;
    return !isRuntimeFreeProviderCase(name);
}

/// The `cross-ref-provider-*` cases that need no wasm runtime. Shared
/// with `hosts/typescript-parity`'s host-local skip family, which draws
/// the line in a *different* place — it also skips `-unavailable`,
/// because its validator has no provider route at all and would build
/// the member set the identity way. Two different gaps, so two lists;
/// the reasons are stated at each.
fn isRuntimeFreeProviderCase(name: []const u8) bool {
    for ([_][]const u8{
        "cross-ref-provider-unknown",
        "cross-ref-provider-ambiguous",
        "cross-ref-provider-source-key-unknown",
        "cross-ref-provider-unavailable",
    }) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

test "conformance: the provider family's runtime split covers both sides" {
    // Positive and negative space, asserted separately: a case that needs
    // `lines.wasm` and one of each kind that does not. Written against
    // `isRuntimeFreeProviderCase` rather than `isPluginExecCase` so it
    // says the same thing on a `plugin_exec=true` build, where the outer
    // predicate is constant-false.
    try testing.expect(!isRuntimeFreeProviderCase("cross-ref-provider-resolved"));
    try testing.expect(!isRuntimeFreeProviderCase("cross-ref-provider-overflow"));
    try testing.expect(isRuntimeFreeProviderCase("cross-ref-provider-unknown"));
    try testing.expect(isRuntimeFreeProviderCase("cross-ref-provider-unavailable"));
    // Not a prefix rule: the family name is not itself a member, and the
    // identity-route `cross-ref-*` cases are untouched.
    try testing.expect(!isRuntimeFreeProviderCase("cross-ref-missing"));
}

test "conformance: legacy cases via host pass" {
    const a = testing.allocator;
    const io = std.testing.io;

    var cases = try discoverCases(a, io);
    defer {
        for (cases.items) |c| a.free(c.name);
        cases.deinit(a);
    }

    // Pin the dual-pass guarantee: every legacy case (modulo the
    // documented host-divergent allowlist) runs through both the
    // pre-compose path (existing `runLegacyCase`) and the host adapter
    // (`runLegacyCaseAsHost`). Same `(code, path)` stream from both. If
    // a divergence appears here that doesn't appear in the existing
    // `corpus runs` test, the host pipeline drifted from the
    // parser/validator pipeline.
    var failures: usize = 0;
    for (cases.items) |c| {
        if (c.kind != .legacy) continue;
        if (isHostPassSkipped(c.name)) continue;
        if (isPluginExecCase(c.name)) continue;
        runLegacyCaseAsHost(a, c.name) catch |err| {
            std.debug.print("\nconformance host-pass case `{s}` failed: {s}\n", .{ c.name, @errorName(err) });
            failures += 1;
        };
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

/// Legacy cases whose tree and binary input-validation streams agree on
/// `(code, severity)` and count but diverge on a diagnostic PATH SEGMENT —
/// a residual the binary walker's path construction hasn't closed yet.
/// They are pinned as single-path characterization tests in
/// `Validator_tests.zig` (the union-div / expr-div blocks); skipping them
/// here keeps the replay honest for every other case while the residual
/// stands.
///
/// `expr-result-arg-mismatch` — a form-valued expression argument
///   (`(sum (vec-result) 1)`). The tree labels the failing arg by its
///   positional ordinal (`[sum 0]`, the corpus-pinned canonical path); the
///   binary walker labels the form child by its head (`[sum vec-result]`)
///   because `computeBinaryPathPair`'s `.positional` step uses the head for
///   any form. Same `expr_type_mismatch`, same count — path only. See
///   `Validator_tests.zig` "[expr-div 4]".
const BINARY_REPLAY_SKIP = [_][]const u8{
    "expr-result-arg-mismatch",
};

fn isBinaryReplaySkipped(name: []const u8) bool {
    for (BINARY_REPLAY_SKIP) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

test "conformance: legacy cases replay through binary validator" {
    const a = testing.allocator;
    const io = std.testing.io;

    var cases = try discoverCases(a, io);
    defer {
        for (cases.items) |c| a.free(c.name);
        cases.deinit(a);
    }

    // Dual-path invariant across the corpus: every legacy case's Phase-3
    // input validation emits an identical (code, severity, path) stream
    // whether walked over the tree or the binary IR (modulo the documented
    // vector-element exemption and the BINARY_REPLAY_SKIP path residuals).
    // A KeySpec / value-kind feature added to one walker but not the other
    // surfaces here — even if `expected.sjon` (tree-only) still matches.
    // Inline and query shapes are covered by 2.5 and the PatternQuery
    // property tests respectively.
    var failures: usize = 0;
    for (cases.items) |c| {
        if (c.kind != .legacy) continue;
        if (isPluginExecCase(c.name)) continue;
        if (isBinaryReplaySkipped(c.name)) continue;
        replayLegacyCaseBinary(a, c.name) catch |err| {
            std.debug.print("\nbinary-replay case `{s}` failed: {s}\n", .{ c.name, @errorName(err) });
            failures += 1;
        };
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "conformance: inline cases replay through binary validator" {
    const a = testing.allocator;
    const io = std.testing.io;

    var cases = try discoverCases(a, io);
    defer {
        for (cases.items) |c| a.free(c.name);
        cases.deinit(a);
    }

    // Dual-path invariant across the inline-manifest corpus: every case's
    // data-forest validation emits an identical (code, severity, path)
    // stream whether walked over the tree or the binary IR (modulo the
    // vector-element exemption and BINARY_REPLAY_SKIP path residuals). The
    // inline shape (2.5) complements the legacy shape (2.4): here the input
    // is a full document driven through `Host.validateDocument`, and the two
    // walkers run over the resolved `data_forest` under `Options{}` (the
    // binary walker takes none). `.query` cases are excluded by the kind
    // filter — PatternQuery parity is covered by its own property tests.
    // `numeric-vector-elementwise-bound` is live proof the exemption arm
    // fires here (tree wraps at the slot, binary fires per element).
    var failures: usize = 0;
    for (cases.items) |c| {
        if (c.kind != .inline_manifest) continue;
        if (isPluginExecCase(c.name)) continue;
        if (isBinaryReplaySkipped(c.name)) continue;
        replayInlineCaseBinary(a, c.name) catch |err| {
            std.debug.print("\nbinary-replay inline case `{s}` failed: {s}\n", .{ c.name, @errorName(err) });
            failures += 1;
        };
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
