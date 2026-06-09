const std = @import("std");
const Ast = @import("Ast.zig");

pub const Reference = struct {
    name: []const u8,

    explicit_path: ?[]const u8 = null,

    version: ?[]const u8 = null,

    hash: ?[]const u8 = null,

    span: Ast.Span,
};

pub const Resolution = union(enum) {
    manifest: ManifestResolution,

    failure: ResolverFailure,
};

pub const ManifestResolution = struct {
    source: []const u8,

    wasm: ?[]const u8 = null,
};

pub const ResolverFailure = struct {
    code: Ast.Diagnostic.Code,

    detail: []const u8,
};

pub const ResolverFn = *const fn (
    ctx: *anyopaque,
    ref: Reference,
    arena: std.mem.Allocator,
) std.mem.Allocator.Error!Resolution;

pub const Resolver = struct {
    ctx: *anyopaque,
    resolve: ResolverFn,
};

pub const ParsedReference = struct {
    reference: Reference,
    diagnostics: []const Ast.Diagnostic,

    pub fn hasErrors(self: ParsedReference) bool {
        for (self.diagnostics) |d| if (d.severity == .err) return true;
        return false;
    }
};

pub fn parseReference(
    arena: std.mem.Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) std.mem.Allocator.Error!ParsedReference {
    std.debug.assert(tree.tagOf(idx) == .form);
    const hdr = tree.formHeader(idx);
    std.debug.assert(hdr.namespace == null and std.mem.eql(u8, hdr.head, "use-plugin"));

    const full_span = tree.spanOf(idx);

    var diags: std.ArrayList(Ast.Diagnostic) = .empty;
    var ref: Reference = .{ .name = "", .span = full_span };

    var name_seen = false;
    var saw_extra_positional = false;
    for (hdr.children) |ci| {
        switch (tree.tagOf(ci)) {
            .kvpair => {
                const kv = tree.kvpairHeader(ci);
                if (std.mem.eql(u8, kv.key, "path")) {
                    if (try expectStringValue(arena, tree, kv, "path", &diags)) |s| {
                        ref.explicit_path = s;
                    }
                } else if (std.mem.eql(u8, kv.key, "version")) {
                    if (try expectStringValue(arena, tree, kv, "version", &diags)) |s| {
                        ref.version = s;
                    }
                } else if (std.mem.eql(u8, kv.key, "hash")) {
                    if (try expectStringValue(arena, tree, kv, "hash", &diags)) |s| {
                        ref.hash = s;
                    }
                } else {
                    try diags.append(arena, .{
                        .span = kv.key_span,
                        .severity = .err,
                        .code = .unknown_key,
                        .message = try std.fmt.allocPrint(
                            arena,
                            "unknown key `:{s}` on (use-plugin …); expected :path, :version, or :hash",
                            .{kv.key},
                        ),
                        .path = try singletonPath(arena, "use-plugin"),
                    });
                }
            },
            .string => {
                if (name_seen) {
                    if (!saw_extra_positional) {
                        try diags.append(arena, .{
                            .span = tree.spanOf(ci),
                            .severity = .err,
                            .code = .invalid_manifest,
                            .message = try arena.dupe(u8, "(use-plugin …) takes a single positional name"),
                            .path = try singletonPath(arena, "use-plugin"),
                        });
                        saw_extra_positional = true;
                    }
                } else {
                    ref.name = try arena.dupe(u8, tree.stringText(ci));
                    ref.span = tree.spanOf(ci);
                    name_seen = true;
                }
            },
            else => {
                if (!name_seen) {
                    try diags.append(arena, .{
                        .span = tree.spanOf(ci),
                        .severity = .err,
                        .code = .invalid_manifest,
                        .message = try arena.dupe(u8, "(use-plugin …) name must be a string literal"),
                        .path = try singletonPath(arena, "use-plugin"),
                    });
                    name_seen = true;
                }
            },
        }
    }

    if (!name_seen) {
        try diags.append(arena, .{
            .span = hdr.head_span,
            .severity = .err,
            .code = .invalid_manifest,
            .message = try arena.dupe(u8, "(use-plugin …) requires a name string"),
            .path = try singletonPath(arena, "use-plugin"),
        });
    }

    return .{
        .reference = ref,
        .diagnostics = try diags.toOwnedSlice(arena),
    };
}

fn expectStringValue(
    arena: std.mem.Allocator,
    tree: *const Ast.Tree,
    kv: Ast.KvPairHeader,
    key_name: []const u8,
    diags: *std.ArrayList(Ast.Diagnostic),
) std.mem.Allocator.Error!?[]const u8 {
    if (tree.tagOf(kv.value) != .string) {
        try diags.append(arena, .{
            .span = tree.spanOf(kv.value),
            .severity = .err,
            .code = .invalid_manifest,
            .message = try std.fmt.allocPrint(
                arena,
                "(use-plugin …) :{s} must be a string",
                .{key_name},
            ),
            .path = try singletonPath(arena, "use-plugin"),
        });
        return null;
    }
    return try arena.dupe(u8, tree.stringText(kv.value));
}

fn singletonPath(arena: std.mem.Allocator, step: []const u8) std.mem.Allocator.Error![]const []const u8 {
    const path = try arena.alloc([]const u8, 1);
    path[0] = try arena.dupe(u8, step);
    return path;
}

const testing = std.testing;
const Parser = @import("Parser.zig");

fn parseSingleRef(a: std.mem.Allocator, src: [:0]const u8) !struct {
    tree: Ast.Tree,
    parsed: ParsedReference,
} {
    var tree = try Parser.parse(a, src);
    errdefer tree.deinit();
    try testing.expect(tree.root.len >= 1);
    const idx = tree.root[0];
    const parsed = try parseReference(tree.arena.allocator(), &tree, idx);
    return .{ .tree = tree, .parsed = parsed };
}
