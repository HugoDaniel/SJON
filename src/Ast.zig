const std = @import("std");
const Allocator = std.mem.Allocator;
const Date = @import("Date.zig");
const Time = @import("Time.zig");

pub const Span = struct {
    start: u32,
    end: u32,
};

pub const Bytes = struct {
    gpa: Allocator,
    data: []u8,

    pub fn deinit(self: *const Bytes) void {
        self.gpa.free(self.data);
    }
};

pub const NumberValue = struct {
    value: f64,
    unit: ?[]const u8 = null,
};

pub const Comment = struct {
    span: Span,
    text: []const u8,
    kind: Kind,

    pub const Kind = enum { line, block };
};

pub const Diagnostic = struct {
    span: Span,
    message: []const u8,
    severity: Severity = .err,
    code: Code = .unspecified,
    path: []const []const u8 = &.{},

    pub const Severity = enum { err, warning };

    pub const Code = enum {
        unspecified,

        unknown_form,
        unknown_key,
        ambiguous_form,
        ambiguous_expr,
        ambiguous_element_kind,
        unknown_element_kind,
        recursion_depth,
        not_cross_ref,
        duplicate_cross_ref_target,
        unknown_cross_ref_target,
        ambiguous_cross_ref_target,
        cross_ref_name_key_unknown,
        acyclic_without_self_edge,
        cyclic_cross_ref,
        unknown_cross_ref_scope,
        ambiguous_cross_ref_scope,
        cross_ref_outside_scope,

        duplicate_key,
        too_many_keys,
        missing_required_key,
        positional_not_allowed,
        expr_kvpair_not_allowed,
        missing_discriminant_key,
        unknown_discriminant_value,
        discriminant_not_closed_enum,
        variant_key_collision,
        mutually_exclusive_keys_present,
        multiple_defaulted_alternatives_in_group,
        required_one_of_missing,
        exclusive_group_invalid,

        wrong_underlying,
        vector_length_mismatch,
        unit_required,
        unit_not_allowed,
        not_member,
        deprecated_member,
        not_head_member,
        union_no_branch_matched,
        nested_union,

        arity_mismatch,
        expr_type_mismatch,
        expr_unknown_label,
        expr_duplicate_label,
        expr_missing_label,
        expr_mixed_args,

        invalid_manifest,

        unresolved_plugin,
        plugin_version_mismatch,
        plugin_hash_mismatch,

        duplicate_plugin_name,
        plugin_name_mismatch,
        project_file_not_found,

        plugin_abi_mismatch,
        plugin_export_missing,
        plugin_import_forbidden,
        plugin_wasm_required,
        plugin_describe_invalid,
        plugin_func_trapped,
        plugin_func_result_type,
        plugin_func_failed,
        plugin_func_alloc_failed,

        default_eval_failed,

        lowering_hook_missing,
        lowering_hook_failed,
        lowering_produced_invalid_head,
        lowering_produced_lowerable_head,
        lowering_output_too_large,

        number_overflow_exact_integer,

        date_invalid_year,
        date_invalid_month,
        date_invalid_day,

        time_invalid_hour,
        time_invalid_minute,
        time_invalid_second,

        number_below_min,
        number_above_max,
        number_at_or_below_exclusive_min,
        number_at_or_above_exclusive_max,
        number_not_integer,
        numeric_bound_unit_mismatch,
        numeric_bounds_invalid,

        string_too_short,
        string_too_long,
        string_format_mismatch,
        string_pattern_mismatch,
        string_pattern_unsupported,
        string_bounds_invalid,

        exclusive_bundle_partial,
        exclusive_bundle_collision,

        plugin_wasm_resolved_outside_package,
        plugin_wasm_self_hash_malformed,
        plugin_wasm_self_hash_mismatch,
        license_unrecognized,
        too_many_keywords,
        sjon_format_unsupported,

        unknown_project_key,
        glob_no_matches,
        pin_disagreement,
        project_documents_outside_root,

        lockfile_drift,
        lockfile_missing_entry,
        lockfile_orphan,
        lockfile_version_unsupported,
        lockfile_corrupt,
        not_flag_member,
        lowering_cycle,
        lowering_target_plugin_absent,
        duplicate_positional_flag,
        lowering_nested_lowerable,
        unit_forbidden,
        vector_too_short,
        vector_too_long,
        vector_bounds_invalid,
        repr_out_of_range,
        unknown_local_form,
    };
};

pub const NodeIndex = enum(u32) {
    invalid = std.math.maxInt(u32),
    _,

    pub inline fn from(i: u32) NodeIndex {
        std.debug.assert(i != std.math.maxInt(u32));
        return @enumFromInt(i);
    }
    pub inline fn raw(self: NodeIndex) u32 {
        return @intFromEnum(self);
    }
    pub inline fn isValid(self: NodeIndex) bool {
        return self != .invalid;
    }
};

pub const StringIndex = enum(u32) {
    invalid = std.math.maxInt(u32),
    _,

    pub inline fn from(i: u32) StringIndex {
        std.debug.assert(i != std.math.maxInt(u32));
        return @enumFromInt(i);
    }
    pub inline fn raw(self: StringIndex) u32 {
        return @intFromEnum(self);
    }
    pub inline fn isValid(self: StringIndex) bool {
        return self != .invalid;
    }
};

pub const ExtraIndex = enum(u32) {
    invalid = std.math.maxInt(u32),
    _,

    pub inline fn from(i: u32) ExtraIndex {
        std.debug.assert(i != std.math.maxInt(u32));
        return @enumFromInt(i);
    }
    pub inline fn raw(self: ExtraIndex) u32 {
        return @intFromEnum(self);
    }
};

pub const Mode = enum {
    canonical,
    compact,
    full,
};

pub const ValueKind = enum(u8) {
    nil,
    boolean,
    number,
    number_with_unit,
    date,
    time,
    string,
    keyword,
    symbol,
    vector,
    form,
};

pub const Tag = enum(u8) {
    form,
    vector,
    kvpair,
    number,
    number_i64,
    number_u64,
    number_with_unit,
    string,
    keyword,
    symbol,
    boolean_true,
    boolean_false,
    nil,
    date,
    time,

    pub fn toValueKind(self: Tag) ValueKind {
        return switch (self) {
            .form => .form,
            .vector => .vector,
            .kvpair => unreachable,
            .number, .number_i64, .number_u64 => .number,
            .number_with_unit => .number_with_unit,
            .string => .string,
            .keyword => .keyword,
            .symbol => .symbol,
            .boolean_true, .boolean_false => .boolean,
            .nil => .nil,
            .date => .date,
            .time => .time,
        };
    }
};

pub const Data = extern union {
    immediate: u64,
    pair: extern struct { a: u32, b: u32 },
    single: u32,
};

pub const Node = struct {
    tag: Tag,
    span: Span,
    data: Data,
};

pub const CommentRange = packed struct {
    start: u32,
    end: u32,

    pub const empty: CommentRange = .{ .start = 0, .end = 0 };

    pub inline fn isEmpty(self: CommentRange) bool {
        return self.start == self.end;
    }
    pub inline fn len(self: CommentRange) u32 {
        std.debug.assert(self.end >= self.start);
        return self.end - self.start;
    }
};

comptime {
    std.debug.assert(@sizeOf(Data) == 8);
    std.debug.assert(@sizeOf(CommentRange) == 8);
    std.debug.assert(@sizeOf(Tag) == 1);
    std.debug.assert(@sizeOf(Span) == 8);
}

pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    source: [:0]const u8,

    nodes: std.MultiArrayList(Node).Slice,

    extra_data: []const u32,

    strings: []const u8,
    string_index: []const u32,

    root: []const NodeIndex,

    leading_comments_index: []const CommentRange,
    trailing_comments_index: []const CommentRange,

    comments: std.MultiArrayList(Comment).Slice,

    tree_trailing_comments: CommentRange,

    diagnostics: []const Diagnostic,

    pub fn deinit(self: *Tree) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *Tree) Allocator {
        return self.arena.allocator();
    }

    pub fn hasErrors(self: *const Tree) bool {
        for (self.diagnostics) |d| if (d.severity == .err) return true;
        return false;
    }

    pub fn tagOf(self: *const Tree, idx: NodeIndex) Tag {
        return self.nodes.items(.tag)[idx.raw()];
    }
    pub fn spanOf(self: *const Tree, idx: NodeIndex) Span {
        return self.nodes.items(.span)[idx.raw()];
    }
    pub fn dataOf(self: *const Tree, idx: NodeIndex) Data {
        return self.nodes.items(.data)[idx.raw()];
    }

    pub fn stringSlice(self: *const Tree, s: StringIndex) []const u8 {
        const i = s.raw();
        std.debug.assert(i + 1 < self.string_index.len);
        return self.strings[self.string_index[i]..self.string_index[i + 1]];
    }

    pub fn formHeader(self: *const Tree, idx: NodeIndex) FormHeader {
        std.debug.assert(self.tagOf(idx) == .form);
        const hdr = self.dataOf(idx).single;
        const head_idx: StringIndex = @enumFromInt(self.extra_data[hdr]);
        const ns_raw: u32 = self.extra_data[hdr + 1];
        const ns_idx: StringIndex = @enumFromInt(ns_raw);
        const head_span = Span{
            .start = self.extra_data[hdr + 2],
            .end = self.extra_data[hdr + 3],
        };
        const count = self.extra_data[hdr + 4];
        const children = @as([*]const NodeIndex, @ptrCast(self.extra_data[hdr + 5 ..].ptr))[0..count];
        return .{
            .head = self.stringSlice(head_idx),
            .namespace = if (ns_idx == .invalid) null else self.stringSlice(ns_idx),
            .head_span = head_span,
            .children = children,
        };
    }

    pub fn vectorElements(self: *const Tree, idx: NodeIndex) []const NodeIndex {
        std.debug.assert(self.tagOf(idx) == .vector);
        const d = self.dataOf(idx).pair;
        std.debug.assert(d.b >= d.a);
        return @as([*]const NodeIndex, @ptrCast(self.extra_data[d.a..d.b].ptr))[0 .. d.b - d.a];
    }

    pub fn kvpairHeader(self: *const Tree, idx: NodeIndex) KvPairHeader {
        std.debug.assert(self.tagOf(idx) == .kvpair);
        const hdr = self.dataOf(idx).single;
        const key_idx: StringIndex = @enumFromInt(self.extra_data[hdr]);
        const value_idx: NodeIndex = @enumFromInt(self.extra_data[hdr + 1]);
        return .{
            .key = self.stringSlice(key_idx),
            .value = value_idx,
            .key_span = .{
                .start = self.extra_data[hdr + 2],
                .end = self.extra_data[hdr + 3],
            },
        };
    }

    pub fn numberOf(self: *const Tree, idx: NodeIndex) f64 {
        const d = self.dataOf(idx).immediate;
        return switch (self.tagOf(idx)) {
            .number => @bitCast(d),
            .number_i64 => @floatFromInt(@as(i64, @bitCast(d))),
            .number_u64 => @floatFromInt(d),
            else => unreachable,
        };
    }

    pub fn numberI64Of(self: *const Tree, idx: NodeIndex) i64 {
        std.debug.assert(self.tagOf(idx) == .number_i64);
        return @bitCast(self.dataOf(idx).immediate);
    }

    pub fn numberU64Of(self: *const Tree, idx: NodeIndex) u64 {
        std.debug.assert(self.tagOf(idx) == .number_u64);
        return self.dataOf(idx).immediate;
    }

    pub fn dateOf(self: *const Tree, idx: NodeIndex) Date {
        std.debug.assert(self.tagOf(idx) == .date);
        return Date.unpack(self.dataOf(idx).immediate);
    }

    pub fn timeOf(self: *const Tree, idx: NodeIndex) Time {
        std.debug.assert(self.tagOf(idx) == .time);
        return Time.unpack(self.dataOf(idx).immediate);
    }

    pub fn numberWithUnitOf(self: *const Tree, idx: NodeIndex) NumberWithUnit {
        std.debug.assert(self.tagOf(idx) == .number_with_unit);
        const hdr = self.dataOf(idx).single;
        std.debug.assert(hdr + 2 < self.extra_data.len);
        const lo: u64 = self.extra_data[hdr];
        const hi: u64 = self.extra_data[hdr + 1];
        const bits: u64 = lo | (hi << 32);
        const unit_idx: StringIndex = @enumFromInt(self.extra_data[hdr + 2]);
        const unit = self.stringSlice(unit_idx);
        std.debug.assert(unit.len > 0);
        return .{ .value = @bitCast(bits), .unit = unit };
    }

    pub fn symbolText(self: *const Tree, idx: NodeIndex) []const u8 {
        std.debug.assert(self.tagOf(idx) == .symbol);
        const si: StringIndex = @enumFromInt(self.dataOf(idx).single);
        return self.stringSlice(si);
    }

    pub fn keywordText(self: *const Tree, idx: NodeIndex) []const u8 {
        std.debug.assert(self.tagOf(idx) == .keyword);
        const si: StringIndex = @enumFromInt(self.dataOf(idx).single);
        return self.stringSlice(si);
    }

    pub fn stringText(self: *const Tree, idx: NodeIndex) []const u8 {
        std.debug.assert(self.tagOf(idx) == .string);
        const si: StringIndex = @enumFromInt(self.dataOf(idx).single);
        return self.stringSlice(si);
    }

    pub fn commentSpans(self: *const Tree, r: CommentRange) []const Span {
        if (r.isEmpty()) return &.{};
        return self.comments.items(.span)[r.start..r.end];
    }
    pub fn commentTexts(self: *const Tree, r: CommentRange) [][]const u8 {
        if (r.isEmpty()) return &.{};
        return self.comments.items(.text)[r.start..r.end];
    }
    pub fn commentKinds(self: *const Tree, r: CommentRange) []const Comment.Kind {
        if (r.isEmpty()) return &.{};
        return self.comments.items(.kind)[r.start..r.end];
    }
};

pub const FormHeader = struct {
    head: []const u8,
    namespace: ?[]const u8,
    head_span: Span,
    children: []const NodeIndex,
};

pub const KvPairHeader = struct {
    key: []const u8,
    value: NodeIndex,
    key_span: Span,
};

pub const NumberWithUnit = struct {
    value: f64,
    unit: []const u8,
};

pub const TreeBuilder = struct {
    a: Allocator,

    nodes: std.MultiArrayList(Node) = .{},
    extra_data: std.ArrayList(u32) = .empty,
    strings: std.ArrayList(u8) = .empty,
    string_index: std.ArrayList(u32) = .empty,
    comments: std.MultiArrayList(Comment) = .{},
    leading_index: std.ArrayList(CommentRange) = .empty,
    trailing_index: std.ArrayList(CommentRange) = .empty,

    pub fn addString(self: *TreeBuilder, text: []const u8) Allocator.Error!StringIndex {
        if (self.string_index.items.len == 0) {
            try self.string_index.append(self.a, 0);
        }
        const i: u32 = @intCast(self.string_index.items.len - 1);
        try self.strings.appendSlice(self.a, text);
        try self.string_index.append(self.a, @intCast(self.strings.items.len));
        return StringIndex.from(i);
    }

    pub fn appendNode(self: *TreeBuilder, node: Node) Allocator.Error!NodeIndex {
        const i: u32 = @intCast(self.nodes.len);
        try self.nodes.append(self.a, node);
        try self.leading_index.append(self.a, .empty);
        try self.trailing_index.append(self.a, .empty);
        return NodeIndex.from(i);
    }

    pub fn setLeading(self: *TreeBuilder, idx: NodeIndex, range: CommentRange) void {
        self.leading_index.items[idx.raw()] = range;
    }

    pub fn setTrailing(self: *TreeBuilder, idx: NodeIndex, range: CommentRange) void {
        self.trailing_index.items[idx.raw()] = range;
    }

    pub fn addCommentRange(self: *TreeBuilder, src: []const Comment) Allocator.Error!CommentRange {
        if (src.len == 0) return .empty;
        const start: u32 = @intCast(self.comments.len);
        for (src) |c| {
            const text_copy = try self.a.dupe(u8, c.text);
            try self.comments.append(self.a, .{
                .span = c.span,
                .text = text_copy,
                .kind = c.kind,
            });
        }
        const end: u32 = @intCast(self.comments.len);
        return .{ .start = start, .end = end };
    }

    pub fn addForm(
        self: *TreeBuilder,
        head: StringIndex,
        namespace: ?StringIndex,
        head_span: Span,
        children: []const NodeIndex,
        span: Span,
    ) Allocator.Error!NodeIndex {
        const ns_raw: u32 = if (namespace) |n| n.raw() else StringIndex.invalid.raw();
        const hdr_at: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.appendSlice(self.a, &.{
            head.raw(),
            ns_raw,
            head_span.start,
            head_span.end,
            @intCast(children.len),
        });
        for (children) |ci| try self.extra_data.append(self.a, ci.raw());
        return self.appendNode(.{
            .tag = .form,
            .span = span,
            .data = .{ .single = hdr_at },
        });
    }

    pub fn addVector(
        self: *TreeBuilder,
        elements: []const NodeIndex,
        span: Span,
    ) Allocator.Error!NodeIndex {
        const start: u32 = @intCast(self.extra_data.items.len);
        for (elements) |ci| try self.extra_data.append(self.a, ci.raw());
        const end: u32 = @intCast(self.extra_data.items.len);
        return self.appendNode(.{
            .tag = .vector,
            .span = span,
            .data = .{ .pair = .{ .a = start, .b = end } },
        });
    }

    pub fn addKvpair(
        self: *TreeBuilder,
        key: StringIndex,
        value: NodeIndex,
        key_span: Span,
        span: Span,
    ) Allocator.Error!NodeIndex {
        const hdr_at: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.appendSlice(self.a, &.{
            key.raw(),
            value.raw(),
            key_span.start,
            key_span.end,
        });
        return self.appendNode(.{
            .tag = .kvpair,
            .span = span,
            .data = .{ .single = hdr_at },
        });
    }

    pub fn cloneCommentRange(
        self: *TreeBuilder,
        src_tree: *const Tree,
        range: CommentRange,
    ) Allocator.Error!CommentRange {
        if (range.isEmpty()) return .empty;
        const start: u32 = @intCast(self.comments.len);
        var i: u32 = range.start;
        while (i < range.end) : (i += 1) {
            const span = src_tree.comments.items(.span)[i];
            const text = src_tree.comments.items(.text)[i];
            const kind = src_tree.comments.items(.kind)[i];
            const text_copy = try self.a.dupe(u8, text);
            try self.comments.append(self.a, .{
                .span = span,
                .text = text_copy,
                .kind = kind,
            });
        }
        const end: u32 = @intCast(self.comments.len);
        return .{ .start = start, .end = end };
    }

    pub fn appendNumber(self: *TreeBuilder, n: f64, span: Span) Allocator.Error!NodeIndex {
        return self.appendNode(.{
            .tag = .number,
            .span = span,
            .data = .{ .immediate = @bitCast(n) },
        });
    }

    pub fn appendString(self: *TreeBuilder, text: []const u8, span: Span) Allocator.Error!NodeIndex {
        const si = try self.addString(text);
        return self.appendNode(.{
            .tag = .string,
            .span = span,
            .data = .{ .single = si.raw() },
        });
    }

    pub fn appendSymbol(self: *TreeBuilder, text: []const u8, span: Span) Allocator.Error!NodeIndex {
        const si = try self.addString(text);
        return self.appendNode(.{
            .tag = .symbol,
            .span = span,
            .data = .{ .single = si.raw() },
        });
    }

    pub fn appendKeyword(self: *TreeBuilder, text: []const u8, span: Span) Allocator.Error!NodeIndex {
        const si = try self.addString(text);
        return self.appendNode(.{
            .tag = .keyword,
            .span = span,
            .data = .{ .single = si.raw() },
        });
    }

    pub fn appendBoolean(self: *TreeBuilder, value: bool, span: Span) Allocator.Error!NodeIndex {
        return self.appendNode(.{
            .tag = if (value) .boolean_true else .boolean_false,
            .span = span,
            .data = .{ .immediate = 0 },
        });
    }

    pub fn appendNil(self: *TreeBuilder, span: Span) Allocator.Error!NodeIndex {
        return self.appendNode(.{
            .tag = .nil,
            .span = span,
            .data = .{ .immediate = 0 },
        });
    }

    pub fn appendForm(
        self: *TreeBuilder,
        head: []const u8,
        namespace: ?[]const u8,
        head_span: Span,
        children: []const NodeIndex,
        span: Span,
    ) Allocator.Error!NodeIndex {
        const head_si = try self.addString(head);
        const ns_si: ?StringIndex = if (namespace) |ns| try self.addString(ns) else null;
        return self.addForm(head_si, ns_si, head_span, children, span);
    }

    pub fn appendKvpair(
        self: *TreeBuilder,
        key: []const u8,
        value: NodeIndex,
        key_span: Span,
        span: Span,
    ) Allocator.Error!NodeIndex {
        const key_si = try self.addString(key);
        return self.addKvpair(key_si, value, key_span, span);
    }

    pub fn appendVector(
        self: *TreeBuilder,
        elements: []const NodeIndex,
        span: Span,
    ) Allocator.Error!NodeIndex {
        return self.addVector(elements, span);
    }

    pub fn finalize(
        self: *TreeBuilder,
        arena_state: *std.heap.ArenaAllocator,
        source: [:0]const u8,
        roots: []const NodeIndex,
    ) Allocator.Error!Tree {
        if (self.string_index.items.len == 0) {
            try self.string_index.append(self.a, 0);
        }
        const roots_dup = try self.a.dupe(NodeIndex, roots);

        const owned = arena_state.*;
        arena_state.* = std.heap.ArenaAllocator.init(arena_state.child_allocator);

        return .{
            .arena = owned,
            .source = source,
            .nodes = self.nodes.toOwnedSlice(),
            .extra_data = self.extra_data.items,
            .strings = self.strings.items,
            .string_index = self.string_index.items,
            .root = roots_dup,
            .leading_comments_index = self.leading_index.items,
            .trailing_comments_index = self.trailing_index.items,
            .comments = self.comments.toOwnedSlice(),
            .tree_trailing_comments = .empty,
            .diagnostics = &.{},
        };
    }

    pub fn cloneNode(
        self: *TreeBuilder,
        src_tree: *const Tree,
        src_idx: NodeIndex,
    ) Allocator.Error!NodeIndex {
        const tag = src_tree.tagOf(src_idx);
        const span = src_tree.spanOf(src_idx);
        const idx: NodeIndex = switch (tag) {
            .number, .number_i64, .number_u64 => try self.appendNode(.{
                .tag = tag,
                .span = span,
                .data = .{ .immediate = src_tree.dataOf(src_idx).immediate },
            }),
            .number_with_unit => blk: {
                const nu = src_tree.numberWithUnitOf(src_idx);
                const unit_si = try self.addString(nu.unit);
                const bits: u64 = @bitCast(nu.value);
                const hdr_at: u32 = @intCast(self.extra_data.items.len);
                try self.extra_data.appendSlice(self.a, &.{
                    @truncate(bits),
                    @truncate(bits >> 32),
                    unit_si.raw(),
                });
                break :blk try self.appendNode(.{
                    .tag = .number_with_unit,
                    .span = span,
                    .data = .{ .single = hdr_at },
                });
            },
            .string, .keyword, .symbol => blk: {
                const src_si: StringIndex = @enumFromInt(src_tree.dataOf(src_idx).single);
                const new_si = try self.addString(src_tree.stringSlice(src_si));
                break :blk try self.appendNode(.{
                    .tag = tag,
                    .span = span,
                    .data = .{ .single = new_si.raw() },
                });
            },
            .boolean_true, .boolean_false, .nil => try self.appendNode(.{
                .tag = tag,
                .span = span,
                .data = .{ .immediate = 0 },
            }),
            .date => try self.appendNode(.{
                .tag = .date,
                .span = span,
                .data = .{ .immediate = src_tree.dataOf(src_idx).immediate },
            }),
            .time => try self.appendNode(.{
                .tag = .time,
                .span = span,
                .data = .{ .immediate = src_tree.dataOf(src_idx).immediate },
            }),
            .vector => blk: {
                const src_elements = src_tree.vectorElements(src_idx);
                var new_elements = try std.ArrayList(NodeIndex).initCapacity(self.a, src_elements.len);
                for (src_elements) |elem_idx| {
                    const ni = try self.cloneNode(src_tree, elem_idx);
                    new_elements.appendAssumeCapacity(ni);
                }
                break :blk try self.addVector(new_elements.items, span);
            },
            .form => blk: {
                const hdr = src_tree.formHeader(src_idx);
                const head_si = try self.addString(hdr.head);
                const ns_si: ?StringIndex = if (hdr.namespace) |n|
                    try self.addString(n)
                else
                    null;
                var new_children = try std.ArrayList(NodeIndex).initCapacity(self.a, hdr.children.len);
                for (hdr.children) |child_idx| {
                    const ni = try self.cloneNode(src_tree, child_idx);
                    new_children.appendAssumeCapacity(ni);
                }
                const form_idx = try self.addForm(head_si, ns_si, hdr.head_span, new_children.items, span);
                const trailing_src = src_tree.trailing_comments_index[src_idx.raw()];
                const trailing_dst = try self.cloneCommentRange(src_tree, trailing_src);
                self.setTrailing(form_idx, trailing_dst);
                break :blk form_idx;
            },
            .kvpair => blk: {
                const kvh = src_tree.kvpairHeader(src_idx);
                const value_idx = try self.cloneNode(src_tree, kvh.value);
                const key_si = try self.addString(kvh.key);
                break :blk try self.addKvpair(key_si, value_idx, kvh.key_span, span);
            },
        };

        const leading_src = src_tree.leading_comments_index[src_idx.raw()];
        const leading_dst = try self.cloneCommentRange(src_tree, leading_src);
        self.setLeading(idx, leading_dst);

        return idx;
    }
};

const testing = std.testing;

fn cloneTree(gpa: Allocator, src: *const Tree) Allocator.Error!Tree {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var b: TreeBuilder = .{ .a = a };
    const root_indices = try a.alloc(NodeIndex, src.root.len);
    for (src.root, 0..) |idx, i| {
        root_indices[i] = try b.cloneNode(src, idx);
    }
    const tree_trailing = try b.cloneCommentRange(src, src.tree_trailing_comments);
    const diagnostics_dup = try a.dupe(Diagnostic, src.diagnostics);

    if (b.string_index.items.len == 0) {
        try b.string_index.append(a, 0);
    }

    return Tree{
        .arena = arena,
        .source = src.source,
        .nodes = b.nodes.toOwnedSlice(),
        .extra_data = b.extra_data.items,
        .strings = b.strings.items,
        .string_index = b.string_index.items,
        .root = root_indices,
        .leading_comments_index = b.leading_index.items,
        .trailing_comments_index = b.trailing_index.items,
        .comments = b.comments.toOwnedSlice(),
        .tree_trailing_comments = tree_trailing,
        .diagnostics = diagnostics_dup,
    };
}
