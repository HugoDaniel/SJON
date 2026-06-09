const std = @import("std");
const Ast = @import("Ast.zig");
const Resolver = @import("Resolver.zig");
const Parser = @import("Parser.zig");
const ManifestLoader = @import("ManifestLoader.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Self = @This();

pub const PROJECT_FILE_NAME = "sjon-project.sjon";

pub const IndexEntry = struct {
    manifest_path: []const u8,
    manifest_source: [:0]const u8,
    version_pin: ?[]const u8 = null,
    hash_pin: ?[]const u8 = null,
    optional: bool = false,
    entry_span: Ast.Span = .{ .start = 0, .end = 0 },
};

pub const ExportLayout = enum { per_plugin, single_file };

pub const ExportSpec = struct {
    json_schema_dir: ?[]const u8 = null,
    typescript_dir: ?[]const u8 = null,
    layout: ExportLayout = .per_plugin,
};

gpa: Allocator,
io: Io,
arena: std.heap.ArenaAllocator,
project_root: []const u8,
project_file_path: ?[]const u8,
project_source: ?[:0]const u8,
name_index: std.StringHashMapUnmanaged(IndexEntry),
project_diagnostics: []Ast.Diagnostic,
project_name: ?[]const u8 = null,
project_version: ?[]const u8 = null,
project_documents: []const []const u8 = &.{},
project_search_roots: []const []const u8 = &.{},
project_ignore: []const []const u8 = &.{},
project_lockfile_path: ?[]const u8 = null,
project_lockfile_disabled: bool = false,
project_exports: ?ExportSpec = null,

pub fn init(
    gpa: Allocator,
    io: Io,
    project_root: []const u8,
    project_file_path: ?[]const u8,
) Allocator.Error!Self {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const root_owned = try a.dupe(u8, project_root);
    const file_owned = if (project_file_path) |p| try a.dupe(u8, p) else null;

    var self: Self = .{
        .gpa = gpa,
        .io = io,
        .arena = arena,
        .project_root = root_owned,
        .project_file_path = file_owned,
        .project_source = null,
        .name_index = .empty,
        .project_diagnostics = &.{},
        .project_documents = &.{},
        .project_search_roots = &.{},
        .project_ignore = &.{},
        .project_exports = null,
    };

    var diags: std.ArrayList(Ast.Diagnostic) = .empty;
    if (file_owned) |path| {
        try loadProjectFile(&self, &diags, path);
    }
    self.project_diagnostics = try diags.toOwnedSlice(a);

    return self;
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn resolver(self: *Self) Resolver.Resolver {
    return .{ .ctx = self, .resolve = resolveCallback };
}

pub fn takeProjectDiagnostics(self: *Self) []Ast.Diagnostic {
    const out = self.project_diagnostics;
    self.project_diagnostics = &.{};
    return out;
}

pub fn getProjectSource(self: *const Self) ?[:0]const u8 {
    return self.project_source;
}

pub const ProjectPluginEntry = struct {
    name: []const u8,
    manifest_path: []const u8,
    manifest_source: [:0]const u8,
};

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

fn loadProjectFile(
    self: *Self,
    diags: *std.ArrayList(Ast.Diagnostic),
    project_path: []const u8,
) Allocator.Error!void {
    const a = self.arena.allocator();

    const project_source = Io.Dir.cwd().readFileAllocOptions(
        self.io,
        project_path,
        a,
        .unlimited,
        .of(u8),
        0,
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
                .path = try singletonPath(a, "project"),
            });
            return;
        },
    };
    self.project_source = project_source;

    var tree = try Parser.parse(self.gpa, project_source);
    defer tree.deinit();

    for (tree.diagnostics) |d| try diags.append(a, try cloneDiagnostic(a, d));

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
            .path = try singletonPath(a, "project"),
        });
        return;
    }

    const root_idx = tree.root[0];
    if (tree.tagOf(root_idx) != .form) {
        try diags.append(a, .{
            .span = tree.spanOf(root_idx),
            .code = .invalid_manifest,
            .message = try std.fmt.allocPrint(
                a,
                "expected a (project …) form at top level of {s}",
                .{PROJECT_FILE_NAME},
            ),
            .path = try singletonPath(a, "project"),
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
            .path = try singletonPath(a, "project"),
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
        } else if (std.mem.eql(u8, kv.key, "sjon")) {} else if (std.mem.eql(u8, kv.key, "documents")) {
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
            try diags.append(a, .{
                .span = tree.spanOf(ci),
                .severity = .warning,
                .code = .unknown_project_key,
                .message = try std.fmt.allocPrint(
                    a,
                    "unknown project-file key `:{s}`",
                    .{kv.key},
                ),
                .path = try singletonPath(a, "project"),
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
            .path = try singletonPath(a, "project"),
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
        .boolean_true => {},
        else => {},
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
                    .path = try singletonPath(a, "project"),
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
            }
            if (rel_path.len == 0) {
                try diags.append(a, .{
                    .span = path_span,
                    .code = .invalid_manifest,
                    .message = try a.dupe(u8, "`(plugin-entry …)` requires a `:path` string"),
                    .path = try singletonPath(a, "project"),
                });
                return;
            }
        },
        else => {
            try diags.append(a, .{
                .span = path_span,
                .code = .invalid_manifest,
                .message = try a.dupe(u8, "`:plugins` entries must be a path string or `(plugin-entry …)` form"),
                .path = try singletonPath(a, "project"),
            });
            return;
        },
    }

    const manifest_path = try resolveAgainstRoot(a, self.project_root, rel_path);

    const manifest_source = Io.Dir.cwd().readFileAllocOptions(
        self.io,
        manifest_path,
        a,
        .unlimited,
        .of(u8),
        0,
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
                .path = try singletonPath(a, "project"),
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
                .path = try singletonPath(a, "project"),
            });
            return;
        },
    };
    defer loaded.deinit();

    if (loaded.hasErrors()) {
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
            .path = try singletonPath(a, "project"),
        });
        return;
    }

    try self.name_index.put(a, name_owned, .{
        .manifest_path = manifest_path,
        .manifest_source = manifest_source,
        .version_pin = version_pin,
        .hash_pin = hash_pin,
        .optional = optional,
        .entry_span = path_span,
    });
}

fn resolveCallback(
    ctx: *anyopaque,
    ref: Resolver.Reference,
    arena: Allocator,
) Allocator.Error!Resolver.Resolution {
    const self: *Self = @ptrCast(@alignCast(ctx));

    if (ref.explicit_path) |explicit| {
        const abs_path = try resolveAgainstRoot(arena, self.project_root, explicit);
        const bytes = Io.Dir.cwd().readFileAllocOptions(
            self.io,
            abs_path,
            arena,
            .unlimited,
            .of(u8),
            0,
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
        const bytes = Io.Dir.cwd().readFileAlloc(io, overridden, arena, .unlimited) catch |err| switch (err) {
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

fn manifestDir(manifest_abs_path: []const u8) []const u8 {
    const slash_idx = std.mem.lastIndexOfScalar(u8, manifest_abs_path, '/');
    if (slash_idx) |i| return manifest_abs_path[0..i];
    return ".";
}

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

fn readPairedWasm(
    io: Io,
    arena: Allocator,
    manifest_abs_path: []const u8,
) Allocator.Error!?[]const u8 {
    const wasm_path = try pairedWasmPath(arena, manifest_abs_path);
    return Io.Dir.cwd().readFileAlloc(io, wasm_path, arena, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

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
    var rel_stripped = rel;
    while (std.mem.startsWith(u8, rel_stripped, "./")) {
        rel_stripped = rel_stripped[2..];
    }
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

fn cloneDiagnostic(a: Allocator, d: Ast.Diagnostic) Allocator.Error!Ast.Diagnostic {
    const path = try a.alloc([]const u8, d.path.len);
    for (d.path, 0..) |step, i| path[i] = try a.dupe(u8, step);
    return .{
        .span = d.span,
        .severity = d.severity,
        .code = d.code,
        .message = try a.dupe(u8, d.message),
        .path = path,
    };
}

fn prefixedDiagnostic(
    a: Allocator,
    d: Ast.Diagnostic,
    manifest_path: []const u8,
) Allocator.Error!Ast.Diagnostic {
    const path = try a.alloc([]const u8, d.path.len);
    for (d.path, 0..) |step, i| path[i] = try a.dupe(u8, step);
    return .{
        .span = d.span,
        .severity = d.severity,
        .code = d.code,
        .message = try std.fmt.allocPrint(a, "in {s}: {s}", .{ manifest_path, d.message }),
        .path = path,
    };
}

fn singletonPath(a: Allocator, step: []const u8) Allocator.Error![]const []const u8 {
    const path = try a.alloc([]const u8, 1);
    path[0] = try a.dupe(u8, step);
    return path;
}

const testing = std.testing;

fn tmpRootPath(a: Allocator, sub_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{sub_path});
}
