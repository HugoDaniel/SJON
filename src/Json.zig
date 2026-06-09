const std = @import("std");
const Date = @import("Date.zig");
const Time = @import("Time.zig");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Ast = @import("Ast.zig");
const Plugin = @import("Plugin.zig");
const Schema = @import("Schema.zig");
const Discriminators = @import("SchemaExport/Discriminators.zig");

pub const ToJsonOptions = struct {
    mode: Ast.Mode = .canonical,
    schema: ?Schema.Schema = null,

    pub fn forMode(mode: Ast.Mode) ToJsonOptions {
        return .{ .mode = mode };
    }
};

pub const FromJsonOptions = struct {
    mode: Ast.Mode = .canonical,

    pub fn forMode(mode: Ast.Mode) FromJsonOptions {
        return .{ .mode = mode };
    }
};

pub const Result = struct {
    arena: ArenaAllocator,
    value: std.json.Value,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }
};

pub const Error = error{
    OutOfMemory,
    MultipleRoots,
    InvalidEncoding,
    InvalidExprForm,
    InvalidFormHead,
    UnknownDiscriminator,
};

fn isKnownFormDiscriminator(key: []const u8) bool {
    for (Discriminators.form_keys) |d| {
        if (std.mem.eql(u8, key, d)) return true;
    }
    return false;
}

fn escapeKey(a: Allocator, key: []const u8) Error![]const u8 {
    if (key.len == 0 or key[0] != '$') return try a.dupe(u8, key);
    const out = try a.alloc(u8, key.len + 1);
    out[0] = '$';
    @memcpy(out[1..], key);
    return out;
}

fn unescapeKey(key: []const u8) []const u8 {
    if (key.len >= 2 and key[0] == '$' and key[1] == '$') return key[1..];
    return key;
}

pub fn toJson(gpa: Allocator, tree: Ast.Tree, opts: ToJsonOptions) Error!Result {
    if (tree.root.len != 1) return error.MultipleRoots;
    return toJsonNode(gpa, &tree, tree.root[0], opts);
}

pub fn toJsonRoots(gpa: Allocator, tree: Ast.Tree, opts: ToJsonOptions) Error!Result {
    var arena = ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var arr = std.json.Array.init(a);
    try arr.ensureTotalCapacity(tree.root.len);
    for (tree.root) |idx| arr.appendAssumeCapacity(try buildJson(a, &tree, idx, opts));

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$roots", .{ .array = arr });
    return .{ .arena = arena, .value = .{ .object = obj } };
}

pub fn toJsonNode(
    gpa: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    opts: ToJsonOptions,
) Error!Result {
    var arena = ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const v = try buildJson(a, tree, idx, opts);
    return .{ .arena = arena, .value = v };
}

fn buildJson(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    opts: ToJsonOptions,
) Error!std.json.Value {
    return switch (tree.tagOf(idx)) {
        .nil => .null,
        .boolean_true => .{ .bool = true },
        .boolean_false => .{ .bool = false },
        .number, .number_i64, .number_u64 => try treeNumberToJson(a, tree, idx),
        .number_with_unit => blk: {
            const nu = tree.numberWithUnitOf(idx);
            break :blk try numberValueToJson(a, .{ .value = nu.value, .unit = nu.unit }, opts);
        },
        .date => blk: {
            const d = tree.dateOf(idx);
            break :blk try dateToJson(a, d, opts);
        },
        .time => blk: {
            const t = tree.timeOf(idx);
            break :blk try timeToJson(a, t, opts);
        },
        .string => blk: {
            const si: Ast.StringIndex = @enumFromInt(tree.dataOf(idx).single);
            break :blk .{ .string = try a.dupe(u8, tree.stringSlice(si)) };
        },
        .keyword => blk: {
            const si: Ast.StringIndex = @enumFromInt(tree.dataOf(idx).single);
            break :blk try keywordToJson(a, tree.stringSlice(si), opts);
        },
        .symbol => blk: {
            const si: Ast.StringIndex = @enumFromInt(tree.dataOf(idx).single);
            break :blk try symbolToJson(a, tree.stringSlice(si), opts);
        },
        .vector => try vectorToJson(a, tree, idx, opts),
        .form => try formToJson(a, tree, idx, opts),
        .kvpair => unreachable,
    };
}

fn numberToJson(x: f64) std.json.Value {
    if (!std.math.isFinite(x)) return .{ .float = x };
    const safe_int_max: f64 = @floatFromInt(@as(i64, 1) << 53);
    if (@floor(x) == x and @abs(x) < safe_int_max) {
        return .{ .integer = @intFromFloat(x) };
    }
    return .{ .float = x };
}

fn treeNumberToJson(a: Allocator, tree: *const Ast.Tree, idx: Ast.NodeIndex) Error!std.json.Value {
    return switch (tree.tagOf(idx)) {
        .number => numberToJson(tree.numberOf(idx)),
        .number_i64 => .{ .integer = tree.numberI64Of(idx) },
        .number_u64 => blk: {
            const v = tree.numberU64Of(idx);
            if (v <= std.math.maxInt(i64)) {
                break :blk .{ .integer = @intCast(v) };
            }
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
            break :blk .{ .number_string = try a.dupe(u8, s) };
        },
        else => unreachable,
    };
}

fn numberValueToJson(a: Allocator, nv: Ast.NumberValue, opts: ToJsonOptions) Error!std.json.Value {
    if (nv.unit) |u| {
        switch (opts.mode) {
            .compact => return numberToJson(nv.value),
            .canonical, .full => {
                var arr = std.json.Array.init(a);
                try arr.ensureTotalCapacity(2);
                arr.appendAssumeCapacity(numberToJson(nv.value));
                arr.appendAssumeCapacity(.{ .string = try a.dupe(u8, u) });
                var obj: std.json.ObjectMap = .empty;
                try obj.put(a, "$num", .{ .array = arr });
                return .{ .object = obj };
            },
        }
    }
    return numberToJson(nv.value);
}

fn keywordToJson(a: Allocator, name: []const u8, opts: ToJsonOptions) Error!std.json.Value {
    const owned = try a.dupe(u8, name);
    return switch (opts.mode) {
        .compact => .{ .string = owned },
        .canonical, .full => blk: {
            var obj: std.json.ObjectMap = .empty;
            try obj.put(a, "$kw", .{ .string = owned });
            break :blk .{ .object = obj };
        },
    };
}

fn symbolToJson(a: Allocator, name: []const u8, opts: ToJsonOptions) Error!std.json.Value {
    const owned = try a.dupe(u8, name);
    return switch (opts.mode) {
        .compact => .{ .string = owned },
        .canonical, .full => blk: {
            var obj: std.json.ObjectMap = .empty;
            try obj.put(a, "$sym", .{ .string = owned });
            break :blk .{ .object = obj };
        },
    };
}

fn dateToJson(a: Allocator, d: Date, opts: ToJsonOptions) Error!std.json.Value {
    var buf: [10]u8 = undefined;
    d.formatCanonical(&buf);
    const owned = try a.dupe(u8, &buf);
    return switch (opts.mode) {
        .compact => .{ .string = owned },
        .canonical, .full => blk: {
            var obj: std.json.ObjectMap = .empty;
            try obj.put(a, "$date", .{ .string = owned });
            break :blk .{ .object = obj };
        },
    };
}

fn timeToJson(a: Allocator, t: Time, opts: ToJsonOptions) Error!std.json.Value {
    var buf: [12]u8 = undefined;
    const n = t.formatCanonical(&buf);
    const owned = try a.dupe(u8, buf[0..n]);
    return switch (opts.mode) {
        .compact => .{ .string = owned },
        .canonical, .full => blk: {
            var obj: std.json.ObjectMap = .empty;
            try obj.put(a, "$time", .{ .string = owned });
            break :blk .{ .object = obj };
        },
    };
}

fn vectorToJson(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    opts: ToJsonOptions,
) Error!std.json.Value {
    const elements = tree.vectorElements(idx);
    var arr = std.json.Array.init(a);
    try arr.ensureTotalCapacity(elements.len);
    for (elements) |e| arr.appendAssumeCapacity(try buildJson(a, tree, e, opts));
    return .{ .array = arr };
}

fn formToJson(
    a: Allocator,
    tree: *const Ast.Tree,
    idx: Ast.NodeIndex,
    opts: ToJsonOptions,
) Error!std.json.Value {
    const hdr = tree.formHeader(idx);

    if (opts.schema) |schema| {
        switch (schema.lookupExprFunc(hdr.head, hdr.namespace)) {
            .found => return try exprFormToJson(a, tree, hdr, opts),
            else => {},
        }
    }

    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$form", .{ .string = try escapeKey(a, hdr.head) });
    if (hdr.namespace) |ns| try obj.put(a, "$ns", .{ .string = try a.dupe(u8, ns) });

    var children = std.json.Array.init(a);
    for (hdr.children) |ch| {
        if (tree.tagOf(ch) == .kvpair) {
            const kvh = tree.kvpairHeader(ch);
            try obj.put(a, try escapeKey(a, kvh.key), try buildJson(a, tree, kvh.value, opts));
        } else {
            try children.append(try buildJson(a, tree, ch, opts));
        }
    }
    if (children.items.len > 0) {
        try obj.put(a, "$children", .{ .array = children });
    } else {
        children.deinit();
    }
    return .{ .object = obj };
}

fn exprFormToJson(
    a: Allocator,
    tree: *const Ast.Tree,
    hdr: Ast.FormHeader,
    opts: ToJsonOptions,
) Error!std.json.Value {
    var args = std.json.Array.init(a);
    try args.append(.{ .string = try escapeKey(a, hdr.head) });
    for (hdr.children) |ch| {
        if (tree.tagOf(ch) == .kvpair) return error.InvalidExprForm;
        try args.append(try buildJson(a, tree, ch, opts));
    }
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "$expr", .{ .array = args });
    if (hdr.namespace) |ns| try obj.put(a, "$ns", .{ .string = try a.dupe(u8, ns) });
    return .{ .object = obj };
}

pub fn fromJson(gpa: Allocator, value: std.json.Value, opts: FromJsonOptions) Error!Ast.Tree {
    var arena = ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var b: Ast.TreeBuilder = .{ .a = a };
    const root_idx = try buildAst(&b, value, opts);

    const roots = try a.alloc(Ast.NodeIndex, 1);
    roots[0] = root_idx;

    if (b.string_index.items.len == 0) {
        try b.string_index.append(a, 0);
    }

    return Ast.Tree{
        .arena = arena,
        .source = "",
        .nodes = b.nodes.toOwnedSlice(),
        .extra_data = b.extra_data.items,
        .strings = b.strings.items,
        .string_index = b.string_index.items,
        .root = roots,
        .leading_comments_index = b.leading_index.items,
        .trailing_comments_index = b.trailing_index.items,
        .comments = b.comments.toOwnedSlice(),
        .tree_trailing_comments = .empty,
        .diagnostics = &.{},
    };
}

pub fn fromJsonRoots(gpa: Allocator, value: std.json.Value, opts: FromJsonOptions) Error!Ast.Tree {
    var arena = ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidEncoding,
    };
    const roots_v = obj.get("$roots") orelse return error.InvalidEncoding;
    const items = switch (roots_v) {
        .array => |arr| arr.items,
        else => return error.InvalidEncoding,
    };

    var b: Ast.TreeBuilder = .{ .a = a };
    const roots = try a.alloc(Ast.NodeIndex, items.len);
    for (items, 0..) |item, i| {
        roots[i] = try buildAst(&b, item, opts);
    }

    if (b.string_index.items.len == 0) {
        try b.string_index.append(a, 0);
    }

    return Ast.Tree{
        .arena = arena,
        .source = "",
        .nodes = b.nodes.toOwnedSlice(),
        .extra_data = b.extra_data.items,
        .strings = b.strings.items,
        .string_index = b.string_index.items,
        .root = roots,
        .leading_comments_index = b.leading_index.items,
        .trailing_comments_index = b.trailing_index.items,
        .comments = b.comments.toOwnedSlice(),
        .tree_trailing_comments = .empty,
        .diagnostics = &.{},
    };
}

const zero_span: Ast.Span = .{ .start = 0, .end = 0 };

fn buildAst(b: *Ast.TreeBuilder, value: std.json.Value, opts: FromJsonOptions) Error!Ast.NodeIndex {
    return switch (value) {
        .null => try b.appendNode(.{ .tag = .nil, .span = zero_span, .data = .{ .immediate = 0 } }),
        .bool => |bo| try b.appendNode(.{
            .tag = if (bo) .boolean_true else .boolean_false,
            .span = zero_span,
            .data = .{ .immediate = 0 },
        }),
        .integer => |i| try makeNumberI64(b, i),
        .float => |f| try makeNumber(b, f),
        .number_string => |s| try numberStringToNode(b, s),
        .string => |s| blk: {
            const si = try b.addString(s);
            break :blk try b.appendNode(.{
                .tag = .string,
                .span = zero_span,
                .data = .{ .single = si.raw() },
            });
        },
        .array => |arr| try arrayToVector(b, arr, opts),
        .object => |obj| try objectToForm(b, obj, opts),
    };
}

fn makeNumber(b: *Ast.TreeBuilder, v: f64) Error!Ast.NodeIndex {
    return try b.appendNode(.{
        .tag = .number,
        .span = zero_span,
        .data = .{ .immediate = @bitCast(v) },
    });
}

fn makeNumberI64(b: *Ast.TreeBuilder, v: i64) Error!Ast.NodeIndex {
    return try b.appendNode(.{
        .tag = .number_i64,
        .span = zero_span,
        .data = .{ .immediate = @bitCast(v) },
    });
}

fn makeNumberU64(b: *Ast.TreeBuilder, v: u64) Error!Ast.NodeIndex {
    return try b.appendNode(.{
        .tag = .number_u64,
        .span = zero_span,
        .data = .{ .immediate = v },
    });
}

fn numberStringToNode(b: *Ast.TreeBuilder, s: []const u8) Error!Ast.NodeIndex {
    if (std.fmt.parseInt(i64, s, 10)) |iv| {
        return try makeNumberI64(b, iv);
    } else |_| {}
    if (s.len > 0 and s[0] != '-') {
        if (std.fmt.parseInt(u64, s, 10)) |uv| {
            return try makeNumberU64(b, uv);
        } else |_| {}
    }
    const f = std.fmt.parseFloat(f64, s) catch return error.InvalidEncoding;
    return try makeNumber(b, f);
}

fn arrayToVector(b: *Ast.TreeBuilder, arr: std.json.Array, opts: FromJsonOptions) Error!Ast.NodeIndex {
    var elements = try std.ArrayList(Ast.NodeIndex).initCapacity(b.a, arr.items.len);
    for (arr.items) |item| {
        elements.appendAssumeCapacity(try buildAst(b, item, opts));
    }
    return try b.addVector(elements.items, zero_span);
}

fn objectToForm(b: *Ast.TreeBuilder, obj: std.json.ObjectMap, opts: FromJsonOptions) Error!Ast.NodeIndex {
    if (obj.get("$roots") != null) return error.MultipleRoots;
    if (obj.get("$expr")) |expr_v| return try exprObjectToForm(b, obj, expr_v, opts);
    if (obj.get("$form")) |form_name_v| return try formObjectToForm(b, obj, form_name_v, opts);
    if (obj.get("$num")) |num_v| return try numObjectToNumber(b, num_v);
    if (obj.get("$kw")) |kw_v| {
        const name = switch (kw_v) {
            .string => |s| s,
            else => return error.InvalidEncoding,
        };
        const si = try b.addString(name);
        return try b.appendNode(.{
            .tag = .keyword,
            .span = zero_span,
            .data = .{ .single = si.raw() },
        });
    }
    if (obj.get("$sym")) |sym_v| {
        const name = switch (sym_v) {
            .string => |s| s,
            else => return error.InvalidEncoding,
        };
        const si = try b.addString(name);
        return try b.appendNode(.{
            .tag = .symbol,
            .span = zero_span,
            .data = .{ .single = si.raw() },
        });
    }
    if (obj.get("$date")) |date_v| {
        const text = switch (date_v) {
            .string => |s| s,
            else => return error.InvalidEncoding,
        };
        const d = Date.parse(text) catch return error.InvalidEncoding;
        return try b.appendNode(.{
            .tag = .date,
            .span = zero_span,
            .data = .{ .immediate = d.pack() },
        });
    }
    if (obj.get("$time")) |time_v| {
        const text = switch (time_v) {
            .string => |s| s,
            else => return error.InvalidEncoding,
        };
        const t = Time.parse(text) catch return error.InvalidEncoding;
        return try b.appendNode(.{
            .tag = .time,
            .span = zero_span,
            .data = .{ .immediate = t.pack() },
        });
    }
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        const k = entry.key_ptr.*;
        if (k.len > 0 and k[0] == '$' and !(k.len >= 2 and k[1] == '$')) {
            return error.UnknownDiscriminator;
        }
    }
    return error.InvalidEncoding;
}

fn numObjectToNumber(b: *Ast.TreeBuilder, num_v: std.json.Value) Error!Ast.NodeIndex {
    const items = switch (num_v) {
        .array => |arr| arr.items,
        else => return error.InvalidEncoding,
    };
    if (items.len != 2) return error.InvalidEncoding;
    const value: f64 = switch (items[0]) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return error.InvalidEncoding,
        else => return error.InvalidEncoding,
    };
    const unit_raw = switch (items[1]) {
        .string => |s| s,
        else => return error.InvalidEncoding,
    };
    if (unit_raw.len == 0) return error.InvalidEncoding;

    const unit_si = try b.addString(unit_raw);
    const bits: u64 = @bitCast(value);
    const hdr_at: u32 = @intCast(b.extra_data.items.len);
    try b.extra_data.appendSlice(b.a, &.{
        @truncate(bits),
        @truncate(bits >> 32),
        unit_si.raw(),
    });
    return try b.appendNode(.{
        .tag = .number_with_unit,
        .span = zero_span,
        .data = .{ .single = hdr_at },
    });
}

fn exprObjectToForm(b: *Ast.TreeBuilder, obj: std.json.ObjectMap, expr_v: std.json.Value, opts: FromJsonOptions) Error!Ast.NodeIndex {
    const items = switch (expr_v) {
        .array => |arr| arr.items,
        else => return error.InvalidExprForm,
    };
    if (items.len == 0) return error.InvalidExprForm;
    const head_raw = switch (items[0]) {
        .string => |s| s,
        else => return error.InvalidExprForm,
    };

    var namespace: ?[]const u8 = null;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (std.mem.eql(u8, k, "$expr")) continue;
        if (std.mem.eql(u8, k, "$ns")) {
            const ns = switch (entry.value_ptr.*) {
                .string => |s| s,
                else => return error.InvalidEncoding,
            };
            if (ns.len == 0) return error.InvalidEncoding;
            if (std.mem.indexOfScalar(u8, ns, '/') != null) return error.InvalidEncoding;
            namespace = ns;
            continue;
        }
        return error.UnknownDiscriminator;
    }
    return try makeFormNode(b, unescapeKey(head_raw), namespace, items[1..], &.{}, &.{}, opts);
}

fn formObjectToForm(
    b: *Ast.TreeBuilder,
    obj: std.json.ObjectMap,
    form_name_v: std.json.Value,
    opts: FromJsonOptions,
) Error!Ast.NodeIndex {
    const head_raw = switch (form_name_v) {
        .string => |s| s,
        else => return error.InvalidFormHead,
    };
    const namespace: ?[]const u8 = if (obj.get("$ns")) |ns_v| switch (ns_v) {
        .string => |s| s,
        else => return error.InvalidEncoding,
    } else null;

    const children_items: []const std.json.Value = if (obj.get("$children")) |c_v| switch (c_v) {
        .array => |arr| arr.items,
        else => return error.InvalidEncoding,
    } else &.{};

    var kp_keys: std.ArrayList([]const u8) = .empty;
    var kp_values: std.ArrayList(std.json.Value) = .empty;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (k.len > 0 and k[0] == '$') {
            if (isKnownFormDiscriminator(k)) continue;
            if (k.len >= 2 and k[1] == '$') {
                try kp_keys.append(b.a, unescapeKey(k));
                try kp_values.append(b.a, entry.value_ptr.*);
                continue;
            }
            return error.UnknownDiscriminator;
        }
        try kp_keys.append(b.a, k);
        try kp_values.append(b.a, entry.value_ptr.*);
    }

    return try makeFormNode(b, unescapeKey(head_raw), namespace, children_items, kp_keys.items, kp_values.items, opts);
}

fn makeFormNode(
    b: *Ast.TreeBuilder,
    head: []const u8,
    namespace: ?[]const u8,
    positional: []const std.json.Value,
    kp_keys: []const []const u8,
    kp_values: []const std.json.Value,
    opts: FromJsonOptions,
) Error!Ast.NodeIndex {
    var children = try std.ArrayList(Ast.NodeIndex).initCapacity(b.a, positional.len + kp_keys.len);

    for (kp_keys, kp_values) |k, v| {
        const value_idx = try buildAst(b, v, opts);
        const key_si = try b.addString(k);
        const kv_idx = try b.addKvpair(key_si, value_idx, zero_span, zero_span);
        children.appendAssumeCapacity(kv_idx);
    }
    for (positional) |v| {
        children.appendAssumeCapacity(try buildAst(b, v, opts));
    }

    const head_si = try b.addString(head);
    const ns_si: ?Ast.StringIndex = if (namespace) |n| try b.addString(n) else null;
    return try b.addForm(head_si, ns_si, zero_span, children.items, zero_span);
}
