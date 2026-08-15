//! SJON Parser.
//!
//! Iterative descent over a `Lexer` token stream into an `Ast.Tree`. No
//! recursion — nesting is handled with an explicit `frames` stack so a
//! deeply-nested input cannot blow the system stack.
//!
//! Invariants:
//!   * **Always returns a `Tree`** (possibly with diagnostics). The only
//!     error path is `error.OutOfMemory` from the arena allocator. Lexer
//!     `.invalid` tokens become diagnostics; structural recovery skips
//!     forward without aborting.
//!   * **Bounded nesting.** `MAX_PARSE_DEPTH = 1024` frames. On overflow the
//!     parser emits `"nesting too deep"` and stops the parse cleanly
//!     (`tree.hasErrors() == true`).
//!   * **Iterative.** No `parse*` helper recurses. The `frames` stack is
//!     the only structural state.
//!   * **Single-pass.** `Lexer.next` is called once per token; the parser
//!     never rewinds.
//!   * **Arena ownership.** Every allocation lives in `tree.arena`;
//!     `tree.deinit()` releases all node slices, identifier dupes, and
//!     diagnostics in one operation.
//!
//! Form children preserve **source order** as a list of `FormChild` entries.
//! Greedy keyword pairing rule (forms only): when the parser sees `:kw`
//! inside a form, it tracks a `pending_key` on that frame. The next
//! non-keyword value is paired as `KeywordPair{key, value}`. If another
//! `:kw` arrives first, or the form closes, the earlier `:kw` is committed
//! as a **positional keyword value** (a "flag"). This matches the masagin
//! convention `(camera :ortho :zoom 2)` → `[positional :ortho, keyword
//! zoom=2]`. Inside a vector, `:kw` is just a positional keyword value —
//! vectors carry no kvpair structure (no consumer reads one) and the
//! pairing machinery would only leak the keyword's leading comments and
//! drift element-index paths.
//!
//! Diagnostics are collected, never raised. `Tree.hasErrors()` reports.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Lexer = @import("Lexer.zig");
const Ast = @import("Ast.zig");
const Date = @import("Date.zig");
const Time = @import("Time.zig");

const Token = Lexer.Token;
const Tag = Token.Tag;
const Span = Ast.Span;

/// Maximum parse-frame depth. SJON has no need for deep nesting; this is a
/// belt-and-braces guard against malicious input. Public so
/// `Binary.zig`'s comptime assert can enforce
/// `Binary.MAX_TREE_DEPTH >= Parser.MAX_PARSE_DEPTH`.
pub const MAX_PARSE_DEPTH: u32 = 1024;

/// One open container frame. Top-level parsing also runs in a frame
/// (`.root`) so the attach/close logic is uniform.
///
/// Children accumulate as `ChildEntry` (positional `NodeIndex` or deferred
/// keyword pair). The frame closes by materialising the entries into a
/// `Tag.form` / `Tag.vector` node via `Ast.TreeBuilder`.
///
/// `parent_step` + `parent_via_kvpair` together identify how this
/// frame sits in its parent — the path-attribution backbone for
/// diagnostic emission. See `computeChildStep`. Walking the frame
/// stack reconstructs the validator-shaped semantic path.
const Frame = struct {
    kind: Kind,
    children: std.ArrayList(ChildEntry),
    pending: ?PendingKey = null,
    /// Comments accumulated since the last attached child (or frame open).
    /// Drained to the next attached child's `leading_comments`, or — on
    /// frame close — to the form's `trailing_comments`.
    pending_comments: std.ArrayList(Ast.Comment) = .empty,
    /// Path step that names this frame in its parent. For kvpair-value
    /// frames this is the key; for positional frames the ordinal as a
    /// decimal string; for root and top-level frames the empty string.
    parent_step: []const u8 = "",
    /// True when this frame is the value of a kvpair in its parent.
    /// In the path walk both `parent_step` (the key) and the form's
    /// head are emitted; for positional frames only the form head (or
    /// ordinal fallback) is emitted.
    parent_via_kvpair: bool = false,

    const Kind = union(enum) {
        root,
        form: struct { head: []const u8, namespace: ?[]const u8, head_span: Span, open_span: Span },
        vector: struct { open_span: Span },
    };

    const PendingKey = struct {
        key: []const u8,
        span: Span,
    };
};

const ChildEntry = union(enum) {
    positional: Ast.NodeIndex,
    keyword: KeywordEntry,
};

const KeywordEntry = struct {
    key: []const u8,
    key_span: Span,
    value: Ast.NodeIndex,
    leading_comments: []const Ast.Comment,
};

/// Bundle of per-parse state threaded through the parse-loop handlers.
/// `gpa` backs the working ArrayLists owned by `parse` (frames stack,
/// diagnostics, per-frame children/comments); `a` is the tree's arena
/// allocator. Helpers borrow `*ParseState` for the duration of one parse
/// — it has no lifecycle of its own.
const ParseState = struct {
    gpa: Allocator,
    a: Allocator,
    source: [:0]const u8,
    b: *Ast.TreeBuilder,
    frames: *std.ArrayList(Frame),
    diagnostics: *std.ArrayList(Ast.Diagnostic),
    lex: *Lexer,
};

/// Per-token handler outcome. `.stop` short-circuits the parse loop
/// (used for `.eof` and `nesting too deep` overflow); `.keep_going`
/// continues with the next token.
const LoopAction = enum { keep_going, stop };

/// Materialized payload of the root frame after the parse loop ends.
/// `root_indices` is the final `Tree.root` slice; `tree_trailing_range`
/// covers comments that appear after the last top-level form.
const RootFreeze = struct {
    root_indices: []Ast.NodeIndex,
    tree_trailing_range: Ast.CommentRange,
};

/// Parse SJON source into a `Tree` (the SoA representation). Always
/// returns a tree (possibly with diagnostics); only fails on `OutOfMemory`.
///
/// Drives four phases:
///   1. `runParseLoop`        — token-by-token state machine
///   2. `closeUnclosedFrames` — emit "unclosed delimiter" for any frame
///                              the loop left open at EOF
///   3. `finalizeRoot`        — pop the root frame, build `Tree.root`,
///                              emit kvpair-at-root diagnostics
///   4. `freezeTree`          — hand the arena + builder slices to a
///                              fresh `Tree`.
pub fn parse(gpa: Allocator, source: [:0]const u8) Allocator.Error!Ast.Tree {
    std.debug.assert(source.len == 0 or source[source.len] == 0);

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var b: Ast.TreeBuilder = .{ .a = a };
    var diagnostics: std.ArrayList(Ast.Diagnostic) = .empty;

    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(gpa);
    try frames.append(gpa, .{ .kind = .root, .children = .empty });
    errdefer for (frames.items) |*f| {
        f.children.deinit(gpa);
        f.pending_comments.deinit(gpa);
    };

    var lex = Lexer.init(source);

    var st: ParseState = .{
        .gpa = gpa,
        .a = a,
        .source = source,
        .b = &b,
        .frames = &frames,
        .diagnostics = &diagnostics,
        .lex = &lex,
    };

    try runParseLoop(&st);
    try closeUnclosedFrames(&st);
    const freeze = try finalizeRoot(&st);
    return try freezeTree(&st, arena, freeze);
}

/// Token-by-token state machine. Dispatches each token to a small
/// handler; the only flow-control hidden inside is `.stop`, which
/// terminates on EOF or `nesting too deep`.
fn runParseLoop(st: *ParseState) Allocator.Error!void {
    // The root frame is pushed by `parse()` before the loop runs and is
    // only popped by `finalizeRoot()` after the loop ends. Every handler
    // below indexes `frames.items[len - 1]`, so the invariant is
    // load-bearing.
    std.debug.assert(st.frames.items.len >= 1);
    while (true) {
        const tok = st.lex.next();
        const action: LoopAction = switch (tok.tag) {
            .comment_line, .comment_block => try handleCommentToken(st, tok),
            .eof => .stop,
            .lparen => try handleLParen(st, tok),
            .lbracket => try handleLBracket(st, tok),
            .rparen, .rbracket => try handleCloseDelim(st, tok),
            .keyword => try handleKeywordToken(st, tok),
            .number, .date, .time, .string, .raw_string, .true_lit, .false_lit, .nil_lit, .symbol => try handleValueToken(st, tok),
            .invalid => try handleInvalidToken(st, tok),
        };
        if (action == .stop) break;
    }
}

fn handleCommentToken(st: *ParseState, tok: Token) Allocator.Error!LoopAction {
    const top = &st.frames.items[st.frames.items.len - 1];
    try appendPendingComment(st, top, tok);
    return .keep_going;
}

/// Dup a comment token's text into the arena and stage it on `top`'s
/// `pending_comments`, whence it becomes leading trivia on the next
/// attached node (or trailing on the frame at its close). Shared by the
/// top-level comment handler and `nextSignificant` so a comment routed
/// from either path is captured identically.
fn appendPendingComment(st: *ParseState, top: *Frame, tok: Token) Allocator.Error!void {
    try top.pending_comments.append(st.gpa, .{
        .span = .{ .start = tok.start, .end = tok.end },
        .text = try st.a.dupe(u8, st.source[tok.start..tok.end]),
        .kind = if (tok.tag == .comment_line) .line else .block,
    });
}

fn handleLParen(st: *ParseState, tok: Token) Allocator.Error!LoopAction {
    if (st.frames.items.len >= MAX_PARSE_DEPTH) {
        try emit(st.diagnostics, st.a, st.frames.items, tok, "nesting too deep", true);
        return .stop;
    }
    const head_tok = try nextSignificant(st);
    switch (head_tok.tag) {
        .symbol, .true_lit, .false_lit, .nil_lit => {
            const head_text = st.source[head_tok.start..head_tok.end];
            const split = splitNamespace(head_text);
            const ns = if (split.namespace) |n| try st.a.dupe(u8, n) else null;
            const head_dup = try st.a.dupe(u8, split.name);
            const cs = try computeChildStep(st.a, &st.frames.items[st.frames.items.len - 1]);
            try st.frames.append(st.gpa, .{
                .kind = .{ .form = .{
                    .head = head_dup,
                    .namespace = ns,
                    .head_span = .{ .start = head_tok.start, .end = head_tok.end },
                    .open_span = .{ .start = tok.start, .end = tok.end },
                } },
                .children = .empty,
                .parent_step = cs.step,
                .parent_via_kvpair = cs.via_kvpair,
            });
        },
        .rparen => {
            try emit(st.diagnostics, st.a, st.frames.items, head_tok, "empty form: expected head symbol after `(`", true);
            const head_si = try st.b.addString("");
            const form_idx = try st.b.addForm(
                head_si,
                null,
                .{ .start = head_tok.start, .end = head_tok.start },
                &.{},
                .{ .start = tok.start, .end = head_tok.end },
            );
            try attach(st.frames, st.b, st.gpa, st.a, form_idx);
        },
        else => {
            try emit(st.diagnostics, st.a, st.frames.items, head_tok, "expected head symbol after `(`", true);
            const cs = try computeChildStep(st.a, &st.frames.items[st.frames.items.len - 1]);
            try st.frames.append(st.gpa, .{
                .kind = .{ .form = .{
                    .head = "",
                    .namespace = null,
                    .head_span = .{ .start = head_tok.start, .end = head_tok.start },
                    .open_span = .{ .start = tok.start, .end = tok.end },
                } },
                .children = .empty,
                .parent_step = cs.step,
                .parent_via_kvpair = cs.via_kvpair,
            });
            if (try makeLeaf(st.b, st.source, head_tok, st.diagnostics, st.frames.items, st.a)) |leaf| {
                try attach(st.frames, st.b, st.gpa, st.a, leaf);
            }
        },
    }
    return .keep_going;
}

fn handleLBracket(st: *ParseState, tok: Token) Allocator.Error!LoopAction {
    if (st.frames.items.len >= MAX_PARSE_DEPTH) {
        try emit(st.diagnostics, st.a, st.frames.items, tok, "nesting too deep", true);
        return .stop;
    }
    const cs = try computeChildStep(st.a, &st.frames.items[st.frames.items.len - 1]);
    try st.frames.append(st.gpa, .{
        .kind = .{ .vector = .{ .open_span = .{ .start = tok.start, .end = tok.end } } },
        .children = .empty,
        .parent_step = cs.step,
        .parent_via_kvpair = cs.via_kvpair,
    });
    return .keep_going;
}

fn handleCloseDelim(st: *ParseState, tok: Token) Allocator.Error!LoopAction {
    if (st.frames.items.len <= 1) {
        try emit(st.diagnostics, st.a, st.frames.items, tok, "unexpected close delimiter at top level", false);
        return .keep_going;
    }
    // Snapshot path *before* the pop — the unclosed/mismatched frame
    // must still be on the stack to compute the right path.
    const top_kind = st.frames.items[st.frames.items.len - 1].kind;
    const expected_close: Tag = switch (top_kind) {
        .form => .rparen,
        .vector => .rbracket,
        .root => unreachable,
    };
    if (tok.tag != expected_close) {
        try emit(st.diagnostics, st.a, st.frames.items, tok, "mismatched close delimiter", false);
    }
    var top = st.frames.pop().?;
    defer {
        top.children.deinit(st.gpa);
        top.pending_comments.deinit(st.gpa);
    }

    try flushPendingFlag(&top, st.b, st.a, st.gpa);
    const trailing = try drainPendingComments(&top.pending_comments, st.a, st.gpa);
    const node_idx = try finalizeFrame(st.b, st.a, &top, tok.end, trailing);
    try attach(st.frames, st.b, st.gpa, st.a, node_idx);
    return .keep_going;
}

fn handleKeywordToken(st: *ParseState, tok: Token) Allocator.Error!LoopAction {
    const top = &st.frames.items[st.frames.items.len - 1];
    try flushPendingFlag(top, st.b, st.a, st.gpa);

    switch (top.kind) {
        .vector => {
            const leaf = try makeLeaf(st.b, st.source, tok, st.diagnostics, st.frames.items, st.a) orelse return .keep_going;
            try attach(st.frames, st.b, st.gpa, st.a, leaf);
        },
        .form, .root => {
            const key_text = st.source[tok.start + 1 .. tok.end];
            const key_dup = try st.a.dupe(u8, key_text);
            top.pending = .{
                .key = key_dup,
                .span = .{ .start = tok.start, .end = tok.end },
            };
        },
    }
    return .keep_going;
}

fn handleValueToken(st: *ParseState, tok: Token) Allocator.Error!LoopAction {
    const leaf = try makeLeaf(st.b, st.source, tok, st.diagnostics, st.frames.items, st.a) orelse return .keep_going;
    try attach(st.frames, st.b, st.gpa, st.a, leaf);
    return .keep_going;
}

fn handleInvalidToken(st: *ParseState, tok: Token) Allocator.Error!LoopAction {
    try emit(st.diagnostics, st.a, st.frames.items, tok, "invalid token", true);
    return .keep_going;
}

/// Drain any frames the parse loop left on the stack (forms or vectors
/// without their matching close delim, or every frame on `nesting too
/// deep`). Emits one `unclosed delimiter at end of input` per frame
/// *before* popping so `buildPath` sees the still-open frame.
fn closeUnclosedFrames(st: *ParseState) Allocator.Error!void {
    std.debug.assert(st.frames.items.len >= 1);
    while (st.frames.items.len > 1) {
        try emit(st.diagnostics, st.a, st.frames.items, .{
            .tag = .eof,
            .start = @intCast(st.source.len),
            .end = @intCast(st.source.len),
        }, "unclosed delimiter at end of input", false);
        var top = st.frames.pop().?;
        defer {
            top.children.deinit(st.gpa);
            top.pending_comments.deinit(st.gpa);
        }
        try flushPendingFlag(&top, st.b, st.a, st.gpa);
        const trailing = try drainPendingComments(&top.pending_comments, st.a, st.gpa);
        const node_idx = try finalizeFrame(st.b, st.a, &top, @intCast(st.source.len), trailing);
        try attach(st.frames, st.b, st.gpa, st.a, node_idx);
    }
    std.debug.assert(st.frames.items.len == 1);
}

/// Pop the root frame and materialize `Tree.root`. Any keyword-pair
/// children become a `(keyword, value)` pair in the root slice with a
/// `keyword pair at top level` diagnostic — kvpairs only make sense
/// inside a form.
fn finalizeRoot(st: *ParseState) Allocator.Error!RootFreeze {
    std.debug.assert(st.frames.items.len == 1);
    var root_frame = st.frames.pop().?;
    defer {
        root_frame.children.deinit(st.gpa);
        root_frame.pending_comments.deinit(st.gpa);
    }
    try flushPendingFlag(&root_frame, st.b, st.a, st.gpa);
    const tree_trailing_comments = try drainPendingComments(&root_frame.pending_comments, st.a, st.gpa);

    var root_capacity: usize = 0;
    for (root_frame.children.items) |c| switch (c) {
        .positional => root_capacity += 1,
        .keyword => root_capacity += 2,
    };
    var root_indices = try std.ArrayList(Ast.NodeIndex).initCapacity(st.a, root_capacity);
    for (root_frame.children.items) |child| switch (child) {
        .positional => |n| root_indices.appendAssumeCapacity(n),
        .keyword => |kp| {
            // The frame stack is empty here — `buildPath` returns `[]`
            // for the kvpair-at-root diagnostic by construction.
            try emit(st.diagnostics, st.a, st.frames.items, .{
                .tag = .keyword,
                .start = kp.key_span.start,
                .end = kp.key_span.end,
            }, "keyword pair at top level (expected inside a form)", false);
            const kw_idx = try st.b.appendKeyword(kp.key, kp.key_span);
            root_indices.appendAssumeCapacity(kw_idx);
            root_indices.appendAssumeCapacity(kp.value);
        },
    };

    const tree_trailing_range = try st.b.addCommentRange(tree_trailing_comments);
    if (st.b.string_index.items.len == 0) {
        try st.b.string_index.append(st.a, 0);
    }

    return .{
        .root_indices = try root_indices.toOwnedSlice(st.a),
        .tree_trailing_range = tree_trailing_range,
    };
}

/// Hand the builder's slices to a fresh `Tree`. Consumes `arena` —
/// every allocation the parser made lives there, so the Tree owns
/// it all in one move.
fn freezeTree(
    st: *ParseState,
    arena: std.heap.ArenaAllocator,
    freeze: RootFreeze,
) Allocator.Error!Ast.Tree {
    return Ast.Tree{
        .arena = arena,
        .source = st.source,
        .nodes = st.b.nodes.toOwnedSlice(),
        .extra_data = st.b.extra_data.items,
        .strings = st.b.strings.items,
        .string_index = st.b.string_index.items,
        .root = freeze.root_indices,
        .leading_comments_index = st.b.leading_index.items,
        .trailing_comments_index = st.b.trailing_index.items,
        .comments = st.b.comments.toOwnedSlice(),
        .tree_trailing_comments = freeze.tree_trailing_range,
        .diagnostics = try st.diagnostics.toOwnedSlice(st.a),
    };
}

// ---------------------------------------------------------------------------
// Frame helpers — drive `Ast.TreeBuilder` from the parse loop.
// ---------------------------------------------------------------------------

fn makeLeaf(
    b: *Ast.TreeBuilder,
    source: [:0]const u8,
    tok: Token,
    diagnostics: *std.ArrayList(Ast.Diagnostic),
    frames: []const Frame,
    a: Allocator,
) Allocator.Error!?Ast.NodeIndex {
    const span = Span{ .start = tok.start, .end = tok.end };
    switch (tok.tag) {
        .number => {
            const slice = source[tok.start..tok.end];
            const split = splitNumberAndUnit(slice);
            const cleaned = try stripUnderscores(a, split.numeric);

            // Unit-bearing literals stay on the f64 path. There is no
            // exact-integer-with-unit tag — units are arithmetic-shaped
            // and `number_with_unit` is the only carrier for the suffix.
            if (split.unit.len > 0) {
                const v = std.fmt.parseFloat(f64, cleaned) catch {
                    try emit(diagnostics, a, frames, tok, "invalid number literal", true);
                    return try b.appendNode(.{
                        .tag = .number,
                        .span = span,
                        .data = .{ .immediate = @bitCast(@as(f64, 0)) },
                    });
                };
                return try b.appendNumberWithUnit(v, split.unit, span);
            }

            // Bare numeric literal. If the lexeme has no fractional or
            // exponent part, try the exact-integer path first: i64, then
            // u64 for values in (i64.max, u64.max]. Only true overflow
            // (≥ 2^64, or < i64.min) drops through to the f64 fallback —
            // and that path emits the overflow diagnostic so callers
            // know exact round-trip is lost.
            if (!hasFloatShape(cleaned)) {
                if (std.fmt.parseInt(i64, cleaned, 10)) |iv| {
                    return try b.appendNumberI64(iv, span);
                } else |err| switch (err) {
                    error.Overflow => {
                        // Positive overflow may still fit in u64.
                        if (cleaned.len > 0 and cleaned[0] != '-') {
                            if (std.fmt.parseInt(u64, cleaned, 10)) |uv| {
                                return try b.appendNumberU64(uv, span);
                            } else |_| {
                                // Falls through to overflow diagnostic + f64.
                            }
                        }
                        try emitOverflow(diagnostics, a, frames, tok);
                    },
                    error.InvalidCharacter => {
                        // Shouldn't happen — lexer only admits digits and
                        // a leading sign in the integer-shaped lexeme. If
                        // it does, fall through to parseFloat which has
                        // its own diagnostic path.
                    },
                }
            }

            const v = std.fmt.parseFloat(f64, cleaned) catch {
                try emit(diagnostics, a, frames, tok, "invalid number literal", true);
                return try b.appendNumber(0, span);
            };
            return try b.appendNumber(v, span);
        },
        .string => {
            const slice = source[tok.start..tok.end];
            std.debug.assert(slice.len >= 2);
            std.debug.assert(slice[0] == '"');
            std.debug.assert(slice[slice.len - 1] == '"');
            const inner = slice[1 .. slice.len - 1];
            const decoded = try decodeString(a, inner, tok, diagnostics, frames);
            return try b.appendString(decoded, span);
        },
        .raw_string => {
            // Lexer guarantees `"""…"""` shape. Body bytes pass through
            // verbatim: no escape processing, no newline stripping, no
            // dedent. Form is pure trivia — the substrate doesn't notice
            // whether the source used `"…"` or `"""…"""`, only the body
            // bytes between the delimiters. The decoded value is a slice
            // of the source, no allocation needed before pooling.
            const slice = source[tok.start..tok.end];
            std.debug.assert(slice.len >= 6);
            std.debug.assert(std.mem.startsWith(u8, slice, "\"\"\""));
            std.debug.assert(std.mem.endsWith(u8, slice, "\"\"\""));
            const body = slice[3 .. slice.len - 3];
            return try b.appendString(body, span);
        },
        .true_lit => return try b.appendBoolean(true, span),
        .false_lit => return try b.appendBoolean(false, span),
        .nil_lit => return try b.appendNil(span),
        .date => {
            // Lexer guarantees the 10-char `YYYY-MM-DD` shape, so we
            // unpack components inline. Range / leap-year checks return
            // typed errors that map onto specific diagnostic codes —
            // bad dates still emit a tree node (defaulted to
            // `0001-01-01`) so downstream walks remain well-formed.
            const slice = source[tok.start..tok.end];
            std.debug.assert(slice.len == 10);
            const parsed = Date.parse(slice) catch |err| {
                const code: Ast.Diagnostic.Code = switch (err) {
                    error.InvalidYear => .date_invalid_year,
                    error.InvalidMonth => .date_invalid_month,
                    error.InvalidDay => .date_invalid_day,
                    error.InvalidFormat => unreachable,
                };
                try emitDateDiagnostic(diagnostics, a, frames, tok, code);
                return try b.appendDate(Date.init(1, 1, 1) catch unreachable, span);
            };
            return try b.appendDate(parsed, span);
        },
        .time => {
            // Lexer guarantees either an 8-char `HH:MM:SS` or a 12-char
            // `HH:MM:SS.fff` shape, so we unpack components inline. The
            // range checks return typed errors that map onto specific
            // diagnostic codes — bad times still emit a tree node
            // (defaulted to `00:00:00.000`) so downstream walks remain
            // well-formed. Millisecond range is enforced by the lexer
            // (exactly 3 digits ⇒ 0..999), so `InvalidMillisecond` is
            // unreachable here.
            const slice = source[tok.start..tok.end];
            std.debug.assert(slice.len == 8 or slice.len == 12);
            const parsed = Time.parse(slice) catch |err| {
                const code: Ast.Diagnostic.Code = switch (err) {
                    error.InvalidHour => .time_invalid_hour,
                    error.InvalidMinute => .time_invalid_minute,
                    error.InvalidSecond => .time_invalid_second,
                    error.InvalidMillisecond, error.InvalidFormat => unreachable,
                };
                try emitTimeDiagnostic(diagnostics, a, frames, tok, code);
                return try b.appendTime(Time.init(0, 0, 0, 0) catch unreachable, span);
            };
            return try b.appendTime(parsed, span);
        },
        .symbol => {
            const slice = source[tok.start..tok.end];
            return try b.appendSymbol(slice, span);
        },
        .keyword => {
            const slice = source[tok.start..tok.end];
            std.debug.assert(slice.len >= 1);
            std.debug.assert(slice[0] == ':');
            return try b.appendKeyword(slice[1..], span);
        },
        else => return null,
    }
}

fn flushPendingFlag(
    frame: *Frame,
    b: *Ast.TreeBuilder,
    arena: Allocator,
    gpa: Allocator,
) Allocator.Error!void {
    const pk = frame.pending orelse return;
    frame.pending = null;
    const leading = try drainPendingComments(&frame.pending_comments, arena, gpa);
    const leading_range = try b.addCommentRange(leading);
    const idx = try b.appendKeyword(pk.key, pk.span);
    b.setLeading(idx, leading_range);
    try frame.children.append(gpa, .{ .positional = idx });
}

fn attach(
    frames: *std.ArrayList(Frame),
    b: *Ast.TreeBuilder,
    gpa: Allocator,
    arena: Allocator,
    node_idx: Ast.NodeIndex,
) Allocator.Error!void {
    std.debug.assert(frames.items.len >= 1);
    const top = &frames.items[frames.items.len - 1];
    const leading = try drainPendingComments(&top.pending_comments, arena, gpa);
    if (top.pending) |pk| {
        top.pending = null;
        try top.children.append(gpa, .{ .keyword = .{
            .key = pk.key,
            .key_span = pk.span,
            .value = node_idx,
            .leading_comments = leading,
        } });
    } else {
        const leading_range = try b.addCommentRange(leading);
        b.setLeading(node_idx, leading_range);
        try top.children.append(gpa, .{ .positional = node_idx });
    }
}

fn finalizeFrame(
    b: *Ast.TreeBuilder,
    a: Allocator,
    frame: *Frame,
    end: u32,
    trailing_comments: []const Ast.Comment,
) Allocator.Error!Ast.NodeIndex {
    switch (frame.kind) {
        .form => |f| {
            var child_indices = try std.ArrayList(Ast.NodeIndex).initCapacity(a, frame.children.items.len);
            for (frame.children.items) |c| switch (c) {
                .positional => |n| child_indices.appendAssumeCapacity(n),
                .keyword => |kp| {
                    const key_si = try b.addString(kp.key);
                    const value_span = b.nodes.items(.span)[kp.value.raw()];
                    const kv_idx = try b.addKvpair(
                        key_si,
                        kp.value,
                        kp.key_span,
                        .{ .start = kp.key_span.start, .end = value_span.end },
                    );
                    const leading_range = try b.addCommentRange(kp.leading_comments);
                    b.setLeading(kv_idx, leading_range);
                    child_indices.appendAssumeCapacity(kv_idx);
                },
            };
            const head_si = try b.addString(f.head);
            const ns_si: ?Ast.StringIndex = if (f.namespace) |n| try b.addString(n) else null;
            const form_idx = try b.addForm(
                head_si,
                ns_si,
                f.head_span,
                child_indices.items,
                .{ .start = f.open_span.start, .end = end },
            );
            const trailing_range = try b.addCommentRange(trailing_comments);
            b.setTrailing(form_idx, trailing_range);
            return form_idx;
        },
        .vector => |v| {
            var elems = try std.ArrayList(Ast.NodeIndex).initCapacity(a, frame.children.items.len);
            for (frame.children.items) |c| switch (c) {
                .positional => |n| elems.appendAssumeCapacity(n),
                .keyword => unreachable,
            };
            const vec_idx = try b.addVector(elems.items, .{ .start = v.open_span.start, .end = end });
            // Vectors carry trailing comments too (a comment before `]`); the
            // form arm and this one both attach the drained trivia.
            const trailing_range = try b.addCommentRange(trailing_comments);
            b.setTrailing(vec_idx, trailing_range);
            return vec_idx;
        },
        .root => unreachable,
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Pull the next non-comment token, routing any skipped comments onto the
/// current top frame's `pending_comments`. This is what preserves a comment
/// wedged between `(` and the head symbol — `(; note\nfoo …)` — as leading
/// trivia on the resulting form instead of dropping it on the floor.
fn nextSignificant(st: *ParseState) Allocator.Error!Token {
    while (true) {
        const t = st.lex.next();
        switch (t.tag) {
            .comment_line, .comment_block => {
                const top = &st.frames.items[st.frames.items.len - 1];
                try appendPendingComment(st, top, t);
                continue;
            },
            else => return t,
        }
    }
}

/// Emit a parser diagnostic. `frames` lets `buildPath` snapshot the
/// semantic path; `in_progress = true` appends an in-progress slot
/// suffix (kvpair key, positional ordinal, or vector element index)
/// for diagnostics about a value being parsed. Use `false` when the
/// diagnostic is *about* a frame on the stack itself (close mismatches,
/// unclosed delimiters, root-level errors).
fn emit(
    diagnostics: *std.ArrayList(Ast.Diagnostic),
    a: Allocator,
    frames: []const Frame,
    tok: Token,
    msg: []const u8,
    in_progress: bool,
) Allocator.Error!void {
    const path = try buildPath(a, frames, in_progress);
    try diagnostics.append(a, .{
        .span = .{ .start = tok.start, .end = tok.end },
        .message = msg,
        .path = path,
    });
}

const ChildStep = struct {
    step: []const u8,
    via_kvpair: bool,
};

/// Compute the step that names a child of `parent` for path
/// attribution. If `parent.pending` is set, the child is the value of
/// a kvpair and the step is the key (with `via_kvpair = true` so the
/// walk emits both the key and the form head). Otherwise the child is
/// positional: for forms, the positional ordinal counting non-kvpair
/// children; for vectors, the children count.
fn computeChildStep(a: Allocator, parent: *const Frame) Allocator.Error!ChildStep {
    return switch (parent.kind) {
        .root => .{ .step = "", .via_kvpair = false },
        .form => blk: {
            if (parent.pending) |pk| break :blk .{ .step = pk.key, .via_kvpair = true };
            var n: usize = 0;
            for (parent.children.items) |c| switch (c) {
                .positional => n += 1,
                .keyword => {},
            };
            break :blk .{
                .step = try std.fmt.allocPrint(a, "{d}", .{n}),
                .via_kvpair = false,
            };
        },
        .vector => .{
            .step = try std.fmt.allocPrint(a, "{d}", .{parent.children.items.len}),
            .via_kvpair = false,
        },
    };
}

/// Snapshot the current semantic path: walk `frames[1..]` (skipping
/// root). For each frame: emit `parent_step` if reached via kvpair (so
/// the kvpair key appears), then emit the form head (or, for synthetic
/// empty-head forms reached as positionals, fall back to the
/// positional ordinal carried in `parent_step`). Vectors emit
/// `parent_step` only — they have no head step.
///
/// When `in_progress` is set, append the suffix that identifies the
/// slot being parsed inside the top frame (kvpair key from
/// `top.pending`, or the next positional ordinal / vector index).
fn buildPath(
    a: Allocator,
    frames: []const Frame,
    in_progress: bool,
) Allocator.Error![]const []const u8 {
    var buf: std.ArrayList([]const u8) = .empty;
    defer buf.deinit(a);

    if (frames.len > 1) {
        for (frames[1..]) |frame| {
            if (frame.parent_via_kvpair) {
                if (frame.parent_step.len > 0) try buf.append(a, frame.parent_step);
                switch (frame.kind) {
                    .form => |f| if (f.head.len > 0) try buf.append(a, f.head),
                    .vector => {},
                    .root => unreachable,
                }
            } else {
                const step = switch (frame.kind) {
                    .root => unreachable,
                    .form => |f| if (f.head.len > 0) f.head else frame.parent_step,
                    .vector => frame.parent_step,
                };
                if (step.len > 0) try buf.append(a, step);
            }
        }
    }

    if (in_progress and frames.len > 1) {
        const top = &frames[frames.len - 1];
        switch (top.kind) {
            .form => {
                if (top.pending) |pk| {
                    try buf.append(a, pk.key);
                } else {
                    var positional_n: usize = 0;
                    for (top.children.items) |c| switch (c) {
                        .positional => positional_n += 1,
                        .keyword => {},
                    };
                    const idx = try std.fmt.allocPrint(a, "{d}", .{positional_n});
                    try buf.append(a, idx);
                }
            },
            .vector => {
                const idx = try std.fmt.allocPrint(a, "{d}", .{top.children.items.len});
                try buf.append(a, idx);
            },
            .root => {},
        }
    }

    return a.dupe([]const u8, buf.items);
}

pub const NamespaceSplit = struct {
    namespace: ?[]const u8,
    name: []const u8,
};

/// Split `text` on its first interior `/`. Returns `.namespace = null`
/// when there is no slash, when the slash is the first byte, or when it
/// is the last byte — those shapes belong to operator-like symbols or
/// are typos for the validator to surface. Used both by the form-head
/// parser and by the manifest loader for value-kind references.
pub fn splitNamespace(text: []const u8) NamespaceSplit {
    if (std.mem.indexOfScalar(u8, text, '/')) |slash| {
        if (slash > 0 and slash + 1 < text.len) {
            return .{ .namespace = text[0..slash], .name = text[slash + 1 ..] };
        }
    }
    return .{ .namespace = null, .name = text };
}

fn stripUnderscores(a: Allocator, src: []const u8) Allocator.Error![]u8 {
    var buf = try a.alloc(u8, src.len);
    var n: usize = 0;
    for (src) |c| {
        if (c == '_') continue;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

/// True when the underscore-stripped numeric lexeme has float syntax —
/// fractional part (`.`) or exponent marker (`e`/`E`). Used by the
/// parser to route bare numeric literals through the exact-integer
/// path (i64/u64) vs the f64 path.
fn hasFloatShape(cleaned: []const u8) bool {
    for (cleaned) |c| {
        if (c == '.' or c == 'e' or c == 'E') return true;
    }
    return false;
}

/// Emit a `.number_overflow_exact_integer` diagnostic. Fired when a
/// pure-integer literal exceeds the u64 (or, with a leading `-`, the
/// i64) range. The parser then falls back to f64 storage so the tree
/// stays well-formed — at the cost of exact round-trip.
fn emitOverflow(
    diagnostics: *std.ArrayList(Ast.Diagnostic),
    a: Allocator,
    frames: []const Frame,
    tok: Token,
) Allocator.Error!void {
    const path = try buildPath(a, frames, true);
    try diagnostics.append(a, .{
        .span = .{ .start = tok.start, .end = tok.end },
        .message = "integer literal exceeds u64 range; storing as approximate f64",
        .severity = .err,
        .code = .number_overflow_exact_integer,
        .path = path,
    });
}

/// Emit a date-component diagnostic. The lexer already accepted the
/// 10-char `YYYY-MM-DD` shape, so the only failure modes here are
/// out-of-range components — year `0000`, month outside `[1, 12]`,
/// day outside `[1, daysInMonth(year, month)]` (including the
/// leap-year case for February).
fn emitDateDiagnostic(
    diagnostics: *std.ArrayList(Ast.Diagnostic),
    a: Allocator,
    frames: []const Frame,
    tok: Token,
    code: Ast.Diagnostic.Code,
) Allocator.Error!void {
    const path = try buildPath(a, frames, true);
    const message = switch (code) {
        .date_invalid_year => "date year out of range (1..9999)",
        .date_invalid_month => "date month out of range (1..12)",
        .date_invalid_day => "date day out of range for the given year and month",
        else => unreachable,
    };
    try diagnostics.append(a, .{
        .span = .{ .start = tok.start, .end = tok.end },
        .message = message,
        .severity = .err,
        .code = code,
        .path = path,
    });
}

/// Emit a time-component diagnostic. The lexer already accepted the
/// 8- or 12-char shape, so the only failure modes here are
/// out-of-range components — hour > 23, minute > 59, second > 59.
/// Millisecond range is enforced at the lexer level (exactly 3
/// digits ⇒ 0..999), so it cannot reach this path.
fn emitTimeDiagnostic(
    diagnostics: *std.ArrayList(Ast.Diagnostic),
    a: Allocator,
    frames: []const Frame,
    tok: Token,
    code: Ast.Diagnostic.Code,
) Allocator.Error!void {
    const path = try buildPath(a, frames, true);
    const message = switch (code) {
        .time_invalid_hour => "time hour out of range (0..23)",
        .time_invalid_minute => "time minute out of range (0..59)",
        .time_invalid_second => "time second out of range (0..59)",
        else => unreachable,
    };
    try diagnostics.append(a, .{
        .span = .{ .start = tok.start, .end = tok.end },
        .message = message,
        .severity = .err,
        .code = code,
        .path = path,
    });
}

const NumberSplit = struct {
    numeric: []const u8,
    unit: []const u8,
};

/// Walk a `.number` token slice produced by the lexer and split it into
/// the numeric portion (digits / `.` / `_` / valid `eEXP`) and the unit
/// suffix (ASCII letters, or a single trailing `%`). Mirrors the lexer's
/// rule that `e`/`E` is exponent only when followed by digit / sign;
/// otherwise it starts the unit. The returned slices alias `slice`.
///
/// Pre: `slice` is a `.number` token from the lexer (len >= 1, at least
///      one digit somewhere).
/// Post: `numeric ++ unit == slice` and `unit` is empty, a single `%`,
///       or a run of ASCII letters.
fn splitNumberAndUnit(slice: []const u8) NumberSplit {
    std.debug.assert(slice.len >= 1);
    var i: usize = 0;
    if (i < slice.len and slice[i] == '-') i += 1;
    while (i < slice.len and (isDigit(slice[i]) or slice[i] == '_')) i += 1;
    if (i < slice.len and slice[i] == '.') {
        i += 1;
        while (i < slice.len and (isDigit(slice[i]) or slice[i] == '_')) i += 1;
    }
    if (i < slice.len and (slice[i] == 'e' or slice[i] == 'E')) {
        // `e`/`E` is exponent only when followed by digit or sign; the
        // lexer's same lookahead rule applies here.
        var j = i + 1;
        if (j < slice.len and (slice[j] == '+' or slice[j] == '-')) j += 1;
        if (j < slice.len and isDigit(slice[j])) {
            i = j;
            while (i < slice.len and (isDigit(slice[i]) or slice[i] == '_')) i += 1;
        }
    }
    const split: NumberSplit = if (i < slice.len and slice[i] == '%')
        .{ .numeric = slice[0..i], .unit = slice[i .. i + 1] }
    else
        .{ .numeric = slice[0..i], .unit = slice[i..] };
    std.debug.assert(split.numeric.len + split.unit.len == slice.len);
    std.debug.assert(split.unit.len == 0 or split.unit[0] == '%' or
        std.ascii.isAlphabetic(split.unit[0]));
    return split;
}

inline fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Parse the number node at `idx` straight into the target machine type
/// `T` (`f32`/`f16`/`u16`/`u32`/`i32`), reading the original source lexeme
/// rather than the tree's decoded `f64`. This is the "no double-round"
/// read primitive behind `:repr`: a decimal like `"1.1"` is rounded once
/// (decimal → `f32`) instead of twice (decimal → `f64` → `f32`), which can
/// differ in the last bit. Any unit suffix is dropped — the GPU consumer
/// wants the magnitude.
///
/// O(n) in the lexeme length; allocates a transient underscore-stripping
/// buffer (freed before return) — no tree mutation, no retained state.
/// `T` must be a float or integer type; anything else is a compile error.
///
/// Errors:
///   * `error.Overflow` — value outside `T`'s *integer* range (`parseInt`
///     only; `parseFloat` saturates to ±inf rather than erroring). The
///     validator's `repr_out_of_range` is the user-facing guard; this is
///     the low-level signal for an unguarded read.
///   * `error.InvalidCharacter` — malformed lexeme (not expected on a
///     parser-produced tree; the slice is re-parsed defensively).
///   * `error.OutOfMemory` — the scratch buffer.
///
/// Tree-path only: the binary IR keeps just the decoded `f64`, so a
/// binary-only consumer can't direct-parse (a documented deferred item).
pub fn parseNumberAs(
    comptime T: type,
    tree: *const Ast.Tree,
    gpa: Allocator,
    idx: Ast.NodeIndex,
) error{ OutOfMemory, Overflow, InvalidCharacter }!T {
    const tag = tree.tagOf(idx);
    std.debug.assert(tag.isNumber() or tag == .number_with_unit);

    const span = tree.spanOf(idx);
    const slice = tree.source[span.start..span.end];
    const numeric = splitNumberAndUnit(slice).numeric;

    // Strip digit-group underscores into a scratch buffer (mirrors
    // `makeLeaf`). Free the *full* allocation — not the `[0..n]` view that
    // `stripUnderscores` would return, which a caller GPA can't free.
    const buf = try gpa.alloc(u8, numeric.len);
    defer gpa.free(buf);
    var n: usize = 0;
    for (numeric) |c| {
        if (c == '_') continue;
        buf[n] = c;
        n += 1;
    }
    const cleaned = buf[0..n];
    std.debug.assert(cleaned.len > 0); // a numeric lexeme always has ≥1 digit

    return switch (@typeInfo(T)) {
        .float => std.fmt.parseFloat(T, cleaned),
        .int => std.fmt.parseInt(T, cleaned, 10),
        else => @compileError("parseNumberAs supports float/int repr types only, got " ++ @typeName(T)),
    };
}

fn decodeString(
    a: Allocator,
    inner: []const u8,
    tok: Token,
    diagnostics: *std.ArrayList(Ast.Diagnostic),
    frames: []const Frame,
) Allocator.Error![]const u8 {
    // Pessimistic: the decoded form is at most as long as the source.
    var buf = try a.alloc(u8, inner.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < inner.len) {
        const c = inner[i];
        if (c == '\\' and i + 1 < inner.len) {
            const e = inner[i + 1];
            switch (e) {
                'n' => buf[n] = '\n',
                't' => buf[n] = '\t',
                'r' => buf[n] = '\r',
                '"' => buf[n] = '"',
                '\\' => buf[n] = '\\',
                '0' => buf[n] = 0,
                else => {
                    try emit(diagnostics, a, frames, tok, "unrecognized string escape", true);
                    buf[n] = e;
                },
            }
            n += 1;
            i += 2;
            continue;
        }
        buf[n] = c;
        n += 1;
        i += 1;
    }
    return buf[0..n];
}

fn drainPendingComments(
    list: *std.ArrayList(Ast.Comment),
    arena: Allocator,
    gpa: Allocator,
) Allocator.Error![]const Ast.Comment {
    if (list.items.len == 0) return &.{};
    const dup = try arena.dupe(Ast.Comment, list.items);
    list.clearAndFree(gpa);
    return dup;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parse number" {
    var tree = try parse(testing.allocator, "42");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    // Pure-integer literal — routes through the exact-integer path.
    try testing.expectEqual(.number_i64, tree.tagOf(tree.root[0]));
    try testing.expectEqual(@as(i64, 42), tree.numberI64Of(tree.root[0]));
    try testing.expect(!tree.hasErrors());
}

test "parse number (float)" {
    var tree = try parse(testing.allocator, "42.5");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    // Fractional literal still lands on the f64-backed `.number` tag.
    try testing.expectEqual(.number, tree.tagOf(tree.root[0]));
    try testing.expectEqual(@as(f64, 42.5), tree.numberOf(tree.root[0]));
    try testing.expect(!tree.hasErrors());
}

test "parse number: exact i64.min and u64.max" {
    var tree = try parse(testing.allocator,
        \\-9223372036854775808 18446744073709551615
    );
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 2), tree.root.len);
    try testing.expectEqual(.number_i64, tree.tagOf(tree.root[0]));
    try testing.expectEqual(std.math.minInt(i64), tree.numberI64Of(tree.root[0]));
    try testing.expectEqual(.number_u64, tree.tagOf(tree.root[1]));
    try testing.expectEqual(std.math.maxInt(u64), tree.numberU64Of(tree.root[1]));
    try testing.expect(!tree.hasErrors());
}

test "parse number: u64-overflow emits .number_overflow_exact_integer" {
    // Beyond u64.max — exact storage isn't possible, so the parser falls
    // back to f64 and emits the new wire-stable diagnostic.
    var tree = try parse(testing.allocator, "99999999999999999999999999");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    try testing.expectEqual(.number, tree.tagOf(tree.root[0]));
    try testing.expect(tree.diagnostics.len >= 1);
    var saw_code = false;
    for (tree.diagnostics) |d| {
        if (d.code == .number_overflow_exact_integer) saw_code = true;
    }
    try testing.expect(saw_code);
}

test "parse number: negative overflow below i64.min emits .number_overflow_exact_integer" {
    // < i64.min with a leading '-'. The positive-only u64 retry is skipped
    // (negatives can't fit u64), so the parser drops straight to the f64
    // fallback and emits the overflow diagnostic — the negative twin of the
    // u64-overflow case above, exercising `emitOverflow`'s remaining arm.
    var tree = try parse(testing.allocator, "-99999999999999999999");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    try testing.expectEqual(.number, tree.tagOf(tree.root[0]));
    try testing.expect(tree.diagnostics.len >= 1);
    var saw_code = false;
    for (tree.diagnostics) |d| {
        if (d.code == .number_overflow_exact_integer) saw_code = true;
    }
    try testing.expect(saw_code);
}

test "parseNumberAs f32: single-rounds the slice, beating the f64 double-round" {
    // Adversarial double-rounding literal. 16777217 is the exact f32 tie
    // between 16777216 (even mantissa) and 16777218; a hair above it rounds
    // UP in a single decimal→f32 step. But decimal→f64 first collapses the
    // hair (1e-9 < half an f64-ulp ≈ 1.86e-9 here) back to the exact tie
    // 16777217.0, then f64→f32 rounds-to-even DOWN to 16777216. So the
    // double-round path (what `@floatCast(f32, tree.numberOf(idx))` does)
    // and a direct slice parse give *different* f32 values — proving the
    // primitive reads the source, not the decoded f64.
    const a = testing.allocator;
    var tree = try parse(a, "16777217.000000001");
    defer tree.deinit();
    try testing.expectEqual(.number, tree.tagOf(tree.root[0]));

    const direct = try parseNumberAs(f32, &tree, a, tree.root[0]);
    try testing.expectEqual(@as(f32, 16777218.0), direct);

    const doubled: f32 = @floatCast(tree.numberOf(tree.root[0]));
    try testing.expectEqual(@as(f32, 16777216.0), doubled);
    try testing.expect(direct != doubled); // the whole point of the primitive
}

test "parseNumberAs: integer reprs parse exactly" {
    const a = testing.allocator;
    var tree = try parse(a, "65535 4294967295 -2147483648");
    defer tree.deinit();
    try testing.expectEqual(@as(u16, 65535), try parseNumberAs(u16, &tree, a, tree.root[0]));
    try testing.expectEqual(@as(u32, 4294967295), try parseNumberAs(u32, &tree, a, tree.root[1]));
    try testing.expectEqual(@as(i32, -2147483648), try parseNumberAs(i32, &tree, a, tree.root[2]));
}

test "parseNumberAs: drops a unit suffix and reads the magnitude" {
    const a = testing.allocator;
    var tree = try parse(a, "250ms");
    defer tree.deinit();
    try testing.expectEqual(.number_with_unit, tree.tagOf(tree.root[0]));
    try testing.expectEqual(@as(u32, 250), try parseNumberAs(u32, &tree, a, tree.root[0]));
    try testing.expectEqual(@as(f32, 250.0), try parseNumberAs(f32, &tree, a, tree.root[0]));
}

test "parseNumberAs: strips digit-group underscores before parsing" {
    const a = testing.allocator;
    var tree = try parse(a, "1_000_000");
    defer tree.deinit();
    try testing.expectEqual(@as(u32, 1000000), try parseNumberAs(u32, &tree, a, tree.root[0]));
}

test "parseNumberAs: integer overflow surfaces error.Overflow" {
    const a = testing.allocator;
    var tree = try parse(a, "70000");
    defer tree.deinit();
    try testing.expectError(error.Overflow, parseNumberAs(u16, &tree, a, tree.root[0]));
}

test "parseNumberAs f16: over-range decimal saturates to inf (no error on floats)" {
    const a = testing.allocator;
    var tree = try parse(a, "70000.0");
    defer tree.deinit();
    const v = try parseNumberAs(f16, &tree, a, tree.root[0]);
    try testing.expect(std.math.isInf(v)); // float path saturates, validator is the guard
}

test "parse number with unit suffix" {
    var tree = try parse(testing.allocator, "90deg");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    try testing.expectEqual(.number_with_unit, tree.tagOf(tree.root[0]));
    const nwu = tree.numberWithUnitOf(tree.root[0]);
    try testing.expectEqual(@as(f64, 90.0), nwu.value);
    try testing.expectEqualStrings("deg", nwu.unit);
    try testing.expect(!tree.hasErrors());
}

test "parse various unit shapes" {
    var tree = try parse(testing.allocator, "0.5em 1.5e2hz -50% 1_000ms 4b");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 5), tree.root.len);
    const cases = [_]struct { value: f64, unit: []const u8 }{
        .{ .value = 0.5, .unit = "em" },
        .{ .value = 150.0, .unit = "hz" },
        .{ .value = -50.0, .unit = "%" },
        .{ .value = 1000.0, .unit = "ms" },
        .{ .value = 4.0, .unit = "b" },
    };
    for (cases, 0..) |c, i| {
        try testing.expectEqual(.number_with_unit, tree.tagOf(tree.root[i]));
        const nwu = tree.numberWithUnitOf(tree.root[i]);
        try testing.expectEqual(c.value, nwu.value);
        try testing.expectEqualStrings(c.unit, nwu.unit);
    }
    try testing.expect(!tree.hasErrors());
}

test "parse vector of unit-suffixed numbers" {
    var tree = try parse(testing.allocator, "[4b 90deg 50% 250ms]");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    try testing.expectEqual(.vector, tree.tagOf(tree.root[0]));
    const elems = tree.vectorElements(tree.root[0]);
    try testing.expectEqual(@as(usize, 4), elems.len);
    const expected_units = [_][]const u8{ "b", "deg", "%", "ms" };
    for (elems, expected_units) |idx, u| {
        try testing.expectEqual(.number_with_unit, tree.tagOf(idx));
        try testing.expectEqualStrings(u, tree.numberWithUnitOf(idx).unit);
    }
    try testing.expect(!tree.hasErrors());
}

test "parse keyword-paired unit numbers" {
    var tree = try parse(testing.allocator, "(scene :angle 90deg :delay 250ms)");
    defer tree.deinit();
    const f = tree.formHeader(tree.root[0]);
    try testing.expectEqual(@as(usize, 2), f.children.len);
    const angle_kp = tree.kvpairHeader(f.children[0]);
    try testing.expectEqualStrings("angle", angle_kp.key);
    try testing.expectEqualStrings("deg", tree.numberWithUnitOf(angle_kp.value).unit);
    const delay_kp = tree.kvpairHeader(f.children[1]);
    try testing.expectEqualStrings("delay", delay_kp.key);
    try testing.expectEqualStrings("ms", tree.numberWithUnitOf(delay_kp.value).unit);
}

test "splitNumberAndUnit boundary cases" {
    // Pure number, no unit.
    {
        const split = splitNumberAndUnit("42");
        try testing.expectEqualStrings("42", split.numeric);
        try testing.expectEqualStrings("", split.unit);
    }
    // Exponent without unit.
    {
        const split = splitNumberAndUnit("1.5e-10");
        try testing.expectEqualStrings("1.5e-10", split.numeric);
        try testing.expectEqualStrings("", split.unit);
    }
    // `e` followed by letter — `e` starts the unit.
    {
        const split = splitNumberAndUnit("1em");
        try testing.expectEqualStrings("1", split.numeric);
        try testing.expectEqualStrings("em", split.unit);
    }
    // Exponent then unit.
    {
        const split = splitNumberAndUnit("1.5e2hz");
        try testing.expectEqualStrings("1.5e2", split.numeric);
        try testing.expectEqualStrings("hz", split.unit);
    }
    // Trailing %.
    {
        const split = splitNumberAndUnit("-50%");
        try testing.expectEqualStrings("-50", split.numeric);
        try testing.expectEqualStrings("%", split.unit);
    }
    // Underscore separator.
    {
        const split = splitNumberAndUnit("1_000ms");
        try testing.expectEqualStrings("1_000", split.numeric);
        try testing.expectEqualStrings("ms", split.unit);
    }
}

test "splitNumberAndUnit handles E/e capitalization symmetrically" {
    {
        const split = splitNumberAndUnit("1.5E2hz");
        try testing.expectEqualStrings("1.5E2", split.numeric);
        try testing.expectEqualStrings("hz", split.unit);
    }
    {
        const split = splitNumberAndUnit("1Em");
        try testing.expectEqualStrings("1", split.numeric);
        try testing.expectEqualStrings("Em", split.unit);
    }
}

test "splitNumberAndUnit on multi-letter and mixed-case unit" {
    {
        const split = splitNumberAndUnit("4PxRem");
        try testing.expectEqualStrings("4", split.numeric);
        try testing.expectEqualStrings("PxRem", split.unit);
    }
    {
        const split = splitNumberAndUnit("100microseconds");
        try testing.expectEqualStrings("100", split.numeric);
        try testing.expectEqualStrings("microseconds", split.unit);
    }
}

test "splitNumberAndUnit treats trailing percent as exactly one byte" {
    const split = splitNumberAndUnit("50%");
    try testing.expectEqualStrings("50", split.numeric);
    try testing.expectEqualStrings("%", split.unit);
    try testing.expectEqual(@as(usize, 1), split.unit.len);
}

test "parse: dot-then-exponent edge case lexes as two tokens" {
    // `1.e2hz` lexes as `1.e` (number with unit `e`) then `2hz`.
    var tree = try parse(testing.allocator, "1.e2hz");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 2), tree.root.len);
    try testing.expectEqualStrings("e", tree.numberWithUnitOf(tree.root[0]).unit);
    try testing.expectEqualStrings("hz", tree.numberWithUnitOf(tree.root[1]).unit);
}

test "parse: nested unit numbers across forms and vectors" {
    var tree = try parse(testing.allocator,
        \\(scene :angle 90deg
        \\  (canvas :z 0.5em
        \\    [4b 90deg 50% 250ms]
        \\    (clip :duration 1.5e2hz)))
    );
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(@as(usize, 1), tree.root.len);
}

test "parse: long unit string survives round-trip into payload" {
    var tree = try parse(testing.allocator, "100microseconds");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const nwu = tree.numberWithUnitOf(tree.root[0]);
    try testing.expectEqual(@as(f64, 100.0), nwu.value);
    try testing.expectEqualStrings("microseconds", nwu.unit);
}

test "parse: positional unit-number children inside form" {
    var tree = try parse(testing.allocator, "(stack 4px 8px 12px)");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const f = tree.formHeader(tree.root[0]);
    try testing.expectEqual(@as(usize, 3), f.children.len);
    try testing.expectEqualStrings("px", tree.numberWithUnitOf(f.children[0]).unit);
    try testing.expectEqualStrings("px", tree.numberWithUnitOf(f.children[2]).unit);
}

test "parse: unit number bound in let scope" {
    // Pin that the parser preserves the unit on a vector binding's value.
    var tree = try parse(testing.allocator, "(let [r 0.5em] (vec3 r r r))");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const let_form = tree.formHeader(tree.root[0]);
    try testing.expectEqualStrings("let", let_form.head);
    const bindings = tree.vectorElements(let_form.children[0]);
    try testing.expectEqual(@as(usize, 2), bindings.len);
    try testing.expectEqualStrings("em", tree.numberWithUnitOf(bindings[1]).unit);
}

test "parse string with escape" {
    var tree = try parse(testing.allocator,
        \\"hi\nthere"
    );
    defer tree.deinit();
    try testing.expectEqual(.string, tree.tagOf(tree.root[0]));
    const si: Ast.StringIndex = @enumFromInt(tree.dataOf(tree.root[0]).single);
    try testing.expectEqualStrings("hi\nthere", tree.stringSlice(si));
}

test "parse boolean and nil" {
    var tree = try parse(testing.allocator, "true false nil");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 3), tree.root.len);
    try testing.expectEqual(.boolean_true, tree.tagOf(tree.root[0]));
    try testing.expectEqual(.boolean_false, tree.tagOf(tree.root[1]));
    try testing.expectEqual(.nil, tree.tagOf(tree.root[2]));
}

test "parse simple form" {
    var tree = try parse(testing.allocator, "(scene :bpm 130)");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    const f = tree.formHeader(tree.root[0]);
    try testing.expectEqualStrings("scene", f.head);
    try testing.expectEqual(@as(usize, 1), f.children.len);
    const kp = tree.kvpairHeader(f.children[0]);
    try testing.expectEqualStrings("bpm", kp.key);
    try testing.expectEqual(@as(f64, 130.0), tree.numberOf(kp.value));
}

test "parse vector" {
    var tree = try parse(testing.allocator, "[1 2 3]");
    defer tree.deinit();
    const elems = tree.vectorElements(tree.root[0]);
    try testing.expectEqual(@as(usize, 3), elems.len);
    try testing.expectEqual(@as(f64, 1), tree.numberOf(elems[0]));
}

test "nested form" {
    var tree = try parse(testing.allocator, "(canvas (camera :ortho :zoom 2))");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const canvas = tree.formHeader(tree.root[0]);
    try testing.expectEqualStrings("canvas", canvas.head);
    try testing.expectEqual(@as(usize, 1), canvas.children.len);

    const camera = tree.formHeader(canvas.children[0]);
    try testing.expectEqualStrings("camera", camera.head);
    try testing.expectEqual(@as(usize, 2), camera.children.len);

    // First child: `:ortho` is positional (followed by another keyword).
    const ortho_idx = camera.children[0];
    try testing.expectEqual(.keyword, tree.tagOf(ortho_idx));
    const ortho_si: Ast.StringIndex = @enumFromInt(tree.dataOf(ortho_idx).single);
    try testing.expectEqualStrings("ortho", tree.stringSlice(ortho_si));

    // Second child: `:zoom 2` keyword pair.
    const zoom_kp = tree.kvpairHeader(camera.children[1]);
    try testing.expectEqualStrings("zoom", zoom_kp.key);
    try testing.expectEqual(@as(f64, 2), tree.numberOf(zoom_kp.value));
}

test "namespace split" {
    var tree = try parse(testing.allocator, "(masagin/verb)");
    defer tree.deinit();
    const f = tree.formHeader(tree.root[0]);
    try testing.expectEqualStrings("verb", f.head);
    try testing.expectEqualStrings("masagin", f.namespace.?);
}

test "trailing keyword becomes positional flag" {
    var tree = try parse(testing.allocator, "(camera :ortho)");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const camera = tree.formHeader(tree.root[0]);
    try testing.expectEqual(@as(usize, 1), camera.children.len);
    try testing.expectEqual(.keyword, tree.tagOf(camera.children[0]));
    const si: Ast.StringIndex = @enumFromInt(tree.dataOf(camera.children[0]).single);
    try testing.expectEqualStrings("ortho", tree.stringSlice(si));
}

test "unclosed paren produces diagnostic" {
    var tree = try parse(testing.allocator, "(scene :bpm 130");
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    try testing.expectEqual(.form, tree.tagOf(tree.root[0]));
}

test "stray rparen at top level emits diagnostic but recovers" {
    var tree = try parse(testing.allocator, ") 42");
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    try testing.expectEqual(@as(f64, 42), tree.numberOf(tree.root[0]));
}

test "expression-shaped form parses uniformly" {
    var tree = try parse(testing.allocator, "(* 2 (b 1))");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const mul = tree.formHeader(tree.root[0]);
    try testing.expectEqualStrings("*", mul.head);
    try testing.expectEqual(@as(usize, 2), mul.children.len);
    try testing.expectEqual(@as(f64, 2), tree.numberOf(mul.children[0]));
    const b = tree.formHeader(mul.children[1]);
    try testing.expectEqualStrings("b", b.head);
    try testing.expectEqual(@as(f64, 1), tree.numberOf(b.children[0]));
}

test "scene fixture parses cleanly" {
    const src =
        \\(scene :bpm 130
        \\  (canvas :name "main"
        \\    (camera :ortho :zoom (* 2 (b 1)))
        \\    (stack :mode :mask
        \\      (shape :sdf :radius 0.5
        \\        :delay (delay :p+s (b 4))
        \\        :lifespan (b 16))
        \\      (shape :path :points [[0 0] [1 0] [1 1]]))))
    ;
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    try testing.expectEqualStrings("scene", tree.formHeader(tree.root[0]).head);
}

test "deep nesting under MAX_PARSE_DEPTH" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const depth: usize = 256;
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < depth) : (i += 1) try buf.appendSlice(a, "(x ");
    i = 0;
    while (i < depth) : (i += 1) try buf.append(a, ')');
    try buf.append(a, 0);
    const src: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
}

test "unterminated string is reported" {
    var tree = try parse(testing.allocator, "\"oops");
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
}

test "comment attaches to following top-level node" {
    var tree = try parse(testing.allocator,
        \\; greeting
        \\42
    );
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    const range = tree.leading_comments_index[tree.root[0].raw()];
    try testing.expectEqual(@as(u32, 1), range.len());
    try testing.expectEqualStrings("; greeting", tree.commentTexts(range)[0]);
    try testing.expectEqual(Ast.Comment.Kind.line, tree.commentKinds(range)[0]);
}

test "block comment attaches to following node" {
    var tree = try parse(testing.allocator,
        \\#| hi |# 7
    );
    defer tree.deinit();
    const range = tree.leading_comments_index[tree.root[0].raw()];
    try testing.expectEqual(@as(u32, 1), range.len());
    try testing.expectEqualStrings("#| hi |#", tree.commentTexts(range)[0]);
    try testing.expectEqual(Ast.Comment.Kind.block, tree.commentKinds(range)[0]);
}

test "comment inside form attaches to next child" {
    var tree = try parse(testing.allocator,
        \\(scene
        \\  ; tempo
        \\  :bpm 130)
    );
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const f = tree.formHeader(tree.root[0]);
    try testing.expectEqual(@as(usize, 1), f.children.len);
    // Form children: kvpair carries leading comments of the pair.
    try testing.expectEqual(.kvpair, tree.tagOf(f.children[0]));
    const range = tree.leading_comments_index[f.children[0].raw()];
    try testing.expectEqual(@as(u32, 1), range.len());
    try testing.expectEqualStrings("; tempo", tree.commentTexts(range)[0]);
}

test "comment after last child becomes form trailing" {
    var tree = try parse(testing.allocator,
        \\(scene 1 ; trailing
        \\)
    );
    defer tree.deinit();
    const range = tree.trailing_comments_index[tree.root[0].raw()];
    try testing.expectEqual(@as(u32, 1), range.len());
    try testing.expectEqualStrings("; trailing", tree.commentTexts(range)[0]);
}

test "comment after final form becomes tree trailing" {
    var tree = try parse(testing.allocator,
        \\42
        \\; bye
    );
    defer tree.deinit();
    try testing.expectEqual(@as(u32, 1), tree.tree_trailing_comments.len());
    try testing.expectEqualStrings("; bye", tree.commentTexts(tree.tree_trailing_comments)[0]);
}

test "comment followed by flush-as-flag attaches to flag node" {
    // `:ortho` is followed by another `:keyword`, so it becomes a positional
    // flag. The leading comment should attach to that flag.
    var tree = try parse(testing.allocator,
        \\(camera
        \\  ; pick projection
        \\  :ortho :zoom 2)
    );
    defer tree.deinit();
    const f = tree.formHeader(tree.root[0]);
    try testing.expectEqual(@as(usize, 2), f.children.len);
    try testing.expectEqual(.keyword, tree.tagOf(f.children[0]));
    const range = tree.leading_comments_index[f.children[0].raw()];
    try testing.expectEqual(@as(u32, 1), range.len());
    try testing.expectEqualStrings("; pick projection", tree.commentTexts(range)[0]);
}

test "vector treats `:kw v` as two positional elements" {
    // Inside a vector, `:foo` is a positional keyword value; the next
    // value is also positional. No kvpair entry is built, so the
    // unrolled element list is just the source order.
    var tree = try parse(testing.allocator, "[1 :foo \"bar\" true nil]");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const elems = tree.vectorElements(tree.root[0]);
    try testing.expectEqual(@as(usize, 5), elems.len);
    try testing.expectEqual(@as(f64, 1), tree.numberOf(elems[0]));
    try testing.expectEqual(.keyword, tree.tagOf(elems[1]));
    const foo_si: Ast.StringIndex = @enumFromInt(tree.dataOf(elems[1]).single);
    try testing.expectEqualStrings("foo", tree.stringSlice(foo_si));
    try testing.expectEqual(.string, tree.tagOf(elems[2]));
    const bar_si: Ast.StringIndex = @enumFromInt(tree.dataOf(elems[2]).single);
    try testing.expectEqualStrings("bar", tree.stringSlice(bar_si));
    try testing.expectEqual(.boolean_true, tree.tagOf(elems[3]));
    try testing.expectEqual(.nil, tree.tagOf(elems[4]));
}

test "vector keyword: comment before `:kw` attaches as the keyword's leading" {
    // Pre-strip behavior: the comment landed in `KeywordEntry.leading_comments`
    // and was discarded by the vector finalize. With pending-key off for
    // vectors, `:foo` is just a positional and gets the comment naturally.
    var tree = try parse(testing.allocator,
        \\[1 ; before-foo
        \\ :foo "bar"]
    );
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const elems = tree.vectorElements(tree.root[0]);
    try testing.expectEqual(@as(usize, 3), elems.len);
    try testing.expectEqual(.keyword, tree.tagOf(elems[1]));
    const range = tree.leading_comments_index[elems[1].raw()];
    try testing.expectEqual(@as(u32, 1), range.len());
    try testing.expectEqualStrings("; before-foo", tree.commentTexts(range)[0]);
}

test "vector keyword: comment between `:kw` and value attaches as the value's leading" {
    // Pre-strip behavior: this comment was also discarded (it accumulated
    // after `:foo` set pending; the next leaf became a `KeywordEntry` whose
    // `leading_comments` were dropped). Now it attaches to the value leaf.
    var tree = try parse(testing.allocator,
        \\[:foo ; between
        \\ "bar"]
    );
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const elems = tree.vectorElements(tree.root[0]);
    try testing.expectEqual(@as(usize, 2), elems.len);
    try testing.expectEqual(.string, tree.tagOf(elems[1]));
    const range = tree.leading_comments_index[elems[1].raw()];
    try testing.expectEqual(@as(u32, 1), range.len());
    try testing.expectEqualStrings("; between", tree.commentTexts(range)[0]);
}

test "diag path: nested vector after `:kw` reports the parent-element's real index" {
    // Pre-strip behavior: when `:foo` was buffered as `pending`, the
    // following `[` opened a sub-vector whose `parent_step` was
    // `children.items.len = 1` (only `1` had been attached as a
    // positional; the kvpair entry wasn't built until the inner vector
    // closed). The unrolled outer vector lays out as `[1, :foo, [..]]`,
    // so the inner vector's real element index is 2 — the path drifted
    // by one. With pending-key off in vectors, `:foo` is itself a
    // positional, so the entry count matches the unrolled index.
    var tree = try parse(testing.allocator, "(parent [1 :foo [\"x\\q\"]])");
    defer tree.deinit();
    const d = findDiag(&tree, "unrecognized string escape") orelse return error.MissingDiagnostic;
    // Outer vector is parent's positional 0; inner vector sits at
    // outer-vector element index 2 ([1, :foo, [..]]); bad escape is
    // element 0 of the inner vector.
    try expectPath(d, &.{ "parent", "0", "2", "0" });
}

test "top-level keyword pair followed by positional" {
    // Regression: root drain previously sized by `children.items.len` while
    // a kw pair expands into two roots. A trailing positional then crashed
    // appendAssumeCapacity. The case is still degenerate (multi-root with a
    // diagnostic), but it must not crash the parser.
    var tree = try parse(testing.allocator, ":foo 1 2");
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
    try testing.expectEqual(@as(usize, 3), tree.root.len);
    try testing.expectEqual(.keyword, tree.tagOf(tree.root[0]));
    const foo_si: Ast.StringIndex = @enumFromInt(tree.dataOf(tree.root[0]).single);
    try testing.expectEqualStrings("foo", tree.stringSlice(foo_si));
    try testing.expectEqual(@as(f64, 1), tree.numberOf(tree.root[1]));
    try testing.expectEqual(@as(f64, 2), tree.numberOf(tree.root[2]));
}

// ---------------------------------------------------------------------------
// Long-tail parser tests — error recovery, depth boundary, edge cases
// in namespace splitting / kwargs / string decoding. Pinned alongside the
// canonical-path tests above so a parser refactor catches drift here.
// ---------------------------------------------------------------------------

test "empty input parses to empty tree" {
    var tree = try parse(testing.allocator, "");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(@as(usize, 0), tree.root.len);
}

test "whitespace-only input parses to empty tree" {
    var tree = try parse(testing.allocator, "   \n\t  \r\n  ");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(@as(usize, 0), tree.root.len);
}

test "only-comment input is preserved as tree-trailing" {
    var tree = try parse(testing.allocator, "; hi only");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(@as(usize, 0), tree.root.len);
    try testing.expectEqual(@as(u32, 1), tree.tree_trailing_comments.len());
}

test "empty form `()` is reported but recoverable" {
    var tree = try parse(testing.allocator, "()");
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    try testing.expectEqual(.form, tree.tagOf(tree.root[0]));
    try testing.expectEqualStrings("", tree.formHeader(tree.root[0]).head);
}

test "empty vector `[]` parses cleanly" {
    var tree = try parse(testing.allocator, "[]");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    try testing.expectEqual(.vector, tree.tagOf(tree.root[0]));
    try testing.expectEqual(@as(usize, 0), tree.vectorElements(tree.root[0]).len);
}

test "many unclosed parens collect a chain of diagnostics" {
    // Every unclosed delimiter at EOF drops a fresh diagnostic; the final
    // tree still finalizes (parser must not panic on cascade).
    var tree = try parse(testing.allocator, "(((((((");
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
    // Six unclosed forms -> at least six diagnostics. Exact count may include
    // additional invalid-token noise; we just pin the lower bound.
    try testing.expect(tree.diagnostics.len >= 6);
}

test "many stray rparens at top level collect a diagnostic each" {
    var tree = try parse(testing.allocator, ")))) 1 ))");
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    try testing.expectEqual(@as(f64, 1), tree.numberOf(tree.root[0]));
    try testing.expect(tree.diagnostics.len >= 6);
}

test "mismatched delimiters report once and recover" {
    // `(a]` — open paren but close bracket. The parser must commit one
    // diagnostic ("mismatched close delimiter") and still produce a form.
    var tree = try parse(testing.allocator, "(a]");
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    try testing.expectEqual(.form, tree.tagOf(tree.root[0]));
}

test "depth at MAX_PARSE_DEPTH does not overflow" {
    // Build exactly MAX_PARSE_DEPTH-1 nested forms (one frame is reserved
    // for the .root frame) and confirm the parse completes without a
    // depth diagnostic.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const depth: usize = MAX_PARSE_DEPTH - 1;
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < depth) : (i += 1) try buf.appendSlice(a, "(x ");
    i = 0;
    while (i < depth) : (i += 1) try buf.append(a, ')');
    try buf.append(a, 0);
    const src: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    var tree = try parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
}

test "depth at MAX_PARSE_DEPTH+1 emits depth diagnostic and stops" {
    // One more form than the budget allows. The parser must emit
    // `"nesting too deep"` and terminate — without overflowing the frame
    // stack or crashing.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const depth: usize = MAX_PARSE_DEPTH + 4;
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < depth) : (i += 1) try buf.appendSlice(a, "(x ");
    i = 0;
    while (i < depth) : (i += 1) try buf.append(a, ')');
    try buf.append(a, 0);
    const src: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    var tree = try parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(tree.hasErrors());

    // At least one diagnostic with the depth message.
    var saw_depth_msg = false;
    for (tree.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "nesting too deep") != null) {
            saw_depth_msg = true;
            break;
        }
    }
    try testing.expect(saw_depth_msg);
}

test "vector depth at MAX_PARSE_DEPTH+1 emits depth diagnostic" {
    // Same depth bound applies to bracket-nested vectors. Pin so a future
    // refactor can't accidentally add a separate vector-only path.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const depth: usize = MAX_PARSE_DEPTH + 4;
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < depth) : (i += 1) try buf.append(a, '[');
    i = 0;
    while (i < depth) : (i += 1) try buf.append(a, ']');
    try buf.append(a, 0);
    const src: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    var tree = try parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
}

test "namespace split: multiple slashes keep first as separator" {
    // `splitNamespace` checks `indexOfScalar`, so the first `/` wins.
    // Pin: `a/b/c` parses as ns=`a`, head=`b/c`. (We don't validate `b/c`
    // further — the parser only splits, the validator may complain later.)
    var tree = try parse(testing.allocator, "(a/b/c)");
    defer tree.deinit();
    const f = tree.formHeader(tree.root[0]);
    try testing.expectEqualStrings("a", f.namespace.?);
    try testing.expectEqualStrings("b/c", f.head);
}

test "namespace split: leading slash is symbol-like, not namespace" {
    // `(/foo)` — leading slash means the head is `/foo`, no namespace.
    var tree = try parse(testing.allocator, "(/foo)");
    defer tree.deinit();
    const f = tree.formHeader(tree.root[0]);
    try testing.expect(f.namespace == null);
    try testing.expectEqualStrings("/foo", f.head);
}

test "namespace split: trailing slash leaves head with trailing slash" {
    // `(foo/)` — trailing slash means no namespace; head keeps the slash.
    // The parser doesn't reject this; later validation can.
    var tree = try parse(testing.allocator, "(foo/)");
    defer tree.deinit();
    const f = tree.formHeader(tree.root[0]);
    try testing.expect(f.namespace == null);
    try testing.expectEqualStrings("foo/", f.head);
}

test "qualified head with operator-like name" {
    // Reach into the schema-name space: `(plugin/+)` is a fully qualified
    // operator. Pin that the parser doesn't trip on the operator alphabet.
    var tree = try parse(testing.allocator, "(masagin/+)");
    defer tree.deinit();
    const f = tree.formHeader(tree.root[0]);
    try testing.expectEqualStrings("masagin", f.namespace.?);
    try testing.expectEqualStrings("+", f.head);
}

test "true/false/nil literal as form head is accepted" {
    // The `.true_lit / .false_lit / .nil_lit` branch in the head dispatch
    // accepts these as form heads (they read back as the literal text).
    // Pin: `(true x)` parses as a form with head text "true".
    var tree = try parse(testing.allocator, "(true 1) (false 2) (nil 3)");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(@as(usize, 3), tree.root.len);
    try testing.expectEqualStrings("true", tree.formHeader(tree.root[0]).head);
    try testing.expectEqualStrings("false", tree.formHeader(tree.root[1]).head);
    try testing.expectEqualStrings("nil", tree.formHeader(tree.root[2]).head);
}

test "form head is a number is rejected with diagnostic" {
    // `(1 x)` — the lparen dispatcher's `else` branch emits a diagnostic
    // and recovers by treating the number as the first child of an empty
    // form.
    var tree = try parse(testing.allocator, "(1 x)");
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
}

test "form head is a string is rejected with diagnostic" {
    var tree = try parse(testing.allocator, "(\"hi\" x)");
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
}

test "consecutive keywords commit the first as a flag" {
    // `:a :b 1 :c 2` — the first `:a` flushes when `:b` arrives; `:b 1`
    // pairs; `:c 2` pairs. Pin: form has 3 children — flag, kvpair, kvpair.
    var tree = try parse(testing.allocator, "(f :a :b 1 :c 2)");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const f = tree.formHeader(tree.root[0]);
    try testing.expectEqual(@as(usize, 3), f.children.len);
    try testing.expectEqual(.keyword, tree.tagOf(f.children[0]));
    try testing.expectEqual(.kvpair, tree.tagOf(f.children[1]));
    try testing.expectEqual(.kvpair, tree.tagOf(f.children[2]));
    try testing.expectEqualStrings("b", tree.kvpairHeader(f.children[1]).key);
    try testing.expectEqualStrings("c", tree.kvpairHeader(f.children[2]).key);
}

test "string with all recognized escapes round-trips to runtime bytes" {
    // The decoder maps \n \t \r \\ \" \0 to their runtime bytes.
    const src =
        \\"a\nb\tc\rd\\e\"f\0g"
    ;
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expectEqual(.string, tree.tagOf(tree.root[0]));
    const si: Ast.StringIndex = @enumFromInt(tree.dataOf(tree.root[0]).single);
    const got = tree.stringSlice(si);
    const want = "a\nb\tc\rd\\e\"f\x00g";
    try testing.expectEqualSlices(u8, want, got);
}

test "string with unrecognized escape emits diagnostic but keeps content" {
    // `\q` is unknown — the decoder emits a diagnostic and copies the `q`
    // through. Pin: tree still produced; result contains `q`.
    const src =
        \\"hello\qworld"
    ;
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
    const si: Ast.StringIndex = @enumFromInt(tree.dataOf(tree.root[0]).single);
    try testing.expectEqualStrings("helloqworld", tree.stringSlice(si));
}

test "multi-root with mixed atoms and forms" {
    // Top-level can hold any number of nodes; pin a mixed sequence.
    var tree = try parse(testing.allocator, "1 (a) [2 3] \"hi\" nil");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(@as(usize, 5), tree.root.len);
    try testing.expectEqual(.number_i64, tree.tagOf(tree.root[0]));
    try testing.expectEqual(.form, tree.tagOf(tree.root[1]));
    try testing.expectEqual(.vector, tree.tagOf(tree.root[2]));
    try testing.expectEqual(.string, tree.tagOf(tree.root[3]));
    try testing.expectEqual(.nil, tree.tagOf(tree.root[4]));
}

test "comment cluster before a form attaches all of them" {
    // Multiple comments before a node attach as ONE leading range with
    // multiple entries. Pin: 3 comments → range.len() == 3.
    const src =
        \\; one
        \\; two
        \\#| three |#
        \\(scene)
    ;
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const range = tree.leading_comments_index[tree.root[0].raw()];
    try testing.expectEqual(@as(u32, 3), range.len());
    const texts = tree.commentTexts(range);
    try testing.expectEqualStrings("; one", texts[0]);
    try testing.expectEqualStrings("; two", texts[1]);
    try testing.expectEqualStrings("#| three |#", texts[2]);
}

test "comments between sibling children attach to the next sibling" {
    // Comment lands on the second child, not the first.
    const src =
        \\(scene
        \\  1
        \\  ; before two
        \\  2)
    ;
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();
    const f = tree.formHeader(tree.root[0]);
    try testing.expectEqual(@as(usize, 2), f.children.len);
    try testing.expectEqual(@as(u32, 0), tree.leading_comments_index[f.children[0].raw()].len());
    try testing.expectEqual(@as(u32, 1), tree.leading_comments_index[f.children[1].raw()].len());
}

test "diagnostic spans point at the offending tokens" {
    // Pin: the `]` in `(a]` produces a diagnostic whose span covers the
    // `]` byte. Span integrity matters because editor surfaces use it.
    var tree = try parse(testing.allocator, "(a]");
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
    var saw_at_bracket = false;
    for (tree.diagnostics) |d| {
        if (d.span.start == 2 and d.span.end == 3) {
            saw_at_bracket = true;
            break;
        }
    }
    try testing.expect(saw_at_bracket);
}

test "spans on every node are within source bounds" {
    // Property-style: scan a fixture and assert every tree-recorded span
    // satisfies `0 <= start <= end <= source.len`.
    const src =
        \\(scene :bpm 130
        \\  (canvas :name "main" [1 2 3])
        \\  ; trailing inside
        \\  )
        \\; tree trailing
    ;
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();
    var i: u32 = 0;
    while (i < tree.nodes.len) : (i += 1) {
        const span = tree.nodes.items(.span)[i];
        try testing.expect(span.start <= span.end);
        try testing.expect(span.end <= src.len);
    }
}

test "very large valid number parses without panic" {
    // 1e308 is well within f64 range. Pin: parser doesn't crash and
    // returns a finite value.
    var tree = try parse(testing.allocator, "1e308");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const v = tree.numberOf(tree.root[0]);
    try testing.expect(std.math.isFinite(v));
    try testing.expect(v > 1e307);
}

test "out-of-range number falls back to zero with diagnostic" {
    // `1e1000` overflows f64 to inf; std.fmt.parseFloat may surface this
    // as Infinity rather than an error in Zig 0.16. Either way the parser
    // must not crash.
    var tree = try parse(testing.allocator, "1e1000");
    defer tree.deinit();
    // The contract is: tree exists, root is a number node, value is
    // either inf or 0 (depending on which branch parseFloat takes).
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    try testing.expectEqual(.number, tree.tagOf(tree.root[0]));
}

test "splitNumberAndUnit: unit only, no exponent" {
    const split = splitNumberAndUnit("123abc");
    try testing.expectEqualStrings("123", split.numeric);
    try testing.expectEqualStrings("abc", split.unit);
}

test "splitNumberAndUnit: leading minus preserved" {
    const split = splitNumberAndUnit("-3.14em");
    try testing.expectEqualStrings("-3.14", split.numeric);
    try testing.expectEqualStrings("em", split.unit);
}

test "splitNumberAndUnit: bare integer has empty unit" {
    const split = splitNumberAndUnit("0");
    try testing.expectEqualStrings("0", split.numeric);
    try testing.expectEqualStrings("", split.unit);
}

// ---------------------------------------------------------------------------
// Raw multi-line strings — `"""…"""` body taken verbatim (decoded value is
// `lexeme[3..len-3]`) and pooled like any other string.
// ---------------------------------------------------------------------------

fn parseSingleString(src: [:0]const u8) !struct { tree: Ast.Tree, content: []const u8 } {
    var tree = try parse(testing.allocator, src);
    errdefer tree.deinit();
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    try testing.expectEqual(.string, tree.tagOf(tree.root[0]));
    const si: Ast.StringIndex = @enumFromInt(tree.dataOf(tree.root[0]).single);
    return .{ .tree = tree, .content = tree.stringSlice(si) };
}

test "raw string: single-line body decodes verbatim" {
    var r = try parseSingleString("\"\"\"hello\"\"\"");
    defer r.tree.deinit();
    try testing.expect(!r.tree.hasErrors());
    try testing.expectEqualStrings("hello", r.content);
}

test "raw string: empty body decodes to empty string" {
    var r = try parseSingleString("\"\"\"\"\"\"");
    defer r.tree.deinit();
    try testing.expectEqualStrings("", r.content);
}

test "raw string: body bytes pass through verbatim — no transformation" {
    // The decoded value is exactly the bytes between the delimiters.
    // No newline stripping, no escape processing, no dedent. Form is
    // pure trivia: same source bytes between either delimiter pair
    // produce identical content.
    const src: [:0]const u8 = "\"\"\"\nhello\n\"\"\"";
    var r = try parseSingleString(src);
    defer r.tree.deinit();
    try testing.expectEqualStrings("\nhello\n", r.content);
}

test "raw string: CRLF in body is preserved (no line-ending normalisation)" {
    const src: [:0]const u8 = "\"\"\"\r\nfoo\r\n\"\"\"";
    var r = try parseSingleString(src);
    defer r.tree.deinit();
    try testing.expectEqualStrings("\r\nfoo\r\n", r.content);
}

test "raw string: backslash sequences are NOT escapes" {
    // `\n` in a raw body is two literal bytes — backslash, then `n`.
    // Pin: the parser does NOT call `decodeString` for raw strings.
    // (Note: a body cannot END with `\` immediately before the close,
    // because a `\"` followed by `""` would feed three consecutive `"`
    // into the closer. See "raw string: greedy close on body ending in
    // quote" in the lexer tests for the canonical statement of that
    // limit.)
    const src: [:0]const u8 = "\"\"\"\\n\\tX\"\"\"";
    var r = try parseSingleString(src);
    defer r.tree.deinit();
    try testing.expectEqualStrings("\\n\\tX", r.content);
}

test "raw string: embedded single and double quotes survive" {
    // Body has `"x` followed by `""y`; the closing `"""` sits at the
    // very end. All five interior `"` bytes pass through.
    const src: [:0]const u8 = "\"\"\"a\"x\"\"y\"\"\"";
    var r = try parseSingleString(src);
    defer r.tree.deinit();
    try testing.expectEqualStrings("a\"x\"\"y", r.content);
}

test "raw string: WGSL-shaped multi-line payload — content includes outer newlines" {
    // Embed a representative WGSL fragment with delimiters on their own
    // lines. The decoded value retains the leading and trailing `\n`
    // bytes; authors who want clean content put the body on the same
    // line as the opening delimiter.
    const src: [:0]const u8 =
        \\"""
        \\@vertex
        \\fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
        \\  var pos = array<vec2f, 3>(
        \\    vec2(0.0, 0.5),
        \\    vec2(-0.5, -0.5),
        \\    vec2(0.5, -0.5),
        \\  );
        \\  return vec4f(pos[i], 0.0, 1.0);
        \\}
        \\"""
    ;
    const want = "\n" ++
        \\@vertex
        \\fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
        \\  var pos = array<vec2f, 3>(
        \\    vec2(0.0, 0.5),
        \\    vec2(-0.5, -0.5),
        \\    vec2(0.5, -0.5),
        \\  );
        \\  return vec4f(pos[i], 0.0, 1.0);
        \\}
    ++ "\n";
    var r = try parseSingleString(src);
    defer r.tree.deinit();
    try testing.expect(!r.tree.hasErrors());
    try testing.expectEqualStrings(want, r.content);
}

test "raw string: as keyword pair value (single-line body, clean content)" {
    // Same-line opening pattern: content has no leading or trailing
    // newline. The recommended shape for embedding cleanly.
    const src: [:0]const u8 =
        "(shader :code \"\"\"@vertex fn vs() -> vec4f { return vec4f(0); }\"\"\")";
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const f = tree.formHeader(tree.root[0]);
    try testing.expectEqualStrings("shader", f.head);
    try testing.expectEqual(@as(usize, 1), f.children.len);
    const kp = tree.kvpairHeader(f.children[0]);
    try testing.expectEqualStrings("code", kp.key);
    try testing.expectEqual(.string, tree.tagOf(kp.value));
    const si: Ast.StringIndex = @enumFromInt(tree.dataOf(kp.value).single);
    try testing.expectEqualStrings(
        "@vertex fn vs() -> vec4f { return vec4f(0); }",
        tree.stringSlice(si),
    );
}

test "raw string: as keyword pair value (multi-line body, content has \\n)" {
    // Delimiters on their own lines: leading and trailing `\n` are
    // content. Authors choose this shape when the surrounding `\n` is
    // harmless (e.g. shader bodies, JSON-as-text payloads).
    const src: [:0]const u8 =
        \\(shader :code """
        \\@vertex fn vs() -> vec4f { return vec4f(0); }
        \\""")
    ;
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const f = tree.formHeader(tree.root[0]);
    const kp = tree.kvpairHeader(f.children[0]);
    const si: Ast.StringIndex = @enumFromInt(tree.dataOf(kp.value).single);
    try testing.expectEqualStrings(
        "\n@vertex fn vs() -> vec4f { return vec4f(0); }\n",
        tree.stringSlice(si),
    );
}

test "raw string: as vector element" {
    var tree = try parse(testing.allocator, "[\"\"\"a\"\"\" 1 \"\"\"b\"\"\"]");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const elems = tree.vectorElements(tree.root[0]);
    try testing.expectEqual(@as(usize, 3), elems.len);
    try testing.expectEqual(.string, tree.tagOf(elems[0]));
    try testing.expectEqual(.string, tree.tagOf(elems[2]));
}

test "raw string: regular and raw forms with byte-equal bodies decode identically" {
    // The AST string pool appends per-token (it does NOT dedupe by
    // content — the binary encoder owns dedup, §10). What the parser
    // must guarantee here is that the decoded byte content is the
    // same regardless of source form: `"hello"` and `"""hello"""` both
    // produce a `.string` node carrying the bytes `hello`.
    var tree = try parse(testing.allocator, "\"hello\" \"\"\"hello\"\"\"");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(@as(usize, 2), tree.root.len);
    const a_si: Ast.StringIndex = @enumFromInt(tree.dataOf(tree.root[0]).single);
    const b_si: Ast.StringIndex = @enumFromInt(tree.dataOf(tree.root[1]).single);
    try testing.expectEqualStrings("hello", tree.stringSlice(a_si));
    try testing.expectEqualStrings("hello", tree.stringSlice(b_si));
}

test "raw string: unterminated reports a diagnostic" {
    var tree = try parse(testing.allocator, "\"\"\"oops");
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
}

test "raw string: as form head is rejected (string heads not allowed)" {
    // Same as a regular `"…"` head — emits "expected head symbol".
    var tree = try parse(testing.allocator, "(\"\"\"hi\"\"\" x)");
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
}

// ---------------------------------------------------------------------------
// Long-tail raw-string scenarios — content shapes a hand-authored payload
// might exercise. With form as pure trivia, all of these reduce to the
// same property: decoded value equals the bytes between the delimiters.
// The cases below pin specific byte combinations as fixture-level evidence.
// ---------------------------------------------------------------------------

test "raw string: indentation on every body line is preserved (no auto-dedent)" {
    // No column-based dedent. Pin: leading spaces on each body line
    // survive verbatim — anyone wanting the un-indented form must do
    // it host-side.
    const src: [:0]const u8 =
        \\"""  fn vs() -> vec4f {
        \\    return vec4f(0);
        \\  }"""
    ;
    const want =
        \\  fn vs() -> vec4f {
        \\    return vec4f(0);
        \\  }
    ;
    var r = try parseSingleString(src);
    defer r.tree.deinit();
    try testing.expectEqualStrings(want, r.content);
}

test "raw string: tabs in body are preserved verbatim" {
    const src: [:0]const u8 = "\"\"\"a\tb\tc\"\"\"";
    var r = try parseSingleString(src);
    defer r.tree.deinit();
    try testing.expectEqualStrings("a\tb\tc", r.content);
}

test "raw string: UTF-8 multi-byte content survives (CJK + emoji + accented)" {
    const src: [:0]const u8 = "\"\"\"héllo 你好 🦀\"\"\"";
    var r = try parseSingleString(src);
    defer r.tree.deinit();
    try testing.expectEqualStrings("héllo 你好 🦀", r.content);
}

test "raw string: top-level standalone document — single value is the whole tree" {
    // The whole document is one raw string. Body has surrounding `\n`s
    // since delimiters sit on their own lines.
    var tree = try parse(testing.allocator, "\"\"\"\nlone\n\"\"\"");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    try testing.expectEqual(.string, tree.tagOf(tree.root[0]));
    const si: Ast.StringIndex = @enumFromInt(tree.dataOf(tree.root[0]).single);
    try testing.expectEqualStrings("\nlone\n", tree.stringSlice(si));
}

test "raw string: many siblings inside a vector each decode independently" {
    // Three raw strings in a vector. Each carries the body bytes
    // verbatim; the wrapping `\n`s belong to each individual node.
    const src: [:0]const u8 =
        \\["""
        \\one
        \\""" """
        \\two
        \\""" """
        \\three
        \\"""]
    ;
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const elems = tree.vectorElements(tree.root[0]);
    try testing.expectEqual(@as(usize, 3), elems.len);
    const want = [_][]const u8{ "\none\n", "\ntwo\n", "\nthree\n" };
    for (elems, 0..) |node, i| {
        try testing.expectEqual(.string, tree.tagOf(node));
        const si: Ast.StringIndex = @enumFromInt(tree.dataOf(node).single);
        try testing.expectEqualStrings(want[i], tree.stringSlice(si));
    }
}

test "raw string: greedy-close residue body `\"abc` decodes to two-quote-plus-content" {
    // `""""abc"""` → opener `"""`, body `"abc`, close `"""`. The body
    // bytes pass through verbatim. This pins the ASCII shape that the
    // lexer test "raw string: greedy close on body ending in quote"
    // assumes.
    const src: [:0]const u8 = "\"\"\"\"abc\"\"\"";
    var r = try parseSingleString(src);
    defer r.tree.deinit();
    try testing.expectEqualStrings("\"abc", r.content);
}

test "raw string: two-quote prefix in body decodes verbatim" {
    // Body has `""prefix`. Two `"`s alone never close — three required.
    const src: [:0]const u8 = "\"\"\"\"\"prefix\"\"\"";
    var r = try parseSingleString(src);
    defer r.tree.deinit();
    try testing.expectEqualStrings("\"\"prefix", r.content);
}

test "raw string: kvpair value containing structural sigils round-trips inert" {
    // A raw body packed with bytes the SJON grammar normally reserves.
    // Pin: nothing in the body is reinterpreted — the value comes out
    // as the literal source byte-for-byte (delimiters on their own
    // lines means leading and trailing `\n` are part of content).
    const src: [:0]const u8 =
        \\(blob :payload """
        \\(this looks like a form)
        \\:keyword [vector] ; comment-shaped
        \\#| block-shaped |#
        \\""")
    ;
    const want = "\n" ++
        \\(this looks like a form)
        \\:keyword [vector] ; comment-shaped
        \\#| block-shaped |#
    ++ "\n";
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    const f = tree.formHeader(tree.root[0]);
    const kp = tree.kvpairHeader(f.children[0]);
    const si: Ast.StringIndex = @enumFromInt(tree.dataOf(kp.value).single);
    try testing.expectEqualStrings(want, tree.stringSlice(si));
}

test "raw string: decoded content equals slice between delimiters (property)" {
    // The contract, said directly: for any valid raw-string token, the
    // decoded value is exactly `lexeme[3..len-3]`. A handful of byte
    // shapes covering the mixed-newline / whitespace / control-byte
    // cases the original strip-once tests probed.
    const cases = [_]struct { src: [:0]const u8, want: []const u8 }{
        .{ .src = "\"\"\"\"\"\"", .want = "" },
        .{ .src = "\"\"\"a\"\"\"", .want = "a" },
        .{ .src = "\"\"\"\n\"\"\"", .want = "\n" },
        .{ .src = "\"\"\"\r\n\"\"\"", .want = "\r\n" },
        .{ .src = "\"\"\"\n\n\"\"\"", .want = "\n\n" },
        .{ .src = "\"\"\"\rfoo\r\"\"\"", .want = "\rfoo\r" },
        .{ .src = "\"\"\"\nABC\r\"\"\"", .want = "\nABC\r" },
        .{ .src = "\"\"\"hello   \n\"\"\"", .want = "hello   \n" },
        .{ .src = "\"\"\"   \nhello\"\"\"", .want = "   \nhello" },
        .{ .src = "\"\"\"foo\n\n\n\"\"\"", .want = "foo\n\n\n" },
        .{ .src = "\"\"\"\n\n\n\"\"\"", .want = "\n\n\n" },
    };
    for (cases) |c| {
        var r = try parseSingleString(c.src);
        defer r.tree.deinit();
        try testing.expectEqualStrings(c.want, r.content);
    }
}

// ---------------------------------------------------------------------------
// Diagnostic-path attribution. Every parser diagnostic carries the same
// semantic path semantics as validator diagnostics: form heads, kvpair
// keys, vector element indices. Cross-host conformance and editor
// surfaces both depend on this; tests pin the contract for each emit
// site so a future refactor can't drift the path shape silently.
// ---------------------------------------------------------------------------

fn findDiag(tree: *const Ast.Tree, msg_substr: []const u8) ?*const Ast.Diagnostic {
    for (tree.diagnostics) |*d| {
        if (std.mem.indexOf(u8, d.message, msg_substr) != null) return d;
    }
    return null;
}

fn expectPath(d: *const Ast.Diagnostic, want: []const []const u8) !void {
    try testing.expectEqual(want.len, d.path.len);
    for (want, d.path) |w, got| try testing.expectEqualStrings(w, got);
}

test "diag path: empty form `()` inside parent points at slot 0" {
    var tree = try parse(testing.allocator, "(parent ())");
    defer tree.deinit();
    const d = findDiag(&tree, "empty form") orelse return error.MissingDiagnostic;
    try expectPath(d, &.{ "parent", "0" });
}

test "diag path: bad-head form `(123 …)` inside parent points at slot 0" {
    var tree = try parse(testing.allocator, "(parent (123 :x 1))");
    defer tree.deinit();
    const d = findDiag(&tree, "expected head symbol") orelse return error.MissingDiagnostic;
    try expectPath(d, &.{ "parent", "0" });
}

test "diag path: bad escape in kvpair value points at the key" {
    var tree = try parse(testing.allocator, "(parent :k \"bad\\q\")");
    defer tree.deinit();
    const d = findDiag(&tree, "unrecognized string escape") orelse return error.MissingDiagnostic;
    try expectPath(d, &.{ "parent", "k" });
}

test "diag path: bad escape in deeply nested kvpair value" {
    var tree = try parse(testing.allocator, "(parent (child :k \"bad\\q\"))");
    defer tree.deinit();
    const d = findDiag(&tree, "unrecognized string escape") orelse return error.MissingDiagnostic;
    try expectPath(d, &.{ "parent", "child", "k" });
}

test "diag path: bad escape in vector element points at vector slot + index" {
    var tree = try parse(testing.allocator, "(parent [\"ok\" \"bad\\q\"])");
    defer tree.deinit();
    const d = findDiag(&tree, "unrecognized string escape") orelse return error.MissingDiagnostic;
    // [parent, "0", "1"]: vector is parent's first positional, bad
    // string is element 1 of the vector.
    try expectPath(d, &.{ "parent", "0", "1" });
}

test "diag path: top-level kvpair carries empty path" {
    var tree = try parse(testing.allocator, ":k v");
    defer tree.deinit();
    const d = findDiag(&tree, "keyword pair at top level") orelse return error.MissingDiagnostic;
    try expectPath(d, &.{});
}

test "diag path: stray top-level rparen carries empty path" {
    var tree = try parse(testing.allocator, ") 42");
    defer tree.deinit();
    const d = findDiag(&tree, "unexpected close delimiter") orelse return error.MissingDiagnostic;
    try expectPath(d, &.{});
}

test "diag path: mismatched close `(parent (a]` reports at the inner form" {
    var tree = try parse(testing.allocator, "(parent (a])");
    defer tree.deinit();
    const d = findDiag(&tree, "mismatched close delimiter") orelse return error.MissingDiagnostic;
    try expectPath(d, &.{ "parent", "a" });
}

test "diag path: unclosed inner form reports at the inner form's path" {
    var tree = try parse(testing.allocator, "(parent (a");
    defer tree.deinit();
    // First-emitted unclosed is the innermost (a — path = [parent, a].
    // Outer parent emits second with path = [parent].
    try testing.expect(tree.diagnostics.len >= 2);
    try expectPath(&tree.diagnostics[0], &.{ "parent", "a" });
    try expectPath(&tree.diagnostics[1], &.{"parent"});
}

test "diag path: depth-overflow lparen path is parent's slot" {
    // Build MAX_PARSE_DEPTH+1 nested forms; the over-deep `(` lives in
    // the slot after the previous successful nesting.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const depth: usize = MAX_PARSE_DEPTH + 1;
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < depth) : (i += 1) try buf.appendSlice(a, "(x ");
    i = 0;
    while (i < depth) : (i += 1) try buf.append(a, ')');
    try buf.append(a, 0);
    const src: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    var tree = try parse(testing.allocator, src);
    defer tree.deinit();
    const d = findDiag(&tree, "nesting too deep") orelse return error.MissingDiagnostic;
    // The over-deep `(` is the first positional of the deepest accepted
    // `x` frame. Path should end at "0" inside a chain of "x" steps.
    try testing.expect(d.path.len >= 2);
    try testing.expectEqualStrings("0", d.path[d.path.len - 1]);
    try testing.expectEqualStrings("x", d.path[d.path.len - 2]);
}

test "diag path: integration fixture with multiple distinct paths" {
    var tree = try parse(testing.allocator, "(root (child :k \"a\\q\") [\"b\" \"c\\q\"])");
    defer tree.deinit();
    // Two diagnostics expected: one for `\q` in the kvpair value at
    // [root, child, k], one for `\q` in the vector element at
    // [root, "1", "1"] (vector is root's second positional after `child`).
    var d1: ?*const Ast.Diagnostic = null;
    var d2: ?*const Ast.Diagnostic = null;
    for (tree.diagnostics) |*d| {
        if (std.mem.indexOf(u8, d.message, "unrecognized string escape") == null) continue;
        if (d1 == null) {
            d1 = d;
        } else if (d2 == null) {
            d2 = d;
            break;
        }
    }
    try testing.expect(d1 != null);
    try testing.expect(d2 != null);
    // Diagnostics emit in source order: kvpair value first, then vector element.
    try expectPath(d1.?, &.{ "root", "child", "k" });
    try expectPath(d2.?, &.{ "root", "1", "1" });
}

test "diag path: vector element bad escape at root carries vector index" {
    var tree = try parse(testing.allocator, "[\"a\" \"b\\q\"]");
    defer tree.deinit();
    const d = findDiag(&tree, "unrecognized string escape") orelse return error.MissingDiagnostic;
    // Top-level vectors don't get a positional step (root's parent_step
    // is empty); element index 1 is the only step.
    try expectPath(d, &.{"1"});
}

test "diag path: kvpair value form-with-head includes head step" {
    // When a kvpair value is itself a form, the form's head appears in
    // the path. Validator semantics: kvpair → key, then form → head.
    var tree = try parse(testing.allocator, "(parent :slot (child :k \"x\\q\"))");
    defer tree.deinit();
    const d = findDiag(&tree, "unrecognized string escape") orelse return error.MissingDiagnostic;
    try expectPath(d, &.{ "parent", "slot", "child", "k" });
}

// ---------------------------------------------------------------------------
// Per-module corner sweep (plan #3): boundary depth, head-shape errors,
// numeric precision, lexer-error propagation. Each test pins a path the
// existing happy-path coverage skips so the parser's recovery contract
// remains visible if it shifts.
// ---------------------------------------------------------------------------

test "depth at exactly MAX_PARSE_DEPTH (1024 forms) emits depth diagnostic" {
    // Existing coverage tests MAX-1 (works) and MAX+4 (fails); the exact
    // boundary is the byte where the `>=` check first fires. Since the
    // parser reserves one frame for `.root`, MAX nested user forms push
    // total frame count to MAX+1 — the open-paren on the MAXth form
    // trips the cap. Pin so a future off-by-one in either direction is
    // caught immediately.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const depth: usize = MAX_PARSE_DEPTH;
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < depth) : (i += 1) try buf.appendSlice(a, "(x ");
    i = 0;
    while (i < depth) : (i += 1) try buf.append(a, ')');
    try buf.append(a, 0);
    const src: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    var tree = try parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
    var saw_depth_msg = false;
    for (tree.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "nesting too deep") != null) {
            saw_depth_msg = true;
            break;
        }
    }
    try testing.expect(saw_depth_msg);
}

test "form head as keyword `(:kw …)` is rejected with diagnostic" {
    // The lparen-dispatch's `else` branch covers any non-symbol head.
    // Coverage exists for number / string / raw_string heads; pin the
    // keyword case explicitly because it exercises a different makeLeaf
    // arm (the keyword leaf attaches to the empty-headed form's body).
    // Recovery contract: tree still parses, diagnostic emitted, the
    // keyword surfaces as a child of an empty-named form.
    var tree = try parse(testing.allocator, "(:kw 1)");
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    try testing.expectEqual(.form, tree.tagOf(tree.root[0]));
    const f = tree.formHeader(tree.root[0]);
    try testing.expectEqualStrings("", f.head);
    var saw_msg = false;
    for (tree.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "expected head symbol") != null) {
            saw_msg = true;
            break;
        }
    }
    try testing.expect(saw_msg);
}

test "parse: 1e308 is finite f64; 1e309 overflows to inf without diagnostic" {
    // `std.fmt.parseFloat` returns Infinity (not an error) for any value
    // outside f64 range in Zig 0.16. Pin both: 1e308 is the largest
    // finite double exponent (≈ 1.0e308), and 1e309 silently saturates
    // to inf. The parser does not flag overflow — by design, since SJON
    // values aren't intrinsically bounded.
    {
        var tree = try parse(testing.allocator, "1e308");
        defer tree.deinit();
        try testing.expect(!tree.hasErrors());
        try testing.expectEqual(.number, tree.tagOf(tree.root[0]));
        try testing.expect(std.math.isFinite(tree.numberOf(tree.root[0])));
    }
    {
        var tree = try parse(testing.allocator, "1e309");
        defer tree.deinit();
        try testing.expect(!tree.hasErrors());
        try testing.expectEqual(.number, tree.tagOf(tree.root[0]));
        const v = tree.numberOf(tree.root[0]);
        // Either +inf (parseFloat saturates) or 0 (parseFloat errors and
        // we fall back, then the `out-of-range falls back to zero`
        // branch fires). Both represent "overflow without crash".
        try testing.expect(std.math.isInf(v) or v == 0);
    }
}

test "parse: 16-digit integer survives via the exact-integer path" {
    // `9_999_999_999_999_999` exceeds 2^53 (the f64 safe-integer ceiling)
    // but fits in i64, so the parser now stores it on `.number_i64` with
    // no precision loss. Before the exact-integer path this literal
    // rounded to 1.0e16; the new tag preserves every digit.
    var tree = try parse(testing.allocator, "9999999999999999");
    defer tree.deinit();
    try testing.expect(!tree.hasErrors());
    try testing.expectEqual(.number_i64, tree.tagOf(tree.root[0]));
    try testing.expectEqual(@as(i64, 9_999_999_999_999_999), tree.numberI64Of(tree.root[0]));
}

test "parse: `\\u{1F600}` falls into unrecognized-escape recovery (lexer-permissive)" {
    // The lexer's `.string_escape` accepts any byte after `\`; the
    // parser's `decodeString` recognises only `n / t / r / \" / \\ / 0`.
    // Anything else (including `u`) emits "unrecognized string escape"
    // and copies the next byte verbatim. So `\u{1F600}` decodes to the
    // literal text `u{1F600}` — NOT a Unicode codepoint. Pin so a
    // future `\u{...}` decoder lands with an explicit migration story
    // (and this test must change in lockstep).
    const src =
        \\"\u{1F600}"
    ;
    var tree = try parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
    try testing.expectEqual(.string, tree.tagOf(tree.root[0]));
    const si: Ast.StringIndex = @enumFromInt(tree.dataOf(tree.root[0]).single);
    try testing.expectEqualStrings("u{1F600}", tree.stringSlice(si));
}

test "lexer-error propagation: `.invalid` byte mid-form emits diagnostic, no panic" {
    // The lexer never aborts; bytes outside the alphabet emit `.invalid`
    // tokens. The parser's `.invalid` branch turns them into "invalid
    // token" diagnostics and continues. Pin: `(\xFE foo)` parses to a
    // form (recovery), one or more diagnostics, no crash.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "(");
    try buf.append(a, 0xFE); // UTF-8 continuation byte at top-level → invalid
    try buf.appendSlice(a, " foo)");
    try buf.append(a, 0);
    const src: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];

    var tree = try parse(testing.allocator, src);
    defer tree.deinit();
    try testing.expect(tree.hasErrors());
    var saw_invalid = false;
    for (tree.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "invalid token") != null or
            std.mem.indexOf(u8, d.message, "expected head symbol") != null)
        {
            saw_invalid = true;
        }
    }
    try testing.expect(saw_invalid);
}
