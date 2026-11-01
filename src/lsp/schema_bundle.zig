//! Ordered editor schema bundles.
//!
//! A `sjon-lsp.sjon` bundle names an ordered list of manifest sources. This
//! module turns one selected bundle into a `Compiled` value:
//!
//!   * every source is read in declaration order through `CappedRead`;
//!   * all readable sources are compiled once through `Host.preloadSchema`
//!     (no plugin-name selection, no resolver deduplication, no sidecar
//!     discovery, no second parser);
//!   * the effective schema is `core ++ preload`, exposed only when every
//!     required source was read and every preload diagnostic is non-error. A
//!     partial compile is never presented as ready.
//!
//! Reports are split by the file their spans index into:
//!
//!   * `reports[i].diagnostics` carry preload diagnostics for `sources[i]`;
//!     their spans index into that source's bytes.
//!   * `config_reports` carry bundle-level failures; their spans always index
//!     into the owning `Config.source` (a real manifest entry or the bundle
//!     form). No source offset is invented.
//!
//! The six aggregate validators emit `span = {0, 0}` (see `Schema.zig`), so an
//! aggregate failure cannot carry a real in-source offset. When its `path[0]`
//! names exactly one participating source, it is anchored at that source's
//! real manifest-entry span; otherwise it is anchored at the real bundle-form
//! span and names every participating source. That is the honest maximum the
//! Host API provides; no offset is fabricated.
//!
//! Ownership: `Compiled` borrows its `Config` (and `context_id`), owns source
//! bytes, the preloaded bundle, the composed plugin slice, and all reports in
//! one arena. Destroy every `Handler` borrowing `schema` before
//! `Compiled.deinit`.

const std = @import("std");
const sjon = @import("sjon");
const editor_config = @import("editor_config");
const uri = @import("uri");
const testing = std.testing;

const Allocator = std.mem.Allocator;
const HostDiagnostic = sjon.Host.HostDiagnostic;

pub const codes = struct {
    pub const bundle_source_read: []const u8 = "sjon-lsp/bundle-source-read";
    pub const bundle_aggregate: []const u8 = "sjon-lsp/bundle-aggregate";
    pub const bundle_unavailable: []const u8 = "sjon-lsp/bundle-unavailable";
};

pub const State = enum { ready, unavailable };

/// One required manifest source of the selected bundle, in declaration order.
pub const Source = struct {
    /// Index of this source's entry in the owning bundle's `:manifests`.
    manifest_index: usize,
    /// Lexically normalized absolute path, borrowed from the owning `Config`.
    path: []const u8,
    /// `file://` URI, owned by the `Compiled` arena.
    uri: []const u8,
    /// Bytes read through `CappedRead.readFileZ`; null when the read failed.
    /// Arena-owned.
    bytes: ?[:0]const u8,
    /// `@errorName` from a failed read, or null when `bytes` is present.
    read_error: ?[]const u8,
};

/// Related information on a config-anchored bundle report.
pub const Related = struct {
    message: []const u8,
    /// Real span in the owning `Config.source`.
    span: sjon.Ast.Span,
    /// Optional source file this relation points at (rendered at byte 0).
    uri: ?[]const u8 = null,
};

/// A bundle-level report. `span` always indexes into the owning
/// `Config.source`; a report never borrows a manifest offset as a config
/// offset or vice versa.
pub const ConfigReport = struct {
    /// Editor-local `sjon-lsp/...` identifier.
    code: []const u8,
    severity: sjon.Ast.Diagnostic.Severity,
    message: []const u8,
    /// Always a real span in the owning `Config.source`.
    span: sjon.Ast.Span,
    related: []const Related = &.{},
};

/// Preload diagnostics attributed to one required source, index-aligned with
/// `Compiled.sources`. A clean source has an empty report; a failed source
/// never compacts the indices of the sources after it.
pub const SourceReport = struct {
    /// Index into `Compiled.sources`; diagnostics' spans are offsets into
    /// `sources[source_index].bytes`.
    source_index: usize,
    diagnostics: []const HostDiagnostic = &.{},
};

/// One compiled (or honestly refused) ordered schema bundle.
pub const Compiled = struct {
    arena: std.heap.ArenaAllocator,
    /// Borrowed editor-context identity; not owned.
    context_id: []const u8,
    /// Borrowed owner of the bundle and source paths. Must outlive this value.
    config: *const editor_config.Config,
    /// Index of the compiled bundle in `config.bundles`.
    bundle_index: usize,
    state: State,
    /// Empty when unavailable; `[core] ++ preloaded.plugins` when ready. The
    /// plugin storage lives in `arena`; plugin strings borrow `preloaded`.
    schema: sjon.Schema.Schema,
    /// The ordered preload, when at least one required source was readable.
    /// Null when no source could be read (or no bundle was compiled).
    preloaded: ?sjon.Host.PreloadedSchema,
    sources: []const Source,
    reports: []const SourceReport,
    config_reports: []const ConfigReport,

    /// Release the preload before the arena that holds the composed slice.
    /// A borrowing `Handler` must already be destroyed.
    pub fn deinit(self: *Compiled) void {
        if (self.preloaded) |*pre| pre.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn hasErrors(self: *const Compiled) bool {
        return self.state == .unavailable;
    }

    /// Read and compile one bundle from `config`.
    ///
    /// Reads the bundle's manifest entries in declaration order. Read
    /// failures and error-severity manifest/preload/aggregate diagnostics make
    /// the result unavailable with an empty `schema`; a partial preload is
    /// retained only for reporting, never installed. `bundle_index` out of
    /// range or an invalid configuration is also unavailable, with one
    /// config-anchored report.
    pub fn load(
        gpa: Allocator,
        io: std.Io,
        context_id: []const u8,
        config: *const editor_config.Config,
        bundle_index: usize,
    ) Allocator.Error!Compiled {
        return loadBundle(gpa, io, context_id, config, bundle_index);
    }
};

/// Implementation of `Compiled.load`.
///
/// Reads the bundle's manifest entries in declaration order. Read failures and
/// error-severity manifest/preload/aggregate diagnostics make the result
/// unavailable with an empty `schema`; a partial preload is retained only for
/// reporting, never installed. `bundle_index` out of range or an invalid
/// configuration is also unavailable, with one config-anchored report.
///
/// Every returned string and slice is arena-owned except `config`, the source
/// paths (borrowed from `config`), and `context_id` (borrowed from the caller).
fn loadBundle(
    gpa: Allocator,
    io: std.Io,
    context_id: []const u8,
    config: *const editor_config.Config,
    bundle_index: usize,
) Allocator.Error!Compiled {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var config_reports: std.ArrayList(ConfigReport) = .empty;

    if (config.hasErrors() or bundle_index >= config.bundles.len) {
        const reason = if (config.hasErrors())
            try a.dupe(u8, "the configuration is not valid")
        else
            try std.fmt.allocPrint(
                a,
                "bundle index {d} is out of range for {d} configured bundle(s)",
                .{ bundle_index, config.bundles.len },
            );
        try config_reports.append(a, .{
            .code = codes.bundle_unavailable,
            .severity = .err,
            .message = try std.fmt.allocPrint(
                a,
                "editor bundle {d} in `{s}` is unavailable: {s}",
                .{ bundle_index, config.path, reason },
            ),
            .span = .{ .start = 0, .end = 0 },
        });
        return .{
            .arena = arena,
            .context_id = context_id,
            .config = config,
            .bundle_index = bundle_index,
            .state = .unavailable,
            .schema = .{ .plugins = &.{} },
            .preloaded = null,
            .sources = &.{},
            .reports = &.{},
            .config_reports = try config_reports.toOwnedSlice(a),
        };
    }

    const bundle = &config.bundles[bundle_index];
    if (bundle.manifests.len == 0) {
        // The typed reader rejects an empty `:manifests`; this is the
        // defense-in-depth path for a hand-built `Config`.
        try config_reports.append(a, .{
            .code = codes.bundle_unavailable,
            .severity = .err,
            .message = try std.fmt.allocPrint(
                a,
                "editor bundle `{s}` has no manifest sources",
                .{bundle.name},
            ),
            .span = bundle.span,
        });
        return .{
            .arena = arena,
            .context_id = context_id,
            .config = config,
            .bundle_index = bundle_index,
            .state = .unavailable,
            .schema = .{ .plugins = &.{} },
            .preloaded = null,
            .sources = &.{},
            .reports = &.{},
            .config_reports = try config_reports.toOwnedSlice(a),
        };
    }

    const sources = try a.alloc(Source, bundle.manifests.len);
    const readable_slots = try a.alloc(?usize, bundle.manifests.len);
    var readable_sources: std.ArrayList([:0]const u8) = .empty;

    // Read every required source in declaration order. A failed read is
    // recorded against its own manifest entry; it never disappears from the
    // order and never shifts a later source's slot.
    for (bundle.manifests, 0..) |manifest, i| {
        const source_uri = try uri.pathToFileUri(a, manifest.path);
        const bytes = sjon.CappedRead.readFileZ(
            io,
            manifest.path,
            a,
            sjon.CappedRead.MAX_FILE_SIZE,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                sources[i] = .{
                    .manifest_index = i,
                    .path = manifest.path,
                    .uri = source_uri,
                    .bytes = null,
                    .read_error = @errorName(err),
                };
                readable_slots[i] = null;

                const related = try a.alloc(Related, 1);
                related[0] = .{
                    .message = "source file named by this manifest entry",
                    .span = .{ .start = 0, .end = 0 },
                    .uri = source_uri,
                };
                try config_reports.append(a, .{
                    .code = codes.bundle_source_read,
                    .severity = .err,
                    .message = try std.fmt.allocPrint(
                        a,
                        "unable to read required schema source `{s}`: {s}",
                        .{ manifest.path, @errorName(err) },
                    ),
                    .span = manifest.span,
                    .related = related,
                });
                continue;
            },
        };

        sources[i] = .{
            .manifest_index = i,
            .path = manifest.path,
            .uri = source_uri,
            .bytes = bytes,
            .read_error = null,
        };
        readable_slots[i] = readable_sources.items.len;
        try readable_sources.append(a, bytes);
    }

    var preloaded: ?sjon.Host.PreloadedSchema = null;
    errdefer if (preloaded) |*pre| pre.deinit();

    if (readable_sources.items.len != 0) {
        preloaded = try sjon.Host.preloadSchema(gpa, readable_sources.items);
    }

    var per_source = try a.alloc(std.ArrayList(HostDiagnostic), sources.len);
    for (per_source) |*list| list.* = .empty;

    // Input index → the name of the plugin that source contributed. A source
    // with an error-severity load diagnostic contributes no plugin, so it is
    // not a candidate for aggregate attribution.
    const contributed = try a.alloc(?[]const u8, sources.len);
    for (contributed) |*name| name.* = null;

    if (preloaded) |*pre| {
        for (sources, 0..) |_, i| {
            const slot = readable_slots[i] orelse continue;
            try per_source[i].appendSlice(a, pre.source_diagnostics[slot]);
        }

        var next_plugin: usize = 0;
        for (sources, 0..) |_, i| {
            const slot = readable_slots[i] orelse continue;
            var has_error = false;
            for (pre.source_diagnostics[slot]) |diag| {
                if (diag.severity == .err) {
                    has_error = true;
                    break;
                }
            }
            if (has_error) continue;
            if (next_plugin < pre.plugins.len) {
                contributed[i] = pre.plugins[next_plugin].name;
                next_plugin += 1;
            }
        }

        // Aggregate diagnostics describe the combined set. Attribute each to
        // the one source its `path[0]` names, when that is unique; otherwise
        // anchor it at the real bundle form and name every candidate.
        for (pre.aggregate_diagnostics) |diag| {
            const candidates = aggregateCandidates(contributed, diag.path);
            if (candidates.matches == 1) {
                const index = candidates.first;
                if (diag.span.end > diag.span.start) {
                    // A future validator that supplies a real source offset
                    // keeps it; today every aggregate span is zero.
                    try per_source[index].append(a, diag);
                } else {
                    const manifest = bundle.manifests[index];
                    const related = try a.alloc(Related, 1);
                    related[0] = .{
                        .message = "source file named by this manifest entry",
                        .span = .{ .start = 0, .end = 0 },
                        .uri = sources[index].uri,
                    };
                    try config_reports.append(a, .{
                        .code = codes.bundle_aggregate,
                        .severity = diag.severity,
                        .message = try std.fmt.allocPrint(
                            a,
                            "schema aggregate error in source `{s}`: {s}",
                            .{ sources[index].path, diag.message },
                        ),
                        .span = manifest.span,
                        .related = related,
                    });
                }
                continue;
            }

            const only_name: ?[]const u8 = if (candidates.matches > 1) diag.path[0] else null;
            try config_reports.append(a, .{
                .code = codes.bundle_aggregate,
                .severity = diag.severity,
                .message = try std.fmt.allocPrint(
                    a,
                    "schema aggregate error in bundle `{s}` cannot be attributed to one source: {s}; participating sources: {s}",
                    .{
                        bundle.name,
                        diag.message,
                        try sourcePathList(a, sources, contributed, only_name),
                    },
                ),
                .span = bundle.span,
                .related = try participantRelated(a, bundle, sources, contributed, only_name),
            });
        }
    }

    var unavailable = preloaded == null;
    for (config_reports.items) |report| {
        if (report.severity == .err) {
            unavailable = true;
            break;
        }
    }
    if (preloaded) |*pre| {
        if (pre.hasErrors()) unavailable = true;
    }

    var schema: sjon.Schema.Schema = .{ .plugins = &.{} };
    if (!unavailable) {
        const pre = if (preloaded) |*p| p else unreachable;
        const composed = try a.alloc(sjon.Plugin.Plugin, 1 + pre.plugins.len);
        composed[0] = sjon.plugins.core.plugin;
        @memcpy(composed[1..], pre.plugins);
        schema = sjon.Schema.Schema.init(composed);
    }

    const reports = try a.alloc(SourceReport, sources.len);
    for (sources, 0..) |_, i| {
        reports[i] = .{
            .source_index = i,
            .diagnostics = try per_source[i].toOwnedSlice(a),
        };
    }

    return .{
        .arena = arena,
        .context_id = context_id,
        .config = config,
        .bundle_index = bundle_index,
        .state = if (unavailable) .unavailable else .ready,
        .schema = schema,
        .preloaded = preloaded,
        .sources = sources,
        .reports = reports,
        .config_reports = try config_reports.toOwnedSlice(a),
    };
}

const AggregateCandidates = struct {
    matches: usize = 0,
    first: usize = 0,
};

/// Count the contributed plugins whose name is `path[0]`. An empty path names
/// no plugin, so it can never be uniquely attributed.
fn aggregateCandidates(
    contributed: []const ?[]const u8,
    path: []const []const u8,
) AggregateCandidates {
    var out: AggregateCandidates = .{};
    if (path.len == 0) return out;
    for (contributed, 0..) |name_opt, i| {
        const name = name_opt orelse continue;
        if (!std.mem.eql(u8, name, path[0])) continue;
        if (out.matches == 0) out.first = i;
        out.matches += 1;
    }
    return out;
}

/// Render the candidate source paths as a backticked comma list.
fn sourcePathList(
    a: Allocator,
    sources: []const Source,
    contributed: []const ?[]const u8,
    only_name: ?[]const u8,
) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (contributed, 0..) |name_opt, i| {
        const name = name_opt orelse continue;
        if (only_name) |want| {
            if (!std.mem.eql(u8, name, want)) continue;
        }
        if (out.items.len != 0) try out.appendSlice(a, ", ");
        try out.append(a, '`');
        try out.appendSlice(a, sources[i].path);
        try out.append(a, '`');
    }
    if (out.items.len == 0) return a.dupe(u8, "(none)");
    return out.toOwnedSlice(a);
}

/// One related entry per candidate, anchored at that source's real manifest
/// entry in the configuration.
fn participantRelated(
    a: Allocator,
    bundle: *const editor_config.Bundle,
    sources: []const Source,
    contributed: []const ?[]const u8,
    only_name: ?[]const u8,
) Allocator.Error![]const Related {
    var out: std.ArrayList(Related) = .empty;
    for (contributed, 0..) |name_opt, i| {
        const name = name_opt orelse continue;
        if (only_name) |want| {
            if (!std.mem.eql(u8, name, want)) continue;
        }
        try out.append(a, .{
            .message = "participating source",
            .span = bundle.manifests[i].span,
            .uri = sources[i].uri,
        });
    }
    return out.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Tests — write first, then implement against them.
// ---------------------------------------------------------------------------

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    dir: []const u8,
    config_path: []const u8,

    fn init() !Fixture {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const tmp = testing.tmpDir(.{});
        const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
        const config_path = try std.fmt.allocPrint(a, "{s}/sjon-lsp.sjon", .{dir});
        return .{ .tmp = tmp, .arena = arena, .dir = dir, .config_path = config_path };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.arena.deinit();
        self.* = undefined;
    }

    fn write(self: *Fixture, sub_path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn writePlugin(self: *Fixture, sub_path: []const u8, plugin_name: []const u8, form_name: []const u8) !void {
        const source = try std.fmt.allocPrintSentinel(
            testing.allocator,
            "(plugin :name {s} :version \"1.0.0\" (form :name {s} :open true))",
            .{ plugin_name, form_name },
            0,
        );
        defer testing.allocator.free(source);
        try self.write(sub_path, source);
    }

    fn parse(self: *Fixture, source: [:0]const u8) !editor_config.Config {
        return editor_config.parse(testing.allocator, self.config_path, source);
    }
};

fn quotedList(a: Allocator, values: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (values, 0..) |value, i| {
        if (i > 0) try out.append(a, ' ');
        try out.append(a, '"');
        try out.appendSlice(a, value);
        try out.append(a, '"');
    }
    return out.toOwnedSlice(a);
}

fn singleBundleConfig(manifests: []const []const u8) ![:0]u8 {
    const list = try quotedList(testing.allocator, manifests);
    defer testing.allocator.free(list);
    return std.fmt.allocPrintSentinel(
        testing.allocator,
        "(sjon-lsp :version 1 :bundles [(bundle :name b :files [\"**/*.sjon\"] :manifests [{s}])])",
        .{list},
        0,
    );
}

fn sameSource(plugin_name: []const u8, target: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(
        testing.allocator,
        \\(plugin :name {s} :version "1.0.0"
        \\  (value-kind :name ref-kind
        \\    :underlying symbol
        \\    :cross-ref (cross-ref :target {s})))
    ,
        .{ plugin_name, target },
        0,
    );
}

fn findSpan(haystack: []const u8, needle: []const u8, occurrence: usize) sjon.Ast.Span {
    var seen: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, from, needle)) |at| {
        if (seen == occurrence) {
            return .{ .start = @intCast(at), .end = @intCast(at + needle.len) };
        }
        seen += 1;
        from = at + needle.len;
    }
    unreachable;
}

test "schema bundle: same-name sources contribute distinct forms in source order" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.writePlugin("first.sjon", "same", "first");
    try fixture.writePlugin("second.sjon", "same", "second");

    const config_source = try singleBundleConfig(&.{ "first.sjon", "second.sjon" });
    defer testing.allocator.free(config_source);
    var config = try fixture.parse(config_source);
    defer config.deinit();

    var compiled = try Compiled.load(testing.allocator, testing.io, "ctx", &config, 0);
    defer compiled.deinit();

    try testing.expectEqual(State.ready, compiled.state);
    try testing.expectEqual(@as(usize, 3), compiled.schema.plugins.len);
    try testing.expectEqualStrings("core", compiled.schema.plugins[0].name);
    try testing.expectEqualStrings("same", compiled.schema.plugins[1].name);
    try testing.expectEqualStrings("same", compiled.schema.plugins[2].name);
    try testing.expectEqual(@as(usize, 1), compiled.schema.plugins[1].forms.len);
    try testing.expectEqual(@as(usize, 1), compiled.schema.plugins[2].forms.len);
    try testing.expectEqualStrings("first", compiled.schema.plugins[1].forms[0].name);
    try testing.expectEqualStrings("second", compiled.schema.plugins[2].forms[0].name);

    try testing.expectEqual(@as(usize, 2), compiled.sources.len);
    try testing.expect(std.mem.endsWith(u8, compiled.sources[0].path, "/first.sjon"));
    try testing.expect(std.mem.endsWith(u8, compiled.sources[1].path, "/second.sjon"));
    try testing.expectEqual(@as(usize, 2), compiled.reports.len);
    try testing.expectEqual(@as(usize, 0), compiled.reports[0].diagnostics.len);
    try testing.expectEqual(@as(usize, 0), compiled.reports[1].diagnostics.len);
    try testing.expectEqual(@as(usize, 0), compiled.config_reports.len);
}

test "schema bundle: core appears exactly once in the ready schema" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.writePlugin("alpha.sjon", "alpha", "a");
    try fixture.writePlugin("beta.sjon", "beta", "b");

    const config_source = try singleBundleConfig(&.{ "alpha.sjon", "beta.sjon" });
    defer testing.allocator.free(config_source);
    var config = try fixture.parse(config_source);
    defer config.deinit();

    var compiled = try Compiled.load(testing.allocator, testing.io, "ctx", &config, 0);
    defer compiled.deinit();

    try testing.expectEqual(State.ready, compiled.state);
    try testing.expectEqualStrings("core", compiled.schema.plugins[0].name);

    var core_count: usize = 0;
    for (compiled.schema.plugins) |plugin| {
        if (std.mem.eql(u8, plugin.name, "core")) core_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), core_count);

    const pre = if (compiled.preloaded) |*p| p else return error.TestExpectedPreloaded;
    try testing.expectEqual(@as(usize, 2), pre.plugins.len);
    for (pre.plugins) |plugin| {
        try testing.expect(!std.mem.eql(u8, plugin.name, "core"));
    }
}

test "schema bundle: source order is not hash-map iteration order" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.writePlugin("zeta.sjon", "zeta", "z");
    try fixture.writePlugin("alpha.sjon", "alpha", "a");
    try fixture.writePlugin("middle.sjon", "middle", "m");

    const config_source = try singleBundleConfig(&.{ "zeta.sjon", "alpha.sjon", "middle.sjon" });
    defer testing.allocator.free(config_source);
    var config = try fixture.parse(config_source);
    defer config.deinit();

    var compiled = try Compiled.load(testing.allocator, testing.io, "ctx", &config, 0);
    defer compiled.deinit();

    try testing.expectEqual(State.ready, compiled.state);
    try testing.expectEqual(@as(usize, 4), compiled.schema.plugins.len);
    try testing.expectEqualStrings("zeta", compiled.schema.plugins[1].name);
    try testing.expectEqualStrings("alpha", compiled.schema.plugins[2].name);
    try testing.expectEqualStrings("middle", compiled.schema.plugins[3].name);
    try testing.expectEqualStrings("z", compiled.schema.plugins[1].forms[0].name);
    try testing.expectEqualStrings("a", compiled.schema.plugins[2].forms[0].name);
    try testing.expectEqualStrings("m", compiled.schema.plugins[3].forms[0].name);
}

test "schema bundle: missing required source makes the bundle unavailable" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.writePlugin("present.sjon", "present", "p");

    const config_source = try singleBundleConfig(&.{ "present.sjon", "missing.sjon" });
    defer testing.allocator.free(config_source);
    var config = try fixture.parse(config_source);
    defer config.deinit();

    var compiled = try Compiled.load(testing.allocator, testing.io, "ctx", &config, 0);
    defer compiled.deinit();

    try testing.expectEqual(State.unavailable, compiled.state);
    try testing.expectEqual(@as(usize, 0), compiled.schema.plugins.len);
    try testing.expectEqual(@as(usize, 2), compiled.sources.len);
    try testing.expect(compiled.sources[0].bytes != null);
    try testing.expect(compiled.sources[1].bytes == null);
    try testing.expect(compiled.sources[1].read_error != null);

    // The readable source still compiled, but the partial set must not be
    // presented as a ready schema.
    const pre = if (compiled.preloaded) |*p| p else return error.TestExpectedPreloaded;
    try testing.expectEqual(@as(usize, 1), pre.plugins.len);

    try testing.expectEqual(@as(usize, 1), compiled.config_reports.len);
    const report = compiled.config_reports[0];
    try testing.expectEqualStrings(codes.bundle_source_read, report.code);
    try testing.expectEqual(sjon.Ast.Diagnostic.Severity.err, report.severity);
    try testing.expectEqual(findSpan(config_source, "\"missing.sjon\"", 0), report.span);
    try testing.expectEqual(@as(usize, 1), report.related.len);
    try testing.expectEqual(@as(u32, 0), report.related[0].span.start);
    try testing.expect(report.related[0].uri != null);
    try testing.expect(std.mem.endsWith(u8, report.related[0].uri.?, "missing.sjon"));
}

test "schema bundle: parse failure exposes no partial ready schema" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.writePlugin("good.sjon", "good", "g");
    try fixture.write("broken.sjon", "(plugin :name broken :version \"1.0.0\"");

    const config_source = try singleBundleConfig(&.{ "good.sjon", "broken.sjon" });
    defer testing.allocator.free(config_source);
    var config = try fixture.parse(config_source);
    defer config.deinit();

    var compiled = try Compiled.load(testing.allocator, testing.io, "ctx", &config, 0);
    defer compiled.deinit();

    try testing.expectEqual(State.unavailable, compiled.state);
    try testing.expectEqual(@as(usize, 0), compiled.schema.plugins.len);
    const pre = if (compiled.preloaded) |*p| p else return error.TestExpectedPreloaded;
    // `Host.preloadSchema` may retain a recovered plugin from a malformed
    // source; the error-severity preload diagnostic is what must keep the
    // partial set out of the ready schema.
    try testing.expect(pre.plugins.len >= 1);

    try testing.expect(compiled.reports[1].diagnostics.len > 0);
    for (compiled.reports[1].diagnostics) |diag| {
        try testing.expectEqual(sjon.Host.Phase.manifest, diag.phase);
    }
    try testing.expectEqual(@as(usize, 0), compiled.config_reports.len);
}

test "schema bundle: aggregate failure exposes no partial ready schema" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const source = try sameSource("dangler", "ghost");
    defer testing.allocator.free(source);
    try fixture.write("dangler.sjon", source);

    const config_source = try singleBundleConfig(&.{"dangler.sjon"});
    defer testing.allocator.free(config_source);
    var config = try fixture.parse(config_source);
    defer config.deinit();

    var compiled = try Compiled.load(testing.allocator, testing.io, "ctx", &config, 0);
    defer compiled.deinit();

    try testing.expectEqual(State.unavailable, compiled.state);
    try testing.expectEqual(@as(usize, 0), compiled.schema.plugins.len);
    const pre = if (compiled.preloaded) |*p| p else return error.TestExpectedPreloaded;
    try testing.expectEqual(@as(usize, 1), pre.plugins.len);
    try testing.expectEqual(@as(usize, 1), compiled.config_reports.len);
    try testing.expectEqualStrings(codes.bundle_aggregate, compiled.config_reports[0].code);
    try testing.expectEqual(sjon.Ast.Diagnostic.Severity.err, compiled.config_reports[0].severity);
}

test "schema bundle: unique aggregate source uses the real source span" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const dangling = try sameSource("dangler", "ghost");
    defer testing.allocator.free(dangling);
    try fixture.write("dangler.sjon", dangling);
    try fixture.writePlugin("clean.sjon", "clean", "c");

    const config_source = try singleBundleConfig(&.{ "dangler.sjon", "clean.sjon" });
    defer testing.allocator.free(config_source);
    var config = try fixture.parse(config_source);
    defer config.deinit();

    var compiled = try Compiled.load(testing.allocator, testing.io, "ctx", &config, 0);
    defer compiled.deinit();

    try testing.expectEqual(State.unavailable, compiled.state);
    try testing.expectEqual(@as(usize, 1), compiled.config_reports.len);
    const report = compiled.config_reports[0];
    try testing.expectEqualStrings(codes.bundle_aggregate, report.code);

    // Aggregate validators emit zero spans today, so the honest real span is
    // the uniquely named source's manifest entry in the configuration — not
    // the bundle form and not an invented offset into the source bytes.
    const manifest_span = findSpan(config_source, "\"dangler.sjon\"", 0);
    try testing.expectEqual(manifest_span, report.span);
    try testing.expect(manifest_span.start != 0);
    try testing.expect(manifest_span.start > findSpan(config_source, "(bundle", 0).start);
    try testing.expect(std.mem.indexOf(u8, report.message, "dangler.sjon") != null);
    try testing.expect(std.mem.indexOf(u8, report.message, "ghost") != null);
}

test "schema bundle: same-name aggregate ambiguity uses config entries and names participants" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const first = try sameSource("same", "ghost-one");
    defer testing.allocator.free(first);
    const second = try sameSource("same", "ghost-two");
    defer testing.allocator.free(second);
    try fixture.write("first.sjon", first);
    try fixture.write("second.sjon", second);

    const config_source = try singleBundleConfig(&.{ "first.sjon", "second.sjon" });
    defer testing.allocator.free(config_source);
    var config = try fixture.parse(config_source);
    defer config.deinit();

    var compiled = try Compiled.load(testing.allocator, testing.io, "ctx", &config, 0);
    defer compiled.deinit();

    try testing.expectEqual(State.unavailable, compiled.state);
    try testing.expectEqual(@as(usize, 2), compiled.config_reports.len);

    const bundle_span = findSpan(config_source, "(bundle", 0);
    const first_entry = findSpan(config_source, "\"first.sjon\"", 0);
    const second_entry = findSpan(config_source, "\"second.sjon\"", 0);

    for (compiled.config_reports) |report| {
        try testing.expectEqualStrings(codes.bundle_aggregate, report.code);
        try testing.expectEqual(bundle_span.start, report.span.start);
        try testing.expect(std.mem.indexOf(u8, report.message, "first.sjon") != null);
        try testing.expect(std.mem.indexOf(u8, report.message, "second.sjon") != null);
        try testing.expectEqual(@as(usize, 2), report.related.len);
        try testing.expectEqual(first_entry, report.related[0].span);
        try testing.expectEqual(second_entry, report.related[1].span);
    }
}

test "schema bundle: unrelated valid bundle remains ready" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.writePlugin("good.sjon", "good", "g");

    const config_source = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "(sjon-lsp :version 1 :bundles [" ++
            " (bundle :name bad :files [\"bad.sjon\"] :manifests [\"missing.sjon\"])" ++
            " (bundle :name good :files [\"good.sjon\"] :manifests [\"good.sjon\"])" ++
            "])",
        .{},
        0,
    );
    defer testing.allocator.free(config_source);
    var config = try fixture.parse(config_source);
    defer config.deinit();

    var bad = try Compiled.load(testing.allocator, testing.io, "ctx", &config, 0);
    defer bad.deinit();
    try testing.expectEqual(State.unavailable, bad.state);
    try testing.expectEqual(@as(usize, 1), bad.config_reports.len);

    var good = try Compiled.load(testing.allocator, testing.io, "ctx", &config, 1);
    defer good.deinit();
    try testing.expectEqual(State.ready, good.state);
    try testing.expectEqual(@as(usize, 2), good.schema.plugins.len);
    try testing.expectEqualStrings("core", good.schema.plugins[0].name);
    try testing.expectEqualStrings("good", good.schema.plugins[1].name);
    try testing.expectEqual(@as(usize, 0), good.config_reports.len);
}
