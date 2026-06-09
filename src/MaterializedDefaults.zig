const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Expr = @import("Expr.zig");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const testing = std.testing;

const Parser = @import("Parser.zig");
const Binary = @import("Binary.zig");
const core = @import("plugins/core.zig");

pub const Origin = enum {
    literal_default,
    expression_default,
};

pub const Entry = struct {
    form: Ast.NodeIndex,
    key: []const u8,
    value: Expr.Value,
    origin: Origin,
    schema_path: []const []const u8 = &.{},
};

pub const MaterializedDefaults = struct {
    entries: []const Entry = &.{},

    pub fn defaultFor(
        self: *const MaterializedDefaults,
        form: Ast.NodeIndex,
        key: []const u8,
    ) ?*const Entry {
        for (self.entries) |*entry| {
            if (entry.form == form and std.mem.eql(u8, entry.key, key)) {
                return entry;
            }
        }
        return null;
    }
};

pub const ConvertError = error{
    OutOfMemory,
    NotALiteral,
};

pub fn literalToValue(
    a: Allocator,
    default: Plugin.KeySpec.Default,
) ConvertError!Expr.Value {
    return switch (default) {
        .number => |n| .{ .number = n },
        .boolean => |b| .{ .boolean = b },
        .nil => .nil,
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .symbol => |s| .{ .keyword = try a.dupe(u8, s) },
        .vector => |xs| blk: {
            const dup = try a.alloc(Expr.Value, xs.len);
            for (xs, 0..) |x, i| dup[i] = try literalToValue(a, x);
            break :blk .{ .vector = dup };
        },
        .expression => ConvertError.NotALiteral,
    };
}

pub const Result = struct {
    materialized: MaterializedDefaults,
    diagnostics: []const Ast.Diagnostic,

    pub fn deinit(self: *Result, gpa: Allocator) void {
        for (self.diagnostics) |d| {
            gpa.free(d.message);
            for (d.path) |p| gpa.free(p);
            gpa.free(d.path);
        }
        gpa.free(self.diagnostics);
    }
};

pub fn materializeDefaults(
    gpa: Allocator,
    arena: Allocator,
    tree: *const Ast.Tree,
    data_forest: []const Ast.NodeIndex,
    schema: Schema.Schema,
) Allocator.Error!Result {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(arena);
    var diags: std.ArrayList(Ast.Diagnostic) = .empty;
    errdefer diags.deinit(gpa);

    const CacheValue = ?Expr.Value;
    var cache: std.AutoHashMapUnmanaged(*const Plugin.KeySpec, CacheValue) = .empty;
    defer cache.deinit(gpa);

    for (data_forest) |idx| {
        try walkNode(gpa, arena, tree, idx, schema, &entries, &diags, &cache);
    }

    return .{
        .materialized = .{ .entries = try entries.toOwnedSlice(arena) },
        .diagnostics = try diags.toOwnedSlice(gpa),
    };
}

fn walkNode(
    gpa: Allocator,
    arena: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    schema: Schema.Schema,
    entries: *std.ArrayList(Entry),
    diags: *std.ArrayList(Ast.Diagnostic),
    cache: *std.AutoHashMapUnmanaged(*const Plugin.KeySpec, ?Expr.Value),
) Allocator.Error!void {
    if (tree.tagOf(idx) != .form) return;
    const hdr = tree.formHeader(idx);
    if (hdr.head.len == 0) return;

    const form_hit = schema.lookupForm(hdr.head, hdr.namespace);
    if (form_hit == .found) {
        const form_spec = form_hit.found.form;
        try materializeForForm(gpa, arena, tree, idx, hdr, form_spec, schema, entries, diags, cache);
    }

    for (hdr.children) |child| {
        const ctag = tree.tagOf(child);
        if (ctag == .form) {
            try walkNode(gpa, arena, tree, child, schema, entries, diags, cache);
            continue;
        }
        if (ctag == .kvpair) {
            const kvh = tree.kvpairHeader(child);
            if (tree.tagOf(kvh.value) == .form) {
                try walkNode(gpa, arena, tree, kvh.value, schema, entries, diags, cache);
            }
        }
    }
}

fn materializeForForm(
    gpa: Allocator,
    arena: Allocator,
    tree: *const Ast.Tree,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    form_spec: *const Plugin.FormSpec,
    schema: Schema.Schema,
    entries: *std.ArrayList(Entry),
    diags: *std.ArrayList(Ast.Diagnostic),
    cache: *std.AutoHashMapUnmanaged(*const Plugin.KeySpec, ?Expr.Value),
) Allocator.Error!void {
    for (form_spec.keys) |*key| {
        if (key.default == null) continue;
        if (authorWroteKey(tree, hdr, key.name)) continue;

        const value = materializeOne(gpa, arena, schema, key, hdr.head, hdr.head_span, diags, cache) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        } orelse continue;

        try entries.append(arena, .{
            .form = form_idx,
            .key = try arena.dupe(u8, key.name),
            .value = value,
            .origin = switch (key.default.?) {
                .expression => .expression_default,
                else => .literal_default,
            },
        });
    }
}

pub fn authorValueOnForm(
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    key: []const u8,
) ?Ast.NodeIndex {
    for (hdr.children) |child| {
        if (tree.tagOf(child) != .kvpair) continue;
        const kvh = tree.kvpairHeader(child);
        if (std.mem.eql(u8, kvh.key, key)) return kvh.value;
    }
    return null;
}

fn authorWroteKey(tree: *const Ast.Tree, hdr: Ast.FormHeader, key_name: []const u8) bool {
    return authorValueOnForm(tree, hdr, key_name) != null;
}

fn materializeOne(
    gpa: Allocator,
    arena: Allocator,
    schema: Schema.Schema,
    key: *const Plugin.KeySpec,
    form_head: []const u8,
    head_span: Ast.Span,
    diags: *std.ArrayList(Ast.Diagnostic),
    cache: *std.AutoHashMapUnmanaged(*const Plugin.KeySpec, ?Expr.Value),
) Allocator.Error!?Expr.Value {
    if (cache.get(key)) |cached| return cached;

    const default = key.default.?;
    if (default != .expression) {
        const value = literalToValue(arena, default) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotALiteral => unreachable,
        };
        try cache.put(gpa, key, value);
        return value;
    }

    const program = default.expression.program;
    var eval_result = Expr.evalBinary(gpa, program, &.{}, schema) catch |err| {
        try emitFailure(gpa, diags, form_head, key.name, head_span, err);
        try cache.put(gpa, key, null);
        return null;
    };
    defer eval_result.deinit();

    const owned = try deepCopyExprValue(arena, eval_result.value);
    try cache.put(gpa, key, owned);
    return owned;
}

fn deepCopyExprValue(a: Allocator, v: Expr.Value) Allocator.Error!Expr.Value {
    return switch (v) {
        .number, .integer_i64, .integer_u64, .boolean, .nil, .date, .time => v,
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .keyword => |k| .{ .keyword = try a.dupe(u8, k) },
        .vector => |xs| blk: {
            const dup = try a.alloc(Expr.Value, xs.len);
            for (xs, 0..) |x, i| dup[i] = try deepCopyExprValue(a, x);
            break :blk .{ .vector = dup };
        },
        .form => |f| blk: {
            const head = try a.dupe(u8, f.head);
            const ns = try a.dupe(u8, f.namespace);
            const children = try a.alloc(Expr.Value, f.children.len);
            for (f.children, 0..) |c, i| children[i] = try deepCopyExprValue(a, c);
            const kvs = try a.alloc(Expr.KvPair, f.kvpairs.len);
            for (f.kvpairs, 0..) |p, i| kvs[i] = .{
                .key = try a.dupe(u8, p.key),
                .value = try deepCopyExprValue(a, p.value),
            };
            break :blk .{ .form = .{
                .head = head,
                .namespace = ns,
                .children = children,
                .kvpairs = kvs,
            } };
        },
    };
}

fn emitFailure(
    gpa: Allocator,
    diags: *std.ArrayList(Ast.Diagnostic),
    form_head: []const u8,
    key_name: []const u8,
    span: Ast.Span,
    err: anyerror,
) Allocator.Error!void {
    const message = try std.fmt.allocPrint(
        gpa,
        "default for `:{s}` on `({s} …)` failed to evaluate: {s}",
        .{ key_name, form_head, @errorName(err) },
    );
    const path = try gpa.alloc([]const u8, 3);
    path[0] = try gpa.dupe(u8, form_head);
    path[1] = try gpa.dupe(u8, key_name);
    path[2] = try gpa.dupe(u8, "default");
    try diags.append(gpa, .{
        .span = span,
        .message = message,
        .severity = .err,
        .code = .default_eval_failed,
        .path = path,
    });
}

fn encodeProgram(a: Allocator, src: [:0]const u8) !Ast.Bytes {
    var prog_tree = try Parser.parse(a, src);
    defer prog_tree.deinit();
    return Binary.toBinary(a, prog_tree, Binary.ToBinaryOptions.forMode(.compact));
}
