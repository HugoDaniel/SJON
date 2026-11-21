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
const wasm_schema_handles = @import("wasm_schema_handles.zig");
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
        \\","exports":["parse","print","validate","eval_expr","query_pattern","to_json","from_json","apply_edit","apply_edits","to_binary","from_binary","validate_binary","eval_expr_binary","host_validate_document","host_eval_expr","preload_schema","schema_free","export_schema","export_lowering_graph","describe"],"plugins":["core","pattern"]}
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
/// of edit actions applied left-to-right in a single pass (see
/// `Edit.applyEdits`). A malformed array or a failing action surfaces the
/// usual framed error (`InvalidAction` / `PathNotFound` / …) — batches are
/// all-or-nothing.
///
/// `opts` is a JSON object, `{"layout": "reprint" | "preserve"}`, empty
/// for the default. Under `reprint` (the default, and what
/// `sjon_apply_edit` always does) the payload is the whole document
/// re-printed in `.full` mode; under `preserve` it is the source with one
/// span replaced per action and every other byte the author's.
export fn sjon_apply_edits(
    src_ptr: [*]const u8,
    src_len: u32,
    actions_ptr: [*]const u8,
    actions_len: u32,
    opts_ptr: [*]const u8,
    opts_len: u32,
) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runApplyEdits(
        src_ptr[0..src_len],
        actions_ptr[0..actions_len],
        opts_ptr[0..opts_len],
    ));
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
/// heldSymbol?, hasResolver, preloadedHandle? }`. `hasResolver=true`
/// enables the JS bridge; `false` behaves like calling
/// `Host.validateDocument` with `resolver=null` (every reference fails as
/// `unresolved_plugin`). `heldSymbol` names the spelling of a position
/// the author has deliberately not filled in yet — the assertion "this
/// document is being typed", made by whoever invoked the validator.
/// `preloadedHandle` (a `sjon_preload_schema` handle from this instance;
/// `null`/absent is today's behavior) borrows one preloaded schema for
/// this one call; a stale/unknown/foreign ID frames
/// `InvalidSchemaHandle`.
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
/// `sjon_host_validate_document` — including `preloadedHandle`, which
/// borrows a preloaded schema the same way; framed payload is the JSON
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

// -- P3 preloaded-schema handle exports --------------------------------------

/// The instance's preloaded-schema ownership record. Instance-scoped and
/// single-threaded: one `sjon.wasm` instance is driven only from its own
/// synchronous export boundary — a wasm instance cannot run two exports
/// concurrently over its linear memory — so nothing here adds
/// synchronization, exactly as `wasm_schema_handles.Table`'s single-
/// instance ownership rule documents. A wasm module global is per-
/// instance state, so two instantiations of the same artifact own
/// disjoint tables. Raw ABI IDs carry no owner token: a foreign ID that
/// collides with a live local ID is indistinguishable at this layer (the
/// Web/Rust wrappers brand handles per host on top), while a foreign,
/// stale, or unknown ID with no live local entry resolves as
/// `InvalidSchemaHandle`. Stale IDs can never alias a newer schema —
/// `wasm_schema_handles.zig` §"Why a stale handle can never alias a newer
/// schema" owns that argument (monotonic `next`, remove-before-destroy
/// `free`, the wraparound exhaustion sentinel).
var preloaded_schemas: wasm_schema_handles.Table = .{};

/// Preload a schema once from a set of standalone `(plugin …)` manifest
/// sources (P3). `src` is one UTF-8 JSON **array** of manifest source
/// strings in a caller-allocated buffer; each entry must be a single
/// top-level `(plugin …)` form. The framed payload (a normal
/// `[u32 ok][u32 len][…]` frame, freed with `sjon_free(ptr, 8 + len)`) is
/// the report written by `host_json.writePreloadedSchemaReport`:
/// `{"handle":N,"hasErrors":…,"diagnostics":[…],"sourceDiagnostics":[[…]],
/// "aggregateDiagnostics":[…],"loadedPlugins":[…]}`.
///
/// Manifest content problems are *successful* framed responses (`ok=1`)
/// carrying a usable partial handle plus diagnostics — the native
/// `Host.preloadSchema` contract, unchanged. `ok=0` is reserved for ABI
/// failures: `InvalidOptions` (malformed JSON, non-array input, non-string
/// members), `HandleExhausted`, and OOM (`null`). OOM after the handle is
/// minted withdraws it again, so no unreachable-but-live schema is left in
/// linear memory.
///
/// The borrow lasts for the synchronous validate/eval call that cites the
/// handle via the `preloadedHandle` option; raw callers must not free
/// during that call. Release with `sjon_schema_free`. Declarative
/// manifests only: `:impl "wasm:…"` plugins are not instantiated here.
export fn sjon_preload_schema(src_ptr: [*]const u8, src_len: u32) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runPreloadSchema(src_ptr[0..src_len]));
}

/// Release the schema behind `handle`. Total and idempotent: zero,
/// unknown, and already-freed IDs are no-ops, so a double free is silent
/// rather than a trap. The next minted handle is a fresh nonzero ID —
/// freed IDs are never reissued.
export fn sjon_schema_free(handle: u32) callconv(.c) void {
    preloaded_schemas.free(wasm_allocator, handle);
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

/// Address the node at `[start, end)`: the framed payload is
/// `{"root":N,"path":[…],"span":[a,b],"kind":"…"}`, or the JSON literal
/// `null` when the span is inside no root.
///
/// The point answer to ask 25's second direction, for a host holding a
/// span and not a table — a diagnostic's span, a selection, or a caret
/// (pass `start == end`). The node is the innermost *addressable* one
/// containing the span, so a span over a whole `:key value` pair answers
/// the enclosing form: §11.2 addresses a pair's value, and an edit over
/// the pair itself is a `set_keyword` on the form.
///
/// `root` and `path` are an action's two fields verbatim, so the answer
/// can be handed straight back to `sjon_apply_edits`. `span` and `kind`
/// ride along so one call decorates as well as addresses.
///
/// Offsets are UTF-8 bytes, the unit every other span SJON hands a host
/// is already in. Answers on the partial tree a recovery leaves behind:
/// the revision mid-keystroke is the one whose address is wanted.
export fn sjon_address_of_span(
    src_ptr: [*]const u8,
    src_len: u32,
    start: u32,
    end: u32,
) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runAddressOfSpan(src_ptr[0..src_len], start, end));
}

/// Every addressable node of the document, flat, in pre-order, with the
/// parse diagnostics beside it:
///
///     {"nodes":[{"i":0,"parent":-1,"root":0,"seg":null,"kind":"form",
///                "span":[128,180],"head_span":[129,134]}, …],
///      "diagnostics":[…]}
///
/// The bulk answer to ask 25, one call per revision. `seg` is the row's
/// own §11.2 path step — a string for a keyword value, an integer for a
/// positional child or a vector element, `null` for a root — so a row's
/// full path is the chain of `seg` up the `parent` links, and it is
/// §11.2 by construction rather than by a host's reading of an encoding.
/// `parent` is `-1` on a root. `head_span` and `key_span` are present
/// only on the rows that have one; `key_span` rides on the *value's* row,
/// because a kvpair is addressed through rather than at and so gets no
/// row of its own.
///
/// Pre-order means a parent always precedes its children and siblings are
/// in source order, so the innermost node containing a byte is the last
/// row whose span contains it: hit-testing is one scan on the host side,
/// with no call back in per pointer move.
///
/// Offsets are UTF-8 bytes. Rows are emitted for a partial tree too — the
/// diagnostics say whether that is what you have.
export fn sjon_node_table(src_ptr: [*]const u8, src_len: u32) callconv(.c) ?[*]u8 {
    return common.guard(wasm_allocator, runNodeTable(src_ptr[0..src_len]));
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

    // std's stringifier recurses on the host stack over the value; the
    // value mirrors the parsed tree, so its depth is ≤ Parser.MAX_PARSE_DEPTH.
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

fn runApplyEdits(src_bytes: []const u8, actions_bytes: []const u8, opts_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    const opts = try parseEditOptions(a, opts_bytes);
    // `applyEditsFromJsonString` owns the JSON parse arena and deep-copies
    // every embedded value, so the actions buffer is fully consumed here.
    const out = try Edit.applyEditsFromJsonString(wasm_allocator, src, actions_bytes, opts);
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
        .held_symbol = opts.held_symbol,
        .preloaded = if (opts.preloaded_handle) |h| try preloaded_schemas.get(h) else null,
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
        .preloaded = if (opts.preloaded_handle) |h| try preloaded_schemas.get(h) else null,
    };

    var result = try Host.evalExpr(wasm_allocator, src, host_options);
    defer result.deinit();

    const json_text = try host_json.writeHostEvalResult(a, result);
    return try common.frame(wasm_allocator, true, json_text);
}

/// The minted handle plus the table-owned schema it names. `runPreloadSchema`
/// needs both to serialize the report; returning them as a pair keeps the
/// lookup from being re-derived (and keeps the impossible `get`-after-`put`
/// miss out of the error surface).
const MintedHandle = struct {
    handle: u32,
    schema: *const Host.PreloadedSchema,
};

/// Allocate, preload, and insert one schema into the instance table.
///
/// Ownership crosses to the table ONLY on the successful return; on any
/// failure (`Host.preloadSchema` OOM, `Table.put` OOM/`HandleExhausted`)
/// ownership never left this function and the schema is deinited and
/// destroyed here — `Table.put`'s documented contract. Keeping the
/// transfer inside this helper is what lets the caller's `errdefer`
/// release the handle unconditionally after it: the pre-put failure paths
/// are already clean by the time `handle` exists.
fn preloadIntoTable(sources: []const [:0]const u8) !MintedHandle {
    const schema = try wasm_allocator.create(Host.PreloadedSchema);
    errdefer wasm_allocator.destroy(schema);
    schema.* = try Host.preloadSchema(wasm_allocator, sources);
    errdefer schema.deinit();
    const handle = try preloaded_schemas.put(wasm_allocator, schema);
    return .{ .handle = handle, .schema = schema };
}

fn runPreloadSchema(src_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sources = try parseManifestSources(a, src_bytes);
    const minted = try preloadIntoTable(sources);
    // From here the table owns the schema. If the report or the frame
    // OOMs, withdraw the handle rather than stranding an unreachable
    // schema in linear memory — nothing on the JS side could ever free it.
    errdefer preloaded_schemas.free(wasm_allocator, minted.handle);

    const json_text = try host_json.writePreloadedSchemaReport(a, minted.handle, minted.schema);
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

/// `[a,b]` — the span shape the address exports use. Two numbers, not an
/// object: a node span is a pair of byte offsets and nothing else, and
/// the table repeats it once per row. `appendDiagnostic`'s object form
/// stays what it is; that one is shared with the read-only artifact and
/// has consumers.
fn appendSpanArray(buf: *std.ArrayList(u8), a: std.mem.Allocator, span: sjon.Ast.Span) !void {
    try buf.append(a, '[');
    try common.appendUint(buf, a, span.start);
    try buf.append(a, ',');
    try common.appendUint(buf, a, span.end);
    try buf.append(a, ']');
}

/// `{"root":N,"path":[…],"span":[a,b],"kind":"…"}` for one table row.
/// Shared by both address exports so a point answer and a table row can
/// never disagree about how an address is spelled.
fn appendRowAddress(
    buf: *std.ArrayList(u8),
    a: std.mem.Allocator,
    table: Edit.NodeTable,
    row_idx: u32,
) !void {
    const row = table.rows[row_idx];
    const address = try table.addressOfRow(a, row_idx);
    defer address.deinit();

    try buf.appendSlice(a, "{\"root\":");
    try common.appendUint(buf, a, address.root);
    try buf.appendSlice(a, ",\"path\":[");
    for (address.steps, 0..) |step, i| {
        if (i > 0) try buf.append(a, ',');
        switch (step) {
            .key => |k| try common.appendJsonString(buf, a, k),
            .index => |n| try common.appendUint(buf, a, n),
        }
    }
    try buf.appendSlice(a, "],\"span\":");
    try appendSpanArray(buf, a, row.span);
    try buf.appendSlice(a, ",\"kind\":\"");
    try buf.appendSlice(a, @tagName(row.tag));
    try buf.appendSlice(a, "\"}");
}

fn runNodeTable(src_bytes: []const u8) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = try toSentinel(a, src_bytes);
    var tree = try Parser.parse(wasm_allocator, src);
    defer tree.deinit();

    const table = try Edit.nodeTable(a, &tree);
    defer table.deinit();

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\"nodes\":[");
    for (table.rows, 0..) |row, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.appendSlice(a, "{\"i\":");
        try common.appendUint(&buf, a, @intCast(i));
        try buf.appendSlice(a, ",\"parent\":");
        if (row.parent) |p| {
            try common.appendUint(&buf, a, p);
        } else {
            // -1, not null: `parent` is an index into this same array and
            // a host reads it as one, so the absent case stays a number.
            try buf.appendSlice(a, "-1");
        }
        try buf.appendSlice(a, ",\"root\":");
        try common.appendUint(&buf, a, row.root);
        try buf.appendSlice(a, ",\"seg\":");
        if (row.seg) |seg| switch (seg) {
            .key => |k| try common.appendJsonString(&buf, a, k),
            .index => |n| try common.appendUint(&buf, a, n),
        } else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ",\"kind\":\"");
        try buf.appendSlice(a, @tagName(row.tag));
        try buf.appendSlice(a, "\",\"span\":");
        try appendSpanArray(&buf, a, row.span);
        // The two optional channels are omitted rather than nulled: a row
        // either has a head or is not a form, and either is a pair's value
        // or is not.
        if (row.head_span) |h| {
            try buf.appendSlice(a, ",\"head_span\":");
            try appendSpanArray(&buf, a, h);
        }
        if (row.key_span) |k| {
            try buf.appendSlice(a, ",\"key_span\":");
            try appendSpanArray(&buf, a, k);
        }
        try buf.append(a, '}');
    }
    try buf.appendSlice(a, "],\"diagnostics\":[");
    for (tree.diagnostics, 0..) |d, i| {
        if (i > 0) try buf.append(a, ',');
        try common.appendDiagnostic(&buf, a, d);
    }
    try buf.appendSlice(a, "]}");
    return try common.frame(wasm_allocator, true, buf.items);
}

fn runAddressOfSpan(src_bytes: []const u8, start: u32, end: u32) ![*]u8 {
    var arena = std.heap.ArenaAllocator.init(wasm_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A backwards range is the caller's mistake, not a document's, so it
    // is refused rather than normalised — silently swapping the ends
    // would answer a question nobody asked. An *empty* range is not that:
    // it is a caret, and it is answered like any other.
    //
    // The refusal is a bare framed name rather than an `Edit.Error`
    // variant: nothing in Zig can construct this input (both ends are
    // `u32`s from the ABI boundary, and every Zig caller passes an
    // `Ast.Span`), so an error variant would be dead in every set that
    // had to carry it.
    if (end < start) return try common.frame(wasm_allocator, false, "InvalidSpan");

    const src = try toSentinel(a, src_bytes);
    var tree = try Parser.parse(wasm_allocator, src);
    defer tree.deinit();

    const table = try Edit.nodeTable(a, &tree);
    defer table.deinit();

    const row = table.rowContaining(.{ .start = start, .end = end }) orelse
        return try common.frame(wasm_allocator, true, "null");

    var buf: std.ArrayList(u8) = .empty;
    try appendRowAddress(&buf, a, table, row);
    return try common.frame(wasm_allocator, true, buf.items);
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

/// `{"layout": "reprint" | "preserve"}`. The default is `.reprint`, which
/// is what every consumer of this export got before the blob existed;
/// `sjon_apply_edit` has no blob and stays on it.
fn parseEditOptions(a: std.mem.Allocator, opts_bytes: []const u8) !Edit.Options {
    var opts: Edit.Options = .{};
    if (opts_bytes.len == 0) return opts;
    const parsed = std.json.parseFromSlice(std.json.Value, a, opts_bytes, .{}) catch
        return error.InvalidOptions;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidOptions,
    };
    if (obj.get("layout")) |v| switch (v) {
        .string => |s| opts.layout = std.meta.stringToEnum(Edit.Layout, s) orelse
            return error.InvalidOptions,
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

/// Decode `src_bytes` as one UTF-8 JSON array of manifest source strings,
/// copying each member to sentinel form in the scratch arena (`Parser`
/// reads `[:0]const u8`, and the sources must outlive nothing —
/// `Host.preloadSchema` deep-copies what it keeps into its own arenas).
/// Anything else — malformed JSON, a non-array value, a non-string member
/// — is `InvalidOptions`, the same refusal the other option surfaces
/// share; a bad *manifest* is never refused here, it becomes report
/// diagnostics inside `ok=1`.
fn parseManifestSources(a: std.mem.Allocator, src_bytes: []const u8) ![]const [:0]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, a, src_bytes, .{}) catch
        return error.InvalidOptions;
    const arr = switch (parsed.value) {
        .array => |arr| arr,
        else => return error.InvalidOptions,
    };
    const sources = try a.alloc([:0]const u8, arr.items.len);
    for (arr.items, 0..) |item, i| {
        const s = switch (item) {
            .string => |s| s,
            else => return error.InvalidOptions,
        };
        sources[i] = try toSentinel(a, s);
    }
    return sources;
}

const ParsedHostOptions = struct {
    failure_policy: Host.FailurePolicy = .lenient,
    project_root: ?[]const u8 = null,
    project_file: ?[]const u8 = null,
    has_resolver: bool = false,
    held_symbol: ?[]const u8 = null,
    /// A live handle from this instance's `sjon_preload_schema` table;
    /// absent/null is today's no-preloaded-schema behavior. Positive
    /// integral `u32` IDs only — zero, negatives, floats, and non-numbers
    /// are `InvalidOptions`; a handle the table does not recognize
    /// (stale, unknown, or foreign) is `InvalidSchemaHandle` at use, not
    /// at parse, so the refusal names the actual problem.
    preloaded_handle: ?u32 = null,
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
    // The one option here that says something about the *document* rather
    // than about where its plugins live: "this document is being typed, so a
    // position spelled with this symbol is one the author has deliberately
    // not filled in yet". Any string is accepted — SJON does not police the
    // name (see `Validator.Options.held_symbol`), and one that does not lex
    // as a symbol simply never matches.
    if (obj.get("heldSymbol")) |v| switch (v) {
        .string => |sym| opts.held_symbol = sym,
        .null => {},
        else => return error.InvalidOptions,
    };
    // `preloadedHandle` borrows one preloaded schema for this call:
    // `sjon_host_validate_document` and `sjon_host_eval_expr` resolve it
    // against the instance table (the export-schema entries parse the
    // shared shape and ignore it, exactly as they ignore `heldSymbol`).
    // `null` and absent are today's behavior; the value must be a positive
    // integral `u32` (handles are minted from 1 and never skip the range),
    // so a float, a string, or zero is an options refusal rather than a
    // handle error — the ID has not been *used* yet, only misspelled.
    if (obj.get("preloadedHandle")) |v| switch (v) {
        .null => {},
        .integer => |n| {
            if (n < 1 or n > std.math.maxInt(u32)) return error.InvalidOptions;
            opts.preloaded_handle = @intCast(n);
        },
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
