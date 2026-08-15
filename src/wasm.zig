//! WASM entry point — exposes a minimal C ABI for editor / web consumers.
//!
//! Output framing (every output-returning function): a single allocation in
//! the wasm linear memory of `[u32 ok][u32 len][u8... payload]` (8-byte
//! header + payload). The JS host reads:
//!
//!   const ok  = view.getUint32(ptr,     true);
//!   const len = view.getUint32(ptr + 4, true);
//!   const buf = new Uint8Array(memory.buffer, ptr + 8, len);
//!   sjon_free(ptr, 8 + len);
//!
//! `ok == 1` → payload is the operation's result (printed text or JSON
//! or raw binary IR). `ok == 0` → payload is a UTF-8 error name.
//!
//! Inputs are caller-allocated buffers (use `sjon_alloc` / `sjon_free` from
//! JS). All input pointers must remain valid for the duration of the call.
//!
//! The kitchen-sink artifact ships the `core` schema plus binary IR exports:
//! `sjon_to_binary`, `sjon_from_binary`, `sjon_validate_binary`,
//! `sjon_eval_expr_binary`. The read-only `sjon-binary.wasm` artifact
//! (Phase B5) exports only the binary inputs.
//!
//! Every ingest body reaches the canonical SoA `Ast.Tree` entrypoints
//! (`Parser.parse`, `Json.fromJson`, `Binary.fromBinary`) directly.
//! `Edit.applyEdit` is a functional rebuild on `Ast.Tree`.

const std = @import("std");
const sjon = @import("root.zig");
const common = @import("wasm_common.zig");
const host_json = @import("wasm_host_json.zig");
const wasm_host_resolver = @import("wasm_host_resolver.zig");
// Force-import so the `env.sjon_host_invoke_plugin` extern declaration
// reaches the wasm linker even when nothing in `sjon.wasm`'s exports
// transitively reference the invoker. `Expr.applyFunction` does call it,
// but only along paths that need a runtime schema with a `wasm_export_name`
// plugin — keeping a top-level reference here pins the import unconditionally.
const wasm_plugin_invoker = @import("wasm_plugin_invoker.zig");
comptime {
    _ = wasm_plugin_invoker;
}

const Schema = sjon.Schema;
const Parser = sjon.Parser;
const Printer = sjon.Printer;
const Validator = sjon.Validator;
const Json = sjon.Json;
const Edit = sjon.Edit;
const Expr = sjon.Expr;
const Binary = sjon.Binary;
const Host = sjon.Host;
const PatternQuery = sjon.PatternQuery;

const wasm_allocator = std.heap.wasm_allocator;

/// The built-in schema: only the `core` expression vocabulary is registered.
/// The construction is single-sourced in `wasm_common` (shared with the
/// read-only artifact); this is a thin alias for the tree-path exports below.
const core_schema = common.core_schema;

/// Pattern-query schema: `core` + the `pattern` combinators. Used only by
/// the pattern-query export so the default document schema is untouched.
const pattern_schema: Schema.Schema = Schema.Schema.init(&.{ sjon.plugins.core.plugin, sjon.plugins.pattern.plugin });

// ---------------------------------------------------------------------------
// Allocation helpers — the JS input/output memory bridge. `sjon_alloc` /
// `sjon_free` live in the shared `wasm_common` leaf (identical in the
// read-only artifact); force-reference them so the exports land here.
// ---------------------------------------------------------------------------

comptime {
    _ = common.sjon_alloc;
    _ = common.sjon_free;
}

// ---------------------------------------------------------------------------
// Exports — every function returns a framed buffer pointer or null on OOM.
// ---------------------------------------------------------------------------

export fn sjon_describe() callconv(.c) ?[*]u8 {
    const text =
        \\{"name":"sjon","version":"
    ++ sjon.version ++
        \\","exports":["parse","print","validate","eval_expr","query_pattern","to_json","from_json","apply_edit","apply_edits","to_binary","from_binary","validate_binary","eval_expr_binary","host_validate_document","host_eval_expr","export_schema","export_lowering_graph","describe"],"plugins":["core","pattern"]}
    ;
    return common.frame(wasm_allocator, true, text) catch null;
}

export fn sjon_parse(src_ptr: [*]const u8, src_len: u32) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runParse(src_ptr[0..src_len]));
}

export fn sjon_print(
    src_ptr: [*]const u8,
    src_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runPrint(src_ptr[0..src_len], opts_ptr[0..opts_len]));
}

export fn sjon_validate(src_ptr: [*]const u8, src_len: u32) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runValidate(src_ptr[0..src_len]));
}

export fn sjon_eval_expr(src_ptr: [*]const u8, src_len: u32) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runEvalExpr(src_ptr[0..src_len]));
}

/// Query a pattern document over `[begin, end)` ticks with RNG `seed`,
/// returning framed `(haps …)` text (or `(diagnostics …)` when the query
/// collected any). i64 args ↔ JS BigInt.
export fn sjon_query_pattern(
    src_ptr: [*]const u8,
    src_len: u32,
    begin: i64,
    end: i64,
    seed: i64,
) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runQueryPattern(src_ptr[0..src_len], begin, end, seed));
}

export fn sjon_to_json(
    src_ptr: [*]const u8,
    src_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runToJson(src_ptr[0..src_len], opts_ptr[0..opts_len]));
}

export fn sjon_from_json(json_ptr: [*]const u8, json_len: u32) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runFromJson(json_ptr[0..json_len]));
}

export fn sjon_apply_edit(
    src_ptr: [*]const u8,
    src_len: u32,
    action_ptr: [*]const u8,
    action_len: u32,
) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runApplyEdit(src_ptr[0..src_len], action_ptr[0..action_len]));
}

/// Batched counterpart to `sjon_apply_edit`: `actions` is a JSON **array**
/// of edit actions applied left-to-right in a single parse/print pass (see
/// `Edit.applyEdits`). The framed payload is the re-printed `.full` SJON
/// text; a malformed array or a failing action surfaces the usual framed
/// error (`InvalidAction` / `PathNotFound` / …) — batches are all-or-nothing.
export fn sjon_apply_edits(
    src_ptr: [*]const u8,
    src_len: u32,
    actions_ptr: [*]const u8,
    actions_len: u32,
) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runApplyEdits(src_ptr[0..src_len], actions_ptr[0..actions_len]));
}

// -- Binary IR exports -------------------------------------------------------

export fn sjon_to_binary(src_ptr: [*]const u8, src_len: u32) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runToBinary(src_ptr[0..src_len]));
}

export fn sjon_from_binary(bin_ptr: [*]const u8, bin_len: u32) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runFromBinary(bin_ptr[0..bin_len]));
}

// The binary-path exports bind `core_schema` (shared, `wasm_common`) to the
// shared `runValidateBinary` / `runEvalExprBinary`. The three-line wrapper
// stays per-entry so the read-only artifact carries the same two exports
// without the LSP artifact (which imports `wasm_common` only for its JSON
// writers) force-inheriting them.
export fn sjon_validate_binary(bin_ptr: [*]const u8, bin_len: u32) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, common.runValidateBinary(wasm_allocator, bin_ptr[0..bin_len], core_schema));
}

export fn sjon_eval_expr_binary(bin_ptr: [*]const u8, bin_len: u32) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, common.runEvalExprBinary(wasm_allocator, bin_ptr[0..bin_len], core_schema));
}

// -- D5 host-pipeline export ------------------------------------------------

/// Validate a document through the cross-host `Host.validateDocument`
/// pipeline. Wraps inline-manifest declarations + `(use-plugin …)`
/// references against the user-supplied JS resolver bound at WASM
/// instantiation time (see `src/wasm_host_resolver.zig`).
///
/// `opts_bytes` is JSON `{ projectRoot?, projectFile?, failurePolicy?,
/// hasResolver }`. `hasResolver=true` enables the JS bridge; `false`
/// behaves like calling `Host.validateDocument` with `resolver=null`
/// (every reference fails as `unresolved_plugin`).
export fn sjon_host_validate_document(
    src_ptr: [*]const u8,
    src_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runHostValidateDocument(src_ptr[0..src_len], opts_ptr[0..opts_len]));
}

/// Evaluate a single SJON expression against the host's aggregated
/// plugin schema. Reuses the same resolver bridge + options shape as
/// `sjon_host_validate_document`; framed payload is the JSON
/// `{ value, diagnostics, loadedPlugins }` shape produced by
/// `host_json.writeHostEvalResult`. Plugin expr-funcs (`(double 21)`,
/// `(count-done items)`, …) dispatch through the resolved schema.
export fn sjon_host_eval_expr(
    src_ptr: [*]const u8,
    src_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runHostEvalExpr(src_ptr[0..src_len], opts_ptr[0..opts_len]));
}

/// Export a JSON Schema 2020-12 + TypeScript `.d.ts` (+ optionally an
/// intermediate IR) from a SJON source declaring its plugins inline or
/// via `(use-plugin …)`. Mirrors `Host.exportSchemaFromSource`: parses,
/// aggregates, validates lenient, then lowers + emits. The framed
/// payload is the single JSON envelope produced by
/// `host_json.writeExportSchemaResult` — one document carries every emitted
/// artifact (aggregated or per-plugin), the export warnings, and the
/// aggregate-phase host diagnostics.
///
/// `opts_bytes` is JSON `{ target?, layout?, draft?, projectRoot?,
/// projectFile?, failurePolicy?, hasResolver? }`. `target` ∈
/// `"json-schema" | "typescript" | "both" | "intermediate"`; `layout` ∈
/// `"aggregated" | "per-plugin"`; `draft` accepts only `"2020-12"` in
/// M4 (other values yield `InvalidOptions`).
export fn sjon_export_schema(
    src_ptr: [*]const u8,
    src_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runExportSchema(src_ptr[0..src_len], opts_ptr[0..opts_len]));
}

/// Render the document's aggregate `:lowering :produces` DAG as SJON.
/// Mirrors `Host.exportLoweringGraphFromSource`: parses, aggregates, then
/// renders the static graph. The framed payload is the `(lowering-graph
/// …)` SJON text itself (not a JSON envelope) — a cyclic aggregate still
/// renders so the cycle is visible. `opts_bytes` is the shared host JSON
/// `{ projectRoot?, projectFile?, failurePolicy?, hasResolver? }`.
export fn sjon_export_lowering_graph(
    src_ptr: [*]const u8,
    src_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runExportLoweringGraph(src_ptr[0..src_len], opts_ptr[0..opts_len]));
}

/// Peek a plugin manifest's identity for host pre-flight: the framed
/// payload is `{"name": string|null, "wasm_impls": string[]}`. The host
/// keys its plugin pool on `name` and verifies every `wasm_impls` entry
/// exists as an export on the plugin binary. Structural (`Host.manifestMeta`)
/// — no source-order scraping, so a nested `(expr-func :name …)` cannot
/// shadow the plugin's own `:name`. `name` is null when `src` is not a
/// well-formed `(plugin …)` manifest.
export fn sjon_manifest_meta(src_ptr: [*]const u8, src_len: u32) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runManifestMeta(src_ptr[0..src_len]));
}

// ---------------------------------------------------------------------------
// Operation bodies
// ---------------------------------------------------------------------------

fn runParse(src_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    var tree = try Parser.parse(wasm_allocator, src);
    defer tree.deinit();

    const json_text = try common.parseDiagnosticsJson(a, tree.diagnostics);
    return try common.frame(wasm_allocator, true, json_text);
}

fn runPrint(src_bytes: []const u8, opts_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    var tree = try Parser.parse(wasm_allocator, src);
    defer tree.deinit();

    const opts = try parsePrintOptions(a, opts_bytes);
    const out = try Printer.print(wasm_allocator, tree, opts);
    defer out.deinit();
    return try common.frame(wasm_allocator, true, out.data);
}

fn runValidate(src_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    var tree = try Parser.parse(wasm_allocator, src);
    defer tree.deinit();

    var result = try Validator.validate(wasm_allocator, tree, core_schema);
    defer result.deinit();

    const json_text = try common.validatorDiagnosticsJson(a, tree.diagnostics, result);
    return try common.frame(wasm_allocator, true, json_text);
}

fn runEvalExpr(src_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    var tree = try Parser.parse(wasm_allocator, src);
    defer tree.deinit();

    if (tree.root.len != 1) return error.MultipleRoots;

    const env: Expr.Env = .{};
    var result = try Expr.eval(wasm_allocator, &tree, tree.root[0], &env, core_schema);
    defer result.deinit();

    const json_text = try common.valueToJson(a, result.value);
    return try common.frame(wasm_allocator, true, json_text);
}

fn runToJson(src_bytes: []const u8, opts_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    var tree = try Parser.parse(wasm_allocator, src);
    defer tree.deinit();

    const opts = try parseToJsonOptions(a, opts_bytes);
    var result = try Json.toJson(wasm_allocator, tree, opts);
    defer result.deinit();

    const out = try std.json.Stringify.valueAlloc(a, result.value, .{});
    return try common.frame(wasm_allocator, true, out);
}

fn runFromJson(json_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, a, json_bytes, .{}) catch
        return error.InvalidJson;

    var tree = try Json.fromJson(wasm_allocator, parsed.value, .{});
    defer tree.deinit();

    const out = try Printer.print(wasm_allocator, tree, .{});
    defer out.deinit();
    return try common.frame(wasm_allocator, true, out.data);
}

fn runApplyEdit(src_bytes: []const u8, action_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, a, action_bytes, .{}) catch
        return error.InvalidAction;

    const out = try Edit.applyEdit(wasm_allocator, src, parsed.value, .{});
    defer out.deinit();
    return try common.frame(wasm_allocator, true, out.data);
}

fn runApplyEdits(src_bytes: []const u8, actions_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    // `applyEditsFromJsonString` owns the JSON parse arena and deep-copies
    // every embedded value, so the actions buffer is fully consumed here.
    const out = try Edit.applyEditsFromJsonString(wasm_allocator, src, actions_bytes, .{});
    defer out.deinit();
    return try common.frame(wasm_allocator, true, out.data);
}

// -- Binary IR operation bodies ---------------------------------------------

fn runToBinary(src_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    var tree = try Parser.parse(wasm_allocator, src);
    defer tree.deinit();

    const out = try Binary.toBinary(wasm_allocator, tree, .{});
    defer out.deinit();
    return try common.frame(wasm_allocator, true, out.data);
}

fn runFromBinary(bin_bytes: []const u8) ![*]u8 {
    var tree = try Binary.fromBinary(wasm_allocator, bin_bytes, .{});
    defer tree.deinit();

    const out = try Printer.print(wasm_allocator, tree, .{});
    defer out.deinit();
    return try common.frame(wasm_allocator, true, out.data);
}

fn runQueryPattern(src_bytes: []const u8, begin: i64, end: i64, seed: i64) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    var tree = try Parser.parse(wasm_allocator, src);
    defer tree.deinit();
    if (tree.root.len != 1) return error.MultipleRoots;
    if (begin > end) return error.InvalidWindow;

    var result = try PatternQuery.queryTree(wasm_allocator, &tree, tree.root[0], pattern_schema, .{ .begin = begin, .end = end }, seed);
    defer result.deinit();

    const text = try PatternQuery.resultToText(a, result);
    return try common.frame(wasm_allocator, true, text);
}

fn runHostValidateDocument(src_bytes: []const u8, opts_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    const opts = try parseHostOptions(a, opts_bytes);

    const host_options: Host.HostOptions = .{
        .failure_policy = opts.failure_policy,
        .project_root = opts.project_root,
        .project_file = opts.project_file,
        .resolver = if (opts.has_resolver) wasm_host_resolver.build() else null,
    };

    var result = try Host.validateDocument(wasm_allocator, src, host_options);
    defer result.deinit();

    const json_text = try host_json.writeHostResult(a, result);
    return try common.frame(wasm_allocator, true, json_text);
}

fn runHostEvalExpr(src_bytes: []const u8, opts_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    const opts = try parseHostOptions(a, opts_bytes);

    const host_options: Host.HostOptions = .{
        .failure_policy = opts.failure_policy,
        .project_root = opts.project_root,
        .project_file = opts.project_file,
        .resolver = if (opts.has_resolver) wasm_host_resolver.build() else null,
    };

    var result = try Host.evalExpr(wasm_allocator, src, host_options);
    defer result.deinit();

    const json_text = try host_json.writeHostEvalResult(a, result);
    return try common.frame(wasm_allocator, true, json_text);
}

fn runExportSchema(src_bytes: []const u8, opts_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    const opts = try parseExportSchemaOptions(a, opts_bytes);

    const host_options: Host.HostOptions = .{
        .failure_policy = opts.failure_policy,
        .project_root = opts.project_root,
        .project_file = opts.project_file,
        .resolver = if (opts.has_resolver) wasm_host_resolver.build() else null,
    };

    const export_options: sjon.SchemaExport.ExportOptions = .{
        .target = opts.target,
        .layout = opts.layout,
        .draft = .@"2020-12",
    };

    var bundle = try Host.exportSchemaFromSource(wasm_allocator, src, host_options, export_options);
    defer bundle.deinit();

    const json_text = try host_json.writeExportSchemaResult(a, bundle);
    return try common.frame(wasm_allocator, true, json_text);
}

fn runExportLoweringGraph(src_bytes: []const u8, opts_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    const opts = try parseHostOptions(a, opts_bytes);

    const host_options: Host.HostOptions = .{
        .failure_policy = opts.failure_policy,
        .project_root = opts.project_root,
        .project_file = opts.project_file,
        .resolver = if (opts.has_resolver) wasm_host_resolver.build() else null,
    };

    var bundle = try Host.exportLoweringGraphFromSource(wasm_allocator, src, host_options);
    defer bundle.deinit();

    // The framed payload is the SJON graph text itself; diagnostics (if
    // any) stay queryable via sjon_host_validate_document.
    return try common.frame(wasm_allocator, true, bundle.sjon);
}

fn runManifestMeta(src_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const meta = try Host.manifestMeta(wasm_allocator, a, src_bytes);
    const json = try std.json.Stringify.valueAlloc(
        a,
        .{ .name = meta.name, .wasm_impls = meta.wasm_impls },
        .{},
    );
    return try common.frame(wasm_allocator, true, json);
}

// ---------------------------------------------------------------------------
// Option parsing (small, hand-rolled — no allocations on the host side)
// ---------------------------------------------------------------------------

/// Parse a JSON `"mode"` value into an `Ast.Mode` (canonical / compact /
/// full). Shared by the print and to-json option parsers — both carry an
/// `Ast.Mode` field and accepted the identical three strings.
fn parseMode(m: std.json.Value) !sjon.Mode {
    switch (m) {
        .string => |s| {
            if (std.mem.eql(u8, s, "canonical")) return .canonical;
            if (std.mem.eql(u8, s, "compact")) return .compact;
            if (std.mem.eql(u8, s, "full")) return .full;
            return error.InvalidOptions;
        },
        else => return error.InvalidOptions,
    }
}

fn parsePrintOptions(a: std.mem.Allocator, opts_bytes: []const u8) !Printer.Options {
    var opts: Printer.Options = .{};
    if (opts_bytes.len == 0) return opts;
    const parsed = std.json.parseFromSlice(std.json.Value, a, opts_bytes, .{}) catch
        return error.InvalidOptions;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidOptions,
    };
    if (obj.get("mode")) |m| {
        opts.mode = try parseMode(m);
    }
    if (obj.get("indent")) |i| switch (i) {
        .integer => |n| if (n >= 0 and n <= 16) {
            opts.indent = @intCast(n);
        } else return error.InvalidOptions,
        else => return error.InvalidOptions,
    };
    if (obj.get("wrap_at")) |w| switch (w) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u16)) {
            opts.wrap_at = @intCast(n);
        } else return error.InvalidOptions,
        else => return error.InvalidOptions,
    };
    return opts;
}

fn parseToJsonOptions(a: std.mem.Allocator, opts_bytes: []const u8) !Json.ToJsonOptions {
    var opts: Json.ToJsonOptions = .{ .schema = core_schema };
    if (opts_bytes.len == 0) return opts;
    const parsed = std.json.parseFromSlice(std.json.Value, a, opts_bytes, .{}) catch
        return error.InvalidOptions;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidOptions,
    };
    if (obj.get("mode")) |m| {
        opts.mode = try parseMode(m);
    }
    return opts;
}

const ParsedHostOptions = struct {
    failure_policy: Host.FailurePolicy = .lenient,
    project_root: ?[]const u8 = null,
    project_file: ?[]const u8 = null,
    has_resolver: bool = false,
};

fn parseHostOptions(a: std.mem.Allocator, opts_bytes: []const u8) !ParsedHostOptions {
    var opts: ParsedHostOptions = .{};
    if (opts_bytes.len == 0) return opts;
    const parsed = std.json.parseFromSlice(std.json.Value, a, opts_bytes, .{}) catch
        return error.InvalidOptions;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidOptions,
    };
    if (obj.get("projectRoot")) |v| switch (v) {
        .string => |s| opts.project_root = s,
        .null => {},
        else => return error.InvalidOptions,
    };
    if (obj.get("projectFile")) |v| switch (v) {
        .string => |s| opts.project_file = s,
        .null => {},
        else => return error.InvalidOptions,
    };
    if (obj.get("failurePolicy")) |v| switch (v) {
        .string => |s| {
            if (std.mem.eql(u8, s, "strict")) opts.failure_policy = .strict else if (std.mem.eql(u8, s, "lenient")) opts.failure_policy = .lenient else return error.InvalidOptions;
        },
        else => return error.InvalidOptions,
    };
    if (obj.get("hasResolver")) |v| switch (v) {
        .bool => |b| opts.has_resolver = b,
        else => return error.InvalidOptions,
    };
    return opts;
}

const ParsedExportSchemaOptions = struct {
    failure_policy: Host.FailurePolicy = .lenient,
    project_root: ?[]const u8 = null,
    project_file: ?[]const u8 = null,
    has_resolver: bool = false,
    target: sjon.SchemaExport.Target = .{},
    layout: sjon.SchemaExport.Layout = .aggregated,
};

fn parseExportSchemaOptions(a: std.mem.Allocator, opts_bytes: []const u8) !ParsedExportSchemaOptions {
    // projectRoot / projectFile / failurePolicy / hasResolver are exactly
    // parseHostOptions' surface — layer on it, then parse the export-only
    // target / layout / draft keys.
    const host = try parseHostOptions(a, opts_bytes);
    var opts: ParsedExportSchemaOptions = .{
        .failure_policy = host.failure_policy,
        .project_root = host.project_root,
        .project_file = host.project_file,
        .has_resolver = host.has_resolver,
    };
    if (opts_bytes.len == 0) return opts;
    const parsed = std.json.parseFromSlice(std.json.Value, a, opts_bytes, .{}) catch
        return error.InvalidOptions;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidOptions,
    };
    if (obj.get("target")) |v| switch (v) {
        .string => |s| {
            if (std.mem.eql(u8, s, "json-schema")) {
                opts.target = .{ .json_schema = true, .ts_types = false, .intermediate = false };
            } else if (std.mem.eql(u8, s, "typescript")) {
                opts.target = .{ .json_schema = false, .ts_types = true, .intermediate = false };
            } else if (std.mem.eql(u8, s, "both")) {
                opts.target = .{ .json_schema = true, .ts_types = true, .intermediate = false };
            } else if (std.mem.eql(u8, s, "intermediate")) {
                opts.target = .{ .json_schema = false, .ts_types = false, .intermediate = true };
            } else return error.InvalidOptions;
        },
        else => return error.InvalidOptions,
    };
    if (obj.get("layout")) |v| switch (v) {
        .string => |s| {
            if (std.mem.eql(u8, s, "aggregated")) opts.layout = .aggregated else if (std.mem.eql(u8, s, "per-plugin")) opts.layout = .per_plugin else return error.InvalidOptions;
        },
        else => return error.InvalidOptions,
    };
    if (obj.get("draft")) |v| switch (v) {
        .string => |s| {
            if (!std.mem.eql(u8, s, "2020-12")) return error.InvalidOptions;
        },
        else => return error.InvalidOptions,
    };
    return opts;
}

// ---------------------------------------------------------------------------
// Misc helpers
// ---------------------------------------------------------------------------

fn toSentinel(a: std.mem.Allocator, bytes: []const u8) ![:0]const u8 {
    const buf = try a.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf;
}
