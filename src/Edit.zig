//! Editor-shaped structural edits over an `Ast.Tree`.
//!
//! `applyEdit(gpa, source, action)` is the v0.1 thin glue:
//!     parse source → build edited tree (functional rebuild) → print
//!
//! It is meant for editor reducers and downstream tooling. The action is a
//! JSON value carrying an `op`, a `path` (chain of steps from the edited
//! root), an optional `root`, and operation-specific fields. v0.1 mutations
//! stay structural — the re-printed source is canonical or full (default).
//!
//! **Comments on subtrees no op re-encodes survive the round-trip in full
//! mode.** The qualifier is load-bearing: the four ops that take a `value`
//! build their node through `Json.fromJson`, and the JSON bridge carries no
//! comments (`Json.zig`'s header says so), so anything decoded from a
//! `value` arrives trivia-free. That is the intended cost when the action is
//! *changing* that part of the document. It is not intended when the action
//! is merely *composing* with a subtree — nesting an existing node inside a
//! `replace`'s value to put it under a new parent loses its comments even
//! though nothing about it changed. `wrap` is the op for that case, and it
//! is the only one whose target crosses over through `cloneNode`.
//!
//! **Layout is preserved by the apply, not by the op.** Under the default
//! `.reprint` layout it is preserved by no op at all: full mode re-prints
//! from the tree, so line breaks and alignment are the printer's decision
//! on every run, and changing one literal can move every byte in the
//! document. Under `.preserve` each op lowers to one `TextEdit` over the
//! target's span (`textEdit`) and the result is the source with that span
//! spliced, so every byte outside it — comments, alignment, the spelling
//! of numbers the action does not touch — is the author's. `sjon edit`
//! uses only the second; the wasm export defaults to the first, where it
//! has consumers with goldens cut against it.
//!
//! **A document that does not parse is not edited.** The parser recovers
//! into a partial tree; editing that edits the recovery, and returns it
//! as though it were the document. `applyEditToTree` refuses on entry
//! with `error.ParseErrors`, the same policy `sjon fmt` and the LSP's
//! `getFormatEdits` already take, and for the same reason: a writer that
//! writes back a recovery turns a syntax error into data loss.
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
//! An empty path resolves to the edited root itself.
//!
//! ## Root
//!
//! `path` starts at one root of the document. `root` names which, and every
//! other root is cloned through untouched; a document that declares or
//! references a plugin has several, so most real files need it. An
//! *omitted* `root` on a multi-root tree is `error.MultipleRoots`, not an
//! implicit 0 — silently editing whichever form came first is the worse
//! failure for an editor. An out-of-range one is `error.PathNotFound`.
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
//!   * `wrap`          { path, value, hole }
//!       Compose the path's target node into a new parent decoded from
//!       `value`, landing it in the slot `hole` names inside that parent
//!       (a path in the same grammar, walked against the decoded value
//!       rather than the document; the placeholder it names is discarded).
//!       Unlike `replace`, `path` may be empty — wrapping the root is the
//!       motivating case. `hole` may not be: with nowhere for the target
//!       to land, a wrap is a `replace` that discards it.
//!       The wrapped subtree is cloned, not re-encoded, so its comments
//!       and formatting survive.
//!   * `insert_positional` { path, value, index? }
//!       At a form/vector node, insert a positional child / element at
//!       `index` (default: append). Existing children shift right.
//!   * `remove_positional` { path, index }
//!       At a form/vector node, remove the positional child / element at
//!       the given positional index.
//!   * `insert_root`   { value, index? }
//!       Place `value` as a new root before the `index`th one (default:
//!       append). The top level is a container too (§4.1), so this is
//!       `insert_positional` with the document's root list as the
//!       container.
//!   * `remove_root`   { index }
//!       Remove root `index`.
//!
//! The last two are the only ops that address the forest rather than a
//! node inside one root, so they take neither `path` nor `root` — both
//! are refused, not ignored. `index` alone says which slot, exactly as it
//! does on the two positional ops.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Parser = @import("Parser.zig");
const Printer = @import("Printer.zig");
const Json = @import("Json.zig");
const EffectiveDocument = @import("EffectiveDocument.zig");

/// How an applied edit reaches the output.
///
/// `.reprint` prints the whole edited tree. Line breaks and alignment are
/// then the printer's decision on every run, so a one-literal edit can
/// move every byte in the document. It is the v0.1 behaviour and stays
/// the default: the wasm export has consumers with goldens cut against it.
///
/// `.preserve` lowers each action to **one** text edit over the target's
/// span and splices it. Every byte outside that span is the author's,
/// including comments, alignment, and the spelling of numbers the action
/// does not touch. `sjon edit` uses only this.
pub const Layout = enum { reprint, preserve };

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
    /// Whether the result is re-printed or spliced. See `Layout`.
    layout: Layout = .reprint,

    /// Parallel to `Binary.ToBinaryOptions.forMode` so the encoder
    /// family has one blessed construction style.
    pub fn forMode(mode: Ast.Mode) Options {
        return .{ .mode = mode };
    }

    /// The printer knobs, in the printer's own struct. Both applies emit
    /// through the printer — one whole tree, one fragment at a time — so
    /// neither spells the field list.
    pub fn printerOptions(self: Options) Printer.Options {
        return .{ .mode = self.mode, .indent = self.indent, .wrap_at = self.wrap_at };
    }
};

/// One text edit: replace `[span_start, span_end)` of the source with
/// `new_text`. A pure insertion has `span_start == span_end`; a pure
/// deletion has an empty `new_text`.
///
/// This is the shape the language server already hands editors
/// (`Handler.TextEdit` aliases it) and the shape a host's own document
/// model wants, since each applies edits in its own way. `new_text` is
/// allocated by whoever produced the edit and borrowed by the struct.
pub const TextEdit = struct {
    span_start: u32,
    span_end: u32,
    new_text: []const u8,
};

/// Errors `applyEdit` and `applyEditFromJsonString` can return. Includes
/// every variant from `Json.Error` since structural edits decode embedded
/// JSON values through the JSON bridge — that union also supplies
/// `DepthExceeded`, which `decodeAction` raises when the action's `path`
/// (or a `wrap`'s `hole`, walked by the same recursion) is longer than
/// `MAX_EDIT_PATH_DEPTH` — the `applyAtPath` descent recurses once per
/// step, and the action is untrusted JSON at the kitchen-sink wasm
/// boundary.
///
/// `MultipleRoots` is now reachable only from an action that omitted
/// `root` on a multi-root tree, or from a `wrap` whose template decodes
/// to more than one root (`Json.fromJson`'s own refusal).
///
/// `ParseErrors` is the refusal to edit a document the parser only
/// *recovered*: see `applyEditToTree`'s header for why editing a recovery
/// is data loss rather than an edit.
///
/// `EmptyTree` is the refusal to run an operation that needs a root on a
/// document that has none. It belongs to the operation rather than to the
/// entry — `insert_root` is the one op that raises it on nothing; see
/// `needsRoot`.
///
/// `NoSourceSpan` belongs to `textEdit` alone. A splice needs a byte
/// coordinate, and a tree that was *synthesized* rather than parsed (every
/// span zero-width, `source` empty) has none to give. The re-print apply
/// never asks, so it never raises it.
pub const Error = error{
    OutOfMemory,
    InvalidAction,
    InvalidPath,
    PathNotFound,
    PathTypeMismatch,
    EmptyTree,
    MultipleRoots,
    UnknownOp,
    ParseErrors,
    NoSourceSpan,
} || Json.Error;

/// Ceiling on edit-path length, deliberately equal to
/// `Parser.MAX_PARSE_DEPTH` (1024): the `applyAtPath` walk recurses once
/// per path step, so this bounds that host recursion regardless of the
/// target tree's shape (a caller-supplied `Ast.Tree` passed to
/// `applyEditToTree` need not have come from the depth-capped parser).
/// A `wrap`'s `hole` takes the same ceiling — it is the same walk, over
/// the decoded template instead of the document.
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
/// A multi-root `src` needs `"root": N` on the action to say which root
/// the `path` starts at; without one it is `error.MultipleRoots`, as it
/// was before `root` existed.
///
/// A `src` carrying an `err`-severity diagnostic is `error.ParseErrors`,
/// checked before anything else is asked of it. The parser recovers into
/// a *partial* tree, so what an edit would land on is the recovery, not
/// the document: `(scene :w 800\n(camera :fov 60` recovers as `camera`
/// nested inside `scene`, and a `set_keyword` there returns one
/// well-formed form where the author had two unclosed ones. Both of
/// SJON's other writers refuse the same input for the same reason
/// (`Cli.runFmt`, `Handler.getFormatEdits`); under `.preserve` the
/// refusal is also a precondition, since a recovered form's span is not
/// a trustworthy splice coordinate.
///
/// The edited tree is at most `Parser.MAX_PARSE_DEPTH` deep, or the edit
/// is `error.DepthExceeded`. Each ceiling here bounds one *input* — the
/// path, the value, the hole — but a `wrap` composes the target's depth
/// with the template's, and a batch composes wraps, so nothing per-op
/// keeps the *output* inside the ceiling `cloneNode`, the JSON bridge and
/// the binary encoder all cite. Two hundred wraps of a 1000-deep template
/// used to segfault inside `cloneNode`; measuring the result restores the
/// invariant every consumer relies on.
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
    // Before the action is even decoded: a tree the parser only recovered
    // is not the document the caller named, so no question about it has a
    // correct answer. `EmptyTree` is not like that — an empty document is
    // well-formed — so it waits for the decode and asks `needsRoot`.
    if (src.hasErrors()) return error.ParseErrors;
    const parsed = try decodeAction(action);
    if (src.root.len == 0 and needsRoot(parsed.action)) return error.EmptyTree;
    const target_root: ?usize = if (takesPath(parsed.action)) try targetRoot(src, parsed.root) else null;
    var out = try buildEditedTree(gpa, src, parsed, target_root);
    errdefer out.deinit();
    if (try out.maxDepth(gpa) > MAX_EDIT_PATH_DEPTH) return error.DepthExceeded;
    return out;
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
/// A `source` that does not parse is `error.ParseErrors`. The check sits
/// here rather than only inside `applyEditToTree` because an empty batch
/// never reaches that entry, and "re-print a document we could not parse"
/// is the same data loss by a shorter route.
///
/// Under `opts.layout == .preserve` the fold is text→text instead: each
/// action parses, lowers to one `TextEdit`, splices, and the next action
/// parses the result. That re-parse is not overhead to be optimised away —
/// a cloned node's span indexes the *old* source and a synthesized node has
/// no span at all, so a tree→tree fold would hand the second action
/// coordinates the first one moved. k parses for k actions, and the result
/// is observably identical to threading single edits, which is the property
/// the batched entry already promises.
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
    if (cur.hasErrors()) return error.ParseErrors;

    // The parse above is the first action's parse under either layout, so
    // the preserve fold takes it rather than repeating it.
    if (opts.layout == .preserve) return spliceEdits(gpa, source, &cur, actions, opts);

    for (actions) |action| {
        const next = try applyEditToTree(gpa, &cur, action);
        cur.deinit();
        cur = next;
    }

    return try Printer.print(gpa, cur, opts.printerOptions());
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
    wrap: struct { value: std.json.Value, hole: []const std.json.Value },
    /// The two forest operations. They carry no `path` and no `root`: the
    /// container they act on is the document's root list, and `index`
    /// alone addresses a slot in it.
    insert_root: struct { index: ?usize, value: std.json.Value },
    remove_root: struct { index: usize },
    /// Internal, unreachable from JSON: `replace` with the node already
    /// built in *this* builder's pool. Everything downstream of
    /// `buildJsonValue` takes a `NodeIndex`, so a decoded value and a
    /// pre-built one are the same thing to the rebuild walk.
    replace_node: struct { value: Ast.NodeIndex },
};

const ParsedAction = struct {
    /// Empty for the two forest operations, which take none.
    path: []const std.json.Value,
    action: Action,
    /// Which root of a multi-root document the `path` starts at. Null when
    /// the action omitted `root`, which is the only spelling that reaches
    /// `error.MultipleRoots`, and null on the two forest operations, which
    /// refuse the field rather than take it.
    root: ?usize,
};

/// Whether the operation starts a `path` at one root of the document.
/// True of the six; false of the two that act on the root list itself.
/// The one predicate both applies ask, so neither can decide on its own
/// which ops walk into a root.
fn takesPath(action: Action) bool {
    return switch (action) {
        .insert_root, .remove_root => false,
        else => true,
    };
}

/// Whether the operation needs the document to have a root at all.
///
/// This is `EmptyTree`, and it is a property of the *operation*, not of
/// the entry: every op that starts a `path` at a root raises it on a
/// rootless document because there is no root for the path to start at,
/// and `remove_root` raises it because there is no root to remove.
/// `insert_root` is the one op that needs none — refusing it would leave
/// `remove_root` able to produce a document `Edit` will not accept, which
/// is §11 holding half a boundary.
///
/// Stated once and called by both entries, after the action is decoded.
/// `ParseErrors` stays ahead of the decode: a tree the parser only
/// recovered is not the document the caller named, so no question about
/// it has a correct answer, while an empty document is well-formed and a
/// question about it has an answer that depends on the question.
fn needsRoot(action: Action) bool {
    return switch (action) {
        .insert_root => false,
        else => true,
    };
}

fn decodeAction(action: std.json.Value) Error!ParsedAction {
    const obj = switch (action) {
        .object => |o| o,
        else => return error.InvalidAction,
    };
    const op = switch (obj.get("op") orelse return error.InvalidAction) {
        .string => |s| s,
        else => return error.InvalidAction,
    };
    if (std.mem.eql(u8, op, "set_keyword")) {
        const at = try requireTarget(obj);
        const key = try requireString(obj, "key");
        const value = obj.get("value") orelse return error.InvalidAction;
        return .{ .path = at.path, .action = .{ .set_keyword = .{ .key = key, .value = value } }, .root = at.root };
    } else if (std.mem.eql(u8, op, "remove_keyword")) {
        const at = try requireTarget(obj);
        const key = try requireString(obj, "key");
        return .{ .path = at.path, .action = .{ .remove_keyword = .{ .key = key } }, .root = at.root };
    } else if (std.mem.eql(u8, op, "replace")) {
        const at = try requireTarget(obj);
        if (at.path.len == 0) return error.InvalidPath;
        const value = obj.get("value") orelse return error.InvalidAction;
        return .{ .path = at.path, .action = .{ .replace = .{ .value = value } }, .root = at.root };
    } else if (std.mem.eql(u8, op, "wrap")) {
        const at = try requireTarget(obj);
        const value = obj.get("value") orelse return error.InvalidAction;
        const hole = switch (obj.get("hole") orelse return error.InvalidAction) {
            .array => |arr| arr.items,
            else => return error.InvalidPath,
        };
        // `hole` is walked by the same `applyAtPath` recursion as `path`,
        // over the template rather than the document, so it takes the same
        // bound — checked here, beside `path`'s, on the same untrusted JSON.
        if (hole.len > MAX_EDIT_PATH_DEPTH) return error.DepthExceeded;
        // A wrap with no hole is a `replace` with extra syntax: there is
        // nowhere for the wrapped node to land, so the target would be
        // dropped rather than composed.
        if (hole.len == 0) return error.InvalidPath;
        return .{ .path = at.path, .action = .{ .wrap = .{ .value = value, .hole = hole } }, .root = at.root };
    } else if (std.mem.eql(u8, op, "insert_positional")) {
        const at = try requireTarget(obj);
        const value = obj.get("value") orelse return error.InvalidAction;
        const idx_opt = try optionalIndex(obj);
        return .{ .path = at.path, .action = .{ .insert_positional = .{ .index = idx_opt, .value = value } }, .root = at.root };
    } else if (std.mem.eql(u8, op, "remove_positional")) {
        const at = try requireTarget(obj);
        const idx = try optionalIndex(obj) orelse return error.InvalidAction;
        return .{ .path = at.path, .action = .{ .remove_positional = .{ .index = idx } }, .root = at.root };
    } else if (std.mem.eql(u8, op, "insert_root")) {
        try refuseAddress(obj);
        const value = obj.get("value") orelse return error.InvalidAction;
        const idx_opt = try optionalIndex(obj);
        return .{ .path = &.{}, .action = .{ .insert_root = .{ .index = idx_opt, .value = value } }, .root = null };
    } else if (std.mem.eql(u8, op, "remove_root")) {
        try refuseAddress(obj);
        const idx = try optionalIndex(obj) orelse return error.InvalidAction;
        return .{ .path = &.{}, .action = .{ .remove_root = .{ .index = idx } }, .root = null };
    }
    return error.UnknownOp;
}

/// Where a path-taking operation starts: which root, and the path from it.
/// The action's own, still in `std.json.Value` — the public `Address` is
/// the same idea travelling the other way, a node's position read *out* of
/// a tree rather than an edit's target read *in* from JSON.
///
/// Read per op rather than in `decodeAction`'s prologue because the two
/// forest operations take neither field. `insert_root` has no `path` to
/// read, and requiring an empty one would say the opposite of what it does:
/// `[]` already means "the root form" (§11.2), which is the container an
/// `insert_root` is a sibling of, not the one it inserts into.
const ActionTarget = struct {
    path: []const std.json.Value,
    /// Range-checked against the target tree by `applyEditToTree` /
    /// `textEdit`, which is the first place the number of roots is known.
    root: ?usize,
};

fn requireTarget(obj: std.json.ObjectMap) Error!ActionTarget {
    const path = switch (obj.get("path") orelse return error.InvalidAction) {
        .array => |arr| arr.items,
        else => return error.InvalidPath,
    };
    // Bound the `applyAtPath` recursion up front: it descends one level per
    // path step, so an over-long path from untrusted JSON would otherwise
    // recurse without limit on a sufficiently deep target tree.
    if (path.len > MAX_EDIT_PATH_DEPTH) return error.DepthExceeded;
    const root: ?usize = if (obj.get("root")) |rv| switch (rv) {
        .integer => |i| if (i < 0) return error.InvalidAction else @as(usize, @intCast(i)),
        else => return error.InvalidAction,
    } else null;
    return .{ .path = path, .root = root };
}

/// The two addressing fields, refused rather than ignored. A forest
/// operation acts on the root list, so a caller who wrote one of them
/// meant something the operation cannot do — silently dropping it is the
/// failure mode `error.MultipleRoots` exists to prevent.
fn refuseAddress(obj: std.json.ObjectMap) Error!void {
    if (obj.get("path") != null) return error.InvalidPath;
    if (obj.get("root") != null) return error.InvalidAction;
}

/// An optional non-negative `index` field: which slot in a container.
/// Shared by the two positional ops and the two forest ops so "index" has
/// one spelling; the ops that require it turn null into their own refusal.
fn optionalIndex(obj: std.json.ObjectMap) Error!?usize {
    const v = obj.get("index") orelse return null;
    return switch (v) {
        .integer => |i| if (i < 0) error.InvalidAction else @as(usize, @intCast(i)),
        else => error.InvalidAction,
    };
}

/// Which root of `src` the action's `path` starts at. Shared by both
/// applies so they cannot disagree about `root`'s meaning — the same
/// reason the keyword and positional scans are shared.
///
/// Deliberately *not* defaulting to 0 on a multi-root document: an
/// omitted `root` keeps the loud refusal, because silently editing
/// whichever form happens to be first is the worse failure for an editor.
fn targetRoot(src: *const Ast.Tree, root: ?usize) Error!usize {
    std.debug.assert(src.root.len > 0);
    if (root) |want| {
        if (want >= src.root.len) return error.PathNotFound;
        return want;
    }
    if (src.root.len > 1) return error.MultipleRoots;
    return 0;
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

/// Build a new `Ast.Tree` that is `src` with `parsed.action` applied.
///
/// For the six path-taking ops that is `parsed.path` inside root
/// `target_root`, with every other root cloned through unchanged; the
/// caller (`applyEditToTree`) has already rejected an empty tree
/// (`EmptyTree` — see `needsRoot`), a multi-root tree with no `root` on
/// the action (`MultipleRoots`) and an out-of-range one (`PathNotFound`).
///
/// For the two forest ops `target_root` is null — they rebuild the root
/// list itself, one longer or one shorter, and descend into no root at
/// all. Everything after the root list (the tree-trailing comments, the
/// diagnostics, the finalize) is the same either way.
fn buildEditedTree(
    gpa: Allocator,
    src: *const Ast.Tree,
    parsed: ParsedAction,
    target_root: ?usize,
) Error!Ast.Tree {
    std.debug.assert((target_root != null) == takesPath(parsed.action));

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var b: Ast.TreeBuilder = .{ .a = a };
    const ctx: Ctx = .{ .gpa = gpa, .b = &b, .src = src };

    const new_root = switch (parsed.action) {
        .insert_root => |args| try insertRootList(ctx, a, args.index, args.value),
        .remove_root => |args| try removeRootList(ctx, a, args.index),
        else => try editedRootList(ctx, a, parsed, target_root.?),
    };

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

/// The root list of a six-op edit: root `target_root` transformed, every
/// other one cloned through.
fn editedRootList(
    ctx: Ctx,
    a: Allocator,
    parsed: ParsedAction,
    target_root: usize,
) Error![]Ast.NodeIndex {
    std.debug.assert(ctx.src.root.len > 0);
    std.debug.assert(target_root < ctx.src.root.len);

    const out = try a.alloc(Ast.NodeIndex, ctx.src.root.len);
    for (ctx.src.root, out, 0..) |root_idx, *slot, i| {
        slot.* = if (i == target_root)
            try applyAtPath(ctx, root_idx, parsed.path, parsed.action)
        else
            try ctx.b.cloneNode(ctx.src, root_idx);
    }
    return out;
}

/// The root list one longer: `value` decoded into slot `index`, or
/// appended when `index` is omitted. An `index` past the end is
/// `error.PathNotFound` — the same answer, and the same reason, as an
/// `insert_positional` index past a container's last child.
fn insertRootList(
    ctx: Ctx,
    a: Allocator,
    index: ?usize,
    value: std.json.Value,
) Error![]Ast.NodeIndex {
    const src_roots = ctx.src.root;
    const at = index orelse src_roots.len;
    if (at > src_roots.len) return error.PathNotFound;

    const out = try a.alloc(Ast.NodeIndex, src_roots.len + 1);
    for (src_roots[0..at], out[0..at]) |root_idx, *slot| slot.* = try ctx.b.cloneNode(ctx.src, root_idx);
    out[at] = try buildJsonValue(ctx, value);
    for (src_roots[at..], out[at + 1 ..]) |root_idx, *slot| slot.* = try ctx.b.cloneNode(ctx.src, root_idx);
    return out;
}

/// The root list one shorter, without root `index`. Removing the only
/// root leaves an empty list: a document with no roots is one the
/// language already describes (the glossary's "may be empty") and one
/// the printer already prints.
fn removeRootList(ctx: Ctx, a: Allocator, index: usize) Error![]Ast.NodeIndex {
    const src_roots = ctx.src.root;
    if (index >= src_roots.len) return error.PathNotFound;

    const out = try a.alloc(Ast.NodeIndex, src_roots.len - 1);
    for (src_roots[0..index], out[0..index]) |root_idx, *slot| slot.* = try ctx.b.cloneNode(ctx.src, root_idx);
    for (src_roots[index + 1 ..], out[index..]) |root_idx, *slot| slot.* = try ctx.b.cloneNode(ctx.src, root_idx);
    return out;
}

/// Recursively walk `path` from `cur_idx`. At each step, descend into the
/// path child while cloning every other child. At path exhaustion, apply
/// the type-A action (set/remove/insert/remove_positional) at the
/// current node. The type-B actions (`replace`, `replace_node`) are
/// consumed by the parent at the final step (where `path.len == 1`).
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

/// The node a type-B action substitutes into the slot the walk has just
/// resolved, or null when the walk must keep descending. `replace` decodes
/// its node from JSON; `replace_node` already holds one. Shared by the form
/// and vector descents so they cannot disagree on which actions terminate
/// the walk — the reason the three keyword/positional scans are shared too.
fn typeBSlotValue(
    ctx: Ctx,
    rest: []const std.json.Value,
    action: Action,
) Error!?Ast.NodeIndex {
    if (rest.len != 0) return null;
    return switch (action) {
        .replace => |args| try buildJsonValue(ctx, args.value),
        .replace_node => |args| args.value,
        else => null,
    };
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

    // A type-B action at the final step substitutes this slot directly.
    if (try typeBSlotValue(ctx, rest, action)) |new_value| {
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
    const want = try vectorIndex(step);
    if (want >= elements.len) return error.PathNotFound;

    const new_elem = try typeBSlotValue(ctx, rest, action) orelse
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
        // Any node can be wrapped, including a scalar — no `tag` guard.
        .wrap => |args| return wrapAt(ctx, cur_idx, args.value, args.hole),
        // Both type-B actions are consumed by the parent at the final
        // step: `replace` because the decoder rejects an empty path,
        // `replace_node` because every caller supplies a non-empty one.
        .replace, .replace_node => unreachable,
        // The forest ops never enter the path walk: `buildEditedTree`
        // rebuilds the root list for them and descends into no root.
        .insert_root, .remove_root => unreachable,
    }
}

/// Compose the node at `cur_idx` into a new parent: decode `template`
/// (ordinary edit-value JSON), then put the *cloned* target into the slot
/// `hole` names inside it.
///
/// The wrapped subtree crosses over through `TreeBuilder.cloneNode`, not
/// through the JSON bridge, so its comments, its spans and the formatting
/// its author chose all survive — that is the whole difference from
/// spelling the same shape as a `replace` whose value nests the target.
/// The template's own nodes carry `Json.fromJson`'s zero-width spans,
/// exactly as `set_keyword`'s appended kvpair does.
///
/// The walk over the template is `applyAtPath` itself, pointed at a second
/// source tree with the same builder: a wrap *is* "clone everything, swap
/// one slot", which is what the rebuild already does. So `hole` gets the
/// path grammar, the error set and the depth bound for free.
///
/// Complexity: O(t + s) — t = template nodes, s = wrapped subtree nodes.
/// `template`'s temp tree is freed here; the target is already in the
/// destination arena.
fn wrapAt(
    ctx: Ctx,
    cur_idx: Ast.NodeIndex,
    template: std.json.Value,
    hole: []const std.json.Value,
) Error!Ast.NodeIndex {
    // The decoder rejects an empty hole; nothing else builds a `.wrap`.
    std.debug.assert(hole.len > 0);

    var tmp = try Json.fromJson(ctx.gpa, template, .{});
    defer tmp.deinit();
    std.debug.assert(tmp.root.len == 1); // fromJson raises MultipleRoots otherwise

    const target = try ctx.b.cloneNode(ctx.src, cur_idx);
    const t_ctx: Ctx = .{ .gpa = ctx.gpa, .b = ctx.b, .src = &tmp };
    return try applyAtPath(t_ctx, tmp.root[0], hole, .{ .replace_node = .{ .value = target } });
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
// Layout-preserving apply — each op lowers to one text edit
//
// The re-print apply above answers "what does the document become"; this
// one answers "which bytes change". Both walk the same paths and share the
// same slot scans, so they can only disagree about output, never about
// what an action addresses.
//
// Every row of the table is a span plus its replacement text:
//
//   replace                  the target's span              <- printed value
//   set_keyword (present)    the kvpair's value span        <- printed value
//   set_keyword (absent)     the closing paren, width 0     <- " :key value"
//   remove_keyword           the gap + the pair             <- ""
//   insert_positional (n)    before the nth child, width 0  <- value + separator
//   insert_positional (end)  the closing delimiter, width 0 <- separator + value
//   remove_positional        the gap + the child            <- ""
//   wrap                     the target's span              <- template around
//                                                              the target's own
//                                                              bytes
//
// "The gap" is the whitespace (and any comments in it) between the previous
// child and this one, so a removed node leaves with its own leading
// comments — the same thing the re-print does, where a removed node's
// comments go with the node.
// ---------------------------------------------------------------------------

/// Lower `action` to the single text edit that applies it to `tree`'s
/// source, **without** applying it. This is the primitive the preserve
/// fold is built on, and the shape the language server and a host's own
/// document model both want, since each applies edits in its own way.
///
/// `new_text` is allocated from `gpa` and borrowed by the result; every
/// intermediate is released before returning, so a caller passing an arena
/// keeps only the edit. Free it with `gpa.free(edit.new_text)`.
///
/// `tree.source` is the text the spans index and the text the edit
/// addresses; a tree that was synthesized rather than parsed has no such
/// coordinate and is `error.NoSourceSpan`. A tree with `err`-severity
/// diagnostics is `error.ParseErrors` — under a splice that is not only a
/// policy but a precondition, since a recovered form's span is not a
/// trustworthy place to cut.
///
/// Complexity: O(d + v) — d = path length (one iterative descent, no host
/// recursion), v = the printed value's size. `action` is borrowed
/// read-only.
pub fn textEdit(
    gpa: Allocator,
    tree: *const Ast.Tree,
    action: std.json.Value,
    opts: Options,
) Error!TextEdit {
    if (tree.hasErrors()) return error.ParseErrors;
    const parsed = try decodeAction(action);
    if (tree.root.len == 0 and needsRoot(parsed.action)) return error.EmptyTree;
    const edit: TextEdit = switch (parsed.action) {
        // The forest ops cut between roots, so they never resolve a path.
        .insert_root => |args| try insertRootEdit(gpa, tree, args.index, args.value, opts),
        .remove_root => |args| try removeRootEdit(tree, args.index),
        else => try pathedEdit(gpa, tree, parsed, opts),
    };
    // The post-condition every row of the table owes, checked once rather
    // than eight times: the span is well-formed and it is a span of *this*
    // source. `splice` asserts the same two, so a coordinate that walked
    // off its node stops here, at the function that computed it.
    std.debug.assert(edit.span_start <= edit.span_end);
    std.debug.assert(edit.span_end <= tree.source.len);
    return edit;
}

/// The edit for one of the six operations that address a node inside a
/// root. Split out of `textEdit` for the same reason `editedRootList` is
/// split out of `buildEditedTree`: the path walk is theirs alone.
fn pathedEdit(
    gpa: Allocator,
    tree: *const Ast.Tree,
    parsed: ParsedAction,
    opts: Options,
) Error!TextEdit {
    std.debug.assert(takesPath(parsed.action));
    const root_idx = tree.root[try targetRoot(tree, parsed.root)];

    // Type-B (`replace`) addresses the node the whole path names; every
    // type-A op addresses the container it ends at. `resolvePath` is the
    // one walk, and the split is which node it hands back.
    const target = try resolvePath(tree, root_idx, parsed.path);
    return switch (parsed.action) {
        .replace => |args| try replaceEdit(gpa, tree, target, args.value, opts),
        .wrap => |args| try wrapEdit(gpa, tree, target, args.value, args.hole, opts),
        .set_keyword => |args| try setKeywordEdit(gpa, tree, target, args.key, args.value, opts),
        .remove_keyword => |args| try removeKeywordEdit(tree, target, args.key),
        .insert_positional => |args| try insertPositionalEdit(gpa, tree, target, args.index, args.value, opts),
        .remove_positional => |args| try removePositionalEdit(tree, target, args.index),
        // Never decoded from JSON; the rebuild walk is its only producer.
        .replace_node => unreachable,
        // Refused by the assert above; `takesPath` is what says so.
        .insert_root, .remove_root => unreachable,
    };
}

/// Resolve `path` from `root_idx` to the node it names — the address, not
/// the edit. A string step lands on the kvpair's *value*, matching the
/// rebuild walk (`descendForm`), so the two applies address the same node.
///
/// The read-side inverse of `addressOf`: what that builds from a node,
/// this spends to get the node back. Public so that round trip is
/// assertable from outside the module — the fuzz harness holds one end of
/// it — and because a caller holding an `Address` needs some way to spend
/// it that is not "issue an edit and see what moved". Feed it
/// `Address.toJsonPath` and `tree.root[address.root]`.
///
/// Iterative: unlike `applyAtPath`, which recurses once per step because it
/// rebuilds each container on the way out, this only descends, so the
/// path's own length bound (`MAX_EDIT_PATH_DEPTH`) is not load-bearing here.
///
/// Complexity: O(d · w) — d = path length, w = the widest container walked
/// (the keyword and positional scans are linear in the child list).
pub fn resolvePath(
    tree: *const Ast.Tree,
    root_idx: Ast.NodeIndex,
    path: []const std.json.Value,
) Error!Ast.NodeIndex {
    var cur = root_idx;
    for (path) |step| {
        switch (tree.tagOf(cur)) {
            .form => {
                const hdr = tree.formHeader(cur);
                const slot = try resolveFormStep(tree, hdr, step);
                const child = hdr.children[slot.abs_idx];
                cur = if (slot.is_kvpair) tree.kvpairHeader(child).value else child;
            },
            .vector => {
                const elements = tree.vectorElements(cur);
                const want = try vectorIndex(step);
                if (want >= elements.len) return error.PathNotFound;
                cur = elements[want];
            },
            else => return error.PathTypeMismatch,
        }
    }
    return cur;
}

/// A vector path step: an integer, and not a negative one. Shared by the
/// resolving walk and the rebuild walk's `descendVector`.
fn vectorIndex(step: std.json.Value) Error!usize {
    return switch (step) {
        .integer => |raw| if (raw < 0) error.InvalidPath else @as(usize, @intCast(raw)),
        else => error.InvalidPath,
    };
}

// -- Span to node ------------------------------------------------------------
//
// Two lookups from a byte coordinate to a node, the inverse of the span a
// diagnostic or a pointer arrives with. They are here rather than in the
// language server because their only interesting use is what comes next:
// naming the node they found in the vocabulary `resolvePath` accepts.
// Neither allocates — both read the SoA `span` column and nothing else.

/// The node whose span is exactly `target`, or null when no node has it.
///
/// This is what a *diagnostic* needs: the validator emits at a node's own
/// span, so an exact match recovers the node it was talking about, and a
/// span that is not a node's — a normalised one, a range a person dragged —
/// is a miss rather than a guess. Use `nodeContaining` for a coordinate
/// that merely falls inside something.
///
/// Returns the first match in node-index order. `Ast.TreeBuilder` emits a
/// child before the parent that lists it, so on the exact-span tie that
/// only a degenerate tree can produce, the inner node wins.
///
/// Complexity: O(n) over `tree.nodes.len`.
pub fn nodeAtSpan(tree: *const Ast.Tree, target: Ast.Span) ?Ast.NodeIndex {
    const spans = tree.nodes.items(.span);
    for (spans, 0..) |span, i| {
        if (span.start == target.start and span.end == target.end) {
            return Ast.NodeIndex.from(@intCast(i));
        }
    }
    return null;
}

/// The innermost node whose span contains `offset`, or null when the offset
/// is inside no node — past the last root, in the whitespace between two,
/// or anywhere in a tree that was synthesized rather than parsed (every
/// span there is zero-width, and a zero-width span contains nothing).
///
/// This is what a *pointer* needs. "Innermost" is the narrowest containing
/// span, not the deepest node: a form and its first child can start at the
/// same byte, so nesting depth does not order them but width does. Spans
/// are half-open, so `offset == span.end` is outside.
///
/// A `.kvpair` is a node like any other here, and its span covers `:key`
/// as well as the value — so an offset on the key answers the pair, which
/// is the true answer to "what is under the cursor". `nodeTable` is the
/// one that drops the pair, because §11.2 addresses its value; a raw
/// coordinate lookup should not decide that for its caller.
///
/// Complexity: O(n) over `tree.nodes.len`.
pub fn nodeContaining(tree: *const Ast.Tree, offset: u32) ?Ast.NodeIndex {
    const spans = tree.nodes.items(.span);
    var best: ?Ast.NodeIndex = null;
    var best_width: u32 = std.math.maxInt(u32);
    for (spans, 0..) |span, i| {
        if (offset < span.start or offset >= span.end) continue;
        const width = span.end - span.start;
        if (width >= best_width) continue;
        best = Ast.NodeIndex.from(@intCast(i));
        best_width = width;
    }
    // Found or not, but never found-and-unmeasured: the two travel together.
    std.debug.assert((best != null) == (best_width != std.math.maxInt(u32)));
    if (best) |idx| {
        const span = tree.spanOf(idx);
        std.debug.assert(span.start <= offset and offset < span.end);
    }
    return best;
}

// -- The node table ----------------------------------------------------------

/// One step of a §11.2 path, in Zig rather than in `std.json.Value`.
///
/// The two spellings the path grammar has: a string names a form's keyword
/// value, an integer names a positional child of a form or an element of a
/// vector. Nothing else is a step, which is why this is a two-armed union
/// and not a `std.json.Value`.
pub const Step = union(enum) {
    /// The value of the keyword pair with this key. `key` borrows the
    /// tree's string pool.
    key: []const u8,
    /// The n-th positional child of a form (keyword pairs skipped), or the
    /// n-th element of a vector.
    index: u32,

    /// The step as the action grammar spells it, ready for `resolvePath`.
    /// The string arm borrows; the value is only as alive as the tree.
    pub fn toJsonValue(self: Step) std.json.Value {
        return switch (self) {
            .key => |k| .{ .string = k },
            .index => |i| .{ .integer = @intCast(i) },
        };
    }
};

/// Every addressable node of a document, flat, in pre-order, each row
/// carrying where it is (`parent` + `seg`, which chain to a §11.2 path)
/// and where its bytes are (`span`, plus `head_span` / `key_span`).
///
/// The shape answers an editor's three questions off one parse: decorate
/// every literal, hit-test a coordinate, and address the node a gesture
/// lands on. It is a *table* rather than a tree because the consumer is a
/// host scanning it, and because a path built from `seg` links is §11.2 by
/// construction — a host deriving one from a nested encoding would be
/// re-implementing `resolveFormStep`'s positional counting and could not
/// be told when it got it wrong.
///
/// Rows borrow `tree`: every span indexes its source and every `.key` step
/// points into its string pool. Only the row slice is owned.
pub const NodeTable = struct {
    gpa: Allocator,
    rows: []Row,

    /// One addressable node.
    ///
    /// A `.kvpair` never gets a row. §11.2 addresses a pair's *value* — a
    /// string step resolves through the pair to what it holds
    /// (`resolveFormStep`) — so the pair itself has no address, and its
    /// key span rides on the value's row instead.
    pub const Row = struct {
        /// The node this row describes, for a caller that has the tree.
        node: Ast.NodeIndex,
        /// Row index of the container this node sits in, or null for a
        /// root. Always less than this row's own index: the walk is
        /// pre-order, so a parent is always already emitted.
        parent: ?u32,
        /// Which root of the document this node is under, indexing
        /// `tree.root`. Inherited down the walk.
        root: u32,
        /// This row's own path step from its parent, or null for a root.
        /// The chain of these up the `parent` links, reversed, is the
        /// §11.2 path from `tree.root[root]` to this node.
        seg: ?Step,
        /// The node's tag, so a consumer can tell a number it may scrub
        /// from a string it may not.
        tag: Ast.Tag,
        /// The node's own bytes.
        span: Ast.Span,
        /// A form's head bytes, null for every other tag.
        head_span: ?Ast.Span,
        /// The `:key` bytes of the pair this node is the value of, null
        /// when it is not one. This is the channel a JSON encoding has
        /// nowhere to put.
        key_span: ?Ast.Span,
    };

    pub fn deinit(self: *const NodeTable) void {
        self.gpa.free(self.rows);
    }

    /// The row describing `node`, or null when the node is not
    /// addressable — a `.kvpair`, or an index from another tree.
    ///
    /// Complexity: O(n) over the rows. A caller resolving many nodes
    /// should build its own map instead of calling this in a loop.
    pub fn rowOf(self: NodeTable, node: Ast.NodeIndex) ?u32 {
        for (self.rows, 0..) |row, i| {
            if (row.node == node) return @intCast(i);
        }
        return null;
    }

    /// The row for the innermost node whose span contains `span`, or null
    /// when the span is inside no root — past the last one, or in the
    /// whitespace between two.
    ///
    /// "Innermost" is the narrowest containing span, as it is for
    /// `nodeContaining`, and a tie goes to the later row: the walk is
    /// pre-order, so of two rows with the same span the deeper one comes
    /// second. This is the scan a host does over the table it holds, in
    /// Zig, so the point export and a host reading the bulk one cannot
    /// disagree about which node a coordinate names.
    ///
    /// A kvpair is never a candidate, because it is never a row. A span
    /// over `:name heat` therefore answers the enclosing form — which is
    /// right, since an edit over a whole pair is a `set_keyword` or a
    /// `remove_keyword` on the form, not an edit of the value.
    ///
    /// An empty `span` is a caret rather than a selection, and a caret on
    /// a node's boundary counts as inside it.
    ///
    /// Complexity: O(n) over the rows.
    pub fn rowContaining(self: NodeTable, span: Ast.Span) ?u32 {
        std.debug.assert(span.start <= span.end);
        var best: ?u32 = null;
        var best_width: u32 = std.math.maxInt(u32);
        for (self.rows, 0..) |row, i| {
            if (row.span.start > span.start or row.span.end < span.end) continue;
            const width = row.span.end - row.span.start;
            if (width > best_width) continue;
            best = @intCast(i);
            best_width = width;
        }
        return best;
    }

    /// The address of row `i`: its root, and the `seg` chain up the
    /// `parent` links reversed into a §11.2 path. Caller releases via
    /// `address.deinit()`.
    ///
    /// Complexity: O(d) — one step per ancestor.
    pub fn addressOfRow(self: NodeTable, gpa: Allocator, i: u32) Error!Address {
        std.debug.assert(i < self.rows.len);
        var steps: std.ArrayList(Step) = .empty;
        errdefer steps.deinit(gpa);
        var cur: ?u32 = i;
        while (cur) |at| {
            const row = self.rows[at];
            if (row.seg) |seg| try steps.append(gpa, seg);
            cur = row.parent;
        }
        std.mem.reverse(Step, steps.items);
        return .{
            .gpa = gpa,
            .root = self.rows[i].root,
            .steps = try steps.toOwnedSlice(gpa),
        };
    }
};

/// Where a node is: which root of the document, and the §11.2 path from
/// that root down to it. Exactly the shape an action's `root` + `path`
/// already take, so an address can be handed straight back as an edit.
///
/// An address is *where* a node is, not *which* node it is. Insert a
/// sibling before the target and the same address names a different node;
/// a host that needs identity across edits keeps its own map and
/// re-derives addresses from the document that came back.
///
/// `steps` is owned; the `.key` strings inside it borrow the tree.
pub const Address = struct {
    gpa: Allocator,
    root: u32,
    steps: []Step,

    pub fn deinit(self: *const Address) void {
        self.gpa.free(self.steps);
    }

    /// The `path` as the action grammar spells it, ready for
    /// `resolvePath` or for JSON. Caller frees the slice; the strings
    /// inside still borrow the tree.
    pub fn toJsonPath(self: Address, gpa: Allocator) Allocator.Error![]std.json.Value {
        const out = try gpa.alloc(std.json.Value, self.steps.len);
        for (self.steps, out) |step, *slot| slot.* = step.toJsonValue();
        return out;
    }
};

/// What the walk still owes: a node to emit, and everything its row needs
/// that only its parent knew.
const PendingNode = struct {
    node: Ast.NodeIndex,
    parent: ?u32,
    root: u32,
    seg: ?Step,
    key_span: ?Ast.Span,
};

/// Build the `NodeTable` for `tree`. Caller releases via `table.deinit()`.
///
/// Pre-order: a parent always precedes its children, and siblings are in
/// source order. Two properties fall out of that, and both are what a host
/// scanning the table relies on. A row's `parent` is always an earlier row.
/// And since siblings have disjoint spans, the innermost node containing a
/// byte is the *last* row whose span contains it — so hit-testing is one
/// linear scan on the host side, with no call back into wasm per pointer
/// move.
///
/// **A document that does not parse still yields a table.** This is the
/// deliberate difference from `applyEditToTree`, which refuses the same
/// input with `error.ParseErrors`: writing back a recovery is data loss,
/// but *reading* one is the whole reason an editor asked — the revision
/// mid-keystroke is the one whose addresses are wanted. Read the
/// diagnostics beside the table to know which you have.
///
/// No depth or step ceiling, and deliberately none: every node is pushed
/// exactly once, by its parent, so the walk is already bounded by the tree
/// the parser bounded. This is `validateOneTree`'s carve-out, for
/// `validateOneTree`'s reason.
///
/// Complexity: O(n) over `tree.nodes.len`, one pass. Peak scratch is
/// bounded by the widest frontier the walk holds, not by the node count.
pub fn nodeTable(gpa: Allocator, tree: *const Ast.Tree) Error!NodeTable {
    var rows: std.ArrayList(NodeTable.Row) = .empty;
    errdefer rows.deinit(gpa);

    var stack: std.ArrayList(PendingNode) = .empty;
    defer stack.deinit(gpa);

    // Roots pushed in reverse so the LIFO pops them in source order.
    var r = tree.root.len;
    while (r > 0) {
        r -= 1;
        try stack.append(gpa, .{
            .node = tree.root[r],
            .parent = null,
            .root = @intCast(r),
            .seg = null,
            .key_span = null,
        });
    }

    while (stack.pop()) |pending| {
        const tag = tree.tagOf(pending.node);
        std.debug.assert(tag != .kvpair);

        const row_idx: u32 = @intCast(rows.items.len);
        if (pending.parent) |p| std.debug.assert(p < row_idx);
        try rows.append(gpa, .{
            .node = pending.node,
            .parent = pending.parent,
            .root = pending.root,
            .seg = pending.seg,
            .tag = tag,
            .span = tree.spanOf(pending.node),
            .head_span = if (tag == .form) tree.formHeader(pending.node).head_span else null,
            .key_span = pending.key_span,
        });

        try pushChildren(gpa, tree, &stack, pending.node, tag, row_idx, pending.root);
    }

    return .{ .gpa = gpa, .rows = try rows.toOwnedSlice(gpa) };
}

/// Push `node`'s addressable children, reversed so the LIFO yields them in
/// source order. A kvpair contributes its value, carrying the pair's key
/// down as the value row's `key_span`; positional steps count with the
/// kvpairs skipped, exactly as `findPositionalSlot` counts them.
fn pushChildren(
    gpa: Allocator,
    tree: *const Ast.Tree,
    stack: *std.ArrayList(PendingNode),
    node: Ast.NodeIndex,
    tag: Ast.Tag,
    row_idx: u32,
    root: u32,
) Error!void {
    switch (tag) {
        .form => {
            const children = tree.formHeader(node).children;
            // The positional step of child `i` needs the count of
            // positionals *before* it, so the reversed push counts down
            // from the total rather than up from zero.
            var positional: u32 = 0;
            for (children) |child| {
                if (tree.tagOf(child) != .kvpair) positional += 1;
            }
            var i = children.len;
            while (i > 0) {
                i -= 1;
                const child = children[i];
                if (tree.tagOf(child) == .kvpair) {
                    const kvh = tree.kvpairHeader(child);
                    try stack.append(gpa, .{
                        .node = kvh.value,
                        .parent = row_idx,
                        .root = root,
                        .seg = .{ .key = kvh.key },
                        .key_span = kvh.key_span,
                    });
                } else {
                    positional -= 1;
                    try stack.append(gpa, .{
                        .node = child,
                        .parent = row_idx,
                        .root = root,
                        .seg = .{ .index = positional },
                        .key_span = null,
                    });
                }
            }
            std.debug.assert(positional == 0);
        },
        .vector => {
            const elements = tree.vectorElements(node);
            var i = elements.len;
            while (i > 0) {
                i -= 1;
                try stack.append(gpa, .{
                    .node = elements[i],
                    .parent = row_idx,
                    .root = root,
                    .seg = .{ .index = @intCast(i) },
                    .key_span = null,
                });
            }
        },
        // Every other tag is a leaf: it has no children to address.
        else => {},
    }
}

/// The address of `node` in `tree`, or null when the node is not
/// addressable. Caller releases via `address.deinit()`.
///
/// Built on `nodeTable`'s walk rather than beside it: an address needs a
/// parent link per node, that is what the table already is, and two walks
/// that had to agree about positional counting would be one more thing to
/// keep in step. A caller resolving more than one node should hold the
/// table and use `addressOfRow` instead of paying for a walk each time.
///
/// Null has two causes and they are not worth distinguishing here: `node`
/// is a `.kvpair`, which §11.2 addresses through rather than at, or it is
/// not a node of this tree at all.
///
/// Complexity: O(n) over `tree.nodes.len`.
pub fn addressOf(gpa: Allocator, tree: *const Ast.Tree, node: Ast.NodeIndex) Error!?Address {
    const table = try nodeTable(gpa, tree);
    defer table.deinit();
    const row = table.rowOf(node) orelse return null;
    return try table.addressOfRow(gpa, row);
}

// -- One op, one edit --------------------------------------------------------

fn replaceEdit(
    gpa: Allocator,
    tree: *const Ast.Tree,
    target: Ast.NodeIndex,
    value: std.json.Value,
    opts: Options,
) Error!TextEdit {
    const span = tree.spanOf(target);
    const text = try printValue(gpa, value, opts, columnOf(tree.source, span.start));
    return .{ .span_start = span.start, .span_end = span.end, .new_text = text };
}

fn setKeywordEdit(
    gpa: Allocator,
    tree: *const Ast.Tree,
    form_idx: Ast.NodeIndex,
    key: []const u8,
    value: std.json.Value,
    opts: Options,
) Error!TextEdit {
    if (tree.tagOf(form_idx) != .form) return error.PathTypeMismatch;
    const hdr = tree.formHeader(form_idx);
    const source = tree.source;

    // Key present: only the value's bytes move. The key, its spacing and
    // the pair's leading comments are all outside the span.
    if (findKeywordSlot(tree, hdr, key)) |abs| {
        const span = tree.spanOf(tree.kvpairHeader(hdr.children[abs]).value);
        const text = try printValue(gpa, value, opts, columnOf(source, span.start));
        return .{ .span_start = span.start, .span_end = span.end, .new_text = text };
    }

    // Key absent: ` :key value` before the closing paren — the rule
    // `EffectiveDocument.formInsertion` already writes defaults with.
    const close = closingDelimiter(source, tree, form_idx) orelse return error.NoSourceSpan;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, " :");
    try out.appendSlice(gpa, key);
    try out.append(gpa, ' ');

    const value_text = try printValue(gpa, value, opts, columnAfter(source, close, out.items));
    defer gpa.free(value_text);
    try out.appendSlice(gpa, value_text);
    return .{ .span_start = close, .span_end = close, .new_text = try out.toOwnedSlice(gpa) };
}

fn removeKeywordEdit(
    tree: *const Ast.Tree,
    form_idx: Ast.NodeIndex,
    key: []const u8,
) Error!TextEdit {
    if (tree.tagOf(form_idx) != .form) return error.PathTypeMismatch;
    const hdr = tree.formHeader(form_idx);
    const abs = findKeywordSlot(tree, hdr, key) orelse return error.PathNotFound;
    return removeChildEdit(tree, form_idx, hdr.children, abs);
}

fn removePositionalEdit(
    tree: *const Ast.Tree,
    container_idx: Ast.NodeIndex,
    index: usize,
) Error!TextEdit {
    switch (tree.tagOf(container_idx)) {
        .form => {
            const hdr = tree.formHeader(container_idx);
            const abs = findPositionalSlot(tree, hdr, index).abs orelse return error.PathNotFound;
            return removeChildEdit(tree, container_idx, hdr.children, abs);
        },
        .vector => {
            const elements = tree.vectorElements(container_idx);
            if (index >= elements.len) return error.PathNotFound;
            return removeChildEdit(tree, container_idx, elements, index);
        },
        else => return error.PathTypeMismatch,
    }
}

fn insertPositionalEdit(
    gpa: Allocator,
    tree: *const Ast.Tree,
    container_idx: Ast.NodeIndex,
    index_opt: ?usize,
    value: std.json.Value,
    opts: Options,
) Error!TextEdit {
    const source = tree.source;
    const children = try containerChildren(tree, container_idx);
    const before = try insertBefore(tree, container_idx, children, index_opt);

    if (before) |abs| {
        // Land on the child's own offset and push it right behind a copy
        // of the spacing that pairs with it, so the new child inherits the
        // container's shape whatever that shape is.
        const at = tree.spanOf(children[abs]).start;
        const separator = separatorText(source, try childGap(tree, container_idx, children, abs));
        const value_text = try printValue(gpa, value, opts, columnOf(source, at));
        defer gpa.free(value_text);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, value_text);
        try out.appendSlice(gpa, separator);
        return .{ .span_start = at, .span_end = at, .new_text = try out.toOwnedSlice(gpa) };
    }

    // Append: the spacing that pairs with the *last* child, then the
    // value, at the closing delimiter. The run after the last child is
    // empty in a compact container and holds the closing delimiter's own
    // line break in a broken one, so it is the wrong side to copy.
    const close = closingDelimiter(source, tree, container_idx) orelse return error.NoSourceSpan;
    const separator: []const u8 = if (children.len > 0)
        separatorText(source, try childGap(tree, container_idx, children, children.len - 1))
    else switch (tree.tagOf(container_idx)) {
        // A childless form still has its head to sit after; a childless
        // vector has `[` and `]` touching, and `[1]` is the wanted shape.
        .form => " ",
        else => "",
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, separator);
    const value_text = try printValue(gpa, value, opts, columnAfter(source, close, separator));
    defer gpa.free(value_text);
    try out.appendSlice(gpa, value_text);
    return .{ .span_start = close, .span_end = close, .new_text = try out.toOwnedSlice(gpa) };
}

/// Insert a root before the `index`th one, or after the last when `index`
/// is omitted.
///
/// The value is printed from **column 0** rather than from the column the
/// splice lands at: a root starts a line, so saying so keeps the printed
/// root independent of whatever precedes the insertion point.
///
/// The append anchor is the last root's own end, not the end of the
/// document. A forest has no closing delimiter to sit before, and the
/// last root's end is before any tree-trailing comments — which is where
/// the printer puts a root too (`Printer.zig:174-189` pushes those first,
/// so they pop last).
fn insertRootEdit(
    gpa: Allocator,
    tree: *const Ast.Tree,
    index: ?usize,
    value: std.json.Value,
    opts: Options,
) Error!TextEdit {
    const roots = tree.root;
    const at = index orelse roots.len;
    if (at > roots.len) return error.PathNotFound;

    const value_text = try printValue(gpa, value, opts, 0);
    defer gpa.free(value_text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (roots.len == 0) {
        // A rootless document: the degenerate insert-before, with "the
        // start of root 0" reading as "the start of whatever is there".
        // A zero-byte document becomes `(a)\n`; `; just a note` becomes
        // `(a)\n; just a note`, which is where the printer puts a root
        // relative to the comments that trail a tree.
        try out.appendSlice(gpa, value_text);
        try out.appendSlice(gpa, ROOT_SEPARATOR);
        return .{ .span_start = 0, .span_end = 0, .new_text = try out.toOwnedSlice(gpa) };
    }
    if (at < roots.len) {
        const before = tree.spanOf(roots[at]).start;
        try out.appendSlice(gpa, value_text);
        try out.appendSlice(gpa, rootSeparator(tree, at));
        return .{ .span_start = before, .span_end = before, .new_text = try out.toOwnedSlice(gpa) };
    }
    const after = tree.spanOf(roots[roots.len - 1]).end;
    try out.appendSlice(gpa, rootSeparator(tree, roots.len - 1));
    try out.appendSlice(gpa, value_text);
    return .{ .span_start = after, .span_end = after, .new_text = try out.toOwnedSlice(gpa) };
}

/// Delete root `index` together with the run that leads it, so the roots
/// around it stay spaced as they were and the comments that introduce it
/// leave with it. `removeChildEdit`'s `before = true` arm, one level up.
fn removeRootEdit(tree: *const Ast.Tree, index: usize) Error!TextEdit {
    if (index >= tree.root.len) return error.PathNotFound;
    const span = tree.spanOf(tree.root[index]);
    const gap = rootGap(tree, index);
    if (gap.span.start > span.end) return error.NoSourceSpan;
    return .{ .span_start = gap.span.start, .span_end = span.end, .new_text = "" };
}

/// The whitespace run that pairs with root `i`: `childGap`'s form arm one
/// level up, and always the run *before* the root.
///
/// A vector's first element genuinely has nothing before it inside the
/// brackets, which is why `childGap` flips sides there. Root 0 does have
/// something before it — the document's prologue — and it is text of the
/// same kind as the run between a form's head and its first child. So the
/// forest never flips, and both of §11.6's sentences hold for it verbatim.
fn rootGap(tree: *const Ast.Tree, i: usize) Gap {
    std.debug.assert(i < tree.root.len);
    const span = tree.spanOf(tree.root[i]);
    const start: u32 = if (i > 0) tree.spanOf(tree.root[i - 1]).end else 0;
    std.debug.assert(start <= span.start);
    return .{ .span = .{ .start = start, .end = span.start }, .before = true };
}

/// The spacing an inserted root is separated by: root `i`'s own run when
/// the document has one to copy, and otherwise a single newline.
///
/// `"\n"` and not the `" "` a container falls back to, because that is
/// what SJON's two other writers of a top-level sibling already produce —
/// `Printer.zig:187` separates roots with one `raw_newline`, and the
/// LSP's definition hoist writes one `'\n'`. Two roots on one line parse;
/// nothing in this repo writes them.
///
/// Only a one-root document reaches the fallback. From the second root
/// onward the separator is the author's own run, blank lines included.
fn rootSeparator(tree: *const Ast.Tree, i: usize) []const u8 {
    return separatorOr(tree.source, rootGap(tree, i), ROOT_SEPARATOR);
}

/// What separates two roots when the document has no run to copy: the
/// one-root case, and the rootless one.
const ROOT_SEPARATOR = "\n";

/// Compose `target` into a new parent without re-printing it.
///
/// The wrapped tree is built exactly as the re-print apply builds it
/// (`wrapAt`), printed as a fragment, and then the target's own source
/// bytes are put back over the printer's rendering of it. Finding that
/// rendering needs no sentinel: printing preserves structure, so walking
/// `hole` over a re-parse of the fragment lands on the same slot, and its
/// span is the byte range to swap.
///
/// The clone's trivia is suppressed before printing. Its leading comments
/// for `Handler.getRangeFormatEdits`' reason — a node's span does not cover
/// the comments that lead it, so they stay in the document and printing
/// them here too would duplicate them — and the rest because none of the
/// printed target survives: in `.full` mode a comment anywhere in a subtree
/// forces every ancestor multi-line, which would break the new parent for a
/// comment the output never shows there.
///
/// A multi-line target keeps its inner lines at their old columns inside
/// its new parent — the one place this apply leaves a document it would
/// not have written. `sjon fmt` is the remedy.
fn wrapEdit(
    gpa: Allocator,
    tree: *const Ast.Tree,
    target: Ast.NodeIndex,
    template: std.json.Value,
    hole: []const std.json.Value,
    opts: Options,
) Error!TextEdit {
    // The decoder rejects an empty hole; nothing else builds a `.wrap`.
    std.debug.assert(hole.len > 0);
    const source = tree.source;
    const span = tree.spanOf(target);

    var wrapped = try buildWrappedTree(gpa, tree, target, template, hole);
    defer wrapped.deinit();

    const printed = try Printer.printNode(
        gpa,
        wrapped,
        wrapped.root[0],
        opts.printerOptions(),
        columnOf(source, span.start),
    );
    defer printed.deinit();

    const printed_z = try gpa.dupeZ(u8, printed.data);
    defer gpa.free(printed_z);
    var reprint = try Parser.parse(gpa, printed_z);
    defer reprint.deinit();
    // The printer's contract is that its output parses back to the same
    // structure. These are invariants of our own output, not questions
    // about the caller's input, so they assert rather than diagnose.
    std.debug.assert(!reprint.hasErrors());
    std.debug.assert(reprint.root.len == 1);
    const hole_span = reprint.spanOf(try resolvePath(&reprint, reprint.root[0], hole));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, printed.data[0..hole_span.start]);
    try out.appendSlice(gpa, source[span.start..span.end]);
    try out.appendSlice(gpa, printed.data[hole_span.end..]);
    return .{ .span_start = span.start, .span_end = span.end, .new_text = try out.toOwnedSlice(gpa) };
}

/// `template` decoded, with `target` cloned into the slot `hole` names —
/// the same tree `wrapAt` produces, standing alone rather than inside a
/// rebuilt document.
fn buildWrappedTree(
    gpa: Allocator,
    tree: *const Ast.Tree,
    target: Ast.NodeIndex,
    template: std.json.Value,
    hole: []const std.json.Value,
) Error!Ast.Tree {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var b: Ast.TreeBuilder = .{ .a = arena.allocator() };

    var tmpl = try Json.fromJson(gpa, template, .{});
    defer tmpl.deinit();
    std.debug.assert(tmpl.root.len == 1); // fromJson raises MultipleRoots otherwise

    const first_node: u32 = @intCast(b.nodes.len);
    const clone = try b.cloneNode(tree, target);
    // Every node `cloneNode` appended belongs to the clone; see the header
    // for why none of them keeps its comments.
    var i: u32 = first_node;
    while (i < b.nodes.len) : (i += 1) {
        const idx = Ast.NodeIndex.from(i);
        b.setLeading(idx, .empty);
        b.setTrailing(idx, .empty);
    }

    const t_ctx: Ctx = .{ .gpa = gpa, .b = &b, .src = &tmpl };
    const root = try applyAtPath(t_ctx, tmpl.root[0], hole, .{ .replace_node = .{ .value = clone } });

    const roots = try b.a.alloc(Ast.NodeIndex, 1);
    roots[0] = root;
    return b.finalizeWith(&arena, tree.source, roots, .{});
}

// -- Coordinates -------------------------------------------------------------

/// The positional children of a form or the elements of a vector — the
/// child list an insert or a remove indexes into.
fn containerChildren(tree: *const Ast.Tree, idx: Ast.NodeIndex) Error![]const Ast.NodeIndex {
    return switch (tree.tagOf(idx)) {
        .form => tree.formHeader(idx).children,
        .vector => tree.vectorElements(idx),
        else => error.PathTypeMismatch,
    };
}

/// Absolute child slot an `insert_positional` lands before, or null to
/// append. Translates the positional *ordinal* the action carries the way
/// `insertPositionalForm` / `insertPositionalVector` do, so the two applies
/// insert at the same place.
fn insertBefore(
    tree: *const Ast.Tree,
    container_idx: Ast.NodeIndex,
    children: []const Ast.NodeIndex,
    index_opt: ?usize,
) Error!?usize {
    const want = index_opt orelse return null;
    switch (tree.tagOf(container_idx)) {
        .form => {
            const slot = findPositionalSlot(tree, tree.formHeader(container_idx), want);
            if (slot.abs) |abs| return abs;
            if (want > slot.count) return error.PathNotFound;
            return null; // want == count -> append
        },
        .vector => {
            if (want > children.len) return error.PathNotFound;
            return if (want < children.len) want else null;
        },
        else => return error.PathTypeMismatch,
    }
}

/// Delete child `abs` together with the whitespace that pairs with it, so
/// its siblings stay spaced as they were. When that whitespace precedes
/// the child it carries the child's leading comments, and they leave with
/// it — the same thing the re-print does.
fn removeChildEdit(
    tree: *const Ast.Tree,
    container_idx: Ast.NodeIndex,
    children: []const Ast.NodeIndex,
    abs: usize,
) Error!TextEdit {
    std.debug.assert(abs < children.len);
    const span = tree.spanOf(children[abs]);
    const gap = try childGap(tree, container_idx, children, abs);
    const from = if (gap.before) gap.span.start else span.start;
    const to = if (gap.before) span.end else gap.span.end;
    if (from > to) return error.NoSourceSpan;
    return .{ .span_start = from, .span_end = to, .new_text = "" };
}

/// The whitespace run that pairs with child `abs`, and which side of it
/// that run is on.
///
/// Normally the gap *before* the child: after the previous child, or after
/// a form's head. A vector's first element has nothing before it inside
/// the brackets, so the gap that pairs with it is the one that *follows*
/// it — take the preceding one there and a remove leaves the space behind
/// (`[1 2 3]` → `[ 2 3]`) while an insert lands against the `[`.
///
/// Both callers read the same run: a remove deletes the child and it, an
/// insert repeats its text beside the child.
const Gap = struct { span: Ast.Span, before: bool };

fn childGap(
    tree: *const Ast.Tree,
    container_idx: Ast.NodeIndex,
    children: []const Ast.NodeIndex,
    abs: usize,
) Error!Gap {
    const span = tree.spanOf(children[abs]);
    if (abs > 0) {
        return .{ .span = .{ .start = tree.spanOf(children[abs - 1]).end, .end = span.start }, .before = true };
    }
    switch (tree.tagOf(container_idx)) {
        .form => return .{
            .span = .{ .start = tree.formHeader(container_idx).head_span.end, .end = span.start },
            .before = true,
        },
        .vector => return .{
            .span = .{
                .start = span.end,
                .end = if (children.len > 1) tree.spanOf(children[1]).start else span.end,
            },
            .before = false,
        },
        else => return error.PathTypeMismatch,
    }
}

/// The spacing an insert repeats beside a child: the gap's trailing run of
/// whitespace, or a single space when there is none.
///
/// The *trailing* run, not the whole gap, because a gap may hold a comment
/// (`:w 1   ; width\n  :h 2`) and a comment is about the child it leads,
/// not about how the children are spaced — copying it would put a second
/// copy of the author's sentence in the document. A removal takes the
/// whole gap, comment included, for the mirror reason: there the comment
/// leaves with the child it belongs to.
///
/// An empty run means the child has no sibling to be spaced from (`[1]`),
/// and a splice beside it still needs one byte of separation.
fn separatorText(source: []const u8, gap: Gap) []const u8 {
    return separatorOr(source, gap, " ");
}

/// `separatorText` with the fallback spelled by the caller. A container's
/// children are separated by a space when there is no run to copy; roots
/// are separated by a newline (`rootSeparator`).
fn separatorOr(source: []const u8, gap: Gap, empty: []const u8) []const u8 {
    const text = source[gap.span.start..gap.span.end];
    var i = text.len;
    while (i > 0 and std.ascii.isWhitespace(text[i - 1])) i -= 1;
    return if (i == text.len) empty else text[i..];
}

/// Offset of the container's own closing delimiter — `)` for a form, `]`
/// for a vector — or null when the tree's spans do not describe one.
///
/// The form case *is* `EffectiveDocument.formClosingParen`, which already
/// carries the recovered-form guard and is already shared by the
/// effective-document splicer, the LSP's inlay hints and its
/// definition-hoist action. The vector case is the same three checks with
/// `]`, written here rather than generalised there because that splicer
/// never inserts into a vector.
fn closingDelimiter(source: []const u8, tree: *const Ast.Tree, idx: Ast.NodeIndex) ?u32 {
    switch (tree.tagOf(idx)) {
        .form => return EffectiveDocument.formClosingParen(source, tree, idx),
        .vector => {
            const span = tree.spanOf(idx);
            if (span.end == 0 or span.end > source.len) return null;
            const close = span.end - 1;
            if (source[close] != ']') return null;
            const elements = tree.vectorElements(idx);
            if (elements.len > 0 and tree.spanOf(elements[elements.len - 1]).end >= span.end) return null;
            std.debug.assert(close >= span.start);
            return close;
        },
        else => return null,
    }
}

/// 0-based column of `offset` in `source`.
fn columnOf(source: []const u8, offset: u32) u16 {
    const upto = source[0..@min(offset, source.len)];
    const col = if (std.mem.lastIndexOfScalar(u8, upto, '\n')) |nl| upto.len - nl - 1 else upto.len;
    return @intCast(@min(col, std.math.maxInt(u16)));
}

/// The column a spliced value lands at when `prefix` precedes it inside the
/// same edit: `prefix`'s own last line when it breaks, otherwise the
/// insertion point advanced by its width.
fn columnAfter(source: []const u8, offset: u32, prefix: []const u8) u16 {
    if (std.mem.lastIndexOfScalar(u8, prefix, '\n')) |nl| {
        return @intCast(@min(prefix.len - nl - 1, std.math.maxInt(u16)));
    }
    return @intCast(@min(@as(usize, columnOf(source, offset)) + prefix.len, std.math.maxInt(u16)));
}

/// An edit value, printed as a fragment for a splice at `column`. Caller
/// owns the bytes.
fn printValue(gpa: Allocator, value: std.json.Value, opts: Options, column: u16) Error![]u8 {
    var tmp = try Json.fromJson(gpa, value, .{});
    defer tmp.deinit();
    std.debug.assert(tmp.root.len == 1); // fromJson raises MultipleRoots otherwise
    const printed = try Printer.printNode(gpa, tmp, tmp.root[0], opts.printerOptions(), column);
    return printed.data;
}

// -- The text->text fold -----------------------------------------------------

/// `source` with `edit` applied. Every byte outside `[span_start,
/// span_end)` is copied through untouched — the whole property the
/// preserve layout exists for, and the one a test can assert directly.
fn splice(gpa: Allocator, source: []const u8, edit: TextEdit) Allocator.Error![]u8 {
    std.debug.assert(edit.span_start <= edit.span_end);
    std.debug.assert(edit.span_end <= source.len);
    const out = try gpa.alloc(u8, source.len - (edit.span_end - edit.span_start) + edit.new_text.len);
    errdefer gpa.free(out);
    @memcpy(out[0..edit.span_start], source[0..edit.span_start]);
    @memcpy(out[edit.span_start..][0..edit.new_text.len], edit.new_text);
    @memcpy(out[edit.span_start + edit.new_text.len ..], source[edit.span_end..]);
    return out;
}

/// Fold `actions` over `source` as text: lower, splice, re-parse, repeat.
/// `first` is `source` already parsed — `applyEdits` needed that parse to
/// refuse a broken document, so this takes it rather than repeating it.
///
/// An empty batch returns `source` byte-for-byte. That is the whole
/// difference from the re-print fold's "canonical/full no-op": under
/// `.preserve` there is nothing to normalise to.
fn spliceEdits(
    gpa: Allocator,
    source: [:0]const u8,
    first: *const Ast.Tree,
    actions: []const std.json.Value,
    opts: Options,
) Error!Ast.Bytes {
    if (actions.len == 0) return .{ .gpa = gpa, .data = try gpa.dupe(u8, source) };

    // One arena for every action's intermediates; reset, not rebuilt,
    // between hops. `cur` is gpa-owned because it outlives each reset.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var cur = try splice(gpa, source, try textEdit(arena.allocator(), first, actions[0], opts));
    errdefer gpa.free(cur);

    for (actions[1..]) |action| {
        _ = arena.reset(.retain_capacity);
        const cur_z = try gpa.dupeZ(u8, cur);
        defer gpa.free(cur_z);
        var tree = try Parser.parse(gpa, cur_z);
        defer tree.deinit();
        // A splice that produced something unparseable must stop the batch
        // rather than let the next action cut against wrong coordinates.
        if (tree.hasErrors()) return error.ParseErrors;

        const next = try splice(gpa, cur_z, try textEdit(arena.allocator(), &tree, action, opts));
        gpa.free(cur);
        cur = next;
    }
    return .{ .gpa = gpa, .data = cur };
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

test "every path-taking op refuses a missing path with InvalidAction" {
    // `path` is read per op now, not in the decoder's prologue, so the
    // refusal is six refusals and each one has to still be there.
    const actions = [_][]const u8{
        \\{"op":"set_keyword","key":"a","value":1}
        ,
        \\{"op":"remove_keyword","key":"a"}
        ,
        \\{"op":"replace","value":1}
        ,
        \\{"op":"wrap","value":{"$form":"g"},"hole":[0]}
        ,
        \\{"op":"insert_positional","value":1}
        ,
        \\{"op":"remove_positional","index":0}
        ,
    };
    for (actions) |json_text| {
        try testing.expectError(error.InvalidAction, applyEditFromJsonString(
            testing.allocator,
            "(scene :a 1)",
            json_text,
            .{},
        ));
    }
}

test "an unknown op reports UnknownOp with or without a path" {
    // Before the per-op read, the prologue refused the missing `path`
    // first and an unknown op that carried none reported `InvalidAction`.
    for ([_][]const u8{
        \\{"op":"explode","value":1}
        ,
        \\{"op":"nonsense"}
        ,
        \\{"op":"nonsense","path":[]}
        ,
    }) |json_text| {
        try testing.expectError(error.UnknownOp, applyEditFromJsonString(
            testing.allocator,
            "(scene :a 1)",
            json_text,
            .{},
        ));
    }
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

test "remove_keyword: multi-root source with no root field raises MultipleRoots" {
    // The backward-compatibility rule for the `root` field: an action that
    // omits it keeps the pre-`root` refusal, rather than defaulting to 0
    // and silently editing whichever form happens to come first.
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

/// A tree equal to `parse(source)` but carrying one arena-owned
/// **warning** diagnostic with both a message and a non-empty semantic
/// path — the two fields `Diagnostic.dupe` must deep-copy. An unclosed
/// form would produce such a diagnostic for free, but `applyEditToTree`
/// refuses a tree with `err`-severity diagnostics, so warnings are now
/// the only severity that reaches the rebuild at all.
fn parseWithWarning(gpa: Allocator, source: [:0]const u8) !Ast.Tree {
    var src = try Parser.parse(gpa, source);
    defer src.deinit();
    std.debug.assert(!src.hasErrors());

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var b: Ast.TreeBuilder = .{ .a = a };

    const roots = try a.alloc(Ast.NodeIndex, src.root.len);
    for (src.root, roots) |root_idx, *out| out.* = try b.cloneNode(&src, root_idx);

    const path = try a.alloc([]const u8, 1);
    path[0] = try a.dupe(u8, "scene");
    const diags = try a.alloc(Ast.Diagnostic, 1);
    diags[0] = .{
        .span = .{ .start = 0, .end = 6 },
        .message = try a.dupe(u8, "a warning rides along with the edit"),
        .severity = .warning,
        .path = path,
    };
    return b.finalizeWith(&arena, source, roots, .{ .diagnostics = diags });
}

test "applyEditToTree: edited tree owns its diagnostics (no source-arena aliasing)" {
    var src = try parseWithWarning(testing.allocator, "(scene :bpm 130)");
    defer src.deinit();
    try testing.expectEqual(@as(usize, 1), src.diagnostics.len);
    try testing.expect(src.diagnostics[0].path.len >= 1);
    try testing.expect(!src.hasErrors());

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

// ---------------------------------------------------------------------------
// wrap — compose an existing node into a new parent
// ---------------------------------------------------------------------------

test "wrap: the ask — the wrapped subtree keeps its inner comment" {
    // The whole point of the op. Spelling this as a `replace` whose value
    // nests the target re-encodes it through `Json.fromJson`, which drops
    // `; inner note` — the bridge carries no comments.
    const src =
        \\(a :x (* 2 ; inner note
        \\           (sin t)))  ; the wobble
    ;
    const got = try applyEditFromJsonString(
        testing.allocator,
        src,
        \\{"op":"wrap","path":["x"],"value":{"$expr":["+",null,0.1]},"hole":[0]}
    ,
        .{ .mode = .full },
    );
    defer got.deinit();
    try testing.expectEqualStrings(
        \\(a
        \\  :x (+
        \\    (*
        \\      2
        \\      ; inner note
        \\      (sin t))
        \\    0.1))
        \\; the wobble
        \\
    , got.data);

    // What `.full` mode promises is the *comments*, not the byte layout:
    // parse → print with no edit at all reflows this source exactly the
    // same way (a form carrying a comment cannot stay on one line, and a
    // trailing comment lands on its own). So the output above is the
    // no-edit print with `(+ … 0.1)` composed around `:x`, and every
    // difference from the source is the printer's, not the wrap's.
    var reprinted = try applyEditsFromJsonString(testing.allocator, src, "[]", .{ .mode = .full });
    defer reprinted.deinit();
    try testing.expectEqualStrings(
        \\(a
        \\  :x (*
        \\    2
        \\    ; inner note
        \\    (sin t)))
        \\; the wobble
        \\
    , reprinted.data);

    // Control: the `replace` spelling of the same shape loses it.
    const via_replace = try applyEditFromJsonString(
        testing.allocator,
        src,
        \\{"op":"replace","path":["x"],"value":{"$expr":["+",{"$expr":["*",2,{"$expr":["sin",{"$sym":"t"}]}]},0.1]}}
    ,
        .{ .mode = .full },
    );
    defer via_replace.deinit();
    try testing.expect(std.mem.indexOf(u8, via_replace.data, "; inner note") == null);
}

test "wrap: an empty path wraps the root" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(warp :source title)",
        \\{"op":"wrap","path":[],"value":{"$form":"transform","$children":[null]},"hole":[0]}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(transform (warp :source title))\n", got.data);
}

test "wrap: the hole may sit after a keyword pair" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(warp :source title)",
        \\{"op":"wrap","path":[],"value":{"$form":"transform","translate":1,"$children":[null]},"hole":[0]}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings(
        "(transform :translate 1 (warp :source title))\n",
        got.data,
    );
}

test "wrap: the hole may be a kvpair value" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(k 1)",
        \\{"op":"wrap","path":[],"value":{"$form":"outer","inner":null},"hole":["inner"]}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(outer :inner (k 1))\n", got.data);
}

test "wrap: the hole may be nested inside a vector" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "2",
        \\{"op":"wrap","path":[],"value":{"$form":"v","$children":[[null,3]]},"hole":[0,0]}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(v [2 3])\n", got.data);
}

test "wrap: an empty hole surfaces InvalidPath" {
    // A wrap with no hole is a `replace` with extra syntax — there is
    // nowhere for the target to land.
    try testing.expectError(error.InvalidPath, applyEditFromJsonString(
        testing.allocator,
        "(a :x 1)",
        \\{"op":"wrap","path":["x"],"value":{"$form":"w","$children":[null]},"hole":[]}
    ,
        .{},
    ));
}

test "wrap: a hole naming a missing slot surfaces PathNotFound" {
    try testing.expectError(error.PathNotFound, applyEditFromJsonString(
        testing.allocator,
        "(a :x 1)",
        \\{"op":"wrap","path":["x"],"value":{"$form":"w","$children":[null]},"hole":["nope"]}
    ,
        .{},
    ));
}

test "wrap: a hole descending through a scalar surfaces PathTypeMismatch" {
    try testing.expectError(error.PathTypeMismatch, applyEditFromJsonString(
        testing.allocator,
        "(a :x 1)",
        \\{"op":"wrap","path":["x"],"value":{"$form":"w","$children":[5]},"hole":[0,0]}
    ,
        .{},
    ));
}

test "wrap: a missing hole field surfaces InvalidAction" {
    try testing.expectError(error.InvalidAction, applyEditFromJsonString(
        testing.allocator,
        "(a :x 1)",
        \\{"op":"wrap","path":["x"],"value":1}
    ,
        .{},
    ));
}

test "wrap: a non-array hole surfaces InvalidPath" {
    try testing.expectError(error.InvalidPath, applyEditFromJsonString(
        testing.allocator,
        "(a :x 1)",
        \\{"op":"wrap","path":["x"],"value":1,"hole":"0"}
    ,
        .{},
    ));
}

test "wrap: a multi-root template surfaces MultipleRoots" {
    try testing.expectError(error.MultipleRoots, applyEditFromJsonString(
        testing.allocator,
        "(a :x 1)",
        \\{"op":"wrap","path":["x"],"value":{"$roots":[1,2]},"hole":[0]}
    ,
        .{},
    ));
}

test "wrap: an over-long hole is bounded like a path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `hole` is walked by the same recursion as `path`, so it takes the
    // same ceiling — and the rejection is up front, before any template is
    // decoded, exactly as the `path` bound is.
    var hole = std.json.Array.init(a);
    for (0..2000) |_| try hole.append(.{ .integer = 0 });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "op", .{ .string = "wrap" });
    try obj.put(a, "path", .{ .array = std.json.Array.init(a) });
    try obj.put(a, "value", .{ .integer = 1 });
    try obj.put(a, "hole", .{ .array = hole });

    var src = try Parser.parse(testing.allocator, "(scene 1)");
    defer src.deinit();
    try testing.expectError(
        error.DepthExceeded,
        applyEditToTree(testing.allocator, &src, .{ .object = obj }),
    );
}

test "wrap: folds through applyEdits like any other action" {
    // Wrap the root, then set a key on the *new* parent — the second action
    // addresses the tree the first produced.
    const got = try applyEditsFromJsonString(
        testing.allocator,
        "(warp :source title)",
        \\[{"op":"wrap","path":[],"value":{"$form":"transform","$children":[null]},"hole":[0]},
        \\ {"op":"set_keyword","path":[],"key":"translate","value":0.12}]
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings(
        "(transform (warp :source title) :translate 0.12)\n",
        got.data,
    );
}

test "wrap: the wrapped subtree's own spans survive into the result" {
    // The target crosses through `cloneNode`, so it keeps the real spans it
    // was parsed with; the template's nodes carry `fromJson`'s zero-width
    // ones. This is what lets `.full` mode re-emit the subtree's trivia.
    const source = "(a :x (* 2 3))";
    var src = try Parser.parse(testing.allocator, source);
    defer src.deinit();

    var parsed = try parseAction(
        testing.allocator,
        \\{"op":"wrap","path":["x"],"value":{"$form":"w","$children":[null]},"hole":[0]}
        ,
    );
    defer parsed.deinit();

    var edited = try applyEditToTree(testing.allocator, &src, parsed.value);
    defer edited.deinit();

    // root → (a :x …) → the `:x` kvpair → (w …) → the wrapped (* 2 3).
    const root_hdr = edited.formHeader(edited.root[0]);
    try testing.expectEqual(@as(usize, 1), root_hdr.children.len);
    const kv = edited.kvpairHeader(root_hdr.children[0]);
    try testing.expectEqualStrings("x", kv.key);
    const outer = edited.formHeader(kv.value);
    try testing.expectEqualStrings("w", outer.head);
    try testing.expectEqual(@as(usize, 1), outer.children.len);
    const inner_span = edited.spanOf(outer.children[0]);
    try testing.expectEqualStrings("(* 2 3)", source[inner_span.start..inner_span.end]);
}

// ---------------------------------------------------------------------------
// root — which root of a multi-root document the action edits
// ---------------------------------------------------------------------------

test "root: names which root of a multi-root document to edit" {
    // Every document that declares or references a plugin is multi-root,
    // so without this the whole op set is unreachable on a real file.
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(use-plugin \"core\") (scene :bpm 130)",
        \\{"op":"set_keyword","path":[],"root":1,"key":"bpm","value":140}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings(
        "(use-plugin \"core\")\n(scene :bpm 140)\n",
        got.data,
    );
}

test "root: the untargeted roots are cloned through untouched" {
    const src =
        \\; the plugin
        \\(use-plugin "core")
        \\(scene :bpm 130)
        \\; the tail
        \\(other :k 1)
    ;
    const got = try applyEditFromJsonString(
        testing.allocator,
        src,
        \\{"op":"set_keyword","path":[],"root":1,"key":"bpm","value":140}
    ,
        .{ .mode = .full },
    );
    defer got.deinit();
    try testing.expectEqualStrings(
        \\; the plugin
        \\(use-plugin "core")
        \\(scene :bpm 140)
        \\; the tail
        \\(other :k 1)
        \\
    , got.data);
}

test "root: 0 on a single-root document is the same as omitting it" {
    const with = try applyEditFromJsonString(
        testing.allocator,
        "(scene :bpm 130)",
        \\{"op":"set_keyword","path":[],"root":0,"key":"bpm","value":140}
    ,
        .{},
    );
    defer with.deinit();
    const without = try applyEditFromJsonString(
        testing.allocator,
        "(scene :bpm 130)",
        \\{"op":"set_keyword","path":[],"key":"bpm","value":140}
    ,
        .{},
    );
    defer without.deinit();
    try testing.expectEqualStrings(without.data, with.data);
    try testing.expectEqualStrings("(scene :bpm 140)\n", with.data);
}

test "root: out of range surfaces PathNotFound" {
    try testing.expectError(error.PathNotFound, applyEditFromJsonString(
        testing.allocator,
        "(a 1) (b 2)",
        \\{"op":"remove_positional","path":[],"root":2,"index":0}
    ,
        .{},
    ));
}

test "root: negative surfaces InvalidAction" {
    try testing.expectError(error.InvalidAction, applyEditFromJsonString(
        testing.allocator,
        "(a 1) (b 2)",
        \\{"op":"remove_positional","path":[],"root":-1,"index":0}
    ,
        .{},
    ));
}

test "root: non-integer surfaces InvalidAction" {
    try testing.expectError(error.InvalidAction, applyEditFromJsonString(
        testing.allocator,
        "(a 1) (b 2)",
        \\{"op":"remove_positional","path":[],"root":"1","index":0}
    ,
        .{},
    ));
}

test "root: an empty document still raises EmptyTree, root field or not" {
    try testing.expectError(error.EmptyTree, applyEditFromJsonString(
        testing.allocator,
        "",
        \\{"op":"set_keyword","path":[],"root":0,"key":"x","value":1}
    ,
        .{},
    ));
}

test "root: wrap reaches a root of a multi-root document" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(use-plugin \"core\") (warp :source title)",
        \\{"op":"wrap","path":[],"root":1,"value":{"$form":"transform","$children":[null]},"hole":[0]}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings(
        "(use-plugin \"core\")\n(transform (warp :source title))\n",
        got.data,
    );
}

test "root: applyEditToTree keeps every root in the edited tree" {
    var src = try Parser.parse(testing.allocator, "(a 1) (b 2) (c 3)");
    defer src.deinit();
    var parsed = try parseAction(
        testing.allocator,
        \\{"op":"set_keyword","path":[],"root":2,"key":"k","value":9}
        ,
    );
    defer parsed.deinit();

    var edited = try applyEditToTree(testing.allocator, &src, parsed.value);
    defer edited.deinit();
    try testing.expectEqual(@as(usize, 3), edited.root.len);
    try testing.expectEqualStrings("a", edited.formHeader(edited.root[0]).head);
    try testing.expectEqualStrings("b", edited.formHeader(edited.root[1]).head);
    const third = edited.formHeader(edited.root[2]);
    try testing.expectEqualStrings("c", third.head);
    try testing.expectEqual(@as(usize, 2), third.children.len);
}

test "root: batched actions may target different roots" {
    const got = try applyEditsFromJsonString(
        testing.allocator,
        "(a :k 1) (b :k 2)",
        \\[{"op":"set_keyword","path":[],"root":0,"key":"k","value":10},
        \\ {"op":"set_keyword","path":[],"root":1,"key":"k","value":20}]
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(a :k 10)\n(b :k 20)\n", got.data);
}

// ---------------------------------------------------------------------------
// insert_root / remove_root — the forest is a container too
// ---------------------------------------------------------------------------

test "insert_root: appends when index is omitted" {
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(a) (b)",
        \\{"op":"insert_root","value":{"$form":"c"}}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(a)\n(b)\n(c)\n", got.data);
}

test "insert_root: index places the new root before the index-th one" {
    for ([_]struct { idx: u8, want: []const u8 }{
        .{ .idx = 0, .want = "(c)\n(a)\n(b)\n" },
        .{ .idx = 1, .want = "(a)\n(c)\n(b)\n" },
        // index == len is the append spelling, written out.
        .{ .idx = 2, .want = "(a)\n(b)\n(c)\n" },
    }) |case| {
        var buf: [64]u8 = undefined;
        const json = try std.fmt.bufPrint(
            &buf,
            "{{\"op\":\"insert_root\",\"index\":{d},\"value\":{{\"$form\":\"c\"}}}}",
            .{case.idx},
        );
        const got = try applyEditFromJsonString(testing.allocator, "(a) (b)", json, .{});
        defer got.deinit();
        try testing.expectEqualStrings(case.want, got.data);
    }
}

test "insert_root: an index past the end surfaces PathNotFound" {
    try testing.expectError(error.PathNotFound, applyEditFromJsonString(
        testing.allocator,
        "(a) (b)",
        \\{"op":"insert_root","index":3,"value":{"$form":"c"}}
    ,
        .{},
    ));
}

test "insert_root: any value is a root, not only a form" {
    // §4.1: the top level is a container with one narrowing, and `1 2` is
    // a two-root document SJON already prints.
    const got = try applyEditFromJsonString(
        testing.allocator,
        "1",
        \\{"op":"insert_root","value":2}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("1\n2\n", got.data);
}

test "insert_root: a standalone keyword is a legal root, a kvpair is not" {
    // The one narrowing §4.1 states enforces itself: a kvpair has no JSON
    // value of its own, so the bridge refuses it before the forest sees
    // it. A bare `:name` keyword does have one, and is a legal root.
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(a)",
        \\{"op":"insert_root","value":{"$kw":"name"}}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(a)\n:name\n", got.data);

    // `$roots` decodes to a document, not to a value, and `fromJson`
    // refuses more than one root — so a forest cannot be spliced in whole.
    try testing.expectError(error.MultipleRoots, applyEditFromJsonString(
        testing.allocator,
        "(a)",
        \\{"op":"insert_root","value":{"$roots":[1,2]}}
    ,
        .{},
    ));
}

test "remove_root: takes the named root and leaves every other one" {
    for ([_]struct { idx: u8, want: []const u8 }{
        .{ .idx = 0, .want = "(b)\n(c)\n" },
        .{ .idx = 1, .want = "(a)\n(c)\n" },
        .{ .idx = 2, .want = "(a)\n(b)\n" },
    }) |case| {
        var buf: [48]u8 = undefined;
        const json = try std.fmt.bufPrint(
            &buf,
            "{{\"op\":\"remove_root\",\"index\":{d}}}",
            .{case.idx},
        );
        const got = try applyEditFromJsonString(testing.allocator, "(a) (b) (c)", json, .{});
        defer got.deinit();
        try testing.expectEqualStrings(case.want, got.data);
    }
}

test "remove_root: an index past the last root surfaces PathNotFound" {
    try testing.expectError(error.PathNotFound, applyEditFromJsonString(
        testing.allocator,
        "(a) (b)",
        \\{"op":"remove_root","index":2}
    ,
        .{},
    ));
}

test "remove_root: a missing index surfaces InvalidAction" {
    try testing.expectError(error.InvalidAction, applyEditFromJsonString(
        testing.allocator,
        "(a) (b)",
        \\{"op":"remove_root"}
    ,
        .{},
    ));
}

test "the forest ops refuse path and root rather than ignoring them" {
    // Both fields address a node *inside* a root, so a caller who wrote
    // one meant something these two cannot do. Dropping it silently is
    // the failure `MultipleRoots` exists to prevent.
    const cases = [_]struct { json: []const u8, want: anyerror }{
        .{ .json =
        \\{"op":"insert_root","path":[],"value":1}
        , .want = error.InvalidPath },
        .{ .json =
        \\{"op":"insert_root","root":0,"value":1}
        , .want = error.InvalidAction },
        .{ .json =
        \\{"op":"remove_root","path":[],"index":0}
        , .want = error.InvalidPath },
        .{ .json =
        \\{"op":"remove_root","root":0,"index":0}
        , .want = error.InvalidAction },
    };
    for (cases) |case| {
        try testing.expectError(case.want, applyEditFromJsonString(
            testing.allocator,
            "(a) (b)",
            case.json,
            .{},
        ));
    }
}

test "insert_root: the depth ceiling still measures the result" {
    // The forest ops take no `path`, so `requireTarget`' bound never
    // runs for them — the output measurement in `applyEditToTree` is the
    // only thing between a 1025-deep value and every consumer downstream.
    const a = testing.allocator;
    const deep = "[" ** 1025 ++ "null" ++ "]" ** 1025;
    const json = "{\"op\":\"insert_root\",\"value\":" ++ deep ++ "}";
    try testing.expectError(error.DepthExceeded, applyEditFromJsonString(a, "(a)", json, .{}));

    const ok = "[" ** 1023 ++ "null" ++ "]" ** 1023;
    const ok_json = "{\"op\":\"insert_root\",\"value\":" ++ ok ++ "}";
    const got = try applyEditFromJsonString(a, "(a)", ok_json, .{});
    got.deinit();
}

test "preserve: insert_root appends behind the run that separates the roots" {
    // The ask's fixture: the author's blank line comes back on the
    // insert, and the trailing comment stays where the author put it.
    try expectPreserved(
        \\(scene
        \\  :w 800)   ; the scene
        \\
        \\(camera :fov 60)
    ,
        \\{"op":"insert_root","value":{"$form":"light","dir":[0,1,0]}}
    ,
        \\(scene
        \\  :w 800)   ; the scene
        \\
        \\(camera :fov 60)
        \\
        \\(light :dir [0 1 0])
    );
}

test "preserve: insert_root before a root lands at that root's own offset" {
    try expectPreserved(
        \\(a)
        \\
        \\(b)
    ,
        \\{"op":"insert_root","index":1,"value":{"$form":"c"}}
    ,
        \\(a)
        \\
        \\(c)
        \\
        \\(b)
    );
}

test "preserve: a one-root document falls back to a single newline" {
    // The only document with no run to copy. `\n` and not `" "` because
    // that is what the printer and the LSP's definition hoist both write.
    try expectPreserved(
        "(a)",
        \\{"op":"insert_root","value":{"$form":"b"}}
    ,
        "(a)\n(b)",
    );
    try expectPreserved(
        "(a)",
        \\{"op":"insert_root","index":0,"value":{"$form":"b"}}
    ,
        "(b)\n(a)",
    );
}

test "preserve: an appended root lands above the document's trailing comments" {
    // Where the printer puts one: tree-trailing comments are pushed first
    // and therefore pop last.
    try expectPreserved(
        \\(a)
        \\; bye
    ,
        \\{"op":"insert_root","value":{"$form":"b"}}
    ,
        \\(a)
        \\(b)
        \\; bye
    );
}

test "preserve: an inserted root is printed from column 0" {
    // The splice lands after `(a)  ` on a document whose roots are on one
    // line; the value's own layout must not inherit that column.
    try expectPreserved("(a)   (b)",
        \\{"op":"insert_root","index":1,"value":{"$form":"wide","one":"aaaaaaaaaaaaaaaaaaaa","two":"bbbbbbbbbbbbbbbbbbbb"}}
    ,
        \\(a)   (wide
        \\  :one "aaaaaaaaaaaaaaaaaaaa"
        \\  :two "bbbbbbbbbbbbbbbbbbbb")   (b)
    );
}

test "preserve: remove_root takes the run that leads the root" {
    try expectPreserved(
        \\(a)
        \\
        \\(b)
    ,
        \\{"op":"remove_root","index":1}
    ,
        "(a)",
    );
}

test "preserve: a removed root takes the comments that lead it" {
    try expectPreserved(
        \\(a)
        \\; about b
        \\(b)
    ,
        \\{"op":"remove_root","index":1}
    ,
        "(a)",
    );
    // Root 0's run is the document's prologue, so its leading comment
    // leaves with it — the `before = true` arm, one level up.
    try expectPreserved(
        \\; about a
        \\(a)
        \\(b)
    ,
        \\{"op":"remove_root","index":0}
    ,
        "\n(b)",
    );
}

test "preserve: a comment trailing the previous root leads the next one" {
    // `; the scene` sits after root 0's span, so it is root 1's leading
    // run and §11.6's rule keeps it when root 0 goes. `sjon fmt` agrees:
    // it prints the comment between the two roots, not inside the first.
    try expectPreserved(
        \\(scene
        \\  :w 800)   ; the scene
        \\
        \\(camera :fov 60)
    ,
        \\{"op":"remove_root","index":0}
    ,
        \\   ; the scene
        \\
        \\(camera :fov 60)
    );
}

test "preserve: a batch of forest ops is a move" {
    const got = try applyEditsFromJsonString(
        testing.allocator,
        \\(a)
        \\(b)
        \\(c)
    ,
        \\[{"op":"remove_root","index":2},
        \\ {"op":"insert_root","index":0,"value":{"$form":"c"}}]
    ,
        preserve,
    );
    defer got.deinit();
    try testing.expectEqualStrings("(c)\n(a)\n(b)", got.data);
}

// ---------------------------------------------------------------------------
// EmptyTree — a property of the operation, not of the entry
// ---------------------------------------------------------------------------

test "EmptyTree: every op that needs a root still raises it on a rootless document" {
    // The six, plus `remove_root` — which needs a root to remove even
    // though it starts no path at one.
    const actions = [_][]const u8{
        \\{"op":"set_keyword","path":[],"key":"x","value":1}
        ,
        \\{"op":"remove_keyword","path":[],"key":"x"}
        ,
        \\{"op":"replace","path":[0],"value":1}
        ,
        \\{"op":"wrap","path":[],"value":{"$form":"w"},"hole":[0]}
        ,
        \\{"op":"insert_positional","path":[],"value":1}
        ,
        \\{"op":"remove_positional","path":[],"index":0}
        ,
        \\{"op":"remove_root","index":0}
        ,
    };
    for (actions) |json_text| {
        for ([_]Options{ .{}, preserve }) |opts| {
            try testing.expectError(error.EmptyTree, applyEditFromJsonString(
                testing.allocator,
                "; just a note",
                json_text,
                opts,
            ));
        }
    }
}

test "EmptyTree: insert_root is the one op a rootless document accepts" {
    // The empty document is a real SJON document — the glossary says a
    // root list "may be empty" — so the guard is `Edit`'s limit, not the
    // language's, and it lifts for the op that needs no root.
    for ([_][:0]const u8{ "", "\n", "   " }) |source| {
        const got = try applyEditFromJsonString(
            testing.allocator,
            source,
            \\{"op":"insert_root","value":{"$form":"a"}}
        ,
            .{},
        );
        defer got.deinit();
        try testing.expectEqualStrings("(a)\n", got.data);
    }
    // A comments-only document has trivia to keep, and `.full` keeps it —
    // below the new root, where the printer puts tree-trailing comments.
    const kept = try applyEditFromJsonString(
        testing.allocator,
        "; just a note",
        \\{"op":"insert_root","value":{"$form":"a"}}
    ,
        .{},
    );
    defer kept.deinit();
    try testing.expectEqualStrings("(a)\n; just a note\n", kept.data);
}

test "preserve: insert_root into a rootless document writes what fmt would" {
    try expectPreserved(
        "",
        \\{"op":"insert_root","value":{"$form":"a"}}
    ,
        "(a)\n",
    );
    // Above the comment, which is where the printer puts a root relative
    // to the comments that trail a tree.
    try expectPreserved(
        "; just a note",
        \\{"op":"insert_root","value":{"$form":"a"}}
    ,
        "(a)\n; just a note",
    );
}

test "remove_root: the only root leaves a document insert_root can refill" {
    // Emptying a piece and starting it over are both §11 actions, so a
    // host needs no applier of its own for either half.
    try expectPreserved(
        "(only)\n",
        \\{"op":"remove_root","index":0}
    ,
        "\n",
    );
    const got = try applyEditsFromJsonString(
        testing.allocator,
        "(only)\n",
        \\[{"op":"remove_root","index":0},
        \\ {"op":"insert_root","value":{"$form":"fresh"}}]
    ,
        preserve,
    );
    defer got.deinit();
    try testing.expectEqualStrings("(fresh)\n\n", got.data);
}

test "EmptyTree: a rootless document plus a malformed action reports the action" {
    // The observable consequence of moving the guard after the decode,
    // and the better answer: the action is what is wrong.
    try testing.expectError(error.UnknownOp, applyEditFromJsonString(
        testing.allocator,
        "",
        \\{"op":"nonsense","path":[]}
    ,
        .{},
    ));
    try testing.expectError(error.InvalidPath, applyEditFromJsonString(
        testing.allocator,
        "",
        \\{"op":"insert_root","path":[],"value":1}
    ,
        .{},
    ));
}

test "ParseErrors still outranks the decode, and EmptyTree no longer does" {
    // The guard order that survives the move: a recovered tree is refused
    // before the action is read, because no question about it has a
    // correct answer.
    try testing.expectError(error.ParseErrors, applyEditFromJsonString(
        testing.allocator,
        "(scene :w 800\n(camera :fov 60",
        \\{"op":"nonsense"}
    ,
        .{},
    ));
}

test "wrap: a batch whose result would exceed MAX_EDIT_PATH_DEPTH is DepthExceeded, not a deeper tree" {
    // Each op respects every per-op ceiling (template 600 deep, hole 600
    // long) but the second wrap nests the first's result 600 levels
    // further: 1200 > 1024. Before the output check the batch produced a
    // tree no consumer is allowed to see; a few hundred such ops
    // overflowed the host stack in `cloneNode`.
    const a = testing.allocator;
    const template = "[" ** 600 ++ "null" ++ "]" ** 600;
    const hole = "[" ++ "0," ** 599 ++ "0]";
    const json = "{\"op\":\"wrap\",\"path\":[],\"value\":" ++ template ++ ",\"hole\":" ++ hole ++ "}";
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();

    const once = try applyEdits(a, "1", &.{parsed.value}, .{});
    once.deinit();
    try testing.expectError(error.DepthExceeded, applyEdits(a, "1", &.{ parsed.value, parsed.value }, .{}));
}

// ---------------------------------------------------------------------------
// ParseErrors — a document the parser only recovered is not edited
// ---------------------------------------------------------------------------

/// The probe from the ask: two unclosed roots recovered into one nested
/// form, which `set_keyword` used to edit and return without a word.
const unclosed_source =
    \\(scene :w 800
    \\(camera :fov 60
;

test "ParseErrors: a recovered document is refused, not edited" {
    try testing.expectError(error.ParseErrors, applyEditFromJsonString(
        testing.allocator,
        unclosed_source,
        \\{"op":"set_keyword","path":[],"root":0,"key":"h","value":600}
    ,
        .{},
    ));
}

test "ParseErrors: the batched entry refuses the same document" {
    try testing.expectError(error.ParseErrors, applyEditsFromJsonString(
        testing.allocator,
        unclosed_source,
        \\[{"op":"set_keyword","path":[],"root":0,"key":"h","value":600}]
    ,
        .{},
    ));
}

test "ParseErrors: an empty batch does not re-print a recovered document" {
    // The empty-batch path never reaches `applyEditToTree`, so without the
    // check in `applyEdits` this printed the recovery as the document.
    try testing.expectError(error.ParseErrors, applyEdits(
        testing.allocator,
        unclosed_source,
        &.{},
        .{},
    ));
}

test "ParseErrors: applyEditToTree refuses a caller-supplied broken tree" {
    var tree = try Parser.parse(testing.allocator, unclosed_source);
    defer tree.deinit();
    try testing.expect(tree.hasErrors());

    var parsed = try parseAction(testing.allocator,
        \\{"op":"set_keyword","path":[],"root":0,"key":"h","value":600}
    );
    defer parsed.deinit();
    try testing.expectError(error.ParseErrors, applyEditToTree(testing.allocator, &tree, parsed.value));
}

test "ParseErrors: a clean document is still edited" {
    // Negative space for the guard above: `hasErrors` is severity-scoped,
    // so a document carrying only warnings is not caught by it.
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(scene :w 800)",
        \\{"op":"set_keyword","path":[],"key":"h","value":600}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings("(scene :w 800 :h 600)\n", got.data);
}

// ---------------------------------------------------------------------------
// Layout-preserving apply
// ---------------------------------------------------------------------------

const preserve: Options = .{ .layout = .preserve };

/// Apply one JSON action under `.preserve` and assert **law A**: every byte
/// outside the edit's own span survived. Returns the edited text (caller
/// frees) so a test can also say what the span became.
///
/// The check is the whole point of the layout, so it runs on every case
/// rather than in one case of its own: the edit is re-derived here as a
/// `TextEdit`, and the result must be `source` with exactly that span
/// swapped — which also pins `applyEdits` to the same lowering.
fn expectSplice(source: [:0]const u8, action_json: []const u8) ![]u8 {
    const a = testing.allocator;

    var tree = try Parser.parse(a, source);
    defer tree.deinit();
    var parsed = try parseAction(a, action_json);
    defer parsed.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const edit = try textEdit(arena.allocator(), &tree, parsed.value, preserve);

    const got = try applyEditFromJsonString(a, source, action_json, preserve);
    errdefer got.deinit();

    // Law A, stated as the two halves that must be byte-identical.
    try testing.expectEqualStrings(source[0..edit.span_start], got.data[0..edit.span_start]);
    const tail_at = edit.span_start + edit.new_text.len;
    try testing.expectEqualStrings(source[edit.span_end..], got.data[tail_at..]);
    try testing.expectEqualStrings(edit.new_text, got.data[edit.span_start..tail_at]);

    // The re-parse leg: a splice's output is still a document.
    const got_z = try a.dupeZ(u8, got.data);
    defer a.free(got_z);
    var back = try Parser.parse(a, got_z);
    defer back.deinit();
    try testing.expect(!back.hasErrors());

    return got.data;
}

fn expectPreserved(source: [:0]const u8, action_json: []const u8, expected: []const u8) !void {
    const got = try expectSplice(source, action_json);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "preserve: replace touches one literal and nothing else" {
    // The motivating case. Under `.reprint` this document comes back with
    // every line changed and `; width` moved onto the next line.
    try expectPreserved(
        \\(scene
        \\  :w   800   ; width
        \\  :h   600)  ; height
    ,
        \\{"op":"replace","path":["w"],"value":801}
    ,
        \\(scene
        \\  :w   801   ; width
        \\  :h   600)  ; height
    );
}

test "preserve: set_keyword on a present key replaces only the value" {
    try expectPreserved(
        "(scene :w   800 :h 600)",
        \\{"op":"set_keyword","path":[],"key":"w","value":1024}
    ,
        "(scene :w   1024 :h 600)",
    );
}

test "preserve: set_keyword on an absent key inserts before the closing paren" {
    try expectPreserved(
        "(scene :w 800)",
        \\{"op":"set_keyword","path":[],"key":"h","value":600}
    ,
        "(scene :w 800 :h 600)",
    );
}

test "preserve: set_keyword on an absent key keeps a broken form broken" {
    try expectPreserved(
        \\(scene
        \\  :w 800)
    ,
        \\{"op":"set_keyword","path":[],"key":"h","value":600}
    ,
        \\(scene
        \\  :w 800 :h 600)
    );
}

test "preserve: remove_keyword takes the separator that preceded the pair" {
    try expectPreserved(
        "(scene :w 800 :h 600)",
        \\{"op":"remove_keyword","path":[],"key":"h"}
    ,
        "(scene :w 800)",
    );
}

test "preserve: remove_keyword on the first child cuts back to the head" {
    try expectPreserved(
        "(scene :w 800 :h 600)",
        \\{"op":"remove_keyword","path":[],"key":"w"}
    ,
        "(scene :h 600)",
    );
}

test "preserve: a removed pair takes its own leading comment with it" {
    try expectPreserved(
        \\(scene
        \\  :w 800
        \\  ; the height
        \\  :h 600)
    ,
        \\{"op":"remove_keyword","path":[],"key":"h"}
    ,
        \\(scene
        \\  :w 800)
    );
}

test "preserve: remove_positional in a form and in a vector" {
    try expectPreserved(
        "(stack 1 2 3)",
        \\{"op":"remove_positional","path":[],"index":1}
    ,
        "(stack 1 3)",
    );
    try expectPreserved(
        "[1 2 3]",
        \\{"op":"remove_positional","path":[],"index":0}
    ,
        "[2 3]",
    );
}

test "preserve: insert_positional at an index copies that child's separator" {
    try expectPreserved(
        "(stack 1 2 3)",
        \\{"op":"insert_positional","path":[],"index":1,"value":9}
    ,
        "(stack 1 9 2 3)",
    );
    try expectPreserved(
        \\(stack
        \\  1
        \\  2)
    ,
        \\{"op":"insert_positional","path":[],"index":1,"value":9}
    ,
        \\(stack
        \\  1
        \\  9
        \\  2)
    );
}

test "preserve: insert_positional appends behind the last child's separator" {
    try expectPreserved(
        "(stack 1 2)",
        \\{"op":"insert_positional","path":[],"value":3}
    ,
        "(stack 1 2 3)",
    );
    try expectPreserved(
        \\(stack
        \\  1
        \\  2)
    ,
        \\{"op":"insert_positional","path":[],"value":3}
    ,
        \\(stack
        \\  1
        \\  2
        \\  3)
    );
}

test "preserve: an inserted child copies the spacing, not the comment in it" {
    // The gap before `:h` holds `; width`. That comment is about `:w`'s
    // line, not about how the pairs are spaced, so an insert repeats the
    // newline and indent and leaves the sentence where its author put it.
    try expectPreserved(
        \\(scene
        \\  :w 800   ; width
        \\  :h 600)
    ,
        \\{"op":"insert_positional","path":[],"value":3}
    ,
        \\(scene
        \\  :w 800   ; width
        \\  :h 600
        \\  3)
    );
}

test "preserve: a removed child takes the whole gap, comment and all" {
    // The mirror of the case above: here the comment leads the pair being
    // removed, so it leaves with it — which is also what the re-print does.
    try expectPreserved(
        \\(scene
        \\  :w 800
        \\  ; about the height
        \\  :h 600)
    ,
        \\{"op":"remove_keyword","path":[],"key":"h"}
    ,
        \\(scene
        \\  :w 800)
    );
}

test "preserve: appending into a childless form and a childless vector" {
    // A form has its head to sit after; a vector's brackets touch.
    try expectPreserved(
        "(stack)",
        \\{"op":"insert_positional","path":[],"value":1}
    ,
        "(stack 1)",
    );
    try expectPreserved(
        "[]",
        \\{"op":"insert_positional","path":[],"value":1}
    ,
        "[1]",
    );
}

test "preserve: insert_positional counts positionals, not children" {
    try expectPreserved(
        "(stack :k 1 7 8)",
        \\{"op":"insert_positional","path":[],"index":0,"value":9}
    ,
        "(stack :k 1 9 7 8)",
    );
}

test "preserve: wrap keeps the target's bytes verbatim" {
    try expectPreserved(
        "(a :x (* 2   (sin t)))",
        \\{"op":"wrap","path":["x"],"value":{"$expr":["+",null,0.1]},"hole":[0]}
    ,
        "(a :x (+ (* 2   (sin t)) 0.1))",
    );
}

test "preserve: wrap keeps a comment inside the target, and does not duplicate one before it" {
    try expectPreserved(
        \\(a
        \\  ; a leading comment
        \\  :x (* 2 ; inner
        \\         (sin t)))
    ,
        \\{"op":"wrap","path":["x"],"value":{"$expr":["+",null,0.1]},"hole":[0]}
    ,
        \\(a
        \\  ; a leading comment
        \\  :x (+ (* 2 ; inner
        \\         (sin t)) 0.1))
    );
}

test "preserve: a multi-line value is indented to the column it lands at" {
    const got = try expectSplice(
        \\(scene
        \\  :canvas 0)
    ,
        \\{"op":"set_keyword","path":[],"key":"canvas",
        \\ "value":{"$form":"canvas","name":"a name long enough to force the wrap",
        \\          "w":800,"h":600}}
    );
    defer testing.allocator.free(got);
    // The fragment broke, and every line after the first sits under the
    // column the value started at rather than against the left margin.
    var lines = std.mem.splitScalar(u8, got, '\n');
    _ = lines.next();
    const second = lines.next() orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.startsWith(u8, second, "  :canvas (canvas"));
    const third = lines.next() orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.startsWith(u8, third, "            "));
}

test "preserve: descending a path reaches the inner form's own bytes" {
    try expectPreserved(
        \\(scene
        \\  :canvas (canvas :name   "main"))
    ,
        \\{"op":"set_keyword","path":["canvas"],"key":"name","value":"alt"}
    ,
        \\(scene
        \\  :canvas (canvas :name   "alt"))
    );
}

test "preserve: a batch equals threading the actions one at a time" {
    const a = testing.allocator;
    const source: [:0]const u8 =
        \\(scene
        \\  :w   800   ; width
        \\  :h   600)
    ;
    const batch =
        \\[{"op":"set_keyword","path":[],"key":"w","value":1024},
        \\ {"op":"set_keyword","path":[],"key":"h","value":768},
        \\ {"op":"set_keyword","path":[],"key":"bg","value":"black"}]
    ;
    const batched = try applyEditsFromJsonString(a, source, batch, preserve);
    defer batched.deinit();

    var threaded = try a.dupeZ(u8, source);
    defer a.free(threaded);
    for ([_][]const u8{
        \\{"op":"set_keyword","path":[],"key":"w","value":1024}
        ,
        \\{"op":"set_keyword","path":[],"key":"h","value":768}
        ,
        \\{"op":"set_keyword","path":[],"key":"bg","value":"black"}
        ,
    }) |action_json| {
        const step = try applyEditFromJsonString(a, threaded, action_json, preserve);
        defer step.deinit();
        const next = try a.dupeZ(u8, step.data);
        a.free(threaded);
        threaded = next;
    }
    try testing.expectEqualStrings(threaded, batched.data);
    try testing.expectEqualStrings(
        \\(scene
        \\  :w   1024   ; width
        \\  :h   768 :bg "black")
    , batched.data);
}

test "preserve: an empty batch returns the source byte-for-byte" {
    // The re-print fold's empty batch is a canonical/full no-op, which
    // rewrites the document; there is nothing to normalise to here.
    const source: [:0]const u8 = "(scene   :w   800)  ; kept";
    const got = try applyEdits(testing.allocator, source, &.{}, preserve);
    defer got.deinit();
    try testing.expectEqualStrings(source, got.data);
}

test "preserve: a document with parse errors is refused, as under reprint" {
    try testing.expectError(error.ParseErrors, applyEditFromJsonString(
        testing.allocator,
        unclosed_source,
        \\{"op":"set_keyword","path":[],"root":0,"key":"h","value":600}
    ,
        preserve,
    ));
}

test "preserve: the two layouts agree on what an action addresses" {
    // Same refusals, different output: the paths, the root rule and the
    // slot scans are shared, so only the bytes may differ.
    const a = testing.allocator;
    const cases = [_][]const u8{
        \\{"op":"set_keyword","path":["nope"],"key":"x","value":1}
        ,
        \\{"op":"remove_keyword","path":[],"key":"nope"}
        ,
        \\{"op":"remove_positional","path":[],"index":9}
        ,
        \\{"op":"replace","path":[0,1],"value":1}
        ,
        \\{"op":"set_keyword","path":[0],"key":"x","value":1}
        ,
    };
    for (cases) |action_json| {
        const reprinted = applyEditFromJsonString(a, "(scene :w 800 3)", action_json, .{});
        const spliced = applyEditFromJsonString(a, "(scene :w 800 3)", action_json, preserve);
        try testing.expectError(
            if (reprinted) |ok| blk: {
                ok.deinit();
                break :blk error.TestExpectedError;
            } else |e| e,
            spliced,
        );
    }
}

test "preserve: textEdit refuses a synthesized tree, which has no coordinates" {
    const a = testing.allocator;
    var parsed_value = try parseAction(a, "{\"$form\":\"scene\",\"$children\":[]}");
    defer parsed_value.deinit();
    var tree = try Json.fromJson(a, parsed_value.value, .{});
    defer tree.deinit();

    var action = try parseAction(a,
        \\{"op":"set_keyword","path":[],"key":"w","value":800}
    );
    defer action.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try testing.expectError(
        error.NoSourceSpan,
        textEdit(arena.allocator(), &tree, action.value, preserve),
    );
}

test "preserve: textEdit hands back the edit without applying it" {
    const a = testing.allocator;
    var tree = try Parser.parse(a, "(scene :w 800)");
    defer tree.deinit();
    var action = try parseAction(a,
        \\{"op":"replace","path":["w"],"value":801}
    );
    defer action.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const edit = try textEdit(arena.allocator(), &tree, action.value, preserve);
    try testing.expectEqual(@as(u32, 10), edit.span_start);
    try testing.expectEqual(@as(u32, 13), edit.span_end);
    try testing.expectEqualStrings("801", edit.new_text);
}

test "reprint stays the default, and stays what it was" {
    // The wasm export and its two consumers read this default; the whole
    // point of `Layout` is that they do not move.
    try testing.expectEqual(Layout.reprint, (Options{}).layout);
    const got = try applyEditFromJsonString(
        testing.allocator,
        "(scene\n  :w   800   ; width\n  :h   600)",
        \\{"op":"replace","path":["w"],"value":801}
    ,
        .{},
    );
    defer got.deinit();
    try testing.expectEqualStrings(
        \\(scene
        \\  :w 801
        \\  ; width
        \\  :h 600)
        \\
    , got.data);
}

// -- Span to node ------------------------------------------------------------

test "nodeAtSpan: an exact span finds its node, a one-byte miss finds none" {
    const src = "(scene :bpm 130)";
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();

    const hit = nodeAtSpan(&tree, .{ .start = 12, .end = 15 }).?;
    try testing.expectEqual(Ast.Tag.number_i64, tree.tagOf(hit));

    try testing.expectEqual(@as(?Ast.NodeIndex, null), nodeAtSpan(&tree, .{ .start = 12, .end = 16 }));
    try testing.expectEqual(@as(?Ast.NodeIndex, null), nodeAtSpan(&tree, .{ .start = 11, .end = 15 }));
}

test "nodeContaining: innermost wins over the form that starts at the same byte" {
    const src = "(param :name heat :value (* 0.4 (sin (* time 0.2))))";
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();

    // `0.4` sits inside three forms and one kvpair; the narrowest is the
    // number. Depth would not order these — `(*` and its head start one
    // byte apart — but width does.
    const at_number = nodeContaining(&tree, @intCast(std.mem.indexOf(u8, src, "0.4").?)).?;
    try testing.expectEqual(Ast.Tag.number, tree.tagOf(at_number));
    try testing.expectEqualStrings("0.4", src[tree.spanOf(at_number).start..tree.spanOf(at_number).end]);

    // The `(` of the innermost `(* time 0.2)` is in every enclosing form's
    // span too, and answers that innermost one.
    const inner_open: u32 = @intCast(std.mem.lastIndexOf(u8, src, "(* time").?);
    const at_open = nodeContaining(&tree, inner_open).?;
    try testing.expectEqual(Ast.Tag.form, tree.tagOf(at_open));
    try testing.expectEqual(inner_open, tree.spanOf(at_open).start);
    try testing.expectEqualStrings("*", tree.formHeader(at_open).head);

    // A kvpair's key is under the pair and under nothing narrower.
    const at_key = nodeContaining(&tree, @intCast(std.mem.indexOf(u8, src, ":name").?)).?;
    try testing.expectEqual(Ast.Tag.kvpair, tree.tagOf(at_key));

    // Spans are half-open, so the byte after the last root is outside it,
    // and so is anything past the document.
    try testing.expectEqual(@as(?Ast.NodeIndex, null), nodeContaining(&tree, @intCast(src.len)));
    try testing.expectEqual(@as(?Ast.NodeIndex, null), nodeContaining(&tree, @intCast(src.len + 100)));
}

test "nodeContaining: whitespace between roots is inside no node" {
    const src = "(a 1)\n\n(b 2)";
    var tree = try Parser.parse(testing.allocator, src);
    defer tree.deinit();

    try testing.expectEqual(@as(?Ast.NodeIndex, null), nodeContaining(&tree, 6));
    const second = nodeContaining(&tree, 8).?;
    try testing.expectEqualStrings("b", tree.formHeader(second).head);
}

// -- The node table ----------------------------------------------------------

/// Ask 25's fixture: four roots, a nested expression whose literals an
/// editor decorates, and one line past ASCII so a byte offset cannot be
/// mistaken for a UTF-16 one.
const spike_fixture =
    \\; The spike's fixture: one declaration over time, one plain literal,
    \\; and a title in more than ASCII.
    \\(use-plugin "spike")
    \\
    \\(param :name heat :value (* 0.4 (sin (* time 0.2))))
    \\(param :name pace :value 0.25)
    \\(title :text "olá — ☀️ 日本")
;

/// The same fixture with the title's closing quote gone: the revision the
/// parity parser throws on and the wasm host recovers.
const spike_fixture_unterminated =
    \\; The spike's fixture: one declaration over time, one plain literal,
    \\; and a title in more than ASCII.
    \\(use-plugin "spike")
    \\
    \\(param :name heat :value (* 0.4 (sin (* time 0.2))))
    \\(param :name pace :value 0.25)
    \\(title :text "olá — ☀️ 日本)
;

/// Assert every row of `src`'s table addresses exactly the node it
/// describes: take the row's address, resolve it the way an edit would,
/// and require the same `NodeIndex` back. The property the JSON forest
/// cannot have, and the one the fuzz harness then asserts on every input.
fn expectEveryRowResolves(src: [:0]const u8) !void {
    const gpa = testing.allocator;
    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();
    const table = try nodeTable(gpa, &tree);
    defer table.deinit();

    for (table.rows, 0..) |row, i| {
        const address = try table.addressOfRow(gpa, @intCast(i));
        defer address.deinit();
        try testing.expectEqual(row.root, address.root);

        const path = try address.toJsonPath(gpa);
        defer gpa.free(path);
        try testing.expectEqual(row.node, try resolvePath(&tree, tree.root[row.root], path));
    }
}

test "nodeTable: a root row has no parent and no step" {
    const gpa = testing.allocator;
    var tree = try Parser.parse(gpa, spike_fixture);
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 4), tree.root.len);

    const table = try nodeTable(gpa, &tree);
    defer table.deinit();

    const first = table.rows[0];
    try testing.expectEqual(@as(?u32, null), first.parent);
    try testing.expectEqual(@as(?Step, null), first.seg);
    try testing.expectEqual(@as(u32, 0), first.root);
    try testing.expectEqualStrings("use-plugin", tree.formHeader(first.node).head);
    // The head span is the channel a form row carries and a leaf does not.
    try testing.expectEqualStrings(
        "use-plugin",
        spike_fixture[first.head_span.?.start..first.head_span.?.end],
    );

    // Pre-order over the forest: roots come out in source order, and every
    // non-root row points back at a row already emitted.
    var seen_roots: u32 = 0;
    for (table.rows, 0..) |row, i| {
        if (row.parent) |p| {
            try testing.expect(p < i);
            try testing.expectEqual(table.rows[p].root, row.root);
        } else {
            try testing.expectEqual(seen_roots, row.root);
            seen_roots += 1;
        }
    }
    try testing.expectEqual(@as(u32, 4), seen_roots);

    // The fixture is the ask's, byte for byte: transcript 7 reads `0.4` at
    // [153, 156) and the title's string at [222, 246), in bytes. Pinned
    // here so a stray edit to the literal above is caught before the web
    // host's own byte assertions go red for the wrong reason.
    const at_number = nodeContaining(&tree, 154).?;
    try testing.expectEqual(Ast.Span{ .start = 153, .end = 156 }, tree.spanOf(at_number));
    const at_title = nodeContaining(&tree, 230).?;
    try testing.expectEqual(Ast.Span{ .start = 222, .end = 246 }, tree.spanOf(at_title));
}

test "nodeTable: a kvpair contributes no row, and its value carries the key span" {
    const gpa = testing.allocator;
    const src = "(param :name heat)";
    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();
    const table = try nodeTable(gpa, &tree);
    defer table.deinit();

    // Two rows, not three: the form and the symbol. The pair is addressed
    // through, never at.
    try testing.expectEqual(@as(usize, 2), table.rows.len);
    for (table.rows) |row| try testing.expect(row.tag != .kvpair);

    const value = table.rows[1];
    try testing.expectEqual(Ast.Tag.symbol, value.tag);
    try testing.expectEqualStrings("name", value.seg.?.key);
    try testing.expectEqualStrings(":name", src[value.key_span.?.start..value.key_span.?.end]);
    try testing.expectEqualStrings("heat", src[value.span.start..value.span.end]);
    // The form itself was never a pair's value, so it has no key span.
    try testing.expectEqual(@as(?Ast.Span, null), table.rows[0].key_span);
}

test "nodeTable: every row's reconstructed path resolves to that row" {
    try expectEveryRowResolves(spike_fixture);
    try expectEveryRowResolves("[1 [2 3] [[4]]]");
    try expectEveryRowResolves("(f :a 1 x :b 2 y [10 :k 20])");
    try expectEveryRowResolves("(a (b (c (d :e (f 1)))))");
    try expectEveryRowResolves("()");
    try expectEveryRowResolves("");
}

test "nodeTable: an integer step counts positionals with kvpairs skipped" {
    const gpa = testing.allocator;
    const src = "(f :a 1 x :b 2 y)";
    var tree = try Parser.parse(gpa, src);
    defer tree.deinit();
    const table = try nodeTable(gpa, &tree);
    defer table.deinit();

    var steps: [2]u32 = undefined;
    var n: usize = 0;
    for (table.rows) |row| {
        if (row.tag != .symbol) continue;
        steps[n] = row.seg.?.index;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u32, 0), steps[0]);
    try testing.expectEqual(@as(u32, 1), steps[1]);

    // Asserted against the resolver rather than the expectation above, so
    // the table and `findPositionalSlot` cannot drift apart.
    try expectEveryRowResolves(src);
}

test "nodeTable: a document that does not parse still yields a table" {
    const gpa = testing.allocator;
    // The fixture's title, minus its closing quote: the revision a person
    // is in the middle of typing, and the one the parity parser throws on.
    var tree = try Parser.parse(gpa, spike_fixture_unterminated);
    defer tree.deinit();
    try testing.expect(tree.hasErrors());

    const table = try nodeTable(gpa, &tree);
    defer table.deinit();
    try testing.expect(table.rows.len > 0);

    // `applyEditToTree` refuses the very same tree; the read does not.
    try testing.expectError(error.ParseErrors, applyEditToTree(gpa, &tree, .{ .null = {} }));
}

test "addressOf: the node at a span, addressed, resolves to the same node" {
    const gpa = testing.allocator;
    var tree = try Parser.parse(gpa, spike_fixture);
    defer tree.deinit();

    // The round trip agent-04 needs: a diagnostic hands over a span, the
    // span names a node, the node names an address, and the address is
    // what an edit takes. The `0.4` in `(param :name heat :value (* 0.4 …))`
    // is `{root: 1, path: ["value", 0]}`.
    const node = nodeAtSpan(&tree, .{ .start = 153, .end = 156 }).?;
    const address = (try addressOf(gpa, &tree, node)).?;
    defer address.deinit();

    try testing.expectEqual(@as(u32, 1), address.root);
    try testing.expectEqual(@as(usize, 2), address.steps.len);
    try testing.expectEqualStrings("value", address.steps[0].key);
    try testing.expectEqual(@as(u32, 0), address.steps[1].index);

    const path = try address.toJsonPath(gpa);
    defer gpa.free(path);
    try testing.expectEqual(node, try resolvePath(&tree, tree.root[address.root], path));

    // And the address is an action's, verbatim: hand it back as one.
    var edited = try applyEditFromJsonString(
        gpa,
        spike_fixture,
        \\{"op":"replace","root":1,"path":["value",0],"value":0.5}
    ,
        .{ .layout = .preserve },
    );
    defer edited.deinit();
    try testing.expect(std.mem.indexOf(u8, edited.data, "(* 0.5 (sin") != null);
}

test "addressOf: each root of the fixture reports its own index" {
    const gpa = testing.allocator;
    var tree = try Parser.parse(gpa, spike_fixture);
    defer tree.deinit();

    // A `root` that defaults silently is the failure `applyEditToTree`
    // already refuses to have (`targetRoot`'s `error.MultipleRoots`), so
    // every address over a four-root document has to name its own.
    for (tree.root, 0..) |root_node, i| {
        const address = (try addressOf(gpa, &tree, root_node)).?;
        defer address.deinit();
        try testing.expectEqual(@as(u32, @intCast(i)), address.root);
        try testing.expectEqual(@as(usize, 0), address.steps.len);
    }

    // The `0.25` of the *third* root, `(param :name pace :value 0.25)`.
    const pace = std.mem.indexOf(u8, spike_fixture, "0.25").?;
    const node = nodeContaining(&tree, @intCast(pace)).?;
    const address = (try addressOf(gpa, &tree, node)).?;
    defer address.deinit();
    try testing.expectEqual(@as(u32, 2), address.root);
    try testing.expectEqualStrings("value", address.steps[0].key);
    try testing.expectEqual(@as(usize, 1), address.steps.len);
}

test "addressOf: a kvpair has no address, and neither does a foreign node" {
    const gpa = testing.allocator;
    var tree = try Parser.parse(gpa, "(param :name heat)");
    defer tree.deinit();

    // §11.2 addresses a pair's value, never the pair, so the pair that
    // `nodeContaining` finds under `:name` is the one node with no address.
    const pair = nodeContaining(&tree, 7).?;
    try testing.expectEqual(Ast.Tag.kvpair, tree.tagOf(pair));
    try testing.expectEqual(@as(?Address, null), try addressOf(gpa, &tree, pair));

    const foreign = Ast.NodeIndex.from(@intCast(tree.nodes.len + 10));
    try testing.expectEqual(@as(?Address, null), try addressOf(gpa, &tree, foreign));
}
