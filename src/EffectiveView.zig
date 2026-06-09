const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Expr = @import("Expr.zig");
const MaterializedDefaults = @import("MaterializedDefaults.zig");
const testing = std.testing;
const Parser = @import("Parser.zig");

pub const EffectiveValue = union(enum) {
    author: Ast.NodeIndex,
    default: *const MaterializedDefaults.Entry,
};

pub const ConvertError = error{
    OutOfMemory,
    NotConvertible,
};

pub const EffectiveView = struct {
    tree: *const Ast.Tree,
    materialized: *const MaterializedDefaults.MaterializedDefaults,

    pub fn init(
        tree: *const Ast.Tree,
        materialized: *const MaterializedDefaults.MaterializedDefaults,
    ) EffectiveView {
        return .{ .tree = tree, .materialized = materialized };
    }

    pub fn getAuthorValue(
        self: EffectiveView,
        form: Ast.NodeIndex,
        key: []const u8,
    ) ?Ast.NodeIndex {
        if (self.tree.tagOf(form) != .form) return null;
        const hdr = self.tree.formHeader(form);
        return MaterializedDefaults.authorValueOnForm(self.tree, hdr, key);
    }

    pub fn getDefaultValue(
        self: EffectiveView,
        form: Ast.NodeIndex,
        key: []const u8,
    ) ?*const MaterializedDefaults.Entry {
        return self.materialized.defaultFor(form, key);
    }

    pub fn getEffectiveValue(
        self: EffectiveView,
        form: Ast.NodeIndex,
        key: []const u8,
    ) ?EffectiveValue {
        if (self.getAuthorValue(form, key)) |idx| return .{ .author = idx };
        if (self.getDefaultValue(form, key)) |entry| return .{ .default = entry };
        return null;
    }
};

pub fn toExprValue(
    ev: EffectiveValue,
    arena: Allocator,
    tree: *const Ast.Tree,
) ConvertError!Expr.Value {
    return switch (ev) {
        .author => |idx| try astNodeToExprValue(arena, tree, idx),
        .default => |entry| try deepCopyExprValue(arena, entry.value),
    };
}

fn astNodeToExprValue(
    arena: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
) ConvertError!Expr.Value {
    return switch (tree.tagOf(idx)) {
        .number, .number_i64, .number_u64 => .{ .number = tree.numberOf(idx) },
        .boolean_true => .{ .boolean = true },
        .boolean_false => .{ .boolean = false },
        .nil => .nil,
        .date => .{ .date = tree.dateOf(idx) },
        .time => .{ .time = tree.timeOf(idx) },
        .string => .{ .string = try arena.dupe(u8, tree.stringText(idx)) },
        .keyword => blk: {
            const si: Ast.StringIndex = @enumFromInt(tree.dataOf(idx).single);
            break :blk .{ .keyword = try arena.dupe(u8, tree.stringSlice(si)) };
        },
        .symbol => .{ .keyword = try arena.dupe(u8, tree.symbolText(idx)) },
        .vector => blk: {
            const elements = tree.vectorElements(idx);
            const dup = try arena.alloc(Expr.Value, elements.len);
            for (elements, 0..) |elem_idx, i| {
                dup[i] = try astNodeToExprValue(arena, tree, elem_idx);
            }
            break :blk .{ .vector = dup };
        },
        .form, .number_with_unit => ConvertError.NotConvertible,
        .kvpair => unreachable,
    };
}

fn deepCopyExprValue(arena: Allocator, v: Expr.Value) Allocator.Error!Expr.Value {
    return switch (v) {
        .number, .integer_i64, .integer_u64, .boolean, .nil, .date, .time => v,
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        .keyword => |k| .{ .keyword = try arena.dupe(u8, k) },
        .vector => |xs| blk: {
            const dup = try arena.alloc(Expr.Value, xs.len);
            for (xs, 0..) |x, i| dup[i] = try deepCopyExprValue(arena, x);
            break :blk .{ .vector = dup };
        },
        .form => |f| blk: {
            const head = try arena.dupe(u8, f.head);
            const ns = try arena.dupe(u8, f.namespace);
            const children = try arena.alloc(Expr.Value, f.children.len);
            for (f.children, 0..) |c, i| children[i] = try deepCopyExprValue(arena, c);
            const kvs = try arena.alloc(Expr.KvPair, f.kvpairs.len);
            for (f.kvpairs, 0..) |p, i| kvs[i] = .{
                .key = try arena.dupe(u8, p.key),
                .value = try deepCopyExprValue(arena, p.value),
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

fn buildOverlay(arena: Allocator, entries: []const MaterializedDefaults.Entry) !MaterializedDefaults.MaterializedDefaults {
    const dup = try arena.dupe(MaterializedDefaults.Entry, entries);
    return .{ .entries = dup };
}
