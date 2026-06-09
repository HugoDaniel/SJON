const std = @import("std");
const Allocator = std.mem.Allocator;
const Lexer = @import("Lexer.zig");
const Ast = @import("Ast.zig");
const Date = @import("Date.zig");
const Time = @import("Time.zig");

const Token = Lexer.Token;
const Tag = Token.Tag;
const Span = Ast.Span;

pub const MAX_PARSE_DEPTH: u32 = 1024;

const Frame = struct {
    kind: Kind,
    children: std.ArrayList(ChildEntry),
    pending: ?PendingKey = null,
    pending_comments: std.ArrayList(Ast.Comment) = .empty,
    parent_step: []const u8 = "",
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

const ParseState = struct {
    gpa: Allocator,
    a: Allocator,
    source: [:0]const u8,
    b: *Ast.TreeBuilder,
    frames: *std.ArrayList(Frame),
    diagnostics: *std.ArrayList(Ast.Diagnostic),
    lex: *Lexer,
};

const LoopAction = enum { keep_going, stop };

const RootFreeze = struct {
    root_indices: []Ast.NodeIndex,
    tree_trailing_range: Ast.CommentRange,
};

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

fn runParseLoop(st: *ParseState) Allocator.Error!void {
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
    try top.pending_comments.append(st.gpa, .{
        .span = .{ .start = tok.start, .end = tok.end },
        .text = try st.a.dupe(u8, st.source[tok.start..tok.end]),
        .kind = if (tok.tag == .comment_line) .line else .block,
    });
    return .keep_going;
}

fn handleLParen(st: *ParseState, tok: Token) Allocator.Error!LoopAction {
    if (st.frames.items.len >= MAX_PARSE_DEPTH) {
        try emit(st.diagnostics, st.a, st.frames.items, tok, "nesting too deep", true);
        return .stop;
    }
    const head_tok = nextSignificant(st.lex);
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
            try emit(st.diagnostics, st.a, st.frames.items, .{
                .tag = .keyword,
                .start = kp.key_span.start,
                .end = kp.key_span.end,
            }, "keyword pair at top level (expected inside a form)", false);
            const kw_si = try st.b.addString(kp.key);
            const kw_idx = try st.b.appendNode(.{
                .tag = .keyword,
                .span = kp.key_span,
                .data = .{ .single = kw_si.raw() },
            });
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

            if (split.unit.len > 0) {
                const v = std.fmt.parseFloat(f64, cleaned) catch {
                    try emit(diagnostics, a, frames, tok, "invalid number literal", true);
                    return try b.appendNode(.{
                        .tag = .number,
                        .span = span,
                        .data = .{ .immediate = @bitCast(@as(f64, 0)) },
                    });
                };
                const unit_si = try b.addString(split.unit);
                const bits: u64 = @bitCast(v);
                const hdr_at: u32 = @intCast(b.extra_data.items.len);
                try b.extra_data.appendSlice(b.a, &.{
                    @truncate(bits),
                    @truncate(bits >> 32),
                    unit_si.raw(),
                });
                return try b.appendNode(.{
                    .tag = .number_with_unit,
                    .span = span,
                    .data = .{ .single = hdr_at },
                });
            }

            if (!hasFloatShape(cleaned)) {
                if (std.fmt.parseInt(i64, cleaned, 10)) |iv| {
                    return try b.appendNode(.{
                        .tag = .number_i64,
                        .span = span,
                        .data = .{ .immediate = @bitCast(iv) },
                    });
                } else |err| switch (err) {
                    error.Overflow => {
                        if (cleaned.len > 0 and cleaned[0] != '-') {
                            if (std.fmt.parseInt(u64, cleaned, 10)) |uv| {
                                return try b.appendNode(.{
                                    .tag = .number_u64,
                                    .span = span,
                                    .data = .{ .immediate = uv },
                                });
                            } else |_| {}
                        }
                        try emitOverflow(diagnostics, a, frames, tok);
                    },
                    error.InvalidCharacter => {},
                }
            }

            const v = std.fmt.parseFloat(f64, cleaned) catch {
                try emit(diagnostics, a, frames, tok, "invalid number literal", true);
                return try b.appendNode(.{
                    .tag = .number,
                    .span = span,
                    .data = .{ .immediate = @bitCast(@as(f64, 0)) },
                });
            };
            return try b.appendNode(.{
                .tag = .number,
                .span = span,
                .data = .{ .immediate = @bitCast(v) },
            });
        },
        .string => {
            const slice = source[tok.start..tok.end];
            std.debug.assert(slice.len >= 2 and slice[0] == '"' and slice[slice.len - 1] == '"');
            const inner = slice[1 .. slice.len - 1];
            const decoded = try decodeString(a, inner, tok, diagnostics, frames);
            const si = try b.addString(decoded);
            return try b.appendNode(.{
                .tag = .string,
                .span = span,
                .data = .{ .single = si.raw() },
            });
        },
        .raw_string => {
            const slice = source[tok.start..tok.end];
            std.debug.assert(slice.len >= 6);
            std.debug.assert(std.mem.startsWith(u8, slice, "\"\"\""));
            std.debug.assert(std.mem.endsWith(u8, slice, "\"\"\""));
            const body = slice[3 .. slice.len - 3];
            const si = try b.addString(body);
            return try b.appendNode(.{
                .tag = .string,
                .span = span,
                .data = .{ .single = si.raw() },
            });
        },
        .true_lit => return try b.appendNode(.{ .tag = .boolean_true, .span = span, .data = .{ .immediate = 0 } }),
        .false_lit => return try b.appendNode(.{ .tag = .boolean_false, .span = span, .data = .{ .immediate = 0 } }),
        .nil_lit => return try b.appendNode(.{ .tag = .nil, .span = span, .data = .{ .immediate = 0 } }),
        .date => {
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
                const default = Date.init(1, 1, 1) catch unreachable;
                return try b.appendNode(.{
                    .tag = .date,
                    .span = span,
                    .data = .{ .immediate = default.pack() },
                });
            };
            return try b.appendNode(.{
                .tag = .date,
                .span = span,
                .data = .{ .immediate = parsed.pack() },
            });
        },
        .time => {
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
                const default = Time.init(0, 0, 0, 0) catch unreachable;
                return try b.appendNode(.{
                    .tag = .time,
                    .span = span,
                    .data = .{ .immediate = default.pack() },
                });
            };
            return try b.appendNode(.{
                .tag = .time,
                .span = span,
                .data = .{ .immediate = parsed.pack() },
            });
        },
        .symbol => {
            const slice = source[tok.start..tok.end];
            const si = try b.addString(slice);
            return try b.appendNode(.{
                .tag = .symbol,
                .span = span,
                .data = .{ .single = si.raw() },
            });
        },
        .keyword => {
            const slice = source[tok.start..tok.end];
            std.debug.assert(slice.len >= 1 and slice[0] == ':');
            const si = try b.addString(slice[1..]);
            return try b.appendNode(.{
                .tag = .keyword,
                .span = span,
                .data = .{ .single = si.raw() },
            });
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
    const key_si = try b.addString(pk.key);
    const idx = try b.appendNode(.{
        .tag = .keyword,
        .span = pk.span,
        .data = .{ .single = key_si.raw() },
    });
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
            return try b.addVector(elems.items, .{ .start = v.open_span.start, .end = end });
        },
        .root => unreachable,
    }
}

fn nextSignificant(lex: *Lexer) Token {
    while (true) {
        const t = lex.next();
        switch (t.tag) {
            .comment_line, .comment_block => continue,
            else => return t,
        }
    }
}

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

fn hasFloatShape(cleaned: []const u8) bool {
    for (cleaned) |c| {
        if (c == '.' or c == 'e' or c == 'E') return true;
    }
    return false;
}

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

pub fn parseNumberAs(
    comptime T: type,
    tree: *const Ast.Tree,
    gpa: Allocator,
    idx: Ast.NodeIndex,
) error{ OutOfMemory, Overflow, InvalidCharacter }!T {
    const tag = tree.tagOf(idx);
    std.debug.assert(tag == .number or tag == .number_i64 or
        tag == .number_u64 or tag == .number_with_unit);

    const span = tree.spanOf(idx);
    const slice = tree.source[span.start..span.end];
    const numeric = splitNumberAndUnit(slice).numeric;

    const buf = try gpa.alloc(u8, numeric.len);
    defer gpa.free(buf);
    var n: usize = 0;
    for (numeric) |c| {
        if (c == '_') continue;
        buf[n] = c;
        n += 1;
    }
    const cleaned = buf[0..n];
    std.debug.assert(cleaned.len > 0);

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

const testing = std.testing;

fn parseSingleString(src: [:0]const u8) !struct { tree: Ast.Tree, content: []const u8 } {
    var tree = try parse(testing.allocator, src);
    errdefer tree.deinit();
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    try testing.expectEqual(.string, tree.tagOf(tree.root[0]));
    const si: Ast.StringIndex = @enumFromInt(tree.dataOf(tree.root[0]).single);
    return .{ .tree = tree, .content = tree.stringSlice(si) };
}

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
