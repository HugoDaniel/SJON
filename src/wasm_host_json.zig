//! Host-facing WASM JSON writers — the `Host.HostResult` /
//! `HostEvalResult` / `ExportSchemaBundle` serializers used by the
//! kitchen-sink `sjon.wasm` (never the read-only `sjon-binary.wasm`).
//!
//! Split out of `wasm_common.zig` so that module can stay a leaf over
//! `std + Ast + Expr + Validator`: these writers pull in Host, Plugin,
//! MaterializedDefaults, and SchemaExport, which must NOT enter the
//! read-only artifact's import closure (enforced by `audit-wasm-imports`).
//! The primitive JSON helpers (`appendValue`, `appendJsonString`,
//! `appendUint`, framing) stay in `wasm_common` and are reached here as
//! `common.*`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Host = @import("Host.zig");
const Plugin = @import("Plugin.zig");
const MaterializedDefaults = @import("MaterializedDefaults.zig");
const SchemaExport = @import("SchemaExport/SchemaExport.zig");
const common = @import("wasm_common.zig");

// ---------------------------------------------------------------------------
// HostResult JSON writer — used by `sjon_host_validate_document`.
// ---------------------------------------------------------------------------

/// Serialize a `Host.HostResult` as
/// `{"diagnostics":[…],"loadedPlugins":[…],"materializedDefaults":[…],"evaluatedResults":[…]}`.
/// Each diagnostic carries the host phase tag, original code, semantic
/// path, and an optional declaration span; each loaded plugin carries
/// `name`, `version` (always `null` — `:version` metadata is not stored
/// on `Plugin`), and `formCount`; each materialized-default entry
/// carries `path` (form-head + key-name), `key`, `origin`
/// (`literal_default` | `expression_default`), and `value` (JSON-
/// encoded `Expr.Value` via `appendValue`); each evaluated-result
/// entry carries `index` (the matching `data_forest` position) and
/// `value` (JSON-encoded `Expr.Value`). Mirrors the typescript-parity
/// `HostResult` shape so the Web host can hand the parsed object
/// straight back to consumers.
///
/// The `materializedDefaults` and `evaluatedResults` fields are always
/// present (empty arrays when the overlay / eval pass produced no
/// entries) so decoders don't have to special-case their absence.
pub fn writeHostResult(a: Allocator, result: Host.HostResult) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\"diagnostics\":[");
    for (result.diagnostics, 0..) |d, i| {
        if (i > 0) try buf.append(a, ',');
        try appendHostDiagnostic(&buf, a, d);
    }
    try buf.appendSlice(a, "],\"loadedPlugins\":[");
    for (result.plugins, 0..) |p, i| {
        if (i > 0) try buf.append(a, ',');
        try appendPluginSummary(&buf, a, p);
    }
    try buf.appendSlice(a, "],\"materializedDefaults\":[");
    for (result.materialized_defaults.entries, 0..) |entry, i| {
        if (i > 0) try buf.append(a, ',');
        try appendMaterializedEntry(&buf, a, &result.tree, entry);
    }
    try buf.appendSlice(a, "],\"evaluatedResults\":[");
    for (result.evaluated_results, 0..) |entry, i| {
        if (i > 0) try buf.append(a, ',');
        try appendEvaluatedResult(&buf, a, entry);
    }
    try buf.appendSlice(a, "]}");
    return buf.toOwnedSlice(a);
}

fn appendEvaluatedResult(
    buf: *std.ArrayList(u8),
    a: Allocator,
    entry: Host.EvalResult,
) Allocator.Error!void {
    try buf.appendSlice(a, "{\"index\":");
    var num_buf: [32]u8 = undefined;
    // SAFETY: a usize prints in at most 20 digits; NoSpaceLeft cannot fire.
    const s = std.fmt.bufPrint(&num_buf, "{d}", .{entry.forest_index}) catch unreachable;
    try buf.appendSlice(a, s);
    try buf.appendSlice(a, ",\"value\":");
    try common.appendValue(buf, a, entry.value);
    try buf.append(a, '}');
}

/// Serialize a `Host.HostEvalResult` as
/// `{"value":<JSON Value | null>,"diagnostics":[…],"loadedPlugins":[…]}`.
/// `value` is `null` when evaluation didn't run or raised an error
/// (matching diagnostic appears in `diagnostics`); otherwise it's the
/// JSON shape produced by `appendValue`.
pub fn writeHostEvalResult(a: Allocator, result: Host.HostEvalResult) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\"value\":");
    if (result.value) |v| {
        try common.appendValue(&buf, a, v);
    } else {
        try buf.appendSlice(a, "null");
    }
    try buf.appendSlice(a, ",\"diagnostics\":[");
    for (result.diagnostics, 0..) |d, i| {
        if (i > 0) try buf.append(a, ',');
        try appendHostDiagnostic(&buf, a, d);
    }
    try buf.appendSlice(a, "],\"loadedPlugins\":[");
    for (result.plugins, 0..) |p, i| {
        if (i > 0) try buf.append(a, ',');
        try appendPluginSummary(&buf, a, p);
    }
    try buf.appendSlice(a, "]}");
    return buf.toOwnedSlice(a);
}

fn appendMaterializedEntry(
    buf: *std.ArrayList(u8),
    a: Allocator,
    tree: *const Ast.Tree,
    entry: MaterializedDefaults.Entry,
) Allocator.Error!void {
    const hdr = tree.formHeader(entry.form);
    try buf.appendSlice(a, "{\"path\":[");
    try common.appendJsonString(buf, a, hdr.head);
    try buf.append(a, ',');
    try common.appendJsonString(buf, a, entry.key);
    try buf.appendSlice(a, "],\"key\":");
    try common.appendJsonString(buf, a, entry.key);
    try buf.appendSlice(a, ",\"origin\":\"");
    try buf.appendSlice(a, @tagName(entry.origin));
    try buf.appendSlice(a, "\",\"value\":");
    try common.appendValue(buf, a, entry.value);
    try buf.append(a, '}');
}

fn appendHostDiagnostic(
    buf: *std.ArrayList(u8),
    a: Allocator,
    d: Host.HostDiagnostic,
) Allocator.Error!void {
    try buf.appendSlice(a, "{\"phase\":\"");
    try buf.appendSlice(a, switch (d.phase) {
        .manifest => "manifest",
        .aggregate => "aggregate",
        .lowering => "lowering",
        .validation => "validation",
    });
    try buf.appendSlice(a, "\",\"code\":\"");
    try buf.appendSlice(a, @tagName(d.code));
    try buf.appendSlice(a, "\",\"severity\":\"");
    try buf.appendSlice(a, switch (d.severity) {
        .err => "err",
        .warning => "warning",
    });
    try buf.appendSlice(a, "\",\"message\":");
    try common.appendJsonString(buf, a, d.message);
    try buf.appendSlice(a, ",\"span\":{\"start\":");
    try common.appendUint(buf, a, d.span.start);
    try buf.appendSlice(a, ",\"end\":");
    try common.appendUint(buf, a, d.span.end);
    try buf.appendSlice(a, "},\"path\":[");
    for (d.path, 0..) |step, i| {
        if (i > 0) try buf.append(a, ',');
        try common.appendJsonString(buf, a, step);
    }
    try buf.appendSlice(a, "],\"declarationSpan\":");
    if (d.declaration_span) |s| {
        try buf.appendSlice(a, "{\"start\":");
        try common.appendUint(buf, a, s.start);
        try buf.appendSlice(a, ",\"end\":");
        try common.appendUint(buf, a, s.end);
        try buf.append(a, '}');
    } else {
        try buf.appendSlice(a, "null");
    }
    try buf.append(a, '}');
}

fn appendPluginSummary(
    buf: *std.ArrayList(u8),
    a: Allocator,
    p: Plugin.Plugin,
) Allocator.Error!void {
    try buf.appendSlice(a, "{\"name\":");
    try common.appendJsonString(buf, a, p.name);
    // `:version` is parsed but not stored on Plugin (see ManifestLoader.zig
    // §"declarative metadata"). Emit `null` so consumers don't need to
    // special-case the field's absence.
    try buf.appendSlice(a, ",\"version\":null,\"formCount\":");
    try common.appendUint(buf, a, @intCast(p.forms.len));
    try buf.append(a, '}');
}

// ---------------------------------------------------------------------------
// Schema-export envelope writer — used by `sjon_export_schema`.
// ---------------------------------------------------------------------------

/// Serialize an `ExportSchemaBundle` as a single JSON envelope carrying
/// every artifact, every warning, and the aggregate-phase diagnostics
/// the host pipeline surfaced. Schema:
///
/// ```
/// {
///   "layout": "aggregated" | "per-plugin",
///   "hostDiagnostics": [...],   // mirrors Host.HostResult.diagnostics
///   "loadedPlugins": [...],     // mirrors Host.HostResult.plugins
///   "warnings": [...],          // SchemaExport.Warning entries
///   "aggregated": {             // present iff layout=aggregated
///     "jsonSchema": "..." | null,
///     "tsTypes":    "..." | null,
///     "intermediate": "..." | null
///   } | null,
///   "perPlugin": [              // present iff layout=per-plugin
///     {"plugin": "...", "jsonSchema": "..." | null, "tsTypes": "..." | null, "intermediate": "..." | null}
///   ] | null
/// }
/// ```
///
/// Per-plugin layouts produce N×M files — one envelope carries them all
/// so callers only pay a single round-trip. The bytes of each emitted
/// artifact are JSON-escaped strings; callers `JSON.parse` once.
pub fn writeExportSchemaResult(a: Allocator, bundle: Host.ExportSchemaBundle) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\"layout\":\"");
    try buf.appendSlice(a, if (bundle.export_result.per_plugin == null) "aggregated" else "per-plugin");
    try buf.appendSlice(a, "\",\"hostDiagnostics\":[");
    for (bundle.host_result.diagnostics, 0..) |d, i| {
        if (i > 0) try buf.append(a, ',');
        try appendHostDiagnostic(&buf, a, d);
    }
    try buf.appendSlice(a, "],\"loadedPlugins\":[");
    for (bundle.host_result.plugins, 0..) |p, i| {
        if (i > 0) try buf.append(a, ',');
        try appendPluginSummary(&buf, a, p);
    }
    try buf.appendSlice(a, "],\"warnings\":[");
    for (bundle.export_result.warnings, 0..) |w, i| {
        if (i > 0) try buf.append(a, ',');
        try appendExportWarning(&buf, a, w);
    }
    try buf.appendSlice(a, "],\"aggregated\":");
    if (bundle.export_result.per_plugin == null) {
        try appendAggregatedArtifacts(&buf, a, bundle.export_result);
    } else {
        try buf.appendSlice(a, "null");
    }
    try buf.appendSlice(a, ",\"perPlugin\":");
    if (bundle.export_result.per_plugin) |arts| {
        try buf.append(a, '[');
        for (arts, 0..) |art, i| {
            if (i > 0) try buf.append(a, ',');
            try appendPerPluginArtifact(&buf, a, art);
        }
        try buf.append(a, ']');
    } else {
        try buf.appendSlice(a, "null");
    }
    try buf.append(a, '}');
    return buf.toOwnedSlice(a);
}

fn appendExportWarning(
    buf: *std.ArrayList(u8),
    a: Allocator,
    w: SchemaExport.Warnings.Warning,
) Allocator.Error!void {
    try buf.appendSlice(a, "{\"severity\":\"");
    try buf.appendSlice(a, @tagName(w.severity));
    try buf.appendSlice(a, "\",\"code\":\"");
    try buf.appendSlice(a, @tagName(w.code));
    try buf.appendSlice(a, "\",\"message\":");
    try common.appendJsonString(buf, a, w.message);
    try buf.appendSlice(a, ",\"plugin\":");
    try appendOptionalString(buf, a, w.plugin_name);
    try buf.appendSlice(a, ",\"form\":");
    try appendOptionalString(buf, a, w.form_name);
    try buf.appendSlice(a, ",\"key\":");
    try appendOptionalString(buf, a, w.key_name);
    try buf.appendSlice(a, ",\"kind\":");
    try appendOptionalString(buf, a, w.kind_name);
    try buf.append(a, '}');
}

fn appendOptionalString(buf: *std.ArrayList(u8), a: Allocator, s: ?[]const u8) Allocator.Error!void {
    if (s) |bytes| {
        try common.appendJsonString(buf, a, bytes);
    } else {
        try buf.appendSlice(a, "null");
    }
}

fn appendAggregatedArtifacts(
    buf: *std.ArrayList(u8),
    a: Allocator,
    er: SchemaExport.ExportResult,
) Allocator.Error!void {
    try buf.appendSlice(a, "{\"jsonSchema\":");
    try appendOptionalString(buf, a, er.json_schema_bytes);
    try buf.appendSlice(a, ",\"tsTypes\":");
    try appendOptionalString(buf, a, er.ts_types_bytes);
    try buf.appendSlice(a, ",\"intermediate\":");
    try appendOptionalString(buf, a, er.intermediate_bytes);
    try buf.append(a, '}');
}

fn appendPerPluginArtifact(
    buf: *std.ArrayList(u8),
    a: Allocator,
    art: SchemaExport.Model.PerPluginArtifact,
) Allocator.Error!void {
    try buf.appendSlice(a, "{\"plugin\":");
    try common.appendJsonString(buf, a, art.plugin);
    try buf.appendSlice(a, ",\"jsonSchema\":");
    try appendOptionalString(buf, a, art.json_schema_bytes);
    try buf.appendSlice(a, ",\"tsTypes\":");
    try appendOptionalString(buf, a, art.ts_types_bytes);
    try buf.appendSlice(a, ",\"intermediate\":");
    try appendOptionalString(buf, a, art.intermediate_bytes);
    try buf.append(a, '}');
}
