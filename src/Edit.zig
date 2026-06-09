const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Parser = @import("Parser.zig");
const Printer = @import("Printer.zig");
const Json = @import("Json.zig");

pub const Options = struct {
    mode: Ast.Mode = .full,
    indent: u8 = 2,
    wrap_at: u16 = 60,

    pub fn forMode(mode: Ast.Mode) Options {
        return .{ .mode = mode };
    }
};

pub const Error = error{
    OutOfMemory,
    InvalidAction,
    InvalidPath,
    PathNotFound,
    PathTypeMismatch,
    EmptyTree,
    MultipleRoots,
    UnknownOp,
} || Json.Error;

pub fn applyEditToTree(
    gpa: Allocator,
    src: *const Ast.Tree,
    action: std.json.Value,
) Error!Ast.Tree {
    if (src.root.len == 0) return error.EmptyTree;
    if (src.root.len > 1) return error.MultipleRoots;
    const parsed = try decodeAction(action);
    return try buildEditedTree(gpa, src, parsed);
}

pub fn applyEdit(
    gpa: Allocator,
    source: [:0]const u8,
    action: std.json.Value,
    opts: Options,
) Error!Ast.Bytes {
    return applyEdits(gpa, source, &.{action}, opts);
}

pub fn applyEdits(
    gpa: Allocator,
    source: [:0]const u8,
    actions: []const std.json.Value,
    opts: Options,
) Error!Ast.Bytes {
    var cur = try Parser.parse(gpa, source);
    defer cur.deinit();

    for (actions) |action| {
        const next = try applyEditToTree(gpa, &cur, action);
        cur.deinit();
        cur = next;
    }

    return try Printer.print(gpa, cur, .{
        .mode = opts.mode,
        .indent = opts.indent,
        .wrap_at = opts.wrap_at,
    });
}

pub fn applyEditFromJsonString(
    gpa: Allocator,
    source: [:0]const u8,
    action_json: []const u8,
    opts: Options,
) Error!Ast.Bytes {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, action_json, .{}) catch
        return error.InvalidAction;
    defer parsed.deinit();
    return try applyEdit(gpa, source, parsed.value, opts);
}

pub fn applyEditsFromJsonString(
    gpa: Allocator,
    source: [:0]const u8,
    actions_json: []const u8,
    opts: Options,
) Error!Ast.Bytes {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, actions_json, .{}) catch
        return error.InvalidAction;
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a.items,
        else => return error.InvalidAction,
    };
    return try applyEdits(gpa, source, arr, opts);
}

const Action = union(enum) {
    set_keyword: struct { key: []const u8, value: std.json.Value },
    remove_keyword: struct { key: []const u8 },
    replace: struct { value: std.json.Value },
    insert_positional: struct { index: ?usize, value: std.json.Value },
    remove_positional: struct { index: usize },
};

const ParsedAction = struct {
    path: []const std.json.Value,
    action: Action,
};

fn decodeAction(action: std.json.Value) Error!ParsedAction {
    const obj = switch (action) {
        .object => |o| o,
        else => return error.InvalidAction,
    };
    const op = switch (obj.get("op") orelse return error.InvalidAction) {
        .string => |s| s,
        else => return error.InvalidAction,
    };
    const path = switch (obj.get("path") orelse return error.InvalidAction) {
        .array => |arr| arr.items,
        else => return error.InvalidPath,
    };

    if (std.mem.eql(u8, op, "set_keyword")) {
        const key = try requireString(obj, "key");
        const value = obj.get("value") orelse return error.InvalidAction;
        return .{ .path = path, .action = .{ .set_keyword = .{ .key = key, .value = value } } };
    } else if (std.mem.eql(u8, op, "remove_keyword")) {
        const key = try requireString(obj, "key");
        return .{ .path = path, .action = .{ .remove_keyword = .{ .key = key } } };
    } else if (std.mem.eql(u8, op, "replace")) {
        if (path.len == 0) return error.InvalidPath;
        const value = obj.get("value") orelse return error.InvalidAction;
        return .{ .path = path, .action = .{ .replace = .{ .value = value } } };
    } else if (std.mem.eql(u8, op, "insert_positional")) {
        const value = obj.get("value") orelse return error.InvalidAction;
        const idx_opt: ?usize = if (obj.get("index")) |iv| switch (iv) {
            .integer => |i| if (i < 0) return error.InvalidAction else @as(usize, @intCast(i)),
            else => return error.InvalidAction,
        } else null;
        return .{ .path = path, .action = .{ .insert_positional = .{ .index = idx_opt, .value = value } } };
    } else if (std.mem.eql(u8, op, "remove_positional")) {
        const idx: usize = switch (obj.get("index") orelse return error.InvalidAction) {
            .integer => |i| if (i < 0) return error.InvalidAction else @as(usize, @intCast(i)),
            else => return error.InvalidAction,
        };
        return .{ .path = path, .action = .{ .remove_positional = .{ .index = idx } } };
    }
    return error.UnknownOp;
}

fn requireString(obj: std.json.ObjectMap, name: []const u8) Error![]const u8 {
    const v = obj.get(name) orelse return error.InvalidAction;
    return switch (v) {
        .string => |s| s,
        else => error.InvalidAction,
    };
}

const Ctx = struct {
    gpa: Allocator,
    b: *Ast.TreeBuilder,
    src: *const Ast.Tree,
};

fn buildEditedTree(
    gpa: Allocator,
    src: *const Ast.Tree,
    parsed: ParsedAction,
) Error!Ast.Tree {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var b: Ast.TreeBuilder = .{ .a = a };
    const ctx: Ctx = .{ .gpa = gpa, .b = &b, .src = src };

    const new_root_idx = try applyAtPath(ctx, src.root[0], parsed.path, parsed.action);

    const new_root = try a.alloc(Ast.NodeIndex, 1);
    new_root[0] = new_root_idx;

    const tree_trailing = try b.cloneCommentRange(src, src.tree_trailing_comments);
    const diagnostics_dup = try a.dupe(Ast.Diagnostic, src.diagnostics);

    if (b.string_index.items.len == 0) {
        try b.string_index.append(a, 0);
    }

    return Ast.Tree{
        .arena = arena,
        .source = src.source,
        .nodes = b.nodes.toOwnedSlice(),
        .extra_data = b.extra_data.items,
        .strings = b.strings.items,
        .string_index = b.string_index.items,
        .root = new_root,
        .leading_comments_index = b.leading_index.items,
        .trailing_comments_index = b.trailing_index.items,
        .comments = b.comments.toOwnedSlice(),
        .tree_trailing_comments = tree_trailing,
        .diagnostics = diagnostics_dup,
    };
}

fn applyAtPath(
    ctx: Ctx,
    cur_idx: Ast.NodeIndex,
    path: []const std.json.Value,
    action: Action,
) Error!Ast.NodeIndex {
    if (path.len == 0) {
        return applyTypeA(ctx, cur_idx, action);
    }
    const step = path[0];
    const rest = path[1..];
    return switch (ctx.src.tagOf(cur_idx)) {
        .form => descendForm(ctx, cur_idx, step, rest, action),
        .vector => descendVector(ctx, cur_idx, step, rest, action),
        else => error.PathTypeMismatch,
    };
}

const FormSlot = struct {
    abs_idx: usize,
    is_kvpair: bool,
};

fn resolveFormStep(src: *const Ast.Tree, hdr: Ast.FormHeader, step: std.json.Value) Error!FormSlot {
    switch (step) {
        .integer => |raw| {
            if (raw < 0) return error.InvalidPath;
            const wanted: usize = @intCast(raw);
            var seen: usize = 0;
            for (hdr.children, 0..) |child_idx, abs| {
                if (src.tagOf(child_idx) != .kvpair) {
                    if (seen == wanted) return .{ .abs_idx = abs, .is_kvpair = false };
                    seen += 1;
                }
            }
            return error.PathNotFound;
        },
        .string => |key| {
            for (hdr.children, 0..) |child_idx, abs| {
                if (src.tagOf(child_idx) == .kvpair) {
                    const kvh = src.kvpairHeader(child_idx);
                    if (std.mem.eql(u8, kvh.key, key)) {
                        return .{ .abs_idx = abs, .is_kvpair = true };
                    }
                }
            }
            return error.PathNotFound;
        },
        else => return error.InvalidPath,
    }
}

fn descendForm(
    ctx: Ctx,
    form_idx: Ast.NodeIndex,
    step: std.json.Value,
    rest: []const std.json.Value,
    action: Action,
) Error!Ast.NodeIndex {
    const hdr = ctx.src.formHeader(form_idx);
    const slot = try resolveFormStep(ctx.src, hdr, step);
    const slot_child = hdr.children[slot.abs_idx];

    if (rest.len == 0 and action == .replace) {
        const new_value = try buildJsonValue(ctx, action.replace.value);
        const new_slot_child = if (slot.is_kvpair)
            try cloneKvpairShellNewValue(ctx, slot_child, new_value)
        else
            new_value;
        return rebuildFormSwapSlot(ctx, form_idx, hdr, slot.abs_idx, new_slot_child);
    }

    const recurse_target = if (slot.is_kvpair)
        ctx.src.kvpairHeader(slot_child).value
    else
        slot_child;
    const new_inner = try applyAtPath(ctx, recurse_target, rest, action);
    const new_slot_child = if (slot.is_kvpair)
        try cloneKvpairShellNewValue(ctx, slot_child, new_inner)
    else
        new_inner;
    return rebuildFormSwapSlot(ctx, form_idx, hdr, slot.abs_idx, new_slot_child);
}

fn descendVector(
    ctx: Ctx,
    vec_idx: Ast.NodeIndex,
    step: std.json.Value,
    rest: []const std.json.Value,
    action: Action,
) Error!Ast.NodeIndex {
    const elements = ctx.src.vectorElements(vec_idx);
    const want: usize = switch (step) {
        .integer => |raw| if (raw < 0) return error.InvalidPath else @as(usize, @intCast(raw)),
        else => return error.InvalidPath,
    };
    if (want >= elements.len) return error.PathNotFound;

    const new_elem = if (rest.len == 0 and action == .replace)
        try buildJsonValue(ctx, action.replace.value)
    else
        try applyAtPath(ctx, elements[want], rest, action);

    return rebuildVectorSwapSlot(ctx, vec_idx, elements, want, new_elem);
}

fn applyTypeA(ctx: Ctx, cur_idx: Ast.NodeIndex, action: Action) Error!Ast.NodeIndex {
    const tag = ctx.src.tagOf(cur_idx);
    switch (action) {
        .set_keyword => |args| {
            if (tag != .form) return error.PathTypeMismatch;
            return setKeywordAt(ctx, cur_idx, args.key, args.value);
        },
        .remove_keyword => |args| {
            if (tag != .form) return error.PathTypeMismatch;
            return removeKeywordAt(ctx, cur_idx, args.key);
        },
        .insert_positional => |args| switch (tag) {
            .form => return insertPositionalForm(ctx, cur_idx, args.index, args.value),
            .vector => return insertPositionalVector(ctx, cur_idx, args.index, args.value),
            else => return error.PathTypeMismatch,
        },
        .remove_positional => |args| switch (tag) {
            .form => return removePositionalForm(ctx, cur_idx, args.index),
            .vector => return removePositionalVector(ctx, cur_idx, args.index),
            else => return error.PathTypeMismatch,
        },
        .replace => unreachable,
    }
}

fn setKeywordAt(
    ctx: Ctx,
    form_idx: Ast.NodeIndex,
    key: []const u8,
    value: std.json.Value,
) Error!Ast.NodeIndex {
    const hdr = ctx.src.formHeader(form_idx);
    const new_value_idx = try buildJsonValue(ctx, value);

    var existing_abs: ?usize = null;
    for (hdr.children, 0..) |child_idx, abs| {
        if (ctx.src.tagOf(child_idx) == .kvpair) {
            const kvh = ctx.src.kvpairHeader(child_idx);
            if (std.mem.eql(u8, kvh.key, key)) {
                existing_abs = abs;
                break;
            }
        }
    }

    if (existing_abs) |target_abs| {
        const new_kv = try cloneKvpairShellNewValue(ctx, hdr.children[target_abs], new_value_idx);
        return rebuildFormSwapSlot(ctx, form_idx, hdr, target_abs, new_kv);
    }

    var new_children = try std.ArrayList(Ast.NodeIndex).initCapacity(ctx.b.a, hdr.children.len + 1);
    for (hdr.children) |child_idx| {
        new_children.appendAssumeCapacity(try ctx.b.cloneNode(ctx.src, child_idx));
    }
    const key_si = try ctx.b.addString(key);
    const new_kv = try ctx.b.addKvpair(
        key_si,
        new_value_idx,
        .{ .start = 0, .end = 0 },
        .{ .start = 0, .end = 0 },
    );
    new_children.appendAssumeCapacity(new_kv);
    return cloneFormShell(ctx, form_idx, new_children.items);
}

fn removeKeywordAt(
    ctx: Ctx,
    form_idx: Ast.NodeIndex,
    key: []const u8,
) Error!Ast.NodeIndex {
    const hdr = ctx.src.formHeader(form_idx);
    var target_abs: ?usize = null;
    for (hdr.children, 0..) |child_idx, abs| {
        if (ctx.src.tagOf(child_idx) == .kvpair) {
            const kvh = ctx.src.kvpairHeader(child_idx);
            if (std.mem.eql(u8, kvh.key, key)) {
                target_abs = abs;
                break;
            }
        }
    }
    if (target_abs == null) return error.PathNotFound;
    return rebuildFormDropSlot(ctx, form_idx, hdr, target_abs.?);
}

fn insertPositionalForm(
    ctx: Ctx,
    form_idx: Ast.NodeIndex,
    index_opt: ?usize,
    value: std.json.Value,
) Error!Ast.NodeIndex {
    const hdr = ctx.src.formHeader(form_idx);
    const new_value_idx = try buildJsonValue(ctx, value);

    const insert_at: usize = blk: {
        if (index_opt) |want| {
            var seen: usize = 0;
            for (hdr.children, 0..) |child_idx, abs| {
                if (ctx.src.tagOf(child_idx) != .kvpair) {
                    if (seen == want) break :blk abs;
                    seen += 1;
                }
            }
            if (want > seen) return error.PathNotFound;
            break :blk hdr.children.len;
        }
        break :blk hdr.children.len;
    };

    var new_children = try std.ArrayList(Ast.NodeIndex).initCapacity(ctx.b.a, hdr.children.len + 1);
    for (hdr.children, 0..) |child_idx, abs| {
        if (abs == insert_at) new_children.appendAssumeCapacity(new_value_idx);
        new_children.appendAssumeCapacity(try ctx.b.cloneNode(ctx.src, child_idx));
    }
    if (insert_at == hdr.children.len) new_children.appendAssumeCapacity(new_value_idx);
    return cloneFormShell(ctx, form_idx, new_children.items);
}

fn insertPositionalVector(
    ctx: Ctx,
    vec_idx: Ast.NodeIndex,
    index_opt: ?usize,
    value: std.json.Value,
) Error!Ast.NodeIndex {
    const elements = ctx.src.vectorElements(vec_idx);
    const new_value_idx = try buildJsonValue(ctx, value);

    const insert_at: usize = if (index_opt) |i|
        if (i > elements.len) return error.PathNotFound else i
    else
        elements.len;

    var new_elements = try std.ArrayList(Ast.NodeIndex).initCapacity(ctx.b.a, elements.len + 1);
    for (elements, 0..) |elem_idx, i| {
        if (i == insert_at) new_elements.appendAssumeCapacity(new_value_idx);
        new_elements.appendAssumeCapacity(try ctx.b.cloneNode(ctx.src, elem_idx));
    }
    if (insert_at == elements.len) new_elements.appendAssumeCapacity(new_value_idx);
    return cloneVectorShell(ctx, vec_idx, new_elements.items);
}

fn removePositionalForm(
    ctx: Ctx,
    form_idx: Ast.NodeIndex,
    index: usize,
) Error!Ast.NodeIndex {
    const hdr = ctx.src.formHeader(form_idx);
    var target_abs: ?usize = null;
    var seen: usize = 0;
    for (hdr.children, 0..) |child_idx, abs| {
        if (ctx.src.tagOf(child_idx) != .kvpair) {
            if (seen == index) {
                target_abs = abs;
                break;
            }
            seen += 1;
        }
    }
    if (target_abs == null) return error.PathNotFound;
    return rebuildFormDropSlot(ctx, form_idx, hdr, target_abs.?);
}

fn removePositionalVector(
    ctx: Ctx,
    vec_idx: Ast.NodeIndex,
    index: usize,
) Error!Ast.NodeIndex {
    const elements = ctx.src.vectorElements(vec_idx);
    if (index >= elements.len) return error.PathNotFound;

    var new_elements = try std.ArrayList(Ast.NodeIndex).initCapacity(ctx.b.a, elements.len - 1);
    for (elements, 0..) |elem_idx, i| {
        if (i == index) continue;
        new_elements.appendAssumeCapacity(try ctx.b.cloneNode(ctx.src, elem_idx));
    }
    return cloneVectorShell(ctx, vec_idx, new_elements.items);
}

fn rebuildFormSwapSlot(
    ctx: Ctx,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    slot_abs: usize,
    new_slot_child: Ast.NodeIndex,
) Error!Ast.NodeIndex {
    var new_children = try std.ArrayList(Ast.NodeIndex).initCapacity(ctx.b.a, hdr.children.len);
    for (hdr.children, 0..) |child_idx, abs| {
        if (abs == slot_abs) {
            new_children.appendAssumeCapacity(new_slot_child);
        } else {
            new_children.appendAssumeCapacity(try ctx.b.cloneNode(ctx.src, child_idx));
        }
    }
    return cloneFormShell(ctx, form_idx, new_children.items);
}

fn rebuildFormDropSlot(
    ctx: Ctx,
    form_idx: Ast.NodeIndex,
    hdr: Ast.FormHeader,
    slot_abs: usize,
) Error!Ast.NodeIndex {
    var new_children = try std.ArrayList(Ast.NodeIndex).initCapacity(ctx.b.a, hdr.children.len - 1);
    for (hdr.children, 0..) |child_idx, abs| {
        if (abs == slot_abs) continue;
        new_children.appendAssumeCapacity(try ctx.b.cloneNode(ctx.src, child_idx));
    }
    return cloneFormShell(ctx, form_idx, new_children.items);
}

fn rebuildVectorSwapSlot(
    ctx: Ctx,
    vec_idx: Ast.NodeIndex,
    elements: []const Ast.NodeIndex,
    target: usize,
    new_elem: Ast.NodeIndex,
) Error!Ast.NodeIndex {
    var new_elements = try std.ArrayList(Ast.NodeIndex).initCapacity(ctx.b.a, elements.len);
    for (elements, 0..) |elem_idx, i| {
        if (i == target) {
            new_elements.appendAssumeCapacity(new_elem);
        } else {
            new_elements.appendAssumeCapacity(try ctx.b.cloneNode(ctx.src, elem_idx));
        }
    }
    return cloneVectorShell(ctx, vec_idx, new_elements.items);
}

fn cloneFormShell(
    ctx: Ctx,
    src_idx: Ast.NodeIndex,
    new_children: []const Ast.NodeIndex,
) Error!Ast.NodeIndex {
    const hdr = ctx.src.formHeader(src_idx);
    const head_si = try ctx.b.addString(hdr.head);
    const ns_si: ?Ast.StringIndex = if (hdr.namespace) |n| try ctx.b.addString(n) else null;
    const span = ctx.src.spanOf(src_idx);
    const new_idx = try ctx.b.addForm(head_si, ns_si, hdr.head_span, new_children, span);

    const leading = try ctx.b.cloneCommentRange(ctx.src, ctx.src.leading_comments_index[src_idx.raw()]);
    ctx.b.setLeading(new_idx, leading);
    const trailing = try ctx.b.cloneCommentRange(ctx.src, ctx.src.trailing_comments_index[src_idx.raw()]);
    ctx.b.setTrailing(new_idx, trailing);
    return new_idx;
}

fn cloneVectorShell(
    ctx: Ctx,
    src_idx: Ast.NodeIndex,
    new_elements: []const Ast.NodeIndex,
) Error!Ast.NodeIndex {
    const span = ctx.src.spanOf(src_idx);
    const new_idx = try ctx.b.addVector(new_elements, span);
    const leading = try ctx.b.cloneCommentRange(ctx.src, ctx.src.leading_comments_index[src_idx.raw()]);
    ctx.b.setLeading(new_idx, leading);
    return new_idx;
}

fn cloneKvpairShellNewValue(
    ctx: Ctx,
    src_idx: Ast.NodeIndex,
    new_value: Ast.NodeIndex,
) Error!Ast.NodeIndex {
    const kvh = ctx.src.kvpairHeader(src_idx);
    const key_si = try ctx.b.addString(kvh.key);
    const span = ctx.src.spanOf(src_idx);
    const new_idx = try ctx.b.addKvpair(key_si, new_value, kvh.key_span, span);
    const leading = try ctx.b.cloneCommentRange(ctx.src, ctx.src.leading_comments_index[src_idx.raw()]);
    ctx.b.setLeading(new_idx, leading);
    return new_idx;
}

fn buildJsonValue(ctx: Ctx, value: std.json.Value) Error!Ast.NodeIndex {
    var tmp = try Json.fromJson(ctx.gpa, value, .{});
    defer tmp.deinit();
    return try ctx.b.cloneNode(&tmp, tmp.root[0]);
}

const testing = std.testing;

fn parseAction(a: Allocator, json_text: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, a, json_text, .{});
}
