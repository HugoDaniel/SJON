//! Editor-shaped structural edits over an `Ast.Tree`.
//!
//! `applyEdit(gpa, source, action)` is the v0.1 thin glue:
//!     parse source → build edited tree (functional rebuild) → print
//!
//! It is meant for editor reducers and downstream tooling. The action is a
//! JSON value carrying an `op`, a `path` (chain of steps from `tree.root[0]`),
//! and operation-specific fields. v0.1 mutations stay structural — the
//! re-printed source is canonical or full (default); comments on
//! untouched subtrees survive the round-trip in full mode.
//!
//! Phase 14: Edit operates entirely on the immutable SoA `Ast.Tree`. The
//! parse path is `Parser.parse → Ast.Tree`; the rebuild walks the source
//! tree pre-order, calling `TreeBuilder.cloneNode` for untouched subtrees
//! and synthesising new nodes (via `Json.fromJson` + `cloneNode`) at the
//! edit target.
//!
//! ## Path
//!
//! `path` is a JSON array of steps. Each step descends one level from
//! the previous node:
//!
//!   * integer N — for forms: visit the N-th positional child (0-indexed,
//!                 keyword pairs skipped).
//!                 for vectors: visit `elements[N]`.
//!   * string  S — for forms only: visit the value of the keyword pair
//!                 with key `S`. (Strings inside vector paths are an error.)
//!
//! An empty path resolves to `tree.root[0]` itself.
//!
//! ## Operations
//!
//!   * `set_keyword`   { path, key, value }
//!       At a form node, set or insert keyword `:key` with `value` (decoded
//!       through `Json.fromJson`). If the key already exists, replace its
//!       value preserving source order (and the kvpair's leading
//!       comments + key_span); otherwise append after the last existing
//!       child.
//!   * `remove_keyword` { path, key }
//!       At a form node, remove the keyword pair `:key` if present.
//!   * `replace`       { path, value }
//!       Replace the path's target node in its container slot with the
//!       JSON-decoded value. Path may not be empty (root replacement is
//!       expressible via `replace_root`, omitted in v0.1 — re-emit the
//!       whole source instead).
//!   * `insert_positional` { path, value, index? }
//!       At a form/vector node, insert a positional child / element at
//!       `index` (default: append). Existing children shift right.
//!   * `remove_positional` { path, index }
//!       At a form/vector node, remove the positional child / element at
//!       the given positional index.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Parser = @import("Parser.zig");
const Printer = @import("Printer.zig");
const Json = @import("Json.zig");

/// Tunables for `applyEdit`.
pub const Options = struct {
    /// Output mode. `.full` (default) preserves comment trivia on
    /// untouched subtrees — appropriate for editor-driven edits. Use
    /// `.canonical` for deterministic, comment-free output.
    mode: Ast.Mode = .full,
    /// Spaces per indentation level (forwarded to the printer).
    indent: u8 = 2,
    /// Soft column budget (forwarded to the printer).
    wrap_at: u16 = 60,

    /// Parallel to `Binary.ToBinaryOptions.forMode` so the encoder
    /// family has one blessed construction style.
    pub fn forMode(mode: Ast.Mode) Options {
        return .{ .mode = mode };
    }
};

/// Errors `applyEdit` and `applyEditFromJsonString` can return. Includes
/// every variant from `Json.Error` since structural edits decode embedded
/// JSON values through the JSON bridge — that union also supplies
/// `DepthExceeded`, which `decodeAction` raises when the action's `path`
/// array is longer than `MAX_EDIT_PATH_DEPTH` (the `applyAtPath` descent
/// recurses once per path step, and the action is untrusted JSON at the
/// kitchen-sink wasm boundary).
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

/// Ceiling on edit-path length, deliberately equal to
/// `Parser.MAX_PARSE_DEPTH` (1024): the `applyAtPath` walk recurses once
/// per path step, so this bounds that host recursion regardless of the
/// target tree's shape (a caller-supplied `Ast.Tree` passed to
/// `applyEditToTree` need not have come from the depth-capped parser).
pub const MAX_EDIT_PATH_DEPTH: u32 = Parser.MAX_PARSE_DEPTH;

/// Apply `action` to `src` and return the edited tree. Caller releases
/// via `tree.deinit()`. Useful when the caller already has a parsed tree
/// (e.g. an editor that maintains a live tree across edits) — avoids the
/// parse/print round-trip that `applyEdit` performs for source-bytes
/// callers. `src` is not modified.
///
/// The edited tree owns all of its *arena* memory independently of `src` —
/// nodes, strings, comments, and diagnostics are copied (diagnostics via
/// `Diagnostic.dupe`, so they no longer alias `src`'s arena). The one
/// borrow is `.source`: it aliases `src.source` (spans on the rebuilt
/// nodes index into it), exactly as a `parse`d tree borrows the caller's
/// source — so `src.source`'s backing must outlive the edited tree, even
/// after `src.deinit()`.
///
/// Complexity: O(n) where n = `src.nodes.len` — one functional rebuild
/// walking every node, transforming at the path target. `action` is
/// borrowed read-only; embedded JSON values are deep-copied into the
/// returned tree's arena.
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

/// Parse `source`, apply the JSON-encoded `action`, re-print, and return
/// the printed bytes as `Ast.Bytes`. Caller releases via `bytes.deinit()`.
/// Composition: `parse → applyEditToTree → print` — delegates to
/// `applyEdits` with a one-element batch.
///
/// Complexity: O(n + m) where n = `source.len`, m = output size — three
/// linear passes (parse, edit-rebuild, print). `source` and `action`
/// are both borrowed read-only.
pub fn applyEdit(
    gpa: Allocator,
    source: [:0]const u8,
    action: std.json.Value,
    opts: Options,
) Error!Ast.Bytes {
    return applyEdits(gpa, source, &.{action}, opts);
}

/// Parse `source` once, apply `actions` left-to-right in a single pass,
/// re-print once, and return the printed bytes as `Ast.Bytes`. Caller
/// releases via `bytes.deinit()`. This is the batched counterpart to
/// `applyEdit`: instead of N parse/print round-trips it parses once, folds
/// the functional rebuild (`applyEditToTree`, tree→tree) over each action —
/// freeing the prior intermediate tree at every hop — and prints the final
/// tree. The observable result is identical to threading `applyEdit`'s
/// output through each action; only the parse/print overhead collapses.
///
/// An empty `actions` slice re-prints `source` in the requested mode (a
/// canonical/full no-op). A failing action aborts the whole batch (the
/// partially-rebuilt tree is dropped, nothing is printed) — batches are
/// all-or-nothing.
///
/// Complexity: O(n + k·m + p) — one parse (n), k functional rebuilds (each
/// O(m), one full tree walk), one print (p). `source` and every element of
/// `actions` are borrowed read-only; embedded JSON values are deep-copied
/// into the working tree's arena, so `actions` may be freed once this
/// returns.
pub fn applyEdits(
    gpa: Allocator,
    source: [:0]const u8,
    actions: []const std.json.Value,
    opts: Options,
) Error!Ast.Bytes {
    var cur = try Parser.parse(gpa, source);
    // Frees whichever tree `cur` names at scope exit: the parsed tree if we
    // never enter the loop / a rebuild fails, otherwise the final fold
    // result. Each hop deinits the prior tree before overwriting `cur`, so
    // no value is freed twice.
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

/// Convenience overload that parses a JSON-encoded action string. The
/// caller's `gpa` is used both for the JSON parse arena and the final
/// output buffer.
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

/// Convenience overload that parses a JSON-encoded **array** of actions.
/// The parse arena outlives the whole fold (actions borrow into it), so the
/// `defer parsed.deinit()` is correct — `applyEdits` deep-copies every
/// embedded value before this returns.
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

// ---------------------------------------------------------------------------
// Action decoding
// ---------------------------------------------------------------------------

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
    // Bound the `applyAtPath` recursion up front: it descends one level per
    // path step, so an over-long path from untrusted JSON would otherwise
    // recurse without limit on a sufficiently deep target tree.
    if (path.len > MAX_EDIT_PATH_DEPTH) return error.DepthExceeded;

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

// ---------------------------------------------------------------------------
// Functional rebuild
// ---------------------------------------------------------------------------

const Ctx = struct {
    gpa: Allocator,
    b: *Ast.TreeBuilder,
    src: *const Ast.Tree,
};

/// Build a new `Ast.Tree` that is `src` with `parsed.action` applied at
/// `parsed.path`. Caller has already guaranteed `src.root.len == 1`
/// (zero → `EmptyTree`, multi → `MultipleRoots`, both rejected upstream).
fn buildEditedTree(
    gpa: Allocator,
    src: *const Ast.Tree,
    parsed: ParsedAction,
) Error!Ast.Tree {
    // Callers (applyEditToTree) reject an empty / multi-root tree with a
    // diagnostic before reaching here, so `src.root[0]` below is in bounds.
    std.debug.assert(src.root.len == 1);

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var b: Ast.TreeBuilder = .{ .a = a };
    const ctx: Ctx = .{ .gpa = gpa, .b = &b, .src = src };

    const new_root_idx = try applyAtPath(ctx, src.root[0], parsed.path, parsed.action);

    const new_root = try a.alloc(Ast.NodeIndex, 1);
    new_root[0] = new_root_idx;

    const tree_trailing = try b.cloneCommentRange(src, src.tree_trailing_comments);
    // Deep-copy: a plain `a.dupe(Ast.Diagnostic, …)` copies the structs by
    // value but leaves their `message`/`path` slices pointing into `src`'s
    // arena, so the edited tree would dangle once the caller frees `src`.
    const diagnostics_dup = try a.alloc(Ast.Diagnostic, src.diagnostics.len);
    for (src.diagnostics, diagnostics_dup) |d, *out| out.* = try d.dupe(a);

    return b.finalizeWith(&arena, src.source, new_root, .{
        .tree_trailing_comments = tree_trailing,
        .diagnostics = diagnostics_dup,
    });
}

/// Recursively walk `path` from `cur_idx`. At each step, descend into the
/// path child while cloning every other child. At path exhaustion, apply
/// the type-A action (set/remove/insert/remove_positional) at the
/// current node. Type-B `replace` is consumed by the parent at the final
/// step (where `path.len == 1`).
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
    /// True when the slot's child is a kvpair node (the step was a string).
    /// `replace` and recursive descent operate on the kvpair's *value* in
    /// this case, not the kvpair node itself.
    is_kvpair: bool,
};

/// Absolute index within `hdr.children` of the kvpair whose key equals `key`,
/// or null when the form has no such keyword child. The three keyword editors
/// (resolve / set / remove) share this scan so they cannot disagree on what
/// "the `:key` slot" is.
fn findKeywordSlot(src: *const Ast.Tree, hdr: Ast.FormHeader, key: []const u8) ?usize {
    for (hdr.children, 0..) |child_idx, abs| {
        if (src.tagOf(child_idx) == .kvpair) {
            const kvh = src.kvpairHeader(child_idx);
            if (std.mem.eql(u8, kvh.key, key)) return abs;
        }
    }
    return null;
}

/// Result of locating the `n`th positional (non-kvpair) child of a form.
const PositionalSlot = struct {
    /// Absolute index within `hdr.children` of the `n`th positional child, or
    /// null when the form has `<= n` positionals.
    abs: ?usize,
    /// Total number of positional children in the form.
    count: usize,
};

/// Locate the `n`th positional (non-kvpair) child of a form. Scans the whole
/// child list so `count` is always the full positional total — the insert
/// editor needs it to tell "append at the end" (`n == count`) from "out of
/// range" (`n > count`); the resolve / remove editors read only `abs`. Shared
/// so the three positional editors count positionals the same way.
fn findPositionalSlot(src: *const Ast.Tree, hdr: Ast.FormHeader, n: usize) PositionalSlot {
    var abs: ?usize = null;
    var count: usize = 0;
    for (hdr.children, 0..) |child_idx, i| {
        if (src.tagOf(child_idx) != .kvpair) {
            if (count == n) abs = i;
            count += 1;
        }
    }
    // `abs` is a child-list index when set, and it is set exactly when the
    // form has more than `n` positionals (the scan passed through slot `n`).
    if (abs) |a| std.debug.assert(a < hdr.children.len);
    std.debug.assert((abs != null) == (n < count));
    return .{ .abs = abs, .count = count };
}

fn resolveFormStep(src: *const Ast.Tree, hdr: Ast.FormHeader, step: std.json.Value) Error!FormSlot {
    switch (step) {
        .integer => |raw| {
            if (raw < 0) return error.InvalidPath;
            const wanted: usize = @intCast(raw);
            if (findPositionalSlot(src, hdr, wanted).abs) |abs| {
                return .{ .abs_idx = abs, .is_kvpair = false };
            }
            return error.PathNotFound;
        },
        .string => |key| {
            if (findKeywordSlot(src, hdr, key)) |abs| {
                return .{ .abs_idx = abs, .is_kvpair = true };
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

    // `replace` at the final step substitutes this slot directly.
    if (rest.len == 0 and action == .replace) {
        const new_value = try buildJsonValue(ctx, action.replace.value);
        const new_slot_child = if (slot.is_kvpair)
            try cloneKvpairShellNewValue(ctx, slot_child, new_value)
        else
            new_value;
        return rebuildFormSwapSlot(ctx, form_idx, hdr, slot.abs_idx, new_slot_child);
    }

    // Otherwise descend into the slot's value and rebuild this form with
    // the recursive result swapped in.
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

// ---------------------------------------------------------------------------
// Type-A: act on the target node directly
// ---------------------------------------------------------------------------

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
        // `replace` requires non-empty path; the parent at the final step
        // consumes it before we get here.
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

    if (findKeywordSlot(ctx.src, hdr, key)) |target_abs| {
        const new_kv = try cloneKvpairShellNewValue(ctx, hdr.children[target_abs], new_value_idx);
        return rebuildFormSwapSlot(ctx, form_idx, hdr, target_abs, new_kv);
    }

    // Append a fresh kvpair after the last existing child. key_span and
    // span use zero-width placeholders since this kvpair is synthesized.
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
    const target_abs = findKeywordSlot(ctx.src, hdr, key) orelse return error.PathNotFound;
    return rebuildFormDropSlot(ctx, form_idx, hdr, target_abs);
}

fn insertPositionalForm(
    ctx: Ctx,
    form_idx: Ast.NodeIndex,
    index_opt: ?usize,
    value: std.json.Value,
) Error!Ast.NodeIndex {
    const hdr = ctx.src.formHeader(form_idx);
    const new_value_idx = try buildJsonValue(ctx, value);

    // Translate positional ordinal to an absolute slot. Default: append.
    const insert_at: usize = blk: {
        if (index_opt) |want| {
            const slot = findPositionalSlot(ctx.src, hdr, want);
            if (slot.abs) |abs| break :blk abs; // insert before the want-th positional
            if (want > slot.count) return error.PathNotFound;
            break :blk hdr.children.len; // want == count → append after the last child
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
    const target_abs = findPositionalSlot(ctx.src, hdr, index).abs orelse return error.PathNotFound;
    return rebuildFormDropSlot(ctx, form_idx, hdr, target_abs);
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

// ---------------------------------------------------------------------------
// Shell helpers — clone the structural skin of a node with new children
// ---------------------------------------------------------------------------

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
    // Trailing comments (before `]`) too — parity with cloneFormShell.
    const trailing = try ctx.b.cloneCommentRange(ctx.src, ctx.src.trailing_comments_index[src_idx.raw()]);
    ctx.b.setTrailing(new_idx, trailing);
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

/// Decode a JSON edit value into a `NodeIndex` in our destination builder.
/// Routes through `Json.fromJson` (which builds a temp single-root Tree)
/// and `cloneNode` (which re-interns into our pool). The temp tree's
/// arena uses `gpa` independently, so its lifetime ends here.
fn buildJsonValue(ctx: Ctx, value: std.json.Value) Error!Ast.NodeIndex {
    var tmp = try Json.fromJson(ctx.gpa, value, .{});
    defer tmp.deinit();
    return try ctx.b.cloneNode(&tmp, tmp.root[0]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseAction(a: Allocator, json_text: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, a, json_text, .{});
}

test "set_keyword: replace existing keyword value" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(scene :bpm 130)",
        \\{"op":"set_keyword","path":[],"key":"bpm","value":140}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(scene :bpm 140)\n", got.data);
}

test "set_keyword: append when key missing" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(scene :bpm 130)",
        \\{"op":"set_keyword","path":[],"key":"name","value":"main"}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(scene :bpm 130 :name \"main\")\n", got.data);
}

test "remove_keyword: erases the keyword pair" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(scene :bpm 130 :name \"main\")",
        \\{"op":"remove_keyword","path":[],"key":"bpm"}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(scene :name \"main\")\n", got.data);
}

test "set_keyword: descend by keyword path" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(scene :canvas (canvas :name \"main\"))",
        \\{"op":"set_keyword","path":["canvas"],"key":"name","value":"alt"}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings(
        "(scene :canvas (canvas :name \"alt\"))\n",
        got.data,
    );
}

test "set_keyword: descend by positional index" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(scene (canvas :name \"main\"))",
        \\{"op":"set_keyword","path":[0],"key":"name","value":"alt"}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings(
        "(scene (canvas :name \"alt\"))\n",
        got.data,
    );
}

test "replace: swap a positional child for a literal" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(stack 1 2 3)",
        \\{"op":"replace","path":[1],"value":99}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(stack 1 99 3)\n", got.data);
}

test "replace: swap a keyword's value via path" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(scene :bpm 130)",
        \\{"op":"replace","path":["bpm"],"value":140}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(scene :bpm 140)\n", got.data);
}

test "replace: build a form via $form encoding" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(scene :bpm 130)",
        \\{"op":"replace","path":["bpm"],"value":{"$form":"beat","$children":[4]}}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(scene :bpm (beat 4))\n", got.data);
}

test "insert_positional: append by default" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(stack 1 2)",
        \\{"op":"insert_positional","path":[],"value":3}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(stack 1 2 3)\n", got.data);
}

test "insert_positional: at explicit index shifts right" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(stack 1 3)",
        \\{"op":"insert_positional","path":[],"index":1,"value":2}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(stack 1 2 3)\n", got.data);
}

test "insert_positional: into a vector" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(stack [1 3])",
        \\{"op":"insert_positional","path":[0],"index":1,"value":2}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(stack [1 2 3])\n", got.data);
}

test "remove_positional: drops the indexed positional" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(stack 1 2 3)",
        \\{"op":"remove_positional","path":[],"index":1}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(stack 1 3)\n", got.data);
}

test "lossless mode preserves comments on untouched subtree" {
    const src =
        \\(scene
        \\  ; tempo
        \\  :bpm 130
        \\  ; about to declare canvas
        \\  (canvas :name "main"))
    ;
    const got = try applyEditFromJsonString(
        testing.allocator,
        src,
        \\{"op":"set_keyword","path":[],"key":"bpm","value":140}
    ,
        .{ .mode = .full },
    );
    defer got.deinit();
    try testing.expectEqualStrings(
        \\(scene
        \\  ; tempo
        \\  :bpm 140
        \\  ; about to declare canvas
        \\  (canvas :name "main"))
        \\
    , got.data);
}

test "unknown op surfaces error" {
    try testing.expectError(error.UnknownOp, applyEditFromJsonString(
        testing.allocator,
        "(scene)",
        \\{"op":"explode","path":[]}
    ,
        .{},
    ));
}

test "invalid path returns PathNotFound" {
    try testing.expectError(error.PathNotFound, applyEditFromJsonString(
        testing.allocator,
        "(scene :bpm 130)",
        \\{"op":"remove_keyword","path":[],"key":"missing"}
    ,
        .{},
    ));
}

test "path into atom rejected" {
    try testing.expectError(error.PathTypeMismatch, applyEditFromJsonString(
        testing.allocator,
        "42",
        \\{"op":"set_keyword","path":[0],"key":"k","value":1}
    ,
        .{},
    ));
}

test "set_keyword: replace value with $num-encoded unit number" {
    // Edits route the value through Json.fromJson → the JSON discriminator
    // handler → `$num` produces a NumberValue with unit. Pin that this
    // path is wired and produces canonical output.
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(scene :angle 0)",
        \\{"op":"set_keyword","path":[],"key":"angle","value":{"$num":[90,"deg"]}}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(scene :angle 90deg)\n", got.data);
}

test "replace: swap a positional with a $num-encoded unit number" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(stack 1 2 3)",
        \\{"op":"replace","path":[1],"value":{"$num":[50,"%"]}}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(stack 1 50% 3)\n", got.data);
}

test "set_keyword: replace existing unit number with another unit" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(scene :angle 90deg)",
        \\{"op":"set_keyword","path":[],"key":"angle","value":{"$num":[180,"deg"]}}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(scene :angle 180deg)\n", got.data);
}

// ---------------------------------------------------------------------------
// Long-tail Edit tests — error contracts, deeper paths, vector edits,
// and a couple of corner cases on each operation.
// ---------------------------------------------------------------------------

test "missing op field surfaces InvalidAction" {
    try testing.expectError(error.InvalidAction, applyEditFromJsonString(
        testing.allocator,
        "(scene)",
        \\{"path":[]}
    ,
        .{},
    ));
}

test "non-object action surfaces InvalidAction" {
    try testing.expectError(error.InvalidAction, applyEditFromJsonString(
        testing.allocator,
        "(scene)",
        \\["op", "remove_keyword"]
    ,
        .{},
    ));
}

test "missing path field surfaces InvalidAction" {
    try testing.expectError(error.InvalidAction, applyEditFromJsonString(
        testing.allocator,
        "(scene :a 1)",
        \\{"op":"remove_keyword","key":"a"}
    ,
        .{},
    ));
}

test "non-array path surfaces InvalidPath" {
    try testing.expectError(error.InvalidPath, applyEditFromJsonString(
        testing.allocator,
        "(scene)",
        \\{"op":"set_keyword","path":"not-an-array","key":"a","value":1}
    ,
        .{},
    ));
}

test "set_keyword: missing key field surfaces InvalidAction" {
    try testing.expectError(error.InvalidAction, applyEditFromJsonString(
        testing.allocator,
        "(scene)",
        \\{"op":"set_keyword","path":[],"value":1}
    ,
        .{},
    ));
}

test "set_keyword: non-string key surfaces InvalidAction" {
    try testing.expectError(error.InvalidAction, applyEditFromJsonString(
        testing.allocator,
        "(scene)",
        \\{"op":"set_keyword","path":[],"key":99,"value":1}
    ,
        .{},
    ));
}

test "set_keyword: missing value field surfaces InvalidAction" {
    try testing.expectError(error.InvalidAction, applyEditFromJsonString(
        testing.allocator,
        "(scene)",
        \\{"op":"set_keyword","path":[],"key":"a"}
    ,
        .{},
    ));
}

test "replace: empty path surfaces InvalidPath" {
    // The replace op forbids root replacement (per file header).
    try testing.expectError(error.InvalidPath, applyEditFromJsonString(
        testing.allocator,
        "42",
        \\{"op":"replace","path":[],"value":99}
    ,
        .{},
    ));
}

test "replace: vector index out of bounds surfaces PathNotFound" {
    try testing.expectError(error.PathNotFound, applyEditFromJsonString(
        testing.allocator,
        "(stack [1 2])",
        \\{"op":"replace","path":[0, 5],"value":99}
    ,
        .{},
    ));
}

test "replace: negative path index surfaces InvalidPath" {
    try testing.expectError(error.InvalidPath, applyEditFromJsonString(
        testing.allocator,
        "(stack 1 2)",
        \\{"op":"replace","path":[-1],"value":99}
    ,
        .{},
    ));
}

test "remove_keyword: empty source raises EmptyTree" {
    try testing.expectError(error.EmptyTree, applyEditFromJsonString(
        testing.allocator,
        "",
        \\{"op":"remove_keyword","path":[],"key":"x"}
    ,
        .{},
    ));
}

test "remove_keyword: multi-root source raises MultipleRoots" {
    try testing.expectError(error.MultipleRoots, applyEditFromJsonString(
        testing.allocator,
        "(stack 1) (stack 2)",
        \\{"op":"remove_keyword","path":[],"key":"x"}
    ,
        .{},
    ));
}

test "insert_positional: index strictly past end raises PathNotFound" {
    // The form-insert path validates `want <= seen` (where `seen` is the
    // positional child count). Anything larger raises PathNotFound — we
    // do NOT silently fall through to append.
    try testing.expectError(error.PathNotFound, applyEditFromJsonString(
        testing.allocator,
        "(stack 1 2)",
        \\{"op":"insert_positional","path":[],"index":99,"value":3}
    ,
        .{},
    ));
}

test "insert_positional: index equal to count appends" {
    // Boundary: `index == count` is the append point.
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(stack 1 2)",
        \\{"op":"insert_positional","path":[],"index":2,"value":3}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(stack 1 2 3)\n", got.data);
}

test "insert_positional: omitted index field appends to a vector" {
    // Pin the no-index branch through the action decoder: vector path
    // appends when index is null.
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(stack [1 2])",
        \\{"op":"insert_positional","path":[0],"value":3}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(stack [1 2 3])\n", got.data);
}

test "insert_positional: index past vector end raises PathNotFound" {
    try testing.expectError(error.PathNotFound, applyEditFromJsonString(
        testing.allocator,
        "(stack [1 2])",
        \\{"op":"insert_positional","path":[0],"index":5,"value":99}
    ,
        .{},
    ));
}

test "insert_positional: insert at index 0 shifts every element" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(stack 2 3 4)",
        \\{"op":"insert_positional","path":[],"index":0,"value":1}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(stack 1 2 3 4)\n", got.data);
}

test "remove_positional: index out of bounds raises PathNotFound" {
    try testing.expectError(error.PathNotFound, applyEditFromJsonString(
        testing.allocator,
        "(stack 1 2 3)",
        \\{"op":"remove_positional","path":[],"index":99}
    ,
        .{},
    ));
}

test "remove_positional: removing the only positional drops it cleanly" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(stack 1)",
        \\{"op":"remove_positional","path":[],"index":0}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(stack)\n", got.data);
}

test "deeply nested edit: 3-level form path traversal" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(a :b (c :d (e :f 1)))",
        \\{"op":"set_keyword","path":["b","d"],"key":"f","value":99}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(a :b (c :d (e :f 99)))\n", got.data);
}

test "deeply nested edit: form-vector-form path mix" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(stack [1 (inner :x 1) 3] 4)",
        \\{"op":"set_keyword","path":[0, 1],"key":"x","value":99}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings(
        "(stack [1 (inner :x 99) 3] 4)\n",
        got.data,
    );
}

test "set_keyword: insert into empty form" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(scene)",
        \\{"op":"set_keyword","path":[],"key":"k","value":1}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(scene :k 1)\n", got.data);
}

test "replace: swap a vector for a different vector" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(stack [1 2 3])",
        \\{"op":"replace","path":[0],"value":[9,8,7,6]}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(stack [9 8 7 6])\n", got.data);
}

test "replace: swap an atom for a string" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(stack 1 2 3)",
        \\{"op":"replace","path":[1],"value":"hi"}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(stack 1 \"hi\" 3)\n", got.data);
}

test "remove_keyword preserves order of remaining keyword pairs" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(scene :a 1 :b 2 :c 3)",
        \\{"op":"remove_keyword","path":[],"key":"b"}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(scene :a 1 :c 3)\n", got.data);
}

test "set_keyword: replace value with a $kw discriminator" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(scene :a 1)",
        \\{"op":"set_keyword","path":[],"key":"a","value":{"$kw":"hello"}}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(scene :a :hello)\n", got.data);
}

test "set_keyword: replace value with a $sym discriminator" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(scene :a 1)",
        \\{"op":"set_keyword","path":[],"key":"a","value":{"$sym":"identity"}}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(scene :a identity)\n", got.data);
}

test "lossless mode: edit doesn't drop tree-trailing comments" {
    const src =
        \\(scene :bpm 130)
        \\; bye
    ;
    const got = try applyEditFromJsonString(
        testing.allocator,
        src,
        \\{"op":"set_keyword","path":[],"key":"bpm","value":140}
    ,
        .{ .mode = .full },
    );
    defer got.deinit();
    try testing.expectEqualStrings(
        \\(scene :bpm 140)
        \\; bye
        \\
    , got.data);
}

test "lossless mode: edit doesn't drop a vector's trailing comment" {
    // Regression: cloneVectorShell cloned only leading comments, so a
    // comment before a vector's `]` was dropped whenever the vector shell
    // was rebuilt — despite .full mode's documented intent to keep trivia
    // on untouched trivia. Parallel to cloneFormShell, which cloned both.
    // The edit inserts into the vector (rebuilding its shell) while the
    // trailing comment is unrelated to the inserted element.
    const src =
        \\(scene [
        \\  1
        \\  ; keep me
        \\])
    ;
    const got = try applyEditFromJsonString(
        testing.allocator,
        src,
        \\{"op":"insert_positional","path":[0],"value":2}
    ,
        .{ .mode = .full },
    );
    defer got.deinit();
    try testing.expect(std.mem.indexOf(u8, got.data, "keep me") != null);
}

test "applyEditToTree: roundtrip via tree (no parse/print)" {
    // Direct call to applyEditToTree — useful for editor reducers that
    // already hold a parsed tree.
    const a = testing.allocator;
    var src = try Parser.parse(a, "(scene :bpm 130)");
    defer src.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        a,
        \\{"op":"set_keyword","path":[],"key":"bpm","value":99}
    ,
        .{},
    );
    defer parsed.deinit();

    var dst = try applyEditToTree(a, &src, parsed.value);
    defer dst.deinit();

    const printed = try Printer.print(a, dst, .{});
    defer printed.deinit();
    try testing.expectEqualStrings("(scene :bpm 99)\n", printed.data);
}

// ---------------------------------------------------------------------------
// Batched edits — applyEdits folds N actions through one parse/print pass.
// ---------------------------------------------------------------------------

test "applyEdits: three actions fold in one pass" {
    const got = try applyEditsFromJsonString(
        testing.allocator,
        "(scene :bpm 130)",
        \\[{"op":"set_keyword","path":[],"key":"bpm","value":140},
        \\ {"op":"set_keyword","path":[],"key":"name","value":"main"},
        \\ {"op":"set_keyword","path":[],"key":"loop","value":true}]
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(scene :bpm 140 :name \"main\" :loop true)\n", got.data);
}

test "applyEdits: result matches threading applyEdit per action" {
    // The batched fold must be observably identical to applying each action
    // one at a time and re-threading the printed text.
    const a = testing.allocator;
    const actions =
        \\[{"op":"insert_positional","path":[],"value":4},
        \\ {"op":"remove_positional","path":[],"index":0},
        \\ {"op":"replace","path":[1],"value":99}]
    ;
    const batched = try applyEditsFromJsonString(a, "(stack 1 2 3)", actions, .{});
    defer batched.deinit();

    // Hand-fold the same three actions through single-action applyEdit.
    var step1 = try applyEditFromJsonString(a, "(stack 1 2 3)", "{\"op\":\"insert_positional\",\"path\":[],\"value\":4}", .{});
    defer step1.deinit();
    const s1: [:0]const u8 = try a.dupeZ(u8, std.mem.trimEnd(u8, step1.data, "\n"));
    defer a.free(s1);
    var step2 = try applyEditFromJsonString(a, s1, "{\"op\":\"remove_positional\",\"path\":[],\"index\":0}", .{});
    defer step2.deinit();
    const s2: [:0]const u8 = try a.dupeZ(u8, std.mem.trimEnd(u8, step2.data, "\n"));
    defer a.free(s2);
    var step3 = try applyEditFromJsonString(a, s2, "{\"op\":\"replace\",\"path\":[1],\"value\":99}", .{});
    defer step3.deinit();

    try testing.expectEqualStrings(step3.data, batched.data);
    try testing.expectEqualStrings("(stack 2 99 4)\n", batched.data);
}

test "applyEdits: preserves trivia outside the edited subtrees" {
    const src =
        \\(scene
        \\  ; tempo
        \\  :bpm 130
        \\  ; about to declare canvas
        \\  (canvas :name "main"))
    ;
    const got = try applyEditsFromJsonString(
        testing.allocator,
        src,
        \\[{"op":"set_keyword","path":[],"key":"bpm","value":140},
        \\ {"op":"set_keyword","path":[0],"key":"name","value":"alt"}]
    ,
        .{ .mode = .full },
    );
    defer got.deinit();
    try testing.expectEqualStrings(
        \\(scene
        \\  ; tempo
        \\  :bpm 140
        \\  ; about to declare canvas
        \\  (canvas :name "alt"))
        \\
    , got.data);
}

test "applyEdits: a failing action aborts the whole batch" {
    // The second action targets a missing keyword; the batch is all-or-
    // nothing, so the error surfaces and nothing is printed.
    try testing.expectError(error.PathNotFound, applyEditsFromJsonString(
        testing.allocator,
        "(scene :bpm 130)",
        \\[{"op":"set_keyword","path":[],"key":"bpm","value":140},
        \\ {"op":"remove_keyword","path":[],"key":"missing"}]
    ,
        .{},
    ));
}

test "applyEdits: empty batch re-prints the source" {
    const got = try applyEditsFromJsonString(
        testing.allocator,
        "(scene :bpm 130)",
        \\[]
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(scene :bpm 130)\n", got.data);
}

test "applyEdits: non-array actions JSON surfaces InvalidAction" {
    try testing.expectError(error.InvalidAction, applyEditsFromJsonString(
        testing.allocator,
        "(scene)",
        \\{"op":"set_keyword","path":[],"key":"a","value":1}
    ,
        .{},
    ));
}

test "applyEditToTree: edited tree owns its diagnostics (no source-arena aliasing)" {
    // Unclosed `(scene …` parses to one root form plus one diagnostic that
    // carries BOTH a message and a non-empty semantic path (`["scene"]`) —
    // exactly the two fields `Diagnostic.dupe` must deep-copy.
    var src = try Parser.parse(testing.allocator, "(scene :bpm 130");
    defer src.deinit();
    try testing.expectEqual(@as(usize, 1), src.diagnostics.len);
    try testing.expect(src.diagnostics[0].path.len >= 1);

    var action = try parseAction(testing.allocator,
        \\{"op":"set_keyword","path":[],"key":"x","value":1}
    );
    defer action.deinit();

    var edited = try applyEditToTree(testing.allocator, &src, action.value);
    defer edited.deinit();

    try testing.expectEqual(@as(usize, 1), edited.diagnostics.len);
    const s = src.diagnostics[0];
    const e = edited.diagnostics[0];
    // Deep copy: the edited diagnostic shares no storage with `src`, so it
    // stays valid once the caller frees the source tree's arena. A shallow
    // `a.dupe(Diagnostic, …)` aliases all three pointers → these fail.
    try testing.expect(e.message.ptr != s.message.ptr);
    try testing.expect(e.path.ptr != s.path.ptr);
    try testing.expect(e.path[0].ptr != s.path[0].ptr);
    // …and carries identical content + metadata.
    try testing.expectEqualStrings(s.message, e.message);
    try testing.expectEqualStrings(s.path[0], e.path[0]);
    try testing.expectEqual(s.code, e.code);
    try testing.expectEqual(s.span, e.span);
}

test "applyEditToTree: rejects an over-long edit path (bounds applyAtPath recursion)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A 2000-step path — past MAX_EDIT_PATH_DEPTH (1024). `decodeAction`
    // rejects it up front, before `applyAtPath` walks the tree, so the
    // (shallow) target's shape is irrelevant to the rejection.
    var path = std.json.Array.init(a);
    for (0..2000) |_| try path.append(.{ .integer = 0 });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "op", .{ .string = "replace" });
    try obj.put(a, "path", .{ .array = path });
    try obj.put(a, "value", .{ .integer = 1 });

    var src = try Parser.parse(testing.allocator, "(scene 1)");
    defer src.deinit();
    try testing.expectError(
        error.DepthExceeded,
        applyEditToTree(testing.allocator, &src, .{ .object = obj }),
    );

    // Control: a valid short path on the same tree still applies.
    var ok_path = std.json.Array.init(a);
    try ok_path.append(.{ .integer = 0 });
    var ok_obj: std.json.ObjectMap = .empty;
    try ok_obj.put(a, "op", .{ .string = "replace" });
    try ok_obj.put(a, "path", .{ .array = ok_path });
    try ok_obj.put(a, "value", .{ .integer = 7 });
    var edited = try applyEditToTree(testing.allocator, &src, .{ .object = ok_obj });
    defer edited.deinit();
    try testing.expectEqual(@as(usize, 1), edited.root.len);
}
