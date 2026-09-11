//! Default filesystem-backed `Resolver.Resolver` for D3.
//!
//! The file IS the struct — a `FilesystemResolver` value is just an
//! instance of this module's top-level fields. Built around a project
//! root directory containing a `sjon-project.sjon` file of the form:
//!
//!     (project :plugins ["./vendor/foo.sjon"
//!                        "./vendor/bar.sjon"])
//!
//! At `init` time the resolver loads each `:plugins` entry through
//! `ManifestLoader`, reads its `:name`, and indexes it. At `resolve` time
//! a `(use-plugin "name")` reference looks the name up; an explicit
//! `:path` short-circuits the index and reads the file directly.
//! Resolution order:
//!
//!   1. `ref.explicit_path` (resolved relative to `project_root`).
//!   2. Project-file index (`ref.name`).
//!   3. Failure → `Resolution.failure{ unresolved_plugin, … }`.
//!
//! `:version` and `:hash` pins from `(use-plugin …)` are accepted on
//! the reference but enforcement lives one level up in `Host.zig` —
//! that way every `Resolver` implementation (Zig filesystem, JS Node
//! `fs`, TS-parity, future fetch-based) gets the check for free after
//! the manifest bytes are loaded. See `loadResolvedManifest` in
//! `src/Host.zig` for the comparison and diagnostic emission.
//!
//! The *project file's* vocabulary is the opposite case, and the
//! distinction is load-bearing: this file's eight keys and the
//! project-pin-vs-document-pin cross-check that emits
//! `pin_disagreement` belong to THIS resolver, not to the language.
//! `Resolver.zig` says so outright — the filesystem resolver is one
//! implementation, not the only one, and a fetch-backed host has no
//! project file to have a vocabulary. `docs/LANGUAGE.md` never
//! specifies the format. So `unknown_project_key` and
//! `pin_disagreement` are corpus-exempt by decision rather than by
//! omission (`tools/corpus_exempt_diagnostic_codes.txt` carries the
//! reasoning); a host that never emits them is not falling behind.
//! Nothing about *enforcement* rides on this — the document's own
//! pins are checked one level up, for every resolver, as above.
//!
//! Project-load failures (project file missing/parse, malformed shape,
//! per-entry manifest read/parse failure, duplicate `:name`) become
//! `Ast.Diagnostic` entries on `project_diagnostics`. The host drains
//! them once via `takeProjectDiagnostics` after constructing the
//! resolver, so they land in `HostResult.diagnostics` with
//! `phase = .manifest`.
//!
//! User-root and `plugin_search_roots` lookups (steps 3-4 of the
//! `Resolver.zig` design docstring) are deliberately not implemented.

const std = @import("std");
const Ast = @import("Ast.zig");
const Resolver = @import("Resolver.zig");
const Parser = @import("Parser.zig");
const ManifestLoader = @import("ManifestLoader.zig");
const CappedRead = @import("CappedRead.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Self = @This();

pub const PROJECT_FILE_NAME = "sjon-project.sjon";

/// One indexed plugin: the absolute path it loaded from plus the
/// (sentinel-terminated) source bytes the host re-parses on each
/// `(use-plugin "name")` hit. Project-level pins from
/// `(plugin-entry :version/:hash …)` ride along so the resolver can
/// emit `pin_disagreement` against the matching `(use-plugin)` pins
/// at resolution time.
pub const IndexEntry = struct {
    manifest_path: []const u8,
    manifest_source: [:0]const u8,
    version_pin: ?[]const u8 = null,
    hash_pin: ?[]const u8 = null,
    /// Parsed from a `(plugin-entry … :optional <bool>)` project row but
    /// not yet consumed by resolution — a forward-compat seam for optional
    /// plugins (a missing one would resolve to a soft failure), sibling to
    /// the reserved `:as` key. Kept rather than deleted: it is live
    /// project-file syntax with a round-trip test.
    optional: bool = false,
};

/// Closed set of `:exports :layout` values. `per-plugin` writes one
/// file per plugin under the declared output dir; `single-file`
/// aggregates into one file per language.
pub const ExportLayout = enum { per_plugin, single_file };

/// Parsed `(exports …)` form from the project file.
pub const ExportSpec = struct {
    json_schema_dir: ?[]const u8 = null,
    typescript_dir: ?[]const u8 = null,
    layout: ExportLayout = .per_plugin,
};

gpa: Allocator,
io: Io,
arena: std.heap.ArenaAllocator,
/// Absolute path to the project root. May be cwd-relative if the
/// caller passed a relative root — we don't normalise.
project_root: []const u8,
/// Absolute path to the project file we loaded; null when no project
/// file was discovered (resolver still works for explicit `:path`
/// references in that case).
project_file_path: ?[]const u8,
/// Source bytes of the project file when one loaded successfully;
/// null when no project file was discovered or the read failed.
/// Owned by the arena; consumers may borrow for the resolver's
/// lifetime.
project_source: ?[:0]const u8,
/// Name → IndexEntry. Owned by the arena.
name_index: std.StringHashMapUnmanaged(IndexEntry),
/// Project-load diagnostics — emptied by the first
/// `takeProjectDiagnostics` call.
project_diagnostics: []Ast.Diagnostic,
/// Optional `:name` from the `(project …)` form. Defaults to the
/// project directory's basename if absent.
project_name: ?[]const u8 = null,
/// Optional `:version` from the `(project …)` form.
project_version: ?[]const u8 = null,
/// `:documents` glob patterns. Project-root-relative.
project_documents: []const []const u8 = &.{},
/// `:search-roots` plugin discovery directories.
project_search_roots: []const []const u8 = &.{},
/// `:ignore` glob patterns. Layered on top of the default set
/// (`.git/`, `node_modules/`, `.zig-cache/`, `zig-out/`).
project_ignore: []const []const u8 = &.{},
/// `:lockfile` path. Null when the project opts out (declared `false`
/// or unrecognized non-string).
project_lockfile_path: ?[]const u8 = null,
/// True when `:lockfile false` was declared explicitly. The CLI uses
/// this to suppress the "no lockfile present" advisory.
project_lockfile_disabled: bool = false,
/// `:exports` declaration when present.
project_exports: ?ExportSpec = null,

/// Construct a filesystem resolver rooted at `project_root`. When
/// `project_file_path` is non-null the resolver loads it through
/// `ManifestLoader` at init time, indexes every entry by `:name`, and
/// stashes any load failures on `project_diagnostics` (drained once via
/// `takeProjectDiagnostics`). When null, the resolver still works for
/// `(use-plugin … :path "…")` references but resolves no bare names.
///
/// This module's error surface, spelled per the repo convention.
///
/// Allocation only, matching `Resolver.Error`, and for the same reason:
/// a filesystem failure (missing manifest, unreadable path, hash
/// mismatch) becomes a `Resolution.failure` or a project diagnostic, not
/// a thrown error, so one broken plugin never fails the whole load.
pub const Error = Allocator.Error;

/// `gpa` backs the internal arena; `io` is borrowed for project-file
/// reads. The returned `Self` owns its arena — call `deinit` to release
/// the index, the duped paths, and the diagnostics buffer.
pub fn init(
    gpa: Allocator,
    io: Io,
    project_root: []const u8,
    project_file_path: ?[]const u8,
) Allocator.Error!Self {
    // The arena lives in `self` from the first allocation. An
    // `ArenaAllocator` is a value type: a local arena copied into `self`
    // after some allocations leaves the local's `errdefer` freeing only
    // the nodes the local saw, while everything `loadProjectFile`
    // allocated through `self.arena` was orphaned on an OOM.
    var self: Self = .{
        .gpa = gpa,
        .io = io,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .project_root = "",
        .project_file_path = null,
        .project_source = null,
        .name_index = .empty,
        .project_diagnostics = &.{},
        .project_documents = &.{},
        .project_search_roots = &.{},
        .project_ignore = &.{},
        .project_exports = null,
    };
    errdefer self.arena.deinit();
    const a = self.arena.allocator();

    self.project_root = try a.dupe(u8, project_root);
    self.project_file_path = if (project_file_path) |p| try a.dupe(u8, p) else null;

    var diags: std.ArrayList(Ast.Diagnostic) = .empty;
    if (self.project_file_path) |path| {
        try loadProjectFile(&self, &diags, path);
    }
    self.project_diagnostics = try diags.toOwnedSlice(a);

    return self;
}

/// Release the internal arena (frees the index, duped paths, project
/// source bytes, and diagnostics buffer). Resets `self.*` to
/// `undefined` to surface use-after-free as a typed crash.
pub fn deinit(self: *Self) void {
    self.arena.deinit();
    self.* = undefined;
}

/// Build a `Resolver.Resolver` vtable bound to this instance. The
/// returned vtable borrows `self` — keep `self` alive (and don't move
/// it) for the vtable's full lifetime. Cheap to call multiple times.
pub fn resolver(self: *Self) Resolver.Resolver {
    return .{ .ctx = self, .resolve = resolveCallback };
}

/// Drain the slice once. Subsequent calls return an empty slice so
/// callers can't accidentally double-report.
pub fn takeProjectDiagnostics(self: *Self) []Ast.Diagnostic {
    const out = self.project_diagnostics;
    self.project_diagnostics = &.{};
    return out;
}

/// Return the project file's source bytes (sentinel-terminated) when
/// a project file was successfully read at init time. Null when no
/// project file was supplied or the read failed. The returned slice
/// is borrowed from the resolver's arena.
pub fn getProjectSource(self: *const Self) ?[:0]const u8 {
    return self.project_source;
}

/// One entry yielded by `iterateProjectPlugins`. Borrows from the
/// resolver's arena — valid until `Self.deinit`.
pub const ProjectPluginEntry = struct {
    name: []const u8,
    manifest_path: []const u8,
    manifest_source: [:0]const u8,
};

/// Iterator over the project file's indexed plugins, in unspecified
/// order. Used by callers that want to eagerly load every plugin in a
/// workspace's `sjon-project.sjon` (e.g. `Host.loadProject` for LSP
/// schema construction) without going through the per-reference
/// `resolve` callback.
pub const ProjectPluginIterator = struct {
    inner: std.StringHashMapUnmanaged(IndexEntry).Iterator,

    pub fn next(self: *ProjectPluginIterator) ?ProjectPluginEntry {
        const kv = self.inner.next() orelse return null;
        return .{
            .name = kv.key_ptr.*,
            .manifest_path = kv.value_ptr.manifest_path,
            .manifest_source = kv.value_ptr.manifest_source,
        };
    }
};

pub fn iterateProjectPlugins(self: *const Self) ProjectPluginIterator {
    return .{ .inner = self.name_index.iterator() };
}

/// Wasm bytes paired with one project-indexed manifest, honoring its
/// `:wasm-file` override — the same resolution `resolveCallback` performs
/// per `(use-plugin …)` reference, reached from the other direction for
/// callers that walk `iterateProjectPlugins` instead (`Host.loadProject`,
/// so the LSP can register executable plugins once per project epoch).
/// Bytes live on `arena`, and `PluginRuntime.register` copies what it
/// keeps, so the caller may reset that arena per entry.
///
/// Null covers two outcomes deliberately: a declarative-only plugin (no
/// override, no paired file) and a resolution *failure* (unreadable
/// override, or one escaping the package dir). Eager project load has no
/// `(use-plugin …)` span to anchor a failure diagnostic on, and the
/// absence is not silent — a provider whose bytes never arrived reports
/// `unavailable` at every site that asked for it. The reference path
/// still reports the failure properly the moment a document names the
/// plugin.
pub fn resolveProjectPluginWasm(
    self: *const Self,
    arena: Allocator,
    entry: ProjectPluginEntry,
) Allocator.Error!?[]const u8 {
    const resolution = try resolveManifestWasm(
        self.gpa,
        self.io,
        arena,
        entry.manifest_path,
        entry.manifest_source,
    );
    return switch (resolution) {
        .manifest => |m| m.wasm,
        .failure => null,
    };
}

// ---------------------------------------------------------------------
// Project-file load.
// ---------------------------------------------------------------------

fn loadProjectFile(
    self: *Self,
    diags: *std.ArrayList(Ast.Diagnostic),
    project_path: []const u8,
) Allocator.Error!void {
    const a = self.arena.allocator();

    const project_source = CappedRead.readFileZ(
        self.io,
        project_path,
        a,
        CappedRead.MAX_FILE_SIZE,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try diags.append(a, .{
                .span = .{ .start = 0, .end = 0 },
                .code = .invalid_manifest,
                .message = try std.fmt.allocPrint(
                    a,
                    "could not read project file `{s}`: {s}",
                    .{ project_path, @errorName(err) },
                ),
                .path = try Ast.dupePath(a, &.{"project"}),
            });
            return;
        },
    };
    self.project_source = project_source;

    var tree = try Parser.parse(self.gpa, project_source);
    defer tree.deinit();

    for (tree.diagnostics) |d| try diags.append(a, try d.dupe(a));

    if (tree.root.len == 0) return;
    if (tree.root.len > 1) {
        try diags.append(a, .{
            .span = .{ .start = 0, .end = 0 },
            .code = .invalid_manifest,
            .message = try std.fmt.allocPrint(
                a,
                "expected a single (project …) form in {s}",
                .{PROJECT_FILE_NAME},
            ),
            .path = try Ast.dupePath(a, &.{"project"}),
        });
        return;
    }

    const root_idx = tree.root[0];
    if (tree.tagOf(root_idx) != .form) {
        // A bare value at the top level isn't a project declaration — fail
        // loudly rather than silently produce an empty index.
        try diags.append(a, .{
            .span = tree.spanOf(root_idx),
            .code = .invalid_manifest,
            .message = try std.fmt.allocPrint(
                a,
                "expected a (project …) form at top level of {s}",
                .{PROJECT_FILE_NAME},
            ),
            .path = try Ast.dupePath(a, &.{"project"}),
        });
        return;
    }
    const hdr = tree.formHeader(root_idx);
    if (hdr.namespace != null or !std.mem.eql(u8, hdr.head, "project")) {
        try diags.append(a, .{
            .span = hdr.head_span,
            .code = .invalid_manifest,
            .message = try std.fmt.allocPrint(
                a,
                "expected (project …) at top level of {s}, got `{s}`",
                .{ PROJECT_FILE_NAME, hdr.head },
            ),
            .path = try Ast.dupePath(a, &.{"project"}),
        });
        return;
    }

    try walkProjectForm(self, diags, tree, hdr);
}

fn walkProjectForm(
    self: *Self,
    diags: *std.ArrayList(Ast.Diagnostic),
    tree: Ast.Tree,
    hdr: Ast.FormHeader,
) Allocator.Error!void {
    const a = self.arena.allocator();
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);

        if (std.mem.eql(u8, kv.key, "plugins")) {
            try walkPluginsKey(self, diags, tree, kv.value);
        } else if (std.mem.eql(u8, kv.key, "name")) {
            if (tree.tagOf(kv.value) == .symbol) {
                self.project_name = try a.dupe(u8, tree.symbolText(kv.value));
            }
        } else if (std.mem.eql(u8, kv.key, "version")) {
            if (tree.tagOf(kv.value) == .string) {
                self.project_version = try a.dupe(u8, tree.stringText(kv.value));
            }
        } else if (std.mem.eql(u8, kv.key, "documents")) {
            self.project_documents = try parseStringVector(a, tree, kv.value);
        } else if (std.mem.eql(u8, kv.key, "search-roots")) {
            self.project_search_roots = try parseStringVector(a, tree, kv.value);
        } else if (std.mem.eql(u8, kv.key, "ignore")) {
            self.project_ignore = try parseStringVector(a, tree, kv.value);
        } else if (std.mem.eql(u8, kv.key, "lockfile")) {
            try walkLockfileKey(self, tree, kv.value);
        } else if (std.mem.eql(u8, kv.key, "exports")) {
            self.project_exports = try walkExportsForm(a, tree, kv.value);
        } else {
            // Forward-compat: unknown keys produce an advisory.
            try diags.append(a, .{
                .span = tree.spanOf(ci),
                .severity = .warning,
                .code = .unknown_project_key,
                .message = try std.fmt.allocPrint(
                    a,
                    "unknown project-file key `:{s}`",
                    .{kv.key},
                ),
                .path = try Ast.dupePath(a, &.{"project"}),
            });
        }
    }
}

fn walkPluginsKey(
    self: *Self,
    diags: *std.ArrayList(Ast.Diagnostic),
    tree: Ast.Tree,
    value: Ast.NodeIndex,
) Allocator.Error!void {
    const a = self.arena.allocator();
    if (tree.tagOf(value) != .vector) {
        try diags.append(a, .{
            .span = tree.spanOf(value),
            .code = .invalid_manifest,
            .message = try a.dupe(u8, "`:plugins` must be a vector"),
            .path = try Ast.dupePath(a, &.{"project"}),
        });
        return;
    }
    for (tree.vectorElements(value)) |elem| {
        try indexOneManifest(self, diags, tree, elem);
    }
}

fn walkLockfileKey(self: *Self, tree: Ast.Tree, value: Ast.NodeIndex) Allocator.Error!void {
    const a = self.arena.allocator();
    switch (tree.tagOf(value)) {
        .string => self.project_lockfile_path = try a.dupe(u8, tree.stringText(value)),
        .boolean_false => self.project_lockfile_disabled = true,
        .boolean_true => {
            // `:lockfile true` is meaningless — keep the default path.
        },
        else => {
            // Silently ignore — `unknown_project_key` was already
            // emitted above if applicable. Future revisions may emit
            // `wrong_underlying` here.
        },
    }
}

fn walkExportsForm(a: Allocator, tree: Ast.Tree, value: Ast.NodeIndex) Allocator.Error!?ExportSpec {
    if (tree.tagOf(value) != .form) return null;
    const sub = tree.formHeader(value);
    if (!std.mem.eql(u8, sub.head, "exports")) return null;
    var spec: ExportSpec = .{};
    for (sub.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kv.key, "json-schema") and tree.tagOf(kv.value) == .string) {
            spec.json_schema_dir = try a.dupe(u8, tree.stringText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "typescript") and tree.tagOf(kv.value) == .string) {
            spec.typescript_dir = try a.dupe(u8, tree.stringText(kv.value));
        } else if (std.mem.eql(u8, kv.key, "layout") and tree.tagOf(kv.value) == .symbol) {
            const sym = tree.symbolText(kv.value);
            if (std.mem.eql(u8, sym, "per-plugin")) {
                spec.layout = .per_plugin;
            } else if (std.mem.eql(u8, sym, "single-file")) {
                spec.layout = .single_file;
            }
        }
    }
    return spec;
}

fn parseStringVector(a: Allocator, tree: Ast.Tree, value: Ast.NodeIndex) Allocator.Error![]const []const u8 {
    if (tree.tagOf(value) != .vector) return &.{};
    const elements = tree.vectorElements(value);
    var out: std.ArrayList([]const u8) = .empty;
    for (elements) |ei| {
        if (tree.tagOf(ei) != .string) continue;
        try out.append(a, try a.dupe(u8, tree.stringText(ei)));
    }
    return try out.toOwnedSlice(a);
}

fn indexOneManifest(
    self: *Self,
    diags: *std.ArrayList(Ast.Diagnostic),
    tree: Ast.Tree,
    elem: Ast.NodeIndex,
) Allocator.Error!void {
    const a = self.arena.allocator();

    var rel_path: []const u8 = "";
    var version_pin: ?[]const u8 = null;
    var hash_pin: ?[]const u8 = null;
    var optional = false;
    const path_span = tree.spanOf(elem);

    switch (tree.tagOf(elem)) {
        .string => rel_path = tree.stringText(elem),
        .form => {
            const hdr = tree.formHeader(elem);
            if (!std.mem.eql(u8, hdr.head, "plugin-entry")) {
                try diags.append(a, .{
                    .span = path_span,
                    .code = .invalid_manifest,
                    .message = try std.fmt.allocPrint(
                        a,
                        "`:plugins` entries must be a path string or `(plugin-entry …)`; got `({s} …)`",
                        .{hdr.head},
                    ),
                    .path = try Ast.dupePath(a, &.{"project"}),
                });
                return;
            }
            for (hdr.children) |ci| {
                if (tree.tagOf(ci) != .kvpair) continue;
                const kv = tree.kvpairHeader(ci);
                if (std.mem.eql(u8, kv.key, "path") and tree.tagOf(kv.value) == .string) {
                    rel_path = tree.stringText(kv.value);
                } else if (std.mem.eql(u8, kv.key, "version") and tree.tagOf(kv.value) == .string) {
                    version_pin = try a.dupe(u8, tree.stringText(kv.value));
                } else if (std.mem.eql(u8, kv.key, "hash") and tree.tagOf(kv.value) == .string) {
                    hash_pin = try a.dupe(u8, tree.stringText(kv.value));
                } else if (std.mem.eql(u8, kv.key, "optional")) {
                    optional = switch (tree.tagOf(kv.value)) {
                        .boolean_true => true,
                        else => false,
                    };
                }
                // `:as` is reserved for future name-collision handling
                // — accepted but unused in v1.1.
            }
            if (rel_path.len == 0) {
                try diags.append(a, .{
                    .span = path_span,
                    .code = .invalid_manifest,
                    .message = try a.dupe(u8, "`(plugin-entry …)` requires a `:path` string"),
                    .path = try Ast.dupePath(a, &.{"project"}),
                });
                return;
            }
        },
        else => {
            try diags.append(a, .{
                .span = path_span,
                .code = .invalid_manifest,
                .message = try a.dupe(u8, "`:plugins` entries must be a path string or `(plugin-entry …)` form"),
                .path = try Ast.dupePath(a, &.{"project"}),
            });
            return;
        },
    }

    const manifest_path = try resolveAgainstRoot(a, self.project_root, rel_path);

    const manifest_source = CappedRead.readFileZ(
        self.io,
        manifest_path,
        a,
        CappedRead.MAX_FILE_SIZE,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try diags.append(a, .{
                .span = path_span,
                .code = .invalid_manifest,
                .message = try std.fmt.allocPrint(
                    a,
                    "manifest at `{s}` unreadable: {s}",
                    .{ manifest_path, @errorName(err) },
                ),
                .path = try Ast.dupePath(a, &.{"project"}),
            });
            return;
        },
    };

    var manifest_tree = try Parser.parse(self.gpa, manifest_source);
    defer manifest_tree.deinit();

    var loaded = ManifestLoader.load(self.gpa, manifest_tree) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotAPluginManifest => {
            try diags.append(a, .{
                .span = path_span,
                .code = .invalid_manifest,
                .message = try std.fmt.allocPrint(
                    a,
                    "manifest at `{s}` is not a (plugin …) form",
                    .{manifest_path},
                ),
                .path = try Ast.dupePath(a, &.{"project"}),
            });
            return;
        },
    };
    defer loaded.deinit();

    if (loaded.hasErrors()) {
        // The inner diagnostics carry spans into the manifest source —
        // `Host.wrapProjectDiagnostic` will zero those at drain time.
        // Prefix the message with the manifest path so the user can
        // navigate without scanning the project file for the offending
        // entry.
        for (loaded.diagnostics) |d| {
            try diags.append(a, try prefixedDiagnostic(a, d, manifest_path));
        }
        return;
    }

    const name_owned = try a.dupe(u8, loaded.plugin.name);

    if (self.name_index.getPtr(name_owned)) |existing| {
        try diags.append(a, .{
            .span = path_span,
            .code = .duplicate_plugin_name,
            .message = try std.fmt.allocPrint(
                a,
                "plugin `:name {s}` already declared by `{s}`; refusing last-wins",
                .{ name_owned, existing.manifest_path },
            ),
            .path = try Ast.dupePath(a, &.{"project"}),
        });
        return;
    }

    try self.name_index.put(a, name_owned, .{
        .manifest_path = manifest_path,
        .manifest_source = manifest_source,
        .version_pin = version_pin,
        .hash_pin = hash_pin,
        .optional = optional,
    });
}

// ---------------------------------------------------------------------
// Resolve callback.
// ---------------------------------------------------------------------

fn resolveCallback(
    ctx: *anyopaque,
    ref: Resolver.Reference,
    arena: Allocator,
) Allocator.Error!Resolver.Resolution {
    const self: *Self = @ptrCast(@alignCast(ctx));

    if (ref.explicit_path) |explicit| {
        const abs_path = try resolveAgainstRoot(arena, self.project_root, explicit);
        const bytes = CappedRead.readFileZ(
            self.io,
            abs_path,
            arena,
            CappedRead.MAX_FILE_SIZE,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .failure = .{
                .code = .unresolved_plugin,
                .detail = try std.fmt.allocPrint(
                    arena,
                    "explicit :path `{s}` unreadable: {s}",
                    .{ abs_path, @errorName(err) },
                ),
            } },
        };
        return try resolveManifestWasm(self.gpa, self.io, arena, abs_path, bytes);
    }

    if (self.name_index.get(ref.name)) |entry| {
        // Pin-disagreement check: when both a project pin and a
        // use-plugin pin are present, they must agree byte-for-byte.
        // One-sided pins succeed silently — documents stay portable,
        // projects stay opinionated.
        if (entry.version_pin) |project_v| {
            if (ref.version) |use_v| {
                if (!std.mem.eql(u8, project_v, use_v)) {
                    return .{ .failure = .{
                        .code = .pin_disagreement,
                        .detail = try std.fmt.allocPrint(
                            arena,
                            "project pins `:version \"{s}\"` but `(use-plugin \"{s}\" :version \"{s}\")` disagrees",
                            .{ project_v, ref.name, use_v },
                        ),
                    } };
                }
            }
        }
        if (entry.hash_pin) |project_h| {
            if (ref.hash) |use_h| {
                if (!std.mem.eql(u8, project_h, use_h)) {
                    return .{ .failure = .{
                        .code = .pin_disagreement,
                        .detail = try std.fmt.allocPrint(
                            arena,
                            "project pins `:hash \"{s}\"` but `(use-plugin \"{s}\" :hash \"{s}\")` disagrees",
                            .{ project_h, ref.name, use_h },
                        ),
                    } };
                }
            }
        }
        // `entry.manifest_source` already lives in the resolver arena
        // (sentinel-terminated); pass it through without duplication —
        // the caller's `arena` is short-lived and re-duping serves only
        // to break the borrow.
        return try resolveManifestWasm(self.gpa, self.io, arena, entry.manifest_path, entry.manifest_source);
    }

    if (self.project_file_path == null) {
        return .{ .failure = .{
            .code = .unresolved_plugin,
            .detail = try std.fmt.allocPrint(
                arena,
                "no plugin named `{s}` (no project file in `{s}`)",
                .{ ref.name, self.project_root },
            ),
        } };
    }
    return .{ .failure = .{
        .code = .unresolved_plugin,
        .detail = try std.fmt.allocPrint(
            arena,
            "no plugin named `{s}` in `{s}`",
            .{ ref.name, self.project_file_path.? },
        ),
    } };
}

// ---------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------

/// Resolve a manifest's paired wasm bytes, honoring the optional
/// `:wasm-file` override. Two outcomes:
///   * Success: `Resolution.manifest{ source, wasm }`. `wasm` is null
///     for declarative-only plugins (no override, no default-paired
///     file).
///   * Failure: `Resolution.failure{ code, detail }` when the override
///     escapes the manifest dir (`plugin_wasm_resolved_outside_package`)
///     or is explicitly named but unreadable (`unresolved_plugin`).
///
/// When the manifest has no `:wasm-file` key, falls back to the default
/// pairing rules in `readPairedWasm`. The manifest is parsed locally
/// (cheap — manifests are small) to extract the override; the host's
/// later `ManifestLoader.load` pass re-parses with full diagnostics.
fn resolveManifestWasm(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    manifest_abs_path: []const u8,
    manifest_source: [:0]const u8,
) Allocator.Error!Resolver.Resolution {
    const override = extractWasmFileOverride(gpa, arena, manifest_source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (override) |rel| {
        // Escape check runs on the AUTHOR'S spelled path (the relative
        // form they wrote in the manifest), not the joined absolute —
        // joining masks `..` segments behind a path that string-prefixes
        // its parent dir.
        if (escapesPackageDir(rel)) {
            return .{ .failure = .{
                .code = .plugin_wasm_resolved_outside_package,
                .detail = try std.fmt.allocPrint(
                    arena,
                    ":wasm-file `{s}` resolves outside the manifest's package directory",
                    .{rel},
                ),
            } };
        }
        const overridden = try joinManifestDirRelative(arena, manifest_abs_path, rel);
        const bytes = CappedRead.readFile(io, overridden, arena, CappedRead.MAX_FILE_SIZE) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .failure = .{
                .code = .unresolved_plugin,
                .detail = try std.fmt.allocPrint(
                    arena,
                    ":wasm-file `{s}` unreadable: {s}",
                    .{ overridden, @errorName(err) },
                ),
            } },
        };
        return .{ .manifest = .{ .source = manifest_source, .wasm = bytes } };
    }

    const wasm_bytes = try readPairedWasm(io, arena, manifest_abs_path);
    return .{ .manifest = .{ .source = manifest_source, .wasm = wasm_bytes } };
}

/// Scan a parsed `(plugin …)` manifest for a `:wasm-file "<path>"`
/// kvpair at the top level. Returns null when absent or malformed —
/// the meta-validator owns the malformed-shape error; this scanner
/// just yields nothing so the resolver falls back to default pairing.
fn extractWasmFileOverride(
    gpa: Allocator,
    arena: Allocator,
    manifest_source: [:0]const u8,
) Allocator.Error!?[]const u8 {
    var tree = Parser.parse(gpa, manifest_source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer tree.deinit();
    if (tree.root.len != 1) return null;
    const root = tree.root[0];
    if (tree.tagOf(root) != .form) return null;
    const hdr = tree.formHeader(root);
    if (hdr.namespace != null or !std.mem.eql(u8, hdr.head, "plugin")) return null;
    for (hdr.children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kv = tree.kvpairHeader(ci);
        if (!std.mem.eql(u8, kv.key, "wasm-file")) continue;
        if (tree.tagOf(kv.value) != .string) return null;
        return try arena.dupe(u8, tree.stringText(kv.value));
    }
    return null;
}

/// Concatenate `manifest_dir + "/" + rel`. Returns an arena-owned
/// slice. The `rel` path is treated as manifest-directory-relative;
/// absolute `rel` is rejected upstream by callers.
fn joinManifestDirRelative(
    arena: Allocator,
    manifest_abs_path: []const u8,
    rel: []const u8,
) Allocator.Error![]const u8 {
    const dir = manifestDir(manifest_abs_path);
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, dir);
    if (dir.len > 0 and dir[dir.len - 1] != '/') {
        try buf.append(arena, '/');
    }
    try buf.appendSlice(arena, rel);
    return try buf.toOwnedSlice(arena);
}

/// Slice the manifest's parent directory off its absolute path.
/// Returns `"."` when the manifest is at the cwd root (no slash).
fn manifestDir(manifest_abs_path: []const u8) []const u8 {
    const slash_idx = std.mem.lastIndexOfScalar(u8, manifest_abs_path, '/');
    if (slash_idx) |i| return manifest_abs_path[0..i];
    return ".";
}

/// Detect when a `:wasm-file` override would escape the manifest's
/// package directory. Operates on the relative path the author spelled
/// (e.g. `"../alt.wasm"` or `"sub/alt.wasm"`), NOT a pre-joined
/// absolute path. Lexical walk: a `..` decrements depth; a name
/// segment increments. The moment depth drops below zero we report
/// escape — one `..` more than name segments seen.
///
/// Absolute paths immediately escape; legitimate manifests use
/// package-relative spellings.
///
/// Uses lexical normalization (no filesystem realpath), so symlinks
/// can still hop out. That's acceptable for v1 — the goal is to catch
/// honest path traversal, not deliberate filesystem-level escapes.
fn escapesPackageDir(relative_path: []const u8) bool {
    if (relative_path.len > 0 and relative_path[0] == '/') return true;
    var depth: i32 = 0;
    var it = std.mem.splitScalar(u8, relative_path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            depth -= 1;
            if (depth < 0) return true;
            continue;
        }
        depth += 1;
    }
    return false;
}

/// Read the WASM binary paired with a manifest. Two pairing conventions
/// per `docs/executable-plugin-abi.md` §3:
///
///   1. Canonical single-plugin-directory layout: `plugin.sjon` next to
///      `plugin.wasm`. Chosen when the manifest filename is exactly
///      `plugin.sjon`.
///   2. Flat-vendor layout: `<stem>.sjon` next to `<stem>.wasm`. The
///      fallback for any other filename.
///
/// The file may not exist (declarative-only plugins); that's a normal
/// case and returns `null`. The `:wasm-file` manifest override is
/// handled in `resolveManifestWasm` (this file) once the manifest is
/// parsed — `readPairedWasm` is only the default-pairing fallback and
/// sees the manifest path, not its contents.
fn readPairedWasm(
    io: Io,
    arena: Allocator,
    manifest_abs_path: []const u8,
) Allocator.Error!?[]const u8 {
    const wasm_path = try pairedWasmPath(arena, manifest_abs_path);
    return CappedRead.readFile(io, wasm_path, arena, CappedRead.MAX_FILE_SIZE) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Any other error (FileNotFound being the common case) means
        // the manifest is declarative-only — `null` lets the host emit
        // `plugin_wasm_required` IFF the manifest declared `:impl
        // "wasm:…"` exports.
        else => return null,
    };
}

/// Compute the conventional paired-wasm path for a manifest. Returns an
/// arena-owned slice. Two cases:
///
///   - Manifest filename is exactly `plugin.sjon` → swap basename for
///     `plugin.wasm`.
///   - Else strip `.sjon` and append `.wasm` (flat-vendor layout). When
///     the manifest path has no `.sjon` suffix at all, just append
///     `.wasm` (defensive — manifests should always end in `.sjon`).
fn pairedWasmPath(arena: Allocator, manifest_path: []const u8) Allocator.Error![]const u8 {
    const sjon_ext = ".sjon";
    const wasm_ext = ".wasm";

    if (basenameIs(manifest_path, "plugin.sjon")) {
        const dir_len = manifest_path.len - "plugin.sjon".len;
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(arena, manifest_path[0..dir_len]);
        try buf.appendSlice(arena, "plugin.wasm");
        return try buf.toOwnedSlice(arena);
    }

    if (std.mem.endsWith(u8, manifest_path, sjon_ext)) {
        const base = manifest_path[0 .. manifest_path.len - sjon_ext.len];
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(arena, base);
        try buf.appendSlice(arena, wasm_ext);
        return try buf.toOwnedSlice(arena);
    }
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, manifest_path);
    try buf.appendSlice(arena, wasm_ext);
    return try buf.toOwnedSlice(arena);
}

/// Returns true when the path's basename (everything after the last
/// `/`) equals `expected`. Uses `/` as the separator — fine on POSIX
/// and the only convention the resolver emits paths in.
fn basenameIs(path: []const u8, expected: []const u8) bool {
    const slash_idx = std.mem.lastIndexOfScalar(u8, path, '/');
    const base = if (slash_idx) |i| path[i + 1 ..] else path;
    return std.mem.eql(u8, base, expected);
}

fn resolveAgainstRoot(
    arena: Allocator,
    root: []const u8,
    rel: []const u8,
) Allocator.Error![]const u8 {
    if (rel.len > 0 and rel[0] == '/') return try arena.dupe(u8, rel);
    // Strip leading `./` from rel — it's redundant with the root prefix
    // and would render as `./` + `./foo` = `././foo` otherwise.
    var rel_stripped = rel;
    while (std.mem.startsWith(u8, rel_stripped, "./")) {
        rel_stripped = rel_stripped[2..];
    }
    // When root is `.` (or empty), don't prepend it — the resulting
    // relative path is already correct.
    if (root.len == 0 or std.mem.eql(u8, root, ".")) {
        return try arena.dupe(u8, rel_stripped);
    }
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, root);
    if (buf.items.len == 0 or buf.items[buf.items.len - 1] != '/') {
        try buf.append(arena, '/');
    }
    try buf.appendSlice(arena, rel_stripped);
    return try buf.toOwnedSlice(arena);
}

fn prefixedDiagnostic(
    a: Allocator,
    d: Ast.Diagnostic,
    manifest_path: []const u8,
) Allocator.Error!Ast.Diagnostic {
    return .{
        .span = d.span,
        .severity = d.severity,
        .code = d.code,
        .message = try std.fmt.allocPrint(a, "in {s}: {s}", .{ manifest_path, d.message }),
        .path = try Ast.dupePath(a, d.path),
    };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

fn tmpRootPath(a: Allocator, sub_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{sub_path});
}

test "FilesystemResolver: no project file → empty index, resolves nothing by name" {
    var fs = try Self.init(testing.allocator, testing.io, "/tmp", null);
    defer fs.deinit();

    try testing.expectEqual(@as(usize, 0), fs.takeProjectDiagnostics().len);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = fs.resolver();
    const res = try r.resolve(r.ctx, .{
        .name = "shapes",
        .span = .{ .start = 0, .end = 0 },
    }, arena.allocator());
    try testing.expect(res == .failure);
    try testing.expectEqual(Ast.Diagnostic.Code.unresolved_plugin, res.failure.code);
}

test "FilesystemResolver: project file with one valid plugin indexes by :name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "shapes.sjon",
        .data = "(plugin :name shapes :version \"1.0.0\")",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(project :plugins [\"shapes.sjon\"])",
    });

    const project_file = try std.fmt.allocPrint(testing.allocator, "{s}/sjon-project.sjon", .{root});
    defer testing.allocator.free(project_file);

    var fs = try Self.init(testing.allocator, testing.io, root, project_file);
    defer fs.deinit();

    try testing.expectEqual(@as(usize, 0), fs.takeProjectDiagnostics().len);
    try testing.expect(fs.name_index.contains("shapes"));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = fs.resolver();
    const res = try r.resolve(r.ctx, .{
        .name = "shapes",
        .span = .{ .start = 0, .end = 0 },
    }, arena.allocator());
    try testing.expect(res == .manifest);
    try testing.expect(res.manifest.wasm == null);
    try testing.expect(std.mem.indexOf(u8, res.manifest.source, ":name shapes") != null);
}

test "FilesystemResolver.init converges under allocation failure without leaking the project load" {
    // Before `init` owned its arena from the first allocation, an OOM
    // inside `loadProjectFile` leaked every node the load allocated
    // (29 of 31 failing indices). `checkAllAllocationFailures` walks
    // every allocation site under `testing.allocator`, which reports a
    // leak as a test failure.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "shapes.sjon",
        .data = "(plugin :name shapes :version \"1.0.0\")",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(project :plugins [\"shapes.sjon\"])",
    });
    const project_file = try std.fmt.allocPrint(testing.allocator, "{s}/sjon-project.sjon", .{root});
    defer testing.allocator.free(project_file);

    const Probe = struct {
        fn run(gpa: Allocator, io: Io, r: []const u8, f: []const u8) !void {
            var fs = try Self.init(gpa, io, r, f);
            fs.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Probe.run, .{ testing.io, root, project_file });
}

test "FilesystemResolver: duplicate :name across :plugins entries emits duplicate_plugin_name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "a.sjon",
        .data = "(plugin :name shapes :version \"1.0.0\")",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "b.sjon",
        .data = "(plugin :name shapes :version \"1.0.0\")",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(project :plugins [\"a.sjon\" \"b.sjon\"])",
    });

    const project_file = try std.fmt.allocPrint(testing.allocator, "{s}/sjon-project.sjon", .{root});
    defer testing.allocator.free(project_file);

    var fs = try Self.init(testing.allocator, testing.io, root, project_file);
    defer fs.deinit();

    const diags = fs.takeProjectDiagnostics();
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.duplicate_plugin_name, diags[0].code);
}

test "FilesystemResolver: missing manifest path emits invalid_manifest at path span" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(project :plugins [\"missing.sjon\"])",
    });

    const project_file = try std.fmt.allocPrint(testing.allocator, "{s}/sjon-project.sjon", .{root});
    defer testing.allocator.free(project_file);

    var fs = try Self.init(testing.allocator, testing.io, root, project_file);
    defer fs.deinit();

    const diags = fs.takeProjectDiagnostics();
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.invalid_manifest, diags[0].code);
    try testing.expect(std.mem.indexOf(u8, diags[0].message, "missing.sjon") != null);
}

test "FilesystemResolver: explicit :path bypasses index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "vendored.sjon",
        .data = "(plugin :name vended :version \"1.0.0\")",
    });

    var fs = try Self.init(testing.allocator, testing.io, root, null);
    defer fs.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = fs.resolver();
    const res = try r.resolve(r.ctx, .{
        .name = "vended",
        .explicit_path = "vendored.sjon",
        .span = .{ .start = 0, .end = 0 },
    }, arena.allocator());
    try testing.expect(res == .manifest);
    try testing.expect(res.manifest.wasm == null);
    try testing.expect(std.mem.indexOf(u8, res.manifest.source, ":name vended") != null);
}

test "FilesystemResolver: explicit :path that does not exist becomes unresolved_plugin" {
    var fs = try Self.init(testing.allocator, testing.io, "/tmp", null);
    defer fs.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = fs.resolver();
    const res = try r.resolve(r.ctx, .{
        .name = "x",
        .explicit_path = "/definitely/does/not/exist.sjon",
        .span = .{ .start = 0, .end = 0 },
    }, arena.allocator());
    try testing.expect(res == .failure);
    try testing.expectEqual(Ast.Diagnostic.Code.unresolved_plugin, res.failure.code);
}

test "FilesystemResolver: project file with non-(project …) root reports invalid_manifest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(not-project :plugins [])",
    });

    const project_file = try std.fmt.allocPrint(testing.allocator, "{s}/sjon-project.sjon", .{root});
    defer testing.allocator.free(project_file);

    var fs = try Self.init(testing.allocator, testing.io, root, project_file);
    defer fs.deinit();

    const diags = fs.takeProjectDiagnostics();
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.invalid_manifest, diags[0].code);
}

test "FilesystemResolver: project file with a bare value (no form root) is invalid_manifest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "42",
    });

    const project_file = try std.fmt.allocPrint(testing.allocator, "{s}/sjon-project.sjon", .{root});
    defer testing.allocator.free(project_file);

    var fs = try Self.init(testing.allocator, testing.io, root, project_file);
    defer fs.deinit();

    const diags = fs.takeProjectDiagnostics();
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.invalid_manifest, diags[0].code);
    try testing.expect(std.mem.indexOf(u8, diags[0].message, "(project …)") != null);
}

test "FilesystemResolver: plugin.sjon pairs with plugin.wasm in same dir" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "plugin.sjon",
        .data = "(plugin :name canon :version \"1.0.0\")",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "plugin.wasm",
        .data = "\x00asm\x01\x00\x00\x00",
    });

    var fs = try Self.init(testing.allocator, testing.io, root, null);
    defer fs.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = fs.resolver();
    const res = try r.resolve(r.ctx, .{
        .name = "canon",
        .explicit_path = "plugin.sjon",
        .span = .{ .start = 0, .end = 0 },
    }, arena.allocator());
    try testing.expect(res == .manifest);
    try testing.expect(res.manifest.wasm != null);
    try testing.expectEqualSlices(u8, "\x00asm\x01\x00\x00\x00", res.manifest.wasm.?);
}

test "FilesystemResolver: stem-pairing still works for flat-vendor layouts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "shapes.sjon",
        .data = "(plugin :name shapes :version \"1.0.0\")",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "shapes.wasm",
        .data = "\x00asm\x01\x00\x00\x00",
    });

    var fs = try Self.init(testing.allocator, testing.io, root, null);
    defer fs.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = fs.resolver();
    const res = try r.resolve(r.ctx, .{
        .name = "shapes",
        .explicit_path = "shapes.sjon",
        .span = .{ .start = 0, .end = 0 },
    }, arena.allocator());
    try testing.expect(res == .manifest);
    try testing.expect(res.manifest.wasm != null);
}

test "FilesystemResolver: plugin.sjon without plugin.wasm yields null wasm" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "plugin.sjon",
        .data = "(plugin :name decl :version \"1.0.0\")",
    });

    var fs = try Self.init(testing.allocator, testing.io, root, null);
    defer fs.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = fs.resolver();
    const res = try r.resolve(r.ctx, .{
        .name = "decl",
        .explicit_path = "plugin.sjon",
        .span = .{ .start = 0, .end = 0 },
    }, arena.allocator());
    try testing.expect(res == .manifest);
    try testing.expect(res.manifest.wasm == null);
}

test "FilesystemResolver: :wasm-file override is honored when in-package" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "plugin.sjon",
        .data = "(plugin :name custom :version \"1.0.0\" :wasm-file \"custom.wasm\")",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "custom.wasm",
        .data = "\x00asm\x01\x00\x00\x00",
    });

    var fs = try Self.init(testing.allocator, testing.io, root, null);
    defer fs.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = fs.resolver();
    const res = try r.resolve(r.ctx, .{
        .name = "custom",
        .explicit_path = "plugin.sjon",
        .span = .{ .start = 0, .end = 0 },
    }, arena.allocator());
    try testing.expect(res == .manifest);
    try testing.expect(res.manifest.wasm != null);
}

test "FilesystemResolver: :wasm-file escaping package emits plugin_wasm_resolved_outside_package" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "plugin.sjon",
        .data = "(plugin :name evil :version \"1.0.0\" :wasm-file \"../../../etc/passwd\")",
    });

    var fs = try Self.init(testing.allocator, testing.io, root, null);
    defer fs.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = fs.resolver();
    const res = try r.resolve(r.ctx, .{
        .name = "evil",
        .explicit_path = "plugin.sjon",
        .span = .{ .start = 0, .end = 0 },
    }, arena.allocator());
    try testing.expect(res == .failure);
    try testing.expectEqual(Ast.Diagnostic.Code.plugin_wasm_resolved_outside_package, res.failure.code);
}

test "FilesystemResolver: escapesPackageDir detects parent-traversal" {
    try testing.expect(!escapesPackageDir("alt.wasm"));
    try testing.expect(!escapesPackageDir("sub/alt.wasm"));
    try testing.expect(!escapesPackageDir("./alt.wasm"));
    try testing.expect(escapesPackageDir("../alt.wasm"));
    try testing.expect(escapesPackageDir("../../alt.wasm"));
    // Down-then-up within the package is fine.
    try testing.expect(!escapesPackageDir("sub/../alt.wasm"));
    // Absolute paths always escape.
    try testing.expect(escapesPackageDir("/etc/passwd"));
}

test "FilesystemResolver: pairedWasmPath chooses plugin.wasm for plugin.sjon basename" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "/usr/share/sjon/plugin.wasm",
        try pairedWasmPath(a, "/usr/share/sjon/plugin.sjon"),
    );
    try testing.expectEqualStrings(
        "/vendor/shapes.wasm",
        try pairedWasmPath(a, "/vendor/shapes.sjon"),
    );
    try testing.expectEqualStrings(
        "plugin.wasm",
        try pairedWasmPath(a, "plugin.sjon"),
    );
}

test "FilesystemResolver: project file with (plugin-entry …) captures pins" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "shapes.sjon",
        .data = "(plugin :name shapes :version \"1.0.0\")",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data =
        \\(project
        \\  :plugins
        \\  [(plugin-entry :path "shapes.sjon"
        \\                 :version "1.0.0"
        \\                 :optional false)])
        ,
    });

    const project_file = try std.fmt.allocPrint(testing.allocator, "{s}/sjon-project.sjon", .{root});
    defer testing.allocator.free(project_file);

    var fs = try Self.init(testing.allocator, testing.io, root, project_file);
    defer fs.deinit();

    try testing.expectEqual(@as(usize, 0), fs.takeProjectDiagnostics().len);
    const entry = fs.name_index.get("shapes") orelse return error.TestUnexpectedResult;
    try testing.expect(entry.version_pin != null);
    try testing.expectEqualStrings("1.0.0", entry.version_pin.?);
    try testing.expect(entry.hash_pin == null);
    try testing.expect(!entry.optional);
}

test "FilesystemResolver: project pin disagreement with use-plugin pin emits pin_disagreement" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "shapes.sjon",
        .data = "(plugin :name shapes :version \"1.0.0\")",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data =
        \\(project :plugins
        \\  [(plugin-entry :path "shapes.sjon" :version "1.0.0")])
        ,
    });

    const project_file = try std.fmt.allocPrint(testing.allocator, "{s}/sjon-project.sjon", .{root});
    defer testing.allocator.free(project_file);

    var fs = try Self.init(testing.allocator, testing.io, root, project_file);
    defer fs.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = fs.resolver();
    const res = try r.resolve(r.ctx, .{
        .name = "shapes",
        .version = "2.0.0", // disagrees with project pin
        .span = .{ .start = 0, .end = 0 },
    }, arena.allocator());
    try testing.expect(res == .failure);
    try testing.expectEqual(Ast.Diagnostic.Code.pin_disagreement, res.failure.code);
}

test "FilesystemResolver: project file v1.1 keys are captured" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data =
        \\(project
        \\  :name workspace
        \\  :documents ["docs/**/*.sjon" "scenes/*.sjon"]
        \\  :search-roots ["./vendor"]
        \\  :ignore [".git/" "node_modules/"]
        \\  :lockfile "./custom.lock")
        ,
    });

    const project_file = try std.fmt.allocPrint(testing.allocator, "{s}/sjon-project.sjon", .{root});
    defer testing.allocator.free(project_file);

    var fs = try Self.init(testing.allocator, testing.io, root, project_file);
    defer fs.deinit();

    try testing.expectEqual(@as(usize, 0), fs.takeProjectDiagnostics().len);
    try testing.expect(fs.project_name != null);
    try testing.expectEqualStrings("workspace", fs.project_name.?);
    try testing.expectEqual(@as(usize, 2), fs.project_documents.len);
    try testing.expectEqualStrings("docs/**/*.sjon", fs.project_documents[0]);
    try testing.expectEqual(@as(usize, 1), fs.project_search_roots.len);
    try testing.expectEqual(@as(usize, 2), fs.project_ignore.len);
    try testing.expectEqualStrings("./custom.lock", fs.project_lockfile_path.?);
    try testing.expect(!fs.project_lockfile_disabled);
}

test "FilesystemResolver: :lockfile false disables lockfile" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(project :lockfile false)",
    });

    const project_file = try std.fmt.allocPrint(testing.allocator, "{s}/sjon-project.sjon", .{root});
    defer testing.allocator.free(project_file);

    var fs = try Self.init(testing.allocator, testing.io, root, project_file);
    defer fs.deinit();

    try testing.expect(fs.project_lockfile_disabled);
    try testing.expect(fs.project_lockfile_path == null);
}

test "FilesystemResolver: unknown project key emits warning" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(project :nonsense \"something\")",
    });

    const project_file = try std.fmt.allocPrint(testing.allocator, "{s}/sjon-project.sjon", .{root});
    defer testing.allocator.free(project_file);

    var fs = try Self.init(testing.allocator, testing.io, root, project_file);
    defer fs.deinit();

    const diags = fs.takeProjectDiagnostics();
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqual(Ast.Diagnostic.Code.unknown_project_key, diags[0].code);
    try testing.expectEqual(Ast.Diagnostic.Severity.warning, diags[0].severity);
}

test "FilesystemResolver: (exports …) form captures targets" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data =
        \\(project :exports (exports :json-schema "./schemas/"
        \\                            :typescript "./types/"
        \\                            :layout per-plugin))
        ,
    });

    const project_file = try std.fmt.allocPrint(testing.allocator, "{s}/sjon-project.sjon", .{root});
    defer testing.allocator.free(project_file);

    var fs = try Self.init(testing.allocator, testing.io, root, project_file);
    defer fs.deinit();

    try testing.expect(fs.project_exports != null);
    const exp = fs.project_exports.?;
    try testing.expectEqualStrings("./schemas/", exp.json_schema_dir.?);
    try testing.expectEqualStrings("./types/", exp.typescript_dir.?);
    try testing.expectEqual(ExportLayout.per_plugin, exp.layout);
}

test "FilesystemResolver: takeProjectDiagnostics drains exactly once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRootPath(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(root);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "sjon-project.sjon",
        .data = "(not-project :plugins [])",
    });

    const project_file = try std.fmt.allocPrint(testing.allocator, "{s}/sjon-project.sjon", .{root});
    defer testing.allocator.free(project_file);

    var fs = try Self.init(testing.allocator, testing.io, root, project_file);
    defer fs.deinit();

    try testing.expectEqual(@as(usize, 1), fs.takeProjectDiagnostics().len);
    try testing.expectEqual(@as(usize, 0), fs.takeProjectDiagnostics().len);
}
