const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Expr = @import("Expr.zig");
const Validator = @import("Validator.zig");
const Host = @import("Host.zig");
const Plugin = @import("Plugin.zig");
const MaterializedDefaults = @import("MaterializedDefaults.zig");
const SchemaExport = @import("SchemaExport/SchemaExport.zig");

pub const HEADER_SIZE: u32 = 8;

pub fn frame(allocator: Allocator, ok: bool, payload: []const u8) ![*]u8 {
    const total: usize = HEADER_SIZE + payload.len;
    const buf = try allocator.alloc(u8, total);
    std.mem.writeInt(u32, buf[0..4], if (ok) 1 else 0, .little);
    std.mem.writeInt(u32, buf[4..8], @intCast(payload.len), .little);
    @memcpy(buf[HEADER_SIZE..], payload);
    return buf.ptr;
}

pub fn frameError(allocator: Allocator, err: anyerror) ![*]u8 {
    const name = @errorName(err);
    return try frame(allocator, false, name);
}

pub fn appendValue(buf: *std.ArrayList(u8), a: Allocator, v: Expr.Value) !void {
    switch (v) {
        .nil => try buf.appendSlice(a, "null"),
        .boolean => |b| try buf.appendSlice(a, if (b) "true" else "false"),
        .number => |x| {
            if (std.math.isNan(x)) {
                try buf.appendSlice(a, "\"nan\"");
            } else if (std.math.isInf(x)) {
                try buf.appendSlice(a, if (x > 0) "\"inf\"" else "\"-inf\"");
            } else {
                var num_buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&num_buf, "{d}", .{x}) catch unreachable;
                try buf.appendSlice(a, s);
            }
        },
        .integer_i64 => |x| {
            var num_buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, "{d}", .{x}) catch unreachable;
            try buf.appendSlice(a, s);
        },
        .integer_u64 => |x| {
            var num_buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&num_buf, "{d}", .{x}) catch unreachable;
            try buf.appendSlice(a, s);
        },
        .string => |s| try appendJsonString(buf, a, s),
        .date => |d| {
            var date_buf: [10]u8 = undefined;
            d.formatCanonical(&date_buf);
            try buf.appendSlice(a, "{\"$date\":\"");
            try buf.appendSlice(a, &date_buf);
            try buf.appendSlice(a, "\"}");
        },
        .time => |t| {
            var time_buf: [12]u8 = undefined;
            const n = t.formatCanonical(&time_buf);
            try buf.appendSlice(a, "{\"$time\":\"");
            try buf.appendSlice(a, time_buf[0..n]);
            try buf.appendSlice(a, "\"}");
        },
        .keyword => |k| {
            try buf.appendSlice(a, "{\"$kw\":");
            try appendJsonString(buf, a, k);
            try buf.append(a, '}');
        },
        .vector => |xs| {
            try buf.append(a, '[');
            for (xs, 0..) |xv, i| {
                if (i > 0) try buf.append(a, ',');
                try appendValue(buf, a, xv);
            }
            try buf.append(a, ']');
        },
        .form => |f| {
            try buf.appendSlice(a, "{\"$form\":");
            try appendJsonString(buf, a, f.head);
            if (f.namespace.len > 0) {
                try buf.appendSlice(a, ",\"$ns\":");
                try appendJsonString(buf, a, f.namespace);
            }
            try buf.appendSlice(a, ",\"children\":[");
            for (f.children, 0..) |child, i| {
                if (i > 0) try buf.append(a, ',');
                try appendValue(buf, a, child);
            }
            try buf.appendSlice(a, "],\"kvpairs\":{");
            for (f.kvpairs, 0..) |pair, i| {
                if (i > 0) try buf.append(a, ',');
                try appendJsonString(buf, a, pair.key);
                try buf.append(a, ':');
                try appendValue(buf, a, pair.value);
            }
            try buf.appendSlice(a, "}}");
        },
    }
}

pub fn appendJsonString(buf: *std.ArrayList(u8), a: Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(a, "\\\""),
        '\\' => try buf.appendSlice(a, "\\\\"),
        '\n' => try buf.appendSlice(a, "\\n"),
        '\r' => try buf.appendSlice(a, "\\r"),
        '\t' => try buf.appendSlice(a, "\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
            var esc_buf: [8]u8 = undefined;
            const s2 = std.fmt.bufPrint(&esc_buf, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(a, s2);
        },
        else => try buf.append(a, c),
    };
    try buf.append(a, '"');
}

pub fn appendUint(buf: *std.ArrayList(u8), a: Allocator, n: u32) !void {
    var num_buf: [10]u8 = undefined;
    const s = std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch unreachable;
    try buf.appendSlice(a, s);
}

pub fn appendDiagnostic(
    buf: *std.ArrayList(u8),
    a: Allocator,
    d: Ast.Diagnostic,
) !void {
    try buf.appendSlice(a, "{\"span\":{\"start\":");
    try appendUint(buf, a, d.span.start);
    try buf.appendSlice(a, ",\"end\":");
    try appendUint(buf, a, d.span.end);
    try buf.appendSlice(a, "},\"severity\":\"");
    try buf.appendSlice(a, switch (d.severity) {
        .err => "err",
        .warning => "warning",
    });
    try buf.appendSlice(a, "\",\"code\":\"");
    try buf.appendSlice(a, @tagName(d.code));
    try buf.appendSlice(a, "\",\"message\":");
    try appendJsonString(buf, a, d.message);
    try buf.append(a, '}');
}

pub fn parseDiagnosticsJson(a: Allocator, diagnostics: []const Ast.Diagnostic) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\"diagnostics\":[");
    for (diagnostics, 0..) |d, i| {
        if (i > 0) try buf.append(a, ',');
        try appendDiagnostic(&buf, a, d);
    }
    try buf.appendSlice(a, "]}");
    return buf.toOwnedSlice(a);
}

pub fn validatorDiagnosticsJson(
    a: Allocator,
    parse_diagnostics: []const Ast.Diagnostic,
    result: Validator.Result,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\"parse_diagnostics\":[");
    for (parse_diagnostics, 0..) |d, i| {
        if (i > 0) try buf.append(a, ',');
        try appendDiagnostic(&buf, a, d);
    }
    try buf.appendSlice(a, "],\"diagnostics\":[");
    for (result.diagnostics, 0..) |d, i| {
        if (i > 0) try buf.append(a, ',');
        try appendDiagnostic(&buf, a, d);
    }
    try buf.appendSlice(a, "]}");
    return buf.toOwnedSlice(a);
}

pub fn validatorBinaryJson(a: Allocator, result: Validator.Result) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\"parse_diagnostics\":[],\"diagnostics\":[");
    for (result.diagnostics, 0..) |d, i| {
        if (i > 0) try buf.append(a, ',');
        try appendDiagnostic(&buf, a, d);
    }
    try buf.appendSlice(a, "]}");
    return buf.toOwnedSlice(a);
}

pub fn valueToJson(a: Allocator, v: Expr.Value) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try appendValue(&buf, a, v);
    return buf.toOwnedSlice(a);
}

pub fn writeHostResult(a: Allocator, result: Host.HostResult) ![]u8 {
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
) !void {
    try buf.appendSlice(a, "{\"index\":");
    var num_buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&num_buf, "{d}", .{entry.forest_index}) catch return error.OutOfMemory;
    try buf.appendSlice(a, s);
    try buf.appendSlice(a, ",\"value\":");
    try appendValue(buf, a, entry.value);
    try buf.append(a, '}');
}

pub fn writeHostEvalResult(a: Allocator, result: Host.HostEvalResult) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\"value\":");
    if (result.value) |v| {
        try appendValue(&buf, a, v);
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
) !void {
    const hdr = tree.formHeader(entry.form);
    try buf.appendSlice(a, "{\"path\":[");
    try appendJsonString(buf, a, hdr.head);
    try buf.append(a, ',');
    try appendJsonString(buf, a, entry.key);
    try buf.appendSlice(a, "],\"key\":");
    try appendJsonString(buf, a, entry.key);
    try buf.appendSlice(a, ",\"origin\":\"");
    try buf.appendSlice(a, @tagName(entry.origin));
    try buf.appendSlice(a, "\",\"value\":");
    try appendValue(buf, a, entry.value);
    try buf.append(a, '}');
}

fn appendHostDiagnostic(
    buf: *std.ArrayList(u8),
    a: Allocator,
    d: Host.HostDiagnostic,
) !void {
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
    try appendJsonString(buf, a, d.message);
    try buf.appendSlice(a, ",\"span\":{\"start\":");
    try appendUint(buf, a, d.span.start);
    try buf.appendSlice(a, ",\"end\":");
    try appendUint(buf, a, d.span.end);
    try buf.appendSlice(a, "},\"path\":[");
    for (d.path, 0..) |step, i| {
        if (i > 0) try buf.append(a, ',');
        try appendJsonString(buf, a, step);
    }
    try buf.appendSlice(a, "],\"declarationSpan\":");
    if (d.declaration_span) |s| {
        try buf.appendSlice(a, "{\"start\":");
        try appendUint(buf, a, s.start);
        try buf.appendSlice(a, ",\"end\":");
        try appendUint(buf, a, s.end);
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
) !void {
    try buf.appendSlice(a, "{\"name\":");
    try appendJsonString(buf, a, p.name);
    try buf.appendSlice(a, ",\"version\":null,\"formCount\":");
    try appendUint(buf, a, @intCast(p.forms.len));
    try buf.append(a, '}');
}

pub fn writeExportSchemaResult(a: Allocator, bundle: Host.ExportSchemaBundle) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "{\"layout\":\"");
    try buf.appendSlice(a, if (bundle.export_result.per_plugin == null) "aggregated" else "per_plugin");
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
) !void {
    try buf.appendSlice(a, "{\"severity\":\"");
    try buf.appendSlice(a, @tagName(w.severity));
    try buf.appendSlice(a, "\",\"code\":\"");
    try buf.appendSlice(a, @tagName(w.code));
    try buf.appendSlice(a, "\",\"message\":");
    try appendJsonString(buf, a, w.message);
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

fn appendOptionalString(buf: *std.ArrayList(u8), a: Allocator, s: ?[]const u8) !void {
    if (s) |bytes| {
        try appendJsonString(buf, a, bytes);
    } else {
        try buf.appendSlice(a, "null");
    }
}

fn appendAggregatedArtifacts(
    buf: *std.ArrayList(u8),
    a: Allocator,
    er: SchemaExport.ExportResult,
) !void {
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
) !void {
    try buf.appendSlice(a, "{\"plugin\":");
    try appendJsonString(buf, a, art.plugin);
    try buf.appendSlice(a, ",\"jsonSchema\":");
    try appendOptionalString(buf, a, art.json_schema_bytes);
    try buf.appendSlice(a, ",\"tsTypes\":");
    try appendOptionalString(buf, a, art.ts_types_bytes);
    try buf.appendSlice(a, ",\"intermediate\":");
    try appendOptionalString(buf, a, art.intermediate_bytes);
    try buf.append(a, '}');
}
