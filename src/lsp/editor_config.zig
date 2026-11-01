//! Strict reader for the editor-local `sjon-lsp.sjon` configuration.
//!
//! This module owns only the configuration grammar: it parses and validates
//! the file into `Config`/`Bundle`/`Pattern`/`Manifest` values and exposes
//! strict bundle matching. It performs no discovery, reads no manifests, and
//! creates no handlers.
//!
//! The file is parsed with the ordinary SJON `Parser`; this is a typed reader,
//! not a second parser. Every diagnostic here is an editor-local string
//! identifier (`sjon-lsp/...`), deliberately not an `Ast.Diagnostic.Code`
//! variant: the wire-stable diagnostic enum is not extended for editor
//! configuration.

const std = @import("std");
const sjon = @import("sjon");
const uri = @import("uri");
const testing = std.testing;

const Allocator = std.mem.Allocator;

pub const codes = struct {
    pub const config_read: []const u8 = "sjon-lsp/config-read";
    pub const config_shape: []const u8 = "sjon-lsp/config-shape";
    pub const config_version: []const u8 = "sjon-lsp/config-version";
    pub const config_duplicate_key: []const u8 = "sjon-lsp/config-duplicate-key";
    pub const config_unknown_field: []const u8 = "sjon-lsp/config-unknown-field";
    pub const config_type: []const u8 = "sjon-lsp/config-type";
    pub const config_empty_list: []const u8 = "sjon-lsp/config-empty-list";
    pub const config_duplicate_bundle: []const u8 = "sjon-lsp/config-duplicate-bundle";
    pub const config_pattern: []const u8 = "sjon-lsp/config-pattern";
    pub const config_path: []const u8 = "sjon-lsp/config-path";
    pub const config_duplicate_source: []const u8 = "sjon-lsp/config-duplicate-source";
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    uri: []const u8,
    source: [:0]const u8,
    bundles: []const Bundle = &.{},
    parse_diagnostics: []const sjon.Ast.Diagnostic = &.{},
    diagnostics: []const Diagnostic = &.{},

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }

    /// True when the file has parser errors or any typed configuration error.
    /// Callers must gate typed use of `bundles` on this being false.
    pub fn hasErrors(self: *const Config) bool {
        if (self.diagnostics.len != 0) return true;
        for (self.parse_diagnostics) |diag| {
            if (diag.severity == .err) return true;
        }
        return false;
    }

    /// Count bundles whose patterns match `relative_path`, a `/`-normalized
    /// document path relative to the configuration directory.
    ///
    /// Multiple patterns inside one bundle still count that bundle once.
    /// `second != null` means the document is a bundle conflict.
    pub fn matchBundles(self: *const Config, relative_path: []const u8) BundleMatches {
        var matches: BundleMatches = .{};
        for (self.bundles, 0..) |bundle, index| {
            if (!bundle.matchesPath(relative_path)) continue;
            matches.count += 1;
            if (matches.first == null) {
                matches.first = index;
            } else if (matches.second == null) {
                matches.second = index;
            }
        }
        return matches;
    }
};

pub const Bundle = struct {
    name: []const u8,
    name_span: sjon.Ast.Span,
    span: sjon.Ast.Span,
    patterns: []const Pattern,
    manifests: []const Manifest,

    pub fn matchesPath(self: *const Bundle, relative_path: []const u8) bool {
        if (!isRelativeDocumentPath(relative_path)) return false;
        for (self.patterns) |pattern| {
            if (pattern.matches(relative_path)) return true;
        }
        return false;
    }
};

pub const Pattern = struct {
    /// The validated source spelling. `parse` rejects every construct outside
    /// the strict grammar before constructing a `Pattern`; `matches` re-checks
    /// as a defense-in-depth guard before calling `Glob.match`.
    source: []const u8,

    pub fn matches(self: Pattern, relative_path: []const u8) bool {
        if (!isRelativeDocumentPath(relative_path)) return false;
        // Defense in depth: even a hand-constructed `Pattern` must not reach
        // `Glob.match` with a construct outside the strict grammar.
        if (patternProblem(self.source) != null) return false;
        return sjon.Glob.match(self.source, relative_path);
    }
};

pub const Manifest = struct {
    /// Lexically normalized path resolved against the configuration directory.
    path: []const u8,
    /// The original string spelling, retained for diagnostics.
    source: []const u8,
    span: sjon.Ast.Span,
};

pub const Related = struct {
    message: []const u8,
    span: sjon.Ast.Span,
};

pub const Diagnostic = struct {
    code: []const u8,
    message: []const u8,
    span: sjon.Ast.Span,
    related: []const Related = &.{},
};

pub const BundleMatches = struct {
    count: usize = 0,
    first: ?usize = null,
    second: ?usize = null,
};

/// Parse a `sjon-lsp.sjon` source. Always returns a `Config` (unless OOM):
/// parser errors are retained in `parse_diagnostics` and stop the typed walk;
/// typed configuration errors are appended to `diagnostics`.
///
/// `source` is copied into the returned arena, so the caller may release its
/// buffer immediately. `path` and `uri` identify the configuration file.
pub fn parse(
    gpa: Allocator,
    config_path: []const u8,
    source: [:0]const u8,
) Allocator.Error!Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const path = try normalizeConfigPath(a, config_path);
    const config_uri = try uri.pathToFileUri(a, path);
    const owned_source = try a.dupeZ(u8, source);

    var tree = try sjon.Parser.parse(a, owned_source);
    defer tree.deinit();

    var parse_diags: std.ArrayList(sjon.Ast.Diagnostic) = .empty;
    for (tree.diagnostics) |diag| {
        try parse_diags.append(a, try diag.dupe(a));
    }
    const parse_diagnostic_slice = try parse_diags.toOwnedSlice(a);

    if (tree.hasErrors()) {
        // Do not typed-walk a recovered tree: a missing delimiter can make
        // the parsed shape look valid while it is not the user's file.
        return .{
            .arena = arena,
            .path = path,
            .uri = config_uri,
            .source = owned_source,
            .parse_diagnostics = parse_diagnostic_slice,
        };
    }

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    var bundles: std.ArrayList(Bundle) = .empty;
    const config_dir = std.fs.path.dirname(path) orelse ".";
    try walkConfig(a, &diagnostics, &bundles, tree, config_dir);

    const diagnostic_slice = try diagnostics.toOwnedSlice(a);
    const bundle_slice = try bundles.toOwnedSlice(a);
    return .{
        .arena = arena,
        .path = path,
        .uri = config_uri,
        .source = owned_source,
        .bundles = bundle_slice,
        .parse_diagnostics = parse_diagnostic_slice,
        .diagnostics = diagnostic_slice,
    };
}

/// Read and parse `config_path`. Filesystem failures become a
/// `sjon-lsp/config-read` diagnostic at byte 0 rather than an Io error; only
/// allocation failure escapes.
pub fn load(
    gpa: Allocator,
    io: std.Io,
    config_path: []const u8,
) Allocator.Error!Config {
    const bytes = sjon.CappedRead.readFileZ(io, config_path, gpa, sjon.CappedRead.MAX_FILE_SIZE) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return loadFailure(gpa, config_path),
    };
    defer gpa.free(bytes);
    return parse(gpa, config_path, bytes);
}

fn loadFailure(gpa: Allocator, config_path: []const u8) Allocator.Error!Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const path = try normalizeConfigPath(a, config_path);
    const config_uri = try uri.pathToFileUri(a, path);
    const source = try a.dupeZ(u8, "");

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    try diagnostics.append(a, .{
        .code = codes.config_read,
        .message = try std.fmt.allocPrint(a, "unable to read editor configuration `{s}`", .{path}),
        .span = .{ .start = 0, .end = 0 },
    });
    const diagnostic_slice = try diagnostics.toOwnedSlice(a);

    return .{
        .arena = arena,
        .path = path,
        .uri = config_uri,
        .source = source,
        .diagnostics = diagnostic_slice,
    };
}

const SeenKey = struct { key: []const u8, span: sjon.Ast.Span };
const SeenName = struct { name: []const u8, span: sjon.Ast.Span };
const SeenSource = struct { path: []const u8, span: sjon.Ast.Span };

fn normalizeConfigPath(a: Allocator, config_path: []const u8) Allocator.Error![]const u8 {
    if (config_path.len == 0) return a.dupe(u8, ".");
    return std.fs.path.resolve(a, &.{config_path});
}

fn walkConfig(
    a: Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    bundles: *std.ArrayList(Bundle),
    tree: sjon.Ast.Tree,
    config_dir: []const u8,
) Allocator.Error!void {
    if (tree.root.len == 0) {
        try emitShape(
            a,
            diagnostics,
            .{ .start = 0, .end = 0 },
            "expected exactly one `(sjon-lsp ...)` root form; found none",
        );
        return;
    }
    if (tree.root.len > 1) {
        try emitShape(
            a,
            diagnostics,
            tree.spanOf(tree.root[1]),
            "expected exactly one `(sjon-lsp ...)` root form",
        );
        return;
    }

    const root = tree.root[0];
    if (tree.tagOf(root) != .form) {
        try emitShape(a, diagnostics, tree.spanOf(root), "expected a `(sjon-lsp ...)` form at the root");
        return;
    }
    const header = tree.formHeader(root);
    if (header.namespace != null or !std.mem.eql(u8, header.head, "sjon-lsp")) {
        try emitShape(
            a,
            diagnostics,
            header.head_span,
            "expected an unqualified `(sjon-lsp ...)` root form",
        );
        return;
    }

    var seen_keys: std.ArrayList(SeenKey) = .empty;
    var have_version = false;
    var have_bundles = false;

    for (header.children) |child| {
        if (tree.tagOf(child) != .kvpair) {
            try emitShape(
                a,
                diagnostics,
                tree.spanOf(child),
                "unexpected positional child in `(sjon-lsp ...)`",
            );
            continue;
        }
        const kv = tree.kvpairHeader(child);
        if (try markKey(a, &seen_keys, kv.key, kv.key_span, diagnostics)) continue;

        if (std.mem.eql(u8, kv.key, "version")) {
            have_version = true;
            try readVersion(a, diagnostics, tree, kv.value);
        } else if (std.mem.eql(u8, kv.key, "bundles")) {
            have_bundles = true;
            try readBundles(a, diagnostics, bundles, tree, kv.value, config_dir);
        } else {
            try emit(
                a,
                diagnostics,
                codes.config_unknown_field,
                kv.key_span,
                try std.fmt.allocPrint(
                    a,
                    "unknown `(sjon-lsp ...)` key `:{s}`",
                    .{kv.key},
                ),
            );
        }
    }

    const root_span = tree.spanOf(root);
    if (!have_version) {
        try emitShape(a, diagnostics, root_span, "missing required `:version`");
    }
    if (!have_bundles) {
        try emitShape(a, diagnostics, root_span, "missing required `:bundles`");
    }
}

fn readVersion(
    a: Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    tree: sjon.Ast.Tree,
    value: sjon.Ast.NodeIndex,
) Allocator.Error!void {
    const span = tree.spanOf(value);
    switch (tree.tagOf(value)) {
        .number_i64 => {
            if (tree.numberI64Of(value) != 1) {
                try emit(
                    a,
                    diagnostics,
                    codes.config_version,
                    span,
                    "unsupported `:version`; this editor configuration is version 1",
                );
            }
        },
        .number_u64 => {
            if (tree.numberU64Of(value) != 1) {
                try emit(
                    a,
                    diagnostics,
                    codes.config_version,
                    span,
                    "unsupported `:version`; this editor configuration is version 1",
                );
            }
        },
        else => try emit(
            a,
            diagnostics,
            codes.config_type,
            span,
            "`:version` must be the exact integer 1",
        ),
    }
}

fn readBundles(
    a: Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    bundles: *std.ArrayList(Bundle),
    tree: sjon.Ast.Tree,
    value: sjon.Ast.NodeIndex,
    config_dir: []const u8,
) Allocator.Error!void {
    if (tree.tagOf(value) != .vector) {
        try emit(
            a,
            diagnostics,
            codes.config_type,
            tree.spanOf(value),
            "`:bundles` must be a vector",
        );
        return;
    }

    var seen_names: std.ArrayList(SeenName) = .empty;
    for (tree.vectorElements(value)) |element| {
        try readBundle(a, diagnostics, bundles, &seen_names, tree, element, config_dir);
    }
}

fn readBundle(
    a: Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    bundles: *std.ArrayList(Bundle),
    seen_names: *std.ArrayList(SeenName),
    tree: sjon.Ast.Tree,
    node: sjon.Ast.NodeIndex,
    config_dir: []const u8,
) Allocator.Error!void {
    if (tree.tagOf(node) != .form) {
        try emitShape(
            a,
            diagnostics,
            tree.spanOf(node),
            "`:bundles` entries must be `(bundle ...)` forms",
        );
        return;
    }
    const header = tree.formHeader(node);
    if (header.namespace != null or !std.mem.eql(u8, header.head, "bundle")) {
        try emitShape(
            a,
            diagnostics,
            header.head_span,
            "expected an unqualified `(bundle ...)` form",
        );
        return;
    }
    const form_span = tree.spanOf(node);

    var seen_keys: std.ArrayList(SeenKey) = .empty;
    var name: ?[]const u8 = null;
    var name_span: sjon.Ast.Span = .{ .start = 0, .end = 0 };
    var patterns: std.ArrayList(Pattern) = .empty;
    var manifests: std.ArrayList(Manifest) = .empty;
    var have_name = false;
    var have_files = false;
    var have_manifests = false;
    var valid = true;

    for (header.children) |child| {
        if (tree.tagOf(child) != .kvpair) {
            try emitShape(
                a,
                diagnostics,
                tree.spanOf(child),
                "unexpected positional child in `(bundle ...)`",
            );
            valid = false;
            continue;
        }
        const kv = tree.kvpairHeader(child);
        if (try markKey(a, &seen_keys, kv.key, kv.key_span, diagnostics)) {
            valid = false;
            continue;
        }

        if (std.mem.eql(u8, kv.key, "name")) {
            have_name = true;
            if (tree.tagOf(kv.value) != .symbol) {
                try emit(
                    a,
                    diagnostics,
                    codes.config_type,
                    tree.spanOf(kv.value),
                    "`:name` must be a symbol",
                );
                valid = false;
                continue;
            }
            const text = tree.symbolText(kv.value);
            const span = tree.spanOf(kv.value);
            name = try a.dupe(u8, text);
            name_span = span;

            var duplicate = false;
            for (seen_names.items) |prior| {
                if (!std.mem.eql(u8, prior.name, text)) continue;
                try emitWithRelated(
                    a,
                    diagnostics,
                    codes.config_duplicate_bundle,
                    span,
                    try std.fmt.allocPrint(a, "duplicate bundle name `{s}`", .{text}),
                    prior.span,
                    "first bundle with this name declared here",
                );
                duplicate = true;
                break;
            }
            if (!duplicate) {
                try seen_names.append(a, .{ .name = try a.dupe(u8, text), .span = span });
            }
        } else if (std.mem.eql(u8, kv.key, "files")) {
            have_files = true;
            if (!try readPatterns(a, diagnostics, &patterns, tree, kv.value)) valid = false;
        } else if (std.mem.eql(u8, kv.key, "manifests")) {
            have_manifests = true;
            if (!try readManifests(a, diagnostics, &manifests, tree, kv.value, config_dir)) valid = false;
        } else {
            try emit(
                a,
                diagnostics,
                codes.config_unknown_field,
                kv.key_span,
                try std.fmt.allocPrint(a, "unknown `(bundle ...)` key `:{s}`", .{kv.key}),
            );
            valid = false;
        }
    }

    if (!have_name) {
        try emitShape(a, diagnostics, form_span, "missing required `:name`");
        valid = false;
    }
    if (!have_files) {
        try emitShape(a, diagnostics, form_span, "missing required `:files`");
        valid = false;
    }
    if (!have_manifests) {
        try emitShape(a, diagnostics, form_span, "missing required `:manifests`");
        valid = false;
    }

    if (valid) {
        const pattern_slice = try patterns.toOwnedSlice(a);
        const manifest_slice = try manifests.toOwnedSlice(a);
        try bundles.append(a, .{
            .name = name.?,
            .name_span = name_span,
            .span = form_span,
            .patterns = pattern_slice,
            .manifests = manifest_slice,
        });
    }
}

fn readPatterns(
    a: Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    patterns: *std.ArrayList(Pattern),
    tree: sjon.Ast.Tree,
    value: sjon.Ast.NodeIndex,
) Allocator.Error!bool {
    if (tree.tagOf(value) != .vector) {
        try emit(
            a,
            diagnostics,
            codes.config_type,
            tree.spanOf(value),
            "`:files` must be a vector of strings",
        );
        return false;
    }
    const elements = tree.vectorElements(value);
    if (elements.len == 0) {
        try emit(
            a,
            diagnostics,
            codes.config_empty_list,
            tree.spanOf(value),
            "`:files` must not be empty",
        );
        return false;
    }

    var ok = true;
    for (elements) |element| {
        const span = tree.spanOf(element);
        if (tree.tagOf(element) != .string) {
            try emit(a, diagnostics, codes.config_type, span, "`:files` entries must be strings");
            ok = false;
            continue;
        }
        const text = tree.stringText(element);
        if (patternProblem(text)) |problem| {
            try emit(
                a,
                diagnostics,
                codes.config_pattern,
                span,
                try std.fmt.allocPrint(a, "invalid file pattern \"{s}\": {s}", .{ text, problem }),
            );
            ok = false;
            continue;
        }
        try patterns.append(a, .{ .source = try a.dupe(u8, text) });
    }
    return ok;
}

fn readManifests(
    a: Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    manifests: *std.ArrayList(Manifest),
    tree: sjon.Ast.Tree,
    value: sjon.Ast.NodeIndex,
    config_dir: []const u8,
) Allocator.Error!bool {
    if (tree.tagOf(value) != .vector) {
        try emit(
            a,
            diagnostics,
            codes.config_type,
            tree.spanOf(value),
            "`:manifests` must be a vector of strings",
        );
        return false;
    }
    const elements = tree.vectorElements(value);
    if (elements.len == 0) {
        try emit(
            a,
            diagnostics,
            codes.config_empty_list,
            tree.spanOf(value),
            "`:manifests` must not be empty",
        );
        return false;
    }

    var ok = true;
    var seen: std.ArrayList(SeenSource) = .empty;
    for (elements) |element| {
        const span = tree.spanOf(element);
        if (tree.tagOf(element) != .string) {
            try emit(a, diagnostics, codes.config_type, span, "`:manifests` entries must be strings");
            ok = false;
            continue;
        }
        const text = tree.stringText(element);
        if (manifestProblem(text)) |problem| {
            try emit(
                a,
                diagnostics,
                codes.config_path,
                span,
                try std.fmt.allocPrint(a, "invalid manifest path \"{s}\": {s}", .{ text, problem }),
            );
            ok = false;
            continue;
        }

        const normalized = try std.fs.path.resolve(a, &.{ config_dir, text });
        var duplicate = false;
        for (seen.items) |prior| {
            if (!std.mem.eql(u8, prior.path, normalized)) continue;
            try emitWithRelated(
                a,
                diagnostics,
                codes.config_duplicate_source,
                span,
                try std.fmt.allocPrint(a, "repeated manifest source `{s}` in one bundle", .{normalized}),
                prior.span,
                "first occurrence of this source in the bundle",
            );
            duplicate = true;
            ok = false;
            break;
        }
        if (duplicate) continue;

        try seen.append(a, .{ .path = normalized, .span = span });
        try manifests.append(a, .{
            .path = normalized,
            .source = try a.dupe(u8, text),
            .span = span,
        });
    }
    return ok;
}

/// A pattern's only function is to gate `Glob.match`; rejecting the wider
/// `Glob` dialect here is what keeps `?`/braces/character classes/embedded
/// `**` from ever reaching it.
fn patternProblem(text: []const u8) ?[]const u8 {
    if (text.len == 0) return "pattern is empty";
    if (text.len > sjon.Glob.MAX_PATTERN_LEN) return "pattern is longer than Glob.MAX_PATTERN_LEN";
    if (text[0] == '/') return "pattern must be relative";
    if (std.mem.indexOfScalar(u8, text, 0) != null) return "pattern contains a NUL byte";
    if (std.mem.indexOfScalar(u8, text, '\\') != null) return "pattern contains a backslash";
    if (containsAny(text, "?{}[]")) return "pattern uses a metacharacter outside the strict grammar";

    var segments = std.mem.splitScalar(u8, text, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return "pattern has an empty segment";
        if (std.mem.eql(u8, segment, "..")) return "pattern must not contain `..`";
        if (std.mem.indexOf(u8, segment, "**") != null and !std.mem.eql(u8, segment, "**")) {
            return "`**` must be a whole path segment";
        }
    }
    return null;
}

fn manifestProblem(text: []const u8) ?[]const u8 {
    if (text.len == 0) return "path is empty";
    if (std.mem.indexOfScalar(u8, text, 0) != null) return "path contains a NUL byte";
    if (std.mem.indexOfScalar(u8, text, '\\') != null) return "path contains a backslash";
    if (looksLikeUrl(text)) return "path must not be a URL";
    if (containsAny(text, "*?{}[]")) return "path must not contain glob metacharacters";
    return null;
}

fn looksLikeUrl(text: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return false;
    if (colon == 0) return false;
    if (!std.ascii.isAlphabetic(text[0])) return false;
    for (text[1..colon]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    // Only a scheme-shaped prefix before any path separator is URL-shaped;
    // POSIX permits `:` inside ordinary file names.
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse text.len;
    return colon < slash;
}

fn containsAny(text: []const u8, needles: []const u8) bool {
    for (text) |c| {
        if (std.mem.indexOfScalar(u8, needles, c) != null) return true;
    }
    return false;
}

fn isRelativeDocumentPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

fn markKey(
    a: Allocator,
    seen: *std.ArrayList(SeenKey),
    key: []const u8,
    span: sjon.Ast.Span,
    diagnostics: *std.ArrayList(Diagnostic),
) Allocator.Error!bool {
    for (seen.items) |prior| {
        if (!std.mem.eql(u8, prior.key, key)) continue;
        try emitWithRelated(
            a,
            diagnostics,
            codes.config_duplicate_key,
            span,
            try std.fmt.allocPrint(a, "duplicate key `:{s}`", .{key}),
            prior.span,
            "first key declared here",
        );
        return true;
    }
    try seen.append(a, .{ .key = try a.dupe(u8, key), .span = span });
    return false;
}

fn emitShape(
    a: Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    span: sjon.Ast.Span,
    message: []const u8,
) Allocator.Error!void {
    try emit(a, diagnostics, codes.config_shape, span, message);
}

fn emit(
    a: Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    code: []const u8,
    span: sjon.Ast.Span,
    message: []const u8,
) Allocator.Error!void {
    try diagnostics.append(a, .{
        .code = code,
        .message = message,
        .span = span,
    });
}

fn emitWithRelated(
    a: Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    code: []const u8,
    span: sjon.Ast.Span,
    message: []const u8,
    related_span: sjon.Ast.Span,
    related_message: []const u8,
) Allocator.Error!void {
    const related = try a.alloc(Related, 1);
    related[0] = .{ .message = related_message, .span = related_span };
    try diagnostics.append(a, .{
        .code = code,
        .message = message,
        .span = span,
        .related = related,
    });
}

// ---------------------------------------------------------------------------
// Tests — write first, then implement against them.
// ---------------------------------------------------------------------------

fn parseConfig(source: [:0]const u8) !Config {
    return parse(testing.allocator, "/work/project/sjon-lsp.sjon", source);
}

fn expectCodes(config: *const Config, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, config.diagnostics.len);
    for (expected, config.diagnostics) |want, got| {
        try testing.expectEqualStrings(want, got.code);
    }
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

test "editor config: accepts version one and an empty bundles vector" {
    const src: [:0]const u8 = "(sjon-lsp :version 1 :bundles [])";
    var config = try parseConfig(src);
    defer config.deinit();

    try testing.expect(!config.hasErrors());
    try testing.expectEqual(@as(usize, 0), config.diagnostics.len);
    try testing.expectEqual(@as(usize, 0), config.parse_diagnostics.len);
    try testing.expectEqual(@as(usize, 0), config.bundles.len);

    // `load` is the same reader over the capped file reader; a missing file
    // is a `config-read` diagnostic, not an allocator/Io error.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sjon-lsp.sjon", .data = src });
    const path = try std.fmt.allocPrint(
        testing.allocator,
        ".zig-cache/tmp/{s}/sjon-lsp.sjon",
        .{&tmp.sub_path},
    );
    defer testing.allocator.free(path);

    var loaded = try load(testing.allocator, testing.io, path);
    defer loaded.deinit();
    try testing.expect(!loaded.hasErrors());
    try testing.expectEqual(@as(usize, 0), loaded.bundles.len);

    var missing = try load(
        testing.allocator,
        testing.io,
        ".zig-cache/tmp/definitely-not-a-config/sjon-lsp.sjon",
    );
    defer missing.deinit();
    try testing.expect(missing.hasErrors());
    try testing.expectEqual(@as(usize, 1), missing.diagnostics.len);
    try testing.expectEqualStrings(codes.config_read, missing.diagnostics[0].code);
    try testing.expectEqual(@as(u32, 0), missing.diagnostics[0].span.start);
}

test "editor config: rejects duplicate keys unknown fields wrong types and missing fields with spans" {
    const src: [:0]const u8 =
        "(sjon-lsp :version 1 :version 1 :bogus 2 :bundles [" ++
        "  (bundle :name a :name b :unknown 1 :files \"nope\" :manifests [])" ++
        "  (bundle :name \"bad\" :files [\"x\"])" ++
        "])";
    var config = try parseConfig(src);
    defer config.deinit();

    try testing.expect(config.hasErrors());
    try expectCodes(&config, &.{
        codes.config_duplicate_key,
        codes.config_unknown_field,
        codes.config_duplicate_key,
        codes.config_unknown_field,
        codes.config_type,
        codes.config_empty_list,
        codes.config_type,
        codes.config_shape,
    });

    // Duplicate `:version` points at the second key and relates the first.
    try testing.expectEqual(findSpan(src, ":version", 1), config.diagnostics[0].span);
    try testing.expectEqual(@as(usize, 1), config.diagnostics[0].related.len);
    try testing.expectEqual(findSpan(src, ":version", 0), config.diagnostics[0].related[0].span);
    try testing.expectEqual(findSpan(src, ":bogus", 0), config.diagnostics[1].span);
    // Duplicate `:name` inside one bundle.
    try testing.expectEqual(findSpan(src, ":name", 1), config.diagnostics[2].span);
    try testing.expectEqual(findSpan(src, ":unknown", 0), config.diagnostics[3].span);
    // Wrong value type points at the value; empty list points at the vector.
    try testing.expectEqual(findSpan(src, "\"nope\"", 0), config.diagnostics[4].span);
    try testing.expectEqual(findSpan(src, "[]", 0), config.diagnostics[5].span);
    try testing.expectEqual(findSpan(src, "\"bad\"", 0), config.diagnostics[6].span);
    // Missing `:manifests` points at the containing bundle form.
    try testing.expectEqual(
        findSpan(src, "(bundle :name \"bad\"", 0).start,
        config.diagnostics[7].span.start,
    );
}

test "editor config: rejects wrong root shape and positional children with config-shape" {
    const cases = [_][:0]const u8{
        "",
        "[\"not a form\"]",
        "(other :version 1 :bundles [])",
        "(ns/sjon-lsp :version 1 :bundles [])",
        "(sjon-lsp extra :version 1 :bundles [])",
        "(sjon-lsp :version 1 :bundles [(bundle :name a :files [\"x.sjon\"] :manifests [\"m.sjon\"] positional)])",
        "(sjon-lsp :version 1 :bundles []) (sjon-lsp :version 1 :bundles [])",
    };
    for (cases) |src| {
        var config = try parseConfig(src);
        defer config.deinit();
        try testing.expect(config.hasErrors());
        try expectCodes(&config, &.{codes.config_shape});
    }
}

test "editor config: rejects unsupported versions and empty required lists" {
    {
        const src: [:0]const u8 = "(sjon-lsp :version 2 :bundles [])";
        var config = try parseConfig(src);
        defer config.deinit();
        try expectCodes(&config, &.{codes.config_version});
        try testing.expectEqual(findSpan(src, "2", 0), config.diagnostics[0].span);
    }
    {
        const src: [:0]const u8 = "(sjon-lsp :version \"1\" :bundles [])";
        var config = try parseConfig(src);
        defer config.deinit();
        try expectCodes(&config, &.{codes.config_type});
        try testing.expectEqual(findSpan(src, "\"1\"", 0), config.diagnostics[0].span);
    }
    {
        // A floating-point `1.0` is not an exact integer node.
        const src: [:0]const u8 = "(sjon-lsp :version 1.0 :bundles [])";
        var config = try parseConfig(src);
        defer config.deinit();
        try expectCodes(&config, &.{codes.config_type});
    }
    {
        const src: [:0]const u8 =
            "(sjon-lsp :version 1 :bundles [" ++
            "  (bundle :name a :files [] :manifests [\"m.sjon\"])" ++
            "  (bundle :name b :files [\"x.sjon\"] :manifests [])" ++
            "])";
        var config = try parseConfig(src);
        defer config.deinit();
        try expectCodes(&config, &.{ codes.config_empty_list, codes.config_empty_list });
        try testing.expectEqual(findSpan(src, "[]", 0), config.diagnostics[0].span);
        try testing.expectEqual(findSpan(src, "[]", 1), config.diagnostics[1].span);
    }
}

test "editor config: rejects duplicate bundle names with related locations" {
    const src: [:0]const u8 =
        "(sjon-lsp :version 1 :bundles [" ++
        "  (bundle :name dup :files [\"a.sjon\"] :manifests [\"a.sjon\"])" ++
        "  (bundle :name dup :files [\"b.sjon\"] :manifests [\"b.sjon\"])" ++
        "])";
    var config = try parseConfig(src);
    defer config.deinit();

    try expectCodes(&config, &.{codes.config_duplicate_bundle});
    try testing.expectEqual(findSpan(src, "dup", 1), config.diagnostics[0].span);
    try testing.expectEqual(@as(usize, 1), config.diagnostics[0].related.len);
    try testing.expectEqual(findSpan(src, "dup", 0), config.diagnostics[0].related[0].span);
}

test "editor config: normalizes absolute and parent manifest paths" {
    const src: [:0]const u8 =
        "(sjon-lsp :version 1 :bundles [" ++
        "  (bundle :name a :files [\"**/*.sjon\"] :manifests [" ++
        "    \"schemas/first.sjon\"" ++
        "    \"../shared/second.sjon\"" ++
        "    \"/abs/third.sjon\"" ++
        "    \"a/./b/../c.sjon\"] )" ++
        "])";
    var config = try parseConfig(src);
    defer config.deinit();

    try testing.expect(!config.hasErrors());
    try testing.expectEqual(@as(usize, 1), config.bundles.len);
    const manifests = config.bundles[0].manifests;
    try testing.expectEqual(@as(usize, 4), manifests.len);
    try testing.expectEqualStrings("/work/project/schemas/first.sjon", manifests[0].path);
    try testing.expectEqualStrings("/work/shared/second.sjon", manifests[1].path);
    try testing.expectEqualStrings("/abs/third.sjon", manifests[2].path);
    try testing.expectEqualStrings("/work/project/a/c.sjon", manifests[3].path);
    // The original spelling survives alongside the normalized path.
    try testing.expectEqualStrings("../shared/second.sjon", manifests[1].source);
}

test "editor config: rejects repeated normalized source paths only within one bundle" {
    {
        const src: [:0]const u8 =
            "(sjon-lsp :version 1 :bundles [" ++
            "  (bundle :name a :files [\"a.sjon\"] :manifests [\"shared.sjon\"])" ++
            "  (bundle :name b :files [\"b.sjon\"] :manifests [\"shared.sjon\"])" ++
            "])";
        var config = try parseConfig(src);
        defer config.deinit();
        try testing.expect(!config.hasErrors());
        try testing.expectEqual(@as(usize, 2), config.bundles.len);
    }
    {
        const src: [:0]const u8 =
            "(sjon-lsp :version 1 :bundles [" ++
            "  (bundle :name a :files [\"a.sjon\"] :manifests [" ++
            "    \"a/../shared.sjon\" \"shared.sjon\"])" ++
            "])";
        var config = try parseConfig(src);
        defer config.deinit();
        try expectCodes(&config, &.{codes.config_duplicate_source});
        try testing.expectEqual(findSpan(src, "\"shared.sjon\"", 0), config.diagnostics[0].span);
        try testing.expectEqual(@as(usize, 1), config.diagnostics[0].related.len);
        try testing.expectEqual(
            findSpan(src, "\"a/../shared.sjon\"", 0),
            config.diagnostics[0].related[0].span,
        );
    }
}

test "editor config: rejects URL paths environment-free glob paths and NUL" {
    {
        const src: [:0]const u8 =
            "(sjon-lsp :version 1 :bundles [" ++
            "  (bundle :name a :files [\"a.sjon\"] :manifests [\"$HOME/schema.sjon\"])" ++
            "])";
        var config = try parseConfig(src);
        defer config.deinit();
        try testing.expect(!config.hasErrors());
        try testing.expectEqualStrings(
            "/work/project/$HOME/schema.sjon",
            config.bundles[0].manifests[0].path,
        );
    }
    {
        const src: [:0]const u8 =
            "(sjon-lsp :version 1 :bundles [" ++
            "  (bundle :name a :files [\"a.sjon\"] :manifests [" ++
            "    \"https://example.com/s.sjon\"" ++
            "    \"schemas/*.sjon\"" ++
            "    \"schemas\\\\x.sjon\"" ++
            "    \"bad\x00path\"])" ++
            "])";
        var config = try parseConfig(src);
        defer config.deinit();
        try expectCodes(&config, &.{
            codes.config_path,
            codes.config_path,
            codes.config_path,
            codes.config_path,
        });
        try testing.expectEqual(
            findSpan(src, "\"https://example.com/s.sjon\"", 0),
            config.diagnostics[0].span,
        );
        try testing.expectEqual(
            findSpan(src, "\"schemas/*.sjon\"", 0),
            config.diagnostics[1].span,
        );
        try testing.expectEqual(
            findSpan(src, "\"schemas\\\\x.sjon\"", 0),
            config.diagnostics[2].span,
        );
        try testing.expectEqual(findSpan(src, "\"bad\x00path\"", 0), config.diagnostics[3].span);
    }
}

test "editor config: rejects Glob-only metacharacters and embedded recursive stars" {
    const over = "a" ** (sjon.Glob.MAX_PATTERN_LEN + 1);
    const long_quoted = try std.fmt.allocPrint(testing.allocator, "\"{s}\"", .{over});
    defer testing.allocator.free(long_quoted);

    const src = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "(sjon-lsp :version 1 :bundles [" ++
            "  (bundle :name a :files [" ++
            "    \"\" \"file?.sjon\" \"{{a,b}}.sjon\" \"a[bc].sjon\"" ++
            "    \"a**/b.sjon\" \"a/***.sjon\" \"**a/b.sjon\" \"{s}\"]" ++
            "   :manifests [\"m.sjon\"])" ++
            "])",
        .{over},
        0,
    );
    defer testing.allocator.free(src);

    var config = try parseConfig(src);
    defer config.deinit();
    try expectCodes(&config, &.{
        codes.config_pattern,
        codes.config_pattern,
        codes.config_pattern,
        codes.config_pattern,
        codes.config_pattern,
        codes.config_pattern,
        codes.config_pattern,
        codes.config_pattern,
    });

    const needles = [_][]const u8{
        "\"\"",
        "\"file?.sjon\"",
        "\"{a,b}.sjon\"",
        "\"a[bc].sjon\"",
        "\"a**/b.sjon\"",
        "\"a/***.sjon\"",
        "\"**a/b.sjon\"",
        long_quoted,
    };
    for (needles, config.diagnostics) |needle, diag| {
        try testing.expectEqual(findSpan(src, needle, 0), diag.span);
    }
}

test "editor config: rejects absolute and parent-traversing file patterns" {
    const src: [:0]const u8 =
        "(sjon-lsp :version 1 :bundles [" ++
        "  (bundle :name a :files [\"/abs.sjon\" \"../x.sjon\" \"a/../b.sjon\" \"..\"]" ++
        "   :manifests [\"m.sjon\"])" ++
        "])";
    var config = try parseConfig(src);
    defer config.deinit();

    try expectCodes(&config, &.{
        codes.config_pattern,
        codes.config_pattern,
        codes.config_pattern,
        codes.config_pattern,
    });
    const needles = [_][]const u8{
        "\"/abs.sjon\"",
        "\"../x.sjon\"",
        "\"a/../b.sjon\"",
        "\"..\"",
    };
    for (needles, config.diagnostics) |needle, diag| {
        try testing.expectEqual(findSpan(src, needle, 0), diag.span);
    }
}

test "editor config: recursive star segment matches a root file" {
    const src: [:0]const u8 =
        "(sjon-lsp :version 1 :bundles [" ++
        "  (bundle :name a :files [\"**/program.sjon\"] :manifests [\"m.sjon\"])" ++
        "])";
    var config = try parseConfig(src);
    defer config.deinit();

    const root_file = config.matchBundles("program.sjon");
    try testing.expectEqual(@as(usize, 1), root_file.count);
    try testing.expectEqual(@as(?usize, 0), root_file.first);
    try testing.expectEqual(@as(?usize, null), root_file.second);
    try testing.expectEqual(@as(usize, 1), config.matchBundles("nested/program.sjon").count);
    try testing.expectEqual(@as(usize, 0), config.matchBundles("program.txt").count);
}

test "editor config: single star never crosses a path separator" {
    const src: [:0]const u8 =
        "(sjon-lsp :version 1 :bundles [" ++
        "  (bundle :name a :files [\"*.sjon\" \"docs/*.sjon\"] :manifests [\"m.sjon\"])" ++
        "])";
    var config = try parseConfig(src);
    defer config.deinit();

    try testing.expectEqual(@as(usize, 1), config.matchBundles("a.sjon").count);
    try testing.expectEqual(@as(usize, 0), config.matchBundles("nested/a.sjon").count);
    try testing.expectEqual(@as(usize, 1), config.matchBundles("docs/a.sjon").count);
    try testing.expectEqual(@as(usize, 0), config.matchBundles("docs/a/b.sjon").count);
}

test "editor config: multiple patterns in one bundle are harmless" {
    const src: [:0]const u8 =
        "(sjon-lsp :version 1 :bundles [" ++
        "  (bundle :name a :files [\"*.sjon\" \"**/both.sjon\"] :manifests [\"m.sjon\"])" ++
        "  (bundle :name b :files [\"other/*.sjon\"] :manifests [\"m2.sjon\"])" ++
        "])";
    var config = try parseConfig(src);
    defer config.deinit();

    // Two patterns in one bundle still name one bundle: no conflict.
    const both = config.matchBundles("both.sjon");
    try testing.expectEqual(@as(usize, 1), both.count);
    try testing.expectEqual(@as(?usize, 0), both.first);
    try testing.expectEqual(@as(?usize, null), both.second);

    // Matching is not first-bundle-wins: a later bundle is found.
    const other = config.matchBundles("other/x.sjon");
    try testing.expectEqual(@as(usize, 1), other.count);
    try testing.expectEqual(@as(?usize, 1), other.first);
}

test "editor config: matching is case-sensitive and Unicode-preserving" {
    const src: [:0]const u8 =
        "(sjon-lsp :version 1 :bundles [" ++
        "  (bundle :name a :files [\"**/Mötley.sjon\"] :manifests [\"m.sjon\"])" ++
        "])";
    var config = try parseConfig(src);
    defer config.deinit();

    try testing.expectEqual(@as(usize, 1), config.matchBundles("Mötley.sjon").count);
    try testing.expectEqual(@as(usize, 1), config.matchBundles("nested/Mötley.sjon").count);
    try testing.expectEqual(@as(usize, 0), config.matchBundles("mötley.sjon").count);
    try testing.expectEqual(@as(usize, 0), config.matchBundles("MÖTLEY.sjon").count);
    // No Unicode normalization: the decomposed spelling is a different path.
    try testing.expectEqual(@as(usize, 0), config.matchBundles("Mo\u{308}tley.sjon").count);
}

test "editor config: parse diagnostics are retained without typed-tree cascades" {
    const src: [:0]const u8 =
        "(sjon-lsp :version 1 :bundles [" ++
        "  (bundle :name a :files [\"x.sjon\"] :manifests [\"m.sjon\"])";
    var config = try parseConfig(src);
    defer config.deinit();

    try testing.expect(config.hasErrors());
    try testing.expect(config.parse_diagnostics.len > 0);
    for (config.parse_diagnostics) |diag| {
        try testing.expectEqual(sjon.Ast.Diagnostic.Severity.err, diag.severity);
    }
    // No recovered-tree typed walk: no configuration diagnostics, no bundles.
    try testing.expectEqual(@as(usize, 0), config.diagnostics.len);
    try testing.expectEqual(@as(usize, 0), config.bundles.len);
}
