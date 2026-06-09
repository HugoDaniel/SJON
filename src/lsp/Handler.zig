const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sjon = @import("sjon");

const Ast = sjon.Ast;
const Host = sjon.Host;
const Parser = sjon.Parser;
const Plugin = sjon.Plugin;
const Schema = sjon.Schema;
const Validator = sjon.Validator;
const ManifestLoader = sjon.ManifestLoader;

pub const Document = struct {
    source: [:0]u8,
    version: i64,
    tree: Ast.Tree,
    validate_result: Validator.Result,

    fn deinit(self: *Document, gpa: Allocator) void {
        self.validate_result.deinit();
        self.tree.deinit();
        gpa.free(self.source);
    }
};

pub const Severity = enum { err, warning };

pub const Diagnostic = struct {
    span_start: u32,
    span_end: u32,
    severity: Severity,
    code: []const u8,
    message: []const u8,
};

pub const SchemaSource = struct {
    uri: []const u8,
    text: []const u8,
};

pub const SchemaReport = struct {
    uri: []const u8,
    name: []const u8,
    diagnostics: []const Diagnostic,
};

pub const Hover = struct {
    contents: []const u8,
    span_start: u32,
    span_end: u32,
};

pub const CompletionItem = struct {
    label: []const u8,
    kind: Kind,
    detail: []const u8 = "",
    documentation: []const u8 = "",
    insert_text: ?[]const u8 = null,
    insert_text_format: InsertTextFormat = .plain_text,
    tags: []const Tag = &.{},
    sort_text: ?[]const u8 = null,
    filter_text: ?[]const u8 = null,
    commit_characters: []const u8 = &.{},

    pub const Kind = enum(u32) {
        function = 3,
        constructor = 4,
        field = 5,
        enum_member = 20,
    };

    pub const Tag = enum(u32) {
        deprecated = 1,
    };

    pub const InsertTextFormat = enum(u32) {
        plain_text = 1,
        snippet = 2,
    };
};

pub const TextEdit = struct {
    span_start: u32,
    span_end: u32,
    new_text: []const u8,
};

pub const Location = struct {
    uri: []const u8,
    span_start: u32,
    span_end: u32,
};

pub const WorkspaceEdit = struct {
    changes: []const FileEdits,

    pub const FileEdits = struct {
        uri: []const u8,
        edits: []const TextEdit,
    };
};

pub const CodeAction = struct {
    title: []const u8,
    edits: []const TextEdit,
    diagnostic_codes: []const []const u8 = &.{},
};

pub const DocumentSymbol = struct {
    name: []const u8,
    span_start: u32,
    span_end: u32,
    selection_start: u32,
    selection_end: u32,
    children: []const DocumentSymbol = &.{},
};

pub const FoldingRange = struct {
    span_start: u32,
    span_end: u32,
};

pub const InlayHint = struct {
    offset: u32,
    label: []const u8,
    padding_left: bool = false,
    padding_right: bool = false,
};

pub const SignatureHelp = struct {
    signatures: []const Signature,
    active_signature: u32 = 0,
    active_parameter: ?u32 = null,
};

pub const Signature = struct {
    label: []const u8,
    documentation: []const u8 = "",
    parameters: []const Parameter,
};

pub const Parameter = struct {
    label_start: u32,
    label_end: u32,
};

allocator: Allocator,
schema: Schema.Schema,
documents: std.StringHashMapUnmanaged(Document),
project: ?Host.LoadedProject,
schema_generation: u32,
user_schemas: std.ArrayList(ManifestLoader.Result),
composed_plugins: []Plugin.Plugin,
cross_ref_index: ?Validator.CrossRefIndex,
cross_ref_arena: ?std.heap.ArenaAllocator,
tree_uris: [][]const u8,
uri_to_tree_idx: std.StringHashMapUnmanaged(u32),

const Self = @This();

pub fn init(gpa: Allocator) Self {
    return .{
        .allocator = gpa,
        .schema = Schema.Schema.init(&.{sjon.plugins.core.plugin}),
        .documents = .empty,
        .project = null,
        .schema_generation = 0,
        .user_schemas = .empty,
        .composed_plugins = &.{},
        .cross_ref_index = null,
        .cross_ref_arena = null,
        .tree_uris = &.{},
        .uri_to_tree_idx = .empty,
    };
}

pub fn deinit(self: *Self) void {
    var it = self.documents.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(self.allocator);
    }
    self.documents.deinit(self.allocator);
    if (self.project != null) self.project.?.deinit();
    self.allocator.free(self.composed_plugins);
    for (self.user_schemas.items) |*r| r.deinit();
    self.user_schemas.deinit(self.allocator);
    if (self.cross_ref_arena) |*ar| ar.deinit();
    self.uri_to_tree_idx.deinit(self.allocator);
    self.* = undefined;
}

pub fn loadProject(self: *Self, io: Io, workspace_root_path: ?[]const u8) Allocator.Error!void {
    var new_project = try sjon.loadProject(self.allocator, .{
        .project_root = workspace_root_path,
        .io = io,
    });
    errdefer new_project.deinit();

    if (self.project != null) self.project.?.deinit();
    self.project = new_project;
    self.schema = Schema.Schema.init(new_project.plugins);
    self.schema_generation +%= 1;
}

pub fn revalidateOpenDocuments(self: *Self) Allocator.Error!void {
    var it = self.documents.iterator();
    while (it.next()) |entry| {
        const doc = entry.value_ptr;
        var tree = try Parser.parse(self.allocator, doc.source);
        errdefer tree.deinit();
        doc.tree.deinit();
        doc.tree = tree;
    }
    try self.revalidateForest();
}

fn revalidateForest(self: *Self) Allocator.Error!void {
    const n = self.documents.count();
    if (n == 0) {
        if (self.cross_ref_arena) |*ar| ar.deinit();
        self.cross_ref_arena = null;
        self.cross_ref_index = null;
        self.tree_uris = &.{};
        self.uri_to_tree_idx.clearRetainingCapacity();
        return;
    }

    const Pair = struct { uri: []const u8, doc: *Document };
    var pairs = try self.allocator.alloc(Pair, n);
    defer self.allocator.free(pairs);

    {
        var i: usize = 0;
        var it = self.documents.iterator();
        while (it.next()) |kv| : (i += 1) {
            pairs[i] = .{ .uri = kv.key_ptr.*, .doc = kv.value_ptr };
        }
    }

    std.mem.sort(Pair, pairs, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return std.mem.lessThan(u8, a.uri, b.uri);
        }
    }.lt);

    var trees = try self.allocator.alloc(Ast.Tree, n);
    defer self.allocator.free(trees);
    for (pairs, 0..) |p, i| trees[i] = p.doc.tree;

    var fr = try Validator.validateForest(self.allocator, trees, self.schema);
    const arena_a = fr.index_arena.allocator();
    var new_tree_uris = arena_a.alloc([]const u8, n) catch |err| {
        fr.deinit(self.allocator);
        return err;
    };
    for (pairs, 0..) |p, i| {
        new_tree_uris[i] = arena_a.dupe(u8, p.uri) catch |err| {
            fr.deinit(self.allocator);
            return err;
        };
    }

    for (pairs, 0..) |p, i| {
        p.doc.validate_result.deinit();
        p.doc.validate_result = fr.results[i];
    }
    self.allocator.free(fr.results);

    if (self.cross_ref_arena) |*ar| ar.deinit();
    self.cross_ref_arena = fr.index_arena;
    self.cross_ref_index = fr.cross_ref_index;
    self.tree_uris = new_tree_uris;

    self.uri_to_tree_idx.clearRetainingCapacity();
    try self.uri_to_tree_idx.ensureTotalCapacity(self.allocator, @intCast(n));
    for (new_tree_uris, 0..) |uri, i| {
        self.uri_to_tree_idx.putAssumeCapacityNoClobber(uri, @intCast(i));
    }
}

pub fn reloadProject(self: *Self, io: Io, workspace_root_path: ?[]const u8) Allocator.Error!void {
    try self.loadProject(io, workspace_root_path);
    try self.revalidateOpenDocuments();
}

pub fn setUserSchemas(
    self: *Self,
    arena: Allocator,
    sources: []const SchemaSource,
) Allocator.Error![]const SchemaReport {
    const reports = try arena.alloc(SchemaReport, sources.len);
    var diag_lists = try arena.alloc(std.ArrayList(Diagnostic), sources.len);
    for (diag_lists) |*l| l.* = .empty;

    var new_schemas: std.ArrayList(ManifestLoader.Result) = .empty;
    errdefer {
        for (new_schemas.items) |*r| r.deinit();
        new_schemas.deinit(self.allocator);
    }

    for (sources, 0..) |src, i| {
        reports[i] = .{ .uri = try arena.dupe(u8, src.uri), .name = "", .diagnostics = &.{} };
        const kept = try self.loadOneSchema(arena, src, &diag_lists[i]);
        if (kept) |loaded| {
            new_schemas.append(self.allocator, loaded) catch |err| {
                var l = loaded;
                l.deinit();
                return err;
            };
            reports[i].name = try arena.dupe(u8, loaded.plugin.name);
        }
    }

    const composed = try self.allocator.alloc(Plugin.Plugin, 1 + new_schemas.items.len);
    errdefer self.allocator.free(composed);
    composed[0] = sjon.plugins.core.plugin;
    for (new_schemas.items, 0..) |*r, i| composed[i + 1] = r.plugin;

    const new_schema = Schema.Schema.init(composed);

    {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const groups = [_][]const Ast.Diagnostic{
            try new_schema.validateCrossRefs(sa),
            try new_schema.validateUnions(sa),
            try new_schema.validateForms(sa),
            try new_schema.validateLowering(sa),
            try new_schema.validateDefaults(sa),
        };
        for (groups) |group| {
            for (group) |d| {
                if (d.path.len == 0) continue;
                for (reports, 0..) |*r, i| {
                    if (r.name.len != 0 and std.mem.eql(u8, r.name, d.path[0])) {
                        try diag_lists[i].append(arena, try translateDupe(arena, d));
                        break;
                    }
                }
            }
        }
    }

    for (reports, 0..) |*r, i| {
        r.diagnostics = try diag_lists[i].toOwnedSlice(arena);
    }

    self.allocator.free(self.composed_plugins);
    for (self.user_schemas.items) |*r| r.deinit();
    self.user_schemas.deinit(self.allocator);
    self.user_schemas = new_schemas;
    self.composed_plugins = composed;
    self.schema = new_schema;
    self.schema_generation +%= 1;

    self.revalidateOpenDocuments() catch {};

    return reports;
}

fn loadOneSchema(
    self: *Self,
    arena: Allocator,
    src: SchemaSource,
    out: *std.ArrayList(Diagnostic),
) Allocator.Error!?ManifestLoader.Result {
    const text0 = try sentinelDupe(self.allocator, src.text);
    defer self.allocator.free(text0);

    var tree = try Parser.parse(self.allocator, text0);
    defer tree.deinit();

    for (tree.diagnostics) |d| try out.append(arena, try translateDupe(arena, d));

    var loaded = ManifestLoader.load(self.allocator, tree) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotAPluginManifest => {
            try out.append(arena, .{
                .span_start = 0,
                .span_end = 0,
                .severity = .err,
                .code = @tagName(Ast.Diagnostic.Code.unspecified),
                .message = "a schema must be a single (plugin …) manifest",
            });
            return null;
        },
    };
    errdefer loaded.deinit();

    for (loaded.diagnostics) |d| try out.append(arena, try translateDupe(arena, d));

    if (loaded.hasErrors()) {
        loaded.deinit();
        return null;
    }
    return loaded;
}

pub fn getProjectInfo(self: *const Self) ?*const Host.LoadedProject {
    if (self.project == null) return null;
    return &self.project.?;
}

pub fn openDocument(self: *Self, uri: []const u8, version: i64, text: []const u8) !void {
    const source = try sentinelDupe(self.allocator, text);
    errdefer self.allocator.free(source);

    var tree = try Parser.parse(self.allocator, source);
    errdefer tree.deinit();

    var placeholder_arena = std.heap.ArenaAllocator.init(self.allocator);
    errdefer placeholder_arena.deinit();

    const gop = try self.documents.getOrPut(self.allocator, uri);
    if (gop.found_existing) {
        gop.value_ptr.deinit(self.allocator);
    } else {
        errdefer std.debug.assert(self.documents.remove(uri));
        gop.key_ptr.* = try self.allocator.dupe(u8, uri);
    }
    gop.value_ptr.* = .{
        .source = source,
        .version = version,
        .tree = tree,
        .validate_result = .{ .arena = placeholder_arena, .diagnostics = &.{} },
    };

    try self.revalidateForest();
}

pub fn changeDocumentFull(self: *Self, uri: []const u8, version: i64, new_text: []const u8) !void {
    const entry = self.documents.getPtr(uri) orelse return error.UnknownDocument;

    const source = try sentinelDupe(self.allocator, new_text);
    errdefer self.allocator.free(source);

    var tree = try Parser.parse(self.allocator, source);
    errdefer tree.deinit();

    var placeholder_arena = std.heap.ArenaAllocator.init(self.allocator);
    errdefer placeholder_arena.deinit();

    entry.deinit(self.allocator);
    entry.* = .{
        .source = source,
        .version = version,
        .tree = tree,
        .validate_result = .{ .arena = placeholder_arena, .diagnostics = &.{} },
    };

    try self.revalidateForest();
}

pub fn closeDocument(self: *Self, uri: []const u8) void {
    const entry = self.documents.fetchRemove(uri) orelse return;
    self.allocator.free(entry.key);
    var doc = entry.value;
    doc.deinit(self.allocator);

    if (self.cross_ref_arena) |*ar| ar.deinit();
    self.cross_ref_arena = null;
    self.cross_ref_index = null;
    self.revalidateForest() catch {};
}

pub fn getDocument(self: *const Self, uri: []const u8) ?*const Document {
    return self.documents.getPtr(uri);
}

pub fn getDiagnostics(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
) Allocator.Error!?[]const Diagnostic {
    const doc = self.getDocument(uri) orelse return null;

    const parse_diags = doc.tree.diagnostics;
    const validate_diags = doc.validate_result.diagnostics;
    const total = parse_diags.len + validate_diags.len;
    var out = try arena.alloc(Diagnostic, total);
    var i: usize = 0;
    for (parse_diags) |d| {
        out[i] = translate(d);
        i += 1;
    }
    for (validate_diags) |d| {
        out[i] = translate(d);
        i += 1;
    }
    return out;
}

pub fn getHover(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    byte_offset: u32,
) Allocator.Error!?Hover {
    const doc = self.getDocument(uri) orelse return null;
    const ctx = findHoverContext(&doc.tree, byte_offset) orelse return null;

    var buf: std.ArrayList(u8) = .empty;
    switch (ctx) {
        .form_head => |fh| return try self.renderHeadHover(arena, &buf, fh.hdr),
        .kvpair_key => |kk| return try self.renderKvpairHover(arena, &buf, kk),
        .member_value => |mv| return try self.renderMemberValueHover(arena, &buf, mv),
    }
}

const HoverContext = union(enum) {
    form_head: struct { hdr: Ast.FormHeader },
    kvpair_key: struct {
        parent_head: []const u8,
        parent_namespace: ?[]const u8,
        kv: Ast.KvPairHeader,
    },
    member_value: struct {
        parent_head: []const u8,
        parent_namespace: ?[]const u8,
        key_name: []const u8,
        text: []const u8,
        span: Ast.Span,
    },
};

fn findHoverContext(tree: *const Ast.Tree, pos: u32) ?HoverContext {
    for (tree.root) |idx| {
        if (containsOffset(tree.spanOf(idx), pos)) {
            return descendForHover(tree, idx, pos, null, null);
        }
    }
    return null;
}

fn descendForHover(
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    pos: u32,
    parent_head: ?[]const u8,
    parent_ns: ?[]const u8,
) ?HoverContext {
    switch (tree.tagOf(idx)) {
        .form => {
            const hdr = tree.formHeader(idx);
            if (containsOffset(hdr.head_span, pos)) {
                return .{ .form_head = .{ .hdr = hdr } };
            }
            for (hdr.children) |child| {
                if (containsOffset(tree.spanOf(child), pos)) {
                    return descendForHover(tree, child, pos, hdr.head, hdr.namespace);
                }
            }
            return .{ .form_head = .{ .hdr = hdr } };
        },
        .vector => {
            for (tree.vectorElements(idx)) |child| {
                if (containsOffset(tree.spanOf(child), pos)) {
                    return descendForHover(tree, child, pos, parent_head, parent_ns);
                }
            }
            return null;
        },
        .kvpair => {
            const kv = tree.kvpairHeader(idx);
            if (containsOffset(kv.key_span, pos)) {
                if (parent_head) |ph| {
                    return .{ .kvpair_key = .{
                        .parent_head = ph,
                        .parent_namespace = parent_ns,
                        .kv = kv,
                    } };
                }
                return null;
            }
            if (containsOffset(tree.spanOf(kv.value), pos)) {
                const value_tag = tree.tagOf(kv.value);
                if ((value_tag == .symbol or value_tag == .string) and parent_head != null) {
                    const text = if (value_tag == .symbol)
                        tree.symbolText(kv.value)
                    else
                        tree.stringText(kv.value);
                    return .{ .member_value = .{
                        .parent_head = parent_head.?,
                        .parent_namespace = parent_ns,
                        .key_name = kv.key,
                        .text = text,
                        .span = tree.spanOf(kv.value),
                    } };
                }
                return descendForHover(tree, kv.value, pos, parent_head, parent_ns);
            }
            return null;
        },
        else => return null,
    }
}

fn containsOffset(span: Ast.Span, pos: u32) bool {
    return pos >= span.start and pos < span.end;
}

fn renderHeadHover(
    self: *const Self,
    arena: Allocator,
    buf: *std.ArrayList(u8),
    hdr: Ast.FormHeader,
) Allocator.Error!?Hover {
    if (hdr.head.len == 0) return null;

    const form_lookup = self.schema.lookupForm(hdr.head, hdr.namespace);
    switch (form_lookup) {
        .found => |hit| {
            try renderFormSpec(arena, buf, hit, hdr);
            return .{
                .contents = try buf.toOwnedSlice(arena),
                .span_start = hdr.head_span.start,
                .span_end = hdr.head_span.end,
            };
        },
        .ambiguous => |amb| {
            try renderAmbiguousHead(arena, buf, hdr, amb, .form);
            return .{
                .contents = try buf.toOwnedSlice(arena),
                .span_start = hdr.head_span.start,
                .span_end = hdr.head_span.end,
            };
        },
        .not_found => {},
    }

    const expr_lookup = self.schema.lookupExprFunc(hdr.head, hdr.namespace);
    switch (expr_lookup) {
        .found => |hit| {
            try renderExprFunc(arena, buf, hit, hdr);
            return .{
                .contents = try buf.toOwnedSlice(arena),
                .span_start = hdr.head_span.start,
                .span_end = hdr.head_span.end,
            };
        },
        .ambiguous => |amb| {
            try renderAmbiguousHead(arena, buf, hdr, amb, .expr);
            return .{
                .contents = try buf.toOwnedSlice(arena),
                .span_start = hdr.head_span.start,
                .span_end = hdr.head_span.end,
            };
        },
        .not_found => return null,
    }
}

fn renderKvpairHover(
    self: *const Self,
    arena: Allocator,
    buf: *std.ArrayList(u8),
    kk: anytype,
) Allocator.Error!?Hover {
    const form_lookup = self.schema.lookupForm(kk.parent_head, kk.parent_namespace);
    const hit = switch (form_lookup) {
        .found => |h| h,
        else => return null,
    };
    for (hit.form.keys) |*key| {
        if (!std.mem.eql(u8, key.name, kk.kv.key)) continue;
        try renderKeySpec(arena, buf, hit, key, kk.kv);
        try appendStringBoundsSummary(arena, buf, self.schema, key.value_type);
        return .{
            .contents = try buf.toOwnedSlice(arena),
            .span_start = kk.kv.key_span.start,
            .span_end = kk.kv.key_span.end,
        };
    }
    return null;
}

fn renderMemberValueHover(
    self: *const Self,
    arena: Allocator,
    buf: *std.ArrayList(u8),
    mv: anytype,
) Allocator.Error!?Hover {
    const form_lookup = self.schema.lookupForm(mv.parent_head, mv.parent_namespace);
    const hit = switch (form_lookup) {
        .found => |h| h,
        else => return null,
    };
    var key_value_type: ?sjon.Plugin.ValueType = null;
    for (hit.form.keys) |k| {
        if (std.mem.eql(u8, k.name, mv.key_name)) {
            key_value_type = k.value_type;
            break;
        }
    }
    const vt = key_value_type orelse return null;
    const named = switch (vt) {
        .named => |n| n,
        else => return null,
    };
    const kind_lookup = self.schema.lookupValueKind(named.name, named.namespace);
    const kind = switch (kind_lookup) {
        .found => |k| k,
        else => return null,
    };
    const m = kind.members orelse return null;
    for (m.members) |mem| {
        if (!std.mem.eql(u8, mem.name, mv.text)) continue;
        try buf.appendSlice(arena, "**");
        try buf.appendSlice(arena, mem.name);
        try buf.appendSlice(arena, "** (kind `");
        try buf.appendSlice(arena, kind.name);
        try buf.appendSlice(arena, "`)");
        if (mem.label.len > 0) {
            try buf.appendSlice(arena, "\n\n");
            try buf.appendSlice(arena, mem.label);
        }
        if (mem.description.len > 0) {
            try buf.appendSlice(arena, "\n\n");
            try buf.appendSlice(arena, mem.description);
        }
        if (mem.deprecated) {
            try buf.appendSlice(arena, "\n\n**Deprecated**");
            if (mem.deprecation_message.len > 0) {
                try buf.appendSlice(arena, ": ");
                try buf.appendSlice(arena, mem.deprecation_message);
            }
        }
        return .{
            .contents = try buf.toOwnedSlice(arena),
            .span_start = mv.span.start,
            .span_end = mv.span.end,
        };
    }
    return null;
}

fn renderFormSpec(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    hit: Schema.FormHit,
    hdr: Ast.FormHeader,
) Allocator.Error!void {
    try buf.appendSlice(arena, "**(");
    if (hdr.namespace) |ns| {
        try buf.appendSlice(arena, ns);
        try buf.append(arena, '/');
    }
    try buf.appendSlice(arena, hit.form.name);
    try buf.appendSlice(arena, ")** — _from `");
    try buf.appendSlice(arena, hit.plugin.name);
    try buf.appendSlice(arena, "`_");
    if (hit.form.description.len > 0) {
        try buf.appendSlice(arena, "\n\n");
        try buf.appendSlice(arena, hit.form.description);
    }
    if (hit.form.keys.len > 0) {
        try buf.appendSlice(arena, "\n\n**Keys:**\n");
        for (hit.form.keys) |k| {
            try buf.appendSlice(arena, "- `:");
            try buf.appendSlice(arena, k.name);
            try buf.appendSlice(arena, "` `");
            try appendValueType(arena, buf, k.value_type);
            try buf.append(arena, '`');
            if (!k.effectiveOptional()) try buf.appendSlice(arena, " _(required)_");
            if (k.description.len > 0) {
                try buf.appendSlice(arena, " — ");
                try buf.appendSlice(arena, k.description);
            }
            try buf.append(arena, '\n');
        }
    }
    switch (hit.form.positional) {
        .none => {},
        .any => try buf.appendSlice(arena, "\n_Accepts positional children._"),
        .kind => |k| {
            try buf.appendSlice(arena, "\n_Accepts positional children of kind `");
            if (k.namespace) |ns| {
                try buf.appendSlice(arena, ns);
                try buf.appendSlice(arena, "/");
            }
            try buf.appendSlice(arena, k.name);
            try buf.appendSlice(arena, "`._");
        },
        .flag_set => |fs| {
            var any_meta = false;
            for (fs.flags) |f| {
                if (f.description.len > 0 or f.link != null) {
                    any_meta = true;
                    break;
                }
            }
            if (any_meta) {
                try buf.appendSlice(arena, "\n\n**Positional flags:**\n");
                for (fs.flags) |f| {
                    try buf.appendSlice(arena, "- `:");
                    try buf.appendSlice(arena, f.name);
                    try buf.append(arena, '`');
                    if (f.description.len > 0) {
                        try buf.appendSlice(arena, " — ");
                        try buf.appendSlice(arena, f.description);
                    }
                    if (f.link) |link| {
                        try buf.appendSlice(arena, " ([docs](");
                        try buf.appendSlice(arena, link);
                        try buf.appendSlice(arena, "))");
                    }
                    try buf.append(arena, '\n');
                }
            } else {
                try buf.appendSlice(arena, "\n_Accepts positional flags: ");
                for (fs.flags, 0..) |f, i| {
                    if (i > 0) try buf.appendSlice(arena, ", ");
                    try buf.appendSlice(arena, ":");
                    try buf.appendSlice(arena, f.name);
                }
                try buf.appendSlice(arena, "._");
            }
        },
    }
    if (hit.form.open) {
        try buf.appendSlice(arena, "\n_Open form: accepts unknown keywords._");
    }
}

fn renderExprFunc(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    hit: Schema.ExprHit,
    hdr: Ast.FormHeader,
) Allocator.Error!void {
    try buf.appendSlice(arena, "**(");
    if (hdr.namespace) |ns| {
        try buf.appendSlice(arena, ns);
        try buf.append(arena, '/');
    }
    try buf.appendSlice(arena, hit.func.name);
    try buf.appendSlice(arena, " …)** — _expression from `");
    try buf.appendSlice(arena, hit.plugin.name);
    try buf.appendSlice(arena, "`_");

    try buf.appendSlice(arena, "\n\n**Arity:** ");
    var num_buf: [32]u8 = undefined;
    switch (hit.func.arity) {
        .fixed => |n| try buf.appendSlice(arena, std.fmt.bufPrint(&num_buf, "exactly {d}", .{n}) catch unreachable),
        .at_least => |n| try buf.appendSlice(arena, std.fmt.bufPrint(&num_buf, "≥ {d}", .{n}) catch unreachable),
        .range => |r| try buf.appendSlice(arena, std.fmt.bufPrint(&num_buf, "{d}..{d}", .{ r.min, r.max }) catch unreachable),
    }

    if (hit.func.params) |params| {
        try buf.appendSlice(arena, "\n\n**Parameters:**\n");
        for (params, 0..) |p, i| {
            try buf.appendSlice(arena, std.fmt.bufPrint(&num_buf, "{d}. `", .{i}) catch unreachable);
            try appendValueType(arena, buf, p);
            try buf.appendSlice(arena, "`\n");
        }
        if (hit.func.rest) |r| {
            try buf.appendSlice(arena, "…rest: `");
            try appendValueType(arena, buf, r);
            try buf.appendSlice(arena, "`\n");
        }
    }

    if (hit.func.description.len > 0) {
        try buf.appendSlice(arena, "\n");
        try buf.appendSlice(arena, hit.func.description);
    }
}

fn renderKeySpec(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    hit: Schema.FormHit,
    key: *const sjon.Plugin.KeySpec,
    kv: Ast.KvPairHeader,
) Allocator.Error!void {
    try buf.appendSlice(arena, "**:");
    try buf.appendSlice(arena, kv.key);
    try buf.appendSlice(arena, "** on **(");
    try buf.appendSlice(arena, hit.form.name);
    try buf.appendSlice(arena, ")** — `");
    try appendValueType(arena, buf, key.value_type);
    try buf.append(arena, '`');
    if (!key.effectiveOptional()) try buf.appendSlice(arena, " _(required)_");
    if (key.description.len > 0) {
        try buf.appendSlice(arena, "\n\n");
        try buf.appendSlice(arena, key.description);
    }
    try buf.appendSlice(arena, "\n\n_From plugin `");
    try buf.appendSlice(arena, hit.plugin.name);
    try buf.appendSlice(arena, "`._");
}

fn renderAmbiguousHead(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    hdr: Ast.FormHeader,
    amb: Schema.Ambiguous,
    flavour: enum { form, expr },
) Allocator.Error!void {
    try buf.appendSlice(arena, "**");
    try buf.appendSlice(arena, hdr.head);
    try buf.appendSlice(arena, "** — _ambiguous ");
    try buf.appendSlice(arena, switch (flavour) {
        .form => "form",
        .expr => "expression",
    });
    try buf.appendSlice(arena, "_\n\nDefined by:");
    for (amb.slice()) |p| {
        try buf.appendSlice(arena, " `");
        try buf.appendSlice(arena, p.name);
        try buf.append(arena, '`');
    }
    try buf.appendSlice(arena, "\n\nQualify with `<plugin>/");
    try buf.appendSlice(arena, hdr.head);
    try buf.appendSlice(arena, "` to disambiguate.");
}

fn appendStringBoundsSummary(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    schema: Schema.Schema,
    vt: sjon.Plugin.ValueType,
) Allocator.Error!void {
    const ref = switch (vt) {
        .named => |n| n,
        else => return,
    };
    const kind = switch (schema.lookupValueKind(ref.name, ref.namespace)) {
        .found => |k| k,
        else => return,
    };
    if (kind.underlying != .string) return;
    const sb = kind.string_bounds orelse return;

    var first: bool = true;
    try buf.appendSlice(arena, "\n\n**Constraints:** ");
    if (sb.min_len != null or sb.max_len != null) {
        try buf.appendSlice(arena, "length ");
        if (sb.min_len) |mn| {
            const piece = try std.fmt.allocPrint(arena, "{d}", .{mn});
            try buf.appendSlice(arena, piece);
        } else {
            try buf.append(arena, '0');
        }
        try buf.appendSlice(arena, "–");
        if (sb.max_len) |mx| {
            const piece = try std.fmt.allocPrint(arena, "{d}", .{mx});
            try buf.appendSlice(arena, piece);
        } else {
            try buf.appendSlice(arena, "∞");
        }
        first = false;
    }
    if (sb.format) |fmt| {
        if (!first) try buf.appendSlice(arena, ", ");
        try buf.appendSlice(arena, "format `");
        try buf.appendSlice(arena, @tagName(fmt));
        try buf.append(arena, '`');
        first = false;
    }
    if (sb.pattern) |p| {
        if (!first) try buf.appendSlice(arena, ", ");
        try buf.appendSlice(arena, "pattern `");
        try buf.appendSlice(arena, p);
        try buf.appendSlice(arena, "` _(informational)_");
        first = false;
    }
}

fn appendValueType(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    vt: sjon.Plugin.ValueType,
) Allocator.Error!void {
    switch (vt) {
        .any => try buf.appendSlice(arena, "any"),
        .number => try buf.appendSlice(arena, "number"),
        .string => try buf.appendSlice(arena, "string"),
        .symbol => try buf.appendSlice(arena, "symbol"),
        .boolean => try buf.appendSlice(arena, "boolean"),
        .nil => try buf.appendSlice(arena, "nil"),
        .vector => try buf.appendSlice(arena, "vector"),
        .form => try buf.appendSlice(arena, "form"),
        .expr => try buf.appendSlice(arena, "expr"),
        .named => |n| {
            if (n.namespace) |ns| {
                try buf.appendSlice(arena, ns);
                try buf.appendSlice(arena, "/");
            }
            try buf.appendSlice(arena, n.name);
        },
    }
}

pub fn getCompletion(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    byte_offset: u32,
) Allocator.Error!?[]const CompletionItem {
    const doc = self.getDocument(uri) orelse return null;
    const ctx = resolveContextAt(&doc.tree, doc.source, byte_offset);
    return switch (ctx.position) {
        .none => null,
        .form_head => try self.completionsForFormHead(arena, &doc.tree, ctx, byte_offset),
        .kvpair_key => try self.completionsForKeywordKey(arena, &doc.tree, byte_offset),
        .kvpair_value => try self.completionsForKvpairValue(arena, uri, doc, byte_offset),
        .vector_elem => try self.completionsForVectorElement(arena, uri, doc, byte_offset, ctx),
        .expr_arg => try self.completionsForExprArg(arena, &doc.tree, ctx, byte_offset),
    };
}

pub const ResolvedContext = struct {
    enclosing_form_idx: ?Ast.NodeIndex,
    enclosing_kvpair_idx: ?Ast.NodeIndex,
    parent_form_idx: ?Ast.NodeIndex,
    position: Position,
    prefix: []const u8,

    pub const Position = enum {
        none,
        form_head,
        kvpair_key,
        kvpair_value,
        vector_elem,
        expr_arg,
    };
};

pub fn resolveContextAt(
    tree: *const Ast.Tree,
    source: []const u8,
    cursor: u32,
) ResolvedContext {
    const enc = findEnclosingFormIdx(tree, cursor);
    var ctx: ResolvedContext = .{
        .enclosing_form_idx = enc,
        .enclosing_kvpair_idx = findEnclosingKvpairIdx(tree, cursor),
        .parent_form_idx = if (enc) |e| findParentFormIdx(tree, e) else null,
        .position = .none,
        .prefix = prefixBefore(source, cursor),
    };
    if (classifyCompletionContext(source, cursor)) |c| {
        ctx.position = switch (c) {
            .form_head => .form_head,
            .keyword_key => .kvpair_key,
            .member_value => .kvpair_value,
        };
    }
    if (findEnclosingVectorIdx(tree, cursor)) |vec_idx| {
        const vec_span = tree.spanOf(vec_idx);
        const vec_size = vec_span.end - vec_span.start;
        const form_size: u32 = if (ctx.enclosing_form_idx) |f| blk: {
            const fs = tree.spanOf(f);
            break :blk fs.end - fs.start;
        } else std.math.maxInt(u32);
        if (vec_size < form_size) ctx.position = .vector_elem;
    }
    if (ctx.position == .none and ctx.enclosing_kvpair_idx == null) {
        if (ctx.enclosing_form_idx) |form_idx| {
            const hdr = tree.formHeader(form_idx);
            if (!containsOffset(hdr.head_span, cursor)) {
                ctx.position = .expr_arg;
            }
        }
    }
    return ctx;
}

fn prefixBefore(source: []const u8, cursor: u32) []const u8 {
    var i: usize = @min(cursor, source.len);
    const end = i;
    while (i > 0 and isSymbolChar(source[i - 1])) i -= 1;
    return source[i..end];
}

fn findEnclosingVectorIdx(tree: *const Ast.Tree, pos: u32) ?Ast.NodeIndex {
    var best: ?Ast.NodeIndex = null;
    var best_size: u32 = std.math.maxInt(u32);
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tags.len) : (i += 1) {
        if (tags[i] != .vector) continue;
        const idx = Ast.NodeIndex.from(i);
        const span = tree.spanOf(idx);
        if (pos < span.start or pos >= span.end) continue;
        const size = span.end - span.start;
        if (size < best_size) {
            best = idx;
            best_size = size;
        }
    }
    return best;
}

fn findEnclosingKvpairIdx(tree: *const Ast.Tree, pos: u32) ?Ast.NodeIndex {
    var best: ?Ast.NodeIndex = null;
    var best_size: u32 = std.math.maxInt(u32);
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tags.len) : (i += 1) {
        if (tags[i] != .kvpair) continue;
        const idx = Ast.NodeIndex.from(i);
        const span = tree.spanOf(idx);
        if (pos < span.start or pos >= span.end) continue;
        const size = span.end - span.start;
        if (size < best_size) {
            best = idx;
            best_size = size;
        }
    }
    return best;
}

const CompletionContext = enum { form_head, keyword_key, member_value };

fn classifyCompletionContext(source: []const u8, cursor: u32) ?CompletionContext {
    var i: usize = @min(cursor, source.len);
    while (i > 0 and isSymbolChar(source[i - 1])) i -= 1;
    while (i > 0 and isWhitespace(source[i - 1])) i -= 1;
    if (i == 0) return null;
    switch (source[i - 1]) {
        '(' => return .form_head,
        ':' => return .keyword_key,
        else => {},
    }
    var j: usize = i;
    while (j > 0 and isSymbolChar(source[j - 1])) j -= 1;
    if (j < i and j > 0 and source[j - 1] == ':') return .member_value;
    return null;
}

fn findEnclosingKvpairKey(source: []const u8, cursor: u32) ?[]const u8 {
    var i: usize = @min(cursor, source.len);
    while (i > 0 and isSymbolChar(source[i - 1])) i -= 1;
    while (i > 0 and isWhitespace(source[i - 1])) i -= 1;
    const key_end = i;
    while (i > 0 and isSymbolChar(source[i - 1])) i -= 1;
    if (i == key_end) return null;
    if (i == 0 or source[i - 1] != ':') return null;
    return source[i..key_end];
}

fn isSymbolChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '+', '*', '/', '?', '!', '=', '<', '>', '%', '.', '$', '&' => true,
        else => false,
    };
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

const Vocabulary = enum { any, expr, form };

fn resolveFormHeadVocabulary(
    self: *const Self,
    tree: *const Ast.Tree,
    ctx: ResolvedContext,
) Vocabulary {
    const parent = ctx.parent_form_idx orelse return .any;
    const parent_hdr = tree.formHeader(parent);

    if (ctx.enclosing_kvpair_idx) |kv_idx| {
        const kv_span = tree.spanOf(kv_idx);
        const parent_span = tree.spanOf(parent);
        if (kv_span.start >= parent_span.start and kv_span.end <= parent_span.end) {
            switch (self.schema.lookupForm(parent_hdr.head, parent_hdr.namespace)) {
                .found => |hit| {
                    const kv_hdr = tree.kvpairHeader(kv_idx);
                    for (hit.form.keys) |k| {
                        if (!std.mem.eql(u8, k.name, kv_hdr.key)) continue;
                        return switch (k.value_type) {
                            .expr => .expr,
                            .form => .form,
                            else => .any,
                        };
                    }
                },
                else => {},
            }
        }
    }

    switch (self.schema.lookupExprFunc(parent_hdr.head, parent_hdr.namespace)) {
        .found => return .expr,
        else => {},
    }
    return .any;
}

fn completionsForFormHead(
    self: *const Self,
    arena: Allocator,
    tree: *const Ast.Tree,
    ctx: ResolvedContext,
    cursor: u32,
) Allocator.Error![]const CompletionItem {
    const vocab = self.resolveFormHeadVocabulary(tree, ctx);

    var expected: ?sjon.Plugin.ValueType = null;
    if (vocab == .expr) {
        if (ctx.parent_form_idx) |pf_idx| {
            const pf_hdr = tree.formHeader(pf_idx);
            const pf_span = tree.spanOf(pf_idx);
            const inside_kvpair_child = if (ctx.enclosing_kvpair_idx) |kv| blk: {
                const kv_span = tree.spanOf(kv);
                break :blk kv_span.start >= pf_span.start and kv_span.end <= pf_span.end;
            } else false;
            if (!inside_kvpair_child) {
                switch (self.schema.lookupExprFunc(pf_hdr.head, pf_hdr.namespace)) {
                    .found => |hit| {
                        const arg_idx = positionalIndex(tree, pf_hdr.children, cursor);
                        expected = expectedArgType(hit.func, arg_idx);
                    },
                    else => {},
                }
            }
        }
    }

    var items: std.ArrayList(CompletionItem) = .empty;
    for (self.schema.plugins) |p| {
        if (vocab != .expr) {
            for (p.forms) |f| {
                const snippet = try buildFormSnippet(arena, self.schema, f);
                try items.append(arena, .{
                    .label = f.name,
                    .kind = .constructor,
                    .detail = try std.fmt.allocPrint(arena, "form ({s})", .{p.name}),
                    .documentation = f.description,
                    .insert_text = snippet,
                    .insert_text_format = if (snippet != null) .snippet else .plain_text,
                });
            }
        }
        if (vocab != .form) {
            for (p.expr_funcs) |*f| {
                if (!candidateMatches(f, expected)) continue;
                try items.append(arena, .{
                    .label = f.name,
                    .kind = .function,
                    .detail = try std.fmt.allocPrint(arena, "expr ({s})", .{p.name}),
                    .documentation = f.description,
                });
            }
        }
    }
    return items.toOwnedSlice(arena);
}

fn completionsForExprArg(
    self: *const Self,
    arena: Allocator,
    tree: *const Ast.Tree,
    ctx: ResolvedContext,
    cursor: u32,
) Allocator.Error!?[]const CompletionItem {
    const form_idx = ctx.enclosing_form_idx orelse return null;
    const hdr = tree.formHeader(form_idx);
    const hit = switch (self.schema.lookupExprFunc(hdr.head, hdr.namespace)) {
        .found => |h| h,
        else => return null,
    };
    const arg_idx = positionalIndex(tree, hdr.children, cursor);
    const expected = expectedArgType(hit.func, arg_idx);

    var items: std.ArrayList(CompletionItem) = .empty;
    if (expected) |exp| try appendLiteralPlaceholders(self.schema, arena, &items, exp);

    for (self.schema.plugins) |p| {
        for (p.expr_funcs) |*f| {
            if (!candidateMatches(f, expected)) continue;
            const snippet = try buildExprFuncCallSnippet(arena, self.schema, f.*);
            try items.append(arena, .{
                .label = f.name,
                .kind = .function,
                .detail = try std.fmt.allocPrint(arena, "expr ({s})", .{p.name}),
                .documentation = f.description,
                .insert_text = snippet,
                .insert_text_format = .snippet,
                .filter_text = f.name,
            });
        }
    }
    const out: []const CompletionItem = try items.toOwnedSlice(arena);
    return out;
}

fn buildExprFuncCallSnippet(
    arena: Allocator,
    schema: Schema.Schema,
    func: sjon.Plugin.ExprFunc,
) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(arena, '(');
    try appendSnippetEscaped(arena, &buf, func.name);
    if (func.params) |params| {
        if (params.len == 0) {
            try buf.appendSlice(arena, " $1");
        } else {
            var tab: u32 = 1;
            for (params) |pt| {
                try buf.append(arena, ' ');
                try appendValueTypePlaceholder(arena, &buf, schema, pt, &tab);
            }
        }
    } else {
        try buf.appendSlice(arena, " $1");
    }
    try buf.append(arena, ')');
    return buf.toOwnedSlice(arena);
}

fn appendLiteralPlaceholders(
    schema: Schema.Schema,
    arena: Allocator,
    items: *std.ArrayList(CompletionItem),
    vt: sjon.Plugin.ValueType,
) Allocator.Error!void {
    switch (vt) {
        .any, .symbol => return,
        .number => try items.append(arena, .{
            .label = "0",
            .kind = .enum_member,
            .insert_text = "${1:0}",
            .insert_text_format = .snippet,
            .filter_text = "0",
        }),
        .string => try items.append(arena, .{
            .label = "\"\"",
            .kind = .enum_member,
            .insert_text = "\"${1:}\"",
            .insert_text_format = .snippet,
            .filter_text = "\"",
        }),
        .boolean => {
            try items.append(arena, .{ .label = "true", .kind = .enum_member, .filter_text = "true" });
            try items.append(arena, .{ .label = "false", .kind = .enum_member, .filter_text = "false" });
        },
        .nil => try items.append(arena, .{ .label = "nil", .kind = .enum_member, .filter_text = "nil" }),
        .vector => try items.append(arena, .{
            .label = "[]",
            .kind = .enum_member,
            .insert_text = "[${1}]",
            .insert_text_format = .snippet,
            .filter_text = "[",
        }),
        .form, .expr => try items.append(arena, .{
            .label = "()",
            .kind = .enum_member,
            .insert_text = "(${1:head})",
            .insert_text_format = .snippet,
            .filter_text = "(",
        }),
        .named => |n| switch (schema.lookupValueKind(n.name, n.namespace)) {
            .found => |k| {
                if (k.members) |m| {
                    const deprecated_tags: []const CompletionItem.Tag = &.{.deprecated};
                    for (m.members) |mem| {
                        try items.append(arena, .{
                            .label = mem.name,
                            .kind = .enum_member,
                            .detail = mem.label,
                            .documentation = mem.description,
                            .tags = if (mem.deprecated) deprecated_tags else &.{},
                            .filter_text = mem.name,
                        });
                    }
                    return;
                }
                const underlying: sjon.Plugin.ValueType = switch (k.underlying) {
                    .number => .number,
                    .string => .string,
                    .symbol => .symbol,
                    .vector => .vector,
                    .form => .form,
                    .union_of => return,
                };
                try appendLiteralPlaceholders(schema, arena, items, underlying);
            },
            else => return,
        },
    }
}

fn expectedArgType(
    func: *const sjon.Plugin.ExprFunc,
    arg_idx: usize,
) ?sjon.Plugin.ValueType {
    if (func.signatures) |sigs| {
        var agreed: ?sjon.Plugin.ValueType = null;
        var found_covering = false;
        for (sigs) |s| {
            if (!arityCoversIndex(s.arity, arg_idx)) continue;
            found_covering = true;
            const pt = s.paramType(arg_idx) orelse return null;
            if (agreed) |a| {
                if (!valueTypeEqual(a, pt)) return null;
            } else agreed = pt;
        }
        return if (found_covering) agreed else null;
    }
    if (func.params) |p| {
        if (arg_idx < p.len) return p[arg_idx];
        if (func.rest) |r| return r;
        return null;
    }
    return null;
}

fn arityCoversIndex(arity: sjon.Plugin.ExprFunc.Arity, i: usize) bool {
    return switch (arity) {
        .fixed => |k| i < k,
        .at_least => true,
        .range => |r| i < r.max,
    };
}

fn candidateMatches(
    c: *const sjon.Plugin.ExprFunc,
    expected: ?sjon.Plugin.ValueType,
) bool {
    const exp = expected orelse return true;
    if (exp == .any) return true;
    if (c.signatures) |sigs| {
        for (sigs) |s| {
            const r = s.result orelse return true;
            if (r == .any) return true;
            if (valueTypeEqual(r, exp)) return true;
        }
        return false;
    }
    const r = c.result orelse return true;
    if (r == .any) return true;
    return valueTypeEqual(r, exp);
}

fn valueTypeEqual(a: sjon.Plugin.ValueType, b: sjon.Plugin.ValueType) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .named => |n| qualifiedRefEql(n, b.named),
        else => true,
    };
}

fn qualifiedRefEql(a: sjon.Plugin.QualifiedRef, b: sjon.Plugin.QualifiedRef) bool {
    if (!std.mem.eql(u8, a.name, b.name)) return false;
    if (a.namespace == null and b.namespace == null) return true;
    if (a.namespace == null or b.namespace == null) return false;
    return std.mem.eql(u8, a.namespace.?, b.namespace.?);
}

fn buildFormSnippet(
    arena: Allocator,
    schema: Schema.Schema,
    form: sjon.Plugin.FormSpec,
) Allocator.Error!?[]const u8 {
    if (!hasRequiredKey(form)) return null;

    var buf: std.ArrayList(u8) = .empty;
    try appendSnippetEscaped(arena, &buf, form.name);
    var tab: u32 = 1;
    try appendFormBody(arena, &buf, schema, form, &tab);
    try buf.appendSlice(arena, "$0");
    return try buf.toOwnedSlice(arena);
}

fn buildFormValueSnippet(
    arena: Allocator,
    schema: Schema.Schema,
    form: sjon.Plugin.FormSpec,
) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(arena, '(');
    try appendSnippetEscaped(arena, &buf, form.name);
    var tab: u32 = 1;
    try appendFormBody(arena, &buf, schema, form, &tab);
    try buf.appendSlice(arena, "$0)");
    return buf.toOwnedSlice(arena);
}

fn appendFormBody(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    schema: Schema.Schema,
    form: sjon.Plugin.FormSpec,
    tab: *u32,
) Allocator.Error!void {
    for (form.keys) |k| {
        if (k.effectiveOptional()) continue;
        try buf.appendSlice(arena, " :");
        try appendSnippetEscaped(arena, buf, k.name);
        try buf.append(arena, ' ');
        try appendValueTypePlaceholder(arena, buf, schema, k.value_type, tab);
    }
}

fn hasRequiredKey(form: sjon.Plugin.FormSpec) bool {
    for (form.keys) |k| {
        if (!k.effectiveOptional()) return true;
    }
    return false;
}

fn appendSnippetEscaped(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    text: []const u8,
) Allocator.Error!void {
    for (text) |c| {
        if (c == '$' or c == '}' or c == '\\') try buf.append(arena, '\\');
        try buf.append(arena, c);
    }
}

fn appendValueTypePlaceholder(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    schema: Schema.Schema,
    vt: sjon.Plugin.ValueType,
    tab: *u32,
) Allocator.Error!void {
    const n = tab.*;
    tab.* += 1;
    const piece = switch (vt) {
        .string => try std.fmt.allocPrint(arena, "\"${d}\"", .{n}),
        .number => try std.fmt.allocPrint(arena, "${{{d}:0}}", .{n}),
        .boolean => try std.fmt.allocPrint(arena, "${{{d}|true,false|}}", .{n}),
        .symbol => try std.fmt.allocPrint(arena, "${{{d}:symbol}}", .{n}),
        .nil => try std.fmt.allocPrint(arena, "${{{d}:nil}}", .{n}),
        .vector => try std.fmt.allocPrint(arena, "[${d}]", .{n}),
        .form, .expr => try std.fmt.allocPrint(arena, "(${d})", .{n}),
        .any => try std.fmt.allocPrint(arena, "${d}", .{n}),
        .named => |ref| {
            if (schema.lookupValueKind(ref.name, ref.namespace) == .found) {
                const kind = schema.lookupValueKind(ref.name, ref.namespace).found;
                if (kind.unit) |u| if (u.allowed.len > 0) {
                    const unit_tab = tab.*;
                    tab.* += 1;
                    try buf.appendSlice(
                        arena,
                        try std.fmt.allocPrint(arena, "${{{d}:0}}", .{n}),
                    );
                    try buf.appendSlice(
                        arena,
                        try std.fmt.allocPrint(arena, "${{{d}:", .{unit_tab}),
                    );
                    try appendSnippetEscaped(arena, buf, u.allowed[0]);
                    try buf.append(arena, '}');
                    return;
                };
            }
            try buf.appendSlice(arena, try std.fmt.allocPrint(arena, "${{{d}:", .{n}));
            try appendSnippetEscaped(arena, buf, ref.name);
            try buf.append(arena, '}');
            return;
        },
    };
    try buf.appendSlice(arena, piece);
}

fn completionsForKeywordKey(
    self: *const Self,
    arena: Allocator,
    tree: *const Ast.Tree,
    cursor: u32,
) Allocator.Error![]const CompletionItem {
    const enclosing = findEnclosingForm(tree, cursor) orelse return &.{};
    const lookup = self.schema.lookupForm(enclosing.head, enclosing.namespace);
    const hit = switch (lookup) {
        .found => |h| h,
        else => return &.{},
    };

    var present: std.StringHashMapUnmanaged(void) = .empty;
    const tags = tree.nodes.items(.tag);
    for (enclosing.children) |child| {
        if (tags[@intFromEnum(child)] != .kvpair) continue;
        const kv = tree.kvpairHeader(child);
        try present.put(arena, kv.key, {});
    }

    var active_variant: ?*const sjon.Plugin.Variant = null;
    if (hit.form.discriminant_name) |disc_name| {
        if (findKvpairSymbolValue(tree, enclosing, disc_name)) |value| {
            if (hit.form.variants) |variants| {
                for (variants) |*v| {
                    if (std.mem.eql(u8, v.when, value)) {
                        active_variant = v;
                        break;
                    }
                }
            }
        }
    }

    var excluded: std.StringHashMapUnmanaged(void) = .empty;
    for (hit.form.exclusive_groups) |grp| try excludeGroupIfTriggered(&excluded, arena, grp, present);
    if (active_variant) |v| {
        for (v.exclusive_groups) |grp| try excludeGroupIfTriggered(&excluded, arena, grp, present);
    }

    const variant_keys_len: usize = if (active_variant) |v| v.keys.len else 0;
    var items: std.ArrayList(CompletionItem) = .empty;
    try items.ensureTotalCapacity(arena, hit.form.keys.len + variant_keys_len);

    try appendKeyCandidates(arena, &items, hit.form.keys, present, excluded);
    if (active_variant) |v| try appendKeyCandidates(arena, &items, v.keys, present, excluded);

    return items.toOwnedSlice(arena);
}

fn excludeGroupIfTriggered(
    excluded: *std.StringHashMapUnmanaged(void),
    arena: Allocator,
    grp: sjon.Plugin.ExclusiveGroup,
    present: std.StringHashMapUnmanaged(void),
) Allocator.Error!void {
    var any_present = false;
    for (grp.alternatives) |alt| {
        for (alt.keys) |k| {
            if (present.contains(k)) {
                any_present = true;
                break;
            }
        }
        if (any_present) break;
    }
    if (!any_present) return;
    for (grp.alternatives) |alt| {
        for (alt.keys) |k| {
            if (!present.contains(k)) try excluded.put(arena, k, {});
        }
    }
}

fn appendKeyCandidates(
    arena: Allocator,
    items: *std.ArrayList(CompletionItem),
    keys: []const sjon.Plugin.KeySpec,
    present: std.StringHashMapUnmanaged(void),
    excluded: std.StringHashMapUnmanaged(void),
) Allocator.Error!void {
    for (keys) |k| {
        if (present.contains(k.name)) continue;
        if (excluded.contains(k.name)) continue;
        const sort_prefix: u8 = if (k.effectiveOptional()) '1' else '0';
        try items.append(arena, .{
            .label = k.name,
            .kind = .field,
            .detail = try keyDetail(arena, k),
            .documentation = k.description,
            .sort_text = try std.fmt.allocPrint(arena, "{c}_{s}", .{ sort_prefix, k.name }),
            .filter_text = k.name,
        });
    }
}

fn findKvpairSymbolValue(
    tree: *const Ast.Tree,
    form: Ast.FormHeader,
    key_name: []const u8,
) ?[]const u8 {
    const tags = tree.nodes.items(.tag);
    for (form.children) |child| {
        if (tags[@intFromEnum(child)] != .kvpair) continue;
        const kv = tree.kvpairHeader(child);
        if (!std.mem.eql(u8, kv.key, key_name)) continue;
        if (tags[@intFromEnum(kv.value)] != .symbol) return null;
        return tree.symbolText(kv.value);
    }
    return null;
}

fn completionsForKvpairValue(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    doc: *const Document,
    cursor: u32,
) Allocator.Error![]const CompletionItem {
    const enclosing_form_idx = findEnclosingFormIdx(&doc.tree, cursor) orelse return &.{};
    const enclosing = doc.tree.formHeader(enclosing_form_idx);
    const lookup = self.schema.lookupForm(enclosing.head, enclosing.namespace);
    const hit = switch (lookup) {
        .found => |h| h,
        else => return &.{},
    };
    const key_name = findEnclosingKvpairKey(doc.source, cursor) orelse return &.{};

    var key_value_type: ?sjon.Plugin.ValueType = null;
    for (hit.form.keys) |k| {
        if (std.mem.eql(u8, k.name, key_name)) {
            key_value_type = k.value_type;
            break;
        }
    }
    const vt = key_value_type orelse return &.{};

    switch (vt) {
        .boolean => return try literalSet(arena, &.{ "true", "false" }),
        .nil => return try literalSet(arena, &.{"nil"}),
        else => {},
    }

    const named = switch (vt) {
        .named => |n| n,
        else => return &.{},
    };
    const kind_lookup = self.schema.lookupValueKind(named.name, named.namespace);
    const kind = switch (kind_lookup) {
        .found => |k| k,
        else => return &.{},
    };

    if (kind.cross_ref) |xref| {
        return self.completionsForCrossRef(arena, uri, doc, enclosing_form_idx, xref);
    }

    if (kind.underlying == .number) {
        if (kind.unit) |u| if (u.allowed.len > 0) {
            if (findKvpairValueByKey(&doc.tree, enclosing, key_name)) |value_idx| {
                return try unitSuffixCompletions(arena, &doc.tree, value_idx, u.allowed, cursor);
            }
        };
    }

    if (kind.underlying == .string) {
        if (kind.string_bounds) |sb| if (sb.format) |fmt| {
            return try stringFormatSnippet(arena, fmt);
        };
    }

    if (kind.underlying == .form) {
        if (kind.heads) |hs| if (hs.names.len > 0) {
            return self.completionsForFormValuedSlot(arena, hs.names);
        };
    }

    const m = kind.members orelse return &.{};
    if (m.members.len == 0) return &.{};

    var items: std.ArrayList(CompletionItem) = .empty;
    try items.ensureTotalCapacity(arena, m.members.len);
    const deprecated_tags: []const CompletionItem.Tag = &.{.deprecated};
    for (m.members) |mem| {
        items.appendAssumeCapacity(.{
            .label = mem.name,
            .kind = .enum_member,
            .detail = mem.label,
            .documentation = mem.description,
            .tags = if (mem.deprecated) deprecated_tags else &.{},
        });
    }
    return items.toOwnedSlice(arena);
}

fn completionsForVectorElement(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    doc: *const Document,
    cursor: u32,
    ctx: ResolvedContext,
) Allocator.Error![]const CompletionItem {
    const form_idx = ctx.enclosing_form_idx orelse return &.{};
    const tree = &doc.tree;
    const tags = tree.nodes.items(.tag);
    const vec_idx = findEnclosingVectorIdx(tree, cursor) orelse return &.{};

    const form_header = tree.formHeader(form_idx);
    var owning_key: ?[]const u8 = null;
    for (form_header.children) |child| {
        if (tags[@intFromEnum(child)] != .kvpair) continue;
        const kv = tree.kvpairHeader(child);
        if (@intFromEnum(kv.value) == @intFromEnum(vec_idx)) {
            owning_key = kv.key;
            break;
        }
    }
    const key_name = owning_key orelse return &.{};

    const lookup = self.schema.lookupForm(form_header.head, form_header.namespace);
    const hit = switch (lookup) {
        .found => |h| h,
        else => return &.{},
    };
    var key_value_type: ?sjon.Plugin.ValueType = null;
    for (hit.form.keys) |k| {
        if (std.mem.eql(u8, k.name, key_name)) {
            key_value_type = k.value_type;
            break;
        }
    }
    const vt = key_value_type orelse return &.{};
    const named = switch (vt) {
        .named => |n| n,
        else => return &.{},
    };
    const vec_kind = switch (self.schema.lookupValueKind(named.name, named.namespace)) {
        .found => |k| k,
        else => return &.{},
    };
    const vec_shape = vec_kind.vector orelse return &.{};

    const elem_kind = switch (self.schema.lookupValueKind(vec_shape.element.name, vec_shape.element.namespace)) {
        .found => |k| k,
        else => return &.{},
    };

    if (elem_kind.cross_ref) |xref| {
        return self.completionsForCrossRef(arena, uri, doc, form_idx, xref);
    }

    if (elem_kind.underlying == .number) {
        if (elem_kind.unit) |u| if (u.allowed.len > 0) {
            for (tree.vectorElements(vec_idx)) |elem_idx| {
                if (tree.spanOf(elem_idx).end == cursor) {
                    return try unitSuffixCompletions(arena, tree, elem_idx, u.allowed, cursor);
                }
            }
            return &.{};
        };
    }

    const m = elem_kind.members orelse return &.{};
    if (m.members.len == 0) return &.{};

    var items: std.ArrayList(CompletionItem) = .empty;
    try items.ensureTotalCapacity(arena, m.members.len);
    const deprecated_tags: []const CompletionItem.Tag = &.{.deprecated};
    for (m.members) |mem| {
        items.appendAssumeCapacity(.{
            .label = mem.name,
            .kind = .enum_member,
            .detail = mem.label,
            .documentation = mem.description,
            .tags = if (mem.deprecated) deprecated_tags else &.{},
        });
    }
    return items.toOwnedSlice(arena);
}

fn literalSet(
    arena: Allocator,
    literals: []const []const u8,
) Allocator.Error![]const CompletionItem {
    var items: std.ArrayList(CompletionItem) = .empty;
    try items.ensureTotalCapacity(arena, literals.len);
    for (literals) |lit| {
        items.appendAssumeCapacity(.{
            .label = lit,
            .kind = .enum_member,
            .filter_text = lit,
        });
    }
    return items.toOwnedSlice(arena);
}

fn stringFormatSnippet(
    arena: Allocator,
    format: sjon.Plugin.ValueKind.StringBounds.Format,
) Allocator.Error![]const CompletionItem {
    const template: []const u8 = switch (format) {
        .email => "\"${1:user@example.com}\"",
        .uri => "\"${1:https://}\"",
        .path => "\"${1:./path}\"",
        .uuid => "\"${1:00000000-0000-0000-0000-000000000000}\"",
        .semver => "\"${1:1.0.0}\"",
    };
    const label: []const u8 = switch (format) {
        .email => "email",
        .uri => "URI",
        .path => "path",
        .uuid => "UUID",
        .semver => "semver",
    };
    const items = try arena.alloc(CompletionItem, 1);
    items[0] = .{
        .label = label,
        .kind = .enum_member,
        .detail = try std.fmt.allocPrint(arena, "string ({s})", .{label}),
        .insert_text = try arena.dupe(u8, template),
        .insert_text_format = .snippet,
        .filter_text = label,
    };
    return items;
}

fn completionsForFormValuedSlot(
    self: *const Self,
    arena: Allocator,
    head_names: []const []const u8,
) Allocator.Error![]const CompletionItem {
    var items: std.ArrayList(CompletionItem) = .empty;
    try items.ensureTotalCapacity(arena, head_names.len);
    for (head_names) |raw_name| {
        var ns: ?[]const u8 = null;
        var name = raw_name;
        if (std.mem.indexOfScalar(u8, raw_name, '/')) |slash| {
            ns = raw_name[0..slash];
            name = raw_name[slash + 1 ..];
        }
        const snippet = switch (self.schema.lookupForm(name, ns)) {
            .found => |h| try buildFormValueSnippet(arena, self.schema, h.form.*),
            else => try std.fmt.allocPrint(arena, "({s} $0)", .{raw_name}),
        };
        const detail: []const u8 = switch (self.schema.lookupForm(name, ns)) {
            .found => |h| try std.fmt.allocPrint(arena, "form ({s})", .{h.plugin.name}),
            else => "",
        };
        const documentation: []const u8 = switch (self.schema.lookupForm(name, ns)) {
            .found => |h| h.form.description,
            else => "",
        };
        items.appendAssumeCapacity(.{
            .label = raw_name,
            .kind = .constructor,
            .detail = detail,
            .documentation = documentation,
            .insert_text = snippet,
            .insert_text_format = .snippet,
            .filter_text = raw_name,
        });
    }
    return items.toOwnedSlice(arena);
}

fn completionsForCrossRef(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    doc: *const Document,
    enclosing_form_idx: Ast.NodeIndex,
    xref: sjon.Plugin.ValueKind.CrossRef,
) Allocator.Error![]const CompletionItem {
    const xri = self.cross_ref_index orelse return &.{};
    const tree_idx = self.uri_to_tree_idx.get(uri) orelse return &.{};
    const enclosing = doc.tree.formHeader(enclosing_form_idx);

    var target_ns: ?[]const u8 = null;
    var target_name = xref.target_form;
    if (std.mem.indexOfScalar(u8, xref.target_form, '/')) |slash| {
        target_ns = xref.target_form[0..slash];
        target_name = xref.target_form[slash + 1 ..];
    }
    const target_hit = switch (self.schema.lookupForm(target_name, target_ns)) {
        .found => |h| h,
        else => return &.{},
    };
    const canonical_target = try std.fmt.allocPrint(
        arena,
        "{s}/{s}",
        .{ target_hit.plugin.name, target_hit.form.name },
    );

    const scope: Validator.ScopeId = blk: {
        const sf_raw = xref.scope_form orelse break :blk .tree(tree_idx);
        const canon_scope = (try self.canonicaliseFormHead(arena, sf_raw, null)) orelse return &.{};
        const scope_form_idx = (try self.findEnclosingScopeFormIdx(arena, &doc.tree, enclosing_form_idx, canon_scope)) orelse return &.{};
        break :blk .lexical(tree_idx, @intFromEnum(scope_form_idx));
    };

    var self_name: ?[]const u8 = null;
    const enc_lookup = self.schema.lookupForm(enclosing.head, enclosing.namespace);
    if (enc_lookup == .found) {
        const enc_hit = enc_lookup.found;
        if (enc_hit.plugin == target_hit.plugin and enc_hit.form == target_hit.form) {
            self_name = findKvpairValueText(doc, enclosing, xref.name_key);
        }
    }

    var items: std.ArrayList(CompletionItem) = .empty;
    var it = xri.iterateNames(scope, canonical_target);
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (self_name) |s| if (std.mem.eql(u8, s, name)) continue;
        try items.append(arena, .{
            .label = name,
            .kind = .enum_member,
            .detail = try std.fmt.allocPrint(arena, "ref → {s}", .{canonical_target}),
        });
    }
    return items.toOwnedSlice(arena);
}

fn findKvpairValueText(
    doc: *const Document,
    enclosing: Ast.FormHeader,
    key_name: []const u8,
) ?[]const u8 {
    const tree = &doc.tree;
    const tags = tree.nodes.items(.tag);
    for (enclosing.children) |child| {
        if (tags[@intFromEnum(child)] != .kvpair) continue;
        const kv = tree.kvpairHeader(child);
        if (!std.mem.eql(u8, kv.key, key_name)) continue;
        if (tags[@intFromEnum(kv.value)] != .symbol) return null;
        const v_span = tree.spanOf(kv.value);
        return doc.source[v_span.start..v_span.end];
    }
    return null;
}

fn findKvpairValueByKey(
    tree: *const Ast.Tree,
    enclosing: Ast.FormHeader,
    key_name: []const u8,
) ?Ast.NodeIndex {
    const tags = tree.nodes.items(.tag);
    for (enclosing.children) |child| {
        if (tags[@intFromEnum(child)] != .kvpair) continue;
        const kv = tree.kvpairHeader(child);
        if (std.mem.eql(u8, kv.key, key_name)) return kv.value;
    }
    return null;
}

fn unitSuffixCompletions(
    arena: Allocator,
    tree: *const Ast.Tree,
    value_idx: Ast.NodeIndex,
    units: []const []const u8,
    cursor: u32,
) Allocator.Error![]const CompletionItem {
    switch (tree.tagOf(value_idx)) {
        .number, .number_i64, .number_u64 => {},
        else => return &.{},
    }
    if (tree.spanOf(value_idx).end != cursor) return &.{};

    var items: std.ArrayList(CompletionItem) = .empty;
    try items.ensureTotalCapacity(arena, units.len);
    for (units) |u| {
        items.appendAssumeCapacity(.{
            .label = u,
            .kind = .enum_member,
            .detail = "unit suffix",
            .insert_text = u,
            .filter_text = u,
        });
    }
    return items.toOwnedSlice(arena);
}

fn keyDetail(arena: Allocator, key: sjon.Plugin.KeySpec) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try appendValueType(arena, &buf, key.value_type);
    if (!key.effectiveOptional()) try buf.appendSlice(arena, " (required)");
    return buf.toOwnedSlice(arena);
}

pub fn getSignatureHelp(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    byte_offset: u32,
) Allocator.Error!?SignatureHelp {
    const doc = self.getDocument(uri) orelse return null;
    const idx = findEnclosingFormIdx(&doc.tree, byte_offset) orelse return null;
    const hdr = doc.tree.formHeader(idx);
    if (hdr.head.len == 0) return null;
    if (containsOffset(hdr.head_span, byte_offset)) return null;

    switch (self.schema.lookupForm(hdr.head, hdr.namespace)) {
        .found => |hit| return try buildFormSignature(arena, hit, &doc.tree, hdr, byte_offset),
        else => {},
    }
    switch (self.schema.lookupExprFunc(hdr.head, hdr.namespace)) {
        .found => |hit| return try buildExprSignature(arena, hit, &doc.tree, hdr, byte_offset),
        else => return null,
    }
}

fn buildFormSignature(
    arena: Allocator,
    hit: Schema.FormHit,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    cursor: u32,
) Allocator.Error!SignatureHelp {
    var label: std.ArrayList(u8) = .empty;
    try appendQualifiedHead(arena, &label, hdr.namespace, hit.form.name);

    var params = try arena.alloc(Parameter, hit.form.keys.len);
    for (hit.form.keys, 0..) |k, i| {
        try label.append(arena, ' ');
        const start: u32 = @intCast(label.items.len);
        try label.append(arena, ':');
        try label.appendSlice(arena, k.name);
        if (k.effectiveOptional()) try label.append(arena, '?');
        try label.append(arena, ' ');
        try appendValueType(arena, &label, k.value_type);
        params[i] = .{ .label_start = start, .label_end = @intCast(label.items.len) };
    }

    const active = activeKeyIndex(tree, hdr, hit.form.keys, cursor);

    const sigs = try arena.alloc(Signature, 1);
    sigs[0] = .{
        .label = try label.toOwnedSlice(arena),
        .documentation = hit.form.description,
        .parameters = params,
    };
    return .{ .signatures = sigs, .active_signature = 0, .active_parameter = active };
}

fn buildExprSignature(
    arena: Allocator,
    hit: Schema.ExprHit,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    cursor: u32,
) Allocator.Error!SignatureHelp {
    var label: std.ArrayList(u8) = .empty;
    try appendQualifiedHead(arena, &label, hdr.namespace, hit.func.name);

    const fixed = hit.func.params orelse &.{};
    var params = try arena.alloc(Parameter, fixed.len + @intFromBool(hit.func.rest != null));
    for (fixed, 0..) |p, i| {
        try label.append(arena, ' ');
        const start: u32 = @intCast(label.items.len);
        try appendValueType(arena, &label, p);
        params[i] = .{ .label_start = start, .label_end = @intCast(label.items.len) };
    }
    if (hit.func.rest) |r| {
        try label.append(arena, ' ');
        const start: u32 = @intCast(label.items.len);
        try label.appendSlice(arena, "...");
        try appendValueType(arena, &label, r);
        params[fixed.len] = .{ .label_start = start, .label_end = @intCast(label.items.len) };
    }
    if (params.len == 0) try label.appendSlice(arena, " …");

    const active: ?u32 = blk: {
        if (params.len == 0) break :blk null;
        const arg_idx = positionalIndex(tree, hdr.children, cursor);
        if (arg_idx < fixed.len) break :blk @intCast(arg_idx);
        if (hit.func.rest != null) break :blk @intCast(fixed.len);
        break :blk null;
    };

    const sigs = try arena.alloc(Signature, 1);
    sigs[0] = .{
        .label = try label.toOwnedSlice(arena),
        .documentation = hit.func.description,
        .parameters = params,
    };
    return .{ .signatures = sigs, .active_signature = 0, .active_parameter = active };
}

fn appendQualifiedHead(
    arena: Allocator,
    buf: *std.ArrayList(u8),
    namespace: ?[]const u8,
    name: []const u8,
) Allocator.Error!void {
    if (namespace) |ns| {
        try buf.appendSlice(arena, ns);
        try buf.append(arena, '/');
    }
    try buf.appendSlice(arena, name);
}

fn activeKeyIndex(
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    keys: []const sjon.Plugin.KeySpec,
    cursor: u32,
) ?u32 {
    for (hdr.children) |c_idx| {
        if (tree.tagOf(c_idx) != .kvpair) continue;
        const span = tree.spanOf(c_idx);
        if (cursor < span.start) return null;
        if (cursor >= span.end) continue;
        const kv = tree.kvpairHeader(c_idx);
        for (keys, 0..) |k, i| {
            if (std.mem.eql(u8, k.name, kv.key)) return @intCast(i);
        }
        return null;
    }
    return null;
}

fn positionalIndex(tree: *const Ast.Tree, children: []const Ast.NodeIndex, cursor: u32) usize {
    var i: usize = 0;
    for (children) |c| {
        const span = tree.spanOf(c);
        if (cursor < span.start) break;
        if (cursor < span.end) break;
        i += 1;
    }
    return i;
}

fn findEnclosingForm(tree: *const Ast.Tree, pos: u32) ?Ast.FormHeader {
    if (findEnclosingFormIdx(tree, pos)) |idx| return tree.formHeader(idx);
    return null;
}

fn findEnclosingFormIdx(tree: *const Ast.Tree, pos: u32) ?Ast.NodeIndex {
    var best: ?Ast.NodeIndex = null;
    var best_size: u32 = std.math.maxInt(u32);
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tags.len) : (i += 1) {
        if (tags[i] != .form) continue;
        const idx = Ast.NodeIndex.from(i);
        const span = tree.spanOf(idx);
        if (pos < span.start or pos >= span.end) continue;
        const size = span.end - span.start;
        if (size < best_size) {
            best = idx;
            best_size = size;
        }
    }
    return best;
}

fn findParentFormIdx(tree: *const Ast.Tree, child: Ast.NodeIndex) ?Ast.NodeIndex {
    const child_span = tree.spanOf(child);
    var best: ?Ast.NodeIndex = null;
    var best_size: u32 = std.math.maxInt(u32);
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tags.len) : (i += 1) {
        if (tags[i] != .form) continue;
        const idx = Ast.NodeIndex.from(i);
        if (@intFromEnum(idx) == @intFromEnum(child)) continue;
        const span = tree.spanOf(idx);
        if (span.start > child_span.start or span.end < child_span.end) continue;
        const size = span.end - span.start;
        if (size < best_size) {
            best = idx;
            best_size = size;
        }
    }
    return best;
}

fn canonicaliseFormHead(
    self: *const Self,
    arena: Allocator,
    head: []const u8,
    namespace: ?[]const u8,
) Allocator.Error!?[]const u8 {
    var ns = namespace;
    var name = head;
    if (ns == null) {
        if (std.mem.indexOfScalar(u8, head, '/')) |slash| {
            ns = head[0..slash];
            name = head[slash + 1 ..];
        }
    }
    const hit = switch (self.schema.lookupForm(name, ns)) {
        .found => |h| h,
        else => return null,
    };
    return try std.fmt.allocPrint(arena, "{s}/{s}", .{ hit.plugin.name, hit.form.name });
}

fn findEnclosingScopeFormIdx(
    self: *const Self,
    arena: Allocator,
    tree: *const Ast.Tree,
    start: Ast.NodeIndex,
    canonical_scope: []const u8,
) Allocator.Error!?Ast.NodeIndex {
    var cur: ?Ast.NodeIndex = start;
    while (cur) |idx| {
        const hdr = tree.formHeader(idx);
        if (try self.canonicaliseFormHead(arena, hdr.head, hdr.namespace)) |canon| {
            if (std.mem.eql(u8, canon, canonical_scope)) return idx;
        }
        cur = findParentFormIdx(tree, idx);
    }
    return null;
}

fn findKvpairByKeySpan(tree: *const Ast.Tree, key_span: Ast.Span) ?Ast.NodeIndex {
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tags.len) : (i += 1) {
        if (tags[i] != .kvpair) continue;
        const idx = Ast.NodeIndex.from(i);
        const kvh = tree.kvpairHeader(idx);
        if (kvh.key_span.start == key_span.start and kvh.key_span.end == key_span.end) {
            return idx;
        }
    }
    return null;
}

pub fn getFormatEdits(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
) Allocator.Error!?[]const TextEdit {
    const doc = self.getDocument(uri) orelse return null;
    if (doc.tree.hasErrors()) return null;

    const printed = try sjon.Printer.print(arena, doc.tree, .{ .mode = .full });
    const edits = try arena.alloc(TextEdit, 1);
    edits[0] = .{
        .span_start = 0,
        .span_end = @intCast(doc.source.len),
        .new_text = printed.data,
    };
    return edits;
}

pub fn getDocumentSymbols(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
) Allocator.Error!?[]const DocumentSymbol {
    const doc = self.getDocument(uri) orelse return null;

    var roots: std.ArrayList(DocumentSymbol) = .empty;
    for (doc.tree.root) |idx| {
        try appendSymbols(arena, &doc.tree, idx, &roots);
    }
    const out: []const DocumentSymbol = try roots.toOwnedSlice(arena);
    return out;
}

fn appendSymbols(
    arena: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    out: *std.ArrayList(DocumentSymbol),
) Allocator.Error!void {
    switch (tree.tagOf(idx)) {
        .form => {
            const hdr = tree.formHeader(idx);
            const name = if (hdr.namespace) |ns|
                try std.fmt.allocPrint(arena, "{s}/{s}", .{ ns, hdr.head })
            else
                try arena.dupe(u8, hdr.head);
            var children: std.ArrayList(DocumentSymbol) = .empty;
            for (hdr.children) |c| try appendSymbols(arena, tree, c, &children);
            const span = tree.spanOf(idx);
            try out.append(arena, .{
                .name = name,
                .span_start = span.start,
                .span_end = span.end,
                .selection_start = hdr.head_span.start,
                .selection_end = hdr.head_span.end,
                .children = try children.toOwnedSlice(arena),
            });
        },
        .kvpair => {
            const kv = tree.kvpairHeader(idx);
            try appendSymbols(arena, tree, kv.value, out);
        },
        .vector => {
            for (tree.vectorElements(idx)) |el| try appendSymbols(arena, tree, el, out);
        },
        else => {},
    }
}

pub fn getFoldingRanges(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
) Allocator.Error!?[]const FoldingRange {
    const doc = self.getDocument(uri) orelse return null;
    var out: std.ArrayList(FoldingRange) = .empty;
    for (doc.tree.root) |idx| try appendFolds(arena, &doc.tree, idx, &out);
    return try out.toOwnedSlice(arena);
}

fn appendFolds(
    arena: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    out: *std.ArrayList(FoldingRange),
) Allocator.Error!void {
    switch (tree.tagOf(idx)) {
        .form => {
            const span = tree.spanOf(idx);
            try out.append(arena, .{ .span_start = span.start, .span_end = span.end });
            const hdr = tree.formHeader(idx);
            for (hdr.children) |c| try appendFolds(arena, tree, c, out);
        },
        .vector => {
            const span = tree.spanOf(idx);
            try out.append(arena, .{ .span_start = span.start, .span_end = span.end });
            for (tree.vectorElements(idx)) |el| try appendFolds(arena, tree, el, out);
        },
        .kvpair => {
            const kv = tree.kvpairHeader(idx);
            try appendFolds(arena, tree, kv.value, out);
        },
        else => {},
    }
}

pub fn getInlayHints(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    range_start: u32,
    range_end: u32,
) Allocator.Error!?[]const InlayHint {
    const doc = self.getDocument(uri) orelse return null;
    var out: std.ArrayList(InlayHint) = .empty;
    for (doc.tree.root) |idx| try self.appendInlayHints(arena, &doc.tree, idx, range_start, range_end, &out);
    return try out.toOwnedSlice(arena);
}

fn appendInlayHints(
    self: *const Self,
    arena: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    range_start: u32,
    range_end: u32,
    out: *std.ArrayList(InlayHint),
) Allocator.Error!void {
    switch (tree.tagOf(idx)) {
        .form => {
            const hdr = tree.formHeader(idx);
            try self.maybeAppendHeadHint(arena, hdr, range_start, range_end, out);
            for (hdr.children) |c| try self.appendInlayHints(arena, tree, c, range_start, range_end, out);
        },
        .vector => {
            for (tree.vectorElements(idx)) |el| try self.appendInlayHints(arena, tree, el, range_start, range_end, out);
        },
        .kvpair => {
            const kv = tree.kvpairHeader(idx);
            try self.appendInlayHints(arena, tree, kv.value, range_start, range_end, out);
        },
        else => {},
    }
}

fn maybeAppendHeadHint(
    self: *const Self,
    arena: Allocator,
    hdr: Ast.FormHeader,
    range_start: u32,
    range_end: u32,
    out: *std.ArrayList(InlayHint),
) Allocator.Error!void {
    if (hdr.head.len == 0) return;
    if (hdr.namespace != null) return;
    if (!spanOverlaps(hdr.head_span, range_start, range_end)) return;

    const plugin: *const sjon.Plugin.Plugin = blk: {
        switch (self.schema.lookupForm(hdr.head, null)) {
            .found => |hit| break :blk hit.plugin,
            else => {},
        }
        switch (self.schema.lookupExprFunc(hdr.head, null)) {
            .found => |hit| break :blk hit.plugin,
            else => return,
        }
    };
    if (std.mem.eql(u8, plugin.name, "core")) return;

    try out.append(arena, .{
        .offset = hdr.head_span.end,
        .label = plugin.name,
        .padding_left = true,
    });
}

pub fn getCodeActions(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    range_start: u32,
    range_end: u32,
) Allocator.Error!?[]const CodeAction {
    const doc = self.getDocument(uri) orelse return null;

    var actions: std.ArrayList(CodeAction) = .empty;
    var seen_missing_forms: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (doc.tree.diagnostics) |d| {
        if (!spanOverlaps(d.span, range_start, range_end)) continue;
        try self.appendActionsFor(arena, uri, doc, d, &actions, &seen_missing_forms);
    }
    for (doc.validate_result.diagnostics) |d| {
        if (!spanOverlaps(d.span, range_start, range_end)) continue;
        try self.appendActionsFor(arena, uri, doc, d, &actions, &seen_missing_forms);
    }
    const out: []const CodeAction = try actions.toOwnedSlice(arena);
    return out;
}

fn spanOverlaps(span: Ast.Span, range_start: u32, range_end: u32) bool {
    return span.start < range_end and span.end > range_start;
}

fn appendActionsFor(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    doc: *const Document,
    d: Ast.Diagnostic,
    out: *std.ArrayList(CodeAction),
    seen_missing_forms: *std.AutoHashMapUnmanaged(u32, void),
) Allocator.Error!void {
    switch (d.code) {
        .unknown_form => try self.appendUnknownFormFix(arena, doc, d, out),
        .unknown_key => try self.appendUnknownKeyFix(arena, doc, d, out),
        .ambiguous_form => try self.appendAmbiguousFormFix(arena, doc, d, out),
        .missing_required_key => try self.appendMissingRequiredKeyFix(arena, doc, d, out, seen_missing_forms),
        .expr_kvpair_not_allowed => try appendExprKvpairFix(arena, doc, d, out),
        .duplicate_key => try appendDuplicateKeyFix(arena, doc, d, out),
        .not_cross_ref, .cross_ref_outside_scope => try self.appendCrossRefFix(arena, uri, doc, d, out),
        .not_member => try self.appendNotMemberFix(arena, doc, d, out),
        else => {},
    }
}

fn appendUnknownFormFix(
    self: *const Self,
    arena: Allocator,
    doc: *const Document,
    d: Ast.Diagnostic,
    out: *std.ArrayList(CodeAction),
) Allocator.Error!void {
    const bad = doc.source[d.span.start..d.span.end];
    const suggestion = self.closestFormName(bad) orelse return;

    const edits = try arena.alloc(TextEdit, 1);
    edits[0] = .{
        .span_start = d.span.start,
        .span_end = d.span.end,
        .new_text = suggestion,
    };
    const title = try std.fmt.allocPrint(arena, "Replace with `{s}`", .{suggestion});
    const codes = try arena.alloc([]const u8, 1);
    codes[0] = @tagName(d.code);
    try out.append(arena, .{
        .title = title,
        .edits = edits,
        .diagnostic_codes = codes,
    });
}

fn appendUnknownKeyFix(
    self: *const Self,
    arena: Allocator,
    doc: *const Document,
    d: Ast.Diagnostic,
    out: *std.ArrayList(CodeAction),
) Allocator.Error!void {
    if (d.span.end <= d.span.start + 1) return;
    const bad_with_colon = doc.source[d.span.start..d.span.end];
    if (bad_with_colon[0] != ':') return;
    const bad = bad_with_colon[1..];

    const enclosing = findEnclosingForm(&doc.tree, d.span.start) orelse return;
    const lookup = self.schema.lookupForm(enclosing.head, enclosing.namespace);
    const hit = switch (lookup) {
        .found => |h| h,
        else => return,
    };
    const suggestion = closestKeyName(bad, hit.form.keys) orelse return;

    const new_text = try std.fmt.allocPrint(arena, ":{s}", .{suggestion});
    const edits = try arena.alloc(TextEdit, 1);
    edits[0] = .{
        .span_start = d.span.start,
        .span_end = d.span.end,
        .new_text = new_text,
    };
    const title = try std.fmt.allocPrint(arena, "Replace with `:{s}`", .{suggestion});
    const codes = try arena.alloc([]const u8, 1);
    codes[0] = @tagName(d.code);
    try out.append(arena, .{
        .title = title,
        .edits = edits,
        .diagnostic_codes = codes,
    });
}

fn appendAmbiguousFormFix(
    self: *const Self,
    arena: Allocator,
    doc: *const Document,
    d: Ast.Diagnostic,
    out: *std.ArrayList(CodeAction),
) Allocator.Error!void {
    const head = doc.source[d.span.start..d.span.end];
    const lookup = self.schema.lookupForm(head, null);
    const claimants = switch (lookup) {
        .ambiguous => |amb| amb.slice(),
        else => return,
    };
    for (claimants) |p| {
        const new_text = try std.fmt.allocPrint(arena, "{s}/{s}", .{ p.name, head });
        const edits = try arena.alloc(TextEdit, 1);
        edits[0] = .{
            .span_start = d.span.start,
            .span_end = d.span.end,
            .new_text = new_text,
        };
        const title = try std.fmt.allocPrint(arena, "Qualify with `{s}/{s}`", .{ p.name, head });
        const codes = try arena.alloc([]const u8, 1);
        codes[0] = @tagName(d.code);
        try out.append(arena, .{
            .title = title,
            .edits = edits,
            .diagnostic_codes = codes,
        });
    }
}

fn appendMissingRequiredKeyFix(
    self: *const Self,
    arena: Allocator,
    doc: *const Document,
    d: Ast.Diagnostic,
    out: *std.ArrayList(CodeAction),
    seen_missing_forms: *std.AutoHashMapUnmanaged(u32, void),
) Allocator.Error!void {
    const form_idx = findEnclosingFormIdx(&doc.tree, d.span.start) orelse return;
    const gop = try seen_missing_forms.getOrPut(arena, form_idx.raw());
    if (gop.found_existing) return;

    const hdr = doc.tree.formHeader(form_idx);
    const lookup = self.schema.lookupForm(hdr.head, hdr.namespace);
    const hit = switch (lookup) {
        .found => |h| h,
        else => return,
    };

    const form_span = doc.tree.spanOf(form_idx);
    const close_paren = form_span.end - 1;

    for (hit.form.keys) |k| {
        if (k.effectiveOptional()) continue;
        if (kvpairChildPresent(&doc.tree, hdr.children, k.name)) continue;

        const stub = stubLiteral(k.value_type);
        const new_text = try std.fmt.allocPrint(arena, " :{s} {s}", .{ k.name, stub });
        const edits = try arena.alloc(TextEdit, 1);
        edits[0] = .{
            .span_start = close_paren,
            .span_end = close_paren,
            .new_text = new_text,
        };
        const title = try std.fmt.allocPrint(arena, "Insert `:{s}` with stub", .{k.name});
        const codes = try arena.alloc([]const u8, 1);
        codes[0] = @tagName(d.code);
        try out.append(arena, .{
            .title = title,
            .edits = edits,
            .diagnostic_codes = codes,
        });
    }
}

fn kvpairChildPresent(
    tree: *const Ast.Tree,
    children: []const Ast.NodeIndex,
    key: []const u8,
) bool {
    for (children) |ci| {
        if (tree.tagOf(ci) != .kvpair) continue;
        const kvh = tree.kvpairHeader(ci);
        if (std.mem.eql(u8, kvh.key, key)) return true;
    }
    return false;
}

fn stubLiteral(vt: sjon.Plugin.ValueType) []const u8 {
    return switch (vt) {
        .string => "\"\"",
        .number => "0",
        .boolean => "false",
        .symbol => "_",
        .nil => "nil",
        .vector => "[]",
        .form, .expr, .any, .named => "nil",
    };
}

fn appendExprKvpairFix(
    arena: Allocator,
    doc: *const Document,
    d: Ast.Diagnostic,
    out: *std.ArrayList(CodeAction),
) Allocator.Error!void {
    const kvpair_idx = findKvpairByKeySpan(&doc.tree, d.span) orelse return;
    const kvh = doc.tree.kvpairHeader(kvpair_idx);
    const value_span = doc.tree.spanOf(kvh.value);
    if (value_span.start <= d.span.start) return;

    const edits = try arena.alloc(TextEdit, 1);
    edits[0] = .{
        .span_start = d.span.start,
        .span_end = value_span.start,
        .new_text = "",
    };
    const title = try std.fmt.allocPrint(arena, "Drop `:{s}` (keep value)", .{kvh.key});
    const codes = try arena.alloc([]const u8, 1);
    codes[0] = @tagName(d.code);
    try out.append(arena, .{
        .title = title,
        .edits = edits,
        .diagnostic_codes = codes,
    });
}

fn appendCrossRefFix(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    doc: *const Document,
    d: Ast.Diagnostic,
    out: *std.ArrayList(CodeAction),
) Allocator.Error!void {
    if (d.span.end <= d.span.start or d.span.end > doc.source.len) return;

    const enclosing_form_idx = findEnclosingFormIdx(&doc.tree, d.span.start) orelse return;
    const enclosing_kvpair_idx = findEnclosingKvpairIdx(&doc.tree, d.span.start) orelse return;
    const kvh = doc.tree.kvpairHeader(enclosing_kvpair_idx);

    const enclosing = doc.tree.formHeader(enclosing_form_idx);
    const form_hit = switch (self.schema.lookupForm(enclosing.head, enclosing.namespace)) {
        .found => |h| h,
        else => return,
    };
    var key_value_type: ?sjon.Plugin.ValueType = null;
    for (form_hit.form.keys) |k| {
        if (std.mem.eql(u8, k.name, kvh.key)) {
            key_value_type = k.value_type;
            break;
        }
    }
    const vt = key_value_type orelse return;
    const named = switch (vt) {
        .named => |n| n,
        else => return,
    };
    const kind = switch (self.schema.lookupValueKind(named.name, named.namespace)) {
        .found => |k| k,
        else => return,
    };

    const xref: sjon.Plugin.ValueKind.CrossRef = blk: {
        if (kind.cross_ref) |x| break :blk x;
        if (kind.vector) |vs| {
            const elem_kind = switch (self.schema.lookupValueKind(vs.element.name, vs.element.namespace)) {
                .found => |k| k,
                else => return,
            };
            if (elem_kind.cross_ref) |x| break :blk x;
        }
        return;
    };

    const xri = self.cross_ref_index orelse return;
    const tree_idx = self.uri_to_tree_idx.get(uri) orelse return;

    var target_ns: ?[]const u8 = null;
    var target_name = xref.target_form;
    if (std.mem.indexOfScalar(u8, xref.target_form, '/')) |slash| {
        target_ns = xref.target_form[0..slash];
        target_name = xref.target_form[slash + 1 ..];
    }
    const target_hit = switch (self.schema.lookupForm(target_name, target_ns)) {
        .found => |h| h,
        else => return,
    };
    const canonical_target = try std.fmt.allocPrint(
        arena,
        "{s}/{s}",
        .{ target_hit.plugin.name, target_hit.form.name },
    );

    const scope: Validator.ScopeId = blk: {
        const sf_raw = xref.scope_form orelse break :blk .tree(tree_idx);
        const canon_scope = (try self.canonicaliseFormHead(arena, sf_raw, null)) orelse return;
        const scope_form_idx = (try self.findEnclosingScopeFormIdx(arena, &doc.tree, enclosing_form_idx, canon_scope)) orelse return;
        break :blk .lexical(tree_idx, @intFromEnum(scope_form_idx));
    };

    const bad_span = resolveCrossRefBadSpan(&doc.tree, xri, scope, canonical_target, d.span) orelse return;
    const bad = doc.source[bad_span.start..bad_span.end];

    var self_name: ?[]const u8 = null;
    if (form_hit.plugin == target_hit.plugin and form_hit.form == target_hit.form) {
        self_name = findKvpairValueText(doc, enclosing, xref.name_key);
    }

    var best: ?[]const u8 = null;
    var best_dist: u32 = std.math.maxInt(u32);
    var it = xri.iterateNames(scope, canonical_target);
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (self_name) |s| if (std.mem.eql(u8, s, name)) continue;
        considerCandidate(bad, name, &best, &best_dist);
    }
    if (best_dist > MAX_TYPO_DISTANCE) return;
    const suggestion = best orelse return;

    const edits = try arena.alloc(TextEdit, 1);
    edits[0] = .{
        .span_start = bad_span.start,
        .span_end = bad_span.end,
        .new_text = suggestion,
    };
    const title = try std.fmt.allocPrint(arena, "Replace with `{s}`", .{suggestion});
    const codes = try arena.alloc([]const u8, 1);
    codes[0] = @tagName(d.code);
    try out.append(arena, .{
        .title = title,
        .edits = edits,
        .diagnostic_codes = codes,
    });
}

fn resolveCrossRefBadSpan(
    tree: *const Ast.Tree,
    xri: Validator.CrossRefIndex,
    scope: Validator.ScopeId,
    canonical_target: []const u8,
    diag_span: Ast.Span,
) ?Ast.Span {
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tags.len) : (i += 1) {
        const idx = Ast.NodeIndex.from(i);
        const span = tree.spanOf(idx);
        if (span.start != diag_span.start or span.end != diag_span.end) continue;
        switch (tags[i]) {
            .symbol => return span,
            .vector => {
                for (tree.vectorElements(idx)) |el| {
                    if (tree.tagOf(el) != .symbol) continue;
                    const text = tree.symbolText(el);
                    if (!xri.contains(scope, canonical_target, text)) {
                        return tree.spanOf(el);
                    }
                }
                return null;
            },
            else => return null,
        }
    }
    return null;
}

fn appendNotMemberFix(
    self: *const Self,
    arena: Allocator,
    doc: *const Document,
    d: Ast.Diagnostic,
    out: *std.ArrayList(CodeAction),
) Allocator.Error!void {
    if (d.span.end <= d.span.start or d.span.end > doc.source.len) return;

    const enclosing_form_idx = findEnclosingFormIdx(&doc.tree, d.span.start) orelse return;
    const enclosing_kvpair_idx = findEnclosingKvpairIdx(&doc.tree, d.span.start) orelse return;
    const kvh = doc.tree.kvpairHeader(enclosing_kvpair_idx);

    const enclosing = doc.tree.formHeader(enclosing_form_idx);
    const form_hit = switch (self.schema.lookupForm(enclosing.head, enclosing.namespace)) {
        .found => |h| h,
        else => return,
    };
    var key_value_type: ?sjon.Plugin.ValueType = null;
    for (form_hit.form.keys) |k| {
        if (std.mem.eql(u8, k.name, kvh.key)) {
            key_value_type = k.value_type;
            break;
        }
    }
    const vt = key_value_type orelse return;
    const named = switch (vt) {
        .named => |n| n,
        else => return,
    };
    const kind = switch (self.schema.lookupValueKind(named.name, named.namespace)) {
        .found => |k| k,
        else => return,
    };

    const member_set: sjon.Plugin.ValueKind.MemberSet = blk: {
        if (kind.members) |m| break :blk m;
        if (kind.vector) |vs| {
            const elem_kind = switch (self.schema.lookupValueKind(vs.element.name, vs.element.namespace)) {
                .found => |k| k,
                else => return,
            };
            if (elem_kind.members) |m| break :blk m;
        }
        return;
    };
    if (member_set.members.len == 0) return;

    const bad_span = resolveNotMemberBadSpan(&doc.tree, member_set.members, d.span) orelse return;
    const bad_node_tag = doc.tree.tagOf(findNodeBySpan(&doc.tree, bad_span) orelse return);
    const bad_text: []const u8 = switch (bad_node_tag) {
        .symbol => doc.tree.symbolText(findNodeBySpan(&doc.tree, bad_span).?),
        .string => doc.tree.stringText(findNodeBySpan(&doc.tree, bad_span).?),
        else => return,
    };

    var best: ?[]const u8 = null;
    var best_dist: u32 = std.math.maxInt(u32);
    for (member_set.members) |m| {
        if (m.deprecated) continue;
        considerCandidate(bad_text, m.name, &best, &best_dist);
    }
    if (best_dist > MAX_TYPO_DISTANCE) return;
    const suggestion = best orelse return;

    if (bad_node_tag == .symbol and !isPlainSymbol(suggestion)) return;

    const new_text: []const u8 = switch (bad_node_tag) {
        .string => try std.fmt.allocPrint(arena, "\"{s}\"", .{suggestion}),
        else => suggestion,
    };

    const edits = try arena.alloc(TextEdit, 1);
    edits[0] = .{
        .span_start = bad_span.start,
        .span_end = bad_span.end,
        .new_text = new_text,
    };
    const title = try std.fmt.allocPrint(arena, "Replace with `{s}`", .{suggestion});
    const codes = try arena.alloc([]const u8, 1);
    codes[0] = @tagName(d.code);
    try out.append(arena, .{
        .title = title,
        .edits = edits,
        .diagnostic_codes = codes,
    });
}

fn resolveNotMemberBadSpan(
    tree: *const Ast.Tree,
    members: []const sjon.Plugin.ValueKind.MemberSet.Member,
    diag_span: Ast.Span,
) ?Ast.Span {
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tags.len) : (i += 1) {
        const idx = Ast.NodeIndex.from(i);
        const span = tree.spanOf(idx);
        if (span.start != diag_span.start or span.end != diag_span.end) continue;
        switch (tags[i]) {
            .symbol, .string => return span,
            .vector => {
                for (tree.vectorElements(idx)) |el| {
                    const el_tag = tree.tagOf(el);
                    const text: []const u8 = switch (el_tag) {
                        .symbol => tree.symbolText(el),
                        .string => tree.stringText(el),
                        else => continue,
                    };
                    if (!memberSetContains(members, text)) return tree.spanOf(el);
                }
                return null;
            },
            else => return null,
        }
    }
    return null;
}

fn memberSetContains(
    members: []const sjon.Plugin.ValueKind.MemberSet.Member,
    text: []const u8,
) bool {
    for (members) |m| {
        if (std.mem.eql(u8, m.name, text)) return true;
    }
    return false;
}

fn findNodeBySpan(tree: *const Ast.Tree, target_span: Ast.Span) ?Ast.NodeIndex {
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tags.len) : (i += 1) {
        const span = tree.nodes.items(.span)[i];
        if (span.start == target_span.start and span.end == target_span.end) {
            return Ast.NodeIndex.from(i);
        }
    }
    return null;
}

fn isPlainSymbol(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!isSymbolChar(c)) return false;
    }
    return true;
}

fn appendDuplicateKeyFix(
    arena: Allocator,
    doc: *const Document,
    d: Ast.Diagnostic,
    out: *std.ArrayList(CodeAction),
) Allocator.Error!void {
    const kvpair_idx = findKvpairByKeySpan(&doc.tree, d.span) orelse return;
    const kvh = doc.tree.kvpairHeader(kvpair_idx);
    const kvpair_span = doc.tree.spanOf(kvpair_idx);

    var sweep_start: u32 = kvpair_span.start;
    while (sweep_start > 0 and isWhitespace(doc.source[sweep_start - 1])) {
        sweep_start -= 1;
    }

    for (doc.source[sweep_start..kvpair_span.end]) |b| {
        if (b == ';') return;
    }
    var s = sweep_start;
    while (s > 0) {
        const c = doc.source[s - 1];
        if (c == '\n') break;
        if (c == ';') return;
        s -= 1;
    }

    const edits = try arena.alloc(TextEdit, 1);
    edits[0] = .{
        .span_start = sweep_start,
        .span_end = kvpair_span.end,
        .new_text = "",
    };
    const title = try std.fmt.allocPrint(arena, "Remove duplicate `:{s}`", .{kvh.key});
    const codes = try arena.alloc([]const u8, 1);
    codes[0] = @tagName(d.code);
    try out.append(arena, .{
        .title = title,
        .edits = edits,
        .diagnostic_codes = codes,
    });
}

const MAX_TYPO_DISTANCE: u32 = 3;

fn closestFormName(self: *const Self, target: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: u32 = std.math.maxInt(u32);
    for (self.schema.plugins) |p| {
        for (p.forms) |f| considerCandidate(target, f.name, &best, &best_dist);
        for (p.expr_funcs) |f| considerCandidate(target, f.name, &best, &best_dist);
    }
    return if (best_dist <= MAX_TYPO_DISTANCE) best else null;
}

fn closestKeyName(target: []const u8, keys: []const sjon.Plugin.KeySpec) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: u32 = std.math.maxInt(u32);
    for (keys) |k| considerCandidate(target, k.name, &best, &best_dist);
    return if (best_dist <= MAX_TYPO_DISTANCE) best else null;
}

fn considerCandidate(
    target: []const u8,
    candidate: []const u8,
    best: *?[]const u8,
    best_dist: *u32,
) void {
    const d = levenshtein(target, candidate);
    if (d < best_dist.*) {
        best.* = candidate;
        best_dist.* = d;
    }
}

const MAX_NAME_LEN: usize = 64;

fn levenshtein(a: []const u8, b: []const u8) u32 {
    if (a.len > MAX_NAME_LEN or b.len > MAX_NAME_LEN) return std.math.maxInt(u32);
    var prev: [MAX_NAME_LEN + 1]u32 = undefined;
    var curr: [MAX_NAME_LEN + 1]u32 = undefined;
    for (0..b.len + 1) |j| prev[j] = @intCast(j);
    for (a, 0..) |ca, i| {
        curr[0] = @intCast(i + 1);
        for (b, 0..) |cb, j| {
            const cost: u32 = if (ca == cb) 0 else 1;
            const del = prev[j + 1] + 1;
            const ins = curr[j] + 1;
            const sub = prev[j] + cost;
            curr[j + 1] = @min(@min(del, ins), sub);
        }
        prev = curr;
    }
    return prev[b.len];
}

fn translate(d: Ast.Diagnostic) Diagnostic {
    return .{
        .span_start = d.span.start,
        .span_end = d.span.end,
        .severity = switch (d.severity) {
            .err => .err,
            .warning => .warning,
        },
        .code = @tagName(d.code),
        .message = d.message,
    };
}

fn translateDupe(arena: Allocator, d: Ast.Diagnostic) Allocator.Error!Diagnostic {
    return .{
        .span_start = d.span.start,
        .span_end = d.span.end,
        .severity = switch (d.severity) {
            .err => .err,
            .warning => .warning,
        },
        .code = @tagName(d.code),
        .message = try arena.dupe(u8, d.message),
    };
}

fn sentinelDupe(gpa: Allocator, bytes: []const u8) Allocator.Error![:0]u8 {
    const buf = try gpa.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf;
}

fn findEnclosingSymbolIdx(tree: *const Ast.Tree, pos: u32) ?Ast.NodeIndex {
    var best: ?Ast.NodeIndex = null;
    var best_size: u32 = std.math.maxInt(u32);
    const tags = tree.nodes.items(.tag);
    var i: u32 = 0;
    while (i < tags.len) : (i += 1) {
        if (tags[i] != .symbol) continue;
        const idx = Ast.NodeIndex.from(i);
        const span = tree.spanOf(idx);
        if (pos < span.start or pos >= span.end) continue;
        const size = span.end - span.start;
        if (size < best_size) {
            best = idx;
            best_size = size;
        }
    }
    return best;
}

const CrossRefSite = struct {
    scope: Validator.ScopeId,
    target: []const u8,
    name: []const u8,
    is_definition: bool,
};

fn locateCrossRefSite(
    index: *const Validator.CrossRefIndex,
    tree_idx: u32,
    cursor: Ast.Span,
) ?CrossRefSite {
    var def_scope_iter = index.by_scope.iterator();
    while (def_scope_iter.next()) |scope_entry| {
        var target_iter = scope_entry.value_ptr.iterator();
        while (target_iter.next()) |target_entry| {
            var name_iter = target_entry.value_ptr.iterator();
            while (name_iter.next()) |name_entry| {
                const s = name_entry.value_ptr.*;
                if (s.tree_idx == tree_idx and s.name_span.start == cursor.start and s.name_span.end == cursor.end) {
                    return .{
                        .scope = scope_entry.key_ptr.*,
                        .target = target_entry.key_ptr.*,
                        .name = name_entry.key_ptr.*,
                        .is_definition = true,
                    };
                }
            }
        }
    }
    var ref_scope_iter = index.references_by_scope.iterator();
    while (ref_scope_iter.next()) |scope_entry| {
        var target_iter = scope_entry.value_ptr.iterator();
        while (target_iter.next()) |target_entry| {
            var name_iter = target_entry.value_ptr.iterator();
            while (name_iter.next()) |name_entry| {
                for (name_entry.value_ptr.items) |s| {
                    if (s.tree_idx == tree_idx and s.name_span.start == cursor.start and s.name_span.end == cursor.end) {
                        return .{
                            .scope = scope_entry.key_ptr.*,
                            .target = target_entry.key_ptr.*,
                            .name = name_entry.key_ptr.*,
                            .is_definition = false,
                        };
                    }
                }
            }
        }
    }
    return null;
}

fn treeIdxOf(self: *const Self, uri: []const u8) ?u32 {
    for (self.tree_uris, 0..) |u, i| {
        if (std.mem.eql(u8, u, uri)) return @intCast(i);
    }
    return null;
}

pub fn findReferences(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    byte_offset: u32,
    include_declaration: bool,
) Allocator.Error!?[]const Location {
    const doc = self.getDocument(uri) orelse return null;
    const index = if (self.cross_ref_index) |*ix| ix else return null;
    const tree_idx = self.treeIdxOf(uri) orelse return null;

    const sym_idx = findEnclosingSymbolIdx(&doc.tree, byte_offset) orelse return null;
    const cursor_span = doc.tree.spanOf(sym_idx);

    const site = locateCrossRefSite(index, tree_idx, cursor_span) orelse return null;

    const refs = index.lookupReferences(site.scope, site.target, site.name);
    const def: ?Validator.CrossRefIndex.Site = index.lookup(site.scope, site.target, site.name);

    var total: usize = refs.len;
    if (include_declaration and def != null) total += 1;

    const out = try arena.alloc(Location, total);
    var w: usize = 0;
    if (include_declaration) {
        if (def) |d| {
            out[w] = .{
                .uri = self.tree_uris[d.tree_idx],
                .span_start = d.name_span.start,
                .span_end = d.name_span.end,
            };
            w += 1;
        }
    }
    for (refs) |r| {
        out[w] = .{
            .uri = self.tree_uris[r.tree_idx],
            .span_start = r.name_span.start,
            .span_end = r.name_span.end,
        };
        w += 1;
    }
    return out[0..w];
}

pub const PrepareRename = struct {
    span_start: u32,
    span_end: u32,
};

pub fn prepareRename(
    self: *const Self,
    uri: []const u8,
    byte_offset: u32,
) ?PrepareRename {
    const doc = self.getDocument(uri) orelse return null;
    const index = if (self.cross_ref_index) |*ix| ix else return null;
    const tree_idx = self.treeIdxOf(uri) orelse return null;

    const sym_idx = findEnclosingSymbolIdx(&doc.tree, byte_offset) orelse return null;
    const cursor_span = doc.tree.spanOf(sym_idx);

    _ = locateCrossRefSite(index, tree_idx, cursor_span) orelse return null;
    return .{ .span_start = cursor_span.start, .span_end = cursor_span.end };
}

pub const RenameError = struct {
    message: []const u8,
};

pub const RenameResult = union(enum) {
    edits: WorkspaceEdit,
    err: RenameError,
};

pub fn rename(
    self: *const Self,
    arena: Allocator,
    uri: []const u8,
    byte_offset: u32,
    new_name: []const u8,
) Allocator.Error!?RenameResult {
    const doc = self.getDocument(uri) orelse return null;
    const index = if (self.cross_ref_index) |*ix| ix else return null;
    const tree_idx = self.treeIdxOf(uri) orelse return null;

    const sym_idx = findEnclosingSymbolIdx(&doc.tree, byte_offset) orelse return null;
    const cursor_span = doc.tree.spanOf(sym_idx);

    const site = locateCrossRefSite(index, tree_idx, cursor_span) orelse return null;

    if (!std.mem.eql(u8, site.name, new_name)) {
        if (index.lookup(site.scope, site.target, new_name)) |_| {
            return .{ .err = .{
                .message = try std.fmt.allocPrint(
                    arena,
                    "cannot rename: `{s}` already declared in this scope",
                    .{new_name},
                ),
            } };
        }
    }

    var sites: std.ArrayList(Validator.CrossRefIndex.Site) = .empty;
    if (index.lookup(site.scope, site.target, site.name)) |def| {
        try sites.append(arena, def);
    }
    for (index.lookupReferences(site.scope, site.target, site.name)) |s| {
        try sites.append(arena, s);
    }

    const max_files = self.tree_uris.len;
    var per_uri = try arena.alloc(std.ArrayList(TextEdit), max_files);
    for (per_uri) |*lst| lst.* = .empty;

    for (sites.items) |s| {
        try per_uri[s.tree_idx].append(arena, .{
            .span_start = s.name_span.start,
            .span_end = s.name_span.end,
            .new_text = new_name,
        });
    }

    var file_edits: std.ArrayList(WorkspaceEdit.FileEdits) = .empty;
    for (per_uri, 0..) |lst, i| {
        if (lst.items.len == 0) continue;
        try file_edits.append(arena, .{
            .uri = self.tree_uris[i],
            .edits = lst.items,
        });
    }
    return .{ .edits = .{ .changes = file_edits.items } };
}
