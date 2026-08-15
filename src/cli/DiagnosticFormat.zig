//! Diagnostic renderers for the `sjon` CLI — `human`, `rich`, and `json`.
//!
//! Split out of `Cli.zig`; the dispatcher picks a renderer by `Format`
//! and hands each the same inputs (file label, optional project file,
//! source, `Host.HostDiagnostic` slice). Renderers write to a
//! `std.Io.Writer` and never allocate except `rich`, which builds hint
//! footers into a caller-supplied arena.
//!
//!   - `human`  — GNU-style `FILE:LINE:COL: severity: code: message`, the
//!                grep/awk-friendly baseline.
//!   - `rich`   — `human` plus source snippets, caret underlines, hint
//!                footers, and (when enabled) ANSI color.
//!   - `json`   — a structured envelope built directly on
//!                `std.json.Stringify` (no `std.json.Value` detour), so the
//!                emitted shape is exactly what we publish.

const std = @import("std");
const sjon = @import("sjon");
const Host = sjon.Host;
const Ast = sjon.Ast;
const Schema = sjon.Schema;
const Color = @import("Color.zig");
const SnippetRenderer = @import("SnippetRenderer.zig");
const Hints = @import("Hints.zig");
const Explanations = sjon.Explanations;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Errors a renderer can return: the writer's, plus the allocator's for
/// the two that build hint footers into the caller's arena (`formatRich`
/// and `formatJson`). `formatHuman`, `formatGithub` and the private
/// helpers allocate nothing and are annotated `Writer.Error` directly, so
/// a caller can still tell from the signature which renderers need an
/// arena to be useful.
///
/// Written as the union of the two canonical sets rather than a literal
/// `error{ OutOfMemory, WriteFailed }` so it tracks `std.Io.Writer` if
/// that set ever grows.
pub const Error = Allocator.Error || Writer.Error;

/// Rich format — `formatHuman`'s output with source snippets, caret
/// underlines, hint footers, and (when stdout is a TTY) ANSI color.
/// The renderer honors `color_enabled`; the caller is responsible for
/// resolving `ColorPolicy` against the underlying file descriptor.
/// `schema` feeds the hint builders (nearest-key/-form suggestions);
/// pass null when no aggregate schema exists for the document.
/// `known_plugin_names` is the `unresolved_plugin` did-you-mean pool
/// (`HostResult.project_plugin_names`); pass null outside a project.
pub fn formatRich(
    out: *Writer,
    arena: Allocator,
    file_label: []const u8,
    project_file: ?[]const u8,
    source: []const u8,
    diags: []const Host.HostDiagnostic,
    schema: ?*const Schema.Schema,
    known_plugin_names: ?[]const []const u8,
    color_enabled: bool,
) Error!void {
    const styler: Color.Styler = .{ .enabled = color_enabled };
    if (project_file) |path| try out.print("# project: {s}\n", .{path});
    var error_count: usize = 0;
    for (diags) |d| {
        // Header: `error[code]: message` (color-styled).
        const sev_style: Color.Style = if (d.severity == .err) .red else .yellow;
        try styler.write(out, sev_style);
        try out.writeAll(severityWord(d.severity));
        try styler.write(out, .reset);
        try out.print("[{s}]: {s}\n", .{ @tagName(d.code), d.message });

        // Source frame via SnippetRenderer.
        try SnippetRenderer.render(out, file_label, source, .{
            .span = d.span,
            .label = "",
            .role = .primary,
        }, &.{}, styler);

        // Path + phase context (matches the human format's "at X" line).
        if (d.path.len > 0) {
            try out.writeAll("  at ");
            try writePath(out, d.path);
            try out.print(" (phase: {s})\n", .{@tagName(d.phase)});
        }

        // Hint footers key on the wrapped diagnostic, not the host's
        // envelope.
        const inner = d.inner();
        const hints = try Hints.forDiagnostic(.{
            .arena = arena,
            .diagnostic = &inner,
            .schema = schema,
            .known_plugin_names = known_plugin_names,
        });
        for (hints) |h| {
            try out.writeAll("  ");
            try styler.write(out, hintStyle(h.kind));
            try out.writeAll(@tagName(h.kind));
            try out.writeAll(":");
            try styler.write(out, .reset);
            try out.print(" {s}\n", .{h.body});
        }

        if (d.severity == .err) error_count += 1;
    }
    if (error_count > 0) {
        try styler.write(out, .bold);
        try out.print("{d} error{s}\n", .{ error_count, if (error_count == 1) "" else "s" });
        try styler.write(out, .reset);
    }
}

/// Footer color per hint kind — `note` carries content (suggestions),
/// `hint` carries an action, `help` is a pointer to docs.
fn hintStyle(kind: Hints.HintKind) Color.Style {
    return switch (kind) {
        .note => .cyan,
        .hint => .green,
        .help => .dim,
    };
}

pub fn formatHuman(
    out: *Writer,
    file_label: []const u8,
    project_file: ?[]const u8,
    source: []const u8,
    diags: []const Host.HostDiagnostic,
) Writer.Error!void {
    if (project_file) |path| try out.print("# project: {s}\n", .{path});
    var error_count: usize = 0;
    for (diags) |d| {
        const lc = SnippetRenderer.indexToLineCol(source, d.span.start);
        try out.print("{s}:{d}:{d}: {s}: {s}: {s}\n", .{
            file_label,
            lc.line,
            lc.col,
            severityWord(d.severity),
            @tagName(d.code),
            d.message,
        });
        if (d.path.len > 0) {
            try out.writeAll("  at ");
            try writePath(out, d.path);
            try out.print(" (phase: {s}", .{@tagName(d.phase)});
            if (d.phase == .manifest) {
                if (d.declaration_span) |ds| {
                    const dlc = SnippetRenderer.indexToLineCol(source, ds.start);
                    try out.print(", in declaration at {d}:{d}", .{ dlc.line, dlc.col });
                }
            }
            try out.writeAll(")\n");
        }
        if (d.severity == .err) error_count += 1;
    }
    if (error_count > 0) {
        try out.print("{d} error{s}\n", .{ error_count, if (error_count == 1) "" else "s" });
    }
}

fn severityWord(s: Ast.Diagnostic.Severity) []const u8 {
    return switch (s) {
        .err => "error",
        .warning => "warning",
    };
}

fn writePath(out: *Writer, path: []const []const u8) Writer.Error!void {
    for (path, 0..) |seg, i| {
        if (i > 0) try out.writeAll("/");
        try out.writeAll(seg);
    }
}

/// JSON formatter — built directly on `std.json.Stringify` so the schema
/// stays exactly what we publish (no `std.json.Value` arena detour).
/// `arena` backs the hint construction; `schema` /
/// `known_plugin_names` feed the same suggestion machinery
/// `formatRich` renders — pass null when unavailable and the `hints`
/// arrays simply stay away. Every diagnostic carries a `docs`
/// catalogue URL regardless.
pub fn formatJson(
    out: *Writer,
    arena: Allocator,
    file_label: []const u8,
    project_file: ?[]const u8,
    source: []const u8,
    diags: []const Host.HostDiagnostic,
    schema: ?*const Schema.Schema,
    known_plugin_names: ?[]const []const u8,
) Error!void {
    var w: std.json.Stringify = .{
        .writer = out,
        .options = .{ .whitespace = .indent_2 },
    };
    try w.beginObject();
    try w.objectField("file");
    try w.write(file_label);
    try w.objectField("project_file");
    if (project_file) |p| try w.write(p) else try w.write(null);
    try w.objectField("diagnostics");
    try w.beginArray();
    for (diags) |d| {
        try w.beginObject();
        try w.objectField("phase");
        try w.write(@tagName(d.phase));
        try w.objectField("code");
        try w.write(@tagName(d.code));
        try w.objectField("severity");
        try w.write(severityWord(d.severity));
        try w.objectField("message");
        try w.write(d.message);
        try w.objectField("span");
        try writeSpanJson(&w, source, d.span);
        try w.objectField("path");
        try w.beginArray();
        for (d.path) |seg| try w.write(seg);
        try w.endArray();
        try w.objectField("declaration_span");
        if (d.declaration_span) |ds| {
            try writeSpanJson(&w, source, ds);
        } else {
            try w.write(null);
        }
        try w.objectField("docs");
        try w.write(Explanations.codeHref(d.code));
        // Code-specific hints only, omitted when none apply — the docs
        // link above is structural, so the URL help footer the rich
        // renderer prints would be pure duplication here.
        const inner = d.inner();
        const hints = try Hints.registered(.{
            .arena = arena,
            .diagnostic = &inner,
            .schema = schema,
            .known_plugin_names = known_plugin_names,
        });
        if (hints.len > 0) {
            try w.objectField("hints");
            try w.beginArray();
            for (hints) |h| {
                try w.beginObject();
                try w.objectField("kind");
                try w.write(@tagName(h.kind));
                try w.objectField("text");
                try w.write(h.body);
                if (h.replacement) |r| {
                    try w.objectField("replacement");
                    try w.write(r);
                }
                try w.endObject();
            }
            try w.endArray();
        }
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();
    try out.writeByte('\n');
}

fn writeSpanJson(w: *std.json.Stringify, source: []const u8, span: Ast.Span) Writer.Error!void {
    const lc = SnippetRenderer.indexToLineCol(source, span.start);
    try w.beginObject();
    try w.objectField("start");
    try w.write(span.start);
    try w.objectField("end");
    try w.write(span.end);
    try w.objectField("line");
    try w.write(lc.line);
    try w.objectField("column");
    try w.write(lc.col);
    try w.endObject();
}

/// GitHub Actions workflow-command formatter — one annotation line per
/// diagnostic: `::error file=F,line=L,col=C,endLine=…,endColumn=…::CODE:
/// message` (`::warning` for warnings). Annotations are the ONLY stdout
/// product in this format; callers route everything else to stderr.
/// Escaping follows the workflow-command grammar: `%` / CR / LF in the
/// message data, plus `,` and `:` in property values.
pub fn formatGithub(
    out: *Writer,
    file_label: []const u8,
    source: []const u8,
    diags: []const Host.HostDiagnostic,
) Writer.Error!void {
    for (diags) |d| {
        const start = SnippetRenderer.indexToLineCol(source, d.span.start);
        const end = SnippetRenderer.indexToLineCol(source, d.span.end);
        try out.writeAll("::");
        try out.writeAll(severityWord(d.severity));
        try out.writeAll(" file=");
        try writeGithubProperty(out, file_label);
        try out.print(",line={d},col={d},endLine={d},endColumn={d}::", .{
            start.line, start.col, end.line, end.col,
        });
        try out.writeAll(@tagName(d.code));
        try out.writeAll(": ");
        try writeGithubData(out, d.message);
        try out.writeByte('\n');
    }
}

/// Escape workflow-command message data: `%` → `%25`, CR → `%0D`,
/// LF → `%0A`.
fn writeGithubData(out: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        '%' => try out.writeAll("%25"),
        '\r' => try out.writeAll("%0D"),
        '\n' => try out.writeAll("%0A"),
        else => try out.writeByte(c),
    };
}

/// Escape a workflow-command property value: the data escapes plus
/// `,` → `%2C` and `:` → `%3A` (both structural in the property list).
fn writeGithubProperty(out: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        '%' => try out.writeAll("%25"),
        '\r' => try out.writeAll("%0D"),
        '\n' => try out.writeAll("%0A"),
        ',' => try out.writeAll("%2C"),
        ':' => try out.writeAll("%3A"),
        else => try out.writeByte(c),
    };
}

test "formatGithub: message newlines and percent signs survive the workflow command grammar" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const diags = [_]Host.HostDiagnostic{.{
        .phase = .validation,
        .code = .unspecified,
        .severity = .err,
        .message = "50% of\nthis",
        .span = .{ .start = 0, .end = 1 },
        .path = &.{},
    }};
    try formatGithub(&buf.writer, "a b.sjon", "x\n", &diags);
    const text = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "50%25 of%0Athis") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\n50%") == null);
}

test "formatGithub: file-label commas and colons escape as property values" {
    // `,` and `:` are structural in the property list — unescaped they
    // shift the line/col properties or truncate the file name.
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const diags = [_]Host.HostDiagnostic{.{
        .phase = .validation,
        .code = .unspecified,
        .severity = .warning,
        .message = "m",
        .span = .{ .start = 0, .end = 1 },
        .path = &.{},
    }};
    try formatGithub(&buf.writer, "dir,x:y.sjon", "x\n", &diags);
    const text = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "::warning file=dir%2Cx%3Ay.sjon,line=") != null);
}
