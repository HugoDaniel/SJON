//! Per-document editor association discovery.
//!
//! Given the initialization roots and a document URI, this module answers one
//! question: which editor configuration (if any) owns this document, and which
//! bundle (if any) matches it? It performs no handler construction, no bundle
//! compilation, and no workspace scan — those are later tasks that consume the
//! values produced here.
//!
//! Discovery is lexical, never physical:
//!
//!   * URIs are percent-decoded with `uri.fileUriToPath` and normalized with
//!     `std.fs.path.resolve`; symlinks are not resolved, so `/var` and
//!     `/private/var` remain distinct paths (the plan deliberately does not
//!     merge aliases).
//!   * Exactly one initialization root contains a document: the
//!     segment-aware, longest containing workspace folder, preserving
//!     initialization order for an exact tie. Without workspace folders the
//!     deprecated `rootUri` is used, then legacy `rootPath`.
//!   * The walk starts at the document's directory and never goes above the
//!     containing root. The first directory holding either marker stops the
//!     search; markers above that directory are never consulted. Without a
//!     containing root only the document's own directory is inspected.
//!   * A directory with both markers is decided by the editor configuration:
//!     a matching bundle wins without loading the project; no match falls back
//!     to that directory's `sjon-project.sjon`. An invalid editor
//!     configuration is an error boundary and never falls through to a parent
//!     or to the project.
//!
//! Four outcomes leave this module:
//!
//!   * `ready` — exactly one bundle matched; `config` and
//!     `matching_bundles[0]` are present.
//!   * `unconfigured` — no editor bundle applies; an optional
//!     `project_path` names the same-directory legacy project.
//!   * `conflict` — more than one bundle matched; every matching index is
//!     retained, never just the first.
//!   * `config_failure` — the selected `sjon-lsp.sjon` is unreadable or
//!     invalid; the owned `config` retains its diagnostics and no project
//!     substitution occurs.
//!
//! Ownership: `Roots` and `Selection` own one arena each. `Selection.config`
//! owns a second arena through `editor_config.Config`; `Selection.deinit`
//! releases the configuration first, then its own arena.

const std = @import("std");
const uri = @import("uri");
const editor_config = @import("editor_config");

const Allocator = std.mem.Allocator;

/// Marker filenames. These are editor-local conventions, not user data; later
/// tasks must exclude them from ordinary project/document scans.
pub const markers = struct {
    pub const config: []const u8 = "sjon-lsp.sjon";
    pub const project: []const u8 = "sjon-project.sjon";
};

/// One initialization root, already percent-decoded and lexically normalized.
pub const Root = struct {
    /// Absolute filesystem path (no trailing separator except `/` itself).
    path: []const u8,
    /// `file://` spelling of `path`, owned by the same arena.
    uri: []const u8,
};

/// The initialization roots a server keeps for its whole lifetime.
pub const Roots = struct {
    arena: std.heap.ArenaAllocator,
    items: []const Root,

    pub fn deinit(self: *Roots) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const State = enum {
    /// One bundle matched; use the owned configuration and bundle index.
    ready,
    /// No editor bundle applies. `project_path` may name a legacy project.
    unconfigured,
    /// More than one bundle matched; this is an unavailable association.
    conflict,
    /// The selected editor configuration is unreadable or invalid; this is an
    /// unavailable association and must never fall back to a project or parent.
    config_failure,
};

/// One owned discovery result. Every slice except a borrowed `Config`'s
/// internals is arena-owned by this value.
pub const Selection = struct {
    arena: std.heap.ArenaAllocator,
    state: State,
    /// Decoded, lexically normalized document path. Null for a non-file URI.
    document_path: ?[]const u8 = null,
    /// The containing initialization root, copied into this arena.
    root: ?Root = null,
    /// The directory where the nearest marker stopped the walk, or null when
    /// no marker was found (including non-file documents).
    marker_dir: ?[]const u8 = null,
    /// Owned editor configuration for `ready`, `conflict`, and
    /// `config_failure`; null for `unconfigured`.
    config: ?editor_config.Config = null,
    /// Same-directory `sjon-project.sjon` for an `unconfigured` legacy
    /// association; null when the document uses core/in-memory behavior.
    project_path: ?[]const u8 = null,
    /// Every bundle index whose patterns match, in configuration order.
    /// `ready` has exactly one entry; `conflict` has at least two.
    matching_bundles: []const usize = &.{},

    pub fn deinit(self: *Selection) void {
        if (self.config) |*config| config.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Build the initialization roots from `InitializeParams`-shaped inputs.
///
/// `workspace_folder_uris` are kept in initialization order; non-file URIs are
/// skipped. When no workspace folder yields a file path, `root_uri` (the
/// deprecated field) is decoded, then `root_path` (a plain filesystem path) is
/// used. The result owns decoded paths and their `file://` spellings.
pub fn initializationRoots(
    gpa: Allocator,
    workspace_folder_uris: []const []const u8,
    root_uri: ?[]const u8,
    root_path: ?[]const u8,
) Allocator.Error!Roots {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var items: std.ArrayList(Root) = .empty;

    for (workspace_folder_uris) |folder_uri| {
        const decoded = (try uri.fileUriToPath(a, folder_uri)) orelse continue;
        try appendRoot(a, &items, decoded);
    }

    if (items.items.len == 0) {
        if (root_uri) |root_uri_text| {
            if (try uri.fileUriToPath(a, root_uri_text)) |decoded| {
                try appendRoot(a, &items, decoded);
            }
        }
    }

    if (items.items.len == 0) {
        if (root_path) |path| {
            if (path.len != 0) try appendRoot(a, &items, path);
        }
    }

    return .{ .arena = arena, .items = try items.toOwnedSlice(a) };
}

/// Discover the association for `document_uri` against `roots`.
///
/// Non-file URIs return `unconfigured` with null path/root and touch no
/// filesystem. File URIs are decoded and normalized lexically; the nearest
/// marker at or below the containing root decides the outcome.
pub fn discover(
    gpa: Allocator,
    io: std.Io,
    roots: []const Root,
    document_uri: []const u8,
) Allocator.Error!Selection {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const decoded = (try uri.fileUriToPath(a, document_uri)) orelse {
        // Non-file URI: no discovery, no filesystem access, no context.
        return .{ .arena = arena, .state = .unconfigured };
    };
    const document_path = try std.fs.path.resolve(a, &.{decoded});

    const containing = mostSpecificRoot(roots, document_path);
    const root_copy: ?Root = if (containing) |root| .{
        .path = try a.dupe(u8, root.path),
        .uri = try a.dupe(u8, root.uri),
    } else null;

    var marker_dir: ?[]const u8 = null;
    var has_config = false;
    var has_project = false;

    var current: []const u8 = std.fs.path.dirname(document_path) orelse document_path;
    while (true) {
        has_config = pathExists(io, try std.fs.path.join(a, &.{ current, markers.config }));
        has_project = pathExists(io, try std.fs.path.join(a, &.{ current, markers.project }));
        if (has_config or has_project) {
            marker_dir = try a.dupe(u8, current);
            break;
        }

        // Without a containing root only the document's own directory is
        // inspected. With one, the boundary directory itself is inspected
        // before stopping; markers above it are never consulted.
        const boundary: ?[]const u8 = if (root_copy) |root| root.path else null;
        if (boundary == null) break;
        if (std.mem.eql(u8, current, boundary.?)) break;
        const parent = std.fs.path.dirname(current) orelse break;
        if (!containsPath(boundary.?, parent)) break;
        current = parent;
    }

    const found_dir = marker_dir orelse {
        return .{
            .arena = arena,
            .state = .unconfigured,
            .document_path = document_path,
            .root = root_copy,
        };
    };

    // Only a legacy marker: use that project, with no upward search.
    if (!has_config) {
        return .{
            .arena = arena,
            .state = .unconfigured,
            .document_path = document_path,
            .root = root_copy,
            .marker_dir = found_dir,
            .project_path = try std.fs.path.join(a, &.{ found_dir, markers.project }),
        };
    }

    const config_path = try std.fs.path.join(a, &.{ found_dir, markers.config });
    const project_path: ?[]const u8 = if (has_project)
        try std.fs.path.join(a, &.{ found_dir, markers.project })
    else
        null;
    const relative = try documentRelativePath(a, found_dir, document_path);

    var config = try editor_config.load(gpa, io, config_path);
    errdefer config.deinit();

    if (config.hasErrors()) {
        // An invalid or unreadable editor configuration is an error boundary:
        // retain it for its diagnostics and never substitute the project or a
        // parent configuration.
        return .{
            .arena = arena,
            .state = .config_failure,
            .document_path = document_path,
            .root = root_copy,
            .marker_dir = found_dir,
            .config = config,
        };
    }

    var matching: std.ArrayList(usize) = .empty;
    for (config.bundles, 0..) |bundle, index| {
        if (bundle.matchesPath(relative)) try matching.append(a, index);
    }
    const matching_slice = try matching.toOwnedSlice(a);

    if (matching_slice.len == 0) {
        // No bundle in the nearest configuration matches. With both markers,
        // this directory's project is the legacy fallback and the named
        // resolver index for declarations; with only the editor config, the
        // document is plain core/in-memory behavior. Never search a parent.
        config.deinit();
        return .{
            .arena = arena,
            .state = .unconfigured,
            .document_path = document_path,
            .root = root_copy,
            .marker_dir = found_dir,
            .project_path = project_path,
        };
    }

    if (matching_slice.len > 1) {
        return .{
            .arena = arena,
            .state = .conflict,
            .document_path = document_path,
            .root = root_copy,
            .marker_dir = found_dir,
            .config = config,
            .matching_bundles = matching_slice,
        };
    }

    return .{
        .arena = arena,
        .state = .ready,
        .document_path = document_path,
        .root = root_copy,
        .marker_dir = found_dir,
        .config = config,
        .matching_bundles = matching_slice,
    };
}

fn appendRoot(a: Allocator, items: *std.ArrayList(Root), raw: []const u8) Allocator.Error!void {
    const path = try std.fs.path.resolve(a, &.{raw});
    try items.append(a, .{
        .path = path,
        .uri = try uri.pathToFileUri(a, path),
    });
}

/// Longest segment-aware containing root; an exact tie keeps the first one,
/// preserving initialization order.
fn mostSpecificRoot(roots: []const Root, document_path: []const u8) ?Root {
    var best: ?Root = null;
    for (roots) |root| {
        if (!containsPath(root.path, document_path)) continue;
        if (best) |current| {
            if (root.path.len <= current.path.len) continue;
        }
        best = root;
    }
    return best;
}

/// Lexical, segment-aware containment. `/a/b` contains `/a/b/c` but not
/// `/a/bc`; the root `/` contains every absolute path. No symlink resolution
/// and no case folding occur.
fn containsPath(root: []const u8, path: []const u8) bool {
    if (path.len < root.len) return false;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    if (root.len != 0 and root[root.len - 1] == std.fs.path.sep) return true;
    return path[root.len] == std.fs.path.sep;
}

fn pathExists(io: std.Io, absolute_path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, absolute_path, .{}) catch return false;
    return true;
}

/// The document path relative to the marker directory, `/`-normalized, as the
/// strict bundle patterns expect.
fn documentRelativePath(
    a: Allocator,
    marker_dir: []const u8,
    document_path: []const u8,
) Allocator.Error![]const u8 {
    std.debug.assert(std.mem.startsWith(u8, document_path, marker_dir));
    var relative = document_path[marker_dir.len..];
    while (relative.len != 0 and relative[0] == std.fs.path.sep) {
        relative = relative[1..];
    }
    const out = try a.dupe(u8, relative);
    if (std.fs.path.sep != '/') {
        for (out) |*byte| {
            if (byte.* == std.fs.path.sep) byte.* = '/';
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests — write first, then implement against them.
// ---------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    /// Absolute, lexically normalized temporary directory.
    dir: []const u8,

    fn init() !Fixture {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const tmp = testing.tmpDir(.{});
        const sub: []const u8 = &tmp.sub_path;
        // `std.fs.path.resolve` is purely lexical in this Zig version and
        // leaves a relative path relative. A real editor's workspace folder
        // URI decodes to an absolute path, so resolve the fixture base
        // physically (test setup only) and keep discovery itself lexical.
        const relative = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", sub });
        const dir = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, a);
        return .{ .tmp = tmp, .arena = arena, .dir = dir };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.arena.deinit();
        self.* = undefined;
    }

    fn write(self: *Fixture, sub_path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub_path)) |parent| {
            try self.tmp.dir.createDirPath(testing.io, parent);
        }
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn path(self: *Fixture, relative: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.dir, relative });
    }

    fn fileUri(self: *Fixture, relative: []const u8) ![]const u8 {
        return uri.pathToFileUri(self.arena.allocator(), try self.path(relative));
    }

    fn rootUri(self: *Fixture) ![]const u8 {
        return uri.pathToFileUri(self.arena.allocator(), self.dir);
    }
};

fn discoverDocument(roots: []const Root, document_uri: []const u8) !Selection {
    return discover(testing.allocator, testing.io, roots, document_uri);
}

fn validConfig(pattern: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(
        testing.allocator,
        "(sjon-lsp :version 1 :bundles [(bundle :name b :files [\"{s}\"] :manifests [\"manifest.sjon\"])])",
        .{pattern},
        0,
    );
}

fn configWithTwoBundles() [:0]const u8 {
    return "(sjon-lsp :version 1 :bundles [" ++
        "  (bundle :name first :files [\"**/*.sjon\"] :manifests [\"a.sjon\"])" ++
        "  (bundle :name second :files [\"*.sjon\"] :manifests [\"b.sjon\"])" ++
        "])";
}

test "discovery: nearest marker stops the upward search" {
    var f = try Fixture.init();
    defer f.deinit();

    const root_config = try validConfig("**/*.sjon");
    defer testing.allocator.free(root_config);
    try f.write("sjon-lsp.sjon", root_config);

    const nested_config = try validConfig("**/*.sjon");
    defer testing.allocator.free(nested_config);
    try f.write("nested/sjon-lsp.sjon", nested_config);

    var roots = try initializationRoots(testing.allocator, &.{try f.rootUri()}, null, null);
    defer roots.deinit();

    var selection = try discoverDocument(roots.items, try f.fileUri("nested/deep/doc.sjon"));
    defer selection.deinit();

    try testing.expectEqual(State.ready, selection.state);
    try testing.expect(selection.config != null);
    try testing.expect(std.mem.endsWith(u8, selection.config.?.path, "/nested/sjon-lsp.sjon"));
    try testing.expect(std.mem.endsWith(u8, selection.marker_dir.?, "/nested"));
    try testing.expectEqual(@as(usize, 1), selection.matching_bundles.len);
    try testing.expectEqual(@as(usize, 0), selection.matching_bundles[0]);
}

test "discovery: no marker at the workspace boundary is unconfigured" {
    var f = try Fixture.init();
    defer f.deinit();

    var roots = try initializationRoots(testing.allocator, &.{try f.rootUri()}, null, null);
    defer roots.deinit();

    var selection = try discoverDocument(roots.items, try f.fileUri("nested/deep/doc.sjon"));
    defer selection.deinit();

    try testing.expectEqual(State.unconfigured, selection.state);
    try testing.expect(selection.config == null);
    try testing.expect(selection.project_path == null);
    try testing.expect(selection.marker_dir == null);
    try testing.expect(selection.root != null);
    try testing.expectEqualStrings(f.dir, selection.root.?.path);
}

test "discovery: without a containing root only the document directory is inspected" {
    var f = try Fixture.init();
    defer f.deinit();

    const config = try validConfig("**/*.sjon");
    defer testing.allocator.free(config);
    try f.write("outside/sjon-lsp.sjon", config);

    // A workspace root in a sibling tree does not contain the document, so
    // the walk has no boundary except the document's own directory.
    var roots = try initializationRoots(testing.allocator, &.{try f.fileUri("workspace")}, null, null);
    defer roots.deinit();

    // The document's parent holds a valid configuration, but without a
    // containing root only the document's own directory may be inspected.
    var ignored = try discoverDocument(roots.items, try f.fileUri("outside/deep/doc.sjon"));
    defer ignored.deinit();
    try testing.expectEqual(State.unconfigured, ignored.state);
    try testing.expect(ignored.config == null);
    try testing.expect(ignored.marker_dir == null);

    // Its own directory is inspected.
    try f.write("outside/deep/sjon-lsp.sjon", config);
    var selection = try discoverDocument(roots.items, try f.fileUri("outside/deep/doc.sjon"));
    defer selection.deinit();
    try testing.expectEqual(State.ready, selection.state);
    try testing.expect(std.mem.endsWith(u8, selection.marker_dir.?, "/outside/deep"));
}

test "discovery: most specific containing workspace folder wins" {
    var f = try Fixture.init();
    defer f.deinit();

    const config = try validConfig("**/*.sjon");
    defer testing.allocator.free(config);
    // The outer configuration would match `inner/doc.sjon` if discovery used
    // the outer root, so an unconfigured result proves the inner boundary.
    try f.write("sjon-lsp.sjon", config);
    try f.tmp.dir.createDirPath(testing.io, "inner");

    var roots = try initializationRoots(
        testing.allocator,
        &.{ try f.rootUri(), try f.fileUri("inner") },
        null,
        null,
    );
    defer roots.deinit();

    var selection = try discoverDocument(roots.items, try f.fileUri("inner/doc.sjon"));
    defer selection.deinit();

    try testing.expectEqual(State.unconfigured, selection.state);
    try testing.expect(selection.config == null);
    try testing.expect(selection.root != null);
    try testing.expect(std.mem.endsWith(u8, selection.root.?.path, "/inner"));
}

test "discovery: legacy rootUri and rootPath remain fallbacks" {
    var f = try Fixture.init();
    defer f.deinit();

    var from_uri = try initializationRoots(
        testing.allocator,
        &.{},
        try f.fileUri("from-uri"),
        try f.path("from-path"),
    );
    defer from_uri.deinit();
    try testing.expectEqual(@as(usize, 1), from_uri.items.len);
    try testing.expect(std.mem.endsWith(u8, from_uri.items[0].path, "/from-uri"));

    var from_path = try initializationRoots(
        testing.allocator,
        &.{},
        null,
        try f.path("from-path"),
    );
    defer from_path.deinit();
    try testing.expectEqual(@as(usize, 1), from_path.items.len);
    try testing.expect(std.mem.endsWith(u8, from_path.items[0].path, "/from-path"));

    // A workspace folder wins over both legacy fields, and a non-file folder
    // URI is skipped rather than turned into a filesystem path.
    var folders = try initializationRoots(
        testing.allocator,
        &.{ "https://example.com/not-a-file", try f.fileUri("folder") },
        try f.fileUri("from-uri"),
        try f.path("from-path"),
    );
    defer folders.deinit();
    try testing.expectEqual(@as(usize, 1), folders.items.len);
    try testing.expect(std.mem.endsWith(u8, folders.items[0].path, "/folder"));
}

test "discovery: both markers use a matching bundle without loading the project" {
    var f = try Fixture.init();
    defer f.deinit();

    const config = try validConfig("**/*.sjon");
    defer testing.allocator.free(config);
    try f.write("sjon-lsp.sjon", config);
    // Invalid project source: loading it would fail. A matching bundle must
    // be selected without opening this file at all.
    try f.write("sjon-project.sjon", "(project :plugins [");

    var roots = try initializationRoots(testing.allocator, &.{try f.rootUri()}, null, null);
    defer roots.deinit();

    var selection = try discoverDocument(roots.items, try f.fileUri("doc.sjon"));
    defer selection.deinit();

    try testing.expectEqual(State.ready, selection.state);
    try testing.expect(selection.config != null);
    try testing.expect(selection.project_path == null);
    try testing.expectEqual(@as(usize, 1), selection.matching_bundles.len);
}

test "discovery: both markers use the same-directory project only when no bundle matches" {
    var f = try Fixture.init();
    defer f.deinit();

    const config = try validConfig("other/*.sjon");
    defer testing.allocator.free(config);
    try f.write("sjon-lsp.sjon", config);
    try f.write("sjon-project.sjon", "(project :plugins [])");

    var roots = try initializationRoots(testing.allocator, &.{try f.rootUri()}, null, null);
    defer roots.deinit();

    var selection = try discoverDocument(roots.items, try f.fileUri("doc.sjon"));
    defer selection.deinit();

    try testing.expectEqual(State.unconfigured, selection.state);
    try testing.expect(selection.config == null);
    try testing.expect(selection.project_path != null);
    try testing.expect(std.mem.endsWith(u8, selection.project_path.?, "/sjon-project.sjon"));
    try testing.expectEqualStrings(f.dir, selection.marker_dir.?);
}

test "discovery: malformed nearer config is an error boundary" {
    var f = try Fixture.init();
    defer f.deinit();

    const root_config = try validConfig("**/*.sjon");
    defer testing.allocator.free(root_config);
    try f.write("sjon-lsp.sjon", root_config);

    // Malformed editor configuration in the nearer directory; its sibling
    // project must not be substituted, and the parent bundle must not win.
    try f.write("nested/sjon-lsp.sjon", "(sjon-lsp :version 1 :bundles [");
    try f.write("nested/sjon-project.sjon", "(project :plugins [])");

    var roots = try initializationRoots(testing.allocator, &.{try f.rootUri()}, null, null);
    defer roots.deinit();

    var selection = try discoverDocument(roots.items, try f.fileUri("nested/doc.sjon"));
    defer selection.deinit();

    try testing.expectEqual(State.config_failure, selection.state);
    try testing.expect(selection.project_path == null);
    try testing.expect(selection.config != null);
    const config = &selection.config.?;
    try testing.expect(config.hasErrors());
    try testing.expect(std.mem.endsWith(u8, config.path, "/nested/sjon-lsp.sjon"));
    try testing.expect(std.mem.endsWith(u8, selection.marker_dir.?, "/nested"));
}

test "discovery: multiple matching bundles conflict instead of first-match" {
    var f = try Fixture.init();
    defer f.deinit();

    try f.write("sjon-lsp.sjon", configWithTwoBundles());

    var roots = try initializationRoots(testing.allocator, &.{try f.rootUri()}, null, null);
    defer roots.deinit();

    var selection = try discoverDocument(roots.items, try f.fileUri("doc.sjon"));
    defer selection.deinit();

    try testing.expectEqual(State.conflict, selection.state);
    try testing.expect(selection.config != null);
    try testing.expectEqual(@as(usize, 2), selection.matching_bundles.len);
    try testing.expectEqual(@as(usize, 0), selection.matching_bundles[0]);
    try testing.expectEqual(@as(usize, 1), selection.matching_bundles[1]);
    try testing.expectEqualStrings("first", selection.config.?.bundles[0].name);
    try testing.expectEqualStrings("second", selection.config.?.bundles[1].name);
}

test "discovery: nested legacy project remains authoritative" {
    var f = try Fixture.init();
    defer f.deinit();

    const config = try validConfig("**/*.sjon");
    defer testing.allocator.free(config);
    try f.write("sjon-lsp.sjon", config);
    try f.write("nested/sjon-project.sjon", "(project :plugins [])");

    var roots = try initializationRoots(testing.allocator, &.{try f.rootUri()}, null, null);
    defer roots.deinit();

    var selection = try discoverDocument(roots.items, try f.fileUri("nested/deep/doc.sjon"));
    defer selection.deinit();

    try testing.expectEqual(State.unconfigured, selection.state);
    try testing.expect(selection.config == null);
    try testing.expect(selection.project_path != null);
    try testing.expect(std.mem.endsWith(u8, selection.project_path.?, "/nested/sjon-project.sjon"));
    try testing.expect(std.mem.endsWith(u8, selection.marker_dir.?, "/nested"));
}

test "discovery: spaces Unicode and percent-encoded URIs select the same config" {
    var f = try Fixture.init();
    defer f.deinit();

    const config = try validConfig("**/*.sjon");
    defer testing.allocator.free(config);
    try f.write("w\u{00f6}rk space/sjon-lsp.sjon", config);

    var roots = try initializationRoots(testing.allocator, &.{try f.rootUri()}, null, null);
    defer roots.deinit();

    var encoded = try discoverDocument(roots.items, try f.fileUri("w\u{00f6}rk space/doc.sjon"));
    defer encoded.deinit();
    try testing.expectEqual(State.ready, encoded.state);
    try testing.expect(std.mem.endsWith(u8, encoded.marker_dir.?, "/w\u{00f6}rk space"));

    const literal_uri = try std.fmt.allocPrint(
        f.arena.allocator(),
        "file://{s}/w\u{00f6}rk space/doc.sjon",
        .{f.dir},
    );
    var literal = try discoverDocument(roots.items, literal_uri);
    defer literal.deinit();
    try testing.expectEqual(State.ready, literal.state);
    try testing.expectEqualStrings(encoded.config.?.path, literal.config.?.path);
    try testing.expectEqualStrings(encoded.marker_dir.?, literal.marker_dir.?);
}

test "discovery: nonexistent new file uses its logical parent directories" {
    var f = try Fixture.init();
    defer f.deinit();

    const config = try validConfig("**/*.sjon");
    defer testing.allocator.free(config);
    try f.write("sjon-lsp.sjon", config);

    var roots = try initializationRoots(testing.allocator, &.{try f.rootUri()}, null, null);
    defer roots.deinit();

    // Neither `new` nor `new/deep` exists on disk; the URI still walks the
    // logical ancestors up to the workspace boundary.
    var selection = try discoverDocument(roots.items, try f.fileUri("new/deep/doc.sjon"));
    defer selection.deinit();

    try testing.expectEqual(State.ready, selection.state);
    try testing.expect(std.mem.endsWith(u8, selection.document_path.?, "/new/deep/doc.sjon"));
    try testing.expectEqualStrings(f.dir, selection.marker_dir.?);
}

test "discovery: var and private-var aliases are not merged" {
    var f = try Fixture.init();
    defer f.deinit();

    const config = try validConfig("**/*.sjon");
    defer testing.allocator.free(config);
    try f.write("var/ws/sjon-lsp.sjon", config);
    try f.tmp.dir.createDirPath(testing.io, "var/ws/nested");
    try f.tmp.dir.createDirPath(testing.io, "private");
    // `/private/var` is the classic filesystem alias of `/var` (macOS). This
    // symlink makes realpath-based containment observable: the document under
    // the alias physically lives inside the `/var/ws` root, but discovery must
    // compare the lexical spellings and keep them distinct.
    try f.tmp.dir.symLink(testing.io, try f.path("var"), "private/var", .{});

    const alias_doc_uri = try std.fmt.allocPrint(
        f.arena.allocator(),
        "file://{s}/private/var/ws/nested/doc.sjon",
        .{f.dir},
    );

    // A root spelled through the real path does not contain a document spelled
    // through the alias; only the document's own (alias) directory is checked.
    var real_roots = try initializationRoots(
        testing.allocator,
        &.{try f.fileUri("var/ws")},
        null,
        null,
    );
    defer real_roots.deinit();
    var unmerged = try discoverDocument(real_roots.items, alias_doc_uri);
    defer unmerged.deinit();
    try testing.expectEqual(State.unconfigured, unmerged.state);
    try testing.expect(unmerged.config == null);
    try testing.expect(unmerged.marker_dir == null);

    // The same tree through the alias root is contained lexically and finds
    // the same marker: the paths were never merged, only compared as spelled.
    var alias_roots = try initializationRoots(
        testing.allocator,
        &.{try f.fileUri("private/var/ws")},
        null,
        null,
    );
    defer alias_roots.deinit();
    var aliased = try discoverDocument(alias_roots.items, alias_doc_uri);
    defer aliased.deinit();
    try testing.expectEqual(State.ready, aliased.state);
    try testing.expect(std.mem.endsWith(u8, aliased.marker_dir.?, "/private/var/ws"));
}

test "discovery: non-file URI never touches the filesystem" {
    var f = try Fixture.init();
    defer f.deinit();

    const config = try validConfig("**/*.sjon");
    defer testing.allocator.free(config);
    try f.write("sjon-lsp.sjon", config);

    var roots = try initializationRoots(testing.allocator, &.{try f.rootUri()}, null, null);
    defer roots.deinit();

    var in_memory = try discoverDocument(roots.items, "inmemory://schema/0.sjon");
    defer in_memory.deinit();
    try testing.expectEqual(State.unconfigured, in_memory.state);
    try testing.expect(in_memory.document_path == null);
    try testing.expect(in_memory.root == null);
    try testing.expect(in_memory.marker_dir == null);
    try testing.expect(in_memory.config == null);
    try testing.expect(in_memory.project_path == null);

    var remote = try discoverDocument(roots.items, "https://example.com/doc.sjon");
    defer remote.deinit();
    try testing.expectEqual(State.unconfigured, remote.state);
    try testing.expect(remote.document_path == null);
    try testing.expect(remote.config == null);
}
